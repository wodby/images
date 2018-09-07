#!/usr/bin/env bash

set -e

. ../lib.sh

image="${1}"
versions="${2}"
branch="${3}"

git_clone "${image}"

upstream=$(get_base_image)

if [[ -f ".${upstream#*/}" ]]; then
    echo "ERROR: Missing .${upstream#*/} file!"
    exit 1
fi

IFS=' ' read -r -a array <<< "${versions}"

ver="${array[0]}"

update_timestamps "${versions}" "${upstream}"
update_stability_tag "${ver}" "${upstream}" "${branch}"
