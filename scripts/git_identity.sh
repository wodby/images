#!/usr/bin/env bash

# Keep automated commits and annotated tags on the configured bot account,
# including when the runner supplies another Git identity through its environment.
configure_wodbot_git_identity() {
  export GIT_AUTHOR_NAME="${WODBOT_GIT_NAME:-Wodby Robot}"
  export GIT_AUTHOR_EMAIL="${WODBOT_GIT_EMAIL:-robot@wodby.com}"
  export GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
  export GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
  git config --local user.name "${GIT_AUTHOR_NAME}"
  git config --local user.email "${GIT_AUTHOR_EMAIL}"
}
