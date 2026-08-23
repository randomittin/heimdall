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
[ -n "$WORK" ] || { echo "FATAL: WORK path empty (mktemp failed)" >&2; exit 2; }
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
# bug #28: exercise a REAL PR-open cycle (the production path). With a scoped bot token +
# a bare origin + a fake `gh pr create`, open_pr PUSHES the branch and OPENS a PR, so the
# loop HONORS pr_opened=True -> tally pr=1. (Without a token open_pr is record-only and
# pr_opened is honestly False — no real PR to count.) This keeps section (6)'s "1 PR"
# heartbeat assertion a genuine production observable, not the old hard-coded fake.
R5BARE="$WORK/checkpoint.origin.git"
[ -n "$R5BARE" ] || { echo "FATAL: R5BARE path empty" >&2; exit 1; }
git init --bare -q "$R5BARE"
git -C "$R5" config commit.gpgsign false
git -C "$R5" remote add origin "$R5BARE"
PRBIN="$WORK/prbin"; mkdir -p "$PRBIN"
cat > "$PRBIN/gh" <<'GHEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "create" ]; then echo "https://github.com/acme/widget/pull/5"; fi
exit 0
GHEOF
chmod +x "$PRBIN/gh"
env HEIMDALL_HOME="$R5/.heimdall" \
    HEIMDALL_STATE_FILE="$R5/heimdall-state.json" \
    HEIMDALL_TOKENS_BIN="$METER_SMALL" \
    HEIMDALL_PR_BOT_TOKEN="ghs_FAKEbottoken000000000000000000000000" \
    PATH="$PRBIN:$PATH" \
    "$CMD" run --repo "$R5" --evidence "true" >/dev/null 2>&1
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
if grep -q 'cycle 1' <<<"$HB" \
   && grep -q '1 fixed' <<<"$HB" \
   && grep -q '1 PR' <<<"$HB" \
   && grep -q 'PASS' <<<"$HB"; then
  ok "heartbeat renders real numbers: '$HB'"
else
  bad "heartbeat did not render the real PASS numbers: '$HB'"
fi
# FALSIFIER: a FAIL-only run's heartbeat shows 0 fixed / flagged>0 / FAIL — not PASS.
R6="$(new_repo hb_fail)"; enable_state "$R6" true 600000; seed "$R6" 61
run_loop "$R6" "$METER_SMALL" --evidence "false" >/dev/null
HBF="$(env HEIMDALL_HOME="$R6/.heimdall" HEIMDALL_STATE_FILE="$R6/heimdall-state.json" \
        HEIMDALL_TOKENS_BIN="$METER_SMALL" "$CMD" heartbeat --repo "$R6")"
if grep -q '0 fixed' <<<"$HBF" \
   && grep -q 'FAIL' <<<"$HBF" \
   && ! grep -q 'PASS' <<<"$HBF"; then
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
if grep -q '/loop 30m /hmd:maintain-check' <<<"$HINT"; then
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

echo "── (11) FRESH-HOME BUDGET — an empty meter at START is used=0, NOT fail-closed ─"
# DEPLOYED-SHAPE: the ephemeral Cloud Run Job container starts with a FRESH HEIMDALL_HOME
# (/app/state, always empty), so heimdall-tokens truthfully reports ZERO accumulated usage
# — a well-formed record with total_tokens==0 + a benign "no session dir" marker. The OLD
# fail-closed rule wrongly treated that as an unreadable meter and STOPPED(budget) at cycle 0,
# so the cloud maintainer could NEVER execute a cycle. Now: budget NOT over at start, a real
# cycle runs (mirrors the deployed --max 1 job). The falsifier below proves fail-closed is
# still enforced once usage has been recorded.
mk_fresh_meter() {
  # emits the exact fresh/no-data record heimdall-tokens returns for an empty home.
  local dest="$1"
  cat > "$dest" <<'METER'
#!/usr/bin/env bash
echo '{"total_tokens": 0, "turns": 0, "total_cost_usd": null, "error": "no session dir for cwd slug under ~/.claude/projects"}'
METER
  chmod +x "$dest"
}
METER_FRESH="$WORK/meter_fresh"; mk_fresh_meter "$METER_FRESH"
R14="$(new_repo fresh_home)"; seed "$R14" 141        # NO state file -> use --explicit authz
[ ! -f "$R14/heimdall-state.json" ] || bad "precondition: R14 unexpectedly has a state file"
OUT="$(run_loop "$R14" "$METER_FRESH" --explicit --max 1 --evidence "true")"
if [ "$(jget "$OUT" '.stop')" != "budget" ] && [ "$(jget "$OUT" '.cycles')" -ge 1 ]; then
  ok "fresh-home meter -> budget NOT over at start, a cycle RAN (stop=$(jget "$OUT" '.stop') cycles=$(jget "$OUT" '.cycles'))"
