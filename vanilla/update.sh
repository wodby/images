#!/usr/bin/env bash

set -e

. ../lib.sh

image="${1}"
versions="${2}"
upstream="${3}"

git_clone "${image}"

update_versions "${versions}" "${upstream}" "${image#*/}"
