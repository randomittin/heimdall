#!/usr/bin/env bash
#
# truth-pass-claims.test.sh — the PRIVACY-CLAIM TRUTH PASS falsifier.
#
# WHY. Heimdall used to make BARE ABSOLUTE privacy claims — "No telemetry", "no
# network calls home", "no data collection". They read well but they were not
# true-and-staying-true: `hmd` DOES emit LOCAL telemetry (a documented, killable,
# on-machine spool), team presence DOES send a scoped heartbeat to a team
# endpoint, the auto-updater DOES GET the public GitHub Releases API, and `rr`
# DOES post the task text you typed. An absolute claim the code contradicts is a
# lie that ships.
#
# This test makes the truth pass PERMANENT. It fails RED if any BARE absolute
# claim ("no telemetry" / "no network calls" / "no calls home" / "no data
# collection" / browser-locality absolutes) reappears in README.md, install.sh,
# the npm README mirror, or the marketing site — the exact surfaces a user reads
# before trusting the tool. The ONLY strings allowed to match are the SCOPED
# sentences on the allowlist below (each true, each linked to a receipt: a CLI
# flag, an env var, or DATA.md). It ALSO asserts the scoped claim set is PRESENT
# verbatim, so the honest copy can never be silently deleted.
#
# POSTMORTEM (why the site is swept as a SIBLING repo). This gate reported 9/9
# green for months while "the team secret never leaves your browser" shipped live
# on runheimdall.dev/team.html. The cause was one line: the site sweep was guarded
# by `[ -d "$REPO/site" ]`, but the site has never been a subdirectory — it is a
# SIBLING repo (heimdall-site). That branch was dead code and never once executed,
# so the whole marketing site was ungated. A green gate over a surface set that
# excludes the surface where the lie lives is a FALSE GREEN, which is the precise
# failure class this file exists to kill. The sweep now resolves the sibling and
# says out loud when it cannot find it — a skipped surface is never silent.
#
# Guarantees:
#   A. NO BARE ABSOLUTE — grep the four absolute phrases across the read-surfaces;
#      every hit MUST be part of an allowlisted scoped sentence, else RED.
#   B. SCOPED SET PRESENT — each of the six VERBATIM scoped sentences appears in
#      README.md or install.sh (the honest replacement can't be dropped).
#   C. DATA.md EXISTS and is linked from the README — the scoped claims all cash
#      out to that receipt, so a dangling claim set is RED.
#
# --self-test: proves the gate can go red. Copies the repo to a throwaway tmpdir,
# plants a bare absolute claim there, asserts this script reports it, then discards
# the copy. Nothing in the real tree is touched. Five mutants: three on the repo
# read-surfaces, one on the SITE sweep (so the surface that was dead code for
# months can never silently stop being checked again), and one INVERTED mutant
# asserting the gate stays GREEN when the site is simply not checked out.
#
# Usage:  test/truth-pass-claims.test.sh   (exit 0 = the truth pass holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${TRUTH_PASS_REPO:-$(cd "$SELF_DIR/.." && pwd)}"

