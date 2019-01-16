#!/usr/bin/env bash

set -e

. ../update.sh

rebuild_and_rebase "wodby/httpd" "3.8" "" "wodby/alpine"
