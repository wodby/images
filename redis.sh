#!/usr/bin/env bash

set -e

versions=(4.0 3.2)

./update-image.sh "wodby/redis" "${versions[@]}"