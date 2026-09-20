#!/usr/bin/env bash

set -e

. ../update.sh

update_from_parent_image "wodby/wordpress" "8.5 8.4 8.3 8.2"