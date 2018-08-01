#!/usr/bin/env bash

set -e

. lib.sh

versions=(7.2 7.1 7.0 5.6)

git clone --depth=1 "https://${GITHUB_MACHINE_USER}:${GITHUB_MACHINE_USER_API_TOKEN}@github.com/wodby/php" /tmp/php
cd /tmp/php

for version in "${versions[@]}"; do
    tags=($(get_tags "wodby/base-php" | grep -v debug | grep -F "${version}." | sort -rV))

    cur_ver=$(grep -oP "(?<=PHP${version//.}=)(.+)" .travis.yml)
    latest_ver="${tags[0]}"

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
