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
#   - UPSTREAM_TAG defaults to whatever `../vultr/docker-compose.lgtm.yml`
#     currently pins, with the -d<N> stripped.  So if the compose says
#     `lgtm-skinned:0.28.0-d9`, UPSTREAM_TAG becomes `0.28.0`.  This
#     keeps every dev build on the same upstream track as production
#     unless you explicitly bump.
#
#   - SKIN_REV defaults to the next integer past the highest existing
#     `<UPSTREAM_TAG>-d<N>` tag on GHCR.  So if `d9` is the newest
#     `0.28.0-d<N>` already pushed, this build is `d10`.  Talks to
#     https://ghcr.io/v2/.../tags/list using GHCR_USER + CR_PAT.
#
#   - After a successful push, the script bumps the `lgtm-skinned:` pin
#     in `../vultr/docker-compose.lgtm.yml` to the freshly-built tag.
#     `git diff` to review; `up-lgtm.sh` consumes this file directly.
#
# Override either default if you want to:
#
#   UPSTREAM_TAG=0.29.0 ./build-and-push.sh        # bumping upstream
#   SKIN_REV=99 ./build-and-push.sh                # forcing a rev
#   PUSH=0 ./build-and-push.sh                     # local-only build
#   NO_COMPOSE_BUMP=1 ./build-and-push.sh          # skip compose edit
#
# Prereqs:
#   - docker buildx multi-arch builder (linux/amd64,linux/arm64)
#   - jq, curl on $PATH
#   - GHCR write token in $CR_PAT (or GHCR_PAT), read:packages min
#   - GHCR_USER (your GitHub username; usually pre-set by `gh auth`)
#   - Easiest is to run via Doppler so both land:
#       doppler run -p hosted -c prd -- ./build-and-push.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# GHCR org is dartastic-io (where provisioner/pubdev/symbolizer/watchdog live
# and what the per-box pull token is scoped to + what vultr/docker-compose.lgtm.yml
# pulls). The old `ghcr.io/dartastic` default put the image in the wrong (public)
# org — so customer boxes 404'd it, and build-skin CI failed (the hosted repo's
# GITHUB_TOKEN can't push to a different org). One source of truth: dartastic-io.
: "${REGISTRY:=ghcr.io/dartastic-io}"
: "${IMAGE:=lgtm-skinned}"
: "${PUSH:=1}"
: "${NO_COMPOSE_BUMP:=0}"

COMPOSE_FILE="$SCRIPT_DIR/../vultr/docker-compose.lgtm.yml"

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
# image: line in vultr/docker-compose.lgtm.yml.  Strip the -d<N>
# suffix so we stay on the same upstream track unless explicitly
# overridden.  An env-set UPSTREAM_TAG always wins.
if [[ -z "${UPSTREAM_TAG:-}" ]]; then
  if [[ -f "$COMPOSE_FILE" ]]; then
    UPSTREAM_TAG=$(grep -oE "${IMAGE}:[0-9a-zA-Z._-]+" "$COMPOSE_FILE" \
      | head -1 \
      | sed -E "s|${IMAGE}:||; s|-d[0-9]+$||")
  fi
  if [[ -z "${UPSTREAM_TAG:-}" ]]; then
    echo "warn: couldn't parse UPSTREAM_TAG from $COMPOSE_FILE — defaulting to 'latest'." >&2
    echo "      For a production-track build, pass UPSTREAM_TAG=<x.y.z> explicitly." >&2
    UPSTREAM_TAG="latest"
  else
    echo "==> Auto-discovered UPSTREAM_TAG=$UPSTREAM_TAG (from $COMPOSE_FILE)"
  fi
fi

