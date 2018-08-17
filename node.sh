#!/usr/bin/env bash

set -e

versions=(10.9 8.11 6.14)

./update-image.sh "wodby/node" "${versions[@]}"