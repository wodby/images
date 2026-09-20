#!/usr/bin/env python3
"""Detect package security fixes and verify them again in release builds."""

import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

RECEIPT = '.image-security-release.json'
ARCHES = ('amd64', 'arm64')
DIGEST = re.compile(r'sha256:[0-9a-f]{64}\Z')
CVE = re.compile(r'CVE-[0-9]{4}-[0-9]+\Z')


def run(*args, cwd=None, env=None):
    """Fail closed on missing registry data, scanner errors or Git failures."""
    result = subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True)
    if result.returncode:
        raise ValueError(f'{args[0]} failed: {result.stderr.strip()}')
    return result.stdout


def distro_version(sbom):
    """Syft records Alpine's VERSION_ID separately from the optional VERSION."""
    distro = sbom.get('distro', {})
    return distro.get('versionID') or distro.get('version')


def packages(sbom):
    """Require a complete Alpine APK inventory; an empty scan is not evidence."""
    if sbom.get('distro', {}).get('id') != 'alpine' or not distro_version(sbom):
        raise ValueError('Expected an Alpine SBOM')
    found = {}
    for artifact in sbom.get('artifacts', []):
        if artifact.get('type') != 'apk':
            continue
        name, version = artifact['name'], artifact['version']
        if name in found and found[name] != version:
            raise ValueError(f'Ambiguous installed package: {name}')
        found[name] = version
    if not found:
        raise ValueError('Missing APK inventory')
    return found


def findings(scan):
    """Index CVEs by installed APK package, keeping ignored findings visible."""
    if not isinstance(scan.get('matches'), list):
        raise ValueError('Missing Grype matches')
    result = defaultdict(set)
    for match in scan['matches'] + (scan.get('ignoredMatches') or []):
        artifact, vulnerability = match['artifact'], match['vulnerability']
        if artifact.get('type') == 'apk' and CVE.fullmatch(vulnerability['id']):
            result[artifact['name']].add(vulnerability['id'])
    return result


def version_compare(actual, previous, image=None):
    """Use APK's version ordering, including epochs and package revisions."""
    args = ['apk', 'version', '-t', actual, previous]
    if image:
        args = ['docker', 'run', '--rm', '--entrypoint', 'apk', image, *args[1:]]
    result = run(*args).strip()
    if result not in ('<', '=', '>'):
        raise ValueError('Invalid APK version comparison')
    return result


def fixed_packages(before_sbom, after_sbom, before_scan, after_scan, compare=version_compare):
    """Require both an installed package upgrade and removal of the same CVE."""
    old, new = packages(before_sbom), packages(after_sbom)
    if distro_version(before_sbom) != distro_version(after_sbom):
        raise ValueError('Distribution versions differ; use the upstream-version release path')
    before, after = findings(before_scan), findings(after_scan)
    fixes = []
    for name, cves in sorted(before.items()):
        resolved = cves - after[name]
        if not resolved or name not in old or name not in new or old[name] == new[name]:
            continue
        if compare(new[name], old[name]) != '>':
            continue
        fixes.append({'package': name, 'from': old[name], 'to': new[name], 'cves': sorted(resolved)})
    return fixes


class Scanner:
    """Reuse one immutable database snapshot for all old/new comparisons."""

    def __init__(self, tools):
        self.tools = Path(tools).resolve()
        self.env = {**os.environ, 'GRYPE_DB_CACHE_DIR': str(self.tools / 'db'),
                    'GRYPE_DB_AUTO_UPDATE': 'false', 'GRYPE_CHECK_FOR_APP_UPDATE': 'false',
                    'SYFT_CHECK_FOR_APP_UPDATE': 'false'}

    def scan(self, image, arch):
        with tempfile.TemporaryDirectory() as directory:
            sbom_path = Path(directory) / 'sbom.json'
            config_path = Path(directory) / 'grype.yaml'
            config_path.write_text('ignore: []\n')
            sbom = json.loads(run(str(self.tools / 'syft'), image, '--platform', f'linux/{arch}',
                                  '--scope', 'squashed', '-o', 'syft-json', env=self.env))
            packages(sbom)
            sbom_path.write_text(json.dumps(sbom))
            scan = json.loads(run(str(self.tools / 'grype'), f'sbom:{sbom_path}',
                                  '--config', str(config_path), '--by-cve', '-o', 'json', env=self.env))
            findings(scan)
            return sbom, scan


def matrix(repo, ref):
    """Read every supported variant from the same configuration used by aliases."""
    config = json.loads(run('git', 'show', f'{ref}:.image-revision-aliases.json', cwd=repo))
    workflow = run('git', 'show', f'{ref}:.github/workflows/workflow.yml', cwd=repo)
    if config.get('schema') != 1 or config.get('image') != 'wodby/alpine':
        raise ValueError('Expected the Alpine alias configuration')
    rows = []
    for entry in config['versions']:
        key = entry['version']['env']
        values = re.findall(r'^  ' + re.escape(key) + r": ['\"]?([0-9]+\.[0-9]+\.[0-9]+)['\"]?\s*$", workflow, re.M)
        if len(values) != 1:
            raise ValueError(f'Expected one version for {key}')
        version = values[0]
        parts = version.split('.')
        for variant in entry['variants']:
            tag = variant['short'][0].format(version=version, minor='.'.join(parts[:2]), major=parts[0])
            if not re.fullmatch(r'[0-9]+\.[0-9]+(?:-dev)?', tag):
                raise ValueError(f'Unsupported Alpine variant: {tag}')
            rows.append({'tag': tag, 'version': version})
    if not rows or len({r['tag'] for r in rows}) != len(rows):
        raise ValueError('Empty or duplicate Alpine matrix')
    return rows


class PendingImage(ValueError):
    """A Git release or mutable candidate has not finished publishing yet."""


