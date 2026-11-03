#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/images/dotnet.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
mkdir -p .github/workflows
_git_commit() { printf 'commit %s\n' "$2" >> events; }
_git_push() { [[ "$*" == origin ]]; printf 'push\n' >> events; }
_release_tag() { printf 'release\n' >> events; printf '%s\n' "$1" > release-notes; }
# Registry and metadata fixtures: a digest is derived from the tag and a per-test salt.
_dotnet_latest_release() { [[ "$1" == 10.0 ]]; [[ "$metadata" != error ]] || return 1; echo "$metadata"; }
_dotnet_tags() { case "$1" in aspnet) printf '%s\n' $fixture_aspnet ;; sdk) printf '%s\n' $fixture_sdk ;; *) return 1 ;; esac; }
_dotnet_digest() {
  [[ "$2" != "${missing_digest:-none}" ]] || return 1
  echo "sha256:$(printf '%s%s' "$1:$2" "$salt" | sha256sum | cut -c1-64)"
}
digest_of() { _dotnet_digest "$1" "$2"; }
reset_fixture() {
  metadata='10.0.14 10.0.403'
  fixture_aspnet='10.0.13-alpine3.24 10.0.14-alpine3.23 10.0.14-alpine3.24 10.0-alpine 10.0.15-alpine3.24 10.0.15-alpine3.25'
  fixture_sdk='10.0.402-alpine3.24 10.0.403-alpine3.24 10.0.404-alpine3.24'
  salt='' missing_digest=''
  cat > .github/workflows/workflow.yml <<'EOF'
env:
  DOTNET10: '10.0.14'
  DOTNET10_SDK: '10.0.403'
EOF
  printf 'DOTNET_VER ?= 10.0.14\nDOTNET_SDK_VER ?= 10.0.403\n' > Makefile
  {
    echo '# Base image inputs.'
    echo 'BASE_IMAGE_VERSION_SUFFIX := -alpine3.24'
    echo 'RUNTIME_BASE_IMAGE_REPOSITORY := mcr.microsoft.com/dotnet/aspnet'
    echo
    echo "BASE_IMAGE_DIGEST_aspnet_10.0.14-alpine3.24 := $(digest_of aspnet 10.0.14-alpine3.24)"
    echo "BASE_IMAGE_DIGEST_sdk_10.0.403-alpine3.24 := $(digest_of sdk 10.0.403-alpine3.24)"
    echo
    echo 'BASE_IMAGE = $(RUNTIME_IMAGE)'
  } > base-images.mk
  cp base-images.mk base-images.expected
  : > events
  rm -f release-notes
}
unchanged() {
  [[ ! -s events ]]
  grep -qx "  DOTNET10: '10.0.14'" .github/workflows/workflow.yml
  grep -qxF 'DOTNET_SDK_VER ?= 10.0.403' Makefile
  cmp base-images.mk base-images.expected
}

# Nothing new: no commit and no release.
reset_fixture
_update_dotnet 10.0
unchanged

# A patch release moves the workflow, the Makefile defaults and both pins together.
reset_fixture
metadata='10.0.15 10.0.404'
_update_dotnet 10.0
grep -qx "  DOTNET10: '10.0.15'" .github/workflows/workflow.yml
grep -qx "  DOTNET10_SDK: '10.0.404'" .github/workflows/workflow.yml
grep -qxF 'DOTNET_VER ?= 10.0.15' Makefile
grep -qxF 'DOTNET_SDK_VER ?= 10.0.404' Makefile
grep -qxF "BASE_IMAGE_DIGEST_aspnet_10.0.15-alpine3.24 := $(digest_of aspnet 10.0.15-alpine3.24)" base-images.mk
grep -qxF "BASE_IMAGE_DIGEST_sdk_10.0.404-alpine3.24 := $(digest_of sdk 10.0.404-alpine3.24)" base-images.mk
[[ $(grep -c '^BASE_IMAGE_DIGEST_' base-images.mk) -eq 2 ]]
# Content around the pins stays in place.
[[ $(head -n2 base-images.mk | tail -n1) == 'BASE_IMAGE_VERSION_SUFFIX := -alpine3.24' ]]
[[ $(tail -n1 base-images.mk) == 'BASE_IMAGE = $(RUNTIME_IMAGE)' ]]
[[ $(cat release-notes) == '.NET updates: 10.0.14 -> 10.0.15 (SDK 10.0.404)' ]]
[[ $(cat events) == $'commit Update .NET to 10.0.15\npush\nrelease' ]]
# Running again finds nothing to do.
: > events
_update_dotnet 10.0
[[ ! -s events ]]

# A newer Alpine is taken only once both images of the release have it.
reset_fixture
metadata='10.0.15 10.0.404'
fixture_sdk="$fixture_sdk 10.0.404-alpine3.25"
_update_dotnet 10.0
grep -qxF 'BASE_IMAGE_VERSION_SUFFIX := -alpine3.25' base-images.mk
grep -qF 'BASE_IMAGE_DIGEST_sdk_10.0.404-alpine3.25 :=' base-images.mk
[[ $(cat release-notes) == '.NET updates: 10.0.14 -> 10.0.15 (SDK 10.0.404); Microsoft base images moved to Alpine 3.24 -> 3.25' ]]

# A rebuilt tag with the same versions is released as a rebuild.
reset_fixture
salt=rebuilt
_update_dotnet 10.0
grep -qxF "BASE_IMAGE_DIGEST_aspnet_10.0.14-alpine3.24 := $(digest_of aspnet 10.0.14-alpine3.24)" base-images.mk
grep -qxF 'DOTNET_VER ?= 10.0.14' Makefile
[[ $(cat release-notes) == 'Rebuild on the updated Microsoft .NET base images' ]]
[[ $(cat events) == $'commit Rebuild against updated base image digests\npush\nrelease' ]]

# Metadata behind the pinned release never moves the line back.
reset_fixture
metadata='10.0.13 10.0.402'
_update_dotnet 10.0
unchanged

# Refusals leave every file as it was.
refuse() {
  if _update_dotnet 10.0 2>/dev/null; then echo "Accepted: $1" >&2; exit 1; fi
  unchanged
}
for candidate in '11.0.0 11.0.100' '10.0.15-rc.1 10.0.404' '10.0.15 10.0.403' '10.0.15' error; do
  reset_fixture
  metadata=$candidate
  refuse "metadata $candidate"
done
reset_fixture
metadata='10.0.15 10.0.404'
fixture_sdk='10.0.404-alpine3.23'
refuse 'no Alpine with both images'
reset_fixture
metadata='10.0.15 10.0.404'
missing_digest='10.0.404-alpine3.24'
refuse 'missing digest'
reset_fixture
sed -i 's/^BASE_IMAGE_VERSION_SUFFIX := .*/BASE_IMAGE_VERSION_SUFFIX := -alpine3.26/' base-images.mk
cp base-images.mk base-images.expected
refuse 'moving Alpine backwards'
reset_fixture
sed -i '/DOTNET10_SDK/d' .github/workflows/workflow.yml
if _update_dotnet 10.0 2>/dev/null; then echo 'Accepted a workflow without the SDK version' >&2; exit 1; fi
[[ ! -s events ]]
for failure in commit push; do
  (
    reset_fixture
    metadata='10.0.15 10.0.404'
    if [[ "$failure" == commit ]]; then _git_commit() { return 1; }; else _git_push() { return 1; }; fi
    if _update_dotnet 10.0; then echo 'Ignored publication failure' >&2; exit 1; fi
    [[ ! -e release-notes ]]
  )
done
echo '.NET updater tests passed.'
