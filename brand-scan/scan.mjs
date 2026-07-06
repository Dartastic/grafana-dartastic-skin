// hosted#194 — brand-scan gate: playwright walk of the skinned image.
//
// Boots nothing itself — point it at a RUNNING lgtm-skinned instance
// (run-local.sh handles the container lifecycle). Walks the customer-facing
// routes, and per route — after the SPA settles and the dartastic-skin.js
// MutationObserver replacer has had its beat — collects:
//
//   - document.body.innerText   (rendered, customer-VISIBLE text; NOT the
//     HTML source: grafanaBootData etc. are full of internal "grafana"
//     strings a customer never sees)
//   - every aria-label / alt / title attribute value (accessible names)
//   - document.title
//   - icon slots: inline-SVG flame signature (#187) + overridden brand-logo
//     asset contents + any grafana.com-hosted image reference
//
// FAILS on any /grafana/i match — plus the other Grafana Labs product marks
// shipped in the box (Loki, Mimir, Tempo, Pyroscope) — outside
// skin/brand-scan/allowlist.json.
// Findings matching skin/brand-scan/expected-fail.json (open-issue-tracked
// known leaks) are reported as KNOWN-FAILURE and do not redden the gate;
// check-expected-fail-freshness.sh flips them to enforcing when the issue
// closes. An expected-fail entry that stops matching anything prints an
// XPASS warning telling you to delete it.
//
// Env:
//   BASE_URL        default http://127.0.0.1:13000
//   ADMIN_USER      default admin   (fresh-image default credential)
//   ADMIN_PASSWORD  default admin
//   SETTLE_MS       default 3500    (post-load beat for the MutationObserver)
//   OUT_DIR         default ./out   (report.json + per-route screenshots)
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const HERE = dirname(fileURLToPath(import.meta.url));
const BASE = (process.env.BASE_URL || 'http://127.0.0.1:13000').replace(/\/$/, '');
const USER = process.env.ADMIN_USER || 'admin';
const PASS = process.env.ADMIN_PASSWORD || 'admin';
const SETTLE_MS = Number(process.env.SETTLE_MS || 3500);
const OUT_DIR = process.env.OUT_DIR || join(HERE, 'out');
const MARK = /grafana/i;
// The other Grafana Labs product marks the LGTM+profiling stack ships (Loki,
// Mimir, Tempo, Pyroscope). Same legal footing as Grafana® — all Grafana Labs
// trademarks — so they get the same zero-tolerance sweep; the skin renames
// their customer-visible DISPLAY to neutral data words (Logs / Metrics /
// Traces / Profiles). Word-anchored so the query-language marks (LogQL,
// TraceQL, PromQL — which don't contain these tokens) and incidental
// substrings ("contemporary") don't trip it. Prometheus and OpenTelemetry are
// deliberately EXCLUDED: CNCF marks, not Grafana Labs's, and expected in the
// product. Functional identifiers (datasource uid/type = "loki"/"tempo",
// which dashboards bind to) surface as DATA and are allowlisted route-scoped,
// exactly like grafana_folder — only the display is renamed.
const LABS_MARKS = /\b(?:loki|mimir|tempo|pyroscope)\b/i;
const anyMark = (s) => MARK.test(s) || LABS_MARKS.test(s);

// The AGPL §13 footer dartastic-skin.js injects (buildAgplFooter). The scan
// EXCLUDES the #dartastic-agpl-footer element from the body-text sweep, but
// only after asserting its text is EXACTLY this — so the exclusion can never
// mask an unrelated leak that crawled into the footer element.
const AGPL_FOOTER_SENTENCE =
  'This service runs modified Grafana — source: ' +
  'github.com/dartastic/grafana-dartastic-skin · Grafana® is a trademark of ' +
  'Grafana Labs. Dartastic.io is not affiliated with, endorsed, or sponsored ' +
  'by Grafana Labs.';
const AGPL_FOOTER_PILL = 'ⓘ open source';

