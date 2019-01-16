#!/usr/bin/env bash

set -e

. ../update.sh

rebuild_and_rebase "wodby/base-php" "3.8" "" "wodby/alpine"
