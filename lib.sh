#!/usr/bin/env bash

set -e

# Init global git config.
git config --global user.email "${GIT_USER_EMAIL}"
git config --global user.name "Wodby Robot"

_git_commit()
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

_get_image_tags()
{
    local repo="${1}"

    wget -q "https://registry.hub.docker.com/v1/repositories/${repo}/tags" -O - \
        | sed -e 's/[][]//g' -e 's/"//g' -e 's/ //g' \
        | tr '}' '\n' \
        | awk -F: '{print $3}'
}

_get_timestamp()
{
    local repo="${1}"
    local tag="${2}"

    if [[ ! "${repo}" =~ / ]]; then
        repo="library/${repo}"
    fi

    curl -L -s "https://registry.hub.docker.com/v2/repositories/${repo}/tags/${tag}" | jq -r '.last_updated'
}

_join_ws()
{
    local IFS=
    local s="${*/#/$1}"
    echo "${s#"$1$1$1"}"
}

_release_tag()
{
    local message="${1}"
    local minor_update="${2}"

    local cur_tag=$(git describe --abbrev=0 --tags)
    local patch_ver
    local tag

    # Patch version changed.
    if [[ -n "${minor_update}" ]]; then
        patch_ver="${cur_tag##*.}"
        local ver="${cur_tag%.*}"
        local minor_ver="${ver#*.}"
        local major_ver="${ver%.*}"
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

_get_dir()
{
    local version="${1}"
    
    local dir

    if [[ -f Dockerfile ]]; then
        dir="."
    elif [[ -f "${version}/Dockerfile" ]]; then
        dir="${version}"
    elif [[ -f "${version%%.*}/Dockerfile" ]]; then
        dir="${version%%.*}"
    else
        exit 1
    fi

    echo "${dir}"
}

_get_suffix()
{
    local path=$(find . -name Makefile -maxdepth 2 | head -n 1)
    local suffix="(?=$)"

    if grep -qP "BASE_IMAGE_TAG.+?-alpine" "${path}"; then
        suffix="(?=\-alpine$)"
    fi

    echo "${suffix}"
}

_github_get_latest_ver()
{
    local version="${1}"
    local slug="${2}"

    local url="https://api.github.com/repos/${slug}/git/refs/tags"
    local user="${GITHUB_MACHINE_USER_API_TOKEN}:x-oauth-basic"
    local expr=".[] | select ( .ref | ltrimstr(\"refs/tags/\") | ltrimstr(\"v\") | startswith(\"${version}\")).ref"

    # Only stable versions.
    local versions=($(curl -s -u "${user}" "${url}" | jq -r "${expr}" | sed -E "s/refs\/tags\/v?//" | grep -oP "^[0-9\.]+$" | sort -rV))

    if [[ "${#versions}" == 0 ]]; then
        >&2 echo "Couldn't find latest version in line ${version} of ${slug}."
        exit 1
    else
        echo "${versions[0]}"
    fi
}

_get_latest_version()
{
    local upstream="${1}"
    local version="${2}"

    local suffix=$(_get_suffix)

    # Get latest stable version from github.
    if [[ "${upstream}" == "github.com"* ]]; then
        latest_ver=$(_github_get_latest_ver "${version}" "${upstream/github.com\//}")
    # From docker hub, only patch updates.
    else
        local base_image_tags=($(_get_image_tags "${upstream}" | grep -oP "^(${version//\./\\.}\.[0-9\.]+)${suffix}" | sort -rV))
        latest_ver="${base_image_tags[0]}"
    fi

    if [[ -z "${latest_ver}" ]]; then
        >&2 echo "Couldn't find latest version of ${version}."
        exit 1
    fi

    echo "${latest_ver}"
}

get_base_image()
{
    local path=$(find . -name Dockerfile -maxdepth 2 | head -n 1)
    local base_image=""

    grep -oP "(?<=FROM ).+(?=:)" "${path}"
}

sync_fork()
{
    local repo="${1}"
    local upstream="${2}"

    git clone "https://${GITHUB_MACHINE_USER}:${GITHUB_MACHINE_USER_API_TOKEN}@github.com/${repo}" "/tmp/${repo#*/}"
    cd "/tmp/${repo#*/}"
    git remote add upstream "https://github.com/docker-library/${upstream}"
    git fetch upstream
    git merge --strategy-option ours --no-edit upstream/master

    ./wodby-meta-update.sh

    _git_commit ./ "Update from upstream"
    git push origin
}

update_versions()
{
    local versions="${1}"
    local upstream="${2}"
    local name="${3}"
    local subdir="${4}"

    local updated=()
    local latest_ver
    local latest_timestamp
    local cur_ver
    local dir

    IFS=' ' read -r -a arr_versions <<< "${versions}"

    echo "============================"
    echo "Checking for version updates"
    echo "============================"

    for version in "${arr_versions[@]}"; do
        if [[ -n "${subdir}" ]]; then
            dir="${subdir}"
        else
            dir=$(_get_dir "${version}")
        fi

        if [[ -f .circleci/config.yml ]]; then
            cur_ver=$(grep -oP "(?<=${name^^}_VER: )${version//\./\\.}\.[0-9\.]+")
        else
            # There two ways how we specify versions in .travis.yml (same used for updates below):
            # 1. PHP72=7.2.8
            # 2. PHP_VER=7.2.8
            cur_ver=$(grep -oP "(?<=${name^^}${version//.}=)[0-9\.]+")

            if [[ -z "${cur_ver}" ]]; then
                cur_ver=$(grep -oP "(?<=${name^^}_VER=)${version//\./\\.}[0-9\.]+")
            fi
        fi

        if [[ -z "${cur_ver}" ]]; then
            >&2 echo "Couldn't get the current version of ${version}! Probably need to update the list of supported versions!"
            exit 1
        fi

        latest_ver=$(_get_latest_version "${upstream}" "${version}")

        if [[ $(compare_semver "${latest_ver}" "${cur_ver}") == 0 ]]; then
            echo "${name^} ${cur_ver} is outdated, updating to ${latest_ver}"

            if [[ -f .circleci/config.yml ]]; then
                sed -i -E "s/(${name^^}_VER): ${version//\./\\.}.*/\1: ${latest_ver}/" .circleci/config.yml
            else
                sed -i -E "s/(${name^^}${version//.})=.+/\1=${latest_ver}/" .travis.yml
                sed -i -E "s/(${name^^}_VER)=${version//\./\\.}\.[0-9\.]+/\1=${latest_ver}/" .travis.yml
            fi

            sed -i -E "s/(${name^^}_VER \?= )${cur_ver}/\1${latest_ver}/" "${dir}/Makefile"

            # Update base image timestamps.
            if [[ -f ".${upstream#*/}" ]]; then
                latest_timestamp=$(_get_timestamp "${upstream}" "${cur_ver}")
                sed -i "s/${cur_ver}#.*/${latest_ver}#${latest_timestamp}/" ".${upstream#*/}"
            fi

            _git_commit ./ "Update ${name^} to ${latest_ver}"
            updated+=("${latest_ver}")
        else
            echo "Version ${cur_ver} is already the latest version"
        fi
    done

    git push origin

    if [[ "${#updated[@]}" != 0 ]]; then
        ver=$(_join_ws ", " "${updated[@]}")
        _release_tag "${name^} updated to ${ver}"
    fi
}

update_timestamps()
{
    local versions="${1}"
    local base_image="${2}"
    local updated=""

    local latest_timestamp
    local cur_timestamp

    IFS=' ' read -r -a arr_versions <<< "${versions}"

    echo "=============================="
    echo "Checking for timestamp updates"
    echo "=============================="

    for version in "${arr_versions[@]}"; do
        latest_timestamp=$(_get_timestamp "${base_image}" "${version}")
        cur_timestamp=$(cat ".${base_image#*/}" | grep "^${version}" | grep -oP "(?<=#)(.+)$")

        if [[ "${cur_timestamp}" != "${latest_timestamp}" ]]; then
            echo "Base image has been updated. Triggering rebuild."
            sed -i "s/${cur_timestamp}/${latest_timestamp}/" ".${base_image#*/}"
            updated=1
        fi
    done

    if [[ -n "${updated}" ]]; then
        _git_commit ./ "Rebuild against updated base image"
        git push origin
    else
        echo "Base image hasn't changed"
    fi
}

update_stability_tag()
{
    local version="${1}"
    local base_image="${2}"
    local branch="${3}"
    local tag=""
    local minor_update=""

    echo "=================================="
    echo "Checking for stability tag updates"
    echo "=================================="

    git checkout "${branch}"
    git merge --no-edit master

    local base_image_tags=($(_get_image_tags "${base_image}" | grep -oP "(?<=${version//\./\\.}-)[0-9\.]+$" | sort -rV))
    local latest_base_image_tag="${base_image_tags[0]}"
    local cur_base_image_tag=$(grep -oP "(?<=BASE_IMAGE_STABILITY_TAG=)[0-9\.]+$" .travis.yml)

    if [[ $(compare_semver "${latest_base_image_tag}" "${cur_base_image_tag}") == 0 ]]; then
        sed -i -E "s/(BASE_IMAGE_STABILITY_TAG=)${cur_base_image_tag}/\1${latest_base_image_tag}/" .travis.yml
        _git_commit ./ "Update base image stability tag to ${latest_base_image_tag}"
        tag=1
    else
        echo "Base image stability tag ${cur_base_image_tag} is already the latest"
    fi

    git push origin

    if [[ -n "${tag}" ]]; then
        if [[ "${cur_base_image_tag%.*}" != "${latest_base_image_tag%.*}" ]]; then
            minor_update=1
        fi

        _release_tag "Base image updated to ${latest_base_image_tag}" "${minor_update}"
    fi
}
