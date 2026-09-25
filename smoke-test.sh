#!/usr/bin/env bash
# Local smoke test for the Dartastic Hosted skin.
#
# Spins up the most recently built skinned image on :13000, asserts
# the brand replacements landed (title, CSS link, custom assets
# served), and tears down. Run after every ./build-and-push.sh PUSH=0.
#
# Usage:
#   ./smoke-test.sh                                         # uses :latest
#   IMAGE=ghcr.io/dartastic-io/lgtm-skinned:0.7.4-d1 ./smoke-test.sh
#
# Exits non-zero on any failure — wire into CI later.

set -euo pipefail
: "${IMAGE:=ghcr.io/dartastic-io/lgtm-skinned:latest}"
: "${PORT:=13000}"
: "${CONTAINER:=dartastic-skin-smoketest}"

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Starting ${IMAGE} on :${PORT}"
# ADMIN_ALERT_EMAIL: the default contact point interpolates it, and
# Grafana refuses to start without an address. Boxes set it from Doppler.
docker run --rm -d --name "$CONTAINER" -p "${PORT}:3000" \
  -e ADMIN_ALERT_EMAIL=smoke-test@example.invalid "$IMAGE" >/dev/null

echo -n "==> Waiting for Grafana to come up"
# Grafana downloads its preinstalled plugins before it listens, so allow
# several minutes, and stop here if it never comes up.
up=0
for _ in $(seq 1 150); do
  if curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
    echo " ok"
    up=1
    break
  fi
  echo -n "."
  sleep 2
done
if [[ "$up" != 1 ]]; then
  echo " Grafana never came up; last container log lines:" >&2
  docker logs "$CONTAINER" 2>&1 | tail -20 >&2
  exit 1
fi

fail() { echo "  FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

echo "==> Verifying brand patches"

# Buffer the login HTML once. (Piping curl directly to grep -q
# closes the pipe early — grep exits on first match, curl whines
# with exit 23 "failed writing output". Save to a tmpfile instead.)
LOGIN_HTML="$(mktemp)"
trap 'rm -f "$LOGIN_HTML"; cleanup' EXIT
curl -fsS "http://127.0.0.1:${PORT}/login" -o "$LOGIN_HTML"

# 1. Browser tab title
grep -q "<title>Dartastic Hosted</title>" "$LOGIN_HTML" \
  || fail "browser tab title not patched"
pass "<title>Dartastic Hosted</title>"

# 2. Our CSS injected
grep -q "dartastic-skin.css" "$LOGIN_HTML" \
  || fail "dartastic-skin.css link not injected"
pass "dartastic-skin.css link present"

# 2b. Our JS injected (text-rewriter for "Grafana" → "Dartastic Hosted")
grep -q "dartastic-skin.js" "$LOGIN_HTML" \
  || fail "dartastic-skin.js script not injected"
pass "dartastic-skin.js script present"

# 3. The upstream Grafana title is NOT in the rendered HTML
if grep -q "<title>Grafana</title>" "$LOGIN_HTML"; then
  fail "<title>Grafana</title> still present — title patch missed"
fi
pass "no <title>Grafana</title>"

# 4. Custom assets serve 200
for asset in \
    public/css/dartastic-skin.css \
    public/img/grafana_icon.svg \
    public/img/grafana_typelogo.svg \
    public/img/fav32.png \
    public/img/apple-touch-icon.png \
    public/img/g8_login_dark.svg \
    public/img/g8_login_light.svg; do
  code="$(curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/${asset}")"
  [[ "$code" == "200" ]] || fail "${asset} returned ${code}"
  pass "${asset} → 200"
done

# 5. The icon SVG at /public/img/ is OUR file.
ICON_SVG="$(mktemp)"
curl -fsS "http://127.0.0.1:${PORT}/public/img/grafana_icon.svg" -o "$ICON_SVG"
grep -q "Dartastic" "$ICON_SVG" \
  || fail "grafana_icon.svg (public/img) is not the Dartastic override"
pass "public/img/grafana_icon.svg served from skin"
rm -f "$ICON_SVG"

