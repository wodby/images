#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/edge-alpine-updater-test.XXXXXX")"

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

assert_eq "true" "$(_version_is_newer 3.2.4 3.2.3 && echo true)"
if _version_is_newer 3.2.3 3.2.3; then
  fail "equal versions were treated as newer"
fi
if _version_is_newer 3.2.2 3.2.3; then
  fail "older version was treated as newer"
fi

dockerfile="${test_root}/Dockerfile"
printf '%s\n' \
  'ARG GO_IMAGE=golang:1.26.4-alpine3.23@sha256:old-go' \
  'ARG NGINX_IMAGE=wodby/nginx:1.31-5.48.4@sha256:old-nginx' \
  'FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS lego-build' \
  'ARG LEGO_VERSION=v4.35.2' \
  'FROM ${NGINX_IMAGE}' \
  'ARG S6_OVERLAY_VERSION=3.2.3.2' >"${dockerfile}"

_get_image_tags() {
  case "${1}" in
    wodby/nginx) echo '5.48.5' ;;
    golang) echo '1.26.5-alpine3.23' ;;
    *) return 1 ;;
  esac
}

_get_image_digest() {
  case "${1}:${2}" in
    wodby/nginx:1.31-5.48.5) echo 'sha256:new-nginx' ;;
    golang:1.26.5-alpine3.23) echo 'sha256:new-go' ;;
    *) return 1 ;;
  esac
}

_get_latest_version() {
  case "${1}" in
    github.com/just-containers/s6-overlay) echo '3.2.4.0' ;;
    github.com/go-acme/lego) echo '4.35.2' ;;
    *) return 1 ;;
  esac
}

export IMAGES_UPDATE_REPORT_FILE="${test_root}/events.jsonl"
export IMAGES_UPDATE_DIR="stability-tags"
export IMAGES_UPDATE_SCRIPT="edge-alpine"

_prepare_edge_alpine_update "${dockerfile}" || fail "expected image pin updates"
assert_file_line 'ARG GO_IMAGE=golang:1.26.5-alpine3.23@sha256:new-go' "${dockerfile}"
assert_file_line 'ARG NGINX_IMAGE=wodby/nginx:1.31-5.48.5@sha256:new-nginx' "${dockerfile}"
jq -e '
  select(
    .type == "manual_review"
    and .repo == "wodby/edge-alpine"
    and .message == "s6-overlay update available: 3.2.3.2 -> 3.2.4.0"
  )
' "${test_root}/events.jsonl" >/dev/null || fail "missing s6 manual-review event"

if _prepare_edge_alpine_update "${dockerfile}"; then
  fail "current image pins were reported as changed"
else
  assert_eq "1" "$?"
fi

_get_image_tags() {
  case "${1}" in
    wodby/nginx) echo '5.48.4' ;;
    golang) echo '1.26.4-alpine3.23' ;;
    *) return 1 ;;
  esac
}

_get_image_digest() {
  echo 'sha256:older'
}

if _prepare_edge_alpine_update "${dockerfile}"; then
  fail "older image pins were accepted"
else
  assert_eq "2" "$?"
fi
assert_file_line 'ARG GO_IMAGE=golang:1.26.5-alpine3.23@sha256:new-go' "${dockerfile}"
assert_file_line 'ARG NGINX_IMAGE=wodby/nginx:1.31-5.48.5@sha256:new-nginx' "${dockerfile}"

invalid_dockerfile="${test_root}/Dockerfile.invalid"
printf '%s\n' \
  'ARG GO_IMAGE=golang:1.26.4-alpine3.23@sha256:old-go' \
  'ARG LEGO_VERSION=v4.35.2' \
  'ARG S6_OVERLAY_VERSION=3.2.3.2' >"${invalid_dockerfile}"
if _prepare_edge_alpine_update "${invalid_dockerfile}"; then
  fail "invalid Dockerfile unexpectedly succeeded"
else
  assert_eq "2" "$?"
fi

_github_api() {
  printf '%s\n' '{"workflow_runs":[{"head_sha":"abc123","head_branch":"master","name":"Build docker image","status":"completed","conclusion":"success","created_at":"2026-08-08T00:00:00Z","html_url":"https://example.test/success"}]}'
}
EDGE_ALPINE_WORKFLOW_TIMEOUT=1 EDGE_ALPINE_WORKFLOW_POLL_INTERVAL=0 \
  _wait_for_github_workflow 'wodby/edge-alpine' 'abc123' 'master' 'Build docker image'

_github_api() {
  printf '%s\n' '{"workflow_runs":[{"head_sha":"abc123","head_branch":"master","name":"Build docker image","status":"completed","conclusion":"failure","created_at":"2026-08-08T00:00:00Z","html_url":"https://example.test/failure"}]}'
}
if EDGE_ALPINE_WORKFLOW_TIMEOUT=1 EDGE_ALPINE_WORKFLOW_POLL_INTERVAL=0 \
  _wait_for_github_workflow 'wodby/edge-alpine' 'abc123' 'master' 'Build docker image'; then
  fail "failed target workflow was accepted"
fi

trace="${test_root}/trace"
orchestration_dir="${test_root}/orchestration"
mkdir -p "${orchestration_dir}"

_git_clone() {
  echo clone >>"${trace}"
  cd "${orchestration_dir}"
}
_prepare_edge_alpine_update() {
  echo prepare >>"${trace}"
}
_git_commit() {
  echo commit >>"${trace}"
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
_wait_for_github_workflow() {
  echo wait >>"${trace}"
}
_release_tag() {
  echo release >>"${trace}"
}

update_edge_alpine
assert_eq $'clone\nprepare\ncommit\npush\nrev-parse\nwait\nrelease' "$(cat "${trace}")"

: >"${trace}"
_wait_for_github_workflow() {
  echo wait >>"${trace}"
  return 1
}
if update_edge_alpine; then
  fail "release proceeded after target workflow failure"
fi
if grep -Fqx release "${trace}"; then
  fail "release tag was created after target workflow failure"
fi

echo "edge-alpine updater tests passed"
