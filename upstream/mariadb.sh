#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/mariadb" "10.3 10.2 10.1" "github.com/MariaDB/server"