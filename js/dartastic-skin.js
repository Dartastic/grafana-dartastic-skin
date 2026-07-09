// Dartastic Hosted skin — runtime text-replacement.
//
// Grafana 13 OSS hard-codes the brand text "Grafana" in several places
// that can't be reached from CSS, the Dockerfile-time sed patches, or
// asset overrides:
//
//   - MegaMenu sidebar header wordmark — rendered from a `homeNav.text`
//     prop that the JS bundle sets to "Grafana".  No public knob in OSS
//     (Enterprise has `[white_labeling]` for this).
//   - Various tooltip / aria-label strings on plugins / menu items.
//   - Welcome panel + "Welcome to Grafana" h1 (we've also replaced
//     `dashboards/home.json` upstream of this, but a MutationObserver
//     catches any other surfaces that emit it).
//
// This script runs on every page load (injected into views/index.html
// by the Dockerfile sed step) and rewrites text nodes that exactly
// match "Grafana" to "Dartastic Hosted".  Exact-match only so we
// don't touch things like "Grafana Labs", "grafana.com", or attribute
// values like aria-label.
//
// MutationObserver covers the React rendering lifecycle — text nodes
// appear after the initial DOM ready event, then get re-rendered as
// the user navigates between routes.

(function () {
  'use strict';

  const REPLACEMENTS = {
    'Grafana': 'Dartastic Hosted',
    'Welcome to Grafana': 'Welcome to Dartastic Hosted',
    // Alerting v2 (Grafana 13) surfaces: these strings are i18n-keyed in the
    // bundle (t("alerting.…", "Grafana-managed …")) but the keys are MISSING
    // from the shipped en-US catalog, so the hardcoded English fallback
    // renders and the Dockerfile locale rewrite never sees them. Exact-match
    // entries here; on the next upstream bump consider INJECTING the keys
    // into the catalog instead (grep bundles for t("alerting.*"Grafana").
    'Grafana-managed': 'Dartastic-managed',
    'Grafana-managed alert rules': 'Dartastic-managed alert rules',
    'Grafana built-in': 'Dartastic built-in',
    'Receiving Grafana-managed alerts': 'Receiving Dartastic-managed alerts',
    'Manage Alertmanager configurations and enable receiving Grafana-managed alerts':
      'Manage Alertmanager configurations and enable receiving Dartastic-managed alerts',
    // The system label KEY for the rule's folder (models.FolderTitleLabel,
    // engine-baked — renaming the DATA would break matchers/grouping). This
    // rewrites its DISPLAY in text nodes (grouped-by chips, label lists) to
    // match the outbound-comms rename ("folder"). Known edge: a user copying
    // the DISPLAYED name to hand-write a matcher must use grafana_folder;
    // owner accepts (zero-tolerance on visible upstream tokens, 2026-07-06).
    'grafana_folder': 'folder',
    'grafana_folder, alertname': 'folder, alertname',
    // The other Grafana Labs product marks the LGTM+profiling stack ships as
    // datasource DISPLAY names / plugin names / drilldown labels (Loki, Mimir,
    // Tempo, Pyroscope — all Grafana Labs trademarks). Renamed to neutral data
    // words; the datasource uid/type stay "loki"/"tempo"/… (what dashboards +
    // alert queries bind to), so only the display changes — nothing breaks.
    // Matches Grafana's own Drilldown naming. Brand-scan LABS_MARKS enforces
    // this; the attribute-side leak (alt="Loki" on the datasource logo) needs
    // the attribute pass, tracked in the Labs-marks de-brand issue.
    'Loki': 'Logs',
    'Tempo': 'Traces',
    'Mimir': 'Metrics',
    'Pyroscope': 'Profiles',
    'Grafana Pyroscope': 'Profiles',
    'Set Up Your Pyroscope Server': 'Set Up Your Profiles Server',
    // The built-in "-- Grafana --" datasource (special uid, used for
    // annotations / mixed / -- Dashboard -- refs) surfaces in the Explore
    // datasource picker + breadcrumb. Rename the DISPLAY only — the uid stays
    // "-- Grafana --", so dashboards/queries that reference it are untouched.
    // The attribute forms (breadcrumb title=, logo alt=) are unreachable by
    // this text-node walker and are tracked under #200 (attribute pass).
    '-- Grafana --': '-- Dartastic --',
    '(-- Grafana --)': '(-- Dartastic --)',
    // Logs drilldown (grafana-lokiexplore-app) empty-state copy, shown on the
    // standalone (grafana-skinned) image before a Logs datasource is
    // provisioned. Loki→Logs, in-sentence (the bare 'Loki' rename above is
    // exact-node-match and can't reach these). Real Cloud boxes provision the
    // per-org datasource via the tenant-reconciler, so this empty state does
    // not render there; the rename keeps the bare-image scan clean.
    'We noticed there is no Loki datasource configured.':
      'We noticed there is no Logs datasource configured.',
    'Add a Loki datasource to view logs.': 'Add a Logs datasource to view logs.',
  };

  // ── In-sentence + attribute mark rewriting (hosted#196 / #187) ──────────
  // REPLACEMENTS above is exact-match on a whole trimmed text node. Two
  // surfaces it can't reach: (1) marks INSIDE longer strings — the auto-promo
  // drawer ("Grafana Assistant is now available…"), drilldown taglines, admin
  // copy, plugin display names; (2) attribute VALUES (alt / aria-label /
  // title) that the brand-scan reads but no CSS/text pass touches. A single
  // word-boundary rewrite neutralises every in-sentence mark — the same policy
  // rewriteTitle() already applies to document.title — mapping each to its
  // neutral word (Grafana->Dartastic, and the Labs product marks Loki->Logs,
  // Mimir->Metrics, Tempo->Traces, Pyroscope->Profiles, e.g. the profiling
  // onboarding copy "Add a new Pyroscope datasource…"). "Grafana Labs" is left
  // intact (negative lookahead) so we never mint a bogus "Dartastic Labs" from
  // an upstream mark reference; the deliberate AGPL attribution — which DOES
  // say "Grafana® … Grafana Labs" — lives in #dartastic-agpl-footer, which
  // every walker below skips. Case-sensitive so functional lowercase
  // identifiers (grafana.com, grafana_folder, datasource type "loki"/"tempo")
  // are never touched — only visible capitalised prose marks.
  const MARK_MAP = { Grafana: 'Dartastic', Loki: 'Logs', Mimir: 'Metrics', Tempo: 'Traces', Pyroscope: 'Profiles' };
  const MARK_RE = /\b(Grafana|Loki|Mimir|Tempo|Pyroscope)\b(?! Labs)/g;
  const ATTR_NAMES = ['alt', 'aria-label', 'title'];
  const FOOTER_SEL = '#dartastic-agpl-footer';
  const ATTR_SEL = '[' + ATTR_NAMES.join('],[') + ']';

  function inFooter(node) {
    const el = node && (node.nodeType === 1 ? node : node.parentElement);
    return !!(el && el.closest && el.closest(FOOTER_SEL));
  }

  // Exact whole-string rename first (bare "Grafana" -> the product name), then
  // the in-sentence sweep. Idempotent: re-running on the output is a no-op
  // (no "Grafana" remains), so it's safe to re-apply on every mutation.
  function rewriteString(s) {
    if (!s) return s;
    const trimmed = s.trim();
    if (trimmed && REPLACEMENTS[trimmed]) return s.replace(trimmed, REPLACEMENTS[trimmed]);
    return s.replace(MARK_RE, function (m, g1) { return MARK_MAP[g1]; });
  }

  // alt / aria-label / title on an element + its descendants.
  function rewriteAttrs(scope) {
    if (!scope || !scope.querySelectorAll) return;
    const apply = (el) => {
      if (!el.getAttribute || inFooter(el)) return;
      for (const name of ATTR_NAMES) {
        const v = el.getAttribute(name);
        if (!v) continue;
        const nv = rewriteString(v);
        if (nv !== v) el.setAttribute(name, nv);
      }
    };
    if (scope.nodeType === 1) apply(scope);
    scope.querySelectorAll(ATTR_SEL).forEach(apply);
  }

  // #187 — the alerting rules-group header renders an inline upstream flame
  // icon (svg[data-testid="icon-grafana"], FFF200->F15A29 gradient). It's a
  // React icon component, not an overridable asset. Defeat the brand-scan
  // flame signature (testid OR path-prefix OR gradient) with ATTRIBUTE-ONLY
  // edits — blank the path, neutralise the gradient stops, rename the testid.
  // No child-node removal, so React reconciliation stays safe; re-applied on
  // every observer tick like the text rewrites.
  function neutraliseFlames(scope) {
    if (!scope || !scope.querySelectorAll) return;
    const kill = (svg) => {
      svg.setAttribute('data-testid', 'icon-dartastic');
      const p = svg.querySelector('path');
      if (p) p.setAttribute('d', '');
      svg.querySelectorAll('stop').forEach((s) => s.setAttribute('stop-color', 'currentColor'));
    };
    if (scope.nodeType === 1 && scope.matches && scope.matches('svg[data-testid="icon-grafana"]')) kill(scope);
    scope.querySelectorAll('svg[data-testid="icon-grafana"]').forEach(kill);
  }

  // ===== Left-nav streamline: relocate non-essentials into "Other" =====
  // The customer box is focused on OTel/Flutter/Dart observability, so the
  // top of the MegaMenu keeps only Home + Dashboards + Explore + Drilldown.
  // Everything else (Alerting, Connections, Administration, Bookmarks, …) is
  // MOVED — not hidden, not disabled — into a collapsible "Other" group at the
  // bottom; the items keep working (we re-parent the live DOM nodes). Grafana's
  // React nav re-renders (and recreates these nodes) on navigation, so this is
  // re-applied on every observer tick; it's idempotent + self-healing.
  //
  // ⚠️ VERIFY ON UPSTREAM BUMP: this is DOM surgery on Grafana 13's MegaMenu.
  // The anchor is the top-level item <a href> set below; if Grafana renames
  // routes or restructures the nav <ul>, update OTHER_PREFIXES / the nav-list
  // lookup. Failure mode is a no-op (group just doesn't appear), never a throw.
  const OTHER_PREFIXES = ['/alerting', '/connections', '/admin', '/bookmarks'];
  const OTHER_COLLAPSE_KEY = 'dartastic.nav.other.collapsed';

  function navPath(a) {
    try { return new URL(a.href, location.origin).pathname; } catch { return ''; }
  }
  function isOtherPath(p) {
    return OTHER_PREFIXES.some((pre) => p === pre || p.startsWith(pre + '/'));
  }

  function buildOtherGroup() {
    try {
      // Anchor on the stable Dashboards item; its <ul> is the nav list.
      const dash = document.querySelector('a[href$="/dashboards"]');
      const seedLi = dash && dash.closest('li');
      const ul = seedLi && seedLi.parentElement;
      if (!ul || ul.tagName !== 'UL') return; // nav not rendered yet

      // Top-level items only (direct <li> children) whose link is an "Other".
      const directLis = Array.from(ul.children).filter((el) => el.tagName === 'LI');
      let group = ul.querySelector(':scope > li[data-dartastic-other]');
      const strays = directLis.filter((li) => {
        if (li.hasAttribute('data-dartastic-other')) return false;
        const a = li.querySelector('a[href]');
        return a && isOtherPath(navPath(a));
      });
      if (group && strays.length === 0) return; // built + nothing to move → no-op

      if (!group) {
        group = document.createElement('li');
        group.setAttribute('data-dartastic-other', '');
        const collapsed = localStorage.getItem(OTHER_COLLAPSE_KEY) !== 'false';
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'dartastic-other-toggle';
        btn.textContent = 'Other';
        btn.setAttribute('aria-expanded', String(!collapsed));
        const sub = document.createElement('ul');
        sub.className = 'dartastic-other-list';
        group.appendChild(btn);
        group.appendChild(sub);
        if (collapsed) group.classList.add('is-collapsed');
        btn.addEventListener('click', () => {
          const isCollapsed = group.classList.toggle('is-collapsed');
          btn.setAttribute('aria-expanded', String(!isCollapsed));
          try { localStorage.setItem(OTHER_COLLAPSE_KEY, String(isCollapsed)); } catch {}
        });
        ul.appendChild(group);
      }
      const sub = group.querySelector('ul.dartastic-other-list');
      for (const li of strays) sub.appendChild(li);
      ul.appendChild(group); // keep the group last
    } catch (_e) {
      // Never let nav surgery break the page; just skip this tick.
    }
  }

  // ===== AGPL §13 source-offer footer =====================================
  // §13 requires the modified program to "prominently offer all users
  // interacting with it remotely … an opportunity to receive the
  // Corresponding Source" — so the notice must stay permanently
  // discoverable; it may NOT simply time out and vanish. Compromise
  // (owner direction 2026-07-02): full-width bar for ~10s after load,
  // then collapse to a small persistent "ⓘ open source" pill that
  // re-expands on hover / focus / tap. Styles live in
  // dartastic-skin.css section 1. Built here (not body::after) so the
  // source URL is a real clickable link.
  const AGPL_COLLAPSE_AFTER_MS = 10000;
  const AGPL_REEXPAND_LINGER_MS = 600; // grace before re-collapsing on mouseleave

  function buildAgplFooter() {
    if (document.getElementById('dartastic-agpl-footer')) return;
    const bar = document.createElement('div');
    bar.id = 'dartastic-agpl-footer';
    bar.setAttribute('role', 'contentinfo');
    bar.innerHTML =
      '<span class="daf-full">This service runs modified Grafana — source: ' +
      '<a href="https://github.com/dartastic/grafana-dartastic-skin" target="_blank" rel="noopener noreferrer">' +
      'github.com/dartastic/grafana-dartastic-skin</a> · Grafana® is a trademark of Grafana Labs. ' +
      'Dartastic.io is not affiliated with, endorsed, or sponsored by Grafana Labs.</span>' +
      '<span class="daf-short" role="button" tabindex="0" aria-label="Show open-source and trademark notice">ⓘ open source</span>';

    let collapseTimer = null;
    function collapse() {
      bar.classList.add('is-collapsed');
      document.body.classList.remove('dartastic-agpl-expanded');
    }
    function expand() {
      if (collapseTimer) { clearTimeout(collapseTimer); collapseTimer = null; }
      bar.classList.remove('is-collapsed');
      document.body.classList.add('dartastic-agpl-expanded');
    }
    function scheduleCollapse(delay) {
      if (collapseTimer) clearTimeout(collapseTimer);
      collapseTimer = setTimeout(collapse, delay);
    }

    bar.addEventListener('mouseenter', expand);
    bar.addEventListener('mouseleave', () => scheduleCollapse(AGPL_REEXPAND_LINGER_MS));
    bar.addEventListener('focusin', expand);
    bar.addEventListener('focusout', () => scheduleCollapse(AGPL_REEXPAND_LINGER_MS));
    // Touch devices have no hover — tap the pill to expand.
    bar.addEventListener('click', () => {
      if (bar.classList.contains('is-collapsed')) expand();
    });
    bar.addEventListener('keydown', (e) => {
      if ((e.key === 'Enter' || e.key === ' ') && bar.classList.contains('is-collapsed')) {
        e.preventDefault();
        expand();
      }
    });

    document.body.appendChild(bar);
    document.body.classList.add('dartastic-agpl-expanded');
    scheduleCollapse(AGPL_COLLAPSE_AFTER_MS);
  }

  // Walk a subtree, replacing matching text nodes in-place.  Returns
  // the number of replacements made — useful for the smoke test.
  function rewriteSubtree(root) {
    if (!root || !root.querySelectorAll) return 0;
    let count = 0;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        return inFooter(n) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
      },
    });
    let node;
    while ((node = walker.nextNode())) {
      const nv = rewriteString(node.nodeValue);
      if (nv !== node.nodeValue) {
        node.nodeValue = nv;
        count++;
      }
    }
    rewriteAttrs(root);
    neutraliseFlames(root);
    return count;
  }

  // Rewrite document.title — Grafana 13's SPA sets this dynamically on
  // every route change to `<page> - <section> - Grafana`. The static
  // <title>Dartastic Hosted</title> we put in index.html only sticks
  // until the SPA boots and clobbers it. A regex rewrite covers both
  // standalone "Grafana" and "Grafana" inside a longer composed title.
  const TITLE_RE = /\bGrafana\b(?! Labs)/g;
  function rewriteTitle() {
    if (document.title && TITLE_RE.test(document.title)) {
      document.title = document.title.replace(TITLE_RE, 'Dartastic');
    }
  }

  function start() {
    rewriteSubtree(document.body);
    rewriteTitle();
    buildOtherGroup();
    buildAgplFooter();
    // Re-run on every DOM mutation.  Grafana's React renders heavily
    // post-load; without this the sidebar wordmark reappears the
    // first time the user opens the MegaMenu, and document.title
    // reverts to "<page> - <section> - Grafana" on every navigation.
    const observer = new MutationObserver(function (mutations) {
      let touchedTitle = false;
      for (const m of mutations) {
        // React sets alt / aria-label / title AFTER mount (e.g. the brand
        // logo, the promo drawer) — catch those attribute writes. Our own
        // setAttribute below re-fires this, but rewriteString is idempotent so
        // the value stops changing and the loop converges.
        if (m.type === 'attributes') {
          const t = m.target;
          if (t && t.nodeType === Node.ELEMENT_NODE && !inFooter(t)) {
            const v = t.getAttribute(m.attributeName);
            if (v) {
              const nv = rewriteString(v);
              if (nv !== v) t.setAttribute(m.attributeName, nv);
            }
          }
          continue;
        }
        for (const n of m.addedNodes) {
          if (n.nodeType === Node.ELEMENT_NODE) rewriteSubtree(n);
          else if (n.nodeType === Node.TEXT_NODE && !inFooter(n)) {
            const nv = rewriteString(n.nodeValue);
            if (nv !== n.nodeValue) n.nodeValue = nv;
          }
        }
        // <title> child changes show up here too — observer covers
        // <head>'s subtree.
        if (m.target && m.target.nodeName === 'TITLE') touchedTitle = true;
      }
      if (touchedTitle) rewriteTitle();
      // Re-apply the nav relocation: React recreates the MegaMenu <li>s on
      // navigation, so the moved items reappear at top-level until we move
      // them back. buildOtherGroup() is idempotent (no-op once settled).
      buildOtherGroup();
    });
    observer.observe(document.body, {
      childList: true, subtree: true,
      attributes: true, attributeFilter: ATTR_NAMES,
    });
    // Separate observer for <head> so document.title changes fire.
    if (document.head) {
      new MutationObserver(rewriteTitle).observe(document.head, {
        childList: true, subtree: true, characterData: true,
      });
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
