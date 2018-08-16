#!/usr/bin/env bash

set -e

. lib.sh

versions=(10.3 10.2 10.1)

user="${GITHUB_MACHINE_USER}"
token="${GITHUB_MACHINE_USER_API_TOKEN}"

git clone --depth=1 "https://${user}:${token}@github.com/wodby/mariadb" /tmp/mariadb
cd /tmp/mariadb

for version in "${versions[@]}"; do
    tags=($(get_tags "mariadb" | grep -oP "^(${version/\./\\.}\.[0-9]+)$" | sort -rV))
    latest_ver="${tags[0]}"

    cur_ver=$(grep -oP "(?<=MARIADB_VER: )(${version}\.[0-9]+)" .circleci/config.yml)

    validate_versions "${version}" "${cur_ver}" "${latest_ver}"

    if [[ $(compare_semver "${latest_ver}" "${cur_ver}") == 0 ]]; then
        echo "MariaDB ${cur_ver} is outdated, updating to ${latest_ver}"
        sed -i -E "s/(MARIADB_VER): ${version}\.[0-9]+/\1: ${latest_ver}/" .circleci/config.yml

        # Update Makefiles.
        [[ "${version}" =~ ^([0-9]+) ]] && major_ver="${BASH_REMATCH[1]}"
        sed -i -E "s/(MARIADB_VER \?= )${cur_ver}/\1${latest_ver}/" "${major_ver}/Makefile"

        git_commit ./ "Updating MariaDB to ${latest_ver}"
        git push origin
    fi
done
