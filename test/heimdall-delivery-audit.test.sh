#!/usr/bin/env bash
# test/heimdall-delivery-audit.test.sh — falsifies bin/heimdall-delivery-audit itself.
#
# WHY THIS EXISTS. heimdall-delivery-audit was built to stop three measured overclaims
# ("queued" with nothing behind it, "landed" on dead code, "running now" on a sweep that
# had already finished) from being repeated uncaught. A claim-checker that is itself
# unverified would just be a fourth overclaim wearing a badge. This suite proves, on
# synthetic trees this repo does not depend on, that each of the tool's three sections
# does what its own header promises — and, separately, that the tool itself is actually
# wired into bin/heimdall and reachable, which is the exact class of claim ("landed")
# that started this in the first place.
#
# HERMETIC: every fixture lives under $TMP (mktemp under $TMPDIR). Nothing here reads or
# writes the real repo's .planning/, .heimdall/, or /tmp sweep-evidence directories —
# section [b]/[c] against THIS repo's real state is exercised separately, by hand, as
# acceptance evidence, never inside this suite.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/bin/heimdall-delivery-audit"
DEADCODE="$ROOT/bin/heimdall-deadcode"
HMD="$ROOT/bin/heimdall"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  PASS: %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  FAIL: %s\n" "$1"; }

