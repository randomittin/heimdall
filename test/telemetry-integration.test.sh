#!/usr/bin/env bash
# telemetry-integration.test.sh — the END-TO-END gate for Heimdall's telemetry
# layer. NOT unit-only: it drives the REAL wired flow across ALL pieces on ONE
# shared telemetry home — substrate (a), install events (b), per-run + card (c),
# hmd report (d), A/B holdout (e) — and asserts they agree. The metering/launcher
# lesson: integration bugs pass unit tests; this exercises the seams between pieces.
#
# Any secret-shaped string here is ASSEMBLED AT RUNTIME (the fixture-secret
# convention) — no static secret literal in this source.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$(command -v python3 || true)"
RT="$REPO/bin/lib/run_telemetry.py"
TLM="$REPO/bin/heimdall-telemetry"
RPT="$REPO/bin/heimdall-report"
HLD="$REPO/bin/heimdall-holdout"
TELE="$REPO/bin/lib/telemetry.py"
[ -n "$PY" ] || { echo "FATAL: python3 absent"; exit 2; }
for f in "$RT" "$TLM" "$RPT" "$HLD" "$TELE"; do
  [ -f "$f" ] || { echo "FATAL: missing piece $f"; exit 2; }
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
H="$WORK/home"                 # the ONE shared telemetry home every piece writes to
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

events_file() { find "$H" -name events.ndjson 2>/dev/null | head -1; }
export REPO
read_run() { HOME_R="$H" RID="$1" "$PY" - <<'PYEOF'
import os, sys, json
sys.path.insert(0, os.path.join(os.environ["REPO"], "bin", "lib"))
import telemetry
evs = telemetry.read_events(home=os.environ["HOME_R"], run_id=os.environ["RID"])
print(json.dumps(evs))
PYEOF
}

echo "── (1) INSTALL: each step emits; a claude-mem failure is captured with step+class ──"
"$TLM" emit --type install_step --step setup            --outcome succeeded --duration-ms 30  --home "$H" >/dev/null
"$TLM" emit --type install_step --step auth             --outcome succeeded --duration-ms 40  --home "$H" >/dev/null
"$TLM" emit --type install_step --step companion:claude-mem --outcome started --home "$H" >/dev/null
"$TLM" emit --type install_step --step companion:claude-mem --outcome failed \
    --error-class npm-exec-failed --error-step companion:claude-mem --duration-ms 900 --home "$H" >/dev/null
DROP="$("$RPT" aggregate --json --home "$H" 2>/dev/null)"
if grep -q 'claude-mem' <<<"$DROP" && grep -q 'npm-exec-failed' <<<"$DROP"; then
  ok "(1) install steps emit; claude-mem failure captured WITH step + error class"
else
  bad "(1) claude-mem install failure not captured: $DROP"
fi

echo "── (2) PER-RUN: a run fills the summary card tokens+commits from REAL telemetry ──"
RUN1="$("$PY" "$RT" new-run-id)"
TOK='{"input_tokens":1000,"output_tokens":200,"total_tokens":1200,"total_cost_usd":0.05,"cache_read_tokens":0,"cache_creation_tokens":0}'
"$PY" "$RT" phase   --run-id "$RUN1" --home "$H" --phase planning --outcome succeeded --duration-ms 4200 >/dev/null
"$PY" "$RT" gate    --run-id "$RUN1" --home "$H" --gate test --outcome passed >/dev/null
"$PY" "$RT" token   --run-id "$RUN1" --home "$H" --tokens "$TOK" >/dev/null
"$PY" "$RT" outcome --run-id "$RUN1" --home "$H" --outcome passed >/dev/null
"$PY" "$RT" commit  --run-id "$RUN1" --home "$H" --commit aaa1111 >/dev/null
"$PY" "$RT" commit  --run-id "$RUN1" --home "$H" --commit bbb2222 >/dev/null
CARD="$("$PY" "$RT" card-data --run-id "$RUN1" --home "$H")"
CT="$(printf '%s' "$CARD" | "$PY" -c 'import sys,json; d=json.load(sys.stdin); print(d.get("total_tokens"), d.get("commits"), d.get("has_tokens"))')"
if [ "$CT" = "1200 2 True" ]; then
  ok "(2) card fills REAL tokens=1200 + commits=2 from telemetry (not hardcoded blanks)"
else
  bad "(2) card did not fill from real telemetry: $CARD"
fi

echo "── (3) DENY→FIX→PASS produces a gate blocked→passed record with stage+loc ──"
LOC="auth.py:5"
"$PY" "$RT" gate --run-id "$RUN1" --home "$H" --gate secret-scan --outcome blocked --loc "$LOC" >/dev/null
"$PY" "$RT" phase --run-id "$RUN1" --home "$H" --phase fix-wave --outcome succeeded >/dev/null
"$PY" "$RT" gate --run-id "$RUN1" --home "$H" --gate secret-scan --outcome passed --loc "$LOC" >/dev/null
EVS="$(read_run "$RUN1")"
BLK="$(printf '%s' "$EVS" | "$PY" -c 'import sys,json
e=json.load(sys.stdin); g=[x for x in e if x.get("event_type")=="gate" and x.get("gate")=="secret-scan"]
outs=[x.get("outcome") for x in g]; locs={x.get("loc") for x in g}
print("OK" if ("blocked" in outs and "passed" in outs and outs.index("blocked")<outs.index("passed") and "auth.py:5" in locs) else "NO")')"
[ "$BLK" = "OK" ] && ok "(3) deny→fix→pass: secret-scan blocked@$LOC → passed, ordered, with loc" \
                   || bad "(3) deny→fix→pass record wrong: $EVS"

