#!/usr/bin/env bash

set -e

. ../update.sh

update_from_parent_image "wodby/moodle" "8.4"
