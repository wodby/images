#!/usr/bin/env bash

set -e

. lib.sh

versions=(4.0 3.2)

user="${GITHUB_MACHINE_USER}"
token="${GITHUB_MACHINE_USER_API_TOKEN}"

git clone --depth=1 "https://${user}:${token}@github.com/wodby/redis" /tmp/redis
cd /tmp/redis

for version in "${versions[@]}"; do
    tags=($(get_tags "redis" | grep -oP "^(${version/./\.}\.[0-9]+)(?=\-alpine$)" | sort -rV))
    latest_ver="${tags[0]}"

    cur_ver=$(grep -oP "(?<=REDIS_VER=)(${version}\.[0-9]+)" .travis.yml)

    validate_versions "${version}" "${cur_ver}" "${latest_ver}"

    if [[ "${cur_ver}" != "${latest_ver}" ]]; then
        echo "Redis ${cur_ver} is outdated, updating to ${latest_ver}"
        sed -i -E "s/(REDIS_VER)=${version}\.[0-9]+/\1=${latest_ver}/" .travis.yml

        # Update Makefiles.
        sed -i -E "s/(REDIS_VER \?= )${cur_ver}/\1${latest_ver}/" Makefile

        git_commit ./ "Updating Redis to ${latest_ver}"
        git push origin
    fi
done
