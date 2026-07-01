#!/usr/bin/env bash
# test/heimdall-watch-queue.test.sh — acceptance test for the LOCAL continuous
# intake work queue (bin/lib/work_queue.py + bin/heimdall-queue) and its drainer
# (bin/heimdall-watch).
#
# HERMETIC: no network, no live model, no control-plane. HEIMDALL_HOME points at
# a throwaway dir so the append-only log (queue/work.jsonl) is isolated per run.
# The drainer's executor + verdict are injected via env seams (HEIMDALL_WATCH_FORK,
# HEIMDALL_WATCH_VERDICT_CMD) so a drain runs WITHOUT claude / attest / a real gate.
#
# Proves (dossier of the task):
#   (1) add -> pick is ATOMIC — two concurrent picks never double-pick one item.
#   (2) dedup_hash BLOCKS a duplicate ingest (retries don't double-run).
#   (3) drain runs HIGHEST-PRIORITY first.
#   (4) a crashed claim is REAPED after ttl -> requeued (attempts preserved).
#   (5) a poison task -> FLAGGED after max_attempts (never infinite-retry).
#   (6) heimdall-watch --drain-empty EXITS on an empty queue.
#   (7) the verdict is RECORDED per drained task (from the seam, not self-report).
#   (8) the webhook frontend (POST /queue) writes to the SAME local log.
#
# Exit 0 = "N passed,0 failed". Any failure is non-zero.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# NOTE: bin/heimdall-watch is already the H-3 sentinel watch-mode tool; the LOCAL
# work-queue drainer is bin/heimdall-drain (distinct name, no clobber).
QUEUE="$ROOT/bin/heimdall-queue"
WATCH="$ROOT/bin/heimdall-drain"
LIB="$ROOT/bin/lib/work_queue.py"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }
[ -x "$QUEUE" ] || { echo "FATAL: $QUEUE not executable" >&2; exit 2; }
[ -x "$WATCH" ] || { echo "FATAL: $WATCH not executable" >&2; exit 2; }
[ -f "$LIB" ]   || { echo "FATAL: $LIB missing" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "wq-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
export HEIMDALL_HOME="$WORK/home"
mkdir -p "$HEIMDALL_HOME"
trap 'rm -rf "$WORK"' EXIT

# jq-free JSON field reader: read <json-on-stdin> <dotless.key.path>.
jget() { "$PY" -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    if k=="": continue
    if isinstance(d,list): d=d[int(k)]
    else: d=d.get(k)
    if d is None: break
print("" if d is None else (json.dumps(d) if isinstance(d,(dict,list,bool)) else d))' "$1"; }

LOG="$HEIMDALL_HOME/queue/work.jsonl"

# ── (1) add -> pick is atomic (no double-pick under concurrent picks) ──────────
"$QUEUE" add "atomic-one" --priority 5 --repo r1 >/dev/null
p1="$WORK/p1.json"; p2="$WORK/p2.json"
# Fire two picks truly concurrently; flock must serialize them so exactly ONE
# claims the single queued item and the other sees null.
( "$QUEUE" pick > "$p1" 2>/dev/null ) &
( "$QUEUE" pick > "$p2" 2>/dev/null ) &
wait
id1="$(jget picked.id < "$p1")"
id2="$(jget picked.id < "$p2")"
nonempty=0
[ -n "$id1" ] && nonempty=$((nonempty+1))
[ -n "$id2" ] && nonempty=$((nonempty+1))
if [ "$nonempty" -eq 1 ]; then
  ok "(1) concurrent picks -> exactly one claim (no double-pick)"
else
  bad "(1) concurrent picks double-picked or lost: id1='$id1' id2='$id2'"
fi

# ── (2) dedup_hash blocks a duplicate ingest ───────────────────────────────────
export HEIMDALL_HOME="$WORK/home2"; mkdir -p "$HEIMDALL_HOME"
a1="$("$QUEUE" add "same body" --repo repoX --priority 3)"
a2="$("$QUEUE" add "same body" --repo repoX --priority 3)"
added1="$(jget added <<<"$a1")"
added2="$(jget added <<<"$a2")"
depth="$("$QUEUE" status | jget depth)"
if [ "$added1" = "true" ] && [ "$added2" = "false" ] && [ "$depth" = "1" ]; then
  ok "(2) duplicate ingest blocked by dedup_hash (depth stays 1)"
else
  bad "(2) dedup failed: added1=$added1 added2=$added2 depth=$depth"
fi
# A different repo with the same body is NOT a duplicate (hash = prompt+repo).
a3added="$("$QUEUE" add "same body" --repo repoY --priority 3 | jget added)"
[ "$a3added" = "true" ] && ok "(2b) same body, different repo -> distinct item" \
  || bad "(2b) cross-repo dedup false-positive: added=$a3added"

# ── (3) drain runs highest-priority first ──────────────────────────────────────
export HEIMDALL_HOME="$WORK/home3"; mkdir -p "$HEIMDALL_HOME"
"$QUEUE" add "low"  --priority 1 --repo r >/dev/null
"$QUEUE" add "high" --priority 9 --repo r >/dev/null
"$QUEUE" add "mid"  --priority 5 --repo r >/dev/null
first="$("$QUEUE" pick | jget picked.prompt)"
second="$("$QUEUE" pick | jget picked.prompt)"
if [ "$first" = "high" ] && [ "$second" = "mid" ]; then
  ok "(3) pick order is highest-priority first (high -> mid)"
else
  bad "(3) wrong pick order: first=$first second=$second"
fi

# ── (4) a crashed claim is reaped after ttl -> requeued ────────────────────────
export HEIMDALL_HOME="$WORK/home4"; mkdir -p "$HEIMDALL_HOME"
addj="$("$QUEUE" add "reap-me" --priority 4 --repo r --ttl 1 --max-attempts 3)"
rid="$(jget id <<<"$addj")"
"$QUEUE" pick >/dev/null                      # claim it (attempts -> 1)
att_after_claim="$("$QUEUE" get "$rid" | jget attempts)"
# Reap with a far-future clock so claimed_at + ttl < now.
reaped="$("$QUEUE" reap --now 2999-01-01T00:00:00+00:00)"
state_after="$("$QUEUE" get "$rid" | jget state)"
att_after_reap="$("$QUEUE" get "$rid" | jget attempts)"
if echo "$reaped" | grep -q "$rid" && [ "$state_after" = "queued" ] \
   && [ "$att_after_claim" = "1" ] && [ "$att_after_reap" = "1" ]; then
  ok "(4) crashed claim reaped after ttl -> requeued (attempts preserved=1)"
else
  bad "(4) reap failed: reaped='$reaped' state=$state_after att_claim=$att_after_claim att_reap=$att_after_reap"
fi
# A second claim increments attempts to 2 (the retry).
"$QUEUE" pick >/dev/null
att2="$("$QUEUE" get "$rid" | jget attempts)"
[ "$att2" = "2" ] && ok "(4b) re-pick increments attempts (1 -> 2)" \
  || bad "(4b) attempts not incremented on re-pick: $att2"

# ── (5) poison task -> flagged after max_attempts ──────────────────────────────
export HEIMDALL_HOME="$WORK/home5"; mkdir -p "$HEIMDALL_HOME"
pj="$("$QUEUE" add "poison" --priority 4 --repo r --ttl 1 --max-attempts 1)"
pid="$(jget id <<<"$pj")"
"$QUEUE" pick >/dev/null                      # attempts -> 1 (== max)
"$QUEUE" reap --now 2999-01-01T00:00:00+00:00 >/dev/null
pstate="$("$QUEUE" get "$pid" | jget state)"
flaggedlist="$("$QUEUE" list --state flagged | jget 0.id)"
if [ "$pstate" = "flagged" ] && [ "$flaggedlist" = "$pid" ]; then
  ok "(5) poison task flagged after max_attempts (never infinite-retry)"
else
  bad "(5) poison not flagged: state=$pstate flaggedlist=$flaggedlist"
fi

# ── (6) heimdall-watch --drain-empty exits on empty ────────────────────────────
export HEIMDALL_HOME="$WORK/home6"; mkdir -p "$HEIMDALL_HOME"
set +e
"$WATCH" --drain-empty >/dev/null 2>&1
wrc=$?
set -e 2>/dev/null || true
[ "$wrc" -eq 0 ] && ok "(6) watch --drain-empty exits 0 on empty queue" \
  || bad "(6) watch --drain-empty did not exit cleanly (rc=$wrc)"

# ── (7) verdict recorded per drained task (from attestation seam) ──────────────
export HEIMDALL_HOME="$WORK/home7"; mkdir -p "$HEIMDALL_HOME"
# Executor seam: a no-op that just succeeds (no claude). Verdict seam: forces PROVEN.
FORK_MOCK="$WORK/fork_mock.sh"
cat > "$FORK_MOCK" <<'EOS'
#!/usr/bin/env bash
# mock executor: echo the prompt, always succeed.
echo "ran: $*"
exit 0
EOS
chmod +x "$FORK_MOCK"
VERDICT_PROVEN="$WORK/verdict_proven.sh"
cat > "$VERDICT_PROVEN" <<'EOS'
#!/usr/bin/env bash
echo "PROVEN"
EOS
chmod +x "$VERDICT_PROVEN"
VERDICT_BLOCKED="$WORK/verdict_blocked.sh"
cat > "$VERDICT_BLOCKED" <<'EOS'
#!/usr/bin/env bash
echo "BLOCKED"
EOS
chmod +x "$VERDICT_BLOCKED"

pjson="$("$QUEUE" add "prove-me" --priority 7 --repo r)"
proveid="$(jget id <<<"$pjson")"
bjson="$("$QUEUE" add "block-me" --priority 6 --repo r)"
blockid="$(jget id <<<"$bjson")"
# Drain: prove-me (pri 7) picked first with PROVEN, then block-me with BLOCKED.
HEIMDALL_WATCH_FORK="$FORK_MOCK" HEIMDALL_WATCH_VERDICT_CMD="$VERDICT_PROVEN" \
  "$WATCH" --drain-empty --max 1 >/dev/null 2>&1
HEIMDALL_WATCH_FORK="$FORK_MOCK" HEIMDALL_WATCH_VERDICT_CMD="$VERDICT_BLOCKED" \
  "$WATCH" --drain-empty --max 1 >/dev/null 2>&1
pv="$("$QUEUE" get "$proveid" | jget gate_verdict)"
ps="$("$QUEUE" get "$proveid" | jget state)"
bv="$("$QUEUE" get "$blockid" | jget gate_verdict)"
if [ "$pv" = "PROVEN" ] && [ "$ps" = "done" ] && [ "$bv" = "BLOCKED" ]; then
  ok "(7) verdict recorded per task (PROVEN + BLOCKED), from the seam"
else
  bad "(7) verdict not recorded: prove_verdict=$pv prove_state=$ps block_verdict=$bv"
fi
lastv="$("$QUEUE" status | jget last_verdict)"
[ -n "$lastv" ] && ok "(7b) status surfaces last_verdict for the HUD ($lastv)" \
  || bad "(7b) status has no last_verdict"

# ── (8) webhook frontend writes to the SAME local log ──────────────────────────
export HEIMDALL_HOME="$WORK/home8"; mkdir -p "$HEIMDALL_HOME"
if command -v curl >/dev/null 2>&1; then
  PORTFILE="$WORK/port"
  "$QUEUE" serve --port 0 --portfile "$PORTFILE" >/dev/null 2>&1 &
  SRV=$!
  # Wait for the server to publish its bound port.
  for _ in $(seq 1 50); do [ -s "$PORTFILE" ] && break; sleep 0.1; done
  PORT="$(cat "$PORTFILE" 2>/dev/null || echo "")"
  if [ -n "$PORT" ]; then
    curl -fsS -X POST "http://127.0.0.1:$PORT/queue" \
      -H 'content-type: application/json' \
      -d '{"prompt":"via-webhook","priority":8,"repo":"r"}' >/dev/null 2>&1
    src="$("$QUEUE" list | jget 0.source)"
    depth8="$("$QUEUE" status | jget depth)"
    if [ "$depth8" = "1" ] && [ "$src" = "webhook" ]; then
      ok "(8) webhook POST /queue wrote to the local log (source=webhook)"
    else
      bad "(8) webhook did not write locally: depth=$depth8 source=$src"
    fi
  else
    bad "(8) webhook server never bound a port"
  fi
  kill "$SRV" 2>/dev/null || true
  wait "$SRV" 2>/dev/null || true
else
  ok "(8) webhook test skipped (curl absent) — non-fatal"
fi

# ── tally ──────────────────────────────────────────────────────────────────────
echo ""
echo "$PASS passed,$FAIL failed"
[ "$FAIL" -eq 0 ]
