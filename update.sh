#!/usr/bin/env bash

set -e

if [[ -n "${DEBUG}" ]]; then
    set -x
fi

# Init global git config.
git config --global user.email "${GIT_USER_EMAIL}"
git config --global user.name "${GIT_USER_NAME}"

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

    IFS="." read -r -a sem_ver <<< $(git describe --abbrev=0 --tags)

    # Minor version changed.
    if [[ -n "${minor_update}" ]]; then
        (( ++sem_ver[1] ))
        sem_ver[2]=0
    # Patch version changed.
    else
        (( ++sem_ver[2] ))
    fi

    local tag=$(_join_ws "." "${sem_ver[@]}")

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
    local name="${3}"

    local url="https://api.github.com/repos/${slug}/git/refs/tags"
    local user="${GITHUB_MACHINE_USER_API_TOKEN}:x-oauth-basic"
    local expr=".[] | select ( .ref | ltrimstr(\"refs/tags/\") | ltrimstr(\"${name}-\") | ltrimstr(\"v\") | startswith(\"${version}\")).ref"

    # Only stable versions.
    local versions=($(curl -s -u "${user}" "${url}" | jq -r "${expr}" | sed -E "s/refs\/tags\/(v|${name}-)?//" | grep -oP "^[0-9\.]+$" | sort -rV))

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
    local name="${3}"

    local suffix=$(_get_suffix)

    # Get latest stable version from github.
    if [[ "${upstream}" == "github.com"* ]]; then
        latest_ver=$(_github_get_latest_ver "${version}" "${upstream/github.com\//}" "${name}")
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

_git_clone()
{
    local slug="${1}"

    git clone "https://${GITHUB_MACHINE_USER}:${GITHUB_MACHINE_USER_API_TOKEN}@github.com/${slug}" "/tmp/${slug#*/}"
    cd "/tmp/${slug#*/}"
}

_get_base_image()
{
    local path=$(find . -name Dockerfile -maxdepth 2 | head -n 1)
    local base_image=""

    grep -oP "(?<=FROM ).+(?=:)" "${path}"
}

_update_versions()
{
    local versions="${1}"
    local upstream="${2}"
    local name="${3}"
    local branch="${4}"

    local updated=()
    local latest_ver
    local latest_timestamp
    local cur_ver
    local dir
    local dots

    local minor_update

    IFS=' ' read -r -a arr_versions <<< "${versions}"

    echo "============================"
    echo "Checking for version updates"
    echo "============================"

    for version in "${arr_versions[@]}"; do
        dir=$(_get_dir "${version}")

        if [[ -f .circleci/config.yml ]]; then
            cur_ver=$(grep -oP -m1 "(?<=${name^^}_VER: )${version//\./\\.}\.[0-9\.]+" .circleci/config.yml || true)
        else
            # There two ways how we specify versions in .travis.yml (same used for updates below):
            # 1. PHP72=7.2.8
            # 2. PHP_VER=7.2.8
            cur_ver=$(grep -oP "(?<=${name^^}${version//.}=)[0-9\.]+" .travis.yml || true)

            if [[ -z "${cur_ver}" ]]; then
                cur_ver=$(grep -oP -m1 "(?<=${name^^}_VER=)${version//\./\\.}[0-9\.]+" .travis.yml || true)
            fi
        fi

        if [[ -z "${cur_ver}" ]]; then
            >&2 echo "Couldn't get the current version of ${version}! Probably need to update the list of supported versions!"
            exit 1
        fi

        latest_ver=$(_get_latest_version "${upstream}" "${version}" "${name}")

        if [[ $(compare_semver "${latest_ver}" "${cur_ver}") == 0 ]]; then
            echo "${name^} ${cur_ver} is outdated, updating to ${latest_ver}"

            if [[ -f .circleci/config.yml ]]; then
                sed -i -E "s/(${name^^}_VER): ${version//\./\\.}.*/\1: ${latest_ver}/" .circleci/config.yml
            else
                sed -i -E "s/(${name^^}${version//.})=.+/\1=${latest_ver}/" .travis.yml
                sed -i -E "s/(${name^^}_VER)=${version//\./\\.}\.[0-9\.]+/\1=${latest_ver}/" .travis.yml
            fi

            # For semver minor updates we should also update tags info.
            if [[ "${latest_ver%.*}" != "${cur_ver%.*}" ]]; then
                minor_update=1
                sed -i -E "s/(TAGS)=.+?${version//\./\\.}\.[0-9\.]+,/\1=${latest_ver%.*},/" .travis.yml
                sed -i -E "s/\`${version//\./\\.}\.[0-9\.]+\`/\`${latest_ver%.*}\`/" README.md
                sed -i -E "s/\:${version//\./\\.}\.[0-9\.]+(-X\.X\.X)/:${latest_ver%.*}\1/" README.md
            fi

            sed -i -E "s/(${name^^}_VER \?= )${cur_ver}/\1${latest_ver}/" "${dir}/Makefile"

            # Update base image timestamps.
            if [[ -f ".${upstream#*/}" ]]; then
                latest_timestamp=$(_get_timestamp "${upstream}" "${latest_ver}")
                sed -i "s/${cur_ver}#.*/${latest_ver}#${latest_timestamp}/" ".${upstream#*/}"
            fi

            _git_commit ./ "Update ${name} to ${latest_ver}"
            updated+=("${latest_ver}")
        else
            echo "Version ${cur_ver} is already the latest version"
        fi
    done

    git push origin

    if [[ "${#updated[@]}" != 0 ]]; then
        if [[ -n "${branch}" ]]; then
            git checkout "${branch}"
            git merge --no-edit master
            git push origin
        fi

        local ver=$(_join_ws ", " "${updated[@]}")

        _release_tag "${name} updates: ${ver}" "${minor_update}"
    fi
}

