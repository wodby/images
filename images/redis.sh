#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/redis" "8.6 8.4 8.2 7.4"
