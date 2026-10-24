#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/upstream/frp.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
mkdir -p .github/workflows
_git_commit() { printf 'commit\n' >> events; }
_git_push() { [[ "$*" == origin ]]; printf 'push\n' >> events; }
_release_tag() { printf 'release\n' >> events; printf '%s\n' "$1" > release-notes; }
_get_latest_version() {
  [[ "$*" == 'github.com/fatedier/frp 0.69 frp' ]]
  [[ "$fixture_candidate" != error ]] || return 1
  echo "$fixture_candidate"
}
_release_source_has_version() {
  [[ "$2" == "$fixture_candidate" ]]
  printf '%s\n' "$1" >> archives
  [[ "$1" != *"${missing_arch:-no-match}.tar.gz" ]]
}
reset_fixture() {
  printf "env:\n  FRP_VERSION: 0.69.1\n" > .github/workflows/workflow.yml
  echo 'FRP_VERSION ?= 0.69.1' > Makefile
  : > events
  : > archives
  missing_arch=''
}
reset_fixture
fixture_candidate=0.69.2
_update_frp
grep -qx "  FRP_VERSION: '0.69.2'" .github/workflows/workflow.yml
grep -qxF 'FRP_VERSION ?= 0.69.2' Makefile
[[ $(cat release-notes) == 'frp updates: 0.69.1 -> 0.69.2' ]]
[[ $(wc -l < events) -eq 3 && $(wc -l < archives) -eq 2 ]]
grep -q 'linux_amd64.tar.gz' archives
grep -q 'linux_arm64.tar.gz' archives
# Quoted pins from the previous update can be read again without another release.
: > events
_update_frp
[[ ! -s events ]]
for fixture_candidate in 0.69.1 0.69.0; do
  reset_fixture
  _update_frp
  [[ ! -s events && ! -s archives ]]
done
for fixture_candidate in 0.70.0 0.690.1 1.0.0 0.69.2-rc1 error ''; do
  reset_fixture
  if _update_frp; then echo "Accepted invalid FRP candidate: $fixture_candidate" >&2; exit 1; fi
  [[ ! -s events ]]
  grep -qxF 'FRP_VERSION ?= 0.69.1' Makefile
done
for arch in amd64 arm64; do
  reset_fixture
  fixture_candidate=0.69.2
  missing_arch=$arch
  if _update_frp; then echo "Accepted missing $arch archive" >&2; exit 1; fi
  [[ ! -s events ]]
  grep -qxF 'FRP_VERSION ?= 0.69.1' Makefile
done
reset_fixture
echo 'FRP_VERSION ?= 0.69.0' > Makefile
if _update_frp; then echo 'Accepted conflicting build versions' >&2; exit 1; fi
[[ ! -s events ]]
for failure in commit push; do
  (
    reset_fixture
    fixture_candidate=0.69.2
    if [[ "$failure" == commit ]]; then _git_commit() { return 1; }; else _git_push() { return 1; }; fi
    if _update_frp; then echo 'Ignored publication failure' >&2; exit 1; fi
    ! grep -q release events
  )
done
echo 'FRP updater tests passed.'
