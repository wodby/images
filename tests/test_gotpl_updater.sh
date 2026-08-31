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
    rev-parse)
      echo rev-parse >>"${trace}"
      echo abc123
      ;;
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

alpine_dir="${test_root}/alpine"
mkdir -p "${alpine_dir}"
printf '%s\n' 'ARG GOTPL_VERSION=0.6.7' >"${alpine_dir}/Dockerfile"
cd "${alpine_dir}"
: >"${trace}"

_get_latest_complete_gotpl_release() {
  echo 0.6.8
}
_wait_for_github_workflow() {
  echo "wait:${1}:${3}:${4}" >>"${trace}"
}

update_alpine_gotpl
assert_file_line 'ARG GOTPL_VERSION=0.6.8' "${alpine_dir}/Dockerfile"
assert_eq $'commit:Update gotpl to 0.6.8\npush\nrev-parse\nwait:wodby/alpine:master:Build docker image\nrelease:gotpl updated from 0.6.7 to 0.6.8' "$(cat "${trace}")"

: >"${trace}"
update_alpine_gotpl
assert_eq "" "$(cat "${trace}")"

_get_latest_complete_gotpl_release() {
  echo 0.6.7
}
if update_alpine_gotpl; then
  fail "gotpl downgrade unexpectedly succeeded"
else
  assert_eq "2" "$?"
fi
assert_file_line 'ARG GOTPL_VERSION=0.6.8' "${alpine_dir}/Dockerfile"

echo "gotpl updater tests passed"
