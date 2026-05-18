# grafana-dartastic-skin

This repository is the **AGPLv3 §13 source offer** for
[Dartastic Hosted Observability](https://dartastic.io/hosted) —
the modifications layered on top of upstream
[`grafana/otel-lgtm`](https://github.com/grafana/docker-otel-lgtm)
that produce the Dartastic-branded UI customers see when they log
into a Dartastic Hosted cluster.

> Grafana® is a trademark of Grafana Labs. Dartastic.io is not
> affiliated with, endorsed, or sponsored by Grafana Labs.

## What's in here

```
Dockerfile             FROM grafana/otel-lgtm:${UPSTREAM_TAG}; layers
                       Dartastic logo/favicon/login-background overlays
                       and patches views/index.html via sed.
build-and-push.sh      Builds the multi-arch image and pushes to GHCR.
smoke-test.sh          Boots the built image and verifies brand
                       replacements landed.
img/                   Replacement assets (logo, wordmark, favicons,
                       login backgrounds). The heart-stethoscope mark
                       is Dartastic IP; the rest are derived from it.
css/dartastic-skin.css Overlay stylesheet — overrides the visible
                       Grafana wordmark and renders the AGPL §13
                       source-offer footer on every cluster page.
```

## Building

```bash
UPSTREAM_TAG=<grafana/otel-lgtm tag> SKIN_REV=<integer> ./build-and-push.sh
```

The built image carries `org.opencontainers.image.source` and
`io.dartastic.upstream` labels pointing at this repo + the upstream
tag for traceability.

## What this repo is NOT

- Not a community Grafana skin you'd want to install yourself. The
  branding overlays the Dartastic identity, not yours.
- Not the customer-facing Dartastic source. The Dart OTel runtime,
  Symbolizer, Pub Dev server, and dashboard JSON live in private
  Dartastic repos — they're proprietary and don't carry AGPL
  obligations (independent programs that communicate with the
  Grafana cluster over OTLP; AGPL is triggered by derivation, not
  network adjacency).

## Issues / contributions

This repo is a compliance mirror, not an active development surface.
For Dartastic Hosted bug reports or feature requests, see
[dartastic.io/support](https://dartastic.io/support).

## License

[AGPL-3.0-only](./LICENSE) — matching upstream Grafana OSS.