// #187 flame signature, lifted from the live bundle's inline icon component
// on /alerting/list (svg[data-testid="icon-grafana"], viewBox 0 0 85.12 92.46,
// FFF200→F15A29 gradient, path starting M85.01 40.8).
// TODO(#187): when the skin replaces/hides that icon, this check goes green —
// delete the alerting-group-header-flame entry from expected-fail.json (the
// freshness check will force it once #187 closes).
const FLAME = {
  testid: 'icon-grafana',
  pathPrefix: 'M85.01 40.8',
  gradientStops: ['#FFF200', '#F15A29'],
};

// Routes to walk. optional:true → a dead route (HTTP >=400 or "Page not
// found" chrome) records a WARNING instead of failing; non-optional dead
// routes also warn loudly (never pass silently), still scanning whatever
// rendered. /login is scanned UNAUTHENTICATED (the one page every customer
// sees logged out); everything else with the admin session.
const ROUTES = [
  { path: '/login', unauthenticated: true },
  { path: '/' },
  { path: '/dashboards' },
  { path: '/explore' },
  { path: '/drilldown' },
  // Drilldown children (app plugin pages) — reachable from /drilldown.
  { path: '/a/grafana-metricsdrilldown-app', optional: true },
  { path: '/a/grafana-lokiexplore-app', optional: true },
  { path: '/a/grafana-exploretraces-app', optional: true },
  { path: '/a/grafana-pyroscope-app', optional: true },
  { path: '/alerting/list' },
  { path: '/alerting/notifications' },
  { path: '/alerting/routes' },
  { path: '/alerting/silences' },
  // Needs the alertingTriage toggle (prod sets it; run-local.sh mirrors it).
  { path: '/alerting/alerts', optional: true },
  { path: '/alerting/groups', optional: true },
  { path: '/alerting/admin/alertmanager' },
  { path: '/connections' },
  { path: '/connections/datasources' },
  { path: '/admin/general' },
];

const allowlist = JSON.parse(readFileSync(join(HERE, 'allowlist.json'), 'utf8')).entries;
const expectedFail = JSON.parse(readFileSync(join(HERE, 'expected-fail.json'), 'utf8')).entries;

const routeMatches = (prefixes, route) =>
  prefixes.includes('*') || prefixes.some((p) => route === p || route.startsWith(p));

function allowlisted(kind, snippet, route) {
  return allowlist.find(
    (e) =>
      (e.context === 'any' || e.context === kind) &&
      routeMatches(e.routes, route) &&
      new RegExp(e.pattern).test(snippet),
  );
}

function expectedFailure(kind, snippet, route) {
  return expectedFail.find(
    (e) => e.kind === kind && routeMatches(e.routes, route) && new RegExp(e.pattern).test(snippet),
  );
}

const failures = []; // { route, kind, snippet }
const knownFailures = []; // same + xfail id/issue
const warnings = [];
const matchedXfailIds = new Set();

function finding(route, kind, snippet, detail = '') {
  const xf = expectedFailure(kind, snippet, route);
  if (xf) {
    matchedXfailIds.add(xf.id);
    knownFailures.push({ route, kind, snippet, detail, xfail: xf.id, issue: xf.issue });
  } else {
    failures.push({ route, kind, snippet, detail });
  }
}

mkdirSync(OUT_DIR, { recursive: true });
const browser = await chromium.launch();

// Two contexts: an anonymous one for /login, an authed one for the rest.
const anonCtx = await browser.newContext();
const authCtx = await browser.newContext();
const loginResp = await authCtx.request.post(`${BASE}/login`, {
  data: { user: USER, password: PASS },
});
if (loginResp.status() !== 200) {
  console.error(`FATAL: admin login POST -> HTTP ${loginResp.status()} — is this a fresh image with admin/admin?`);
  process.exit(2);
}

