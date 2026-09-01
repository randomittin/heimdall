#!/usr/bin/env bash
#
# caveman-level-claim.test.sh — hmd may REPORT the caveman level in force; it may
# never ASSERT one it does not actually have.
#
# THE BUG THIS PINS
# hmd's system preamble hardcoded "CAVEMAN ULTRA (max compression, every
# response)", and three specialist agent templates carried a "## CAVEMAN ULTRA
# active" header. None of it was true on any session hmd has ever run.
#
# So hmd shipped a declaration with no mechanism behind it: the failure class
# this repo exists to catch, inside its own prompt. Worse than cosmetic, because
# a model told "ultra is active" reports ultra behaviour it was never given the
# rules for, and nothing goes red.
#
# OWNERSHIP MOVED IN-HOUSE, 2026-08-30
# The level used to live in `.caveman-active`, written by an external caveman
# plugin's own mode-tracker hook — hmd never wrote it, and could only report
# what it happened to observe there. hmd no longer installs that plugin at all
# (see CLAUDE.md "Token Efficiency") and now owns the level directly:
# bin/heimdall-caveman, backed by $HEIMDALL_HOME/caveman-level.
# bin/heimdall-caveman-block reflects this: it no longer reads `.caveman-active`
# in any form, not even as a fallback, and unconditionally defers to
# `heimdall-caveman rules` for the real, currently configured level and text.
# See heimdall-caveman-no-plugin.test.sh for the dedicated fresh-install proof.
#
# Guarantees proved here:
#   1. The block reports the live level (full / ultra) hmd itself has set, via
#      its own real rules text — a behavioural check, not a grep for a string.
#   2. The block names the real, current way to change level
#      (`heimdall-caveman set`) and never the retired plugin command or a
#      disclaimer that hmd does not own the level — it does now.
#   3. Losing the block's only dependency (bin/heimdall-caveman itself missing)
#      degrades cleanly and still claims no specific level — fail-open one
#      layer up from guarantee 6 below.
#   4. No shipped source file asserts a caveman LEVEL as an active fact.
#   5. The launcher is actually wired to the helper (else 1-3 prove nothing).
#   6. Fail-open: a broken helper degrades, and the degraded text claims no level.
#
# Usage: test/caveman-level-claim.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BLOCK="$REPO/bin/heimdall-caveman-block"
CAV="$REPO/bin/heimdall-caveman"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Run the block against an isolated hmd state dir. A level of "" leaves hmd's
# own state unconfigured (fresh install), which bin/heimdall-caveman resolves
# to its own DEFAULT_LEVEL. There is no plugin flag concept left to seed —
# bin/heimdall-caveman-block never reads one any more — so seeding now goes
# through the real `heimdall-caveman set` command against an isolated
# HEIMDALL_HOME, never a hand-written `.caveman-active` file.
run_at() {
  local lvl="$1" hh="$TMP/hh"
  rm -rf "$hh"; mkdir -p "$hh"
  if [ -n "$lvl" ]; then
    HEIMDALL_HOME="$hh" "$CAV" set "$lvl" >/dev/null 2>&1
  fi
  HEIMDALL_HOME="$hh" "$BLOCK" 2>/dev/null
}

echo "caveman-level-claim harness  repo=$REPO"
echo "--------------------------------------------------------------------"

[ -x "$BLOCK" ] && ok "bin/heimdall-caveman-block is executable" \
  || bad "bin/heimdall-caveman-block missing or not executable"

# ── 1. THE BLOCK REPORTS THE LIVE LEVEL, NEVER A HARDCODED ONE ──
# Matched against the HEADER line specifically ("HMD OUTPUT COMPRESSION —
# level: <lvl>"), not a bare `level: ultra` substring: the rules text also
# contains the unrelated boilerplate sentence "Default level: ultra (the
# only level). Change level: ..." (see bin/heimdall-caveman's _rules_ultra),
# so a bare substring match on ultra's own output would false-positive on
# that sentence and "prove" a bug that is not there.
#
# 2026-09-01: hmd collapsed to a single settable level, ultra (see
# bin/heimdall-caveman "SCOPE"). 'full'/'lite' are no longer states hmd can
# actually be in -- `set full`/`set lite` now MAP FORWARD to ultra rather
# than erroring (see test/heimdall-caveman.test.sh's coverage of that
# mapping). So feeding run_at a RETIRED name is now the STRONGER version of
# this guarantee, not a weaker one: it proves the block reports the TRUE
# resolved state (ultra) even when fed a legacy name, rather than parroting
# the raw input back or freezing on a stale claim -- exactly the failure
# class this file exists to catch, just triggered from the input side now
# instead of from a hardcoded template.
out="$(run_at full)"
case "$out" in
  *'HMD OUTPUT COMPRESSION — level: ultra'*) ok "legacy level=full maps forward and is honestly reported as ultra" ;;
  *) bad "level=full (legacy) produced: $out" ;;
