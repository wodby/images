#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/wordpress" "7" "github.com/WordPress/WordPress" "https://wordpress.org/wordpress-{{version}}.tar.gz"
