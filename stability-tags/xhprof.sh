#!/usr/bin/env bash

set -e

. ../update.sh

rebuild_and_rebase "wodby/xhprof" "7.1" "1.x"
