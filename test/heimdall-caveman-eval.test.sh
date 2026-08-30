#!/usr/bin/env bash
# test/heimdall-caveman-eval.test.sh -- red-proofs for bin/heimdall-caveman-eval.
#
# Covers, each with real evidence (never a hand-waved assertion):
#  1. --help text
#  2. missing snapshot -> honest "no measurement yet", exit 0, never a fake zero
#  3. known snapshot -> exact hand-computed median/mean/min/max/stdev
#  4. missing control arm -> a reported error, not a crash or a silent zero
#  5. a zero-token terse entry is guarded (no ZeroDivisionError)
#  6. lite/full/ultra rules text is genuinely distinct (pairwise) from each
#     other AND from the literal terse-control string -- using the REAL
#     bin/heimdall-caveman binary, not a mock
#  7. refresh without --confirm-spend makes ZERO real `claude` calls
#  8. refresh --dry-run makes ZERO real `claude` calls
#  9. refresh --confirm-spend (fake `claude` on PATH) makes exactly
#     n_prompts x 5 calls, in strict per-arm-block order, with a genuinely
#     distinct system prompt per arm, and writes a snapshot `report` can
#     then read back
#  10. a mid-sweep failure must never clobber a pre-existing good snapshot
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOOL="$ROOT/bin/heimdall-caveman-eval"
CAVEMAN="$ROOT/bin/heimdall-caveman"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

get() {
  python3 -c "import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2], ''))" "$1" "$2"
}

lvl_field() {
  python3 -c "
import json, sys
obj = json.loads(sys.argv[1])
for row in obj['levels']:
    if row['level'] == sys.argv[2]:
        print(row[sys.argv[3]])
        break
" "$1" "$2" "$3"
}

feq() {
  # $1=actual $2=expected -- float compare with a small epsilon
  python3 -c "import sys; sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) < 1e-9 else 1)" "$1" "$2"
}

# ---------------------------------------------------------------------------
# 1. --help
# ---------------------------------------------------------------------------
out="$("$TOOL" --help 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "refresh --confirm-spend"; then ok; else bad "help text (rc=$rc): $out"; fi

# ---------------------------------------------------------------------------
# 2. missing snapshot -> honest "no measurement yet", exit 0, never a fake zero
# ---------------------------------------------------------------------------
MISSING="$TMPDIR_T/does-not-exist.json"
out="$("$TOOL" report --snapshot "$MISSING" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "no measurement yet"; then ok; else bad "missing snapshot human (rc=$rc): $out"; fi

out_json="$("$TOOL" report --snapshot "$MISSING" --json 2>&1)"; rc=$?
err="$(get "$out_json" error)"
if [ "$rc" -eq 0 ] && echo "$err" | grep -q "no measurement yet"; then ok; else bad "missing snapshot --json (rc=$rc): $out_json"; fi

# Red-proof: an absent snapshot must never be indistinguishable from a real
# computed zero -- the error shape has no "levels"/"median" fields at all.
if echo "$out_json" | grep -q '"median"'; then bad "missing snapshot must not carry any median field: $out_json"; else ok; fi

# ---------------------------------------------------------------------------
# 3. known snapshot -> exact hand-computed stats
#    baseline=[100,200] terse=[50,100] lite=[40,90] full=[30,70] ultra=[25,40]
#    lite   savings=[.2,.1]  median=.15 mean=.15 min=.1 max=.2  stdev~=.07071068
#    full   savings=[.4,.3]  median=.35 mean=.35 min=.3 max=.4  stdev~=.07071068
#    ultra  savings=[.5,.6]  median=.55 mean=.55 min=.5 max=.6  stdev~=.07071068
#    terse_vs_baseline_pct = 1 - 150/300 = 0.5
# ---------------------------------------------------------------------------
GOOD="$TMPDIR_T/good-snapshot.json"
cat > "$GOOD" <<'JSONEOF'
{
  "metadata": {"generated_at": "2026-01-01T00:00:00+00:00", "model": "test", "n_prompts": 2},
  "prompts": ["p1", "p2"],
  "arms": {
    "__baseline__": [{"output_tokens": 100}, {"output_tokens": 200}],
    "__terse__":    [{"output_tokens": 50},  {"output_tokens": 100}],
    "lite":         [{"output_tokens": 40},  {"output_tokens": 90}],
    "full":         [{"output_tokens": 30},  {"output_tokens": 70}],
    "ultra":        [{"output_tokens": 25},  {"output_tokens": 40}]
  }
}
JSONEOF

