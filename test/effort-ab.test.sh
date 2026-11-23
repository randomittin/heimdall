#!/usr/bin/env bash
# effort-ab.test.sh - proof for evals/effort-ab (the pre-registered high-vs-medium effort A/B).
# budget: ~10s solo (10 fixtures x 2 accept runs, 2 fake-claude runs); no API call, no network.
# Journeys: (1) every fixture is falsifiable: the seed FAILS hidden acceptance, seed+reference PASSES;
# (2) the schedule is interleaved + counterbalanced and the child command/env are scrubbed;
# (3) the runner end to end against a FAKE claude (the only external boundary): rows, resume, infra retry;
# (4) the analysis implements the pre-registered GO/NO-GO rule exactly.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AB="$ROOT/evals/effort-ab"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "[1] fixtures: seed fails, seed+reference passes"
n=0
for d in "$AB"/tasks/*/; do
  id="$(basename "$d")"; n=$((n + 1))
  jq -e '.id and .title and (.difficulty|IN("easy","medium","hard")) and .lang and (.prompt|length>40)' "$d/task.json" >/dev/null 2>&1 \
    && [ "$(jq -r .id "$d/task.json")" = "$id" ] && [ -d "$d/seed" ] && [ -f "$d/accept.sh" ] && [ -d "$d/reference" ] \
    && ok "$id layout" || bad "$id layout"
  a="$T/a-$id"; b="$T/b-$id"; mkdir -p "$a" "$b"
  cp -R "$d/seed/." "$a/"; cp -R "$d/seed/." "$b/"; cp -R "$d/reference/." "$b/"
  (cd "$a" && ACCEPT_DIR="$d" PYTHONDONTWRITEBYTECODE=1 timeout 30 bash "$d/accept.sh" >/dev/null 2>&1); rc_seed=$?
  (cd "$b" && ACCEPT_DIR="$d" PYTHONDONTWRITEBYTECODE=1 timeout 30 bash "$d/accept.sh" >/dev/null 2>&1); rc_ref=$?
  [ "$rc_seed" -ne 0 ] && ok "$id seed fails acceptance (rc=$rc_seed)" || bad "$id seed passed acceptance"
  [ "$rc_ref" -eq 0 ] && ok "$id reference passes acceptance" || bad "$id reference rc=$rc_ref"
done
check "ten fixtures present" "[ $n -eq 10 ]"
check "mix of difficulties (>=3 easy, >=3 medium-or-hard)" \
  "[ \$(jq -r .difficulty $AB/tasks/*/task.json | grep -c '^easy$') -ge 3 ] && [ \$(jq -r .difficulty $AB/tasks/*/task.json | grep -vc '^easy$') -ge 3 ]"

echo "[2] schedule + command + env (dry run)"
python3 "$AB/run.py" --dry-run --claude /usr/bin/true > "$T/dry.json"
check "40 jobs = 10 tasks x 2 arms x 2 reps" "[ \$(jq '.jobs|length' $T/dry.json) -eq 40 ]"
check "every adjacent pair is one (task,rep) with both arms" \
  "jq -e '[.jobs as \$j | range(0;40;2) | (\$j[.].task==\$j[.+1].task and \$j[.].rep==\$j[.+1].rep and \$j[.].arm!=\$j[.+1].arm)] | all' $T/dry.json >/dev/null"
check "arm order counterbalanced per task across the two reps" \
  "jq -e '[.jobs | group_by(.task)[] | ([.[]|select(.rep==1)][0].arm) != ([.[]|select(.rep==2)][0].arm)] | all' $T/dry.json >/dev/null"
check "no run of >2 equal arms in a row (interleaved, never all-A then all-B)" \
  "jq -e '[.jobs[].arm] | . as \$a | [range(0;length-2) | (\$a[.]==\$a[.+1] and \$a[.]==\$a[.+2])] | any | not' $T/dry.json >/dev/null"
check "command pins sonnet, safe-mode, no persistence, scoped tools" \
  "jq -e '.claude | (index(\"--model\") as \$i | .[\$i+1]==\"sonnet\") and index(\"--safe-mode\") and index(\"--no-session-persistence\") and index(\"--effort\")' $T/dry.json >/dev/null"
check "child env carries no token, proxy or session names" \
  "! jq -r '.child_env_names[]' $T/dry.json | grep -Ei 'token|anthropic|claude|session|key|secret|proxy'"
check "concurrency never above 3" "python3 $AB/run.py --dry-run --claude /usr/bin/true --concurrency 9 | jq -e '.concurrency==3' >/dev/null"

echo "[3] runner end to end against a fake claude"
cat > "$T/fake-claude" <<'PYEOF'
#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
args = sys.argv[1:]
effort = args[args.index("--effort") + 1]
sys.stdin.read()
cwd = pathlib.Path.cwd()
task = cwd.name.split(".")[1]
if (pathlib.Path(__file__).parent / "fail-first").exists() and not (pathlib.Path(__file__).parent / "failed").exists():
    (pathlib.Path(__file__).parent / "failed").write_text("x")
    print(json.dumps({"type": "result", "subtype": "error_during_execution", "is_error": True, "api_error_status": 529}))
    sys.exit(1)
ref = pathlib.Path((pathlib.Path(__file__).parent / "tasks_dir").read_text().strip()) / task / "reference"
shutil.copytree(ref, cwd, dirs_exist_ok=True)
out = {"high": 1000, "medium": 800}[effort]
for ev in (
    {"type": "system", "subtype": "init", "model": "claude-sonnet-5-5", "claude_code_version": "fake"},
    {"type": "system", "subtype": "thinking_tokens", "estimated_tokens": 50},
    {"type": "system", "subtype": "thinking_tokens", "estimated_tokens": 400},
    {"type": "system", "subtype": "thinking_tokens", "estimated_tokens": 30},
    {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Edit"}]}},
    {"type": "rate_limit_event", "rate_limit_info": {"unifiedWindows": {"five_hour": {"utilization": 0.1}}}},
    {"type": "result", "subtype": "success", "is_error": False, "num_turns": 3, "duration_ms": 10, "duration_api_ms": 5,
     "total_cost_usd": 0.01, "result": "done", "usage": {"output_tokens": out, "input_tokens": 3},
     "modelUsage": {"claude-sonnet-5-5": {"outputTokens": out, "inputTokens": 3, "cacheReadInputTokens": 100,
                                          "cacheCreationInputTokens": 7}}},
):
    print(json.dumps(ev))
PYEOF
chmod +x "$T/fake-claude"; echo "$AB/tasks" > "$T/tasks_dir"
python3 "$AB/run.py" --claude "$T/fake-claude" --results "$T/res/runs.jsonl" --only 01-paginate-off-by-one --reps 1 --tmp-root "$T" > "$T/run1.out" 2>&1
check "fake run exits 0 and writes one row per arm" "[ \$(wc -l < $T/res/runs.jsonl) -eq 2 ]"
check "both arms pass acceptance (reference applied)" "jq -s -e 'all(.[]; .pass==true and .accept_rc==0)' $T/res/runs.jsonl >/dev/null"
check "output tokens recorded per arm (high 1000, medium 800)" \
  "jq -s -e '([.[]|select(.arm==\"high\")][0].output_tokens==1000) and ([.[]|select(.arm==\"medium\")][0].output_tokens==800)' $T/res/runs.jsonl >/dev/null"
check "thinking estimate sums per-message maxima (400+30)" "jq -s -e 'all(.[]; .thinking_est_tokens==430 and .tool_calls.Edit==1 and .cache_write_tokens==7)' $T/res/runs.jsonl >/dev/null"
check "patch captured and workdirs removed" "[ -s $T/res/patches/01-paginate-off-by-one.high.r1.a1.patch ] && [ -z \"\$(ls -d $T/effort-ab.* 2>/dev/null)\" ]"
python3 "$AB/run.py" --claude "$T/fake-claude" --results "$T/res/runs.jsonl" --only 01-paginate-off-by-one --reps 1 --tmp-root "$T" > "$T/run2.out" 2>&1
check "resume skips counted runs (still 2 rows)" "[ \$(wc -l < $T/res/runs.jsonl) -eq 2 ] && grep -q '0 runs to do' $T/run2.out"
touch "$T/fail-first"
python3 "$AB/run.py" --claude "$T/fake-claude" --results "$T/res2/runs.jsonl" --only 01-paginate-off-by-one --reps 1 --arms high --tmp-root "$T" > "$T/run3.out" 2>&1
check "infra failure retried: uncounted failure row, then counted pass" \
  "jq -s -e 'length==2 and .[0].infra_failure==true and .[0].counted==false and .[1].pass==true and .[1].counted==true and .[1].attempt==2' $T/res2/runs.jsonl >/dev/null"

echo "[4] analysis implements the pre-registered rule"
mkrows() { # args: high_out medium_out medium_fail_task_count_both_reps(0|1) medium_extra_fail(0|1)
  python3 - "$@" <<'PYEOF'
import json, sys
high_out, med_out, regress, extra = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
for ti in range(1, 5):
    for arm in ("high", "medium"):
        for rep in (1, 2):
            ok = True
            if arm == "medium" and ti == 1 and regress:
                ok = False
            if arm == "medium" and ti == 2 and rep == 1 and extra:
                ok = False
            print(json.dumps({"kind": "run", "task": f"t{ti}", "difficulty": "easy", "arm": arm, "rep": rep, "attempt": 1,
                              "counted": True, "pass": ok, "output_tokens": high_out if arm == "high" else med_out,
                              "input_tokens": 1, "cache_read_tokens": 1, "cache_write_tokens": 1, "num_turns": 5,
                              "wall_s": 10, "cost_usd": 0.1, "thinking_est_tokens": 1, "infra_failure": False,
                              "timed_out": False, "hook_events": 0, "models": ["m"]}))
PYEOF
}
verdict() { python3 "$AB/analyze.py" --results "$1" --expected 16 --json | jq -r .decision.verdict; }
mkrows 1000 800 0 0 > "$T/go.jsonl";        check "20% fewer tokens, equal passes -> GO" "[ \"\$(verdict $T/go.jsonl)\" = GO ]"
mkrows 1000 900 0 0 > "$T/small.jsonl";     check "10% fewer tokens -> NO-GO" "[ \"\$(verdict $T/small.jsonl)\" = NO-GO ]"
mkrows 1000 800 1 0 > "$T/reg.jsonl";       check "task passing both high reps failing both medium -> NO-GO" "[ \"\$(verdict $T/reg.jsonl)\" = NO-GO ]"
mkrows 1000 800 0 1 > "$T/lower.jsonl";     check "one fewer medium pass (no task fully regressed) -> NO-GO" "[ \"\$(verdict $T/lower.jsonl)\" = NO-GO ]"
mkrows 1000 850 0 0 > "$T/edge.jsonl";      check "exactly 15% fewer tokens -> GO (boundary inclusive)" "[ \"\$(verdict $T/edge.jsonl)\" = GO ]"
head -n 10 "$T/go.jsonl" > "$T/part.jsonl";  check "fewer counted runs than expected -> INCOMPLETE" "[ \"\$(verdict $T/part.jsonl)\" = INCOMPLETE ]"
python3 - "$T/go.jsonl" "$T/retry.jsonl" <<'PYEOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
bad = dict(rows[0], attempt=1, counted=False, infra_failure=True, **{"pass": False})
good = dict(rows[0], attempt=2)
open(sys.argv[2], "w").write("\n".join(json.dumps(r) for r in [bad, good] + rows[1:]) + "\n")
PYEOF
check "uncounted infra attempt is excluded from the verdict, counted in attempts" \
  "python3 $AB/analyze.py --results $T/retry.jsonl --expected 16 --json | jq -e '.decision.verdict==\"GO\" and .supplementary.infra_retries==1 and .counted_runs==16' >/dev/null"

echo "effort-ab.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
