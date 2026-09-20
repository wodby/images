#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../update.sh"

# Follow packages available on the image's Alpine branch, rather than an
# upstream Squid release that apk cannot install yet.
_squid_package_version() {
  local work version
  work=$(mktemp -d) || return 1
  # Keep the large package index out of shell variables and DEBUG traces.
  # Download first so extraction cannot close curl's pipe prematurely.
  if ! curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 \
    -o "$work/index.tar.gz" \
    https://dl-cdn.alpinelinux.org/alpine/v3.24/main/x86_64/APKINDEX.tar.gz; then
    echo >&2 "Failed to download the Alpine 3.24 Squid package index"
    rm -rf "$work"
    return 1
  fi
  if ! tar -xzOf "$work/index.tar.gz" APKINDEX > "$work/APKINDEX"; then
    echo >&2 "Failed to extract the Alpine 3.24 Squid package index"
    rm -rf "$work"
    return 1
  fi
  if ! version=$(awk -F: '$0 == "P:squid" { found=1; next } found && /^V:/ { print $2; exit }' "$work/APKINDEX"); then
    rm -rf "$work"
    return 1
  fi
  rm -rf "$work"
  [[ "$version" =~ ^7\.[0-9]+(\.[0-9]+)?-r[0-9]+$ ]] || {
    echo >&2 "Expected a stable Squid 7 package, got: $version"
    return 1
  }
  printf '%s\n' "$version"
}

_update_squid_package() {
  local candidate current version previous
  candidate=$(_squid_package_version) || return 1
  current=$(cat .squid-package) || return 1
  [[ "$current" =~ ^7\.[0-9]+(\.[0-9]+)?-r[0-9]+$ ]] || return 1
  [[ "$candidate" != "$current" ]] || return 0
  version=${candidate%-r*}
  previous=${current%-r*}
  if [[ "$version" == "$previous" ]]; then
    (( ${candidate##*-r} > ${current##*-r} )) || return 0
  elif ! _version_is_newer "$version" "$previous"; then
    return 0
  fi

  # Keep versioned tags, the local build default and package revision aligned.
  sed -i -E "s/(SQUID7: )'[^']+'/\1'$version'/" .github/workflows/workflow.yml
  sed -i -E "s/(SQUID_VER \?= ).*/\1$version/" Makefile
  sed -i "s/\`$previous\`/\`$version\`/g" README.md
  printf '%s\n' "$candidate" > .squid-package
  _git_commit ./ "Update Squid package to $candidate"
  _git_push origin
  _release_tag "Squid package: $current -> $candidate" ""
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _git_clone wodby/squid
  # The image migration and updater can be reviewed together without modifying
  # an older Squid checkout during the scheduled or pull-request dry run.
  if [[ ! -f .squid-package ]] || ! grep -q '^ALPINE_VER ?= 3.24$' Makefile; then
    _report_event manual_review wodby/squid 'Waiting for the Squid 7 / Alpine 3.24 image migration before enabling automatic updates'
    exit 0
  fi
  _require_base_image_pins || exit 0
  _update_squid_package
  _update_digests "3.24" "wodby/alpine"
  _update_base_alpine_image "3.24" "wodby/alpine" "true"
fi
