#!/usr/bin/env bash

set -e

. ../update.sh

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # One release covers the source and the Ubuntu variant updates found in this
  # run. The trap still releases updates already pushed when a later step fails.
  _release_batch_start
  trap '_release_batch_finish' EXIT
  update_from_upstream "wodby/mariadb" "12.3 11.8 11.4 10.11" "github.com/MariaDB/server" "https://archive.mariadb.org/mariadb-{{version}}/source/mariadb-{{version}}.tar.gz"
  # The Ubuntu variant follows the official mariadb image, not the source releases.
  update_variant_from_base_image "wodby/mariadb" "12.3 11.8 11.4" "ubuntu" "_UBUNTU"
  trap - EXIT
  _release_batch_finish
fi
