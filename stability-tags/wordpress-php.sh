#!/usr/bin/env bash

set -e

. ../update.sh

rebuild_and_rebase "wodby/wordpress-php" "8.5 8.4 8.3 8.2" "4.x"