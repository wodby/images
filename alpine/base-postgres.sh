#!/usr/bin/env bash

set -e

. ../update.sh

update_base_alpine "wodby/base-postgres" "3.15"