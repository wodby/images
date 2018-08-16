#!/usr/bin/env bash

set -e

# http://www.databasesoup.com/2016/05/changing-postgresql-version-numbering.html
versions=(10 9.6 9.5 9.4 9.3)

./update-image.sh "wodby/postgres" "${versions}"