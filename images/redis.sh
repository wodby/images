#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/redis" "8.2 8.0 7.4"
