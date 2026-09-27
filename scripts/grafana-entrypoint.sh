#!/bin/sh
# grafana-skinned entrypoint: write the AGPL §13 source location the footer
# links to (DARTASTIC_SOURCE_URL, required), then hand off to Grafana's own
# /run.sh. The file goes to /tmp, which is writable even with a read-only
# root filesystem; public/js/dartastic-source.js is a symlink to it.
set -eu
/usr/local/bin/write-source-url.sh /tmp/dartastic/source.js
exec /run.sh "$@"
