#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "wodby/solr" "7.5 7.4 7.3 7.2 7.1 6.6 6.4 5.5 5.4"