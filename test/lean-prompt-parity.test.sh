#!/usr/bin/env bash
# lean-prompt-parity.test.sh -- proves evals/lean/prompt-parity.sh (lean-core plan T5.1): REPLAYED traces (no live model run), whole-trace
# differential of `heimdall` vs `heimdall-lean`. Committed traces/prompts are copied to a fixture root; the committed receipt is never touched.
#   golden -> green + receipt in install.sh's shape; then one defect each -> red: extra spawn, dropped gates, different file, reordered events,
#   edited lean prompt (stale trace), missing trace, empty task set.
set -u
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

fresh() {
  rm -rf "$tmp/r"; mkdir -p "$tmp/r/agents" "$tmp/r/evals"
  cp "$repo/agents/heimdall.md" "$repo/agents/heimdall-lean.md" "$tmp/r/agents/"
  cp -R "$repo/evals/lean" "$tmp/r/evals/lean"
  rm -f "$tmp/r/evals/lean/prompt-parity.receipt.json"
}
run() { HMD_PARITY_ROOT="$tmp/r" bash "$repo/evals/lean/prompt-parity.sh" >"$tmp/out" 2>&1; echo $?; }
verdict() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["verdict"])' "$tmp/r/evals/lean/prompt-parity.receipt.json"; }
expect_red() {
  rc="$(run)"; v="$(verdict)"
  if [ "$rc" = 1 ] && [ "$v" = red ] && grep -q -- "$2" "$tmp/out"; then ok "$1"; else no "$1 (rc=$rc verdict=$v)"; fi
}
edit() { python3 -I -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));exec(sys.argv[2]);json.dump(d,open(p,"w"),indent=2)' "$@"; }

fresh
rc="$(run)"
want="$(shasum -a 256 "$repo/agents/heimdall-lean.md" | cut -d' ' -f1)"
got="$(python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["verdict"],d["lean_prompt_sha256"],d["replayed"],d["live"])' "$tmp/r/evals/lean/prompt-parity.receipt.json")"
if [ "$rc" = 0 ] && [ "$got" = "green $want True False" ]; then ok "golden: green receipt with the lean prompt sha, replayed not live"; else no "golden ($rc: $got)"; fi
if grep -q 'REPLAY' "$tmp/out"; then ok "output says replay"; else no "output says replay"; fi
n="$(ls "$repo"/evals/lean/traces/lean | wc -l | tr -d ' ')"
t="$(python3 -I -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["tasks"]))' "$repo/evals/lean/tasks.json")"
if [ "$n" = "$t" ] && [ "$t" -ge 5 ]; then ok "one lean trace per task ($t)"; else no "trace/task count $n/$t"; fi

T="$tmp/r/evals/lean/traces/lean/t01-bugfix.json"
fresh; edit "$T" 'd["events"].insert(1,{"kind":"spawn","name":"hmd:design"})'; expect_red "extra spawn -> red" "t01-bugfix: traces differ"
fresh; edit "$T" 'd["events"]=[e for e in d["events"] if e["kind"]!="gate"]'; expect_red "dropped gates -> red" "t01-bugfix: traces differ"
fresh; edit "$T" 'd["events"][1]["name"]="src/other.py"'; expect_red "different file touched -> red" "t01-bugfix: traces differ"
fresh; edit "$T" 'd["events"][0],d["events"][-1]=d["events"][-1],d["events"][0]'; expect_red "reordered whole trace -> red" "t01-bugfix: traces differ"
fresh; echo "edit" >> "$tmp/r/agents/heimdall-lean.md"; expect_red "edited lean prompt (stale traces) -> red" "stale"
fresh; rm "$tmp/r/evals/lean/traces/full/t03-refactor.json"; expect_red "missing trace -> red" "t03-refactor: trace missing"
fresh; edit "$tmp/r/evals/lean/tasks.json" 'd["tasks"]=[]'; expect_red "empty task set -> red" "no valid task list"
fresh; rc="$(run)"
if [ "$rc" = 0 ] && [ "$(verdict)" = green ]; then ok "restored -> green again"; else no "restored"; fi

printf '%s\n' '------'
printf 'lean-prompt-parity: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
