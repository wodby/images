#!/usr/bin/env bash

set -e

. lib.sh

# http://www.databasesoup.com/2016/05/changing-postgresql-version-numbering.html
versions=(10 9.6 9.5 9.4 9.3)

user="${GITHUB_MACHINE_USER}"
token="${GITHUB_MACHINE_USER_API_TOKEN}"
repo="postgres"

git clone --depth=1 "https://${user}:${token}@github.com/wodby/postgres" /tmp/postgres
cd /tmp/postgres

for version in "${versions[@]}"; do
    tags=($(get_tags "${repo}" | grep -oP "^(${version/\./\\.}\.[0-9]+)(?=\-alpine$)" | sort -rV))
    latest_ver="${tags[0]}"

    cur_ver=$(grep -oP "(?<=POSTGRES_VER=)(${version}\.[0-9]+)" .travis.yml)

    validate_versions "${version}" "${cur_ver}" "${latest_ver}"
    latest_timestamp=$(get_timestamp "${repo}" "${cur_ver}")

    if [[ $(compare_semver "${latest_ver}" "${cur_ver}") == 0 ]]; then
        echo "PostgreSQL ${cur_ver} is outdated, updating to ${latest_ver}"

        sed -i -E "s/(POSTGRES_VER)=${cur_ver}/\1=${latest_ver}/" .travis.yml
        sed -i -E "s/(POSTGRES_VER \?= )${cur_ver}/\1${latest_ver}/" Makefile
        sed -i "s/${cur_ver}#.*/${latest_ver}#${latest_timestamp}/" .postgres

        git_commit ./ "Updating PostgreSQL to ${latest_ver}"
    else
        cur_timestamp=$(grep -oP "(?<=^${cur_ver/./\.}#)(.+)$" .postgres)

        if [[ "${cur_timestamp}" != "${latest_timestamp}" ]]; then
            echo "Base image has been updated. Triggering rebuild."
            sed -i "s/${cur_timestamp}/${latest_timestamp}/" .postgres
            git_commit ./ "Update base image updated timestamp"
        fi
    fi

    git push origin
done
