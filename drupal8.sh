#!/usr/bin/env bash

set -e

versions=(7.2 7.1 7.0)

./update-image.sh "wodby/drupal" "${versions}" "4.x" "" 8