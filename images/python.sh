#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/python" "3.13 3.12 3.11 3.10 3.9"
