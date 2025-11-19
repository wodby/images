#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/mariadb" "11.8 11.4 10.11 10.6" "github.com/MariaDB/server"