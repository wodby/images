#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/mariadb-ubuntu-updater-test.XXXXXX")"

cleanup() {
  rm -rf "${test_root}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [[ "${2}" == "${1}" ]] || fail "expected '${1}', got '${2}'"
}

# The updater script batches both update steps of wodby/mariadb into one release.
mkdir -p "${test_root}/wiring/upstream"
cp "${repo_root}/upstream/mariadb.sh" "${test_root}/wiring/upstream/mariadb.sh"
cat >"${test_root}/wiring/update.sh" <<'STUB'
_release_batch_start() { echo batch-start >>"${TRACE}"; }
_release_batch_finish() { echo batch-finish >>"${TRACE}"; }
update_from_upstream() { printf 'upstream:%s:%s\n' "$1" "$2" >>"${TRACE}"; }
update_variant_from_base_image() { printf 'variant:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" >>"${TRACE}"; }
STUB
export TRACE="${test_root}/trace"
(
  cd "${test_root}/wiring/upstream"
  ./mariadb.sh
)
assert_eq $'batch-start\nupstream:wodby/mariadb:12.3 11.8 11.4 10.11\nvariant:wodby/mariadb:12.3 11.8 11.4:ubuntu:_UBUNTU\nbatch-finish' "$(cat "${TRACE}")"

# The pin editor runs unchanged except for digest resolution, which would
# otherwise query Docker Hub: a digest is derived from the image reference.
mkdir -p "${test_root}/tooling/scripts"
cat >"${test_root}/tooling/scripts/base_images.py" <<STUB
import hashlib, importlib.util, sys
spec = importlib.util.spec_from_file_location('base_images', '${repo_root}/scripts/base_images.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
def resolve(repository, tag):
    with open('${test_root}/resolved', 'a') as stream:
        stream.write(f'{repository}:{tag}\n')
    salt = open('${test_root}/salt').read().strip()
    return 'sha256:' + hashlib.sha256(f'{repository}:{tag}:{salt}'.encode()).hexdigest()
module.BaseImages.update.__defaults__ = ('', '', resolve)
module.main()
STUB
echo first >"${test_root}/salt"
digest() {
  printf '%s:%s:%s' "$1" "$2" "$(cat "${test_root}/salt")" | sha256sum | cut -d' ' -f1
}

export IMAGES_REPO_ROOT="${test_root}/tooling"
# shellcheck source=../update.sh
. "${repo_root}/update.sh"

repo="${test_root}/mariadb"
git init -q -b master "${repo}"
cd "${repo}"
git config user.email test@wodby.invalid
git config user.name 'Wodby Tests'
git config commit.gpgsign false
git config tag.gpgsign false
mkdir -p .github/workflows 11 12 ubuntu
cat >.github/workflows/workflow.yml <<'YAML'
env:
  BASE_IMAGE_REVISION: r18
  MARIADB123: '12.3.4'
  MARIADB118: '11.8.10'
  MARIADB114: '11.4.14'
  MARIADB123_UBUNTU: '12.3.3'
  MARIADB118_UBUNTU: '11.8.9'
  MARIADB114_UBUNTU: '11.4.13'
jobs:
  build:
    steps:
      - env:
          MARIADB_VER: ${{ env.MARIADB118 }}
      - run: echo "${{ env.MARIADB118_UBUNTU }}"
YAML
cat >base-images.mk <<'MK'
BASE_IMAGE_REPOSITORY := wodby/alpine
BASE_IMAGE_VERSION_SUFFIX :=

BASE_IMAGE_DIGEST_3.22-r18 := sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MK
cat >ubuntu/base-images.mk <<MK
BASE_IMAGE_REPOSITORY := mariadb
BASE_IMAGE_VERSION_SUFFIX :=

BASE_IMAGE_DIGEST_11.4.13 := sha256:$(digest mariadb 11.4.13)
BASE_IMAGE_DIGEST_11.8.9 := sha256:$(digest mariadb 11.8.9)
BASE_IMAGE_DIGEST_12.3.3 := sha256:$(digest mariadb 12.3.3)
MK
printf 'MARIADB_VER ?= 11.8.9\n' >ubuntu/Makefile
# The Alpine directory's default must not follow the variant.
printf 'MARIADB_VER ?= 11.8.9\n' >11/Makefile
printf 'MARIADB_VER ?= 12.3.4\n' >12/Makefile
touch 11/Dockerfile 12/Dockerfile ubuntu/Dockerfile README.md
git add -A
git commit -qm 'Fixture'
alpine_pins="$(cat base-images.mk)"

# Reuse the clone of an earlier step; a clone here would reach GitHub.
_git_clone() { fail "unexpected clone of $*"; }
_git_push() { echo "push $*" >>"${test_root}/pushes"; }
latest_118='11.8.10'
_get_image_tags() {
  echo "tags $1 $2" >>"${test_root}/tag-queries"
  case "$2" in
    *'12\.3'*) echo 12.3.3 ;;
    *'11\.8'*) echo "${latest_118}" ;;
    *'11\.4'*) echo 11.4.13 ;;
    *) fail "unexpected tag filter $2" ;;
  esac
}
run_update() {
  rm -rf /tmp/mariadb
  ln -s "${repo}" /tmp/mariadb
  update_variant_from_base_image wodby/mariadb '12.3 11.8 11.4' ubuntu _UBUNTU
  rm /tmp/mariadb
  cd "${repo}"
}

