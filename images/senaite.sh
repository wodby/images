#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../update.sh"

# wodby/senaite builds SENAITE LIMS (Plone 5.2 on Python 2.7) on ubuntu:22.04, which still ships
# python2.7 with security updates. base-images.mk pins one image as BASE_IMAGE_REPOSITORY,
# BASE_IMAGE_TAG and BASE_IMAGE_DIGEST. A new digest is rebuilt and released, which also brings in
# Ubuntu's package updates. A new SENAITE release is only reported: it needs new pins in
# versions.cfg and a review of the installed hotfix. The generic base image updater can't be used:
# its pin format has per-tag digests, and on a digest change it compares Alpine versions.

SENAITE_PYPI_URL="${SENAITE_PYPI_URL:-https://pypi.org/pypi/senaite.lims/json}"

# Prints the multi-platform index digest of <repository>:<tag>.
_senaite_base_digest() {
  _get_image_digest "${1}" "${2}"
}

# Prints the newest final senaite.lims release on PyPI, ignoring pre-releases and yanked releases.
_senaite_latest_release() {
  local response
  response=$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 3 "${SENAITE_PYPI_URL}") || return 1
  jq -r '.releases | to_entries[]
    | select((.value | length) > 0 and all(.value[]; .yanked != true))
    | .key' <<<"${response}" \
    | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V | tail -n1
}

# Reports a newer SENAITE release for manual review. It never edits a file, and a failed lookup
# only warns, so it can't block the base image update.
_senaite_check_release() {
  local current latest
  current=$(sed -nE "s/^  SENAITE26: '?([0-9]+(\.[0-9]+)*)'?$/\1/p" .github/workflows/workflow.yml)
  if [[ -z "${current}" ]]; then
    echo >&2 "Warning: expected SENAITE26 in the build workflow; skipping the SENAITE release check"
    return 0
  fi
  if ! latest=$(_senaite_latest_release) || [[ ! "${latest}" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo >&2 "Warning: failed to look up the latest SENAITE release on PyPI"
    return 0
  fi
  if _version_is_newer "${latest}" "${current}"; then
    _report_event manual_review "$(_current_repo_slug)" \
      "SENAITE ${latest} is released; update versions.cfg and review the hotfix" "${latest}" "${current}"
  else
    echo "SENAITE ${current} is the latest release"
  fi
}

_update_senaite() {
  local repository tag current digest

  _senaite_check_release

  [[ -f base-images.mk ]] || {
    echo >&2 "Expected base-images.mk"
    return 1
  }
  repository=$(sed -nE 's/^BASE_IMAGE_REPOSITORY := *([^ ]+) *$/\1/p' base-images.mk)
  tag=$(sed -nE 's/^BASE_IMAGE_TAG := *([^ ]+) *$/\1/p' base-images.mk)
  current=$(sed -nE 's/^BASE_IMAGE_DIGEST := *([^ ]+) *$/\1/p' base-images.mk)
  [[ "${repository}" == ubuntu && "${tag}" =~ ^[0-9]{2}\.[0-9]{2}$ && "${current}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo >&2 "Expected one digest-pinned ubuntu:<yy.mm> base image in base-images.mk"
    return 1
  }

  # Resolve the digest before editing anything, so a registry failure changes no file.
  digest=$(_senaite_base_digest "${repository}" "${tag}") || return 1
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo >&2 "Invalid digest for ${repository}:${tag}"
    return 1
  }
  if [[ "${digest}" == "${current}" ]]; then
    echo "Ubuntu ${tag} base image is up to date"
    return 0
  fi

  sed -i -E "s/^(BASE_IMAGE_DIGEST := *).*/\1${digest}/" base-images.mk
  _git_commit ./ "Rebuild against updated base image digests" || return 1
  _git_push origin || return 1
  _release_tag "Rebuild on the updated Ubuntu ${tag} base image" ""
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _git_clone wodby/senaite
  _update_senaite
fi