# 5b. The build/img assets are what Grafana 13's index.html ACTUALLY references
# (favicon, apple-touch-icon, AND the page-load preloader spinner). The
# favicon/spinner regression lived exactly here: public/img/ was overridden but
# the HTML pointed at public/build/img/, so the upstream flame leaked through.
# Byte-match each against the skin source so a future upstream path move fails
# loud instead of silently shipping Grafana branding.
SKIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in fav32.png apple-touch-icon.png grafana_icon.svg; do
  served="$(mktemp)"
  curl -fsS "http://127.0.0.1:${PORT}/public/build/img/${f}" -o "$served" \
    || fail "public/build/img/${f} did not serve"
  cmp -s "$served" "${SKIN_DIR}/img/${f}" \
    || { rm -f "$served"; fail "public/build/img/${f} is NOT the skin asset (upstream moved the path? see skin/Dockerfile build/img COPYs)"; }
  rm -f "$served"
  pass "public/build/img/${f} byte-matches skin/img/${f}"
done

# 6. The runtime text-rewriter JS file is served.
JS="$(mktemp)"
curl -fsS "http://127.0.0.1:${PORT}/public/js/dartastic-skin.js" -o "$JS"
grep -q "Dartastic Hosted" "$JS" \
  || fail "dartastic-skin.js is missing or not the skin's copy"
pass "public/js/dartastic-skin.js served from skin"
rm -f "$JS"

# 7. The home dashboard has been replaced — no "Welcome to Grafana"
# survives in /api/dashboards/home.  This is the surface that
# previously rendered the upstream welcome panel with the
# Welcome-to-Grafana h1; without this assertion a regression in the
# COPY step in the Dockerfile would silently let upstream's home.json
# come back through.
HOME_JSON="$(mktemp)"
# /api/dashboards/home requires auth; log in as admin/admin to get a
# session cookie (Grafana ships with admin/admin defaults, smoke
# container is fresh so the credential works).
COOKIE_JAR="$(mktemp)"
curl -fsS -c "$COOKIE_JAR" -H "Content-Type: application/json" \
  -d '{"user":"admin","password":"admin"}' \
  "http://127.0.0.1:${PORT}/login" >/dev/null
curl -fsS -b "$COOKIE_JAR" "http://127.0.0.1:${PORT}/api/dashboards/home" -o "$HOME_JSON"
if grep -q "Welcome to Grafana" "$HOME_JSON"; then
  fail "home dashboard JSON still contains \"Welcome to Grafana\""
fi
pass "no \"Welcome to Grafana\" in /api/dashboards/home"
grep -q "Dartastic Hosted" "$HOME_JSON" \
  || fail "home dashboard doesn't contain the Dartastic content"
pass "home dashboard carries Dartastic content"
rm -f "$HOME_JSON" "$COOKIE_JAR"

# 8. The webpack-hashed copy under public/build/static/img/ is ALSO
# overridden — this is the path the React app actually fetches for
# the visible login page logo. The hash varies per upstream version;
# look up the current hashed filename via the build manifest then
# fetch it.
BUILT_LOGO_NAME="$(docker exec dartastic-skin-smoketest sh -c '
  ls /otel-lgtm/grafana/public/build/static/img/grafana_icon.*.svg 2>/dev/null | head -1 | xargs basename
' 2>/dev/null)"
if [[ -n "$BUILT_LOGO_NAME" ]]; then
  BUILT_LOGO="$(mktemp)"
  curl -fsS "http://127.0.0.1:${PORT}/public/build/static/img/${BUILT_LOGO_NAME}" -o "$BUILT_LOGO"
  grep -q "Dartastic" "$BUILT_LOGO" \
    || fail "build/static/img/${BUILT_LOGO_NAME} is not the Dartastic override"
  pass "build/static/img/${BUILT_LOGO_NAME} served from skin"
  rm -f "$BUILT_LOGO"
else
  fail "no grafana_icon.*.svg in build/static/img — upstream renamed?"
fi

# 9. The Dartastic AI plugin is REGISTERED, not just copied: Grafana
# serves a plugin's module.js only once it has loaded the plugin.
# (Until 2026-09-25 the image copied it to a directory this Grafana never
# reads, and nothing noticed.)
for plugin_id in dartastic-ai-panel dartastic-ai-panel-panel; do
  code="$(curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/public/plugins/${plugin_id}/module.js")"
  [[ "$code" == "200" ]] || fail "plugin ${plugin_id} not registered (module.js HTTP ${code})"
  pass "plugin ${plugin_id} registered"
done

echo "==> All assertions passed"
