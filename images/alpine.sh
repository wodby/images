#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/alpine" "3.14 3.13 3.12 3.11 3.10"