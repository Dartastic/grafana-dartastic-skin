#!/usr/bin/env bash
# hosted#194 — outbound-email fixture check: re-verify the SHIPPED alert
# email templates in the built image carry no upstream mark.
#
# The skin Dockerfile already asserts this at BUILD time (fail-loud seds);
# this re-checks the artifact that actually ships — a Dockerfile refactor
# that drops the assertion, or a base-image layer that reintroduces the
# templates, gets caught here.
#
# Usage: ./check-emails.sh <image>
# Allowed /grafana/i occurrences come from allowlist.json's
# email_template_entries (Go-template SOURCE tokens that never render):
#   - the `eq .Name "grafana_folder"` display-rename conditional
#   - the `{{ .GroupLabels.grafana_folder }}` label-VALUE access
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${1:?usage: check-emails.sh <image>}"

TMP="$(mktemp -d)"
CID=""
cleanup() {
  [[ -n "$CID" ]] && docker rm "$CID" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> [emails] extracting ng_alert_notification.{html,txt} from ${IMAGE}"
CID="$(docker create "$IMAGE")"
docker cp "${CID}:/otel-lgtm/grafana/public/emails/ng_alert_notification.html" "$TMP/" >/dev/null
docker cp "${CID}:/otel-lgtm/grafana/public/emails/ng_alert_notification.txt" "$TMP/" >/dev/null

# Pull the allowed template-source patterns out of allowlist.json so the
# email allowlist lives in the same PR-reviewed file as the DOM one.
# (while-read, not mapfile — macOS ships bash 3.2 for local runs.)
ALLOWED=()
while IFS= read -r pat; do
  ALLOWED+=("$pat")
done < <(jq -r '.email_template_entries[].pattern' "$HERE/allowlist.json")

fail=0
for f in ng_alert_notification.html ng_alert_notification.txt; do
  # Strip every allowed pattern, then anything /grafana/i left is a leak.
  scrubbed="$TMP/$f.scrubbed"
  cp "$TMP/$f" "$scrubbed"
  for pat in "${ALLOWED[@]}"; do
    perl -pi -e "s/${pat}//g" "$scrubbed"
  done
  if grep -niE 'grafana' "$scrubbed" >/dev/null; then
    echo "FAIL [emails] upstream mark in shipped $f (outside allowlist):" >&2
    grep -niE 'grafana' "$scrubbed" | head -20 >&2
    fail=1
  else
    echo "  ok: $f carries no upstream mark outside the allowlist"
  fi
done
exit $fail