else
  bad "fresh-home still fail-closed at cycle 0 (stop=$(jget "$OUT" '.stop') cycles=$(jget "$OUT" '.cycles'))"
fi
# the checkpoint's budget block must carry the fresh reading (used=0, meter=fresh, not over).
FRESH_BUDGET="$("$PY" -c 'import sys,os;sys.path.insert(0,os.path.join(sys.argv[1],"..","..","bin","lib"));import maintain_loop as m;import json;print(json.dumps(m.budget_state(sys.argv[1],600000,usage_recorded=False)))' "$R14" 2>/dev/null || true)"
if printf '%s' "$FRESH_BUDGET" | jq -e '.over==false and .used==0 and .meter=="fresh"' >/dev/null 2>&1; then
  ok "budget_state(fresh, usage_recorded=False) -> over:false used:0 meter:fresh (deployed-shape truth)"
else
  bad "fresh budget snapshot wrong: $FRESH_BUDGET"
fi

echo "── (12) FALSIFIER — a meter that goes UNREADABLE after usage still fail-closes ─"
# The fix must NOT disable fail-closed entirely. Once ANY usage is recorded this run, a
# meter that becomes UNREADABLE fail-closes (STOP budget) rather than running blind — the
# honesty rule for a genuinely broken meter is preserved.
# A stateful meter: 1st read = a real under-cap usage (records usage), 2nd+ = a DEGRADED
# record with no numeric total (unreadable). The loop must run exactly ONE cycle then STOP.
mk_stateful_meter() {
  local dest="$1" counter="$2"
  cat > "$dest" <<METER
#!/usr/bin/env bash
n=\$(cat "$counter" 2>/dev/null || echo 0)
echo \$((n+1)) > "$counter"
if [ "\$n" = "0" ]; then
  echo '{"total_tokens": 100, "total_cost_usd": 0.0}'
else
  echo '{"error": "meter backend unavailable", "total_cost_usd": null}'
fi
METER
  chmod +x "$dest"
}
CNT="$WORK/meter_state_counter"
METER_STATE="$WORK/meter_stateful"; mk_stateful_meter "$METER_STATE" "$CNT"
R15="$(new_repo fresh_falsify)"; seed "$R15" 151; seed "$R15" 152; seed "$R15" 153
OUT="$(run_loop "$R15" "$METER_STATE" --explicit --evidence "true" --max-failures 9)"
if [ "$(jget "$OUT" '.stop')" = "budget" ] && [ "$(jget "$OUT" '.cycles')" = "1" ]; then
  ok "FALSIFIER: meter unreadable AFTER usage recorded -> STOP(budget) after 1 cycle (never blind)"
else
  bad "fail-closed-after-usage broke (stop=$(jget "$OUT" '.stop') cycles=$(jget "$OUT" '.cycles'))"
fi
# and the direct guard: an unreadable meter WITH usage recorded is over; a MISSING binary is
# unreadable at start too (so the old fail-safe test (2) still holds — never blind on a truly
# broken meter, only on a truthful fresh zero do we run).
FALSE_BUDGET="$("$PY" -c 'import sys,os;sys.path.insert(0,os.path.join(sys.argv[1],"..","..","bin","lib"));import maintain_loop as m;import json;print(json.dumps(m.budget_state(sys.argv[1],600000,usage_recorded=True)))' "$R14" 2>/dev/null || true)"
if printf '%s' "$FALSE_BUDGET" | jq -e '.over==true and .meter=="unavailable"' >/dev/null 2>&1; then
  ok "budget_state(empty, usage_recorded=True) -> over:true meter:unavailable (fail-closed after usage)"
else
  bad "fail-closed-after-usage snapshot wrong: $FALSE_BUDGET"
fi

