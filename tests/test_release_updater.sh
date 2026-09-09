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
git tag -m 'Release 4.82.6' 4.82.6

git switch -q divergent
git commit --allow-empty -qm 'distant release'
git tag -m 'Release 4.82.7' 4.82.7
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

echo "release updater tests passed"
