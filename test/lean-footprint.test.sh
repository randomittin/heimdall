#!/usr/bin/env bash
# lean-footprint.test.sh -- proves bin/heimdall-footprint (lean-core plan T0.1, docs/superpowers/plans/2026-11-12-3x-lean-core.md): the meter that makes
# "how heavy is an hmd install, and what does a session pay before the first prompt" one reproducible command, and its --check against the
# ceilings in release/lean-budget.json (today's numbers; a later wave lowers them).
#
#   1. DISK      tracked bytes and files per top-level directory, counting only what is on disk: a tracked file that is gone (a sparse checkout,
#                a delete) is `absent`, never a crash; a symlink counts by lstat (a dangling one too); an untracked file never counts.
#   2. CONTEXT   the main-session prompt (settings.json `agent`), the frontmatter of every agent / command / skill, and what the caveman hooks
#                inject (SessionStart rules; the per-prompt reminder, counted as its additionalContext, not its JSON wrapper).
#   3. HOOKS     registered hooks per event and per tool: a hook with matcher A|B counts for A and for B, a `*` or matcher-less hook for every tool.
#   4. HERMETIC  nothing of the caller leaks in (HEIMDALL_HOME, GIT_DIR), only the caveman hooks are ever run, the output is deterministic, and
#                a number it cannot trust (no git, no hooks.json, a matcher it cannot read, a hook that fails) is exit 2 with nothing on stdout.
#   5. --check   a measured number above its ceiling is exit 1 and is named; at the ceiling it passes; a malformed budget, or one naming a
#                metric the meter does not report, is exit 2 (a budget that checks nothing must never read as a pass).
#   6. THE REAL TREE   the meter agrees with an independent jq count over this repo's hooks.json, and the shipped budget is well formed and wired
#                to metrics the meter reports. It does NOT freeze the ceilings: a hook or a skill added later is the budget's job to flag
#                (`bin/heimdall-footprint --check`), not a reason for this suite to go red.
#
# Every fixture number is derived independently of the meter (printf | wc -c, constants of the construction), never read back from it.
# HMD_FOOTPRINT_BIN points the suite at another copy of the meter (a mutated copy, to watch an assertion go red). bash 3.2 compatible.
#
# Usage:  bash test/lean-footprint.test.sh
# shellcheck disable=SC2016  # the jq programs are single-quoted on purpose: their $vars are jq variables bound with --argjson, not shell variables
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CLI="${HMD_FOOTPRINT_BIN:-$REPO/bin/heimdall-footprint}"
SHIPPED_BUDGET="$REPO/release/lean-budget.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# nothing of the caller's environment may leak into a case
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX HEIMDALL_HOME CLAUDE_PLUGIN_ROOT

T="$(mktemp -d "${TMPDIR:-/tmp}/lean-footprint.XXXXXX")" || exit 1; T="$(cd "$T" && pwd -P)"
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "lean-footprint (the meter: disk, injected context, hooks per tool; --check against the budget)"

# ── helpers: every run writes $T/<name>.{out,err,rc} ───────────────────────────────────────────────────────────────────────────────────
run() { local n="$1"; shift; "$CLI" "$@" >"$T/$n.out" 2>"$T/$n.err"; echo $? >"$T/$n.rc"; }
rc() { cat "$T/$1.rc" 2>/dev/null; }
jq_ok() { local n="$1" expr="$2"; shift 2; jq -e "$@" "$expr" "$T/$n.out" >/dev/null 2>&1; }   # stdout of run $n satisfies a jq expression
show() { printf 'rc=%s out=[%s] err=[%s]' "$(rc "$1")" "$(head -c 300 "$T/$1.out" 2>/dev/null)" "$(head -c 300 "$T/$1.err" 2>/dev/null)"; }
eo() { [ -f "$T/$1.out" ] && [ ! -s "$T/$1.out" ]; }                                          # stdout of run $1 is empty
ge() { grep -qF -- "$2" "$T/$1.err" 2>/dev/null; }                                             # stderr of run $1 contains $2
fm_bytes() { printf '%s\n' "$@" | wc -c | tr -d ' '; }                                         # bytes of frontmatter lines, each with its newline
sizeof() { wc -c < "$1" | tr -d ' '; }