out_json="$("$TOOL" report --snapshot "$GOOD" --json 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "known snapshot exit code: rc=$rc: $out_json"

btot="$(get "$out_json" baseline_tokens_total)"
[ "$btot" = "300" ] && ok || bad "baseline_tokens_total expected 300 got $btot"
ttot="$(get "$out_json" terse_tokens_total)"
[ "$ttot" = "150" ] && ok || bad "terse_tokens_total expected 150 got $ttot"
tvb="$(get "$out_json" terse_vs_baseline_pct)"
feq "$tvb" 0.5 && ok || bad "terse_vs_baseline_pct expected 0.5 got $tvb"

med_lite="$(lvl_field "$out_json" lite median)"
feq "$med_lite" 0.15 && ok || bad "lite median expected 0.15 got $med_lite"
mean_lite="$(lvl_field "$out_json" lite mean)"
feq "$mean_lite" 0.15 && ok || bad "lite mean expected 0.15 got $mean_lite"
min_lite="$(lvl_field "$out_json" lite min)"
feq "$min_lite" 0.1 && ok || bad "lite min expected 0.1 got $min_lite"
max_lite="$(lvl_field "$out_json" lite max)"
feq "$max_lite" 0.2 && ok || bad "lite max expected 0.2 got $max_lite"
sd_lite="$(lvl_field "$out_json" lite stdev)"
feq "$sd_lite" 0.07071067811865475 && ok || bad "lite stdev expected ~0.0707107 got $sd_lite"

med_full="$(lvl_field "$out_json" full median)"
feq "$med_full" 0.35 && ok || bad "full median expected 0.35 got $med_full"
sd_full="$(lvl_field "$out_json" full stdev)"
feq "$sd_full" 0.07071067811865475 && ok || bad "full stdev expected ~0.0707107 got $sd_full"

med_ultra="$(lvl_field "$out_json" ultra median)"
feq "$med_ultra" 0.55 && ok || bad "ultra median expected 0.55 got $med_ultra"
sd_ultra="$(lvl_field "$out_json" ultra stdev)"
feq "$sd_ultra" 0.07071067811865475 && ok || bad "ultra stdev expected ~0.0707107 got $sd_ultra"

# human report sorts descending by median: ultra(55%) > full(35%) > lite(15%)
human="$("$TOOL" report --snapshot "$GOOD" 2>&1)"
order_ok="$(python3 -c "
import sys
s = sys.stdin.read()
i_u, i_f, i_l = s.find('ultra'), s.find('full'), s.find('lite')
print('yes' if -1 < i_u < i_f < i_l else 'no')
" <<< "$human")"
[ "$order_ok" = "yes" ] && ok || bad "human report should sort ultra > full > lite by median: $human"

# ---------------------------------------------------------------------------
# 4. missing control arm -> error, not a crash, not a silent zero
# ---------------------------------------------------------------------------
NOCONTROL="$TMPDIR_T/no-control.json"
cat > "$NOCONTROL" <<'JSONEOF'
{"arms": {"lite": [{"output_tokens": 10}]}}
JSONEOF
out_json="$("$TOOL" report --snapshot "$NOCONTROL" --json 2>&1)"; rc=$?
err="$(get "$out_json" error)"
if [ "$rc" -eq 1 ] && echo "$err" | grep -qi "control arm"; then ok; else bad "missing control arm (rc=$rc): $out_json"; fi

# ---------------------------------------------------------------------------
# 5. zero-token terse entry -> guarded, no ZeroDivisionError crash
# ---------------------------------------------------------------------------
ZERODIV="$TMPDIR_T/zerodiv.json"
cat > "$ZERODIV" <<'JSONEOF'
{"arms": {
  "__baseline__": [{"output_tokens": 10}],
  "__terse__":    [{"output_tokens": 0}],
  "lite":         [{"output_tokens": 5}]
}}
JSONEOF
out_json="$("$TOOL" report --snapshot "$ZERODIV" --json 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok; else bad "zero-token terse entry should not crash (rc=$rc): $out_json"; fi
sav0="$(lvl_field "$out_json" lite median)"
feq "$sav0" 0.0 && ok || bad "zero-terse-token entry should report 0.0 savings for that prompt, got $sav0"

