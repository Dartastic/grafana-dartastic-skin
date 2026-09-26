# Changelog

All notable changes to this plugin live here.  Follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- **P1.H**: First-run consent gate (`src/consent.ts` +
  `ConsentGate` component in the panel).  The first time the
  panel renders in any browser, it shows a card with the legal
  disclaimer + Dartastic AI's three load-bearing properties
  (suggestions advisory, no training on customer telemetry,
  every answer grounded).  "I understand" persists the
  acknowledgement to localStorage under
  `dartastic-ai-panel.consent-v1` and the panel flips to the
  composer.  Subsequent renders skip the gate.  Versioned key
  so a material wording change can re-prompt every browser.
- **P1.E**: RAG context assembly in `src/rag.ts`.  Trace-id-shaped
  hex tokens in the question (16 or 32 chars, word-bounded) are
  extracted and fetched from box-local Tempo via Grafana's data-
  source proxy.  Spans are normalised to the gateway's `context.spans`
  shape (handles both `resourceSpans` and legacy `batches` Tempo
  response wrappers).  Panel renders a "grounded in: …" line under
  the question so the user sees which sources contributed.
- Failure-mode handling: a Tempo fetch failure surfaces as an
  in-panel Alert, separate from the gateway's refuse-to-answer
  Alert, so the user can distinguish "couldn't read Tempo" from
  "model didn't have grounded context."

### Known limitations
- Only `span_id`-based citations resolve.  Source-line and metric
  citations need P2 (PubDev source pull + Mimir snapshot pull).
- No automatic trace-id detection from the current dashboard time
  range — the user has to paste the trace_id explicitly.  Smarter
  "use the active trace from this panel" plumbing is P2.

## [0.3.0] - 2026-09-26

### Changed
- The proxy route reads the gateway address from `jsonData.gatewayUrl`
  and sends `secureJsonData.gatewayToken` as a bearer token, so the same
  plugin serves Hosted (gateway in the Grafana container) and
  Self-Hosted (gateway as its own service). The token never reaches the
  browser.

### Added
- Published as an OCI image for Self-Hosted Grafana installs.

## [0.2.0] - 2026-09-25

### Fixed
- The chat panel now loads. It ships as a panel plugin nested in the
  app (`dartastic-ai-panel-panel`); before, Grafana registered only
  the app, so dashboards showed "Panel plugin not found".
- Requests reach the gateway. The panel calls the app's proxy route,
  and the route matches its full path.
- Removed a reference to an undefined name that would have stopped
  the panel module from loading. The build now typechecks first.

### Security
- Only organization admins can use Dartastic AI. Grafana refuses
  anyone below Admin before proxying to the gateway, and the panel
  tells other users the AI is for admins.

## [0.1.0] - 2026-05-20

### Added
- Initial scaffold: app plugin + bundled `Dartastic AI` panel.
- Chat composer + answer/citations rendering with the canonical
  Dartastic palette.
- Grafana plugin proxy route to `http://127.0.0.1:8091`, calling
  the bundled gateway under localhost-trust mode.
- Refuse-to-answer surfaced as an Alert with the gateway's reason.
- Per-panel options: `starterQuestion`, `showUsage`.

### Known limitations
- Empty RAG context — the panel sends no spans/logs/metrics yet
  (P1.E lands the bridge).  Until then most questions trigger
  refuse-to-answer; the few that match by inspection of the
  user's question still work.
- Plugin must be loaded unsigned (or signed by Grafana Labs in a
  future release).  Bundled flow uses
  `allow_loading_unsigned_plugins` in custom.ini.
