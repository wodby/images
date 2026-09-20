#!/usr/bin/env python3
"""Read and update the base image inputs consumed by image Makefiles."""

import argparse
import json
import os
from pathlib import Path
import re
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import urlopen

DIGEST = re.compile(r"sha256:[a-f0-9]{64}\Z")
PIN = re.compile(r"BASE_IMAGE_DIGEST_([A-Za-z0-9_][A-Za-z0-9_.-]*) := (sha256:[a-f0-9]{64})\Z")
BUILDER = re.compile(r"(BUILD_IMAGE_[A-Z0-9_]+) := ([a-z0-9_.-]+(?:/[a-z0-9_.-]+)?):([A-Za-z0-9_][A-Za-z0-9_.-]*)@(sha256:[a-f0-9]{64})\Z")
STABILITY = re.compile(r"-\d+\.\d+\.\d+$")


def resolve_digest(repository, tag):
    """Resolve Docker Hub's tag-level digest without downloading image layers."""
    if "/" not in repository:
        repository = "library/" + repository
    namespace, name = repository.split("/", 1)
    url = ("https://hub.docker.com/v2/namespaces/" + quote(namespace, safe="")
           + "/repositories/" + quote(name, safe="") + "/tags/" + quote(tag, safe=""))
    for attempt in range(4):
        try:
            with urlopen(url, timeout=30) as response:
                digest = json.load(response).get("digest", "")
            if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
                raise ValueError(f"Invalid manifest digest for {repository}:{tag}")
            return digest
        except (HTTPError, URLError, TimeoutError) as exc:
            if attempt == 3 or isinstance(exc, HTTPError) and exc.code not in (429, 500, 502, 503, 504):
                raise ValueError(f"Cannot resolve {repository}:{tag}: {exc}") from exc
            time.sleep(2 ** attempt)


