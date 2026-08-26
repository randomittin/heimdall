#!/usr/bin/env bash
#
# demo-wall-honesty.test.sh — the DECORATIVE-WALL falsifier.
#
# WHY. The presence wall is this project's hero asset and its whole pitch is that
# the people on it are REAL. bin/heimdall-seed-demo-wall populates a public demo
# team with BOTS so the site embed has something to render before the real team is
# big enough to fill it — which means every render of that team is a claim about
# adoption that did not happen, unless it is labelled where a reader can see it.
#
# This repo has already been bitten here: launch-docs/assets/wall.* depict five
# invented teammates and name a source path that never existed.
# test/asset-provenance-gate.test.sh now blocks fixture assets from reader-facing
# surfaces — but it scans $REPO/site, and the site is a SEPARATE repo, so it cannot
# see the embed at all. THIS gate covers that blind spot.
#
# EXECUTION, NOT INSPECTION. The assertions load the SHIPPED inline script out of
# the site's team.html and run it under a DOM double, then drive the real render
# functions with the REAL output of a real seeder dry-run. Nothing here is a
# paraphrase of the embed: if the shipped code stops labelling, this goes RED.
#
# Guarantees:
#   A. THE SEEDER PRODUCES A LABELLABLE ROSTER — a dry-run against a local CP
#      profile round-trips through the real GET /roster-team handler, and every row
#      it returns carries the bot prefix. A row without one would render as a human.
#   B. THE DATA FLOOR HOLDS — the seeded rows invent nothing beyond what a row needs
#      to render: the verdict is the weakest of the four (claiming `pass` would
#      fabricate a proof) and `file` is a self-describing literal, never a
#      plausible-looking repo path (the wall.json sin).
#   C. STAGED, NEVER LIVE-BY-DEFAULT — --live without the exact confirmation phrase
#      is REFUSED, and a dry-run leaves the real ~/.heimdall untouched.
#   D. THE EMBED LABELS THE DEMO WALL, VISIBLY — the banner's words survive stripping
#      every HTML comment and every attribute, so a label that retreated into alt
#      text or a comment does NOT count.
#   E. THE LABEL MEANS SOMETHING — a real-looking roster renders with NO banner, so
#      the assertion cannot be satisfied by labelling everything unconditionally.
#   F. FAIL-SAFE BY ROW — one bot in a NON-demo project still labels the whole wall.
#      Keying on the project id alone would let a stray bot pass as a teammate.
#   G. THE DEGRADE IS WIRED — an empty roster AND an unreachable control plane both
#      render the static fallback rather than a blank wall, and the image they point
#      at actually exists in the site repo.
#   H. THE FALLBACK IS DECLARED AND HONEST — byte-identical to the copy declared in
#      launch-docs/assets/provenance.json, declared `fixture` and never `real`, and
#      carrying no teammate / verdict / count claim.
#   I. NO DRIFT — the prefix and project id the seeder stamps are the exact strings
#      the embed labels off. Divergence silently un-labels the wall, so it is a
#      failure here rather than a surprise in production.
#
# Usage:  test/demo-wall-honesty.test.sh
#   env:  HEIMDALL_SITE_DIR  path to the heimdall-site checkout (auto-located)
#
# Exit 0 = a demo roster cannot reach a reader unlabelled.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
SEEDER="$REPO/bin/heimdall-seed-demo-wall"
MANIFEST="$REPO/launch-docs/assets/provenance.json"
ASSET="$REPO/launch-docs/assets/wall-fallback.gif"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# Bound every subprocess: macOS has no timeout(1), and a hung seeder must fail the
# gate rather than hang CI.
run() { perl -e 'alarm shift; exec @ARGV' "$@"; }

# Portable path stamp: mtime + size, BSD stat then GNU stat (mirrors
# test/checkpoint-autosave.test.sh:55's mtime_of()), falling back to a zeroed
# stamp — never a silent drop — so a file that vanishes between find and stat
# still shows up as a changed line instead of disappearing invisibly.
stamp_of() { stat -f '%N %m %z' "$1" 2>/dev/null || stat -c '%n %Y %s' "$1" 2>/dev/null || printf '%s 0 0\n' "$1"; }