# ── fake gh/claude on PATH (hermetic: NO network, NO real GitHub, NO real model) ─
# A fake `gh` records its argv + whether GH_TOKEN rode the env, and fabricates a REAL
# throwaway git checkout on `gh repo clone` — so the cloud-shape clone path is exercised
# end-to-end without a network. `git` stays REAL (only gh/claude are faked), so the loop's
# own git/comprehend/attest run for real against the fabricated checkout.
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
GH_ARGV_LOG="$WORK/gh_argv.log"; : > "$GH_ARGV_LOG"
GH_ENV_LOG="$WORK/gh_env.log"; : > "$GH_ENV_LOG"
cat > "$FAKEBIN/gh" <<GHEOF
#!/usr/bin/env bash
# fake gh — record argv + GH_TOKEN-in-env, fabricate a checkout on \`repo clone\`,
# and serve a canned/failing \`issue list\` (the queue-sync seam).
printf '%s\n' "\$*" >> "$GH_ARGV_LOG"
[ -n "\${GH_TOKEN:-}" ] && printf 'GH_TOKEN_PRESENT\n' >> "$GH_ENV_LOG"
if [ "\${1:-}" = "issue" ] && [ "\${2:-}" = "list" ]; then
  if [ -n "\${GH_ISSUE_LIST_FAIL:-}" ]; then
    printf 'gh: could not resolve to a Repository (simulated)\n' >&2
    exit 1
  fi
  cat "\${GH_ISSUE_LIST_JSON:-/dev/null}"
  exit 0
fi
if [ "\${1:-}" = "repo" ] && [ "\${2:-}" = "clone" ]; then
  slug="\$3"; dest="\$4"
  [ -n "\$dest" ] || { echo "FATAL: dest path empty" >&2; exit 1; }
  # HERMETIC ORIGIN: a LOCAL BARE repo stands in for GitHub as \`origin\` so bug #21's
  # real \`git push\` of the heimdall/* branch (open_pr commits+pushes BEFORE gh pr create)
  # lands with NO network — mirrors issue-pr.test.sh §6. A github.com URL here makes
  # open_pr's push hit the real network and fail auth (never hermetic, never green).
  bare="\${dest}.origin.git"
  [ -n "\$bare" ] || { echo "FATAL: bare path empty" >&2; exit 1; }
  git init -q --bare "\$bare"
  mkdir -p "\$dest"
  git init -q "\$dest"
  git -C "\$dest" config user.email t@t
  git -C "\$dest" config user.name t
  git -C "\$dest" config commit.gpgsign false
  git -C "\$dest" remote add origin "\$bare"
  printf 'x\n' > "\$dest/app.py"
  git -C "\$dest" add -A
  git -C "\$dest" commit -qm init
fi
exit 0
GHEOF
chmod +x "$FAKEBIN/gh"
cat > "$FAKEBIN/claude" <<'CLAUDEEOF'
#!/usr/bin/env bash
exit 0
CLAUDEEOF
chmod +x "$FAKEBIN/claude"
BOT_TOKEN="ghs_FAKEcloneTOKEN0000000000000000000000"

echo "── (13) CLOUD-SHAPE WORKSPACE — a bare owner/name SLUG is CLONED into the workdir ─"
# The deployed shape: a FRESH HEIMDALL_HOME, a read-only CWD (mimics /app in the Cloud Run
# Job, where only /app/state=HEIMDALL_HOME is writable), NO state file, and --repo as a bare
# SLUG. The loop must clone into ${HEIMDALL_HOME}/work/<owner>__<name> (NOT a CWD-relative
# join — the PermissionError bug), auth riding the bot token in the ENV (never argv).
CLOUD_HOME="$WORK/cloud_home"; mkdir -p "$CLOUD_HOME"
RO_CWD="$WORK/ro_cwd"; mkdir -p "$RO_CWD"
SLUG="randomittin/heimdall-maintainer-test"
WORKDIR="$CLOUD_HOME/work/randomittin__heimdall-maintainer-test"
: > "$GH_ARGV_LOG"; : > "$GH_ENV_LOG"
RAW="$("$PY" -c 'import json,sys;print(json.dumps({"repo":"acme/widget","number":131,"title":"fix","body":"broken","labels":[{"name":"bug"}],"created_at":"2020-06-01T00:00:00Z"}))')"
HEIMDALL_HOME="$CLOUD_HOME" "$QCMD" ingest --source github --raw "$RAW" --repo "$SLUG" >/dev/null
chmod 555 "$RO_CWD"
OUT="$(cd "$RO_CWD" && env HEIMDALL_HOME="$CLOUD_HOME" \
      HEIMDALL_TOKENS_BIN="$METER_SMALL" \
      HEIMDALL_PR_BOT_TOKEN="$BOT_TOKEN" \
      PATH="$FAKEBIN:$PATH" \
      "$CMD" run --repo "$SLUG" --explicit --max 1 --evidence "true" 2>/dev/null)"
chmod 755 "$RO_CWD"
if [ -d "$WORKDIR/.git" ]; then
  ok "the bare slug was CLONED into \${HEIMDALL_HOME}/work/<owner>__<name> (writable root)"
else
  bad "no workdir cloned at $WORKDIR"
