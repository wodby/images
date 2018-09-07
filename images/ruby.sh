#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/ruby" "2.5 2.4 2.3"