# Dartastic Hosted — skinned LGTM image.
#
# Layers a Dartastic-branded UI on top of upstream grafana/otel-lgtm.
# AGPLv3 §13: this Dockerfile + the files it COPYs in constitute our
# "modifications" of Grafana. The skin/ directory is mirrored to a
# public GitHub repo and the cluster UI links to it from the footer.
#
# Build:
#   ./build-and-push.sh
#
# The pin to a specific upstream tag is intentional — reproducible
# cluster provisioning, not "latest broke us last night". Bump the tag
# on a deliberate cadence (weekly cron + smoke test).
ARG UPSTREAM_TAG=latest
FROM grafana/otel-lgtm:${UPSTREAM_TAG}

# Re-declare after FROM — Dockerfile scoping rule. Without this, the
# LABEL block at the bottom of the file sees an empty value and Docker
# emits an "UndefinedVar" warning at build time.
ARG UPSTREAM_TAG

# Grafana's install lives at /otel-lgtm/grafana/ inside the
# single-binary image. Public assets (the path Grafana serves to the
# browser) under /otel-lgtm/grafana/public/.
ARG GF_PUBLIC=/otel-lgtm/grafana/public

# --- Image assets: logos, favicons, login backgrounds ---
# Two locations get our overrides:
#
#   ${GF_PUBLIC}/img/                  - source assets Grafana serves
#                                        for some legacy paths.
#   ${GF_PUBLIC}/build/static/img/     - webpack-hashed copies that
#                                        the React app actually
#                                        references for the visible
#                                        login page logo + background.
#
# The build/static/ filenames carry content hashes (e.g.
# grafana_icon.1e0deb6b.svg) that change per Grafana release; we
# match them via a glob in a RUN step after the COPYs land in /tmp.
COPY img/grafana_icon.svg       ${GF_PUBLIC}/img/grafana_icon.svg
COPY img/grafana_typelogo.svg   ${GF_PUBLIC}/img/grafana_typelogo.svg
COPY img/fav32.png              ${GF_PUBLIC}/img/fav32.png
COPY img/apple-touch-icon.png   ${GF_PUBLIC}/img/apple-touch-icon.png
COPY img/g8_login_dark.svg      ${GF_PUBLIC}/img/g8_login_dark.svg
COPY img/g8_login_light.svg     ${GF_PUBLIC}/img/g8_login_light.svg
# Some Grafana code paths read these alternate filenames; mirror them.
COPY img/g8_login_dark.svg      ${GF_PUBLIC}/img/login_background_dark.svg
COPY img/g8_login_light.svg     ${GF_PUBLIC}/img/login_background_light.svg
COPY img/grafana_typelogo.svg   ${GF_PUBLIC}/img/grafana_text_logo-dark.svg
COPY img/grafana_typelogo.svg   ${GF_PUBLIC}/img/grafana_text_logo-light.svg
COPY img/grafana_typelogo.svg   ${GF_PUBLIC}/img/grafana_text_logo_dark.svg
COPY img/grafana_typelogo.svg   ${GF_PUBLIC}/img/grafana_text_logo_light.svg

# Stage the same files under /tmp so the next RUN can glob-overwrite
# the webpack-hashed copies in build/static/img/.
COPY img/grafana_icon.svg       /tmp/skin/grafana_icon.svg
COPY img/g8_login_dark.svg      /tmp/skin/g8_login_dark.svg
COPY img/g8_login_light.svg     /tmp/skin/g8_login_light.svg
COPY img/grafana_typelogo.svg   /tmp/skin/grafana_text_logo_dark.svg
COPY img/grafana_typelogo.svg   /tmp/skin/grafana_text_logo_light.svg

# Overwrite the hash-named webpack copies with our skin assets. Each
# upstream asset emits one or more `<basename>.<hash>.svg` files in
# build/static/img/; we glob each prefix and write our content over
# whatever hash is there. If a glob matches nothing the loop body
# is skipped silently — which means an upstream rename will produce
# a visible "missed override" rather than a build failure. The smoke
# test catches that downstream.
RUN set -eux; \
    cd ${GF_PUBLIC}/build/static/img; \
    for src in /tmp/skin/*.svg; do \
      base=$(basename "$src" .svg); \
      for target in ${base}.*.svg; do \
        if [ -f "$target" ]; then \
          cp "$src" "$target"; \
          echo "  override: build/static/img/$target ← skin/${base}.svg"; \
        fi; \
      done; \
    done; \
    rm -rf /tmp/skin

# --- CSS overlay ---
COPY css/dartastic-skin.css     ${GF_PUBLIC}/css/dartastic-skin.css

# --- Template patches via sed ---
# More robust than a unified-diff patch file across upstream version
# bumps. Each sed runs independently; if upstream removes a string the
# sed becomes a no-op (and the smoke test catches the regression).
# Verify on each upstream image bump:
#   docker run --rm ghcr.io/dartastic/lgtm-skinned:next \
#     cat /otel-lgtm/grafana/public/views/index.html | grep -i grafana
RUN set -eux; \
    INDEX=${GF_PUBLIC}/views/index.html; \
    # 1. Browser tab title — replace the Go template variable with a
    # literal. The template engine emits it verbatim, so customers
    # see "Dartastic Hosted" in their browser tab.
    sed -i 's|<title>\[\[\.AppTitle\]\]</title>|<title>Dartastic Hosted</title>|' "$INDEX"; \
    # 2. Inject our stylesheet AFTER the upstream CSS files so our
    # rules win specificity ties.
    sed -i 's|\[\[range \$asset := \.Assets\.CSSFiles\]\]|<link rel="stylesheet" href="public/css/dartastic-skin.css" />\n    [[range $asset := .Assets.CSSFiles]]|' "$INDEX"; \
    # 3. Loading-spinner aria-label (screen-reader text) — accessibility
    # courtesy. Not visible in the UI but worth aligning.
    sed -i 's|aria-label="Loading Grafana"|aria-label="Loading dashboards"|' "$INDEX"; \
    # 4. The (hidden until failure) error message — when loading
    # *does* fail, the user sees this. Brand-align the copy.
    sed -i 's|<h1>If you'\''re seeing this Grafana has failed to load|<h1>If you'\''re seeing this Dartastic Hosted has failed to load|' "$INDEX"; \
    # Sanity: confirm at least one of the patches actually matched.
    # If all four sed calls became no-ops the upstream template changed
    # shape and we need to revisit. Fail loud during build, not in prod.
    grep -q "Dartastic Hosted" "$INDEX" \
      || (echo "ERROR: index.html patches all no-op'd — upstream template changed. See skin/Dockerfile" >&2 && exit 1)

# Labels for image provenance + AGPL source offer.
LABEL org.opencontainers.image.title="Dartastic Hosted — skinned LGTM"
LABEL org.opencontainers.image.source="https://github.com/dartastic/grafana-dartastic-skin"
LABEL org.opencontainers.image.licenses="AGPL-3.0-only"
LABEL io.dartastic.upstream="grafana/otel-lgtm:${UPSTREAM_TAG}"