echo "-- 0. the meter exists --"
if [ -x "$CLI" ]; then ok "bin/heimdall-footprint exists and is executable"; else bad "$CLI is missing or not executable"; fi

# ── the fixture: a real git repo with known sizes ──────────────────────────────────────────────────────────────────────────────────────
FX="$T/fx"; mkdir -p "$FX/agents" "$FX/commands" "$FX/skills/s1" "$FX/hooks" "$FX/bin/lib" "$FX/docs" "$FX/test" "$FX/gone" "$FX/.hid"
mkfile() { head -c "$2" /dev/zero | tr '\0' 'x' > "$FX/$1"; }
MAIN_FM=("name: main" "description: Main agent" "tools: Read")
HELP_FM=("name: helper" "description: Helper agent with a longer description")
C1_FM=("name: c1" "description: First command" "argument-hint: <x>")
S1_FM=("name: s1" "description: The only skill")
{ echo '---'; printf '%s\n' "${MAIN_FM[@]}"; echo '---'; echo 'main prompt body, a few words'; } > "$FX/agents/main.md"
{ echo '---'; printf '%s\n' "${HELP_FM[@]}"; echo '---'; echo 'helper body'; } > "$FX/agents/helper.md"
{ echo '---'; printf '%s\n' "${C1_FM[@]}"; echo '---'; echo 'command body'; } > "$FX/commands/c1.md"
echo 'a command with no frontmatter at all' > "$FX/commands/c2.md"
{ echo '---'; printf '%s\n' "${S1_FM[@]}"; echo '---'; echo 'skill body'; } > "$FX/skills/s1/SKILL.md"
printf '{"agent": "main"}\n' > "$FX/settings.json"
cat > "$FX/bin/heimdall-caveman" <<'EOF'
#!/bin/sh
case "$1" in
  rules) if [ -e "${HEIMDALL_HOME:-/nonexistent}/leak" ]; then printf 'LEAKED'; else printf 'RULES-TEXT-1234567890'; fi ;;
  prompt) printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"abcdefgh"}}' ;;
esac
EOF
chmod +x "$FX/bin/heimdall-caveman"
cat > "$FX/hooks/hooks.json" <<'EOF'
{"hooks":{
 "PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"true"}]},
  {"matcher":"Read|Grep|Glob|Bash","hooks":[{"type":"command","command":"true"},{"type":"command","command":"true"}]},
  {"matcher":"*","hooks":[{"type":"command","command":"true"}]},
  {"matcher":"Edit|Write","hooks":[{"type":"command","command":"true"}]},
  {"hooks":[{"type":"command","command":"true"}]}
 ],
 "SessionStart":[
  {"hooks":[{"type":"command","command":"\"$CLAUDE_PLUGIN_ROOT/bin/heimdall-caveman\" rules"}]},
  {"hooks":[{"type":"command","command":"touch \"$CLAUDE_PLUGIN_ROOT/../executed-marker\""}]},
  {"matcher":"compact","hooks":[{"type":"command","command":"true"}]}
 ],
 "UserPromptSubmit":[
  {"hooks":[{"type":"command","command":"\"$CLAUDE_PLUGIN_ROOT/bin/heimdall-caveman\" prompt"}]}
 ],
 "Stop":[
  {"hooks":[{"type":"command","command":"true"},{"type":"command","command":"true"}]}
 ]
}}
EOF
mkfile bin/x 100; mkfile bin/lib/y 50; ln -s nowhere "$FX/bin/dangling"
mkfile docs/d.md 1000; mkfile test/t1 2000; mkfile test/t2 3000; mkfile gone/g 777; mkfile .hid/h 5; mkfile ROOTFILE 10; mkfile skills/s1/extra.md 40
git init -q "$FX" && git -C "$FX" add -A
rm -f "$FX/gone/g"              # tracked, now gone from disk: what a sparse checkout leaves behind
mkfile UNTRACKED 999            # on disk, never added

