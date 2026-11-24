#!/usr/bin/env bash
# effort-ab.test.sh - proof for evals/effort-ab (the pre-registered high-vs-medium effort A/B).
# budget: ~20s solo (10 fixtures x 2 accept runs, 6 fake-claude runs, 15 sandbox-exec probes + 10 sandboxed accept runs on macOS); no API call, no network.
# Journeys: (1) every fixture is falsifiable: the seed FAILS hidden acceptance, seed+reference PASSES;
# (2) the schedule is interleaved + counterbalanced and the child command/env are scrubbed and least-privilege:
#     no blanket tool rule, Bash limited to the fixture language's toolchain, every child wrapped in sandbox-exec,
#     and the runner refuses to start unconfined (no sandbox-exec, or one that confines nothing) without --no-sandbox;
# (3) the runner end to end against a FAKE claude (the only external boundary): rows, resume, infra retry,
#     and a child that writes outside its workdir is refused (it succeeds under --no-sandbox, so the probe can fail);
# (4) the analysis implements the pre-registered GO/NO-GO rule exactly;
# (5) the sandbox profile itself, probed directly with sandbox-exec (macOS): writes only inside the allowed roots.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AB="$ROOT/evals/effort-ab"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
DARWIN=0; [ "$(uname)" = Darwin ] && DARWIN=1
SBX=""; [ "$DARWIN" -eq 1 ] || SBX="--no-sandbox"   # no sandbox-exec off macOS: the fake runs there opt out explicitly

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
python3 "$AB/run.py" --dry-run --claude /usr/bin/true --sandbox-exec /usr/bin/true > "$T/dry.json"
check "40 jobs = 10 tasks x 2 arms x 2 reps" "[ \$(jq '.jobs|length' $T/dry.json) -eq 40 ]"
check "every adjacent pair is one (task,rep) with both arms" \
  "jq -e '[.jobs as \$j | range(0;40;2) | (\$j[.].task==\$j[.+1].task and \$j[.].rep==\$j[.+1].rep and \$j[.].arm!=\$j[.+1].arm)] | all' $T/dry.json >/dev/null"
check "arm order counterbalanced per task across the two reps" \
  "jq -e '[.jobs | group_by(.task)[] | ([.[]|select(.rep==1)][0].arm) != ([.[]|select(.rep==2)][0].arm)] | all' $T/dry.json >/dev/null"
check "no run of >2 equal arms in a row (interleaved, never all-A then all-B)" \
  "jq -e '[.jobs[].arm] | . as \$a | [range(0;length-2) | (\$a[.]==\$a[.+1] and \$a[.]==\$a[.+2])] | any | not' $T/dry.json >/dev/null"
check "command pins sonnet, safe-mode, restricted, no persistence, effort" \
  "jq -e '.claude | (index(\"--model\") as \$i | .[\$i+1]==\"sonnet\") and index(\"--safe-mode\") and index(\"--restricted\") and index(\"--no-session-persistence\") and index(\"--effort\")' $T/dry.json >/dev/null"
check "child env carries no token, proxy or session names" \
  "! jq -r '.child_env_names[]' $T/dry.json | grep -Ei 'token|anthropic|claude|session|key|secret|proxy'"
check "concurrency never above 3" "python3 $AB/run.py --dry-run --claude /usr/bin/true --concurrency 9 | jq -e '.concurrency==3' >/dev/null"