# Full recursive (path, mtime, size) snapshot of the real ~/.heimdall, used by
# C3 below instead of a bare top-directory mtime compare.
#
# WHY A DIRECTORY-MTIME COMPARE IS NOT ENOUGH: this machine's live statusline
# (refreshInterval: 2s in the operator's Claude Code settings) and its hooks
# are entirely unrelated to this seeder, yet both legitimately write under the
# real ~/.heimdall on their own schedule:
#   - sentinels/hmd-statusline.py's persist_rate_limits() writes
#     ~/.heimdall/rate-limits.json via tmp+os.replace() on every render.
#   - the PreToolUse ctx-meter hook writes ~/.heimdall/ctx/<session-id>.json
#     on every tool call (bin/heimdall-ctx-meter notice).
#   - the statusline's throttled presence beat drives bin/heimdall-status-json,
#     which writes ~/.heimdall/ledger/status.json via the same tmp+rename
#     pattern (opposite tmp-name order: <path>.tmp.<pid> vs rate-limits'
#     <path>.<pid>.tmp).
# A tmp+rename INSIDE a directory bumps that directory's OWN mtime too (not
# just the file's) — so a bare `ls -lTd ~/.heimdall` before/after false-
# positived on all three, none of which have anything to do with the seeder
# (confirmed by grep: none of these paths appear anywhere in
# bin/heimdall-seed-demo-wall).
#
# THE FIX IS A FULL SNAPSHOT DIFF, NOT A LOOSER CHECK: this walks every path
# under ~/.heimdall and stamps each one — STRICTLY MORE sensitive than the old
# check (a write to ANY file anywhere in the tree now fails C3, including an
# in-place content overwrite with no rename at all, which the old directory-
# mtime compare would have missed entirely) except for the three writers named
# above, excluded BY EXACT PATH — never a wildcarded directory — so a genuine
# escape into a sibling file, even right next to rate-limits.json or inside
# ledger/, still fails the gate. ctx/ is the one subtree excluded wholesale,
# because it is inherently dynamic (a new file per Claude Code session, not a
# fixed name) — it is independently hook-driven and the seeder never
# references it either.
home_heimdall_snapshot() {
  [ -d "$HOME/.heimdall" ] || return 0
  local rl="$HOME/.heimdall/rate-limits.json"
  local lg="$HOME/.heimdall/ledger/status.json"
  local lgdir="$HOME/.heimdall/ledger"
  local ctx="$HOME/.heimdall/ctx"
  find "$HOME/.heimdall" -mindepth 1 2>/dev/null | sort | while IFS= read -r f; do
    case "$f" in
      "$rl"|"$rl".*.tmp) continue ;;  # statusline rate-limit persister
      "$lg"|"$lg".tmp.*) continue ;;  # heimdall-status-json persister
      "$lgdir") continue ;;           # the rename above also bumps ledger/'s own mtime
      "$ctx"|"$ctx"/*) continue ;;    # per-session ctx-meter hook writes
    esac
    stamp_of "$f"
  done
}

NODE="$(command -v node || true)"
PY="$(command -v python3 || command -v python || true)"
JQ="$(command -v jq || true)"
[ -n "$NODE" ] || { echo "FATAL: node not found (needed to execute the shipped embed)" >&2; exit 2; }
[ -n "$PY" ]   || { echo "FATAL: python3 not found" >&2; exit 2; }
[ -n "$JQ" ]   || { echo "FATAL: jq not found" >&2; exit 2; }
[ -x "$SEEDER" ] || { echo "FATAL: $SEEDER missing or not executable" >&2; exit 2; }

# ── locate the site checkout ──────────────────────────────────────────────────
# FAIL-CLOSED: a site we cannot find must fail loudly. A gate that silently passes
# because it checked nothing is worse than no gate (mirrors the provenance gate's
# anti-vacuous guard).
SITE_DIR="${HEIMDALL_SITE_DIR:-}"
if [ -z "$SITE_DIR" ]; then
  for cand in "$REPO/../heimdall-site" "$REPO/../../heimdall-site" \
              "$REPO/../../../heimdall-site" "$REPO/../../../../heimdall-site" \
              "$HOME/Downloads/heimdall-site"; do
    if [ -f "$cand/team.html" ]; then SITE_DIR="$(cd "$cand" && pwd)"; break; fi
  done
fi
TEAM_HTML="$SITE_DIR/team.html"

TMP="$(mktemp -d -t demo-wall-honesty)"
trap 'rm -rf "$TMP"' EXIT

echo "demo-wall-honesty harness  repo=$REPO"
echo "                           site=${SITE_DIR:-<NOT FOUND>}"
echo "--------------------------------------------------------------------"

if [ -n "$SITE_DIR" ] && [ -f "$TEAM_HTML" ]; then
  ok "located the site embed (team.html) — the gate has a surface to check"
else
  bad "could NOT locate heimdall-site/team.html — set \$HEIMDALL_SITE_DIR (refusing to pass vacuously)"
  echo "--------------------------------------------------------------------"
  printf 'demo-wall-honesty: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# A/B. THE SEEDER — a dry-run against a local CP profile, round-tripped through the
#      real GET /roster-team handler.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "A/B. seeder dry-run against a local CP profile (no network, no live write)"

ROSTER="$TMP/roster.json"
if run 120 bash "$SEEDER" --count 5 --json > "$ROSTER" 2>"$TMP/seed.err"; then
  ok "A1 dry-run exits 0 against a local CP profile (no network)"
else
  bad "A1 dry-run failed (rc=$?): $(tail -3 "$TMP/seed.err" 2>/dev/null)"
fi

N_ROWS="$($JQ -r '(.online // []) | length' "$ROSTER" 2>/dev/null || echo 0)"
[ "$N_ROWS" = "5" ] \
  && ok "A2 the read-back returns 5 rows in the CP wire shape (project + online[])" \
  || bad "A2 expected 5 rows from the read-back, got '$N_ROWS'"

SEED_PREFIX="$(sed -n 's/^DEMO_HANDLE_PREFIX="\(.*\)"$/\1/p' "$SEEDER" | head -1)"
SEED_PROJECT="$(sed -n 's/^DEMO_PROJECT_DEFAULT="\(.*\)"$/\1/p' "$SEEDER" | head -1)"
[ -n "$SEED_PREFIX" ] \
  && ok "A3 the seeder declares its handle prefix ('$SEED_PREFIX') as a single source of truth" \
  || bad "A3 could not read DEMO_HANDLE_PREFIX out of the seeder"

UNPREFIXED="$($JQ -r --arg p "$SEED_PREFIX" \
  '[(.online // [])[] | select((.handle // "") | startswith($p) | not)] | length' "$ROSTER" 2>/dev/null || echo -1)"
[ "$UNPREFIXED" = "0" ] \
  && ok "A4 every seeded row carries the bot prefix — none can render as a human" \
  || bad "A4 $UNPREFIXED seeded row(s) lack the '$SEED_PREFIX' prefix and would pass as teammates"

# THE DATA FLOOR. `pass` would assert a proof that never happened; a repo-looking
# path is exactly what made wall.json dishonest (it named src/auth/session.ts).
NON_WATCHING="$($JQ -r '[(.online // [])[] | select((.verdict // "") != "watching")] | length' "$ROSTER" 2>/dev/null || echo -1)"
[ "$NON_WATCHING" = "0" ] \
  && ok "B1 every seeded verdict is 'watching' — no bot claims a proof it never ran" \
  || bad "B1 $NON_WATCHING seeded row(s) claim a verdict stronger than 'watching'"

PATHY="$($JQ -r '[(.online // [])[] | select((.file // "") | test("^[A-Za-z0-9_.-]+/|\\.(ts|js|py|sh|go|rs|md)$"))] | length' "$ROSTER" 2>/dev/null || echo -1)"
[ "$PATHY" = "0" ] \
  && ok "B2 no seeded 'file' looks like a source path — the wall.json sin is not repeated" \
  || bad "B2 $PATHY seeded row(s) name a plausible-looking source path"

# ──────────────────────────────────────────────────────────────────────────────
# C. STAGED, NEVER LIVE-BY-DEFAULT.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "C. staged-only: live demands an explicit phrase; dry-run never touches ~/.heimdall"

LIVE_OUT="$TMP/live.out"
if run 60 bash "$SEEDER" --live --count 2 >"$LIVE_OUT" 2>&1; then
  bad "C1 --live RAN without the confirmation phrase — live-by-default is reachable"
else
  ok "C1 --live without the confirmation phrase is REFUSED (nonzero exit)"
fi
grep -q 'HEIMDALL_SEED_LIVE_CONFIRM' "$LIVE_OUT" 2>/dev/null \
  && ok "C2 the refusal names the exact opt-in, so going live is deliberate not discovered" \
  || bad "C2 the refusal does not name \$HEIMDALL_SEED_LIVE_CONFIRM"

# The real presence state must be untouched by any exercise above. Snapshot
# every path under ~/.heimdall (see home_heimdall_snapshot() above for why a
# bare directory-mtime compare is not enough on this machine).
HOME_STAMP_BEFORE="$(home_heimdall_snapshot)"
run 120 bash "$SEEDER" --count 3 >/dev/null 2>&1
HOME_STAMP_AFTER="$(home_heimdall_snapshot)"
[ "$HOME_STAMP_BEFORE" = "$HOME_STAMP_AFTER" ] \
  && ok "C3 a dry-run leaves the real ~/.heimdall untouched (full recursive snapshot)" \
  || bad "C3 the real ~/.heimdall was modified by a dry-run: $(diff <(printf '%s' "$HOME_STAMP_BEFORE") <(printf '%s' "$HOME_STAMP_AFTER"))"

if [ -d "$HOME/.heimdall" ] && grep -rqs "$SEED_PROJECT" "$HOME/.heimdall" 2>/dev/null; then
  bad "C4 the demo project '$SEED_PROJECT' leaked into the real ~/.heimdall"
else
  ok "C4 the demo project id appears nowhere under the real ~/.heimdall (sandbox held)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# D-G. THE EMBED — the shipped script, executed.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "D-G. the shipped embed, executed under a DOM double against the real roster"

cat >"$TMP/harness.js" <<'JSEOF'
// Load the SHIPPED inline <script> out of team.html and run it under a minimal but
// REAL DOM double, so the assertions drive production code rather than a copy of it.
const fs = require('fs');

const html = fs.readFileSync(process.env.TEAM_HTML, 'utf8');
const blocks = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
const src = blocks.find(b => b.includes('function renderRoster'));
if (!src) { console.error('HARNESS: no inline <script> defining renderRoster'); process.exit(2); }

function makeEl(id){
  return {
    id, value: '', innerHTML: '', className: '', textContent: '', checked: false,
    content: '', style: {}, attrs: {}, listeners: {}, focused: false,
    setAttribute(k, v){ this.attrs[k] = v; },
    getAttribute(k){ return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; },
    addEventListener(t, fn){ (this.listeners[t] = this.listeners[t] || []).push(fn); },
    removeEventListener(t, fn){
      const L = this.listeners[t] || [];
      const i = L.indexOf(fn);
      if (i >= 0) L.splice(i, 1);
    },
    focus(){ this.focused = true; },
    querySelector(){ return makeEl('child'); },
  };
}

const nodes = Object.create(null);
const documentDouble = {
  hidden: false,
  listeners: {},
  // The <html> root. The shipped theme block reads and writes data-theme on it at
  // load time, BEFORE renderRoster is ever defined — so a double without a
  // documentElement kills the whole script at syncIcon() and every downstream
  // assertion then reads an empty render, reporting drift that does not exist.
  documentElement: makeEl('html'),
  getElementById(id){ return nodes[id] || (nodes[id] = makeEl(id)); },
  querySelector(sel){
    // The only real query the embed makes is the pinned version <meta>.
    if (String(sel).includes('heimdall-version')) return { content: 'v0.0.0-harness' };
    return nodes[sel] || (nodes[sel] = makeEl(sel));
  },
  querySelectorAll(){ return []; },
  addEventListener(t, fn){ (this.listeners[t] = this.listeners[t] || []).push(fn); },
  createElement(tag){ return makeEl(tag); },
};

const windowDouble = {
  listeners: {},
  addEventListener(t, fn){ (this.listeners[t] = this.listeners[t] || []).push(fn); },
};

const store = new Map();
const localStorageDouble = {
  getItem(k){ return store.has(k) ? store.get(k) : null; },
  setItem(k, v){ store.set(k, String(v)); },
  removeItem(k){ store.delete(k); },
};

// The embed must never reach the network inside this harness. Any call is recorded
// and rejected, which is also how the UNREACHABLE degrade is driven below.
const fetchCalls = [];
function fetchDouble(url, opts){
  fetchCalls.push({ url, opts });
  return Promise.reject(new Error('harness: network is disabled'));
}

// Timers are recorded rather than scheduled, so node exits instead of polling.
const timers = [];
function setIntervalDouble(fn, ms){ timers.push({ fn, ms }); return timers.length; }
function clearIntervalDouble(id){ if (id) timers[id - 1] = null; }

const factory = new Function(
  'window', 'document', 'localStorage', 'fetch', 'setInterval', 'clearInterval', 'navigator',
  src + `
  ;return {
    renderRoster, renderEmpty, renderError, isDemoRoster, demoBannerHTML, fallbackHTML,
    DEMO_HANDLE_PREFIX, DEMO_PROJECT_ID,
    setProject(p){ activeProject = p; },
    body(){ return rosterBody.innerHTML; }
  };`
);

const api = factory(
  windowDouble, documentDouble, localStorageDouble, fetchDouble,
  setIntervalDouble, clearIntervalDouble, { userAgent: 'harness' }
);

// VISIBLE text only: drop comments, then drop every tag WITH its attributes. A label
// that retreated into an HTML comment or an alt= attribute therefore does not count.
function visibleText(h){
  return String(h)
    .replace(/<!--[\s\S]*?-->/g, ' ')
    .replace(/<[^>]*>/g, ' ')
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/\s+/g, ' ')
    .trim();
}

const roster = JSON.parse(fs.readFileSync(process.env.ROSTER, 'utf8'));
const demoRows = roster.online || [];
const humanRows = [
  { haid: 'haid:rj.mbp-7f3a', handle: 'rj', verdict: 'pass', file: 'bin/heimdall-presence', age_seconds: 4 },
  { haid: 'haid:dana.mbp-11c2', handle: 'dana', verdict: 'working', file: 'bin/lib/cp_presence.py', age_seconds: 9 },
];

const out = {};

// D — the demo roster, rendered through the real renderRoster.
api.setProject(roster.project || 'heimdall-demo-wall');
api.renderRoster(demoRows);
out.demo_html = api.body();
out.demo_visible = visibleText(out.demo_html);

// E — a real-looking roster in a normal project must NOT be labelled.
api.setProject('acme/widget');
api.renderRoster(humanRows);
out.human_html = api.body();
out.human_visible = visibleText(out.human_html);

// F — ONE bot inside a NON-demo project must still label the whole wall.
api.setProject('acme/widget');
api.renderRoster([humanRows[0], demoRows[0]]);
out.mixed_html = api.body();
out.mixed_visible = visibleText(out.mixed_html);

// G — both degrade paths.
api.renderEmpty();
out.empty_html = api.body();
api.renderError();
out.error_html = api.body();

// The roster read must have been attempted over the wire, never faked locally.
out.demo_row_count = demoRows.length;
out.prefix = api.DEMO_HANDLE_PREFIX;
out.project_id = api.DEMO_PROJECT_ID;
out.fallback_html = api.fallbackHTML();
out.is_demo_by_project = api.isDemoRoster('heimdall-demo-wall', []);
out.is_demo_by_row = api.isDemoRoster('acme/widget', [demoRows[0]]);
out.is_demo_human = api.isDemoRoster('acme/widget', humanRows);

process.stdout.write(JSON.stringify(out, null, 2));
JSEOF

if TEAM_HTML="$TEAM_HTML" ROSTER="$ROSTER" run 60 "$NODE" "$TMP/harness.js" > "$TMP/render.json" 2>"$TMP/render.err"; then
  ok "D1 the shipped team.html script loads and exposes the honesty seam"
else
  bad "D1 could not execute the shipped embed: $(tail -5 "$TMP/render.err" 2>/dev/null)"
fi

rget() { $JQ -r "$1" "$TMP/render.json" 2>/dev/null; }

DEMO_VIS="$(rget '.demo_visible')"
case "$DEMO_VIS" in
  *"not teammates"*|*"not real"*|*"bots"*)
    ok "D2 the demo roster renders a VISIBLE label naming the rows as bots, not teammates" ;;
  *) bad "D2 the demo roster rendered with NO visible demo label. visible text: ${DEMO_VIS:0:200}" ;;
esac

case "$DEMO_VIS" in
  *"Demo wall"*) ok "D3 the label leads with 'Demo wall' — a reader sees it, not a footnote" ;;
  *) bad "D3 the visible text carries no 'Demo wall' heading" ;;
esac

# The rows must actually be on the page — a gate that passed because nothing
# rendered would be vacuous.
case "$DEMO_VIS" in
  *"demo-bot-01"*) ok "D4 the demo rows really rendered (the label is not covering an empty wall)" ;;
  *) bad "D4 no demo row rendered — the label assertion would be vacuous" ;;
esac

[ "$(rget '.is_demo_by_project')" = "true" ] \
  && ok "D5 isDemoRoster() flags the demo project id" \
  || bad "D5 isDemoRoster() does not flag the demo project id"

# E — the label must MEAN something.
HUMAN_VIS="$(rget '.human_visible')"
# ANTI-VACUOUS. "carries no banner" is trivially true of an empty render, so the
# human rows must be ON the page for their lack of a banner to mean anything —
# the D4 guard, applied to the negative case.
case "$HUMAN_VIS" in
  *"Demo wall"*|*"not teammates"*)
    bad "E1 a REAL-looking roster was labelled a demo — the label is unconditional and meaningless" ;;
  *"haid:rj.mbp-7f3a"*)
    ok "E1 a real-looking roster renders with NO demo banner — the label discriminates" ;;
  *)
    bad "E1 the real-looking roster did not render at all — the 'no banner' check would be vacuous. visible text: ${HUMAN_VIS:0:200}" ;;
esac
[ "$(rget '.is_demo_human')" = "false" ] \
  && ok "E2 isDemoRoster() returns false for an all-human roster (no false positive)" \
  || bad "E2 isDemoRoster() flagged an all-human roster"

# F — fail-safe by row.
MIXED_VIS="$(rget '.mixed_visible')"
case "$MIXED_VIS" in
  *"Demo wall"*) ok "F1 ONE bot in a non-demo project still labels the whole wall (fail-safe by row)" ;;
  *) bad "F1 a bot inside a non-demo project rendered UNLABELLED alongside a real teammate" ;;
esac
[ "$(rget '.is_demo_by_row')" = "true" ] \
  && ok "F2 isDemoRoster() flags a single bot row regardless of project" \
  || bad "F2 isDemoRoster() missed a bot row in a non-demo project"

# G — the degrade paths.
FALLBACK_SRC="$(rget '.fallback_html' | sed -n 's/.*src="\([^"]*\)".*/\1/p')"
EMPTY_HTML="$(rget '.empty_html')"
ERROR_HTML="$(rget '.error_html')"
# ANTI-VACUOUS. An empty $FALLBACK_SRC collapses the two patterns below to *""*,
# which matches every string — including the empty render of an embed that failed
# to load. Both degrade checks would then pass having compared nothing at all.
if [ -z "$FALLBACK_SRC" ]; then
  bad "G1 fallbackHTML() names no image src — the empty-roster degrade cannot be verified"
  bad "G2 fallbackHTML() names no image src — the unreachable degrade cannot be verified"
  bad "G3 the embed points at no file at all"
