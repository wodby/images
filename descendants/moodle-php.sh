#!/usr/bin/env bash

set -e

. ../update.sh

update_from_parent_image "wodby/moodle-php" "8.4"