echo "[2b] least privilege: built-in tools, Bash allowlist, sandbox wrapper"
cat > "$T/f-tools.jq" <<'JQ'
.claude as $c | ($c | index("--tools")) as $t | ($c | index("--allowedTools")) as $a
| $c[$t + 1] == "Bash,Read,Edit,Write,Glob,Grep" and $a != null and ($c[$a + 1:] | length > 0)
JQ
cat > "$T/f-nobroad.jq" <<'JQ'
.claude as $c | ($c | index("--allowedTools")) as $a
| $c[$a + 1:] | all(.[]; test("^Bash\\([a-z0-9_./-]+( [a-z0-9_./-]+)* \\*\\)$"))
JQ
cat > "$T/f-bylang.jq" <<'JQ'
.allowed_tools_by_task
| .["01-paginate-off-by-one"] == ["Bash(python3 *)"]
and .["07-event-emitter-reentrancy"] == ["Bash(node *)"]
and .["04-bash-log-summary"] == ["Bash(bash summarize.sh *)", "Bash(bash tests/run_tests.sh *)"]
and ([.[][]] | unique) == ["Bash(bash summarize.sh *)", "Bash(bash tests/run_tests.sh *)", "Bash(node *)", "Bash(python3 *)"]
JQ
cat > "$T/f-sbx.jq" <<'JQ'
.sandbox as $s | $s.argv_prefix as $p
| $s.exec == "/usr/bin/true" and $p[0] == "/usr/bin/true" and $p[-2] == "-p" and $p[-1] == $s.profile
and ([$p[] | select(startswith("WORK=") or startswith("SCRATCH=") or startswith("CLAUDE_TMP=") or startswith("HOME="))] | length == 4)
and ($s.profile | index("(deny file-write*)") < index("(allow file-write*"))
JQ
cat > "$T/f-roots.jq" <<'JQ'
.sandbox.profile | split("\n") as $l
| ([$l | to_entries[] | select(.value | startswith("(allow file-write*")) | .key][0]) as $a
| ([$l | to_entries[] | select(.value | startswith("(deny file-read*")) | .key][0]) as $d
| [$l[$a:$d][] | select(contains("subpath"))] | length == 3 and all(.[]; test("param \"(WORK|SCRATCH|CLAUDE_TMP)\""))
JQ
check "tools are the six built-ins and --allowedTools is present" "jq -e -f $T/f-tools.jq $T/dry.json >/dev/null"
check "--allowedTools holds only Bash(<command words> *) rules: no bare Bash/Read/Edit/Write/Glob/Grep" "jq -e -f $T/f-nobroad.jq $T/dry.json >/dev/null"
check "Bash allowlist per fixture language: python3 / node / the seed's own .sh files, nothing else" "jq -e -f $T/f-bylang.jq $T/dry.json >/dev/null"
check "dry run shows the sandbox wrapper: exec, four -D params, -p profile, deny-all-writes before the allow" "jq -e -f $T/f-sbx.jq $T/dry.json >/dev/null"
check "write allowlist is exactly workdir, private scratch and Claude's per-cwd scratch (no HOME, no literal path)" "jq -e -f $T/f-roots.jq $T/dry.json >/dev/null"
check "credential stores are unreadable (.ssh .aws .gnupg in the deny-read rule)" \
  "jq -e '.sandbox.profile | contains(\"/.ssh\") and contains(\"/.aws\") and contains(\"/.gnupg\") and contains(\"(deny file-read*\")' $T/dry.json >/dev/null"
check "--no-sandbox is explicit: dry run then shows sandbox null" \
  "python3 $AB/run.py --dry-run --claude /usr/bin/true --no-sandbox | jq -e '.sandbox==null' >/dev/null"
mkdir -p "$T/fc"
python3 "$AB/run.py" --claude /usr/bin/true --sandbox-exec "$T/no-such-sandbox-exec" --results "$T/fc/runs.jsonl" \
  --only 01-paginate-off-by-one --reps 1 --tmp-root "$T" > "$T/fc1.out" 2>&1; rc_missing=$?
check "no sandbox-exec: fails closed (exit 2), names --no-sandbox, starts no run, leaves no workdir" \
  "[ $rc_missing -eq 2 ] && grep -q -e '--no-sandbox' $T/fc1.out && [ ! -e $T/fc/runs.jsonl ] && [ -z \"\$(ls -d $T/effort-ab.* 2>/dev/null)\" ]"
python3 "$AB/run.py" --claude /usr/bin/true --sandbox-exec /usr/bin/true --results "$T/fc/runs.jsonl" \
  --only 01-paginate-off-by-one --reps 1 --tmp-root "$T" > "$T/fc2.out" 2>&1; rc_noconf=$?
