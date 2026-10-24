#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/alpine/opensmtpd.sh"
fixture_root=$(mktemp -d)
trap 'rm -rf "$fixture_root"' EXIT
cd "$fixture_root"
mkdir -p .github/workflows
_git_commit() { printf 'commit\n' >> events; }
_git_push() { [[ "$*" == origin ]]; printf 'push\n' >> events; }
_release_tag() { printf 'release\n' >> events; printf '%s\n' "$1" > release-notes; }
reset_fixture() {
  echo '7.8.0_p0-r0' > .opensmtpd-package
  echo "  OPENSMTPD7: '7.8.0'" > .github/workflows/workflow.yml
  echo 'OPENSMTPD_VER ?= 7.8.0' > Makefile
  echo 'Tags: `7.8`, `7`, `latest`' > README.md
  : > events
}
# Exercise actual compressed APK index parsing with different architecture fixtures.
curl() {
  local output url
  while [[ "$1" != -o ]]; do shift; done
  output=$2; url=$3
  [[ "$url" == https://dl-cdn.alpinelinux.org/alpine/v3.23/community/*/APKINDEX.tar.gz ]]
  if [[ "$url" == */x86_64/* ]]; then
    cp "$fixture_root/amd64.tar.gz" "$output"
  else
    [[ "$url" == */aarch64/* ]]
    cp "$fixture_root/arm64.tar.gz" "$output"
  fi
}
index_fixture() {
  printf 'P:other\nV:9.0-r0\n\nP:opensmtpd\nV:%s\n\n' "$2" > APKINDEX
  tar -czf "$1.tar.gz" APKINDEX
}
index_fixture amd64 7.8.0_p0-r0
index_fixture arm64 7.8.0_p0-r0
[[ $(_opensmtpd_package_version) == 7.8.0_p0-r0 ]]
index_fixture arm64 7.8.0_p0-r1
if _opensmtpd_package_version; then echo 'Accepted architecture drift' >&2; exit 1; fi
for candidate in 8.0.0-r0 7.8.0_rc1-r0 ''; do
  index_fixture amd64 "$candidate"
  if _opensmtpd_package_version; then echo 'Accepted invalid package' >&2; exit 1; fi
done
echo corrupt > amd64.tar.gz
if _opensmtpd_package_version; then echo 'Accepted corrupt index' >&2; exit 1; fi
(
  curl() { return 22; }
  if _opensmtpd_package_version; then echo 'Ignored download failure' >&2; exit 1; fi
)
index_fixture amd64 7.8.0_p0-r0
index_fixture arm64 7.8.0_p0-r0
reset_fixture
_update_opensmtpd_package
[[ ! -s events ]]
# Check packaging, portable and upstream updates, including minor alias changes.
for candidate in 7.8.0_p0-r1 7.8.0_p1-r0 7.8.1-r0 7.9.0_p0-r0; do
  reset_fixture
  index_fixture amd64 "$candidate"
  index_fixture arm64 "$candidate"
  _update_opensmtpd_package
  [[ $(cat .opensmtpd-package) == "$candidate" && $(wc -l < events) -eq 3 ]]
  [[ $(cat release-notes) == "OpenSMTPD package: 7.8.0_p0-r0 -> $candidate" ]]
  version=${candidate%-r*}; version=${version%_p*}
  grep -qxF "OPENSMTPD_VER ?= $version" Makefile
  grep -qx "  OPENSMTPD7: '$version'" .github/workflows/workflow.yml
  grep -qF "\`${version%.*}\`" README.md
  : > events
  _update_opensmtpd_package
  [[ ! -s events ]]
done
reset_fixture
echo 7.8.0_p1-r10 > .opensmtpd-package
for candidate in 7.8.0_p1-r9 7.8.0_p0-r20 7.7.0_p9-r99; do
  index_fixture amd64 "$candidate"
  index_fixture arm64 "$candidate"
  _update_opensmtpd_package
  [[ ! -s events && $(cat .opensmtpd-package) == 7.8.0_p1-r10 ]]
done
reset_fixture
echo 'OPENSMTPD_VER ?= 7.7.0' > Makefile
if _update_opensmtpd_package; then echo 'Accepted inconsistent version pins' >&2; exit 1; fi
[[ ! -s events ]]
for failure in commit push; do
  (
    reset_fixture
    index_fixture amd64 7.8.0_p0-r1
    index_fixture arm64 7.8.0_p0-r1
    if [[ "$failure" == commit ]]; then _git_commit() { return 1; }; else _git_push() { return 1; }; fi
    if _update_opensmtpd_package; then echo 'Ignored publication failure' >&2; exit 1; fi
    ! grep -q release events
  )
done
# Existing base-image updates must continue before the package-pin rollout.
mkdir -p rollout/alpine rollout/checkout
cp "$root/alpine/opensmtpd.sh" rollout/alpine/opensmtpd.sh
cat > rollout/update.sh <<'STUB'
_git_clone() { cd "$ROLLOUT_ROOT/checkout"; }
_require_base_image_pins() { return 0; }
_require_parent_image_revision() { return 0; }
_report_event() { printf 'review\n' >> "$ROLLOUT_ROOT/trace"; }
_update_digests() { [[ "$*" == '3.23 wodby/alpine' ]]; printf 'digests\n' >> "$ROLLOUT_ROOT/trace"; }
_update_base_alpine_image() { [[ "$*" == '3.23 wodby/alpine true' ]]; printf 'parent\n' >> "$ROLLOUT_ROOT/trace"; }
STUB
export ROLLOUT_ROOT="$fixture_root/rollout"
bash rollout/alpine/opensmtpd.sh
[[ $(cat rollout/trace) == $'review\ndigests\nparent' ]]
echo 'OpenSMTPD updater tests passed.'