# the figures, derived without the meter: the dangling symlink is 7 bytes (lstat: len "nowhere"), every other present file by wc -c
EXP_TOTAL=7; EXP_FILES=1
while IFS= read -r f; do
  if [ -f "$FX/$f" ] && [ ! -L "$FX/$f" ]; then EXP_TOTAL=$((EXP_TOTAL + $(sizeof "$FX/$f"))); EXP_FILES=$((EXP_FILES + 1)); fi
done < <(git -C "$FX" ls-files)
CAV_B="$(sizeof "$FX/bin/heimdall-caveman")"; SET_B="$(sizeof "$FX/settings.json")"
MAIN_B="$(sizeof "$FX/agents/main.md")"
AG_FM=$(( $(fm_bytes "${MAIN_FM[@]}") + $(fm_bytes "${HELP_FM[@]}") ))
CM_FM="$(fm_bytes "${C1_FM[@]}")"; SK_FM="$(fm_bytes "${S1_FM[@]}")"
SESSION=$(( MAIN_B + AG_FM + CM_FM + SK_FM + 21 ))

echo "-- 1. the usage surface --"
run help --help
if [ "$(rc help)" = 0 ] && grep -q -- '--check' "$T/help.out" && grep -q -- '--root' "$T/help.out" && [ ! -s "$T/help.err" ]; then ok "--help: exit 0, on stdout, names --check and --root, nothing on stderr"; else bad "--help: $(show help)"; fi
run u1 --nope
run u2 --budget "$T/whatever.json"
run u3 --json --check
if [ "$(rc u1)" = 2 ] && [ "$(rc u2)" = 2 ] && [ "$(rc u3)" = 2 ] && eo u1 && eo u2 && eo u3; then ok "an unknown flag, --budget without --check, and --json with --check are each exit 2 with nothing on stdout"; else bad "usage errors: $(show u1) / $(show u2) / $(show u3)"; fi

echo "-- 2. disk --"
run fx --json --root "$FX"
if [ "$(rc fx)" = 0 ] && jq -e '.schema == 1' "$T/fx.out" >/dev/null 2>&1 && [ ! -s "$T/fx.err" ]; then ok "--json on the fixture: exit 0, one valid schema-1 JSON document on stdout, nothing on stderr"; else bad "fixture --json: $(show fx)"; fi
if jq_ok fx '.disk.total_bytes == $b and .disk.total_files == $f' --argjson b "$EXP_TOTAL" --argjson f "$EXP_FILES"; then ok "total bytes ($EXP_TOTAL) and files ($EXP_FILES) match an independent sum: the gone file and the untracked file are not counted"; else bad "disk total: $(jq -c .disk "$T/fx.out" 2>&1 | head -c 400) want bytes=$EXP_TOTAL files=$EXP_FILES"; fi
if jq_ok fx '.disk.by_dir.bin == {bytes: ($c + 157), files: 4} and .disk.by_dir.docs == {bytes: 1000, files: 1} and .disk.by_dir.test == {bytes: 5000, files: 2}' --argjson c "$CAV_B"; then ok "per top dir: bin (a file under bin/lib and a DANGLING symlink counted by lstat), docs, test"; else bad "by_dir: $(jq -c .disk.by_dir "$T/fx.out" 2>&1 | head -c 500)"; fi
if jq_ok fx '.disk.by_dir["."] == {bytes: (10 + $s), files: 2} and .disk.by_dir[".hid"] == {bytes: 5, files: 1}' --argjson s "$SET_B"; then ok "root-level files are under \".\" and a dot-directory is its own entry"; else bad "root / dot dir: $(jq -c '.disk.by_dir | {".": .["."], ".hid": .[".hid"]}' "$T/fx.out" 2>&1 | head -c 300)"; fi
if jq_ok fx '.disk.by_dir.gone == {bytes: 0, files: 0} and .disk.absent_files == 1'; then ok "a tracked dir with nothing left on disk is {0 bytes, 0 files} and the missing file is counted as absent (sparse checkout, not a crash)"; else bad "absent: $(jq -c '.disk | {absent_files, gone: .by_dir.gone}' "$T/fx.out" 2>&1 | head -c 300)"; fi
if jq_ok fx '([.disk.by_dir[].bytes] | add) == .disk.total_bytes and ([.disk.by_dir[].files] | add) == .disk.total_files'; then ok "the per-dir figures add up to the totals"; else bad "per-dir sums differ from the totals"; fi

