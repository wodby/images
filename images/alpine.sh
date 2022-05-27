#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/alpine" "3.16 3.15 3.14 3.13"