else
  case "$EMPTY_HTML" in
    *"$FALLBACK_SRC"*) ok "G1 an EMPTY roster degrades to the static fallback, not a blank wall" ;;
    *) bad "G1 the empty-roster state does not render the fallback image" ;;
  esac
  case "$ERROR_HTML" in
    *"$FALLBACK_SRC"*) ok "G2 an UNREACHABLE control plane degrades to the static fallback" ;;
    *) bad "G2 the unreachable state does not render the fallback image" ;;
  esac
  if [ -f "$SITE_DIR/$FALLBACK_SRC" ]; then
    ok "G3 the fallback the embed points at ($FALLBACK_SRC) exists in the site repo"
  else
    bad "G3 the embed points at '$FALLBACK_SRC', which is not a file in the site repo"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# H. THE FALLBACK ASSET — declared, honest, and not drifted.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "H. the fallback asset is declared fixture, honest, and identical across repos"

# Each failure mode reports its OWN cause. Collapsing "declared copy missing",
# "embed names nothing", "served copy missing" and "the bytes differ" into a single
# `differ` verdict makes this gate cry drift that never happened — which is exactly
# what it did while the two files were in fact byte-identical. An assertion has to
# say the true thing when it fails, or it sends the next reader to fix the wrong bug.
ASSET_SUM=""; SERVED_SUM=""; SERVED=""
[ -f "$ASSET" ] && ASSET_SUM="$(shasum -a 256 "$ASSET" | awk '{print $1}')"
if [ -n "$FALLBACK_SRC" ]; then
  SERVED="$SITE_DIR/$FALLBACK_SRC"
  [ -f "$SERVED" ] && SERVED_SUM="$(shasum -a 256 "$SERVED" | awk '{print $1}')"