fi
if [ -f "$WORKDIR/.planning/CHECKPOINT.md" ]; then
  ok "the planning/checkpoint dir lands UNDER the workdir (not a bare-slug CWD join)"
else
  bad "no checkpoint under the workdir (planning_dir did not derive from the workdir)"
fi
if grep -q "repo clone $SLUG" "$GH_ARGV_LOG" && ! grep -q "$BOT_TOKEN" "$GH_ARGV_LOG"; then
  ok "clone argv is TOKEN-FREE (falsifier: a token in argv would fail this grep)"
else
  bad "clone argv missing or leaked the token: $(cat "$GH_ARGV_LOG")"
fi
if grep -q 'GH_TOKEN_PRESENT' "$GH_ENV_LOG"; then
  ok "the bot token rode the ENV (GH_TOKEN) into the cloner — never argv/logs"
else
  bad "clone auth did NOT ride the env (GH_TOKEN absent)"
fi
if [ "$(jget "$OUT" '.stop')" != "workspace-error" ] && [ "$(jget "$OUT" '.cycles')" -ge 1 ] \
   && [ "$(jget "$OUT" '.tally.fixed')" -ge 1 ]; then
  ok "the cycle PROCEEDED against the clone (cycles=$(jget "$OUT" '.cycles') fixed=$(jget "$OUT" '.tally.fixed'))"
else
  bad "the cycle did not proceed (stop=$(jget "$OUT" '.stop') cycles=$(jget "$OUT" '.cycles'))"
fi
if [ ! -e "$RO_CWD/randomittin" ]; then
  ok "NOTHING was written CWD-relative (the /app read-only PermissionError can't recur)"
else
  bad "a bare-slug dir was created under the CWD (the original bug)"
fi

echo "── (14) WORKSTATION-SHAPE — CWD is a checkout matching the SLUG -> NO clone ──"
# Byte-identical local behavior: when the CWD is ALREADY a checkout of the target slug (its
# git remote matches), the loop uses it unchanged — NO clone, planning at the checkout's own
# .planning. HEIMDALL_MAINTAIN_WORKDIR points at a dir that must stay UNUSED (the falsifier).
WS_REPO="$(new_repo ws_slug)"
git -C "$WS_REPO" remote add origin "https://github.com/acme/ws-widget.git"
enable_state "$WS_REPO" true 600000
seed "$WS_REPO" 141
UNUSED_ROOT="$WORK/should_not_be_used"
: > "$GH_ARGV_LOG"
OUT="$(cd "$WS_REPO" && env HEIMDALL_HOME="$WS_REPO/.heimdall" \
      HEIMDALL_STATE_FILE="$WS_REPO/heimdall-state.json" \
      HEIMDALL_TOKENS_BIN="$METER_SMALL" \
      HEIMDALL_MAINTAIN_WORKDIR="$UNUSED_ROOT" \
      PATH="$FAKEBIN:$PATH" \
      "$CMD" run --repo "acme/ws-widget" --max 1 --evidence "true" 2>/dev/null)"
if ! grep -q "repo clone" "$GH_ARGV_LOG"; then
  ok "workstation: the CWD checkout was reused — NO clone attempted (byte-identical local)"
else
  bad "workstation still cloned despite a matching CWD checkout: $(cat "$GH_ARGV_LOG")"
fi
if [ -f "$WS_REPO/.planning/CHECKPOINT.md" ] && [ ! -d "$UNUSED_ROOT" ]; then
  ok "workstation: planning at the CHECKOUT's .planning; the workdir root stays UNUSED"
else
  bad "workstation planning misplaced (checkpoint=$( [ -f "$WS_REPO/.planning/CHECKPOINT.md" ] && echo yes || echo no ) unused_root=$( [ -d "$UNUSED_ROOT" ] && echo created || echo absent ))"
fi
if [ "$(jget "$OUT" '.cycles')" -ge 1 ]; then
  ok "workstation: the cycle ran against the local checkout (cycles=$(jget "$OUT" '.cycles'))"
else
  bad "workstation cycle did not run (cycles=$(jget "$OUT" '.cycles'))"
fi

echo "── (15) SLUG TRAVERSAL — owner/../../etc is REFUSED (no clone, no join) ──────"
TRAV_HOME="$WORK/trav_home"; mkdir -p "$TRAV_HOME"
TRAV_CWD="$WORK/trav_cwd"; mkdir -p "$TRAV_CWD"
: > "$GH_ARGV_LOG"
OUT="$(cd "$TRAV_CWD" && env HEIMDALL_HOME="$TRAV_HOME" \
      HEIMDALL_TOKENS_BIN="$METER_SMALL" \
      HEIMDALL_PR_BOT_TOKEN="$BOT_TOKEN" \
      PATH="$FAKEBIN:$PATH" \
      "$CMD" run --repo "owner/../../etc" --explicit --max 1 --evidence "true" 2>/dev/null)"
