#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/php" "8.1 8.0 7.4"
