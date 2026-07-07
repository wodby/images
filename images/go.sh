#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/go" "1.26 1.25"
