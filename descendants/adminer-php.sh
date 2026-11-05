#!/usr/bin/env bash

set -e

. ../update.sh

update_from_parent_image "wodby/adminer" "8.4-apache"
