#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/images/odoo.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
mkdir -p .github/workflows
_git_commit() { printf 'commit %s\n' "$2" >> events; }
_git_push() { [[ "$*" == origin ]]; printf 'push\n' >> events; }
_release_tag() { printf 'release\n' >> events; printf '%s\n' "$1" > release-notes; }
# Registry fixtures: the newest build per series, and a digest derived from the tag and a per-test salt.
_odoo_latest_build() {
  local var="latest_${1%%.*}"
  [[ "${!var}" != error ]] || return 1
  echo "${!var}"
}
_odoo_digest() {
  [[ "$1" != "${missing_digest:-none}" ]] || return 1
  echo "sha256:$(printf '%s%s' "$1" "$salt" | sha256sum | cut -c1-64)"
}
reset_fixture() {
  latest_20=20261102 latest_19=20261102 latest_18=20261102
  salt='' missing_digest=''
  cat > .github/workflows/workflow.yml <<'EOF'
env:
  ODOO20: '20.0.20261102'
  ODOO19: '19.0.20261102'
  ODOO18: '18.0.20261102'
EOF
  printf 'ODOO_VER ?= 20.0.20261102\nODOO_VER_MINOR := $(basename $(ODOO_VER))\n' > Makefile
  {
    echo '# Base image inputs.'
    echo 'BASE_IMAGE_REPOSITORY := odoo'
    echo
    echo "BASE_IMAGE_DIGEST_18.0-20261102 := $(_odoo_digest 18.0-20261102)"
    echo "BASE_IMAGE_DIGEST_19.0-20261102 := $(_odoo_digest 19.0-20261102)"
    echo "BASE_IMAGE_DIGEST_20.0-20261102 := $(_odoo_digest 20.0-20261102)"
    echo
    echo 'BASE_IMAGE = $(BASE_IMAGE_REPOSITORY):$(BASE_IMAGE_TAG)'
  } > base-images.mk
  cp base-images.mk base-images.expected
  cp .github/workflows/workflow.yml workflow.expected
  : > events
  rm -f release-notes
}
unchanged() {
  [[ ! -s events ]]
  cmp .github/workflows/workflow.yml workflow.expected
  grep -qxF 'ODOO_VER ?= 20.0.20261102' Makefile
  cmp base-images.mk base-images.expected
}

# Nothing new: no commit and no release.
reset_fixture
_update_odoo "20.0 19.0 18.0"
unchanged

# New builds move the workflow, the Makefile default and the pins of their series only.
reset_fixture
latest_20=20261109 latest_18=20261110
_update_odoo "20.0 19.0 18.0"
grep -qx "  ODOO20: '20.0.20261109'" .github/workflows/workflow.yml
grep -qx "  ODOO19: '19.0.20261102'" .github/workflows/workflow.yml
grep -qx "  ODOO18: '18.0.20261110'" .github/workflows/workflow.yml
grep -qxF 'ODOO_VER ?= 20.0.20261109' Makefile
grep -qxF "BASE_IMAGE_DIGEST_20.0-20261109 := $(_odoo_digest 20.0-20261109)" base-images.mk
grep -qxF "BASE_IMAGE_DIGEST_19.0-20261102 := $(_odoo_digest 19.0-20261102)" base-images.mk
grep -qxF "BASE_IMAGE_DIGEST_18.0-20261110 := $(_odoo_digest 18.0-20261110)" base-images.mk
[[ $(grep -c '^BASE_IMAGE_DIGEST_' base-images.mk) -eq 3 ]]
# Content around the pins stays in place.
[[ $(head -n2 base-images.mk | tail -n1) == 'BASE_IMAGE_REPOSITORY := odoo' ]]
[[ $(tail -n1 base-images.mk) == 'BASE_IMAGE = $(BASE_IMAGE_REPOSITORY):$(BASE_IMAGE_TAG)' ]]
[[ $(cat release-notes) == 'Odoo updates: 20.0.20261102 -> 20.0.20261109, 18.0.20261102 -> 18.0.20261110' ]]
[[ $(cat events) == $'commit Update Odoo to 20.0.20261109, 18.0.20261110\npush\nrelease' ]]
# Running again finds nothing to do.
: > events
_update_odoo "20.0 19.0 18.0"
[[ ! -s events ]]

# A rebuilt tag with the same build is released as a rebuild.
reset_fixture
salt=rebuilt
_update_odoo "20.0 19.0 18.0"
grep -qxF "BASE_IMAGE_DIGEST_20.0-20261102 := $(_odoo_digest 20.0-20261102)" base-images.mk
grep -qxF 'ODOO_VER ?= 20.0.20261102' Makefile
[[ $(cat release-notes) == 'Rebuild on the updated official Odoo base images' ]]
[[ $(cat events) == $'commit Rebuild against updated base image digests\npush\nrelease' ]]

# An older build never moves a series back.
reset_fixture
latest_19=20261015
_update_odoo "20.0 19.0 18.0"
unchanged

# Refusals leave every file as it was.
refuse() {
  if _update_odoo "20.0 19.0 18.0" 2>/dev/null; then echo "Accepted: $1" >&2; exit 1; fi
  unchanged
}
for candidate in error 2026110 latest; do
  reset_fixture
  latest_20=$candidate
  refuse "build $candidate"
done
reset_fixture
latest_20=20261109
missing_digest='20.0-20261109'
refuse 'missing digest'
reset_fixture
sed -i '/ODOO19/d' .github/workflows/workflow.yml
cp .github/workflows/workflow.yml workflow.expected
refuse 'a workflow without a series'
reset_fixture
if _update_odoo "20" 2>/dev/null; then echo 'Accepted an invalid series' >&2; exit 1; fi
unchanged
for failure in commit push; do
  (
    reset_fixture
    latest_20=20261109
    if [[ "$failure" == commit ]]; then _git_commit() { return 1; }; else _git_push() { return 1; }; fi
    if _update_odoo "20.0 19.0 18.0"; then echo 'Ignored publication failure' >&2; exit 1; fi
    [[ ! -e release-notes ]]
  )
done
echo 'Odoo updater tests passed.'
