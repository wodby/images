#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/elasticsearch" "7" "github.com/elastic/elasticsearch"