#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/nginx" "1.23 1.22 1.21 1.20 1.19" "github.com/nginx/nginx"