#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/gotpl-updater-test.XXXXXX")"

cleanup() {
  rm -rf "${test_root}"
}
trap cleanup EXIT

. "${repo_root}/update.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="${1}"
  local actual="${2}"

  [[ "${actual}" == "${expected}" ]] || fail "expected '${expected}', got '${actual}'"
}

assert_file_line() {
  local expected="${1}"
  local file="${2}"

  grep -Fqx "${expected}" "${file}" || fail "missing '${expected}' in ${file}"
}

go_metadata='[
  {"version":"go1.27.1","stable":true},
  {"version":"go1.26.6","stable":true},
  {"version":"go1.28rc1","stable":false}
]'

assert_eq "1.26.6" "$(_get_latest_go_patch_version 1.26.5 "${go_metadata}")"
assert_eq "" "$(_get_latest_go_patch_version 1.25.9 "${go_metadata}")"

_github_api() {
  printf '%s\n' '[
    {"tag_name":"0.6.9","draft":false,"prerelease":false,"assets":[{"name":"gotpl-linux-amd64.tar.gz"}]},
    {"tag_name":"0.6.8","draft":false,"prerelease":false,"assets":[{"name":"gotpl-linux-amd64.tar.gz"},{"name":"gotpl-linux-arm64.tar.gz"}]}
  ]'
}
assert_eq "0.6.8" "$(_get_latest_complete_gotpl_release)"

gotpl_dir="${test_root}/gotpl"
mkdir -p "${gotpl_dir}/.github/workflows"
printf '%s\n' 'go-version: 1.26.5' >"${gotpl_dir}/.github/workflows/workflow.yml"

trace="${test_root}/trace"
_git_clone() {
  cd "${gotpl_dir}"
}
_get_go_downloads_metadata() {
  printf '%s\n' "${go_metadata}"
}
_git_commit() {
  echo "commit:${2}" >>"${trace}"
}
git() {
  case "${1}" in
    push) echo push >>"${trace}" ;;
    *) fail "unexpected git command: $*" ;;
  esac
}

export IMAGES_UPDATE_PUSH=0
: >"${trace}"
_git_push origin
assert_eq "" "$(cat "${trace}")"
if _publishing_enabled; then
  fail "publishing unexpectedly enabled for a validation run"
fi
export IMAGES_UPDATE_PUSH=1

_release_tag() {
  echo "release:${1}" >>"${trace}"
}

update_gotpl_go
assert_file_line 'go-version: 1.26.6' "${gotpl_dir}/.github/workflows/workflow.yml"
assert_eq $'commit:Update Go to 1.26.6\npush\nrelease:Go updated from 1.26.5 to 1.26.6' "$(cat "${trace}")"

printf '%s\n' 'go-version: 1.25.9' >"${gotpl_dir}/.github/workflows/workflow.yml"
: >"${trace}"
export IMAGES_UPDATE_REPORT_FILE="${test_root}/events.jsonl"
export IMAGES_UPDATE_DIR="repos"
export IMAGES_UPDATE_SCRIPT="gotpl"
update_gotpl_go
assert_file_line 'go-version: 1.25.9' "${gotpl_dir}/.github/workflows/workflow.yml"
assert_eq "" "$(cat "${trace}")"
jq -e '
  select(
    .type == "eol_warning"
    and .repo == "wodby/gotpl"
    and .version == "1.25.9"
    and (.message | contains("gotpl uses EOL Go 1.25"))
  )
' "${test_root}/events.jsonl" >/dev/null || fail "missing gotpl Go EOL report event"

