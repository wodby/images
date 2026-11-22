#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/images/senaite.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
mkdir -p .github/workflows
_git_commit() { printf 'commit %s\n' "$2" >> events; }
_git_push() { [[ "$*" == origin ]]; printf 'push\n' >> events; }
_release_tag() { printf 'release\n' >> events; printf '%s\n' "$1" > release-notes; }
_report_event() { printf '%s %s %s %s\n' "$1" "$3" "${4:-}" "${5:-}" >> reports; }
_current_repo_slug() { echo wodby/senaite; }
old_digest="sha256:$(printf old | sha256sum | cut -c1-64)"
new_digest="sha256:$(printf new | sha256sum | cut -c1-64)"
# Registry fixture: the digest Docker Hub returns for ubuntu:22.04, or "error".
_senaite_base_digest() {
  [[ "$1:$2" == ubuntu:22.04 ]] || return 1
  [[ "${fixture_digest}" != error ]] || return 1
  echo "${fixture_digest}"
}
# PyPI fixture: the JSON API response for senaite.lims, or a failed request.
curl() {
  [[ "${*: -1}" == "${SENAITE_PYPI_URL}" ]] || return 1
  [[ "${pypi}" != error ]] || return 22
  printf '%s' "${pypi}"
}
pypi_releases() {
  local release entries=""
  for release in "$@"; do
    entries+="\"${release%%:*}\": [{\"yanked\": $([[ "${release}" == *:yanked ]] && echo true || echo false)}],"
  done
  pypi="{\"info\": {\"version\": \"2.6.0\"}, \"releases\": {${entries%,}}}"
}
reset_fixture() {
  fixture_digest="${old_digest}"
  pypi_releases 2.5.0 2.6.0
  cat > .github/workflows/workflow.yml <<'YAML'
env:
  # The latest SENAITE release.
  SENAITE26: '2.6.0'
YAML
  printf 'SENAITE_VER ?= 2.6.0\n' > Makefile
  printf 'senaite.lims = 2.6.0\n' > versions.cfg
  {
    echo '# Base image inputs shared by local builds and CI.'
    echo 'BASE_IMAGE_REPOSITORY := ubuntu'
    echo 'BASE_IMAGE_TAG := 22.04'
    echo "BASE_IMAGE_DIGEST := ${old_digest}"
    echo
    echo 'BASE_IMAGE = $(BASE_IMAGE_REPOSITORY):$(BASE_IMAGE_TAG)@$(BASE_IMAGE_DIGEST)'
  } > base-images.mk
  mkdir -p expected
  cp base-images.mk .github/workflows/workflow.yml Makefile versions.cfg expected/
  : > events
  : > reports
  rm -f release-notes
}
unchanged() {
  [[ ! -s events ]]
  [[ ! -e release-notes ]]
  cmp base-images.mk expected/base-images.mk
  cmp .github/workflows/workflow.yml expected/workflow.yml
  cmp Makefile expected/Makefile
  cmp versions.cfg expected/versions.cfg
}

# Nothing new: no commit, no release and no report.
reset_fixture
[[ $(_update_senaite) == *'Ubuntu 22.04 base image is up to date'* ]]
unchanged
[[ ! -s reports ]]

# A new ubuntu:22.04 digest is pinned, committed, pushed and released as a rebuild.
reset_fixture
fixture_digest="${new_digest}"
_update_senaite
grep -qxF "BASE_IMAGE_DIGEST := ${new_digest}" base-images.mk
[[ $(grep -c '^BASE_IMAGE_DIGEST' base-images.mk) -eq 1 ]]
# Only the digest changes.
[[ $(diff expected/base-images.mk base-images.mk | grep -c '^[<>]') -eq 2 ]]
cmp .github/workflows/workflow.yml expected/workflow.yml
cmp Makefile expected/Makefile
[[ $(cat release-notes) == 'Rebuild on the updated Ubuntu 22.04 base image' ]]
[[ $(cat events) == $'commit Rebuild against updated base image digests\npush\nrelease' ]]
[[ ! -s reports ]]
# Running again finds nothing to do.
: > events
rm -f release-notes
_update_senaite >/dev/null
[[ ! -s events ]]