class BaseImages:
    """Keep updates atomic and preserve the Makefile's non-pin content."""

    def __init__(self, path):
        self.path = Path(path)
        self.text = self.path.read_text()
        self.repository = self._field("BASE_IMAGE_REPOSITORY")
        self.suffix = self._field("BASE_IMAGE_VERSION_SUFFIX")
        if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]*(?:/[a-z0-9][a-z0-9_.-]*)?", self.repository):
            raise ValueError("Invalid base image repository")
        if not re.fullmatch(r"(?:-[A-Za-z0-9_.-]+)?", self.suffix):
            raise ValueError("Invalid base image version suffix")
        self.pins = {}
        self.builders = {}
        for line in self.text.splitlines():
            if line.startswith("BUILD_IMAGE_"):
                match = BUILDER.fullmatch(line)
                if not match or match[1] in self.builders:
                    raise ValueError(f"Invalid or duplicate builder image: {line}")
                self.builders[match[1]] = (match[2], match[3], match[4])
            if not line.startswith("BASE_IMAGE_DIGEST_"):
                continue
            match = PIN.fullmatch(line)
            if not match or match[1] in self.pins:
                raise ValueError(f"Invalid or duplicate base image pin: {line}")
            self.pins[match[1]] = match[2]
        if not self.pins:
            raise ValueError("No base image pins found")

    def _field(self, key):
        matches = re.findall(r"^" + key + r" := *([^\n]*)$", self.text, re.M)
        if len(matches) != 1:
            raise ValueError(f"Expected one {key} assignment")
        return matches[0].strip()

    def reference(self, tag, pins=None):
        return f"{self.repository}:{tag}@{(self.pins if pins is None else pins)[tag]}"

    def ref_for_line(self, line, stability=""):
        """Select the exact non-dev base used by a supported release line."""
        ending = self.suffix + ("-" + stability if stability else "")
        pattern = re.compile(re.escape(line) + r"(?:\.[0-9]+)*" + re.escape(ending) + r"\Z")
        candidates = [tag for tag in self.pins if pattern.fullmatch(tag)]
        if len(candidates) != 1:
            raise ValueError(f"Expected one base image for line {line}, found {candidates}")
        return self.reference(candidates[0])

    def update(self, mode, old="", new="", resolver=resolve_digest):
        """Resolve every candidate before replacing the file; failures leave it intact."""
        candidate = dict(self.pins)
        builders = dict(self.builders)
        changes = []
        selected = []
        if mode == "refresh":
            selected = [(tag, tag) for tag in self.pins]
        elif mode == "version":
            if not re.fullmatch(r"\d+(?:\.\d+)*", old) or not re.fullmatch(r"\d+(?:\.\d+)*", new):
                raise ValueError("Invalid version transition")
            tag = old + self.suffix
            if tag not in self.pins:
                raise ValueError(f"Missing base image pin for {tag}")
            selected = [(tag, new + self.suffix)]
        elif mode == "stability":
            if not re.fullmatch(r"\d+\.\d+\.\d+", new):
                raise ValueError("Invalid stability tag")
            # Every floating variant needs a matching pin for the new stability release.
            selected = [(tag, tag + "-" + new) for tag in self.pins if not STABILITY.search(tag)]
            if not selected:
                raise ValueError("No base image variants for stability update")
            candidate = {tag: digest for tag, digest in candidate.items() if not STABILITY.search(tag)}
        else:
            raise ValueError(f"Unknown update mode: {mode}")
        for previous, tag in selected:
            digest = resolver(self.repository, tag)
            if not DIGEST.fullmatch(digest):
                raise ValueError(f"Invalid digest for {self.repository}:{tag}")
            if mode == "version":
                candidate.pop(previous)
            candidate[tag] = digest
            if self.pins.get(tag) != digest:
                changes.append((self.reference(previous), self.reference(tag, candidate)))
        if mode == "refresh":
            for key, (repository, tag, previous) in self.builders.items():
                digest = resolver(repository, tag)
                if not DIGEST.fullmatch(digest):
                    raise ValueError(f"Invalid builder digest for {repository}:{tag}")
                builders[key] = (repository, tag, digest)
                if digest != previous:
                    changes.append((f"{repository}:{tag}@{previous}", f"{repository}:{tag}@{digest}"))
        if candidate == self.pins and builders == self.builders:
            return []
        lines = self.text.splitlines(keepends=True)
        first = next(i for i, line in enumerate(lines) if line.startswith("BASE_IMAGE_DIGEST_"))
        lines = [line for line in lines if not line.startswith("BASE_IMAGE_DIGEST_")]
        lines[first:first] = [f"BASE_IMAGE_DIGEST_{tag} := {digest}\n" for tag, digest in sorted(candidate.items())]
        lines = [
            (f"{match[1]} := {builders[match[1]][0]}:{builders[match[1]][1]}@{builders[match[1]][2]}\n"
             if (match := BUILDER.fullmatch(line.rstrip("\n"))) else line)
            for line in lines
        ]
        # Use a sibling file so replacement remains atomic on the repository filesystem.
        fd, temporary = tempfile.mkstemp(prefix=".base-images-", dir=self.path.parent)
        try:
            with os.fdopen(fd, "w") as stream:
                stream.write("".join(lines))
            os.chmod(temporary, self.path.stat().st_mode & 0o777)
            os.replace(temporary, self.path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        return changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["repository", "suffix", "ref", "refresh", "version", "stability"])
    parser.add_argument("--file", default="base-images.mk")
    parser.add_argument("--old", default="")
    parser.add_argument("--new", default="")
    parser.add_argument("--line", default="")
    parser.add_argument("--stability", default="")
    args = parser.parse_args()
    images = BaseImages(args.file)
    if args.command == "repository":
        print(images.repository)
    elif args.command == "suffix":
        print(images.suffix)
    elif args.command == "ref":
        print(images.ref_for_line(args.line, args.stability))
    else:
        for previous, current in images.update(args.command, args.old, args.new):
            print(f"{previous} -> {current}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        raise SystemExit(str(error))
