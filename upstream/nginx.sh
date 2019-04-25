#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/nginx" "1.16 1.15 1.14 1.13" "nginx"