_update_timestamps()
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

_update_base_alpine_image()
{
    local version="${1}"
    local base_image="${2}"
    local release_tag="${3}"
    local current

    echo "=========================================="
    echo "Checking for alpine base image tag updates"
    echo "=========================================="

    local latest=$(_get_image_tags "${base_image}" | grep -oP "(?<=${version//\./\\.}-)[0-9\.]+$" | sort -rV | head -n1)

    if [[ -z "${latest}" ]]; then
        >&2 echo "Failed to acquire latest image tag"
        exit 1
    fi

    if [[ -f .circleci/config.yml ]]; then
        current=$(grep -oP "(?<=BASE_IMAGE_STABILITY_TAG: )[0-9\.]+$" .circleci/config.yml | head -n1)
    else
        current=$(grep -oP "(?<=BASE_IMAGE_STABILITY_TAG=)[0-9\.]+$" .travis.yml)
    fi

    if [[ $(compare_semver "${latest}" "${current}") == 0 ]]; then
        if [[ -f .circleci/config.yml ]]; then
            sed -i -E "s/(BASE_IMAGE_STABILITY_TAG: )${current}/\1${latest}/" .circleci/config.yml
        else
            sed -i -E "s/(BASE_IMAGE_STABILITY_TAG=)${current}/\1${latest}/" .travis.yml
        fi

        _git_commit ./ "Update base image stability tag to ${latest}"
    else
        release_tag=""
        echo "Base image stability tag ${current} is already the latest"
    fi

    git push origin

    if [[ -n "${release_tag}" ]]; then
        if [[ "${current%.*}" != "${latest%.*}" ]]; then
            minor_update=1
        fi

        _release_tag "Base image stability tag updated to ${latest}" "${minor_update}"
    fi
}

_update_stability_tag()
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

    local latest=$(_get_image_tags "${base_image}" | grep -oP "(?<=${version//\./\\.}-)[0-9\.]+$" | sort -rV | head -n1)

    if [[ -z "${latest}" ]]; then
        >&2 echo "Failed to acquire latest image tag"
        exit 1
    fi

    local current=$(grep -oP "(?<=BASE_IMAGE_STABILITY_TAG=)[0-9\.]+$" .travis.yml)

    if [[ $(compare_semver "${latest}" "${current}") == 0 ]]; then
        sed -i -E "s/(BASE_IMAGE_STABILITY_TAG=)${current}/\1${latest}/" .travis.yml
        _git_commit ./ "Update base image stability tag to ${latest}"
        tag=1
    else
        echo "Base image stability tag ${current} is already the latest"
    fi

    git push origin

    if [[ -n "${tag}" ]]; then
        if [[ "${current%.*}" != "${latest%.*}" ]]; then
            minor_update=1
        fi

        _release_tag "Base image stability tag updated to ${latest}" "${minor_update}"
    fi
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

