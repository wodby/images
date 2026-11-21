#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/images/php.sh"
# The fixtures below cover these versions. Pin them so adding a PHP version to
# images/php.sh does not need fixture changes.
PHP_VERSIONS="8.5 8.4 8.3 8.2"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [[ "${2}" == "${1}" ]] || fail "expected '${1}', got '${2}'"
}

# Parse the package that apk reports inside the base image.
docker() { printf '%s\n' "${docker_output}"; }
docker_output='apache2-2.4.71-r0'
assert_eq 2.4.71-r0 "$(_apache_package_version php:8.5.12-fpm-alpine@sha256:1)"
docker_output='apache2-2.4.71-r12'
assert_eq 2.4.71-r12 "$(_apache_package_version php:8.5.12-fpm-alpine@sha256:1)"
for docker_output in '' 'apache2-doc-2.4.71-r0' 'apache2-2.6.0-r0' $'apache2-2.4.71-r0\napache2-2.4.70-r0'; do
  if _apache_package_version ref >/dev/null 2>&1; then fail "accepted '${docker_output}'"; fi
done
(
  docker() { return 1; }
  if _apache_package_version ref >/dev/null 2>&1; then fail 'ignored a failed lookup'; fi
)

# Package revisions count as updates; older and equal versions do not.
_apk_version_is_newer 2.4.71-r1 2.4.71-r0
_apk_version_is_newer 2.4.72-r0 2.4.71-r3
_apk_version_is_newer 2.4.100-r0 2.4.99-r0
if _apk_version_is_newer 2.4.71-r0 2.4.71-r0; then fail 'equal version is newer'; fi
if _apk_version_is_newer 2.4.71-r0 2.4.71-r1; then fail 'older revision is newer'; fi
if _apk_version_is_newer 2.4.70-r9 2.4.71-r0; then fail 'older version is newer'; fi

# Mock publication; tests never access or mutate a remote repository.
_git_commit() { printf 'commit %s\n' "$2" >> events; }
_git_push() { [[ "$*" == origin ]]; printf 'push\n' >> events; }
_release_tag() { printf 'release\n' >> events; printf '%s\n' "$1" > release-notes; }
_report_event() { printf 'report %s\n' "$1" >> events; }
_base_image_ref_for_line() { echo "php:${1}.0-fpm-alpine@sha256:${1}"; }
declare -A available=()
_apache_package_version() { [[ -n "${available[$1]:-}" ]] || return 1; echo "${available[$1]}"; }
set_available() {
  available=(
    ['php:8.5.0-fpm-alpine@sha256:8.5']="$1" ['php:8.4.0-fpm-alpine@sha256:8.4']="$2"
    ['php:8.3.0-fpm-alpine@sha256:8.3']="$3" ['php:8.2.0-fpm-alpine@sha256:8.2']="$4"
  )
}
reset_fixture() {
  cat > apache-packages.mk <<'EOF'
# Comment
APACHE_PACKAGE_VERSION_8.5 := 2.4.69-r0
APACHE_PACKAGE_VERSION_8.4 := 2.4.69-r0
APACHE_PACKAGE_VERSION_8.3 := 2.4.69-r0
APACHE_PACKAGE_VERSION_8.2 := 2.4.69-r0
EOF
  cp apache-packages.mk original.mk
  : > events
  rm -f release-notes
}

# Repositories without the pin file are skipped.
reset_fixture
rm apache-packages.mk
_update_apache_packages "${PHP_VERSIONS}"
assert_eq 'report manual_review' "$(cat events)"

# Nothing to do when Alpine has the recorded or an older package.
reset_fixture
set_available 2.4.69-r0 2.4.69-r0 2.4.68-r0 2.4.69-r0
_update_apache_packages "${PHP_VERSIONS}"
[[ ! -s events ]] || fail "unexpected events: $(cat events)"
cmp -s apache-packages.mk original.mk || fail 'changed pins without an update'

# One shared update is one commit, one push and one release.
reset_fixture
set_available 2.4.71-r0 2.4.71-r0 2.4.71-r0 2.4.71-r0
_update_apache_packages "${PHP_VERSIONS}"
assert_eq 'Apache updates: 2.4.69-r0 -> 2.4.71-r0' "$(cat release-notes)"
assert_eq $'commit Apache updates: 2.4.69-r0 -> 2.4.71-r0\npush\nrelease' "$(cat events)"
assert_eq 4 "$(grep -c ' := 2.4.71-r0$' apache-packages.mk)"
grep -q '^# Comment$' apache-packages.mk || fail 'dropped the comment'

