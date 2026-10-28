#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../update.sh"

# Use installable packages from the image's Alpine branch for both build architectures.
_opensmtpd_package_version() {
  local work arch version candidate=''
  work=$(mktemp -d) || return 1
  for arch in x86_64 aarch64; do
    if ! curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 \
      -o "$work/index.tar.gz" \
      "https://dl-cdn.alpinelinux.org/alpine/v3.23/community/$arch/APKINDEX.tar.gz"; then
      echo >&2 "Failed to download the Alpine 3.23 OpenSMTPD package index for $arch"
      rm -rf "$work"
      return 1
    fi
    if ! tar -xzOf "$work/index.tar.gz" APKINDEX > "$work/APKINDEX"; then
      echo >&2 "Failed to extract the OpenSMTPD package index for $arch"
      rm -rf "$work"
      return 1
    fi
    version=$(awk -F: '/^P:/ { found=($0 == "P:opensmtpd") } found && /^V:/ { print $2; exit }' "$work/APKINDEX") || {
      rm -rf "$work"
      return 1
    }
    [[ "$version" =~ ^7\.[0-9]+\.[0-9]+(_p[0-9]+)?-r[0-9]+$ ]] || {
      echo >&2 "Expected a stable OpenSMTPD 7 package, got: $version"
      rm -rf "$work"
      return 1
    }
    if [[ -n "$candidate" && "$candidate" != "$version" ]]; then
      echo >&2 'OpenSMTPD package versions differ between amd64 and arm64; waiting for both'
      rm -rf "$work"
      return 1
    fi
    candidate=$version
  done
  rm -rf "$work"
  printf '%s\n' "$candidate"
}

# Package patches and Alpine packaging revisions both require a new image revision.
_update_opensmtpd_package() {
  local current candidate version previous workflow_version
  current=$(cat .opensmtpd-package) || return 1
  [[ "$current" =~ ^7\.[0-9]+\.[0-9]+(_p[0-9]+)?-r[0-9]+$ ]] || return 1
  previous=${current%-r*}
  previous=${previous%_p*}
  workflow_version=$(sed -nE "s/^  OPENSMTPD7: '?([0-9.]+)'?$/\1/p" .github/workflows/workflow.yml)
  [[ "$workflow_version" == "$previous" ]] && grep -qxF "OPENSMTPD_VER ?= $previous" Makefile || {
    echo >&2 'OpenSMTPD package pin, workflow and Makefile versions differ'
    return 1
  }
  candidate=$(_opensmtpd_package_version) || return 1
  if ! _version_is_newer "$candidate" "$current"; then
    return 0
  fi
  version=${candidate%-r*}
  version=${version%_p*}
  sed -i -E "s/^(  OPENSMTPD7: ).*/\1'$version'/" .github/workflows/workflow.yml
  sed -i -E "s/^(OPENSMTPD_VER \?= ).*/\1$version/" Makefile
  # Keep the documented floating minor alias aligned when Alpine advances it.
  sed -i "s/\`${previous%.*}\`/\`${version%.*}\`/g" README.md
  printf '%s\n' "$candidate" > .opensmtpd-package
  _git_commit ./ "Update OpenSMTPD package to $candidate" || return 1
  _git_push origin || return 1
  _release_tag "OpenSMTPD package: $current -> $candidate" ""
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _git_clone wodby/opensmtpd
  _require_base_image_pins || exit 0
  _require_parent_image_revision || exit 0
  # Ship before the image contract lands without editing an older checkout.
  if [[ ! -f .opensmtpd-package ]] || ! grep -qxF 'ALPINE_VER ?= 3.23' Makefile; then
    _report_event manual_review wodby/opensmtpd 'Waiting for the OpenSMTPD package pin on Alpine 3.23 before enabling automatic package updates'
  else
    _update_opensmtpd_package
  fi
  _update_digests '3.23' wodby/alpine
  _update_base_alpine_image '3.23' wodby/alpine true
fi
