#!/usr/bin/env bash

set -e

. ../update.sh

rebuild_and_rebase "wodby/base-python" "3.8" "" "wodby/alpine"
