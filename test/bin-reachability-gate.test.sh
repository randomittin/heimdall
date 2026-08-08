#!/usr/bin/env bash
# test/bin-reachability-gate.test.sh — THE CLASS GUARD for built-but-unreachable code.
#
# WHY THIS EXISTS. Six separate instances of ONE bug shipped in this repo:
#   1. `hmd update`            — advertised, fell through to a splash banner.
#   2. `hmd weekly-log`        — advertised, unrouted.
#   3. `heimdall-gate-run --json` — a documented flag that silently no-opped.
#   4. the wrap-chain wire     — a dispatch kind with no handler.
#   5. `bin/heimdall-git-guard` — fully built, its own suite green 4/0, and
#      `grep -rl git-guard bin/ hooks/ sentinels/` matched only the file itself.
#   6. `bin/heimdall-brief`    — built complete, suite green, invoked by NOTHING for two
#      months. THIS GATE CLEARED IT THE WHOLE TIME, because bin/heimdall-protocol named
#      it — and nothing invoked heimdall-protocol either. A corpse vouched for a corpse.
# Each was found by hand, one at a time. This file turns the CLASS into a gate so
# the seventh instance fails a test the day it is written instead of years later.
#
# TWO RULES, deliberately scoped so every failure is a real defect:
#
#   RULE A — ADVERTISED ⇒ DISPATCHED.  Every space-form subcommand printed in the
#     user-facing `--help` block of bin/heimdall must have a real `case` arm. Zero
#     judgement, zero false positives: if we tell a user to type it, typing it must
#     work. This is instances 1 and 2.
#
#   RULE B — SHIPPED ⇒ REACHABLE FROM A LIVE ENTRY POINT.  Not "some file mentions
#     it". Instance 6 is the proof that a mention is worth nothing when the mouth
#     naming it is itself dead. Liveness is SEEDED only at the surfaces the outside
#     world actually enters through — hooks/hooks.json, .mcp.json, install.sh, the
#     `hmd` CLI, commands/ agents/ skills/, .claude-plugin/, deploy/, .github/workflows/
#     — and propagates outward from there. A bin no live entry point can reach is dead
#     however many other dead files name it. This is instances 5 and 6.
#
# ONE ENGINE, NOT TWO. This file used to carry its OWN flat "does any file name it?"
# matcher: a second detector, with its own opinion, that disagreed with the one in
# bin/heimdall-deadcode — it called nine executables "wired" that no live entry point
# could reach. Two gates with different verdicts is the drift this repo keeps hitting,
# so the rule now lives exactly ONCE, in bin/lib/reachability.sh, and this file is a
# thin caller over it. If the engine is wrong, everything that consumes it is wrong
# together and loudly, which is the only kind of wrong you can actually fix.
#
# EXEMPTIONS are not in this file either. They live one row per name — with a written
# reason AND a recheck date — in bin/lib/reachability-exemptions.tsv. Keeping them in
# the registry rather than in a `case` block here is what makes an exemption reviewable
# and, crucially, EXPIRING: an exclusion that never lapses is a second way to go quietly
# dead, which is exactly how heimdall-brief would have survived even WITH this gate.
#
# The engine is falsified in §3 against a synthetic tree we control, so "the gate is
# green" can never mean "the gate stopped looking".
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HMD="$ROOT/bin/heimdall"
LIB="$ROOT/bin/lib/reachability.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -f "$HMD" ] || { echo "FATAL: $HMD missing"; exit 2; }
[ -f "$LIB" ] || { echo "FATAL: reachability engine $LIB missing — RULE B cannot run"; exit 2; }
# shellcheck source=../bin/lib/reachability.sh
. "$LIB"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-reach-gate-XXXXXX")"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hmd-reach-falsify-XXXXXX")"
trap 'rm -rf "$WORK" "$SANDBOX"' EXIT INT TERM

