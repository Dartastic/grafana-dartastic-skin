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
# deploy. AI is off unless that file carries AI_PROVIDER_KEY.

set -eu

LOG_DIR=/var/log/dartastic
mkdir -p "$LOG_DIR"

# ── AI gateway credentials: files, never environment ─────────────────
# The gateway reads its bearer token and the provider key from files it
# re-reads on every use. The token is minted here at every start: only
# Grafana (via plugin provisioning, $AI_GATEWAY_TOKEN) and the gateway
# (via the file) ever hold it, and the metrics scrape reads the file.
AI_RUN_DIR=/run/ai-gateway
mkdir -p "$AI_RUN_DIR"
chmod 0700 "$AI_RUN_DIR"
umask 077
head -c 48 /dev/urandom | base64 | tr -d '+/=\n' | head -c 48 > "$AI_RUN_DIR/token"
AI_GATEWAY_TOKEN="$(cat "$AI_RUN_DIR/token")"
export AI_GATEWAY_TOKEN

if [[ -n "${AI_PROVIDER_KEY:-}" ]]; then
  printf '%s' "$AI_PROVIDER_KEY" > "$AI_RUN_DIR/provider-key"
  unset AI_PROVIDER_KEY
  echo "[dartastic-entrypoint] starting ai_gateway (logs: $LOG_DIR/ai_gateway.log)"
  # Loopback only: Grafana's plugin proxy, in this container, is the one
  # caller. Grafana's signing keys are read from the same loopback.
  env AI_GATEWAY_LISTEN=127.0.0.1:8091 \
      AI_GATEWAY_TOKEN_FILE="$AI_RUN_DIR/token" \
      AI_KEY_SOURCE=file \
      AI_PROVIDER_KEY_FILE="$AI_RUN_DIR/provider-key" \
      AI_GATEWAY_GRAFANA_URL=http://127.0.0.1:3000 \
      /usr/local/bin/ai_gateway >>"$LOG_DIR/ai_gateway.log" 2>&1 &
  # A refused configuration exits 64 with one line naming the variable;
  # it lands in ai_gateway.log and Grafana keeps serving.
else
  echo "[dartastic-entrypoint] AI gateway off: no AI_PROVIDER_KEY in /etc/dartastic/ai-gateway.env"
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
