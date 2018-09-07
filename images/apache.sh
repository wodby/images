#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/apache" "2.4"
