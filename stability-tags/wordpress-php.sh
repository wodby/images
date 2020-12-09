#!/usr/bin/env bash

set -e

. ../update.sh

rebuild_and_rebase "wodby/wordpress-php" "8.0 7.4 7.3 7.2" "4.x"