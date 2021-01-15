#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/ruby" "3.0 2.7 2.6 2.5"