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
# collection") reappears in README.md, install.sh, the npm README mirror, or
# site/ — the exact surfaces a user reads before trusting the tool. The ONLY
# strings allowed to match are the SCOPED sentences on the allowlist below (each
# true, each linked to a receipt: a CLI flag, an env var, or DATA.md). It ALSO
# asserts the scoped claim set is PRESENT verbatim, so the honest copy can never
# be silently deleted.
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
# the copy. Nothing in the real tree is touched.
#
# Usage:  test/truth-pass-claims.test.sh   (exit 0 = the truth pass holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${TRUTH_PASS_REPO:-$(cd "$SELF_DIR/.." && pwd)}"

# ── --self-test: prove the gate is falsifiable ────────────────────────────────
if [ "${1:-}" = "--self-test" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  cp -R "$REPO/." "$TMP/" 2>/dev/null
  # Plant a BARE absolute claim on a read-surface.
  printf '\nNo telemetry, ever. Trust us.\n' >> "$TMP/README.md"
  echo "truth-pass-claims --self-test: asserting the gate goes RED on a planted bare claim"
  if TRUTH_PASS_REPO="$TMP" bash "$SELF_DIR/truth-pass-claims.test.sh" >/dev/null 2>&1; then
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
  if TRUTH_PASS_REPO="$TMP" bash "$SELF_DIR/truth-pass-claims.test.sh" >/dev/null 2>&1; then
    echo "  ✗ SELF-TEST FAILED: gate passed with scoped claim S1 deleted" >&2
    exit 1
  fi
  echo "  ✓ gate correctly went RED on a deleted scoped claim"

  # And Guarantee C: the receipt must be reachable.
  cp -R "$REPO/." "$TMP/" 2>/dev/null
  rm -f "$TMP/DATA.md"
  if TRUTH_PASS_REPO="$TMP" bash "$SELF_DIR/truth-pass-claims.test.sh" >/dev/null 2>&1; then
    echo "  ✗ SELF-TEST FAILED: gate passed with DATA.md deleted" >&2
    exit 1
  fi
  echo "  ✓ gate correctly went RED on a missing DATA.md"
  echo "truth-pass-claims --self-test: PASS"
  exit 0
fi

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# The four BARE ABSOLUTE claims the truth pass forbids (case-insensitive).
BARE_ABSOLUTES='no telemetry|no network calls|no calls home|no data collection'

# The read-surfaces a user inspects before trusting hmd. The npm README mirror is
# the npmjs.com/package/runheimdall page (a byte-identical copy of the root README,
# gated by test/npm-readme-drift.test.sh). site/ is optional.
SURFACES=("$REPO/README.md" "$REPO/install.sh")
[ -f "$REPO/packages/runheimdall/README.md" ] && SURFACES+=("$REPO/packages/runheimdall/README.md")
[ -d "$REPO/site" ] && SURFACES+=("$REPO/site")

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
echo "surfaces: ${SURFACES[*]#$REPO/}"
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
