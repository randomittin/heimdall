#!/usr/bin/env bash
# test/bin-reachability-gate.test.sh — THE CLASS GUARD for built-but-unreachable code.
#
# WHY THIS EXISTS. Five separate instances of ONE bug shipped in this repo:
#   1. `hmd update`            — advertised, fell through to a splash banner.
#   2. `hmd weekly-log`        — advertised, unrouted.
#   3. `heimdall-gate-run --json` — a documented flag that silently no-opped.
#   4. the wrap-chain wire     — a dispatch kind with no handler.
#   5. `bin/heimdall-git-guard` — fully built, its own suite green 4/0, and
#      `grep -rl git-guard bin/ hooks/ sentinels/` matched only the file itself.
# Each was found by hand, one at a time. This file turns the CLASS into a gate so
# the sixth instance fails a test the day it is written instead of years later.
#
# TWO RULES, deliberately scoped so every failure is a real defect:
#
#   RULE A — ADVERTISED ⇒ DISPATCHED.  Every space-form subcommand printed in the
#     user-facing `--help` block of bin/heimdall must have a real `case` arm. Zero
#     judgement, zero false positives: if we tell a user to type it, typing it must
#     work. This is instances 1 and 2.
#
#   RULE B — SHIPPED ⇒ REACHABLE.  Every executable in bin/ must be named by at
#     least one dispatch surface (the bin/heimdall dispatcher, another bin, a hook,
#     a sentinel, a skill/agent, or the installer) — or appear on the STANDALONE
#     allowlist below with a written reason. This is instance 5.
#
#     Why an allowlist and not a blanket rule: a blanket rule false-positives on
#     genuinely standalone tools (an MCP server a client launches, a one-shot
#     migration, ops tooling a human runs against a deployment). Excluding them by
#     NAME with a REASON keeps the gate honest — and keeps it a ratchet: a NEW
#     unreachable executable fails until someone either wires it up or consciously
#     writes down why it stands alone. Nothing is excluded by pattern.
#
# The detector is itself falsified in §3 against a synthetic tree, so "the gate is
# green" can never mean "the gate stopped looking".
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HMD="$ROOT/bin/heimdall"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -f "$HMD" ] || { echo "FATAL: $HMD missing"; exit 2; }

# ══════════════════════════════════════════════════════════════════════════════
# STANDALONE ALLOWLIST — executables with NO runtime caller BY DESIGN.
# Every entry is "<name> — why it stands alone". Adding a name here is a
# deliberate, reviewable act; that is the whole point.
# ══════════════════════════════════════════════════════════════════════════════
# Reasons are honest about the difference between "standalone BY DESIGN" and "a known
# gap we have chosen to record rather than hide". Both are excluded from the failure
# set; only one of them is a compliment.
standalone_reason() {
  case "$1" in
    generate-changelog)        printf 'BY DESIGN — release tooling the maintainer runs when cutting a release' ;;
    heimdall-banner-test)      printf 'BY DESIGN — manual wcwidth acceptance harness for the launch banner; a human eyeballs it' ;;
    heimdall-live-verify)      printf 'BY DESIGN — on-demand live isolation verification that emits a committed receipt' ;;
    heimdall-seed-demo-wall)   printf 'BY DESIGN — one-shot demo seeding a human runs before a demo' ;;
    heimdall-team-converge)    printf 'BY DESIGN — one-shot forward migration healing an existing team split; run once, by hand' ;;
    heimdall-board)            printf 'KNOWN GAP — a read-only view whose siblings (watch/dashboard/verdict/badge/clip) all have `hmd` case arms; this one has none' ;;
    heimdall-queue-mcp)        printf 'KNOWN GAP — MCP stdio server NOT registered in .mcp.json, while its sibling heimdall-ledger-mcp is' ;;
    heimdall-registry-hygiene) printf 'KNOWN GAP — self-described MONTHLY job with no in-repo scheduler (no cron, LaunchAgent or workflow calls it)' ;;
    *) return 1 ;;
  esac
}

