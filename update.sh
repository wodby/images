#!/usr/bin/env bash

set -e
set -o pipefail

if [[ -n "${DEBUG}" ]]; then
  set -x
fi

git config --global user.email "${GIT_USER_EMAIL}"
git config --global user.name "${GIT_USER_NAME}"

urlencode() {
    local length="${#1}"
    local encoded=""
    for (( i = 0; i < length; i++ )); do
        local c="${1:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) encoded+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"
               encoded+="$hex"
               ;;
        esac
    done
    echo "$encoded"
}

_git_commit() {
  local dir="${1}"
  local msg="${2}"

  cd "${dir}"
  git add -A

  if ! git diff --cached --quiet; then
    git commit -m "${msg}"
  else
    echo 'Nothing to commit'
  fi
}

_get_image_tags() {
  local slug="${1%:*}"
  local filter="${2}"
  local response
  local tag_names
  local res

  local namespace=${slug%/*}
  local repo=${slug#*/}
  if [[ "${namespace}" == "${slug}" ]]; then
    namespace="library"
  fi

  local url="https://hub.docker.com/v2/namespaces/${namespace}/repositories/${repo}/tags"

  for page in {1..10}; do
    response=$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 3 "${url}?page=${page}&page_size=100") || {
      echo >&2 "Failed to fetch tags from ${slug}"
      exit 1
    }
    tag_names=$(jq -r '.results[].name' <<<"${response}") || {
      echo >&2 "Failed to parse tags response from ${slug}"
      exit 1
    }
    res=$(grep -oP "${filter}" <<<"${tag_names}" | sort -rV | head -n1 || true)
    if [[ -n "${res}" ]]; then
      echo "${res}"
      return 0
    fi
  done

  echo >&2 "Failed to find tags in ${slug} with filter ${filter}"
  return 1
}

_get_timestamp() {
  local repo="${1}"
  local tag="${2}"
  local namespace
  local name
  local url
  local response

  if [[ "${repo}" =~ / ]]; then
    namespace="${repo%/*}"
    name="${repo#*/}"
  else
    namespace="library"
    name="${repo}"
  fi

  url="https://hub.docker.com/v2/namespaces/${namespace}/repositories/${name}/tags/${tag}"
  response=$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 3 "${url}") || {
    echo >&2 "Failed to fetch Docker Hub tag metadata for ${namespace}/${name}:${tag}"
    exit 1
  }

  jq -er '.last_updated' <<<"${response}" || {
    echo >&2 "Failed to parse Docker Hub tag metadata for ${namespace}/${name}:${tag}"
    exit 1
  }
}

_join_ws() {
  local IFS=
  local s="${*/#/$1}"
  echo "${s#"$1$1$1"}"
}

_get_minor_series() {
  local version="${1}"
  local major
  local minor

  IFS='.' read -r major minor _ <<<"${version}"

  echo "${major}.${minor:-0}"
}

_head_has_unpushed_commits() {
  local branch_name="${1:-$(git rev-parse --abbrev-ref HEAD)}"

  [[ $(git rev-list --count "origin/${branch_name}..HEAD") -gt 0 ]]
}

_release_tag() {
  local message="${1}"
  local minor_update="${2}"
  local tag

  IFS="." read -r -a sem_ver <<<"$(git describe --abbrev=0 --tags)"

  # Minor version changed.
  if [[ -n "${minor_update}" ]]; then
    ((++sem_ver[1]))
    sem_ver[2]=0
  # Patch version changed.
  else
    ((++sem_ver[2]))
  fi

  tag=$(_join_ws "." "${sem_ver[@]}")

  git tag -m "${message}" "${tag}"
  git push origin "${tag}"
}

_get_dir() {
  local version="${1}"
  local dir

  if [[ -f Dockerfile ]]; then
    dir="."
  elif [[ -f "${version}/Dockerfile" ]]; then
    dir="${version}"
  elif [[ -f "${version%%.*}/Dockerfile" ]]; then
    dir="${version%%.*}"
  else
    echo >&2 "Couldn't detect directory with Dockerfile"
    exit 1
  fi

  echo "${dir}"
}

