#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/redis" "6 5"