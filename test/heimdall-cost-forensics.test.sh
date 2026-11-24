#!/usr/bin/env bash
# Tests for bin/heimdall-cost-forensics — the portable Claude-API token/cost
# forensics tool. Hermetic: every fixture below is synthesized under a mktemp
# dir; this test NEVER reads the operator's real ~/.claude/projects history.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOOL="$ROOT/bin/heimdall-cost-forensics"

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  echo "ok - $1"
}

bad() {
  FAIL=$((FAIL + 1))
  echo "FAIL - $1"
}

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

# Run a python3 checker script (stdin) against a json file (argv[1]); the
# script must print one "PASS <name>" or "FAIL <name>" line per assertion.
# Runs in the CURRENT shell (redirected from a file, not a pipe) so PASS/FAIL
# counters actually persist — a `... | while read` pipeline would run the
# loop in a subshell and silently drop every counter update.
run_checks() {
  local json_file="$1" out_file
  out_file="$TMPDIR_T/checks.$$.$RANDOM.txt"
  python3 - "$json_file" > "$out_file"
  local rc=$?
  # A checker that crashes prints no FAIL line for the assertions it never
  # reached; without this guard a crash would read as a pass.
  [ "$rc" -eq 0 ] || bad "checker script crashed (exit $rc): its remaining assertions never ran"
  while IFS= read -r line; do
    case "$line" in
      "PASS "*) ok "${line#PASS }" ;;
      "FAIL "*) bad "${line#FAIL }" ;;
    esac
  done < "$out_file"
}

[ -x "$TOOL" ] || { echo "FATAL: $TOOL not found or not executable"; exit 1; }

# ── 1. --help: exit 0, states the privacy guarantee and pricing source ────
HELP_OUT="$("$TOOL" --help 2>&1)"
HELP_RC=$?
[ "$HELP_RC" -eq 0 ] && ok "--help exits 0" || bad "--help exit code was $HELP_RC, want 0"
echo "$HELP_OUT" | grep -q "PRIVACY GUARANTEE" && ok "--help states the privacy guarantee" \
  || bad "--help missing the privacy guarantee section"
echo "$HELP_OUT" | grep -q "NEVER sends anything anywhere" && ok "--help asserts offline/never-sends" \
  || bad "--help missing the offline/never-sends assertion"
echo "$HELP_OUT" | grep -q "PRICING SOURCE" && ok "--help cites its pricing source" \
  || bad "--help missing the pricing source citation"
echo "$HELP_OUT" | grep -q "2026-06-24" && ok "--help cites the pricing table's cache date" \
  || bad "--help missing the pricing table cache date"
echo "$HELP_OUT" | grep -q "bin/lib/tier-table.json" && ok "--help names the table the rates are read from" \
  || bad "--help does not name bin/lib/tier-table.json as the pricing source"

# ── 2. no transcripts found -> honest empty result, exit 0 (not an error) ──
EMPTY_DIR="$TMPDIR_T/empty"
mkdir -p "$EMPTY_DIR"
EMPTY_OUT="$("$TOOL" --root "$EMPTY_DIR" 2>&1)"
EMPTY_RC=$?
[ "$EMPTY_RC" -eq 0 ] && ok "empty root exits 0" || bad "empty root exit code was $EMPTY_RC, want 0"
echo "$EMPTY_OUT" | grep -q "honest empty result" && ok "empty root reports an honest empty result" \
  || bad "empty root did not report an honest empty result"

# ── 3. known fixture: message.id dedup + cache-creation fallback + exact $ ─
# msg_001 is written as 3 duplicate JSONL lines (simulating a real transcript
# request's separate thinking/text/tool_use content-block lines, which all
# repeat the identical message.usage) — must collapse to ONE counted request.
# msg_002 carries ONLY the flat legacy cache_creation_input_tokens field (no
# nested 5m/1h breakdown) -> must hit the documented 5m-TTL fallback path.
# Model is a DATED SNAPSHOT id (claude-sonnet-5-20260301) to prove
# normalize_model() strips the date suffix and still finds the sonnet-5 rate.
#
# Hand-computed expectations (sonnet-5: input=$2, output=$10, cache_read=$0.20,
# cache_write_5m=$2.50 per MTok):
#   req1: in=1000 out=200 cache_read=5000 cache_write_5m=300
#     -> $0.002 + $0.002 + $0.001 + $0.00075 = $0.00575
#   req2: in=2000 out=400 cache_read=10000 cache_write_5m=500 (via fallback)
#     -> $0.004 + $0.004 + $0.002 + $0.00125 = $0.01125
#   total priced cost = $0.017 exactly; field $ = input .006 output .006
#   cache_read .003 cache_write_5m .002 (sums to .017)
KNOWN_DIR="$TMPDIR_T/known"
mkdir -p "$KNOWN_DIR"
KNOWN_FILE="$KNOWN_DIR/session-known.jsonl"
SECRET="SECRET_TOKEN_DO_NOT_LEAK_xyz789"
cat > "$KNOWN_FILE" <<EOF
{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"msg_001","model":"claude-sonnet-5-20260301","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":5000,"cache_creation":{"ephemeral_5m_input_tokens":300,"ephemeral_1h_input_tokens":0},"cache_creation_input_tokens":300},"content":[{"type":"thinking","thinking":"$SECRET"}]}}
{"type":"assistant","timestamp":"2026-01-01T00:00:01Z","message":{"id":"msg_001","model":"claude-sonnet-5-20260301","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":5000,"cache_creation":{"ephemeral_5m_input_tokens":300,"ephemeral_1h_input_tokens":0},"cache_creation_input_tokens":300},"content":[{"type":"text","text":"hello"}]}}
{"type":"assistant","timestamp":"2026-01-01T00:00:02Z","message":{"id":"msg_001","model":"claude-sonnet-5-20260301","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":5000,"cache_creation":{"ephemeral_5m_input_tokens":300,"ephemeral_1h_input_tokens":0},"cache_creation_input_tokens":300},"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/etc/passwd"}}]}}
{"type":"assistant","timestamp":"2026-01-01T00:00:03Z","message":{"id":"msg_002","model":"claude-sonnet-5-20260301","usage":{"input_tokens":2000,"output_tokens":400,"cache_read_input_tokens":10000,"cache_creation_input_tokens":500},"content":[{"type":"text","text":"world"}]}}
EOF

KNOWN_JSON_FILE="$TMPDIR_T/known.json"
"$TOOL" --root "$KNOWN_DIR" --json > "$KNOWN_JSON_FILE" 2>"$TMPDIR_T/known.stderr"
KNOWN_RC=$?
[ "$KNOWN_RC" -eq 0 ] && ok "known fixture run exits 0" || bad "known fixture run exit code was $KNOWN_RC"

run_checks "$KNOWN_JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print("%s %s%s" % (status, name, ("" if cond or not detail else " (%s)" % detail)))

check("dedup: n_requests==2 (3 duplicate msg_001 lines collapse to 1)",
      d["n_requests"] == 2, "got %r" % (d["n_requests"],))
check("n_sessions==1", d["n_sessions"] == 1, "got %r" % (d["n_sessions"],))
check("n_files==1", d["n_files"] == 1, "got %r" % (d["n_files"],))
check("total input tokens==3000", d["totals_tokens"]["input"] == 3000, "got %r" % (d["totals_tokens"],))
check("total output tokens==600", d["totals_tokens"]["output"] == 600)
check("total cache_read tokens==15000", d["totals_tokens"]["cache_read"] == 15000)
check("total cache_write_5m tokens==800 (300 nested + 500 fallback, no double-count)",
      d["totals_tokens"]["cache_write_5m"] == 800, "got %r" % (d["totals_tokens"],))
check("total cache_write_1h tokens==0", d["totals_tokens"]["cache_write_1h"] == 0)
check("fallback path used for exactly 500 tok (msg_002's flat field)",
      d["fallback_cache_write_tokens"] == 500, "got %r" % (d["fallback_cache_write_tokens"],))