_github_get_versions() {
  local version="${1}"
  local slug="${2}"
  local name="${3}"
  local response
  local refs

  local url="https://api.github.com/repos/${slug}/git/refs/tags"
  local user="${GITHUB_MACHINE_USER_API_TOKEN}:x-oauth-basic"
  local expr=".[] | select ( .ref | ltrimstr(\"refs/tags/\") | ltrimstr(\"releases/${name}/\") | ltrimstr(\"${name}-\") | ltrimstr(\"v\") | ltrimstr(\"release-\") | startswith(\"${version}\")).ref"

  local -a versions

  # Only stable versions.
  response=$(curl -fsSL -u "${user}" "${url}") || {
    echo >&2 "Failed to fetch tags from ${slug}"
    exit 1
  }
  refs=$(jq -r "${expr}" <<<"${response}") || {
    echo >&2 "Failed to parse tags response from ${slug}"
    exit 1
  }
  mapfile -t versions < <(sed -E "s/refs\/tags\/(v|release-|releases\/${name}\/|${name}-)?//" <<<"${refs}" | grep -oP "^[0-9.]+$" | sort -rV || true)

  if [[ "${#versions[@]}" == 0 ]]; then
    echo >&2 "Couldn't find latest version in line ${version} of ${slug}."
    exit 1
  fi

  printf '%s\n' "${versions[@]}"
}

_gitlab_get_versions() {
  local version="${1}"
  local url="${2}"
  local encoded_path
  local version_prefix
  local response
  local refs

  local host="${url%%/*}"
  encoded_path=$(urlencode "${url#*/}")

  version_prefix=$(urlencode "^${version}.")

  local api_url="https://$host/api/v4/projects/$encoded_path/repository/tags?per_page=100&order_by=version&sort=desc&search=${version_prefix}"
  local expr=".[] | .name"

  local -a versions

  # Only stable versions.
  response=$(curl -fsSL "${api_url}") || {
    echo >&2 "Failed to fetch tags from ${url}"
    exit 1
  }
  refs=$(jq -r "${expr}" <<<"${response}") || {
    echo >&2 "Failed to parse tags response from ${url}"
    exit 1
  }
  mapfile -t versions < <(grep -oP "^[0-9.]+$" <<<"${refs}" | sort -rV || true)

  if [[ "${#versions[@]}" == 0 ]]; then
    echo >&2 "Couldn't find latest version in line ${version} of ${url}."
    exit 1
  fi

  printf '%s\n' "${versions[@]}"
}

_packagist_get_versions() {
  local version="${1}"
  local package="${2}"
  local response
  local pkg_encoded="${package//\//%2F}"

  local -a versions

  response=$(curl -fsSL "https://repo.packagist.org/p2/${pkg_encoded}.json") || {
    echo >&2 "Failed to fetch package metadata from Packagist for ${package}"
    exit 1
  }

  mapfile -t versions < <(
    jq -r --arg package "${package}" '.packages[$package][]?.version' <<<"${response}" \
      | grep -oP "^[0-9.]+$" \
      | grep -P "^${version//\./\\.}(\\.|$)" \
      | sort -rV \
      | uniq || true
  )

  if [[ "${#versions[@]}" == 0 ]]; then
    echo >&2 "Couldn't find latest version in line ${version} of ${package} on Packagist."
    exit 1
  fi

  printf '%s\n' "${versions[@]}"
}

_url_exists() {
  local url="${1}"

  curl -fsSIL --connect-timeout 10 --max-time 30 --retry 3 -o /dev/null "${url}" \
    || curl -fsSL --connect-timeout 10 --max-time 30 --retry 3 --range 0-0 -o /dev/null "${url}"
}

_release_source_has_version() {
  local release_source="${1}"
  local version="${2}"
  local url

  if [[ -z "${release_source}" ]]; then
    return 0
  fi

  if [[ "${release_source}" == packagist:* ]]; then
    _packagist_get_versions "${version}" "${release_source#packagist:}" >/dev/null
    return 0
  fi

  url="${release_source//\{\{version\}\}/${version}}"
  _url_exists "${url}"
}