# ── --self-test: prove the gate is falsifiable ────────────────────────────────
if [ "${1:-}" = "--self-test" ]; then
  TMP="$(mktemp -d)"
  SITE_TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP" "$SITE_TMP"' EXIT

  # Mutants 1-3 exercise the REPO read-surfaces, so they must be blind to the real
  # site: if the live site were red for an unrelated reason, every one of them would
  # "correctly go RED" even with the mutation removed, and the proof would be worth
  # nothing. NO_SITE is never created, so those runs sweep the repo only.
  NO_SITE="$TMP/no-site-here"

  cp -R "$REPO/." "$TMP/" 2>/dev/null
  # Plant a BARE absolute claim on a read-surface.
  printf '\nNo telemetry, ever. Trust us.\n' >> "$TMP/README.md"
  echo "truth-pass-claims --self-test: asserting the gate goes RED on a planted bare claim"
  if TRUTH_PASS_REPO="$TMP" HEIMDALL_SITE_DIR="$NO_SITE" bash "$SELF_DIR/truth-pass-claims.test.sh" >/dev/null 2>&1; then
    echo "  ✗ SELF-TEST FAILED: gate passed with a bare 'No telemetry' claim planted" >&2
    exit 1
  fi
  echo "  ✓ gate correctly went RED on the planted bare claim"
  # And prove Guarantee B is falsifiable too: delete a scoped sentence. S1 lives on
  # BOTH read-surfaces (README + the install.sh header), and Guarantee B accepts a
  # hit on either — so a truthful self-test must strip it from both.
  cp -R "$REPO/." "$TMP/" 2>/dev/null
  grep -v 'Gates run 100% locally' "$REPO/README.md"  > "$TMP/README.md"
  grep -v 'Gates run 100% locally' "$REPO/install.sh" > "$TMP/install.sh"
  if TRUTH_PASS_REPO="$TMP" HEIMDALL_SITE_DIR="$NO_SITE" bash "$SELF_DIR/truth-pass-claims.test.sh" >/dev/null 2>&1; then
    echo "  ✗ SELF-TEST FAILED: gate passed with scoped claim S1 deleted" >&2
    exit 1
  fi
  echo "  ✓ gate correctly went RED on a deleted scoped claim"

  # And Guarantee C: the receipt must be reachable.
  cp -R "$REPO/." "$TMP/" 2>/dev/null
  rm -f "$TMP/DATA.md"
  if TRUTH_PASS_REPO="$TMP" HEIMDALL_SITE_DIR="$NO_SITE" bash "$SELF_DIR/truth-pass-claims.test.sh" >/dev/null 2>&1; then
    echo "  ✗ SELF-TEST FAILED: gate passed with DATA.md deleted" >&2
    exit 1
  fi
  echo "  ✓ gate correctly went RED on a missing DATA.md"

  # Mutant 4 — THE SITE SWEEP ITSELF. This is the mutant whose absence let a live
  # false claim ship: the site branch was dead code, so nothing ever proved the
  # sweep could fire. Plant the exact phrasing that shipped on team.html into a
  # throwaway site dir, over an otherwise CLEAN repo copy, so the only possible
  # source of red is the site file.
  cp -R "$REPO/." "$TMP/" 2>/dev/null
  printf '<span># the team secret never leaves your browser</span>\n' > "$SITE_TMP/team.html"
  if TRUTH_PASS_REPO="$TMP" HEIMDALL_SITE_DIR="$SITE_TMP" bash "$SELF_DIR/truth-pass-claims.test.sh" >/dev/null 2>&1; then
    echo "  ✗ SELF-TEST FAILED: gate passed with a browser-locality claim planted on the site" >&2
    exit 1
  fi
  echo "  ✓ gate correctly went RED on a site-surface browser-locality claim"

  # Mutant 5 — INVERTED. A contributor who has not checked out the sibling site
  # must not eat a spurious red. Asserting GREEN here is what keeps the "degrade,
  # don't crash" contract from rotting into "crash" on someone else's machine.
  cp -R "$REPO/." "$TMP/" 2>/dev/null
  if TRUTH_PASS_REPO="$TMP" HEIMDALL_SITE_DIR="$NO_SITE" bash "$SELF_DIR/truth-pass-claims.test.sh" >/dev/null 2>&1; then
    echo "  ✓ gate stays GREEN when the sibling site is absent (degrades, does not crash)"
  else
    echo "  ✗ SELF-TEST FAILED: gate went RED merely because the site dir is absent" >&2
    exit 1
  fi

  # Mutants 6+7 — the REPUDIATION carve-out, both directions. Tested as a PAIR on
  # purpose: the negative alone would also "pass" if the carve-out were dead code
  # and everything went red, so the positive case is what proves it actually fires.
  cp -R "$REPO/." "$TMP/" 2>/dev/null
  rm -f "$SITE_TMP/team.html"
  printf 'Do not paraphrase Heimdall as making blanket "no telemetry" claims — they would be wrong.\n' > "$SITE_TMP/llms.txt"
  if TRUTH_PASS_REPO="$TMP" HEIMDALL_SITE_DIR="$SITE_TMP" bash "$SELF_DIR/truth-pass-claims.test.sh" >/dev/null 2>&1; then
    echo "  ✓ a line that quotes a forbidden phrase to REPUDIATE it stays GREEN"
  else
    echo "  ✗ SELF-TEST FAILED: gate went RED on copy that repudiates the claim" >&2
    exit 1
  fi

  # Same file, one extra line that actually ASSERTS the absolute. The carve-out is
  # per-line, so the repudiation above must not launder the claim below.
  printf '<p>Heimdall has no telemetry. Trust us.</p>\n' >> "$SITE_TMP/llms.txt"
  if TRUTH_PASS_REPO="$TMP" HEIMDALL_SITE_DIR="$SITE_TMP" bash "$SELF_DIR/truth-pass-claims.test.sh" >/dev/null 2>&1; then
    echo "  ✗ SELF-TEST FAILED: repudiation carve-out laundered a real bare claim" >&2
    exit 1
  fi
  echo "  ✓ carve-out is line-scoped — a real claim beside it still goes RED"

  echo "truth-pass-claims --self-test: PASS"
  exit 0