check("priced_cost_total_usd==0.017 exactly",
      abs(d["priced_cost_total_usd"] - 0.017) < 1e-9, "got %r" % (d["priced_cost_total_usd"],))
check("field_dollars.input==0.006", abs(d["field_dollars"]["input"] - 0.006) < 1e-9)
check("field_dollars.output==0.006", abs(d["field_dollars"]["output"] - 0.006) < 1e-9)
check("field_dollars.cache_read==0.003", abs(d["field_dollars"]["cache_read"] - 0.003) < 1e-9)
check("field_dollars.cache_write_5m==0.002", abs(d["field_dollars"]["cache_write_5m"] - 0.002) < 1e-9)
check("model normalized: 'claude-sonnet-5' (dated snapshot suffix stripped)",
      "claude-sonnet-5" in d["per_model"], "per_model keys: %r" % (list(d["per_model"]),))
check("per_model sonnet-5 requests==2", d["per_model"].get("claude-sonnet-5", {}).get("requests") == 2)
check("unpriced_tokens_total==0 (every token in this fixture is priced)",
      d["unpriced_tokens_total"] == 0, "got %r" % (d["unpriced_tokens_total"],))
check("sparse-data guard: regime comparison correctly UNAVAILABLE at n=2",
      d["regime_comparison"]["available"] is False)
check("sparse-data reason names the request-count shortfall",
      "distinct request" in d["regime_comparison"].get("reason", ""),
      "reason: %r" % (d["regime_comparison"].get("reason"),))
check("ts_min captured", d["ts_min"] == "2026-01-01T00:00:00Z", "got %r" % (d["ts_min"],))
check("ts_max captured", d["ts_max"] == "2026-01-01T00:00:03Z", "got %r" % (d["ts_max"],))
PY

# ── 4. privacy proof: the planted secret NEVER appears in any output stream ─
KNOWN_TEXT_OUT="$("$TOOL" --root "$KNOWN_DIR" 2>&1)"
if echo "$KNOWN_TEXT_OUT" | grep -qF "$SECRET"; then
  bad "PRIVACY VIOLATION: secret leaked into text-mode output"
else
  ok "privacy: secret absent from text-mode stdout+stderr"
fi
if grep -qF "$SECRET" "$KNOWN_JSON_FILE" "$TMPDIR_T/known.stderr"; then
  bad "PRIVACY VIOLATION: secret leaked into json-mode output"
else
  ok "privacy: secret absent from --json stdout and stderr"
fi

# ── 5. large fixture: 40 requests in two well-separated context regimes ───
# 20 "low" requests at context=10000 tok, 20 "high" at context=50000 tok (5x
# spread, comfortably over MIN_SPREAD_RATIO=2.0) and n=40 >= MIN_REQUESTS(30)
# -> the regime comparison MUST engage and produce the exact hand-computed
# ratio below (all requests within a group are identical, so stdev==0 too).
#   low  cost/req  = 1000*2/1e6 + 9000*0.20/1e6 + 100*10/1e6 = 0.0048
#   high cost/req  = 5000*2/1e6 + 45000*0.20/1e6 + 100*10/1e6 = 0.02
#   ratio = 0.02 / 0.0048 = 4.1666... -> 4.17
LARGE_DIR="$TMPDIR_T/large"
mkdir -p "$LARGE_DIR"
LARGE_FILE="$LARGE_DIR/session-large.jsonl"
python3 - "$LARGE_FILE" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "w") as fh:
    for i in range(20):
        rec = {
            "type": "assistant",
            "timestamp": "2026-01-02T00:00:%02dZ" % i,
            "message": {
                "id": "low_%03d" % i,
                "model": "claude-sonnet-5",
                "usage": {
                    "input_tokens": 1000, "output_tokens": 100,
                    "cache_read_input_tokens": 9000,
                    "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 0},
                },
            },
        }
        fh.write(json.dumps(rec) + "\n")
    for i in range(20):
        rec = {
            "type": "assistant",
            "timestamp": "2026-01-02T01:00:%02dZ" % i,
            "message": {
                "id": "high_%03d" % i,
                "model": "claude-sonnet-5",
                "usage": {
                    "input_tokens": 5000, "output_tokens": 100,
                    "cache_read_input_tokens": 45000,
                    "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 0},
                },
            },
        }
        fh.write(json.dumps(rec) + "\n")
PY

LARGE_JSON_FILE="$TMPDIR_T/large.json"
"$TOOL" --root "$LARGE_FILE" --json > "$LARGE_JSON_FILE" 2>"$TMPDIR_T/large.stderr"
LARGE_RC=$?
[ "$LARGE_RC" -eq 0 ] && ok "large fixture run exits 0 (root given as a single file, not a dir)" \
  || bad "large fixture run exit code was $LARGE_RC"

run_checks "$LARGE_JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print("%s %s%s" % (status, name, ("" if cond or not detail else " (%s)" % detail)))

check("n_requests==40", d["n_requests"] == 40, "got %r" % (d["n_requests"],))
r = d["regime_comparison"]
check("regime comparison IS available at n=40 with 5x spread", r["available"] is True, "got %r" % (r,))
if r["available"]:
    check("low_context_mean_tokens==10000", r["low_context_mean_tokens"] == 10000, "got %r" % (r,))
    check("high_context_mean_tokens==50000", r["high_context_mean_tokens"] == 50000, "got %r" % (r,))
    check("low_cost_mean_usd==0.0048", abs(r["low_cost_mean_usd"] - 0.0048) < 1e-9, "got %r" % (r,))
    check("high_cost_mean_usd==0.02", abs(r["high_cost_mean_usd"] - 0.02) < 1e-9, "got %r" % (r,))
    check("low_cost_stdev_usd==0.0 (homogeneous group)", abs(r["low_cost_stdev_usd"] - 0.0) < 1e-9)
    check("high_cost_stdev_usd==0.0 (homogeneous group)", abs(r["high_cost_stdev_usd"] - 0.0) < 1e-9)
    check("ratio==4.17 (0.02 / 0.0048, hand-computed)", abs(r["ratio"] - 4.17) < 1e-9, "got %r" % (r["ratio"],))
PY

# --min-requests raises the bar: the SAME 40-request fixture must become
# "not enough data" when the threshold is set above 40 -- proves the flag is
# actually read, not merely accepted and ignored.
MINREQ_OUT="$("$TOOL" --root "$LARGE_FILE" --min-requests 999 2>&1)"
echo "$MINREQ_OUT" | grep -q "not available" && ok "--min-requests override actually raises the sparse-data bar" \
  || bad "--min-requests 999 did not disable the regime comparison on a 40-request fixture"

# ── 6. unknown model: tokens counted, dollars excluded, model named ────────
UNPRICED_FILE="$TMPDIR_T/session-unpriced.jsonl"
cat > "$UNPRICED_FILE" <<'EOF'
{"type":"assistant","timestamp":"2026-01-03T00:00:00Z","message":{"id":"msg_up1","model":"claude-totally-unknown-9","usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":0}}}
EOF
UNPRICED_JSON_FILE="$TMPDIR_T/unpriced.json"
"$TOOL" --root "$UNPRICED_FILE" --json > "$UNPRICED_JSON_FILE" 2>&1
run_checks "$UNPRICED_JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print("%s %s%s" % (status, name, ("" if cond or not detail else " (%s)" % detail)))

check("unrecognized model: tokens still counted (1100 total)",
      d["totals_tokens"]["input"] + d["totals_tokens"]["output"] == 1100)
check("unrecognized model: $0 priced (never invents a price)",
      abs(d["priced_cost_total_usd"] - 0.0) < 1e-9, "got %r" % (d["priced_cost_total_usd"],))
check("unrecognized model: excluded tokens counted (1100)",
      d["unpriced_tokens_total"] == 1100, "got %r" % (d["unpriced_tokens_total"],))
