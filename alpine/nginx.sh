#!/usr/bin/env bash

set -e

. ../update.sh

update_base_alpine "wodby/nginx" "3.16" "true"