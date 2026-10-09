#!/bin/bash
# Dartastic-skinned LGTM container entrypoint.
#
# Two-process container: this wrapper backgrounds the AI gateway
# (when configured) and execs the upstream LGTM run script as PID
# 1's foreground.  If LGTM dies the container exits and Docker
# restarts it; if the AI gateway dies the container keeps serving
# Grafana but the AI route returns 502 until the container cycles.
#
# Why two processes in one container instead of two containers:
# operational simplicity for customers — one image, one bump, one
# health check.  The gateway keeps its daily spend in
# /var/lib/ai-gateway (a volume), so a restart cannot reset the cap.
#
# The gateway runs the contract in byoc doc/AI_GATEWAY_SELF_HOSTED.md
# (the same one as Self-Hosted), fed from /etc/dartastic/ai-gateway.env,
# which hosted-deploy.sh rewrites from the box's Doppler config on every
# deploy. AI is off unless that file names AI_PROVIDER.

set -eu

LOG_DIR=/var/log/dartastic
mkdir -p "$LOG_DIR"

# The AGPL §13 source location the footer links to (DARTASTIC_SOURCE_URL,
# required): the container stops here without it.
/usr/local/bin/write-source-url.sh /otel-lgtm/grafana/public/js/dartastic-source.js

# ── AI gateway credentials: files, never environment ─────────────────
# The gateway reads its bearer token from a file it re-reads on every use.
# It has no model key at rest: it fetches the org's own key from the control
# plane at runtime (AI_KEY_SOURCE=mint, from the env file) and keeps it in
# memory. The token is minted here at every start: only
# Grafana (via plugin provisioning, $AI_GATEWAY_TOKEN) and the gateway
# (via the file) ever hold it, and the metrics scrape reads the file.
AI_RUN_DIR=/run/ai-gateway
mkdir -p "$AI_RUN_DIR"
chmod 0700 "$AI_RUN_DIR"
umask 077
head -c 48 /dev/urandom | base64 | tr -d '+/=\n' | head -c 48 > "$AI_RUN_DIR/token"
AI_GATEWAY_TOKEN="$(cat "$AI_RUN_DIR/token")"
export AI_GATEWAY_TOKEN

if [[ -n "${AI_PROVIDER:-}" ]]; then
  # The box's sync secret, as a file the gateway re-reads on every use: it
  # pulls the signed box-state with it and mints its ai-key token with it.
  # AI_KEY_SOURCE, AI_ORG_KEY_URL, AI_SERVICE_TOKEN_URL, AI_BOX_STATE_URL,
  # AI_BOX_ID and AI_BOX_STATE_ISSUER pass through from the env file; the
  # gateway refuses to start on a partial set.
  if [[ -n "${AI_BOX_STATE_SECRET:-}" ]]; then
    printf '%s' "$AI_BOX_STATE_SECRET" > "$AI_RUN_DIR/box-state-secret"
    unset AI_BOX_STATE_SECRET
    export AI_BOX_STATE_SECRET_FILE="$AI_RUN_DIR/box-state-secret"
  fi
  echo "[dartastic-entrypoint] starting ai_gateway (logs: $LOG_DIR/ai_gateway.log)"
  # Two callers: Grafana's plugin proxy in this container (the panel), and
  # the dartastic.io Control Room's POST /v1/ask, which reaches the box's
  # nginx at https://<box>/ai/v1/ask and is proxied to the host's
  # 127.0.0.1:8091, published from here (docker-compose.dartastic.yml). So
  # the gateway listens on the container's interfaces; the host publishes it
  # on loopback only, and nginx forwards exactly /ai/v1/ask (and GET /ai/v1/questions). /v1/ask and
  # /v1/questions need a DAIQ token; every other route needs the gateway token.
  # Grafana's signing keys are read on this container's loopback, and
  # /v1/ask's tools read its Tempo, Loki and Prometheus (single-tenant: they
  # ignore X-Scope-OrgID), and its symbolize tool calls this box's
  # Symbolizer over the compose network with a read-only ai-gateway token.
  # Its source tools read the org's Pub with the org's AI service Pub token,
  # which the gateway fetches from the control plane like the model key.
  # The gateway's own telemetry goes to this box's
  # collector as service ai-gateway, which the tools leave out.
  env AI_GATEWAY_LISTEN=0.0.0.0:8091 \
      AI_GATEWAY_TOKEN_FILE="$AI_RUN_DIR/token" \
      AI_GATEWAY_GRAFANA_URL=http://127.0.0.1:3000 \
      AI_STORE_DRIVER=lgtm \
      AI_STORE_TEMPO_URL=http://127.0.0.1:3200 \
      AI_STORE_LOKI_URL=http://127.0.0.1:3100 \
      AI_STORE_PROMETHEUS_URL=http://127.0.0.1:9090 \
      AI_SYMBOLIZER_URL=http://symbolizer:8080 \
      OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 \
      OTEL_SERVICE_NAME=ai-gateway \
      /usr/local/bin/ai_gateway >>"$LOG_DIR/ai_gateway.log" 2>&1 &
  # A refused configuration exits 64 with one line naming the variable;
  # it lands in ai_gateway.log and Grafana keeps serving.
else
  echo "[dartastic-entrypoint] AI gateway off: no AI_PROVIDER in /etc/dartastic/ai-gateway.env"
fi
umask 022

# ── Install the Dartastic AI plugin where Grafana looks ─────────
# Upstream's run-grafana.sh sets GF_PATHS_PLUGINS=/data/grafana/plugins,
# on the persistent /data volume, so a plugin baked anywhere else is
# never loaded and one baked there is hidden by the volume. Copy the
# image's build in at every start so the image's version always wins.
# The Dockerfile asserts the upstream path at build time.
AI_PLUGIN_SRC=/var/lib/grafana/plugins/dartastic-ai-panel
GRAFANA_PLUGINS_DIR=/data/grafana/plugins
mkdir -p "$GRAFANA_PLUGINS_DIR"
rm -rf "$GRAFANA_PLUGINS_DIR/dartastic-ai-panel"
cp -a "$AI_PLUGIN_SRC" "$GRAFANA_PLUGINS_DIR/dartastic-ai-panel"
echo "[dartastic-entrypoint] AI plugin installed in $GRAFANA_PLUGINS_DIR"

# ── Hand off to LGTM ────────────────────────────────────────────
# Upstream grafana/otel-lgtm uses `CMD ["/otel-lgtm/run-all.sh"]`
# (verified at the upstream image tag we pin).  If we get an
# explicit command from docker run we honor it; otherwise we fall
# back to the upstream default.
LGTM_CMD=( /otel-lgtm/run-all.sh )
if [[ $# -gt 0 ]]; then
  LGTM_CMD=( "$@" )
fi

exec "${LGTM_CMD[@]}"