check("unrecognized model named in unpriced_models",
      d["unpriced_models"].get("claude-totally-unknown-9") == 1100, "got %r" % (d["unpriced_models"],))
PY

# ── 7. partial pricing: Mythos 5.1's UNCONFIRMED cache-read rate stays None ─
# input/output ARE priced for this model; only the cache_read slice is left
# unpriced -- a distinct code path from "entire model unknown" above.
PARTIAL_FILE="$TMPDIR_T/session-partial.jsonl"
cat > "$PARTIAL_FILE" <<'EOF'
{"type":"assistant","timestamp":"2026-01-04T00:00:00Z","message":{"id":"msg_pp1","model":"claude-mythos-5-1","usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":2000}}}
EOF
PARTIAL_JSON_FILE="$TMPDIR_T/partial.json"
"$TOOL" --root "$PARTIAL_FILE" --json > "$PARTIAL_JSON_FILE" 2>&1
run_checks "$PARTIAL_JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print("%s %s%s" % (status, name, ("" if cond or not detail else " (%s)" % detail)))

# input 1000*$10/1e6=0.01, output 100*$50/1e6=0.005 -> priced=0.015;
# cache_read (2000 tok) unpriced because Mythos 5.1's read rate is None.
check("partial pricing: input+output priced ($0.015)",
      abs(d["priced_cost_total_usd"] - 0.015) < 1e-9, "got %r" % (d["priced_cost_total_usd"],))
check("partial pricing: cache_read tokens (2000) left unpriced",
      d["unpriced_tokens_total"] == 2000, "got %r" % (d["unpriced_tokens_total"],))
check("partial pricing: model named in unpriced_models despite being a KNOWN model",
      d["unpriced_models"].get("claude-mythos-5-1") == 2000, "got %r" % (d["unpriced_models"],))
PY

# ── 8. root precedence: --root beats HMD_COST_FORENSICS_ROOT beats default ─
ENV_ONLY_OUT="$(HMD_COST_FORENSICS_ROOT="$EMPTY_DIR" "$TOOL" 2>&1)"
echo "$ENV_ONLY_OUT" | grep -q "0 file(s) scanned" \
  && ok "HMD_COST_FORENSICS_ROOT overrides the default root (scanned 0 files, never the real ~/.claude/projects)" \
  || bad "HMD_COST_FORENSICS_ROOT did not override the default root"

PRECEDENCE_JSON="$TMPDIR_T/precedence.json"
HMD_COST_FORENSICS_ROOT="/definitely/does/not/exist-xyz-heimdall-test" \
  "$TOOL" --root "$KNOWN_DIR" --json > "$PRECEDENCE_JSON" 2>&1
python3 -c "
import json
d = json.load(open('$PRECEDENCE_JSON'))
import sys
sys.exit(0 if d.get('n_requests') == 2 else 1)
" && ok "--root takes precedence over HMD_COST_FORENSICS_ROOT" \
  || bad "--root did not take precedence over HMD_COST_FORENSICS_ROOT"

# ── 9. CLI error handling: bad invocations exit 2, not 0 and not a crash ──
"$TOOL" --nope-not-a-flag >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok "unrecognized flag exits 2" || bad "unrecognized flag exit was $RC, want 2"

"$TOOL" --root >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok "missing --root argument exits 2" || bad "missing --root argument exit was $RC, want 2"

"$TOOL" --min-requests not-a-number >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok "non-integer --min-requests exits 2" || bad "non-integer --min-requests exit was $RC, want 2"

# gen_jsonl <outfile> <spec>: one assistant record per spec line, each line
#   "<message id> <model> <input> <output> <cache_read> <cache_write_5m> <cache_write_1h>"
gen_jsonl() {
  python3 - "$1" "$2" <<'PY'
import json, sys
out, spec = sys.argv[1], sys.argv[2]
with open(out, "w") as fh:
    for n, line in enumerate(spec.strip().splitlines()):
        mid, model, tin, tout, read, w5m, w1h = line.split()
        usage = {
            "input_tokens": int(tin), "output_tokens": int(tout),
            "cache_read_input_tokens": int(read),
            "cache_creation": {
                "ephemeral_5m_input_tokens": int(w5m),
                "ephemeral_1h_input_tokens": int(w1h),
            },
        }
        rec = {"type": "assistant", "timestamp": "2026-02-01T00:00:%02dZ" % n,
               "message": {"id": mid, "model": model, "usage": usage}}
        fh.write(json.dumps(rec) + "\n")
PY
}

# ── 10. the Claude 5.5 generation is priced, from bin/lib/tier-table.json ──
# Regression for the unpriced-corpus bug (docs/analysis/2026-11-22-token-
# utilization-next.md, "Finding (tool bug)"): the tool's rate table had no row
# for any 5.5-generation id, so ~88% of a real corpus's tokens landed in
# unpriced_models and every dollar figure it printed was a floor.
#
# Every request below carries exactly 1,000,000 tokens in EACH of the five
# fields, so a model's cost in dollars is the plain SUM of its five $/MTok
# rates, read straight off the list prices:
#   opus 5.5    4 + 20 + 0.20 + 5.00 + 8.00 = 37.20  (cache read 0.05x, not the 0.1x default)
#   sonnet 5.5  2 + 10 + 0.10 + 2.50 + 4.00 = 18.60  (dated snapshot id: suffix stripped)
#   fable 5.2   8 + 40 + 0.20 + 10   + 16   = 74.20  (cache read 0.025x)
#   mythos 5.2  the fable 5.2 card          = 74.20
#   total 204.20; cache_read $ = 0.20+0.10+0.20+0.20 = 0.70 (a 0.1x default read would give 2.20)
GEN55_FILE="$TMPDIR_T/session-gen55.jsonl"
gen_jsonl "$GEN55_FILE" '
g_opus   claude-opus-5-5             1000000 1000000 1000000 1000000 1000000
g_sonnet claude-sonnet-5-5-20261101  1000000 1000000 1000000 1000000 1000000
g_fable  claude-fable-5-2            1000000 1000000 1000000 1000000 1000000
g_mythos claude-mythos-5-2           1000000 1000000 1000000 1000000 1000000
'
GEN55_JSON="$TMPDIR_T/gen55.json"
"$TOOL" --root "$GEN55_FILE" --json > "$GEN55_JSON" 2>"$TMPDIR_T/gen55.stderr"
GEN55_RC=$?
[ "$GEN55_RC" -eq 0 ] && ok "5.5-generation fixture run exits 0" || bad "5.5-generation fixture run exit code was $GEN55_RC"
run_checks "$GEN55_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print("%s %s%s" % (status, name, ("" if cond or not detail else " (%s)" % detail)))

check("5.5 gen: every token priced (unpriced_tokens_total==0)",
      d.get("unpriced_tokens_total") == 0, "got %r" % (d.get("unpriced_tokens_total"),))
check("5.5 gen: unpriced_models is empty",
      d.get("unpriced_models") == {}, "got %r" % (d.get("unpriced_models"),))
check("5.5 gen: nothing estimated (all four ids have an exact row)",
      d.get("estimated_models") == {} and d.get("estimated_cost_usd") == 0,
      "got %r / %r" % (d.get("estimated_models"), d.get("estimated_cost_usd")))
per_model = d.get("per_model", {})
for name, want in (("claude-opus-5-5", 37.2), ("claude-sonnet-5-5", 18.6),
                   ("claude-fable-5-2", 74.2), ("claude-mythos-5-2", 74.2)):
    got = per_model.get(name, {}).get("cost_usd")
    check("%s priced at $%.2f (dated snapshot suffix stripped where present)" % (name, want),
          got is not None and abs(got - want) < 1e-6,
          "got %r; per_model keys %r" % (got, sorted(per_model)))
check("5.5 gen: priced_cost_total_usd==204.20",
      abs(d.get("priced_cost_total_usd", -1) - 204.2) < 1e-6, "got %r" % (d.get("priced_cost_total_usd"),))
