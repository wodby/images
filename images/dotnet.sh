#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../update.sh"

# .NET images build on two Microsoft images per release line: the ASP.NET Core runtime for
# ordinary images and the SDK carrying the same runtime for -dev images. Both live on
# mcr.microsoft.com, not Docker Hub, so this updater selects versions from Microsoft's release
# metadata and resolves tags and digests on that registry.
DOTNET_RELEASE_METADATA="${DOTNET_RELEASE_METADATA:-https://builds.dotnet.microsoft.com/dotnet/release-metadata}"
DOTNET_REGISTRY="${DOTNET_REGISTRY:-https://mcr.microsoft.com}"
DOTNET_INDEX_TYPES='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'

# Prints "<ASP.NET Core runtime> <SDK>" of the newest release in a line such as 10.0.
_dotnet_latest_release() {
  local line="${1}" json
  json=$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 3 "${DOTNET_RELEASE_METADATA}/${line}/releases.json") || {
    echo >&2 "Failed to fetch .NET ${line} release metadata"
    return 1
  }
  jq -er '.releases[0] | "\(."aspnetcore-runtime".version) \(.sdk.version)"' <<<"${json}"
}

# Prints every tag of a repository under dotnet/ on the Microsoft registry.
_dotnet_tags() {
  curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 "${DOTNET_REGISTRY}/v2/dotnet/${1}/tags/list" | jq -er '.tags[]'
}

# Prints the multi-platform index digest of dotnet/<repository>:<tag>.
_dotnet_digest() {
  local digest
  digest=$(curl -fsSI --connect-timeout 10 --max-time 30 --retry 3 -H "Accept: ${DOTNET_INDEX_TYPES}" \
    "${DOTNET_REGISTRY}/v2/dotnet/${1}/manifests/${2}" | tr -d '\r' | sed -nE 's/^docker-content-digest: *//Ip') || return 1
  [[ "${digest}" =~ ^sha256:[a-f0-9]{64}$ ]] || {
    echo >&2 "No index digest for dotnet/${1}:${2}"
    return 1
  }
  echo "${digest}"
}

# Prints the Alpine suffixes (-alpine3.24) published for an exact version tag.
_dotnet_alpine_suffixes() {
  local version="${1//./\\.}"
  grep -oP "^${version}\K-alpine3\.[0-9]+$" || true
}