_release_source_get_latest_ver() {
  local version="${1}"
  local release_source="${2}"
  local -a versions

  if [[ "${release_source}" == packagist:* ]]; then
    mapfile -t versions < <(_packagist_get_versions "${version}" "${release_source#packagist:}")
    echo "${versions[0]}"
    return 0
  fi

  return 1
}

_get_latest_version() {
  local upstream="${1%:*}"
  local version="${2}"
  local name="${3}"
  local release_source="${4:-}"
  local latest_ver

  local -a versions

  if [[ -n "${release_source}" ]]; then
    latest_ver=$(_release_source_get_latest_ver "${version}" "${release_source}" || true)
    if [[ -n "${latest_ver}" ]]; then
      echo "${latest_ver}"
      return 0
    fi
  fi

  # Get latest stable versions from upstream.
  if [[ "${upstream}" == "github.com"* ]]; then
    mapfile -t versions < <(_github_get_versions "${version}" "${upstream/github.com\//}" "${name}")
  elif [[ "${upstream}" == "git.drupalcode.org"* ]]; then
    mapfile -t versions < <(_gitlab_get_versions "${version}" "${upstream}")
  # From docker hub, only patch updates.
  else
    local makefilePath
    local dockerfilePath
    local suffix="(?=$)"

    makefilePath=$(find . -name Makefile -maxdepth 2 | head -n 1)
    dockerfilePath=$(find . -name Dockerfile -maxdepth 2 | head -n 1)

    # Alpine-only tags.
    if grep -qP "BASE_IMAGE_TAG.+?-alpine" "${makefilePath}" || grep -qP "^FROM .+?-alpine" "${dockerfilePath}" ; then
      suffix="(?=\-alpine$)"
    fi

    latest_ver=$(_get_image_tags "${upstream}" "^(${version//\./\\.}\.[0-9.]+)${suffix}")
    echo "${latest_ver}"
    return 0
  fi

  if [[ -n "${release_source}" ]]; then
    local candidate

    for candidate in "${versions[@]}"; do
      if _release_source_has_version "${release_source}" "${candidate}"; then
        latest_ver="${candidate}"
        break
      fi
    done
  else
    latest_ver="${versions[0]}"
  fi

  if [[ -z "${latest_ver}" ]]; then
    if [[ -n "${release_source}" ]]; then
      echo >&2 "Couldn't find released version in line ${version} from ${release_source}."
    else
      echo >&2 "Couldn't find latest version of ${version}."
    fi
    exit 1
  fi

  echo "${latest_ver}"
}

_git_clone() {
  local slug="${1}"

  git clone "https://${GITHUB_MACHINE_USER}:${GITHUB_MACHINE_USER_API_TOKEN}@github.com/${slug}" "/tmp/${slug#*/}"
  cd "/tmp/${slug#*/}"
}

_install_composer() {
  local tmp_dir
  local expected_checksum
  local actual_checksum

  apk add --no-cache php-cli php-openssl php-phar php-mbstring ca-certificates

  tmp_dir=$(mktemp -d)

  if ! (
    cd "${tmp_dir}"

    expected_checksum=$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");') || {
      echo >&2 "Failed to fetch Composer installer signature"
      exit 1
    }

    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" || {
      echo >&2 "Failed to download Composer installer"
      exit 1
    }

    actual_checksum=$(php -r "echo hash_file('sha384', 'composer-setup.php');") || {
      echo >&2 "Failed to calculate Composer installer checksum"
      exit 1
    }

    if [[ "${expected_checksum}" != "${actual_checksum}" ]]; then
      echo >&2 "Composer installer checksum verification failed"
      exit 1
    fi

    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
  ); then
    rm -rf "${tmp_dir}"
    return 1
  fi

  rm -rf "${tmp_dir}"
}