if [ "$(jget "$OUT" '.stop')" = "workspace-error" ] && [ "$(jget "$OUT" '.cycles')" = "0" ]; then
  ok "traversal slug -> stop=workspace-error, 0 cycles (refused BEFORE any filesystem join)"
else
  bad "traversal not refused (stop=$(jget "$OUT" '.stop') cycles=$(jget "$OUT" '.cycles'))"
fi
if ! grep -q "clone" "$GH_ARGV_LOG"; then
  ok "traversal: NO clone attempted (nothing joined, nothing executed)"
else
  bad "traversal still attempted a clone: $(cat "$GH_ARGV_LOG")"
fi
# direct guard: the segment validator refuses traversal shapes yet accepts a real slug.
PY_TRAV="$("$PY" -c '
import maintain_loop as m
refused = True
for b in ["owner/..","../x/y","a/b/c","owner/na me","o/..","owner/../../etc"]:
    try:
        m._parse_repo_slug(b); refused = False; break
    except m.WorkspaceError:
        continue
good = False
try:
    good = m._parse_repo_slug("acme/widget") == ("acme", "widget")
except Exception:
    good = False
print("OK" if (refused and good) else "BAD")')"
if [ "$PY_TRAV" = "OK" ]; then
  ok "the slug validator refuses every traversal shape yet accepts a real owner/name"
else
  bad "the slug validator is wrong (result=$PY_TRAV)"
fi

# ── the GITHUB-INGEST issues fixture (what the fake `gh issue list` serves) ────
# Two OPEN maintainer-labeled issues; #1 is OLDER so it outranks #2 on age (both share
# severity), which is what the pick order must choose first.
ISSUES2="$WORK/issues2.json"
cat > "$ISSUES2" <<'JSON'
[{"number":1,"title":"first bug","body":"broken one","labels":[{"name":"maintainer"}],"createdAt":"2024-01-01T00:00:00Z"},
 {"number":2,"title":"second bug","body":"broken two","labels":[{"name":"maintainer"}],"createdAt":"2024-01-02T00:00:00Z"}]
JSON
SYNC_SLUG="randomittin/heimdall-maintainer-test"

echo "── (16) GITHUB INGEST — empty queue + gh returns 2 issues -> ingested, cycle runs ─"
# The ROOT-CAUSE fix: an EMPTY queue looks at GitHub BEFORE the first pick. Fresh HOME
# (nothing seeded), bare SLUG, --explicit — the loop clones, syncs the 2 OPEN maintainer
# issues into the queue, then drains (picks the oldest, #1). Token rides GH_TOKEN in the
# env, never argv.
S16_HOME="$WORK/sync_home"; mkdir -p "$S16_HOME"
: > "$GH_ARGV_LOG"; : > "$GH_ENV_LOG"
OUT="$(env HEIMDALL_HOME="$S16_HOME" \
      HEIMDALL_TOKENS_BIN="$METER_SMALL" \
      HEIMDALL_PR_BOT_TOKEN="$BOT_TOKEN" \
      GH_ISSUE_LIST_JSON="$ISSUES2" \
      PATH="$FAKEBIN:$PATH" \
      "$CMD" run --repo "$SYNC_SLUG" --explicit --max 1 --evidence "true" 2>/dev/null)"
if [ "$(jget "$OUT" '.stop')" != "empty-queue" ] && [ "$(jget "$OUT" '.cycles')" -ge 1 ] \
   && [ "$(jget "$OUT" '.tally.fixed')" -ge 1 ]; then
  ok "empty queue + gh 2 issues -> ingested + cycle PROCEEDED (stop=$(jget "$OUT" '.stop') fixed=$(jget "$OUT" '.tally.fixed'))"
else
  bad "sync did not populate/proceed (stop=$(jget "$OUT" '.stop') cycles=$(jget "$OUT" '.cycles') fixed=$(jget "$OUT" '.tally.fixed'))"
fi
PICKED="$(jget "$OUT" '.last.issue')"
if grep -q '#1$' <<<"$PICKED"; then
  ok "picked the OLDEST ingested issue first (#1): $PICKED"
else
  bad "wrong pick order (expected the #1 issue, got: $PICKED)"
fi
QST16="$(HEIMDALL_HOME="$S16_HOME" "$QCMD" status --repo "$SYNC_SLUG")"
if [ "$(jget "$QST16" '.total')" = "2" ] && [ "$(jget "$QST16" '.queued')" = "1" ]; then
  ok "both issues ingested (total 2); #1 claimed, #2 still queued (1)"