update_from_base_image()
{
    local image="${1}"
    local versions="${2}"

    _git_clone "${image}"

    local upstream=$(_get_base_image)

    if [[ ! -f ".${upstream#*/}" ]]; then
        >&2 echo "ERROR: Missing .${upstream#*/} file!"
        exit 1
    fi

    _update_versions "${versions}" "${upstream}" "${image#*/}"
    _update_timestamps "${versions}" "${upstream}"
}

rebuild_and_rebase()
{
    local image="${1}"
    local versions="${2}"
    local branch="${3}"

    _git_clone "${image}"

    local base_image=$(_get_base_image)

    if [[ ! -f ".${base_image#*/}" ]]; then
        >&2 echo "ERROR: Missing .${base_image#*/} file!"
        exit 1
    fi

    IFS=' ' read -r -a array <<< "${versions}"

    _update_timestamps "${versions}" "${base_image}"
    _update_stability_tag "${array[0]}" "${base_image}" "${branch}"
}

update_base_alpine()
{
    local image="${1}"
    local version="${2}"
    local release_tag="${3}"

    local base_image="wodby/alpine"

    _git_clone "${image}"

    if [[ ! -f ".alpine" ]]; then
        >&2 echo "ERROR: Missing .alpine file!"
        exit 1
    fi

    _update_timestamps "${version}" "${base_image}"
    _update_base_alpine_image "${version}" "${base_image}" "${release_tag}"
}

update_from_upstream()
{
    local image="${1}"
    local versions="${2}"
    local upstream="${3}"
    local branch="${4}"

    _git_clone "${image}"

    _update_versions "${versions}" "${upstream}" "${image#*/}" "${branch}"
}

update_docker4x()
{
    local project="${1}"
    local branch="${2}"

    local lines=()
    local image
    local env_var
    local tags
    local current
    local latest

    local name="${image#*/}"

    _git_clone "${project}"

    lines=($(grep -hoP "(?<=image: )wodby\/.+" docker-compose*.yml))

    if [[ -f Dockerfile ]]; then
        if grep -q "FROM wodby/python" Dockerfile; then
            lines+=(wodby/python:\$PYTHON_TAG)
        fi

        if grep -q "FROM wodby/ruby" Dockerfile; then
            lines+=(wodby/ruby:\$RUBY_TAG)
        fi
    fi

    for line in "${lines[@]}"; do
        [[ "${line}" =~ (.+?):\$(.+) ]]

        image="${BASH_REMATCH[1]}"
        env_var="${BASH_REMATCH[2]}"

        tags=($(grep -oP "(?<=${env_var}=).+" .env))

        if [[ "${tags[0]}" == "latest" ]]; then
            continue
        fi

        current="${tags[0]##*-}"
        name="${image#*/}"

        latest=$(_get_image_tags "${image}" | grep -oP "(?<=-)([0-9]+\.){2}[0-9]+$" | sort -rV | head -n1)

        # If no stability tags have been found, try searching one without a version (e.g. xhprof image).
        if [[ -z "${latest}" ]]; then
            latest=$(_get_image_tags "${image}" | grep -oP "^([0-9]+\.){2}[0-9]+$" | sort -rV | head -n1)
        fi

        if [[ -z "${latest}" ]]; then
            >&2 echo "Failed to acquire latest image tag"
            exit 1
        fi

        if [[ $(compare_semver "${latest}" "${current}") == 0 ]]; then
            sed -i -E "s/^(${env_var}=[0-9\.-]+?)${current}$/\1${latest}/" .env

            # Update tests.
            find tests/ -name .env -exec sed -i -E "s/^(#?${env_var}=[0-9\.]+(:?-dev|-dev-macos)?-)${current}$/\1${latest}/" .env {} +

            # Update env var like like $DRUPAL_STABILITY_TAG in tests.
            if [[ "${name}" == "${project#*docker4}" ]]; then
                find tests/ -name .env -exec sed -i -E "s/^(${name^^}_STABILITY_TAG)=${current}$/\1=${latest}/" .env {} +
            fi

            _git_commit ./ "Update ${name} stability tag to ${latest}"
            git push origin
        else
            echo "${name}: stability tag ${current} is already latest"
        fi
    done
}
