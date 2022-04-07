#!/usr/bin/env bash

set -e

. ../update.sh

update_base_alpine "wodby/base-memcached" "3.15"