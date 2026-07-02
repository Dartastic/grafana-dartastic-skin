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
  };

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
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    let node;
    while ((node = walker.nextNode())) {
      const trimmed = node.nodeValue && node.nodeValue.trim();
      if (REPLACEMENTS[trimmed]) {
        node.nodeValue = node.nodeValue.replace(trimmed, REPLACEMENTS[trimmed]);
        count++;
      }
    }
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
        for (const n of m.addedNodes) {
          if (n.nodeType === Node.ELEMENT_NODE) rewriteSubtree(n);
          else if (n.nodeType === Node.TEXT_NODE) {
            const trimmed = n.nodeValue && n.nodeValue.trim();
            if (REPLACEMENTS[trimmed]) {
              n.nodeValue = n.nodeValue.replace(trimmed, REPLACEMENTS[trimmed]);
            }
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
    observer.observe(document.body, { childList: true, subtree: true });
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
