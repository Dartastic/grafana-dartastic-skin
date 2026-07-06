#!/usr/bin/env bash
# hosted#194 — enforcement flip for the expected-fail (xfail) list.
#
# Every expected-fail.json entry references an OPEN issue. When that issue
# closes, the leak is supposedly fixed — so the entry must be DELETED (the
# fixing PR's paper trail) and the check becomes enforcing. This script
# fails the build if any referenced issue is CLOSED while its entry is
# still present.
#
# Needs `gh` + auth (GH_TOKEN is set in CI). Locally without gh/auth it
# warns and exits 0 — freshness is a CI property.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${BRAND_SCAN_REPO:-dartastic-io/hosted}"

if ! command -v gh >/dev/null 2>&1; then
  echo "WARN [xfail-freshness] gh not installed — skipping (CI enforces this)"
  exit 0
fi

fail=0
for issue in $(jq -r '[.entries[].issue] | unique | .[]' "$HERE/expected-fail.json"); do
  state="$(gh issue view "$issue" --repo "$REPO" --json state -q .state 2>/dev/null || echo UNKNOWN)"
  case "$state" in
    OPEN)
      echo "  ok: expected-fail issue #${issue} is still open" ;;
    CLOSED)
      echo "FAIL [xfail-freshness] issue #${issue} is CLOSED but expected-fail.json still carries entries for it." >&2
      echo "     Remove those entries (ids: $(jq -r --argjson n "$issue" '[.entries[] | select(.issue == $n) | .id] | join(", ")' "$HERE/expected-fail.json")) — the gate is now enforcing for them." >&2
      fail=1 ;;
    *)
      echo "WARN [xfail-freshness] could not read state of issue #${issue} (gh unauthenticated?) — skipping" ;;
  esac
done
exit $fail
