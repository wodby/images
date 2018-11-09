#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/alpine" "3.8 3.7 3.6"