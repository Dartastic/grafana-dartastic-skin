#!/usr/bin/env bash
# Build the Dartastic Hosted skinned LGTM image and push to GHCR.
#
# Tagging:
#   <upstream-tag>-d<skin-rev>    e.g. 0.28.0-d9, 0.28.0-d10, …
#   latest                        — also moved to the most recent tag
#
# Dead-simple invocation (auto-discovery does the right thing):
#
#   ./build-and-push.sh
#
# What auto-discovery does:
#
#   - UPSTREAM_TAG defaults to whatever `../docker-compose.dartastic.yml`
#     currently pins for lgtm-skinned (the `${LGTM_TAG:-<tag>}` default), with
#     the -d<N> stripped.  So if it says `lgtm-skinned:${LGTM_TAG:-0.28.0-d9}`,
#     UPSTREAM_TAG becomes `0.28.0`.  Keeps every dev build on the same upstream
#     track as production unless you explicitly bump.
#
#   - SKIN_REV defaults to the next integer past the highest existing
#     `<UPSTREAM_TAG>-d<N>` tag ON GHCR — never off the compose pin, which lags
#     (CI pushes a rev per merge to main; the pin moves only when a human
#     promotes it). No credentials, no discovery, no build: a guessed rev
#     republishes a live image instead of erroring. See lib/ghcr-rev.sh.
#
#   - This does NOT rewrite any compose file. To make a build the fleet default,
#     bump the `${LGTM_TAG:-<tag>}` pin in docker-compose.dartastic.yml, commit
#     (build-hosted.yml rebuilds the carrier), and roll-hosted-fleet.sh. The
#     script prints these next-steps after a push.
#
# Override either default if you want to:
#
#   UPSTREAM_TAG=0.29.0 ./build-and-push.sh        # bumping upstream
#   SKIN_REV=99 ./build-and-push.sh                # forcing a rev (must be free)
#   PUSH=0 ./build-and-push.sh                     # local-only build
#   NO_COMPOSE_BUMP=1 ./build-and-push.sh          # accepted no-op (back-compat)
#
# Prereqs:
#   - docker buildx multi-arch builder (linux/amd64,linux/arm64)
#   - jq, curl on $PATH
#   - GHCR_USER + GHCR_DEPLOY_PAT (read:packages min). Doppler hosted/prd has
#     both under exactly those names — just run under it:
#       doppler run -p hosted -c prd -- ./build-and-push.sh
#     (CR_PAT is also accepted; that's the name CI injects. For months the
#      scripts read ONLY CR_PAT while Doppler shipped GHCR_DEPLOY_PAT, so the
#      documented local invocation silently authenticated as nobody.)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# GHCR org is dartastic-io (where provisioner/pubdev/symbolizer/watchdog live
# and what the per-box pull token is scoped to + what docker-compose.dartastic.yml
# pulls). The old `ghcr.io/dartastic` default put the image in the wrong (public)
# org — so customer boxes 404'd it, and build-skin CI failed (the hosted repo's
# GITHUB_TOKEN can't push to a different org). One source of truth: dartastic-io.
: "${REGISTRY:=ghcr.io/dartastic-io}"
: "${IMAGE:=lgtm-skinned}"
: "${PUSH:=1}"
: "${NO_COMPOSE_BUMP:=0}"

# Source of truth for the production LGTM image tag is the unified box compose
# (docker-compose.dartastic.yml) — docker-compose.lgtm.yml was retired (hosted#131).
COMPOSE_FILE="$SCRIPT_DIR/../docker-compose.dartastic.yml"

# ── prereqs ──────────────────────────────────────────────────────
need_cmd() {
  command -v "$1" >/dev/null 2>&1 \
    || { echo "ERROR: missing required command: $1" >&2; exit 1; }
}
need_cmd docker
need_cmd jq
need_cmd curl