# ══════════════════════════════════════════════════════════════════════════════
# THE DETECTOR — parameterised on a tree root so §3 can falsify it.
#
# reference_surfaces ROOT — the files where a dispatch/hook/install reference to a
#   bin can legitimately live. A bin named ONLY by its own source (its header
#   comment, its usage text) is unreachable; that self-match is excluded per name.
# ══════════════════════════════════════════════════════════════════════════════
reference_surfaces() {
  local root="$1"
  { find "$root/bin" "$root/hooks" "$root/sentinels" "$root/skills" \
         "$root/agents" "$root/commands" "$root/.claude-plugin" "$root/deploy" \
         -type f 2>/dev/null
    [ -f "$root/install.sh" ] && printf '%s\n' "$root/install.sh"
    [ -f "$root/.mcp.json" ] && printf '%s\n' "$root/.mcp.json"
  } 2>/dev/null
}

# referenced_by ROOT NAME — prints the count of reference-surface files (other than
# bin/NAME itself) that name this executable.
#
# WORD-BOUNDARY, never substring. A plain -F match is wrong in both directions and
# this file's own falsifier caught it: `heimdall-git-guard` matched inside
# `heimdall-git-guard-DISABLED`, so DISABLING the routing still read as "reachable"
# — the gate would have shipped unable to detect the very defect it exists for. The
# same flaw made `heimdall-team` look reachable because `heimdall-team-converge`
# contains it. Requiring a non-[A-Za-z0-9_-] neighbour on both sides keeps a real
# call site (`"$PLUGIN/bin/heimdall-git-guard"`, `bin/heimdall-presence.py`) matching
# while a longer name that merely CONTAINS this one does not.
referenced_by() {
  local root="$1" name="$2" pat
  pat="(^|[^A-Za-z0-9_-])${name}([^A-Za-z0-9_-]|$)"
  reference_surfaces "$root" \
    | grep -vFx "$root/bin/$name" \
    | tr '\n' '\0' \
    | xargs -0 grep -lE -- "$pat" 2>/dev/null \
    | grep -c . || true
}

