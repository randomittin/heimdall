#!/usr/bin/env bash
#
# version-pin-conformance.test.sh — ZERO UNMARKED HARDCODED VERSIONS.
#
#   bash test/version-pin-conformance.test.sh              # the gate
#   bash test/version-pin-conformance.test.sh --self-test  # corrupt-and-confirm proof
#   bash test/version-pin-conformance.test.sh --list       # machine-readable pin inventory
#
# test/version-drift.test.sh answers "does every surface AGREE with plugin.json?". It cannot
# answer the question that actually caused the damage: "is every surface RENDERED, or is some
# human still hand-typing the version?" A hand-typed pin agrees with the manifest on the day it
# is typed and drifts on the next bump — which is how the site simultaneously carried v2.0.16,
# v2.2.2, v2.2.6 and 2.3.3 across twelve surfaces, and how README.md ended up pinning a sha256
# that did not describe the bytes it sat next to (`shasum -c` prints FAILED, the published `&&`
# chain aborts, and the advertised install command is dead).
#
# This gate closes that class permanently. Every version pin on a published surface — the tag
# `vX.Y.Z`, the bare `X.Y.Z`, or a pinned install sha256 — must be one of:
#
#   MARKED      the line carries (or sits inside a region opened by) a HEIMDALL:PIN marker, so
#               bin/heimdall-render-version rewrites it from plugin.json at release time.
#   STRUCTURAL  the whole FIELD is machine-owned in a file with no comment syntax to mark
#               (VERSION, vercel.json, the npx wrapper's package.json, _redirects, install.sh
#               DEFAULT_REF). Not exempt on trust: each entry must name a RENDERER that still
#               rewrites the file, a version-drift ASSERTION that still checks the result, and
#               the exact LINE SHAPE it excuses — all three verified below against the real
#               files. Without the line shape the exemption would be file-wide, and a hand-typed
#               pin could hide anywhere in an otherwise-rendered file.
#
# Anything else is a hand-typed pin and this gate goes RED on it. That is the load-bearing
# assertion — it fires the moment someone adds a new hardcoded version ANYWHERE in the swept
# set, which is the only moment at which the fix is cheap.
#
# ── The marker grammar (shared with bin/heimdall-render-version) ──────────────
#   HEIMDALL:PIN:<KINDS>              governs the line it sits on
#   HEIMDALL:PIN:<KINDS>:BEGIN        opens a region  ─┐ governs every line between them
#   HEIMDALL:PIN:END                  closes it       ─┘ (and the BEGIN line itself)
#
# <KINDS> is a comma-joined subset of:
#   TAG      a `vX.Y.Z` token          -> rendered to v<manifest version>
#   VERSION  a bare `X.Y.Z` token      -> rendered to <manifest version>
#   SHA256   a pinned install digest   -> rendered to the sha256 of this tag's install.sh
#   FROZEN   deliberately NOT current  -> never rendered, never flagged
#
# The marker goes inside whatever comment syntax the file already uses (`<!-- -->`, `//`, `#`),
# so it is inert in the published artifact. The region form exists because two real surfaces
# CANNOT take an inline comment: JSON-LD inside <script type="application/ld+json"> (a comment
# there is raw text and breaks JSON.parse) and a fenced install snippet whose bytes a reader
# copies verbatim. Both get a region opened on a structurally-inert line beside them.
#
# KIND IS CHECKED, not just presence: a line holding a `vX.Y.Z` must be governed by TAG (or
# FROZEN), a bare `X.Y.Z` by VERSION, a digest by SHA256. Without that, `HEIMDALL:PIN:SHA256`
# beside a version would silently "cover" a tag the renderer never rewrites — a marker that
# lies is worse than no marker, because it reads as proof.
#
# FROZEN is the honest escape hatch for a version that genuinely is not Heimdall's and must not
# move. It exists so the gate can be SATISFIED rather than deleted: a gate with no legitimate
# way to say "this one is deliberate" gets commented out the first time it is right-but-
# inconvenient. It is explicit, greppable, and shows up in review.
#
# ── What counts as a pin ──────────────────────────────────────────────────────
# TAG/VERSION are scoped to the CURRENT manifest version, and that precision is the point. A
# semver that does NOT equal the current version is either already drifted (test/version-drift
# owns that) or a deliberate foreign/historical reference — published pages legitimately name
# other software's versions in prose (`superx v1.1.0`, the MCP contract's `v1.0.0`, the v2.0.5
# incident write-up). A semver that DOES equal the current version and is rendered by nothing is
# exactly what rots at the next bump. Sweeping every semver instead would produce a red that is
# WRONG, and a wrong red trains people to ignore the next one.
#
# SHA256 is found by SHAPE instead — a 64-hex token within DIGEST_WINDOW lines of a
# raw.githubusercontent install URL, the same discovery rule test/version-drift.test.sh uses —
# and deliberately NOT by comparing against today's digest. A digest cannot be scoped by value
# here: the working tree's install.sh changes between releases, so "the current digest" is not
# yet decided at the moment this gate runs. Shape is the durable question anyway: any digest
# published beside an install URL is a pin that must be rendered, whatever it currently says.
#
# ── Scaffolding and dated-archive exclusion ───────────────────────────────────
# Identical rule to test/version-drift.test.sh, and for the same reason: gate FIXTURES carry
# deliberately-wrong versions (v9.9.9) and deliberately-unmarked pins — including this file's
# own mutants. Pruned by DIRECTORY ROLE at traversal, never by a filename blocklist, and with
# -mindepth 1 so a checkout that happens to BE named `gates` cannot prune its own root to zero
# and pass vacuously off an empty set.
#
# Dated archives (drafts/, archive/) are pruned by that same one mechanism, for a reason set out
# in full at ARCHIVE_DIRS below: a dated changelog QUOTES a version, it does not CLAIM one, and
# rendering a quotation forges history rather than refreshing it. The exclusion is not free —
# section 2 of the gate makes it prove, every run, that what it removed really was archival.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${VERSION_PIN_REPO:-$(cd "$SELF_DIR/.." && pwd)}"

SCAFFOLDING_DIRS="test tests gates node_modules"

