#!/usr/bin/env bash
# Local smoke test for the Dartastic Hosted skin.
#
# Spins up the most recently built skinned image on :13000, asserts
# the brand replacements landed (title, CSS link, custom assets
# served), and tears down. Run after every ./build-and-push.sh PUSH=0.
#
# Usage:
#   ./smoke-test.sh                                         # uses :latest
#   IMAGE=ghcr.io/dartastic/lgtm-skinned:0.7.4-d1 ./smoke-test.sh
#
# Exits non-zero on any failure — wire into CI later.

set -euo pipefail
: "${IMAGE:=ghcr.io/dartastic/lgtm-skinned:latest}"
: "${PORT:=13000}"
: "${CONTAINER:=dartastic-skin-smoketest}"

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Starting ${IMAGE} on :${PORT}"
docker run --rm -d --name "$CONTAINER" -p "${PORT}:3000" "$IMAGE" >/dev/null

echo -n "==> Waiting for Grafana to come up"
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
    echo " ok"
    break
  fi
  echo -n "."
  sleep 2
done

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

# 6. The webpack-hashed copy under public/build/static/img/ is ALSO
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

echo "==> All assertions passed"