# ── 2. Auto-discover SKIN_REV from GHCR ─────────────────────────
# Hit the registry's tag-list endpoint with a bearer token minted
# from CR_PAT.  Find the highest existing <UPSTREAM_TAG>-d<N>.  Next
# build is N+1.  Falls back to 1 if no prior build exists.  Env-set
# SKIN_REV always wins.
discover_next_skin_rev() {
  local upstream="$1"
  local user="${GHCR_USER:-}"
  local pat="${CR_PAT:-${GHCR_PAT:-}}"

  if [[ -z "$user" || -z "$pat" ]]; then
    echo "warn: GHCR_USER / CR_PAT not set — can't auto-discover SKIN_REV." >&2
    echo "      Pass SKIN_REV explicitly, or run via Doppler:" >&2
    echo "        doppler run -p hosted -c prd -- $0" >&2
    echo "1"
    return 0
  fi

  # GHCR requires a bearer token even for private package reads.
  # Mint one scoped to read this specific repo.
  local token
  token=$(curl -sS --max-time 10 -u "${user}:${pat}" \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:dartastic/${IMAGE}:pull" \
    2>/dev/null | jq -r '.token // empty')

  if [[ -z "$token" ]]; then
    echo "warn: GHCR token mint failed — defaulting SKIN_REV to 1." >&2
    echo "      Check CR_PAT scope (needs read:packages)." >&2
    echo "1"
    return 0
  fi

  local tags_json
  tags_json=$(curl -sS --max-time 10 \
    -H "Authorization: Bearer $token" \
    "https://ghcr.io/v2/dartastic/${IMAGE}/tags/list" \
    2>/dev/null || echo '{}')

  # Find max N in <upstream>-d<N>; emit N+1, or 1 if none exist.
  local max
  max=$(echo "$tags_json" | jq -r --arg up "$upstream" \
    '[.tags[]? | capture("^" + $up + "-d(?<n>[0-9]+)$") | .n | tonumber] | max // 0')

  if [[ -z "$max" || "$max" == "null" ]]; then
    echo "1"
  else
    echo "$((max + 1))"
  fi
}

if [[ -z "${SKIN_REV:-}" ]]; then
  SKIN_REV=$(discover_next_skin_rev "$UPSTREAM_TAG")
  echo "==> Auto-discovered SKIN_REV=$SKIN_REV (next after newest ${UPSTREAM_TAG}-d<N> on GHCR)"
fi

TAG="${UPSTREAM_TAG}-d${SKIN_REV}"
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

# ── 3. Auto-bump the compose pin ────────────────────────────────
# So the operator doesn't have to remember "now edit the compose
# file" as a separate step.  Only runs after a successful push
# (no point pinning a tag that isn't in the registry yet).
COMPOSE_BUMPED=0
if [[ "${PUSH}" == "1" && "${NO_COMPOSE_BUMP}" != "1" && -f "$COMPOSE_FILE" ]]; then
  current_in_compose=$(grep -oE "${IMAGE}:[0-9a-zA-Z._-]+" "$COMPOSE_FILE" | head -1)
  new_pin="${IMAGE}:${TAG}"
  if [[ -n "$current_in_compose" && "$current_in_compose" != "$new_pin" ]]; then
    # In-place edit; sed -i syntax differs between GNU and BSD/macOS.
    # Use a temp file to stay portable.
    tmp=$(mktemp)
    sed "s|${current_in_compose}|${new_pin}|" "$COMPOSE_FILE" > "$tmp"
    mv "$tmp" "$COMPOSE_FILE"
    echo "==> Bumped compose pin: $current_in_compose → $new_pin"
    echo "    (in $COMPOSE_FILE)"
    COMPOSE_BUMPED=1
  elif [[ "$current_in_compose" == "$new_pin" ]]; then
    echo "==> Compose pin already on $new_pin — no edit needed."
  fi
fi

# ── 4. Tell the operator what to do next ────────────────────────
# Absolute paths instead of `realpath --relative-to` — the latter
# is GNU coreutils only; BSD realpath on macOS silently falls back
# to `.` and the operator gets useless `cd .` instructions.  Use
# the cd-style absolute paths, which work everywhere.
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VULTR_DIR="$REPO_DIR/vultr"

# If the compose was actually bumped, surface the review/commit
# block.  Otherwise skip it — there's nothing to commit.
if [[ "$COMPOSE_BUMPED" == "1" ]]; then
  cat <<EOF

────────────────────────────────────────────────────────────────
Built + pushed ${FULL}.

Compose pin bumped — review + commit:
    cd $REPO_DIR
    git diff vultr/docker-compose.lgtm.yml
    git add vultr/docker-compose.lgtm.yml && git commit -m "lgtm: bump skin to ${TAG}"

Deploy to the box(es), runs from your laptop, no manual SSH:
    cd $VULTR_DIR

    # One box (dogfood / dev):
    ./up-lgtm.sh

    # Every customer box (hosted-* labels in Vultr) + optionally
    # the dogfood box:
    ./roll-skin-fleet.sh --include-dogfood
────────────────────────────────────────────────────────────────
EOF
else
  cat <<EOF

────────────────────────────────────────────────────────────────
Built + pushed ${FULL}.
Compose already on this tag — nothing to commit.

If you want to deploy anyway (refresh the running container):
    cd $VULTR_DIR

    # One box (dogfood / dev):
    ./up-lgtm.sh

    # Every customer box + optionally the dogfood box:
    ./roll-skin-fleet.sh --include-dogfood
────────────────────────────────────────────────────────────────
EOF
fi
