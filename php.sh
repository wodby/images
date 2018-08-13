#!/usr/bin/env bash

set -e

. lib.sh

versions=(7.2 7.1 7.0 5.6)

user="${GITHUB_MACHINE_USER}"
token="${GITHUB_MACHINE_USER_API_TOKEN}"
repo="wodby/base-php"

git clone --depth=1 "https://${user}:${token}@github.com/wodby/php" /tmp/php
cd /tmp/php

for version in "${versions[@]}"; do
    tags=($(get_tags "${repo}" | grep -oP "^(${version/\./\\.}\.[0-9]+)$" | sort -rV))
    latest_ver="${tags[0]}"

    cur_ver=$(grep -oP "(?<=PHP${version//.}=)(.+)" .travis.yml)

    validate_versions "${version}" "${cur_ver}" "${latest_ver}"
    latest_timestamp=$(get_timestamp "${repo}" "${cur_ver}")

    if [[ $(compare_semver "${latest_ver}" "${cur_ver}") == 0 ]]; then
        echo "PHP ${cur_ver} is outdated, updating to ${latest_ver}"

        if [[ -d "${version}" ]]; then
            dir="${version}"
        else
            dir="${version%%.*}"
        fi

        sed -i -E "s/(PHP${version//.})=.+/\1=${latest_ver}/" .travis.yml
        sed -i -E "s/(PHP_VER \?= )${cur_ver}/\1${latest_ver}/" "${dir}/Makefile"
        sed -i "s/${cur_ver}#.*/${latest_ver}#${latest_timestamp}/" .base-php

        git_commit ./ "Updating PHP to ${latest_ver}"
    else
        cur_timestamp=$(grep -oP "(?<=^${cur_ver/./\.}#)(.+)$" .base-php)

        if [[ "${cur_timestamp}" != "${latest_timestamp}" ]]; then
            echo "Base image has been updated. Triggering rebuild."
            sed -i "s/${cur_timestamp}/${latest_timestamp}/" .base-php
            git_commit ./ "Update base image updated timestamp"
        fi
    fi

    git push origin
done
