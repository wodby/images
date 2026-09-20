#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$root/update.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
export GIT_CONFIG_GLOBAL="$scratch/gitconfig"
git config --global user.name Test
git config --global user.email test@example.invalid
git config --global commit.gpgsign false
git config --global tag.gpgsign false
export IMAGES_UPDATE_PUSH=1
export IMAGES_UPDATE_REPORT_FILE="$scratch/events.jsonl"
# Model scanner outcomes while exercising real Git, annotated tags and atomic pushes.
python3() {
  local output="${@: -1}"
  if [[ "$SCAN_RESULT" == failure ]]; then return 2; fi
  if [[ "$SCAN_RESULT" == none ]]; then
    printf '%s\n' '{"reason":"No security fixes"}' > "$output"
  else
    printf '%s\n' '{"schema":1,"release":"r1","notes":"Alpine package security updates\n\n- Alpine 3.24: openssl 1.0-r0 -> 1.0-r1; fixes CVE-2026-1234"}' > "$output"
  fi
}
for mode in none failure fixed push-failure disabled; do
  origin="$scratch/$mode.git"
  git init -q --bare "$origin"
  git clone -q "$origin" "$scratch/$mode"
  cd "$scratch/$mode"
  printf 'revision\n' > .image-release-format
  printf '1\n' > .image-security-updates
  git add .
  git commit -qm 'Fixture'
  git tag -am 'First release' r0
  git push -q origin HEAD --tags
  initial=$(git rev-parse HEAD)
  SCAN_RESULT="$mode"
  if [[ "$mode" == push-failure ]]; then
    cat > "$origin/hooks/pre-receive" <<'HOOK'
#!/bin/sh
exit 1
HOOK
    chmod +x "$origin/hooks/pre-receive"
  fi
  if [[ "$mode" == disabled ]]; then IMAGES_UPDATE_PUSH=0; fi
  if update_alpine_security; then status=0; else status=$?; fi
  IMAGES_UPDATE_PUSH=1
  case "$mode" in
    fixed)
      [[ "$status" == 0 ]]
      [[ "$(git cat-file -t r1)" == tag ]]
      git for-each-ref --format='%(contents)' refs/tags/r1 | grep -q 'CVE-2026-1234'
      [[ "$(git diff --name-only HEAD^ HEAD)" == .image-security-release.json ]]
      [[ "$(git --git-dir="$origin" rev-parse r1^{commit})" == "$(git rev-parse HEAD)" ]]
      # A retry with no new fixes creates no additional commit or revision.
      released=$(git rev-parse HEAD)
      SCAN_RESULT=none
      update_alpine_security
      [[ "$(git rev-parse HEAD)" == "$released" ]]
      [[ "$(git tag --list 'r*' | wc -l | tr -d ' ')" == 2 ]]
      ;;
    push-failure)
      [[ "$status" != 0 ]]
      [[ "$(git --git-dir="$origin" rev-parse refs/heads/$(git branch --show-current))" == "$initial" ]]
      ! git --git-dir="$origin" show-ref --verify --quiet refs/tags/r1
      ;;
    failure) [[ "$status" != 0 && "$(git rev-parse HEAD)" == "$initial" ]] ;;
    none|disabled) [[ "$status" == 0 && "$(git rev-parse HEAD)" == "$initial" ]] ;;
  esac
done
echo 'Alpine security updater atomic-publication and retry tests passed'
