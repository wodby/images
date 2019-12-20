#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/alpine" "3.11 3.10 3.9 3.8"