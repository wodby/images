#!/usr/bin/env bash

set -e

. ../update.sh

rebuild_and_rebase "wodby/drupal" "8.2 8.1 8.0" "4.x"