_assert_all_entries_copied() {
  local source_dir="${1}"
  local target_dir="${2}"
  local -a missing_entries=()
  local entry
  local name

  while IFS= read -r entry; do
    name="${entry##*/}"

    if [[ "${name}" == .* ]] || [[ "${name}" == *.md ]] || [[ "${name}" == *.txt ]]; then
      continue
    fi

    if [[ ! -e "${target_dir}/${name}" ]]; then
      missing_entries+=("${name}")
    fi
  done < <(find "${source_dir}" -mindepth 1 -maxdepth 1 | sort)

  if [[ "${#missing_entries[@]}" -gt 0 ]]; then
    echo >&2 "Failed to copy upstream entries: ${missing_entries[*]}"
    exit 1
  fi
}

_get_base_image() {
  local path
  local base_image

  path=$(find . -name Dockerfile -maxdepth 2 | sort -n | head -n 1)
  base_image=$(sed -E 's/\$\{.+\}-?//' "${path}" | grep -oPm1 "(?<=FROM )(.+)" | sed 's/:$//' || true)

  if [[ -z "${base_image}" ]]; then
    echo >&2 "Failed to identify failed image"
    exit 1
  fi

  echo "${base_image}"
}

_get_alpine_ver() {
  local image="${1}"
  local ver

  docker pull "${image}" >/dev/null
  ver=$(docker run --rm --entrypoint=/bin/sh "${image}" -c 'cat /etc/os-release' | grep -oP '(?<=VERSION_ID=)[0-9.]+' || true)

  if [[ -z "${ver}" ]]; then
    echo >&2 "Failed to detect alpine version"
    exit 1
  fi

  echo "${ver}"
}

_update_versions() {
  local version_list="${1}"
  local upstream="${2%:*}"
  local name="${3}"
  local branch="${4}"
  local release_source="${5:-}"

  local updated=()
  local latest_ver
  local latest_timestamp
  local cur_ver
  local cur_series
  local dir
  local has_quotes
  local latest_series

  local minor_update
  local version_key
  local name_key

  IFS=' ' read -r -a arr_versions <<<"${version_list}"

  name_key=$(tr '[:lower:]-' '[:upper:]_' <<<"${name}")

  echo "============================"
  echo "Checking for version updates"
  echo "============================"

  for version in "${arr_versions[@]}"; do
    dir=$(_get_dir "${version}")

    # There are three supported ways to pin a version in workflow.yml:
    # 1. PHP72: 7.2.8 (or PHP7 depending on the provided version)
    # 2. PHP_VER: 7.2.8
    # 3. version: 7.2.8
    version_key="${name_key}${version//./}"
    cur_ver=$(grep -oPm1 "(?<=${version_key}: )'?[0-9.]+" .github/workflows/workflow.yml || true)

    if [[ -z "${cur_ver}" ]]; then
      version_key="${name_key}_VER"
      cur_ver=$(grep -oPm1 "(?<=${version_key}: )'?[0-9.]+" .github/workflows/workflow.yml || true)
    fi

    if [[ -z "${cur_ver}" ]]; then
      version_key="version"
      cur_ver=$(grep -oPm1 "(?<=version: )'?${version//\./\\.}[0-9.]+" .github/workflows/workflow.yml || true)
    fi

    if [[ -z "${cur_ver}" ]]; then
      echo >&2 "Couldn't get the current version of ${version}! Probably need to update the list of supported versions!"
      exit 1
    else
      has_quotes=""
      # Version in YAML may contain optional single quote to avoid types issues (e.g. 8.0 parsed as 8)
      if [[ -n "${cur_ver//[^\']/}" ]]; then
        has_quotes=1
        cur_ver="${cur_ver#\'}"
      fi
    fi

    latest_ver=$(_get_latest_version "${upstream}" "${version}" "${name}" "${release_source}")
    latest_series=$(_get_minor_series "${latest_ver}")
    cur_series=$(_get_minor_series "${cur_ver}")

    if [[ $(compare_semver "${latest_ver}" "${cur_ver}") == 0 ]]; then
      echo "${name^} ${cur_ver} is outdated, updating to ${latest_ver}"

      if [[ "${version_key}" == "version" ]]; then
        if [[ -z "${has_quotes}" ]]; then
          sed -i -E "s/(version): ${version//\./\\.}\.[0-9.]+/\1: '${latest_ver}'/g" .github/workflows/workflow.yml
        else
          sed -i -E "s/(version): '${version//\./\\.}\.[0-9.]+'/\1: '${latest_ver}'/g" .github/workflows/workflow.yml
        fi
      else
        sed -i -E "s/(${version_key}): .+/\1: '${latest_ver}'/g" .github/workflows/workflow.yml
      fi

      # For semver minor updates we should also update tags info.
      if [[ "${latest_series}" != "${cur_series}" ]]; then
        minor_update=1
        sed -i -E "s/(tags): (.+?)${version//\./\\.}\.[0-9.]+/\1: \2${latest_series}/g" .github/workflows/workflow.yml
        sed -i -E "s/\`${version//\./\\.}\.[0-9.]+\`/\`${latest_series}\`/g" README.md
        sed -i -E "s/\`${version//\./\\.}\.[0-9.]+-dev\`/\`${latest_series}-dev\`/g" README.md
        sed -i -E "s/\:${version//\./\\.}\.[0-9.]+(-X\.X\.X)/:${latest_series}\1/g" README.md
      fi

      sed -i -E "s/(${name_key}_VER \?= )${cur_ver}/\1${latest_ver}/" "${dir}/Makefile"

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

  if [[ "${#updated[@]}" != 0 ]]; then
    git push origin

    if [[ -n "${branch}" ]]; then
      git checkout "${branch}"
      git merge --no-edit master
      git push origin
    fi

    local ver
    ver=$(_join_ws ", " "${updated[@]}")

    _release_tag "${name} updates: ${ver}" "${minor_update}"
  fi
}

