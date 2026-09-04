#!/usr/bin/env bash

set -e

# shellcheck source=../update.sh
. ../update.sh

_git_clone "wodby/mysql"
_update_versions "8.0" "mysql" "mysql"

# The official MySQL image is based on Oracle Linux. Omitting the Wodby image
# argument disables the Alpine-version comparison while retaining rebuilds
# when Docker Hub refreshes the upstream tag.
_update_timestamps "8.0" "mysql"