echo "-- 3. injected context --"
if jq_ok fx '.context.main_prompt == {agent: "main", bytes: $b}' --argjson b "$MAIN_B"; then ok "main prompt: settings.json agent -> agents/main.md, whole file bytes ($MAIN_B)"; else bad "main_prompt: $(jq -c .context.main_prompt "$T/fx.out" 2>&1)"; fi
if jq_ok fx '.context.agents == {count: 2, frontmatter_bytes: $a} and .context.commands == {count: 2, frontmatter_bytes: $c} and .context.skills == {count: 1, frontmatter_bytes: $s}' --argjson a "$AG_FM" --argjson c "$CM_FM" --argjson s "$SK_FM"; then ok "frontmatter bytes per group (agents $AG_FM, commands $CM_FM, skills $SK_FM); a command with no frontmatter counts as a file and adds 0"; else bad "groups: $(jq -c '.context | {agents, commands, skills}' "$T/fx.out" 2>&1 | head -c 400)"; fi
if jq_ok fx '.context.caveman == {session_start_bytes: 21, per_prompt_bytes: 8}'; then ok "caveman: SessionStart stdout (21) and the per-prompt reminder as additionalContext (8, not its JSON wrapper)"; else bad "caveman: $(jq -c .context.caveman "$T/fx.out" 2>&1)"; fi
if jq_ok fx '.context.session_start_bytes == $t and .context.session_start_tokens_est == ($t / 4 | floor)' --argjson t "$SESSION"; then ok "session-start total = main prompt + the three frontmatter groups + caveman rules ($SESSION B), tokens estimated as bytes/4"; else bad "session total: $(jq -c '.context | {session_start_bytes, session_start_tokens_est}' "$T/fx.out" 2>&1) want $SESSION"; fi
if [ "$(rc fx)" = 0 ] && [ ! -e "$T/executed-marker" ]; then ok "only the caveman hooks are ever run: a hook that touches a marker file never ran"; else bad "a non-caveman hook was executed by the meter, or the meter did not run"; fi

echo "-- 4. hooks per event and tool --"
if jq_ok fx '.hooks.PreToolUse == {total: 6, "*": 2, Bash: 5, Read: 4, Grep: 4, Glob: 4, Edit: 3, Write: 3}'; then ok "PreToolUse: a group with 2 hooks counts 2; A|B counts for A and B; * and a matcher-less group count for every tool"; else bad "PreToolUse: $(jq -c .hooks.PreToolUse "$T/fx.out" 2>&1)"; fi
if jq_ok fx '.hooks.SessionStart == {total: 3, "*": 2, compact: 3} and .hooks.UserPromptSubmit == {total: 1, "*": 1} and .hooks.Stop == {total: 2, "*": 2} and .hooks_total == 12'; then ok "SessionStart (a compact-only hook), UserPromptSubmit, Stop and the grand total (12)"; else bad "other events: $(jq -c '{hooks, hooks_total}' "$T/fx.out" 2>&1 | head -c 500)"; fi

