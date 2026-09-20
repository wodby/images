#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/release-updater-test.XXXXXX")"

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

grep -Fq -- '-e IMAGES_UPDATE_PUSH' "${repo_root}/.github/actions/action.yml" \
  || fail "the updater container does not receive IMAGES_UPDATE_PUSH"

release_repo="${test_root}/release-repo"
git init -q -b master "${release_repo}"
cd "${release_repo}"
git config user.email test@wodby.invalid
git config user.name 'Wodby Tests'
git config commit.gpgsign false
git config tag.gpgsign false

git commit --allow-empty -qm root
git branch divergent
git commit --allow-empty -qm 'main release'
GIT_COMMITTER_DATE='2026-01-02T00:00:00Z' git tag -m 'Release 4.82.6' 4.82.6

git switch -q divergent
git commit --allow-empty -qm 'distant release'
GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' git tag -m 'Release 4.82.7' 4.82.7
for number in 1 2 3 4 5; do
  git commit --allow-empty -qm "divergent change ${number}"
done

git switch -q master
git merge -q --no-edit divergent

# The nearest tag is older even though the newer release is reachable through
# the merged branch. This is the history shape that caused drupal-php to try to
# create 4.82.7 a second time.
assert_eq '4.82.6' "$(git describe --abbrev=0 --tags)"
assert_eq '4.82.7' "$(_latest_release_tag)"
assert_eq '4.82.8' "$(_next_release_tag '')"
assert_eq '4.83.0' "$(_next_release_tag '1')"

trace="${test_root}/push-trace"
_git_push() {
  printf '%s\n' "$*" >"${trace}"
}

export IMAGES_UPDATE_PUSH=1
_release_tag 'Base image stability tag updated' ''
assert_eq 'tag' "$(git cat-file -t refs/tags/4.82.8)"
assert_eq 'origin 4.82.8' "$(cat "${trace}")"

# Returning to product versions must preserve r0 without letting it, aliases,
# prereleases, or an unrelated major line choose the next release.
(
  git init -q -b master "${test_root}/product"
  cd "${test_root}/product"
  git config user.email test@wodby.invalid
  git config user.name 'Wodby Tests'
  git config commit.gpgsign false
  git config tag.gpgsign false
  git commit --allow-empty -qm 'Product release'
  git tag -am 'Current product version' 3.0.11
  printf 'revision\n' > .image-release-format
  git add .image-release-format
  git commit -qm 'Opt in to image revisions'
  git tag -am 'Accidental image revision' r0
  revision_commit=$(git rev-parse r0)
  assert_eq r1 "$(_next_release_tag '')"
  for tag in 3-r0 3.0.11-r0 9.9.9-rc1 3.0.11.1; do
    git tag -am 'Non-product tag' "${tag}"
  done
  git checkout -qb future
  git commit --allow-empty -qm 'Future major'
  git tag -am 'Future major version' 4.0.0
  git checkout -q master
  git rm -q .image-release-format
  git commit -qm 'Restore product versions'
  assert_eq 3.0.11 "$(_latest_release_tag)"
  assert_eq 3.0.12 "$(_next_release_tag '')"
  assert_eq 3.1.0 "$(_next_release_tag 1)"
  _git_push() { assert_eq 'origin 3.0.12' "$*"; }
  _release_tag 'Compatible product fixes' ''
  assert_eq tag "$(git cat-file -t 3.0.12)"
  assert_eq 'Compatible product fixes' "$(git for-each-ref --format='%(contents:subject)' refs/tags/3.0.12)"
  assert_eq "${revision_commit}" "$(git rev-parse r0)"
  assert_eq 3.0.12 "$(_latest_release_tag)"
  git checkout -q future
  rm .image-release-format
  assert_eq 4.0.0 "$(_latest_release_tag)"
)

# A repository with no product history must not invent a semantic version.
(
  git init -q -b master "${test_root}/no-product-version"
  cd "${test_root}/no-product-version"
  git config user.email test@wodby.invalid
  git config user.name 'Wodby Tests'
  git config commit.gpgsign false
  git config tag.gpgsign false
  git commit --allow-empty -qm initial
  git tag -am 'Image revision only' r0
  if _next_release_tag ''; then fail 'invented a product version'; fi
)

