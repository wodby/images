#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

. "${script_dir}/../update.sh"

boilerplate="${1:-}"

if [[ -z "${boilerplate}" ]]; then
  echo >&2 "Boilerplate name is required"
  exit 1
fi

set +e
(
  set -e
  update_boilerplate_dependencies "${boilerplate}"
)
status=$?
set -e

if [[ "${status}" != "0" ]]; then
  _boilerplate_update_failed "${boilerplate}" "${status}"
fi
