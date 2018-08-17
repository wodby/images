#!/usr/bin/env bash

set -e

versions=(7.1)

./update-image.sh "wodby/matomo" "${versions[@]}" "1.x"