check "a sandbox-exec that confines nothing fails closed too (the self-test refuses it)" \
  "[ $rc_noconf -eq 2 ] && grep -qi 'did not confine' $T/fc2.out && [ ! -e $T/fc/runs.jsonl ] && [ -z \"\$(ls -d $T/effort-ab.* 2>/dev/null)\" ]"

echo "[3] runner end to end against a fake claude"
cat > "$T/fake-claude" <<'PYEOF'
#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
args = sys.argv[1:]
effort = args[args.index("--effort") + 1]
sys.stdin.read()
cwd = pathlib.Path.cwd()
task = cwd.name.split(".")[1]
here = pathlib.Path(__file__).parent
if (here / "fail-first").exists() and not pathlib.Path((here / "fail-first").read_text().strip()).exists():  # fail until the first row lands
    print(json.dumps({"type": "result", "subtype": "error_during_execution", "is_error": True, "api_error_status": 529}))
    sys.exit(1)
(cwd / "tmpdir.log").write_text(f"TMPDIR={os.environ.get('TMPDIR', '')}\nTMPPREFIX={os.environ.get('TMPPREFIX', '')}\n")
if (here / "escape-mode").exists():  # a misbehaving child: try to write outside the workdir
    try:
        pathlib.Path((here / "escape-mode").read_text().strip()).write_text("x")
        verdict = "allowed"
    except OSError:
        verdict = "denied"
    (cwd / "escape.log").write_text(f"escape: {verdict}\n")
ref = pathlib.Path((here / "tasks_dir").read_text().strip()) / task / "reference"
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
python3 "$AB/run.py" --claude "$T/fake-claude" --results "$T/res/runs.jsonl" --only 01-paginate-off-by-one --reps 1 --tmp-root "$T" $SBX > "$T/run1.out" 2>&1
check "fake run exits 0 and writes one row per arm" "[ \$(wc -l < $T/res/runs.jsonl) -eq 2 ]"
check "both arms pass acceptance (reference applied)" "jq -s -e 'all(.[]; .pass==true and .accept_rc==0)' $T/res/runs.jsonl >/dev/null"
check "output tokens recorded per arm (high 1000, medium 800)" \
  "jq -s -e '([.[]|select(.arm==\"high\")][0].output_tokens==1000) and ([.[]|select(.arm==\"medium\")][0].output_tokens==800)' $T/res/runs.jsonl >/dev/null"
check "thinking estimate sums per-message maxima (400+30)" "jq -s -e 'all(.[]; .thinking_est_tokens==430 and .tool_calls.Edit==1 and .cache_write_tokens==7)' $T/res/runs.jsonl >/dev/null"
check "patch captured and workdirs removed" "[ -s $T/res/patches/01-paginate-off-by-one.high.r1.a1.patch ] && [ -z \"\$(ls -d $T/effort-ab.* 2>/dev/null)\" ]"
check "rows record whether the child was sandboxed (true on macOS, false with --no-sandbox)" \
  "jq -s -e --argjson want \$([ $DARWIN -eq 1 ] && echo true || echo false) 'all(.[]; .sandboxed == \$want)' $T/res/runs.jsonl >/dev/null"
check "child TMPDIR is a private per-run scratch, not the shared temp dir" \
  "grep -q 'TMPDIR=.*effort-ab\\.01-paginate-off-by-one\\.tmp\\.' $T/res/patches/01-paginate-off-by-one.high.r1.a1.patch"
check "child TMPPREFIX (zsh here-document temp files) points into the same private scratch" \
  "grep -q 'TMPPREFIX=.*effort-ab\\.01-paginate-off-by-one\\.tmp\\..*/zsh' $T/res/patches/01-paginate-off-by-one.high.r1.a1.patch"
