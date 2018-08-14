#!/usr/bin/env bash

set -ex

. lib.sh

versions=(7.2 7.1 7.0 5.6 5.3)

user="${GITHUB_MACHINE_USER}"
token="${GITHUB_MACHINE_USER_API_TOKEN}"
repo="wodby/php"

git clone "https://${user}:${token}@github.com/wodby/drupal-php" /tmp/drupal-php
cd /tmp/drupal-php

for version in "${versions[@]}"; do
    latest_timestamp=$(get_timestamp "${repo}" "${version}")
    cur_timestamp=$(grep -oP "(?<=^${version/\./\\.}#)(.+)$" .php)

    if [[ "${cur_timestamp}" != "${latest_timestamp}" ]]; then
        echo "Base image has been updated. Triggering rebuild."
        sed -i "s/${cur_timestamp}/${latest_timestamp}/" .php
        git_commit ./ "Update base image updated timestamp"
    fi

    git push origin
done

# Updating stability tags
git checkout 4.x
git merge --no-edit master
tag=""

version="${versions[0]}"
tags=($(get_tags "${repo}" | grep -oP "(?<=${version/\./\\.}-)([0-9]\.){2}[0-9]$" | sort -rV))
latest_tag="${tags[0]}"

cur_tag=$(grep -oP "(?<=BASE_IMAGE_STABILITY_TAG=)([0-9]\.){2}[0-9]$" .travis.yml)

if [[ $(compare_semver "${latest_tag}" "${cur_tag}") == 0 ]]; then
    sed -i -E "s/(BASE_IMAGE_STABILITY_TAG=)${cur_tag}/\1${latest_tag}/" .travis.yml
    git_commit ./ "Update base image stability tag to ${latest_tag}"
    tag=1
fi

git push origin

if [[ -n "${tag}" ]]; then
    cur_tag=$(git describe --abbrev=0 --tags)
    patch_ver="${cur_tag##*.}"
    let "patch_ver++"
    new_tag="${cur_tag%.*}${patch_ver}"

    git tag -m "Base image updated to ${latest_tag}" "${new_tag}"
    git push origin "${new_tag}"
fi
