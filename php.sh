#!/usr/bin/env bash

set -e

. lib.sh

versions=(7.2 7.1 7.0 5.6)

user="${GITHUB_MACHINE_USER}"
token="${GITHUB_MACHINE_USER_API_TOKEN}"

git clone --depth=1 "https://${user}:${token}@github.com/wodby/php" /tmp/php
cd /tmp/php

for version in "${versions[@]}"; do
    tags=($(get_tags "wodby/base-php" | grep -oP "^(${version/./\.}\.[0-9]+)$" | sort -rV))
    latest_ver="${tags[0]}"

    cur_ver=$(grep -oP "(?<=PHP${version//.}=)(.+)" .travis.yml)

    validate_versions "${version}" "${cur_ver}" "${latest_ver}"

    if [[ "${cur_ver}" != "${latest_ver}" ]]; then
        echo "PHP ${cur_ver} is outdated, updating to ${latest_ver}"
        sed -i -E "s/(PHP${version//.})=.+/\1=${latest_ver}/" .travis.yml

        # Update Makefiles.
        if [[ -f "${version}/Makefile" ]]; then
            sed -i -E "s/(PHP_VER \?= )${cur_ver}/\1${latest_ver}/" "${version}/Makefile"
        fi

        [[ "${version}" =~ ^([0-9]+) ]] && major_ver="${BASH_REMATCH[1]}"

        if [[ -f "${major_ver}/Makefile" ]]; then
            sed -i -E "s/(PHP_VER ?= )${cur_ver}/\1${latest_ver}/" "${major_ver}/Makefile"
        fi

        git_commit ./ "Updating PHP to ${latest_ver}"
        git push origin
    fi
done
