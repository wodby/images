#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${repo_root}/update.sh"
test_root=$(mktemp -d)
trap 'rm -rf "${test_root}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$1', got '$2'"; }

# Legacy repositories, including software tools, retain their SemVer sequence.
git init -q -b master "${test_root}/repo"
cd "${test_root}/repo"
git config user.name 'Release test'
git config user.email test@example.invalid
git config commit.gpgsign false
git config tag.gpgsign false
git commit --allow-empty -qm initial
git tag -am 'Initial legacy release' 4.83.3
assert_eq 4.83.4 "$(_next_release_tag '')"
assert_eq 4.84.0 "$(_next_release_tag 1)"
printf 'revision\n' > .image-release-format
assert_eq r1 "$(_next_release_tag '')"
assert_eq r1 "$(_next_release_tag 1)"
assert_eq 4.83.3 "$(_latest_release_tag)"
git tag -am 'First image revision' r1
git branch maintenance
git checkout -q maintenance
git commit --allow-empty -qm maintenance
git tag -am 'Later maintenance revision' r10
git checkout -q master
git tag -am 'Another revision' r2
git tag -am 'Unrelated prerelease' r99-rc1
git tag -am 'Invalid leading zero' r099
git tag -am 'Major version alias' 8-r999
git tag -am 'Minor version alias' 8.5-r999
git tag -am 'Full version alias' 8.5.10-r999
assert_eq r10 "$(_latest_release_tag)"
assert_eq r11 "$(_next_release_tag '')"
assert_eq r11 "$(_next_release_tag 1)"
# Publication still uses annotated tags and never mutates earlier tags.
_git_push() { assert_eq 'origin r11' "$*"; }
export IMAGES_UPDATE_PUSH=1
_release_tag 'Adopt compatible dependency fixes' ''
assert_eq tag "$(git cat-file -t r11)"
assert_eq 'Adopt compatible dependency fixes' "$(git for-each-ref --format='%(contents:subject)' refs/tags/r11)"

_image_release_is_newer r1 99.9.9 || fail 'legacy transition rejected'
_image_release_is_newer r10 r2 || fail 'revisions not ordered numerically'
for pair in 'r2 r10' 'r1 r1' '99.9.9 r1' 'r01 4.0.0' 'r1-rc1 4.0.0'; do
 read -r candidate current <<<"$pair"
 if _image_release_is_newer "$candidate" "$current"; then fail "invalid transition: $pair"; fi
done

# Registry lookup filters the exact runtime and variant, scans every page, and
# prefers revisions even when a legacy release was pushed more recently.
curl() {
 case "${*: -1}" in
  *'page=1&'*) printf '%s\n' '{"next":"page2","results":[{"name":"8.5-99.9.9"},{"name":"8.5-r2"},{"name":"8.5-dev-r100"},{"name":"8.5-r100-amd64"}]}' ;;
  *'page=2&'*) printf '%s\n' '{"next":null,"results":[{"name":"8.5-r10"},{"name":"8.5-r01"},{"name":"8.5-r99-rc1"},{"name":"8.4-r999"}]}' ;;
  *) fail "unexpected registry request: $*" ;;
 esac
}
assert_eq r10 "$(_get_image_release wodby/php 8.5-)"
assert_eq r100 "$(_get_image_release wodby/php 8.5-dev-)"
curl() { echo '{"next":null,"results":[{"name":"8.5-4.71.5"},{"name":"8.5-4.71.12"}]}'; }
assert_eq 4.71.12 "$(_get_image_release wodby/php 8.5-)"
curl() { return 22; }
if _get_image_release wodby/php 8.5-; then fail 'registry error ignored'; fi

# A descendant keeps its current pin until an actual published parent release
# is available. Both workflow variable names remain usable during rollout.
mkdir -p .github/workflows
_git_commit() { :; }
_git_push() { :; }
_get_image_release() { echo r12; }
_release_tag() { echo "$1" > revision-notes; }
for key in BASE_IMAGE_STABILITY_TAG BASE_IMAGE_REVISION; do
 echo "  ${key}: 4.71.5" > .github/workflows/workflow.yml
 _update_image_revision 8.5 wodby/php ''
 assert_eq r12 "$(_base_image_release)"
 (
   _base_image_pins() { assert_eq 'ref --line 8.5 --stability r12' "$*"; }
   _base_image_ref_for_line 8.5
 )
 grep -Fq "${key}: r12" .github/workflows/workflow.yml
 grep -Fq '8.5-4.71.5 -> 8.5-r12' revision-notes
 rm revision-notes
 _update_image_revision 8.5 wodby/php ''
 [[ ! -f revision-notes ]] || fail 'unchanged parent released again'
done

# Docker4X updates preserve runtime/variant prefixes and existing test fixtures.
mkdir -p tests/php
printf 'services:\n  php:\n    image: wodby/php:$PHP_TAG\n  xhprof:\n    image: wodby/xhprof:$XHPROF_TAG\n' > compose.yml
printf 'PHP_TAG=8.5-dev-4.71.5\nXHPROF_TAG=2.0.0\n' > .env
printf 'PHP_TAG=8.4-dev-macos-4.71.5\nPHP_STABILITY_TAG=4.71.5\nPHP_IMAGE_REVISION=4.71.5\nXHPROF_TAG=2.0.0\n' > tests/php/.env
_git_clone() { :; }
_get_image_release() {
 case "$1:$2" in
  wodby/php:8.5-dev-|wodby/xhprof:) echo r12 ;;
  *) fail "wrong runtime or variant prefix: $*" ;;
 esac
}
update_docker4x wodby/docker4php ''
grep -Fxq 'PHP_TAG=8.5-dev-r12' .env
grep -Fxq 'XHPROF_TAG=r12' .env
grep -Fxq 'PHP_TAG=8.4-dev-macos-r12' tests/php/.env
grep -Fxq 'PHP_STABILITY_TAG=r12' tests/php/.env
grep -Fxq 'PHP_IMAGE_REVISION=r12' tests/php/.env

echo 'image revision tests passed'
