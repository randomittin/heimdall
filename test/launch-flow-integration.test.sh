#!/usr/bin/env bash
# launch-flow-integration.test.sh — the END-TO-END gate for the internal-launch
# readiness work: it chains the COLD-LAUNCH seam that the per-piece unit tests
# (update-prompt.test.sh, install-stranger.sh) each cover in isolation — update-
# check (piece 1) + F1 onboarding (piece 3) + the demo pointer — into ONE flow,
# in both non-TTY and a real pty, and proves the pointed-to first task runs.
#
# Drives the launcher via HEIMDALL_LIB_ONLY=1 (source bin/heimdall, call the F1 +
# update functions) — the same deterministic harness the unit tests use, so no
# 2-minute reinstall and no flake. Any version string here is a tag literal, not a
# secret. The metering/launcher lesson: integration bugs pass unit tests.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HMD="$REPO/bin/heimdall"
[ -f "$HMD" ] || { echo "FATAL: bin/heimdall missing"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

seed_cache() { # $1=path $2=installed $3=latest $4=epoch
  mkdir -p "$(dirname "$1")"
  printf '{"checked_epoch":%s,"installed":"%s","latest":"%s"}\n' "$4" "$2" "$3" > "$1"
}
ONBOARD='HEIMDALL_LIB_ONLY=1 bash -c '\''cd "'"$REPO"'"; source ./bin/heimdall; F1_WAS_FIRST_RUN=1; F1_CONTEXT=empty-dir; f1_onboard_if_cold'\'''
print_cache() { # installed cache → notice text (bypasses the [ -t 1 ] guard)
  HEIMDALL_LIB_ONLY=1 bash -c 'source "'"$HMD"'"; _update_print_from_cache "'"$1"'" "'"$2"'"' 2>&1
}
have_pty() { command -v script >/dev/null 2>&1; }
pty_run() { script -q /dev/null bash -c "$1" 2>&1; }

echo "── (1) COLD LAUNCH NON-TTY is inert + never hangs (the hang-discipline seam) ──"
OUT_NT="$(eval "$ONBOARD" 2>&1)"            # onboarding piped (non-TTY) → must be silent
VER="$(HEIMDALL_LIB_ONLY=0 "$HMD" version 2>/dev/null | head -1)"   # reserved subcmd, non-TTY
VRC=$?
if [ -z "$OUT_NT" ] && printf '%s' "$VER" | grep -q '^Heimdall v[0-9]' && [ "$VRC" -eq 0 ]; then
  ok "(1) non-TTY: onboarding silent + reserved 'version' completes fast ($VER), no hang"
else
  bad "(1) non-TTY cold launch not inert (onboard='$OUT_NT' ver='$VER' rc=$VRC)"
fi

echo "── (2) COLD LAUNCH on a real TTY orients the newcomer + points to the demo ──"
if have_pty; then
  OUT_TTY="$(pty_run "$ONBOARD")"
  if printf '%s' "$OUT_TTY" | grep -qi 'demo --run' \
     && printf '%s' "$OUT_TTY" | grep -qiE 'new here|heimdall|build'; then
    ok "(2) TTY cold launch: orients (what Heimdall is) + points to 'hmd demo --run'"
  else
    bad "(2) TTY onboarding did not orient/point to demo: $OUT_TTY"
  fi
else
  ok "(2) SKIP — no pty tool (script) on this host"
fi

echo "── (3) UPDATE-CHECK accurate: a behind install gets a ONE-LINE notice ──"
CB="$WORK/cache-behind.json"; seed_cache "$CB" "v2.0.0" "v2.0.5" "$(date +%s)"
N="$(print_cache "v2.0.0" "$CB")"
LINES="$(printf '%s' "$N" | grep -c .)"
if [ "$LINES" -eq 1 ] && printf '%s' "$N" | grep -q 'v2.0.5' \
   && printf '%s' "$N" | grep -q 'v2.0.0' && printf '%s' "$N" | grep -qi 'hmd update'; then
  ok "(3) behind: one-line notice names latest(v2.0.5)+installed(v2.0.0)+'hmd update'"
else
  bad "(3) behind notice wrong (lines=$LINES): $N"
fi

echo "── (4) UPDATE-CHECK no false 'behind' on a current install (FALSIFIABLE) ──"
CC="$WORK/cache-current.json"; seed_cache "$CC" "v2.0.5" "v2.0.5" "$(date +%s)"
NC="$(print_cache "v2.0.5" "$CC")"
if [ -z "$(printf '%s' "$NC" | tr -d '[:space:]')" ]; then
  ok "(4) current install prints NO notice (no false 'behind' — a regression reds this)"
else
  bad "(4) a CURRENT install wrongly printed a notice: $NC"
fi

echo "── (5) SEAM: update notice + onboarding COMPOSE in one cold launch (no clobber) ──"
if have_pty; then
  COMP="HEIMDALL_LIB_ONLY=1 bash -c 'cd \"$REPO\"; source ./bin/heimdall; _update_print_from_cache v2.0.0 \"$CB\"; F1_WAS_FIRST_RUN=1; F1_CONTEXT=empty-dir; f1_onboard_if_cold'"
  OUT_C="$(pty_run "$COMP")"
  if printf '%s' "$OUT_C" | grep -q 'v2.0.5' && printf '%s' "$OUT_C" | grep -qi 'demo --run'; then
    ok "(5) one cold launch shows BOTH the update notice AND the onboarding demo-pointer"
  else
    bad "(5) update + onboarding did not compose: $OUT_C"
  fi
else
  ok "(5) SKIP — no pty tool"
fi

echo "── (6) DEMO POINTER LANDS: the pointed-to first task ('hmd demo') actually runs ──"
# The newcomer's first move must resolve to a REAL runnable command that emits its
# tour — not a dead pointer. --dry is the safe non-executing path; assert it runs +
# narrates (the pre-existing --dry exit is 1 by design, so test OUTPUT, not rc).
DEMO_OUT=""
if [ -x "$REPO/bin/heimdall-demo" ]; then
  DEMO_OUT="$("$REPO/bin/heimdall-demo" --dry 2>&1)"   # exit is 1 by design; we test OUTPUT
fi
if [ -n "$DEMO_OUT" ] && printf '%s' "$DEMO_OUT" | grep -qiE 'demo|build|heimdall'; then
  ok "(6) 'hmd demo --dry' runs + narrates its tour (the demo pointer is a live command)"
else
  bad "(6) the demo pointer does not resolve to a runnable, narrating command"
fi

echo
echo "launch-flow-integration: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
