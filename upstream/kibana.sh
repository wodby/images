#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/kibana" "6.7 6.6 6.5 6.4 6.3 6.2 6.1 6.0 5.6" "github.com/elastic/kibana"