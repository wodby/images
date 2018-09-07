#!/usr/bin/env bash

set -e

. ../update.sh

rebuild_and_rebase "wodby/drupal" "5.6 5.3" "4.x"