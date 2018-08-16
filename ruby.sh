#!/usr/bin/env bash

set -e

versions=(2.5 2.4 2.3)

./update-image.sh "wodby/ruby" "${versions}"