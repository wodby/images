#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../update.sh"

# wodby/redmine builds each Redmine release line (7.0, 6.1) on the official Debian image
# redmine:<x.y.z>-trixie. The build workflow records the release as REDMINE70: '7.0.3' and
# base-images.mk pins BASE_IMAGE_DIGEST_7.0.3-trixie. The generic base image updater can't
# be used: on a digest change it compares Alpine versions, and this base is Debian.

REDMINE_BASE_SUFFIX="${REDMINE_BASE_SUFFIX:--trixie}"

# Prints the newest release of a Redmine line that has a Debian image, such as 7.0.3 for 7.0.
_redmine_latest_release() {
  _get_image_tags redmine "^${1//./\\.}\.[0-9]+(?=${REDMINE_BASE_SUFFIX}$)"
}

# Prints the newest release line that has a Debian image, such as 7.1.
_redmine_newest_line() {
  local release
  release=$(_get_image_tags redmine "^[0-9]+\.[0-9]+\.[0-9]+(?=${REDMINE_BASE_SUFFIX}$)") || return 1
  echo "${release%.*}"
}

# Prints the multi-platform index digest of redmine:<tag>.
_redmine_digest() {
  _get_image_digest redmine "${1}"
}

_update_redmine() {
  local line_list="${1}"
  local -a lines version_changes=()
  local line key current latest newest_line pins="" notes commit_message makefile_ver
  declare -A version

  IFS=' ' read -r -a lines <<<"${line_list}"
  makefile_ver=$(sed -nE 's/^REDMINE_VER \?= *([0-9.]+) *$/\1/p' Makefile)

  for line in "${lines[@]}"; do
    [[ "${line}" =~ ^[0-9]+\.[0-9]+$ ]] || {
      echo >&2 "Invalid Redmine line: ${line}"
      return 1
    }
    key="REDMINE${line//./}"
    current=$(sed -nE "s/^  ${key}: '?(${line//./\\.}\.[0-9]+)'?$/\1/p" .github/workflows/workflow.yml)
    [[ -n "${current}" ]] || {
      echo >&2 "Expected ${key} in the build workflow"
      return 1
    }
    latest=$(_redmine_latest_release "${line}") || return 1
    [[ "${latest}" =~ ^${line//./\\.}\.[0-9]+$ ]] || {
      echo >&2 "Unexpected Redmine ${line} release: ${latest}"
      return 1
    }
    # Never move a line backwards.
    if _version_is_newer "${latest}" "${current}"; then
      version[${line}]="${latest}"
      version_changes+=("${current} -> ${latest}")
    else
      version[${line}]="${current}"
    fi
  done

  # Resolve every pin before editing anything, so a registry failure changes no file. The
  # official image is rebuilt under the same tag when Debian or Ruby updates, so unchanged
  # releases are compared too.
  for line in $(printf '%s\n' "${lines[@]}" | sort -V); do
    local tag digest
    tag="${version[${line}]}${REDMINE_BASE_SUFFIX}"
    digest=$(_redmine_digest "${tag}") || return 1
    [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
      echo >&2 "Invalid digest for redmine:${tag}"
      return 1
    }
    pins+="BASE_IMAGE_DIGEST_${tag} := ${digest}"$'\n'
  done

  # A new release line needs a new image line and service option, so it is only reported.
  newest_line=$(_redmine_newest_line) || newest_line=""
  line=$(printf '%s\n' "${lines[@]}" | sort -V | tail -n1)
  if [[ -n "${newest_line}" ]] && _version_is_newer "${newest_line}.0" "${line}.0"; then
    _report_event manual_review "$(_current_repo_slug)" \
      "Redmine ${newest_line} is released; add an image line and a service option for it"
  fi

  # Compare as sets: the order of the pins in base-images.mk doesn't matter.
  if [[ "$(sort <<<"${pins%$'\n'}")" == "$(grep '^BASE_IMAGE_DIGEST_' base-images.mk | sort)" ]]; then
    echo "Redmine ${line_list} base images are up to date"
    return 0
  fi

  for line in "${lines[@]}"; do
    key="REDMINE${line//./}"
    sed -i -E "s/^(  ${key}: ).*/\1'${version[${line}]}'/" .github/workflows/workflow.yml
    if [[ "${makefile_ver%.*}" == "${line}" ]]; then
      sed -i -E "s/^(REDMINE_VER \?= ).*/\1${version[${line}]}/" Makefile
    fi
  done
  # Replace the pin block in place, keeping the file's other content and order.
  awk -v pins="${pins%$'\n'}" '/^BASE_IMAGE_DIGEST_/ { if (!done) { print pins; done = 1 } next } { print }' \
    base-images.mk > base-images.mk.new && mv base-images.mk.new base-images.mk

  if [[ "${#version_changes[@]}" -gt 0 ]]; then
    notes="Redmine updates: $(_join_ws ", " "${version_changes[@]}")"
    commit_message="Update Redmine to $(_join_ws ", " "${version_changes[@]##* -> }")"
  else
    notes="Rebuild on the updated official Redmine base images"
    commit_message="Rebuild against updated base image digests"
  fi

  _git_commit ./ "${commit_message}" || return 1
  _git_push origin || return 1
  _release_tag "${notes}" ""
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _git_clone wodby/redmine
  _require_base_image_pins || exit 0
  _update_redmine "7.0 6.1"
fi
