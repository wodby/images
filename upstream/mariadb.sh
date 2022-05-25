#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/mariadb" "10.7 10.6 10.5 10.4 10.3" "github.com/MariaDB/server"