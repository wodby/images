#!/usr/bin/env bash

set -e

versions=(8 7 6)

./update-image.sh "wodby/drupal" "${versions}" "4.x"