# Exercise the real update paths while keeping all publication local to the test.
(
  mkdir -p "${test_root}/descriptions/.github/workflows"
  cd "${test_root}/descriptions"
  _git_commit() { :; }
  _git_push() { :; }
  _head_has_unpushed_commits() { return 0; }
  _release_tag() { printf '%s' "$1" > release-notes; printf '%s' "$2" > release-minor; }
  git() { [[ "$1" == rev-parse ]] || fail "unexpected git command: $*"; echo master; }

  # Multiple upstream lines retain both their old and new versions.
  _get_dir() { echo .; }
  _get_latest_version() {
    case "$2" in
      1.2) echo 1.2.10 ;;
      2.3) echo 2.3.8 ;;
      *) fail "unexpected version: $2" ;;
    esac
  }
  printf "env:\n  APP12: '1.2.3'\n  APP23: '2.3.7'\n" > .github/workflows/workflow.yml
  echo 'APP_VER ?= 1.2.3' > Makefile
  _update_versions '1.2 2.3' upstream app ''
  assert_eq 'app updates: 1.2.3 -> 1.2.10, 2.3.7 -> 2.3.8' "$(cat release-notes)"
  assert_eq '' "$(cat release-minor)"
  assert_eq 'APP_VER ?= 1.2.10' "$(cat Makefile)"

  # Equal and older candidates must not rewrite or publish the current version.
  (
    workflow_before=$(cat .github/workflows/workflow.yml)
    _git_commit() { fail 'unchanged or older version was committed'; }
    _git_push() { fail 'unchanged or older version was pushed'; }
    _release_tag() { fail 'unchanged or older version was released'; }
    _update_versions '1.2 2.3' upstream app ''
    _get_latest_version() { echo 1.2.9; }
    _update_versions '1.2' upstream app ''
    assert_eq "${workflow_before}" "$(cat .github/workflows/workflow.yml)"
    assert_eq 'APP_VER ?= 1.2.10' "$(cat Makefile)"
  )

  # Both base-image paths name the image and the complete tag transition.
  _get_image_release() { echo 4.9.2; }
  for updater in _update_base_alpine_image _update_image_revision; do
    echo '  BASE_IMAGE_STABILITY_TAG: 4.8.1' > .github/workflows/workflow.yml
    if [[ "$updater" == _update_base_alpine_image ]]; then
      "$updater" 3.24 wodby/alpine true
    else
      "$updater" 3.24 wodby/alpine ''
    fi
    assert_eq 'Base image wodby/alpine: 3.24-4.8.1 -> 3.24-4.9.2' "$(cat release-notes)"
    assert_eq 1 "$(cat release-minor)"
  done

  # A later unchanged Alpine line must not overwrite earlier release details.
  _require_base_image_pins() { return 0; }
  _base_image_ref_for_line() {
    printf 'upstream:%s-alpine@%s\n' "$1" "$(awk -F '#' -v version="$1" '$1 == version {print $2}' pins)"
  }
  _base_image_pins() {
    [[ "$1" == refresh ]] || fail "unexpected pin command: $*"
    if grep -q '#old' pins; then
      sed -i -E 's/#old[0-9]*/#new/g' pins
      echo 'Updated base image digest'
    fi
  }
  _get_alpine_ver() {
    case "${1%@*}" in
      wodby/app:1) echo 3.22.1 ;;
      upstream:1-alpine) echo 3.22.2 ;;
      wodby/app:2) echo 3.23.3 ;;
      upstream:2-alpine) echo 3.24.1 ;;
      wodby/app:3|upstream:3-alpine) echo 3.21.4 ;;
      *) fail "unexpected image: $1" ;;
    esac
  }
  printf '1#old1\n2#old2\n3#old3\n' > pins
  _update_digests '1 2 3' upstream:alpine wodby/app
  assert_eq 'Alpine Linux updates: 3.22.1 -> 3.22.2 (wodby/app:1); 3.23.3 -> 3.24.1 (wodby/app:2)' "$(cat release-notes)"
  assert_eq 1 "$(cat release-minor)"

  # Identical updates are described once, including exceptions for unchanged
  # Alpine versions and image lines whose pins did not change.
  _get_alpine_ver() {
    case "${1%@*}" in
      wodby/app:*) echo 3.24.1 ;;
      upstream:3-alpine) echo 3.24.1 ;;
      upstream:*-alpine) echo 3.24.2 ;;
      *) fail "unexpected image: $1" ;;
    esac
  }
  printf '1#old1\n2#old2\n' > pins
  _update_digests '1 2' upstream:alpine wodby/app
  assert_eq 'Alpine Linux updates: 3.24.1 -> 3.24.2' "$(cat release-notes)"
  assert_eq '' "$(cat release-minor)"

  printf '1#old1\n2#old2\n3#old3\n' > pins
  _update_digests '1 2 3' upstream:alpine wodby/app
  assert_eq 'Alpine Linux updates: 3.24.1 -> 3.24.2 (except wodby/app:3)' "$(cat release-notes)"

  printf '1#old1\n2#new\n3#old3\n' > pins
  _update_digests '1 2 3' upstream:alpine wodby/app
  assert_eq 'Alpine Linux updates: 3.24.1 -> 3.24.2 (except wodby/app:2, wodby/app:3)' "$(cat release-notes)"

  printf '1#old1\n' > pins
  _update_digests '1' upstream:alpine wodby/app
  assert_eq 'Alpine Linux updates: 3.24.1 -> 3.24.2' "$(cat release-notes)"

  # Multiple transitions group their affected images without duplicating versions.
  assert_eq 'Alpine Linux updates: 3.24.1 -> 3.24.2 (wodby/app:1, wodby/app:2); 3.23.3 -> 3.24.2 (wodby/app:3)' \
    "$(_alpine_release_description wodby/app '1 2 3 4' '3.24.1 -> 3.24.2' '3.24.1 -> 3.24.2' '3.23.3 -> 3.24.2' '')"

  # Digest-only rebuilds still do not create release tags.
  rm release-notes
  echo '3#old' > pins
  _update_digests 3 upstream:alpine wodby/app
  [[ ! -e release-notes ]] || fail 'digest-only rebuild created a release'
)

# Exact build variants determine version discovery.
(
  cd "${test_root}/descriptions"
  _get_image_tags() { printf '%s' "$2" > tag-filter; echo 8.5.11; }
  _base_image_pins() {
    case "$1" in repository) echo php ;; suffix) echo -fpm-alpine ;; *) fail "unexpected pin command" ;; esac
  }
  touch base-images.mk Dockerfile
  _get_latest_version php 8.5 php >/dev/null
  assert_eq '^(8\.5\.[0-9.]+)(?=-fpm-alpine$)' "$(cat tag-filter)"

)

echo "release updater tests passed"
