#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/python" "3.7 3.6 3.5 2.7"