# ── 1. Auto-discover UPSTREAM_TAG from the compose file ─────────
# Source of truth for "what's in production right now" is the pinned
# lgtm-skinned image: line in docker-compose.dartastic.yml, which reads
# `lgtm-skinned:${LGTM_TAG:-<x.y.z>-d<N>}`. Pull the default tag out of the
# ${VAR:-…} form (also handles a bare literal tag), then strip the -d<N> suffix
# so we stay on the same upstream track. An env-set UPSTREAM_TAG always wins.
if [[ -z "${UPSTREAM_TAG:-}" ]]; then
  if [[ -f "$COMPOSE_FILE" ]]; then
    UPSTREAM_TAG=$(grep -E "image:.*${IMAGE}:" "$COMPOSE_FILE" \
      | head -1 \
      | sed -E "s|.*${IMAGE}:||; s|[\"' ].*\$||; s|^\\\$\\{[A-Za-z_]+:-||; s|\\}.*\$||; s|-d[0-9]+\$||")
  fi
  if [[ -z "${UPSTREAM_TAG:-}" ]]; then
    # Was: default to "latest". That builds the skin against a MOVING upstream
    # and tags it `latest-d<N>` — a tag no compose file pins and no operator
    # asked for. Same family as the rev fallbacks: guess something plausible
    # rather than stop. Stop.
    echo "FATAL: couldn't parse the lgtm-skinned pin out of $COMPOSE_FILE." >&2
    echo "       Pass UPSTREAM_TAG=<x.y.z> explicitly, or fix the pin line." >&2
    exit 1
  fi
  echo "==> Auto-discovered UPSTREAM_TAG=$UPSTREAM_TAG (from $COMPOSE_FILE)"
fi

# ── 2. Pick SKIN_REV against GHCR — the registry is the only truth ──
# See lib/ghcr-rev.sh for why every failure here is fatal and why the tag is
# checked for freedom even when the operator passed SKIN_REV by hand. Short
# version: an unverified rev doesn't error, it republishes a live image.
# NOTE the compose pin is NOT the current rev — CI pushes a rev per merge, so
# GHCR runs ahead of the pin. Never derive SKIN_REV from the compose file.
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

echo "==> Building ${FULL} (upstream=grafana/otel-lgtm:${UPSTREAM_TAG})"

# Sanity check: required asset files exist. The Dockerfile COPYs would
# fail later anyway, but failing here with a clear message saves a
# build round-trip.
for f in img/grafana_icon.svg img/grafana_typelogo.svg img/fav32.png \
         img/apple-touch-icon.png img/g8_login_dark.svg img/g8_login_light.svg \
         css/dartastic-skin.css js/dartastic-skin.js dashboards/home.json \
         conf/custom.ini conf/otelcol-config.yaml build/rewrite-locale.py \
         scripts/dartastic-entrypoint.sh \
         ../ai-gateway/bin/ai_gateway.dart ../ai-gateway/pubspec.yaml; do
  if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
    echo "ERROR: missing $f — see doc/plans/dartastic-hosted-whitelabel.md Phase 2" >&2
    exit 1
  fi
done

cd "$SCRIPT_DIR"

# Stage the customer-facing dashboards from ../dashboards/ into
# build/customer-dashboards/ so the Dockerfile can COPY them without
# crossing the docker build context boundary. `hosted/dashboards/`
# stays the single source of truth — operators import the same files
# from there if they're running outside our skinned image.
echo "==> Staging customer dashboards from ../dashboards/"
mkdir -p "$SCRIPT_DIR/build/customer-dashboards"
rm -f "$SCRIPT_DIR/build/customer-dashboards/"*.json
cp "$SCRIPT_DIR/../dashboards/"*.json "$SCRIPT_DIR/build/customer-dashboards/"
ls -1 "$SCRIPT_DIR/build/customer-dashboards/" | sed 's/^/    /'

# Stage the demo-specific dashboards from ../dashboards/demo/ into
# build/reference-demo-dashboards/. These land in their own
# "Dartastic Reference Demo" Grafana folder (see
# conf/dartastic-reference-demo-dashboards.yaml), separate from the
# product dashboards above. Source-of-truth stays
# `hosted/dashboards/demo/*.json`.
echo "==> Staging Dartastic Reference Demo dashboards from ../dashboards/demo/"
mkdir -p "$SCRIPT_DIR/build/reference-demo-dashboards"
rm -f "$SCRIPT_DIR/build/reference-demo-dashboards/"*.json
cp "$SCRIPT_DIR/../dashboards/demo/"*.json "$SCRIPT_DIR/build/reference-demo-dashboards/"
ls -1 "$SCRIPT_DIR/build/reference-demo-dashboards/" | sed 's/^/    /'

