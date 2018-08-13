#!/usr/bin/env bash

set -e

git_commit()
{
    local dir="${1}"
    local msg="${2}"

    cd "${dir}"
    git update-index -q --refresh

    if [[ "$(git diff-index --name-only HEAD --)" ]]; then
        git commit -am "${msg}"
    else
        echo 'Nothing to commit'
    fi
}

get_tags()
{
    local repo=$1

    wget -q "https://registry.hub.docker.com/v1/repositories/${repo}/tags" -O - \
        | sed -e 's/[][]//g' -e 's/"//g' -e 's/ //g' \
        | tr '}' '\n' \
        | awk -F: '{print $3}'
}

get_timestamp()
{
    local repo=$1
    local tag=$2

    if [[ ! "${repo}" =~ / ]]; then
        repo="library/${repo}"
    fi

    curl -L -s "https://registry.hub.docker.com/v2/repositories/${repo}/tags/${tag}" | jq -r '.last_updated'
}

validate_versions()
{
    local version=$1
    local current=$2
    local latest=$3

    if [[ -z "${latest}" ]]; then
        echo "Couldn't find latest version of ${version}. Probably no longer supported!"
        exit 1
    fi

    if [[ -z "${current}" ]]; then
        echo "Couldn't get the current version of ${version}! Probably need to updated supported minor version!"
        exit 1
    fi

    if [[ "${current}" == "${latest}" ]]; then
        echo "The current version ${current} is already the latest version of branch ${version}"
    fi
}

# Init global git config.
git config --global user.email "${GIT_USER_EMAIL}"
git config --global user.name "Wodby Robot"