# ── Dated-archive exclusion ───────────────────────────────────────────────────
# A dated archive is NOT a pin, and marking one would make the renderer produce falsehoods.
#
# launch-docs/drafts/log-week-2026-08-03.md line 140 reads:
#     - chore(release): v2.3.8 (`063155f`)
# That is a verbatim quotation of commit 063155f's subject line, and the document's own preamble
# promises "each line carries the sha it was read from, so any claim here can be checked with
# `git show`". Mark it and the next bump rewrites it to `chore(release): v2.3.9 (063155f)` — a
# commit subject that never existed, attached to a real and checkable sha. Drift makes a document
# STALE; rendering history makes it LIE with a receipt attached, which is strictly worse, and it
# is the same class of error as rewriting a dated design spec to match present enforcement — a
# thing this repo has already refused to do once.
#
# A pin rots because it claims to be CURRENT. A dated changelog entry claims only that something
# happened inside a named past window, and that stays true forever. These lines trip a
# current-version sweep at all only because the week they record happens to be the week 2.3.8
# shipped: at the next release they stop matching on their own. A finding that disappears without
# anyone fixing anything was never drift — it was a temporal collision.
#
# The precedent is already here. test/version-drift.test.sh prunes .planning/ because it
# "archives design comps and incident write-ups pinned to long-dead tags (v2.0.5) — history, not
# drift". A dated weekly changelog is that same object, so it gets that same rule rather than a
# second mechanism: pruned by DIRECTORY ROLE at traversal, matched by basename, with -mindepth 1
# so a checkout that happens to BE named `drafts` cannot prune its own root to zero.
#
# DATED_DIRS is the subset that must PROVE it is dated. `drafts/` is a STAGING directory —
# things move OUT of it, and the next thing to land there could be live listing copy — so an
# undated file in it reds the gate (obligation A below). `archive/` is TERMINAL: history is the
# whole point of it, and this repo's design specs there are genuinely undated.
ARCHIVE_DIRS="drafts archive"
DATED_DIRS="drafts"

DIGEST_WINDOW=8

# ── STRUCTURAL allowlist ─────────────────────────────────────────────────────
# "<relpath>|<renderer>|<renderer code anchor>|<version-drift assertion substring>|<line ERE>"
# Five columns because fewer would make this a suppression list. A path alone means "append a
# file, silence the gate". The RENDERER + ANCHOR pair keeps the entry valid only while that
# script still names the file IN CODE; the ASSERTION column only while something still checks
# the result; the LINE ERE narrows the excuse to the exact machine-owned line, so a hand-typed
# pin added elsewhere in the same file is still caught.
#
# The ANCHOR is the quoted path expression, not the bare filename, and it is matched only on
# NON-COMMENT lines. That distinction is not pedantry — it is a hole this gate's own self-test
# found: `grep -F vercel.json release/sync-release.sh` stays satisfied by the header comment
# long after the code stopped touching the file, so the exemption would outlive the renderer it
# claims and the pin would be hand-typed again with the gate still green.
STRUCTURAL_ROWS='VERSION|bin/heimdall-render-version|"$ROOT/VERSION"|VERSION == plugin.json|^[0-9]+\.[0-9]+\.[0-9]+$
vercel.json|release/sync-release.sh|"$ROOT/vercel.json"|vercel.json /install redirect targets|"destination"[[:space:]]*:
_redirects|release/sync-release.sh|"$ROOT/_redirects"|_redirects /install targets|^/install[[:space:]]
install.sh|release/sync-release.sh|"$ROOT/install.sh"|install.sh DEFAULT_REF ==|local DEFAULT_REF=
packages/runheimdall/package.json|release/sync-release.sh|"$ROOT/packages/runheimdall/package.json"|runheimdall package.json .version|"(version|tag|installScriptUrl|sha256)"[[:space:]]*:'

# find_files <mode> <root> — see the header. published prunes dot-dirs AND scaffolding;
# candidates prunes dot-dirs only, so the sweep can REPORT what its own exclusion removed
# instead of removing it silently.
#
# The file-type predicate is declared ONCE and shared by every traversal below, so the sweep,
# the exclusion, and the exclusion's proof obligation can never disagree about what "a file" is —
# a disagreement there would be invisible and would silently shrink whichever one drifted.
PUBLISHED_TYPES=( -type f '('
  -name '*.md' -o -name '*.txt' -o -name '*.json' -o -name '*.toml'
  -o -name '*.html' -o -name '*.js' -o -name '*.sh' -o -name '*.yml' -o -name '*.yaml'
  -o -name 'VERSION' -o -name '_redirects' ')' -print )

find_files() {
  local mode="$1" root="$2"
  local fx d
  fx=( -mindepth 1 -type d '(' -name '.?*' )
  if [ "$mode" = published ]; then
    for d in $SCAFFOLDING_DIRS $ARCHIVE_DIRS; do fx+=( -o -name "$d" ); done
  fi
  fx+=( ')' -prune -o "${PUBLISHED_TYPES[@]}" )
  find "$root" "${fx[@]}" 2>/dev/null | sort
}

# find_archived <root> [dirs] — the files the archive role removed from the published set.
# Enumerated rather than forgotten. Every other exemption in this gate carries a live proof
# obligation (STRUCTURAL names a renderer, an anchor, an assertion and a line shape); an
# exclusion whose contents cannot be listed is one that cannot be checked, and would be the
# single place in this gate where "trust me" still works.
find_archived() {
  local root="$1" dirs="${2:-$ARCHIVE_DIRS}" d ad
  for d in $dirs; do
    while IFS= read -r ad; do
      [ -n "$ad" ] || continue
      find "$ad" "${PUBLISHED_TYPES[@]}" 2>/dev/null
    done <<ARCHDIRS
$(find "$root" -mindepth 1 -type d -name '.?*' -prune -o -type d -name "$d" -print 2>/dev/null)
ARCHDIRS
  done | sort -u
}

# ── The single source of truth ───────────────────────────────────────────────
# .claude-plugin/ is a dot-dir, so the manifest is pruned from the sweep by the same rule that
# prunes .git and .planning — correct here for a second reason: the manifest is the thing every
# other surface is rendered FROM, so its own version is not a pin.
MANIFEST="$REPO/.claude-plugin/plugin.json"
[ -f "$MANIFEST" ] || { printf 'version-pin-conformance: manifest missing: %s\n' "$MANIFEST" >&2; exit 1; }

