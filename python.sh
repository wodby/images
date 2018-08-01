#!/usr/bin/env bash

set -e

. lib.sh

versions=(3.7 3.6 3.5 3.4 2.7)

git clone --depth=1 "https://${GITHUB_MACHINE_USER}:${GITHUB_MACHINE_USER_API_TOKEN}@github.com/wodby/python" /tmp/python
cd /tmp/python

for version in "${versions[@]}"; do
    tags=($(get_tags "wodby/base-python" | grep -v debug | grep -F "${version}." | sort -rV))

    cur_ver=$(grep -oP "(?<=PYTHON${version//.}=)(.+)" .travis.yml)
    latest_ver="${tags[0]}"

    if [[ "${cur_ver}" != "${latest_ver}" ]]; then
        echo "Python ${cur_ver} is outdated, updating to ${latest_ver}"
        sed -i -E "s/(PYTHON${version//.})=.+/\1=${latest_ver}/" .travis.yml
        git_commit ./ "Updating Python to ${latest_ver}"
        git push origin
    fi
done
