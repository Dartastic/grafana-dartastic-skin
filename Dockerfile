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

# --- Stage 1: AOT-compile the Dartastic AI gateway (#85 P1) ---
#
# Source comes from `../ai-gateway/` and is staged into
# `build/ai-gateway/` by build-and-push.sh — same pattern as the
# dashboards staging.  The gateway binary ships in this image but
# is OFF BY DEFAULT — dartastic-entrypoint.sh only starts it when
# ANTHROPIC_API_KEY + at least one AI_GATEWAY_CUSTOMER_<ID>_SECRET
# are present at boot.
#
# License posture: the Dart binary is Pro Commercial (see
# ../ai-gateway/LICENSE).  Bundling a separately-licensed program
# into the same container image is not "combining" under AGPL —
# same as bundling nginx in a Grafana image.  The §13 source
# offer in the cluster UI still points at the public skin mirror,
# which does NOT include the ai-gateway source (Pro repo, not OSS).
FROM dart:stable AS ai-gateway-build
WORKDIR /app
COPY build/ai-gateway/pubspec.* /app/
RUN dart pub get
COPY build/ai-gateway/ /app/
RUN dart pub get --offline
RUN dart compile exe bin/ai_gateway.dart -o /app/ai_gateway

# --- Stage 1b: Build the Dartastic AI Grafana plugin (#85 P1.D) ---
#
# TypeScript + React, bundled to a Grafana plugin `dist/` via
# webpack.  Output lands at /plugin/dist/ — that's what stage 2
# COPYs into /var/lib/grafana/plugins/dartastic-ai-panel/.
#
# Plugin source-of-truth: hosted/grafana-plugins/dartastic-ai-panel/.
# Staged into build/ai-plugin/ by build-and-push.sh.
FROM node:20-slim AS ai-plugin-build
WORKDIR /plugin
COPY build/ai-plugin/ /plugin/
RUN npm install --no-audit --no-fund
RUN npm run build

# --- Stage 2: the skinned LGTM image (the deployable) ---
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
# Grafana 13 references the favicon, apple-touch-icon, AND the page-load
# preloader spinner from public/build/img/ (NOT public/img/) — see
# index.html: <link rel="icon" href="public/build/img/fav32.png">,
# <link rel="apple-touch-icon" href="public/build/img/apple-touch-icon.png">,
# and the preloader <img src="public/build/img/grafana_icon.svg">. Overriding
# only public/img/ above leaves the browser loading the upstream Grafana flame
# (the favicon + spinner regression). These build/img names are NOT hashed, so
# a direct COPY wins. smoke-test.sh byte-checks them to catch a future move.
COPY img/fav32.png              ${GF_PUBLIC}/build/img/fav32.png
COPY img/apple-touch-icon.png   ${GF_PUBLIC}/build/img/apple-touch-icon.png
COPY img/grafana_icon.svg       ${GF_PUBLIC}/build/img/grafana_icon.svg
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

# --- JS runtime text-replacer ---
# Handles "Grafana" text that's hard-coded inside the React bundle
# (e.g. the MegaMenu sidebar wordmark from `homeNav.text`, which
# Grafana OSS won't let us override at config time). Runs on every
# page load via the index.html injection below.
COPY js/dartastic-skin.js       ${GF_PUBLIC}/js/dartastic-skin.js

# --- Replace the default home dashboard ---
# Upstream `home.json` renders a `type: welcome` panel that emits
# `<h1>Welcome to Grafana</h1>` plus tutorial links to grafana.com,
# and a `news` panel that fetches grafana.com/blog/news.xml. Replace
# the whole file with Dartastic-flavored content (markdown panels +
# dashlist; no welcome panel, no upstream news feed).
COPY dashboards/home.json       ${GF_PUBLIC}/dashboards/home.json

