#!/usr/bin/env bash

set -e

. ../update.sh

rebuild_and_rebase "wodby/drupal" "7.2 7.1 7.0" "4.x"