read_version_field() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.version // empty' "$1" 2>/dev/null
  else
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' "$1" | head -1
  fi
}

VER="$(read_version_field "$MANIFEST")"
grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$VER" \
  || { printf 'version-pin-conformance: plugin.json .version is not semver: %s\n' "${VER:-<none>}" >&2; exit 1; }
TAG="v$VER"

# ── The sweep ────────────────────────────────────────────────────────────────
# Two passes over each file: pass 1 records the line numbers of install URLs (so a 64-hex token
# can be judged by proximity, exactly as version-drift discovers digest surfaces); pass 2 walks
# the file tracking region state and emits one record per finding:
#   OK|<loc>|<line>|<kinds>|<marker>|<text>    a governed pin whose kinds match
#   BAD|<loc>|<line>|<kinds>|<reason>|<text>   an ungoverned pin, or a kind mismatch
#   MARK|<loc>|<line>|<kinds>||                a marker (counted for the anti-vacuous guard)
#
# Written as a single-quoted awk program rather than a heredoc: bash 3.2.57 cannot parse a
# heredoc inside a command substitution, and this output is consumed through one. The version
# regexes are built inside awk from the plain version string so `-v` escape processing can
# never quietly turn `\.` into `.` and widen the match.
PIN_AWK='
BEGIN {
  verq = ver
  gsub(/\./, "\\.", verq)
  tagre = "v" verq "([^0-9.]|$)"
  verre = "([^v0-9.]|^)" verq "([^0-9.]|$)"
  hexre = "[0-9a-fA-F]{64}"
  instre = "raw\\.githubusercontent\\.com/[^/]+/heimdall/[^/]+/install\\.sh"
}
function neardigest(ln,   u, d) {
  for (u in urls) { d = ln - u; if (d < 0) d = -d; if (d <= win) return 1 }
  return 0
}
function kindsof(s, ln,   r) {
  r = ""
  if (s ~ tagre) r = r "TAG,"
  if (s ~ verre) r = r "VERSION,"
  if (s ~ hexre && neardigest(ln)) r = r "SHA256,"
  return r
}
NR == FNR { if ($0 ~ instre) urls[FNR] = 1; next }
FNR == 1 { region = 0; regionkinds = "" }
{
  line = $0
  govern = ""

  # The PRE-EXISTING generated region. bin/heimdall-render-version has owned the README badge
  # between HEIMDALL:VERSION:BEGIN/END since before this gate existed, regenerating the whole
  # block from a template rather than rewriting tokens inside it. It is therefore already a
  # rendered surface and is recognised as one, rather than made to carry a second, redundant
  # marker: two marker schemes on one line is itself a drift source.
  if (line ~ /HEIMDALL:VERSION:BEGIN/) {
    region = 1; regionkinds = "TAG,VERSION"; govern = regionkinds
    printf "MARK|%s|%d|%s||\n", loc, FNR, regionkinds
  } else if (line ~ /HEIMDALL:VERSION:END/) {
    printf "MARK|%s|%d|END||\n", loc, FNR
    region = 0; regionkinds = ""
  } else if (match(line, /HEIMDALL:PIN:[A-Z0-9,]+:BEGIN/)) {
    marker = substr(line, RSTART, RLENGTH)
    sub(/^HEIMDALL:PIN:/, "", marker); sub(/:BEGIN$/, "", marker)
    region = 1; regionkinds = marker
    printf "MARK|%s|%d|%s||\n", loc, FNR, marker
    govern = marker
  } else if (line ~ /HEIMDALL:PIN:END/) {
    printf "MARK|%s|%d|END||\n", loc, FNR
    region = 0; regionkinds = ""
  } else if (match(line, /HEIMDALL:PIN:[A-Z0-9,]+/)) {
    marker = substr(line, RSTART, RLENGTH)
    sub(/^HEIMDALL:PIN:/, "", marker)
    printf "MARK|%s|%d|%s||\n", loc, FNR, marker
    govern = marker
  } else if (region == 1) {
    govern = regionkinds
  }

  found = kindsof(line, FNR)
  if (found == "") next

  if (govern == "") { printf "BAD|%s|%d|%s|UNMARKED|%s\n", loc, FNR, found, line; next }
  if (govern ~ /FROZEN/) { printf "OK|%s|%d|%s|%s|%s\n", loc, FNR, found, govern, line; next }

  miss = ""
  n = split(found, fk, ",")
  for (i = 1; i <= n; i++) {
    if (fk[i] == "") continue
    if (govern !~ ("(^|,)" fk[i] "(,|$)")) miss = miss fk[i] ","
  }
  if (miss != "") { printf "BAD|%s|%d|%s|KIND-MISMATCH marker=%s uncovered=%s|%s\n", loc, FNR, found, govern, miss, line; next }
  printf "OK|%s|%d|%s|%s|%s\n", loc, FNR, found, govern, line
}
'

