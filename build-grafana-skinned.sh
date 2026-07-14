#!/usr/bin/env bash
# Build the Dartastic skinned STANDALONE Grafana image (grafana-skinned) and
# push to GHCR. Second target of the same skin — see Dockerfile.grafana.
#
# Tagging mirrors build-and-push.sh:  <grafana-tag>-d<skin-rev>, plus :latest.
#
#   ./build-grafana-skinned.sh                 # auto-rev, build+push
#   UPSTREAM_TAG=13.1.0 ./build-grafana-skinned.sh
#   SKIN_REV=1 PUSH=0 ./build-grafana-skinned.sh   # first/local build
#
# Prereqs: docker buildx, jq, curl, python3, and GHCR creds for rev discovery +
# push. Doppler hosted/prd carries GHCR_USER + GHCR_DEPLOY_PAT, so:
#   doppler run -p hosted -c prd -- ./build-grafana-skinned.sh
# Rev discovery is mandatory (no creds = no build): see lib/ghcr-rev.sh for the
# three times a guessed rev silently overwrote a published image.
#
# After a green build, run the brand-scan gate against it:
#   cd brand-scan && IMAGE=ghcr.io/dartastic-io/grafana-skinned:<tag> ./run-local.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${REGISTRY:=ghcr.io/dartastic-io}"
: "${IMAGE:=grafana-skinned}"
: "${PUSH:=1}"
# Product branding stamped into the skin at build (login title + text
# rewrites). Default = hosted. Cloud build:
#   PRODUCT_NAME="Dartastic Cloud Observatory" IMAGE=grafana-skinned-cloud \
#     ./build-grafana-skinned.sh
: "${PRODUCT_NAME:=Dartastic Hosted}"
# Pin: the Grafana version inside the current lgtm-skinned (13.0.1) — keep the
# two images on the same Grafana until lgtm-skinned retires post-convergence.
: "${UPSTREAM_TAG:=13.0.1}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 \
    || { echo "ERROR: missing required command: $1" >&2; exit 1; }
}
need_cmd docker; need_cmd jq; need_cmd curl; need_cmd python3

# ── Pick SKIN_REV against GHCR — the registry is the only truth ──
# Shared with build-and-push.sh: this file used to carry its own copy of the
# discovery logic, which is how it kept the "no creds => rev 1" fallback months
# after the other script grew guards against it. One implementation now; see
# lib/ghcr-rev.sh for the three in-place overwrites that bought these rules.
source "$SCRIPT_DIR/lib/ghcr-rev.sh"

NS="${REGISTRY#ghcr.io/}"
GHCR_TOKEN="$(ghcr_token "$NS" "$IMAGE")"
GHCR_TAGS="$(ghcr_tags "$NS" "$IMAGE" "$GHCR_TOKEN")"

if [[ -z "${SKIN_REV:-}" ]]; then
  SKIN_REV="$(ghcr_next_skin_rev "$UPSTREAM_TAG" "$GHCR_TAGS")"
  echo "==> SKIN_REV=$SKIN_REV (next after the newest ${UPSTREAM_TAG}-d<N> on GHCR)"
else
  echo "==> SKIN_REV=$SKIN_REV (operator-supplied — verifying it's actually free)"
fi

TAG="${UPSTREAM_TAG}-d${SKIN_REV}"
ghcr_assert_tag_free "$NS" "$IMAGE" "$TAG" "$GHCR_TAGS"
FULL="${REGISTRY}/${IMAGE}:${TAG}"
LATEST="${REGISTRY}/${IMAGE}:latest"

echo "==> Building ${FULL} (upstream=grafana/grafana:${UPSTREAM_TAG})"

for f in img/grafana_icon.svg img/grafana_typelogo.svg img/fav32.png \
         img/apple-touch-icon.png img/g8_login_dark.svg img/g8_login_light.svg \
         css/dartastic-skin.css js/dartastic-skin.js conf/custom.ini \
         build/rewrite-locale.py Dockerfile.grafana; do
  [[ -f "$SCRIPT_DIR/$f" ]] || { echo "ERROR: missing $f" >&2; exit 1; }
done

cd "$SCRIPT_DIR"

# ── Stage the rewritten locale, extracted from THIS upstream image ──
# (standalone Grafana path, not the /otel-lgtm one).
echo "==> Extracting grafana/grafana:${UPSTREAM_TAG} en-US locale + rewriting"
docker pull "grafana/grafana:${UPSTREAM_TAG}" >/dev/null
EXTRACTOR_ID="$(docker create "grafana/grafana:${UPSTREAM_TAG}")"
trap "docker rm '$EXTRACTOR_ID' >/dev/null 2>&1 || true" EXIT
docker cp "${EXTRACTOR_ID}:/usr/share/grafana/public/locales/en-US/grafana.json" \
  "$SCRIPT_DIR/build/upstream-grafana-en-US.json"
python3 "$SCRIPT_DIR/build/rewrite-locale.py" \
  "$SCRIPT_DIR/build/upstream-grafana-en-US.json" \
  "$SCRIPT_DIR/build/skin-grafana-en-US.json"

if [[ "${PUSH}" == "1" ]]; then
  docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --file Dockerfile.grafana \
    --build-arg "UPSTREAM_TAG=${UPSTREAM_TAG}" \
    --build-arg "PRODUCT_NAME=${PRODUCT_NAME}" \
    --tag "${FULL}" --tag "${LATEST}" \
    --push .
else
  docker buildx build \
    --file Dockerfile.grafana \
    --build-arg "UPSTREAM_TAG=${UPSTREAM_TAG}" \
    --build-arg "PRODUCT_NAME=${PRODUCT_NAME}" \
    --tag "${FULL}" --tag "${LATEST}" \
    --load .
fi

cat <<EOF

────────────────────────────────────────────────────────────────
Built ${FULL}$( [[ "$PUSH" == "1" ]] && echo " (pushed, also :latest)" ).

Next:
  1. Brand-scan gate (blocking before any deploy/mirror):
       cd brand-scan && IMAGE=${FULL} ./run-local.sh
  2. Pin it in docker-compose.cloud.yml (grafana service).
  3. Mirror the skin source (mirror-skin.sh) — Dockerfile.grafana +
     build-grafana-skinned.sh are part of the AGPL §13 offer.
────────────────────────────────────────────────────────────────
EOF
