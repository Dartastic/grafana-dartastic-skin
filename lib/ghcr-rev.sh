#!/usr/bin/env bash
# Shared GHCR tag logic for the skin builds (build-and-push.sh,
# build-grafana-skinned.sh). Sourced, not executed.
#
# WHY THIS FILE EXISTS
#
# The skin tag is <upstream>-d<rev>. Picking <rev> wrong doesn't error — it
# REPUBLISHES AN EXISTING TAG IN PLACE, silently replacing an image someone
# else's box or compose file may be pinning. That has now happened three times,
# each from a different root cause, all of them a fallback:
#
#   1. 2026-07-05 — discovery queried the pre-migration `dartastic` namespace
#      while pushing to `dartastic-io`; the tag list came back denied and the
#      "no tags => rev 1" fallback rebuilt d1 in place.
#   2. 2026-07-13 — Doppler names the GHCR secret GHCR_DEPLOY_PAT; both scripts
#      read CR_PAT/GHCR_PAT. So the DOCUMENTED local path (doppler run -- ...)
#      could never authenticate, discovery always failed, and the same rev-1
#      fallback overwrote d1 again.
#   3. 2026-07-13 — with discovery broken, the operator passed SKIN_REV by hand,
#      reading the "current" rev off the compose pin (d14). But CI pushes a rev
#      on every merge to main, so GHCR was already at d17. SKIN_REV=15 clobbered
#      a real CI image.
#
# The lesson is not "compute the rev more carefully." It is that a rev is a
# GUESS until the registry confirms it's free. So:
#
#   - Every discovery failure is FATAL. No fallback rev, ever. (#1, #2)
#   - The computed tag is checked against the registry before the build, and an
#     already-taken tag ABORTS — no matter how the rev was chosen, discovered or
#     hand-passed. That is the invariant that catches all three, including the
#     class where a human is confidently wrong. (#3)
#
# The registry is the only source of truth for "what rev is next" — never the
# compose pin, which lags CI by design (humans promote pins deliberately).

# Credential chain. GHCR_DEPLOY_PAT is what Doppler (hosted/prd) actually calls
# it — the name the scripts spent months not reading. CR_PAT is what CI injects
# (secrets.GITHUB_TOKEN in build-skin.yml). Both are supported on purpose; add a
# name here rather than teaching a caller to re-export.
ghcr_pat() { echo "${GHCR_DEPLOY_PAT:-${CR_PAT:-${GHCR_PAT:-}}}"; }

# Mint a pull-scoped bearer token for $ns/$image. FATAL if creds are missing or
# the mint fails — a caller that can't read the registry cannot safely pick a
# tag, so there is nothing to degrade to.
ghcr_token() {
  local ns="$1" image="$2"
  local user="${GHCR_USER:-}" pat
  pat="$(ghcr_pat)"

  if [[ -z "$user" || -z "$pat" ]]; then
    cat >&2 <<EOF
FATAL: no GHCR credentials — cannot determine which tags already exist, and
       this script will not guess a rev (guessing overwrites live images).
       Set GHCR_USER + GHCR_DEPLOY_PAT, or run under Doppler, which has both:
         doppler run -p hosted -c prd -- \$0
EOF
    return 1
  fi

  local token
  token=$(curl -sS --max-time 10 -u "${user}:${pat}" \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:${ns}/${image}:pull" \
    2>/dev/null | jq -r '.token // empty')

  if [[ -z "$token" ]]; then
    echo "FATAL: GHCR token mint failed for ${ns}/${image} with creds set." >&2
    echo "       Check the PAT's scope (needs read:packages)." >&2
    return 1
  fi
  echo "$token"
}

# Echo the image's tag list, one per line. FATAL if the response isn't a tag
# array — a denied/errored body ({"errors":[...]}) has no .tags, and treating
# that as "no tags exist" is exactly how root cause #1 overwrote d1.
ghcr_tags() {
  local ns="$1" image="$2" token="$3"
  local body
  body=$(curl -sS --max-time 10 -H "Authorization: Bearer $token" \
    "https://ghcr.io/v2/${ns}/${image}/tags/list" 2>/dev/null || echo '{}')

  # A package that doesn't exist yet (the first-ever build of an image) answers
  # NAME_UNKNOWN with no `.tags` array. That is an unambiguous "zero tags", NOT
  # an unreadable response — return empty so a first build proceeds:
  # assert-image-tag-free sees the tag as free, and ghcr_next_skin_rev still
  # refuses to guess (its own empty-tags guard fatals with "pass SKIN_REV=1").
  # Any OTHER non-array body (auth failure, malformed, network) stays fatal —
  # guessing there is exactly the rev-1-fallback bug this file guards against.
  if jq -e '(.errors // [])[] | select(.code == "NAME_UNKNOWN")' \
       >/dev/null 2>&1 <<<"$body"; then
    return 0
  fi

  if ! jq -e '.tags | type == "array"' >/dev/null 2>&1 <<<"$body"; then
    echo "FATAL: GHCR tag list for ${ns}/${image} unusable — refusing to guess." >&2
    echo "       If this is the first-ever build of this image, pass SKIN_REV=1." >&2
    echo "       Response: $(head -c 300 <<<"$body")" >&2
    return 1
  fi
  jq -r '.tags[]?' <<<"$body"
}

# Next rev = (highest existing <upstream>-d<N>) + 1. FATAL when no rev exists
# yet: that's either a genuine first build (say so with SKIN_REV=1) or, far more
# likely, an $upstream that parsed wrong — and silently answering "1" there is
# root cause #1. Make the operator assert it.
ghcr_next_skin_rev() {
  local upstream="$1" tags="$2"
  local max
  max=$(grep -E "^${upstream}-d[0-9]+$" <<<"$tags" \
        | sed -E "s|^${upstream}-d||" | sort -n | tail -1)

  if [[ -z "$max" ]]; then
    echo "FATAL: no existing ${upstream}-d<N> tags to increment from." >&2
    echo "       First-ever build on this upstream? Pass SKIN_REV=1 explicitly." >&2
    echo "       Otherwise UPSTREAM_TAG=${upstream} is wrong — check it." >&2
    return 1
  fi
  echo "$((max + 1))"
}

# THE INVARIANT: published tags are immutable. Abort if $tag already exists,
# however the rev was chosen. This is the one check that also catches a
# hand-passed SKIN_REV (root cause #3) — discovery hygiene alone cannot.
ghcr_assert_tag_free() {
  local ns="$1" image="$2" tag="$3" tags="$4"
  if grep -qxF "$tag" <<<"$tags"; then
    cat >&2 <<EOF
FATAL: ${ns}/${image}:${tag} already exists on GHCR. Pushing would replace it
       in place — some box or compose file may be pinning that exact tag.
       Tags are immutable here. Let discovery pick the next rev (drop SKIN_REV),
       or pass a rev that is actually free.
       Highest existing: $(grep -E -- "-d[0-9]+$" <<<"$tags" | sort -V | tail -1)
EOF
    return 1
  fi
}