# Versions on different Alpine branches are named.
reset_fixture
set_available 2.4.71-r0 2.4.71-r0 2.4.71-r0 2.4.69-r0
_update_apache_packages "${PHP_VERSIONS}"
assert_eq 'Apache updates: 2.4.69-r0 -> 2.4.71-r0 (except wodby/php:8.2-apache)' "$(cat release-notes)"
grep -q '^APACHE_PACKAGE_VERSION_8.2 := 2.4.69-r0$' apache-packages.mk || fail 'updated 8.2'
grep -q '^APACHE_PACKAGE_VERSION_8.3 := 2.4.71-r0$' apache-packages.mk || fail 'did not update 8.3'
reset_fixture
set_available 2.4.71-r1 2.4.71-r0 2.4.71-r0 2.4.71-r0
_update_apache_packages "${PHP_VERSIONS}"
assert_eq 'Apache updates: 2.4.69-r0 -> 2.4.71-r1 (wodby/php:8.5-apache); 2.4.69-r0 -> 2.4.71-r0 (wodby/php:8.4-apache, wodby/php:8.3-apache, wodby/php:8.2-apache)' "$(cat release-notes)"

# A failed lookup changes nothing.
reset_fixture
set_available 2.4.71-r0 2.4.71-r0 2.4.71-r0 ''
if _update_apache_packages "${PHP_VERSIONS}" >/dev/null 2>&1; then fail 'ignored a failed lookup'; fi
[[ ! -s events ]] || fail "unexpected events: $(cat events)"
cmp -s apache-packages.mk original.mk || fail 'changed pins after a failed lookup'

# A PHP version without a recorded package fails instead of guessing.
reset_fixture
set_available 2.4.71-r0 2.4.71-r0 2.4.71-r0 2.4.71-r0
sed -i '/8\.2/d' apache-packages.mk
if _update_apache_packages "${PHP_VERSIONS}" >/dev/null 2>&1; then fail 'accepted a missing pin'; fi
[[ ! -s events ]] || fail "unexpected events: $(cat events)"

# A batch turns the run's notes into one release, in order, keeping a minor flag.
(
  . "$root/update.sh"
  tags=()
  _publishing_enabled() { return 0; }
  _head_has_unpushed_commits() { return 1; }
  _pending_gotpl_note() { :; }
  _next_release_tag() { echo "r7${1:+ minor}"; }
  _ensure_git_identity() { :; }
  _git_push() { :; }
  _report_event() { :; }
  git() { [[ "$1" == tag ]] && printf '%s|%s\n' "$4" "$3" >> tags; }
  : > tags
  _release_batch_finish
  [[ ! -s tags ]] || fail 'released an empty batch'

  _release_batch_start
  _release_tag 'php updates: 8.5.11 -> 8.5.12' ''
  _release_tag 'Alpine Linux updates: 3.24.4 -> 3.25.0' 1
  _release_tag 'Apache updates: 2.4.71-r0 -> 2.4.72-r0' ''
  [[ ! -s tags ]] || fail 'tagged inside a batch'
  _release_batch_finish
  assert_eq $'r7 minor|php updates: 8.5.11 -> 8.5.12\n\nAlpine Linux updates: 3.24.4 -> 3.25.0\n\nApache updates: 2.4.71-r0 -> 2.4.72-r0' "$(cat tags)"
  # The batch ends with its release, and later releases tag directly.
  : > tags
  _release_batch_finish
  _release_tag 'Apache updates: 2.4.72-r0 -> 2.4.72-r1' ''
  assert_eq 'r7|Apache updates: 2.4.72-r0 -> 2.4.72-r1' "$(cat tags)"

  # A run whose push failed does not tag the local commit.
  : > tags
  _head_has_unpushed_commits() { return 0; }
  _release_batch_start
  _release_tag 'Apache updates: 2.4.71-r0 -> 2.4.72-r0' ''
  if _release_batch_finish 2>/dev/null; then fail 'released unpushed commits'; fi
  [[ ! -s tags ]] || fail 'tagged unpushed commits'
)

echo 'PHP Apache updater tests passed.'
