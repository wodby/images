#!/usr/bin/env bash

set -e

versions=(1.15 1.14 1.13)

./update-image.sh "wodby/nginx" "${versions[@]}" "" "nginx"