echo "-- 5. hermetic, deterministic, loud --"
run fx2 --json --root "$FX"
if [ -s "$T/fx.out" ] && cmp -s "$T/fx.out" "$T/fx2.out"; then ok "two runs on the same tree print byte-identical, non-empty JSON"; else bad "the output is empty or differs between two runs"; fi
mkdir -p "$T/state"; : > "$T/state/leak"
env HEIMDALL_HOME="$T/state" HOME="$T/state" GIT_DIR="$T/nowhere.git" GIT_WORK_TREE="$T/elsewhere" "$CLI" --json --root "$FX" > "$T/env.out" 2> "$T/env.err"; echo $? > "$T/env.rc"
if [ "$(rc env)" = 0 ] && cmp -s "$T/fx.out" "$T/env.out"; then ok "the caller's HEIMDALL_HOME, HOME and GIT_DIR/GIT_WORK_TREE change nothing (the hooks run in a clean sandbox, git runs without GIT_*)"; else bad "caller environment leaked in: $(show env)"; fi
run human --root "$FX"
if [ "$(rc human)" = 0 ] && grep -q 'PreToolUse' "$T/human.out" && grep -qi 'session start' "$T/human.out" && grep -q 'disk' "$T/human.out"; then ok "without flags: a readable report with the disk, context and hooks sections"; else bad "human view: $(show human)"; fi

cp -R "$FX" "$T/fxb"; FXB="$T/fxb"
restore() { cp -f "$FX/hooks/hooks.json" "$FXB/hooks/hooks.json"; cp -f "$FX/settings.json" "$FXB/settings.json"; cp -f "$FX/bin/heimdall-caveman" "$FXB/bin/heimdall-caveman"; }   # the three files the cases below rewrite
mkdir "$T/nogit"
run nogit --json --root "$T/nogit"
if [ "$(rc nogit)" = 2 ] && eo nogit && ge nogit 'git'; then ok "a directory that is not a git work tree is exit 2 naming git, nothing on stdout"; else bad "no git: $(show nogit)"; fi
rm -f "$FXB/hooks/hooks.json"; run nohooks --json --root "$FXB"; restore
if [ "$(rc nohooks)" = 2 ] && eo nohooks && ge nohooks 'hooks/hooks.json'; then ok "a missing hooks/hooks.json is exit 2 naming the file"; else bad "no hooks.json: $(show nohooks)"; fi
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"mcp__.*","hooks":[{"type":"command","command":"true"}]}]}}' > "$FXB/hooks/hooks.json"; run regex --json --root "$FXB"; restore
if [ "$(rc regex)" = 2 ] && eo regex && ge regex 'mcp__.*'; then ok "a regex matcher the meter cannot count is exit 2 naming it (never a silently wrong per-tool number)"; else bad "regex matcher: $(show regex)"; fi
printf '{"agent":"ghost"}\n' > "$FXB/settings.json"; run ghost --json --root "$FXB"; restore
if [ "$(rc ghost)" = 2 ] && eo ghost && ge ghost 'ghost'; then ok "settings.json naming an agent with no file is exit 2 naming the agent"; else bad "missing agent: $(show ghost)"; fi
printf '#!/bin/sh\nexit 3\n' > "$FXB/bin/heimdall-caveman"; run hookfail --json --root "$FXB"; restore
if [ "$(rc hookfail)" = 2 ] && eo hookfail && ge hookfail 'heimdall-caveman'; then ok "a caveman hook that exits non-zero is exit 2 (it is never counted as 0 injected bytes)"; else bad "failing hook: $(show hookfail)"; fi
printf '{}\n' > "$FXB/settings.json"; run noagent --json --root "$FXB"; restore
if [ "$(rc noagent)" = 0 ] && jq_ok noagent '.context.main_prompt == {agent: null, bytes: 0}'; then ok "settings.json without an agent has no main prompt: {null, 0}, not an error"; else bad "no agent key: $(show noagent)"; fi

