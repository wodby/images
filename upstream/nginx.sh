#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/nginx" "1.31 1.30" "github.com/nginx/nginx" "" "https://nginx.org/download/nginx-{{version}}.tar.gz"
