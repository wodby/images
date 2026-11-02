#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/rustdesk" "1" "github.com/rustdesk/rustdesk-server"
