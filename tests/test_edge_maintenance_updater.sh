#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${repo_root}/update.sh"
test_root=$(mktemp -d)
trap 'rm -rf "${test_root}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$1', got '$2'"; }
export GIT_CONFIG_GLOBAL="${test_root}/gitconfig"
git config --global user.name 'Updater tests'
git config --global user.email tests@wodby.invalid
git config --global commit.gpgsign false
git config --global tag.gpgsign false
export IMAGES_UPDATE_PUSH=1 IMAGES_UPDATE_REPORT_FILE="${test_root}/events.jsonl"

# Check that the actual clone helper forwards an explicit branch and keeps the
# default clone unchanged. No GitHub request or fixed /tmp checkout is created.
(
  export WODBOT_GITHUB_USERNAME=fixture WODBOT_GITHUB_PAT=fixture
  git() { printf '%s\n' "$*" > "${test_root}/clone-args"; }
  cd() { assert_eq /tmp/edge-alpine "$1"; }
  _git_clone wodby/edge-alpine release/edge-2.x
  assert_eq 'clone --branch release/edge-2.x https://fixture:fixture@github.com/wodby/edge-alpine /tmp/edge-alpine' "$(cat "${test_root}/clone-args")"
  _git_clone wodby/edge-alpine
  assert_eq 'clone https://fixture:fixture@github.com/wodby/edge-alpine /tmp/edge-alpine' "$(cat "${test_root}/clone-args")"
)

seed="${test_root}/seed"
origin="${test_root}/origin.git"
git init -q -b master "${seed}"
cd "${seed}"
cat > Dockerfile <<'DOCKERFILE'
ARG GO_IMAGE=golang:1.26.9-alpine3.23@sha256:old
ARG NGINX_IMAGE=wodby/nginx:1.31-r13@sha256:old
ARG LEGO_VERSION=v5.6.0
ARG LEGO_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ARG LEGO_GO_MODULES=""
ARG CONFD_VERSION=v0.41.3
ARG CONFD_COMMIT=cccccccccccccccccccccccccccccccccccccccc
ARG CONFD_GO_MODULES="golang.org/x/net@v0.62.0"
ARG S6_OVERLAY_VERSION=3.2.3.2
ARG GOTPL_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
DOCKERFILE
git add . && git commit -qm 'Current Edge fixture'
git tag -am 'Current Edge release' 3.1.0
git checkout -qb release/edge-2.x
cat > Dockerfile <<'DOCKERFILE'
ARG GO_IMAGE=golang:1.26.9-alpine3.23@sha256:old
ARG NGINX_IMAGE=wodby/nginx:1.31-r13@sha256:old
ARG LEGO_VERSION=v4.35.2
ARG LEGO_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ARG LEGO_GO_MODULES="golang.org/x/net@v0.62.0"
ARG S6_OVERLAY_VERSION=3.2.3.2
ARG GOTPL_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
DOCKERFILE
git commit -qam 'Legacy runtime fixture'
git tag -am 'Legacy Edge release' 2.7.1
git checkout -q master
git clone -q --bare "${seed}" "${origin}"

# Explicit major selection wins even on a branch rooted in another major.
assert_eq 2.7.1 "$(_latest_release_tag 2)"
assert_eq 2.7.2 "$(_next_release_tag '' 2)"
assert_eq 3.1.1 "$(_next_release_tag '' 3)"
if _latest_release_tag 4; then fail 'invented a missing release line'; fi
if _latest_release_tag '2.*'; then fail 'accepted an invalid major'; fi

