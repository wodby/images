#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/prometheus" "3.13" "github.com/prometheus/prometheus"
