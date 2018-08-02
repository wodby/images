#!/usr/bin/env bash

set -e

. lib.sh

versions=(2.4)

user="${GITHUB_MACHINE_USER}"
token="${GITHUB_MACHINE_USER_API_TOKEN}"

git clone --depth=1 "https://${user}:${token}@github.com/wodby/apache" /tmp/apache
cd /tmp/apache

for version in "${versions[@]}"; do
    tags=($(get_tags "wodby/httpd" | grep -F "${version}." | sort -rV))
    latest_ver="${tags[0]}"

    cur_ver=$(grep -oP "(?<=APACHE_VER=)(${version}\.[0-9]+)" .travis.yml)

    validate_versions "${version}" "${cur_ver}" "${latest_ver}"

    if [[ "${cur_ver}" != "${latest_ver}" ]]; then
        echo "Apache ${cur_ver} is outdated, updating to ${latest_ver}"
        sed -i -E "s/(APACHE_VER)=${version}\.[0-9]+/\1=${latest_ver}/" .travis.yml

        # Update Makefiles.
        sed -i -E "s/(APACHE_VER \?= )${cur_ver}/\1${latest_ver}/" Makefile

        git_commit ./ "Updating Apache to ${latest_ver}"
        git push origin
    fi
done
