#!/usr/bin/env bash

set -e

. lib.sh

versions=(2.5 2.4 2.3)

user="${GITHUB_MACHINE_USER}"
token="${GITHUB_MACHINE_USER_API_TOKEN}"
repo="wodby/base-ruby"

git clone --depth=1 "https://${user}:${token}@github.com/wodby/ruby" /tmp/ruby
cd /tmp/ruby

for version in "${versions[@]}"; do
    tags=($(get_tags "${repo}" | grep -oP "^(${version/./\.}\.[0-9]+)$" | sort -rV))
    latest_ver="${tags[0]}"

    cur_ver=$(grep -oP "(?<=RUBY${version//.}=)(.+)" .travis.yml)

    validate_versions "${version}" "${cur_ver}" "${latest_ver}"
    latest_timestamp=$(get_timestamp "${repo}" "${cur_ver}")

    if [[ $(compare_semver "${latest_ver}" "${cur_ver}") == 0 ]]; then
        echo "Ruby ${cur_ver} is outdated, updating to ${latest_ver}"
        sed -i -E "s/(RUBY${version//.})=.+/\1=${latest_ver}/" .travis.yml
        sed -i -E "s/(RUBY_VER \?= )${cur_ver}/\1${latest_ver}/" Makefile
        sed -i "s/${cur_ver}#.*/${latest_ver}#${latest_timestamp}/" .base-ruby

        git_commit ./ "Updating Ruby to ${latest_ver}"
    else
        cur_timestamp=$(grep -oP "(?<=^${cur_ver/./\.}#)(.+)$" .base-ruby)

        if [[ "${cur_timestamp}" != "${latest_timestamp}" ]]; then
            echo "Base image has been updated. Triggering rebuild."
            sed -i "s/${cur_timestamp}/${latest_timestamp}/" .base-ruby
            git_commit ./ "Update base image updated timestamp"
        fi
    fi

    git push origin
done
