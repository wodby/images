#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/images/discourse.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
mkdir -p .github/workflows
_git_commit() { printf 'commit %s\n' "$2" >> events; }
_git_push() { [[ "$*" == origin ]]; printf 'push\n' >> events; }
_release_tag() { printf 'release\n' >> events; printf '%s\n' "$1" > release-notes; }
_current_repo_slug() { echo wodby/discourse; }
_report_event() { printf 'report %s %s\n' "$1" "$3" >> reports; }
# Upstream fixtures: the newest patch per line, the newest base tag per suffix, the newest line, and
# a digest derived from the tag and a per-test salt.
_discourse_latest_patch() {
  local var="patch_${1//./_}"
  [[ "${!var}" != error ]] || return 1
  echo "${!var}"
}
_discourse_latest_base() {
  local var="base_${1//-/_}"
  [[ "${!var}" != error ]] || return 1
  echo "${!var}"
}
_discourse_newest_line() { echo "${newest_line_fixture}"; }
_discourse_digest() {
  [[ "$1" != "${missing_digest:-none}" ]] || return 1
  echo "sha256:$(printf '%s%s' "$1" "$salt" | sha256sum | cut -c1-64)"
}
main_tag=2.0.20261028-0019-web-only
stable_tag=2.0.20261028-0019-web-only-stable
reset_fixture() {
  patch_2026_10=2026.10.0 patch_2026_7=2026.7.4
  base_web_only=$main_tag base_web_only_stable=$stable_tag
  newest_line_fixture=2026.10 salt='' missing_digest=''
  cat > .github/workflows/workflow.yml <<'EOF'
env:
  # The monthly release and the extended support release (ESR).
  DISCOURSE_RELEASE: '2026.10.0'
  DISCOURSE_ESR: '2026.7.4'
EOF
  cat > Makefile <<EOF
DISCOURSE_VER ?= 2026.10.0
DISCOURSE_VER_MINOR := \$(basename \$(DISCOURSE_VER))

DISCOURSE_BASE_TAG_2026.10 := $main_tag
DISCOURSE_BASE_TAG_2026.7 := $stable_tag
EOF
  {
    echo '# Base image inputs.'
    echo 'BASE_IMAGE_REPOSITORY := discourse/base'
    echo
    echo "BASE_IMAGE_DIGEST_$main_tag := $(_discourse_digest $main_tag)"
    echo "BASE_IMAGE_DIGEST_$stable_tag := $(_discourse_digest $stable_tag)"
    echo
    echo 'BASE_IMAGE = $(BASE_IMAGE_REPOSITORY):$(BASE_IMAGE_TAG)'
  } > base-images.mk
  cp base-images.mk base-images.expected
  cp .github/workflows/workflow.yml workflow.expected
  cp Makefile Makefile.expected
  : > events
  : > reports
  rm -f release-notes
}
unchanged() {
  [[ ! -s events ]]
  cmp .github/workflows/workflow.yml workflow.expected
  cmp Makefile Makefile.expected
  cmp base-images.mk base-images.expected
}
run() { _update_discourse "DISCOURSE_RELEASE DISCOURSE_ESR"; }

# Nothing new: no commit, no release and no report.
reset_fixture
run
unchanged
[[ ! -s reports ]]

# Patch releases move the workflow and the Makefile default of their line only.
reset_fixture
patch_2026_10=2026.10.2 patch_2026_7=2026.7.5
run
grep -qx "  DISCOURSE_RELEASE: '2026.10.2'" .github/workflows/workflow.yml
grep -qx "  DISCOURSE_ESR: '2026.7.5'" .github/workflows/workflow.yml
grep -qxF 'DISCOURSE_VER ?= 2026.10.2' Makefile
cmp base-images.mk base-images.expected
[[ $(cat release-notes) == 'Discourse updates: 2026.10.0 -> 2026.10.2, 2026.7.4 -> 2026.7.5' ]]
[[ $(cat events) == $'commit Update Discourse to 2026.10.2, 2026.7.5\npush\nrelease' ]]
# Running again finds nothing to do.
: > events
run
[[ ! -s events ]]

