#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/mysql-updater-test.XXXXXX")"

cleanup() {
  rm -rf "${test_root}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "${test_root}/images"
cp "${repo_root}/images/mysql.sh" "${test_root}/images/mysql.sh"

cat >"${test_root}/update.sh" <<'EOF'
_git_clone() {
  printf 'clone:%s\n' "$1" >>"${TRACE}"
}

_require_base_image_pins() { return 0; }

_update_versions() {
  printf 'versions:%s:%s:%s\n' "$1" "$2" "$3" >>"${TRACE}"
}

_update_digests() {
  printf 'digests:%s:%s:%s\n' "$1" "$2" "$#" >>"${TRACE}"
}
EOF

export TRACE="${test_root}/trace"
(
  cd "${test_root}/images"
  ./mysql.sh
)

expected=$'clone:wodby/mysql\nversions:8.4:mysql:mysql\ndigests:8.4:mysql:2'
actual="$(cat "${TRACE}")"
[[ "${actual}" == "${expected}" ]] || fail "unexpected updater calls: ${actual}"

echo "mysql updater tests passed"
