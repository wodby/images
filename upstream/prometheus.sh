#!/usr/bin/env bash

set -e

. ../update.sh

# The image builds FROM prom/prometheus, which upstream publishes after the git tag.
update_from_upstream "wodby/prometheus" "3.13" "github.com/prometheus/prometheus" "https://hub.docker.com/v2/namespaces/prom/repositories/prometheus/tags/v{{version}}"
