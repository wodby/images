#!/usr/bin/env bash

set -e

. ../update.sh

update_base_alpine "wodby/mariadb" "3.20" "true"