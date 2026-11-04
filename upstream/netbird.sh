#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../update.sh"

# wodby/netbird copies NetBird's server and relay binaries and the dashboard's static build from NetBird's own images
# onto a Debian base. NetBird is pre-1.0 and its image and service follow the whole 0.x line, as NetBird's own
# self-hosting guide does; the dashboard is released separately in its own v2.x line. The image's tests connect two
# real clients through the server before an image revision is published.
#
# Every build input is pinned by digest in base-images.mk. A new NetBird or dashboard release, or a rebuilt tag of any
# input (including Debian security updates), releases a new image revision. All digests are resolved before any file
# changes, so a registry failure changes nothing.

# Prints the newest NetBird release published as a server image, such as 0.82.0.
_netbird_latest() {
  _get_image_tags netbirdio/netbird-server '^0\.[0-9]+\.[0-9]+$'
}

# Prints the newest dashboard release, such as v2.96.0.
_netbird_dashboard_latest() {
  _get_image_tags netbirdio/dashboard '^v2\.[0-9]+\.[0-9]+$'
}

# Prints the multi-platform index digest of <repository>:<tag>.
_netbird_digest() {
  _get_image_digest "${1}" "${2}"
}

_update_netbird() {
  local workflow=.github/workflows/workflow.yml
  local current current_dashboard latest latest_dashboard version dashboard
  local debian_digest server_digest relay_digest dashboard_digest pins current_pins
  local -a changes=()

  current=$(sed -nE "s/^  NETBIRD0: '?(0\.[0-9]+\.[0-9]+)'?$/\1/p" "${workflow}")
  current_dashboard=$(sed -nE "s/^  NETBIRD_DASHBOARD: '?(v2\.[0-9]+\.[0-9]+)'?$/\1/p" "${workflow}")
  [[ -n "${current}" && -n "${current_dashboard}" ]] || {
    echo >&2 'Expected NETBIRD0 and NETBIRD_DASHBOARD in the build workflow'
    return 1
  }
  grep -qxF "NETBIRD_VER ?= ${current}" Makefile && grep -qxF "NETBIRD_DASHBOARD_VER ?= ${current_dashboard}" Makefile || {
    echo >&2 'NetBird workflow and Makefile versions differ'
    return 1
  }

  latest=$(_netbird_latest) || return 1
  latest_dashboard=$(_netbird_dashboard_latest) || return 1
  [[ "${latest}" =~ ^0\.[0-9]+\.[0-9]+$ ]] || {
    echo >&2 "Unexpected NetBird release: ${latest}"
    return 1
  }
  [[ "${latest_dashboard}" =~ ^v2\.[0-9]+\.[0-9]+$ ]] || {
    echo >&2 "Unexpected NetBird dashboard release: ${latest_dashboard}"
    return 1
  }

  # Never move a version backwards.
  version="${current}"
  if _version_is_newer "${latest}" "${current}"; then
    version="${latest}"
    changes+=("NetBird ${current} -> ${version}")
  fi
  dashboard="${current_dashboard}"
  if _version_is_newer "${latest_dashboard#v}" "${current_dashboard#v}"; then
    dashboard="${latest_dashboard}"
    changes+=("dashboard ${current_dashboard} -> ${dashboard}")
  fi

  # The relay is published separately from the server; both must exist for the release.
  debian_digest=$(_netbird_digest debian trixie-slim) || return 1
  server_digest=$(_netbird_digest netbirdio/netbird-server "${version}") || return 1
  relay_digest=$(_netbird_digest netbirdio/relay "${version}") || {
    echo >&2 "NetBird ${version} has no published relay image"
    return 1
  }
  dashboard_digest=$(_netbird_digest netbirdio/dashboard "${dashboard}") || return 1

  pins="BASE_IMAGE_DIGEST_trixie-slim := ${debian_digest}"$'\n'
  pins+="BUILD_IMAGE_NETBIRD_SERVER := netbirdio/netbird-server:${version}@${server_digest}"$'\n'
  pins+="BUILD_IMAGE_NETBIRD_RELAY := netbirdio/relay:${version}@${relay_digest}"$'\n'
  pins+="BUILD_IMAGE_NETBIRD_DASHBOARD := netbirdio/dashboard:${dashboard}@${dashboard_digest}"
  current_pins=$(grep -E '^(BASE_IMAGE_DIGEST_|BUILD_IMAGE_NETBIRD_)' base-images.mk)
  if [[ "${pins}" == "${current_pins}" ]]; then
    echo "NetBird ${version} and dashboard ${dashboard} are up to date"
    return 0
  fi

  sed -i -E "s/^(  NETBIRD0: ).*/\1'${version}'/; s/^(  NETBIRD_DASHBOARD: ).*/\1'${dashboard}'/" "${workflow}"
  sed -i -E "s/^(NETBIRD_VER \?= ).*/\1${version}/; s/^(NETBIRD_DASHBOARD_VER \?= ).*/\1${dashboard}/" Makefile
  sed -i -E "s/^(ARG NETBIRD_VER=).*/\1${version}/; s/^(ARG NETBIRD_DASHBOARD_VER=).*/\1${dashboard}/" Dockerfile
  sed -i -E \
    -e "s|^BASE_IMAGE_DIGEST_trixie-slim := .*|BASE_IMAGE_DIGEST_trixie-slim := ${debian_digest}|" \
    -e "s|^BUILD_IMAGE_NETBIRD_SERVER := .*|BUILD_IMAGE_NETBIRD_SERVER := netbirdio/netbird-server:${version}@${server_digest}|" \
    -e "s|^BUILD_IMAGE_NETBIRD_RELAY := .*|BUILD_IMAGE_NETBIRD_RELAY := netbirdio/relay:${version}@${relay_digest}|" \
    -e "s|^BUILD_IMAGE_NETBIRD_DASHBOARD := .*|BUILD_IMAGE_NETBIRD_DASHBOARD := netbirdio/dashboard:${dashboard}@${dashboard_digest}|" \
    base-images.mk

  if [[ "${#changes[@]}" -gt 0 ]]; then
    _git_commit ./ "Update $(_join_ws ", " "${changes[@]}")" || return 1
    _git_push origin || return 1
    _release_tag "NetBird updates: $(_join_ws ", " "${changes[@]}")" ""
  else
    _git_commit ./ "Rebuild against updated base image digests" || return 1
    _git_push origin || return 1
    _release_tag "Rebuild on updated Debian and NetBird base images" ""
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _git_clone wodby/netbird
  _require_base_image_pins || exit 0
  _update_netbird
fi
