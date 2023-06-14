#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/mariadb" "11.0 10.11 10.10 10.9 10.6 10.5 10.4" "github.com/MariaDB/server"