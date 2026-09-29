#!/usr/bin/env bash
# Mirror skin/ to the public AGPL §13 repo, tag the mirror commit, and print it.
#
#   PUBLIC_REMOTE=… PUBLIC_CLONE=… ./mirror-and-tag.sh <tag>
#   e.g. ./mirror-and-tag.sh grafana-skinned-cloud-13.0.1-d33
#
# WHY: a Self-Hosted bundle pins the corresponding source of every AGPL image
# by the image's org.opencontainers.image.revision, which must be a TAGGED
# commit of github.com/Dartastic/grafana-dartastic-skin. So the source is
# mirrored and tagged BEFORE the image is built, and the build refuses to push
# without the sha this prints (build-grafana-skinned.sh, MIRROR_REVISION).
#
# Steps, each verified at the remote, any failure fatal:
#   1. mirror-skin.sh (idempotent: "no changes" leaves the mirror's HEAD as the
#      mirror of this tree). Retried after a fresh fetch if another workflow
#      pushed first (build-skin.yml mirrors on the same pushes).
#   2. The remote main IS the local HEAD.
#   3. <tag> on that commit, pushed, and the remote tag resolves to it. A tag
#      that already exists at ANOTHER commit is an error, never moved.
# Prints the full sha as the last line; with GITHUB_OUTPUT set, also
# `revision=<sha>` there.
set -euo pipefail

TAG="${1:?usage: mirror-and-tag.sh <tag>}"
[[ "$TAG" =~ ^[a-z0-9][a-z0-9.-]*-d[0-9]+$ ]] || { echo "ERROR: tag '$TAG' is not <image>-<version>-d<N>" >&2; exit 1; }
: "${PUBLIC_REMOTE:?PUBLIC_REMOTE required}"
: "${PUBLIC_CLONE:?PUBLIC_CLONE required}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

attempt=1
until PUBLIC_REMOTE="$PUBLIC_REMOTE" PUBLIC_CLONE="$PUBLIC_CLONE" "$SCRIPT_DIR/mirror-skin.sh"; do
  if (( attempt >= 3 )); then
    echo "ERROR: mirror-skin.sh failed $attempt times" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  echo "mirror-skin.sh failed; refetching the public repo and retrying ($attempt/3)" >&2
  git -C "$PUBLIC_CLONE" fetch -q origin main
  git -C "$PUBLIC_CLONE" reset -q --hard origin/main   # the throwaway CI clone only
  sleep 5
done

SHA="$(git -C "$PUBLIC_CLONE" rev-parse HEAD)"
REMOTE_MAIN="$(git -C "$PUBLIC_CLONE" ls-remote origin refs/heads/main | cut -f1)"
[[ "$REMOTE_MAIN" == "$SHA" ]] \
  || { echo "ERROR: the public main is $REMOTE_MAIN, not the mirrored $SHA" >&2; exit 1; }

EXISTING="$(git -C "$PUBLIC_CLONE" ls-remote origin "refs/tags/$TAG" | cut -f1)"
if [[ -n "$EXISTING" ]]; then
  [[ "$EXISTING" == "$SHA" ]] \
    || { echo "ERROR: tag $TAG already exists at $EXISTING, not $SHA; refusing to move it" >&2; exit 1; }
  echo "tag $TAG already at $SHA" >&2
else
  git -C "$PUBLIC_CLONE" tag "$TAG" "$SHA"
  git -C "$PUBLIC_CLONE" push -q origin "refs/tags/$TAG"
  PUSHED="$(git -C "$PUBLIC_CLONE" ls-remote origin "refs/tags/$TAG" | cut -f1)"
  [[ "$PUSHED" == "$SHA" ]] \
    || { echo "ERROR: tag $TAG resolves to '$PUSHED' on the remote, not $SHA" >&2; exit 1; }
  echo "tagged $TAG at $SHA" >&2
fi

[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "revision=$SHA" >> "$GITHUB_OUTPUT"
echo "$SHA"
