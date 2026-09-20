#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${repo_root}/update.sh"
test_root=$(mktemp -d)
trap 'rm -rf "${test_root}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$1', got '$2'"; }

# Exercise actual Git commits and atomic pushes against disposable local repos.
export GIT_CONFIG_GLOBAL="${test_root}/gitconfig"
cd "${test_root}"
git config --global user.name 'Updater tests'
git config --global user.email tests@wodby.invalid
git config --global commit.gpgsign false
git config --global tag.gpgsign false
export IMAGES_UPDATE_PUSH=1
export IMAGES_UPDATE_REPORT_FILE="${test_root}/events.jsonl"
export IMAGES_REPO_ROOT
export TEST_BASE_DIGEST="sha256:$(printf '%064d' 2)"

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

# Use the real pin editor, with registry resolution supplied by the fixture.
_base_image_pins() {
  python3 - "$@" <<'PY'
import os, sys
sys.path.insert(0, os.environ['IMAGES_REPO_ROOT'] + '/scripts')
from base_images import BaseImages
pins = BaseImages('base-images.mk')
if sys.argv[1] == 'repository':
    print(pins.repository)
else:
    def resolve(repository, tag):
        assert (repository, tag) == ('wodby/alpine', 'latest')
        if os.environ.get('FAIL_LOOKUP') == '1':
            raise ValueError('Registry lookup failed')
        return os.environ['TEST_BASE_DIGEST']
    for old, new in pins.update('refresh', resolver=resolve):
        print(f'{old} -> {new}')
PY
}

for branch in master main; do
  seed="${test_root}/seed-${branch}"
  origin="${test_root}/origin-${branch}.git"
  git init -q -b "${branch}" "${seed}"
  cd "${seed}"
  printf 'BASE_IMAGE_REPOSITORY := wodby/alpine\nBASE_IMAGE_VERSION_SUFFIX :=\nBASE_IMAGE_DIGEST_latest := sha256:%064d\n' 1 > base-images.mk
  git add base-images.mk
  git commit -qm 'Initial base pin'
  git tag -am 'Current product release' 2.3.2
  git commit --allow-empty -qm 'Image revision migration'
  git tag -am 'Retained image revision' r0
  git clone -q --bare "${seed}" "${origin}"
  original_r0=$(git rev-parse r0)

  update_backup
  released=$(git rev-parse HEAD)
  assert_eq "${released}" "$(git --git-dir="${origin}" rev-parse "${branch}")"
  assert_eq "${released}" "$(git --git-dir="${origin}" rev-parse '2.3.3^{commit}')"
  assert_eq tag "$(git cat-file -t 2.3.3)"
  assert_eq "${original_r0}" "$(git rev-parse r0)"
  assert_eq 'Refresh Backup base image' "$(git for-each-ref --format='%(contents:subject)' refs/tags/2.3.3)"
  git for-each-ref --format='%(contents:body)' refs/tags/2.3.3 | grep -Fq "${TEST_BASE_DIGEST}"

  # An unchanged base or documentation-only commit must not release again.
  update_backup
  assert_eq "${released}" "$(git rev-parse HEAD)"
  echo 'Backup documentation' > README.md
  git add README.md
  git commit -qm 'Document usage'
  git push -q origin "${branch}"
  documented=$(git rev-parse HEAD)
  update_backup
  assert_eq "${documented}" "$(git rev-parse HEAD)"
  assert_eq $'2.3.2\n2.3.3\nr0' "$(git tag --list)"

  # Preview mode can resolve changes but must not push or create release tags.
  export TEST_BASE_DIGEST="sha256:$(printf '%064d' 3)"
  (
    export IMAGES_UPDATE_PUSH=0
    update_backup
    assert_eq $'2.3.2\n2.3.3\nr0' "$(git tag --list)"
    assert_eq "${documented}" "$(git --git-dir="${origin}" rev-parse "${branch}")"
  )

  # Resolution errors leave both repository and tag state unchanged.
  (
    export FAIL_LOOKUP=1
    if update_backup; then fail 'registry failure ignored'; fi
    [[ -z "$(git status --porcelain)" ]] || fail 'lookup failure modified files'
    assert_eq "${documented}" "$(git --git-dir="${origin}" rev-parse "${branch}")"
  )

  # A failed commit must not be hidden by a conditional call or tag old content.
  (
    export FAIL_COMMIT=1
    if update_backup; then fail 'commit failure ignored'; fi
    [[ -z "$(git tag --list 2.3.4)" ]] || fail 'commit failure created a tag'
    assert_eq "${documented}" "$(git --git-dir="${origin}" rev-parse "${branch}")"
  )

  # Reject a release tag remotely: atomic push must also reject the pin commit.
  cat > "${origin}/hooks/update" <<'HOOK'
#!/bin/sh
case "$1" in refs/tags/*) exit 1 ;; esac
HOOK
  chmod +x "${origin}/hooks/update"
  if update_backup; then fail 'failed tag push ignored'; fi
  assert_eq "${documented}" "$(git --git-dir="${origin}" rev-parse "${branch}")"
  [[ -z "$(git --git-dir="${origin}" tag --list 2.3.4)" ]] || fail 'failed push published tag'
  rm "${origin}/hooks/update"

  # A fresh retry publishes the same next version, followed by an idempotent run.
  update_backup
  assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="${origin}" rev-parse '2.3.4^{commit}')"
  update_backup
  assert_eq $'2.3.2\n2.3.3\n2.3.4\nr0' "$(git tag --list)"
  export TEST_BASE_DIGEST="sha256:$(printf '%064d' 2)"
done

jq -se 'length == 4 and all(.[]; .type == "release_tag" and .repo == "wodby/backup" and (.version == "2.3.3" or .version == "2.3.4"))' "${IMAGES_UPDATE_REPORT_FILE}" >/dev/null
echo 'Backup updater tests passed'
