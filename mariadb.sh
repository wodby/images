#!/usr/bin/env bash

set -e

versions=(10.3 10.2 10.1)

./update-image.sh "wodby/mariadb" "${versions}"