#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../update.sh"

# Report bundle or digest drift without changing initialization SQL, restore compatibility, or releases.
_check_supabase_postgres() {
  local dockerfile="${1:-Dockerfile}"
  local current current_tag major latest digest
  current=$(_dockerfile_arg_value SUPABASE_IMAGE "${dockerfile}") || return 1
  if [[ ! "$current" =~ ^supabase/postgres:([0-9]+)\.[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]; then
    echo >&2 'Expected a version- and digest-pinned Supabase PostgreSQL image'
    return 1
  fi
  major="${BASH_REMATCH[1]}"
  current_tag=$(_image_ref_tag "$current")
  latest=$(_get_image_tags supabase/postgres "^${major}\\.[0-9]+\\.[0-9]+\\.[0-9]+$") || return 1
  if [[ ! "$latest" =~ ^${major}\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo >&2 'Unexpected Supabase PostgreSQL candidate version'
    return 1
  fi
  if _version_is_newer "$latest" "$current_tag"; then
    _report_event manual_review wodby/supabase-postgres \
      "Supabase PostgreSQL bundle update available: ${current_tag} -> ${latest}; validate initialization and recovery before updating" \
      "$latest" "$current_tag"
  fi
  digest=$(_get_image_digest supabase/postgres "$current_tag") || return 1
  if [[ "$digest" != "${current##*@}" ]]; then
    _report_event manual_review wodby/supabase-postgres \
      "Pinned Supabase PostgreSQL tag ${current_tag} has a new digest; review and test before repinning" \
      "$digest" "${current##*@}"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _git_clone wodby/supabase-postgres
  _check_supabase_postgres Dockerfile
fi
