#!/usr/bin/env bash

set -e

# Init global git config.
git config --global user.email "${GIT_USER_EMAIL}"
git config --global user.name "Wodby Robot"

sync_fork()
{
    local repo=$1
    local upstream=$2

    git clone "https://${GITHUB_MACHINE_USER}:${GITHUB_MACHINE_USER_API_TOKEN}@github.com/${repo}" "/tmp/${repo#*/}"
    cd "/tmp/${repo#*/}"
    git remote add upstream "https://github.com/docker-library/${upstream}"
    git fetch upstream
    git merge --strategy-option ours --no-edit upstream/master

    ./wodby-meta-update.sh

    git_commit ./ "Update from upstream"
    git push origin
}

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

join_ws()
{
    local IFS=
    local s="${*/#/$1}"
    echo "${s#"$1$1$1"}"
};

release_tag()
{
    message=$1
    minor_update=$2

    cur_tag=$(git describe --abbrev=0 --tags)

    # Patch version changed.
    if [[ -n "${minor_update}" ]]; then
        patch_ver="${cur_tag##*.}"
        ver="${cur_tag%.*}"
        minor_ver="${ver#*.}"
        major_ver="${ver%.*}"
        minor_ver=$((minor_ver + 1))
        tag="${major_ver}.${minor_ver}.${patch_ver}"
    # Minor version changed.
    else
        patch_ver="${cur_tag##*.}"
        patch_ver=$((patch_ver + 1))
        tag="${cur_tag%.*}.${patch_ver}"
    fi

    git tag -m "${message}" "${tag}"
    git push origin "${tag}"
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
    local updated=()

    IFS=' ' read -r -a arr_versions <<< "${versions}"

    echo "============================"
    echo "Checking for version updates"
    echo "============================"

    [[ -n "${alpine}" ]] && suffix="(?=\-alpine$)"

    for version in "${arr_versions[@]}"; do
        base_image_tags=($(get_tags "${base_image}" | grep -oP "^(${version/\./\\.}\.[0-9]+)${suffix}" | sort -rV))
        base_image_latest_ver="${base_image_tags[0]}"

        if [[ -z "${base_image_latest_ver}" ]]; then
            echo "Couldn't find latest version of ${version}. Probably no longer supported!"
            exit 1
        fi

        if [[ -f .circleci/config.yml ]]; then
            cur_ver=$(grep -oP "(?<=${name^^}_VER: )(${version/\./\\.}\.[0-9]+)" .circleci/config.yml)
        else
            cur_ver=$(grep -oP "(?<=${name^^}_VER=)(${version/\./\\.}\.[0-9]+)" .travis.yml || true)

            if [[ -z "${cur_ver}" ]]; then
                cur_ver=$(grep -oP "(?<=${name^^}${version//.}=)(.+)" .travis.yml)
                regex="s/(${name^^}${version//.})=.+/\1=${base_image_latest_ver}/"
            else
                regex="s/(${name^^}_VER)=${version/\./\\.}\.[0-9]+/\1=${base_image_latest_ver}/"
            fi
        fi

        if [[ -z "${cur_ver}" ]]; then
            echo "Couldn't get the current version of ${version}! Probably need to update the list of supported versions!"
            exit 1
        fi

        latest_timestamp=$(get_timestamp "${base_image}" "${cur_ver}")

        if [[ $(compare_semver "${base_image_latest_ver}" "${cur_ver}") == 0 ]]; then
            echo "${name^} ${cur_ver} is outdated, updating to ${base_image_latest_ver}"

            if [[ -f .circleci/config.yml ]]; then
                sed -i -E "s/(MARIADB_VER): ${version/\./\\.}\.[0-9]+/\1: ${base_image_latest_ver}/" .circleci/config.yml
            else
                sed -i -E "${regex}" .travis.yml
            fi

            sed -i -E "s/(${name^^}_VER \?= )${cur_ver}/\1${base_image_latest_ver}/" "${dir}/Makefile"

            if [[ -f ".${base_image#*/}" ]]; then
                sed -i "s/${cur_ver}#.*/${base_image_latest_ver}#${latest_timestamp}/" ".${base_image#*/}"
            fi

            git_commit ./ "Update ${name^} to ${base_image_latest_ver}"
            updated+=("${base_image_latest_ver}")
        else
            echo "Version ${cur_ver} is already the latest version"
        fi
    done

    git push origin

    if [[ "${#updated[@]}" != 0 ]]; then
        ver=$(join_ws ", " "${updated[@]}")
        release_tag "${name^} updated to ${ver}"
    fi
}

update_timestamps()
{
    local versions=$1
    local base_image=$2
    local updated=""

    IFS=' ' read -r -a arr_versions <<< "${versions}"

    echo "=============================="
    echo "Checking for timestamp updates"
    echo "=============================="

    for version in "${arr_versions[@]}"; do
        latest_timestamp=$(get_timestamp "${base_image}" "${version}")
        cur_timestamp=$(cat ".${base_image#*/}" | grep "^${version}" | grep -oP "(?<=#)(.+)$")

        if [[ "${cur_timestamp}" != "${latest_timestamp}" ]]; then
            echo "Base image has been updated. Triggering rebuild."
            sed -i "s/${cur_timestamp}/${latest_timestamp}/" ".${base_image#*/}"
            updated=1
        fi
    done

    if [[ -n "${updated}" ]]; then
        git_commit ./ "Rebuild against updated base image"
        git push origin
    else
        echo "Base image hasn't changed"
    fi
}

update_stability_tag()
{
    local version=$1
    local base_image=$2
    local branch=$3
    local tag=""

    echo "=================================="
    echo "Checking for stability tag updates"
    echo "=================================="

    git checkout "${branch}"
    git merge --no-edit master

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

    git push origin

    if [[ -n "${tag}" ]]; then
        if [[ "${cur_base_image_tag%.*}" == "${latest_base_image_tag%.*}" ]]; then
            minor_update=""
        else
            minor_update=1
        fi

        release_tag "Base image updated to ${latest_base_image_tag}" "${minor_update}"
    fi
}
