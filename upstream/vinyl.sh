#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/vinyl" "9.1 6.0" "code.vinyl-cache.org/vinyl-cache/vinyl-cache" "https://vinyl-cache.org/downloads/vinyl-cache-{{version}}.tgz https://vinyl-cache.org/downloads/varnish-{{version}}.tgz" "varnish- vinyl-cache-"
