#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/elasticsearch" "6.7 5.6" "github.com/elastic/elasticsearch"