#!/usr/bin/env bash

set -e

. ../update.sh

update_base_alpine "wodby/opensmtpd" "3.9" "true"