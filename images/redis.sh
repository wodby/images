#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/redis" "4.0 3.2"