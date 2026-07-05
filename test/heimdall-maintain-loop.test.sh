#!/usr/bin/env bash
# test/heimdall-maintain-loop.test.sh — acceptance for the DURABLE maintainer
# AUTOPILOT loop (bin/heimdall-maintain-loop -> bin/lib/maintain_loop.py).
#
# Hermetic: the token METER and the issue engine's GATE are driven through env
# seams (a fake heimdall-tokens binary + the --evidence gate command), so nothing
# here touches a live transcript, the network, or a real model. The loop drives the
# REAL issue_loop.run_once against a REAL throwaway git repo + REAL queue store — no
# canned result shapes — so the wrapper is proven over the honest engine it wraps.
#
# FALSIFIABLE claims proven:
#   (1) BUDGET CAP — a meter reading OVER the cap STOPS(budget) and does NOT spend:
#       the queued issue is untouched, zero cycles ran (the can't-burn-tokens guard).
#   (2) FAIL-SAFE — a MISSING/unreadable meter is treated as NEAR-CAP -> STOP(budget)
#       (the loop never runs blind on tokens). Flip: a small reading DOES run.
#   (3) REPEATED-FAILURE — N consecutive gate failures on DISTINCT issues STOP the
#       loop (repeated-failure) after exactly N cycles.
#   (4) EMPTY-QUEUE — nothing pickable -> STOP(empty-queue), zero cycles.
#   (5) CHECKPOINT — the header block appended to .planning/CHECKPOINT.md is valid +
#       machine-readable (parses to cycle:int, budget/queue/tally:dict, stop).
#   (6) HEARTBEAT — the receipt renders REAL numbers from the last block (cycle N,
#       fixed/PR counts, budget %, last verdict) — falsified by a FAIL run's numbers.
#   (7) RESUME-HINT — emits the re-arm line ONLY when stop:null + enabled + budget
#       remains; silent on a terminal stop, silent when disabled.
#   (8) DISABLED — the loop NEVER runs when maintainer.enabled != true (queue
#       untouched, zero cycles).
#   (9) APPROVAL PARK — a critical issue with no decision is PARKED (approval-wait)
#       and the loop CONTINUES with the others (one gated issue never blocks it).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CMD="$ROOT/bin/heimdall-maintain-loop"
LIB="$ROOT/bin/lib/maintain_loop.py"
QCMD="$ROOT/bin/heimdall-issue-queue"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
PY="$(command -v python3 || command -v python)"
[ -x "$CMD" ] || { echo "FATAL: $CMD not executable" >&2; exit 2; }
[ -f "$LIB" ] || { echo "FATAL: $LIB missing" >&2; exit 2; }

WORK="$(mktemp -d -t "maintain-loop-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

export PYTHONPATH="$ROOT/bin/lib:${PYTHONPATH:-}"

# ── fake token meters (env-seam substitutes for the real session meter) ───────
mk_meter() {
  # $1 = dest path ; $2 = total_tokens to report (a clean, error-free record).
  local dest="$1" tok="$2"
  cat > "$dest" <<METER
#!/usr/bin/env bash
echo '{"total_tokens": ${tok}, "total_cost_usd": 0.0}'
METER
  chmod +x "$dest"
}
METER_SMALL="$WORK/meter_small"; mk_meter "$METER_SMALL" 10        # well under cap
METER_BIG="$WORK/meter_big"; mk_meter "$METER_BIG" 700000          # over the cap
METER_MISSING="$WORK/meter_does_not_exist"                          # absent -> near-cap

# ── a throwaway git repo + enabled maintainer state per scenario ──────────────
new_repo() {
  # Prints a fresh repo path. Each scenario is isolated (own queue/home/state).
  local name="$1"
  local repo="$WORK/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@runheimdall.dev"
  git -C "$repo" config user.name "test"
  printf 'module init\n' > "$repo/app.py"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "init"
  printf '%s' "$repo"
}