# ── Untracked-file exclusion: docs/analysis/ ──────────────────────────────────
# docs/analysis/ is this repo's own gitignored scratch space for point-in-time analysis and
# audit reports (.gitignore's own comment: "user-generated docs (research/plans/specs from
# real tasks)"). A file dropped there and never committed cannot be a published surface this
# gate needs to protect — no OTHER checkout will ever contain it, so a version or sha256
# quoted inside one, as forensic EVIDENCE in a finding rather than a claim of what ships, can
# never rot anywhere a reader could see it. Marking it would be actively wrong, for the same
# reason the dated-archive exemption below refuses to mark a changelog: the renderer would
# overwrite a quoted historical value with today's version, corrupting the finding it quoted.
#
# This is deliberately NOT folded into ARCHIVE_DIRS/DATED_DIRS below. This repo also carries
# two dozen already-TRACKED files directly under docs/analysis/ that predate the gitignore
# rule (`git ls-files docs/analysis/`), most with no ISO-dated filename — forcing DATED_DIRS'
# provenance obligation onto them would demand a field none of them have and turn this fix
# into a fresh wave of failures. Exempting the whole directory unconditionally instead (the
# SCAFFOLDING_DIRS treatment) would overshoot the other way and hide a genuine unmarked pin
# added to one of those tracked files. Commit status is the one fact that actually
# distinguishes the untracked audit report from the tracked ones, and it is exactly — and
# only — what gets checked, per file, against git's own index. It also needs no separate
# staleness proof the way the STRUCTURAL and ARCHIVE exemptions above do: git ls-files IS the
# live truth every run, not a claim about it, so there is no comment string here that can
# ever drift out of sync with reality.
untracked_in_docs_analysis() {
  local rel="$1"
  case "$rel" in
    docs/analysis/*) git -C "$REPO" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 && return 1 || return 0 ;;
    *) return 1 ;;
  esac
}

# ── ISO-dated docs/analysis/ files: quoted evidence, same rule as a DATED_DIRS changelog ──────
# The untracked check above does not cover every legitimate case: this repo also commits
# docs/analysis/ point-in-time audit reports ON PURPOSE (four-state census, cross-cli audits,
# ...), and some of those carry an ISO date in their OWN basename — same shape DATED_DIRS
# already trusts (section 2 below). A dated report QUOTES the version it ran against as of
# that date; it does not CLAIM today's. Marking it would make bin/heimdall-render-version
# overwrite that historical fact at the next bump, forging the finding it quoted — exactly the
# damage the ARCHIVE_DIRS comment above documents for a rendered changelog quote. Real-world
# trigger: docs/analysis/2026-08-22-capability-census.md:2, "**Version:** v2.4.0", a fact about
# the day of the audit, tracked in git same as any other committed analysis report.
#
# Filename-scoped, not directory-wide (SCAFFOLDING_DIRS overshoot risk, same as ARCHIVE_DIRS'
# reasoning), and using the exact basename-date glob the ARCHIVE integrity check below already
# uses, so an UNDATED tracked file (docs/analysis/INDEX.md) is untouched and still gated.
dated_in_docs_analysis() {
  local rel="$1"
  case "$rel" in
    docs/analysis/*) ;;
    *) return 1 ;;
  esac
  case "${rel##*/}" in
    *[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# sweep_root <root> <label> — print records for every published file under <root>. Relative
# paths are emitted so records are stable across the real tree and a throwaway copy.
sweep_root() {
  local root="$1" label="$2" f rel
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#$root/}"
    if [ "$label" = repo ] && untracked_in_docs_analysis "$rel"; then continue; fi
    awk -v ver="$VER" -v win="$DIGEST_WINDOW" -v loc="$label:$rel" "$PIN_AWK" "$f" "$f"
  done <<FILES
$(find_files published "$root")
FILES
}

collect_records() {
  local site="$1"
  sweep_root "$REPO" repo
  [ -d "$site" ] && sweep_root "$(cd "$site" && pwd)" site
  return 0
}

SITE_DIR="${HEIMDALL_SITE_DIR:-$REPO/../heimdall-site}"

if [ "${1:-}" = "--list" ]; then
  collect_records "$SITE_DIR"
  exit 0
fi

# ── --self-test: the corrupt-and-confirm proof ───────────────────────────────
# Every mutation happens in a `mktemp -d` throwaway copy reached through VERSION_PIN_REPO; the
# real tree is never written to. A gate that cannot demonstrate going red proves nothing.
if [ "${1:-}" = "--self-test" ]; then
  TMP="$(mktemp -d)"
  SITE_TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP" "$SITE_TMP"' EXIT

  NO_SITE="$TMP/no-site-here"
  MUT_SITE="$NO_SITE"

  SELF_VER="$VER"
  SELF_TAG="$TAG"
  # A well-formed but arbitrary digest: every mutant that plants one only needs it to be
  # 64 hex characters beside an install URL, never to describe real bytes.
  FAKE_DIGEST="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  INSTALL_URL="https://raw.githubusercontent.com/randomittin/heimdall/$SELF_TAG/install.sh"

  fresh_copy() { rm -rf "$TMP"; mkdir -p "$TMP"; cp -R "$REPO/." "$TMP/" 2>/dev/null; }
  reset_site()  { rm -rf "$SITE_TMP"; mkdir -p "$SITE_TMP"; }

  # assert_red <label> <expected-substring> — require BOTH a non-zero exit AND the SPECIFIC
  # failure the mutation should have caused. Asserting the reason rather than a pass/fail count
  # is deliberate: counts shift whenever a surface is added, which trains people to "just update
  # the number" instead of reading the failure.
  assert_red() {
    local label="$1" want="$2" out summary
    if out="$(VERSION_PIN_REPO="$TMP" HEIMDALL_SITE_DIR="$MUT_SITE" bash "$SELF_DIR/version-pin-conformance.test.sh" 2>&1)"; then
      echo "  ✗ SELF-TEST FAILED: gate stayed GREEN with $label planted" >&2
      printf '%s\n' "$out" >&2
      exit 1
    fi
    case "$out" in
      *"$want"*) ;;
      *) echo "  ✗ SELF-TEST FAILED: RED for the wrong reason with $label planted (wanted: $want)" >&2
         printf '%s\n' "$out" >&2
         exit 1 ;;
    esac
    summary="$(grep -E '^version-pin-conformance:' <<<"$out" | tail -1)"
    echo "  ✓ RED on $label — ${summary:-<no summary line>}"
  }

  assert_green() {
    local label="$1" out
    if out="$(VERSION_PIN_REPO="$TMP" HEIMDALL_SITE_DIR="$MUT_SITE" bash "$SELF_DIR/version-pin-conformance.test.sh" 2>&1)"; then
      echo "  ✓ GREEN on $label"
    else
      echo "  ✗ SELF-TEST FAILED: gate went RED on $label" >&2
      printf '%s\n' "$out" >&2
      exit 1
    fi
  }

  echo "version-pin-conformance --self-test: asserting the gate goes RED on planted drift"

  # Mutant 0 — the pristine copy must be GREEN before anything is planted, so every red below
  # is attributable to its own mutation and not to a pre-existing hole.
  fresh_copy
  assert_green "pristine copy (nothing planted)"

  # Mutant 1 — THE WHOLE POINT. A new hand-typed pin in a published doc, of the exact shape a
  # human adds when writing a new install snippet. Nothing about it is wrong TODAY; it rots at
  # the next bump, silently, which is how the site reached four different versions at once.
  fresh_copy
  printf '\nInstall the %s release from the mirror.\n' "$SELF_TAG" >> "$TMP/README.md"
  assert_red "a new hand-typed tag in README.md" "UNMARKED"

  # Mutant 2 — same class, bare X.Y.Z rather than the tag. Both shapes ship; gating one would
  # leave the other free.
  fresh_copy
  printf '\nHeimdall %s is current.\n' "$SELF_VER" >> "$TMP/README.md"
  assert_red "a new hand-typed bare version in README.md" "UNMARKED"

  # Mutant 3 — a MARKED pin is accepted. The inverted direction: without it, a gate that reds on
  # everything would look like a working proof while being useless.
  fresh_copy
  printf '\nInstall the %s release from the mirror. <!-- HEIMDALL:PIN:TAG -->\n' "$SELF_TAG" >> "$TMP/README.md"
  assert_green "the same pin, marked HEIMDALL:PIN:TAG"

  # Mutant 4 — a marker that LIES. `SHA256` beside a tag reads as proof in review, but the
  # renderer would never rewrite that token, so the pin rots exactly as if unmarked. A marker
  # whose kind does not cover what is on the line must not buy a pass.
  fresh_copy
  printf '\nInstall the %s release. <!-- HEIMDALL:PIN:SHA256 -->\n' "$SELF_TAG" >> "$TMP/README.md"
  assert_red "a marker whose kind does not cover the token on its line" "KIND-MISMATCH"

  # Mutant 5 — the region form, both directions. A region must actually govern the lines inside
  # it, and must STOP governing at its END: a region that never closed would silently cover
  # every hand-typed pin below it for the rest of the file.
  fresh_copy
  { printf '\n<!-- HEIMDALL:PIN:TAG:BEGIN -->\n'
    printf 'Install %s from the mirror.\n' "$SELF_TAG"
    printf '<!-- HEIMDALL:PIN:END -->\n'
  } >> "$TMP/README.md"
  assert_green "a pin inside a HEIMDALL:PIN:TAG:BEGIN/END region"

  printf 'And then install %s by hand.\n' "$SELF_TAG" >> "$TMP/README.md"
  assert_red "a pin AFTER the region closed" "UNMARKED"

  # Mutant 6 — the SITE, which is where this defect class did its damage. A published page is
  # swept exactly like a repo doc, and a site checkout is optional (absent must never be a red).
  fresh_copy
  reset_site
  MUT_SITE="$SITE_TMP"
  printf '<meta name="heimdall-version" content="%s">\n' "$SELF_TAG" > "$SITE_TMP/proof.html"
  assert_red "a hand-typed tag on a published site page" "UNMARKED"

  printf '<meta name="heimdall-version" content="%s"> <!-- HEIMDALL:PIN:TAG -->\n' "$SELF_TAG" > "$SITE_TMP/proof.html"
  assert_green "the same site pin, marked"

  MUT_SITE="$NO_SITE"
  assert_green "no site checkout (skipped, not failed)"

  # Mutant 7 — the DIGEST, which is the pin whose rot BREAKS the install rather than merely
  # aging it: the published `&&` chain aborts at `shasum -c` and nothing after it runs. Found by
  # shape beside an install URL, and it gets the same treatment as a version.
  fresh_copy
  reset_site
  MUT_SITE="$SITE_TMP"
  { printf 'curl -fsSL %s -o heimdall-install.sh\n' "$INSTALL_URL"
    printf 'echo "%s  heimdall-install.sh" | shasum -a 256 -c -\n' "$FAKE_DIGEST"
  } > "$SITE_TMP/proof.txt"
  assert_red "a hand-typed install digest on a published site page" "UNMARKED"

  { printf '<!-- HEIMDALL:PIN:TAG,SHA256:BEGIN -->\n'
    printf 'curl -fsSL %s -o heimdall-install.sh\n' "$INSTALL_URL"
    printf 'echo "%s  heimdall-install.sh" | shasum -a 256 -c -\n' "$FAKE_DIGEST"
    printf '<!-- HEIMDALL:PIN:END -->\n'
  } > "$SITE_TMP/proof.txt"
  assert_green "the same install snippet inside a TAG,SHA256 region"

  # Mutant 8 — the STRUCTURAL allowlist must not be a suppression list. Break the renderer that
  # a structural entry names and the entry stops being valid: the file is rendered by nothing,
  # so its pin is hand-typed again and the gate must say so.
  fresh_copy
  MUT_SITE="$NO_SITE"
  sed 's#^VERCEL="$ROOT/vercel.json"#VERCEL="$ROOT/vercel-renamed.json"#' "$TMP/release/sync-release.sh" > "$TMP/release/sync-release.sh.mut" \
    && mv "$TMP/release/sync-release.sh.mut" "$TMP/release/sync-release.sh"
  assert_red "a structural entry whose renderer no longer names it in code" "no longer names it in CODE"

  # Mutant 9 — the same, from the other end: a structural entry whose version-drift assertion is
  # gone. Rendered-but-unchecked is how the npx wrapper sat 20 patch releases stale.
  fresh_copy
  sed 's#_redirects /install targets#_redirects /install pointed at#' "$TMP/test/version-drift.test.sh" > "$TMP/test/version-drift.test.sh.mut" \
    && mv "$TMP/test/version-drift.test.sh.mut" "$TMP/test/version-drift.test.sh"
  assert_red "a structural entry whose drift assertion is gone" "no longer asserted"

  # Mutant 10 — the structural exemption is LINE-SCOPED, not file-scoped. A hand-typed pin
  # somewhere else in an otherwise-rendered file must still be caught; a file-wide excuse would
  # turn every structural entry into a blind spot the size of the whole file.
  fresh_copy
  printf '\n# mirror of the %s release\n' "$SELF_TAG" >> "$TMP/_redirects"
  assert_red "a hand-typed pin elsewhere inside a structurally-exempt file" "UNMARKED"

  # Mutant 11 — the anti-vacuous guard. Strip every pin and the sweep must FAIL for having
  # examined nothing, not sail through green off an empty set. This is the exact shape of the
  # sibling bug this repo already ate: a filter discarded every hit and the check passed
  # vacuously with a real defect planted.
  # Digests are voided alongside versions, not instead of them: a sweep still holding the
  # pinned sha256s is NOT vacuous, so stripping only the semvers would leave this mutant
  # proving nothing while looking like it proved the guard.
  fresh_copy
  while IFS= read -r vf; do
    [ -n "$vf" ] || continue
    sed -e "s#v${SELF_VER//./\\.}#vX.Y.Z#g" \
        -e "s#${SELF_VER//./\\.}#X.Y.Z#g" \
        -e "s#[0-9a-fA-F]\{64\}#DIGEST-REMOVED#g" "$vf" > "$vf.mut" \
      && mv "$vf.mut" "$vf"
  done <<VOID
