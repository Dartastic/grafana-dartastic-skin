#!/usr/bin/env bash
# Refuse a skin mirror that contains commercial source by SHAPE, whether or
# not a file carries the license header (mirror-skin.sh's header check
# catches the labeled ones). The public skin repository is AGPL source for
# the Grafana modifications: shell, config, CSS, JavaScript and images. It
# never holds the AI gateway, the AI panel plugin, the shared Ask element
# or any Dart package; those are commercial and built elsewhere.
#
#   check-mirror-has-no-commercial-source.sh <mirror dir>
#
# Exit 1 listing every offending path; exit 0 when clean.
set -euo pipefail

DIR="${1:?usage: check-mirror-has-no-commercial-source.sh <mirror dir>}"
[[ -d "$DIR" ]] || { echo "not a directory: $DIR" >&2; exit 2; }

offending="$(cd "$DIR" && find . -path ./.git -prune -o -type f \( \
    -name '*.dart' -o -name '*.ts' -o -name '*.tsx' \
    -o -name 'plugin.json' -o -name 'pubspec.yaml' -o -name 'pubspec.lock' \
  \) -print -o -type d \( \
    -path ./build/ai-gateway -o -path ./build/ai-plugin -o -path ./build/packages \
  \) -print | sed 's#^\./##' | sort)"

if [[ -n "$offending" ]]; then
  echo "refusing to mirror: commercial source (Dart, TypeScript, a plugin or a staged build) in the public skin:" >&2
  echo "$offending" >&2
  exit 1
fi
echo "no commercial source in the mirror"