enable_state() {
  # $1 = repo ; $2 = enabled (true|false) ; $3 = budget_tokens (optional, default 600000)
  local repo="$1" enabled="$2" budget="${3:-600000}"
  cat > "$repo/heimdall-state.json" <<STATE
{"maintainer":{"enabled":${enabled},"budget_tokens":${budget},"autopilot":{"cycle":0,"stop":null,"last_heartbeat":null,"approvals":[]}}}
STATE
}

seed() {
  # $1 = repo ; $2 = number ; $3 = label (bug|p0)
  local repo="$1" num="$2" label="${3:-bug}"
  local raw
  raw="$("$PY" -c 'import json,sys; print(json.dumps({"repo":"acme/widget","number":int(sys.argv[1]),"title":"fix the thing","body":"broken","labels":[{"name":sys.argv[2]}],"created_at":"2020-06-01T00:00:00Z"}))' "$num" "$label")"
  HEIMDALL_HOME="$repo/.heimdall" "$QCMD" ingest --source github --raw "$raw" --repo "$repo" >/dev/null
}

# run the loop in a scenario's env. Extra args after the meter are passed through.
run_loop() {
  local repo="$1" meter="$2"; shift 2
  env HEIMDALL_HOME="$repo/.heimdall" \
      HEIMDALL_STATE_FILE="$repo/heimdall-state.json" \
      HEIMDALL_TOKENS_BIN="$meter" \
      "$CMD" run --repo "$repo" "$@" 2>/dev/null
}

jget() { printf '%s' "$1" | jq -r "$2"; }

echo "── (1) BUDGET CAP — over-cap meter STOPS(budget) and spends NOTHING ──────────"
R1="$(new_repo budget)"; enable_state "$R1" true 600000; seed "$R1" 1
OUT="$(run_loop "$R1" "$METER_BIG" --evidence "true")"
if [ "$(jget "$OUT" '.stop')" = "budget" ] && [ "$(jget "$OUT" '.cycles')" = "0" ]; then
  ok "over-cap meter -> STOP(budget), 0 cycles"
else
  bad "over-cap did not STOP(budget)/0 cycles (stop=$(jget "$OUT" '.stop') cycles=$(jget "$OUT" '.cycles'))"
fi
# can't-burn-tokens: the queued issue is UNTOUCHED (never claimed / picked).
QST="$(HEIMDALL_HOME="$R1/.heimdall" "$QCMD" status --repo "$R1")"
if [ "$(jget "$QST" '.queued')" = "1" ] && [ "$(jget "$QST" '.in_flight')" = "0" ]; then
  ok "can't-burn-tokens: issue stayed queued, nothing claimed"
else
  bad "budget stop still touched the queue (queued=$(jget "$QST" '.queued') in_flight=$(jget "$QST" '.in_flight'))"
fi

echo "── (2) FAIL-SAFE — a MISSING meter is NEAR-CAP -> STOP(budget) (never blind) ──"
R2="$(new_repo failsafe)"; enable_state "$R2" true 600000; seed "$R2" 2
OUT="$(run_loop "$R2" "$METER_MISSING" --evidence "true")"
if [ "$(jget "$OUT" '.stop')" = "budget" ] && [ "$(jget "$OUT" '.cycles')" = "0" ]; then
  ok "missing meter -> STOP(budget) (fail-safe: assume near-cap, never run blind)"
else
  bad "missing meter did NOT fail safe (stop=$(jget "$OUT" '.stop'))"
fi
# FLIP: a small reading in the SAME repo DOES run -> proves the stop was the meter.
OUT="$(run_loop "$R2" "$METER_SMALL" --evidence "true")"
if [ "$(jget "$OUT" '.stop')" != "budget" ] && [ "$(jget "$OUT" '.cycles')" -ge 1 ]; then
  ok "flip: a readable under-cap meter DOES run (the stop was genuinely the meter)"
else
  bad "flip failed: under-cap meter still refused to run (stop=$(jget "$OUT" '.stop'))"
fi

