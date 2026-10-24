#!/usr/bin/env python3
"""Check CVE-2026-111497 fixes without installing packages or starting services."""

import argparse
import re
import subprocess
import sys


# Run inside the final image. Debian and RPM backports must be checked using
# package revisions/changelogs; their upstream library version can stay unchanged.
INVENTORY = r'''
set -eu
if command -v apk >/dev/null 2>&1; then
    printf 'package-db\tapk\n'
    awk -F: '/^P:/ {package=$2} /^V:/ && package == "brotli-libs" {print "apk\t" $2}' \
        /lib/apk/db/installed
elif command -v dpkg-query >/dev/null 2>&1; then
    printf 'package-db\tdpkg\n'
    version=$(dpkg-query -W -f='${Version}' libbrotli1 2>/dev/null || true)
    if [ -n "$version" ]; then
        printf 'dpkg\t%s\n' "$version"
        case "$version" in
            1.0.9-2+deb12u*) minimum=1.0.9-2+deb12u1 ;;
            1.1.0-2+deb13u*) minimum=1.1.0-2+deb13u1 ;;
            *) minimum=999999 ;;
        esac
        if dpkg --compare-versions "$version" ge "$minimum"; then
            printf 'dpkg-backport\tverified\n'
        fi
    fi
elif command -v rpm >/dev/null 2>&1; then
    printf 'package-db\trpm\n'
    if rpm -q libbrotli >/dev/null 2>&1; then
        rpm -q --qf 'rpm\t%{VERSION}-%{RELEASE}\n' libbrotli
        if rpm -q --changelog libbrotli | grep -q 'CVE-2026-111497'; then
            printf 'rpm-backport\tverified\n'
        fi
    fi
else
    echo 'Unsupported package database; Brotli cannot be verified' >&2
    exit 1
fi
if [ -d /nix/store ]; then
    find /nix/store -path '*/lib/libbrotlidec.so*' -print |
        sed 's/^/nix\t/'
fi
if command -v curl >/dev/null 2>&1; then
    curl --version | head -n 1 | sed 's/^/curl\t/'
fi
if [ "$1" = true ]; then
    printf 'node\t'
    node -p process.versions.node
fi
if [ "$2" = true ]; then
    printf 'bun\t'
    bun --version
fi
'''


def version_tuple(value):
    """Read a stable upstream version while retaining package revision checks."""
    match = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:$|[-+])", value)
    if not match:
        raise ValueError(f"Unrecognized version: {value}")
    return tuple(map(int, match.groups()))


def upstream_fixed(value):
    """Accept fixes on all three upstream release lines, including future lines."""
    version = version_tuple(value)
    if version < (1, 0, 3):
        return True
    if version[:2] == (1, 0):
        return version >= (1, 0, 10)
    if version[:2] == (1, 1):
        return version >= (1, 1, 1)
    return version >= (1, 2, 1)


def inspect_inventory(output, check_node=False, check_bun=False):
    """Reject every affected copy; one fixed package cannot clear another copy."""
    records = [line.split("\t", 1) for line in output.splitlines() if line]
    if not records:
        raise ValueError("Empty Brotli inventory")
    if any(len(record) != 2 for record in records):
        raise ValueError("Incomplete Brotli inventory")
    flags = {kind for kind, value in records if value == "verified"}
    failures = []
    copies = 0
    for kind, value in records:
        if kind in ("apk", "dpkg", "rpm"):
            copies += 1
            if not upstream_fixed(value) and f"{kind}-backport" not in flags:
                failures.append(f"{kind} Brotli {value}: no verified CVE-2026-111497 fix")
        elif kind == "nix":
            copies += 1
            match = re.search(r"/[^/]*-brotli-(\d+\.\d+\.\d+)(?:-|/)", value)
            if not match or not upstream_fixed(match.group(1)):
                failures.append(f"Nix Brotli needs a verified upstream fix: {value}")
        elif kind == "node":
            minimum = {22: (22, 23, 4), 24: (24, 22, 1), 26: (26, 12, 1)}
            version = version_tuple(value)
            if version[0] not in minimum or version < minimum[version[0]]:
                failures.append(f"Node.js {value}: update to a verified fixed release")
        elif kind == "bun" and version_tuple(value) < (1, 4, 4):
            failures.append(f"Bun {value}: update to 1.4.4 or newer")
        elif kind == "curl":
            match = re.search(r"\bbrotli/(\d+\.\d+\.\d+)", value, re.I)
            if match and not upstream_fixed(match.group(1)):
                backported = any(
                    package_kind in ("dpkg", "rpm")
                    and f"{package_kind}-backport" in flags
                    and version_tuple(package_version) == version_tuple(match.group(1))
                    for package_kind, package_version in records
                    if package_kind in ("apk", "dpkg", "rpm"))
                if not backported:
                    failures.append(f"cURL still reports affected Brotli {match.group(1)}")
    for kind, enabled in (("node", check_node), ("bun", check_bun)):
        if enabled and not any(record[0] == kind for record in records):
            failures.append(f"Missing requested {kind} runtime check")
    if not copies and any(kind == "curl" and re.search(r"\bbrotli/", value, re.I)
                          for kind, value in records):
        failures.append("cURL has Brotli support but no checked Brotli package was found")
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--check-node", action="store_true")
    parser.add_argument("--check-bun", action="store_true")
    args = parser.parse_args()
    # No startup entrypoint, credentials, mounts or network access are needed.
    result = subprocess.run([
        "docker", "run", "--rm", "--interactive", "--network", "none", "--read-only",
        "--entrypoint", "/bin/sh", args.image, "-s", "--",
        str(args.check_node).lower(), str(args.check_bun).lower(),
    ], input=INVENTORY, text=True, capture_output=True, check=True)
    print(result.stdout, end="")
    failures = inspect_inventory(result.stdout, args.check_node, args.check_bun)
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("No affected Brotli decoder found in the checked packages and runtimes.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"Brotli verification failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
