#!/usr/bin/env bash

set -e

. ../update.sh

update_from_upstream "wodby/zookeeper" "3.9" "github.com/apache/zookeeper" "" "https://downloads.apache.org/zookeeper/zookeeper-{{version}}/apache-zookeeper-{{version}}-bin.tar.gz"
