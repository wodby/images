#!/usr/bin/env bash

set -e

. lib.sh

versions=(7.4 7.3 7.2 7.1 6.6 5.5 5.4)

user="${GITHUB_MACHINE_USER}"
token="${GITHUB_MACHINE_USER_API_TOKEN}"

git clone --depth=1 "https://${user}:${token}@github.com/wodby/solr" /tmp/solr
cd /tmp/solr

for version in "${versions[@]}"; do
    tags=($(get_tags "solr" | grep -oP "^(${version/./\.}\.[0-9]+)(?=\-alpine$)" | sort -rV))
    latest_ver="${tags[0]}"

    cur_ver=$(grep -oP "(?<=SOLR_VER=)(${version}\.[0-9]+)" .travis.yml)

    validate_versions "${version}" "${cur_ver}" "${latest_ver}"

    if [[ "${cur_ver}" != "${latest_ver}" ]]; then
        echo "Solr ${cur_ver} is outdated, updating to ${latest_ver}"
        sed -i -E "s/(SOLR_VER)=${version}\.[0-9]+/\1=${latest_ver}/" .travis.yml

        # Update Makefiles.
        sed -i -E "s/(SOLR_VER \?= )${cur_ver}/\1${latest_ver}/" Makefile

        git_commit ./ "Updating Solr to ${latest_ver}"
        git push origin
    fi
done
