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

# 2b. The registry must not rot: an exclusion that outlives its reason is how a gate
#     quietly stops gating.
#
#     This used to be a hardcoded list of NINE NAMES — a copy of the registry, kept in
#     a file that is not the registry, checking exactly one rot condition. It rotted in
#     both directions at once. It could not see a row for any other name, so twenty-two
#     rows were watched by nine. And it judged those nine with the flat matcher, so it
#     reported all nine "now wired, remove them" when re-checking each one against a
#     live entry point says every one is still unreachable. Deleting those rows on that
#     advice would have turned nine acknowledged-dead tools into nine surprise failures.
#
#     The engine already audits EVERY row against five rot conditions. Ask it instead of
#     keeping a second, smaller, staler copy of the question:
#       MALFORMED  no name, no reason, or a recheck date that is not a real ISO date
#       DUPLICATE  listed twice, so the later reason is invisible
#       EXPIRED    past its recheck date — re-justify it, wire it, or delete it
#       STALE      reachable again, so the exclusion is now hiding nothing
#       ORPHAN     bin/<name> is gone; the row would pre-clear a future namesake
ROT="$(reach_exempt_audit "$ROOT" "$WORK")"
EXEMPT_ROWS="$(reach_exempt_rows "$ROOT" | grep -c . || true)"
if [ -z "$ROT" ]; then
  ok "all $EXEMPT_ROWS exemption rows are well-formed, in-date, and still genuinely unreachable"
else
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    bad "EXEMPTION ROT: $(printf '%s' "$r" | tr '\t' ' ')"
  done <<EOF
$ROT
EOF
  printf "         → bin/lib/reachability-exemptions.tsv: fix the row, or wire the tool up and delete it.\n"
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

sb_flagged() { grep -qx "$1" <<<"$SB_DEAD"; }

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
if grep -qx "orphan-tool" <<<"$SB2_DEAD"; then
  ok "falsifier: the exemption registry is not a reference surface (naming a bin there does not make it reachable)"
else
  bad "falsifier: the exemption file VOUCHED for bin/orphan-tool — writing an exemption would make a dead bin read as wired"
fi

# 3d. The LIVENESS MANIFEST must NOT be a reference surface either. It declares which
#     subsystems OWE a receipt, naming each one's command in a data column. Declaring
#     that something SHOULD run is the opposite of evidence that anything runs it.
#
#     This is a regression test for a real defect, not a hypothetical. When
#     heimdall-weekly-log began reading the manifest, the manifest itself became
#     reachable, and heimdall-cost-report, heimdall-cost-model-refresh and
#     heimdall-registry-hygiene all inherited liveness through it. The gate then
#     reported their (correct) exemptions as STALE, and acting on that would have
#     deleted three good rows and reported three unscheduled jobs as live.
#
#     The sandbox reproduces that exact shape: a LIVE hook seeds wired-tool, wired-tool
#     names the manifest, and the manifest names declared-tool. Pre-fix that chain
#     cleared declared-tool, so this assertion discriminates rather than passing
#     vacuously.
printf '#!/bin/sh\n# reads bin/lib/liveness-subsystems.conf for its schedule\nexit 0\n' \
  > "$SANDBOX/bin/wired-tool"
chmod +x "$SANDBOX/bin/wired-tool"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/declared-tool"
chmod +x "$SANDBOX/bin/declared-tool"
printf 'declared|86400|3|operator|some subject|declared-tool --apply\n' \
  > "$SANDBOX/bin/lib/liveness-subsystems.conf"
SBW3="$WORK/sandbox-manifest"
reach_build "$SANDBOX" "$SBW3"
SB3_DEAD="$(reach_dead "$SBW3")"
if grep -qx "declared-tool" <<<"$SB3_DEAD"; then
  ok "falsifier: the liveness manifest is not a reference surface (declaring a subsystem does not make it reachable)"