echo "-- 6. --check --"
BUDGET_FILTER='{schema: 1, max: ({disk: .disk, context: .context, hooks: .hooks, hooks_total: .hooks_total} | walk(if type == "object" then with_entries(select(.value | type != "string" and . != null)) else . end))}'
mkbudget() { jq -S "$BUDGET_FILTER | ${2:-.}" "$T/fx.out" > "$1"; }   # ceilings = the fixture's own measured numbers, then a tweak
mkbudget "$T/b-eq.json"
run c-eq --check --budget "$T/b-eq.json" --root "$FX"
if [ "$(rc c-eq)" = 0 ] && grep -q '^ok:' "$T/c-eq.out"; then ok "ceilings equal to the measured numbers pass (a number AT its ceiling is fine): exit 0, an ok: line"; else bad "check at the ceiling: $(show c-eq)"; fi
mkbudget "$T/b-one.json" '.max.hooks.PreToolUse.Bash -= 1'
run c-one --check --budget "$T/b-one.json" --root "$FX"
if [ "$(rc c-one)" = 1 ] && [ "$(grep -c '^OVER:' "$T/c-one.out")" = 1 ] && grep '^OVER:' "$T/c-one.out" | grep -q 'hooks/PreToolUse/Bash' && grep '^OVER:' "$T/c-one.out" | grep -q '5' && grep '^OVER:' "$T/c-one.out" | grep -q '4'; then ok "one ceiling one below the measured number: exit 1, exactly one OVER line naming hooks/PreToolUse/Bash with 5 against 4"; else bad "check one over: $(show c-one)"; fi
mkbudget "$T/b-two.json" '.max.disk.total_bytes -= 1 | .max.context.caveman.per_prompt_bytes -= 1'
run c-two --check --budget "$T/b-two.json" --root "$FX"
if [ "$(rc c-two)" = 1 ] && [ "$(grep -c '^OVER:' "$T/c-two.out")" = 2 ] && grep -q 'disk/total_bytes' "$T/c-two.out" && grep -q 'context/caveman/per_prompt_bytes' "$T/c-two.out"; then ok "two metrics over: both are listed, not just the first"; else bad "check two over: $(show c-two)"; fi
mkbudget "$T/b-up.json" '.max.disk.total_bytes += 1000'
run c-up --check --budget "$T/b-up.json" --root "$FX"
if [ "$(rc c-up)" = 0 ]; then ok "a ceiling above the measured number passes"; else bad "check above: $(show c-up)"; fi
printf '{"schema":1,"max":{"hooks_total":12}}\n' > "$T/b-single.json"
run c-single --check --budget "$T/b-single.json" --root "$FX"
if [ "$(rc c-single)" = 0 ]; then ok "a metric the budget does not list is not checked (a one-ceiling budget passes)"; else bad "single ceiling: $(show c-single)"; fi
printf '{"schema":1,"max":{"hooks":{"Nope":{"total":1}}}}\n' > "$T/b-nope.json"
run c-nope --check --budget "$T/b-nope.json" --root "$FX"
if [ "$(rc c-nope)" = 2 ] && eo c-nope && ge c-nope 'hooks/Nope'; then ok "a ceiling for a metric the meter does not report is exit 2 naming it (a typo cannot silently check nothing)"; else bad "unmeasured metric: $(show c-nope)"; fi
BAD_ALL=""
i=0
for body in 'not json' '[]' '{"schema":2,"max":{"hooks_total":12}}' '{"schema":true,"max":{"hooks_total":12}}' '{"schema":1}' '{"schema":1,"max":{}}' '{"schema":1,"max":{"hooks":{}}}' \
            '{"schema":1,"max":{"hooks_total":"12"}}' '{"schema":1,"max":{"hooks_total":-1}}' '{"schema":1,"max":{"hooks_total":1.5}}' '{"schema":1,"max":{"hooks_total":true}}' '{"schema":1,"max":{"hooks_total":null}}'; do
  i=$((i+1)); printf '%s\n' "$body" > "$T/b-bad$i.json"
  run "c-bad$i" --check --budget "$T/b-bad$i.json" --root "$FX"
  { [ "$(rc "c-bad$i")" = 2 ] && eo "c-bad$i"; } || BAD_ALL="$BAD_ALL [$body: $(show "c-bad$i")]"
