#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../update.sh"

# Follow wodby/alpine 3.24 revisions; each new base revision releases a new image revision.
update_base_alpine "wodby/rsyslog" "3.24" "true"
