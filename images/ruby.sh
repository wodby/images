#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/ruby" "3.4 3.3 3.2"