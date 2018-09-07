#!/usr/bin/env bash

set -e

. ../update.sh

rebuild_and_rebase "wodby/drupal-php" "7.2 7.1 7.0 5.6 5.3" "4.x"