else
  bad "falsifier: the liveness manifest VOUCHED for bin/declared-tool — a live reader of the manifest revives every subsystem it declares, and correct exemptions then read STALE"
fi

# 3d. The registry rot audit must be able to go RED. §2b passes when the audit returns
#     nothing, so "no rot found" and "the audit stopped looking" render identically
#     unless something forces the difference. Feed it one row of each rot kind and
#     require all five back. HMD_REACH_TODAY is the library's documented test seam, set
#     here only so EXPIRED does not depend on the day the suite runs.
{ printf 'bad-date\tnope\tdate is not a real ISO date\n'
  printf 'ghost-tool\t2099-01-01\tno bin of this name exists\n'
  printf 'wired-tool\t2099-01-01\tclaims standalone, but a hook reaches it\n'
  printf 'orphan-tool\t2000-01-01\trecheck date long past\n'
  printf 'orphan-tool\t2099-01-01\tsecond row for a name already listed\n'
} > "$SANDBOX/bin/lib/reachability-exemptions.tsv"

HMD_REACH_TODAY="2026-06-01"
ROT_SB="$(reach_exempt_audit "$SANDBOX" "$SBW2")"
unset HMD_REACH_TODAY

ROT_MISSING=""
for k in MALFORMED ORPHAN STALE EXPIRED DUPLICATE; do
  grep -q "^$k" <<<"$ROT_SB" || ROT_MISSING="$ROT_MISSING $k"
done
if [ -z "$ROT_MISSING" ]; then
  ok "falsifier: registry audit catches all five rot kinds (malformed, orphan, stale, expired, duplicate)"
else
  bad "falsifier: registry audit MISSED rot kind(s):$ROT_MISSING — a rotten exemption row would pass §2b unseen"
fi

# 3e. …and the RULE A parser must actually reject a missing arm. Build a tiny
#     heimdall-shaped script that advertises a command it never dispatches.
FAKE="$SANDBOX/fake-heimdall"
{ printf '%s\n' '  echo "  heimdall ghostcmd       Advertised but never routed"'
  printf '%s\n' '  echo "  heimdall realcmd        Advertised and routed"'
  printf '%s\n' '  realcmd)'
  printf '%s\n' '    exit 0 ;;'
} > "$FAKE"
FAKE_ADV="$(sed -n 's/^[[:space:]]*echo "  heimdall \([a-z][a-z0-9-]*\)[[:space:]].*/\1/p' "$FAKE" | sort -u)"
fake_has_arm() { grep -qE "^[[:space:]]*($1|[a-z0-9|-]+\|$1)(\|[a-z0-9|-]+)*\)[[:space:]]*$" "$FAKE"; }

if grep -qx "ghostcmd" <<<"$FAKE_ADV" && grep -qx "realcmd" <<<"$FAKE_ADV"; then
  ok "falsifier: --help parser extracts advertised subcommands"
else
  bad "falsifier: --help parser failed to extract from a known-good sample"
fi
if ! fake_has_arm ghostcmd && fake_has_arm realcmd; then
  ok "falsifier: dispatch-arm detector rejects the unrouted name, accepts the routed one"
else
  bad "falsifier: dispatch-arm detector cannot tell routed from unrouted"
fi


# ══════════════════════════════════════════════════════════════════════════════
# 4. CALLER CLASS — LIVE vs. REACHABLE vs. PROSE-ONLY are three different kinds of
#    evidence that "reachable" was reporting as one word: a hook that fires with
#    nobody in the loop, a real script someone has to run on purpose, and a sentence
#    in a *.md file an agent may or may not act on. This section proves the classifier
#    on a synthetic tree we control, then checks two named regressions against the
#    real repo: bin/heimdall-git-guard (hook-wired, existing §2c anchor) and
#    bin/heimdall-brief (the capability census's headline example — hook-wired for
#    real, AND named ONE HOP CLOSER by agents/heimdall.md prose, which is exactly why
#    classification must prefer the all-code path over the shorter one).
# ══════════════════════════════════════════════════════════════════════════════

