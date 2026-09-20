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
  _find_timestamp_file() { return 1; }
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
  _get_image_tags() { echo 4.9.2; }
  for updater in _update_base_alpine_image _update_stability_tag; do
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
  _find_timestamp_file() { echo timestamps; }
  _get_timestamp() { echo new; }
  _get_alpine_ver() {
    case "$1" in
      wodby/app:1) echo 3.22.1 ;;
      upstream:1-alpine) echo 3.22.2 ;;
      wodby/app:2) echo 3.23.3 ;;
      upstream:2-alpine) echo 3.24.1 ;;
      wodby/app:3|upstream:3-alpine) echo 3.21.4 ;;
      *) fail "unexpected image: $1" ;;
    esac
  }
  printf '1#old1\n2#old2\n3#old3\n' > timestamps
  _update_timestamps '1 2 3' upstream:alpine wodby/app
  assert_eq 'Alpine Linux updates: 3.22.1 -> 3.22.2 (wodby/app:1); 3.23.3 -> 3.24.1 (wodby/app:2)' "$(cat release-notes)"
  assert_eq 1 "$(cat release-minor)"

  # Identical updates are described once, including exceptions for unchanged
  # Alpine versions and image lines whose timestamps did not change.
  _get_alpine_ver() {
    case "$1" in
      wodby/app:*) echo 3.24.1 ;;
      upstream:3-alpine) echo 3.24.1 ;;
      upstream:*-alpine) echo 3.24.2 ;;
      *) fail "unexpected image: $1" ;;
    esac
  }
  printf '1#old1\n2#old2\n' > timestamps
  _update_timestamps '1 2' upstream:alpine wodby/app
  assert_eq 'Alpine Linux updates: 3.24.1 -> 3.24.2' "$(cat release-notes)"
  assert_eq '' "$(cat release-minor)"

  printf '1#old1\n2#old2\n3#old3\n' > timestamps
  _update_timestamps '1 2 3' upstream:alpine wodby/app
  assert_eq 'Alpine Linux updates: 3.24.1 -> 3.24.2 (except wodby/app:3)' "$(cat release-notes)"

  printf '1#old1\n2#new\n3#old3\n' > timestamps
  _update_timestamps '1 2 3' upstream:alpine wodby/app
  assert_eq 'Alpine Linux updates: 3.24.1 -> 3.24.2 (except wodby/app:2, wodby/app:3)' "$(cat release-notes)"

  printf '1#old1\n' > timestamps
  _update_timestamps '1' upstream:alpine wodby/app
  assert_eq 'Alpine Linux updates: 3.24.1 -> 3.24.2' "$(cat release-notes)"

  # Multiple transitions group their affected images without duplicating versions.
  assert_eq 'Alpine Linux updates: 3.24.1 -> 3.24.2 (wodby/app:1, wodby/app:2); 3.23.3 -> 3.24.2 (wodby/app:3)' \
    "$(_alpine_release_description wodby/app '1 2 3 4' '3.24.1 -> 3.24.2' '3.24.1 -> 3.24.2' '3.23.3 -> 3.24.2' '')"

  # Timestamp-only rebuilds still do not create release tags.
  rm release-notes
  echo '3#old' > timestamps
  _update_timestamps 3 upstream:alpine wodby/app
  [[ ! -e release-notes ]] || fail 'timestamp-only rebuild created a release'
)

echo "release updater tests passed"