python3 "$AB/run.py" --claude "$T/fake-claude" --results "$T/res/runs.jsonl" --only 01-paginate-off-by-one --reps 1 --tmp-root "$T" $SBX > "$T/run2.out" 2>&1
check "resume skips counted runs (still 2 rows)" "[ \$(wc -l < $T/res/runs.jsonl) -eq 2 ] && grep -q '0 runs to do' $T/run2.out"
echo "$T/res2/runs.jsonl" > "$T/fail-first"   # the fake fails while this results file does not exist yet (a sandboxed child cannot keep state of its own)
python3 "$AB/run.py" --claude "$T/fake-claude" --results "$T/res2/runs.jsonl" --only 01-paginate-off-by-one --reps 1 --arms high --tmp-root "$T" $SBX > "$T/run3.out" 2>&1
check "infra failure retried: uncounted failure row, then counted pass" \
  "jq -s -e 'length==2 and .[0].infra_failure==true and .[0].counted==false and .[1].pass==true and .[1].counted==true and .[1].attempt==2' $T/res2/runs.jsonl >/dev/null"
rm -f "$T/fail-first"
echo "$T/escape-canary" > "$T/escape-mode"
python3 "$AB/run.py" --claude "$T/fake-claude" --results "$T/res3/runs.jsonl" --only 01-paginate-off-by-one --reps 1 --arms high --tmp-root "$T" --no-sandbox > "$T/run4.out" 2>&1
check "control: unsandboxed, the same misbehaving child DOES write outside its workdir (so the probe can fail)" \
  "[ -e $T/escape-canary ] && grep -q 'escape: allowed' $T/res3/patches/01-paginate-off-by-one.high.r1.a1.patch"
rm -f "$T/escape-canary"
if [ "$DARWIN" -eq 1 ]; then
  python3 "$AB/run.py" --claude "$T/fake-claude" --results "$T/res4/runs.jsonl" --only 01-paginate-off-by-one --reps 1 --arms high --tmp-root "$T" > "$T/run5.out" 2>&1
  check "sandboxed: the same child's write outside its workdir is refused, the run still passes" \
    "[ ! -e $T/escape-canary ] && grep -q 'escape: denied' $T/res4/patches/01-paginate-off-by-one.high.r1.a1.patch && jq -s -e 'all(.[]; .pass==true and .sandboxed==true)' $T/res4/runs.jsonl >/dev/null"
fi
rm -f "$T/escape-mode"

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

echo "[5] sandbox profile probed directly with sandbox-exec (macOS only; the production argv, no claude call)"
if [ "$DARWIN" -eq 1 ]; then
  mkdir -p "$T/pr/work" "$T/pr/scratch" "$T/pr/other" "$T/pr/home/.ssh"
  echo secret > "$T/pr/home/.ssh/id_probe"; echo note > "$T/pr/home/notes.txt"
  python3 - "$AB" "$T/pr" > "$T/probe.out" 2>&1 <<'PYEOF'
import importlib.util, os, shutil, subprocess, sys
ab, pr = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("effort_run", os.path.join(ab, "run.py"))
run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run)
w, s, o, h = (os.path.realpath(os.path.join(pr, d)) for d in ("work", "scratch", "other", "home"))
prefix = run.sandbox_argv(run.SANDBOX_EXEC, w, s, h)
ctmp = str(run.claude_tmp_dir(w))
canary = f"/private/tmp/effort-ab-probe.{os.getpid()}"


def sh(script):
    return subprocess.run(prefix + ["/bin/sh", "-c", script], capture_output=True, text=True, timeout=30).returncode


def case(name, passed):
    print(("ok " if passed else "BAD ") + name)


