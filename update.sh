#!/usr/bin/env bash

set -e
set -o pipefail

IMAGES_REPO_ROOT="${IMAGES_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
IMAGES_HOST_ROOT="${IMAGES_HOST_ROOT:-${IMAGES_REPO_ROOT}}"

if [[ -n "${DEBUG:-}" ]]; then
  set -x
fi

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

_ensure_git_identity() {
  local email
  local name

  email=$(git config --get user.email || true)
  name=$(git config --get user.name || true)

  if [[ -z "${email}" && -n "${WODBOT_GIT_EMAIL:-}" ]]; then
    git config --local user.email "${WODBOT_GIT_EMAIL}"
  fi

  if [[ -z "${name}" && -n "${WODBOT_GIT_NAME:-}" ]]; then
    git config --local user.name "${WODBOT_GIT_NAME}"
  fi
}

_current_repo_slug() {
  local url
  local slug

  url=$(git config --get remote.origin.url || true)
  slug="${url#https://}"
  slug="${slug#*@github.com/}"
  slug="${slug#github.com/}"
  slug="${slug#git@github.com:}"
  slug="${slug%.git}"

  if [[ -z "${slug}" || "${slug}" == "${url}" ]]; then
    slug=$(basename "$(pwd)")
  fi

  echo "${slug}"
}

_report_event() {
  local type="${1}"
  local repo="${2}"
  local message="${3}"
  local version="${4:-}"
  local previous="${5:-}"
  local report_dir

  if [[ -z "${IMAGES_UPDATE_REPORT_FILE:-}" ]]; then
    return 0
  fi

  if [[ -z "${repo}" ]]; then
    repo=$(_current_repo_slug)
  fi

  report_dir=$(dirname "${IMAGES_UPDATE_REPORT_FILE}")
  mkdir -p "${report_dir}"

  if ! jq -nc \
    --arg type "${type}" \
    --arg repo "${repo}" \
    --arg message "${message}" \
    --arg version "${version}" \
    --arg previous "${previous}" \
    --arg dir "${IMAGES_UPDATE_DIR:-}" \
    --arg script "${IMAGES_UPDATE_SCRIPT:-}" \
    '{
      type: $type,
      repo: $repo,
      message: $message,
      version: $version,
      previous: $previous,
      dir: $dir,
      script: $script,
      created_at: (now | todateiso8601)
    }' >> "${IMAGES_UPDATE_REPORT_FILE}"; then
    echo >&2 "Failed to write update report event"
  fi
}

