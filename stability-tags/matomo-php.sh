#!/usr/bin/env bash

set -e

. ../update.sh

rebuild_and_rebase "wodby/matomo" "7.1" "1.x"