# 4a. reach_hop_class is a pure function of the referrer's path — no build needed.
if [ "$(reach_hop_class "hooks/hooks.json")" = "LIVE" ] && [ "$(reach_hop_class ".mcp.json")" = "LIVE" ]; then
  ok "reach_hop_class: hooks/hooks.json and .mcp.json classify LIVE"
else
  bad "reach_hop_class: a hook/MCP registration surface did not classify LIVE"
fi

if [ "$(reach_hop_class "agents/whatever.md")" = "PROSE-ONLY" ] && [ "$(reach_hop_class "skills/whatever/SKILL.md")" = "PROSE-ONLY" ]; then
  ok "reach_hop_class: an agents/ or skills/ *.md referrer classifies PROSE-ONLY"
else
  bad "reach_hop_class: an agents/ or skills/ *.md referrer did not classify PROSE-ONLY"
fi

if [ "$(reach_hop_class "commands/foo.md")" = "REACHABLE" ]; then
  ok "reach_hop_class: a commands/*.md referrer classifies REACHABLE (a declared slash command, not prose)"
else
  bad "reach_hop_class: a commands/*.md referrer did not classify REACHABLE — a declared entry point misread as prose"
fi

if [ "$(reach_hop_class "bin/some-script")" = "REACHABLE" ] && [ "$(reach_hop_class "install.sh")" = "REACHABLE" ]; then
  ok "reach_hop_class: a real non-Markdown referrer classifies REACHABLE"
else
  bad "reach_hop_class: a real non-Markdown referrer misclassified"
fi

# 4b. The real repo's code-only closure — needed by every real-tree check below.
reach_build_class "$WORK"
reach_build_hook_class "$WORK"
if [ -s "$WORK/live-code-paths" ]; then
  ok "reach_build_class produced a non-empty code-only closure over the real tree"
else
  bad "reach_build_class produced an EMPTY code-only closure — every seed is *.md, or the pass is broken"
fi

