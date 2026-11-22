#!/usr/bin/env bash
# lean-prompt-parity.test.sh -- proves evals/lean/prompt-parity.sh (lean-core plan T5.1), CHECK mode only (--record is live and never run here).
# Inputs are the fixture traces in test/fixtures/lean-prompt-parity/ stamped with the current prompt shas, copied to a throwaway root; the
# committed receipt is never touched.
#   fixture traces        -> "unverified" (exit 2), never green: self-authored traces are not evidence
#   live-shaped trace set -> green + receipt in install.sh's shape
#   no traces at all      -> unverified
#   mutants (live-shaped) -> red: extra spawn, dropped gates, different file, reordered events, edited lean prompt (stale), half-missing set,
#                            empty task set, a live trace without model / recorded_at -> unverified
set -u
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
R="$tmp/r/evals/lean"

# fresh [live]: fixture traces stamped with the prompts' shas; "live" also marks them source live with model + recorded_at.
fresh() {
  rm -rf "$tmp/r"; mkdir -p "$tmp/r/agents" "$R"
  cp "$repo/agents/heimdall.md" "$repo/agents/heimdall-lean.md" "$tmp/r/agents/"
  cp "$repo/evals/lean/tasks.json" "$R/"
  python3 -I - "$repo/test/fixtures/lean-prompt-parity" "$R/traces" "$tmp/r/agents" "${1:-fixture}" <<'PY'
import hashlib, json, os, sys
src, dst, agents, kind = sys.argv[1:5]
for prof, f in (("full", "heimdall.md"), ("lean", "heimdall-lean.md")):
    sha = hashlib.sha256(open(os.path.join(agents, f), "rb").read()).hexdigest()
    os.makedirs(os.path.join(dst, prof))
    for name in os.listdir(os.path.join(src, prof)):
        d = json.load(open(os.path.join(src, prof, name)))
        d["prompt_sha256"] = sha
        if kind == "live":
            d.update(source="live", model="claude-test-model", recorded_at="2026-11-22T00:00:00Z")
        json.dump(d, open(os.path.join(dst, prof, name), "w"), indent=2)
PY
}
run() { HMD_PARITY_ROOT="$tmp/r" bash "$repo/evals/lean/prompt-parity.sh" >"$tmp/out" 2>&1; echo $?; }
verdict() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["verdict"])' "$R/prompt-parity.receipt.json"; }
expect() { # name, rc, verdict, substring
  rc="$(run)"; v="$(verdict)"
  if [ "$rc" = "$2" ] && [ "$v" = "$3" ] && grep -q -- "$4" "$tmp/out"; then ok "$1"; else no "$1 (rc=$rc verdict=$v)"; fi
}
edit() { python3 -I -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));exec(sys.argv[2]);json.dump(d,open(p,"w"),indent=2)' "$@"; }

n="$(ls "$repo"/test/fixtures/lean-prompt-parity/lean | wc -l | tr -d ' ')"
t="$(python3 -I -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["tasks"]))' "$repo/evals/lean/tasks.json")"
if [ "$n" = "$t" ] && [ "$t" -ge 5 ]; then ok "one fixture trace per task ($t)"; else no "fixture/task count $n/$t"; fi
if [ ! -d "$repo/evals/lean/traces" ] || [ -z "$(ls -A "$repo/evals/lean/traces" 2>/dev/null)" ]; then ok "no fixture traces under evals/lean/traces"; else no "evals/lean/traces holds files"; fi

fresh; expect "fixture traces -> unverified, not green" 2 unverified "not a live trace"
fresh live
rc="$(run)"
want="$(shasum -a 256 "$repo/agents/heimdall-lean.md" | cut -d' ' -f1)"
got="$(python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["verdict"],d["lean_prompt_sha256"])' "$R/prompt-parity.receipt.json")"
if [ "$rc" = 0 ] && [ "$got" = "green $want" ]; then ok "live-shaped set -> green receipt with the lean prompt sha"; else no "live golden ($rc: $got)"; fi
fresh live; rm -rf "$R/traces"; expect "no traces -> unverified" 2 unverified "no traces recorded"

T="$R/traces/lean/t01-bugfix.json"
fresh live; edit "$T" 'd["events"].insert(1,{"kind":"spawn","name":"hmd:design"})'; expect "extra spawn -> red" 1 red "t01-bugfix: traces differ"
fresh live; edit "$T" 'd["events"]=[e for e in d["events"] if e["kind"]!="gate"]'; expect "dropped gates -> red" 1 red "t01-bugfix: traces differ"
fresh live; edit "$T" 'd["events"][1]["name"]="src/other.py"'; expect "different file touched -> red" 1 red "t01-bugfix: traces differ"
fresh live; edit "$T" 'd["events"][0],d["events"][-1]=d["events"][-1],d["events"][0]'; expect "reordered whole trace -> red" 1 red "t01-bugfix: traces differ"
fresh live; echo "edit" >> "$tmp/r/agents/heimdall-lean.md"; expect "edited lean prompt (stale traces) -> red" 1 red "stale"
fresh live; rm "$R/traces/full/t03-refactor.json"; expect "half-missing set -> red" 1 red "t03-refactor: trace missing"
fresh live; edit "$R/tasks.json" 'd["tasks"]=[]'; expect "empty task set -> red" 1 red "no valid task list"
fresh live; edit "$T" 'del d["model"]'; expect "live trace without model -> unverified" 2 unverified "not a live trace"
fresh live; edit "$T" 'del d["recorded_at"]'; expect "live trace without recorded_at -> unverified" 2 unverified "not a live trace"
fresh live; rc="$(run)"
if [ "$rc" = 0 ] && [ "$(verdict)" = green ]; then ok "restored -> green again"; else no "restored"; fi
if bash "$repo/evals/lean/prompt-parity.sh" --bogus >/dev/null 2>&1; then no "unknown flag rejected"; else ok "unknown flag rejected"; fi

printf '%s\n' '------'
printf 'lean-prompt-parity: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
