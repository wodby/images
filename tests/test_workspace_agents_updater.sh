#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${repo_root}/update.sh"
test_root=$(mktemp -d)
trap 'rm -rf "${test_root}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$1', got '$2'"; }

# Real commits, tags and atomic pushes; only the repository's pinning script is a fixture.
export GIT_CONFIG_GLOBAL="${test_root}/gitconfig"
cd "${test_root}"
git config --global user.name 'Updater tests'
git config --global user.email tests@wodby.invalid
git config --global commit.gpgsign false
git config --global tag.gpgsign false
export IMAGES_UPDATE_PUSH=1 WODBOT_GITHUB_PAT=fixture-token
export IMAGES_UPDATE_REPORT_FILE="${test_root}/events.jsonl"

seed="${test_root}/seed"
origin="${test_root}/origin.git"

_git_clone() {
  assert_eq wodby/workspace-agents "$1"
  local checkout
  checkout=$(mktemp -d "${test_root}/checkout.XXXXXX")
  git clone -q "${origin}" "${checkout}" || return 1
  cd "${checkout}"
}

origin_tags() { git --git-dir="${origin}" tag --list | tr '\n' ' '; }
origin_master() { git --git-dir="${origin}" rev-parse master; }

git init -q -b master "${seed}"
cd "${seed}"
mkdir scripts
# Pins the versions and checksum given in the environment, like the real script.
cat > scripts/update.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[[ "${FAIL_UPDATE:-0}" != 1 ]] || exit 1
[[ "${GITHUB_TOKEN:-}" == fixture-token ]] || { echo >&2 'missing GitHub token'; exit 1; }
printf 'CLAUDE_CODE_VERSION=%s\nCODEX_VERSION=%s\nOPENCODE_VERSION=1.18.32\nRIPGREP_VERSION=15.2.0\n' \
  "${CLAUDE:-2.1.274}" "${CODEX:-0.157.1}" > versions.env
printf '%064d  codex-package-%s\n' "${CHECKSUM:-1}" "${CODEX:-0.157.1}" > checksums.txt
SCRIPT
chmod +x scripts/update.sh
CLAUDE=2.1.274 CODEX=0.157.1 GITHUB_TOKEN=fixture-token scripts/update.sh
git add .
git commit -qm 'Initial pins'
git clone -q --bare "${seed}" "${origin}"
initial=$(origin_master)

# Until the first release is tagged by hand, the updater only asks for it.
(update_workspace_agents)
assert_eq "${initial}" "$(origin_master)"
assert_eq '' "$(origin_tags)"
jq -e 'select(.type == "manual_review" and .message == "Waiting for the first workspace agents release")' \
  "${IMAGES_UPDATE_REPORT_FILE}" >/dev/null || fail 'missing first-release event'
git -C "${seed}" tag -am 'First release' 1.0.0
git -C "${seed}" push -q "${origin}" 1.0.0

# Current pins change nothing.
(update_workspace_agents)
assert_eq "${initial}" "$(origin_master)"
assert_eq '1.0.0 ' "$(origin_tags)"

# A new tool release is one patch release: the pin commit and its annotated tag.
(export CODEX=0.158.0 CHECKSUM=2; update_workspace_agents)
released=$(origin_master)
[[ "${released}" != "${initial}" ]] || fail 'pins were not pushed'
assert_eq tag "$(git --git-dir="${origin}" cat-file -t 1.0.1)"
assert_eq "${released}" "$(git --git-dir="${origin}" rev-parse '1.0.1^{commit}')"
git --git-dir="${origin}" show master:versions.env | grep -qx 'CODEX_VERSION=0.158.0' || fail 'Codex not pinned'
assert_eq 'Update Codex' "$(git --git-dir="${origin}" for-each-ref --format='%(contents:subject)' refs/tags/1.0.1)"
notes=$(git --git-dir="${origin}" for-each-ref --format='%(contents:body)' refs/tags/1.0.1)
[[ "${notes}" == *'Changes since 1.0.0'* ]] || fail 'missing previous release'
[[ "${notes}" == *'- Codex: 0.157.1 -> 0.158.0.'* ]] || fail 'missing Codex change'
[[ "${notes}" == *'compare/1.0.0...1.0.1'* ]] || fail 'missing compare link'
[[ "${notes}" != *'Claude Code'* ]] || fail 'unchanged tool listed'
assert_eq "Update Codex" "$(git --git-dir="${origin}" log -1 --format=%s master)"
jq -e 'select(.type == "release_tag" and .version == "1.0.1")' "${IMAGES_UPDATE_REPORT_FILE}" >/dev/null \
  || fail 'missing release event'
(export CODEX=0.158.0 CHECKSUM=2; update_workspace_agents)
assert_eq "${released}" "$(origin_master)"

# Several tools in one release are listed together.
(export CLAUDE=2.1.290 CODEX=0.159.0 CHECKSUM=3; update_workspace_agents)
assert_eq 'Update Claude Code and Codex' \
  "$(git --git-dir="${origin}" for-each-ref --format='%(contents:subject)' refs/tags/1.0.2)"
released=$(origin_master)
export CLAUDE=2.1.290 CODEX=0.159.0

# A replaced upstream asset changes a checksum without a version: stop for review.
if (export CHECKSUM=4; update_workspace_agents); then fail 'changed checksum accepted'; fi
jq -e 'select(.type == "manual_review" and (.message | test("checksums changed")))' "${IMAGES_UPDATE_REPORT_FILE}" \
  >/dev/null || fail 'missing checksum event'

# Validation runs, pinning failures and rejected tags publish nothing.
(export IMAGES_UPDATE_PUSH=0 CODEX=0.160.0 CHECKSUM=5; update_workspace_agents)
if (export FAIL_UPDATE=1 CODEX=0.160.0; update_workspace_agents); then fail 'pinning failure ignored'; fi
cat > "${origin}/hooks/update" <<'HOOK'
#!/bin/sh
case "$1" in refs/tags/*) exit 1 ;; esac
HOOK
chmod +x "${origin}/hooks/update"
if (export CODEX=0.160.0 CHECKSUM=5; update_workspace_agents 2>/dev/null); then fail 'rejected tag ignored'; fi
assert_eq "${released}" "$(origin_master)"
assert_eq '1.0.0 1.0.1 1.0.2 ' "$(origin_tags)"

echo "Workspace agents updater tests passed"