fi
if [ -z "$ASSET_SUM" ]; then
  bad "H1 the provenance-declared copy does not exist: $ASSET"
elif [ -z "$FALLBACK_SRC" ]; then
  bad "H1 the embed names no fallback image, so there is nothing to compare against $ASSET"
elif [ -z "$SERVED_SUM" ]; then
  bad "H1 the embed points at '$FALLBACK_SRC', which the site repo does not serve ($SERVED)"
elif [ "$ASSET_SUM" != "$SERVED_SUM" ]; then
  bad "H1 served '$FALLBACK_SRC' ($SERVED_SUM) != declared $(basename "$ASSET") ($ASSET_SUM) — provenance does not describe what ships"
else
  ok "H1 the served copy is byte-identical to the provenance-declared copy (${ASSET_SUM:0:12}…)"
fi

ASSET_PROV="$($JQ -r --arg f "$(basename "$ASSET")" \
  '(.assets // [])[] | select(.file == $f) | .provenance' "$MANIFEST" 2>/dev/null)"
[ "$ASSET_PROV" = "fixture" ] \
  && ok "H2 the fallback is declared 'fixture' in provenance.json (never 'real')" \
  || bad "H2 the fallback's declared provenance is '$ASSET_PROV', expected 'fixture'"

# The image itself must carry no teammate/verdict/count claim. Its pixels are
# defined ONLY by the generator, so the generator is the thing to interrogate.
GEN_BLOCK="$(sed -n '/the static fallback GIF/,/^fi$/p' "$SEEDER")"
if grep -Eqi 'merges|proven|arjun|kai|maya|nadia|priya|teammates online|watchmen' <<<"$GEN_BLOCK"; then
  bad "H3 the fallback generator renders a teammate/verdict/count claim"
else
  ok "H3 the fallback generator renders no teammate, verdict or count — nothing to fabricate"
fi

# ──────────────────────────────────────────────────────────────────────────────
# I. NO DRIFT between the seeder's stamp and the embed's label trigger.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "I. the seeder's stamp and the embed's trigger are the same strings"

EMBED_PREFIX="$(rget '.prefix')"
EMBED_PROJECT="$(rget '.project_id')"
[ -n "$SEED_PREFIX" ] && [ "$SEED_PREFIX" = "$EMBED_PREFIX" ] \
  && ok "I1 handle prefix matches across seeder and embed ('$SEED_PREFIX')" \
  || bad "I1 prefix DRIFT: seeder='$SEED_PREFIX' embed='$EMBED_PREFIX' — the wall would render unlabelled"
[ -n "$SEED_PROJECT" ] && [ "$SEED_PROJECT" = "$EMBED_PROJECT" ] \
  && ok "I2 demo project id matches across seeder and embed ('$SEED_PROJECT')" \
  || bad "I2 project-id DRIFT: seeder='$SEED_PROJECT' embed='$EMBED_PROJECT'"

echo "--------------------------------------------------------------------"
printf 'demo-wall-honesty: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