_update_timestamps() {
  local version_list="${1}"
  local base_image="${2}"

  # When passed we also check for Alpine update and release versions.
  local image="${3:-}"
  local updated

  local latest_timestamp
  local cur_timestamp
  local tag

  local latest_alpine_ver
  local cur_alpine_ver
  local branch_name
  local had_local_commits
  local minor_update=""
  local ver_list

  local -a ver_with_updated_alpine

  IFS=' ' read -r -a arr_versions <<<"${version_list}"

  echo "=============================="
  echo "Checking for timestamp updates"
  echo "=============================="

  for version in "${arr_versions[@]}"; do
    latest_timestamp=$(_get_timestamp "${base_image%:*}" "${version}")
    if [[ -z "${latest_timestamp}" ]]; then
      echo >&2 "Failed to acquire latest timestamp"
      exit 1
    fi

    local filename="${base_image%:*}"
    filename=".${filename#*/}"
    cur_timestamp=$(grep "^${version}" "${filename}" | grep -oP "(?<=#)(.+)$" || true)
    if [[ -z "${cur_timestamp}" ]]; then
      echo >&2 "Failed to acquire current timestamp"
      exit 1
    fi

    if [[ "${cur_timestamp}" != "${latest_timestamp}" ]]; then
      echo "Base image has been updated. Triggering rebuild."
      sed -i "s/${cur_timestamp}/${latest_timestamp}/" "${filename}"
      updated=1

      # Check for Alpine updates.
      if [[ -n "${image}" && "${base_image}" != alpine* ]]; then
        cur_alpine_ver=$(_get_alpine_ver "${image}:${version}")
        if [[ "${base_image}" != wodby* ]]; then
          local suffix="${base_image#*:}"
          if [[ -z "${suffix}" ]]; then
            echo >&2 "Failed to identify base image"
            exit 1
          fi
          latest_alpine_ver=$(_get_alpine_ver "${base_image%:*}:${version}-${suffix}")
        else
          latest_alpine_ver=$(_get_alpine_ver "${base_image%:*}:${version}")
        fi

        if [[ $(compare_semver "${latest_alpine_ver}" "${cur_alpine_ver}") == 0 ]]; then
          if [[ "$(_get_minor_series "${latest_alpine_ver}")" != "$(_get_minor_series "${cur_alpine_ver}")" ]]; then
            minor_update=1
          fi

          ver_with_updated_alpine+=("${version}")
        fi
      fi
    fi
  done

  if [[ -n "${updated}" ]]; then
    _git_commit ./ "Rebuild against updated base image"

    branch_name=$(git rev-parse --abbrev-ref HEAD)
    had_local_commits=""
    if _head_has_unpushed_commits "${branch_name}"; then
      had_local_commits=1
    fi
    git push origin

    # Release tags on alpine updates.
    if [[ "${#ver_with_updated_alpine[@]}" != 0 ]]; then
      # In case there were no new commits but the base image alpine we want to force rebuild latest images against new Alpine.
      if [[ -z "${had_local_commits}" ]]; then
        git commit --allow-empty -m "Rebuild against updated Alpine"
        git push origin
      fi
      ver_list=$(_join_ws ", " "${ver_with_updated_alpine[@]}")
      _release_tag "Alpine Linux updated to ${latest_alpine_ver} for versions: ${ver_list}" "${minor_update}"
    fi
  else
    echo "Base image hasn't changed"
  fi
}

