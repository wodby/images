#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/php" "7.2 7.1 7.0 5.6"