# 4c. A synthetic tree, built fresh so nothing from §3's accumulated sandbox can bleed
#     into these counts.
CLASS_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hmd-reach-class-XXXXXX")"
mkdir -p "$CLASS_SANDBOX/bin" "$CLASS_SANDBOX/hooks" "$CLASS_SANDBOX/commands" "$CLASS_SANDBOX/agents"
printf '#!/bin/sh\nexit 0\n' > "$CLASS_SANDBOX/bin/hook-direct"
printf '#!/bin/sh\nbin/human-direct --setup\nbin/dual-path --setup\nexit 0\n' > "$CLASS_SANDBOX/install.sh"
printf '#!/bin/sh\nexit 0\n' > "$CLASS_SANDBOX/bin/human-direct"
printf '#!/bin/sh\nexit 0\n' > "$CLASS_SANDBOX/bin/prose-direct"
printf '#!/bin/sh\nexit 0\n' > "$CLASS_SANDBOX/bin/nobody-calls"
# THE REQUIRED FIXTURE: a bin referenced ONLY from a *.md file OUTSIDE commands/ must
# classify PROSE-ONLY, not REACHABLE. agents/ (not commands/) is the correct home for
# this fixture: commands/*.md is a declared slash-command entry point, not prose — see
# COMMANDS/*.MD ARE A DECLARED ENTRY POINT in bin/lib/reachability.sh.
printf '# mentions bin/prose-direct in prose, nowhere else\n' > "$CLASS_SANDBOX/agents/only-prose.md"
# THE COMMANDS/*.MD FIXTURE: a bin referenced ONLY from a commands/*.md file must
# classify REACHABLE, not PROSE-ONLY — a slash command is a human types `/name` away
# from firing, the same evidentiary weight as install.sh naming a bin directly.
printf '#!/bin/sh\nexit 0\n' > "$CLASS_SANDBOX/bin/command-direct"
printf '# running bin/command-direct is the entire purpose of this command\n' > "$CLASS_SANDBOX/commands/does-thing.md"
# THE CRUX FIXTURE: brief-shaped is named ONE hop away by prose (mentions.md, shorter)
# AND TWO hops away by a real, hook-fired path (longer) — reconstructing bin/heimdall-
# brief's own shape, where agents/heimdall.md names it directly and
# bin/heimdall-precheck-agent also names it via a genuine hook-rooted code path.
printf '# see bin/brief-shaped for details\n' > "$CLASS_SANDBOX/agents/mentions.md"
printf '#!/bin/sh\nexec bin/brief-shaped\n' > "$CLASS_SANDBOX/bin/precheck-shaped"
printf '#!/bin/sh\nexit 0\n' > "$CLASS_SANDBOX/bin/brief-shaped"
# THE STRONGEST-WINS FALSIFIER: dual-path is reachable by TWO separate ALL-CODE routes
# at once — install.sh names it directly, ONE hop from a seed and NOT hook-rooted;
# hooks.json also reaches it, TWO hops out via hook-relay. A single-parent BFS always
# keeps whichever route it discovers first, and a 1-hop route is always discovered
# before a 2-hop one regardless of seed ordering — so the OLD (pre-fix) reach_class
# always recorded install.sh as the parent and reported REACHABLE, never LIVE, no
# matter how real the hook-fired route also is. The class must be the STRONGEST path
# over ALL routes, never merely the one a BFS got to first.
printf '#!/bin/sh\nexec bin/dual-path\n' > "$CLASS_SANDBOX/bin/hook-relay"
printf '#!/bin/sh\nexit 0\n' > "$CLASS_SANDBOX/bin/dual-path"
chmod +x "$CLASS_SANDBOX"/bin/* "$CLASS_SANDBOX/install.sh"
printf '{"hooks":{"X":"run bin/hook-direct now","Y":"run bin/precheck-shaped now","Z":"run bin/hook-relay now"}}\n' \
  > "$CLASS_SANDBOX/hooks/hooks.json"

CLASS_WORK="$WORK/class-sandbox"
reach_build "$CLASS_SANDBOX" "$CLASS_WORK"
CLASS_BUILD_RC=$?
reach_build_class "$CLASS_WORK"
reach_build_hook_class "$CLASS_WORK"
if [ "$CLASS_BUILD_RC" -eq 0 ]; then
  ok "falsifier: engine builds a closure over the caller-class synthetic tree"
else
  bad "falsifier: engine REFUSED the caller-class synthetic tree (rc=$CLASS_BUILD_RC) — §4c proves nothing"
fi

if [ "$(reach_class "$CLASS_WORK" hook-direct)" = "LIVE" ]; then
  ok "falsifier: a bin named directly by hooks.json classifies LIVE"
else
  bad "falsifier: a bin named directly by hooks.json did not classify LIVE"
fi

if [ "$(reach_class "$CLASS_WORK" human-direct)" = "REACHABLE" ]; then
  ok "falsifier: a bin named by a real, non-hook, non-Markdown file classifies REACHABLE"
else
  bad "falsifier: a bin named by a real non-Markdown, non-hook file misclassified"
fi

if [ "$(reach_class "$CLASS_WORK" prose-direct)" = "PROSE-ONLY" ]; then
  ok "falsifier: a bin referenced ONLY from a *.md file classifies PROSE-ONLY, not REACHABLE (the required fixture)"
else
  bad "falsifier: a bin referenced only from a *.md file did NOT classify PROSE-ONLY — a prose mention is reading as a genuine caller again"
fi

if [ "$(reach_class "$CLASS_WORK" command-direct)" = "REACHABLE" ]; then
  ok "falsifier: a bin named ONLY by a commands/*.md file classifies REACHABLE, not PROSE-ONLY (a declared slash command is a real entry point, not prose)"
else
  bad "falsifier: a bin named ONLY by a commands/*.md file did NOT classify REACHABLE — a declared slash-command entry point misread as prose"
fi

if reach_class "$CLASS_WORK" nobody-calls >/dev/null 2>&1; then
  bad "falsifier: an unreferenced bin returned a class — dead code must have none"
else
  ok "falsifier: an unreferenced (dead) bin returns no class"
fi

# THE CRUX: brief-shaped is one hop from a *.md mention (shorter) and two hops from a
# hook-fired, all-code path (longer). Classification must prefer the longer all-code
# path — reporting LIVE — exactly reconstructing why bin/heimdall-brief itself must not
# read PROSE-ONLY just because agents/heimdall.md also happens to name it more directly
# than bin/heimdall-precheck-agent does.
BS_CLASS="$(reach_class "$CLASS_WORK" brief-shaped)"
BS_CHAIN="$(reach_chain_classified "$CLASS_WORK" brief-shaped)"
if [ "$BS_CLASS" = "LIVE" ]; then
  ok "falsifier: a hook-fired all-code path outranks a SHORTER prose mention of the same bin ($BS_CHAIN)"
else
  bad "falsifier: THE SHORTEST PATH WON — brief-shaped classified $BS_CLASS via a shorter prose hop despite a real hook-fired path also existing; a hook-wired tool would misreport as prose-summoned ($BS_CHAIN)"
fi

case "$BS_CHAIN" in
  *"[PROSE-ONLY]"*)
    bad "falsifier: the DISPLAYED chain for brief-shaped still routes through a Markdown hop even though an all-code path exists: $BS_CHAIN"
    ;;
  *"hooks/hooks.json"*"[LIVE]"*)
    ok "falsifier: --why's displayed chain for brief-shaped shows the real hook-fired path, not the shorter prose one"
    ;;
  *)
    bad "falsifier: brief-shaped's classified chain has neither a prose hop nor the expected hook root: $BS_CHAIN"
    ;;
esac

# THE STRONGEST-WINS FALSIFIER, continued: dual-path must classify LIVE because a
# hook-rooted all-code route exists, even though a SHORTER, non-hook all-code route to
# the very same bin also exists and would win any plain single-parent BFS race. This is
# the two-all-code-paths regression (bin/heimdall-brief hit it for real, via
# bin/heimdall <-> bin/heimdall-deadcode comments), as opposed to §4c's crux fixture
# above, which only pits an all-code path against a Markdown one.
DP_CLASS="$(reach_class "$CLASS_WORK" dual-path)"
DP_CHAIN="$(reach_chain_classified "$CLASS_WORK" dual-path)"
if [ "$DP_CLASS" = "LIVE" ]; then
  ok "falsifier: a hook-rooted all-code route outranks a SHORTER non-hook all-code route to the same bin ($DP_CHAIN)"
else
  bad "falsifier: STRONGEST-WINS BROKE — dual-path classified $DP_CLASS via the shorter non-hook route despite a real hook-rooted route also existing; single-parent BFS discovery order picked the weaker path ($DP_CHAIN)"
fi

case "$DP_CHAIN" in
  *"hooks/hooks.json"*"[LIVE]"*)
    ok "falsifier: --why's displayed chain for dual-path shows the hook-rooted route, not the shorter install.sh one"
    ;;
  *)
    bad "falsifier: dual-path's classified chain does not show the expected hook root: $DP_CHAIN"
    ;;
esac

# 4d. The design constraint this feature must not violate: the classifier's OWN
#     production caller, bin/heimdall-deadcode, must itself be LIVE or REACHABLE — if
#     adding a caller-class feature left its own CLI reading PROSE-ONLY, that would be
#     the exact self-own the task called out by name.
DC_CLASS="$(reach_class "$WORK" heimdall-deadcode)"
if [ "$DC_CLASS" = "LIVE" ] || [ "$DC_CLASS" = "REACHABLE" ]; then
  ok "heimdall-deadcode itself classifies $DC_CLASS, not PROSE-ONLY (the feature does not self-own)"
else
  bad "heimdall-deadcode itself classifies ${DC_CLASS:-DEAD} — the caller-class feature would be reporting itself as prose-summoned or worse"
fi

# 4e. Named regressions against the REAL repo, mirroring §2c's style.
GG_CLASS="$(reach_class "$WORK" heimdall-git-guard)"
if [ "$GG_CLASS" = "LIVE" ]; then
  ok "heimdall-git-guard classifies LIVE: $(reach_chain_classified "$WORK" heimdall-git-guard)"
else
  bad "heimdall-git-guard classifies ${GG_CLASS:-DEAD}, not LIVE — the self-heal's hook wiring regressed"
fi

BRIEF_CLASS="$(reach_class "$WORK" heimdall-brief)"
if [ "$BRIEF_CLASS" = "LIVE" ]; then
  ok "heimdall-brief classifies LIVE via its real hook-fired path, not the shorter agents/heimdall.md prose mention: $(reach_chain_classified "$WORK" heimdall-brief)"
else
  bad "heimdall-brief classifies ${BRIEF_CLASS:-DEAD}, not LIVE — this is the capability census's headline example; either its hook wiring regressed or the classifier picked the shorter prose path over the real one"
fi

# 4f. The tallies must partition the reachable set exactly: every reachable subject
#     gets exactly one class, none skipped, none double-counted.
CLASS_TSV="$(reach_classify_all "$WORK")"
CLASS_TOTAL="$(printf '%s\n' "$CLASS_TSV" | grep -c . || true)"
PROSE_N="$(printf '%s\n' "$CLASS_TSV" | LC_ALL=C awk -F'\t' '$2=="PROSE-ONLY"' | grep -c . || true)"
LIVE_N="$(printf '%s\n' "$CLASS_TSV" | LC_ALL=C awk -F'\t' '$2=="LIVE"' | grep -c . || true)"
REACH_N="$(printf '%s\n' "$CLASS_TSV" | LC_ALL=C awk -F'\t' '$2=="REACHABLE"' | grep -c . || true)"
REACHABLE_TOTAL=$((TOTAL_BINS - DEAD_COUNT))
if [ "$CLASS_TOTAL" -eq "$REACHABLE_TOTAL" ]; then
  ok "classification partitions all $REACHABLE_TOTAL reachable bin/ executables exactly ($LIVE_N LIVE, $REACH_N REACHABLE, $PROSE_N PROSE-ONLY)"
else
  bad "classification tally mismatch: $CLASS_TOTAL classified vs $REACHABLE_TOTAL actually reachable — reach_classify_all skipped or double-counted a name"
fi

printf '\n  caller class census (real tree): %s LIVE, %s REACHABLE, %s PROSE-ONLY of %s reachable bin/ executables\n' \
  "$LIVE_N" "$REACH_N" "$PROSE_N" "$REACHABLE_TOTAL"
printf '%s\n' "$CLASS_TSV" | LC_ALL=C awk -F'\t' '$2=="PROSE-ONLY"{print "    PROSE-ONLY  "$1}'

# 4g. ANTI-VACUITY FALSIFIER — reach_vacuity_check must be able to fail, proven against
#     this file's own real, lived history rather than a contrived number: the
#     classifier's actual measured PRE-FIX output (131 of 179 scanned executables,
#     73%) MUST fail the ceiling, and its actual measured CURRENT output (99 of 179,
#     55%) MUST pass it. If either direction is wrong the ceiling has no teeth — either
#     it never fires (no different from not having this gate) or it always fires (no
#     different from a permanently broken build). Both numbers are frozen fixture
#     values, deliberately independent of whatever $TOTAL_BINS/$LIVE_N happen to be
#     when this file is next run — see reach_vacuity_check's own comment in
#     bin/lib/reachability.sh.
if reach_vacuity_check 179 131; then
  bad "falsifier: reach_vacuity_check 179 131 (this classifier's actual pre-fix output, 73% LIVE) passed — the anti-vacuity ceiling cannot fail on a genuinely skewed distribution"
else
  ok "falsifier: reach_vacuity_check 179 131 (this classifier's actual pre-fix output, 73% LIVE) correctly fails — a skewed distribution trips the ceiling"
fi
if reach_vacuity_check 179 99; then
  ok "falsifier: reach_vacuity_check 179 99 (this classifier's actual current output, 55% LIVE) correctly passes"
else
  bad "falsifier: reach_vacuity_check 179 99 (this classifier's actual current output, 55% LIVE) failed — the ceiling is set below the classifier's own honest current output, it would block real progress rather than catch a regression"
fi

# 4h. ANTI-VACUITY, applied for real. LIVE means "fires without a human typing it" —
#     useful only while it stays a minority-leaning share of everything scanned. The
#     two bugs this whole gate exists because of (comment-only mentions counted as
#     invocation edges; bin/heimdall's ~65-arm dispatch table laundering REACHABLE
#     hops into LIVE) both manifested as exactly one symptom: a silently bloated LIVE
#     count. This is the tripwire against a third bug re-inflating it the same way
#     after everyone has moved on. See reach_vacuity_ceiling's comment in
#     bin/lib/reachability.sh for why 60%, not some other number.
VACUITY_PCT=$(( (LIVE_N * 100) / TOTAL_BINS ))
if reach_vacuity_check "$TOTAL_BINS" "$LIVE_N"; then
  ok "anti-vacuity: $LIVE_N of $TOTAL_BINS scanned executables ($VACUITY_PCT%) classify LIVE, within the $(reach_vacuity_ceiling)% ceiling"
else
  bad "anti-vacuity: $LIVE_N of $TOTAL_BINS scanned executables ($VACUITY_PCT%) classify LIVE, OVER the $(reach_vacuity_ceiling)% ceiling — the caller-class census looks vacuous again; go find what just got miscategorized into LIVE the way comment-only mentions or bin/heimdall's dispatch table once did"
fi

# 4i. The CLI surface itself, not just the library: `heimdall-deadcode --why` must show
#     the class inline, or requirement 2 ("--why must show the class of every hop") is
#     satisfied in the library and nowhere a human or agent actually looks.
DC_WHY_OUT="$("$ROOT/bin/heimdall-deadcode" --why heimdall-git-guard 2>&1)"
if printf '%s' "$DC_WHY_OUT" | grep -q '^LIVE' && printf '%s' "$DC_WHY_OUT" | grep -q '\[LIVE\]'; then
  ok "heimdall-deadcode --why heimdall-git-guard shows class LIVE on the CLI surface: $DC_WHY_OUT"
else
  bad "heimdall-deadcode --why heimdall-git-guard does not show LIVE class on the CLI surface: $DC_WHY_OUT"
fi

DC_JSON_OUT="$("$ROOT/bin/heimdall-deadcode" --json 2>&1)"
if printf '%s' "$DC_JSON_OUT" | grep -q '"class_live":[0-9]' \
  && printf '%s' "$DC_JSON_OUT" | grep -q '"class_reachable":[0-9]' \
  && printf '%s' "$DC_JSON_OUT" | grep -q '"class_prose_only":[0-9]' \
  && printf '%s' "$DC_JSON_OUT" | grep -q '"prose_only_names":\['; then
  ok "heimdall-deadcode --json emits class_live/class_reachable/class_prose_only/prose_only_names"
else
  bad "heimdall-deadcode --json is missing one or more caller-class keys: $DC_JSON_OUT"
fi
printf "\n  bin-reachability-gate: %d passed, %d failed  (scanned %s executables)\n" \
  "$PASS" "$FAIL" "$TOTAL_BINS"
[ "$FAIL" -eq 0 ] || exit 1