echo "── (4) hmd report renders per-run AND aggregate from the real events ──"
AGG="$("$RPT" aggregate --json --home "$H" 2>/dev/null)"
PR_RC=0; "$RPT" run "$RUN1" --home "$H" >/dev/null 2>&1 || PR_RC=$?
HAS_GATE="$(grep -c 'secret-scan' <<<"$AGG")"
HAS_DROP="$(grep -c 'claude-mem' <<<"$AGG")"
if [ "$PR_RC" -eq 0 ] && [ "$HAS_GATE" -ge 1 ] && [ "$HAS_DROP" -ge 1 ]; then
  ok "(4) report: per-run renders (rc=0) + aggregate shows gate-frequency + install drop-off"
else
  bad "(4) report incomplete (per-run rc=$PR_RC gate=$HAS_GATE drop=$HAS_DROP)"
fi

echo "── (5) HOLDOUT honesty: measured needs both arms; no control ⇒ never a fabricated number ──"
RUN2="$("$PY" "$RT" new-run-id)"
"$PY" "$RT" token --run-id "$RUN2" --home "$H" \
   --tokens '{"input_tokens":400,"output_tokens":100,"total_tokens":500,"total_cost_usd":0.02,"cache_read_tokens":0,"cache_creation_tokens":0}' >/dev/null
HEIMDALL_HOLDOUT=control "$HLD" assign --run-id "$RUN2" --home "$H" >/dev/null
"$HLD" assign --run-id "$RUN1" --home "$H" >/dev/null   # default → treatment
D_BOTH="$("$HLD" delta --home "$H" --min-n 1 2>/dev/null)"
M_BOTH="$(printf '%s' "$D_BOTH" | "$PY" -c 'import sys,json; print(json.load(sys.stdin).get("measured"))')"
H2="$WORK/home2"; RUN3="$("$PY" "$RT" new-run-id)"
"$PY" "$RT" token --run-id "$RUN3" --home "$H2" --tokens "$TOK" >/dev/null
"$HLD" assign --run-id "$RUN3" --home "$H2" >/dev/null
D_ONE="$("$HLD" delta --home "$H2" --min-n 1 2>/dev/null)"
ONE="$(printf '%s' "$D_ONE" | "$PY" -c 'import sys,json; d=json.load(sys.stdin); print(d.get("measured"), d.get("delta"))')"
if [ "$M_BOTH" = "True" ] && [ "$ONE" = "False None" ]; then
  ok "(5) holdout: both arms ⇒ measured; one arm ⇒ measured=False, delta=None (NEVER fabricated)"
else
  bad "(5) holdout honesty broken (both=$M_BOTH one='$ONE')"
fi

echo "── (6) PRIVACY: a runtime-assembled secret in an event field never reaches the store ──"
P="ghp_"; A="0123456789abcdefghij"; B="ABCDEFGHIJ012345"; SECRET="${P}${A}${B}"
"$TLM" emit --type outcome --run-id "$RUN1" --outcome failed --error-class boom \
    --error-detail "leaked=$SECRET" --home "$H" >/dev/null
EF="$(events_file)"
RAW_HIT=0; [ -n "$EF" ] && grep -q "$SECRET" "$EF" && RAW_HIT=1
GL_RC=0
if command -v gitleaks >/dev/null 2>&1 && [ -n "$EF" ]; then
  gitleaks detect --no-git --no-banner --source "$EF" >/dev/null 2>&1 || GL_RC=$?
fi
if [ "$RAW_HIT" -eq 0 ] && [ "$GL_RC" -eq 0 ]; then
  ok "(6) the secret is ABSENT from the store (scrubbed) + gitleaks finds nothing"
else
  bad "(6) secret leaked into store (raw=$RAW_HIT gitleaks_rc=$GL_RC) — telemetry became a leak surface"
fi

echo "── (7) DISABLED ⇒ identical: HEIMDALL_TELEMETRY=off writes nothing, card shows '—' ──"
HOFF="$WORK/off"; RUNX="$("$PY" "$RT" new-run-id)"
HEIMDALL_TELEMETRY=off "$PY" "$RT" token --run-id "$RUNX" --home "$HOFF" --tokens "$TOK" >/dev/null
CARD_OFF="$(HEIMDALL_TELEMETRY=off "$PY" "$RT" card-data --run-id "$RUNX" --home "$HOFF")"
OFF_HAS="$(printf '%s' "$CARD_OFF" | "$PY" -c 'import sys,json; print(json.load(sys.stdin).get("has_tokens"))')"
NO_FILE=1; find "$HOFF" -name events.ndjson 2>/dev/null | grep -q . && NO_FILE=0
if [ "$OFF_HAS" = "False" ] && [ "$NO_FILE" -eq 1 ]; then
  ok "(7) disabled telemetry: no events written, card honest-empty (renders '—'), no crash"
else
  bad "(7) disabled telemetry not inert (has_tokens=$OFF_HAS no_file=$NO_FILE)"
fi

echo "── (8) GRACEFUL: a telemetry write failure does NOT fail the caller ──"
HBAD="$WORK/blocked"; : > "$HBAD"   # a FILE where the home dir should be → store write must fail
set +e
"$PY" "$RT" token --run-id "$("$PY" "$RT" new-run-id)" --home "$HBAD" --tokens "$TOK" >/dev/null 2>&1
G_RC=$?
"$TLM" emit --type phase --phase waves --outcome started --home "$HBAD" >/dev/null 2>&1
T_RC=$?
set -e 2>/dev/null || true
if [ "$G_RC" -eq 0 ] && [ "$T_RC" -eq 0 ]; then
  ok "(8) write failure degrades gracefully — emit returns 0, the run continues"
else
  bad "(8) telemetry write failure propagated to caller (run rc=$G_RC tlm rc=$T_RC)"
fi

echo
echo "telemetry-integration: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
