#!/usr/bin/env bash
# test/false-green-agent-cap.test.sh: the Study A per-run cap (evals/benchmark/false-green/PREREG.md
# section 8 and Amendment 1), bin/lib/fg_agent.py wired into bin/lib/fg_bench.py.
#
# WHAT THIS PROVES
#   [P] PRICE   the live spend estimate is tokens x the published per-token price of the model that produced
#               them; one message id is counted once however many events carry it; an unknown model is priced
#               at the highest listed rate; the price table in fg_agent.py is exactly the table frozen in
#               PREREG.md Amendment 1.
#   [K] KILL    a run is killed, the whole process group with its grandchildren, when its estimated spend
#               reaches the cap or its wall-clock limit passes, and is NOT killed below the cap (falsifiable:
#               double-counting duplicate message ids would kill the run that must survive).
#   [B] BENCH   through bin/benchmark: a capped run is an infrastructure exclusion with its reason and the
#               summary lists it; a run that finishes over the cap is excluded too; the row's cost is the
#               agent's own total when it reports one; an agent that reports no usage is recorded as
#               unmetered, never as free; the claude-code command streams JSON and carries --max-budget-usd.
#
# Hermetic: HOME and TMPDIR point into a throwaway dir; no network and no model call (the agents are fakes
# and a stub `claude` on PATH prints canned events).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SUITE="$REPO/evals/benchmark/false-green"
BENCH="$REPO/bin/benchmark"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
jqok()  { local desc="$1" file="$2" expr="$3"; if jq -e "$expr" "$file" >/dev/null 2>&1; then ok "$desc"; else bad "$desc  [jq: $expr]"; fi; }

for tool in jq python3 node perl; do command -v "$tool" >/dev/null 2>&1 || { echo "$tool required" >&2; exit 2; }; done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fg-cap-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" TMPDIR="$TMP/tmp"; mkdir -p "$HOME" "$TMPDIR"

# A python white-box section prints "PASS<TAB>desc<TAB>detail" / "FAIL..." lines and a final "END" line;
# a crash before END is itself a failure, never a silent skip.
report() {  # report <output file>
  local verdict desc detail seen_end=0
  while IFS=$'\t' read -r verdict desc detail; do
    case "$verdict" in
      PASS) ok "$desc" ;;
      FAIL) bad "$desc  [$detail]" ;;
      END)  seen_end=1 ;;
      *)    bad "unexpected line from the python section: $verdict $desc" ;;
    esac
  done <"$1"
  [ "$seen_end" -eq 1 ] || bad "the python section did not run to its end: $(tail -3 "$1.err" 2>/dev/null | tr '\n' ' ')"
}

# ══════════════════════════════════════════════════════════════════════════════
echo "[P] price: tokens x the published price of the model that produced them"
# ══════════════════════════════════════════════════════════════════════════════
python3 - "$REPO" >"$TMP/p.out" 2>"$TMP/p.out.err" <<'PY'
import json, os, re, sys
repo = sys.argv[1]
sys.path.insert(0, os.path.join(repo, "bin", "lib"))
import fg_agent

out = []
def t(desc, cond, detail=""):
    out.append("%s\t%s\t%s" % ("PASS" if cond else "FAIL", desc, "" if cond else detail))