open(f"{o}/keep", "w").write("keep")
case("write inside the workdir", sh(f"echo x > '{w}/a'") == 0 and os.path.exists(f"{w}/a"))
case("write inside the private scratch", sh(f"echo x > '{s}/a'") == 0 and os.path.exists(f"{s}/a"))
case("write inside Claude's per-cwd scratch (mkdir -p + file)", sh(f"mkdir -p '{ctmp}/t' && echo x > '{ctmp}/t/a'") == 0 and os.path.exists(f"{ctmp}/t/a"))
case("write to a sibling dir refused", sh(f"echo x > '{o}/a'") != 0 and not os.path.exists(f"{o}/a"))
case("write to HOME refused", sh(f"echo x > '{h}/a'") != 0 and not os.path.exists(f"{h}/a"))
case("write to the shared /private/tmp refused", sh(f"echo x > '{canary}'") != 0 and not os.path.exists(canary))
sh(f"rm -f '{o}/keep'")
case("delete outside the workdir refused", os.path.exists(f"{o}/keep"))
case("symlink out of the workdir does not open a write path", sh(f"ln -s '{o}' '{w}/lnk'; echo x > '{w}/lnk/z'") != 0 and not os.path.exists(f"{o}/z"))
case("read of a credential dir refused (.ssh)", sh(f"cat '{h}/.ssh/id_probe'") != 0)
case("read of other HOME files still allowed", sh(f"cat '{h}/notes.txt'") == 0)
case("/dev/null, /dev/stdout and /dev/stderr stay usable", sh("echo x > /dev/null && echo x > /dev/stdout && echo x > /dev/stderr") == 0)
case("python3 writes the workdir, not outside it",
     sh(f"python3 -c \"open('{w}/p','w').write('x')\"") == 0 and sh(f"python3 -c \"open('{o}/p','w').write('x')\"") != 0 and not os.path.exists(f"{o}/p"))
cwdfile = "/private/tmp/claude-effab0-cwd"
case("Claude Code's /tmp/claude-<hex>-cwd file stays writable (else every Bash result reads Exit code 1)", sh(f"echo x > '{cwdfile}'") == 0 and os.path.exists(cwdfile))
if os.path.exists(cwdfile):
    os.remove(cwdfile)
zsh = subprocess.run(prefix + ["/bin/zsh", "-c", "cat > /dev/null <<EOF\nhello\nEOF"], env=run.child_env(s), capture_output=True, timeout=30)
case("zsh here-documents work (TMPPREFIX points into the private scratch)", zsh.returncode == 0)
case("diff reading stdin works (it hardcodes /tmp/diff.<rand>)", sh("echo a | diff - /dev/null") == 1)
shutil.rmtree(ctmp, ignore_errors=True)
PYEOF
  check "direct probe ran all 15 cases (no crash)" "[ \$(grep -cE '^(ok|BAD) ' $T/probe.out) -eq 15 ] || { cat $T/probe.out; false; }"
  while IFS= read -r line; do
    case "$line" in "ok "*) ok "probe: ${line#ok }" ;; "BAD "*) bad "probe: ${line#BAD }" ;; esac
  done < "$T/probe.out"
  # every fixture's hidden acceptance must still run under the production sandbox (the runner confines accept.sh too)
  for d in "$AB"/tasks/*/; do
    id="$(basename "$d")"; b="$T/sb-$id"; s="$T/sbs-$id"; mkdir -p "$b" "$s"
    cp -R "$d/seed/." "$b/"; cp -R "$d/reference/." "$b/"
    PYTHONDONTWRITEBYTECODE=1 python3 - "$AB" "$d" "$b" "$s" <<'PYEOF'
import importlib.util, os, pathlib, sys
ab, task, work, scratch = (os.path.realpath(p) for p in sys.argv[1:5])
spec = importlib.util.spec_from_file_location("effort_run", os.path.join(ab, "run.py"))
run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run)
confine = lambda argv: run.sandbox_argv(run.SANDBOX_EXEC, work, scratch, os.environ["HOME"]) + argv
rc, tail = run.run_accept(pathlib.Path(task), pathlib.Path(work), pathlib.Path(scratch), confine)
sys.exit(rc)
PYEOF
    [ $? -eq 0 ] && ok "$id reference passes acceptance under the sandbox" || bad "$id reference fails acceptance under the sandbox"
  done
else
  ok "sandbox-exec probes skipped (not macOS); the fail-closed and dry-run checks above ran"
fi

echo "effort-ab.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