_update_base_alpine_image() {
  local version="${1}"
  local base_image="${2}"
  local release_tag="${3}"
  local branch_name
  local current
  local had_local_commits
  local latest
  local minor_update=""

  echo "=========================================="
  echo "Checking for alpine base image tag updates"
  echo "=========================================="

  latest=$(_get_image_tags "${base_image}" "(?<=${version//\./\\.}-)[0-9.]+")

  if [[ -z "${latest}" ]]; then
    echo >&2 "Failed to acquire latest image tag"
    exit 1
  fi

  current=$(grep -oP "(?<=BASE_IMAGE_STABILITY_TAG: )[0-9.]+$" .github/workflows/workflow.yml || true)
  if [[ -z "${current}" ]]; then
    echo >&2 "Failed to acquire current base image stability tag"
    exit 1
  fi

  if [[ $(compare_semver "${latest}" "${current}") == 0 ]]; then
    sed -i -E "s/(BASE_IMAGE_STABILITY_TAG: )${current}/\1${latest}/" .github/workflows/workflow.yml

    _git_commit ./ "Update base image stability tag to ${latest}"
  else
    release_tag=""
    echo "Base image stability tag ${current} is already the latest"
  fi

  branch_name=$(git rev-parse --abbrev-ref HEAD)
  had_local_commits=""
  if _head_has_unpushed_commits "${branch_name}"; then
    had_local_commits=1
  fi
  git push origin

  if [[ -n "${release_tag}" ]]; then
    # In case there were no new commits but the base image was updated we want to force rebuild latest images.
    if [[ -z "${had_local_commits}" ]]; then
      git commit --allow-empty -m "Rebuild against updated Alpine"
      git push origin
    fi
    if [[ "$(_get_minor_series "${current}")" != "$(_get_minor_series "${latest}")" ]]; then
      minor_update=1
    fi

    _release_tag "Base image stability tag updated to ${latest}" "${minor_update}"
  fi
}

_update_stability_tag() {
  local version="${1}"
  local base_image="${2}"
  local branch="${3}"
  local tag=""
  local minor_update=""
  local latest
  local current

  echo "=================================="
  echo "Checking for stability tag updates"
  echo "=================================="

  if [[ -n "${branch}" ]]; then
    git checkout "${branch}"
    git merge --no-edit master
  fi

  latest=$(_get_image_tags "${base_image}" "(?<=${version//\./\\.}-)[0-9.]+")

  if [[ -z "${latest}" ]]; then
    echo >&2 "Failed to acquire latest image tag"
    exit 1
  fi

  current=$(grep -oP "(?<=BASE_IMAGE_STABILITY_TAG: )[0-9.]+$" .github/workflows/workflow.yml || true)
  if [[ -z "${current}" ]]; then
    echo >&2 "Failed to acquire current base image stability tag"
    exit 1
  fi

  if [[ $(compare_semver "${latest}" "${current}") == 0 ]]; then
    sed -i -E "s/(BASE_IMAGE_STABILITY_TAG: )${current}/\1${latest}/" .github/workflows/workflow.yml
    _git_commit ./ "Update base image stability tag to ${latest}"
    git push origin
    tag=1
  else
    echo "Base image stability tag ${current} is already the latest"
  fi

  if [[ -n "${tag}" ]]; then
    if [[ "$(_get_minor_series "${current}")" != "$(_get_minor_series "${latest}")" ]]; then
      minor_update=1
    fi

    _release_tag "Base image stability tag updated to ${latest}" "${minor_update}"
  fi

  if [[ -n "${branch}" ]] && _head_has_unpushed_commits "${branch}"; then
    git push origin
  fi
}