echo "── (3) REPEATED-FAILURE — 3 gate-fails on distinct issues -> STOP(repeated) ──"
R3="$(new_repo repeated)"; enable_state "$R3" true 600000
seed "$R3" 31; seed "$R3" 32; seed "$R3" 33; seed "$R3" 34
OUT="$(run_loop "$R3" "$METER_SMALL" --evidence "false" --max-failures 3)"
if [ "$(jget "$OUT" '.stop')" = "repeated-failure" ] && [ "$(jget "$OUT" '.cycles')" = "3" ]; then
  ok "3 consecutive gate-fails -> STOP(repeated-failure) after exactly 3 cycles"
else
  bad "repeated-failure guard broken (stop=$(jget "$OUT" '.stop') cycles=$(jget "$OUT" '.cycles'))"
fi
if [ "$(jget "$OUT" '.tally.flagged')" = "3" ] && [ "$(jget "$OUT" '.tally.fixed')" = "0" ]; then
  ok "all 3 flagged, none fixed (honest — a failed gate never PR's)"
else
  bad "failure tally wrong (flagged=$(jget "$OUT" '.tally.flagged') fixed=$(jget "$OUT" '.tally.fixed'))"
fi

echo "── (4) EMPTY-QUEUE — nothing pickable -> STOP(empty-queue), 0 cycles ─────────"
R4="$(new_repo empty)"; enable_state "$R4" true 600000  # NO issues seeded
OUT="$(run_loop "$R4" "$METER_SMALL" --evidence "true")"
if [ "$(jget "$OUT" '.stop')" = "empty-queue" ] && [ "$(jget "$OUT" '.cycles')" = "0" ]; then
  ok "empty queue -> STOP(empty-queue), 0 cycles"
else
  bad "empty queue did not STOP(empty-queue)/0 (stop=$(jget "$OUT" '.stop') cycles=$(jget "$OUT" '.cycles'))"
fi

echo "── (5) CHECKPOINT — the header block is valid + machine-readable ─────────────"
R5="$(new_repo checkpoint)"; enable_state "$R5" true 600000; seed "$R5" 5
run_loop "$R5" "$METER_SMALL" --evidence "true" >/dev/null
CKPT="$R5/.planning/CHECKPOINT.md"
if [ -f "$CKPT" ] && grep -q '<!-- heimdall-autopilot' "$CKPT"; then
  ok "CHECKPOINT.md exists and carries an autopilot header block"
else
  bad "no autopilot header block written to CHECKPOINT.md"
fi
# machine-readable: the engine's own parser must decode the last block to typed fields.
PARSED="$("$PY" - "$R5" <<'PYEOF'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "..", "..", "bin", "lib"))
import maintain_loop as m
b = m.parse_last_block(os.path.join(sys.argv[1], ".planning"))
ok = (isinstance(b, dict)
      and isinstance(b.get("cycle"), int)
      and isinstance(b.get("budget"), dict)
      and isinstance(b.get("queue"), dict)
      and isinstance(b.get("tally"), dict)
      and "stop" in b
      and isinstance(b["budget"].get("cap_tokens"), int))
print("OK" if ok else "BAD")
PYEOF
)"
# fall back to a pure-jq check on a hand-extracted block (independent of the lib).
LASTBLOCK="$("$PY" -c 'import sys;t=open(sys.argv[1]).read();i=t.rfind("<!-- heimdall-autopilot");s=t[i:];print(s[:s.find("-->")])' "$CKPT")"
BUDGET_LINE="$(printf '%s\n' "$LASTBLOCK" | sed -n 's/^budget: //p')"
if [ "$PARSED" = "OK" ]; then
  ok "the block parses to typed fields (cycle:int, budget/queue/tally:dict, stop present)"
else
  bad "the checkpoint block did not parse to the expected typed shape"
fi
if printf '%s' "$BUDGET_LINE" | jq -e '.cap_tokens == 600000 and (.used|type=="number")' >/dev/null 2>&1; then
  ok "each block value is valid JSON (budget parses via jq independently of the lib)"
else
  bad "block values are not valid JSON (budget line: $BUDGET_LINE)"
fi

