#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/kibana" "7" "github.com/elastic/kibana" "" "https://artifacts.elastic.co/downloads/kibana/kibana-{{version}}-linux-x86_64.tar.gz"
