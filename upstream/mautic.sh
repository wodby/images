#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/mautic" "7" "github.com/mautic/mautic"