esac
case "$out" in
  *'HMD OUTPUT COMPRESSION — level: full'*) bad "level=full (legacy) was falsely asserted verbatim instead of the true resolved level: $out" ;;
  *) ok "level=full (legacy) is never asserted verbatim -- the true resolved level (ultra) wins" ;;
esac

out="$(run_at ultra)"
case "$out" in
  *'HMD OUTPUT COMPRESSION — level: ultra'*) ok "level=ultra is reported as ultra" ;;
  *) bad "level=ultra produced: $out" ;;
esac
case "$out" in
  *'HMD OUTPUT COMPRESSION — level: full'*|*'HMD OUTPUT COMPRESSION — level: lite'*) bad "level=ultra still asserts a retired level in its header: $out" ;;
  *) ok "level=ultra never asserts a retired level (full/lite) in its header" ;;
esac

# ── 2. THE BLOCK NAMES THE REAL WAY TO CHANGE LEVEL, NEVER THE RETIRED ONE ──
out="$(run_at lite)"
case "$out" in
  *'heimdall-caveman set'*) ok "block names the real change-level command" ;;
  *) bad "block does not say how to change level: $out" ;;
esac
case "$out" in
  *'/caveman '*) bad "block still references the retired plugin slash command: $out" ;;
  *) ok "block does not reference the retired /caveman slash command" ;;
esac
case "$out" in
  *'will not set it for you'*|*'does not set the level'*|*'does not restate them'*)
    bad "block still disclaims hmd ownership of the level, which is now false: $out" ;;
  *) ok "block does not disclaim ownership of the level — hmd sets it now" ;;
esac

# ── 3. FAIL-OPEN WHEN heimdall-caveman ITSELF IS MISSING ──
# The block no longer reads any plugin flag; its only dependency is its sibling
# heimdall-caveman. Prove that losing that sibling degrades cleanly instead of
# erroring, by running an isolated copy of ONLY the block (no sibling present).
ISO="$TMP/iso-no-caveman"
rm -rf "$ISO"; mkdir -p "$ISO"
cp "$BLOCK" "$ISO/heimdall-caveman-block"
out="$(HEIMDALL_HOME="$TMP/hh-iso" "$ISO/heimdall-caveman-block" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
  ok "missing sibling heimdall-caveman degrades instead of erroring (rc=0)"
else
  bad "missing sibling heimdall-caveman broke the block (rc=$rc): $out"
fi
case "$out" in
  *'no caveman level set'*) ok "degraded output claims no level, per the fail-open contract" ;;
  *) bad "degraded output did not use the expected no-level fallback text: $out" ;;
esac
case "$out" in
  *'level: full'*|*'level: ultra'*|*'level: lite'*) bad "degraded path invented a level: $out" ;;
  *) ok "degraded path names no specific level" ;;
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
# ── wenyan-* modes: DELIBERATELY NO LONGER TESTED HERE ────────────────────────
# The retired external plugin also supported wenyan / wenyan-lite / wenyan-full
# / wenyan-ultra modes, tracked via `.caveman-active`. Since ownership moved
# in-house (2026-08-30), bin/heimdall-caveman-block never reads that flag at
# all any more (see its own header), and bin/heimdall-caveman does not own
# those modes either (see its "SCOPE" header — wenyan-*/off are explicitly out
# of scope). This is a known, accepted scope reduction that came with
# in-housing ownership, not a gap this suite silently stopped covering by
# accident.

echo "caveman-level-claim.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
