#!/usr/bin/env bash

set -e

. lib.sh

versions=(2.5 2.4 2.3)

user="${GITHUB_MACHINE_USER}"
token="${GITHUB_MACHINE_USER_API_TOKEN}"

git clone --depth=1 "https://${user}:${token}@github.com/wodby/ruby" /tmp/ruby
cd /tmp/ruby

for version in "${versions[@]}"; do
    tags=($(get_tags "wodby/base-ruby" | grep -oP "^(${version/./\.}\.[0-9]+)$" | sort -rV))
    latest_ver="${tags[0]}"

    cur_ver=$(grep -oP "(?<=RUBY${version//.}=)(.+)" .travis.yml)

    validate_versions "${version}" "${cur_ver}" "${latest_ver}"

    if [[ "${cur_ver}" != "${latest_ver}" ]]; then
        echo "Ruby ${cur_ver} is outdated, updating to ${latest_ver}"
        sed -i -E "s/(RUBY${version//.})=.+/\1=${latest_ver}/" .travis.yml

        # Update Makefiles.
        sed -i -E "s/(RUBY_VER \?= )${cur_ver}/\1${latest_ver}/" Makefile

        git_commit ./ "Updating Ruby to ${latest_ver}"
        git push origin
    fi
done