echo "── (6) HEARTBEAT — renders REAL numbers from the last block ──────────────────"
# reuse R5 (one PASS cycle). The heartbeat must show cycle 1, 1 fixed, 1 PR, PASS.
HB="$(env HEIMDALL_HOME="$R5/.heimdall" HEIMDALL_STATE_FILE="$R5/heimdall-state.json" \
       HEIMDALL_TOKENS_BIN="$METER_SMALL" "$CMD" heartbeat --repo "$R5")"
if printf '%s' "$HB" | grep -q 'cycle 1' \
   && printf '%s' "$HB" | grep -q '1 fixed' \
   && printf '%s' "$HB" | grep -q '1 PR' \
   && printf '%s' "$HB" | grep -q 'PASS'; then
  ok "heartbeat renders real numbers: '$HB'"
else
  bad "heartbeat did not render the real PASS numbers: '$HB'"
fi
# FALSIFIER: a FAIL-only run's heartbeat shows 0 fixed / flagged>0 / FAIL — not PASS.
R6="$(new_repo hb_fail)"; enable_state "$R6" true 600000; seed "$R6" 61
run_loop "$R6" "$METER_SMALL" --evidence "false" >/dev/null
HBF="$(env HEIMDALL_HOME="$R6/.heimdall" HEIMDALL_STATE_FILE="$R6/heimdall-state.json" \
        HEIMDALL_TOKENS_BIN="$METER_SMALL" "$CMD" heartbeat --repo "$R6")"
if printf '%s' "$HBF" | grep -q '0 fixed' \
   && printf '%s' "$HBF" | grep -q 'FAIL' \
   && ! printf '%s' "$HBF" | grep -q 'PASS'; then
  ok "falsifier: a FAIL run's heartbeat shows 0 fixed + FAIL (numbers are not canned)"
else
  bad "heartbeat numbers look canned — FAIL run did not flip them: '$HBF'"
fi

echo "── (7) RESUME-HINT — emits ONLY when stop:null + enabled + budget remains ────"
# positive: a --max 1 pause with a 2nd issue queued leaves stop:null -> re-arm.
R7="$(new_repo resume)"; enable_state "$R7" true 600000; seed "$R7" 71; seed "$R7" 72
run_loop "$R7" "$METER_SMALL" --max 1 --evidence "true" >/dev/null
HINT="$(env HEIMDALL_STATE_FILE="$R7/heimdall-state.json" HEIMDALL_TOKENS_BIN="$METER_SMALL" \
         "$CMD" resume-hint --repo "$R7")"
if printf '%s' "$HINT" | grep -q '/loop 30m /hmd:maintain-check'; then
  ok "positive: stop:null + enabled + budget -> re-arm line emitted"
else
  bad "resume-hint did NOT emit on a re-armable pause (got: '$HINT')"
fi
# negative A: a terminal STOP (empty-queue) must NOT re-arm.
R8="$(new_repo resume_stopped)"; enable_state "$R8" true 600000; seed "$R8" 81
run_loop "$R8" "$METER_SMALL" --evidence "true" >/dev/null   # drains -> empty-queue stop
HINT8="$(env HEIMDALL_STATE_FILE="$R8/heimdall-state.json" HEIMDALL_TOKENS_BIN="$METER_SMALL" \
          "$CMD" resume-hint --repo "$R8")"
if [ -z "$HINT8" ]; then
  ok "negative: a terminal STOP(empty-queue) emits NOTHING (no auto-resurrect)"
else
  bad "resume-hint re-armed after a terminal stop (got: '$HINT8')"
fi
# negative B: disabled maintainer must NOT re-arm even with a stop:null checkpoint.
enable_state "$R7" false 600000   # flip the SAME re-armable checkpoint to disabled
HINT7D="$(env HEIMDALL_STATE_FILE="$R7/heimdall-state.json" HEIMDALL_TOKENS_BIN="$METER_SMALL" \
           "$CMD" resume-hint --repo "$R7")"
if [ -z "$HINT7D" ]; then
  ok "negative: disabled maintainer emits NOTHING (even on a stop:null checkpoint)"
else
  bad "resume-hint re-armed while disabled (got: '$HINT7D')"
fi