# --- De-brand outbound alert-notification emails (hosted#131) ---
# public/emails/ng_alert_notification.{html,txt} carry three customer-facing
# branding leaks the rest of the skin can't reach: the grafana.com header logo
# and a footer "(c) YEAR Grafana Labs. Sent by Grafana vX.Y.Z". These render in
# the CUSTOMER's alert emails, so — like the Slack notification-sanitizer — they
# must not name the upstream. Patch in place, then ASSERT the leaks are gone: an
# upstream template reword no-ops the sed and FAILS THE BUILD (louder than the
# silent-skip SVG globs above). Unlike the in-app i18n catalog, which KEEPS
# "Grafana Labs" as trademark attribution in-product, these are external comms
# and get fully de-branded. BRANDING IS INLINE, zero vertical space (Michael:
# a standalone logo block pushes the alert content below the fold): the
# upstream banner section is collapsed (its <img> deleted + that section's
# padding zeroed — range-scoped to the FIRST padding:20px, which sits just
# above the logo img; the other three 20px paddings are real section spacing),
# and the Dartastic heart (public/img/apple-touch-icon.png, PNG so Gmail/
# Outlook render it) replaces the folder emoji INSIDE the <h2> title line at
# 22px. Footer copyright names the DBA "Dartastic.io". "View alert" buttons
# go to /alerting/alerts (the ACTIVE-instances route Grafana 13 actually
# registers — /alerting/groups renders via a legacy fallback with 404 page
# chrome; /alerting/list is rule CONFIG, wrong audience. The route is gated
# on the alertingTriage toggle, enabled in docker-compose.dartastic.yml).
# The `grafana_folder` group label stays intact as DATA (matchers, grouping)
# but its DISPLAYED name is renamed to "folder" wherever templates print
# label names ({{ .Name }} loops, builtin `eq` conditional — the email
# funcmap has no sprig, so no replace/reReplaceAll; verified) and the txt
# header's raw {{ .GroupLabels }} map print (which would show the label key)
# becomes the alertname.
RUN set -eux; \
    cd ${GF_PUBLIC}/emails; \
    sed -i '0,/logo_new_transparent/ s@padding:20px 0;@padding:0;@' \
      ng_alert_notification.html; \
    sed -i \
      -e 's@<img[^>]*logo_new_transparent[^>]*>@@' \
      -e 's@📁@<img src="{{ $.AppUrl }}public/img/apple-touch-icon.png" width="22" height="22" style="border:0;vertical-align:middle;">@g' \
      -e 's@Grafana Labs. Sent by <a href="{{ .AppUrl }}" style="color: #6E9FFF;">Grafana v{{ .BuildVersion }}</a>.@<a href="{{ .AppUrl }}" style="color: #6E9FFF;">Dartastic.io</a>.@' \
      -e 's@href="{{ .GeneratorURL }}"@href="{{ $.AppUrl }}alerting/alerts"@g' \
      -e 's@href="{{ .SilenceURL }}"@href="{{ $.AppUrl }}alerting/silences"@g' \
      -e 's@{{ .Name }}@{{ if eq .Name "grafana_folder" }}folder{{ else }}{{ .Name }}{{ end }}@g' \
      ng_alert_notification.html; \
    sed -i \
      -e 's@Sent by Grafana v{{.BuildVersion}} (c) {{now | date "2006"}} Grafana Labs@Sent by Dartastic (c) {{now | date "2006"}} Dartastic.io@' \
      -e 's@{{ .Name }}@{{ if eq .Name "grafana_folder" }}folder{{ else }}{{ .Name }}{{ end }}@g' \
      -e 's@for {{ .GroupLabels }}@for {{ index .GroupLabels "alertname" }}@' \
      ng_alert_notification.txt; \
    if grep -Eiq 'grafana labs|grafana v|logo_new_transparent' \
         ng_alert_notification.html ng_alert_notification.txt; then \
      echo "FATAL: alert-email de-brand missed a leak — upstream template reworded?" >&2; \
      exit 1; \
    fi; \
    # The Firing/View-alert/Silence button hrefs expand at RUNTIME to
    # /alerting/grafana/<uid>/view and ...?alertmanager=grafana&... — the
    # upstream name inside customer comms (AGPL/trademark: not one character).
    # Repoint them at the native brand-free routes (active instances / silences).
    # SCOPE: those buttons sit inside {{ range .Alerts }}, where dot is an
    # ExtendedAlert with no AppUrl field — `.AppUrl` there ABORTS the whole
    # template ("can't evaluate field AppUrl", rice-19 2026-07-05) and the
    # email never sends. `$.AppUrl` reaches the root context from any scope.
    # The {{ if .GeneratorURL/.SilenceURL }} display-guards stay. Assert the
    # href forms are gone so an upstream reword fails the build, same as above.
    if grep -Fq 'href="{{ .GeneratorURL }}"' ng_alert_notification.html \
       || grep -Fq 'href="{{ .SilenceURL }}"' ng_alert_notification.html; then \
      echo "FATAL: alert-email URL de-brand missed a leak — upstream template reworded?" >&2; \
      exit 1; \
    fi; \
    # The grafana_folder DISPLAY rename must have landed in both parts (the
    # raw {{ .Name }} loops print the label KEY to the customer otherwise).
    if ! grep -Fq 'eq .Name "grafana_folder"' ng_alert_notification.html \
       || ! grep -Fq 'eq .Name "grafana_folder"' ng_alert_notification.txt; then \
      echo "FATAL: grafana_folder display-rename missing — upstream label loop reworded?" >&2; \
      exit 1; \
    fi

