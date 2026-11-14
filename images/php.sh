#!/usr/bin/env bash

set -e

. "$(dirname "${BASH_SOURCE[0]}")/../update.sh"

PHP_VERSIONS="8.5 8.4 8.3 8.2"

# Print the newest apache2 package the Alpine repositories of a PHP base image
# offer. The lookup runs in the base image itself, so it sees the same Alpine
# branch and repositories as the -apache build that starts from it.
_apache_package_version() {
  local ref="${1}"
  local output
  local version

  output=$(docker run --rm --entrypoint /bin/sh "${ref}" -c 'apk --no-cache search -x apache2') || {
    echo >&2 "Failed to look up the apache2 package for ${ref}"
    return 1
  }
  version="${output#apache2-}"
  if [[ "${output}" != apache2-* || ! "${version}" =~ ^2\.4\.[0-9]+-r[0-9]+$ ]]; then
    echo >&2 "Expected one Apache 2.4 package for ${ref}, got: ${output}"
    return 1
  fi
  echo "${version}"
}

# Compare Alpine package versions such as 2.4.71-r0, including the revision
# Alpine bumps when it patches a release.
_apk_version_is_newer() {
  local candidate="${1}"
  local current="${2}"

  if [[ "${candidate%-r*}" == "${current%-r*}" ]]; then
    (( ${candidate##*-r} > ${current##*-r} ))
  else
    _version_is_newer "${candidate%-r*}" "${current%-r*}"
  fi
}

_apache_recorded_version() {
  sed -n -E "s/^APACHE_PACKAGE_VERSION_${1//./\\.} := ([^ ]+) *$/\1/p" apache-packages.mk
}

# The -apache images install Alpine's apache2 package, which the PHP base
# images do not contain, so base image updates do not follow Apache releases.
# Record a newer package for each PHP version in apache-packages.mk. The
# changed file rebuilds the images on the default branch, and the release
# names the Apache update.
_update_apache_packages() {
  local version_list="${1}"
  local -a versions=() candidates=() transitions=() apache_versions=()
  local version ref current candidate description
  local updated=
  local i

  if [[ ! -f apache-packages.mk ]]; then
    _report_event manual_review "$(_current_repo_slug)" "Waiting for apache-packages.mk before following Apache package updates"
    echo "Skipping Apache package updates until apache-packages.mk is available"
    return 0
  fi

  echo "============================"
  echo "Checking for Apache updates"
  echo "============================"

  IFS=' ' read -r -a versions <<<"${version_list}"

  # Look up every version before editing, so a failed lookup changes nothing.
  for version in "${versions[@]}"; do
    ref=$(_base_image_ref_for_line "${version}") || return 1
    candidate=$(_apache_package_version "${ref}") || return 1
    candidates+=("${candidate}")
  done

  for ((i = 0; i < ${#versions[@]}; i++)); do
    version="${versions[i]}"
    candidate="${candidates[i]}"
    current=$(_apache_recorded_version "${version}")
    if [[ ! "${current}" =~ ^[0-9.]+-r[0-9]+$ ]]; then
      echo >&2 "No Apache package version for PHP ${version} in apache-packages.mk"
      return 1
    fi

    apache_versions+=("${version}-apache")
    if _apk_version_is_newer "${candidate}" "${current}"; then
      echo "Apache for PHP ${version}: ${current} -> ${candidate}"
      sed -i -E "s/^(APACHE_PACKAGE_VERSION_${version//./\\.} := ).*/\1${candidate}/" apache-packages.mk
      transitions+=("${current} -> ${candidate}")
      updated=1
    else
      echo "Apache for PHP ${version} is already ${current}"
      transitions+=("")
    fi
  done

  if [[ -z "${updated}" ]]; then
    return 0
  fi

  description="Apache updates: $(_transitions_description "wodby/php" "${apache_versions[*]}" "${transitions[@]}")"
  _git_commit ./ "${description}"
  _git_push origin
  _release_tag "${description}" ""
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # One release covers the PHP, Alpine and Apache updates found in this run.
  # The trap still releases updates already pushed when a later step fails.
  _release_batch_start
  trap '_release_batch_finish' EXIT
  update_from_base_image "wodby/php" "${PHP_VERSIONS}"
  _update_apache_packages "${PHP_VERSIONS}"
  trap - EXIT
  _release_batch_finish
fi
