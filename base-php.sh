#!/usr/bin/env bash

set -ex

. ./git.sh

git clone "https://${GITHUB_MACHINE_USER}:${GITHUB_MACHINE_USER_API_TOKEN}@github.com/wodby/base-php"
git remote add upstream https://github.com/docker-library/php
git fetch upstream
git merge --strategy-option ours upstream/master

./wodby-meta-update.sh

git_commit ./ "Merge changes from upstream"

git push origin
