#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/solr" "8 7.7 7.6 7.5 6.6 5.5"