_git_clone() {
  assert_eq wodby/edge-alpine "$1"
  local checkout
  checkout=$(mktemp -d "${test_root}/clone.XXXXXX")
  git clone -q --branch "${2:-master}" "${origin}" "${checkout}"
  cd "${checkout}"
}
_get_image_release() { assert_eq 'wodby/nginx 1.31-' "$*"; echo r14; }
_get_image_tags() { echo 1.26.10-alpine3.23; }
TEST_EDGE_NGINX_DIGEST="sha256:$(printf '%064d' 2)"
_get_image_digest() {
  case "$1:$2" in
    wodby/nginx:1.31-r14) echo "${TEST_EDGE_NGINX_DIGEST}" ;;
    golang:1.26.10-alpine3.23) printf 'sha256:%064d\n' 3 ;;
    wodby/edge-alpine:*) printf 'sha256:%064d\n' 4 ;;
    *) fail "unexpected image: $*" ;;
  esac
}
_get_latest_version() {
  case "$1:$2" in
    github.com/go-acme/lego:4) echo "${TEST_EDGE_LEGO4_VERSION:-4.35.2}" ;;
    github.com/go-acme/lego:5|github.com/go-acme/lego:) echo 5.6.1 ;;
    github.com/just-containers/s6-overlay:*) echo 3.2.4.0 ;;
    github.com/wodby/gotpl:*) echo 0.6.9 ;;
    github.com/abtreece/confd:*)
      [[ "$(git branch --show-current)" != release/edge-2.x ]] || fail 'legacy branch requested confd'
      echo 0.41.3 ;;
    *) fail "unexpected dependency: $*" ;;
  esac
}
go_mod() {
  jq -nc --arg content "$(printf 'module example\n\nrequire (\n\t%s\n)\n' "$1" | base64)" '{content: $content}'
}
_github_api() {
  case "$1" in
    repos/go-acme/lego/commits/v*|repos/wodby/gotpl/commits/0.6.9) printf '{"sha":"%040d"}\n' 4 ;;
    repos/wodby/gotpl/compare/*) echo '{"status":"ahead"}' ;;
    repos/go-acme/lego/contents/go.mod*) go_mod 'golang.org/x/net v0.53.0' ;;
    repos/abtreece/confd/contents/go.mod*) go_mod 'golang.org/x/net v0.60.0' ;;
    *) fail "unexpected GitHub request: $*" ;;
  esac
}
_edge_nginx_version() { echo 1.31.8; }

finding() {
  jq -nc --arg id "$1" --arg package "$2" --arg version "$3" --arg type "$4" --arg path "$5" --arg fix "$6" \
    '{id: $id, severity: "High", package: $package, version: $version, type: $type, fixes: [$fix], paths: [$path]}'
}
# The first release of each line has findings; later releases are clean. The
# branch images fix the Alpine package but not the confd module.
_edge_security_findings() {
  case "$1" in
    docker.io/wodby/edge-alpine:2.7.1|docker.io/wodby/edge-alpine:3.1.0)
      finding CVE-APK busybox 1.37.0-r1 apk /lib/apk/db/installed 1.37.0-r2
      finding CVE-NET golang.org/x/net 0.62.0 go-module /opt/wodby/tools/bin/confd 0.63.0 ;;
    docker.io/wodby/edge-alpine:latest|docker.io/wodby/edge-alpine:2.x)
      finding CVE-NET golang.org/x/net 0.62.0 go-module /opt/wodby/tools/bin/confd 0.63.0 ;;
    *) ;;
  esac
}

update_edge_alpine 2
assert_eq release/edge-2.x "$(git branch --show-current)"
assert_eq tag "$(git cat-file -t 2.7.2)"
assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="${origin}" rev-parse release/edge-2.x)"
assert_eq "$(git rev-parse HEAD)" "$(git rev-parse '2.7.2^{commit}')"
! grep -Eq '^ARG CONFD_' Dockerfile || fail 'introduced confd inputs'
grep -q '^ARG LEGO_GO_MODULES="golang.org/x/net@v0.62.0"$' Dockerfile || fail 'legacy override changed'
notes=$(git for-each-ref --format='%(contents)' refs/tags/2.7.2)
[[ "$notes" == *'compare/2.7.1...2.7.2'* ]] || fail 'wrong maintenance release notes'
[[ "$notes" == *'- CVE-APK (High): busybox 1.37.0-r1.'* ]] || fail 'missing fixed vulnerability'
[[ "$notes" != *'CVE-NET'* && "$notes" != *'confd'* ]] || fail 'confd leaked into legacy notes'
[[ "$notes" == *'- gotpl'* || "$notes" == *'Updated gotpl'* ]] || fail 'missing dependency update in release notes'
legacy_head=$(git rev-parse HEAD)

update_edge_alpine
assert_eq master "$(git branch --show-current)"
assert_eq tag "$(git cat-file -t 3.1.1)"
grep -q '^ARG CONFD_GO_MODULES="golang.org/x/net@v0.63.0"$' Dockerfile || fail 'confd override was not raised'
grep -q '^ARG LEGO_VERSION=v5.6.1$' Dockerfile || fail 'lego was not updated on its line'
notes=$(git for-each-ref --format='%(contents)' refs/tags/3.1.1)
[[ "$notes" == *'compare/3.1.0...3.1.1'* ]] || fail 'current release used the legacy series'
[[ "$notes" == *'- CVE-NET (High): golang.org/x/net 0.62.0 in the confd build, raised to 0.63.0.'* ]] || fail 'missing raised module'
[[ "$notes" == *'- golang.org/x/net (confd build): 0.62.0 -> 0.63.0.'* ]] || fail 'missing override change'
current_head=$(git rev-parse HEAD)

# Both release lines are idempotent once current and clean.
update_edge_alpine 2
assert_eq "${legacy_head}" "$(git rev-parse HEAD)"
update_edge_alpine 3
assert_eq "${current_head}" "$(git rev-parse HEAD)"

# Dependency updates without a finding reach the branch but not a release.
TEST_EDGE_LEGO4_VERSION=4.35.3
update_edge_alpine 2
[[ "${legacy_head}" != "$(git rev-parse HEAD)" ]] || fail 'dependency update was not committed'
assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="${origin}" rev-parse release/edge-2.x)"
assert_eq 2.7.2 "$(_latest_release_tag 2)"
[[ "$(git log -1 --format=%B)" == 'Update Edge dependencies'$'\n\n''- lego (certificate issuance and renewal): 4.35.2 -> 4.35.3.'* ]] \
  || fail "unexpected update commit: $(git log -1 --format=%B)"
legacy_head=$(git rev-parse HEAD)

# Digest-only refreshes rebuild the branch without a release.
TEST_EDGE_NGINX_DIGEST="sha256:$(printf '%064d' 6)"
update_edge_alpine 2
[[ "${legacy_head}" != "$(git rev-parse HEAD)" ]] || fail 'digest refresh was not committed'
assert_eq 'Refresh pinned image digests' "$(git log -1 --format=%s)"
assert_eq 2.7.2 "$(_latest_release_tag 2)"
legacy_head=$(git rev-parse HEAD)

# Pull-request runs can prepare local updates, but neither branch nor tag publishes.
export IMAGES_UPDATE_PUSH=0
TEST_EDGE_LEGO4_VERSION=4.35.4
TEST_EDGE_NGINX_DIGEST="sha256:$(printf '%064d' 7)"
_edge_security_findings() { fail 'validation run scanned images'; }
update_edge_alpine 2
assert_eq "${legacy_head}" "$(git --git-dir="${origin}" rev-parse release/edge-2.x)"
assert_eq 2.7.2 "$(_latest_release_tag 2)"
if git show-ref --verify --quiet refs/tags/2.7.3; then fail "dry run created a release tag"; fi
(
  _git_clone() { fail 'unsupported major cloned a repository'; }
  if update_edge_alpine 4; then fail 'unsupported major accepted'; fi
)
(
  _git_clone() { return 1; }
  _prepare_edge_alpine_update() { fail 'missing maintenance branch fell back to default'; }
  if update_edge_alpine 2; then fail 'missing maintenance branch was ignored'; fi
)
echo 'Edge maintenance updater tests passed'
