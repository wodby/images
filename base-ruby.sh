#!/usr/bin/env bash

set -e

. lib.sh

git clone "https://${GITHUB_MACHINE_USER}:${GITHUB_MACHINE_USER_API_TOKEN}@github.com/wodby/base-ruby" /tmp/base-ruby
cd /tmp/base-ruby
git remote add upstream https://github.com/docker-library/ruby
git fetch upstream
git merge --strategy-option ours --no-edit upstream/master

./wodby-meta-update.sh

git_commit ./ "Merge changes from upstream"

git push origin
