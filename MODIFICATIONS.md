# Modifications to Grafana

This repository is the source of Dartastic's modifications to Grafana, which
is licensed under the GNU Affero General Public License v3.0 (see `LICENSE`).
It is published under AGPL-3.0 section 13 so that anyone who uses the
modified Grafana over a network can get the corresponding source. The
modified work is provided with no warranty (AGPL-3.0 sections 15 and 16).

Statement of changes, as of 2026-09-27. Each image built from this source
names the Grafana it is based on in its `io.dartastic.upstream` label, and
upstream Grafana's source in `io.dartastic.upstream.source` (the repo) and
`io.dartastic.upstream.revision` (the release tag, such as `v13.0.1`).

## What is modified

Two images are built from the same changes:

- `lgtm-skinned` (`Dockerfile`), based on `grafana/otel-lgtm`, which bundles
  Grafana with Loki, Tempo, Prometheus and an OpenTelemetry Collector;
- `grafana-skinned` (`Dockerfile.grafana`), based on `grafana/grafana`.

The changes, all applied at image build time to the upstream Grafana files:

- **Branding assets.** Logos, favicons and icons under `public/img` and
  `public/build` are replaced with Dartastic's (`img/`). Datasource logos for
  Loki, Tempo and Pyroscope are replaced.
- **Page template.** `public/views/index.html`: the title, the loading text
  and the failure text are changed, and the Dartastic stylesheet and script
  are added.
- **Stylesheet and script.** `css/dartastic-skin.css` and
  `js/dartastic-skin.js` restyle the UI, rename product text in the browser
  (for example "Grafana" to the product name and "Loki" to "Logs"), and add
  the source footer that links here.
- **Translations.** The en-US locale catalog is rewritten
  (`build/rewrite-locale.py`) with the same product-text renames.
- **Alert notification email.** `public/emails/ng_alert_notification.html`
  and `.txt`: the Grafana logo is removed, the Dartastic icon is added to the
  title, links point at the alerting pages, the `grafana_folder` label is
  displayed as "folder", and the footer reads "Sent by Dartastic." The
  template remains Grafana's, modified; no copyright is claimed on it.
- **Configuration.** `conf/custom.ini` (server, users, help, feature
  toggles), provisioning for dashboards and alerting (`conf/provisioning/`),
  and, in `lgtm-skinned` only, the OpenTelemetry Collector configuration
  (`conf/otelcol-config.yaml`).
- **Dashboards.** Dartastic dashboards are provisioned (`dashboards/`).

## What is not part of this source

`lgtm-skinned` also carries, as separate programs that talk to Grafana only
over HTTP, the Dartastic AI gateway and the Dartastic AI Grafana plugin.
They are Dartastic's own work under the Dartastic Pro Commercial License, are
not modifications of Grafana, and are not in this repository.

Grafana® is a trademark of Grafana Labs. Dartastic.io is not affiliated with,
endorsed, or sponsored by Grafana Labs.
