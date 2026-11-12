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

assert_event() {
  local filter="${1}"

  jq -e "select(${filter})" "${IMAGES_UPDATE_REPORT_FILE}" >/dev/null || fail "missing event: ${filter}"
}

assert_eq "true" "$(_version_is_newer 3.2.4 3.2.3 && echo true)"
if _version_is_newer 3.2.3 3.2.3; then
  fail "equal versions were treated as newer"
fi
if _version_is_newer 3.2.2 3.2.3; then
  fail "older version was treated as newer"
fi

export IMAGES_UPDATE_REPORT_FILE="${test_root}/events.jsonl"
export IMAGES_UPDATE_DIR="descendants"
export IMAGES_UPDATE_SCRIPT="edge-alpine"

dockerfile="${test_root}/Dockerfile"
printf '%s\n' \
  'ARG GO_IMAGE=golang:1.26.4-alpine3.23@sha256:old-go' \
  'ARG NGINX_IMAGE=wodby/nginx:1.31-5.48.4@sha256:old-nginx' \
  'FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS lego-build' \
  'ARG LEGO_VERSION=v5.6.0' \
  'ARG LEGO_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'ARG LEGO_GO_MODULES="golang.org/x/net@v0.62.0 google.golang.org/grpc@v1.85.0"' \
  'FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS confd-build' \
  'ARG CONFD_VERSION=v0.17.0' \
  'ARG CONFD_COMMIT=cccccccccccccccccccccccccccccccccccccccc' \
  'FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS gotpl-build' \
  'ARG GOTPL_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
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

# Versions per compatibility line; an empty line asks for the newest release.
_get_latest_version() {
  case "${1}:${2}" in
    github.com/just-containers/s6-overlay:3|github.com/just-containers/s6-overlay:) echo '3.2.4.0' ;;
    github.com/go-acme/lego:5) echo '5.6.1' ;;
    github.com/go-acme/lego:4) echo '4.35.2' ;;
    github.com/go-acme/lego:) echo '6.0.0' ;;
    github.com/wodby/confd:0.17) echo '0.17.1' ;;
    github.com/wodby/confd:) echo '0.18.0' ;;
    github.com/wodby/gotpl:0.6) echo '0.6.9' ;;
    *) return 1 ;;
  esac
}

go_mod() {
  local requirements="${1}"
  jq -nc --arg content "$(printf 'module example\n\ngo 1.26\n\nrequire (\n%b)\n' "${requirements}" | base64)" '{content: $content}'
}

