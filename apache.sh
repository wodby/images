#!/usr/bin/env bash

set -e

. lib.sh

versions=(2.4)

user="${GITHUB_MACHINE_USER}"
token="${GITHUB_MACHINE_USER_API_TOKEN}"
repo="wodby/httpd"

git clone --depth=1 "https://${user}:${token}@github.com/wodby/apache" /tmp/apache
cd /tmp/apache

for version in "${versions[@]}"; do
    tags=($(get_tags "${repo}" | grep -F "${version}." | sort -rV))
    latest_ver="${tags[0]}"

    cur_ver=$(grep -oP "(?<=APACHE_VER=)(${version}\.[0-9]+)" .travis.yml)

    validate_versions "${version}" "${cur_ver}" "${latest_ver}"
    latest_timestamp=$(get_timestamp "${repo}" "${cur_ver}")

    if [[ $(compare_semver "${latest_ver}" "${cur_ver}") == 0 ]]; then
        echo "Apache ${cur_ver} is outdated, updating to ${latest_ver}"

        sed -i -E "s/(APACHE_VER)=${version}\.[0-9]+/\1=${latest_ver}/" .travis.yml
        sed -i -E "s/(APACHE_VER \?= )${cur_ver}/\1${latest_ver}/" Makefile
        sed -i "s/${cur_ver}#.*/${latest_ver}#${latest_timestamp}/" .httpd

        git_commit ./ "Updating Apache to ${latest_ver}"
    else
        cur_timestamp=$(grep -oP "(?<=^${cur_ver/./\.}#)(.+)$" .httpd)

        if [[ "${cur_timestamp}" != "${latest_timestamp}" ]]; then
            echo "Base image has been updated. Triggering rebuild."
            sed -i "s/${cur_timestamp}/${latest_timestamp}/" .httpd
            git_commit ./ "Update base image updated timestamp"
        fi
    fi

    git push origin
done
