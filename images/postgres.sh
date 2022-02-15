#!/usr/bin/env bash

set -e

. ../update.sh

# http://www.databasesoup.com/2016/05/changing-postgresql-version-numbering.html
update_from_base_image "wodby/postgres" "14 13 12 11 10"