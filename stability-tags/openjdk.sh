#!/usr/bin/env bash

set -e

. ../update.sh

rebuild_and_rebase "wodby/openjdk" "3.8" "" "wodby/alpine"
