#!/usr/bin/env bash

set -euo pipefail

updater_image='wodby/docker:dev@sha256:733230bc461c3a4173fea8fe835bc58bf9698fc58c701510d10edc6b9c1af09b'
logged_in=0
cleanup() {
  if [[ "${logged_in}" == "1" ]]; then
    docker logout || true
  fi
}
trap cleanup EXIT
if [[ -n "${DOCKER_USERNAME:-}" && -n "${DOCKER_PASSWORD:-}" ]]; then
  docker login -u "${DOCKER_USERNAME}" --password-stdin <<<"${DOCKER_PASSWORD}"
  logged_in=1
fi

# Retry only the pull: rerunning the updater could repeat commits or releases.
for attempt in 1 2 3; do
  echo "Pulling updater image (attempt ${attempt}/3)"
  if docker pull --quiet "${updater_image}"; then
    break
  fi
  if [[ "${attempt}" == 3 ]]; then
    echo >&2 "Failed to pull updater image after 3 attempts"
    exit 1
  fi
  sleep "$((attempt * 5))"
done

echo "Checking ${dir}/${script} for updates"
docker run --pull=never -e WODBOT_GITHUB_PAT -e WODBOT_GITHUB_USERNAME -e WODBOT_GIT_EMAIL -e WODBOT_GIT_NAME -e DEBUG -e IMAGES_UPDATE_PUSH \
  -e IMAGES_UPDATE_REPORT_FILE="/images/${report_file}" \
  -e IMAGES_UPDATE_DIR="${dir}" \
  -e IMAGES_UPDATE_SCRIPT="${script}" \
  -e IMAGES_HOST_ROOT="${PWD}" \
  --rm -v "${PWD}:/images" -v /var/run/docker.sock:/var/run/docker.sock \
  "${updater_image}" \
  bash -c 'cd "/images/${IMAGES_UPDATE_DIR}" && "./${IMAGES_UPDATE_SCRIPT}.sh"'