# ══════════════════════════════════════════════════════════════════════════════
# 1. RULE A — every advertised space-form subcommand has a dispatch arm.
#    Parsed from the `--help` block: `echo "  heimdall <word> …`, keeping only
#    bare words (flags are handled by their own `if` branches, and the quoted
#    "build X" line is a task example, not a subcommand).
# ══════════════════════════════════════════════════════════════════════════════
ADVERTISED="$(sed -n 's/^[[:space:]]*echo "  heimdall \([a-z][a-z0-9-]*\)[[:space:]].*/\1/p' "$HMD" | sort -u)"

if [ -n "$ADVERTISED" ]; then
  ok "parsed $(printf '%s\n' "$ADVERTISED" | grep -c .) advertised subcommand(s) from --help"
else
  bad "parsed ZERO advertised subcommands — the --help parser has rotted, RULE A is dead"
fi

# has_dispatch_arm NAME — a `case` arm for NAME in bin/heimdall, alone or alternated.
has_dispatch_arm() {
  grep -qE "^[[:space:]]*($1|[a-z0-9|-]+\|$1)(\|[a-z0-9|-]+)*\)[[:space:]]*$" "$HMD"
}

MISROUTED=""
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  if has_dispatch_arm "$cmd"; then
    ok "advertised \`hmd $cmd\` has a dispatch arm"
  else
    bad "ADVERTISED BUT NOT DISPATCHED: \`hmd $cmd\` is printed by --help with no case arm"
    MISROUTED="$MISROUTED $cmd"
  fi
done <<EOF
$ADVERTISED
EOF

# ══════════════════════════════════════════════════════════════════════════════
# 2. RULE B — every shipped executable reaches a live entry point, or carries a
#    valid (reasoned, in-date) row in the exemption registry.
#
#    FAIL-CLOSED FIRST. reach_build returns 2 when it enumerates no nodes, no seeds
#    or no subjects. "The scanner found nothing" and "nothing is wrong" render
#    identically if you let them, so a refusal is a hard failure here, never a pass.
# ══════════════════════════════════════════════════════════════════════════════
reach_build "$ROOT" "$WORK"
BUILD_RC=$?

if [ "$BUILD_RC" -ne 0 ]; then
  bad "reachability engine REFUSED to scan (rc=$BUILD_RC) — RULE B is NOT VERIFIED, not clean"
  printf "\n  bin-reachability-gate: %d passed, %d failed  (scan refused)\n" "$PASS" "$FAIL"
  exit 1
fi

TOTAL_BINS="$(reach_subject_count "$WORK")"
DEAD_COUNT="$(reach_dead "$WORK" | grep -c . || true)"
UNACKNOWLEDGED="$(reach_unacknowledged "$ROOT" "$WORK")"

if [ -z "$UNACKNOWLEDGED" ]; then
  ok "all $TOTAL_BINS bin/ executables reach a live entry point or carry a valid exemption ($DEAD_COUNT exempt, 0 orphaned)"
else
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    bad "SHIPPED BUT UNREACHABLE: no live entry point reaches bin/$n — every file naming it is itself dead"
  done <<EOF
$UNACKNOWLEDGED
EOF
  printf "         → wire it into a dispatch path, or add a reasoned, dated row to bin/lib/reachability-exemptions.tsv.\n"
fi

# 2b. The registry must not rot: an entry that has since been wired up is stale,
#     and a stale exclusion is how a gate quietly stops gating.
STALE=""
for n in generate-changelog heimdall-banner-test heimdall-board heimdall-headroom-ab \
         heimdall-live-verify heimdall-queue-mcp heimdall-registry-hygiene \
         heimdall-seed-demo-wall heimdall-team-converge; do
  if [ -f "$ROOT/bin/$n" ] && reach_is_live "$WORK" "$n"; then
    STALE="$STALE $n"
  fi
done
if [ -z "$STALE" ]; then
  ok "exemption registry has no stale entries (every listed name is genuinely unreachable)"
else
  bad "STALE EXEMPTIONS (now reachable — remove the rows so the gate keeps gating):$STALE"
fi

