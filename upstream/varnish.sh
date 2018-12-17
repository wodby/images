#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/varnish" "6.0 4.1" "github.com/varnishcache/varnish-cache"