#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../update.sh"

# FRP is pre-1.0: only patch releases within the reviewed minor line are compatible.
_update_frp() {
  local current candidate arch
  current=$(sed -nE "s/^  FRP_VERSION: '?([0-9]+\.[0-9]+\.[0-9]+)'?$/\1/p" .github/workflows/workflow.yml)
  [[ "$current" =~ ^0\.69\.[0-9]+$ ]] || {
    echo >&2 'Expected FRP 0.69 in the build workflow'
    return 1
  }
  grep -qxF "FRP_VERSION ?= $current" Makefile || {
    echo >&2 'FRP workflow and Makefile versions differ'
    return 1
  }
  candidate=$(_get_latest_version github.com/fatedier/frp 0.69 frp) || return 1
  [[ "$candidate" =~ ^0\.69\.[0-9]+$ ]] || {
    echo >&2 "Expected a stable FRP 0.69 patch, got: $candidate"
    return 1
  }
  if ! _version_is_newer "$candidate" "$current"; then
    return 0
  fi
  # Both build architectures must have published upstream archives before any edit.
  for arch in amd64 arm64; do
    _release_source_has_version \
      "https://github.com/fatedier/frp/releases/download/v{{version}}/frp_{{version}}_linux_${arch}.tar.gz" \
      "$candidate" || {
        echo >&2 "FRP $candidate has no published linux/$arch archive"
        return 1
      }
  done
  sed -i -E "s/^(  FRP_VERSION: ).*/\1'$candidate'/" .github/workflows/workflow.yml
  sed -i -E "s/^(FRP_VERSION \?= ).*/\1$candidate/" Makefile
  _git_commit ./ "Update frp to $candidate" || return 1
  _git_push origin || return 1
  _release_tag "frp updates: $current -> $candidate" ""
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _git_clone wodby/frp
  _update_frp
fi
