#!/usr/bin/env bash

set -e

versions=(4)

./update-image.sh "wodby/wordpress" "${versions}" "4.x"