M = 1_000_000
def ev(mid, model="claude-opus-5-5", **usage):
    base = {"input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}
    base.update(usage)
    return json.dumps({"type": "assistant", "message": {"id": mid, "model": model, "usage": base, "content": []}})

def fed(*lines):
    meter = fg_agent.Meter()
    for line in lines:
        meter.feed(line + "\n")
    return meter

def near(a, b):
    return abs(a - b) < 1e-9

# claude-opus-5-5 is $4 input, $5 5m write, $8 1h write, $0.20 cache read, $20 output per million tokens
t("one million input tokens on claude-opus-5-5 cost $4", near(fed(ev("m", input_tokens=M)).spend_usd, 4.0), fed(ev("m", input_tokens=M)).spend_usd)
t("one million output tokens cost $20", near(fed(ev("m", output_tokens=M)).spend_usd, 20.0))
t("one million cache-read tokens cost $0.20", near(fed(ev("m", cache_read_input_tokens=M)).spend_usd, 0.20))
five = ev("m", cache_creation_input_tokens=M, cache_creation={"ephemeral_5m_input_tokens": M, "ephemeral_1h_input_tokens": 0})
hour = ev("m", cache_creation_input_tokens=M, cache_creation={"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": M})
bare = ev("m", cache_creation_input_tokens=M)
t("5-minute cache writes are priced at the 5-minute rate ($5)", near(fed(five).spend_usd, 5.0), fed(five).spend_usd)
t("1-hour cache writes are priced at the 1-hour rate ($8)", near(fed(hour).spend_usd, 8.0), fed(hour).spend_usd)
t("cache writes with no TTL split are priced at the 1-hour rate, the dearer one", near(fed(bare).spend_usd, 8.0), fed(bare).spend_usd)

# one message id, many events (a turn with several tool calls shares one id and one usage)
t("the same message id repeated is counted once", near(fed(ev("m", output_tokens=M), ev("m", output_tokens=M), ev("m", output_tokens=M)).spend_usd, 20.0))
t("distinct message ids are summed", near(fed(ev("a", output_tokens=M), ev("b", output_tokens=M)).spend_usd, 40.0))
t("a message id seen with growing usage is counted at its largest, not summed and not at its first",
  near(fed(ev("m", output_tokens=10), ev("m", output_tokens=M)).spend_usd, 20.0))
it = json.dumps({"type": "assistant", "message": {"id": "m", "model": "claude-opus-5-5", "content": [], "usage": {
    "input_tokens": 0, "output_tokens": 10, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
    "iterations": [{"output_tokens": M // 2, "input_tokens": 0}, {"output_tokens": M // 2, "input_tokens": 0}]}}})
t("iterations that add up to more than the top-level usage are what is counted", near(fed(it).spend_usd, 20.0), fed(it).spend_usd)

# models
unknown = fed(ev("m", model="claude-from-the-future-9", output_tokens=M))
t("an unknown model is priced at the highest listed output rate ($50)", near(unknown.spend_usd, 50.0), unknown.spend_usd)
t("an unknown model is flagged in price_basis", unknown.price_basis == "fallback-highest", unknown.price_basis)
known = fed(ev("m", output_tokens=M))
t("a listed model has price_basis table", known.price_basis == "table", known.price_basis)
t("a dated id resolves to its model (claude-opus-4-5-20251101 is $5 input)", near(fed(ev("m", model="claude-opus-4-5-20251101", input_tokens=M)).spend_usd, 5.0))
t("a context-window suffix is ignored (claude-opus-5-5[1m] is $4 input)", near(fed(ev("m", model="claude-opus-5-5[1m]", input_tokens=M)).spend_usd, 4.0))
t("the first model named is recorded", fed(ev("a", model="claude-sonnet-5-5"), ev("b")).model == "claude-sonnet-5-5")

# modifiers that stack on the token price
t("fast mode doubles the price", near(fed(ev("m", output_tokens=M, speed="fast")).spend_usd, 40.0))
t("US-only inference adds 10%", near(fed(ev("m", output_tokens=M, inference_geo="us")).spend_usd, 22.0), fed(ev("m", output_tokens=M, inference_geo="us")).spend_usd)
t("each web search costs a cent", near(fed(ev("m", server_tool_use={"web_search_requests": 3})).spend_usd, 0.03))

# the agent's own final total
result = json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": "built\nCLAIM: done", "total_cost_usd": 1.25})
m = fed(ev("m", output_tokens=M // 100), result)
t("the agent's own total_cost_usd is read from the result event", m.reported_usd == 1.25, m.reported_usd)
t("the final text is the result event's text", m.final_text == "built\nCLAIM: done", repr(m.final_text))
t("spend_usd is the larger of the estimate and the agent's own total", near(m.spend_usd, 1.25), m.spend_usd)
t("cost_usd prefers the agent's own total and says so", m.cost_usd == 1.25 and m.cost_source == "agent-reported", (m.cost_usd, m.cost_source))
est = fed(ev("m", output_tokens=M // 100))
t("without a reported total cost_usd is the estimate and says so", near(est.cost_usd, 0.20) and est.cost_source == "estimated-from-usage", (est.cost_usd, est.cost_source))
stopped = fed(json.dumps({"type": "result", "subtype": "error_max_budget_usd", "is_error": True, "total_cost_usd": 2.01}))
t("a result with subtype error_max_budget_usd marks the agent as stopped at its own budget", stopped.stopped_at_budget is True)

# robustness: the meter must never raise on what an agent prints
for junk in ("", "not json at all", "[1, 2]", "42", '{"type":"assistant"}', '{"type":"assistant","message":"x"}',
             '{"type":"assistant","message":{"id":"m","usage":"x"}}', '{"type":"assistant","message":{"id":"m","usage":{"output_tokens":"lots","input_tokens":-5}}}',
             '{"type":"result","total_cost_usd":"free"}'):
    try:
        junk_meter = fed(junk)
        t("junk is ignored without raising: %r" % junk[:40], junk_meter.spend_usd == 0.0, junk_meter.spend_usd)
    except Exception as exc:
        t("junk is ignored without raising: %r" % junk[:40], False, repr(exc))
plain = fed("hello", "CLAIM: done")
t("plain text is not metered: no usage means unmetered, cost_usd is None, never 0", plain.metered is False and plain.cost_usd is None and plain.cost_source == "unmetered", (plain.metered, plain.cost_usd, plain.cost_source))

# the table in the code is the table frozen in the preregistration
text = open(os.path.join(repo, "evals", "benchmark", "false-green", "PREREG.md"), encoding="utf-8").read()
frozen = {}
for row in re.finditer(r"^\| (claude-[a-z0-9-]+) \| ([0-9.]+) \| ([0-9.]+) \| ([0-9.]+) \| ([0-9.]+) \| ([0-9.]+) \|$", text, re.M):
    frozen[row.group(1)] = tuple(float(row.group(i)) for i in range(2, 7))
t("the price table frozen in PREREG.md Amendment 1 has rows", len(frozen) >= 10, len(frozen))
t("the price table frozen in PREREG.md Amendment 1 is exactly fg_agent.PRICES", frozen == {k: tuple(v) for k, v in fg_agent.PRICES.items()},
  "only in the amendment: %s; only in code: %s; differing: %s" % (
      sorted(set(frozen) - set(fg_agent.PRICES)), sorted(set(fg_agent.PRICES) - set(frozen)),
      sorted(k for k in frozen if k in fg_agent.PRICES and frozen[k] != tuple(fg_agent.PRICES[k]))))
t("the fallback price is the highest listed in every column", fg_agent.FALLBACK == tuple(max(col) for col in zip(*fg_agent.PRICES.values())), fg_agent.FALLBACK)

print("\n".join(out))
print("END")
PY
report "$TMP/p.out"

# ══════════════════════════════════════════════════════════════════════════════
echo "[K] kill: the whole process group, at the cap or the wall clock, and never below the cap"
# ══════════════════════════════════════════════════════════════════════════════
cat >"$TMP/fake_stream.py" <<'PY'
#!/usr/bin/env python3
# A fake streaming agent. key=value args: events, cost (USD per event on claude-opus-5-5, $20/M output),
# interval (s between events), same_id=1, grandchild=<pidfile>, deliver=<file copied to webhook.mjs>,
# reported=<total_cost_usd>, claim, model, silent_for=<s> (sleep without output).
import json, shutil, subprocess, sys, time
args = dict(a.split("=", 1) for a in sys.argv[1:] if "=" in a and a.split("=", 1)[0].isidentifier())
if args.get("grandchild"):
    child = subprocess.Popen(["sleep", "300"])
    with open(args["grandchild"], "w") as fh:
        fh.write(str(child.pid))
time.sleep(float(args.get("silent_for", "0")))
tokens = int(round(float(args.get("cost", "0.1")) / 20.0 * 1_000_000))
for i in range(int(args.get("events", "1"))):
    mid = "msg_same" if args.get("same_id") == "1" else "msg_%d" % i
    print(json.dumps({"type": "assistant", "message": {"id": mid, "model": args.get("model", "claude-opus-5-5"), "content": [{"type": "text", "text": "working"}],
          "usage": {"input_tokens": 0, "output_tokens": tokens, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}}), flush=True)
    time.sleep(float(args.get("interval", "0")))
if args.get("deliver"):
    shutil.copy(args["deliver"], "webhook.mjs")
result = {"type": "result", "subtype": "success", "is_error": False, "result": "finished\nCLAIM: %s" % args.get("claim", "done")}
if args.get("reported") is not None:
    result["total_cost_usd"] = float(args["reported"])
print(json.dumps(result), flush=True)
PY
python3 - "$REPO" "$TMP" >"$TMP/k.out" 2>"$TMP/k.out.err" <<'PY'
import os, sys, time
repo, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(repo, "bin", "lib"))
import fg_agent

out = []
def t(desc, cond, detail=""):
    out.append("%s\t%s\t%s" % ("PASS" if cond else "FAIL", desc, "" if cond else detail))

fake = [sys.executable, os.path.join(tmp, "fake_stream.py")]

def gone(pid_file):
    """True once the grandchild the fake agent started is dead (the kill is asynchronous: poll briefly)."""
    pid = int(open(pid_file).read())
    for _ in range(40):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.1)
    return False

# K1 below the cap: runs to the end
meter = fg_agent.Meter()
run = fg_agent.supervise(fake + ["events=3", "cost=0.30", "interval=0.05"], tmp, meter, 2.00, 30)
t("below the cap the run is not killed", run.killed is None and run.rc == 0, (run.killed, run.rc))
t("below the cap the run's output is captured", "CLAIM: done" in run.stdout, run.stdout[-200:])
t("below the cap the estimate is what was spent ($0.90)", abs(meter.spend_usd - 0.90) < 1e-6, meter.spend_usd)

# K2 over the cap: killed at the cap, promptly, grandchild included
pid_file = os.path.join(tmp, "k2.pid")
meter = fg_agent.Meter()
started = time.monotonic()
run = fg_agent.supervise(fake + ["events=20", "cost=0.60", "interval=0.5", "grandchild=" + pid_file], tmp, meter, 2.00, 60)
t("over the cap the run is killed and says why", run.killed == "cap", run.killed)
t("over the cap the run was killed long before it would have finished (10 s of events)", time.monotonic() - started < 6, time.monotonic() - started)
t("the estimate had reached the cap when it was killed, and not by much", 2.00 <= meter.spend_usd < 3.2, meter.spend_usd)
t("the killed run never printed its final claim", "CLAIM" not in run.stdout, run.stdout[-200:])
t("killing the run killed the whole process group (the agent's grandchild is dead)", gone(pid_file))

# K3 wall clock
pid_file = os.path.join(tmp, "k3.pid")
meter = fg_agent.Meter()
started = time.monotonic()
run = fg_agent.supervise(fake + ["events=1", "silent_for=120", "grandchild=" + pid_file], tmp, meter, 2.00, 1)
t("past the wall-clock limit the run is killed and says why", run.killed == "timeout", run.killed)
t("the timeout fired at the limit, not at the agent's own pace", time.monotonic() - started < 6, time.monotonic() - started)
t("the timeout killed the grandchild too", gone(pid_file))

# K4 falsifiability: one message id repeated must not be double-counted into a kill
meter = fg_agent.Meter()
run = fg_agent.supervise(fake + ["events=6", "cost=1.50", "same_id=1", "interval=0.05"], tmp, meter, 2.00, 30)
t("six events of one message id (one $1.50 message) are not killed at a $2.00 cap", run.killed is None, (run.killed, meter.spend_usd))
t("and the estimate is one message, $1.50", abs(meter.spend_usd - 1.50) < 1e-6, meter.spend_usd)

# K5 an agent that reports no usage runs to the end and is unmetered
meter = fg_agent.Meter()
run = fg_agent.supervise([sys.executable, "-c", "print('thinking'); print('CLAIM: done')"], tmp, meter, 2.00, 30)
t("an agent that reports no usage is not killed", run.killed is None and run.rc == 0, (run.killed, run.rc))
t("and is unmetered", meter.metered is False)

# K6 a command that cannot start is a result, not a crash
meter = fg_agent.Meter()
run = fg_agent.supervise([os.path.join(tmp, "no-such-agent")], tmp, meter, 2.00, 30)
t("a command that does not exist returns rc 127 with the reason", run.rc == 127 and run.stderr, (run.rc, run.stderr))

# K7 a supervisor that fails must not leave the agent running (and spending): the group is killed first
pid_file = os.path.join(tmp, "k7.pid")

class Blind(fg_agent.Meter):
    @property
    def spend_usd(self):
        while not os.path.exists(pid_file):
            time.sleep(0.02)
        raise RuntimeError("the meter cannot read spend")

raised = None
try:
    fg_agent.supervise(fake + ["events=20", "cost=0.10", "interval=0.5", "grandchild=" + pid_file], tmp, Blind(), 2.00, 60)
except RuntimeError as exc:
    raised = exc
t("a failure in the supervisor propagates", raised is not None, raised)
t("and the agent's process group is killed before it does (the grandchild is dead)", os.path.exists(pid_file) and gone(pid_file))

# K8 a meter that raises while it is being fed kills the run: spend that cannot be read is not left running
pid_file = os.path.join(tmp, "k8.pid")

class Faulty(fg_agent.Meter):
    def feed(self, line):
        raise ValueError("cannot parse")

run = fg_agent.supervise(fake + ["events=20", "cost=0.10", "interval=0.5", "grandchild=" + pid_file], tmp, Faulty(), 2.00, 60)
t("a meter that raises on feed kills the run and says so", run.killed == "fault" and "cannot parse" in (run.fault or ""), (run.killed, run.fault))
t("and the fault run's grandchild is dead", gone(pid_file))

print("\n".join(out))
print("END")
PY
report "$TMP/k.out"

# ══════════════════════════════════════════════════════════════════════════════
echo "[B] bench: through bin/benchmark and the Study A live path"
# ══════════════════════════════════════════════════════════════════════════════
GOLDEN="$SUITE/tasks/settlement-webhook/base/golden.mjs"
bench() {  # bench <name> <agent-cmd...>: one fake agent, both arms, rows in $TMP/<name>
  local name="$1"; shift
  bash "$BENCH" run --suite false-green --agent "fake-$name" --agent-cmd "$*" --live --confirm-spend --out "$TMP/$name" >"$TMP/$name.out" 2>"$TMP/$name.err"
}
PYBIN="$(command -v python3)"
printf '#!/bin/sh\necho "CLAIM: done"\n' >"$TMP/plain.sh"; chmod +x "$TMP/plain.sh"
bench capped   "$PYBIN $TMP/fake_stream.py events=20 cost=0.90 interval=0.4 {prompt}"
bench ok       "$PYBIN $TMP/fake_stream.py events=2 cost=0.10 reported=0.2 deliver=$GOLDEN {prompt}"
bench over     "$PYBIN $TMP/fake_stream.py events=1 cost=0.50 reported=2.40 deliver=$GOLDEN {prompt}"
bench plain    "$TMP/plain.sh {prompt}"

jqok "a run that hits the cap is an infrastructure exclusion that says so"     "$TMP/capped/runhmd.jsonl" '.infra_error | startswith("per-run cap")'
jqok "a capped run is over_cap and its cost is the estimate that tripped it"   "$TMP/capped/runhmd.jsonl" '.over_cap == true and .cost_usd >= 2.0 and .cost_usd < 4.0 and .cost_source == "estimated-from-usage"'
jqok "a killed run never printed a claim, so its row is not a false green"     "$TMP/capped/runhmd.jsonl" '.agent_claim == "gave_up" and .false_green == false'
jqok "both arms of the capped run carry the exclusion"                         <(cat "$TMP/capped/alone.jsonl" "$TMP/capped/runhmd.jsonl") '.infra_error | startswith("per-run cap")'
bash "$BENCH" summarize --json --suite false-green --in "$TMP/capped" >"$TMP/capped.json" 2>/dev/null
jqok "the summary lists the capped run as excluded, with the reason"           "$TMP/capped.json" '(.study_a.excluded|length) == 1 and (.study_a.excluded[0].reason | startswith("infrastructure: per-run cap"))'
jqok "and counts nothing from it"                                              "$TMP/capped.json" '.study_a.pooled.runs == 0'

jqok "a normal metered run: claim, ground truth and no infrastructure error"   "$TMP/ok/runhmd.jsonl" '.agent_claim == "done" and .ground_truth == "pass" and .infra_error == null and .over_cap == false'
jqok "its cost is the agent's own total, and the row says so"                  "$TMP/ok/runhmd.jsonl" '.cost_usd == 0.2 and .cost_source == "agent-reported"'
jqok "its model and price basis are recorded"                                  "$TMP/ok/runhmd.jsonl" '.model == "claude-opus-5-5" and .price_basis == "table"'
jqok "its tokens are recorded"                                                 "$TMP/ok/runhmd.jsonl" '.tokens.out == 10000 and .tokens.in == 0'

jqok "a run that finishes with a reported cost over the cap is excluded too"   "$TMP/over/runhmd.jsonl" '(.infra_error | startswith("per-run cap")) and .over_cap == true and .cost_usd == 2.4'

jqok "an agent that reports no usage is unmetered, its cost null, not zero"    "$TMP/plain/runhmd.jsonl" '.cost_source == "unmetered" and .cost_usd == null and .infra_error == null'
check "and the harness warns that the cap could not be enforced for it"        grep -q 'per-run cap could not be enforced' "$TMP/plain.err"
check "the run line reports the unmetered runs instead of a bare dollar figure" grep -q 'unmetered' "$TMP/plain.out"

# the real claude-code command line, against a stub claude that prints canned events
mkdir -p "$TMP/stubbin"
cat >"$TMP/claude.stream" <<'EOF'
{"type":"system","subtype":"init","model":"claude-opus-5-5"}
{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1000,"output_tokens":2000,"cache_read_input_tokens":5000,"cache_creation_input_tokens":0}}}
{"type":"result","subtype":"success","is_error":false,"result":"built it\nCLAIM: done","total_cost_usd":0.0421,"num_turns":1}
EOF
cat >"$TMP/stubbin/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >"$TMP/claude.argv"
cp "$GOLDEN" webhook.mjs
cat "$TMP/claude.stream"
EOF
chmod +x "$TMP/stubbin/claude"
PATH="$TMP/stubbin:$PATH" bash "$BENCH" run --suite false-green --agent claude-code --live --confirm-spend --out "$TMP/cc" >"$TMP/cc.out" 2>"$TMP/cc.err"
check "the claude-code command streams JSON events"                            bash -c "grep -qx 'stream-json' '$TMP/claude.argv' && grep -qx -- '--verbose' '$TMP/claude.argv'"
check "the claude-code command carries the agent's own cap, --max-budget-usd 2.00" bash -c "[ \"\$(awk '/^--max-budget-usd\$/{getline; print}' '$TMP/claude.argv')\" = 2.00 ]"
check "the claude-code command still passes the prompt with -p"                bash -c "grep -qx -- '-p' '$TMP/claude.argv' && grep -q 'CLAIM: done' '$TMP/claude.argv'"
jqok "the claude-code row has the agent's claim, cost and model"               "$TMP/cc/runhmd.jsonl" '.agent == "claude-code" and .agent_claim == "done" and .ground_truth == "pass" and .cost_usd == 0.0421 and .cost_source == "agent-reported" and .model == "claude-opus-5-5"'

# the 30-minute limit, wired through the live path (the constant patched down to one second)
python3 - "$REPO" "$TMP" >"$TMP/t.out" 2>"$TMP/t.out.err" <<'PY'
import argparse, contextlib, io, json, os, sys
repo, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(repo, "bin", "lib"))
import fg_bench

out = []
def t(desc, cond, detail=""):
    out.append("%s\t%s\t%s" % ("PASS" if cond else "FAIL", desc, "" if cond else detail))

fg_bench.RUN_TIMEOUT_S = 1
args = argparse.Namespace(agent="fake-timeout", agent_cmd="%s %s events=1 silent_for=60 {prompt}" % (sys.executable, os.path.join(tmp, "fake_stream.py")),
                          arm="runhmd", out=os.path.join(tmp, "timeout"))
with contextlib.redirect_stdout(io.StringIO()):
    fg_bench.run_study_a_live(fg_bench.SUITE, args)
row = json.loads(open(os.path.join(tmp, "timeout", "runhmd.jsonl")).read().splitlines()[0])
t("a run past the wall-clock limit is an infrastructure exclusion that says so", str(row["infra_error"]).startswith("agent timed out"), row["infra_error"])
t("and has no claim, so it cannot be a false green", row["agent_claim"] == "gave_up" and row["false_green"] is False, row)
print("\n".join(out))
print("END")
PY
report "$TMP/t.out"

echo
echo "false-green-agent-cap: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
