#!/usr/bin/env bash

set -ex

# Init global git config.
git config --global user.email "${GIT_USER_EMAIL}"
git config --global user.name "Wodby Robot"

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

update_versions()
{
    local image=$1
    local versions=$2
    local base_image=$3
    local dir=$4
    local alpine=$5

    local name="${image#*/}"
    local suffix=""

    [[ -n "${alpine}" ]] && suffix="(?=\-alpine$)"

    for version in "${versions[@]}"; do
        base_image_tags=($(get_tags "${base_image}" | grep -oP "^(${version/\./\\.}\.[0-9]+)${suffix}" | sort -rV))
        base_image_latest_ver="${base_image_tags[0]}"

        cur_ver=$(grep -oP "(?<=${name^^}_VER=)(${version}\.[0-9]+)" .travis.yml)

        validate_versions "${version}" "${cur_ver}" "${base_image_latest_ver}"
        latest_timestamp=$(get_timestamp "${base_image}" "${cur_ver}")

        if [[ $(compare_semver "${base_image_latest_ver}" "${cur_ver}") == 0 ]]; then
            echo "${name^} ${cur_ver} is outdated, updating to ${base_image_latest_ver}"

            sed -i -E "s/(${name^^}${version//.})=.+/\1=${base_image_latest_ver}/" .travis.yml
            sed -i -E "s/(${name^^}_VER)=${version}\.[0-9]+/\1=${base_image_latest_ver}/" .travis.yml

            sed -i -E "s/(${name^^}_VER \?= )${cur_ver}/\1${base_image_latest_ver}/" "${dir}/Makefile"

            if [[ -f ".${base_image#*/}" ]]; then
                sed -i "s/${cur_ver}#.*/${base_image_latest_ver}#${latest_timestamp}/" ".${base_image#*/}"
            fi

            git_commit ./ "Updating ${name^} to ${base_image_latest_ver}"
        else
            echo "Version ${cur_ver} is already the latest version"
        fi
    done

#    git push origin
}

update_timestamps()
{
    local versions=$1
    local base_image=$2

    for version in "${versions[@]}"; do
        latest_timestamp=$(get_timestamp "${base_image}" "${version}")
        cur_timestamp=$(grep -oP "(?<=^${version/\./\\.}#)(.+)$" ".${base_image#*/}")

        if [[ "${cur_timestamp}" != "${latest_timestamp}" ]]; then
            echo "Base image has been updated. Triggering rebuild."
            sed -i "s/${cur_timestamp}/${latest_timestamp}/" ".${base_image#*/}"
            git_commit ./ "Update base image timestamp (version ${version})"
        fi
    done

#        git push origin
}

update_stability_tag()
{
    local version=$2
    local base_image=$3
    local branch=$1

    git checkout "${branch}"
    git merge --no-edit master
    tag=""

    base_image_tags=($(get_tags "${base_image}" | grep -oP "(?<=${version/\./\\.}-)([0-9]\.){2}[0-9]$" | sort -rV))
    latest_base_image_tag="${base_image_tags[0]}"

    cur_base_image_tag=$(grep -oP "(?<=BASE_IMAGE_STABILITY_TAG=)([0-9]\.){2}[0-9]$" .travis.yml)

    if [[ $(compare_semver "${latest_base_image_tag}" "${cur_base_image_tag}") == 0 ]]; then
        sed -i -E "s/(BASE_IMAGE_STABILITY_TAG=)${cur_base_image_tag}/\1${latest_base_image_tag}/" .travis.yml
        git_commit ./ "Update base image stability tag to ${latest_base_image_tag}"
        tag=1
    else
        echo "Base image stability tag ${cur_base_image_tag} is already the latest"
    fi

#    git push origin

    if [[ -n "${tag}" ]]; then
        cur_tag=$(git describe --abbrev=0 --tags)
        patch_ver="${cur_tag##*.}"
        patch_ver=$((patch_ver + 1))
        new_tag="${cur_tag%.*}.${patch_ver}"

        git tag -m "Base image updated to ${latest_base_image_tag}" "${new_tag}"
#        git push origin "${new_tag}"
    fi
}
