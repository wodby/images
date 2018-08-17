#!/usr/bin/env bash

set -e

versions=(7.2 7.1 7.0 5.6)

./update-image.sh "wodby/wordpress-php" "${versions[@]}" "4.x"