# Stage the AI gateway Dart source so the Dockerfile's stage-1
# `dart compile exe` can reach it without crossing the build
# context boundary.  Same pattern as the dashboards stage above.
# Source-of-truth files live in `../ai-gateway/`.
echo "==> Staging AI gateway source from ../ai-gateway/"
rm -rf "$SCRIPT_DIR/build/ai-gateway"
mkdir -p "$SCRIPT_DIR/build/ai-gateway"
# Skip .dart_tool/, pubspec.lock, test/ — Dockerfile doesn't need
# any of them and copying them slows the build context transfer.
rsync -a --exclude='.dart_tool' --exclude='pubspec.lock' --exclude='test' \
  --exclude='.gitignore' \
  "$SCRIPT_DIR/../ai-gateway/" "$SCRIPT_DIR/build/ai-gateway/"
echo "    $(find "$SCRIPT_DIR/build/ai-gateway" -name '*.dart' | wc -l | tr -d ' ') Dart files staged"

# Stage the AI Grafana plugin (#85 P1.D).  TypeScript source +
# webpack config; the Dockerfile's stage-2 npm-build produces the
# dist/ Grafana consumes.  Source-of-truth lives at
# `../grafana-plugins/dartastic-ai-panel/`.
echo "==> Staging AI Grafana plugin source from ../grafana-plugins/dartastic-ai-panel/"
rm -rf "$SCRIPT_DIR/build/ai-plugin"
mkdir -p "$SCRIPT_DIR/build/ai-plugin"
rsync -a --exclude='node_modules' --exclude='dist' --exclude='.gitignore' \
  "$SCRIPT_DIR/../grafana-plugins/dartastic-ai-panel/" "$SCRIPT_DIR/build/ai-plugin/"
echo "    $(find "$SCRIPT_DIR/build/ai-plugin/src" -name '*.ts' -o -name '*.tsx' 2>/dev/null | wc -l | tr -d ' ') TypeScript files staged"

# Regenerate the rewritten en-US locale catalog. We extract it from
# the upstream image (so version bumps don't ship stale strings),
# pipe through rewrite-locale.py, and land the result at
# build/skin-en-US.json for the Dockerfile to COPY in. The grafana/
# otel-lgtm base image is RHEL-minimal — no python — so this has to
# happen on the host before docker build.
echo "==> Extracting upstream en-US locale + rewriting Grafana → Dartastic"
docker pull "grafana/otel-lgtm:${UPSTREAM_TAG}" >/dev/null
EXTRACTOR_ID="$(docker create "grafana/otel-lgtm:${UPSTREAM_TAG}")"
trap "docker rm '$EXTRACTOR_ID' >/dev/null 2>&1 || true" EXIT
docker cp "${EXTRACTOR_ID}:/otel-lgtm/grafana/public/locales/en-US/grafana.json" \
  "$SCRIPT_DIR/build/upstream-en-US.json"
python3 "$SCRIPT_DIR/build/rewrite-locale.py" \
  "$SCRIPT_DIR/build/upstream-en-US.json" \
  "$SCRIPT_DIR/build/skin-en-US.json"

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

# ── 3. Deployment note (carrier flow) ───────────────────────────
# The production LGTM tag lives in docker-compose.dartastic.yml as
# `lgtm-skinned:${LGTM_TAG:-<tag>}`, carried by the dartastic-hosted image and
# rolled to boxes by roll-hosted-fleet.sh. We DON'T auto-rewrite that default
# here — bumping it needs a carrier rebuild (build-hosted.yml) to reach boxes,
# so the operator does it deliberately (see next-steps). NO_COMPOSE_BUMP is kept
# as an accepted no-op env for backward compat.

# ── 4. Tell the operator what to do next ────────────────────────
# Absolute paths instead of `realpath --relative-to` — the latter
# is GNU coreutils only; BSD realpath on macOS silently falls back
# to `.` and the operator gets useless `cd .` instructions.  Use
# the cd-style absolute paths, which work everywhere.
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cat <<EOF

────────────────────────────────────────────────────────────────
Built + pushed ${FULL}  (also tagged :latest).

To make this the default skin for every box, bump the pin in the unified
compose, rebuild the carrier, and roll the fleet:
    cd $REPO_DIR
    # edit docker-compose.dartastic.yml, lgtm service:
    #   image: ghcr.io/dartastic-io/lgtm-skinned:\${LGTM_TAG:-${TAG}}
    git add docker-compose.dartastic.yml && git commit -m "lgtm: bump skin to ${TAG}"
    git push                                       # build-hosted.yml rebuilds the carrier
    vultr/roll-hosted-fleet.sh --include-dogfood    # roll every box under doppler run

Or pin ONE box without changing the fleet default: set LGTM_TAG=${TAG} in that
box's Doppler config, then vultr/up-hosted-box.sh for it.
────────────────────────────────────────────────────────────────
EOF
