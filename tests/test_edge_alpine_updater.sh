#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/edge-alpine-updater-test.XXXXXX")"

cleanup() {
  rm -rf "${test_root}"
}
trap cleanup EXIT

. "${repo_root}/update.sh"
export IMAGES_UPDATE_PUSH=1

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
  'ARG LEGO_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'ARG ETCD_CLIENT_VERSION=v3.6.14' \
  'ARG GOTPL_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'ARG CONFD_COMMIT=cccccccccccccccccccccccccccccccccccccccc' \
  'FROM ${NGINX_IMAGE}' \
  'ARG S6_OVERLAY_VERSION=3.2.3.2' >"${dockerfile}"

_get_image_release() {
  case "${1}" in
    wodby/nginx) echo '5.48.5' ;;
    golang) echo '1.26.5-alpine3.23' ;;
    *) return 1 ;;
  esac
}

_get_image_tags() { _get_image_release "$@"; }

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
    github.com/go-acme/lego) echo '4.35.3' ;;
    github.com/etcd-io/etcd) echo '3.6.15' ;;
    github.com/wodby/gotpl) echo '0.6.9' ;;
    github.com/kelseyhightower/confd) echo '0.16.0' ;;
    *) return 1 ;;
  esac
}
_github_api() {
  case "${1}" in
    repos/go-acme/lego/commits/v4.35.3|repos/wodby/gotpl/commits/0.6.9) echo '{"sha":"dddddddddddddddddddddddddddddddddddddddd"}' ;;
    repos/kelseyhightower/confd/commits/v0.16.0) echo '{"sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}' ;;
    repos/wodby/gotpl/compare/*) echo '{"status":"ahead"}' ;;
    repos/kelseyhightower/confd/compare/*) echo '{"status":"behind"}' ;;
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
    .type == "dependency_update"
    and .repo == "wodby/edge-alpine"
    and .message == "s6-overlay: 3.2.3.2 -> 3.2.4.0"
  )
' "${test_root}/events.jsonl" >/dev/null || fail "missing s6 update event"

assert_file_line 'ARG LEGO_VERSION=v4.35.3' "${dockerfile}"
assert_file_line 'ARG LEGO_COMMIT=dddddddddddddddddddddddddddddddddddddddd' "${dockerfile}"
assert_file_line 'ARG S6_OVERLAY_VERSION=3.2.4.0' "${dockerfile}"
assert_file_line 'ARG ETCD_CLIENT_VERSION=v3.6.15' "${dockerfile}"
assert_file_line 'ARG GOTPL_COMMIT=dddddddddddddddddddddddddddddddddddddddd' "${dockerfile}"
assert_file_line 'ARG CONFD_COMMIT=cccccccccccccccccccccccccccccccccccccccc' "${dockerfile}"

if _prepare_edge_alpine_update "${dockerfile}"; then
  fail "current image pins were reported as changed"
else
  assert_eq "1" "$?"
fi

# Runtime-only releases still trigger an Edge rebuild when image pins are current.
sed -i 's/LEGO_VERSION=v4.35.3/LEGO_VERSION=v4.35.2/' "${dockerfile}"
_prepare_edge_alpine_update "${dockerfile}" || fail 'runtime-only update was skipped'
assert_file_line 'ARG LEGO_VERSION=v4.35.3' "${dockerfile}"
(
  _get_latest_version() { echo 5.0.0; }
  if _edge_runtime_updates "${dockerfile}"; then
    fail 'major migration was accepted'
  else
    assert_eq 2 "$?"
  fi
)
(
  _github_api() {
    case "${1}" in
      */commits/*) echo '{"sha":"ffffffffffffffffffffffffffffffffffffffff"}' ;;
      */compare/*) echo '{"status":"diverged"}' ;;
    esac
  }
  if _edge_runtime_updates "${dockerfile}"; then
    fail 'divergent source was updated'
  else
    assert_eq 1 "$?"
  fi
  assert_file_line 'ARG GOTPL_COMMIT=dddddddddddddddddddddddddddddddddddddddd' "${dockerfile}"
)
jq -e 'select(.type == "manual_review" and (.message | contains("diverges")))' "${IMAGES_UPDATE_REPORT_FILE}" >/dev/null || fail 'missing divergent source report'

# Revision pins resolve through the same digest path and never fall back to SemVer.
(
  revision_dockerfile="${test_root}/Dockerfile.revision"
  cp "${dockerfile}" "${revision_dockerfile}"
  _get_image_release() { assert_eq 'wodby/nginx 1.31-' "$*"; echo r1; }
  _get_image_tags() { echo '1.26.5-alpine3.23'; }
  _get_image_digest() {
    case "$1:$2" in
      wodby/nginx:1.31-r1) echo sha256:revision ;;
      golang:1.26.5-alpine3.23) echo sha256:new-go ;;
      *) fail "unexpected image digest request: $*" ;;
    esac
  }
  _prepare_edge_alpine_update "${revision_dockerfile}"
  assert_file_line 'ARG NGINX_IMAGE=wodby/nginx:1.31-r1@sha256:revision' "${revision_dockerfile}"
  _get_image_release() { echo 99.9.9; }
  _get_image_digest() { echo sha256:legacy; }
  if _prepare_edge_alpine_update "${revision_dockerfile}"; then
    fail 'revision pin fell back to legacy SemVer'
  else
    assert_eq 2 "$?"
  fi
  assert_file_line 'ARG NGINX_IMAGE=wodby/nginx:1.31-r1@sha256:revision' "${revision_dockerfile}"
)

_get_image_release() {
  case "${1}" in
    wodby/nginx) echo '5.48.4' ;;
    golang) echo '1.26.4-alpine3.23' ;;
    *) return 1 ;;
  esac
}

_get_image_tags() { _get_image_release "$@"; }

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
  'ARG LEGO_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'ARG ETCD_CLIENT_VERSION=v3.6.14' \
  'ARG GOTPL_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'ARG CONFD_COMMIT=cccccccccccccccccccccccccccccccccccccccc' \
  'ARG S6_OVERLAY_VERSION=3.2.3.2' >"${invalid_dockerfile}"
if _prepare_edge_alpine_update "${invalid_dockerfile}"; then
  fail "invalid Dockerfile unexpectedly succeeded"
else
  assert_eq "2" "$?"
fi

# Resolve the real patch version from both legacy and revision parent releases.
for release in 5.48.13 r0 r23; do
  _github_api() {
    assert_eq "repos/wodby/nginx/contents/.github/workflows/workflow.yml?ref=${release}" "${1}"
    jq -nc --arg content "$(printf "env:\n  NGINX131: '1.31.6'\n" | base64)" '{content: $content}'
  }
  assert_eq 1.31.6 "$(_edge_nginx_version "wodby/nginx:1.31-${release}@sha256:test")"
done
_github_api() { fail 'invalid parent tag reached GitHub'; }
for tag in 1.31-r00 1.31-r01 1.31-r1-rc1 1.30-r0 1.31; do
  if _edge_nginx_version "wodby/nginx:${tag}"; then
    fail "invalid NGINX tag was accepted: ${tag}"
  fi
done
_github_api() { echo '{"content":""}'; }
for release in 5.48.13 r0; do
  if _edge_nginx_version "wodby/nginx:1.31-${release}"; then
    fail 'missing NGINX version was accepted'
  fi
done

# Release comparisons must include changes accumulated since the previous tag.
notes_dir="${test_root}/notes"
mkdir -p "${notes_dir}"
(
  cd "${notes_dir}"
  printf '%s\n' 'ARG NGINX_IMAGE=wodby/nginx:1.31-5.48.13@sha256:new' 'ARG GO_IMAGE=golang:1.26.8-alpine3.23@sha256:new' > Dockerfile
  runtime_pins() {
    printf '%s\n' 'ARG LEGO_VERSION=v4.35.2' 'ARG S6_OVERLAY_VERSION=3.2.3.2' 'ARG ETCD_CLIENT_VERSION=v3.6.14' 'ARG GOTPL_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' 'ARG CONFD_COMMIT=cccccccccccccccccccccccccccccccccccccccc'
  }
  runtime_pins >> Dockerfile
  sed -i 's/LEGO_VERSION=v4.35.2/LEGO_VERSION=v4.35.3/' Dockerfile
  git() {
    runtime_pins
    assert_eq 'show 3.0.6:Dockerfile' "$*"
    printf '%s\n' 'ARG NGINX_IMAGE=wodby/nginx:1.31-5.48.7@sha256:old' 'ARG GO_IMAGE=golang:1.26.7-alpine3.23@sha256:old'
  }
  _next_release_tag() { echo 3.0.7; }
  _edge_nginx_version() {
    case "${1}" in
      *5.48.7*) echo 1.31.3 ;;
      *) echo 1.31.6 ;;
    esac
  }
  notes=$(_edge_release_notes 3.0.6)
  [[ "${notes}" == *'NGINX: 1.31.3 -> 1.31.6.'* ]] || fail 'missing NGINX upgrade'
  [[ "${notes}" == *'lego (certificate issuance and renewal): 4.35.2 -> 4.35.3.'* ]] || fail 'missing runtime update note'
  [[ "${notes}" == *'Go builder image: 1.26.7-alpine3.23 -> 1.26.8-alpine3.23.'* ]] || fail 'missing builder upgrade'
  [[ "${notes}" != *'sha256:'* ]] || fail 'raw digests leaked into release notes'
  [[ "${notes}" == *'compare/3.0.6...3.0.7'* ]] || fail 'wrong release comparison'
  _edge_nginx_version() { echo 1.31.6; }
  notes=$(_edge_release_notes 3.0.6)
  [[ "${notes}" != *'NGINX remains'* && "${notes}" != *'- NGINX:'* ]] || fail 'unchanged NGINX reported'
  [[ "${notes}" == *'NGINX base image: wodby/nginx:1.31-5.48.7 -> wodby/nginx:1.31-5.48.13.'* ]] || fail 'missing base image upgrade'
  _edge_nginx_version() { return 1; }
  if _edge_release_notes 3.0.6; then
    fail 'release notes accepted an unknown NGINX version'
  fi

  # Reproduce a release whose only change is the Go builder digest.
  cp Dockerfile previous.Dockerfile
  git() { cat previous.Dockerfile; }
  sed -i 's/GO_IMAGE=.*$/GO_IMAGE=golang:1.26.8-alpine3.23@sha256:refreshed/' Dockerfile
  if _edge_update_requires_release; then fail 'Go digest refresh requires a release'; fi
  notes=$(_edge_release_notes 3.0.6)
  [[ "${notes}" == *'Refresh Go builder image 1.26.8-alpine3.23 (image digest changed).'* ]] || fail 'missing builder refresh'
  [[ "${notes}" != *'NGINX'* && "${notes}" != *'lego'* ]] || fail 'unchanged components reported'

  cp previous.Dockerfile Dockerfile
  sed -i 's/NGINX_IMAGE=.*$/NGINX_IMAGE=wodby\/nginx:1.31-5.48.13@sha256:refreshed/' Dockerfile
  _edge_nginx_version() { echo 1.31.6; }
  notes=$(_edge_release_notes 3.0.6)
  [[ "${notes}" == *'Refresh NGINX base image wodby/nginx:1.31-5.48.13 (image digest changed).'* ]] || fail 'missing NGINX digest refresh'
  [[ "${notes}" != *'Go builder'* && "${notes}" != *'- NGINX:'* ]] || fail 'unchanged versions reported'
  if _edge_update_requires_release; then fail 'NGINX digest refresh requires a release'; fi
  sed -i 's/1.26.8/1.26.9/' Dockerfile
  _edge_update_requires_release || fail 'version update did not require a release'
  cp previous.Dockerfile Dockerfile
  sed -i 's/LEGO_VERSION=v4.35.3/LEGO_VERSION=v4.35.4/' Dockerfile
  _edge_update_requires_release || fail 'runtime update did not require a release'
  git() { return 1; }
  if _edge_update_requires_release; then
    fail 'missing previous Dockerfile accepted'
  else
    assert_eq 2 "$?"
  fi

)

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
_edge_update_requires_release() { return 0; }
_latest_release_tag() { echo 3.0.6; }
_edge_release_notes() { echo "NGINX: 1.31.3 -> 1.31.6"; }
_git_commit() {
  assert_eq "NGINX: 1.31.3 -> 1.31.6" "${2}"
  echo commit >>"${trace}"
}
git() {
  case "${1}" in
    push) echo push >>"${trace}" ;;
    *) fail "unexpected git command: $*" ;;
  esac
}
# Any status lookup is an error, even when publishing is enabled.
_github_api() { fail "unexpected GitHub API request: $*"; }
_wait_for_github_workflow() { fail "unexpected build workflow check"; }
export IMAGES_UPDATE_PUSH=1
_release_tag() {
  assert_eq "NGINX: 1.31.3 -> 1.31.6" "${1}"
  echo release >>"${trace}"
}

update_edge_alpine
assert_eq $'clone\nprepare\ncommit\npush\nrelease' "$(cat "${trace}")"

# Digest-only updates commit and push without generating notes or releasing.
(
  : >"${trace}"
  _edge_update_requires_release() { return 1; }
  _latest_release_tag() { fail "digest refresh looked up release tags"; }
  _edge_release_notes() { fail "digest refresh generated release notes"; }
  _git_commit() {
    assert_eq "Refresh pinned image digests" "${2}"
    echo commit >>"${trace}"
  }
  update_edge_alpine
  assert_eq $'clone\nprepare\ncommit\npush' "$(cat "${trace}")"
  : >"${trace}"
  _edge_update_requires_release() { return 2; }
  if update_edge_alpine; then fail 'release classification failure ignored'; fi
  assert_eq $'clone\nprepare' "$(cat "${trace}")"
)

# Update failures must still fail the job and prevent release publication.
: >"${trace}"
git() { echo push >>"${trace}"; return 1; }
if update_edge_alpine; then
  fail "push failure was ignored"
fi
assert_eq $'clone\nprepare\ncommit\npush' "$(cat "${trace}")"

echo "edge-alpine updater tests passed"
