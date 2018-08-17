#!/usr/bin/env bash

set -e

. lib.sh

user="${GITHUB_MACHINE_USER}"
token="${GITHUB_MACHINE_USER_API_TOKEN}"

image=$1
versions=$2
# Some images have [version].x branches with base image stability tags.
branch=$3
# May be a docker image different from base image or github repo.
upstream=$4
# When we need to update lang version for vanilla image, e.g. update PHP for vanilla drupal
# vanilla version dir doesn't match lang version, so we should specify a concrete directory.
subdir=$5

IFS=' ' read -r -a array <<< "${versions}"

git clone "https://${user}:${token}@github.com/${image}" "/tmp/${image#*/}"
cd "/tmp/${image#*/}"

version="${array[0]}"

if [[ -z "${upstream}" ]]; then
    upstream=$(get_base_image)
fi

# Those with branches update via stability tags.
if [[ -z "${branch}" ]]; then
    update_versions "${versions}" "${upstream}" "${image#*/}" "${subdir}"
fi

# For docker images upstreams only.
if [[ -f ".${upstream#*/}" ]]; then
    update_timestamps "${versions}" "${upstream}"

    if [[ -n "${branch}" ]]; then
        update_stability_tag "${version}" "${upstream}" "${branch}"
    fi
fi
