#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${repo_root}/update.sh"
test_root=$(mktemp -d)
trap 'rm -rf "${test_root}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$1', got '$2'"; }

# Real commits, clones, pushes and annotated tags stay in disposable local repos.
export GIT_CONFIG_GLOBAL="${test_root}/gitconfig"
cd "${test_root}"
git config --global user.name 'Updater tests'
git config --global user.email tests@wodby.invalid
git config --global commit.gpgsign false
git config --global tag.gpgsign false
export IMAGES_UPDATE_PUSH=1
export IMAGES_UPDATE_REPORT_FILE="${test_root}/events.jsonl"
export IMAGES_REPO_ROOT
export TEST_PARENT_DIGEST="sha256:$(printf '%064d' 2)"
export TEST_FLOATING_DIGEST="sha256:$(printf '%064d' 1)"

# Use the real pin editor with a deterministic registry resolver.
_base_image_pins() {
  python3 - "$@" <<'PY'
import os, sys
sys.path.insert(0, os.environ['IMAGES_REPO_ROOT'] + '/scripts')
from base_images import BaseImages
pins = BaseImages('base-images.mk')
mode = sys.argv[1]
if mode == 'repository':
    print(pins.repository)
else:
    def resolve(repository, tag):
        return os.environ['TEST_PARENT_DIGEST' if '-r' in tag else 'TEST_FLOATING_DIGEST']
    changes = pins.update(mode, new=sys.argv[3] if mode == 'stability' else '', resolver=resolve)
    for old, new in changes:
        print(f'{old} -> {new}')
PY
}
_get_image_release() {
  assert_eq 'wodby/php 8.5-' "$*"
  echo r12
}
_get_latest_version() {
  assert_eq 'github.com/example/app 11.4 app https://example.invalid/{{version}}.tgz app-' "$*"
  echo 11.4.2
}
_git_clone() {
  assert_eq wodby/app "$1"
  local checkout
  checkout=$(mktemp -d "${test_root}/clone.XXXXXX")
  git clone -q "${origin}" "${checkout}"
  cd "${checkout}"
}

for branch in main master; do
  seed="${test_root}/seed-${branch}"
  origin="${test_root}/origin-${branch}.git"
  git init -q -b "${branch}" "${seed}"
  cd "${seed}"
  mkdir -p .github/workflows
  printf 'revision\n' > .image-release-format
  printf 'env:\n  APP_VER: 11.4.1\n  BASE_IMAGE_REVISION: 4.71.5\n' > .github/workflows/workflow.yml
  printf 'APP_VER ?= 11.4.1\n' > Makefile
  echo 'FROM wodby/php:8.5' > Dockerfile
  echo 'Application image' > README.md
  printf 'BASE_IMAGE_REPOSITORY := wodby/php\nBASE_IMAGE_VERSION_SUFFIX :=\n' > base-images.mk
  for version in 8.5 8.4; do
    for variant in '' -dev -dev-macos; do
      printf 'BASE_IMAGE_DIGEST_%s%s := %s\n' "$version" "$variant" "$TEST_FLOATING_DIGEST" >> base-images.mk
      printf 'BASE_IMAGE_DIGEST_%s%s-4.71.5 := %s\n' "$version" "$variant" "$TEST_FLOATING_DIGEST" >> base-images.mk
    done
  done
  git add .
  git commit -qm 'Initial pinned parent'
  git clone -q --bare "${seed}" "${origin}"

  # A parent update pins every runtime/variant and releases on the default branch.
  update_from_parent_image wodby/app '8.5 8.4'
  assert_eq "${branch}" "$(git branch --show-current)"
  assert_eq r12 "$(_base_image_release)"
  assert_eq tag "$(git cat-file -t r1)"
  assert_eq "$(git rev-parse HEAD)" "$(git rev-parse 'r1^{commit}')"
  assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="${origin}" rev-parse "${branch}")"
  assert_eq 6 "$(grep -c -- '-r12 :=' base-images.mk)"
  assert_eq "${branch}" "$(git --git-dir="${origin}" for-each-ref --format='%(refname:short)' refs/heads)"
  parent_head=$(git rev-parse HEAD)
  update_from_parent_image wodby/app '8.5 8.4'
  assert_eq "${parent_head}" "$(git rev-parse HEAD)"
  assert_eq r1 "$(git tag --list)"

  # Application updates use the same parent and tag the updated default branch.
  update_from_upstream wodby/app 11.4 github.com/example/app 'https://example.invalid/{{version}}.tgz' 'app-'
  assert_eq "${branch}" "$(git branch --show-current)"
  assert_eq r12 "$(_base_image_release)"
  assert_eq tag "$(git cat-file -t r2)"
  assert_eq "$(git rev-parse HEAD)" "$(git rev-parse 'r2^{commit}')"
  assert_eq 'APP_VER ?= 11.4.2' "$(cat Makefile)"
  app_head=$(git rev-parse HEAD)
  update_from_upstream wodby/app 11.4 github.com/example/app 'https://example.invalid/{{version}}.tgz' 'app-'
  assert_eq "${app_head}" "$(git rev-parse HEAD)"
  assert_eq $'r1\nr2' "$(git tag --list)"

  # Digest-only refresh still commits a rebuild without creating a release tag.
  export TEST_FLOATING_DIGEST="sha256:$(printf '%064d' 3)"
  update_from_parent_image wodby/app '8.5 8.4'
  [[ "${app_head}" != "$(git rev-parse HEAD)" ]] || fail 'digest refresh did not commit'
  assert_eq $'r1\nr2' "$(git tag --list)"
  export TEST_FLOATING_DIGEST="sha256:$(printf '%064d' 1)"

  # During rollout, either entry point must stop before modifying an unpinned default.
  sed -i '/BASE_IMAGE_REVISION:/d' .github/workflows/workflow.yml
  git add .github/workflows/workflow.yml
  git commit -qm 'Simulate an unmigrated default branch'
  git push -q origin
  unpinned_head=$(git rev-parse HEAD)
  update_from_parent_image wodby/app '8.5 8.4'
  assert_eq "${unpinned_head}" "$(git rev-parse HEAD)"
  update_from_upstream wodby/app 11.4 github.com/example/app
  assert_eq "${unpinned_head}" "$(git rev-parse HEAD)"
  assert_eq $'r1\nr2' "$(git tag --list)"
  assert_eq '' "$(git status --porcelain)"
done
assert_eq 4 "$(jq -s '[.[] | select(.type == "manual_review")] | length' "$IMAGES_UPDATE_REPORT_FILE")"
echo 'default branch updater tests passed'