# Images that use gotpl pin it themselves. Exercise the pins, release notes and
# the delayed release against a real repository; only publication is local.
(
  . "${repo_root}/update.sh"
  unset -f git
  export IMAGES_UPDATE_PUSH=1
  pushes="${test_root}/pushes"
  _git_push() { printf '%s\n' "$*" >>"${pushes}"; }

  new_image_repo() {
    git init -q -b master "${1}"
    cd "${1}"
    git config user.email test@wodby.invalid
    git config user.name 'Wodby Tests'
    git config commit.gpgsign false
    git config tag.gpgsign false
    printf 'revision\n' >.image-release-format
  }

  # Installing gotpl is not announced as an update of a release that inherited it.
  new_image_repo "${test_root}/installed"
  printf '%s\n' 'FROM scratch' >Dockerfile
  git add -A
  git commit -qm initial
  git tag -am 'First release' r0
  printf '%s\n' 'FROM scratch' 'ARG GOTPL_VERSION=0.6.8' >Dockerfile
  git commit -qam 'Install gotpl'
  assert_eq "" "$(_pending_gotpl_note)"
  _release_due_gotpl_update
  assert_eq r0 "$(_current_release_tag)"

  new_image_repo "${test_root}/image"
  mkdir 10 11 tests
  printf '%s\n' 'FROM scratch' 'ARG GOTPL_VERSION=0.6.7' >10/Dockerfile
  cp 10/Dockerfile 11/Dockerfile
  printf '%s\n' 'FROM scratch' 'ARG GOTPL_COMMIT=0123456789abcdef' >tests/Dockerfile
  git add -A
  git commit -qm initial
  git tag -am 'First release' r0

  assert_eq $'10/Dockerfile\n11/Dockerfile' "$(_gotpl_dockerfiles)"
  assert_eq "" "$(_pending_gotpl_note)"

  # Every pin moves together in one commit, without a release.
  _get_latest_complete_gotpl_release() { echo 0.6.8; }
  _update_image_gotpl
  assert_file_line 'ARG GOTPL_VERSION=0.6.8' 10/Dockerfile
  assert_file_line 'ARG GOTPL_VERSION=0.6.8' 11/Dockerfile
  assert_eq 'Update gotpl to 0.6.8' "$(git log -1 --format=%s)"
  assert_eq r0 "$(_current_release_tag)"
  assert_eq 'gotpl updated from 0.6.7 to 0.6.8' "$(_pending_gotpl_note)"

  head=$(git rev-parse HEAD)
  _update_image_gotpl
  assert_eq "${head}" "$(git rev-parse HEAD)"

  # A downgrade is refused before any pin changes.
  _get_latest_complete_gotpl_release() { echo 0.6.7; }
  if _update_image_gotpl; then
    fail "gotpl downgrade unexpectedly succeeded"
  fi
  assert_file_line 'ARG GOTPL_VERSION=0.6.8' 10/Dockerfile
  git diff --quiet HEAD || fail "refused gotpl downgrade changed the checkout"

  # A recent update waits for another image release.
  : >"${pushes}"
  _release_due_gotpl_update
  assert_eq r0 "$(_current_release_tag)"
  assert_eq "" "$(cat "${pushes}")"

  # The next image release names the gotpl update it ships, once.
  _release_tag 'Base image wodby/alpine: 3.23-r1 -> 3.23-r2' ''
  assert_eq $'Base image wodby/alpine: 3.23-r1 -> 3.23-r2\n\ngotpl updated from 0.6.7 to 0.6.8' \
    "$(git for-each-ref --format='%(contents)' refs/tags/r1)"
  assert_eq 'origin r1' "$(cat "${pushes}")"
  assert_eq "" "$(_pending_gotpl_note)"
  _release_due_gotpl_update
  assert_eq r1 "$(_current_release_tag)"

  # An update that waited longer than the delay is released on its own.
  _get_latest_complete_gotpl_release() { echo 0.6.9; }
  GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' _update_image_gotpl
  git commit -q --allow-empty -m 'Rebuild against updated base image digests'
  _release_due_gotpl_update
  assert_eq r2 "$(_current_release_tag)"
  assert_eq 'gotpl updated from 0.6.8 to 0.6.9' "$(git for-each-ref --format='%(contents)' refs/tags/r2)"

  # Releases of images without a gotpl pin are unchanged.
  new_image_repo "${test_root}/no-gotpl"
  printf '%s\n' 'FROM scratch' >Dockerfile
  git add -A
  git commit -qm initial
  git tag -am 'First release' r0
  _get_latest_complete_gotpl_release() { fail "unexpected gotpl release lookup"; }
  _update_image_gotpl
  git commit -q --allow-empty -m change
  _release_tag 'Base image wodby/alpine: 3.24-r1 -> 3.24-r2' ''
  assert_eq 'Base image wodby/alpine: 3.24-r1 -> 3.24-r2' "$(git for-each-ref --format='%(contents)' refs/tags/r1)"
)

# A failed gotpl update must not hold back base image updates.
(
  trace="${test_root}/base-trace"
  : >"${trace}"
  _git_clone() { :; }
  _require_base_image_pins() { return 0; }
  _update_image_gotpl() { echo gotpl >>"${trace}"; return 1; }
  _update_digests() { echo digests >>"${trace}"; }
  _update_base_alpine_image() { echo "parent:$*" >>"${trace}"; }
  _release_due_gotpl_update() { echo due >>"${trace}"; }
  if update_base_alpine wodby/app 3.23 true; then
    fail "failed gotpl update was not reported"
  fi
  assert_eq $'gotpl\ndigests\nparent:3.23 wodby/alpine true\ndue' "$(cat "${trace}")"

  _update_image_gotpl() { echo gotpl >>"${trace}"; }
  : >"${trace}"
  update_base_alpine wodby/app 3.23 ''
  assert_eq $'gotpl\ndigests\nparent:3.23 wodby/alpine ' "$(cat "${trace}")"
)

echo "gotpl updater tests passed"