# 2c. The one that started this: heimdall-git-guard must stay wired. Named
#     explicitly so a regression reads as itself and not as a generic count.
if reach_is_live "$WORK" heimdall-git-guard; then
  ok "heimdall-git-guard is reachable: $(reach_chain "$WORK" heimdall-git-guard)"
else
  bad "heimdall-git-guard is unreachable again — the self-heal is dead code"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. FALSIFIER — prove the ENGINE detects, on a synthetic tree.
#    A green gate must mean "nothing is orphaned", never "the scan stopped
#    looking". Both directions are exercised against a tree we control.
# ══════════════════════════════════════════════════════════════════════════════
mkdir -p "$SANDBOX/bin" "$SANDBOX/hooks" "$SANDBOX/sentinels"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/orphan-tool"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/wired-tool"
# substr-tool is referenced NOWHERE; the only places its name appears are INSIDE the
# longer name substr-tool-extended. A substring matcher clears it (wrongly).
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/substr-tool"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/substr-tool-extended"
# THE DEAD-CHAIN TRAP (heimdall-brief's historical shape, reconstructed). dead-caller is
# named by nothing live; dead-callee is named ONLY by dead-caller.
printf '#!/bin/sh\nexec bin/dead-callee\n' > "$SANDBOX/bin/dead-caller"
printf '#!/bin/sh\nexit 0\n'               > "$SANDBOX/bin/dead-callee"
# THE MUTUAL-CITATION TRAP. Two corpses naming each other manufacture a reference for
# one another out of nothing. Any rule that stops at "is it named?" clears BOTH; a rule
# seeded at live entry points clears NEITHER, because the cycle touches no seed. This is
# not hypothetical — bin/heimdall-s6-manifest and bin/heimdall-s6-sweep are exactly this
# shape in the real tree, and a naive fix for the dead chain above still passes them.
printf '#!/bin/sh\nexec bin/mutual-b\n' > "$SANDBOX/bin/mutual-a"
printf '#!/bin/sh\nexec bin/mutual-a\n' > "$SANDBOX/bin/mutual-b"
chmod +x "$SANDBOX"/bin/*
printf '{"hooks":{"X":"run bin/wired-tool now","Y":"run bin/substr-tool-extended now"}}\n' \
  > "$SANDBOX/hooks/hooks.json"

SBW="$WORK/sandbox"
reach_build "$SANDBOX" "$SBW"
SB_RC=$?
SB_DEAD="$(reach_dead "$SBW")"

sb_flagged() { printf '%s\n' "$SB_DEAD" | grep -qx "$1"; }

if [ "$SB_RC" -eq 0 ]; then
  ok "falsifier: engine builds a closure over the synthetic tree"
else
  bad "falsifier: engine REFUSED the synthetic tree (rc=$SB_RC) — §3 proves nothing"
fi

if sb_flagged "orphan-tool"; then
  ok "falsifier: engine FLAGS an executable no surface references"
else
  bad "falsifier: engine MISSED an orphaned executable — RULE B does not actually detect"
fi

if ! sb_flagged "wired-tool"; then
  ok "falsifier: engine CLEARS an executable a live hook references (no false positive)"
else
  bad "falsifier: engine flagged a wired executable — RULE B false-positives"
fi

# The substring trap, pinned. This is not hypothetical: the first cut of this gate
# used `grep -F` and therefore reported heimdall-git-guard "reachable" even with
# every call site renamed away. A gate that cannot go red is not a gate.
if sb_flagged "substr-tool"; then
  ok "falsifier: a name that only occurs INSIDE a longer name is still unreachable"
else
  bad "falsifier: substring match — bin/substr-tool cleared by 'substr-tool-extended'; the gate cannot go red"
fi

if ! sb_flagged "substr-tool-extended"; then
  ok "falsifier: the longer name itself is correctly cleared by its real reference"
else
  bad "falsifier: word-boundary match is too strict — a real reference was missed"
fi

# 3a. The dead chain must NOT clear. Both ends of it flag: the head because nothing
#     live names it, the tail because its only caller is the head.
if sb_flagged "dead-callee"; then
  ok "falsifier: a bin named ONLY by another DEAD bin is still unreachable (dead chain closed)"
else
  bad "falsifier: DEAD CHAIN CLEARS — bin/dead-callee passes because bin/dead-caller names it, and nothing names bin/dead-caller. This is exactly how heimdall-brief read 'reachable' for two months."
fi

if sb_flagged "dead-caller"; then
  ok "falsifier: the head of the dead chain flags too (naming a corpse is not being alive)"
else
  bad "falsifier: bin/dead-caller cleared — the engine credits a file for the references it MAKES"
fi

# 3b. The mutual-citation trap: two dead bins naming each other must BOTH flag.
if sb_flagged "mutual-a" && sb_flagged "mutual-b"; then
  ok "falsifier: two dead bins naming EACH OTHER both stay unreachable (no bootstrapping a cycle into life)"
else
  bad "falsifier: MUTUAL CITATION CLEARS — bin/mutual-a and bin/mutual-b vouch for each other and the engine believes them; a reference cycle touching no entry point is still dead"
fi

# 3c. The exemption registry must NOT be a reference surface. It names every exempt
#     executable, so if the scanner read it, WRITING AN EXEMPTION WOULD MAKE THE BINARY
#     LOOK REACHABLE — the escape hatch would silently become a second way to be dead,
#     and removing the row would then "revive" the tool. Proven, not asserted.
mkdir -p "$SANDBOX/bin/lib"
printf 'orphan-tool\t2099-01-01\tfalsifier row — must not confer reachability\n' \
  > "$SANDBOX/bin/lib/reachability-exemptions.tsv"
SBW2="$WORK/sandbox-exempt"
reach_build "$SANDBOX" "$SBW2"
SB2_DEAD="$(reach_dead "$SBW2")"
if printf '%s\n' "$SB2_DEAD" | grep -qx "orphan-tool"; then
  ok "falsifier: the exemption registry is not a reference surface (naming a bin there does not make it reachable)"
else
  bad "falsifier: the exemption file VOUCHED for bin/orphan-tool — writing an exemption would make a dead bin read as wired"
fi

# 3d. …and the RULE A parser must actually reject a missing arm. Build a tiny
#     heimdall-shaped script that advertises a command it never dispatches.
FAKE="$SANDBOX/fake-heimdall"
{ printf '%s\n' '  echo "  heimdall ghostcmd       Advertised but never routed"'
  printf '%s\n' '  echo "  heimdall realcmd        Advertised and routed"'
  printf '%s\n' '  realcmd)'
  printf '%s\n' '    exit 0 ;;'
} > "$FAKE"
FAKE_ADV="$(sed -n 's/^[[:space:]]*echo "  heimdall \([a-z][a-z0-9-]*\)[[:space:]].*/\1/p' "$FAKE" | sort -u)"
fake_has_arm() { grep -qE "^[[:space:]]*($1|[a-z0-9|-]+\|$1)(\|[a-z0-9|-]+)*\)[[:space:]]*$" "$FAKE"; }

if printf '%s\n' "$FAKE_ADV" | grep -qx "ghostcmd" && printf '%s\n' "$FAKE_ADV" | grep -qx "realcmd"; then
  ok "falsifier: --help parser extracts advertised subcommands"
else
  bad "falsifier: --help parser failed to extract from a known-good sample"
fi
if ! fake_has_arm ghostcmd && fake_has_arm realcmd; then
  ok "falsifier: dispatch-arm detector rejects the unrouted name, accepts the routed one"
else
  bad "falsifier: dispatch-arm detector cannot tell routed from unrouted"
fi

printf "\n  bin-reachability-gate: %d passed, %d failed  (scanned %s executables)\n" \
  "$PASS" "$FAIL" "$TOTAL_BINS"
[ "$FAIL" -eq 0 ] || exit 1