check("5.5 gen: cache_read $==0.70 (per-model read rates 0.05x/0.025x, not a 0.1x default)",
      abs(d.get("field_dollars", {}).get("cache_read", -1) - 0.70) < 1e-9,
      "got %r" % (d.get("field_dollars", {}).get("cache_read"),))
PY

# ── 11. Haiku 5.5 bills two rate cards, split by prompt length ────────────
# $0.10 in / $0.50 out for a prompt of 100K tokens or fewer, $0.50 / $2.50
# above it; cache reads 0.1x, 5m writes 1.25x, 1h writes 2x of the card's own
# input rate. Prompt = input + cache_read + cache_write (output excluded).
#   low   prompt 80,000 (20k in, 50k read, 10k write 5m), 100k out:
#           .002 + .0005 + .00125 + .05          = 0.05375
#   high  prompt 200,000 (10k in, 140k read, 50k write 1h), 20k out, on the long
#         card (in .50, read .05, write 1h 1.00, out 2.50):
#           .005 + .007 + .05 + .05              = 0.112
#   edge  prompt exactly 100,000 (all input) is NOT above the threshold, so the
#         low card applies: 100000 x .10 / 1e6   = 0.01 (the long card: 0.05)
#   total 0.17575; by field: input .017, output .10, cache_read .0075,
#   cache_write_5m .00125, cache_write_1h .05
HAIKU_FILE="$TMPDIR_T/session-haiku.jsonl"
gen_jsonl "$HAIKU_FILE" '
h_low  claude-haiku-5-5  20000  100000 50000  10000 0
h_high claude-haiku-5-5  10000  20000  140000 0     50000
h_edge claude-haiku-5-5  100000 0      0      0     0
'
HAIKU_JSON="$TMPDIR_T/haiku.json"
"$TOOL" --root "$HAIKU_FILE" --json > "$HAIKU_JSON" 2>"$TMPDIR_T/haiku.stderr"
run_checks "$HAIKU_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print("%s %s%s" % (status, name, ("" if cond or not detail else " (%s)" % detail)))

fd = d.get("field_dollars", {})
check("haiku 5.5: every token priced", d.get("unpriced_tokens_total") == 0,
      "got %r" % (d.get("unpriced_tokens_total"),))
check("haiku 5.5: priced_cost_total_usd==0.17575",
      abs(d.get("priced_cost_total_usd", -1) - 0.17575) < 1e-9, "got %r" % (d.get("priced_cost_total_usd"),))
check("haiku 5.5: input $==0.017 (long card above 100K, low card at exactly 100K)",
      abs(fd.get("input", -1) - 0.017) < 1e-9, "got %r" % (fd.get("input"),))
check("haiku 5.5: output $==0.10", abs(fd.get("output", -1) - 0.10) < 1e-9, "got %r" % (fd.get("output"),))
check("haiku 5.5: cache_read $==0.0075 (0.1x of each card's own input rate)",
      abs(fd.get("cache_read", -1) - 0.0075) < 1e-9, "got %r" % (fd.get("cache_read"),))
check("haiku 5.5: cache_write_5m $==0.00125", abs(fd.get("cache_write_5m", -1) - 0.00125) < 1e-9,
      "got %r" % (fd.get("cache_write_5m"),))
check("haiku 5.5: cache_write_1h $==0.05 (2x the long card's input rate)",
      abs(fd.get("cache_write_1h", -1) - 0.05) < 1e-9, "got %r" % (fd.get("cache_write_1h"),))
PY

# ── 12. a NEWER unlisted version is an estimate; an OLDER one is unpriced ──
# A version newer than every listed version of its family is priced as the
# newest listed row and flagged ESTIMATE, so the next generation is never
# silently unpriced. An older version nothing lists must NOT borrow a newer
# model's price (an old model's list price is not inferable from it): it stays
# in unpriced_models, as does any id the table can't place (section 6).
NEXT_FILE="$TMPDIR_T/session-next.jsonl"
gen_jsonl "$NEXT_FILE" '
n_next  claude-opus-9-9    1000000 1000000 1000000 1000000 1000000
n_older claude-sonnet-1-0  1000000 1000000 1000000 1000000 1000000
'
NEXT_JSON="$TMPDIR_T/next.json"
"$TOOL" --root "$NEXT_FILE" --json > "$NEXT_JSON" 2>"$TMPDIR_T/next.stderr"
run_checks "$NEXT_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print("%s %s%s" % (status, name, ("" if cond or not detail else " (%s)" % detail)))

per_model = d.get("per_model", {})
est = d.get("estimated_models", {})
check("next gen: claude-opus-9-9 flagged as an estimate (5,000,000 tok)",
      est.get("claude-opus-9-9") == 5000000, "got %r" % (est,))
check("next gen: estimate names the row it was priced as (opus 5.5)",
      per_model.get("claude-opus-9-9", {}).get("estimated_as") == "opus 5.5",
      "got %r" % (per_model.get("claude-opus-9-9"),))
check("next gen: the estimate carries the newest opus card's $37.20, inside the total",
      abs(d.get("estimated_cost_usd", -1) - 37.2) < 1e-6 and abs(d.get("priced_cost_total_usd", -1) - 37.2) < 1e-6,
      "estimated %r, total %r" % (d.get("estimated_cost_usd"), d.get("priced_cost_total_usd")))
check("next gen: an estimated model is not listed as unpriced",
      "claude-opus-9-9" not in d.get("unpriced_models", {}), "got %r" % (d.get("unpriced_models"),))
check("older unlisted version stays unpriced (5,000,000 tok, never borrowed from a newer price)",
      d.get("unpriced_models", {}).get("claude-sonnet-1-0") == 5000000, "got %r" % (d.get("unpriced_models"),))
check("older unlisted version adds no dollars and is not an estimate",
      abs(per_model.get("claude-sonnet-1-0", {}).get("cost_usd", -1)) < 1e-9
      and "claude-sonnet-1-0" not in est,
      "got %r / %r" % (per_model.get("claude-sonnet-1-0"), est))
PY
NEXT_TEXT="$("$TOOL" --root "$NEXT_FILE" 2>&1)"
echo "$NEXT_TEXT" | grep -q "ESTIMATE" && ok "text report calls the next-generation dollars an ESTIMATE" \
  || bad "text report never says ESTIMATE for a model priced by the newest-listed-version rule"
echo "$NEXT_TEXT" | grep -qF "claude-opus-9-9 as opus 5.5" && ok "text report names the id and the row it was priced as" \
  || bad "text report does not say 'claude-opus-9-9 as opus 5.5'"

# ── 13. one rate source: the tier table, not a copy inside the tool ───────
# Same request priced twice, the second time against a copy of the table in
# which the opus 5.5 input rate is $40 instead of $4. If the tool held its own
# rate table the number would not move.
ONE_FILE="$TMPDIR_T/session-one.jsonl"
gen_jsonl "$ONE_FILE" 'one_opus claude-opus-5-5 1000000 0 0 0 0'
ALT_TABLE="$TMPDIR_T/alt-tier-table.json"
python3 - "$ROOT/bin/lib/tier-table.json" "$ALT_TABLE" <<'PY'
import json, sys
table = json.load(open(sys.argv[1]))
for row in table.get("model_prices", {}).get("rows", []):
    if row.get("family") == "opus" and row.get("version") == "5.5":
        row["input"] = 40.0
json.dump(table, open(sys.argv[2], "w"))
PY
ONE_JSON="$TMPDIR_T/one.json"
ALT_JSON="$TMPDIR_T/alt.json"
"$TOOL" --root "$ONE_FILE" --json > "$ONE_JSON" 2>/dev/null
HMD_COST_FORENSICS_TIER_TABLE="$ALT_TABLE" "$TOOL" --root "$ONE_FILE" --json > "$ALT_JSON" 2>/dev/null
run_checks "$ONE_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cost = d.get("priced_cost_total_usd")
print("%s shipped table: 1M opus 5.5 input tokens cost $4.00%s" % (
    "PASS" if cost is not None and abs(cost - 4.0) < 1e-9 else "FAIL",
    "" if cost is not None and abs(cost - 4.0) < 1e-9 else " (got %r)" % (cost,)))
