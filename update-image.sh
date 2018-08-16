#!/usr/bin/env bash

set -e

. lib.sh

user="${GITHUB_MACHINE_USER}"
token="${GITHUB_MACHINE_USER_API_TOKEN}"

image=$1
versions=$2
branch=$3

git clone "https://${user}:${token}@github.com/${image}" "/tmp/${image#*/}"
cd "/tmp/${image#*/}"

version="${versions[0]}"

if [[ -f Dockerfile ]]; then
    dir="."
elif [[ -d "${version}" ]]; then
    dir="${version}"
else
    dir="${version%%.*}"
fi

base_image=$(grep -oP "(?<=FROM ).+(?=:)" "${dir}/Dockerfile")

if [[ -z "${branch}" ]]; then
    alpine=""

    if grep -P "BASE_IMAGE_TAG.+?-alpine" "${dir}/Makefile"; then
        alpine=1
    fi

    update_versions "${image}" "${versions}" "${base_image}" "${dir}" "${alpine}"
fi

if [[ -f ".${base_image#*/}" ]]; then
    update_timestamps "${versions}" "${base_image}"

    if [[ -n "${branch}" ]]; then
        update_stability_tag "${version}" "${base_image}" "${branch}"
    fi
fi
