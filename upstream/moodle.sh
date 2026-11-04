#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/moodle" "5.3" "github.com/moodle/moodle"
