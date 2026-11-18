#!/usr/bin/env bash
# Exercise arch-image-push with a recording docker; no registry is contacted.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/.github/actions/arch-image-push/push.sh"
test_root=$(mktemp -d)
trap 'rm -rf "${test_root}"' EXIT
mkdir "${test_root}/bin"
cat > "${test_root}/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "${CALL_LOG}"
case "$1 ${2:-}" in
  'push '*)
    echo 'The push refers to repository [docker.io/wodby/mariadb]'
    echo '1b2c3d4e5f60: Pushed'
    if [[ -n "${PUSH_DIGEST}" ]]; then
      echo "${2##*:}: digest: ${PUSH_DIGEST} size: 2412"
    fi
    ;;
  'buildx imagetools') exit "${INSPECT_STATUS}" ;;
  *) exit 99 ;;
esac
DOCKER
chmod +x "${test_root}/bin/docker"
export PATH="${test_root}/bin:${PATH}" CALL_LOG="${test_root}/calls"
digest="sha256:$(printf 'a%.0s' {1..64})"

run_push() {
    : > "${CALL_LOG}"
    rm -rf "${test_root}/pins" "${test_root}/output"
    IMAGE="$1" RECORD_DIR="${test_root}/pins" GITHUB_OUTPUT="${test_root}/output" \
        bash "$script" > "${test_root}/stdout" 2>&1
}

# The record holds the pushed digest and is named after the shared tag.
PUSH_DIGEST="$digest" INSPECT_STATUS=0 run_push wodby/mariadb:11.4-amd64
test "$(cat "${test_root}/pins/wodby_mariadb_11.4-amd64")" = "wodby/mariadb@${digest}"
grep -qx "digest-ref=wodby/mariadb@${digest}" "${test_root}/output"
grep -qx "artifact=arch-image-pin-wodby_mariadb_11.4-amd64" "${test_root}/output"
grep -qx "buildx imagetools inspect wodby/mariadb@${digest}" "${CALL_LOG}"

# Without a digest from the push there is nothing safe to combine.
if PUSH_DIGEST='' INSPECT_STATUS=0 run_push wodby/mariadb:11.4-amd64; then
    echo 'missing push digest accepted' >&2; exit 1
fi
test ! -e "${test_root}/pins/wodby_mariadb_11.4-amd64"

# A digest the registry cannot serve is refused before it is recorded.
if PUSH_DIGEST="$digest" INSPECT_STATUS=1 run_push wodby/mariadb:11.4-amd64; then
    echo 'unavailable digest accepted' >&2; exit 1
fi
test ! -e "${test_root}/pins/wodby_mariadb_11.4-amd64"

# Digest references and malformed names are refused before any push.
for image in 'wodby/mariadb@sha256:abc' 'wodby/mariadb' 'wodby/mariadb:a b' '../x:1' 'wodby/mariadb:1;id'; do
    if PUSH_DIGEST="$digest" INSPECT_STATUS=0 run_push "$image"; then
        echo "invalid image accepted: $image" >&2; exit 1
    fi
    test ! -s "${CALL_LOG}"
done

# A Makefile lookup in the documented form resolves records and fails loudly.
cat > "${test_root}/Makefile" <<'MAKE'
REPO = wodby/mariadb
arch-image = $(if $(ARCH_IMAGE_PINS),$(or $(shell cat '$(ARCH_IMAGE_PINS)/$(subst :,_,$(subst /,_,$(1)))' 2>/dev/null),$(error No digest of $(1) was pushed by this workflow run)),$(1))
sources:
	@echo $(call arch-image,$(REPO):11.4-amd64) $(call arch-image,$(REPO):11.4-arm64)
MAKE
test "$(make -s -C "${test_root}" sources)" = 'wodby/mariadb:11.4-amd64 wodby/mariadb:11.4-arm64'
if make -s -C "${test_root}" sources ARCH_IMAGE_PINS="${test_root}/empty" 2>/dev/null; then
    echo 'missing record accepted' >&2; exit 1
fi
mkdir "${test_root}/both"
echo "wodby/mariadb@${digest}" > "${test_root}/both/wodby_mariadb_11.4-amd64"
echo "wodby/mariadb@sha256:$(printf 'b%.0s' {1..64})" > "${test_root}/both/wodby_mariadb_11.4-arm64"
test "$(make -s -C "${test_root}" sources ARCH_IMAGE_PINS="${test_root}/both")" = \
    "wodby/mariadb@${digest} wodby/mariadb@sha256:$(printf 'b%.0s' {1..64})"

echo 'arch-image-push tests passed'
