#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/nginx" "1.28 1.27" "github.com/nginx/nginx"