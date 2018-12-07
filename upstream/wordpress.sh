#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/wordpress" "5" "github.com/WordPress/WordPress" "4.x"