_update_dotnet() {
  local version_list="${1}"
  local -a lines
  local line key cur_rt cur_sdk new_rt new_sdk current_suffix suffix aspnet_tags sdk_tags candidates
  local pins="" changes="" notes="" commit_message makefile_ver
  local -a version_changes=()

  IFS=' ' read -r -a lines <<<"${version_list}"
  current_suffix=$(sed -nE 's/^BASE_IMAGE_VERSION_SUFFIX := *(-alpine3\.[0-9]+) *$/\1/p' base-images.mk)
  [[ -n "${current_suffix}" ]] || {
    echo >&2 'Expected BASE_IMAGE_VERSION_SUFFIX := -alpine3.N in base-images.mk'
    return 1
  }
  makefile_ver=$(sed -nE 's/^DOTNET_VER \?= *([0-9.]+) *$/\1/p' Makefile)
  aspnet_tags=$(_dotnet_tags aspnet) || return 1
  sdk_tags=$(_dotnet_tags sdk) || return 1

  # Pick each line's newest release, then the newest Alpine that has both of its images.
  candidates=""
  declare -A runtime sdk
  for line in "${lines[@]}"; do
    [[ "${line}" =~ ^[0-9]+\.0$ ]] || {
      echo >&2 "Invalid .NET release line: ${line}"
      return 1
    }
    key="DOTNET${line%%.*}"
    cur_rt=$(sed -nE "s/^  ${key}: '?([0-9]+\.[0-9]+\.[0-9]+)'?$/\1/p" .github/workflows/workflow.yml)
    cur_sdk=$(sed -nE "s/^  ${key}_SDK: '?([0-9]+\.[0-9]+\.[0-9]+)'?$/\1/p" .github/workflows/workflow.yml)
    [[ -n "${cur_rt}" && -n "${cur_sdk}" ]] || {
      echo >&2 "Expected ${key} and ${key}_SDK in the build workflow"
      return 1
    }
    read -r new_rt new_sdk < <(_dotnet_latest_release "${line}") || return 1
    [[ "${new_rt}" =~ ^${line//./\\.}\.[0-9]+$ && "${new_sdk}" =~ ^${line%%.*}\.0\.[0-9]+$ ]] || {
      echo >&2 "Expected a stable .NET ${line} release, got runtime '${new_rt}' and SDK '${new_sdk}'"
      return 1
    }
    # Never move a line backwards, for example while the metadata lags a published release.
    if ! _version_is_newer "${new_rt}" "${cur_rt}"; then
      new_rt="${cur_rt}" new_sdk="${cur_sdk}"
    elif ! _version_is_newer "${new_sdk}" "${cur_sdk}"; then
      echo >&2 ".NET ${new_rt} comes with SDK ${new_sdk}, not newer than ${cur_sdk}"
      return 1
    fi
    runtime[${line}]="${new_rt}" sdk[${line}]="${new_sdk}"
    if [[ "${new_rt}" != "${cur_rt}" ]]; then
      version_changes+=("${cur_rt} -> ${new_rt} (SDK ${new_sdk})")
    fi
    local pair
    pair=$(comm -12 <(_dotnet_alpine_suffixes "${new_rt}" <<<"${aspnet_tags}" | sort) \
      <(_dotnet_alpine_suffixes "${new_sdk}" <<<"${sdk_tags}" | sort))
    if [[ -z "${candidates}" ]]; then
      candidates="${pair}"
    else
      candidates=$(comm -12 <(sort <<<"${candidates}") <(sort <<<"${pair}"))
    fi
    [[ -n "${candidates}" ]] || {
      echo >&2 "No Alpine release has both dotnet/aspnet:${new_rt} and dotnet/sdk:${new_sdk}"
      return 1
    }
  done
  suffix=$(sort -V <<<"${candidates}" | tail -n1)
  if _version_is_newer "${current_suffix#-alpine}" "${suffix#-alpine}"; then
    echo >&2 "Refusing to move from ${current_suffix} back to ${suffix}"
    return 1
  fi

  # Resolve every pin before editing anything, so a registry failure changes no file.
  for line in "${lines[@]}"; do
    local tag digest
    for tag in "aspnet ${runtime[${line}]}" "sdk ${sdk[${line}]}"; do
      digest=$(_dotnet_digest "${tag% *}" "${tag#* }${suffix}") || return 1
      pins+="BASE_IMAGE_DIGEST_${tag% *}_${tag#* }${suffix} := ${digest}"$'\n'
    done
  done
  if [[ "${pins}" == "$(grep '^BASE_IMAGE_DIGEST_' base-images.mk)"$'\n' ]]; then
    echo ".NET ${version_list} base images are up to date"
    return 0
  fi

  for line in "${lines[@]}"; do
    key="DOTNET${line%%.*}"
    sed -i -E "s/^(  ${key}: ).*/\1'${runtime[${line}]}'/; s/^(  ${key}_SDK: ).*/\1'${sdk[${line}]}'/" .github/workflows/workflow.yml
    if [[ "${makefile_ver%.*}" == "${line}" ]]; then
      sed -i -E "s/^(DOTNET_VER \?= ).*/\1${runtime[${line}]}/; s/^(DOTNET_SDK_VER \?= ).*/\1${sdk[${line}]}/" Makefile
    fi
  done
  sed -i -E "s/^(BASE_IMAGE_VERSION_SUFFIX := ).*/\1${suffix}/" base-images.mk
  # Replace the pin block in place, keeping the file's other content and order.
  awk -v pins="${pins%$'\n'}" '/^BASE_IMAGE_DIGEST_/ { if (!done) { print pins; done = 1 } next } { print }' \
    base-images.mk > base-images.mk.new && mv base-images.mk.new base-images.mk

  if [[ "${#version_changes[@]}" -gt 0 ]]; then
    notes=".NET updates: $(_join_ws ", " "${version_changes[@]}")"
    commit_message="Update .NET to $(_join_ws ", " "${runtime[@]}")"
  fi
  if [[ "${suffix}" != "${current_suffix}" ]]; then
    changes="Alpine ${current_suffix#-alpine} -> ${suffix#-alpine}"
    notes="${notes:+${notes}; }Microsoft base images moved to ${changes}"
    commit_message="${commit_message:-Move the base images to ${changes}}"
  fi
  # Microsoft rebuilds published tags for base image fixes; those reach images only as a release.
  notes="${notes:-Rebuild on the updated Microsoft .NET base images}"
  commit_message="${commit_message:-Rebuild against updated base image digests}"

  _git_commit ./ "${commit_message}" || return 1
  _git_push origin || return 1
  _release_tag "${notes}" ""
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _git_clone wodby/dotnet
  _update_dotnet "10.0"
fi
