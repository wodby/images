#!/usr/bin/env python3
"""Update a product's pinned parent from inside its own repository workflow."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import quote, urlencode
from urllib.request import urlopen

from base_images import BaseImages
from image_release import api, git

SEMVER = re.compile(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z')
REVISION = re.compile(r'r(0|[1-9][0-9]*)\Z')


def latest_parent(repository, prefix):
    """Inspect all matching registry pages; unrelated lines cannot upgrade a product."""
    pattern = re.compile(re.escape(prefix) + r'r(0|[1-9][0-9]*)\Z')
    latest = None
    page = 1
    while True:
        query = urlencode({'name': prefix + 'r', 'page_size': 100, 'page': page})
        namespace, name = repository.split('/', 1)
        url = f'https://hub.docker.com/v2/namespaces/{namespace}/repositories/{name}/tags?{query}'
        with urlopen(url, timeout=30) as response:
            data = json.load(response)
        for item in data['results']:
            match = pattern.fullmatch(item['name'])
            if match and (latest is None or int(match[1]) > latest):
                latest = int(match[1])
        if not data.get('next'):
            break
        page += 1
    if latest is None:
        raise ValueError('No published parent revision found')
    return f'r{latest}'


def parent_notes(repository, tag):
    """Only release annotations can supply the product's inherited release notes."""
    status, ref = api('GET', f'repos/{repository}/git/ref/tags/{quote(tag, safe="")}')
    if status != 200 or ref['object']['type'] != 'tag':
        raise ValueError('Parent release requires an annotated tag')
    status, annotation = api('GET', f'repos/{repository}/git/tags/{ref["object"]["sha"]}')
    if status != 200 or annotation['tag'] != tag:
        raise ValueError('Cannot read matching parent release notes')
    notes = re.split(r'\n-----BEGIN (?:PGP|SSH) SIGNATURE-----', annotation['message'])[0].strip()
    if not notes:
        raise ValueError('Parent release requires nonempty notes')
    return notes


def latest_product():
    """Allocate patches from the latest product tag, rejecting divergent release lines."""
    tags = [tag for tag in git('tag', '--list').splitlines() if SEMVER.fullmatch(tag)]
    if not tags:
        raise ValueError('Publish the initial product release manually')
    tag = max(tags, key=lambda value: tuple(map(int, value.split('.'))))
    git('merge-base', '--is-ancestor', f'{tag}^{{commit}}', 'HEAD')
    if git('cat-file', '-t', f'refs/tags/{tag}') != 'tag':
        raise ValueError('Product releases require annotated tags')
    if git('show', f'{tag}:.image-release-format').strip() != 'semver':
        raise ValueError('Publish the first opted-in product release manually')
    return tag


def prepare(branch, publish=False):
    """Commit only reviewed parent pins and push the patch tag atomically with them."""
    if git('status', '--porcelain'):
        raise ValueError('Product checkout must be clean')
    if git('symbolic-ref', '--short', 'HEAD') != branch:
        raise ValueError('Updates must run on the default branch')
    if git('rev-parse', 'HEAD') != git('rev-parse', f'refs/remotes/origin/{branch}'):
        raise ValueError('Checkout does not match the fetched default branch')
    if Path('.image-release-format').read_text().strip() != 'semver':
        raise ValueError('Product must opt in to semantic releases')
    pins = BaseImages('base-images.mk')
    line = pins._field('BASE_IMAGE_VERSION')
    current = pins._field('BASE_IMAGE_REVISION')
    if not re.fullmatch(r'\d+(?:\.\d+)*', line) or not REVISION.fullmatch(current):
        raise ValueError('Invalid parent release line or revision')
    prefix = line + pins.suffix + '-'
    pins.reference(prefix + current)
    product = latest_product()
    latest = latest_parent(pins.repository, prefix)
    if int(latest[1:]) <= int(current[1:]):
        # A prior push may have succeeded before workflow dispatch failed. Retry
        # that exact tag, never allocate another patch or release untagged work.
        if git('rev-parse', f'{product}^{{commit}}') == git('rev-parse', 'HEAD'):
            return product if publish else ''
        return ''
    notes = parent_notes(pins.repository, prefix + latest)
    # Resolve every pin before touching the checkout, including during previews.
    with tempfile.TemporaryDirectory() as directory:
        planned = Path(directory) / 'base-images.mk'
        planned.write_text(pins.text)
        candidate = BaseImages(planned)
        candidate.update('stability', new=latest)
        text = planned.read_text().replace(
            f'BASE_IMAGE_REVISION := {current}', f'BASE_IMAGE_REVISION := {latest}')
    major, minor, patch = map(int, product.split('.'))
    tag = f'{major}.{minor}.{patch + 1}'
    message = f'Update base image to {pins.repository}:{prefix}{latest}\n\n{notes}'
    print(f'Proposed product release: {tag}\n{message}')
    if not publish:
        return ''
    Path('base-images.mk').write_text(text)
    git('add', '--', 'base-images.mk')
    git('commit', '-m', message)
    git('tag', '-a', tag, '-m', message)
    git('push', '--atomic', 'origin', f'HEAD:refs/heads/{branch}', f'refs/tags/{tag}')
    return tag


def dispatch(repository, workflow, tag):
    """GITHUB_TOKEN pushes need an explicit dispatch; retain retries after failures."""
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Invalid repository')
    if not re.fullmatch(r'[A-Za-z0-9_-]+\.ya?ml', workflow):
        raise ValueError('Invalid publication workflow')
    status, release = api('GET', f'repos/{repository}/releases/tags/{tag}')
    if status == 200:
        if release['draft'] or release['tag_name'] != tag:
            raise ValueError('Existing release requires manual review')
        return
    if status != 404:
        raise ValueError('Cannot determine release state')
    sha = git('rev-parse', f'{tag}^{{commit}}')
    remote = git('ls-remote', '--exit-code', 'origin', f'refs/tags/{tag}').split()
    if remote != [git('rev-parse', f'refs/tags/{tag}'), f'refs/tags/{tag}']:
        raise ValueError('Remote release tag is missing or changed')
    endpoint = f'repos/{repository}/actions/workflows/{workflow}'
    status, runs = api('GET', f'{endpoint}/runs?head_sha={sha}&per_page=100')
    if status != 200:
        raise ValueError('Cannot determine publication workflow state')
    if any(run['head_branch'] == tag and run['status'] != 'completed'
           for run in runs['workflow_runs']):
        return
    status, _ = api('POST', f'{endpoint}/dispatches', {'ref': tag})
    if status != 204:
        raise ValueError('Publication workflow dispatch failed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--branch', required=True)
    parser.add_argument('--workflow', required=True)
    parser.add_argument('--publish', action='store_true')
    args = parser.parse_args()
    git('fetch', 'origin', f'refs/heads/{args.branch}:refs/remotes/origin/{args.branch}', '--tags')
    tag = prepare(args.branch, args.publish)
    if tag:
        dispatch(os.environ['GITHUB_REPOSITORY'], args.workflow, tag)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Parent image update failed: {error}')