$(find_files published "$TMP")
VOID
  assert_red "every version pin and digest removed from every swept file" "VACUOUS"

  # Mutant 12 — the scaffolding exclusion, both directions. A gate's own fixture holding an
  # unmarked pin must be IGNORED (a wrong red is worse than no gate)…
  fresh_copy
  reset_site
  MUT_SITE="$SITE_TMP"
  printf '<meta name="heimdall-version" content="%s"> <!-- HEIMDALL:PIN:TAG -->\n' "$SELF_TAG" > "$SITE_TMP/proof.html"
  mkdir -p "$SITE_TMP/gates"
  printf 'const LIVE_TAG = "%s";\n' "$SELF_TAG" > "$SITE_TMP/gates/copy-parity.js"
  assert_green "site gates/ fixture holding an unmarked pin (scaffolding, not a published surface)"

  # …and the exclusion must NOT be broad enough to swallow a real published file beside it.
  printf 'Install %s today.\n' "$SELF_TAG" > "$SITE_TMP/mirror.txt"
  assert_red "a real unmarked pin in a published file beside an excluded fixture" "UNMARKED"

  # Mutant 13 — the dated-archive exemption, in the direction it exists for. A weekly changelog
  # QUOTES the current tag inside a commit subject it read from git. Rendering that would forge
  # history, so the sweep must not demand a marker on it.
  fresh_copy
  MUT_SITE="$NO_SITE"
  mkdir -p "$TMP/launch-docs/drafts"
  { printf -- '---\ndate: 1999-01-01\n---\n'
    printf -- '- chore(release): %s (`deadbee`)\n' "$SELF_TAG"
  } > "$TMP/launch-docs/drafts/log-week-1999-01-01.md"
  assert_green "an unmarked tag quoted inside a DATED archive draft"

  # Mutant 14 — and the hole that exemption could have opened. An install snippet is a published
  # surface whatever directory it sits in: its digest aborts the `&&` chain at `shasum -c` when it
  # rots, which is the concrete way installs broke here twice. The archive excuse must not reach
  # it. Dated, so it can only be RED for the install-surface reason and not for the date.
  fresh_copy
  mkdir -p "$TMP/launch-docs/drafts"
  { printf -- '---\ndate: 1999-01-01\n---\n'
    printf 'curl -fsSL %s -o heimdall-install.sh\n' "$INSTALL_URL"
    printf 'echo "%s  heimdall-install.sh" | shasum -a 256 -c -\n' "$FAKE_DIGEST"
  } > "$TMP/launch-docs/drafts/install-1999-01-01.md"
  assert_red "a live install snippet parked inside an archive directory" "live install URL"

  # Mutant 15 — the other half of the same hole. `drafts/` is a STAGING directory, so the next
  # file to land in it may well be live listing copy rather than dated history. Undated means the
  # exemption does not describe it, and a human has to decide rather than inherit a pass.
  fresh_copy
  mkdir -p "$TMP/launch-docs/drafts"
  printf 'Install %s today — the listing blurb.\n' "$SELF_TAG" > "$TMP/launch-docs/drafts/listing-copy.md"
  assert_red "undated live copy parked inside the dated-archive staging directory" "undated file"

  # Mutant 16 — the exclusion must be no WIDER than the directory it names. A pin one level up,
  # outside drafts/, is an ordinary published surface and must still be caught; a prune that
  # leaked to the parent would silently exempt all of launch-docs/.
  fresh_copy
  printf 'Install %s from the mirror.\n' "$SELF_TAG" > "$TMP/launch-docs/live-listing.md"
  assert_red "a pin in the parent of an archive directory (exclusion must not widen)" "UNMARKED"

  # Mutant 17 — THE ACTUAL BUG. docs/analysis/ is this repo's own gitignored scratch space
  # (see the untracked_in_docs_analysis comment above); a file dropped there and never
  # committed is quoted EVIDENCE in an audit finding, not a claim of what ships, and it will
  # never exist in any OTHER checkout to rot in. It must not need a marker.
  fresh_copy
  MUT_SITE="$NO_SITE"
  mkdir -p "$TMP/docs/analysis"
  { printf 'Finding: repo pins %s (tag %s) as of this audit.\n' "$SELF_VER" "$SELF_TAG"
    printf 'curl -fsSL %s -o heimdall-install.sh\n' "$INSTALL_URL"
    printf 'echo "%s  heimdall-install.sh" | shasum -a 256 -c -\n' "$FAKE_DIGEST"
  } > "$TMP/docs/analysis/mock-launch-audit.md"
  assert_green "an unmarked version/tag/digest quoted in an UNTRACKED docs/analysis/ audit report"

  # Mutant 18 — the boundary. docs/analysis/ also carries real, already-TRACKED files
  # (predating the gitignore rule) that ship in every clone same as any other doc. The
  # exemption is about commit status, not the directory name, so a hand-typed pin added to
  # one of THOSE must still be caught.
  fresh_copy
  [ -f "$TMP/docs/analysis/INDEX.md" ] \
    || { echo "  ✗ SELF-TEST FAILED: fixture assumption broken — docs/analysis/INDEX.md is no longer tracked" >&2; exit 1; }
  printf '\nInstall the %s release from the mirror.\n' "$SELF_TAG" >> "$TMP/docs/analysis/INDEX.md"
  assert_red "a hand-typed tag added to an already-TRACKED docs/analysis/ file" "UNMARKED"

  # Mutant 19 — an ISO-dated docs/analysis/ file is quoted evidence EVEN WHEN TRACKED (unlike
  # Mutant 18's undated INDEX.md). Proven on an EXISTING already-tracked dated fixture, not a
  # freshly created one, so this cannot be satisfied by Mutant 17's untracked-scratch-space
  # exemption by accident — this is the dated_in_docs_analysis() branch, and only that branch.
  fresh_copy
  [ -f "$TMP/docs/analysis/2026-08-19-parallel-session-resource-audit.md" ] \
    || { echo "  ✗ SELF-TEST FAILED: fixture assumption broken — the dated docs/analysis/ fixture is no longer tracked" >&2; exit 1; }
  printf '\nHeimdall %s is current.\n' "$SELF_VER" >> "$TMP/docs/analysis/2026-08-19-parallel-session-resource-audit.md"
  assert_green "an unmarked current-version mention added to an ISO-dated, already-TRACKED docs/analysis/ file"

  echo "version-pin-conformance --self-test: PASS"
  exit 0
