#!/usr/bin/env bash

set -e

versions=(7.1)

./update-image.sh "wodby/cachet" "${versions}" "1.x"