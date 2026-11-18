#!/usr/bin/env bash
# Push one architecture image and record the digest that this push produced.
#
# Per-architecture tags such as wodby/mariadb:11.4-amd64 are shared by every
# workflow run of a repository. Combining them by tag lets an overlapping run
# replace one architecture before the multi-arch image is created, so the
# publish job combines the digests recorded here instead (see arch-image-pins).
set -euo pipefail

: "${IMAGE:?Missing image}" "${RECORD_DIR:?Missing record directory}"

# Only repository:tag references; the record name is derived from them.
if [[ ! "$IMAGE" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
    echo "Invalid architecture image reference: $IMAGE" >&2
    exit 1
fi
repository="${IMAGE%:*}"
record="${IMAGE//[\/:]/_}"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
docker push "$IMAGE" | tee "$log"

# docker push ends with "<tag>: digest: sha256:<hex> size: <bytes>".
digest="$(sed -nE 's/^.*: digest: (sha256:[0-9a-f]{64}) size: [0-9]+$/\1/p' "$log" | tail -n 1)"
if [[ -z "$digest" ]]; then
    echo "docker push reported no digest for $IMAGE" >&2
    exit 1
fi
# Fail here rather than in the publish job if the registry lacks the digest.
docker buildx imagetools inspect "$repository@$digest" >/dev/null

mkdir -p "$RECORD_DIR"
printf '%s@%s\n' "$repository" "$digest" > "$RECORD_DIR/$record"
echo "Recorded $IMAGE as $repository@$digest"
{
    echo "digest-ref=$repository@$digest"
    echo "record=$RECORD_DIR/$record"
    echo "artifact=arch-image-pin-$record"
} >> "${GITHUB_OUTPUT:-/dev/null}"