fi

# ── The gate ─────────────────────────────────────────────────────────────────
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "version-pin-conformance  repo=$REPO  manifest=$VER  tag=$TAG"
if [ -d "$SITE_DIR" ]; then
  echo "  site: $(cd "$SITE_DIR" && pwd)"
else
  echo "  site: SKIPPED — nothing at $SITE_DIR (set HEIMDALL_SITE_DIR to gate it)"
fi
echo "--------------------------------------------------------------------"

RECORDS="$(collect_records "$SITE_DIR")"

N_MARK="$(grep -c '^MARK|' <<<"$RECORDS" || true)"
N_OK="$(grep -c '^OK|' <<<"$RECORDS" || true)"
N_BAD="$(grep -c '^BAD|' <<<"$RECORDS" || true)"
N_FILES="$(grep -E '^(OK|BAD)\|' <<<"$RECORDS" | awk -F'|' '{print $2}' | sort -u | grep -c . || true)"

echo "  swept: $N_OK governed pin(s) + $N_BAD ungoverned across $N_FILES file(s); $N_MARK marker(s)"

# ── 1. STRUCTURAL allowlist integrity — checked BEFORE it is used to excuse anything ──
STRUCTURAL_ROWS_OK=""
STRUCT_OK=1
# The line ERE is the LAST column precisely because it may itself contain '|' (an alternation),
# and `read` hands every remaining separator to the final variable. Splitting it across fewer
# vars would truncate the ERE at its first alternation bar and silently narrow the excuse to one
# branch — an exemption quietly doing less than it claims.
while IFS='|' read -r srel srenderer sanchor sassert sline; do
  [ -n "$srel" ] || continue
  if [ ! -f "$REPO/$srel" ]; then
    bad "structural allowlist names $srel, which does not exist — remove the entry or restore the file"
    STRUCT_OK=0; continue
  fi
  if ! grep -v '^[[:space:]]*#' "$REPO/$srenderer" 2>/dev/null | grep -Fq "$sanchor"; then
    bad "structural exemption for $srel is STALE: $srenderer no longer names it in CODE (looked for $sanchor on a non-comment line). An exemption whose renderer is gone means the pin is hand-typed again — mark it, or fix the renderer"
    STRUCT_OK=0; continue
  fi
  if ! grep -Fq "$sassert" "$REPO/test/version-drift.test.sh" 2>/dev/null; then
    bad "structural exemption for $srel is STALE: its value is no longer asserted by test/version-drift.test.sh (looked for '$sassert'). Rendered-but-unchecked is how the npx wrapper sat 20 patch releases stale"
    STRUCT_OK=0; continue
  fi
  STRUCTURAL_ROWS_OK="${STRUCTURAL_ROWS_OK}repo:${srel}|${sline}