# --- Rewritten en-US i18n catalog ---
# Pre-generated on the host by build-and-push.sh + rewrite-locale.py.
# Bulk-renames "Grafana" → "Dartastic" across ~270 user-visible
# strings while preserving "Grafana Labs" (trademark attribution),
# grafana.com URLs, and github.com/grafana links. This is the
# heaviest brand-strip in the skin: it catches everything Grafana
# emits via its i18n layer (menus, tooltips, error messages,
# admin pages, alerting workflows, plugin-marketplace copy, ...).
#
# `build-and-push.sh` extracts the upstream JSON, runs
# `build/rewrite-locale.py` against it, and writes the result to
# `build/skin-en-US.json` which we COPY in here. If the file is
# missing the build fails — the script is in charge of regenerating
# it on every build so version bumps don't ship stale strings.
COPY build/skin-en-US.json      ${GF_PUBLIC}/locales/en-US/grafana.json

# --- Custom Grafana config ---
# Disables: the upstream news feed (grafana.com blog RSS), the
# `gettingstarted` panel plugin (the auto-injected "Welcome to
# Grafana" tutorial card on the home dashboard), and the upstream
# help menu (mostly grafana.com doc links).
COPY conf/custom.ini            /otel-lgtm/grafana/conf/custom.ini

# --- Dartastic dashboards (#101) ---
# Auto-provision the customer-facing dashboards on first boot so a
# fresh box shows "Crashes — Symbolized" + "Flutter App Health" +
# "Mobile Release Health" + "Server Health" without anyone having
# to import JSON by hand. Source-of-truth files live in
# `../dashboards/` and are staged into `build/customer-dashboards/`
# by build-and-push.sh — keeps `hosted/dashboards/*.json` as the
# single authoritative location.
COPY build/customer-dashboards/      /otel-lgtm/dartastic-dashboards/
COPY conf/dartastic-dashboards.yaml  /otel-lgtm/grafana/conf/provisioning/dashboards/dartastic-dashboards.yaml

# --- Dartastic Reference Demo dashboards ---
# The reference-demo dashboards (Service Overview) in their own
# "Dartastic Reference Demo" sidebar folder, separate from the
# product dashboards above. They populate when a customer runs the
# Dartastic Reference Demo. Staged from ../dashboards/demo/ by
# build-and-push.sh.
COPY build/reference-demo-dashboards/            /otel-lgtm/dartastic-reference-demo-dashboards/
COPY conf/dartastic-reference-demo-dashboards.yaml  /otel-lgtm/grafana/conf/provisioning/dashboards/dartastic-reference-demo-dashboards.yaml

# --- Default alert-notification wiring (hosted#131) ---
# A default email contact point + notification policy so a customer's alert
# RULES actually deliver instead of "failed to send". Address is injected per
# box as $ADMIN_ALERT_EMAIL; SMTP transport via GF_SMTP_* (docker-compose.lgtm).
COPY conf/provisioning/alerting/dartastic-default.yaml  /otel-lgtm/grafana/conf/provisioning/alerting/dartastic-default.yaml

# --- Starter alert rules (hosted#184) ---
# A small pack of file-provisioned rules (app error rate, crashes, no-telemetry,
# box disk/CPU/memory) so a fresh box does something useful the moment a
# destination exists — like the pre-loaded dashboards. Unrouted → falls through
# to the default policy the reconciler maintains (#183).
COPY conf/provisioning/alerting/dartastic-starter-rules.yaml  /otel-lgtm/grafana/conf/provisioning/alerting/dartastic-starter-rules.yaml