else
  bad "queue not populated as expected (total=$(jget "$QST16" '.total') queued=$(jget "$QST16" '.queued'))"
fi
if grep -q "issue list --repo $SYNC_SLUG --state open --label maintainer" "$GH_ARGV_LOG"; then
  ok "gh argv: issue list --repo <slug> --state open --label maintainer"
else
  bad "gh issue list argv wrong: $(cat "$GH_ARGV_LOG")"
fi
if ! grep -q "$BOT_TOKEN" "$GH_ARGV_LOG"; then
  ok "the bot token is NEVER in gh argv (falsifier: a token in argv would fail this grep)"
else
  bad "the bot token LEAKED into gh argv: $(cat "$GH_ARGV_LOG")"
fi
if grep -q 'GH_TOKEN_PRESENT' "$GH_ENV_LOG"; then
  ok "the bot token rode the ENV (GH_TOKEN) into gh issue list — never argv"
else
  bad "gh issue list auth did NOT ride the env (GH_TOKEN absent)"
fi

echo "── (17) SYNC FAILURE — gh list fails -> stop=queue-sync-error (NOT empty-queue) ─"
# A list failure must be LOUD: the loop STOPS with a named, scrubbed note — never a
# silent empty-queue (which would hide a broken GitHub read as "no work").
S17_HOME="$WORK/sync_fail_home"; mkdir -p "$S17_HOME"
: > "$GH_ARGV_LOG"
OUT="$(env HEIMDALL_HOME="$S17_HOME" \
      HEIMDALL_TOKENS_BIN="$METER_SMALL" \
      HEIMDALL_PR_BOT_TOKEN="$BOT_TOKEN" \
      GH_ISSUE_LIST_FAIL=1 \
      PATH="$FAKEBIN:$PATH" \
      "$CMD" run --repo "$SYNC_SLUG" --explicit --max 1 --evidence "true" 2>/dev/null)"
if [ "$(jget "$OUT" '.stop')" = "queue-sync-error" ] && [ "$(jget "$OUT" '.cycles')" = "0" ]; then
  ok "gh list failure -> STOP(queue-sync-error), 0 cycles"
else
  bad "list failure not surfaced (stop=$(jget "$OUT" '.stop') cycles=$(jget "$OUT" '.cycles'))"
fi
if [ "$(jget "$OUT" '.stop')" != "empty-queue" ]; then
  ok "FALSIFIER: a sync failure is NOT mislabeled empty-queue (a real break is never hidden)"
else
  bad "a sync failure was silently reported as empty-queue"
fi
NOTE17="$(jget "$OUT" '.note')"
if grep -q 'queue sync failed' <<<"$NOTE17" && ! grep -q "$BOT_TOKEN" <<<"$NOTE17"; then
  ok "the summary carries a named, token-scrubbed note: $NOTE17"
else
  bad "sync-error note missing or leaked a token: $NOTE17"
fi

echo "── (18) IDEMPOTENT RE-SYNC — same issues -> 2 ingested then 0 (dedup by id) ──────"
IDEM_HOME="$WORK/idem_home"; mkdir -p "$IDEM_HOME"
PY_IDEM="$("$PY" -c '
import os, sys
os.environ["PATH"] = sys.argv[1] + os.pathsep + os.environ.get("PATH", "")
os.environ["HEIMDALL_HOME"] = sys.argv[2]
os.environ["GH_ISSUE_LIST_JSON"] = sys.argv[3]
os.environ["HEIMDALL_PR_BOT_TOKEN"] = "ghs_x"
import maintain_loop as m
r1 = m.sync_queue_from_github("acme/widget")
r2 = m.sync_queue_from_github("acme/widget")
print("OK" if (r1["listed"] == 2 and r1["ingested"] == 2 and r2["ingested"] == 0) else "BAD:%r/%r" % (r1, r2))
' "$FAKEBIN" "$IDEM_HOME" "$ISSUES2" 2>&1)"
if [ "$PY_IDEM" = "OK" ]; then
  ok "re-sync of the same 2 issues ingests 0 the second time (idempotent, no dupes)"
else
  bad "re-sync was not idempotent (result=$PY_IDEM)"
fi

