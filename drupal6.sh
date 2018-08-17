#!/usr/bin/env bash

set -e

versions=(5.6 5.3)

./update-image.sh "wodby/drupal" "${versions}" "4.x" "" 6