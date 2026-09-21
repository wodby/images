#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root=$(mktemp -d)
trap 'rm -rf "${test_root}"' EXIT
mkdir "${test_root}/bin"
cat > "${test_root}/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "${CALL_LOG}"
case "$1" in
  login) cat >/dev/null ;;
  logout) ;;
  pull)
    n=$(cat "${PULL_COUNT}" 2>/dev/null || echo 0)
    n=$((n+1)); echo "$n" > "${PULL_COUNT}"
    if ((n <= FAIL_PULLS)); then echo >&2 'registry connection reset'; exit 17; fi
    echo 'sha256:updater'
    ;;
  run)
    # The PR publishing guard must reach the updater container unchanged.
    [[ "$*" == *' -e IMAGES_UPDATE_PUSH '* && "${IMAGES_UPDATE_PUSH:-}" == 0 ]] || exit 99
    exit "${RUN_STATUS}"
    ;;
  *) exit 99 ;;
esac
DOCKER
cat > "${test_root}/bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
printf 'sleep %s\n' "$1" >> "${CALL_LOG}"
SLEEP
chmod +x "${test_root}/bin/"*
export PATH="${test_root}/bin:${PATH}"
export CALL_LOG="${test_root}/calls" PULL_COUNT="${test_root}/pulls"
export DOCKER_USERNAME=test DOCKER_PASSWORD=test-password DEBUG='' IMAGES_UPDATE_PUSH=0
export dir=descendants script=wordpress-php report_file=reports/events.jsonl

# Exercise the actual action runner; no registry or updater mutations occur.
check_case() {
  export FAIL_PULLS="$1" RUN_STATUS="$2"
  local expected_status="$3" pulls="$4" runs="$5" status
  rm -f "${CALL_LOG}" "${PULL_COUNT}"
  if bash "${repo_root}/.github/actions/run.sh" >"${test_root}/stdout" 2>"${test_root}/stderr"; then
    status=0
  else
    status=$?
  fi
  [[ "$status" == "$expected_status" ]]
  [[ "$(grep -c '^pull --quiet ' "${CALL_LOG}" || true)" == "$pulls" ]]
  [[ "$(grep -c '^run --pull=never ' "${CALL_LOG}" || true)" == "$runs" ]]
  [[ "$(grep -c '^logout$' "${CALL_LOG}")" == 1 ]]
  ! grep -q 'test-password' "${test_root}/stdout" "${test_root}/stderr"
  ! grep -q '^+' "${test_root}/stderr"
}
check_case 0 0 0 1 1
if grep -q -- 'BUILDX_CONFIG=' "$CALL_LOG"; then
  echo >&2 'Buildx state override leaked into another updater'
  exit 1
fi
! grep -q '^sleep ' "${CALL_LOG}"
check_case 2 0 0 3 1
[[ "$(grep -c '^sleep ' "${CALL_LOG}")" == 2 ]]
check_case 3 0 1 3 0
grep -q 'Failed to pull updater image after 3 attempts' "${test_root}/stderr"
check_case 0 42 42 1 1
! grep -q '^sleep ' "${CALL_LOG}"
export dir=images script=alpine
check_case 0 0 0 1 1
grep -q -- '-e DOCKER_CONFIG=/registry-auth' "$CALL_LOG"
# Manifest inspection must not create Buildx state inside the read-only auth mount.
grep -q -- '-e BUILDX_CONFIG=/tmp/buildx' "$CALL_LOG"
grep -q -- ':/registry-auth:ro' "$CALL_LOG"
echo 'Action runner retry, registry authentication and logging tests passed'