PY
run_checks "$ALT_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cost = d.get("priced_cost_total_usd")
print("%s HMD_COST_FORENSICS_TIER_TABLE: the same tokens cost $40.00 when the table says so%s" % (
    "PASS" if cost is not None and abs(cost - 40.0) < 1e-9 else "FAIL",
    "" if cost is not None and abs(cost - 40.0) < 1e-9 else " (got %r)" % (cost,)))
PY

# ── 14. an unusable table fails loudly: it never silently prices nothing ──
BAD_TABLE="$TMPDIR_T/bad-tier-table.json"
python3 - "$ROOT/bin/lib/tier-table.json" "$BAD_TABLE" <<'PY'
import json, sys
table = json.load(open(sys.argv[1]))
for row in table.get("model_prices", {}).get("rows", []):
    if row.get("family") == "opus" and row.get("version") == "5.5":
        del row["output"]
json.dump(table, open(sys.argv[2], "w"))
PY
HMD_COST_FORENSICS_TIER_TABLE="$BAD_TABLE" "$TOOL" --root "$ONE_FILE" --json >"$TMPDIR_T/bad.out" 2>"$TMPDIR_T/bad.err"
BAD_RC=$?
[ "$BAD_RC" -eq 1 ] && ok "a row missing its output rate exits 1" || bad "a row missing its output rate exited $BAD_RC, want 1"
[ ! -s "$TMPDIR_T/bad.out" ] && ok "a malformed table puts nothing on stdout (no half-priced report)" \
  || bad "a malformed table still printed a report on stdout"
grep -q '"output"' "$TMPDIR_T/bad.err" && ok "stderr names the missing field" \
  || bad "stderr does not name the missing \"output\" field"
HMD_COST_FORENSICS_TIER_TABLE="$TMPDIR_T/no-such-table.json" "$TOOL" --root "$ONE_FILE" --json >"$TMPDIR_T/miss.out" 2>"$TMPDIR_T/miss.err"
MISS_RC=$?
[ "$MISS_RC" -eq 1 ] && ok "a missing table file exits 1" || bad "a missing table file exited $MISS_RC, want 1"
grep -q "pricing table" "$TMPDIR_T/miss.err" && ok "stderr says it is the pricing table that failed" \
  || bad "stderr does not mention the pricing table"

# ── 15. --levers: the 7-day verification of the token levers ──────────────
# docs/analysis/2026-11-22-token-utilization-next.md and 2026-11-24-market-
# token-techniques.md each end a lever with a "Falsify" check. --levers runs
# every one of them over a date window in one command, before vs after a date.
# The fixture below is a project tree built so that every number is hand-
# checkable; the stub text and the gate reason come from the hooks' OWN code, so
# the day a hook rewords its message this suite goes red instead of the
# recogniser going blind. Windows: before = everything < 2026-11-24, after =
# everything >= 2026-11-24 (UTC). Corpus floor 2026-11-10T00:00:00Z, ceiling
# 2026-11-27T00:00:00Z: the before window spans 14.0 days, the after window 3.0.
LEVERS_DIR="$TMPDIR_T/levers"
LEVERS_SECRET="LEVERS_SECRET_DO_NOT_LEAK_q42"
export LEVERS_EXPECT="$TMPDIR_T/levers-expect.json"
python3 - "$LEVERS_DIR" "$LEVERS_SECRET" "$ROOT" > "$LEVERS_EXPECT" <<'PY'
import datetime, importlib.machinery, importlib.util, json, os, sys

out_root, SECRET, repo = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.append(os.path.join(repo, "bin", "lib"))


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


dedup = load("hmd_read_dedup", os.path.join(repo, "bin", "lib", "hmd_read_dedup.py"))
gate = load("report_gate", os.path.join(repo, "bin", "heimdall-subagent-report-gate"))
SONNET = "claude-sonnet-5"
MARK = "⚡ MULTI-PART TASK DETECTED (~3 independent subtasks)."
APATH = "/home/%s/p/a.py" % SECRET
CPATH = "/home/%s/p/c.py" % SECRET


def reason(agent):
    return gate.decision(1801, 1500, "/h/.heimdall/subagent-reports/%s.md" % agent)["reason"]


def iso(day, sec):
    moment = datetime.datetime(2026, 11, day, tzinfo=datetime.timezone.utc) + datetime.timedelta(seconds=sec)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def use(inp=0, out=0, read=0, w5m=0, w1h=0):
    return {"input_tokens": inp, "output_tokens": out, "cache_read_input_tokens": read,
            "cache_creation": {"ephemeral_5m_input_tokens": w5m, "ephemeral_1h_input_tokens": w1h}}


def pad(text, n):
    assert len(text) < n, (len(text), n)
    return (text + " " * n)[:n]


def notif(n, status):
    head = "<task-notification>\n<task-id>n%d</task-id>\n<status>%s</status>\n<result>%s" % (n, status, SECRET)
    tail = "</result>\n</task-notification>"
    text = head + "x" * (n - len(head) - len(tail)) + tail
    assert len(text) == n
    return text


class Transcript:
    def __init__(self, rel, agent=None, agent_type=None):
        self.path = os.path.join(out_root, rel)
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.fh = open(self.path, "w")
        self.agent = agent
        if agent and agent_type:
            with open(self.path[:-len(".jsonl")] + ".meta.json", "w") as meta:
                json.dump({"agentType": agent_type, "description": SECRET}, meta)

    def put(self, rec):
        rec["isSidechain"] = self.agent is not None
        if self.agent:
            rec["agentId"] = self.agent
        self.fh.write(json.dumps(rec) + "\n")

    def request(self, ts, mid, usage, blocks=None, model=SONNET, effort=None):
        for block in blocks or [{"type": "text", "text": "ok"}]:
            rec = {"type": "assistant", "timestamp": ts,
                   "message": {"id": mid, "model": model, "usage": usage, "content": [block]}}
            if effort:
                rec["effort"] = rec["perTurnEffort"] = effort
            self.put(rec)

    def text(self, ts, content, origin=None, **extra):
        rec = {"type": "user", "timestamp": ts, "message": {"role": "user", "content": content}}
        if origin:
            rec["origin"] = {"kind": origin}
        rec.update(extra)
        self.put(rec)

    def result(self, ts, tool_id, text):
        self.put({"type": "user", "timestamp": ts, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "content": text}]}})

    def attach(self, ts, attachment):
        self.put({"type": "attachment", "timestamp": ts, "attachment": attachment})

    def tool(self, ts, mid, usage, name, tid, tool_input, result_text, effort=None):
        """A request that calls one tool, then that tool's result. The tool_use rides the SECOND line of
        the request (a real transcript writes one line per content block, all repeating the usage)."""
        self.request(ts, mid, usage, [{"type": "thinking", "thinking": "hm"},
                                      {"type": "tool_use", "id": tid, "name": name, "input": tool_input}], effort=effort)
        self.result(ts, tid, result_text)

    def inject(self, ts, event, content):
        self.attach(ts, {"type": "hook_additional_context", "hookEvent": event, "hookName": event, "content": [content]})


