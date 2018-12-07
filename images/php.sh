#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/php" "7.3 7.2 7.1 5.6"