const report = [];
for (const route of ROUTES) {
  const ctx = route.unauthenticated ? anonCtx : authCtx;
  const page = await ctx.newPage();
  let status = null;
  try {
    const nav = await page.goto(BASE + route.path, { waitUntil: 'domcontentloaded', timeout: 45000 });
    status = nav ? nav.status() : null;
  } catch (e) {
    warnings.push(`${route.path}: navigation failed (${String(e).split('\n')[0]})`);
    await page.close();
    continue;
  }
  // networkidle best-effort (Grafana keeps sockets open on some pages), then
  // a fixed settle so the MutationObserver replacer + React have finished.
  await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});
  await page.waitForTimeout(SETTLE_MS);

  const dump = await page.evaluate((flame) => {
    const footer = document.getElementById('dartastic-agpl-footer');
    const footerText = footer ? footer.textContent : null;
    // Hide the (verified-below) attribution footer while capturing innerText
    // so its deliberate upstream naming doesn't need a blanket allowlist.
    const prev = footer ? footer.style.display : null;
    if (footer) footer.style.display = 'none';
    const bodyText = document.body.innerText;
    if (footer) footer.style.display = prev;

    const attrs = [];
    for (const el of document.querySelectorAll('[aria-label],[alt],[title]')) {
      for (const a of ['aria-label', 'alt', 'title']) {
        const v = el.getAttribute(a);
        if (v) attrs.push({ attr: a, value: v, el: el.outerHTML.slice(0, 200) });
      }
    }

    // Icon sweep (kept broad — any inline flame anywhere, any grafana.com-
    // hosted image, plus the brand-logo <img> slots for content verification).
    const flames = [];
    for (const svg of document.querySelectorAll('svg')) {
      const testid = svg.getAttribute('data-testid') || '';
      const d = svg.querySelector('path')?.getAttribute('d') || '';
      const stops = [...svg.querySelectorAll('stop')].map((s) => (s.getAttribute('stop-color') || '').toUpperCase());
      if (
        testid === flame.testid ||
        d.startsWith(flame.pathPrefix) ||
        (stops.includes(flame.gradientStops[0]) && stops.includes(flame.gradientStops[1]))
      ) {
        flames.push(svg.outerHTML.slice(0, 300));
      }
    }
    const remoteImgs = [...document.querySelectorAll('img')]
      .map((i) => i.getAttribute('src') || '')
      .filter((s) => /grafana\.(com|net)/i.test(s));
    const brandImgSrcs = [
      ...new Set(
        [...document.querySelectorAll('img')]
          .map((i) => i.getAttribute('src') || '')
          .filter((s) => /grafana_(icon|typelogo|text_logo)|g8_login/i.test(s) && s.endsWith('.svg')),
      ),
    ];
    return { bodyText, attrs, footerText, docTitle: document.title, flames, remoteImgs, brandImgSrcs, finalPath: location.pathname };
  }, FLAME);

  // Dead-route detection — record a warning, never pass silently. "Page not
  // found" chrome is the real signal; Grafana serves some live routes with a
  // server-side 404 while the SPA renders them fine (/admin/general does).
  const dead = /page not found/i.test(dump.docTitle);
  if (dead) {
    warnings.push(
      `${route.path}: renders "Page not found" (HTTP ${status})${route.optional ? ' [optional route]' : ' — ROUTE LIST NEEDS UPDATING for this Grafana version'}`,
    );
  } else if (status && status >= 400) {
    warnings.push(`${route.path}: server returned HTTP ${status} but the SPA rendered "${dump.docTitle}" — scanned as live`);
  }

  // AGPL footer: must exist everywhere the skin JS runs, and must say
  // exactly what we expect (else the structural exclusion above could hide
  // an arbitrary leak inside the footer element).
  if (!dump.footerText) {
    finding(route.path, 'footer', '(missing)', 'AGPL §13 footer element #dartastic-agpl-footer not found — skin JS not running?');
  } else {
    // Compare with ALL whitespace stripped — textContent concatenates the
    // full-bar and pill spans without a separator.
    const squash = (s) => s.replace(/\s+/g, '');
    const normalized = squash(dump.footerText);
    const expected = squash(AGPL_FOOTER_SENTENCE + AGPL_FOOTER_PILL);
    const expectedNoPill = squash(AGPL_FOOTER_SENTENCE);
    if (normalized !== expected && normalized !== expectedNoPill) {
      finding(route.path, 'footer', dump.footerText.replace(/\s+/g, ' ').trim().slice(0, 200), 'AGPL footer text drifted from the expected attribution');
    }
  }

  // Rendered text, line by line.
  for (const line of dump.bodyText.split('\n')) {
    const t = line.trim();
    if (t && anyMark(t) && !allowlisted('text', t, route.path)) finding(route.path, 'text', t.slice(0, 300));
  }
  // Accessible names / tooltips / alt text.
  for (const { attr, value, el } of dump.attrs) {
    if (anyMark(value) && !allowlisted('attr', value, route.path)) {
      finding(route.path, 'attr', value.slice(0, 300), `${attr} on ${el}`);
    }
  }
  // Page title.
  if (anyMark(dump.docTitle) && !allowlisted('title', dump.docTitle, route.path)) {
    finding(route.path, 'title', dump.docTitle);
  }
  // Icons: inline flame (#187 class of leak) …
  for (const f of dump.flames) finding(route.path, 'icon', f.slice(0, 200), 'inline upstream flame SVG');
  // … images loaded from upstream's own hosts …
  for (const src of dump.remoteImgs) finding(route.path, 'icon', src, 'image loaded from an upstream host');
  // … and the brand-logo slots: the <img> src paths are upstream-named by
  // design (we override the CONTENT); verify each actually serves our
  // override (all skin SVGs carry a "Dartastic" marker comment).
  for (const src of dump.brandImgSrcs) {
    try {
      // Resolve against the server ROOT: Grafana's index.html sets
      // <base href="/">, so relative srcs are root-relative regardless of
      // the route depth.
      const resp = await ctx.request.get(new URL(src, BASE + '/').href);
      const body = await resp.text();
      if (!resp.ok() || !/Dartastic/.test(body)) {
        finding(route.path, 'icon', src, 'brand-logo slot serves NON-skin content (upstream asset leaked through)');
      }
    } catch {
      warnings.push(`${route.path}: could not fetch brand img ${src} for content check`);
    }
  }

  await page.screenshot({ path: join(OUT_DIR, `${route.path.replace(/[^a-z0-9]+/gi, '_') || 'root'}.png`), fullPage: true }).catch(() => {});
  report.push({ route: route.path, status, finalPath: dump.finalPath, title: dump.docTitle, dead });
  console.log(`scanned ${route.path}  (HTTP ${status}, title "${dump.docTitle}")`);
  await page.close();
}
await browser.close();