# A newer official image: the variant's setting, pin and Makefile default move,
# and nothing that belongs to the Alpine builds does.
_release_batch_start
run_update
grep -Fxq "  MARIADB118_UBUNTU: '11.8.10'" .github/workflows/workflow.yml || fail 'variant version was not updated'
grep -Fxq "  MARIADB118: '11.8.10'" .github/workflows/workflow.yml || fail 'source version was changed'
grep -Fxq "  MARIADB123_UBUNTU: '12.3.3'" .github/workflows/workflow.yml || fail 'current variant version was changed'
grep -Fq 'echo "${{ env.MARIADB118_UBUNTU }}"' .github/workflows/workflow.yml || fail 'a use of the setting was rewritten'
grep -Fxq "BASE_IMAGE_DIGEST_11.8.10 := sha256:$(digest mariadb 11.8.10)" ubuntu/base-images.mk || fail 'new version was not pinned'
! grep -q 'BASE_IMAGE_DIGEST_11.8.9 ' ubuntu/base-images.mk || fail 'old version is still pinned'
assert_eq 'MARIADB_VER ?= 11.8.10' "$(cat ubuntu/Makefile)"
assert_eq 'MARIADB_VER ?= 11.8.9' "$(cat 11/Makefile)"
assert_eq "${alpine_pins}" "$(cat base-images.mk)"
assert_eq 'Update mariadb ubuntu variant to 11.8.10' "$(git log -1 --format=%s)"
assert_eq 1 "${#_RELEASE_BATCH_NOTES[@]}"
assert_eq 'mariadb ubuntu variant updates: 11.8.9 -> 11.8.10' "${_RELEASE_BATCH_NOTES[0]}"
# Only exact version tags of the official image are candidates: no -noble or -ubi.
grep -Fxq 'tags mariadb ^(11\.8\.[0-9.]+)(?=$)' "${test_root}/tag-queries" || fail "unexpected tag filters: $(cat "${test_root}/tag-queries")"
! grep -q wodby/alpine "${test_root}/resolved" || fail 'the Alpine pin file was resolved'
assert_eq 2 "$(git rev-list --count HEAD)"

# Nothing new: no commit and no further release note.
run_update
assert_eq 2 "$(git rev-list --count HEAD)"
assert_eq 1 "${#_RELEASE_BATCH_NOTES[@]}"

# The official image was rebuilt under the same tags: the pins are refreshed
# and committed so the variant is rebuilt, without a release.
echo second >"${test_root}/salt"
run_update
assert_eq 3 "$(git rev-list --count HEAD)"
assert_eq 'Rebuild the ubuntu variant against updated base image digests' "$(git log -1 --format=%s)"
grep -Fxq "BASE_IMAGE_DIGEST_11.8.10 := sha256:$(digest mariadb 11.8.10)" ubuntu/base-images.mk || fail 'pin was not refreshed'
assert_eq "${alpine_pins}" "$(cat base-images.mk)"
assert_eq 1 "${#_RELEASE_BATCH_NOTES[@]}"
assert_eq "  MARIADB118_UBUNTU: '11.8.10'" "$(grep MARIADB118_UBUNTU: .github/workflows/workflow.yml)"

# An older tag listed first must not move the variant back.
latest_118='11.8.9'
run_update
assert_eq 3 "$(git rev-list --count HEAD)"

# A repository without the variant's pin file is skipped, not failed.
git rm -q ubuntu/base-images.mk
git commit -qm 'Remove the variant pins'
run_update
assert_eq 4 "$(git rev-list --count HEAD)"

# Without a variant the helpers still use the repository's own pin file.
assert_eq base-images.mk "$(_base_image_pins_file)"
assert_eq wodby/alpine "$(_base_image_pins repository)"

echo "mariadb ubuntu updater tests passed"
