#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/node" "10.9 8.11 6.14"