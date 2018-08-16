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

update_timestamps "${versions}" "${base_image}"
update_stability_tag "${version}" "${base_image}" "${branch}"