# ---------------------------------------------------------------------------
# 6. genuine arm distinctness: real rules text for lite/full/ultra actually
#    differ from each other AND from the literal terse-control string.
#    Hermetic HEIMDALL_HOME so no real user state leaks in or is touched.
# ---------------------------------------------------------------------------
FAKE_HOME="$TMPDIR_T/home"
mkdir -p "$FAKE_HOME"
r_lite="$(HEIMDALL_HOME="$FAKE_HOME" "$CAVEMAN" rules lite 2>/dev/null)"
r_full="$(HEIMDALL_HOME="$FAKE_HOME" "$CAVEMAN" rules full 2>/dev/null)"
r_ultra="$(HEIMDALL_HOME="$FAKE_HOME" "$CAVEMAN" rules ultra 2>/dev/null)"

if [ -n "$r_lite" ] && [ -n "$r_full" ] && [ -n "$r_ultra" ]; then ok; else bad "rules text must be non-empty for all 3 levels"; fi
if [ "$r_lite" != "$r_full" ] && [ "$r_full" != "$r_ultra" ] && [ "$r_lite" != "$r_ultra" ]; then ok; else bad "lite/full/ultra rules text must be pairwise distinct"; fi
if [ "$r_lite" != "Answer concisely." ] && [ "$r_full" != "Answer concisely." ] && [ "$r_ultra" != "Answer concisely." ]; then ok; else bad "level rules text must differ from the literal terse-control string"; fi

# ---------------------------------------------------------------------------
# 7. refresh guard: no --confirm-spend, no --dry-run -> refuses, ZERO real
#    `claude` calls, exits non-zero. `claude` on PATH is a call-logging fake
#    that would make this test fail loudly if it were ever actually invoked.
# ---------------------------------------------------------------------------
FAKEBIN="$TMPDIR_T/fakebin"
mkdir -p "$FAKEBIN"
CALLLOG="$TMPDIR_T/calls.log"
: > "$CALLLOG"
cat > "$FAKEBIN/claude" <<FAKEEOF
#!/usr/bin/env bash
# Log argv as ONE JSON array per line -- a plain "echo \"\$@\"" breaks call
# counting the moment an argument (a real multi-line rules block) contains
# its own newlines, since each embedded newline would look like a separate
# call to a naive "wc -l". json.dumps guarantees exactly one physical line
# per invocation, and preserves multi-word arguments (e.g. "Answer
# concisely.") as a single array element instead of splitting on spaces.
python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" "\$@" >> "$CALLLOG"
if [ "\$1" = "--version" ]; then echo "fake-claude 0.0.0"; exit 0; fi
sysprompt=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "--system-prompt" ]; then sysprompt="\$a"; fi
  prev="\$a"