echo "── (8) DISABLED — the loop NEVER runs when maintainer.enabled != true ────────"
R9="$(new_repo disabled)"; enable_state "$R9" false 600000; seed "$R9" 9
OUT="$(run_loop "$R9" "$METER_SMALL" --evidence "true")"
if [ "$(jget "$OUT" '.stop')" = "disabled" ] && [ "$(jget "$OUT" '.cycles')" = "0" ]; then
  ok "disabled -> stop=disabled, 0 cycles"
else
  bad "disabled loop still ran (stop=$(jget "$OUT" '.stop') cycles=$(jget "$OUT" '.cycles'))"
fi
QST9="$(HEIMDALL_HOME="$R9/.heimdall" "$QCMD" status --repo "$R9")"
if [ "$(jget "$QST9" '.queued')" = "1" ] && [ "$(jget "$QST9" '.in_flight')" = "0" ]; then
  ok "disabled: the queue is untouched (nothing claimed)"
else
  bad "disabled loop touched the queue (queued=$(jget "$QST9" '.queued'))"
fi
# and NO checkpoint is written when nothing ran.
if [ ! -f "$R9/.planning/CHECKPOINT.md" ]; then
  ok "disabled: no checkpoint written (the loop truly did nothing)"
else
  bad "disabled loop still wrote a checkpoint"
fi

echo "── (9) APPROVAL PARK — a critical issue is parked; the loop CONTINUES ─────────"
R10="$(new_repo approval)"; enable_state "$R10" true 600000
seed "$R10" 100 p0     # critical (p0 label) -> requires approval, no decision
seed "$R10" 200 bug    # normal -> fixable
OUT="$(run_loop "$R10" "$METER_SMALL" --evidence "true")"
if [ "$(jget "$OUT" '.tally.parked')" = "1" ] && [ "$(jget "$OUT" '.tally.fixed')" = "1" ]; then
  ok "critical parked (1) while the normal issue was fixed (1) — one gate never blocks"
else
  bad "approval park/continue broken (parked=$(jget "$OUT" '.tally.parked') fixed=$(jget "$OUT" '.tally.fixed'))"
fi
PARK_REASON="$("$PY" -c 'import json,sys;d=json.load(open(sys.argv[1]));fl=d.get("flagged",{});print(fl.get("github:acme/widget#100",{}).get("reason",""))' "$R10/.heimdall/issues/queue.json" 2>/dev/null || true)"
if [ "$PARK_REASON" = "approval-wait" ]; then
  ok "the parked critical is flagged 'approval-wait' (kept out of the fix path)"
else
  bad "parked issue flag reason was '$PARK_REASON' (expected 'approval-wait')"
fi
# once a human decision is recorded, a fresh drain picks it up (no longer parked).
env HEIMDALL_STATE_FILE="$R10/heimdall-state.json" "$ROOT/bin/heimdall-state" \
    autopilot-approve "github:acme/widget#100" >/dev/null
# the park flagged it out; re-queue by ingesting again (idempotent id is now flagged,
# so release it back to the pool to prove the decision unblocks a future pick).
"$PY" -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));d["issues"]["github:acme/widget#100"]=d["issues"].get("github:acme/widget#100") or {"id":"github:acme/widget#100","title":"outage","body":"p0","priority_signal":{"severity":"critical","age_seconds":0,"source_priority":0},"links":{},"created_at":"2020-06-01T00:00:00Z"};d["flagged"].pop("github:acme/widget#100",None);json.dump(d,open(p,"w"))' "$R10/.heimdall/issues/queue.json"
OUT2="$(run_loop "$R10" "$METER_SMALL" --evidence "true")"
if [ "$(jget "$OUT2" '.tally.parked')" = "0" ] && [ "$(jget "$OUT2" '.tally.fixed')" -ge 1 ]; then
  ok "after autopilot-approve, the decision UNBLOCKS the issue (fixed, not parked)"
else
  bad "an approved issue was still parked (parked=$(jget "$OUT2" '.tally.parked'))"
fi

