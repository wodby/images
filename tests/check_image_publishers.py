#!/usr/bin/env python3
"""Exercise image publishers offline against sibling repository checkouts.

Run with --root pointing to the directory containing the image repositories.
Docker is replaced with a recorder, and Make only renders commands; no image is
built or pushed. This checks tag wiring across the actual scripts and Makefiles.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess

# Representative versions; these are test inputs, not catalog version pins.
VERSIONS = {
    'ADMINER_VER': '6.0.1', 'ALPINE_VER': '3.24.2', 'APACHE_VER': '2.4.66',
    'CACHET_VER': '2.4.1', 'DRUPAL_VER': '11.4.7', 'DRUPAL_CMS_VER': '2.0.2',
    'ELASTICSEARCH_VER': '7.17.1', 'FRP_VERSION': '0.61.1', 'GO_VER': '1.27.1',
    'KIBANA_VER': '7.17.1', 'NODEJS_VER': '18.0.0', 'MARIADB_VER': '11.4.8',
    'MATOMO_VER': '5.0.1', 'MEMCACHED_VER': '1.6.1', 'MYSQL_VER': '8.4.1',
    'NGINX_VER': '1.31.1', 'NODE_VER': '26.0.1', 'OPENCLAW_VER': '2026.9.1',
    'OPENSMTPD_VER': '7.8.0', 'PHP_VER': '8.5.10', 'POSTGRES_VER': '17.6',
    'PROMETHEUS_VER': '3.13.1', 'PYTHON_VER': '3.14.1', 'RABBITMQ_VER': '4.3.1',
    'REDIS_VER': '8.6.1', 'RUBY_VER': '4.0.1', 'SLACKIN_VER': '2.2.1',
    'SOLR_VER': '10.0.1', 'SQUID_VER': '7.1', 'VALKEY_VER': '9.0.1',
    'VINYL_VER': '8.0.1', 'WEBGRIND_VER': '1.9.1', 'WORDPRESS_VER': '7.0.1',
    'XHPROF_VER': '2.3.1', 'ZOO_VER': '3.9.1',
}
WORKDIRS = {'php': '8', 'mariadb': '11', 'drupal': '11', 'vinyl': '8'}
TAG_INPUTS = {
    'apache': '2.4,2,latest', 'cachet': '2.4,2,latest',
    'drupal-cms': '2,latest', 'elasticsearch': '7.17,7,latest',
    'kibana': '7.17,7,latest', 'matomo': '5,latest', 'node': '26,latest',
    'slackin': '2.2,2,latest', 'squid': '7,latest', 'webgrind': '1.9,1,latest',
    'xhprof': '2.3,2,latest',
}


def check_make_aliases(repo: Path) -> int:
    """Verify old and new build inputs resolve to the same parent and image tags."""
    count = 0
    env = {k: v for k, v in os.environ.items() if k not in (
        'IMAGE_REVISION', 'STABILITY_TAG', 'BASE_IMAGE_REVISION', 'BASE_IMAGE_STABILITY_TAG')}
    for makefile in repo.rglob('Makefile'):
        source = makefile.read_text()
        for current, legacy in (('IMAGE_REVISION', 'STABILITY_TAG'),
                                ('BASE_IMAGE_REVISION', 'BASE_IMAGE_STABILITY_TAG')):
            if f'{current} ?= $({legacy})' not in source:
                continue
            def render(*args: str) -> str:
                return subprocess.check_output(['make', '--no-print-directory', '-n', 'build', *args],
                                               cwd=makefile.parent, env=env, text=True)
            new = render(f'{current}=r23')
            variable = 'BASE_IMAGE_TAG' if current.startswith('BASE_') else 'TAG'
            value = subprocess.run(
                ['make', '--no-print-directory', '-s', '-f', 'Makefile', '-f', '-',
                 'revision-test-input', f'{current}=r23'],
                input=f"revision-test-input:\n\t@printf '%s' '$({variable})'\n",
                cwd=makefile.parent, env=env, text=True, capture_output=True, check=True).stdout
            assert value == 'r23' or value.endswith('-r23'), (makefile, current, value)
            assert new == render(f'{legacy}=r23'), (makefile, legacy, 'alias differs')
            assert new == render(f'{current}=r23', f'{legacy}=4.83.3'), (makefile, current, 'precedence differs')
            count += 2
    return count


def check_repo(repo: Path) -> int:
    """Check revision and legacy releases, variants, and non-publishing refs."""
    name = repo.name
    script = repo / '.github/actions/release.sh'
    env = {**os.environ, **VERSIONS, 'DEBUG': '', 'LATEST': '1', 'LATEST_MAJOR': '1',
           'LATEST_PHP': '1', 'LATEST_MAJOR_PHP': '1', 'LATEST_ALIAS': 'latest',
           'TAG_SUFFIX': '', 'TAGS': TAG_INPUTS.get(name, 'latest'),
           'PLATFORM': 'linux/amd64,linux/arm64', 'DOCKER_USERNAME': 'test',
           'DOCKER_PASSWORD': 'test', 'SCANNED_IMAGE': 'sha256:scanned',
           'SCANNED_IMAGE_AMD64': 'sha256:amd64', 'SCANNED_IMAGE_ARM64': 'sha256:arm64',
           'WODBY_USER_ID': '1000', 'WODBY_GROUP_ID': '1000',
           'PHP_DEV': '', 'PHP_DEV_MACOS': '', 'PYTHON_DEV': '', 'RUBY_DEV': '',
           'GO_DEV': '', 'ALPINE_DEV': '', 'IMAGE_REVISION': '', 'STABILITY_TAG': '',
           'BASE_IMAGE_REVISION': '', 'BASE_IMAGE_STABILITY_TAG': ''}
    if name in ('drupal', 'drupal-php', 'wordpress', 'wordpress-php', 'laravel-php'):
        env['PHP_VER'] = '8.5'
    workdir = repo / WORKDIRS.get(name, '.')
    variants = [{}]
    for runtime in ('php', 'python', 'ruby', 'go'):
        if name == runtime:
            variants += [{runtime.upper() + '_DEV': 'dev'},
                         {runtime.upper() + '_DEV': 'dev', 'WODBY_USER_ID': '501'}]
    if name in ('drupal-php', 'wordpress-php', 'laravel-php'):
        variants += [{'PHP_DEV': 'dev'}, {'PHP_DEV_MACOS': 'dev-macos'}]
    if name in ('alpine', 'docker'):
        variants += [{'ALPINE_DEV': '1', **({'TAGS': 'dev'} if name == 'docker' else {})}]
    # A fake docker command records direct publishing and never contacts a daemon.
    wrapper = r'''
make() {
    case " $* " in
      *' image-ref '*) command make "$@" ;;
      *) command make --no-print-directory -n "$@" ;;
    esac
}
docker() {
    if [[ "$1" == login ]]; then
        if [[ " $* " == *' --password-stdin '* ]]; then cat >/dev/null; fi
        return 0
    fi
    printf 'docker'; printf ' %s' "$@"; printf '\n'
}
. "$1"
'''
    count = 0
    for variant in variants:
        for revision in ('r1', 'r23', '4.83.3'):
            result = subprocess.run(['bash', '-c', wrapper, 'publisher-test', str(script)],
                                    cwd=workdir, env={**env, **variant, 'GITHUB_REF': 'refs/tags/' + revision},
                                    capture_output=True, text=True, check=True)
            # Match publish destinations, excluding source architecture references.
            destinations = re.findall(r'(?:\s-t\s+|docker push\s+)(?:docker.io/)?wodby/' + re.escape(name) + r':([^\s\\]+)', result.stdout)
            assert destinations, (name, revision, 'no published references', result.stdout)
            # These publishers historically exposed only floating aliases for
            # legacy Git tags. Preserve that behavior when rerunning old tags.
            if revision == '4.83.3' and name in ('docker', 'mkdocs', 'sshd'):
                assert destinations == ['dev' if variant else 'latest'], (name, destinations)
                count += 1
                continue
            assert any(t == revision or t.endswith('-' + revision) for t in destinations), (name, revision, destinations)
            if revision == '4.83.3' and name in ('cachet', 'drupal-cms', 'elasticsearch',
                                                'kibana', 'matomo', 'slackin', 'squid', 'webgrind', 'xhprof'):
                assert 'latest' in destinations, (name, 'legacy latest alias changed', destinations)
            # Floating aliases may still be updated by older publishers. Every
            # non-floating revision destination must retain the complete revision.
            assert not any('r-r' in t or t.endswith('-' + revision + '-' + revision) for t in destinations), (name, destinations)
            if variant.get('PHP_DEV_MACOS') or variant.get('WODBY_USER_ID') == '501':
                assert any('dev-macos-' + revision in t for t in destinations), (name, variant, destinations)
            elif any(variant.get(k) for k in ('PHP_DEV', 'PYTHON_DEV', 'RUBY_DEV', 'GO_DEV', 'ALPINE_DEV')):
                assert any('dev-' + revision in t for t in destinations), (name, variant, destinations)
            count += 1
    result = subprocess.run(['bash', '-c', wrapper, 'publisher-test', str(script)], cwd=workdir,
                            env={**env, 'GITHUB_REF': 'refs/heads/feature/test'}, capture_output=True, text=True, check=True)
    assert not result.stdout.strip(), (name, 'feature ref publishes', result.stdout)
    aliases = check_make_aliases(repo)
    print(f'{name}: {count} release cases, feature-ref guard, and {aliases} build-input checks passed')
    return count + 1 + aliases


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('repos', nargs='*')
    args = parser.parse_args()
    repos = [args.root / n for n in args.repos] if args.repos else sorted(
        p for p in args.root.iterdir() if (p / '.image-release-format').is_file())
    assert repos, 'No image repository checkouts found'
    cases = sum(check_repo(p.resolve()) for p in repos)
    print(f'{len(repos)} image publishers: {cases} checks passed')


if __name__ == '__main__':
    main()