# bin_executables ROOT — every executable file directly in bin/ (bin/lib is a
# library dir, not a command surface; sources and data are not commands).
bin_executables() {
  local root="$1" f name
  for f in "$root"/bin/*; do
    [ -f "$f" ] || continue
    [ -x "$f" ] || continue
    name="$(basename "$f")"
    case "$name" in *.c|*.h|*.md|*.json|*.py) continue ;; esac
    printf '%s\n' "$name"
  done
}

# unreachable_in ROOT — names with zero external references (allowlist NOT applied;
# the allowlist is policy, this function is measurement).
unreachable_in() {
  local root="$1" name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$(referenced_by "$root" "$name")" = "0" ] && printf '%s\n' "$name"
  done < <(bin_executables "$root")
  return 0
}

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
# 2. RULE B — every shipped executable is reachable, or explicitly standalone.
# ══════════════════════════════════════════════════════════════════════════════
TOTAL_BINS="$(bin_executables "$ROOT" | grep -c .)"
UNREACHED="$(unreachable_in "$ROOT")"
UNROUTED_COUNT=0
UNLISTED=""

while IFS= read -r name; do
  [ -n "$name" ] || continue
  UNROUTED_COUNT=$((UNROUTED_COUNT+1))
  if ! standalone_reason "$name" >/dev/null; then
    UNLISTED="$UNLISTED $name"
  fi
done <<EOF
$UNREACHED
EOF

if [ -z "$UNLISTED" ]; then
  ok "all $TOTAL_BINS bin/ executables reachable or allowlisted ($UNROUTED_COUNT standalone, 0 orphaned)"
else
  for n in $UNLISTED; do
    bad "SHIPPED BUT UNREACHABLE: bin/$n is named by no dispatcher, hook, sentinel, skill or installer"
  done
  printf "         → wire it into a dispatch path, or add it to standalone_reason() with a written reason.\n"
fi

# 2b. The allowlist must not rot: an entry that has since been wired up is stale,
#     and a stale exclusion is how a gate quietly stops gating.
STALE=""
for n in generate-changelog heimdall-banner-test heimdall-board heimdall-live-verify \
         heimdall-queue-mcp heimdall-registry-hygiene heimdall-seed-demo-wall \
         heimdall-team-converge; do
  if [ -f "$ROOT/bin/$n" ] && [ "$(referenced_by "$ROOT" "$n")" != "0" ]; then
    STALE="$STALE $n"
  fi
done
if [ -z "$STALE" ]; then
  ok "standalone allowlist has no stale entries (every listed name is genuinely unreferenced)"
else
  bad "STALE ALLOWLIST ENTRIES (now wired — remove them so the gate keeps gating):$STALE"
fi

# 2c. The one that started this: heimdall-git-guard must stay wired. Named
#     explicitly so a regression reads as itself and not as a generic count.
if [ "$(referenced_by "$ROOT" "heimdall-git-guard")" != "0" ]; then
  ok "heimdall-git-guard is reachable (the defect that motivated this gate stays fixed)"
else
  bad "heimdall-git-guard is unreachable again — the self-heal is dead code"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. FALSIFIER — prove the DETECTOR detects, on a synthetic tree.
#    A green gate must mean "nothing is orphaned", never "the scan stopped
#    looking". Both directions are exercised against a tree we control.
# ══════════════════════════════════════════════════════════════════════════════
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hmd-reach-falsify-XXXXXX")"
mkdir -p "$SANDBOX/bin" "$SANDBOX/hooks"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/orphan-tool";          chmod +x "$SANDBOX/bin/orphan-tool"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/wired-tool";           chmod +x "$SANDBOX/bin/wired-tool"
# substr-tool is referenced NOWHERE; the only places its name appears are INSIDE the
# longer name substr-tool-extended. A substring matcher clears it (wrongly).
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/substr-tool";          chmod +x "$SANDBOX/bin/substr-tool"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/substr-tool-extended"; chmod +x "$SANDBOX/bin/substr-tool-extended"
printf '{"hooks":{"X":"run bin/wired-tool now","Y":"run bin/substr-tool-extended now"}}\n' \
  > "$SANDBOX/hooks/hooks.json"

SB_UNREACHED="$(unreachable_in "$SANDBOX")"

if printf '%s\n' "$SB_UNREACHED" | grep -qx "orphan-tool"; then
  ok "falsifier: detector FLAGS an executable no surface references"
else
  bad "falsifier: detector MISSED an orphaned executable — RULE B does not actually detect"
fi

if ! printf '%s\n' "$SB_UNREACHED" | grep -qx "wired-tool"; then
  ok "falsifier: detector CLEARS an executable a hook references (no false positive)"
else
  bad "falsifier: detector flagged a wired executable — RULE B false-positives"
fi

# The substring trap, pinned. This is not hypothetical: the first cut of this gate
# used `grep -F` and therefore reported heimdall-git-guard "reachable" even with
# every call site renamed away. A gate that cannot go red is not a gate.
if printf '%s\n' "$SB_UNREACHED" | grep -qx "substr-tool"; then
  ok "falsifier: a name that only occurs INSIDE a longer name is still unreachable"
else
  bad "falsifier: substring match — bin/substr-tool cleared by 'substr-tool-extended'; the gate cannot go red"
fi

if ! printf '%s\n' "$SB_UNREACHED" | grep -qx "substr-tool-extended"; then
  ok "falsifier: the longer name itself is correctly cleared by its real reference"
else
  bad "falsifier: word-boundary match is too strict — a real reference was missed"
fi

# 3b. …and the RULE A parser must actually reject a missing arm. Build a tiny
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

rm -rf "$SANDBOX"

printf "\n  bin-reachability-gate: %d passed, %d failed  (scanned %s executables)\n" \
  "$PASS" "$FAIL" "$TOTAL_BINS"
[ "$FAIL" -eq 0 ] || exit 1
