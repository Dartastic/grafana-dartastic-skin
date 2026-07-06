#!/usr/bin/env bash
# hosted#194 — notification-sanitizer end-to-end fixture check.
#
# Boots the sanitizer image, points its forward target at a local mock
# receiver (stands in for hooks.slack.com; the env-held destination is
# trusted, so a non-Slack URL is accepted), POSTs the recorded Grafana
# Slack payload fixture through /slack, and FAILS if any /grafana/i
# survives in what the mock received. Verifies the egress path a customer's
# Slack channel actually sees — not just the Dart unit tests.
#
# Usage: ./check-sanitizer.sh [sanitizer-image]
# Env:   MOCK_PORT (default 18099), SANITIZER_PORT (default 18092)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${1:-ghcr.io/dartastic-io/notification-sanitizer:latest}"
MOCK_PORT="${MOCK_PORT:-18099}"
SANITIZER_PORT="${SANITIZER_PORT:-18092}"
CONTAINER="brand-scan-sanitizer"

TMP="$(mktemp -d)"
MOCK_PID=""
cleanup() {
  [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" >/dev/null 2>&1 || true
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> [sanitizer] mock receiver on :${MOCK_PORT}"
node "$HERE/mock-receiver.mjs" "$MOCK_PORT" "$TMP/forwarded.jsonl" &
MOCK_PID=$!

echo "==> [sanitizer] starting ${IMAGE} on :${SANITIZER_PORT}"
# host.docker.internal: built into Docker Desktop; host-gateway alias makes
# it work on the Linux CI runner too. The sanitizer image is amd64-only —
# pin the platform so an arm64 host (mac local run) uses emulation instead
# of erroring.
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" \
  --platform linux/amd64 \
  --add-host=host.docker.internal:host-gateway \
  -p "${SANITIZER_PORT}:8092" \
  -e "SANITIZER_SLACK_WEBHOOK_URL=http://host.docker.internal:${MOCK_PORT}/hook" \
  "$IMAGE" >/dev/null

echo -n "==> [sanitizer] waiting for /health"
for _ in $(seq 1 30); do
  if curl -fsS -m 2 "http://127.0.0.1:${SANITIZER_PORT}/health" >/dev/null 2>&1; then
    echo " ok"
    break
  fi
  echo -n "."
  sleep 2
done
curl -fsS -m 2 "http://127.0.0.1:${SANITIZER_PORT}/health" >/dev/null \
  || { echo "FAIL [sanitizer] never became healthy"; docker logs "$CONTAINER" | tail -20; exit 1; }

echo "==> [sanitizer] POSTing the recorded Grafana Slack fixture through /slack"
code="$(curl -sS -o "$TMP/resp.txt" -w '%{http_code}' \
  -H 'content-type: application/json' \
  --data @"$HERE/fixtures/slack-payload.json" \
  "http://127.0.0.1:${SANITIZER_PORT}/slack")"
[[ "$code" == "200" ]] || { echo "FAIL [sanitizer] POST /slack -> HTTP $code ($(cat "$TMP/resp.txt"))"; exit 1; }

[[ -s "$TMP/forwarded.jsonl" ]] \
  || { echo "FAIL [sanitizer] mock receiver got no forwarded payload"; exit 1; }

lines="$(wc -l < "$TMP/forwarded.jsonl" | tr -d ' ')"
[[ "$lines" == "1" ]] || echo "WARN [sanitizer] expected exactly 1 forwarded request, got $lines"

if grep -iq 'grafana' "$TMP/forwarded.jsonl"; then
  echo "FAIL [sanitizer] upstream mark survived in the FORWARDED payload:" >&2
  grep -ioE '.{40}grafana.{40}' "$TMP/forwarded.jsonl" | head -10 >&2
  exit 1
fi
# Positive control: the de-brand actually ran (footer rewritten), so an
# accidentally-empty forward can't pass as "no grafana".
grep -q '"footer":"Dartastic"' "$TMP/forwarded.jsonl" \
  || { echo "FAIL [sanitizer] forwarded payload missing the Dartastic footer rewrite — did the rules run?"; exit 1; }

echo "  ok: forwarded payload is mark-free (footer rewritten, grafana_folder renamed, URLs de-branded)"
