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

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