done
n=\${#sysprompt}
python3 -c "import json,sys; print(json.dumps({'result':'ok','usage':{'output_tokens': 10 + int(sys.argv[1])},'total_cost_usd':0.0001,'session_id':'fake'}))" "\$n"
FAKEEOF
chmod +x "$FAKEBIN/claude"

out="$(PATH="$FAKEBIN:$PATH" "$TOOL" refresh 2>&1)"; rc=$?
ncalls="$(wc -l < "$CALLLOG" | tr -d ' ')"
if [ "$rc" -ne 0 ] && [ "$ncalls" = "0" ]; then ok; else bad "refresh without --confirm-spend must refuse and make 0 calls (rc=$rc, calls=$ncalls): $out"; fi

# ---------------------------------------------------------------------------
# 8. refresh --dry-run: zero calls, exit 0, prints the estimate
# ---------------------------------------------------------------------------
: > "$CALLLOG"
out="$(PATH="$FAKEBIN:$PATH" "$TOOL" refresh --dry-run 2>&1)"; rc=$?
ncalls="$(wc -l < "$CALLLOG" | tr -d ' ')"
if [ "$rc" -eq 0 ] && [ "$ncalls" = "0" ] && echo "$out" | grep -q "50 real"; then ok; else bad "refresh --dry-run must make 0 calls and print the estimate (rc=$rc, calls=$ncalls): $out"; fi

# ---------------------------------------------------------------------------
# 9. refresh --confirm-spend (fully faked claude): correct call count, order,
#    and per-arm system-prompt distinctness end to end; writes a valid
#    snapshot that `report` can then read back successfully.
# ---------------------------------------------------------------------------
: > "$CALLLOG"
SNAP_OUT="$TMPDIR_T/generated-snapshot.json"
FAKE_HOME2="$TMPDIR_T/home2"
mkdir -p "$FAKE_HOME2"
out="$(PATH="$FAKEBIN:$PATH" HEIMDALL_HOME="$FAKE_HOME2" "$TOOL" refresh --confirm-spend --snapshot "$SNAP_OUT" 2>&1)"; rc=$?
ncalls="$(wc -l < "$CALLLOG" | tr -d ' ')"
if [ "$rc" -eq 0 ]; then ok; else bad "refresh --confirm-spend should succeed with a working fake claude (rc=$rc): $out"; fi
# 1 claude_version() probe + 10 real prompts (evals/caveman/prompts.txt) x 5
# arms = 51 calls, exactly.
if [ "$ncalls" = "51" ]; then ok; else bad "expected exactly 51 claude invocations (1 version probe + 50 arm calls), got $ncalls"; fi
if [ -f "$SNAP_OUT" ]; then ok; else bad "refresh --confirm-spend must write the snapshot file"; fi

# Call ORDER: strict per-arm blocks of 10 (__baseline__, __terse__, lite,
# full, ultra) -- each block internally consistent on its own system prompt,
# baseline's block has none, and all 5 system-prompt values are pairwise
# distinct (proves the level arms are not accidentally sharing one prompt).
# The one-off claude_version() probe (a bare ["--version"] call, made once
# before the arm loop starts) is filtered out first -- it is not one of the
# 5 arms and would otherwise skew the block boundaries by one.
order_check="$(python3 -c "
import json
lines = open('$CALLLOG').read().splitlines()
parsed = [json.loads(l) for l in lines]
calls = [argv for argv in parsed if argv != ['--version']]
if len(calls) != 50:
    print('bad-length-%d' % len(calls))
else:
    def sysprompt(argv):
        return argv[argv.index('--system-prompt') + 1] if '--system-prompt' in argv else None
    blocks = [calls[i*10:(i+1)*10] for i in range(5)]
    flat = []
    bad = False
    for b in blocks:
        sp = set(sysprompt(argv) for argv in b)
        if len(sp) != 1:
            bad = True
            break
        flat.append(next(iter(sp)))
    if not bad and flat[0] is not None:
        bad = True
    if not bad and len(set(flat)) != 5:
        bad = True
    print('bad' if bad else 'ok')
")"
[ "$order_check" = "ok" ] && ok || bad "refresh call order/content check failed: $order_check"

# report reads the freshly generated snapshot back successfully
out_json="$("$TOOL" report --snapshot "$SNAP_OUT" --json 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && echo "$out_json" | grep -q '"level": "lite"'; then ok; else bad "generated snapshot must round-trip through report cleanly (rc=$rc): $out_json"; fi

# ---------------------------------------------------------------------------
# 10. a mid-sweep failure must NOT clobber a pre-existing good snapshot
# ---------------------------------------------------------------------------
PRESERVE="$TMPDIR_T/preserve.json"
cp "$GOOD" "$PRESERVE"
before_hash="$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$PRESERVE")"

FAILBIN="$TMPDIR_T/failbin"
mkdir -p "$FAILBIN"
cat > "$FAILBIN/claude" <<'FAILEOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "fake-claude 0.0.0"; exit 0; fi
echo "simulated failure" >&2
exit 1
FAILEOF
chmod +x "$FAILBIN/claude"

out="$(PATH="$FAILBIN:$PATH" "$TOOL" refresh --confirm-spend --snapshot "$PRESERVE" 2>&1)"; rc=$?
after_hash="$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$PRESERVE")"
if [ "$rc" -ne 0 ]; then ok; else bad "a failing refresh must not exit 0"; fi
if [ "$before_hash" = "$after_hash" ]; then ok; else bad "a failing refresh must not touch the pre-existing snapshot file"; fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
