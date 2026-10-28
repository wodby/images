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
ARG LEGO_VERSION=v4.35.2
ARG LEGO_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ARG GO_CRYPTO_VERSION=v0.58.0
ARG GO_NET_VERSION=v0.61.0
ARG GO_GRPC_VERSION=v1.83.2
ARG S6_OVERLAY_VERSION=3.2.3.2
ARG GOTPL_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
ARG ETCD_CLIENT_VERSION=v3.6.14
ARG CONFD_COMMIT=cccccccccccccccccccccccccccccccccccccccc
DOCKERFILE
git add . && git commit -qm 'Current Edge fixture'
git tag -am 'Current Edge release' 3.0.27
git checkout -qb release/edge-2.x
sed -i '/^ARG \(ETCD_CLIENT_VERSION\|CONFD_COMMIT\)=/d' Dockerfile
git commit -qam 'Legacy runtime fixture'
git tag -am 'Legacy Edge release' 2.7.1
git checkout -q master
git commit --allow-empty -qm 'Current release advances independently'
git tag -am 'Next current release' 3.0.28
git clone -q --bare "${seed}" "${origin}"

# Explicit major selection wins even on a branch rooted in another major.
assert_eq 2.7.1 "$(_latest_release_tag 2)"
assert_eq 2.7.2 "$(_next_release_tag '' 2)"
assert_eq 3.0.29 "$(_next_release_tag '' 3)"
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
    *) fail "unexpected image: $*" ;;
  esac
}
_get_latest_version() {
  case "$1" in
    github.com/go-acme/lego) echo "${TEST_EDGE_LEGO_VERSION:-4.35.3}" ;;
    github.com/just-containers/s6-overlay) echo 3.2.4.0 ;;
    github.com/wodby/gotpl) echo 0.6.9 ;;
    github.com/golang/crypto) echo 0.58.0 ;;
    github.com/golang/net) echo 0.62.0 ;;
    github.com/grpc/grpc-go) echo 1.83.2 ;;
    github.com/etcd-io/etcd|github.com/kelseyhightower/confd)
      [[ "$(git branch --show-current)" != release/edge-2.x ]] || fail 'legacy branch requested a v3 dependency'
      if [[ "$1" == */etcd ]]; then echo 3.6.15; else echo 0.16.0; fi ;;
    *) fail "unexpected dependency: $*" ;;
  esac
}
_github_api() {
  case "$1" in
    repos/go-acme/lego/commits/v4.35.[34]|repos/wodby/gotpl/commits/0.6.9) printf '{"sha":"%040d"}\n' 4 ;;
    repos/kelseyhightower/confd/commits/v0.16.0) printf '{"sha":"%040d"}\n' 5 ;;
    repos/wodby/gotpl/compare/*) echo '{"status":"ahead"}' ;;
    repos/kelseyhightower/confd/compare/*) echo '{"status":"behind"}' ;;
    *) fail "unexpected GitHub request: $*" ;;
  esac
}
_edge_nginx_version() { echo 1.31.8; }

update_edge_alpine 2
assert_eq release/edge-2.x "$(git branch --show-current)"
assert_eq tag "$(git cat-file -t 2.7.2)"
assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="${origin}" rev-parse release/edge-2.x)"
assert_eq "$(git rev-parse HEAD)" "$(git rev-parse '2.7.2^{commit}')"
! grep -Eq '^ARG (ETCD_CLIENT_VERSION|CONFD_COMMIT)=' Dockerfile || fail 'introduced etcd v3 inputs'
grep -q '^ARG GO_NET_VERSION=v0.62.0$' Dockerfile || fail 'legacy Go library override was not updated'
notes=$(git for-each-ref --format='%(contents)' refs/tags/2.7.2)
[[ "$notes" == *'compare/2.7.1...2.7.2'* && "$notes" == *'lego'* ]] || fail 'wrong maintenance release notes'
[[ "$notes" != *'etcd client'* && "$notes" != *'Updated confd'* ]] || fail 'v3 dependencies leaked into legacy notes'
legacy_head=$(git rev-parse HEAD)

update_edge_alpine
assert_eq master "$(git branch --show-current)"
assert_eq tag "$(git cat-file -t 3.0.29)"
grep -q '^ARG ETCD_CLIENT_VERSION=v3.6.15$' Dockerfile
notes=$(git for-each-ref --format='%(contents)' refs/tags/3.0.29)
[[ "$notes" == *'compare/3.0.28...3.0.29'* ]] || fail 'current release used the legacy series'
current_head=$(git rev-parse HEAD)

# Both release lines are idempotent once current.
update_edge_alpine 2
assert_eq "${legacy_head}" "$(git rev-parse HEAD)"
update_edge_alpine 3
assert_eq "${current_head}" "$(git rev-parse HEAD)"

# Digest-only maintenance refreshes rebuild the legacy branch without a release.
TEST_EDGE_NGINX_DIGEST="sha256:$(printf '%064d' 6)"
update_edge_alpine 2
[[ "${legacy_head}" != "$(git rev-parse HEAD)" ]] || fail 'digest refresh was not committed'
assert_eq 2.7.2 "$(_latest_release_tag 2)"
legacy_head=$(git rev-parse HEAD)

# Pull-request runs can prepare local updates, but neither branch nor tag publishes.
export IMAGES_UPDATE_PUSH=0
TEST_EDGE_LEGO_VERSION=4.35.4
TEST_EDGE_NGINX_DIGEST="sha256:$(printf '%064d' 7)"
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