echo "── (19) NO OPEN ISSUES — gh returns [] -> genuine empty-queue stop (unchanged) ──"
S19_HOME="$WORK/sync_none_home"; mkdir -p "$S19_HOME"
EMPTY_ISSUES="$WORK/issues_empty.json"; printf '[]\n' > "$EMPTY_ISSUES"
OUT="$(env HEIMDALL_HOME="$S19_HOME" \
      HEIMDALL_TOKENS_BIN="$METER_SMALL" \
      HEIMDALL_PR_BOT_TOKEN="$BOT_TOKEN" \
      GH_ISSUE_LIST_JSON="$EMPTY_ISSUES" \
      PATH="$FAKEBIN:$PATH" \
      "$CMD" run --repo "$SYNC_SLUG" --explicit --max 1 --evidence "true" 2>/dev/null)"
if [ "$(jget "$OUT" '.stop')" = "empty-queue" ] && [ "$(jget "$OUT" '.cycles')" = "0" ]; then
  ok "no OPEN maintainer issues -> genuine STOP(empty-queue), 0 cycles (behavior preserved)"
else
  bad "no-issues case regressed (stop=$(jget "$OUT" '.stop') cycles=$(jget "$OUT" '.cycles'))"
fi

echo "── (20) SEEKER CONTRACT — agents/seeker.md's real --label is ingested by the engine's default filter ─"
# THE DEFECT this pins: agents/seeker.md used to file `gh issue create --label
# "bug,seeker"`, while the engine's ingest (sync_queue_from_github,
# DEFAULT_MAINTAINER_LABEL="maintainer") only ever requests `--label maintainer`.
# gh's real label filter is a SUPERSET/AND match (an issue must carry EVERY
# requested label, never just one of several) — those two label sets never
# overlapped, so a seeker-filed issue was NEVER ingested and seeker/fixer were
# never spawned by the durable engine. The shared fake `gh` above does not
# simulate this at all (it serves GH_ISSUE_LIST_JSON unconditionally regardless
# of --label), so this section brings its OWN label-aware fake, scoped locally.
#
# Half (b) reads agents/seeker.md's ACTUAL --label value at RUN TIME rather than
# hardcoding it, so this test is a live contract: it goes RED again on its own if
# the label contract between seeker.md and the engine ever regresses.

