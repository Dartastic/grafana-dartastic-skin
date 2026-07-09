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
# Prereqs: docker buildx, jq, curl, python3; CR_PAT + GHCR_USER for push/rev
# discovery (doppler run -p hosted -c prd -- ./build-grafana-skinned.sh).
#
# After a green build, run the brand-scan gate against it:
#   cd brand-scan && IMAGE=ghcr.io/dartastic-io/grafana-skinned:<tag> ./run-local.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${REGISTRY:=ghcr.io/dartastic-io}"
: "${IMAGE:=grafana-skinned}"
: "${PUSH:=1}"
# Pin: the Grafana version inside the current lgtm-skinned (13.0.1) — keep the
# two images on the same Grafana until lgtm-skinned retires post-convergence.
: "${UPSTREAM_TAG:=13.0.1}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 \
    || { echo "ERROR: missing required command: $1" >&2; exit 1; }
}
need_cmd docker; need_cmd jq; need_cmd curl; need_cmd python3

# ── SKIN_REV auto-discovery (same GHCR logic as build-and-push.sh) ──
discover_next_skin_rev() {
  local upstream="$1"
  local user="${GHCR_USER:-}"
  local pat="${CR_PAT:-${GHCR_PAT:-}}"
  if [[ -z "$user" || -z "$pat" ]]; then
    echo "warn: GHCR_USER / CR_PAT not set — can't auto-discover SKIN_REV." >&2
    echo "1"; return 0
  fi
  local ns="${REGISTRY#ghcr.io/}"
  local token
  token=$(curl -sS --max-time 10 -u "${user}:${pat}" \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:${ns}/${IMAGE}:pull" \
    2>/dev/null | jq -r '.token // empty')
  if [[ -z "$token" ]]; then
    echo "FATAL: GHCR token mint failed with creds set — refusing the rev-1 fallback." >&2
    return 1
  fi
  local tags_json
  tags_json=$(curl -sS --max-time 10 -H "Authorization: Bearer $token" \
    "https://ghcr.io/v2/${ns}/${IMAGE}/tags/list" 2>/dev/null || echo '{}')
  if ! jq -e '.tags | type == "array"' >/dev/null 2>&1 <<<"$tags_json"; then
    # First-ever build of this image (404, no package) is expected — but make
    # the operator say so, same guard as build-and-push.sh.
    echo "FATAL: GHCR tag list for ${ns}/${IMAGE} unusable. First-ever build?" >&2
    echo "       Pass SKIN_REV=1 explicitly. Response: $(head -c 200 <<<"$tags_json")" >&2
    return 1
  fi
  local max
  max=$(echo "$tags_json" | jq -r --arg up "$upstream" \
    '[.tags[]? | capture("^" + $up + "-d(?<n>[0-9]+)$") | .n | tonumber] | max // 0')
  echo "$((max + 1))"
}

if [[ -z "${SKIN_REV:-}" ]]; then
  SKIN_REV=$(discover_next_skin_rev "$UPSTREAM_TAG")
  echo "==> Auto-discovered SKIN_REV=$SKIN_REV (next after newest ${UPSTREAM_TAG}-d<N> on GHCR)"
fi

TAG="${UPSTREAM_TAG}-d${SKIN_REV}"
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
    --tag "${FULL}" --tag "${LATEST}" \
    --push .
else
  docker buildx build \
    --file Dockerfile.grafana \
    --build-arg "UPSTREAM_TAG=${UPSTREAM_TAG}" \
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