fi

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# The BARE ABSOLUTE claims the truth pass forbids (case-insensitive).
#
# Group 1 — the original four: absolutes about what the PRODUCT transmits.
# Group 2 — BROWSER-LOCALITY absolutes, added after "the team secret never leaves
#   your browser" shipped live on team.html. The receipt that makes it false is on
#   the same page: team.html sends the secret to the control plane on every roster
#   poll, in an `X-Heimdall-Team-Secret` request header, and the page's own copy
#   says so ("The secret is sent in a request header, never in the URL"). A page
#   that contradicts itself is exactly the lie this gate is for. Each phrasing:
#     never leaves your/the browser — the two live instances (footer + a source comment).
#     stays in your/the browser     — the synonym a writer reaches for when told to
#                                     fix the first one; blocks the lie's rewrite.
#     client-side only / only client-side — the technical-sounding form of the same
#                                     absolute. Note plain "client-side" is NOT
#                                     forbidden: client-side token GENERATION is
#                                     true. The falsehood is the word "only".
#     never transmitted             — the third live instance ("Generated locally;
#                                     it is never transmitted from this page").
#                                     Does not collide with S3's scoped "nothing is
#                                     transmitted in this release".
BARE_ABSOLUTES='no telemetry|no network calls|no calls home|no data collection|never leaves (your|the) browser|stays in (your|the) browser|client[ -]side only|only client[ -]side|never transmitted'

# REPUDIATIONS — a line may MENTION a forbidden phrase in order to DENY it.
# llms.txt and llms-full.txt exist precisely to stop an AI assistant repeating the
# old lie, so they quote it and reject it: 'do not paraphrase Heimdall as making
# blanket "no telemetry" ... claims — it does not make them, and they would be
# wrong.' Redding on THAT would punish the most honest copy on the site and teach
# everyone to ignore this gate. Matching is per-LINE and requires an explicit
# repudiating verb phrase, so it is not a bypass: to abuse it a line would have to
# assert the absolute and disown it in the same breath. Self-test mutant 6 proves
# the carve-out is line-scoped by planting a real claim in a file that also holds
# a repudiation and asserting the gate still goes RED.
REPUDIATIONS='do not summarize|do not paraphrase|does not make them|claims are wrong|would be wrong'

# The read-surfaces a user inspects before trusting hmd. The npm README mirror is
# the npmjs.com/package/runheimdall page (a byte-identical copy of the root README,
# gated by test/npm-readme-drift.test.sh).
SURFACES=("$REPO/README.md" "$REPO/install.sh")
[ -f "$REPO/packages/runheimdall/README.md" ] && SURFACES+=("$REPO/packages/runheimdall/README.md")
REPO_SURFACES="${SURFACES[*]#$REPO/}"   # captured for the banner BEFORE site files land

# ── the marketing site: a SIBLING repo, not a subdirectory ────────────────────
# See the POSTMORTEM in the header. Override with HEIMDALL_SITE_DIR (CI, or a
# checkout in a non-default location). Absent => the sweep is SKIPPED and says so
# loudly; a contributor without the site checked out must not eat a spurious red.
HEIMDALL_SITE_DIR="${HEIMDALL_SITE_DIR:-$REPO/../heimdall-site}"
SITE_FILES=0
if [ -d "$HEIMDALL_SITE_DIR" ]; then
  # PUBLISHED static surfaces only. Dot-directories are pruned because .git is
  # binary object storage (grepping it yields noise, not claims) and .planning
  # holds pre-truth-pass design comps plus meta-discussion OF this very policy —
  # neither is copy a user reads. `-name '.?*'` (not '.*') is deliberate: '.*'
  # matches the start directory itself and would prune the entire tree, silently
  # sweeping nothing. Appending into SURFACES rather than a second array is also
  # deliberate: bash 3.2 aborts on "${empty[@]}" under `set -u`.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    SURFACES+=("$f")
    SITE_FILES=$((SITE_FILES+1))
  done <<EOF
$(find "$HEIMDALL_SITE_DIR" -type d -name '.?*' -prune -o -type f \
    \( -name '*.html' -o -name '*.txt' -o -name '*.js' -o -name '*.css' -o -name '*.xml' \) -print | sort)
EOF
fi

