#!/usr/bin/env python3
"""rewrite-locale.py — bulk-rename "Grafana" to "Dartastic" in a
Grafana i18n catalog JSON.

Called from `build-and-push.sh`. Reads the upstream
`locales/en-US/grafana.json` (extracted from the upstream image into
`build/upstream-en-US.json`) and writes a rewritten version to
`build/skin-en-US.json` which the Dockerfile then COPYs over the
in-image catalog at:

  /otel-lgtm/grafana/public/locales/en-US/grafana.json

We can't run this inside the Dockerfile because the
`grafana/otel-lgtm` base image is RHEL-minimal — no python, jq, or
even awk — so we do the work on the host where Python's available.

Rules:
  - Replace whole-word "Grafana" with "Dartastic" inside string values.
  - PRESERVE these tokens unchanged anywhere they appear:
      "Grafana Labs"      (trademark attribution — legal requirement)
      "grafana.com"       (URL — points at upstream docs/marketing)
      "github.com/grafana" (URL)
  - Don't touch keys (only string values).
  - Don't touch booleans, numbers, null, or arrays of non-strings.
"""

import json
import re
import sys
from pathlib import Path

if len(sys.argv) != 3:
    print("usage: rewrite-locale.py <input.json> <output.json>", file=sys.stderr)
    sys.exit(64)

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
data = json.loads(src.read_text(encoding="utf-8"))

# Tokens we leave intact. Order matters — sub the placeholders in
# first (preserving Grafana Labs etc.), do the bulk replace, then sub
# the placeholders back. We use unicode private-use chars as
# placeholders so they can't collide with anything real in the
# translation strings.
KEEP = {
    "Grafana Labs": "",
    "grafana.com": "",
    "github.com/grafana": "",
}

WORD = re.compile(r"\bGrafana\b")

def rewrite(s: str) -> str:
    out = s
    for needle, placeholder in KEEP.items():
        out = out.replace(needle, placeholder)
    out = WORD.sub("Dartastic", out)
    for needle, placeholder in KEEP.items():
        out = out.replace(placeholder, needle)
    return out

def walk(o):
    if isinstance(o, dict):
        return {k: walk(v) for k, v in o.items()}
    if isinstance(o, list):
        return [walk(v) for v in o]
    if isinstance(o, str):
        return rewrite(o)
    return o

rewritten = walk(data)
dst.write_text(json.dumps(rewritten, ensure_ascii=False, indent=2), encoding="utf-8")

# Audit + report.
original_count = len(WORD.findall(src.read_text(encoding="utf-8")))
remaining_count = len(WORD.findall(dst.read_text(encoding="utf-8")))
print(f"rewrote {original_count - remaining_count} occurrences of 'Grafana' → 'Dartastic'")
print(f"preserved {remaining_count} (Grafana Labs / grafana.com / github.com/grafana)")
