#!/usr/bin/env bash

set -e

. ../update.sh

rebuild_from_base_image "wodby/alpine" "3.9 3.8"