// XPASS: expected-fail entries that matched nothing this run.
const xpass = expectedFail.filter((e) => !matchedXfailIds.has(e.id));
for (const e of xpass) {
  warnings.push(`XPASS: expected-fail entry "${e.id}" (issue #${e.issue}) matched nothing — if the leak is really fixed, DELETE the entry from expected-fail.json`);
}

writeFileSync(
  join(OUT_DIR, 'report.json'),
  JSON.stringify({ base: BASE, when: new Date().toISOString(), routes: report, failures, knownFailures, warnings }, null, 2),
);

console.log('\n===== brand-scan summary =====');
for (const w of warnings) console.log(`WARN  ${w}`);
for (const k of knownFailures) {
  console.log(`KNOWN-FAILURE [#${k.issue} ${k.xfail}] ${k.route} ${k.kind}: ${JSON.stringify(k.snippet)}`);
}
for (const f of failures) {
  console.log(`FAIL  ${f.route} ${f.kind}: ${JSON.stringify(f.snippet)}${f.detail ? `  (${f.detail})` : ''}`);
}
console.log(`routes=${report.length} failures=${failures.length} known-failures=${knownFailures.length} warnings=${warnings.length}`);
if (failures.length) {
  console.error('\nBRAND SCAN FAILED — customer-visible upstream marks found outside the allowlist.');
  console.error('If a match is legitimately nominative/required, add a narrow allowlist.json entry via PR.');
  process.exit(1);
}
console.log('\nBRAND SCAN PASSED');