done
run c-nofile --check --budget "$T/does-not-exist.json" --root "$FX"
{ [ "$(rc c-nofile)" = 2 ] && eo c-nofile; } || BAD_ALL="$BAD_ALL [missing file: $(show c-nofile)]"
if [ -z "$BAD_ALL" ]; then ok "malformed budgets (not JSON, wrong schema, no max, empty max, a string / negative / float / boolean / null ceiling) and a missing budget file are each exit 2, nothing on stdout"; else bad "malformed budgets:$BAD_ALL"; fi

echo "-- 7. the real tree --"
run live --json --root "$REPO"
LIVE_BASH="$(jq '[.hooks.PreToolUse[] | select((.matcher // "*") as $m | $m == "*" or $m == "" or (($m | split("|")) | index("Bash") != null)) | .hooks | length] | add' "$REPO/hooks/hooks.json" 2>/dev/null)"
LIVE_HOOKS="$(jq '[.hooks[][].hooks | length] | add' "$REPO/hooks/hooks.json" 2>/dev/null)"
count_args() { echo "$#"; }
LIVE_AGENTS="$(count_args "$REPO"/agents/*.md)"; LIVE_SKILLS="$(count_args "$REPO"/skills/*/SKILL.md)"
if [ "$(rc live)" = 0 ] && jq_ok live '.disk.total_bytes > 0 and .disk.total_files > 0 and .context.session_start_bytes > 0'; then ok "the meter runs on this repo: exit 0, disk and session-start totals are positive"; else bad "live tree: $(show live)"; fi
if jq_ok live '.hooks.PreToolUse.Bash == $b and .hooks_total == $h' --argjson b "${LIVE_BASH:-null}" --argjson h "${LIVE_HOOKS:-null}"; then ok "PreToolUse.Bash ($LIVE_BASH) and the hook total ($LIVE_HOOKS) equal an independent jq count over hooks/hooks.json"; else bad "live hooks: meter says $(jq -c '[.hooks.PreToolUse.Bash, .hooks_total]' "$T/live.out" 2>&1), jq says [$LIVE_BASH, $LIVE_HOOKS]"; fi
if jq_ok live '.context.agents.count == $a and .context.skills.count == $s and .context.caveman.session_start_bytes > 0 and .context.caveman.per_prompt_bytes > 0' --argjson a "$LIVE_AGENTS" --argjson s "$LIVE_SKILLS"; then ok "agents ($LIVE_AGENTS) and skills ($LIVE_SKILLS) match ls, and both caveman hooks inject something"; else bad "live context: $(jq -c .context "$T/live.out" 2>&1 | head -c 500)"; fi
if jq -e '.schema == 1 and (.max | type == "object")' "$SHIPPED_BUDGET" >/dev/null 2>&1; then ok "release/lean-budget.json exists and is a schema-1 budget"; else bad "release/lean-budget.json is missing or not a schema-1 budget"; fi
run livechk --check --root "$REPO" --budget "$SHIPPED_BUDGET"
if [ "$(rc livechk)" = 0 ] || [ "$(rc livechk)" = 1 ]; then ok "the shipped budget is wired to metrics the meter reports (exit 0 or 1, never 2; --check says: $(head -n 1 "$T/livechk.out" | cut -c1-60))"; else bad "shipped budget against this tree: $(show livechk)"; fi
if [ -n "${HMD_FOOTPRINT_BIN:-}" ]; then
  ok "(a mutated copy is under test: the default root and the default budget path are only checked on the real script)"
else
  run livedef --check
  if [ "$(rc livedef)" = 0 ] || [ "$(rc livedef)" = 1 ]; then ok "with no flags --check reads release/lean-budget.json next to the script and measures the script's own tree"; else bad "--check with no flags: $(show livedef)"; fi
fi

printf '\nlean-footprint: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