command -v jq  >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required" >&2; exit 2; }
[ -x "$BIN" ]      || { echo "FATAL: $BIN missing"; exit 2; }
[ -x "$DEADCODE" ] || { echo "FATAL: $DEADCODE missing — [a] cannot be tested"; exit 2; }
[ -x "$HMD" ]      || { echo "FATAL: $HMD missing"; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmd-delivery-audit-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

# mk_fixture DIR — a minimal, real reachability tree: a git repo with one live seed
# (hooks/hooks.json) that names bin/wired-new by a whole-token reference, exactly the
# shape bin/lib/reachability.sh (via heimdall-deadcode) requires to build a closure.
mk_fixture() {
  local d="$1"
  mkdir -p "$d/bin/lib" "$d/hooks"
  git -C "$d" init -q
  git -C "$d" config user.email test@test.invalid
  git -C "$d" config user.name  test
  printf '{"hooks":{"X":"run bin/wired-new now"}}\n' > "$d/hooks/hooks.json"
  printf '#!/bin/sh\nexit 0\n' > "$d/bin/wired-new"
  chmod +x "$d/bin/wired-new"
}

# ══════════════════════════════════════════════════════════════════════════════
# [0] WIRING + REACHABILITY PROOF — non-negotiable. Instance 2 ("landed" on dead
#     code) is exactly what shipping this tool unwired would reproduce.
# ══════════════════════════════════════════════════════════════════════════════
echo "[0] wiring + reachability proof"
why_out="$("$DEADCODE" --why heimdall-delivery-audit 2>&1)"; why_rc=$?
if [ "$why_rc" -eq 0 ] && printf '%s' "$why_out" | grep -q '^REACHABLE'; then
  ok "heimdall-deadcode --why heimdall-delivery-audit -> $why_out"
else
  bad "heimdall-delivery-audit is NOT reachable per heimdall-deadcode (rc=$why_rc): $why_out"
fi

dispatch_out="$("$HMD" delivery-audit --help 2>&1)"; dispatch_rc=$?
if [ "$dispatch_rc" -eq 0 ] && printf '%s' "$dispatch_out" | grep -q 'heimdall-delivery-audit'; then
  ok "bin/heimdall delivery-audit dispatches to the real tool"
else
  bad "bin/heimdall delivery-audit did not dispatch (rc=$dispatch_rc): $dispatch_out"
fi

# ══════════════════════════════════════════════════════════════════════════════
# [a] DEAD-ON-ARRIVAL — the only ENFORCEABLE section. Hermetic synthetic repos.
# ══════════════════════════════════════════════════════════════════════════════
echo "[a-1] repo WITHOUT a dead new bin reports CLEAN"
FIX1="$TMP/fixtureA1"
mk_fixture "$FIX1"
out1="$(HMD_DELIVERY_AUDIT_ROOT="$FIX1" "$BIN" report 2>&1)"; rc1=$?
[ "$rc1" -eq 0 ] && ok "clean fixture exits 0" || bad "clean fixture exit $rc1 (want 0): $out1"
printf '%s' "$out1" | grep -qE 'reachable[[:space:]]+wired-new' && ok "clean fixture lists wired-new as reachable" || bad "clean fixture lost wired-new: $out1"
printf '%s' "$out1" | grep -q 'verdict: CLEAN' && ok "clean fixture prints verdict: CLEAN" || bad "clean fixture missing CLEAN verdict: $out1"

echo "[a-2] repo WITH an unacknowledged dead new bin reports it; a validly-exempted one is reported separately as acknowledged"
FIX2="$TMP/fixtureA2"
mk_fixture "$FIX2"
printf '#!/bin/sh\nexit 0\n' > "$FIX2/bin/orphan-new";  chmod +x "$FIX2/bin/orphan-new"
printf '#!/bin/sh\nexit 0\n' > "$FIX2/bin/exempt-new";  chmod +x "$FIX2/bin/exempt-new"
printf 'exempt-new\t2099-01-01\ttest fixture: intentionally standalone\n' > "$FIX2/bin/lib/reachability-exemptions.tsv"
out2="$(HMD_DELIVERY_AUDIT_ROOT="$FIX2" "$BIN" report 2>&1)"; rc2=$?
[ "$rc2" -eq 1 ] && ok "dirty fixture exits 1" || bad "dirty fixture exit $rc2 (want 1): $out2"
printf '%s' "$out2" | grep -q 'UNACKNOWLEDGED DEAD.*orphan-new' && ok "orphan-new flagged UNACKNOWLEDGED DEAD" || bad "orphan-new not flagged: $out2"
printf '%s' "$out2" | grep -q 'acknowledged dead.*exempt-new' && ok "exempt-new reported acknowledged dead (valid exemption honored)" || bad "exempt-new not reported acknowledged: $out2"
printf '%s' "$out2" | grep -qE 'reachable[[:space:]]+wired-new' && ok "wired-new still reachable amid the dead ones" || bad "wired-new status lost: $out2"
printf '%s' "$out2" | grep -q 'verdict: ROT' && ok "dirty fixture prints verdict: ROT" || bad "dirty fixture missing ROT verdict: $out2"

echo "[a-3] a dead bin OUTSIDE the --since window is not reported, even though it is genuinely dead"
FIX3="$TMP/fixtureA3"
mk_fixture "$FIX3"
printf '#!/bin/sh\nexit 0\n' > "$FIX3/bin/old-orphan"; chmod +x "$FIX3/bin/old-orphan"
( cd "$FIX3" && git add bin/old-orphan && GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" git commit -q -m "old commit: old-orphan" )
out3="$(HMD_DELIVERY_AUDIT_ROOT="$FIX3" "$BIN" report --since "1 day ago" 2>&1)"; rc3=$?
[ "$rc3" -eq 0 ] && ok "old, out-of-window dead bin: exit 0" || bad "exit $rc3 (want 0): $out3"
if printf '%s' "$out3" | grep -q 'old-orphan'; then bad "old-orphan LEAKED past the --since window: $out3"; else ok "old-orphan correctly excluded by the --since window"; fi
printf '%s' "$out3" | grep -qE 'reachable[[:space:]]+wired-new' && ok "wired-new (still untracked, genuinely recent) is reported" || bad "wired-new missing: $out3"

echo "[a-4] ROOT that is not a git repo -> REFUSED (exit 2), never rendered as a pass"
FIX4="$TMP/fixtureA4-not-a-repo"
mkdir -p "$FIX4/bin"
printf '#!/bin/sh\nexit 0\n' > "$FIX4/bin/whatever"; chmod +x "$FIX4/bin/whatever"
out4="$(HMD_DELIVERY_AUDIT_ROOT="$FIX4" "$BIN" report 2>&1)"; rc4=$?
[ "$rc4" -eq 2 ] && ok "non-git ROOT refuses with exit 2" || bad "non-git ROOT exit $rc4 (want 2): $out4"
printf '%s' "$out4" | grep -q 'REFUSED' && ok "non-git ROOT reports REFUSED" || bad "missing REFUSED marker: $out4"
printf '%s' "$out4" | grep -q 'NOT VERIFIED' && ok "non-git ROOT explicitly says NOT VERIFIED, not clean" || bad "missing NOT VERIFIED: $out4"

echo "[json] --json emits structured, parseable output for section [a]"
FIXJ="$TMP/fixtureJ"
mk_fixture "$FIXJ"
printf '#!/bin/sh\nexit 0\n' > "$FIXJ/bin/orphan-json"; chmod +x "$FIXJ/bin/orphan-json"
outj="$(HMD_DELIVERY_AUDIT_ROOT="$FIXJ" "$BIN" --json 2>&1)"; rcj=$?
if [ "$rcj" -eq 1 ] && printf '%s' "$outj" | jq -e '.a_dead_on_arrival.unacknowledged==1 and (.a_dead_on_arrival.unacknowledged_names | index("orphan-json") != null)' >/dev/null 2>&1; then
  ok "--json exit 1, unacknowledged_names contains orphan-json"
else
  bad "--json wrong/unparseable (rc=$rcj): $outj"
fi

# ══════════════════════════════════════════════════════════════════════════════
# [b] STALE-CLAIM — MEASURABLE/REPORTABLE only; asserted on the `artifact` subcommand,
#     which never gates (always exits 0) by design.
# ══════════════════════════════════════════════════════════════════════════════
echo "[b-1] artifact: nonexistent path -> EXISTS=0, exit 0 (a measurement, not a failure)"
outb1="$("$BIN" artifact "$TMP/does-not-exist-at-all" 2>&1)"; rcb1=$?
[ "$rcb1" -eq 0 ] && ok "nonexistent artifact: exit 0" || bad "exit $rcb1 (want 0)"
printf '%s' "$outb1" | grep -q 'EXISTS=0' && ok "nonexistent artifact: EXISTS=0" || bad "missing EXISTS=0: $outb1"

echo "[b-2] artifact: a fresh file is labeled FRESH"
freshf="$TMP/fresh.log"; : > "$freshf"
outb2="$("$BIN" artifact "$freshf" --stale-after 1800 2>&1)"
printf '%s' "$outb2" | grep -q 'LABEL=FRESH' && ok "fresh file labeled FRESH" || bad "fresh file mislabeled: $outb2"

echo "[b-3] artifact: an old file is labeled STALE"
stalef="$TMP/stale.log"; : > "$stalef"
touch -t 202001010000 "$stalef"
outb3="$("$BIN" artifact "$stalef" --stale-after 60 2>&1)"
printf '%s' "$outb3" | grep -q 'LABEL=STALE' && ok "backdated (2020) file labeled STALE" || bad "backdated file mislabeled: $outb3"

echo "[b-4] artifact --pattern: a genuinely alive process is detected"
sleep 5 & livepid=$!
outb4="$("$BIN" artifact "$TMP" --pattern "sleep 5" 2>&1)"
kill "$livepid" 2>/dev/null; wait "$livepid" 2>/dev/null
if printf '%s' "$outb4" | grep -qE "ALIVE\(pid=([0-9]+,)*${livepid}(,[0-9]+)*\)"; then
  ok "live process detected via --pattern (pid $livepid)"
else
  bad "live process not detected: $outb4"
fi

echo "[b-5] artifact --pattern: a pattern matching no process reports NOT_RUNNING"
outb5="$("$BIN" artifact "$TMP" --pattern "definitely-not-a-real-process-$$-$RANDOM" 2>&1)"
printf '%s' "$outb5" | grep -q 'NOT_RUNNING' && ok "no matching process reported NOT_RUNNING" || bad "...: $outb5"

echo "[b-6] artifact: missing required PATH argument -> exit 2"
outb6="$("$BIN" artifact 2>&1)"; rcb6=$?
[ "$rcb6" -eq 2 ] && ok "artifact with no path: exit 2" || bad "exit $rcb6 (want 2): $outb6"

# ══════════════════════════════════════════════════════════════════════════════
# [c] UNSTARTED-INTENT — NOT DETECTABLE beyond two structured stores. Every check
#     here proves the tool discloses the gap honestly rather than inventing a signal.
# ══════════════════════════════════════════════════════════════════════════════
echo "[c-1] intent: neither store exists -> both reported MISSING, gap disclosed, exit 0"
FIXC1="$TMP/fixtureC1"
mkdir -p "$FIXC1"
outc1="$(HEIMDALL_HOME="$FIXC1/.heimdall" HMD_DELIVERY_AUDIT_ROOT="$FIXC1" "$BIN" intent 2>&1)"; rcc1=$?
[ "$rcc1" -eq 0 ] && ok "intent with nothing recorded: exit 0" || bad "exit $rcc1 (want 0)"
printf '%s' "$outc1" | grep -q 'QUEUE=.*EXISTS=0' && ok "queue store reported MISSING when none exists" || bad "...: $outc1"
printf '%s' "$outc1" | grep -q 'TASKS=.*EXISTS=0' && ok "task store reported MISSING when none exists" || bad "...: $outc1"
printf '%s' "$outc1" | grep -q 'DISCLOSURE:' && ok "gap disclosed explicitly, not silently" || bad "...: $outc1"

echo "[c-2] intent: a recorded QUEUED item and a recorded todo task are both counted"
FIXC2="$TMP/fixtureC2"
mkdir -p "$FIXC2/.heimdall/queue" "$FIXC2/.planning/ledger/tasks"
{ printf '{"id":"w1","state":"QUEUED","title":"instrument metrics later"}\n'
  printf '{"id":"w2","state":"DONE","title":"unrelated finished item"}\n'
} > "$FIXC2/.heimdall/queue/work.jsonl"
printf '{"task_id":"t1","title":"instrument metrics later","state":"todo"}\n' > "$FIXC2/.planning/ledger/tasks/t1.json"
outc2="$(HEIMDALL_HOME="$FIXC2/.heimdall" HMD_DELIVERY_AUDIT_ROOT="$FIXC2" "$BIN" intent 2>&1)"; rcc2=$?
[ "$rcc2" -eq 0 ] && ok "intent with records present: exit 0" || bad "exit $rcc2 (want 0)"
printf '%s' "$outc2" | grep -q 'TOTAL=2 QUEUED=1' && ok "queue store: 2 total / 1 QUEUED" || bad "...: $outc2"
printf '%s' "$outc2" | grep -q 'TOTAL=1 TODO=1' && ok "task store: 1 total / 1 todo" || bad "...: $outc2"

echo "[c-3] intent KEYWORD filters to matching records only, in both directions"
outc3="$(HEIMDALL_HOME="$FIXC2/.heimdall" HMD_DELIVERY_AUDIT_ROOT="$FIXC2" "$BIN" intent metrics 2>&1)"
printf '%s' "$outc3" | grep -q 'QUEUED_MATCHING(metrics)=1' && ok "keyword matches the QUEUED record mentioning 'metrics'" || bad "...: $outc3"
printf '%s' "$outc3" | grep -q 'TODO_MATCHING(metrics)=1' && ok "keyword matches the todo task mentioning 'metrics'" || bad "...: $outc3"
outc3b="$(HEIMDALL_HOME="$FIXC2/.heimdall" HMD_DELIVERY_AUDIT_ROOT="$FIXC2" "$BIN" intent nonexistentkeyword 2>&1)"
if printf '%s' "$outc3b" | grep -q 'QUEUED_MATCHING(nonexistentkeyword)=0' && printf '%s' "$outc3b" | grep -q 'TODO_MATCHING(nonexistentkeyword)=0'; then
  ok "unrelated keyword correctly matches nothing"
else
  bad "...: $outc3b"
fi

echo "[c-4] intent: TASK_MECHANISM_REACHABILITY tracks the real reachability engine, both directions"
FIXC4="$TMP/fixtureC4"
mk_fixture "$FIXC4"
printf '#!/bin/sh\nexit 0\n' > "$FIXC4/bin/heimdall-task"; chmod +x "$FIXC4/bin/heimdall-task"
outc4a="$(HEIMDALL_HOME="$FIXC4/.heimdall" HMD_DELIVERY_AUDIT_ROOT="$FIXC4" "$BIN" intent 2>&1)"
printf '%s' "$outc4a" | grep -q 'TASK_MECHANISM_REACHABILITY=DEAD' && ok "unreferenced heimdall-task in the fixture reads DEAD" || bad "...: $outc4a"
printf '{"hooks":{"X":"run bin/wired-new now","Y":"run bin/heimdall-task now"}}\n' > "$FIXC4/hooks/hooks.json"
outc4b="$(HEIMDALL_HOME="$FIXC4/.heimdall" HMD_DELIVERY_AUDIT_ROOT="$FIXC4" "$BIN" intent 2>&1)"
printf '%s' "$outc4b" | grep -q 'TASK_MECHANISM_REACHABILITY=REACHABLE' && ok "once a live seed references it, heimdall-task reads REACHABLE" || bad "...: $outc4b"

echo "[c-5] the default report (not just the intent subcommand) also renders section [c] honestly"
outc5="$(HMD_DELIVERY_AUDIT_ROOT="$FIXC1" "$BIN" report 2>&1)"
if printf '%s' "$outc5" | grep -q '\[c\] UNSTARTED-INTENT' && printf '%s' "$outc5" | grep -q 'MISSING' && printf '%s' "$outc5" | grep -q 'DISCLOSURE:'; then
  ok "default report's section [c] renders MISSING stores + DISCLOSURE"
else
  bad "default report section [c] incomplete: $outc5"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
