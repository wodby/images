#!/usr/bin/env bash

set -e

. ../update.sh

rebuild_and_rebase "wodby/wordpress" "7.2 7.1 5.6" "4.x"