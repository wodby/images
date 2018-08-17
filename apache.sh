#!/usr/bin/env bash

set -e

versions=(2.4)

./update-image.sh "wodby/apache" "${versions[@]}"
