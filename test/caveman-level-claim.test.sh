#!/usr/bin/env bash
#
# caveman-level-claim.test.sh — hmd may REPORT the caveman level in force; it may
# never ASSERT one.
#
# THE BUG THIS PINS
# hmd's system preamble hardcoded "CAVEMAN ULTRA (max compression, every
# response)", and three specialist agent templates carried a "## CAVEMAN ULTRA
# active" header. None of it was true on any session hmd has ever run. The level
# is written to `.caveman-active` by the caveman plugin's mode-tracker hook when
# a human types `/caveman lite|full|ultra`. hmd never writes that file — it is
# the operator's config — and the observed value is `full`.
#
# So hmd shipped a declaration with no mechanism behind it: the failure class
# this repo exists to catch, inside its own prompt. Worse than cosmetic, because
# a model told "ultra is active" reports ultra behaviour it was never given the
# rules for, and nothing goes red.
#
# UPDATED 2026-08-30: hmd no longer installs the external plugin at all (see
# CLAUDE.md "Token Efficiency") and owns a level of its own directly
# (bin/heimdall-caveman). The plugin-present path this file pins is UNCHANGED;
# what used to be the "absent/corrupt ⇒ claim nothing" path now falls through
# to hmd's own real level instead (guarantee 1, below) — see
# heimdall-caveman-no-plugin.test.sh for the dedicated fresh-install proof.
#
# Guarantees proved here:
#   1. The block reports the live level, per state (full / ultra), and for an
#      absent/corrupt plugin flag falls through to hmd's OWN level instead of
#      claiming none — a behavioural check, not a grep for a string.
#   2. Not-ultra is stated as not-ultra, with the command that would change it.
#   3. No shipped source file asserts a caveman LEVEL as an active fact.
#   4. The launcher is actually wired to the helper (else 1-2 prove nothing).
#   5. Fail-open: a broken helper degrades, and the degraded text claims no level.
#
# Usage: test/caveman-level-claim.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BLOCK="$REPO/bin/heimdall-caveman-block"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Run the block with a fixture config dir. Empty arg = no flag file at all.
run_at() {
  local lvl="$1" dir="$TMP/cfg" hh="$TMP/hh"
  rm -rf "$dir"; mkdir -p "$dir"
  [ -n "$lvl" ] && printf '%s\n' "$lvl" > "$dir/.caveman-active"
  # HEIMDALL_HOME is ALSO isolated + reset every call: once no plugin flag is
  # recognized, the block falls through to bin/heimdall-caveman, which would
  # otherwise read/seed the REAL machine's ~/.heimdall/caveman-level.
  rm -rf "$hh"
  CLAUDE_CONFIG_DIR="$dir" HEIMDALL_HOME="$hh" "$BLOCK" 2>/dev/null
}

echo "caveman-level-claim harness  repo=$REPO"
echo "--------------------------------------------------------------------"

[ -x "$BLOCK" ] && ok "bin/heimdall-caveman-block is executable" \
  || bad "bin/heimdall-caveman-block missing or not executable"

# ── 1. THE BLOCK REPORTS THE LIVE LEVEL ──
out="$(run_at full)"
case "$out" in
  *'level `full`'*) ok "level=full is reported as full" ;;
  *) bad "level=full produced: $out" ;;
esac
case "$out" in
  *'ULTRA'*|*'ultra is active'*) bad "level=full still asserts ultra somewhere: $out" ;;
  *) ok "level=full never asserts ultra (the original bug)" ;;
esac

out="$(run_at ultra)"
case "$out" in
  *'level `ultra`'*) ok "level=ultra is reported as ultra" ;;
  *) bad "level=ultra produced: $out" ;;
esac
# When ultra IS the live level, the "you are not on ultra" nudge must not appear.
case "$out" in
  *'will not set it for you'*) bad "level=ultra still prints the raise-to-ultra nudge" ;;
  *) ok "level=ultra omits the raise-to-ultra nudge (already there)" ;;
esac

# ── 2. NOT-ULTRA SAYS SO, AND SAYS WHO CAN CHANGE IT ──
out="$(run_at lite)"
case "$out" in
  *'/caveman ultra'*) ok "a non-ultra level names the command that would raise it" ;;
  *) bad "non-ultra level does not say how to reach ultra: $out" ;;
esac
case "$out" in
  *'hmd will not set it'*) ok "block states hmd does not set the level (it is operator config)" ;;
  *) bad "block does not disclaim ownership of the level: $out" ;;
esac

# ── 3. ABSENT/CORRUPT PLUGIN FLAG FALLS THROUGH TO HMD'S OWN LEVEL ──
# No recognized plugin flag (missing file, or a value outside
# lite/full/ultra/wenyan*) no longer means "nothing to say" now that hmd owns
# its own level directly (bin/heimdall-caveman) -- it falls through to THAT
# instead of a generic placeholder. See heimdall-caveman-no-plugin.test.sh for
# the dedicated fresh-install proof; this section only re-confirms the corrupt
# VALUE itself is never echoed back as if it were real.
for state in "" MAXIMUM "full; rm -rf /"; do
  label="${state:-<no flag file>}"
  out="$(run_at "$state")"
  case "$out" in
    *'HMD OUTPUT COMPRESSION'*) ok "state '$label' falls through to hmd's own level + rules" ;;
    *) bad "state '$label' produced neither a plugin level nor hmd's own rules: $(printf '%s' "$out" | head -1)" ;;
  esac
