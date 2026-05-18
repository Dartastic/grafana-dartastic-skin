#!/usr/bin/env bash
# Build the Dartastic Hosted skinned LGTM image and push to GHCR.
#
# Tagging:
#   <upstream-tag>-d<skin-rev>    e.g. 0.7.4-d1, 0.7.4-d2, …
#   latest                        — moved to the most recent tag after smoke
#
# The skin-rev is bumped manually when we ship a new skin (CSS change,
# new logo, etc.) without bumping the upstream image. When upstream
# moves, reset skin-rev to 1.
#
# Prereqs:
#   - docker buildx with a builder that supports linux/amd64,linux/arm64
#   - GHCR write token in $CR_PAT (or run mint-ghcr-token.sh first)
#
# Usage:
#   UPSTREAM_TAG=0.7.4 SKIN_REV=1 ./build-and-push.sh
#   UPSTREAM_TAG=0.7.4 SKIN_REV=1 PUSH=0 ./build-and-push.sh   # local only

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${UPSTREAM_TAG:?set UPSTREAM_TAG (the grafana/otel-lgtm tag to layer onto)}"
: "${SKIN_REV:=1}"
: "${PUSH:=1}"
: "${REGISTRY:=ghcr.io/dartastic}"
: "${IMAGE:=lgtm-skinned}"

TAG="${UPSTREAM_TAG}-d${SKIN_REV}"
FULL="${REGISTRY}/${IMAGE}:${TAG}"
LATEST="${REGISTRY}/${IMAGE}:latest"

echo "==> Building ${FULL} (upstream=grafana/otel-lgtm:${UPSTREAM_TAG})"

# Sanity check: required asset files exist. The Dockerfile COPYs would
# fail later anyway, but failing here with a clear message saves a
# build round-trip.
for f in img/grafana_icon.svg img/grafana_typelogo.svg img/fav32.png \
         img/apple-touch-icon.png img/g8_login_dark.svg img/g8_login_light.svg \
         css/dartastic-skin.css; do
  if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
    echo "ERROR: missing $f — see doc/plans/dartastic-hosted-whitelabel.md Phase 2" >&2
    exit 1
  fi
done

cd "$SCRIPT_DIR"

if [[ "${PUSH}" == "1" ]]; then
  docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --build-arg "UPSTREAM_TAG=${UPSTREAM_TAG}" \
    --tag "${FULL}" \
    --tag "${LATEST}" \
    --push \
    .
else
  docker buildx build \
    --build-arg "UPSTREAM_TAG=${UPSTREAM_TAG}" \
    --tag "${FULL}" \
    --tag "${LATEST}" \
    --load \
    .
fi

echo "==> Built ${FULL}"
echo "==> Smoke test locally:"
echo "    docker run --rm -p 3000:3000 ${LATEST}"
echo "    curl -fsS http://127.0.0.1:3000 | grep -i dartastic"
