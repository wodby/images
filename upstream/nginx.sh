#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/nginx" "1.25 1.24 1.23" "github.com/nginx/nginx"