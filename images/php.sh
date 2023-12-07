#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/php" "8.3 8.2 8.1"
