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
_release_tag() { printf 'release\n' >> events; printf '%s\n' "$1" > release-notes; }
reset_fixture() {
  echo '7.6-r0' > .squid-package
  echo "  SQUID7: '7.6'" > .github/workflows/workflow.yml
  echo 'SQUID_VER ?= 7.6' > Makefile
  echo 'Tags: `7.6`, `7`, `latest`' > README.md
  : > events
}
# Check real parser behavior against a compressed package index fixture.
index_fixture="$work/index.tar.gz"
curl() {
  while [[ "$1" != -o ]]; do shift; done
  cp "$index_fixture" "$2"
}
printf 'P:other\nV:9.0-r0\n\nP:squid\nV:7.7-r1\n\n' > APKINDEX
tar -czf index.tar.gz APKINDEX
[[ $(_squid_package_version) == 7.7-r1 ]]
printf 'P:squid\nV:8.0-r0\n' > APKINDEX
tar -czf index.tar.gz APKINDEX
if _squid_package_version >/dev/null 2>&1; then echo 'Accepted Squid 8' >&2; exit 1; fi
printf 'not an archive' > index.tar.gz
if _squid_package_version >/dev/null 2>&1; then echo 'Accepted a corrupt index' >&2; exit 1; fi
(
  curl() { return 22; }
  if _squid_package_version >/dev/null 2>&1; then echo 'Ignored download failure' >&2; exit 1; fi
)
_squid_package_version() { echo "$fixture_candidate"; }
reset_fixture
fixture_candidate=7.6-r0; _update_squid_package; [[ ! -s events ]]
fixture_candidate=7.5-r9; _update_squid_package; [[ ! -s events ]]
fixture_candidate=7.6-r1; _update_squid_package
[[ $(cat release-notes) == 'Squid package: 7.6-r0 -> 7.6-r1' ]]
[[ $(cat .squid-package) == 7.6-r1 && $(wc -l < events) -eq 3 ]]
reset_fixture
fixture_candidate=7.7-r0; _update_squid_package
[[ $(cat release-notes) == 'Squid package: 7.6-r0 -> 7.7-r0' ]]
[[ $(cat .squid-package) == 7.7-r0 && $(wc -l < events) -eq 3 ]]
grep -q "SQUID7: '7.7'" .github/workflows/workflow.yml
grep -q 'SQUID_VER ?= 7.7' Makefile
grep -q '`7.7`' README.md
_squid_package_version() { return 1; }
if _update_squid_package; then echo 'Ignored lookup failure' >&2; exit 1; fi
# Squid enables nounset for the shared timestamp updater as well.
(
  _find_timestamp_file() { echo timestamps; }
  _get_timestamp() { echo new; }
  git() { echo master; }
  _head_has_unpushed_commits() { return 1; }
  echo '3.24#new' > timestamps
  : > events
  _update_timestamps 3.24 wodby/alpine
  [[ ! -s events ]]
  echo '3.24#old' > timestamps
  _update_timestamps 3.24 wodby/alpine
  [[ $(cat timestamps) == '3.24#new' ]]
  [[ $(cat events) == $'commit\npush' ]]
)
echo 'Squid updater tests passed.'