# A newer base image moves only its line's base tag and pin; content around the pins stays.
reset_fixture
base_web_only_stable=2.0.20261104-0911-web-only-stable
run
grep -qxF "DISCOURSE_BASE_TAG_2026.7 := 2.0.20261104-0911-web-only-stable" Makefile
grep -qxF "DISCOURSE_BASE_TAG_2026.10 := $main_tag" Makefile
grep -qxF "BASE_IMAGE_DIGEST_2.0.20261104-0911-web-only-stable := $(_discourse_digest 2.0.20261104-0911-web-only-stable)" base-images.mk
grep -qxF "BASE_IMAGE_DIGEST_$main_tag := $(_discourse_digest $main_tag)" base-images.mk
[[ $(grep -c '^BASE_IMAGE_DIGEST_' base-images.mk) -eq 2 ]]
[[ $(head -n2 base-images.mk | tail -n1) == 'BASE_IMAGE_REPOSITORY := discourse/base' ]]
[[ $(tail -n1 base-images.mk) == 'BASE_IMAGE = $(BASE_IMAGE_REPOSITORY):$(BASE_IMAGE_TAG)' ]]
cmp .github/workflows/workflow.yml workflow.expected
[[ $(cat release-notes) == $'Rebuild on newer Discourse base images\n\ndiscourse/base 2.0.20261028-0019-web-only-stable -> 2.0.20261104-0911-web-only-stable' ]]
[[ $(cat events) == $'commit Update the Discourse base images\npush\nrelease' ]]

# A rebuilt base tag is released as a rebuild.
reset_fixture
salt=rebuilt
run
grep -qxF "BASE_IMAGE_DIGEST_$main_tag := $(_discourse_digest $main_tag)" base-images.mk
cmp Makefile Makefile.expected
[[ $(cat release-notes) == 'Rebuild on the updated Discourse base images' ]]
[[ $(cat events) == $'commit Rebuild against updated base image digests\npush\nrelease' ]]

# Older releases and base images never move a line back.
reset_fixture
patch_2026_7=2026.7.3 base_web_only=2.0.20261001-0001-web-only
run
unchanged

# A newer monthly line is reported, not applied.
reset_fixture
newest_line_fixture=2026.11
run
unchanged
[[ $(cat reports) == 'report manual_review Discourse 2026.11 is released; add an image line, base tag and service option for it' ]]

# Refusals leave every file as it was.
refuse() {
  if run 2>/dev/null; then echo "Accepted: $1" >&2; exit 1; fi
  unchanged
}
for candidate in error 2026.11.0 2026.10.0-latest latest; do
  reset_fixture
  patch_2026_10=$candidate
  refuse "release $candidate"
done
for candidate in error 2.0.20261104-web-only 2.0.20261104-0911-web-only; do
  reset_fixture
  base_web_only_stable=$candidate
  refuse "base $candidate"
done
reset_fixture
base_web_only=2.0.20261104-0911-web-only
missing_digest=2.0.20261104-0911-web-only
refuse 'missing digest'
reset_fixture
sed -i '/DISCOURSE_ESR/d' .github/workflows/workflow.yml
cp .github/workflows/workflow.yml workflow.expected
refuse 'a workflow without a line'
reset_fixture
sed -i '/DISCOURSE_BASE_TAG_2026.7/d' Makefile
cp Makefile Makefile.expected
refuse 'a line without a base tag'
for failure in commit push; do
  (
    reset_fixture
    patch_2026_10=2026.10.2
    if [[ "$failure" == commit ]]; then _git_commit() { return 1; }; else _git_push() { return 1; }; fi
    if run; then echo 'Ignored publication failure' >&2; exit 1; fi
    [[ ! -e release-notes ]]
  )
done
echo 'Discourse updater tests passed.'