# ---- before: the main thread of proj-a (day 10) ----------------------------
m = Transcript("proj-a/sess-before.jsonl")
m.text(iso(10, 0), "kickoff " + SECRET)                                              # human prompt 1, the corpus floor
m.text(iso(10, 9 * 3600), "plain prompt")                                            # human 2
m.text(iso(10, 9 * 3600 + 5), "<system-reminder>x</system-reminder>", isMeta=True)   # meta: not a prompt
m.text(iso(10, 11 * 3600), [{"type": "text", "text": "block prompt"}])               # human 3, text-block content
m.text(iso(10, 13 * 3600), "origin prompt", origin="human")                          # human 4
m.text(iso(10, 15 * 3600), "last human")                                             # human 5
m.text(iso(10, 20 * 3600 + 100), "compact summary", isCompactSummary=True)           # not a prompt
for k, (n, status) in enumerate(((1000, "completed"), (2000, "completed"), (3000, "completed"),
                                 (4000, "completed"), (10000, "failed"))):
    m.text(iso(10, 17 * 3600 + k * 10), notif(n, status), origin="task-notification")  # 5 more prompts
for k in range(4):
    m.inject(iso(10, 9 * 3600 + 10 + k), "UserPromptSubmit", MARK + " " + SECRET)    # 4 parallel-gate injections
for k in range(2):
    m.inject(iso(10, 9 * 3600 + 20 + k), "UserPromptSubmit", "HMD OUTPUT COMPRESSION - level: ultra.")
m.inject(iso(10, 9 * 3600 + 30), "PreToolUse", MARK)                                 # wrong event: not counted
# (second of day 10, cache_read, cache_write_1h); every other usage field is 0, so each prompt is read + write.
# Idle gaps of 2 h: r2 rewrites a 100K prefix (below 150K), r4 a 200K one, r6 a 350K one. r8 follows a gap but
# the cache survived (writes 10K of 360K), r9 is a compaction after idle (writes 20K of 370K): neither is a rewrite.
for i, (sec, read, w1h) in enumerate([
        (10 * 3600, 90000, 10000), (12 * 3600, 0, 100000), (12 * 3600 + 60, 100000, 100000),
        (14 * 3600 + 60, 0, 200000), (14 * 3600 + 120, 200000, 150000), (16 * 3600 + 120, 0, 350000),
        (16 * 3600 + 180, 350000, 10000), (18 * 3600 + 180, 360000, 10000), (20 * 3600 + 180, 0, 20000),
        (20 * 3600 + 240, 20000, 10000)], 1):
    if i in (3, 4):   # the main thread Reads one file twice: a subagent metric must not see it
        m.tool(iso(10, sec), "mb%d" % i, use(read=read, w1h=w1h), "Read", "mt%d" % i, {"file_path": APATH}, pad("main read", 700))
    else:
        m.request(iso(10, sec), "mb%d" % i, use(read=read, w1h=w1h))
m.request(iso(10, 21 * 3600), "mb_syn", use(read=400000), model="<synthetic>")        # excluded: client-made placeholder

# ---- before: four subagents (day 11) ---------------------------------------
T = iso(11, 10)
b1 = Transcript("proj-a/sess-before/subagents/agent-b1.jsonl", "b1", "hmd:coder")
b1.text(iso(11, 0), "spawn prompt " + SECRET)
for rid, out, rd, w5m, name, tin, size in (
        ("b1r1", 1000, 0, 40000, "Read", {"file_path": APATH}, 1000),
        ("b1r2", 3000, 40000, 1000, "Read", {"file_path": APATH}, 1000),                          # identical re-read
        ("b1r3", 0, 41000, 0, "Read", {"file_path": APATH, "offset": 10, "limit": 5}, 200),       # other range
        ("b1r4", 0, 41000, 0, "Edit", {"file_path": APATH, "old_string": "a", "new_string": "b"}, 50),
        ("b1r5", 0, 41000, 0, "Read", {"file_path": APATH}, 1100),                                # after the edit
        ("b1r6", 0, 41000, 0, "Read", {"file_path": APATH}, 1100),                                # identical re-read
        ("b1r7", 0, 41000, 0, "Bash", {"command": "ls"}, 650),
        ("b1r8", 0, 41000, 0, "Read", {"file_path": "/home/%s/p/b.py" % SECRET}, 2000)):
    b1.tool(T, rid, use(out=out, read=rd, w5m=w5m), name, rid.replace("r", "t"), tin, pad("r", size), effort="high")
b2 = Transcript("proj-a/sess-before/subagents/agent-b2.jsonl", "b2", "hmd:coder")
b2.tool(T, "b2r1", use(out=2000, w5m=50000), "Read", "b2t1", {"file_path": APATH}, pad("r", 1000), effort="high")
b2.tool(T, "b2r2", use(read=50000, w5m=1000), "Read", "b2t2", {"file_path": APATH}, pad("r", 1000), effort="high")
b3 = Transcript("proj-a/sess-before/subagents/agent-b3.jsonl", "b3", "Explore")
b3.tool(T, "b3r1", use(out=600, w5m=20000), "Bash", "b3t1", {"command": "ls"}, pad("b", 900), effort="medium")
b3.request(T, "b3r2", use(read=480000, w5m=20000), effort="medium")          # 500K inside a subagent: not main-thread
b4 = Transcript("proj-a/sess-before/subagents/agent-b4.jsonl", "b4")           # no meta file, no effort recorded
b4.request(T, "b4r1", use(out=1000, w5m=30000))

# ---- after: the main thread (days 25-27) -----------------------------------
n = Transcript("proj-a/sess-after.jsonl")
n.text(iso(25, 0), "after kickoff")
for k in range(5):
    n.text(iso(25, 5 * 3600 + k), "human %d" % k)
n.text(iso(27, 0), "last prompt")                                              # the corpus ceiling; 7 human prompts
for k, size in enumerate((800, 1200, 1500)):
    n.text(iso(25, 4 * 3600 + k * 10), notif(size, "completed"), origin="task-notification")
n.inject(iso(25, 5 * 3600 + 10), "UserPromptSubmit", MARK)                      # 1 injection in 10 prompts
for k in range(2):
    n.inject(iso(25, 5 * 3600 + 20 + k), "UserPromptSubmit", "HMD OUTPUT COMPRESSION - level: ultra.")
n.attach(iso(25, 5 * 3600 + 40), {"type": "hook_success", "hookEvent": "SubagentStop", "hookName": "SubagentStop",
                                  "stdout": json.dumps({"decision": "block", "reason": reason("a1")})})   # a1 again
for k, ctx in enumerate((30000, 100000, 200000, 300000)):                        # 300,000 is NOT above 300K
    n.request(iso(25, 6 * 3600 + k * 60), "na%d" % (k + 1), use(read=ctx - 10000, w1h=10000))

# ---- after: two subagents, stubs and gate blocks ---------------------------
T = iso(25, 3600)
S1 = "     1→" + dedup.STUB % (APATH, 1, 40)         # cat -n style prefix: the recogniser must search, not anchor
S2 = dedup.STUB % (CPATH, 1, 90)
a1 = Transcript("proj-a/sess-after/subagents/agent-a1.jsonl", "a1", "hmd:coder")
a1.tool(T, "a1r1", use(out=500, w5m=30000), "Read", "a1t1", {"file_path": APATH}, pad("r", 1000), effort="medium")
a1.tool(T, "a1r2", use(out=1000, read=30000, w5m=1000), "Read", "a1t2", {"file_path": APATH}, S1, effort="medium")
a1.tool(T, "a1r3", use(read=31000), "Read", "a1t3", {"file_path": CPATH}, pad("r", 3000), effort="medium")
a1.tool(T, "a1r4", use(read=31000), "Bash", "a1t4", {"command": "grep stub"}, pad(dedup.STUB % ("/x/y.py", 1, 5), 300), effort="medium")
a1.tool(T, "a1r5", use(read=31000), "Bash", "a1t5", {"command": "cat"}, pad(reason("a9"), 500), effort="medium")   # quoted, not a block
a1.request(T, "a1r6", use(read=31000), [{"type": "text", "text": reason("a8")}], effort="medium")                  # assistant quote
a1.attach(T, {"type": "hook_blocking_error", "hookEvent": "SubagentStop", "hookName": "SubagentStop",
              "blockingError": json.dumps({"blockingError": reason("a1")})})                                        # block 1