echo "── (10) EXPLICIT rr-task authorization — runs with NO local heimdall-state.json ─"
# The deployed-shape gap fix: an EXPLICIT rr task (the gated drain passes --explicit) IS the
# authorization, so the loop runs even though NO heimdall-state.json exists (the ephemeral
# Cloud Run Job container shape). NOTE: enable_state is deliberately NOT called here, and the
# run_loop helper points HEIMDALL_STATE_FILE at a path that does NOT exist -> _read_state {}.
R11="$(new_repo explicit_on)"; seed "$R11" 111       # queued issue, but NO state file at all
[ ! -f "$R11/heimdall-state.json" ] || bad "precondition: R11 unexpectedly has a state file"
OUT="$(run_loop "$R11" "$METER_SMALL" --explicit --evidence "true")"
if [ "$(jget "$OUT" '.stop')" != "disabled" ] && [ "$(jget "$OUT" '.cycles')" -ge 1 ]; then
  ok "explicit -> runs with NO local state file (stop=$(jget "$OUT" '.stop'), cycles=$(jget "$OUT" '.cycles') — the no-op is removed)"
else
  bad "explicit did NOT run without state (stop=$(jget "$OUT" '.stop') cycles=$(jget "$OUT" '.cycles'))"
fi

# FALSIFIER — the SAFETY GATE HOLDS: the SAME repo shape with NO --explicit + NO state file
# stays OFF (unattended never auto-runs on an unconfigured repo). This is what proves the
# explicit path is a scoped authorization, not a blanket always-on.
R12="$(new_repo explicit_off)"; seed "$R12" 112
[ ! -f "$R12/heimdall-state.json" ] || bad "precondition: R12 unexpectedly has a state file"
OUT="$(run_loop "$R12" "$METER_SMALL" --evidence "true")"
if [ "$(jget "$OUT" '.stop')" = "disabled" ] && [ "$(jget "$OUT" '.cycles')" = "0" ]; then
  ok "FALSIFIER: no --explicit + no state file -> stop=disabled, 0 cycles (the unattended gate holds)"
else
  bad "the unattended safety gate did NOT hold (stop=$(jget "$OUT" '.stop') cycles=$(jget "$OUT" '.cycles'))"
fi
# and the falsifier truly did nothing — the queued issue is untouched.
QST12="$(HEIMDALL_HOME="$R12/.heimdall" "$QCMD" status --repo "$R12")"
if [ "$(jget "$QST12" '.queued')" = "1" ]; then
  ok "FALSIFIER: the unauthorized run touched NOTHING (queue still has its issue)"
else
  bad "the unauthorized run mutated the queue (queued=$(jget "$QST12" '.queued'))"
fi

# OPERATOR ENV OVERRIDE — HEIMDALL_MAINTAINER_ENABLED=1 authorizes a run with NO state file.
R13="$(new_repo env_enabled)"; seed "$R13" 113
[ ! -f "$R13/heimdall-state.json" ] || bad "precondition: R13 unexpectedly has a state file"
OUT="$(env HEIMDALL_HOME="$R13/.heimdall" \
           HEIMDALL_STATE_FILE="$R13/heimdall-state.json" \
           HEIMDALL_TOKENS_BIN="$METER_SMALL" \
           HEIMDALL_MAINTAINER_ENABLED=1 \
           "$CMD" run --repo "$R13" --evidence "true" 2>/dev/null)"
if [ "$(jget "$OUT" '.stop')" != "disabled" ] && [ "$(jget "$OUT" '.cycles')" -ge 1 ]; then
  ok "HEIMDALL_MAINTAINER_ENABLED=1 -> runs with NO state file (documented operator override)"
else
  bad "env override did NOT authorize a run (stop=$(jget "$OUT" '.stop') cycles=$(jget "$OUT" '.cycles'))"
fi

echo
echo "════════════════════════════════════════════════════════════════════════════"
printf "maintain-loop: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf "\033[31m%d failed\033[0m\n" "$FAIL"
  exit 1
fi
printf "%d failed\n" "$FAIL"
echo "ALL GREEN — budget-cap can't-burn-tokens · stop-guards · checkpoint · heartbeat · resume · disabled · approval-park · explicit-rr-authz · env-override"
