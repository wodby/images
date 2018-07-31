#!/usr/bin/env bash

set -e

. lib.sh

apk add --update git grep

versions=(7.2 7.1 7.0 5.6)

git clone --depth=1 "https://${GITHUB_MACHINE_USER}:${GITHUB_MACHINE_USER_API_TOKEN}@github.com/wodby/php" /tmp/php
cd /tmp/php

for version in "${versions[@]}"; do
    tags=($(get_tags "wodby/base-php" | grep -v debug | grep -F "${version}." | sort -r))

    cur_ver=$(grep -oP "(?<=PHP${version//.}=)(.+)" .travis.yml)
    latest_ver="${tags[0]}"

    if [[ "${cur_ver}" != "${latest_ver}" ]]; then
        sed -i -E "s/(PHP${version//.})=.+/\1=${latest_ver}/" .travis.yml
        git_commit ./ "Update PHP to: ${latest_ver}"
        git push origin
    fi;
done
