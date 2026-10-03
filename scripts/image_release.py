#!/usr/bin/env python3
"""Publish a GitHub Release after a primary image revision finishes publishing."""

import argparse
import json
import os
import re
import subprocess
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def git(*args):
    """Read Git state without invoking a shell."""
    result = subprocess.run(['git', *args], text=True, capture_output=True, check=True)
    return result.stdout.rstrip('\n')


def release_notes(tag, expected_commit, release_format="revision"):
    """Require the original, remotely published annotated primary revision."""
    if release_format == 'revision':
        if not re.fullmatch(r'r(0|[1-9][0-9]*)', tag):
            raise ValueError('Only primary rN tags can have an automatic GitHub Release')
    elif release_format == 'semver':
        if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', tag):
            raise ValueError('Product releases require a semantic version')
    else:
        raise ValueError('Unknown release format')
    ref = f'refs/tags/{tag}'
    if git('cat-file', '-t', ref) != 'tag':
        raise ValueError('Release requires an annotated Git tag')
    if git('rev-parse', f'{ref}^{{commit}}') != expected_commit:
        raise ValueError('Release tag does not match the workflow commit')
    if git('show', f'{ref}:.image-release-format').strip() != release_format:
        raise ValueError('Repository does not use the requested release format')
    remote = git('ls-remote', '--exit-code', 'origin', ref).split()
    if remote != [git('rev-parse', ref), ref]:
        raise ValueError('Remote release tag is missing or changed')
    notes = git('for-each-ref', '--format=%(contents)', ref)
    signature = git('for-each-ref', '--format=%(contents:signature)', ref)
    if signature:
        if not notes.endswith(signature):
            raise ValueError('Cannot separate the tag signature from release notes')
        notes = notes[:-len(signature)]
    notes = notes.strip()
    if not notes:
        raise ValueError('Release requires nonempty tag notes')
    return notes


def api(method, endpoint, payload=None):
    """Call GitHub; distinguish a missing release from authentication/API failures."""
    token = os.environ.get('GH_TOKEN')
    if not token:
        raise ValueError('GH_TOKEN is required')
    request = Request(
        f'https://api.github.com/{endpoint}', method=method,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={'Authorization': f'Bearer {token}',
                 'Accept': 'application/vnd.github+json',
                 'Content-Type': 'application/json',
                 'X-GitHub-Api-Version': '2022-11-28'})
    try:
        with urlopen(request, timeout=60) as response:
            return response.status, None if response.status == 204 else json.load(response)
    except HTTPError as error:
        # Only these two statuses can mean an absent release or a concurrent create.
        if error.code in (404, 422):
            return error.code, None
        raise ValueError(f'GitHub {method} failed with HTTP {error.code}') from error


def published(release, tag):
    """Preserve published releases and leave manually prepared drafts untouched."""
    if release['tag_name'] != tag or release['draft']:
        raise ValueError('Existing release is a draft or does not match the tag')
    return release['html_url']


def publish(repository, tag, expected_commit, release_format="revision"):
    """Create exactly one release; retries never overwrite existing release notes."""
    if not re.fullmatch(r'wodby/[a-z0-9-]+', repository):
        raise ValueError('Expected a Wodby image repository')
    notes = release_notes(tag, expected_commit, release_format)
    endpoint = f'repos/{repository}/releases'
    status, release = api('GET', f'{endpoint}/tags/{tag}')
    if status == 200:
        return published(release, tag)
    if status != 404:
        raise ValueError(f'Cannot look up release: HTTP {status}')
    status, release = api('POST', endpoint, {
        'tag_name': tag, 'name': tag, 'body': notes,
        'draft': False, 'prerelease': False, 'generate_release_notes': False,
        'make_latest': 'legacy',
    })
    if status == 201:
        return published(release, tag)
    if status == 422:
        # Another job may have completed publication between our lookup and POST.
        retry_status, existing = api('GET', f'{endpoint}/tags/{tag}')
        if retry_status == 200:
            return published(existing, tag)
    raise ValueError(f'Cannot create release: HTTP {status}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--format', choices=['revision', 'semver'], default='revision')
    args = parser.parse_args()
    try:
        print(publish(args.repository, args.tag, args.expected_commit, args.format))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f'Image release failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
