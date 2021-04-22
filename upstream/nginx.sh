#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/nginx" "1.20 1.19 1.18" "github.com/nginx/nginx"