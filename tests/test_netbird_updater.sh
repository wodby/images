#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/upstream/netbird.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
mkdir -p .github/workflows
_git_commit() { printf 'commit %s\n' "$2" >> events; }
_git_push() { [[ "$*" == origin ]]; printf 'push\n' >> events; }
_release_tag() { printf 'release\n' >> events; printf '%s\n' "$1" > release-notes; }
_netbird_latest() { [[ "$fixture_latest" != error ]] || return 1; echo "$fixture_latest"; }
_netbird_dashboard_latest() { echo "$fixture_dashboard"; }
# Digests encode the tag and a per-image "build", so a rebuilt tag changes its digest.
_netbird_digest() {
  [[ "$1:$2" != "${missing:-none}" ]] || return 1
  local build=1
  [[ "$1" != "${rebuilt:-none}" ]] || build=2
  printf 'sha256:%s\n' "$(printf '%s:%s:%s' "$1" "$2" "$build" | sha256sum | cut -c1-64)"
}
digest() { _netbird_digest "$@"; }
reset_fixture() {
  missing='' rebuilt=''
  printf "env:\n  NETBIRD0: '0.82.0'\n  NETBIRD_DASHBOARD: 'v2.96.0'\n" > .github/workflows/workflow.yml
  printf 'NETBIRD_VER ?= 0.82.0\nNETBIRD_DASHBOARD_VER ?= v2.96.0\n' > Makefile
  printf 'ARG NETBIRD_VER=0.82.0\nARG NETBIRD_DASHBOARD_VER=v2.96.0\n' > Dockerfile
  cat > base-images.mk <<EOF
BASE_IMAGE_REPOSITORY := debian
BASE_IMAGE_VERSION_SUFFIX :=

BASE_IMAGE_DIGEST_trixie-slim := $(digest debian trixie-slim)

# NetBird's own images.
BUILD_IMAGE_NETBIRD_SERVER := netbirdio/netbird-server:0.82.0@$(digest netbirdio/netbird-server 0.82.0)
BUILD_IMAGE_NETBIRD_RELAY := netbirdio/relay:0.82.0@$(digest netbirdio/relay 0.82.0)
BUILD_IMAGE_NETBIRD_DASHBOARD := netbirdio/dashboard:v2.96.0@$(digest netbirdio/dashboard v2.96.0)

BASE_IMAGE = \$(BASE_IMAGE_REPOSITORY):trixie-slim@\$(BASE_IMAGE_DIGEST_trixie-slim)
EOF
  cp base-images.mk base-images.mk.orig
  : > events
  rm -f release-notes
}
unchanged() {
  [[ ! -s events ]]
  grep -qxF 'NETBIRD_VER ?= 0.82.0' Makefile
  cmp -s base-images.mk base-images.mk.orig
}

# Nothing new: no commit, no release.
reset_fixture
fixture_latest=0.82.0 fixture_dashboard=v2.96.0
_update_netbird
unchanged

# A new NetBird and dashboard release updates every file and releases one revision.
reset_fixture
fixture_latest=0.83.1 fixture_dashboard=v2.97.0
_update_netbird
grep -qx "  NETBIRD0: '0.83.1'" .github/workflows/workflow.yml
grep -qx "  NETBIRD_DASHBOARD: 'v2.97.0'" .github/workflows/workflow.yml
grep -qxF 'NETBIRD_VER ?= 0.83.1' Makefile
grep -qxF 'NETBIRD_DASHBOARD_VER ?= v2.97.0' Makefile
grep -qxF 'ARG NETBIRD_VER=0.83.1' Dockerfile
grep -qxF 'ARG NETBIRD_DASHBOARD_VER=v2.97.0' Dockerfile
grep -qxF "BUILD_IMAGE_NETBIRD_SERVER := netbirdio/netbird-server:0.83.1@$(digest netbirdio/netbird-server 0.83.1)" base-images.mk
grep -qxF "BUILD_IMAGE_NETBIRD_RELAY := netbirdio/relay:0.83.1@$(digest netbirdio/relay 0.83.1)" base-images.mk
grep -qxF "BUILD_IMAGE_NETBIRD_DASHBOARD := netbirdio/dashboard:v2.97.0@$(digest netbirdio/dashboard v2.97.0)" base-images.mk
grep -qxF '# NetBird'"'"'s own images.' base-images.mk
[[ $(cat release-notes) == 'NetBird updates: NetBird 0.82.0 -> 0.83.1, dashboard v2.96.0 -> v2.97.0' ]]
[[ $(grep -c '^commit' events) -eq 1 && $(grep -c '^release' events) -eq 1 ]]
# The updated files are read again without another release.
: > events
_update_netbird
[[ ! -s events ]]

# Only the dashboard moved.
reset_fixture
fixture_latest=0.82.0 fixture_dashboard=v2.96.1
_update_netbird
[[ $(cat release-notes) == 'NetBird updates: dashboard v2.96.0 -> v2.96.1' ]]
grep -qxF 'NETBIRD_VER ?= 0.82.0' Makefile

# A rebuilt tag of the same versions releases a rebuild.
for image in debian netbirdio/netbird-server netbirdio/relay netbirdio/dashboard; do
  reset_fixture
  fixture_latest=0.82.0 fixture_dashboard=v2.96.0 rebuilt=$image
  _update_netbird
  [[ $(cat release-notes) == 'Rebuild on updated Debian and NetBird base images' ]]
  grep -qxF 'NETBIRD_VER ?= 0.82.0' Makefile
  ! cmp -s base-images.mk base-images.mk.orig
done

# Older releases never move a version backwards.
reset_fixture
fixture_latest=0.81.9 fixture_dashboard=v2.95.0
_update_netbird
unchanged

# A release without its relay image, or a failed lookup, changes nothing.
reset_fixture
fixture_latest=0.83.0 fixture_dashboard=v2.96.0 missing=netbirdio/relay:0.83.0
if _update_netbird; then echo 'Accepted a release without a relay image' >&2; exit 1; fi
unchanged
for fixture_latest in 1.0.0 0.83 v0.83.0 0.83.0-rc1 error ''; do
  reset_fixture
  fixture_dashboard=v2.96.0
  if _update_netbird; then echo "Accepted invalid NetBird release: $fixture_latest" >&2; exit 1; fi
  unchanged
done
for fixture_dashboard in v3.0.0 2.97.0 v2.97.0-rc1 ''; do
  reset_fixture
  fixture_latest=0.82.0
  if _update_netbird; then echo "Accepted invalid dashboard release: $fixture_dashboard" >&2; exit 1; fi
  unchanged
done

# Inconsistent pins stop the update.
reset_fixture
fixture_latest=0.83.0 fixture_dashboard=v2.96.0
echo 'NETBIRD_VER ?= 0.81.0' > Makefile
if _update_netbird; then echo 'Accepted inconsistent versions' >&2; exit 1; fi
[[ ! -s events ]]

echo 'NetBird updater tests passed'