a2 = Transcript("proj-a/sess-after/subagents/agent-a2.jsonl", "a2", "hmd:coder")
a2.tool(T, "a2r1", use(out=1500, w5m=34000), "Read", "a2t1", {"file_path": CPATH}, pad("r", 3000), effort="medium")
a2.tool(T, "a2r2", use(out=1000, read=34000, w5m=1000), "Read", "a2t2", {"file_path": CPATH}, S2, effort="medium")
long_body = "x" * 2000 + dedup.STUB % ("/x/y.py", 1, 5)
a2.tool(T, "a2r3", use(read=35000), "Read", "a2t3", {"file_path": "/home/%s/p/hook.py" % SECRET},
        long_body + "y" * (5000 - len(long_body)), effort="medium")                          # long Read quoting the stub
a2.text(T, "Stop hook feedback:\n" + reason("a2"), isMeta=True)                              # block 2
a2.attach(T, {"type": "edited_text_file", "filename": "x", "snippet": reason("a7")})         # a snippet, not a hook

# ---- decoy project and the window-boundary fixture -------------------------
Transcript("proj-b/sess-other.jsonl").request(iso(10, 5000), "ob1", use(read=600000))
edge = Transcript("../levers-edge/sess-edge.jsonl")
for sec_day, ts in ((23, 86399), (24, 0), (24, 1)):
    edge.request(iso(sec_day, ts), "e%d" % ts, use(read=400000))
for t in (m, b1, b2, b3, b4, n, a1, a2, edge):
    t.fh.close()
print(json.dumps({"stub_chars": len(S1) + len(S2)}))
PY
[ -s "$LEVERS_EXPECT" ] && ok "levers fixture generated (stub and gate text taken from the hooks' own code)" \
  || bad "levers fixture generator failed"

grep -q "MULTI-PART TASK DETECTED" "$ROOT/bin/parallel-gate" && ok "levers: bin/parallel-gate still emits the marker the tool counts" \
  || bad "levers: bin/parallel-gate no longer emits MULTI-PART TASK DETECTED"

LEVERS_ARGS=(--levers --root "$LEVERS_DIR" --project proj-a --baseline-until 2026-11-24)
"$TOOL" "${LEVERS_ARGS[@]}" --json > "$TMPDIR_T/levers.json" 2>"$TMPDIR_T/levers.stderr"
LEVERS_RC=$?
[ "$LEVERS_RC" -eq 0 ] && ok "--levers run exits 0" || bad "--levers run exit code was $LEVERS_RC, want 0"
run_checks "$TMPDIR_T/levers.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
exp = json.load(open(__import__("os").environ["LEVERS_EXPECT"]))
S = exp["stub_chars"]
rows = {r["id"]: r for r in d["rows"]}
B, A = "before", "after"
def check(name, cond, detail=""):
    print("%s %s%s" % ("PASS" if cond else "FAIL", name, ("" if cond or not detail else " (%s)" % detail)))
def v(rid, win):
    row = rows.get(rid)
    return None if row is None else row["values"].get(win, {}).get("value")
def detail(rid, win):
    row = rows.get(rid)
    return "" if row is None else row["values"].get(win, {}).get("detail", "")
def near(rid, win, want, tol=1e-6):
    got = v(rid, win)
    check("%s %s == %.4f" % (rid, win, want), got is not None and abs(got - want) <= tol, "got %r" % (got,))

check("windows: before ends and after starts at 2026-11-24T00:00:00Z (--since defaults to --baseline-until)",
      d["windows"][B]["until"] == "2026-11-24T00:00:00Z" and d["windows"][A]["since"] == "2026-11-24T00:00:00Z",
      "got %r" % (d["windows"],))
check("windows: before spans 14.0 days, after 3.0 (nominal bound, capped at the data's own horizon)",
      d["windows"][B]["span_days"] == 14.0 and d["windows"][A]["span_days"] == 3.0, "got %r" % (d["windows"],))
check("every row is labelled DERIVED and carries its query",
      all(r["label"] == "DERIVED" and len(r["query"]) > 20 for r in d["rows"]), "rows %r" % ([r["id"] for r in d["rows"]],))

# lever 1: main-thread context. 10 main requests (a <synthetic> one, subagent requests and proj-b are not main-thread of
# this project): r5-r8 are above 300K = 4 of 10; their $ 0.64+1.4+0.11+0.112 = 2.262 of 4.064.
near("main_requests_gt_300k_share", B, 40.0)
near("main_requests_gt_300k_share", A, 0.0)
near("main_spend_gt_300k_usd", B, 2.262)
near("main_spend_gt_300k_usd", A, 0.0)
near("main_spend_gt_300k_share", B, 100 * 2.262 / 4.064)
near("main_spend_gt_300k_share", A, 0.0)
# lever 2: cache-expiry rewrites. r4 (prior 200K) and r6 (prior 350K) are above 150K, only r6 above 300K; r2's prior is
# 100K, r8 kept its cache, r9 compacted. 14.0 days -> x30/14.
near("cache_expiry_rewrites_gt_150k_per_30d", B, 2 * 30 / 14)
near("cache_expiry_rewrites_gt_300k_per_30d", B, 1 * 30 / 14)
near("cache_expiry_rewrites_gt_150k_per_30d", A, 0.0)
check("rewrite row states the mean rewritten tokens (275,000) and the $ of the writes (2.2000)",
      "275,000" in detail("cache_expiry_rewrites_gt_150k_per_30d", B) and "2.2000" in detail("cache_expiry_rewrites_gt_150k_per_30d", B),
      "got %r" % (detail("cache_expiry_rewrites_gt_150k_per_30d", B),))
# lever 5: task-notification reports. before [1000,2000,3000,4000,10000]: mean 4000, p90 7600; after [800,1200,1500].
near("task_notification_chars_mean", B, 4000.0)
near("task_notification_chars_p90", B, 7600.0)
near("task_notification_chars_mean", A, 3500 / 3)
near("task_notification_chars_p90", A, 1440.0)
check("notification row says how many were completed (4 of 5)", "4 completed" in detail("task_notification_chars_mean", B),
      "got %r" % (detail("task_notification_chars_mean", B),))
# report gate: agents a1 (a hook_blocking_error, repeated once as a hook_success) and a2 (a user feedback) are blocked;
# a quoted tool result (a9), an assistant quote (a8) and an edited-file snippet (a7) are not blocks.
near("task_notifications_gate_blocked", B, 0)
near("task_notifications_gate_blocked", A, 2)
check("gate row relates the blocks to the notifications (of 3)", "of 3" in detail("task_notifications_gate_blocked", A),
      "got %r" % (detail("task_notifications_gate_blocked", A),))
# lever 6: identical re-reads by subagents. before: results 7100+2000+900 = 10000 chars, Read 8400, identical 1000+1100+1000
# = 3100. after: results 12800+S, Read 12000+S, identical S (the two stubs).
near("subagent_identical_reread_share", B, 31.0)
near("subagent_identical_reread_share_of_read_chars", B, 100 * 3100 / 8400)
near("subagent_identical_reread_share", A, 100 * S / (12800 + S))
near("subagent_identical_reread_share_of_read_chars", A, 100 * S / (12000 + S))
near("read_dedup_stub_hits", B, 0)
near("read_dedup_stub_hits", A, 2)
# lever 7: parallel-gate injections per 100 prompts: 4 of 10 before, 1 of 10 after.
near("parallel_gate_injections_per_100_prompts", B, 40.0)
near("parallel_gate_injections_per_100_prompts", A, 10.0)
# lever 4: subagent first-request context. before 40K, 50K (coders), 20K (Explore), 30K (no meta file); after 30K, 34K.
near("subagent_first_request_context_mean", B, 35000.0)
near("subagent_first_request_context_mean", A, 32000.0)
near("subagent_first_request_context_mean[hmd:coder]", B, 45000.0)
near("subagent_first_request_context_mean[hmd:coder]", A, 32000.0)
near("subagent_first_request_context_mean[Explore]", B, 20000.0)
check("an agent type absent from a window reads n/a there", v("subagent_first_request_context_mean[Explore]", A) is None)
near("subagent_first_request_context_mean[(unknown)]", B, 30000.0)
# lever 3: output tokens per subagent by recorded effort. b1 4000 (1000 + 3000, the duplicated request line counted once),
# b2 2000 -> high mean 3000; b3 600 medium; b4 1000 with no effort. after: a1 1500, a2 2500 -> medium 2000.
near("subagent_output_tokens_per_agent[high]", B, 3000.0)
near("subagent_output_tokens_per_agent[medium]", B, 600.0)
near("subagent_output_tokens_per_agent[(not recorded)]", B, 1000.0)
near("subagent_output_tokens_per_agent[medium]", A, 2000.0)
check("effort level absent from a window reads n/a there", v("subagent_output_tokens_per_agent[high]", A) is None)
PY