done
# A corrupt file must not be echoed back as if it were a real setting.
out="$(run_at MAXIMUM)"
case "$out" in
  *MAXIMUM*) bad "corrupt flag value was parroted into the prompt as a live level" ;;
  *) ok "corrupt flag value is not parroted as a live level" ;;
esac

# ── 4. NO SHIPPED FILE ASSERTS A LEVEL ──
# Scope: what actually reaches a model — launcher, agent templates, hooks, the
# CLAUDE.md files hmd writes. Tests and docs/ are excluded: this file itself must
# be able to name the bug, and analysis docs record it as history.
assert_sites="$(grep -rniE 'caveman[ -]*(ultra|lite|full)[ -]*(is )?(active|mode active)|(ultra|lite|full) mode active' \
  --exclude-dir=.git --exclude-dir=.claude --exclude-dir=node_modules \
  --exclude-dir=test --exclude-dir=docs --exclude-dir=launch-docs \
  --exclude='PARITY.md' \
  "$REPO/bin" "$REPO/agents" "$REPO/hooks" "$REPO/skills" \
  "$REPO/CLAUDE.md" "$REPO"/packages/*/CLAUDE.md 2>/dev/null \
  | grep -v 'heimdall-caveman-block' || true)"
if [ -z "$assert_sites" ]; then
  ok "no shipped file asserts a caveman level as an active fact"
else
  bad "a shipped file asserts a caveman level it does not set:"
  printf '       %s\n' "$assert_sites"
fi

# ── 5. THE LAUNCHER IS WIRED TO THE HELPER ──
# Without this, every assertion above tests a file nothing calls.
#
# Comment lines are stripped FIRST. This check originally did not, and a mutant
# that repointed the helper path survived: the long WHY comment above the call
# site still contained the helper's name, so the grep matched prose and reported
# wiring that no longer existed. An assertion satisfiable by a comment proves
# only that someone wrote the name down.
#
# Stripped into a VARIABLE, never piped into `grep -q`. Under `set -o pipefail`
# that pipeline is flaky by construction: `grep -q` exits at the first match and
# SIGPIPEs the upstream grep, and pipefail then reports the whole pipeline as
# failed — but only when the writer loses the race. A test that fails at random
# is worse than one that fails always, because the first green rerun buries it.
CODE_ONLY="$(grep -vE '^[[:space:]]*#' "$REPO/bin/heimdall")"
case "$CODE_ONLY" in
  *bin/heimdall-caveman-block*) ok "bin/heimdall invokes heimdall-caveman-block (code line, not a comment)" ;;
  *) bad "bin/heimdall never calls heimdall-caveman-block in code — the block is dead" ;;
esac
case "$CODE_ONLY" in
  *'${CAVEMAN_BLOCK}'*) ok "bin/heimdall interpolates \${CAVEMAN_BLOCK} into the preamble" ;;
  *) bad "bin/heimdall never interpolates \${CAVEMAN_BLOCK} — the preamble is unchanged" ;;
esac

# ── 6. FAIL-OPEN ──
# The launcher runs under `set -euo pipefail`; a helper that is missing or has
# lost its +x bit must degrade, never abort the launch. Proven by extracting the
# guarded lines and running them against a non-existent helper.
guard="$(mktemp "$TMP/guard.XXXXXX")"
{
  echo 'set -euo pipefail'
  echo 'PLUGIN_DIR=/nonexistent-plugin-dir'
  sed -n '/^_cav_helper=/,/^\[ -n "\$CAVEMAN_BLOCK" \]/p' "$REPO/bin/heimdall"
  echo 'printf "%s\n" "$CAVEMAN_BLOCK"'
} > "$guard"
degraded="$(bash "$guard" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$degraded" ]; then
  ok "a missing helper degrades instead of aborting the launcher (rc=0)"
else
  bad "missing helper aborted the guarded block (rc=$rc) — a partial install would brick hmd"
fi
case "$degraded" in
  *ultra*|*'level `'*) bad "degraded path invented a level: $degraded" ;;
  *) ok "degraded path claims no level ('$degraded')" ;;
esac

echo ""
# ── wenyan-* are real compression levels, not garbage ─────────────────────────
# caveman-config.js's VALID_MODES includes wenyan, wenyan-lite, wenyan-full and
# wenyan-ultra. The level parser once matched only lite|full|ultra, so a live
# wenyan session was reported as "no level set" — the same misreport this whole
# helper exists to prevent, just for an exotic mode nobody tested.
for wy in wenyan wenyan-lite wenyan-full wenyan-ultra; do
  out="$(run_at "$wy")"
  case "$out" in
    *"level \`$wy\`"*) ok "$wy reported as its own level" ;;
    *) bad "$wy was not reported as a level: $out" ;;
  esac
done

# wenyan-ultra IS max compression — it must not be told to escalate to ultra.
out="$(run_at wenyan-ultra)"
case "$out" in
  *"Max compression is"*) bad "wenyan-ultra told to escalate — it is already max" ;;
  *) ok "wenyan-ultra not told to escalate (already max)" ;;
esac

echo "caveman-level-claim.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
