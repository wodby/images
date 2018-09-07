#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/elasticsearch" "6.3 6.2 6.1 6.0 5.6 5.5 5.4" "github.com/elastic/elasticsearch"