# --- Template patches via sed ---
# More robust than a unified-diff patch file across upstream version
# bumps. Each sed runs independently; if upstream removes a string the
# sed becomes a no-op (and the smoke test catches the regression).
# Verify on each upstream image bump:
#   docker run --rm ghcr.io/dartastic-io/lgtm-skinned:next \
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
    # 3. Inject our JS text-rewriter just before </body>. Runs after
    # the React bundle so the MutationObserver catches everything
    # the SPA renders. `defer` keeps it from blocking initial paint.
    sed -i 's|</body>|<script src="public/js/dartastic-skin.js" defer></script>\n  </body>|' "$INDEX"; \
    # 4. Loading-spinner aria-label (screen-reader text) — accessibility
    # courtesy. Not visible in the UI but worth aligning.
    sed -i 's|aria-label="Loading Grafana"|aria-label="Loading dashboards"|' "$INDEX"; \
    # 5. The (hidden until failure) error message — when loading
    # *does* fail, the user sees this. Brand-align the copy.
    sed -i 's|<h1>If you'\''re seeing this Grafana has failed to load|<h1>If you'\''re seeing this Dartastic Hosted has failed to load|' "$INDEX"; \
    # Sanity: confirm patches matched. Title + JS injection are both
    # required; if either is missing the build fails loud.
    grep -q "Dartastic Hosted" "$INDEX" \
      || (echo "ERROR: index.html title patch no-op'd — upstream template changed. See skin/Dockerfile" >&2 && exit 1); \
    grep -q "public/js/dartastic-skin.js" "$INDEX" \
      || (echo "ERROR: index.html JS injection no-op'd — </body> not found?" >&2 && exit 1)

# --- Bundle the Dartastic AI gateway binary (#85 P1) ---
# Off-by-default: the wrapper entrypoint only starts the gateway
# when ANTHROPIC_API_KEY + at least one AI_GATEWAY_CUSTOMER_<ID>_SECRET
# are present on the box at boot.  Customers without an AI add-on
# never see it run.
COPY --from=ai-gateway-build /app/ai_gateway /usr/local/bin/ai_gateway

# --- OTel collector config override (#85 P1.G) ---
# Replaces upstream's /otel-lgtm/otelcol-config.yaml.  Adds a
# `prometheus/ai-gateway` receiver that scrapes the bundled AI
# gateway's /metrics on 127.0.0.1:8091 every 15s and routes the
# samples through the existing metrics pipeline into Prometheus
# (the metrics store otel-lgtm bundles — not Mimir).  When
# AI is off on this box the scrape quietly fails (up=0); nothing
# else changes.  When the upstream tag bumps, reconcile against
# `docker run --rm grafana/otel-lgtm:<new-tag> cat
# /otel-lgtm/otelcol-config.yaml`.
COPY conf/otelcol-config.yaml   /otel-lgtm/otelcol-config.yaml

# --- Bundle the Dartastic AI Grafana plugin (#85 P1.D) ---
# Grafana auto-discovers plugins under /var/lib/grafana/plugins/.
# Grafana refuses to load unsigned plugins by default; the
# `[plugins] allow_loading_unsigned_plugins` config line in
# conf/custom.ini whitelists ours by id.  Customers on Hosted
# never need to think about plugin signing — the bundled deploy
# is trusted by virtue of being inside the same image.
COPY --from=ai-plugin-build /plugin/dist/ /var/lib/grafana/plugins/dartastic-ai-panel/

# Wrapper entrypoint — backgrounds the AI gateway when configured,
# then execs the original LGTM entrypoint in the foreground (so if
# LGTM dies the container restarts and supervisor semantics work).
COPY scripts/dartastic-entrypoint.sh /usr/local/bin/dartastic-entrypoint.sh
RUN chmod +x /usr/local/bin/dartastic-entrypoint.sh

# Persistent-disk path for the gateway's state (rate-limiter
# buckets, future cached embeddings).  Compose mounts a named
# volume here so a container restart doesn't wipe per-customer
# usage history — addresses the "but I want to update AI on a
# different cadence than LGTM" concern by making state durable
# across image bumps.
RUN mkdir -p /var/lib/dartastic-ai && chmod 755 /var/lib/dartastic-ai
VOLUME ["/var/lib/dartastic-ai"]

EXPOSE 8091
ENTRYPOINT ["/usr/local/bin/dartastic-entrypoint.sh"]

# Labels for image provenance + AGPL source offer.
LABEL org.opencontainers.image.title="Dartastic Hosted — skinned LGTM + AI"
LABEL org.opencontainers.image.source="https://github.com/dartastic/grafana-dartastic-skin"
LABEL org.opencontainers.image.licenses="AGPL-3.0-only AND LicenseRef-Dartastic-Commercial"
LABEL io.dartastic.upstream="grafana/otel-lgtm:${UPSTREAM_TAG}"
