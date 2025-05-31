#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/alpine" "3.22 3.21 3.20 3.19"