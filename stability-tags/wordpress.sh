#!/usr/bin/env bash

set -e

. ../update.sh

rebuild_and_rebase "wodby/wordpress" "8.3 8.2 8.1" "4.x"