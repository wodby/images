#!/usr/bin/env bash

set -e

versions=(1.5)

./update-image.sh "wodby/memcached" "${versions[@]}"