"
done <<STRUCT
$STRUCTURAL_ROWS
STRUCT
[ "$STRUCT_OK" -eq 1 ] && ok "every structural exemption is backed by a live renderer AND a live drift assertion"

# structurally_owned <loc> <line-text> — 0 when this exact line is the machine-owned one the
# allowlist excuses. File membership alone is deliberately NOT enough.
structurally_owned() {
  local loc="$1" text="$2" row rloc rere
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    rloc="${row%%|*}"; rere="${row#*|}"
    [ "$rloc" = "$loc" ] || continue
    grep -Eq "$rere" <<<"$text" && return 0
  done <<OWNED
$STRUCTURAL_ROWS_OK
OWNED
  return 1
}

# ── 2. ARCHIVE exemption integrity — checked BEFORE it is used to excuse anything ──
# The dated-archive prune is the only exclusion in this gate that removes files a HUMAN wrote and
# a reader can reach, so it is the one most able to hide a live surface. It therefore pays for
# itself with two obligations, both re-checked on every run over the exact files it removed:
#
#   A. DATED PROVENANCE. Every file under a DATED_DIRS directory must carry an ISO date — in its
#      basename, or in a date:/window:/generated: field. This is the obligation that keeps
#      `drafts/` from becoming a hole: the moment someone drops undated live copy there (a
#      listing blurb, a submission draft) the gate reds and a human has to decide, instead of the
#      file quietly inheriting an exemption written for weekly changelogs.
#   B. NO INSTALL SURFACE. No archived file, dated or not, may carry an install URL. The install
#      snippet is the pin whose rot BREAKS rather than ages: a wrong digest aborts the published
#      `&&` chain at `shasum -c` and nothing after it runs. A file holding one is a live install
#      surface whatever directory it sits in, and no archive excuse may reach it.
#
# What this deliberately does NOT claim: it is not a proof that nothing published can ever sit in
# an archive directory. It is a proof that the two shapes that actually caused damage here —
# undated live copy, and a hand-typed install snippet — cannot.
ARCHIVE_N=0
ARCHIVE_OK=1
ARCH_ROOTS="$REPO"
[ -d "$SITE_DIR" ] && ARCH_ROOTS="$ARCH_ROOTS
$(cd "$SITE_DIR" && pwd)"

