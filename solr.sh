#!/usr/bin/env bash

set -e

versions=(7.4 7.3 7.2 7.1 6.6 5.5 5.4)

./update-image.sh "wodby/solr" "${versions}"