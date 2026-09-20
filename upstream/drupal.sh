#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/drupal" "11 10" "github.com/drupal/drupal" "packagist:drupal/recommended-project"
