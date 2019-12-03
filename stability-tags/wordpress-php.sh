#!/usr/bin/env bash

set -e

. ../update.sh

rebuild_and_rebase "wodby/wordpress-php" "7.4 7.3 7.2 7.1 5.6" "4.x"