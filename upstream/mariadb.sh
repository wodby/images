#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/mariadb" "10.5 10.4 10.3 10.2" "github.com/MariaDB/server"