_git_commit() {
  local dir="${1}"
  local msg="${2}"
  local report_event="${3:-1}"

  cd "${dir}"
  git add -A

  if ! git diff --cached --quiet; then
    _ensure_git_identity
    git commit -m "${msg}"
    if [[ "${report_event}" != "0" ]]; then
      _report_event "commit" "$(_current_repo_slug)" "${msg}"
    fi
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

_get_image_digest() {
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

  jq -er '.digest | select(type == "string" and startswith("sha256:"))' <<<"${response}" || {
    echo >&2 "Failed to parse Docker Hub digest for ${namespace}/${name}:${tag}"
    exit 1
  }
}

# Invoke the pin editor against the cloned image repository, not the updater checkout.
_base_image_pins() {
  python3 "${IMAGES_REPO_ROOT}/scripts/base_images.py" "$@"
}

# Permit the updater to ship before individual repositories complete the migration.
_require_base_image_pins() {
  if [[ ! -f base-images.mk ]]; then
    _report_event manual_review "$(_current_repo_slug)" "Waiting for digest-pinned base image build inputs"
    echo "Skipping base image updates until base-images.mk is available"
    return 1
  fi
  _base_image_pins repository >/dev/null || exit 1
}

# Avoid merging a migrated default branch into an unmigrated stability branch.
_require_digest_branch() {
  local branch="${1:-}"
  if [[ -f base-images.mk && -n "${branch}" ]] && ! git cat-file -e "origin/${branch}:base-images.mk" 2>/dev/null; then
    _report_event manual_review "$(_current_repo_slug)" "Waiting for digest-pinned build inputs on ${branch}"
    echo "Skipping updates until ${branch} has digest-pinned build inputs"
    return 1
  fi
}

# Select the base actually used by the workflow, including its stability tag.
_base_image_ref_for_line() {
  local stability
  stability=$(sed -nE 's/^  BASE_IMAGE_STABILITY_TAG: ([0-9.]+)$/\1/p' .github/workflows/workflow.yml)
  _base_image_pins ref --line "$1" --stability "${stability}"
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

_publishing_enabled() {
  [[ "${IMAGES_UPDATE_PUSH:-0}" == "1" ]]
}

_git_push() {
  if ! _publishing_enabled; then
    echo "Publishing is disabled for this validation run"
    return 0
  fi

  git push "$@"
}

_latest_release_tag() {
  local described_tag
  local major
  local tag

  described_tag=$(git describe --abbrev=0 --tags) || {
    echo >&2 "Failed to find the current release tag"
    return 1
  }

  if [[ ! "${described_tag}" =~ ^([0-9]+)\.[0-9]+\.[0-9]+$ ]]; then
    echo >&2 "Current release tag is not semantic: ${described_tag}"
    return 1
  fi
  major="${BASH_REMATCH[1]}"

  # git describe returns the closest tag in the commit graph, which can be an
  # older release after branches have been merged. Release tag names are
  # repository-wide, so select the greatest semantic tag in the same major
  # release line before calculating the next version.
  while IFS= read -r tag; do
    if [[ "${tag}" =~ ^${major}\.[0-9]+\.[0-9]+$ ]]; then
      echo "${tag}"
      return 0
    fi
  done < <(git tag --list "${major}.*" --sort=-version:refname)

  echo >&2 "Failed to find a semantic release tag in major line ${major}"
  return 1
}

_next_release_tag() {
  local minor_update="${1}"
  local current_tag
  local tag
  local -a sem_ver

  current_tag=$(_latest_release_tag) || return 1
  IFS="." read -r -a sem_ver <<<"${current_tag}"

  # Minor version changed.
  if [[ -n "${minor_update}" ]]; then
    ((++sem_ver[1]))
    sem_ver[2]=0
  # Patch version changed.
  else
    ((++sem_ver[2]))
  fi

  tag=$(_join_ws "." "${sem_ver[@]}")
  if git show-ref --verify --quiet "refs/tags/${tag}"; then
    echo >&2 "Refusing to overwrite existing release tag ${tag}"
    return 1
  fi

  echo "${tag}"
}

_release_tag() {
  if ! _publishing_enabled; then
    echo "Skipping release tag because publishing is disabled"
    return 0
  fi

  local message="${1}"
  local minor_update="${2}"
  local tag

  tag=$(_next_release_tag "${minor_update}") || return 1

  _ensure_git_identity
  git tag -m "${message}" "${tag}"
  _git_push origin "${tag}"
  _report_event "release_tag" "$(_current_repo_slug)" "${message}" "${tag}"
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
  local user="${WODBOT_GITHUB_USERNAME}:${WODBOT_GITHUB_PAT}"
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

_github_api() {
  local path="${1}"

  if [[ -z "${WODBOT_GITHUB_PAT:-}" ]]; then
    echo >&2 "WODBOT_GITHUB_PAT is required for GitHub API requests"
    return 1
  fi

  curl -fsSL \
    --connect-timeout 10 \
    --max-time 30 \
    --retry 3 \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${WODBOT_GITHUB_PAT}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/${path}"
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

_git_get_versions() {
  local version="${1}"
  local url="${2}"
  local name="${3}"
  local tag_prefixes="${4:-}"
  local refs

  local -a versions
  local -a prefixes

  IFS=' ' read -r -a prefixes <<<"${tag_prefixes}"

  refs=$(git ls-remote --tags "https://${url}.git") || {
    echo >&2 "Failed to fetch git tags from ${url}"
    exit 1
  }

  mapfile -t versions < <(
    awk '{print $2}' <<<"${refs}" \
      | sed -E 's#^refs/tags/##; s#\^\{\}$##' \
      | while IFS= read -r tag; do
          tag="${tag#releases/${name}/}"
          tag="${tag#${name}-}"
          for prefix in "${prefixes[@]}"; do
            tag="${tag#${prefix}}"
          done
          tag="${tag#release-}"
          if [[ "${tag}" =~ ^v[0-9] ]]; then
            tag="${tag#v}"
          fi
          printf '%s\n' "${tag}"
        done \
      | grep -oP "^[0-9.]+$" \
      | grep -P "^${version//\./\\.}(\.|$)" \
      | sort -rV \
      | uniq || true
  )

  if [[ "${#versions[@]}" == 0 ]]; then
    echo >&2 "Couldn't find latest version in line ${version} of ${url}."
    exit 1
  fi

  printf '%s\n' "${versions[@]}"
}

_packagist_list_versions() {
  local package="${1}"
  local response
  local pkg_encoded="${package//\//%2F}"

  response=$(curl -fsSL "https://repo.packagist.org/p2/${pkg_encoded}.json") || {
    echo >&2 "Failed to fetch package metadata from Packagist for ${package}"
    exit 1
  }

  jq -r --arg package "${package}" '.packages[$package][]?.version' <<<"${response}" \
    | sed -E 's/^(v|release-)//' \
    | grep -oP "^[0-9.]+$" \
    | sort -rV \
    | uniq || true
}

_packagist_get_versions() {
  local version="${1}"
  local package="${2}"

  local -a versions

  mapfile -t versions < <(
    _packagist_list_versions "${package}" \
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

_packagist_has_version() {
  local version="${1}"
  local package="${2}"

  _packagist_list_versions "${package}" | grep -qx "${version}"
}

_url_exists() {
  local url="${1}"

  if [[ "${url}" == https://builds.matomo.org/* ]]; then
    curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 -o /dev/null "${url}"
    return $?
  fi

  curl -fsSIL --connect-timeout 10 --max-time 30 --retry 3 -o /dev/null "${url}" \
    || curl -fsSL --connect-timeout 10 --max-time 30 --retry 3 --range 0-0 -o /dev/null "${url}" \
    || curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 -o /dev/null "${url}"
}

_release_source_has_version() {
  local release_source="${1}"
  local version="${2}"
  local url

  if [[ -z "${release_source}" ]]; then
    return 0
  fi

  if [[ "${release_source}" == packagist:* ]]; then
    _packagist_has_version "${version}" "${release_source#packagist:}"
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
  local tag_prefixes="${5:-}"
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
  elif [[ "${upstream}" == "code.vinyl-cache.org"* ]]; then
    mapfile -t versions < <(_git_get_versions "${version}" "${upstream}" "${name}" "${tag_prefixes}")
  # From docker hub, only patch updates.
  else
    local makefilePath
    local dockerfilePath
    local suffix="(?=$)"

    makefilePath=$(find . -name Makefile -maxdepth 2 | head -n 1)
    dockerfilePath=$(find . -name Dockerfile -maxdepth 2 | head -n 1)

    # Match the build's exact variant, including PHP's fpm-alpine suffix.
    if [[ -f base-images.mk && "$(_base_image_pins repository)" == "${upstream}" ]]; then
      local variant
      variant=$(_base_image_pins suffix) || return 1
      suffix="(?=${variant}$)"
    elif grep -qP "BASE_IMAGE_TAG.+?-alpine" "${makefilePath}" || grep -qP "^FROM .+?-alpine" "${dockerfilePath}"; then
      suffix="(?=\-alpine$)"
    fi

    latest_ver=$(_get_image_tags "${upstream}" "^(${version//\./\\.}\.[0-9.]+)${suffix}")
    echo "${latest_ver}"
    return 0
  fi

  if [[ -n "${release_source}" ]]; then
    local candidate

    # Use the same release source that image Dockerfiles use for builds, so
    # upstream update detection only selects versions the build can fetch.
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

  git clone "https://${WODBOT_GITHUB_USERNAME}:${WODBOT_GITHUB_PAT}@github.com/${slug}" "/tmp/${slug#*/}"
  cd "/tmp/${slug#*/}"
}

_get_go_downloads_metadata() {
  local response

  response=$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 3 "https://go.dev/dl/?mode=json") || {
    echo >&2 "Failed to fetch Go downloads metadata"
    exit 1
  }

  jq -e 'type == "array" and any(.[]; .stable == true and (.version | type == "string"))' \
    <<<"${response}" >/dev/null || {
      echo >&2 "Failed to parse Go downloads metadata"
      exit 1
    }

  echo "${response}"
}

_get_latest_go_patch_version() {
  local current="${1}"
  local response="${2}"
  local series

  series=$(_get_minor_series "${current}")

  jq -r '.[] | select(.stable == true) | .version | ltrimstr("go")' <<<"${response}" \
    | grep -E "^${series//./\\.}\\.[0-9]+$" \
    | sort -rV \
    | head -n1 \
    || true
}

_get_latest_complete_gotpl_release() {
  local response
  local version

  response=$(_github_api "repos/wodby/gotpl/releases?per_page=20") || return 1
  version=$(jq -r '
    [
      .[]
      | select(.draft == false and .prerelease == false)
      | select(
          ([.assets[]?.name] | index("gotpl-linux-amd64.tar.gz")) != null
          and ([.assets[]?.name] | index("gotpl-linux-arm64.tar.gz")) != null
        )
      | .tag_name
    ][0] // ""
  ' <<<"${response}") || {
    echo >&2 "Failed to parse gotpl releases"
    return 1
  }

  version="${version#v}"
  if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo >&2 "Failed to find a stable gotpl release with amd64 and arm64 artifacts"
    return 1
  fi

  echo "${version}"
}

_get_base_image() {
  if [[ -f base-images.mk ]]; then
    _base_image_pins repository
    return
  fi
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
  local branch="${4:-}"
  local release_source="${5:-}"
  local tag_prefixes="${6:-}"

  local updated=()
  local latest_ver
  local cur_ver
  local cur_series
  local dir
  local has_quotes
  local latest_series

  local minor_update=""
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

    latest_ver=$(_get_latest_version "${upstream}" "${version}" "${name}" "${release_source}" "${tag_prefixes:-}")
    latest_series=$(_get_minor_series "${latest_ver}")
    cur_series=$(_get_minor_series "${cur_ver}")

    if _version_is_newer "${latest_ver}" "${cur_ver}"; then
      echo "${name^} ${cur_ver} is outdated, updating to ${latest_ver}"

      if [[ -f base-images.mk && "$(_base_image_pins repository)" == "${upstream}" ]]; then
        _base_image_pins version --old "${cur_ver}" --new "${latest_ver}" || return 1
      fi

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

      _git_commit ./ "Update ${name} to ${latest_ver}"
      updated+=("${cur_ver} -> ${latest_ver}")
    else
      echo "Version ${cur_ver} is already the latest version"
    fi
  done

  if [[ "${#updated[@]}" != 0 ]]; then
    _git_push origin

    if [[ -n "${branch}" ]]; then
      git checkout "${branch}"
      _ensure_git_identity
      git merge --no-edit master
      _git_push origin
    fi

    local ver
    ver=$(_join_ws ", " "${updated[@]}")

    _release_tag "${name} updates: ${ver}" "${minor_update}"
  fi
}

# Group identical Alpine transitions, naming only exceptions when there is one
# shared update. Keep distinct transitions associated with their image tags.
_alpine_release_description() {
  local image="${1}"
  local version_list="${2}"
  shift 2
  local -a transitions=("$@") versions=() groups=() descriptions=()
  local -a affected=() excluded=()
  local transition group found i
  IFS=' ' read -r -a versions <<<"${version_list}"

  for transition in "${transitions[@]}"; do
    [[ -n "${transition}" ]] || continue
    found=""
    for group in "${groups[@]}"; do
      [[ "${group}" != "${transition}" ]] || found=1
    done
    [[ -n "${found}" ]] || groups+=("${transition}")
  done

  for group in "${groups[@]}"; do
    affected=()
    excluded=()
    for ((i = 0; i < ${#versions[@]}; i++)); do
      if [[ "${transitions[i]}" == "${group}" ]]; then
        affected+=("${image}:${versions[i]}")
      else
        excluded+=("${image}:${versions[i]}")
      fi
    done
    if [[ "${#groups[@]}" == 1 ]]; then
      if [[ "${#excluded[@]}" == 0 ]]; then
        descriptions+=("${group}")
      else
        descriptions+=("${group} (except $(_join_ws ", " "${excluded[@]}"))")
      fi
    else
      descriptions+=("${group} ($(_join_ws ", " "${affected[@]}"))")
    fi
  done
  printf 'Alpine Linux updates: %s' "$(_join_ws "; " "${descriptions[@]}")"
}

# Refresh content pins even when upstream versions and stability tags are unchanged.
_update_digests() {
  local version_list="${1}"
  local base_image="${2}"
  local image="${3:-}"
  local changes version previous current cur_alpine_ver latest_alpine_ver
  local minor_update="" alpine_updated="" alpine_transition ver_list
  local -a versions=() previous_refs=() alpine_transitions=()

  _require_base_image_pins || return 0
  IFS=' ' read -r -a versions <<<"${version_list}"
  if [[ -n "${image}" && "${base_image}" != alpine* ]]; then
    for version in "${versions[@]}"; do
      previous=$(_base_image_ref_for_line "${version}") || return 1
      previous_refs+=("${previous}")
    done
  fi
  changes=$(_base_image_pins refresh) || return 1
  if [[ -z "${changes}" ]]; then
    echo "Base image digests have not changed"
    return 0
  fi
  printf '%s\n' "${changes}"

  local i=0
  for version in "${versions[@]}"; do
    alpine_transition=""
    if [[ -n "${image}" && "${base_image}" != alpine* ]]; then
      previous="${previous_refs[$i]}"
      current=$(_base_image_ref_for_line "${version}") || return 1
      if [[ "${previous}" != "${current}" ]]; then
        cur_alpine_ver=$(_get_alpine_ver "${image}:${version}") || return 1
        latest_alpine_ver=$(_get_alpine_ver "${current}") || return 1
        if _version_is_newer "${latest_alpine_ver}" "${cur_alpine_ver}"; then
          if [[ "$(_get_minor_series "${latest_alpine_ver}")" != "$(_get_minor_series "${cur_alpine_ver}")" ]]; then
            minor_update=1
          fi
          alpine_transition="${cur_alpine_ver} -> ${latest_alpine_ver}"
          alpine_updated=1
        fi
      fi
    fi
    alpine_transitions+=("${alpine_transition}")
    i=$((i + 1))
  done

  _git_commit ./ "Rebuild against updated base image digests" "0"
  _git_push origin
  if [[ -n "${alpine_updated}" ]]; then
    ver_list=$(_alpine_release_description "${image}" "${version_list}" "${alpine_transitions[@]}")
    _release_tag "${ver_list}" "${minor_update}"
  fi
}

_update_base_alpine_image() {
  # Use the leading line to discover the release, then resolve every pinned line.
  local version="${1%% *}"
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

  if _version_is_newer "${latest}" "${current}"; then
    if [[ -f base-images.mk ]]; then
      _base_image_pins stability --new "${latest}" || return 1
    fi
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
  _git_push origin

  if [[ -n "${release_tag}" ]]; then
    # In case there were no new commits but the base image was updated we want to force rebuild latest images.
    if [[ -z "${had_local_commits}" ]]; then
      _ensure_git_identity
      git commit --allow-empty -m "Rebuild against updated Alpine"
      _report_event "commit" "$(_current_repo_slug)" "Rebuild against updated Alpine"
      _git_push origin
    fi
    if [[ "$(_get_minor_series "${current}")" != "$(_get_minor_series "${latest}")" ]]; then
      minor_update=1
    fi

    _release_tag "Base image ${base_image}: ${version}-${current} -> ${version}-${latest}" "${minor_update}"
  fi
}

_update_stability_tag() {
  local version="${1}"
  local base_image="${2}"
  local branch="${3:-}"
  local tag=""
  local minor_update=""
  local latest
  local current

  echo "=================================="
  echo "Checking for stability tag updates"
  echo "=================================="

  if [[ -n "${branch}" ]]; then
    git checkout "${branch}"
    _ensure_git_identity
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

  if _version_is_newer "${latest}" "${current}"; then
    if [[ -f base-images.mk ]]; then
      _base_image_pins stability --new "${latest}" || return 1
    fi
    sed -i -E "s/(BASE_IMAGE_STABILITY_TAG: )${current}/\1${latest}/" .github/workflows/workflow.yml
    _git_commit ./ "Update base image stability tag to ${latest}"
    _git_push origin
    tag=1
  else
    echo "Base image stability tag ${current} is already the latest"
  fi

  if [[ -n "${tag}" ]]; then
    if [[ "$(_get_minor_series "${current}")" != "$(_get_minor_series "${latest}")" ]]; then
      minor_update=1
    fi

    _release_tag "Base image ${base_image}: ${version}-${current} -> ${version}-${latest}" "${minor_update}"
  fi

  if [[ -n "${branch}" ]] && _head_has_unpushed_commits "${branch}"; then
    _git_push origin
  fi
}

_version_is_newer() {
  local latest="${1}"
  local current="${2}"

  [[ "${latest}" != "${current}" ]] \
    && [[ "$(printf '%s\n%s\n' "${current}" "${latest}" | sort -V | tail -n1)" == "${latest}" ]]
}

_image_ref_tag() {
  local ref_without_digest="${1%@*}"

  echo "${ref_without_digest##*:}"
}

_edge_require_current_or_newer() {
  local dependency="${1}"
  local candidate="${2}"
  local current="${3}"

  if [[ "${candidate}" == "${current}" ]] || _version_is_newer "${candidate}" "${current}"; then
    return 0
  fi

  echo >&2 "Refusing to downgrade ${dependency} from ${current} to ${candidate}"
  return 1
}

_dockerfile_arg_value() {
  local name="${1}"
  local dockerfile="${2:-Dockerfile}"
  local value

  value=$(sed -n -E "s/^ARG ${name}=(.+)$/\\1/p" "${dockerfile}" | head -n1)
  if [[ -z "${value}" ]]; then
    echo >&2 "Failed to find ARG ${name} in ${dockerfile}"
    return 1
  fi

  echo "${value}"
}

_update_dockerfile_arg_image() {
  local name="${1}"
  local image="${2}"
  local digest="${3}"
  local dockerfile="${4:-Dockerfile}"
  local current
  local expected

  current=$(_dockerfile_arg_value "${name}" "${dockerfile}") || return 2
  expected="${image}@${digest}"

  if [[ "${current}" == "${expected}" ]]; then
    echo "${name} is already pinned to ${expected}"
    return 1
  fi

  sed -i -E "s|^ARG ${name}=.*$|ARG ${name}=${expected}|" "${dockerfile}"
  echo "Updated ${name} from ${current} to ${expected}"
}

# Keep runtime source updates on their reviewed compatibility lines. A release
# commit must descend from a pinned commit before replacing that source pin.
_edge_runtime_updates() {
  local dockerfile="${1}"
  local name arg repo line current latest commit_arg commit comparison sha old_sha
  local changed=1
  while read -r name arg repo line commit_arg; do
    current=$(_dockerfile_arg_value "${arg}" "${dockerfile}") || return 2
    current="${current#v}"
    latest=$(_get_latest_version "github.com/${repo}" "${line}" "${name}") || return 2
    [[ "${latest}" =~ ^[0-9]+(\.[0-9]+)+$ && "${latest}" == "${line}."* ]] || {
      echo >&2 "Refusing ${name} release outside compatibility line ${line}: ${latest}"
      return 2
    }
    _edge_require_current_or_newer "${name}" "${latest}" "${current}" || return 2
    [[ "${current}" != "${latest}" ]] || continue
    if [[ "${commit_arg}" != - ]]; then
      _dockerfile_arg_value "${commit_arg}" "${dockerfile}" >/dev/null || return 2
      commit=$(_github_api "repos/${repo}/commits/v${latest}") || return 2
      sha=$(jq -er '.sha | select(test("^[0-9a-f]{40}$"))' <<<"${commit}") || return 2
      sed -i -E "s/^ARG ${commit_arg}=.*/ARG ${commit_arg}=${sha}/" "${dockerfile}"
    fi
    case "${arg}" in
      S6_OVERLAY_VERSION) sed -i -E "s/^ARG ${arg}=.*/ARG ${arg}=${latest}/" "${dockerfile}" ;;
      *) sed -i -E "s/^ARG ${arg}=.*/ARG ${arg}=v${latest}/" "${dockerfile}" ;;
    esac
    _report_event dependency_update wodby/edge-alpine "${name}: ${current} -> ${latest}" "${latest}" "${current}"
    changed=0
  done <<'DEPENDENCIES'
lego LEGO_VERSION go-acme/lego 4 LEGO_COMMIT
s6-overlay S6_OVERLAY_VERSION just-containers/s6-overlay 3 -
etcd-client ETCD_CLIENT_VERSION etcd-io/etcd 3.6 -
DEPENDENCIES

  while read -r name arg repo line; do
    old_sha=$(_dockerfile_arg_value "${arg}" "${dockerfile}") || return 2
    latest=$(_get_latest_version "github.com/${repo}" "${line}" "${name}") || return 2
    [[ "${latest}" =~ ^[0-9]+(\.[0-9]+)+$ && "${latest}" == "${line}."* ]] || {
      echo >&2 "Refusing ${name} release outside compatibility line ${line}: ${latest}"
      return 2
    }
    case "${name}" in
      gotpl) commit=$(_github_api "repos/${repo}/commits/${latest}") || return 2 ;;
      confd) commit=$(_github_api "repos/${repo}/commits/v${latest}") || return 2 ;;
    esac
    sha=$(jq -er '.sha | select(test("^[0-9a-f]{40}$"))' <<<"${commit}") || return 2
    [[ "${sha}" != "${old_sha}" ]] || continue
    comparison=$(_github_api "repos/${repo}/compare/${old_sha}...${sha}") || return 2
    comparison=$(jq -er '.status' <<<"${comparison}") || return 2
    case "${comparison}" in
      ahead)
        sed -i -E "s/^ARG ${arg}=.*/ARG ${arg}=${sha}/" "${dockerfile}"
        _report_event dependency_update wodby/edge-alpine "${name}: update to release ${latest}" "${latest}" "${old_sha}"
        changed=0 ;;
      behind)
        echo "${name}: pinned source is newer than release ${latest}; keeping current source" ;;
      diverged)
        _report_event manual_review wodby/edge-alpine "${name} release ${latest} diverges from pinned source; review required" "${latest}" "${old_sha}" ;;
      *) echo >&2 "Unexpected ${name} comparison: ${comparison}"; return 2 ;;
    esac
  done <<'SOURCES'
gotpl GOTPL_COMMIT wodby/gotpl 0.6
confd CONFD_COMMIT kelseyhightower/confd 0
SOURCES
  return "${changed}"
}

_prepare_edge_alpine_update() {
  local dockerfile="${1:-Dockerfile}"
  local nginx_stability_tag
  local nginx_tag
  local nginx_digest
  local current_nginx_image
  local current_nginx_tag
  local current_nginx_stability_tag
  local go_tag
  local go_digest
  local current_go_image
  local current_go_tag
  local current_go_version
  local candidate_go_version
  local update_status
  local updated=""

  nginx_stability_tag=$(_get_image_tags "wodby/nginx" '(?<=1\.31-)[0-9]+(?:\.[0-9]+)+$') || return 2
  nginx_tag="1.31-${nginx_stability_tag}"
  nginx_digest=$(_get_image_digest "wodby/nginx" "${nginx_tag}") || return 2

  current_nginx_image=$(_dockerfile_arg_value "NGINX_IMAGE" "${dockerfile}") || return 2
  current_nginx_tag=$(_image_ref_tag "${current_nginx_image}")
  if [[ "${current_nginx_tag}" != 1.31-* ]]; then
    echo >&2 "Expected NGINX_IMAGE to remain on the 1.31 compatibility line"
    return 2
  fi
  current_nginx_stability_tag="${current_nginx_tag#1.31-}"
  _edge_require_current_or_newer \
    "wodby/nginx stability tag" \
    "${nginx_stability_tag}" \
    "${current_nginx_stability_tag}" || return 2

  go_tag=$(_get_image_tags "golang" '^1\.26\.[0-9]+-alpine3\.23$') || return 2
  go_digest=$(_get_image_digest "golang" "${go_tag}") || return 2

  current_go_image=$(_dockerfile_arg_value "GO_IMAGE" "${dockerfile}") || return 2
  current_go_tag=$(_image_ref_tag "${current_go_image}")
  if [[ ! "${current_go_tag}" =~ ^1\.26\.[0-9]+-alpine3\.23$ ]]; then
    echo >&2 "Expected GO_IMAGE to remain on the Go 1.26 / Alpine 3.23 compatibility line"
    return 2
  fi
  current_go_version="${current_go_tag%-alpine3.23}"
  candidate_go_version="${go_tag%-alpine3.23}"
  _edge_require_current_or_newer \
    "Go image" \
    "${candidate_go_version}" \
    "${current_go_version}" || return 2

  if _update_dockerfile_arg_image \
    "NGINX_IMAGE" \
    "wodby/nginx:${nginx_tag}" \
    "${nginx_digest}" \
    "${dockerfile}"; then
    updated=1
  else
    update_status=$?
    [[ "${update_status}" -eq 1 ]] || return 2
  fi

  if _update_dockerfile_arg_image \
    "GO_IMAGE" \
    "golang:${go_tag}" \
    "${go_digest}" \
    "${dockerfile}"; then
    updated=1
  else
    update_status=$?
    [[ "${update_status}" -eq 1 ]] || return 2
  fi

  if _edge_runtime_updates "${dockerfile}"; then
    updated=1
  else
    update_status=$?
    [[ "${update_status}" -eq 1 ]] || return 2
  fi

  [[ -n "${updated}" ]]
}

# Resolve the NGINX patch version from the build definition of the pinned
# Wodby image release; its Docker tag only exposes the 1.31 compatibility line.
_edge_nginx_version() {
  local tag
  local release
  local workflow
  local version

  tag=$(_image_ref_tag "${1}")
  release="${tag#1.31-}"
  [[ "${tag}" =~ ^1\.31-[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  workflow=$(_github_api "repos/wodby/nginx/contents/.github/workflows/workflow.yml?ref=${release}") || return 1
  workflow=$(jq -er '.content' <<<"${workflow}" | base64 -d) || return 1
  version=$(sed -n -E "s/^[[:space:]]*NGINX131: ['\"]?([0-9.]+).*$/\\1/p" <<<"${workflow}")
  [[ "${version}" =~ ^1\.31\.[0-9]+$ ]] || return 1
  echo "${version}"
}

# Compare with the last release so notes include all accumulated pin changes.
_edge_release_notes() {
  local previous="${1}"
  local old_dockerfile
  local next_release
  local old_nginx new_nginx old_version new_version
  local old_go new_go old_tag new_tag

  next_release=$(_next_release_tag "") || return 1
  old_dockerfile=$(git show "${previous}:Dockerfile") || return 1
  old_nginx=$(_dockerfile_arg_value NGINX_IMAGE <(printf '%s\n' "${old_dockerfile}")) || return 1
  new_nginx=$(_dockerfile_arg_value NGINX_IMAGE Dockerfile) || return 1
  printf 'Changes since %s\n\n' "${previous}"
  if [[ "${old_nginx}" != "${new_nginx}" ]]; then
    old_version=$(_edge_nginx_version "${old_nginx}") || return 1
    new_version=$(_edge_nginx_version "${new_nginx}") || return 1
    old_tag=$(_image_ref_tag "${old_nginx}")
    new_tag=$(_image_ref_tag "${new_nginx}")
    if [[ "${old_version}" != "${new_version}" ]]; then
      printf -- '- NGINX: %s -> %s.\n' "${old_version}" "${new_version}"
    fi
    if [[ "${old_tag}" != "${new_tag}" ]]; then
      printf -- '- NGINX base image: wodby/nginx:%s -> wodby/nginx:%s.\n' "${old_tag}" "${new_tag}"
    else
      printf -- '- Refresh NGINX base image wodby/nginx:%s (image digest changed).\n' "${new_tag}"
    fi
  fi

  # Builder image changes also trigger releases, including digest-only refreshes.
  old_go=$(_dockerfile_arg_value GO_IMAGE <(printf '%s\n' "${old_dockerfile}")) || return 1
  new_go=$(_dockerfile_arg_value GO_IMAGE Dockerfile) || return 1
  if [[ "${old_go}" != "${new_go}" ]]; then
    old_tag=$(_image_ref_tag "${old_go}")
    new_tag=$(_image_ref_tag "${new_go}")
    if [[ "${old_tag}" != "${new_tag}" ]]; then
      printf -- '- Go builder image: %s -> %s.\n' "${old_tag}" "${new_tag}"
    else
      printf -- '- Refresh Go builder image %s (image digest changed).\n' "${new_tag}"
    fi
  fi
  local arg label old_value new_value
  while read -r arg label; do
    old_value=$(_dockerfile_arg_value "${arg}" <(printf '%s\n' "${old_dockerfile}")) || return 1
    new_value=$(_dockerfile_arg_value "${arg}" Dockerfile) || return 1
    if [[ "${old_value}" != "${new_value}" ]]; then
      case "${arg}" in
        *_COMMIT) printf -- '- Updated %s.\n' "${label}" ;;
        *) printf -- '- %s: %s -> %s.\n' "${label}" "${old_value#v}" "${new_value#v}" ;;
      esac
    fi
  done <<'RUNTIME_NOTES'
LEGO_VERSION lego (certificate issuance and renewal)
S6_OVERLAY_VERSION s6-overlay (service supervision)
ETCD_CLIENT_VERSION etcd client (configuration updates)
GOTPL_COMMIT gotpl (configuration templates)
CONFD_COMMIT confd (configuration generation)
RUNTIME_NOTES
  printf '\nFull changes: https://github.com/wodby/edge-alpine/compare/%s...%s\n' "${previous}" "${next_release}"
}

# Image digest refreshes should rebuild master without creating a release tag.
# Preserve every other Dockerfile change when deciding whether to release.
_edge_update_requires_release() {
  local previous current
  previous=$(git show HEAD:Dockerfile) || return 2
  previous=$(sed -E '/^ARG (NGINX_IMAGE|GO_IMAGE)=/s/@sha256:[^[:space:]]+//' <<<"${previous}") || return 2
  current=$(sed -E '/^ARG (NGINX_IMAGE|GO_IMAGE)=/s/@sha256:[^[:space:]]+//' Dockerfile) || return 2
  [[ "${previous}" != "${current}" ]]
}

update_edge_alpine() {
  local repo="wodby/edge-alpine"
  local prepare_status
  local previous_release
  local release_notes

  _git_clone "${repo}" || return 1

  if _prepare_edge_alpine_update Dockerfile; then
    :
  else
    prepare_status=$?
    if [[ "${prepare_status}" -eq 1 ]]; then
      echo "Edge Alpine image pins are already current"
      return 0
    fi

    echo >&2 "Failed to prepare Edge Alpine dependency updates"
    return "${prepare_status}"
  fi

  if _edge_update_requires_release; then
    :
  else
    prepare_status=$?
    [[ "${prepare_status}" -eq 1 ]] || return "${prepare_status}"
    _git_commit ./ "Refresh pinned image digests" || return 1
    _git_push origin || return 1
    return 0
  fi

  previous_release=$(_latest_release_tag) || return 1
  release_notes=$(_edge_release_notes "${previous_release}") || return 1
  _git_commit ./ "${release_notes}" || return 1
  _git_push origin || return 1

  # Build outcomes belong to the image repository; updates do not wait for CI.
  _release_tag "${release_notes}" "" || return 1
}

sync_solr_fork() {
  git clone "https://${WODBOT_GITHUB_USERNAME}:${WODBOT_GITHUB_PAT}@github.com/wodby/base-solr" /tmp/base-solr
  cd /tmp/base-solr
  git remote add upstream "https://github.com/docker-solr/docker-solr"
  git fetch upstream
  _ensure_git_identity
  git merge --strategy-option ours --no-edit upstream/master

  ./tools/update.sh

  _git_commit ./ "Update from upstream"
  _git_push origin
}

update_from_base_image() {
  local image="${1}"
  local version_list="${2}"
  local base_image

  _git_clone "${image}"
  _require_base_image_pins || return 0

  base_image=$(_get_base_image)

  _update_versions "${version_list}" "${base_image}" "${image#*/}"
  _update_digests "${version_list}" "${base_image}" "${image}"
}

rebuild_and_rebase() {
  local image="${1}"
  local version_list="${2}"
  local branch="${3:-}"
  local base_image=

  _git_clone "${image}"
  _require_base_image_pins || return 0
  _require_digest_branch "${branch}" || return 0

  base_image=$(_get_base_image)

  IFS=' ' read -r -a array <<<"${version_list}"

  _update_digests "${version_list}" "${base_image}"
  _update_stability_tag "${array[0]}" "${base_image}" "${branch}"
  if [[ -n "${branch}" ]]; then
    # The stability branch has its own build inputs after merging the default branch.
    _update_digests "${version_list}" "${base_image}"
  fi
}

update_base_alpine() {
  local image="${1}"
  local version="${2}"
  local release_tag="${3}"
  local base_image="wodby/alpine"

  _git_clone "${image}"

  _require_base_image_pins || return 0

  _update_digests "${version}" "${base_image}"
  _update_base_alpine_image "${version}" "${base_image}" "${release_tag}"
}

update_from_upstream() {
  local image="${1}"
  local version_list="${2}"
  local upstream="${3%:*}"
  local branch="${4:-}"
  local release_source="${5:-}"
  local tag_prefixes="${6:-}"

  _git_clone "${image}"
  _require_digest_branch "${branch}" || return 0

  _update_versions "${version_list}" "${upstream}" "${image#*/}" "${branch}" "${release_source}" "${tag_prefixes}"
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

    if _version_is_newer "${latest}" "${current}"; then
      sed -i -E "s/^(${env_var}=[0-9.-]+?)${current}$/\1${latest}/" .env

      # Update tests.
      find tests/ -name .env -exec sed -i -E "s/^(#?${env_var}=[0-9.]+(:?-dev|-dev-macos)?-)${current}$/\1${latest}/" .env {} +

      # Update env var like like $DRUPAL_STABILITY_TAG in tests.
      if [[ "${name}" == "${project#*docker4}" ]]; then
        find tests/ -name .env -exec sed -i -E "s/^(${name^^}_STABILITY_TAG)=.+$/\1=${latest}/" .env {} +
      fi

      _git_commit ./ "Update ${name} stability tag to ${latest}"
      _git_push origin
    else
      echo "${name}: stability tag ${current} is already latest"
    fi
  done
}

_prepare_alpine_gotpl_update() {
  local dockerfile="${1:-Dockerfile}"
  local latest="${2}"
  local current

  current=$(_dockerfile_arg_value "GOTPL_VERSION" "${dockerfile}") || return 2

  if [[ "${current}" == "${latest}" ]]; then
    echo "Alpine is already pinned to gotpl ${current}"
    return 1
  fi

  if ! _version_is_newer "${latest}" "${current}"; then
    echo >&2 "Refusing to downgrade Alpine gotpl from ${current} to ${latest}"
    return 2
  fi

  sed -i -E "s/^ARG GOTPL_VERSION=.*/ARG GOTPL_VERSION=${latest}/" "${dockerfile}"
  echo "Updated Alpine gotpl from ${current} to ${latest}"
}

update_alpine_gotpl() {
  local current
  local latest
  local prepare_status

  current=$(_dockerfile_arg_value "GOTPL_VERSION" Dockerfile) || return 1
  latest=$(_get_latest_complete_gotpl_release) || return 1

  if _prepare_alpine_gotpl_update Dockerfile "${latest}"; then
    :
  else
    prepare_status=$?
    if [[ "${prepare_status}" -eq 1 ]]; then
      return 0
    fi
    return "${prepare_status}"
  fi

  _git_commit ./ "Update gotpl to ${latest}" || return 1
  _git_push origin || return 1

  # Build outcomes belong to the image repository; updates do not wait for CI.
  _release_tag "gotpl updated from ${current} to ${latest}" "" || return 1
}

update_gotpl_go() {
  local latest
  local current
  local metadata
  local series

  _git_clone "wodby/gotpl"

  current=$(sed -n -E 's/.*go-version: ([0-9.]+).*/\1/p' .github/workflows/workflow.yml | head -n1)

  if [[ -z "${current}" ]]; then
    echo >&2 "Failed to acquire current Go version from gotpl workflow"
    exit 1
  fi

  metadata=$(_get_go_downloads_metadata)
  latest=$(_get_latest_go_patch_version "${current}" "${metadata}")
  series=$(_get_minor_series "${current}")

  # The default Go downloads feed contains the supported release lines. If the
  # configured line is absent, patch-only automation cannot safely move gotpl
  # to a new minor line and must make that visible to operators.
  if [[ -z "${latest}" ]]; then
    echo "Go ${series} used by gotpl is EOL and requires a manual minor-line update"
    _report_event \
      "eol_warning" \
      "wodby/gotpl" \
      "gotpl uses EOL Go ${series}; automatic updates are limited to patches and a supported minor line must be selected manually" \
      "${current}"
    return 0
  fi

  if [[ "${current}" == "${latest}" ]]; then
    echo "Go ${current} is already the latest patch in supported line ${series}"
    return 0
  fi

  if ! _version_is_newer "${latest}" "${current}"; then
    echo "Go downloads metadata reports ${latest} behind configured ${current}; refusing to downgrade"
    _report_event \
      "manual_review" \
      "wodby/gotpl" \
      "Go downloads metadata reports ${latest} behind configured ${current}; automatic downgrade skipped" \
      "${current}" \
      "${latest}"
    return 0
  fi

  sed -i -E "s/(go-version: )[0-9.]+/\1${latest}/" .github/workflows/workflow.yml

  _git_commit ./ "Update Go to ${latest}"
  _git_push origin
  _release_tag "Go updated from ${current} to ${latest}" ""
}
