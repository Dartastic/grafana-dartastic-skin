#!/bin/sh
# grafana-skinned entrypoint: write the AGPL §13 source location the footer
# links to (DARTASTIC_SOURCE_URL, required), then hand off to Grafana's own
# /run.sh. The file goes to /tmp, which is writable even with a read-only
# root filesystem; public/js/dartastic-source.js is a symlink to it.
set -eu
/usr/local/bin/write-source-url.sh /tmp/dartastic/source.js

# The Dartastic AI plugin this image carries (D23), copied into Grafana's
# plugins directory at every start so the image's version wins. A copy
# someone else installed (Self-Hosted's initContainer) has no marker and is
# left alone. Never stops Grafana: a failed copy is logged.
AI_PLUGIN_SRC=/usr/share/dartastic/plugins/dartastic-ai-panel
AI_PLUGIN_DST="${GF_PATHS_PLUGINS:-/var/lib/grafana/plugins}/dartastic-ai-panel"
if [ -d "$AI_PLUGIN_SRC" ]; then
  if [ ! -e "$AI_PLUGIN_DST" ] || [ -e "$AI_PLUGIN_DST/.dartastic-bundled" ]; then
    { rm -rf "$AI_PLUGIN_DST" \
      && mkdir -p "$AI_PLUGIN_DST" \
      && cp -R "$AI_PLUGIN_SRC/." "$AI_PLUGIN_DST/" \
      && touch "$AI_PLUGIN_DST/.dartastic-bundled"; } \
      || echo "[grafana-entrypoint] WARNING: could not install the AI plugin in $AI_PLUGIN_DST" >&2
  else
    echo "[grafana-entrypoint] AI plugin in $AI_PLUGIN_DST was installed by someone else; left as it is"
  fi
fi
exec /run.sh "$@"
