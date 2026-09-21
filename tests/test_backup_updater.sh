#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${repo_root}/update.sh"
test_root=$(mktemp -d)
trap 'rm -rf "${test_root}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$1', got '$2'"; }

# Use real commits and atomic pushes; only registry and GitHub reads are fixtures.
export GIT_CONFIG_GLOBAL="${test_root}/gitconfig"
cd "${test_root}"
git config --global user.name 'Updater tests'
git config --global user.email tests@wodby.invalid
git config --global commit.gpgsign false
git config --global tag.gpgsign false
export IMAGES_UPDATE_PUSH=1 IMAGES_REPO_ROOT
export IMAGES_UPDATE_REPORT_FILE="${test_root}/events.jsonl"
export TEST_BASE_DIGEST="sha256:$(printf '%064d' 2)" LATEST_PARENT=r0
export PARENT_NOTES=$'Alpine package security updates\n\n- zlib 1.3.1 -> 1.3.2; fixes CVE-2026-0001'

_git_clone() {
  assert_eq wodby/backup "$1"
  local checkout
  checkout=$(mktemp -d "${test_root}/checkout.XXXXXX")
  git clone -q "${origin}" "${checkout}" || return 1
  cd "${checkout}"
  if [[ "${FAIL_COMMIT:-0}" == 1 ]]; then
    printf '#!/bin/sh\nexit 1\n' > .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
  fi
}
_get_image_release() {
  assert_eq wodby/alpine "$1"; assert_eq 3- "$2"
  [[ "${FAIL_LOOKUP:-0}" != 1 ]] || return 1
  echo "${LATEST_PARENT}"
}
_github_api() {
  [[ "${FAIL_NOTES:-0}" != 1 ]] || return 1
  case "$1" in
    repos/wodby/alpine/git/ref/tags/3-*)
      jq -cn --arg kind "${PARENT_KIND:-tag}" '{object:{type:$kind,sha:("a"*40)}}' ;;
    repos/wodby/alpine/git/tags/*)
      jq -cn --arg tag "3-${LATEST_PARENT}" --arg message "${PARENT_NOTES}" \
        '{tag:$tag,message:($message+"\n-----BEGIN SSH SIGNATURE-----\nfixture\n-----END SSH SIGNATURE-----\n")}' ;;
    *) fail "Unexpected GitHub lookup: $1" ;;
  esac
}
_base_image_pins() {
  python3 - "$@" <<'PY'
import os, sys
sys.path.insert(0, os.environ['IMAGES_REPO_ROOT'] + '/scripts')
from base_images import BaseImages
pins = BaseImages('base-images.mk')
args = sys.argv[1:]
if args[0] == 'repository':
    print(pins.repository)
elif args[0] == 'ref':
    print(pins.ref_for_line(args[args.index('--line')+1], args[args.index('--stability')+1]))
else:
    def resolve(repository, tag):
        assert repository == 'wodby/alpine'
        if tag == '3':
            return os.environ['TEST_BASE_DIGEST']
        assert tag.startswith('3-r'), tag
        if os.environ.get('FAIL_RESOLVE') == '1':
            raise ValueError('Registry lookup failed')
        return 'sha256:' + str(10+int(tag[3:])).zfill(64)
    new = args[args.index('--new')+1] if '--new' in args else ''
    for old, new in pins.update(args[0], new=new, resolver=resolve):
        print(f'{old} -> {new}')
PY
}

for branch in master main; do
  seed="${test_root}/seed-${branch}"
  origin="${test_root}/origin-${branch}.git"
  git init -q -b "${branch}" "${seed}"
  cd "${seed}"
  mkdir -p .github/workflows
  printf 'env:\n  BASE_IMAGE_REVISION: r0\n' > .github/workflows/workflow.yml
  printf 'BASE_IMAGE_REPOSITORY := wodby/alpine\nBASE_IMAGE_VERSION_SUFFIX :=\nBASE_IMAGE_DIGEST_3 := sha256:%064d\nBASE_IMAGE_DIGEST_3-r0 := sha256:%064d\n' 1 10 > base-images.mk
  git add .
  git commit -qm 'Initial parent revision'
  git tag -am 'Current product release' 2.3.2
  git commit --allow-empty -qm 'Image revision migration'
  git tag -am 'Retained image revision' r0
  git clone -q --bare "${seed}" "${origin}"
  original_r0=$(git rev-parse r0)
  export LATEST_PARENT=r0 TEST_BASE_DIGEST="sha256:$(printf '%064d' 2)"

  # A digest-only update commits new inputs and rebuilds latest, without a tag.
  update_backup
  refreshed=$(git rev-parse HEAD)
  assert_eq "${refreshed}" "$(git --git-dir="${origin}" rev-parse "${branch}")"
  assert_eq $'2.3.2\nr0' "$(git tag --list)"
  grep -Fq "BASE_IMAGE_DIGEST_3 := ${TEST_BASE_DIGEST}" base-images.mk
  update_backup
  assert_eq "${refreshed}" "$(git rev-parse HEAD)"
  echo 'Backup documentation' > README.md
  git add README.md; git commit -qm 'Document usage'; git push -q origin "${branch}"
  documented=$(git rev-parse HEAD)
  update_backup
  assert_eq "${documented}" "$(git rev-parse HEAD)"

  # A newly published parent creates one patch release, even when the floating
  # digest has already been adopted by an earlier rebuild.
  export LATEST_PARENT=r1
  update_backup
  released=$(git rev-parse HEAD)
  assert_eq "${released}" "$(git --git-dir="${origin}" rev-parse '2.3.3^{commit}')"
  assert_eq tag "$(git cat-file -t 2.3.3)"
  assert_eq "${original_r0}" "$(git rev-parse r0)"
  assert_eq r1 "$(_base_image_release)"
  assert_eq 'Update Alpine base image to 3-r1' "$(git for-each-ref --format='%(contents:subject)' refs/tags/2.3.3)"
  notes=$(git for-each-ref --format='%(contents:body)' refs/tags/2.3.3)
  [[ "${notes}" == *'zlib 1.3.1 -> 1.3.2; fixes CVE-2026-0001'* ]] || fail 'missing parent changes'
  if grep -Eq 'sha256:|SIGNATURE' <<<"${notes}"; then fail 'metadata leaked into notes'; fi
  update_backup
  assert_eq "${released}" "$(git rev-parse HEAD)"

  # Subsequent digest changes and an older parent listing must not tag or roll back.
  export TEST_BASE_DIGEST="sha256:$(printf '%064d' 3)"
  (export LATEST_PARENT=r0; update_backup; assert_eq r1 "$(_base_image_release)")
  update_backup
  refreshed=$(git rev-parse HEAD)
  assert_eq $'2.3.2\n2.3.3\nr0' "$(git tag --list)"

  # Validation, API/registry errors and commit failures cannot advance releases.
  export LATEST_PARENT=r2
  (
    export IMAGES_UPDATE_PUSH=0
    update_backup
    assert_eq $'2.3.2\n2.3.3\nr0' "$(git tag --list)"
    assert_eq "${refreshed}" "$(git --git-dir="${origin}" rev-parse "${branch}")"
  )
  for failure in FAIL_LOOKUP FAIL_NOTES FAIL_RESOLVE FAIL_COMMIT; do
    (
      export "${failure}=1"
      if update_backup; then fail "${failure} ignored"; fi
      [[ -z "$(git tag --list 2.3.4)" ]] || fail 'failure created a tag'
      assert_eq "${refreshed}" "$(git --git-dir="${origin}" rev-parse "${branch}")"
    )
  done
  (export PARENT_KIND=commit; if update_backup; then fail 'lightweight parent accepted'; fi)
  (export PARENT_NOTES=''; if update_backup; then fail 'empty notes accepted'; fi)

  # A rejected release tag must also reject the accompanying pin commit.
  cat > "${origin}/hooks/update" <<'HOOK'
#!/bin/sh
case "$1" in refs/tags/*) exit 1 ;; esac
HOOK
  chmod +x "${origin}/hooks/update"
  if update_backup; then fail 'failed tag push ignored'; fi
  assert_eq "${refreshed}" "$(git --git-dir="${origin}" rev-parse "${branch}")"
  [[ -z "$(git --git-dir="${origin}" tag --list 2.3.4)" ]] || fail 'failed push published tag'
  rm "${origin}/hooks/update"
  update_backup
  assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="${origin}" rev-parse '2.3.4^{commit}')"
  update_backup
  assert_eq $'2.3.2\n2.3.3\n2.3.4\nr0' "$(git tag --list)"

  # The updater can merge before Backup's build-input migration without emitting
  # another digest-triggered product release from its legacy checkout.
  sed -i 's/BASE_IMAGE_DIGEST_3 :=/BASE_IMAGE_DIGEST_latest :=/' base-images.mk
  git add base-images.mk; git commit -qm 'Legacy checkout fixture'; git push -q origin "${branch}"
  legacy=$(git rev-parse HEAD)
  update_backup
  assert_eq "${legacy}" "$(git rev-parse HEAD)"
done

jq -se '[.[] | select(.type == "release_tag")] | length == 4 and all(.[]; .repo == "wodby/backup" and (.version == "2.3.3" or .version == "2.3.4"))' "${IMAGES_UPDATE_REPORT_FILE}" >/dev/null
echo 'Backup parent revision, digest-only rebuild and atomic publication tests passed'
