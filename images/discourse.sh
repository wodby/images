#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../update.sh"

# wodby/discourse publishes one image per Discourse release line: the monthly release and the
# extended support release (ESR). Its build workflow records them as DISCOURSE_RELEASE: '2026.10.0'
# and DISCOURSE_ESR: '2026.7.4'. Each line builds on a dated discourse/base web-only image, the main
# image (2.0.20261028-0019-web-only) for the monthly release and the stable one
# (2.0.20261028-0019-web-only-stable) for the ESR; the Makefile maps a line to its base tag as
# DISCOURSE_BASE_TAG_2026.10, and base-images.mk pins the tags' digests.
#
# The updater moves each line to its newest patch release and newest base image. A new release line
# needs a new image line, base tag mapping and service option, so it is only reported.

# Prints the newest patch release of a Discourse line, such as 2026.10.1 for 2026.10. Pre-release
# tags such as v2026.10.0-latest are skipped.
_discourse_latest_patch() {
  git ls-remote --tags https://github.com/discourse/discourse.git "refs/tags/v${1}.*" \
    | sed -nE "s#^.*refs/tags/v(${1//./\\.}\.[0-9]+)\$#\1#p" | sort -V | tail -n1
}

# Prints the newest release line Discourse has published, such as 2026.11.
_discourse_newest_line() {
  git ls-remote --tags https://github.com/discourse/discourse.git 'refs/tags/v*.0' \
    | sed -nE 's#^.*refs/tags/v([0-9]{4}\.[0-9]+)\.0$#\1#p' | sort -V | tail -n1
}

# Prints the newest dated discourse/base tag with a suffix, such as web-only or web-only-stable.
_discourse_latest_base() {
  _get_image_tags discourse/base "^2\.0\.[0-9]{8}-[0-9]{4}-${1}$"
}

# Prints the multi-platform index digest of discourse/base:<tag>.
_discourse_digest() {
  _get_image_digest discourse/base "${1}"
}

_update_discourse() {
  local key_list="${1}"
  local -a keys changes=() version_changes=()
  local key current line latest base_current base_suffix base_latest newest_line pins="" notes
  local commit_message makefile_ver
  declare -A version base

  IFS=' ' read -r -a keys <<<"${key_list}"
  makefile_ver=$(sed -nE 's/^DISCOURSE_VER \?= *([0-9.]+) *$/\1/p' Makefile)

  for key in "${keys[@]}"; do
    current=$(sed -nE "s/^  ${key}: '?([0-9]{4}\.[0-9]+\.[0-9]+)'?$/\1/p" .github/workflows/workflow.yml)
    [[ -n "${current}" ]] || {
      echo >&2 "Expected ${key} in the build workflow"
      return 1
    }
    line="${current%.*}"

    latest=$(_discourse_latest_patch "${line}") || return 1
    [[ "${latest}" =~ ^${line//./\\.}\.[0-9]+$ ]] || {
      echo >&2 "Unexpected Discourse ${line} release: ${latest}"
      return 1
    }
    # Never move a line backwards.
    if [[ "$(printf '%s\n%s\n' "${current}" "${latest}" | sort -V | tail -n1)" != "${current}" ]]; then
      version[${key}]="${latest}"
      version_changes+=("${current} -> ${latest}")
    else
      version[${key}]="${current}"
    fi

    base_current=$(sed -nE "s/^DISCOURSE_BASE_TAG_${line//./\\.} := *(.+)$/\1/p" Makefile)
    [[ "${base_current}" =~ ^2\.0\.[0-9]{8}-[0-9]{4}-(web-only(-stable)?)$ ]] || {
      echo >&2 "Expected a dated discourse/base tag for Discourse ${line} in the Makefile"
      return 1
    }
    base_suffix="${BASH_REMATCH[1]}"
    base_latest=$(_discourse_latest_base "${base_suffix}") || return 1
    [[ "${base_latest}" =~ ^2\.0\.[0-9]{8}-[0-9]{4}-${base_suffix}$ ]] || {
      echo >&2 "Unexpected discourse/base ${base_suffix} tag: ${base_latest}"
      return 1
    }
    if [[ "${base_latest}" > "${base_current}" ]]; then
      base[${line}]="${base_latest}"
      changes+=("discourse/base ${base_current} -> ${base_latest}")
    else
      base[${line}]="${base_current}"
    fi
  done

  # Resolve every pin before editing anything, so a registry failure changes no file. Pins are
  # compared even when no tag moves, in case a tag was rebuilt.
  local tag digest
  for tag in $(printf '%s\n' "${base[@]}" | sort -u); do
    digest=$(_discourse_digest "${tag}") || return 1
    [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
      echo >&2 "Invalid digest for discourse/base:${tag}"
      return 1
    }
    pins+="BASE_IMAGE_DIGEST_${tag} := ${digest}"$'\n'
  done

  # A newer monthly line is a manual change, so it is only reported.
  if [[ -n "${version[DISCOURSE_RELEASE]:-}" ]]; then
    line="${version[DISCOURSE_RELEASE]%.*}"
    newest_line=$(_discourse_newest_line) || newest_line=""
    if [[ -n "${newest_line}" && "${newest_line}" != "${line}" \
        && "$(printf '%s\n%s\n' "${line}" "${newest_line}" | sort -V | tail -n1)" == "${newest_line}" ]]; then
      _report_event manual_review "$(_current_repo_slug)" \
        "Discourse ${newest_line} is released; add an image line, base tag and service option for it"
    fi
  fi

  if [[ "${#version_changes[@]}" -eq 0 && "${pins}" == "$(grep '^BASE_IMAGE_DIGEST_' base-images.mk)"$'\n' ]]; then
    echo "Discourse ${key_list} images are up to date"
    return 0
  fi

  for key in "${keys[@]}"; do
    line="${version[${key}]%.*}"
    sed -i -E "s/^(  ${key}: ).*/\1'${version[${key}]}'/" .github/workflows/workflow.yml
    if [[ "${makefile_ver%.*}" == "${line}" ]]; then
      sed -i -E "s/^(DISCOURSE_VER \?= ).*/\1${version[${key}]}/" Makefile
    fi
    sed -i -E "s/^(DISCOURSE_BASE_TAG_${line//./\\.} := ).*/\1${base[${line}]}/" Makefile
  done
  # Replace the pin block in place, keeping the file's other content and order.
  awk -v pins="${pins%$'\n'}" '/^BASE_IMAGE_DIGEST_/ { if (!done) { print pins; done = 1 } next } { print }' \
    base-images.mk > base-images.mk.new && mv base-images.mk.new base-images.mk

  if [[ "${#version_changes[@]}" -gt 0 ]]; then
    notes="Discourse updates: $(_join_ws ", " "${version_changes[@]}")"
    commit_message="Update Discourse to $(_join_ws ", " "${version_changes[@]##* -> }")"
  elif [[ "${#changes[@]}" -gt 0 ]]; then
    notes="Rebuild on newer Discourse base images"
    commit_message="Update the Discourse base images"
  else
    notes="Rebuild on the updated Discourse base images"
    commit_message="Rebuild against updated base image digests"
  fi
  if [[ "${#changes[@]}" -gt 0 ]]; then
    notes+=$'\n\n'"$(_join_ws ", " "${changes[@]}")"
  fi

  _git_commit ./ "${commit_message}" || return 1
  _git_push origin || return 1
  _release_tag "${notes}" ""
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _git_clone wodby/discourse
  _require_base_image_pins || exit 0
  _update_discourse "DISCOURSE_RELEASE DISCOURSE_ESR"
fi
