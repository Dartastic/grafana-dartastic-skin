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
# health check.  Persistent disk at /var/lib/dartastic-ai/ holds
# per-customer rate-limiter state so AI restarts don't wipe usage
# history (addresses the "but I want to tune AI separately" concern
# from #85 P1 review).
#
# Secret-management modes (auto-detected):
#
#   - **Doppler-on-box mode** (#14): if /etc/doppler/token exists +
#     the `doppler` CLI is installed, wrap both child processes in
#     `doppler run` so their env comes from the per-customer Doppler
#     config at process start.  This is the productionised flow.
#
#   - **env_file fallback**: if Doppler isn't set up on the box,
#     read secrets straight from /etc/dartastic/ai-gateway.env
#     (via the compose env_file directive).  Stopgap for the
#     dogfood demo + emergency overrides via set-ai-gateway-env.sh.
#
# AI is OFF BY DEFAULT.  Boxes without the Shared AI / Private AI
# add-on never start the gateway because the env preconditions are
# never met.

set -eu

LOG_DIR=/var/log/dartastic
mkdir -p "$LOG_DIR"

# ── Detect Doppler-on-box mode (#14) ────────────────────────────
# Provisioner drops the per-customer Doppler service token at
# /etc/doppler/token (mode 0600, root-owned).  If it's there + the
# doppler CLI is present + Doppler responds to a smoke call, run
# every child under `doppler run`.
DOPPLER_TOKEN_FILE=/etc/doppler/token
USE_DOPPLER=false
if [[ -f "$DOPPLER_TOKEN_FILE" ]] && command -v doppler >/dev/null 2>&1; then
  DOPPLER_TOKEN="$(cat "$DOPPLER_TOKEN_FILE")"
  export DOPPLER_TOKEN
  # Smoke: ask Doppler to expand its env once.  If the token is
  # invalid or revoked, doppler exits non-zero — we fall back to
  # env_file mode rather than fail the container.  Operator sees
  # the warning in the container log.
  if doppler secrets --silent >/dev/null 2>&1; then
    USE_DOPPLER=true
    echo "[dartastic-entrypoint] Doppler-on-box mode: token at $DOPPLER_TOKEN_FILE"
  else
    echo "[dartastic-entrypoint] WARN: $DOPPLER_TOKEN_FILE present but Doppler" \
         "rejected the token — falling back to env_file mode." >&2
    unset DOPPLER_TOKEN
  fi
else
  echo "[dartastic-entrypoint] env_file mode (no Doppler token at $DOPPLER_TOKEN_FILE)"
fi

# When Doppler-on-box is active, pull the gateway-relevant env vars
# in now so the precondition check below can read them.  In
# env_file mode the compose env_file directive populated them
# already; this no-ops.
if [[ "$USE_DOPPLER" == "true" ]]; then
  eval "$(doppler secrets download --no-file --format env-no-quotes 2>/dev/null \
    | grep -E '^(ANTHROPIC_API_KEY|OPENAI_API_KEY|AI_GATEWAY_)' \
    | sed 's|^|export |')" || true
fi

# ── AI gateway: opt-in via env ──────────────────────────────────
# Preconditions:
#   1. A PROVIDER KEY must be set — ANTHROPIC_API_KEY or OPENAI_API_KEY.
#      The key is the CUSTOMER's: Hosted and Self-Hosted customers add
#      their own and turn AI on themselves (Michael, 2026-09-17), so an
#      unconfigured box simply never starts the gateway, which is the
#      off state and costs nothing.
#   2. EITHER at least one AI_GATEWAY_CUSTOMER_<ID>_SECRET is set
#      (HMAC-authenticated external callers — Shared AI tier),
#      OR AI_GATEWAY_TRUST_LOCALHOST=true (Private AI on Box +
#      Compliance + dogfood — Grafana panel calling over the
#      container's internal loopback, no HMAC needed).
#
# Which vendor gets called, which model, and what it costs are the
# gateway's own decisions (AI_GATEWAY_PROVIDER, AI_GATEWAY_MODEL,
# AI_GATEWAY_PRICE_*_PER_MTOK); it exits 64 with a stated reason rather
# than guessing any of them, and that reason lands in ai_gateway.log.
HAS_CUSTOMER_SECRET=$(env | grep -c '^AI_GATEWAY_CUSTOMER_.*_SECRET=' || true)
TRUST_LOCALHOST="${AI_GATEWAY_TRUST_LOCALHOST:-false}"
if { [[ -n "${ANTHROPIC_API_KEY:-}" ]] || [[ -n "${OPENAI_API_KEY:-}" ]]; } \
   && { [[ "$HAS_CUSTOMER_SECRET" -gt 0 ]] || [[ "$TRUST_LOCALHOST" == "true" ]]; }; then
  echo "[dartastic-entrypoint] starting ai_gateway in background"
  echo "[dartastic-entrypoint]   logs: $LOG_DIR/ai_gateway.log"
  if [[ "$USE_DOPPLER" == "true" ]]; then
    # Run the gateway under doppler so its env (including future
    # rotated values) is refreshed at process start.
    doppler run --silent -- /usr/local/bin/ai_gateway \
      >>"$LOG_DIR/ai_gateway.log" 2>&1 &
  else
    /usr/local/bin/ai_gateway >>"$LOG_DIR/ai_gateway.log" 2>&1 &
  fi
  AI_PID=$!
  echo "[dartastic-entrypoint]   pid:  $AI_PID"

  # Surface AI-gateway exits to the container log.
  (
    wait "$AI_PID"
    rc=$?
    echo "[dartastic-entrypoint] ai_gateway exited with code $rc — AI route now 502" >&2
  ) &
else
  echo "[dartastic-entrypoint] AI gateway off:" \
       "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:+set}${ANTHROPIC_API_KEY:-unset}," \
       "customer-secrets=$HAS_CUSTOMER_SECRET," \
       "trust-localhost=$TRUST_LOCALHOST"
fi

# ── Hand off to LGTM ────────────────────────────────────────────
# Upstream grafana/otel-lgtm uses `CMD ["/otel-lgtm/run-all.sh"]`
# (verified at the upstream image tag we pin).  If we get an
# explicit command from docker run we honor it; otherwise we fall
# back to the upstream default.
LGTM_CMD=( /otel-lgtm/run-all.sh )
if [[ $# -gt 0 ]]; then
  LGTM_CMD=( "$@" )
fi

if [[ "$USE_DOPPLER" == "true" ]]; then
  exec doppler run --silent -- "${LGTM_CMD[@]}"
fi
exec "${LGTM_CMD[@]}"