def manifests(image):
    """Freeze the platform digests before scanning, ignoring attestations."""
    try:
        manifest = json.loads(run('docker', 'buildx', 'imagetools', 'inspect', image, '--format', '{{json .Manifest}}'))
    except ValueError as error:
        if re.search(r'manifest unknown|no such manifest|: not found', str(error), re.I):
            raise PendingImage(f'Waiting for published image {image}') from error
        raise
    result = {}
    for item in manifest.get('manifests', []):
        platform = item.get('platform', {})
        arch = platform.get('architecture')
        if platform.get('os') == 'linux' and arch in ARCHES:
            if arch in result or not DIGEST.fullmatch(item['digest']):
                raise ValueError(f'Ambiguous platform manifest: {image}')
            result[arch] = 'wodby/alpine@' + item['digest']
    if set(result) != set(ARCHES):
        raise PendingImage(f'Waiting for all published architectures: {image}')
    return result


def source_commit(image):
    """Prevent releasing notes from mutable images built from another commit."""
    config = json.loads(run('docker', 'buildx', 'imagetools', 'inspect', image, '--format', '{{json .Image}}'))
    return (config.get('config', {}).get('Labels') or {}).get('org.opencontainers.image.revision')


def release_notes(fixes):
    """Group identical fixes without hiding variant or architecture differences."""
    grouped = defaultdict(list)
    for fix in fixes:
        key = (fix['tag'], fix['package'], fix['from'], fix['to'], tuple(fix['cves']))
        grouped[key].append(fix['arch'])
    lines = ['Alpine package security updates', '']
    for (tag, name, old, new, cves), arches in sorted(grouped.items()):
        lines.append(f'- Alpine {tag} ({", ".join(sorted(arches))}): {name} {old} -> {new}; fixes {", ".join(cves)}')
    return '\n'.join(lines)


def plan(repo, scanner, release):
    """Compare all current candidates against the newest complete primary release."""
    head = run('git', 'rev-parse', 'HEAD', cwd=repo).strip()
    tags = run('git', 'tag', '--list', 'r*', cwd=repo).splitlines()
    tags = [tag for tag in tags if re.fullmatch(r'r(0|[1-9][0-9]*)', tag)]
    if not tags:
        return {'reason': 'Waiting for the first published image revision'}
    baseline = max(tags, key=lambda tag: int(tag[1:]))
    if release != f'r{int(baseline[1:]) + 1}':
        raise ValueError('Release reservation changed')
    rows = matrix(repo, 'HEAD')
    if rows != matrix(repo, baseline):
        return {'reason': 'Waiting for the upstream-version release to be published'}
    targets = []
    for row in rows:
        try:
            old = manifests(f'wodby/alpine:{row["tag"]}-{baseline}')
            new = manifests(f'wodby/alpine:{row["tag"]}')
        except PendingImage as pending:
            return {'reason': str(pending)}
        for arch in ARCHES:
            if source_commit(new[arch]) != head:
                return {'reason': 'Waiting for tested mutable images from the current commit'}
            targets.append({**row, 'arch': arch, 'baseline_image': old[arch], 'candidate_image': new[arch]})
    fixes = []
    for target in targets:
        old_sbom, old_scan = scanner.scan('registry:' + target['baseline_image'], target['arch'])
        new_sbom, new_scan = scanner.scan('registry:' + target['candidate_image'], target['arch'])
        for fix in fixed_packages(old_sbom, new_sbom, old_scan, new_scan):
            fixes.append({**fix, 'tag': target['tag'], 'arch': target['arch']})
    if not fixes:
        return {'reason': 'No package security fixes since the last revision'}
    return {'schema': 1, 'release': release, 'baseline': baseline, 'source_commit': head,
            'targets': targets, 'fixes': fixes, 'notes': release_notes(fixes)}


def verify(receipt, release, tag, arch, sbom, scan, compare=version_compare):
    """Block a release rebuild if any advertised package fix is absent."""
    if receipt.get('release') != release:
        return
    if receipt.get('schema') != 1 or not receipt.get('fixes'):
        raise ValueError('Invalid security release receipt')
    inventory, current = packages(sbom), findings(scan)
    if not any(t['tag'] == tag and t['arch'] == arch for t in receipt['targets']):
        raise ValueError('Release matrix differs from the security comparison')
    for fix in receipt['fixes']:
        if fix['tag'] != tag or fix['arch'] != arch:
            continue
        name = fix['package']
        if name not in inventory or compare(inventory[name], fix['to']) == '<':
            raise ValueError(f'Missing advertised package update: {name}')
        if current[name] & set(fix['cves']):
            raise ValueError(f'Advertised CVE fix is still vulnerable: {name}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('plan', 'verify'))
    parser.add_argument('--repo', default='.')
    parser.add_argument('--tools', required=True)
    parser.add_argument('--release', required=True)
    parser.add_argument('--output')
    parser.add_argument('--image')
    parser.add_argument('--tag')
    parser.add_argument('--arch', choices=ARCHES)
    args = parser.parse_args()
    scanner = Scanner(args.tools)
    if args.mode == 'plan':
        result = plan(args.repo, scanner, args.release)
        Path(args.output).write_text(json.dumps(result, indent=2) + '\n')
        print(result.get('notes', result.get('reason')))
    else:
        path = Path(args.repo) / RECEIPT
        if not path.exists():
            return
        receipt = json.loads(path.read_text())
        if receipt.get('release') != args.release:
            return
        sbom, scan = scanner.scan('docker:' + args.image, args.arch)
        verify(receipt, args.release, args.tag, args.arch, sbom, scan,
               lambda a, b: version_compare(a, b, args.image))
        print('Verified advertised Alpine package security fixes')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError) as error:
        raise SystemExit(str(error))
