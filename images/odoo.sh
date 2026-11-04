#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../update.sh"

# Odoo publishes one series per major version and dates its builds: the official image tag
# 20.0-20261102 is Odoo 20.0 built on 2026-11-02. wodby/odoo records it as ODOO20: '20.0.20261102'
# in the build workflow and pins the tag's digest as BASE_IMAGE_DIGEST_20.0-20261102. The generic
# Docker Hub updater can't follow these tags, because the build date follows a dash.

# Prints the newest build date of an Odoo series, such as 20261102 for 20.0.
_odoo_latest_build() {
  _get_image_tags odoo "(?<=^${1//./\\.}-)[0-9]{8}$"
}

# Prints the multi-platform index digest of odoo:<tag>.
_odoo_digest() {
  _get_image_digest odoo "${1}"
}

_update_odoo() {
  local series_list="${1}"
  local -a lines version_changes=()
  local line key current current_build latest_build pins="" notes commit_message makefile_ver
  declare -A version

  IFS=' ' read -r -a lines <<<"${series_list}"
  makefile_ver=$(sed -nE 's/^ODOO_VER \?= *([0-9.]+) *$/\1/p' Makefile)

  for line in "${lines[@]}"; do
    [[ "${line}" =~ ^[0-9]+\.0$ ]] || {
      echo >&2 "Invalid Odoo series: ${line}"
      return 1
    }
    key="ODOO${line%%.*}"
    current=$(sed -nE "s/^  ${key}: '?(${line//./\\.}\.[0-9]{8})'?$/\1/p" .github/workflows/workflow.yml)
    [[ -n "${current}" ]] || {
      echo >&2 "Expected ${key} in the build workflow"
      return 1
    }
    current_build="${current##*.}"
    latest_build=$(_odoo_latest_build "${line}") || return 1
    [[ "${latest_build}" =~ ^[0-9]{8}$ ]] || {
      echo >&2 "Unexpected Odoo ${line} build: ${latest_build}"
      return 1
    }
    # Never move a series backwards.
    if (( latest_build > current_build )); then
      version[${line}]="${line}.${latest_build}"
      version_changes+=("${current} -> ${version[${line}]}")
    else
      version[${line}]="${current}"
    fi
  done

  # Resolve every pin before editing anything, so a registry failure changes no file. Odoo's image
  # is rebuilt under the same tag when Ubuntu updates, so unchanged builds are compared too.
  for line in $(printf '%s\n' "${lines[@]}" | sort -V); do
    local tag digest
    tag="${line}-${version[${line}]##*.}"
    digest=$(_odoo_digest "${tag}") || return 1
    pins+="BASE_IMAGE_DIGEST_${tag} := ${digest}"$'\n'
  done
  if [[ "${pins}" == "$(grep '^BASE_IMAGE_DIGEST_' base-images.mk)"$'\n' ]]; then
    echo "Odoo ${series_list} base images are up to date"
    return 0
  fi

  for line in "${lines[@]}"; do
    key="ODOO${line%%.*}"
    sed -i -E "s/^(  ${key}: ).*/\1'${version[${line}]}'/" .github/workflows/workflow.yml
    if [[ "${makefile_ver%.*}" == "${line}" ]]; then
      sed -i -E "s/^(ODOO_VER \?= ).*/\1${version[${line}]}/" Makefile
    fi
  done
  # Replace the pin block in place, keeping the file's other content and order.
  awk -v pins="${pins%$'\n'}" '/^BASE_IMAGE_DIGEST_/ { if (!done) { print pins; done = 1 } next } { print }' \
    base-images.mk > base-images.mk.new && mv base-images.mk.new base-images.mk

  if [[ "${#version_changes[@]}" -gt 0 ]]; then
    notes="Odoo updates: $(_join_ws ", " "${version_changes[@]}")"
    commit_message="Update Odoo to $(_join_ws ", " "${version_changes[@]##* -> }")"
  else
    notes="Rebuild on the updated official Odoo base images"
    commit_message="Rebuild against updated base image digests"
  fi

  _git_commit ./ "${commit_message}" || return 1
  _git_push origin || return 1
  _release_tag "${notes}" ""
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _git_clone wodby/odoo
  _require_base_image_pins || exit 0
  _update_odoo "20.0 19.0 18.0"
fi
