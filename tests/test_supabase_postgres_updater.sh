#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/images/supabase-postgres.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export IMAGES_UPDATE_REPORT_FILE="$work/events.jsonl"
pinned="sha256:$(printf 'a%.0s' {1..64})"
changed="sha256:$(printf 'b%.0s' {1..64})"
echo "ARG SUPABASE_IMAGE=supabase/postgres:17.6.1.136@$pinned" > "$work/Dockerfile"
cp "$work/Dockerfile" "$work/original"
# No test case may publish or mutate an image checkout.
_git_commit() { echo 'Unexpected commit' >&2; exit 1; }
_git_push() { echo 'Unexpected push' >&2; exit 1; }
_release_tag() { echo 'Unexpected release' >&2; exit 1; }
_get_image_tags() { [[ "$1" == supabase/postgres && "$2" == '^17\.[0-9]+\.[0-9]+\.[0-9]+$' ]] || return 1; echo "$candidate"; }
_get_image_digest() { [[ "$1:$2" == supabase/postgres:17.6.1.136 ]] || return 1; echo "$remote_digest"; }
check() { : > "$IMAGES_UPDATE_REPORT_FILE"; _check_supabase_postgres "$work/Dockerfile"; cmp "$work/Dockerfile" "$work/original"; }
candidate=17.6.1.136; remote_digest=$pinned
check; [[ ! -s "$IMAGES_UPDATE_REPORT_FILE" ]]
candidate=17.6.1.137
check; jq -se 'length == 1 and .[0].type == "manual_review" and .[0].repo == "wodby/supabase-postgres" and .[0].version == "17.6.1.137"' "$IMAGES_UPDATE_REPORT_FILE" >/dev/null
candidate=17.6.1.136; remote_digest=$changed
check; jq -se 'length == 1 and .[0].type == "manual_review" and (.[0].message | contains("new digest"))' "$IMAGES_UPDATE_REPORT_FILE" >/dev/null
candidate=17.6.1.137
check; [[ $(wc -l < "$IMAGES_UPDATE_REPORT_FILE") -eq 2 ]]
candidate=17.6.1.135; remote_digest=$pinned
check; [[ ! -s "$IMAGES_UPDATE_REPORT_FILE" ]]
candidate=18.1.1.1
if _check_supabase_postgres "$work/Dockerfile" >/dev/null 2>&1; then echo 'Accepted wrong major' >&2; exit 1; fi
candidate=17.6.1.136
_get_image_digest() { return 1; }
if _check_supabase_postgres "$work/Dockerfile" >/dev/null 2>&1; then echo 'Ignored lookup failure' >&2; exit 1; fi
echo 'ARG SUPABASE_IMAGE=supabase/postgres:latest' > "$work/Dockerfile"
if _check_supabase_postgres "$work/Dockerfile" >/dev/null 2>&1; then echo 'Accepted unpinned image' >&2; exit 1; fi
echo 'Supabase PostgreSQL monitoring tests passed.'
