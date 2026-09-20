#!/usr/bin/env python3
"""Plan and publish immutable Docker aliases and their annotated Git tags."""

import argparse
import base64
from functools import lru_cache
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import quote

import yaml

CONFIG = '.image-revision-aliases.json'
WORKFLOW = '.github/workflows/workflow.yml'
PRIMARY = re.compile(r'r([1-9][0-9]*)\Z')
VERSION = re.compile(r'[0-9]+(?:\.[0-9]+)+\Z')
TAG = re.compile(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\Z')


def command(*args, cwd=None, check=True):
    """Capture command output without invoking a shell."""
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    if check and result.returncode:
        raise ValueError(f'{args[0]} failed: {result.stderr.strip()}')
    return result


class Repository:
    """Read release inputs from committed snapshots, never from floating refs."""

    def __init__(self, path):
        self.path = Path(path)

    def git(self, *args, check=True):
        return command('git', *args, cwd=self.path, check=check)

    @lru_cache(maxsize=None)
    def read(self, ref, path):
        return self.git('show', f'{ref}:{path}').stdout

    @lru_cache(maxsize=None)
    def parent_workflow(self, repository, tag):
        """Resolve pinned parent releases through the public GitHub contents API."""
        if not re.fullmatch(r'wodby/[a-z0-9-]+', repository):
            raise ValueError('Parent must be a Wodby image repository')
        if not re.fullmatch(r'(?:r[1-9][0-9]*|[0-9]+\.[0-9]+\.[0-9]+)', tag):
            raise ValueError('Parent image must be pinned to a release tag')
        response = command('gh', 'api',
                           f'repos/{repository}/contents/{WORKFLOW}?ref={quote(tag)}')
        return yaml.safe_load(base64.b64decode(json.loads(response.stdout)['content']))

    def version(self, ref, selector, workflow):
        """Read one upstream version using the selector recorded in this release."""
        if 'env' in selector:
            value = workflow['env'][selector['env']]
        elif 'job' in selector:
            steps = workflow['jobs'][selector['job']]['steps']
            values = [s['with']['version'] for s in steps
                      if s.get('uses') == './.github/actions' and 'version' in s.get('with', {})]
            if len(values) != 1:
                raise ValueError(f'Ambiguous version in job {selector["job"]}')
            value = values[0]
            match = re.fullmatch(r'\$\{\{ env\.([A-Z0-9_]+) }}', str(value))
            if match:
                value = workflow['env'][match[1]]
        elif 'parent_env' in selector:
            env = workflow.get('env', {})
            pin = env.get('BASE_IMAGE_REVISION', env.get('BASE_IMAGE_STABILITY_TAG', ''))
            parent = self.parent_workflow(selector['repository'], str(pin))
            value = parent['env'][selector['parent_env']]
        elif 'file' in selector:
            matches = re.findall(selector['pattern'], self.read(ref, selector['file']), re.M)
            if len(matches) != 1:
                raise ValueError(f'Expected one version in {selector["file"]}')
            value = matches[0]
        else:
            raise ValueError('Unknown version selector')
        value = str(value)
        if not VERSION.fullmatch(value):
            raise ValueError(f'Expected a complete numeric upstream version, got {value!r}')
        # WordPress names initial releases X.Y; use X.Y.0 to distinguish their
        # exact-version aliases from the existing X.Y release-line aliases.
        if selector.get('pad_patch') and value.count('.') == 1:
            value += '.0'
        return value

    def releases(self, ref):
        """Expand the tag templates associated with each full upstream version."""
        config = json.loads(self.read(ref, CONFIG))
        if config.get('schema') != 1:
            raise ValueError('Unsupported alias configuration schema')
        if not re.fullmatch(r'wodby/[a-z0-9-]+', config['image']):
            raise ValueError('Expected a Wodby image name')
        workflow = yaml.safe_load(self.read(ref, WORKFLOW))
        releases = []
        for entry in config['versions']:
            version = self.version(ref, entry['version'], workflow)
            parts = version.split('.')
            values = {'version': version, 'major': parts[0], 'minor': '.'.join(parts[:2])}
            variants = []
            for variant in entry['variants']:
                short = [tag.format(**values) for tag in variant['short']]
                full = variant['full'].format(**values)
                if not short or full in short:
                    raise ValueError(f'Full and short tag namespaces overlap for {version}')
                if any(not TAG.fullmatch(tag) for tag in [*short, full]):
                    raise ValueError('Invalid Docker tag template')
                variants.append({'short': short, 'full': full})
            releases.append({'version': version, 'variants': variants})
        if not releases:
            raise ValueError('No versioned images configured')
        return config['image'], releases

    def plan(self, primary):
        """Count earlier primary releases containing each complete upstream version.

        Counting reservations in Git, including failed builds, makes allocation
        independent of workflow completion order. Retries cannot allocate a new
        number. Only primary tags with a committed alias config participate.
        """
        match = PRIMARY.fullmatch(primary)
        if not match:
            raise ValueError('Only primary rN tags can publish aliases')
        ref = f'refs/tags/{primary}'
        commit = self.git('rev-parse', '--verify', f'{ref}^{{commit}}').stdout.strip()
        image, releases = self.releases(ref)
        counts = {r['version']: 0 for r in releases}
        tags = self.git('tag', '--list', 'r*').stdout.splitlines()
        for tag in tags:
            older = PRIMARY.fullmatch(tag)
            if not older or int(older[1]) >= int(match[1]):
                continue
            old_ref = f'refs/tags/{tag}'
            files = self.git('ls-tree', '--name-only', old_ref, '--', CONFIG).stdout.strip()
            if not files:
                continue
            old_image, previous = self.releases(old_ref)
            if old_image != image:
                raise ValueError('Image identity changed across primary releases')
            for version in {r['version'] for r in previous} & counts.keys():
                counts[version] += 1
        aliases = {}
        for release in releases:
            revision = f'r{counts[release["version"]]}'
            for variant in release['variants']:
                source = f'{variant["short"][0]}-{primary}'
                # Every published major/minor alias also gets a Git tag.
                for short in variant['short']:
                    tag = f'{short}-{primary}'
                    self.add_alias(aliases, tag, tag, release['version'], primary)
                self.add_alias(aliases, f'{variant["full"]}-{revision}', source,
                               release['version'], revision)
        return {'primary': primary, 'commit': commit, 'image': image,
                'aliases': [dict(tag=tag, **value) for tag, value in sorted(aliases.items())]}

    @staticmethod
    def add_alias(aliases, tag, source, version, revision):
        """Reject ambiguous major aliases instead of choosing a runtime silently."""
        value = {'source': source, 'version': version, 'revision': revision}
        if not TAG.fullmatch(tag) or tag in aliases and aliases[tag] != value:
            raise ValueError(f'Conflicting or invalid alias: {tag}')
        aliases[tag] = value


def digest(image, missing_ok=False):
    """Inspect a registry manifest; authentication and transport errors are fatal."""
    result = command('docker', 'buildx', 'imagetools', 'inspect', image, check=False)
    if result.returncode:
        if missing_ok and re.search(r'manifest unknown|: not found\s*$', result.stderr, re.I):
            return None
        raise ValueError(f'Cannot inspect {image}: {result.stderr.strip()}')
    match = re.search(r'^Digest:\s+(sha256:[a-f0-9]{64})\s*$', result.stdout, re.M)
    if not match:
        raise ValueError(f'Missing manifest digest for {image}')
    return match[1]


def annotation(plan, alias):
    """Describe both the primary release and the exact published artifact."""
    return (f'{plan["image"]}:{alias["tag"]} from image release {plan["primary"]}\n\n'
            f'Upstream version: {alias["version"]}\n'
            f'Image: {plan["image"]}@{alias["digest"]}\n')


def publish(repo, plan):
    """Verify every source and destination before writing any alias.

    Callers serialize this job per primary release. Distinct primary releases
    have disjoint alias names and can finish in any order. Publication can retry
    after an interruption; existing aliases must retain the same digest. Git
    aliases are pushed atomically only after every Docker alias is verified.
    """
    missing_git = []
    for alias in plan['aliases']:
        ref = f'refs/tags/{alias["tag"]}'
        exists = repo.git('show-ref', '--verify', '--quiet', ref, check=False)
        if exists.returncode not in (0, 1):
            raise ValueError(f'Cannot inspect Git alias {ref}')
        if not exists.returncode:
            kind = repo.git('cat-file', '-t', ref).stdout.strip()
            commit = repo.git('rev-parse', f'{ref}^{{commit}}').stdout.strip()
            if kind != 'tag' or commit != plan['commit']:
                raise ValueError(f'Refusing to overwrite Git alias {ref}')
        else:
            missing_git.append(alias)

    sources = {}
    for alias in plan['aliases']:
        source = f'{plan["image"]}:{alias["source"]}'
        if source not in sources:
            sources[source] = digest(source)
        alias['digest'] = sources[source]
        target = f'{plan["image"]}:{alias["tag"]}'
        actual = sources[source] if target == source else digest(target, missing_ok=True)
        if actual and actual != alias['digest']:
            raise ValueError(f'Refusing to overwrite Docker alias {target}')
        alias['exists'] = bool(actual)
        if alias not in missing_git:
            message = repo.git('for-each-ref', '--format=%(contents)',
                               f'refs/tags/{alias["tag"]}').stdout
            if message.strip() != annotation(plan, alias).strip():
                raise ValueError(f'Git alias metadata differs: {alias["tag"]}')

    for alias in plan['aliases']:
        target = f'{plan["image"]}:{alias["tag"]}'
        if not alias['exists']:
            command('docker', 'buildx', 'imagetools', 'create', '--prefer-index=false',
                    '--tag', target, f'{plan["image"]}@{alias["digest"]}')
        if digest(target) != alias['digest']:
            raise ValueError(f'Published digest mismatch for {target}')

    for alias in missing_git:
        repo.git('-c', 'tag.gpgSign=false', 'tag', '-a', alias['tag'], plan['commit'],
                 '-m', annotation(plan, alias))
    # Include existing local aliases too: a previous push may have failed after
    # creating the local tags. Explicit refspecs never push unrelated tags.
    if plan['aliases']:
        repo.git('push', '--atomic', 'origin',
                 *[f'refs/tags/{a["tag"]}:refs/tags/{a["tag"]}' for a in plan['aliases']])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default='.')
    parser.add_argument('--tag', required=True)
    parser.add_argument('--expected-commit', help='Require the primary tag to retain the triggering commit')
    parser.add_argument('--publish', action='store_true', help='Write Docker and Git aliases')
    args = parser.parse_args()
    repo = Repository(args.repo)
    if args.publish:
        repo.git('fetch', 'origin', '--tags')
    plan = repo.plan(args.tag)
    if args.expected_commit and args.expected_commit != plan['commit']:
        raise ValueError('Primary tag no longer points to the triggering commit')
    if args.publish:
        publish(repo, plan)
    print(json.dumps(plan, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError) as error:
        sys.exit(str(error))
