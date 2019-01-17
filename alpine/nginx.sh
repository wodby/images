#!/usr/bin/env bash

set -e

. ../update.sh

update_base_alpine "wodby/nginx" "3.8" "true"