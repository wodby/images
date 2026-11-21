#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/images/redmine.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
mkdir -p .github/workflows
_git_commit() { printf 'commit %s\n' "$2" >> events; }
_git_push() { [[ "$*" == origin ]]; printf 'push\n' >> events; }
_release_tag() { printf 'release\n' >> events; printf '%s\n' "$1" > release-notes; }
_report_event() { printf '%s %s\n' "$1" "$3" >> reports; }
_current_repo_slug() { echo wodby/redmine; }
# Registry fixtures: the newest release per line, the newest line, and a digest derived from
# the tag and a per-test salt.
_redmine_latest_release() {
  local var="latest_${1//./}"
  [[ "${!var}" != error ]] || return 1
  echo "${!var}"
}
_redmine_newest_line() { echo "${fixture_newest_line}"; }
_redmine_digest() {
  [[ "$1" != "${missing_digest:-none}" ]] || return 1
  echo "sha256:$(printf '%s%s' "$1" "$salt" | sha256sum | cut -c1-64)"
}
reset_fixture() {
  latest_70=7.0.3 latest_61=6.1.6 fixture_newest_line=7.0
  salt='' missing_digest=''
  cat > .github/workflows/workflow.yml <<'YAML'
env:
  REDMINE70: '7.0.3'
  REDMINE61: '6.1.6'
YAML
  printf 'REDMINE_VER ?= 7.0.3\nREDMINE_VER_MINOR := $(basename $(REDMINE_VER))\n' > Makefile
  {
    echo '# Base image inputs.'
    echo 'BASE_IMAGE_REPOSITORY := redmine'
    echo 'BASE_IMAGE_VERSION_SUFFIX := -trixie'
    echo
    echo "BASE_IMAGE_DIGEST_6.1.6-trixie := $(_redmine_digest 6.1.6-trixie)"
    echo "BASE_IMAGE_DIGEST_7.0.3-trixie := $(_redmine_digest 7.0.3-trixie)"
    echo
    echo 'BASE_IMAGE = $(BASE_IMAGE_REPOSITORY):$(BASE_IMAGE_TAG)'
  } > base-images.mk
  cp base-images.mk base-images.expected
  cp .github/workflows/workflow.yml workflow.expected
  : > events
  : > reports
  rm -f release-notes
}
unchanged() {
  [[ ! -s events ]]
  cmp .github/workflows/workflow.yml workflow.expected
  grep -qxF 'REDMINE_VER ?= 7.0.3' Makefile
  cmp base-images.mk base-images.expected
}

# Nothing new: no commit, no release and no report.
reset_fixture
_update_redmine "7.0 6.1"
unchanged
[[ ! -s reports ]]

# New patch releases move the workflow, the Makefile default and the pins of their line only.
reset_fixture
latest_70=7.0.4
_update_redmine "7.0 6.1"
grep -qx "  REDMINE70: '7.0.4'" .github/workflows/workflow.yml
grep -qx "  REDMINE61: '6.1.6'" .github/workflows/workflow.yml
grep -qxF 'REDMINE_VER ?= 7.0.4' Makefile
grep -qxF "BASE_IMAGE_DIGEST_7.0.4-trixie := $(_redmine_digest 7.0.4-trixie)" base-images.mk
grep -qxF "BASE_IMAGE_DIGEST_6.1.6-trixie := $(_redmine_digest 6.1.6-trixie)" base-images.mk
[[ $(grep -c '^BASE_IMAGE_DIGEST_' base-images.mk) -eq 2 ]]
# Content around the pins stays in place.
[[ $(sed -n 3p base-images.mk) == 'BASE_IMAGE_VERSION_SUFFIX := -trixie' ]]
[[ $(tail -n1 base-images.mk) == 'BASE_IMAGE = $(BASE_IMAGE_REPOSITORY):$(BASE_IMAGE_TAG)' ]]
[[ $(cat release-notes) == 'Redmine updates: 7.0.3 -> 7.0.4' ]]
[[ $(cat events) == $'commit Update Redmine to 7.0.4\npush\nrelease' ]]
# Running again finds nothing to do.
: > events
_update_redmine "7.0 6.1"
[[ ! -s events ]]

# The other line moves without touching the Makefile default.
reset_fixture
latest_61=6.1.7
_update_redmine "7.0 6.1"
grep -qx "  REDMINE61: '6.1.7'" .github/workflows/workflow.yml
grep -qxF 'REDMINE_VER ?= 7.0.3' Makefile
[[ $(cat events) == $'commit Update Redmine to 6.1.7\npush\nrelease' ]]

# A rebuilt tag with the same release is released as a rebuild.
reset_fixture
salt=rebuilt
_update_redmine "7.0 6.1"
grep -qxF "BASE_IMAGE_DIGEST_7.0.3-trixie := $(_redmine_digest 7.0.3-trixie)" base-images.mk
grep -qxF 'REDMINE_VER ?= 7.0.3' Makefile
[[ $(cat release-notes) == 'Rebuild on the updated official Redmine base images' ]]
[[ $(cat events) == $'commit Rebuild against updated base image digests\npush\nrelease' ]]

# An older release never moves a line back.
reset_fixture
latest_70=7.0.2
_update_redmine "7.0 6.1"
unchanged

# A new release line is only reported.
reset_fixture
fixture_newest_line=7.1
_update_redmine "7.0 6.1"
unchanged
[[ $(cat reports) == 'manual_review Redmine 7.1 is released; add an image line and a service option for it' ]]
reset_fixture
fixture_newest_line=7.0
_update_redmine "7.0 6.1"
[[ ! -s reports ]]

# Refusals leave every file as it was.
refuse() {
  if _update_redmine "7.0 6.1" 2>/dev/null; then echo "Accepted: $1" >&2; exit 1; fi
  unchanged
}
for candidate in error 7.0 7.1.0 7.0.x latest; do
  reset_fixture
  latest_70=$candidate
  refuse "release $candidate"
done
reset_fixture
latest_70=7.0.4
missing_digest='7.0.4-trixie'
refuse 'missing digest'
reset_fixture
sed -i '/REDMINE61/d' .github/workflows/workflow.yml
cp .github/workflows/workflow.yml workflow.expected
refuse 'a workflow without a line'
reset_fixture
if _update_redmine "7" 2>/dev/null; then echo 'Accepted an invalid line' >&2; exit 1; fi
unchanged
for failure in commit push; do
  (
    reset_fixture
    latest_70=7.0.4
    if [[ "$failure" == commit ]]; then _git_commit() { return 1; }; else _git_push() { return 1; }; fi
    if _update_redmine "7.0 6.1"; then echo 'Ignored publication failure' >&2; exit 1; fi
    [[ ! -e release-notes ]]
  )
done
echo 'Redmine updater tests passed.'
