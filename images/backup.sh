#!/usr/bin/env bash
set -e

. ../update.sh

_git_clone "wodby/backup"
_require_base_image_pins || exit 0
# Backup currently builds from wodby/alpine:latest; preserve that tag selection.
_update_digests "" "wodby/alpine"