sync_solr_fork() {
  git clone "https://${GITHUB_MACHINE_USER}:${GITHUB_MACHINE_USER_API_TOKEN}@github.com/wodby/base-solr" /tmp/base-solr
  cd /tmp/base-solr
  git remote add upstream "https://github.com/docker-solr/docker-solr"
  git fetch upstream
  git merge --strategy-option ours --no-edit upstream/master

  ./tools/update.sh

  _git_commit ./ "Update from upstream"
  git push origin
}

update_from_base_image() {
  local image="${1}"
  local version_list="${2}"
  local base_image

  _git_clone "${image}"

  base_image=$(_get_base_image)

  _update_versions "${version_list}" "${base_image}" "${image#*/}"
  _update_timestamps "${version_list}" "${base_image}" "${image}"
}

rebuild_and_rebase() {
  local image="${1}"
  local version_list="${2}"
  local branch="${3}"
  local base_image=

  _git_clone "${image}"

  base_image=$(_get_base_image)

  IFS=' ' read -r -a array <<<"${version_list}"

  if [[ -n "${branch}" ]]; then
    _update_timestamps "${version_list}" "${base_image}"
  fi

  _update_stability_tag "${array[0]}" "${base_image}" "${branch}"
}

update_base_alpine() {
  local image="${1}"
  local version="${2}"
  local release_tag="${3}"
  local base_image="wodby/alpine"

  _git_clone "${image}"

  if [[ ! -f ".alpine" ]]; then
    echo >&2 "ERROR: Missing .alpine file!"
    exit 1
  fi

  _update_timestamps "${version}" "${base_image}"
  _update_base_alpine_image "${version}" "${base_image}" "${release_tag}"
}

update_from_upstream() {
  local image="${1}"
  local version_list="${2}"
  local upstream="${3%:*}"
  local branch="${4}"
  local release_source="${5:-}"

  _git_clone "${image}"

  _update_versions "${version_list}" "${upstream}" "${image#*/}" "${branch}" "${release_source}"
}

update_docker4x() {
  local project="${1}"
  local branch="${2}"

  local -a lines=()
  local -a tags=()
  local image
  local env_var
  local current
  local latest

  local name="${image#*/}"

  _git_clone "${project}"

  mapfile -t lines < <(grep -hoP "(?<=image: )wodby\/.+" compose*.yml || true)

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

    mapfile -t tags < <(grep -oP "(?<=${env_var}=).+" .env || true)
    if [[ "${#tags[@]}" == 0 ]]; then
      echo >&2 "Failed to acquire current tags for ${env_var}"
      exit 1
    fi

    if [[ "${tags[0]}" == "latest" ]]; then
      continue
    fi

    current="${tags[0]##*-}"
    name="${image#*/}"

    latest=$(_get_image_tags "${image}" "(?<=-)([0-9]+\.){2}[0-9]+")

    # If no stability tags have been found, try searching one without a version (e.g. xhprof image).
    if [[ -z "${latest}" ]]; then
      latest=$(_get_image_tags "${image}" "^([0-9]+\.){2}[0-9]+")
    fi

    if [[ -z "${latest}" ]]; then
      echo >&2 "Failed to acquire latest image tag"
      exit 1
    fi

    if [[ $(compare_semver "${latest}" "${current}") == 0 ]]; then
      sed -i -E "s/^(${env_var}=[0-9.-]+?)${current}$/\1${latest}/" .env

      # Update tests.
      find tests/ -name .env -exec sed -i -E "s/^(#?${env_var}=[0-9.]+(:?-dev|-dev-macos)?-)${current}$/\1${latest}/" .env {} +

      # Update env var like like $DRUPAL_STABILITY_TAG in tests.
      if [[ "${name}" == "${project#*docker4}" ]]; then
        find tests/ -name .env -exec sed -i -E "s/^(${name^^}_STABILITY_TAG)=.+$/\1=${latest}/" .env {} +
      fi

      _git_commit ./ "Update ${name} stability tag to ${latest}"
      git push origin
    else
      echo "${name}: stability tag ${current} is already latest"
    fi
  done
}

