#!/usr/bin/env bash

set -e

. lib.sh

versions=(3.7 3.6 3.5 3.4 2.7)

user="${GITHUB_MACHINE_USER}"
token="${GITHUB_MACHINE_USER_API_TOKEN}"

git clone --depth=1 "https://${user}:${token}@github.com/wodby/python" /tmp/python
cd /tmp/python

for version in "${versions[@]}"; do
    tags=($(get_tags "wodby/base-python" | grep -oP "^(${version/./\.}\.[0-9]+)$" | sort -rV))
    latest_ver="${tags[0]}"

    cur_ver=$(grep -oP "(?<=PYTHON${version//.}=)(.+)" .travis.yml)

    validate_versions "${version}" "${cur_ver}" "${latest_ver}"

    if [[ "${cur_ver}" != "${latest_ver}" ]]; then
        echo "Python ${cur_ver} is outdated, updating to ${latest_ver}"
        sed -i -E "s/(PYTHON${version//.})=.+/\1=${latest_ver}/" .travis.yml

        # Update Makefiles.
        sed -i -E "s/(PYTHON_VER \?= )${cur_ver}/\1${latest_ver}/" Makefile

        git_commit ./ "Updating Python to ${latest_ver}"
        git push origin
    fi
done