# no --project: proj-b's lone 600K request joins the before window (5 of 11 above 300K)
"$TOOL" --levers --root "$LEVERS_DIR" --baseline-until 2026-11-24 --json > "$TMPDIR_T/levers-all.json" 2>/dev/null
run_checks "$TMPDIR_T/levers-all.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
got = {r["id"]: r for r in d["rows"]}["main_requests_gt_300k_share"]["values"]["before"]["value"]
print("%s without --project every project directory is scanned (5 of 11 requests above 300K = 45.45%%)%s" % (
    "PASS" if got is not None and abs(got - 100 * 5 / 11) < 1e-6 else "FAIL", "" if got is not None and abs(got - 100 * 5 / 11) < 1e-6 else " (got %r)" % (got,)))
PY

# --cache-ttl is read: a 3 h TTL makes every 2 h gap a cache hit, so no expiry rewrite remains
"$TOOL" "${LEVERS_ARGS[@]}" --cache-ttl 10800 --json > "$TMPDIR_T/levers-ttl.json" 2>/dev/null
run_checks "$TMPDIR_T/levers-ttl.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
got = {r["id"]: r for r in d["rows"]}["cache_expiry_rewrites_gt_150k_per_30d"]["values"]["before"]["value"]
print("%s --cache-ttl 10800 leaves no expiry rewrite (a 2 h gap is inside that TTL)%s" % (
    "PASS" if got == 0.0 else "FAIL", "" if got == 0.0 else " (got %r)" % (got,)))
PY

# single window: without --baseline-until there is one column, named "window"
"$TOOL" --levers --root "$LEVERS_DIR" --project proj-a --since 2026-11-24 --json > "$TMPDIR_T/levers-one.json" 2>/dev/null
run_checks "$TMPDIR_T/levers-one.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rows = {r["id"]: r for r in d["rows"]}
ok = sorted(d["windows"]) == ["window"] and all(sorted(r["values"]) == ["window"] for r in d["rows"])
print("%s without --baseline-until there is a single column named window%s" % ("PASS" if ok else "FAIL", "" if ok else " (windows %r)" % (sorted(d["windows"]),)))
got = rows["read_dedup_stub_hits"]["values"]["window"]["value"]
print("%s --since alone covers the after data (2 stub hits)%s" % ("PASS" if got == 2 else "FAIL", "" if got == 2 else " (got %r)" % (got,)))
PY

# window edges: --since is inclusive and --until exclusive; a window under one day gives no per-30-day rate
"$TOOL" --levers --root "$TMPDIR_T/levers-edge" --since 2026-11-24 --until 2026-11-24T00:00:01Z --json > "$TMPDIR_T/levers-edge.json" 2>/dev/null
run_checks "$TMPDIR_T/levers-edge.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rows = {r["id"]: r for r in d["rows"]}
share = rows["main_requests_gt_300k_share"]["values"]["window"]
print("%s window [00:00:00, 00:00:01) holds exactly the request stamped 00:00:00 (1 of 1)%s" % (
    "PASS" if share["value"] == 100.0 and "1 of 1" in share["detail"] else "FAIL", "" if share["value"] == 100.0 else " (got %r)" % (share,)))
rate = rows["cache_expiry_rewrites_gt_150k_per_30d"]["values"]["window"]["value"]
print("%s a window shorter than a day prints no per-30-day rate (n/a, never an extrapolation)%s" % (
    "PASS" if rate is None else "FAIL", "" if rate is None else " (got %r)" % (rate,)))
PY

# empty window and empty root: honest "nothing to report", exit 0
"$TOOL" --levers --root "$LEVERS_DIR" --project proj-a --since 2030-01-01 --json > "$TMPDIR_T/levers-none.json" 2>/dev/null
LEVERS_NONE_RC=$?
run_checks "$TMPDIR_T/levers-none.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
got = {r["id"]: r for r in d["rows"]}["main_requests_gt_300k_share"]["values"]["window"]["value"]
print("%s a window with no requests reads n/a, never 0%%%s" % ("PASS" if got is None else "FAIL", "" if got is None else " (got %r)" % (got,)))
PY
[ "$LEVERS_NONE_RC" -eq 0 ] && ok "--levers on an empty window exits 0" || bad "--levers on an empty window exited $LEVERS_NONE_RC"
"$TOOL" --levers --root "$EMPTY_DIR" 2>&1 | grep -q "honest empty result" && ok "--levers on an empty root reports an honest empty result" \
  || bad "--levers on an empty root did not report an honest empty result"

# the text report: every row carries DERIVED and its query, both columns are named, nothing private is printed
LEVERS_TEXT="$("$TOOL" "${LEVERS_ARGS[@]}" 2>&1)"
[ "$(echo "$LEVERS_TEXT" | grep -c "DERIVED")" -ge 19 ] && ok "text report labels every one of the 19 rows DERIVED" \
  || bad "text report has fewer than 19 DERIVED labels"
[ "$(echo "$LEVERS_TEXT" | grep -c "query:")" -ge 19 ] && ok "text report prints a query: line for every row" \
  || bad "text report has fewer than 19 query lines"
echo "$LEVERS_TEXT" | grep -q "before" && echo "$LEVERS_TEXT" | grep -q "after" && ok "text report names the before and after columns" \
  || bad "text report does not name the before and after columns"
if echo "$LEVERS_TEXT" | grep -qF "$LEVERS_SECRET" || grep -qF "$LEVERS_SECRET" "$TMPDIR_T/levers.json" "$TMPDIR_T/levers.stderr"; then
  bad "PRIVACY VIOLATION: --levers printed text from a transcript (prompt, report, path, tool output or hook text)"
else
  ok "privacy: --levers prints aggregates only; the secret planted in prompts, reports, paths, results and hook text never appears"
fi
"$TOOL" --help 2>&1 | grep -q -e "--levers" && ok "--help documents --levers" || bad "--help does not document --levers"

# bad invocations exit 2
"$TOOL" --since 2026-11-24 >/dev/null 2>&1
RC=$?; [ "$RC" -eq 2 ] && ok "--since without --levers exits 2 (never silently ignored)" || bad "--since without --levers exited $RC, want 2"
"$TOOL" --levers --since not-a-date >/dev/null 2>&1
RC=$?; [ "$RC" -eq 2 ] && ok "--levers --since not-a-date exits 2" || bad "--since not-a-date exited $RC, want 2"
"$TOOL" --levers --baseline-until >/dev/null 2>&1
RC=$?; [ "$RC" -eq 2 ] && ok "--baseline-until without a value exits 2" || bad "--baseline-until without a value exited $RC, want 2"
"$TOOL" --levers --cache-ttl 0 >/dev/null 2>&1
RC=$?; [ "$RC" -eq 2 ] && ok "--cache-ttl 0 exits 2" || bad "--cache-ttl 0 exited $RC, want 2"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
