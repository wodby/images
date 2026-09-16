#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/alpine/squid.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
mkdir -p .github/workflows
# Mock publication; tests never access or mutate a remote repository.
_git_commit() { printf 'commit\n' >> events; }
_git_push() { [[ "$*" == 'origin' ]]; printf 'push\n' >> events; }
_release_tag() { printf 'release\n' >> events; }
reset_fixture() {
  echo '7.6-r0' > .squid-package
  echo "  SQUID7: '7.6'" > .github/workflows/workflow.yml
  echo 'SQUID_VER ?= 7.6' > Makefile
  echo 'Tags: `7.6`, `7`, `latest`' > README.md
  : > events
}
# Check real parser behavior against a compressed package index fixture.
curl() { cat "$work/index.tar.gz"; }
printf 'P:other\nV:9.0-r0\n\nP:squid\nV:7.7-r1\n\n' > APKINDEX
tar -czf index.tar.gz APKINDEX
[[ $(_squid_package_version) == 7.7-r1 ]]
printf 'P:squid\nV:8.0-r0\n' > APKINDEX
tar -czf index.tar.gz APKINDEX
if _squid_package_version >/dev/null 2>&1; then echo 'Accepted Squid 8' >&2; exit 1; fi
_squid_package_version() { echo "$fixture_candidate"; }
reset_fixture
fixture_candidate=7.6-r0; _update_squid_package; [[ ! -s events ]]
fixture_candidate=7.5-r9; _update_squid_package; [[ ! -s events ]]
fixture_candidate=7.6-r1; _update_squid_package
[[ $(cat .squid-package) == 7.6-r1 && $(wc -l < events) -eq 3 ]]
reset_fixture
fixture_candidate=7.7-r0; _update_squid_package
[[ $(cat .squid-package) == 7.7-r0 && $(wc -l < events) -eq 3 ]]
grep -q "SQUID7: '7.7'" .github/workflows/workflow.yml
grep -q 'SQUID_VER ?= 7.7' Makefile
grep -q '`7.7`' README.md
_squid_package_version() { return 1; }
if _update_squid_package; then echo 'Ignored lookup failure' >&2; exit 1; fi
echo 'Squid updater tests passed.'
