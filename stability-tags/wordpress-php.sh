#!/usr/bin/env bash

set -e

. ../update.sh

rebuild_and_rebase "wodby/wordpress-php" "8.1 8.0 7.4" "4.x"