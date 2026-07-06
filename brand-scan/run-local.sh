#!/usr/bin/env bash
# hosted#194 — run the full brand-scan gate outside (or inside) CI.
#
# Modes:
#   IMAGE=ghcr.io/dartastic-io/lgtm-skinned:latest ./run-local.sh
#       Boots the image on :$PORT with the prod-like env (auth on,
#       alertingTriage toggle, ADMIN_ALERT_EMAIL), waits for Grafana,
#       runs the DOM scan + email-template check + sanitizer check,
#       tears down.
#   BASE_URL=http://127.0.0.1:13000 ./run-local.sh
#       Scans an ALREADY-RUNNING instance (no boot/teardown). Email +
#       sanitizer checks still run if IMAGE / sanitizer image are set,
#       else are skipped with a warning.
#
# Env knobs:
#   PORT              host port for the booted container (default 13000)
#   SANITIZER_IMAGE   default ghcr.io/dartastic-io/notification-sanitizer:latest
#   SKIP_EMAILS=1     skip the email-template fixture check
#   SKIP_SANITIZER=1  skip the sanitizer end-to-end check
#   SETTLE_MS, OUT_DIR, ADMIN_USER, ADMIN_PASSWORD — passed through to scan.mjs
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${IMAGE:=}"
: "${BASE_URL:=}"
: "${PORT:=13000}"
: "${SANITIZER_IMAGE:=ghcr.io/dartastic-io/notification-sanitizer:latest}"
CONTAINER="brand-scan-lgtm"

if [[ -z "$IMAGE" && -z "$BASE_URL" ]]; then
  IMAGE="ghcr.io/dartastic-io/lgtm-skinned:latest"
  echo "==> no IMAGE/BASE_URL given — defaulting to IMAGE=$IMAGE"
fi

BOOTED=0
cleanup() {
  if [[ "$BOOTED" == "1" ]]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ── deps ─────────────────────────────────────────────────────────
command -v node >/dev/null || { echo "ERROR: node required" >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 1; }
if [[ ! -d "$HERE/node_modules" ]]; then
  echo "==> npm install (playwright)"
  (cd "$HERE" && npm install --no-audit --no-fund)
fi
# Idempotent — no-op when the browser is already cached. CI passes
# --with-deps separately (system libs); locally the cache is enough.
(cd "$HERE" && npx playwright install chromium >/dev/null)

# ── boot the image (IMAGE mode) ─────────────────────────────────
if [[ -z "$BASE_URL" ]]; then
  echo "==> booting ${IMAGE} on :${PORT} (prod-like env)"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  # Mirror the fleet compose (docker-compose.dartastic.yml): auth ON (the
  # base image defaults to anonymous Admin — scanning that would miss the
  # login page), the alertingTriage toggle (registers /alerting/alerts, the
  # route outbound notifications link to), and ADMIN_ALERT_EMAIL (the
  # provisioned default contact point interpolates it; Grafana REFUSES TO
  # START without it).
  docker run -d --name "$CONTAINER" -p "${PORT}:3000" \
    -e GF_AUTH_ANONYMOUS_ENABLED=false \
    -e GF_FEATURE_TOGGLES_ENABLE=alertingTriage \
    -e ADMIN_ALERT_EMAIL=brand-scan@example.invalid \
    "$IMAGE" >/dev/null
  BOOTED=1
  BASE_URL="http://127.0.0.1:${PORT}"

  echo -n "==> waiting for Grafana at ${BASE_URL} (LGTM boot takes ~2min)"
  up=0
  for _ in $(seq 1 120); do
    if curl -fsS -m 3 "${BASE_URL}/api/health" >/dev/null 2>&1; then up=1; echo " ok"; break; fi
    echo -n "."
    sleep 3
  done
  if [[ "$up" != "1" ]]; then
    echo
    echo "FAIL: Grafana never became healthy" >&2
    docker logs "$CONTAINER" 2>&1 | tail -30 >&2
    exit 1
  fi
fi

# ── the gate ─────────────────────────────────────────────────────
rc=0

echo "==> DOM brand scan (${BASE_URL})"
BASE_URL="$BASE_URL" node "$HERE/scan.mjs" || rc=1

if [[ "${SKIP_EMAILS:-0}" != "1" ]]; then
  if [[ -n "$IMAGE" ]]; then
    "$HERE/check-emails.sh" "$IMAGE" || rc=1
  else
    echo "WARN: BASE_URL mode without IMAGE — skipping email-template check"
  fi
else
  echo "==> SKIP_EMAILS=1 — email-template check skipped"
fi

if [[ "${SKIP_SANITIZER:-0}" != "1" ]]; then
  "$HERE/check-sanitizer.sh" "$SANITIZER_IMAGE" || rc=1
else
  echo "==> SKIP_SANITIZER=1 — sanitizer check skipped"
fi

if [[ "$rc" != "0" ]]; then
  echo
  echo "BRAND-SCAN GATE FAILED (see failures above; report + screenshots in $HERE/out/)" >&2
  exit 1
fi
echo
echo "BRAND-SCAN GATE PASSED (report + screenshots in $HERE/out/)"
