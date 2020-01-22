#!/usr/bin/env bash

set -e

. ../update.sh

# Cachet doesn't yet support 7.2
#rebuild_and_rebase "wodby/cachet" "7.1"