LBIN="$WORK/fakebin_labels"; mkdir -p "$LBIN"
cat > "$LBIN/gh" <<'LABELGHEOF'
#!/usr/bin/env bash
# Label-aware fake gh, scoped to test (20) only. Replicates GitHub's real
# `issue list --label` filter: an issue is returned only if its label set is a
# SUPERSET of the requested --label list (comma-separated = AND, never OR).
# That distinction is the entire subject of this test, so the fake must not
# fake it away the way the shared fake above does.
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  want=""; prev=""
  for a in "$@"; do
    [ "$prev" = "--label" ] && want="$a"
    prev="$a"
  done
  jq --arg want "$want" '
    ( $want | split(",") ) as $wanted
    | map(select( ($wanted - [ (.labels // [])[].name ]) == [] ))
  ' "${GH_ISSUE_LIST_JSON:?GH_ISSUE_LIST_JSON unset}"
  exit 0
fi
exit 0
LABELGHEOF
chmod +x "$LBIN/gh"

# Fixture (a) — the HISTORICAL broken shape, hardcoded so this regression stays
# pinned forever no matter what agents/seeker.md says in the future.
ISSUES_SEEKER_BROKEN="$WORK/issues_seeker_broken.json"
cat > "$ISSUES_SEEKER_BROKEN" <<'JSON'
[{"number":101,"title":"[seeker] TypeError: cannot read property of undefined","body":"pre-fix seeker output - labeled bug,seeker only","labels":[{"name":"bug"},{"name":"seeker"}],"createdAt":"2024-01-01T00:00:00Z"}]
JSON

# Fixture (b) — the LIVE label set, extracted from agents/seeker.md's actual
# `gh issue create --label "..."` line at RUN time (not hardcoded).
SEEKER_MD="$ROOT/agents/seeker.md"
SEEKER_LABELS="$(grep -m1 -- '--label "' "$SEEKER_MD" | sed -n 's/.*--label "\([^"]*\)".*/\1/p')"
if [ -z "$SEEKER_LABELS" ]; then
  bad "could not extract a --label value from agents/seeker.md (grep/sed found nothing — has the issue-create block moved or changed shape?)"
  SEEKER_LABELS="__extraction_failed__"
fi
SEEKER_LABELS_JSON="$(printf '%s' "$SEEKER_LABELS" | jq -R 'split(",") | map({name: .})')"
ISSUES_SEEKER_LIVE="$WORK/issues_seeker_live.json"
jq -n --argjson labels "$SEEKER_LABELS_JSON" \
  '[{"number":202,"title":"[seeker] live-extracted contract issue","body":"labels extracted live from agents/seeker.md","labels":$labels,"createdAt":"2024-01-03T00:00:00Z"}]' \
  > "$ISSUES_SEEKER_LIVE"

SEEKER_SLUG="randomittin/heimdall-seeker-contract-test"

# (a) historical broken label set -> the engine's DEFAULT ingest (no label=
#     override passed — the exact production call shape used at run()'s only
#     call site) must ingest NOTHING.
S20A_HOME="$WORK/seeker_contract_broken_home"; mkdir -p "$S20A_HOME"
R20A="$("$PY" -c '
import os, sys
os.environ["PATH"] = sys.argv[1] + os.pathsep + os.environ.get("PATH", "")
os.environ["HEIMDALL_HOME"] = sys.argv[2]
os.environ["GH_ISSUE_LIST_JSON"] = sys.argv[3]
import maintain_loop as m
r = m.sync_queue_from_github(sys.argv[4])
print(r["ingested"])
' "$LBIN" "$S20A_HOME" "$ISSUES_SEEKER_BROKEN" "$SEEKER_SLUG" 2>&1)"
if [ "$R20A" = "0" ]; then
  ok "FALSIFIER: the historical bug,seeker label set ingests 0 issues (the old defect, pinned forever)"
else
  bad "historical bug,seeker label set should ingest 0, got: $R20A"
fi

# (b) agents/seeker.md's CURRENT real label set -> the SAME default ingest call
#     must ingest exactly 1. Run this BEFORE the seeker.md fix and it fails RED
#     for the same reason as (a); run it after and it goes GREEN.
S20B_HOME="$WORK/seeker_contract_live_home"; mkdir -p "$S20B_HOME"
R20B="$("$PY" -c '
import os, sys
os.environ["PATH"] = sys.argv[1] + os.pathsep + os.environ.get("PATH", "")
os.environ["HEIMDALL_HOME"] = sys.argv[2]
os.environ["GH_ISSUE_LIST_JSON"] = sys.argv[3]
import maintain_loop as m
r = m.sync_queue_from_github(sys.argv[4])
print(r["ingested"])
' "$LBIN" "$S20B_HOME" "$ISSUES_SEEKER_LIVE" "$SEEKER_SLUG" 2>&1)"
if [ "$R20B" = "1" ]; then
  ok "agents/seeker.md's LIVE label set (\"$SEEKER_LABELS\") IS ingested by the engine's default filter (ingested=1)"
else
  bad "agents/seeker.md's LIVE label set (\"$SEEKER_LABELS\") was NOT ingested (expected 1, got: $R20B) -- seeker and the engine are disconnected"
fi

# (c) the ingested issue must actually REACH the fixer path. Proven via the
# read-only `plan` dry-run CLI — its own docstring says "Mutates NOTHING". No
# PR, no push, no network; this is the dry-run path this section exercises for
# the seeker -> queue -> fixer proof. It must appear in pick order at severity
# "high" (the `bug` label; "seeker"/"maintainer" carry no severity of their own)
# routed to fix+PR — NOT parked, since "high" sits below the default "critical"
# approval floor (DEFAULT_APPROVAL_SEVERITY).
PLAN20="$(HEIMDALL_HOME="$S20B_HOME" "$CMD" plan --repo "$SEEKER_SLUG" 2>&1)"
if [ "$(jget "$PLAN20" '.plan | length')" = "1" ] \
   && grep -q '#202$' <<<"$(jget "$PLAN20" '.plan[0].issue')" \
   && [ "$(jget "$PLAN20" '.plan[0].severity')" = "high" ] \
   && [ "$(jget "$PLAN20" '.plan[0].action')" = "WOULD: fix + GATE + PR (via issue-loop run-once)" ]; then
  ok "plan (read-only dry-run) shows the seeker-filed issue reaching the fixer: $(jget "$PLAN20" '.plan[0].issue') severity=high action=fix+GATE+PR"
else
  bad "plan did not route the seeker issue to the fixer: $PLAN20"
fi

echo
echo "════════════════════════════════════════════════════════════════════════════"
printf "maintain-loop: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf "\033[31m%d failed\033[0m\n" "$FAIL"
  exit 1
fi
printf "%d failed\n" "$FAIL"
echo "ALL GREEN — budget-cap can't-burn-tokens · stop-guards · checkpoint · heartbeat · resume · disabled · approval-park · explicit-rr-authz · env-override · fresh-home-budget · fail-closed-after-usage · cloud-clone-workspace · workstation-parity · slug-traversal-refused · github-ingest · sync-error-loud · idempotent-resync · no-issues-empty-queue · seeker-label-contract"
