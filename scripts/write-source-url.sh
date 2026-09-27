#!/bin/sh
# Writes the AGPL §13 source location the footer links to, from
# DARTASTIC_SOURCE_URL, into the JS file Grafana serves as
# public/js/dartastic-source.js. Run at every container start.
#
# Required, with no default: Hosted and Cloud point at the public mirror; an
# air-gapped Self-Hosted install points at its own copy of the source. A
# missing or malformed value stops the container (exit 64) rather than show a
# footer that links nowhere.
#
#   write-source-url.sh <target file>
set -eu
target="${1:?usage: write-source-url.sh <target file>}"
url="${DARTASTIC_SOURCE_URL:-}"
if [ -z "$url" ]; then
  echo "FATAL: DARTASTIC_SOURCE_URL is required (where users get this Grafana's source)" >&2
  exit 64
fi
# http(s), a host, an optional port and path: nothing that could break out of
# the JS string it is written into.
if ! printf '%s' "$url" | grep -Eq '^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/+-]*)?$'; then
  echo "FATAL: DARTASTIC_SOURCE_URL must be an http(s) URL of host, optional port and path" >&2
  exit 64
fi
mkdir -p "$(dirname "$target")"
printf 'window.DARTASTIC_SOURCE_URL = "%s";\n' "$url" > "$target"