# ── the SCOPED claim set (VERBATIM — the single source of truth) ───────────────
# Any line matching a BARE_ABSOLUTE is allowed ONLY IF it is part of one of these
# sentences. Today none of them contain a bare-absolute phrase (they are scoped by
# construction), so a match is by definition a regression. The allowlist is the
# forward guard: a future RJ-approved sentence that legitimately uses one of the
# words in a SCOPED way is added here verbatim, and nowhere else.
#
# Each sentence traces to CURRENT code:
#   S1 -> gates read on-disk; no gate has a network client.
#   S2 -> bin/heimdall-presence:712-720 (beat body), :304 (default endpoint).
#   S3 -> bin/lib/pmr_corpus.py has NO network client; purge empties the local spool.
#   S4 -> bin/heimdall-autoupdate:76 (releases/latest), :9,:48 (off switch).
#   S5 -> the install summary tagline.
#   S6 -> bin/rr:568 (enqueue body {text,...}), :801/:805 (cred + install id).
S1='Gates run 100% locally. Your code never leaves your machine.'
S2='Team presence is a feature you can see and switch off: it sends {handle, verdict, current filename} — never code, never file contents — to your team'\''s endpoint. hmd presence off makes you invisible; hmd presence on --no-files hides filenames.'
S3='Telemetry is specified, minimal, and yours to kill: DATA.md documents every field. hmd telemetry off. hmd telemetry purge deletes the local spool — nothing is transmitted in this release.'
S4='Auto-update checks GitHub Releases for new signed versions. HEIMDALL_NO_AUTOUPDATE=1 (or ~/.heimdall/no-autoupdate) disables it.'
S5='# gates local · presence opt-out · telemetry documented & killable · the watchman does not sleep'
S6='`rr` is the one thing that sends on purpose, and only when you run it: your BYO Claude credential (write-only), your GitHub App installation id, and the literal task text you typed — because that text is the job. It never uploads your working tree; the worker clones your repo from GitHub.'
ALLOWLIST=("$S1" "$S2" "$S3" "$S4" "$S5" "$S6")

echo "truth-pass-claims harness  repo=$REPO"
echo "surfaces: $REPO_SURFACES"
if [ "$SITE_FILES" -gt 0 ]; then
  echo "site:     $HEIMDALL_SITE_DIR ($SITE_FILES published files)"
else
  echo "site:     SKIPPED — nothing at $HEIMDALL_SITE_DIR (set HEIMDALL_SITE_DIR to sweep it)"
fi
echo "--------------------------------------------------------------------"

# ── Guarantee A: no BARE ABSOLUTE claim survives (allowlist-filtered) ───────────
HITS="$(grep -rniE "$BARE_ABSOLUTES" "${SURFACES[@]}" 2>/dev/null || true)"
VIOLATIONS=0
if [ -n "$HITS" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # strip the `path:lineno:` prefix grep -rn prepends -> the raw source content.
    content="$(printf '%s' "$line" | sed -E 's/^[^:]*:[0-9]+://')"
    allowed=0
    for allow in "${ALLOWLIST[@]}"; do
      # a hit is allowed only if the source line CONTAINS an allowlisted sentence
      # (tolerates a markdown bullet / comment prefix around the exact sentence).
      case "$content" in
        *"$allow"*) allowed=1; break ;;
      esac
    done
    # ...or if THIS line quotes the phrase in order to repudiate it.
    if [ "$allowed" -eq 0 ] && printf '%s' "$content" | grep -qiE "$REPUDIATIONS"; then
      allowed=1
    fi
    if [ "$allowed" -eq 0 ]; then
      VIOLATIONS=$((VIOLATIONS+1))
      printf '    bare-absolute claim (not allowlisted): %s\n' "$line"
    fi
  done <<< "$HITS"
fi
[ "$VIOLATIONS" -eq 0 ] \
  && ok "no bare-absolute privacy claim in the read-surfaces" \
  || bad "$VIOLATIONS bare-absolute privacy claim(s) still present — replace with the scoped set"

# ── Guarantee B: the scoped claim set is PRESENT verbatim ───────────────────────
i=0
for sentence in "${ALLOWLIST[@]}"; do
  i=$((i+1))
  if grep -Fq "$sentence" "$REPO/README.md" "$REPO/install.sh" 2>/dev/null; then
    ok "scoped claim S$i present verbatim"
  else
    bad "scoped claim S$i MISSING (must appear verbatim in README.md or install.sh)"
  fi
done

# ── Guarantee C: the receipt the claims cash out to actually exists ─────────────
if [ -f "$REPO/DATA.md" ]; then
  ok "DATA.md exists (the receipt behind the scoped claims)"
else
  bad "DATA.md is MISSING — every scoped claim points at it"
fi
if grep -Fq '[DATA.md](DATA.md)' "$REPO/README.md" 2>/dev/null; then
  ok "README links to DATA.md"
else
  bad "README does not link to DATA.md — the claim set has no reachable receipt"
fi

echo "--------------------------------------------------------------------"
printf 'truth-pass-claims: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