update_drupal_vanilla() {
  echo "Updating Drupal 11"
  _git_clone "wodby/drupal-vanilla"
  _git_clone "drupal/recommended-project"
  _install_composer
  latest_ver=$(git show-ref --tags | grep -P -o '(?<=refs/tags/)11\.[0-9]+\.[0-9]+$' | sort -rV | head -n1 || true)
  if [[ -z "${latest_ver}" ]]; then
    echo >&2 "Failed to detect latest Drupal 11 version"
    exit 1
  fi
  git checkout "${latest_ver}"
  cp composer.json composer.lock /tmp/drupal-vanilla
  cd /tmp/drupal-vanilla
  # Upstream Drupal releases can temporarily pin packages that Composer 2.9
  # blocks during lock refresh. Allow adding the downstream Drush dependency
  # and lockfile refresh in one step.
  composer require --dev drush/drush --no-install --ignore-platform-reqs --no-security-blocking
  _git_commit /tmp/drupal-vanilla "Update Drupal 11"
  git push origin

  echo "Updating Drupal 10"
  cd /tmp/drupal-vanilla
  git checkout 10.x
  cd /tmp/recommended-project
  latest_ver=$(git show-ref --tags | grep -P -o '(?<=refs/tags/)10\.[0-9]+\.[0-9]+$' | sort -rV | head -n1 || true)
  if [[ -z "${latest_ver}" ]]; then
    echo >&2 "Failed to detect latest Drupal 10 version"
    exit 1
  fi
  git checkout "${latest_ver}"
  cp composer.json composer.lock /tmp/drupal-vanilla
  cd /tmp/drupal-vanilla
  composer require --dev drush/drush --no-install --ignore-platform-reqs --no-security-blocking
  _git_commit /tmp/drupal-vanilla "Update Drupal 10"
  git push origin

  echo "Updating Drupal 7"
  cd /tmp/drupal-vanilla
  git checkout 7.x
  _git_clone "drupal-composer/drupal-project"
  git checkout 7.x
  cp -R composer.json drush scripts phpunit.xml.dist /tmp/drupal-vanilla
  _git_commit /tmp/drupal-vanilla "Update Drupal 7"
  git push origin
}

update_wordpress_vanilla() {
  echo "Updating WordPress"
  # Drupal CMS source has no composer.lock file by default.
  _git_clone "wodby/wordpress-vanilla"
  _install_composer
  composer update --no-install --ignore-platform-reqs
  _git_commit /tmp/wordpress-vanilla "Update WordPress"
  git push origin
}

update_drupal_cms_template() {
  echo "Updating Drupal CMS 2.x template"
  _git_clone "wodby/drupal-cms-template"
  git clone "https://git.drupalcode.org/project/cms.git" /tmp/cms
  cd /tmp/cms
  latest_ver=$(git show-ref --tags | grep -P -o '(?<=refs/tags/)2\.[0-9]+\.[0-9]+$' | sort -rV | head -n1 || true)
  if [[ -z "${latest_ver}" ]]; then
    echo >&2 "Failed to detect latest Drupal CMS 2 version"
    exit 1
  fi
  git checkout "${latest_ver}"
  cp -R assets config composer.json /tmp/drupal-cms-template
  _assert_all_entries_copied /tmp/cms /tmp/drupal-cms-template
  cd /tmp/drupal-cms-template
  # Drupal CMS source has no composer.lock file by default, but this template
  # repo does and it must be refreshed after copying upstream composer.json.
  _install_composer
  composer update --no-install --ignore-platform-reqs --no-security-blocking
  _git_commit /tmp/drupal-cms-template "Update Drupal CMS 2.x"
  git push origin
}
