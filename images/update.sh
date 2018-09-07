#!/usr/bin/env bash

set -e

. ../lib.sh

image="${1}"
versions="${2}"

git_clone "${image}"

upstream=$(get_base_image)

if [[ -f ".${upstream#*/}" ]]; then
    echo "ERROR: Missing .${upstream#*/} file!"
    exit 1
fi

update_versions "${versions}" "${upstream}" "${image#*/}"
update_timestamps "${versions}" "${upstream}"