# Refusals leave every file as it was: an invalid or missing digest, a failed registry lookup,
# and a pin file the updater doesn't recognise.
refuse() {
  if _update_senaite >/dev/null 2>&1; then echo "Accepted: $1" >&2; exit 1; fi
  unchanged
}
for candidate in error '' sha256: "sha256:${new_digest#sha256:}0" "${new_digest#sha256:}" \
  "sha256:$(printf '%064d' 0 | tr 0 A)" 'sha256:abc; rm -rf /' latest; do
  reset_fixture
  fixture_digest="${candidate}"
  refuse "digest '${candidate}'"
done
for edit in 's/^BASE_IMAGE_REPOSITORY := ubuntu/BASE_IMAGE_REPOSITORY := debian/' \
  's/^BASE_IMAGE_TAG := 22.04/BASE_IMAGE_TAG := jammy/' \
  '/^BASE_IMAGE_DIGEST := /d' \
  's/^BASE_IMAGE_DIGEST := sha256:/BASE_IMAGE_DIGEST := md5:/'; do
  reset_fixture
  fixture_digest="${new_digest}"
  sed -i "${edit}" base-images.mk
  cp base-images.mk expected/base-images.mk
  refuse "base-images.mk edited with ${edit}"
done
reset_fixture
rm base-images.mk expected/base-images.mk
if _update_senaite >/dev/null 2>&1; then echo 'Accepted a missing base-images.mk' >&2; exit 1; fi
[[ ! -s events ]]

# A newer SENAITE release is reported for review but never applied.
reset_fixture
pypi_releases 2.6.0 2.6.1 2.7.0 2.5.0
_update_senaite >/dev/null
unchanged
[[ $(cat reports) == 'manual_review SENAITE 2.7.0 is released; update versions.cfg and review the hotfix 2.7.0 2.6.0' ]]
# It is reported alongside a base image rebuild too.
reset_fixture
pypi_releases 2.6.0 2.6.1
fixture_digest="${new_digest}"
_update_senaite >/dev/null
grep -qxF "BASE_IMAGE_DIGEST := ${new_digest}" base-images.mk
cmp .github/workflows/workflow.yml expected/workflow.yml
cmp versions.cfg expected/versions.cfg
[[ $(cat reports) == 'manual_review SENAITE 2.6.1 is released; update versions.cfg and review the hotfix 2.6.1 2.6.0' ]]
[[ $(cat events) == $'commit Rebuild against updated base image digests\npush\nrelease' ]]

# Pre-releases, yanked and older releases are not reported.
reset_fixture
pypi_releases 2.5.0 2.6.0 2.7.0rc1 2.7.0b2 2.7.0.dev1 2.6.1:yanked 3.0a1
_update_senaite >/dev/null
unchanged
[[ ! -s reports ]]

# A failed or unreadable PyPI lookup warns without blocking the base image update.
for candidate in error 'not json' '{"releases": {}}' '{"releases": {"2.7.0rc1": [{}]}}'; do
  reset_fixture
  pypi="${candidate}"
  fixture_digest="${new_digest}"
  _update_senaite >/dev/null 2>stderr
  grep -q 'Warning: failed to look up the latest SENAITE release on PyPI' stderr
  grep -qxF "BASE_IMAGE_DIGEST := ${new_digest}" base-images.mk
  [[ $(cat events) == $'commit Rebuild against updated base image digests\npush\nrelease' ]]
  [[ ! -s reports ]]
done
# So does a workflow without the SENAITE version.
reset_fixture
sed -i '/SENAITE26/d' .github/workflows/workflow.yml
fixture_digest="${new_digest}"
_update_senaite >/dev/null 2>stderr
grep -q 'Warning: expected SENAITE26 in the build workflow' stderr
[[ $(cat events) == $'commit Rebuild against updated base image digests\npush\nrelease' ]]
# And a failed PyPI lookup with no digest change still ends up to date.
reset_fixture
pypi=error
[[ $(_update_senaite 2>/dev/null) == *'Ubuntu 22.04 base image is up to date'* ]]
unchanged

# Commit and push failures stop before a release.
for failure in commit push; do
  (
    reset_fixture
    fixture_digest="${new_digest}"
    if [[ "$failure" == commit ]]; then _git_commit() { return 1; }; else _git_push() { return 1; }; fi
    if _update_senaite >/dev/null; then echo "Ignored a ${failure} failure" >&2; exit 1; fi
    [[ ! -e release-notes ]]
  )
done
echo 'SENAITE updater tests passed.'
