#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/vinyl" "8.0 6.0" "code.vinyl-cache.org/vinyl-cache/vinyl-cache" "" "https://vinyl-cache.org/downloads/varnish-{{version}}.tgz" "varnish- vinyl-cache-"