_github_api() {
  case "${1}" in
    repos/go-acme/lego/commits/v5.6.1|repos/wodby/gotpl/commits/0.6.9) echo '{"sha":"dddddddddddddddddddddddddddddddddddddddd"}' ;;
    repos/wodby/confd/commits/v0.17.1) echo '{"sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}' ;;
    repos/wodby/gotpl/compare/*) echo '{"status":"ahead"}' ;;
    # lego caught up with the x/net override but still requires an older grpc.
    'repos/go-acme/lego/contents/go.mod?ref=v5.6.1')
      go_mod '\tgolang.org/x/net v0.63.0 // indirect\n\tgoogle.golang.org/grpc v1.84.0 // indirect\n' ;;
    *) return 1 ;;
  esac
}

_prepare_edge_alpine_update "${dockerfile}" || fail "expected image pin updates"
assert_file_line 'ARG GO_IMAGE=golang:1.26.5-alpine3.23@sha256:new-go' "${dockerfile}"
assert_file_line 'ARG NGINX_IMAGE=wodby/nginx:1.31-5.48.5@sha256:new-nginx' "${dockerfile}"
assert_file_line 'ARG LEGO_VERSION=v5.6.1' "${dockerfile}"
assert_file_line 'ARG LEGO_COMMIT=dddddddddddddddddddddddddddddddddddddddd' "${dockerfile}"
assert_file_line 'ARG CONFD_VERSION=v0.17.1' "${dockerfile}"
assert_file_line 'ARG CONFD_COMMIT=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' "${dockerfile}"
assert_file_line 'ARG S6_OVERLAY_VERSION=3.2.4.0' "${dockerfile}"
assert_file_line 'ARG GOTPL_COMMIT=dddddddddddddddddddddddddddddddddddddddd' "${dockerfile}"
# The override lego now meets is dropped; the one it does not meet stays.
assert_file_line 'ARG LEGO_GO_MODULES="google.golang.org/grpc@v1.85.0"' "${dockerfile}"
assert_event '.type == "dependency_update" and .message == "s6-overlay: 3.2.3.2 -> 3.2.4.0"'
assert_event '.type == "dependency_update" and .message == "lego: 5.6.0 -> 5.6.1"'
assert_event '.type == "dependency_update" and .message == "confd: 0.17.0 -> 0.17.1"'
assert_event '.type == "dependency_update" and (.message | startswith("golang.org/x/net (lego build): override 0.62.0 removed"))'
# Newer lines are reported, never adopted.
assert_event '.type == "manual_review" and (.message | startswith("lego 6.0.0 is available"))'
assert_event '.type == "manual_review" and (.message | startswith("confd 0.18.0 is available"))'
if jq -e 'select(.message | startswith("s6-overlay 3.2.4.0 is available"))' "${IMAGES_UPDATE_REPORT_FILE}" >/dev/null; then
  fail "a release on the current line was reported as a new line"
fi

# Once current, nothing changes.
_github_api() {
  case "${1}" in
    repos/wodby/gotpl/commits/0.6.9) echo '{"sha":"dddddddddddddddddddddddddddddddddddddddd"}' ;;
    'repos/go-acme/lego/contents/go.mod?ref=v5.6.1') go_mod '\tgoogle.golang.org/grpc v1.84.0\n' ;;
    *) return 1 ;;
  esac
}
if _prepare_edge_alpine_update "${dockerfile}"; then
  fail "current image pins were reported as changed"
else
  assert_eq "1" "$?"
fi

# An override for a module the release no longer uses is dropped.
(
  _github_api() { go_mod '\tgolang.org/x/text v0.38.0\n'; }
  _edge_prune_module_pins "${dockerfile}" || fail 'unused override was kept'
  assert_file_line 'ARG LEGO_GO_MODULES=""' "${dockerfile}"
)

# Releases outside the current line are refused, not adopted.
(
  _get_latest_version() {
    case "${1}:${2}" in
      github.com/go-acme/lego:5) echo '6.0.0' ;;
      *) echo '3.2.4.0' ;;
    esac
  }
  if _edge_runtime_updates "${dockerfile}"; then
    fail 'major migration was accepted'
  else
    assert_eq 2 "$?"
  fi
  assert_file_line 'ARG LEGO_VERSION=v5.6.1' "${dockerfile}"
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
assert_event '.type == "manual_review" and (.message | contains("diverges"))'

# Edge 2 has no confd build and stays on lego 4.
(
  edge2_dockerfile="${test_root}/Dockerfile.edge2"
  printf '%s\n' \
    'FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS lego-build' \
    'ARG LEGO_VERSION=v4.35.2' \
    'ARG LEGO_COMMIT=dddddddddddddddddddddddddddddddddddddddd' \
    'ARG LEGO_GO_MODULES="golang.org/x/net@v0.62.0"' \
    'FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS gotpl-build' \
    'ARG GOTPL_COMMIT=dddddddddddddddddddddddddddddddddddddddd' \
    'FROM ${NGINX_IMAGE}' \
    'ARG S6_OVERLAY_VERSION=3.2.4.0' >"${edge2_dockerfile}"
  _get_latest_version() {
    case "${1}:${2}" in
      github.com/wodby/confd:*) fail 'Edge 2 requested confd' ;;
      github.com/go-acme/lego:4) echo '4.35.2' ;;
      github.com/go-acme/lego:) echo '5.6.1' ;;
      github.com/wodby/gotpl:*) echo '0.6.9' ;;
      *) echo '3.2.4.0' ;;
    esac
  }
  _github_api() {
    case "${1}" in
      repos/wodby/gotpl/commits/*) echo '{"sha":"dddddddddddddddddddddddddddddddddddddddd"}' ;;
      'repos/go-acme/lego/contents/go.mod?ref=v4.35.2') go_mod '\tgolang.org/x/net v0.53.0\n' ;;
      *) fail "unexpected GitHub request: $1" ;;
    esac
  }
  if _edge_runtime_updates "${edge2_dockerfile}" 2; then
    fail 'current Edge 2 pins were reported as changed'
  else
    assert_eq 1 "$?"
  fi
  if _edge_prune_module_pins "${edge2_dockerfile}" 2; then
    fail 'an override lego 4 still needs was dropped'
  fi
  assert_file_line 'ARG LEGO_GO_MODULES="golang.org/x/net@v0.62.0"' "${edge2_dockerfile}"
)

# Override parsing, including releases cut before the overrides ARGs existed.
(
  legacy="${test_root}/Dockerfile.legacy"
  printf '%s\n' 'ARG GO_CRYPTO_VERSION=v0.58.0' 'ARG GO_NET_VERSION=v0.61.0' \
    'ARG GO_GRPC_VERSION=v1.83.2' 'ARG GO_JOSE_VERSION=v4.1.4' \
    'ARG GO_CRYPTO_VERSION=v0.58.0' 'ARG GO_NET_VERSION=v0.61.0' 'ARG GO_GRPC_VERSION=v1.83.2' >"${legacy}"
  assert_eq $'golang.org/x/crypto@v0.58.0\ngolang.org/x/net@v0.61.0\ngoogle.golang.org/grpc@v1.83.2\ngithub.com/go-jose/go-jose/v4@v4.1.4' \
    "$(_edge_module_pins LEGO_GO_MODULES "${legacy}")"
  # confd's old overrides have no successor: its fork carries its own dependencies.
  assert_eq '' "$(_edge_module_pins CONFD_GO_MODULES <(cat "${legacy}"))"
  printf '%s\n' 'ARG LEGO_GO_MODULES="golang.org/x/net@0.62.0"' >"${legacy}"
  if _edge_module_pins LEGO_GO_MODULES "${legacy}" 2>/dev/null; then
    fail 'invalid override accepted'
  else
    assert_eq 2 "$?"
  fi
  printf '%s\n' 'ARG LEGO_GO_MODULES=""' >"${legacy}"
  _edge_write_module_pins LEGO_GO_MODULES "${legacy}" golang.org/x/net@v0.62.0 '' golang.org/x/crypto@v0.59.0
  assert_file_line 'ARG LEGO_GO_MODULES="golang.org/x/crypto@v0.59.0 golang.org/x/net@v0.62.0"' "${legacy}"
  assert_eq 0.62.0 "$(_edge_pinned_version golang.org/x/net golang.org/x/crypto@v0.59.0 golang.org/x/net@v0.62.0)"
  assert_eq '' "$(_edge_pinned_version golang.org/x/ne golang.org/x/net@v0.62.0)"
)

# Grype output becomes one finding per line: High and Critical only, versions
# without the v prefix, and the repository's Grype configuration applied.
(
  export IMAGES_REPO_ROOT="${test_root}/images"
  mkdir -p "${IMAGES_REPO_ROOT}/.image-security-tools/db" "${test_root}/scan-repo"
  cat >"${IMAGES_REPO_ROOT}/.image-security-tools/grype" <<'GRYPE'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${GRYPE_ARGS_FILE}"
cat <<'JSON'
{"matches": [
  {"vulnerability": {"id": "CVE-1", "severity": "High", "fix": {"versions": ["v0.63.0"]}},
   "artifact": {"name": "golang.org/x/net", "version": "v0.62.0", "type": "go-module",
                "locations": [{"path": "/opt/wodby/tools/bin/confd"}]}},
  {"vulnerability": {"id": "CVE-2", "severity": "Medium", "fix": {"versions": ["1.0.1"]}},
   "artifact": {"name": "busybox", "version": "1.0.0", "type": "apk", "locations": [{"path": "/lib/apk/db/installed"}]}},
  {"vulnerability": {"id": "CVE-3", "severity": "Critical", "fix": {"versions": ["1.0.1"]}},
   "artifact": {"name": "busybox", "version": "1.0.0", "type": "apk", "locations": [{"path": "/lib/apk/db/installed"}]}}
]}
JSON
GRYPE
  chmod +x "${IMAGES_REPO_ROOT}/.image-security-tools/grype"
  export GRYPE_ARGS_FILE="${test_root}/grype-args"
  cd "${test_root}/scan-repo"
  touch .grype.yaml
  findings=$(_edge_security_findings docker.io/wodby/edge-alpine:3.1.0)
  assert_eq 2 "$(wc -l <<<"${findings}" | tr -d ' ')"
  assert_eq 'CVE-1 0.62.0 0.63.0 /opt/wodby/tools/bin/confd' \
    "$(head -n1 <<<"${findings}" | jq -r '[.id, .version, .fixes[0], .paths[0]] | join(" ")')"
  assert_eq 'CVE-3 Critical apk' "$(tail -n1 <<<"${findings}" | jq -r '[.id, .severity, .type] | join(" ")')"
  grep -Fq 'registry:docker.io/wodby/edge-alpine:3.1.0 --platform linux/amd64 --by-cve --only-fixed --config .grype.yaml -o json' \
    "${GRYPE_ARGS_FILE}" || fail "unexpected Grype arguments: $(cat "${GRYPE_ARGS_FILE}")"
  rm -rf "${IMAGES_REPO_ROOT}/.image-security-tools"
  if _edge_security_findings docker.io/wodby/edge-alpine:3.1.0 2>/dev/null; then
    fail 'missing scanner accepted'
  else
    assert_eq 2 "$?"
  fi
)

assert_eq 0.63.0 "$(_edge_fix_version 0.62.0 '["0.61.0","0.64.0","0.63.0"]')"
if _edge_fix_version 0.62.0 '["1.0.0"]'; then
  fail 'a fix on another major line was accepted'
fi

# Security plan: which findings the release would fix, and the overrides it adds.
plan_dockerfile="${test_root}/Dockerfile.plan"
printf '%s\n' 'ARG LEGO_VERSION=v5.6.1' 'ARG LEGO_GO_MODULES="golang.org/x/crypto@v0.59.0 golang.org/x/net@v0.62.0"' \
  'ARG CONFD_VERSION=v0.17.0' >"${plan_dockerfile}"
finding() {
  jq -nc --arg id "$1" --arg package "$2" --arg version "$3" --arg type "$4" --arg path "$5" --arg fix "$6" \
    '{id: $id, severity: "High", package: $package, version: $version, type: $type, fixes: [$fix], paths: [$path]}'
}
(
  _get_image_digest() { echo sha256:published; }
  # The pinned lego release does not require the fixed versions yet.
  _github_api() {
    case "${1}" in
      'repos/go-acme/lego/contents/go.mod?ref=v5.6.1') go_mod '\tgithub.com/go-jose/go-jose/v4 v4.1.6\n\tgolang.org/x/net v0.60.0\n' ;;
      *) fail "unexpected GitHub request: $1" ;;
    esac
  }
  _edge_security_findings() {
    case "${1}" in
      docker.io/wodby/edge-alpine:3.1.0)
        finding CVE-NET golang.org/x/net 0.62.0 go-module /opt/wodby/bin/lego 0.63.0
        finding CVE-JOSE github.com/go-jose/go-jose/v4 4.1.9 go-module /opt/wodby/bin/lego 4.1.10
        finding CVE-APK busybox 1.37.0-r1 apk /lib/apk/db/installed 1.37.0-r2
        finding CVE-GO stdlib 1.26.11 go-module /opt/wodby/bin/lego 1.26.12
        finding CVE-MAJOR golang.org/x/text 0.38.0 go-module /opt/wodby/bin/lego 1.0.0
        finding CVE-CONFD google.golang.org/grpc 1.84.0 go-module /opt/wodby/tools/bin/confd 1.85.0 ;;
      docker.io/wodby/edge-alpine:latest)
        finding CVE-NET golang.org/x/net 0.62.0 go-module /opt/wodby/bin/lego 0.63.0
        finding CVE-JOSE github.com/go-jose/go-jose/v4 4.1.9 go-module /opt/wodby/bin/lego 4.1.10
        finding CVE-GO stdlib 1.26.11 go-module /opt/wodby/bin/lego 1.26.12
        finding CVE-MAJOR golang.org/x/text 0.38.0 go-module /opt/wodby/bin/lego 1.0.0
        finding CVE-CONFD google.golang.org/grpc 1.84.0 go-module /opt/wodby/tools/bin/confd 1.85.0 ;;
      *) fail "unexpected scan: $1" ;;
    esac
  }
  notes=$(_edge_security_plan 3.1.0 3 latest "${plan_dockerfile}") || fail 'fixable findings did not plan a release'
  assert_eq $'- CVE-APK (High): busybox 1.37.0-r1.\n- CVE-JOSE (High): github.com/go-jose/go-jose/v4 4.1.9 in the lego build, raised to 4.1.10.\n- CVE-NET (High): golang.org/x/net 0.62.0 in the lego build, raised to 0.63.0.' "${notes}"
  assert_file_line 'ARG LEGO_GO_MODULES="github.com/go-jose/go-jose/v4@v4.1.10 golang.org/x/crypto@v0.59.0 golang.org/x/net@v0.63.0"' "${plan_dockerfile}"
  # stdlib is fixed by the Go builder image, x/text 1.0.0 is a new major line, and
  # confd's dependencies are fixed in wodby/confd.
  assert_event '.type == "manual_review" and (.message | contains("CVE-GO in stdlib 1.26.11, CVE-MAJOR in golang.org/x/text 0.38.0 and CVE-CONFD in google.golang.org/grpc 1.84.0"))'

  # The overrides are already in place on the next run: the plan still releases.
  notes=$(_edge_security_plan 3.1.0 3 latest "${plan_dockerfile}") || fail 'existing overrides did not plan a release'
  assert_file_line 'ARG LEGO_GO_MODULES="github.com/go-jose/go-jose/v4@v4.1.10 golang.org/x/crypto@v0.59.0 golang.org/x/net@v0.63.0"' "${plan_dockerfile}"

  # A release that already requires the fixed version needs no override, and
  # one below its requirement would downgrade the module.
  (
    satisfied_plan="${test_root}/Dockerfile.satisfied"
    printf '%s\n' 'ARG LEGO_VERSION=v5.6.1' 'ARG LEGO_GO_MODULES=""' >"${satisfied_plan}"
    _github_api() { go_mod '\tgolang.org/x/net v0.64.0\n'; }
    _edge_security_findings() {
      finding CVE-NET golang.org/x/net 0.62.0 go-module /opt/wodby/bin/lego 0.63.0
    }
    notes=$(_edge_security_plan 3.1.0 3 latest "${satisfied_plan}") || fail 'a fix the branch release requires was not counted'
    assert_eq '- CVE-NET (High): golang.org/x/net 0.62.0 in the lego build, fixed by lego 5.6.1.' "${notes}"
    assert_file_line 'ARG LEGO_GO_MODULES=""' "${satisfied_plan}"
  )

  # A confd finding never becomes an override, on either line.
  edge2_plan="${test_root}/Dockerfile.plan2"
  printf '%s\n' 'ARG LEGO_VERSION=v4.35.2' 'ARG LEGO_GO_MODULES=""' >"${edge2_plan}"
  _edge_security_findings() {
    finding CVE-NET golang.org/x/net 0.62.0 go-module /opt/wodby/tools/bin/confd 0.63.0
  }
  if _edge_security_plan 2.7.13 2 2.x "${edge2_plan}"; then
    fail 'a confd override was planned'
  fi
  assert_file_line 'ARG LEGO_GO_MODULES=""' "${edge2_plan}"

  _edge_security_findings() { :; }
  if _edge_security_plan 3.1.0 3 latest "${plan_dockerfile}"; then
    fail 'a release without findings was planned'
  else
    assert_eq 1 "$?"
  fi
  _edge_security_findings() { return 2; }
  if _edge_security_plan 3.1.0 3 latest "${plan_dockerfile}"; then
    fail 'a failed scan was ignored'
  else
    assert_eq 2 "$?"
  fi
  _get_image_digest() { [[ "${2}" != 3.1.0 ]] || exit 1; echo sha256:published; }
  if _edge_security_plan 3.1.0 3 latest "${plan_dockerfile}"; then
    fail 'an unpublished release was scanned'
  else
    assert_eq 1 "$?"
  fi
  assert_event '.type == "manual_review" and .message == "wodby/edge-alpine:3.1.0 is not published; skipped the security check"'
)

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

# Release notes include everything since the previous tag.
notes_dir="${test_root}/notes"
mkdir -p "${notes_dir}"
(
  cd "${notes_dir}"
  previous_pins() {
    printf '%s\n' 'ARG NGINX_IMAGE=wodby/nginx:1.31-5.48.7@sha256:old' 'ARG GO_IMAGE=golang:1.26.7-alpine3.23@sha256:old' \
      'ARG LEGO_VERSION=v5.6.0' 'ARG LEGO_GO_MODULES="golang.org/x/crypto@v0.59.0 golang.org/x/net@v0.62.0"' 'ARG S6_OVERLAY_VERSION=3.2.3.2' \
      'ARG GOTPL_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' 'ARG CONFD_VERSION=v0.17.0'
  }
  previous_pins | sed 's/LEGO_VERSION=v5.6.0/LEGO_VERSION=v5.6.1/; s/1.31-5.48.7@sha256:old/1.31-5.48.13@sha256:new/' \
    | sed 's|LEGO_GO_MODULES=.*|LEGO_GO_MODULES="github.com/go-jose/go-jose/v4@v4.1.10 golang.org/x/net@v0.63.0 google.golang.org/grpc@v1.85.0"|' >Dockerfile
  git() {
    assert_eq 'show 3.1.0:Dockerfile' "$*"
    previous_pins
  }
  _next_release_tag() { echo 3.1.1; }
  _edge_nginx_version() {
    case "${1}" in
      *5.48.7*) echo 1.31.3 ;;
      *) echo 1.31.6 ;;
    esac
  }
  notes=$(_edge_release_notes 3.1.0 '- CVE-NET (High): golang.org/x/net 0.62.0 in the lego build, raised to 0.63.0.')
  [[ "${notes}" == 'Changes since 3.1.0'$'\n\n''Fixes these vulnerabilities:'$'\n''- CVE-NET (High)'* ]] || fail "missing security section: ${notes}"
  [[ "${notes}" == *'NGINX: 1.31.3 -> 1.31.6.'* ]] || fail 'missing NGINX upgrade'
  [[ "${notes}" == *'- lego (certificate issuance and renewal): 5.6.0 -> 5.6.1.'* ]] || fail 'missing runtime update note'
  [[ "${notes}" == *'- golang.org/x/net (lego build): 0.62.0 -> 0.63.0.'* ]] || fail 'missing changed override'
  [[ "${notes}" == *'- google.golang.org/grpc (lego build): raised to 1.85.0.'* ]] || fail 'missing new override'
  [[ "${notes}" == *'- golang.org/x/crypto (lego build): override removed, lego now requires a fixed version.'* ]] || fail 'missing removed override'
  [[ "${notes}" == *'- github.com/go-jose/go-jose/v4 (lego build): raised to 4.1.10.'* ]] || fail 'missing lego override'
  [[ "${notes}" != *'confd (configuration generation)'* && "${notes}" != *'Go builder'* ]] || fail 'unchanged components reported'
  [[ "${notes}" != *'sha256:'* ]] || fail 'raw digests leaked into release notes'
  [[ "${notes}" == *'compare/3.1.0...3.1.1' ]] || fail 'wrong release comparison'

  # Releases cut before the overrides ARGs compare against their per-module pins.
  git() {
    printf '%s\n' 'ARG NGINX_IMAGE=wodby/nginx:1.31-5.48.13@sha256:new' 'ARG GO_IMAGE=golang:1.26.7-alpine3.23@sha256:old' \
      'ARG LEGO_VERSION=v4.35.2' 'ARG GO_NET_VERSION=v0.62.0' 'ARG GO_JOSE_VERSION=v4.1.9' \
      'ARG S6_OVERLAY_VERSION=3.2.3.2' 'ARG GOTPL_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
      'ARG CONFD_COMMIT=cccccccccccccccccccccccccccccccccccccccc' 'ARG GO_NET_VERSION=v0.62.0'
  }
  notes=$(_edge_release_notes 3.0.41)
  [[ "${notes}" == *'- lego (certificate issuance and renewal): 4.35.2 -> 5.6.1.'* ]] || fail 'missing lego major note'
  [[ "${notes}" == *'- confd (configuration generation): pinned to 0.17.0.'* ]] || fail 'missing new confd note'
  [[ "${notes}" == *'- golang.org/x/net (lego build): 0.62.0 -> 0.63.0.'* ]] || fail 'legacy override not compared'
  [[ "${notes}" != *'(confd build)'* ]] || fail 'confd overrides reported'
  [[ "${notes}" == *'- github.com/go-jose/go-jose/v4 (lego build): 4.1.9 -> 4.1.10.'* ]] || fail 'legacy lego override not compared'
  [[ "${notes}" != *'Fixes these vulnerabilities'* ]] || fail 'empty security section printed'

  # Digest-only refreshes are not dependency changes.
  previous_pins >Dockerfile
  git() { previous_pins; }
  sed -i 's/GO_IMAGE=.*$/GO_IMAGE=golang:1.26.7-alpine3.23@sha256:refreshed/' Dockerfile
  if _edge_update_requires_release; then fail 'Go digest refresh counted as a dependency change'; fi
  assert_eq '- Refresh Go builder image 1.26.7-alpine3.23 (image digest changed).' "$(_edge_change_lines HEAD)"
  sed -i 's/1.26.7/1.26.8/' Dockerfile
  _edge_update_requires_release || fail 'version update did not count as a dependency change'
  git() { return 1; }
  if _edge_update_requires_release; then
    fail 'missing previous Dockerfile accepted'
  else
    assert_eq 2 "$?"
  fi
)

# Orchestration: daily updates land on the branch; only security findings tag.
trace="${test_root}/trace"
orchestration_dir="${test_root}/orchestration"
mkdir -p "${orchestration_dir}"

_git_clone() {
  echo "clone ${2:-master}" >>"${trace}"
  cd "${orchestration_dir}"
}
_prepare_edge_alpine_update() { echo prepare >>"${trace}"; }
_latest_release_tag() { echo 3.1.0; }
_edge_security_plan() {
  echo "plan $*" >>"${trace}"
  echo '- CVE-1 (High): busybox 1.37.0-r1.'
}
_edge_release_notes() {
  assert_eq '3.1.0 - CVE-1 (High): busybox 1.37.0-r1.' "$*"
  echo 'Release notes'
}
_git_commit() {
  echo "commit ${2}" >>"${trace}"
}
git() {
  case "${1}:${2:-}" in
    push:*) echo push >>"${trace}" ;;
    diff:--quiet) return "${TEST_DOCKERFILE_UNCHANGED:-1}" ;;
    *) fail "unexpected git command: $*" ;;
  esac
}
_github_api() { fail "unexpected GitHub API request: $*"; }
_release_tag() {
  assert_eq 'Release notes  3' "$*"
  echo release >>"${trace}"
}

update_edge_alpine
assert_eq $'clone master\nprepare\nplan 3.1.0 3 latest\ncommit Release notes\npush\nrelease' "$(cat "${trace}")"

# A branch that equals the release has nothing to tag, whatever the findings.
(
  : >"${trace}"
  git() {
    case "${1}:${2:-}:${3:-}" in
      diff:--quiet:3.1.0) return 0 ;;
      diff:--quiet:--) return 0 ;;
      *) fail "unexpected git command: $*" ;;
    esac
  }
  update_edge_alpine
  assert_eq $'clone master\nprepare\nplan 3.1.0 3 latest' "$(cat "${trace}")"
  assert_event '.type == "manual_review" and (.message | contains("has no changes to release"))'
)

# Without findings, dependency updates are committed and pushed without a tag.
(
  : >"${trace}"
  _edge_security_plan() { echo "plan $*" >>"${trace}"; return 1; }
  _edge_release_notes() { fail 'release notes without a release'; }
  _release_tag() { fail 'released without a security finding'; }
  _edge_update_requires_release() { return 0; }
  _edge_change_lines() { assert_eq HEAD "$1"; echo '- lego (certificate issuance and renewal): 5.6.0 -> 5.6.1.'; }
  update_edge_alpine 2
  assert_eq $'clone release/edge-2.x\nprepare\nplan 3.1.0 2 2.x\ncommit Update Edge dependencies\n\n- lego (certificate issuance and renewal): 5.6.0 -> 5.6.1.\npush' "$(cat "${trace}")"

  : >"${trace}"
  _edge_update_requires_release() { return 1; }
  _edge_change_lines() { fail 'digest refresh listed changes'; }
  update_edge_alpine
  assert_eq $'clone master\nprepare\nplan 3.1.0 3 latest\ncommit Refresh pinned image digests\npush' "$(cat "${trace}")"

  : >"${trace}"
  TEST_DOCKERFILE_UNCHANGED=0 update_edge_alpine
  assert_eq $'clone master\nprepare\nplan 3.1.0 3 latest' "$(cat "${trace}")"

  : >"${trace}"
  _edge_update_requires_release() { return 2; }
  if update_edge_alpine; then fail 'change classification failure ignored'; fi
)

# Scan failures fail the job before anything is committed.
(
  : >"${trace}"
  _edge_security_plan() { echo "plan $*" >>"${trace}"; return 2; }
  if update_edge_alpine; then fail 'scan failure was ignored'; fi
  assert_eq $'clone master\nprepare\nplan 3.1.0 3 latest' "$(cat "${trace}")"
)

# Validation runs never scan.
(
  : >"${trace}"
  export IMAGES_UPDATE_PUSH=0
  _edge_security_plan() { fail 'validation run scanned images'; }
  _edge_update_requires_release() { return 0; }
  _edge_change_lines() { echo '- change'; }
  update_edge_alpine
  assert_eq $'clone master\nprepare\ncommit Update Edge dependencies\n\n- change' "$(cat "${trace}")"
)

# Push failures must still fail the job and prevent release publication.
: >"${trace}"
git() {
  case "${1}" in
    push) echo push >>"${trace}"; return 1 ;;
    diff) return 1 ;;
  esac
}
if update_edge_alpine; then
  fail "push failure was ignored"
fi
assert_eq $'clone master\nprepare\nplan 3.1.0 3 latest\ncommit Release notes\npush' "$(cat "${trace}")"

if (update_edge_alpine 4); then fail 'unsupported major accepted'; fi

echo "edge-alpine updater tests passed"
