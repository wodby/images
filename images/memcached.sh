#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/memcached" "1.5"