while IFS= read -r aroot; do
  [ -n "$aroot" ] || continue
  while IFS= read -r af; do
    [ -n "$af" ] || continue
    ARCHIVE_N=$((ARCHIVE_N+1))
    if grep -Eq 'raw\.githubusercontent\.com/[^/]+/heimdall/[^/]+/install\.sh' "$af" 2>/dev/null; then
      bad "archived file ${af#$aroot/} carries a live install URL — an install snippet is a published surface whatever directory it sits in, and its digest aborts the \`&&\` chain at \`shasum -c\` when it rots. Move it out of the archive directory, or mark it (HEIMDALL:PIN:TAG,SHA256)"
      ARCHIVE_OK=0
    fi
  done <<ARCHFILES
$(find_archived "$aroot")
ARCHFILES
  while IFS= read -r df; do
    [ -n "$df" ] || continue
    case "${df##*/}" in
      *[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) continue ;;
    esac
    grep -Eq '^(date|window|generated)[[:space:]]*:' "$df" 2>/dev/null && continue
    bad "undated file ${df#$aroot/} sits in a staging directory ($DATED_DIRS) that is exempted from the pin sweep BECAUSE its contents are dated history. This one carries no ISO date in its name and no date:/window:/generated: field, so the exemption does not describe it — date it, or move it somewhere the sweep can see it"
    ARCHIVE_OK=0
  done <<DATEDFILES
$(find_archived "$aroot" "$DATED_DIRS")
DATEDFILES
done <<ROOTS
$ARCH_ROOTS
ROOTS

[ "$ARCHIVE_OK" -eq 1 ] \
  && ok "every one of the $ARCHIVE_N dated-archive file(s) excluded from the sweep is genuinely archival (dated, and carrying no install surface)"

# ── 3. Anti-vacuous: the sweep must have had something to assert over ─────────
if [ "$N_OK" -eq 0 ] && [ "$N_BAD" -eq 0 ]; then
  bad "VACUOUS sweep: ZERO occurrences of $VER / $TAG / a pinned install digest were found in ANY swept file. Either the sweep is pointed at the wrong tree or its file filter now excludes everything — a gate that asserts over an empty set passes for free"
else
  ok "sweep is non-vacuous ($((N_OK + N_BAD)) pin occurrence(s) found to assert over)"
fi

# ── 4. THE LOAD-BEARING ASSERTION — zero unmarked hardcoded versions ─────────
UNMARKED=0
while IFS='|' read -r kind loc lineno found reason text; do
  [ "$kind" = "BAD" ] || continue
  if [ "$STRUCT_OK" -eq 1 ] && structurally_owned "$loc" "$text"; then continue; fi
  # A dated docs/analysis/ file's mention is quoted evidence, not a live claim (see
  # dated_in_docs_analysis() above) -- suppressed HERE, at the BAD-record verdict, not by
  # skipping the file from sweep_root entirely, so the file's OTHER pins (if any are
  # correctly MARKED) still show up as OK/MARK records and stay under this gate's watch.
  # A sweep-level skip was tried and reverted: it hid two files that already carry
  # legitimate HEIMDALL:PIN markers (2026-08-04-hn-red-team.md, 2026-08-05-dream-capability.md)
  # from the sweep ENTIRELY, which is a coverage regression, not an exemption.
  if [ "${loc#repo:}" != "$loc" ] && dated_in_docs_analysis "${loc#repo:}"; then continue; fi
  bad "hand-typed version pin at $loc:$lineno [$reason, tokens: ${found%,}] — nothing renders it, so it silently rots at the next bump. Mark it (HEIMDALL:PIN:TAG / :VERSION / :SHA256) so bin/heimdall-render-version rewrites it from plugin.json"
  UNMARKED=$((UNMARKED+1))
done <<BADREC
$(grep '^BAD|' <<<"$RECORDS" || true)
BADREC
[ "$UNMARKED" -eq 0 ] && ok "ZERO unmarked hardcoded versions — every pin is rendered from plugin.json or structurally owned"

# ── 5. The markers must actually be reachable by the renderer ────────────────
# A marker the renderer cannot see is decoration. This asserts the renderer names the same
# marker token this gate parses, so the two cannot drift apart into a false green.
RENDERER="$REPO/bin/heimdall-render-version"
if [ -f "$RENDERER" ]; then
  grep -Fq 'HEIMDALL:PIN:' "$RENDERER" \
    && ok "bin/heimdall-render-version speaks the HEIMDALL:PIN grammar this gate enforces" \
    || bad "bin/heimdall-render-version does not mention HEIMDALL:PIN — the markers this gate demands would be decoration, rewritten by nothing"
  # The same demand for the OTHER grammar this gate credits. The sweep above treats a
  # HEIMDALL:VERSION region as governing TAG,VERSION, which is a claim that something rewrites
  # what is inside it. That claim was FALSE for packages/runheimdall/README.md: render_readme
  # only ever regenerated the ROOT README, so the npm package's version badge held the previous
  # release while this gate reported the line as governed. Credit that the renderer cannot back
  # is exactly the "marker that lies" this file refuses everywhere else.
  grep -Fq 'HEIMDALL:VERSION:BEGIN' "$RENDERER" \
    && ok "bin/heimdall-render-version also renders the HEIMDALL:VERSION regions this gate credits as governed" \
    || bad "the sweep credits HEIMDALL:VERSION regions as governed, but bin/heimdall-render-version never matches HEIMDALL:VERSION:BEGIN in its pin pass — every such region is decoration, and this gate is vouching for it"
else
  bad "bin/heimdall-render-version missing — nothing renders the marked pins"
fi

# ── 6. Markers must exist at all ─────────────────────────────────────────────
[ "$N_MARK" -gt 0 ] \
  && ok "$N_MARK HEIMDALL:PIN marker(s) present across the swept surfaces" \
  || bad "ZERO HEIMDALL:PIN markers found — either every pin vanished or the marker parser matches nothing; both make this gate vacuous"

echo ""
echo "version-pin-conformance: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
