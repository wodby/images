#!/usr/bin/env bash

set -e

versions=(3.7 3.6 3.5 3.4 2.7)

./update-image.sh "wodby/python" "${versions[@]}"
