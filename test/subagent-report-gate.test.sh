#!/usr/bin/env bash
# test/subagent-report-gate.test.sh
#
# Proof for the subagent final-report gate (docs/analysis/2026-11-24-market-token-techniques.md, gap 2): an hmd subagent whose
# final message is longer than the cap (1,500 chars) is sent back ONCE to cut it. The hook saves the whole text to a file and tells
# the agent the path, so the report that reaches the main thread (as a task-notification, which no hook can rewrite) is a summary.
#
# The hooks run through the REAL command string of hooks/hooks.json (pulled out with jq and run with `bash -c`, the way Claude Code
# runs it) fed fake payloads in the shape of the SubagentStop input, so the wiring is proven together with the behaviour. Hermetic:
# HEIMDALL_HOME and HOME are temp dirs, nothing outside them is read or written.
#
#    1  wiring      the hook's one group in hooks.json (own kill-switch prefix), its id in the sidecar (SubagentStop, unlocked, no
#                   phone toggle), `heimdall-hooks check` clean, a recommended hook row in the guardrails manifest
#    2  long        an hmd report over the cap: ONE block; the reason names the size, the cap and a file; the file holds the whole
#                   text (0600, in a 0700 directory)
#    3  once        a second stop of that agent passes, with stop_hook_active either way; an agent already continuing because of a
#                   stop hook is never blocked
#    4  cap         a report AT the cap passes and creates nothing; one char over is blocked; chars are counted, not bytes
#    5  not hmd     Explore, general-purpose, no type, a bare `coder`, the orchestrators: never blocked, nothing written
#    6  override    HMD_REPORT_CAP raises or lowers the cap; anything that is not a positive integer is the default
#    7  fail-open   garbage, empty and wrong-shape payloads, a hostile agent id, a lone surrogate, state that cannot be written: exit 0
#                   and no decision (a report that cannot be saved is never blocked: nothing could be named, and a loop is possible)
#    8  off switch  `hmd guardrails off subagent-report-gate` silences the real command, `on` brings it back
#    9  hygiene     a saved report older than the retention is pruned by the next block; a fresh one stays
#   10  defects     each defect, applied ALONE to a copy of the script, turns the case that owns it red
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="$REPO/hooks/hooks.json"
META="$REPO/hooks/hooks.metadata.json"
MANIFEST="$REPO/guardrails.manifest.json"
TOOL="$REPO/bin/heimdall-subagent-report-gate"
GUARDRAILS="$REPO/bin/heimdall-guardrails"
HOOKSCLI="$REPO/bin/heimdall-hooks"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
check() { # check DESCRIPTION CMD... -- ok when CMD succeeds
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required"; exit 1; }
PY="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
[ -n "$PY" ] && [ -x "$PY" ] || { echo "FATAL: python3 is required"; exit 1; }

TMP="$(mktemp -d)" || exit 1
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
HHOME="$TMP/home"          # HEIMDALL_HOME: not created here, the first block makes it
USERHOME="$TMP/user"       # HOME and the working directory of every run
mkdir -p "$USERHOME"
SPILL="$HHOME/subagent-reports"

mode_of() { perl -e 'printf "%o", (stat $ARGV[0])[2] & 07777' "$1"; }
rep() { "$PY" -I -c 'import sys; sys.stdout.write(sys.argv[1] * int(sys.argv[2]))' "$1" "$2"; }
age_file() { perl -e 'utime(time - $ARGV[1] * 86400, time - $ARGV[1] * 86400, $ARGV[0])' "$1" "$2"; }

LONG="$(rep x 3000)"
AT_CAP="$(rep x 1500)"
OVER_CAP="$(rep x 1501)"

# ── the hook, as wired ──────────────────────────────────────────────────────────────────────────────────────────────────────────
CMD="$(jq -r '[.hooks.SubagentStop[]?.hooks[]?.command | select(contains("bin/heimdall-subagent-report-gate"))] | first // empty' "$HOOKS" 2>/dev/null)"

# fire COMMAND PAYLOAD -- the way Claude Code runs a hook: bash -c <command>, the payload on stdin. Stdout lands in $OUT, the
# status in $RC. XENV holds extra NAME=value assignments for the hook's environment (none contains a space).
XENV=""
fire() {
  OUT="$(printf '%s' "$2" | ( cd "$USERHOME" && env CLAUDE_PLUGIN_ROOT="$REPO" HEIMDALL_HOME="$HHOME" HOME="$USERHOME" $XENV bash -c "$1" ) 2>"$TMP/stderr")"
  RC=$?
}
silent()  { [ "$RC" = 0 ] && [ -z "$OUT" ]; }
blocked() { [ "$RC" = 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.decision // empty' 2>/dev/null)" = block ]; }
reason()  { printf '%s' "$OUT" | jq -r '.reason // empty' 2>/dev/null; }
saved_path() { reason | sed -n 's/.*saved at \(.*\.md\)\. Reply.*/\1/p'; }

SID="3f2a9c1e-7b44-4d2e-9a10-5c6e8d1b7f20"
payload() { # payload AGENT_TYPE AGENT_ID TEXT [STOP_HOOK_ACTIVE] -- the SubagentStop input
  jq -cn --arg sid "$SID" --arg t "$1" --arg id "$2" --arg text "$3" --argjson active "${4:-false}" \
    '{session_id:$sid, transcript_path:"/x/t.jsonl", cwd:"/work", permission_mode:"default", hook_event_name:"SubagentStop",
      stop_hook_active:$active, agent_id:$id, agent_type:$t, agent_transcript_path:("/x/t/subagents/agent-" + $id + ".jsonl"),
      last_assistant_message:$text, background_tasks:[], session_crons:[]}'
}

echo "subagent-report-gate"

# ── 1. wiring ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────
if [ -n "$CMD" ]; then ok "1. hooks.json runs bin/heimdall-subagent-report-gate on SubagentStop"; else bad "1. no SubagentStop entry runs bin/heimdall-subagent-report-gate"; fi
N_GROUPS="$(jq '[.hooks | to_entries[] | .value[]?.hooks[]?.command | select(contains("heimdall-subagent-report-gate"))] | length' "$HOOKS" 2>/dev/null)"
[ "$N_GROUPS" = 1 ] && ok "1. exactly one hooks.json entry runs it (no other event, no second SubagentStop group)" || bad "1. the hook is wired $N_GROUPS times, want 1"
case "$CMD" in
  *'hmd_hook_enabled subagent-report-gate'*'exit 0'*) ok "1. the command starts with its own kill-switch check (hmd_hook_enabled subagent-report-gate) and ends in exit 0" ;;
  *) bad "1. the command has no hmd_hook_enabled subagent-report-gate prefix" ;;
esac
check "1. the script is executable" test -x "$TOOL"
check "1. the sidecar names it: SubagentStop, advisory (not locked), not phone-toggleable" \
  jq -e '[.hooks[] | select(.id == "subagent-report-gate" and .event == "SubagentStop" and .locked == false and .remote_toggle == false)] | length == 1' "$META"
check "1. heimdall-hooks check: hooks.json and the sidecar agree" "$HOOKSCLI" check
check "1. the manifest lists it: a recommended hook guard, fails open, proved by this suite" \
  jq -e '[.guardrails[] | select(.id == "subagent-report-gate" and .tier == "recommended" and .layer == "hook" and .hook == "subagent-report-gate" and .kind == "guard" and .fails == "open" and .proof == "test/subagent-report-gate.test.sh")] | length == 1' "$MANIFEST"

# ── 2. a long hmd report is blocked, once, and saved whole ──────────────────────────────────────────────────────────────────────
fire "$CMD" "$(payload hmd:coder lng1 "$LONG")"
if blocked; then ok "2. a 3,000-char hmd:coder report -> decision block, exit 0"; else bad "2. a 3,000-char hmd:coder report was not blocked (rc=$RC)" "$OUT"; fi
R="$(reason)"
case "$R" in *"Report is 3,000 chars; cap 1,500."*) ok "2. the reason states the size and the cap with thousands separators" ;; *) bad "2. the reason lacks 'Report is 3,000 chars; cap 1,500.'" "$R" ;; esac
case "$R" in *"1,500-char summary"*"names that path"*) ok "2. the reason tells the agent to reply with a summary that names the path" ;; *) bad "2. the reason lacks the summary instruction" "$R" ;; esac
P="$(saved_path)"
[ "$P" = "$SPILL/lng1.md" ] && ok "2. the reason names \$HEIMDALL_HOME/subagent-reports/<agent_id>.md" || bad "2. the saved path in the reason is [$P], want $SPILL/lng1.md"
if [ -f "$P" ] && printf '%s' "$LONG" | cmp -s - "$P"; then ok "2. that file holds the whole report, byte for byte"; else bad "2. the saved file is missing or differs from the report"; fi
[ "$(mode_of "$P" 2>/dev/null)" = 600 ] && ok "2. the file is 0600" || bad "2. the file mode is $(mode_of "$P" 2>/dev/null), want 600"
[ "$(mode_of "$SPILL" 2>/dev/null)" = 700 ] && ok "2. its directory is 0700" || bad "2. the directory mode is $(mode_of "$SPILL" 2>/dev/null), want 700"

# ── 3. blocked at most once per agent ───────────────────────────────────────────────────────────────────────────────────────────
fire "$CMD" "$(payload hmd:coder lng1 "$LONG" true)"
silent && ok "3. the second stop of that agent (stop_hook_active true, as the harness sends it) passes" || bad "3. the second stop was blocked again (rc=$RC)" "$OUT"
fire "$CMD" "$(payload hmd:coder lng1 "$(rep y 5000)" false)"
silent && ok "3. the same agent id with stop_hook_active false and another long text passes too (the state, not the flag, is the authority)" || bad "3. a second stop with stop_hook_active false was blocked again" "$OUT"
printf '%s' "$LONG" | cmp -s - "$P" && ok "3. and the saved report is not overwritten" || bad "3. the saved report changed on the second stop"
fire "$CMD" "$(payload hmd:coder act1 "$LONG" true)"
if silent && [ ! -e "$SPILL/act1.md" ]; then ok "3. an agent already continuing because of a stop hook (stop_hook_active true, never blocked by us) is not blocked, and nothing is saved"; else bad "3. a stop_hook_active agent was blocked or saved" "$OUT"; fi

# ── 4. the cap is on characters, inclusive ──────────────────────────────────────────────────────────────────────────────────────
rm -rf "$HHOME"
fire "$CMD" "$(payload hmd:coder cap1 "$AT_CAP")"
if silent && [ ! -e "$HHOME" ]; then ok "4. a report of exactly 1,500 chars passes and creates nothing (not even the state directory)"; else bad "4. a report at the cap was blocked or left state behind" "$OUT"; fi
fire "$CMD" "$(payload hmd:coder cap2 "$OVER_CAP")"
if blocked; then ok "4. 1,501 chars is blocked"; else bad "4. 1,501 chars was not blocked" "$OUT"; fi
case "$(reason)" in *"Report is 1,501 chars;"*) ok "4. and the reason says 1,501" ;; *) bad "4. the reason does not say 1,501" "$(reason)" ;; esac
fire "$CMD" "$(payload hmd:coder cap3 "$(rep é 1000)")"
silent && ok "4. 1,000 two-byte chars (2,000 bytes) pass: characters are counted, not bytes" || bad "4. 1,000 two-byte chars were blocked" "$OUT"
fire "$CMD" "$(payload hmd:coder cap4 "$(rep é 1501)")"
blocked && ok "4. 1,501 two-byte chars are blocked" || bad "4. 1,501 two-byte chars were not blocked" "$OUT"
fire "$CMD" "$(payload hmd:coder cap5 "DONE")"
silent && ok "4. a short report (DONE) passes" || bad "4. a short report was blocked" "$OUT"

# ── 5. only hmd's worker agents ─────────────────────────────────────────────────────────────────────────────────────────────────
rm -rf "$HHOME"
for t in Explore general-purpose Plan "" coder fork "hmd:heimdall" "hmd:heimdall-lean" "other:coder"; do
  fire "$CMD" "$(payload "$t" "nh-$RANDOM" "$LONG")"
  silent && ok "5. type [$t] with a 3,000-char report is not blocked" || bad "5. type [$t] was blocked" "$OUT"
done
[ ! -e "$HHOME" ] && ok "5. and none of them left anything behind" || bad "5. a non-hmd stop created state: $(ls "$HHOME" 2>/dev/null)"
for t in hmd:architect hmd:test-runner hmd:reviewer hmd:wave-executor; do
  fire "$CMD" "$(payload "$t" "w-$RANDOM" "$LONG")"
  blocked && ok "5. type [$t] is gated" || bad "5. type [$t] was not blocked" "$OUT"
done
fire "$CMD" "$(jq -cn --arg id nt1 --arg text "$LONG" '{session_id:"s1", hook_event_name:"SubagentStop", stop_hook_active:false, agent_id:$id, last_assistant_message:$text}')"
silent && ok "5. a payload with no agent_type is not blocked" || bad "5. a payload with no agent_type was blocked" "$OUT"

# ── 6. the cap override ─────────────────────────────────────────────────────────────────────────────────────────────────────────
rm -rf "$HHOME"
XENV="HMD_REPORT_CAP=5000"; fire "$CMD" "$(payload hmd:coder ov1 "$LONG")"
silent && ok "6. HMD_REPORT_CAP=5000: a 3,000-char report passes" || bad "6. HMD_REPORT_CAP=5000 did not raise the cap" "$OUT"
XENV="HMD_REPORT_CAP=2000"; fire "$CMD" "$(payload hmd:coder ov2 "$LONG")"
if blocked; then case "$(reason)" in *"Report is 3,000 chars; cap 2,000."*"2,000-char summary"*) ok "6. HMD_REPORT_CAP=2000: blocked, and the reason says cap 2,000" ;; *) bad "6. the reason does not carry the overridden cap" "$(reason)" ;; esac; else bad "6. HMD_REPORT_CAP=2000 did not block a 3,000-char report" "$OUT"; fi
n=0
for v in abc 0 -5 1e3 "" 1.5 99999999999999999999999; do
  n=$((n + 1)); XENV="HMD_REPORT_CAP=$v"; fire "$CMD" "$(payload hmd:coder "gb$n" "$LONG")"
  if blocked; then case "$(reason)" in *"cap 1,500."*) ok "6. HMD_REPORT_CAP=[$v] is not a usable cap: the default 1,500 applies" ;; *) bad "6. HMD_REPORT_CAP=[$v]: wrong cap in the reason" "$(reason)" ;; esac; else bad "6. HMD_REPORT_CAP=[$v] disabled the gate" "$OUT"; fi
done
XENV=""

# ── 7. fail open ────────────────────────────────────────────────────────────────────────────────────────────────────────────────
rm -rf "$HHOME"
for case_name in "empty stdin" "not json" "a JSON array" "a JSON string" "truncated JSON" "a number as the message" "no agent_id" "agent_id with a slash" "agent_id with a dotdot" "agent_id with a space" "no message"; do
  case "$case_name" in
    "empty stdin")              body="" ;;
    "not json")                 body="this is not json" ;;
    "a JSON array")             body="[]" ;;
    "a JSON string")            body='"hello"' ;;
    "truncated JSON")           body='{"session_id":"s1","agent_type":"hmd:coder","agent_id":"tr1","last_assistant_message":"xxxxxxxx' ;;
    "a number as the message")  body="$(jq -cn '{session_id:"s1", hook_event_name:"SubagentStop", stop_hook_active:false, agent_id:"nm1", agent_type:"hmd:coder", last_assistant_message:12345}')" ;;
    "no agent_id")              body="$(jq -cn --arg t "$LONG" '{session_id:"s1", hook_event_name:"SubagentStop", stop_hook_active:false, agent_type:"hmd:coder", last_assistant_message:$t}')" ;;
    "agent_id with a slash")    body="$(payload hmd:coder "a/b" "$LONG")" ;;
    "agent_id with a dotdot")   body="$(payload hmd:coder "../../escape" "$LONG")" ;;
    "agent_id with a space")    body="$(payload hmd:coder "a b" "$LONG")" ;;
    "no message")               body="$(jq -cn '{session_id:"s1", hook_event_name:"SubagentStop", stop_hook_active:false, agent_id:"nmsg1", agent_type:"hmd:coder"}')" ;;
  esac
  fire "$CMD" "$body"
  silent && ok "7. $case_name: exit 0, no decision" || bad "7. $case_name: rc=$RC out=[$OUT]"
done
[ ! -e "$HHOME" ] && [ ! -e "$TMP/escape.md" ] && ok "7. and none of them wrote anything" || bad "7. a malformed payload wrote state"
fire "$CMD" "$(jq -cn --arg id wrong1 --arg text "$LONG" '{session_id:"s1", hook_event_name:"Stop", stop_hook_active:false, agent_id:$id, agent_type:"hmd:coder", last_assistant_message:$text}')"
silent && ok "7. a payload of another event (Stop) is not blocked" || bad "7. a Stop payload was blocked" "$OUT"
fire "$CMD" "$(printf '{"session_id":"s1","hook_event_name":"SubagentStop","stop_hook_active":false,"agent_id":"sur1","agent_type":"hmd:coder","last_assistant_message":"\\ud800%s"}' "$LONG")"
if blocked; then ok "7. a lone surrogate in the text does not crash the gate: still blocked"; else bad "7. a lone surrogate made the gate fail open or crash" "$OUT $(cat "$TMP/stderr")"; fi
rm -rf "$HHOME"; mkdir -p "$HHOME"; : > "$SPILL"
fire "$CMD" "$(payload hmd:coder un1 "$LONG")"
silent && ok "7. state that cannot be written (the directory is a file): not blocked, exit 0" || bad "7. an unwritable state still blocked or failed (rc=$RC)" "$OUT"
rm -rf "$HHOME"; mkdir -p "$HHOME"; ln -s "$TMP/elsewhere" "$SPILL"; mkdir -p "$TMP/elsewhere"
fire "$CMD" "$(payload hmd:coder ln1 "$LONG")"
if silent && [ -z "$(ls -A "$TMP/elsewhere")" ]; then ok "7. a link where the state directory belongs is never followed: not blocked, nothing written through it"; else bad "7. the gate followed a link or blocked: [$OUT] $(ls "$TMP/elsewhere")"; fi
rm -rf "$HHOME"
OUT="$(printf '%s' "$(payload hmd:coder nh2 "$LONG")" | ( cd "$USERHOME" && env -u HEIMDALL_HOME -u HOME CLAUDE_PLUGIN_ROOT="$REPO" bash -c "$CMD" ) 2>/dev/null)"; RC=$?
silent && ok "7. neither HEIMDALL_HOME nor HOME set: no place to save, so not blocked" || bad "7. with no home the gate blocked or failed (rc=$RC)" "$OUT"
OUT="$(printf '%s' "$(payload hmd:coder rel1 "$LONG")" | ( cd "$USERHOME" && env CLAUDE_PLUGIN_ROOT="$REPO" HEIMDALL_HOME="relative/home" HOME="$USERHOME" bash -c "$CMD" ) 2>/dev/null)"; RC=$?
if silent && [ ! -e "$USERHOME/relative" ]; then ok "7. a relative HEIMDALL_HOME is refused (a repository could ship it): not blocked, nothing written"; else bad "7. a relative HEIMDALL_HOME was used (rc=$RC)" "$OUT"; fi

# ── 8. the off switch ───────────────────────────────────────────────────────────────────────────────────────────────────────────
rm -rf "$HHOME"
guardrails() { env -u CLAUDE_PLUGIN_ROOT -u HMD_GUARDRAILS_MANIFEST -u HMD_HOOKS_METADATA HEIMDALL_HOME="$HHOME" HOME="$USERHOME" "$GUARDRAILS" "$@" 2>"$TMP/stderr"; }
GOUT="$(guardrails off subagent-report-gate)"; GRC=$?
[ "$GRC" = 0 ] && ok "8. hmd guardrails off subagent-report-gate exits 0" || bad "8. guardrails off exited $GRC" "$GOUT $(cat "$TMP/stderr")"
fire "$CMD" "$(payload hmd:coder off1 "$LONG")"
if silent && [ ! -e "$SPILL" ]; then ok "8. switched off: the real command says nothing and saves nothing"; else bad "8. the gate still ran while switched off" "$OUT"; fi
GOUT="$(guardrails on subagent-report-gate)"; GRC=$?
[ "$GRC" = 0 ] && ok "8. hmd guardrails on exits 0" || bad "8. guardrails on exited $GRC" "$GOUT"
fire "$CMD" "$(payload hmd:coder on1 "$LONG")"
blocked && ok "8. switched back on: blocks again" || bad "8. the gate did not come back on" "$OUT"
GOUT="$(guardrails list --json | jq -r '.[] | select(.id == "subagent-report-gate") | [.tier, .switchable, .state] | join(" ")')"
[ "$GOUT" = "recommended true on" ] && ok "8. hmd guardrails list: recommended, switchable, on" || bad "8. guardrails list shows [$GOUT]" "$(cat "$TMP/stderr")"

# ── 9. hygiene: retention ───────────────────────────────────────────────────────────────────────────────────────────────────────
rm -rf "$HHOME"; mkdir -p "$SPILL"; chmod 700 "$HHOME" "$SPILL"
printf 'old report' > "$SPILL/stale1.md"; age_file "$SPILL/stale1.md" 30
printf 'recent report' > "$SPILL/fresh1.md"; age_file "$SPILL/fresh1.md" 2
fire "$CMD" "$(payload hmd:coder hy1 "$LONG")"
if blocked && [ ! -e "$SPILL/stale1.md" ] && [ -f "$SPILL/fresh1.md" ] && [ -f "$SPILL/hy1.md" ]; then ok "9. a saved report 30 days old is pruned by the next block; one 2 days old and the new one stay"; else bad "9. pruning wrong: $(ls "$SPILL")"; fi

# ── 10. each defect, alone, turns its case red ──────────────────────────────────────────────────────────────────────────────────
MUT="$TMP/mut"; mkdir -p "$MUT/bin/lib"
cp "$REPO/bin/lib/hmd_private_state.py" "$MUT/bin/lib/"
run_script() { # run_script SCRIPT HOME PAYLOAD -- the script itself, no hooks.json
  OUT="$(printf '%s' "$3" | env HEIMDALL_HOME="$2" HOME="$USERHOME" "$1" 2>/dev/null)"
}
sc_blocks()   { run_script "$1" "$2" "$(payload hmd:coder blk1 "$LONG")"; [ "$(printf '%s' "$OUT" | jq -r '.decision // empty')" = block ]; }
sc_boundary() { run_script "$1" "$2" "$(payload hmd:coder bnd1 "$AT_CAP")"; [ -z "$OUT" ]; }
sc_once()     { run_script "$1" "$2" "$(payload hmd:coder one1 "$LONG")"; run_script "$1" "$2" "$(payload hmd:coder one1 "$LONG")"; [ -z "$OUT" ]; }
sc_active()   { run_script "$1" "$2" "$(payload hmd:coder act1 "$LONG" true)"; [ -z "$OUT" ]; }
sc_not_hmd()  { run_script "$1" "$2" "$(payload Explore nh1 "$LONG")"; [ -z "$OUT" ]; }
sc_orch()     { run_script "$1" "$2" "$(payload hmd:heimdall or1 "$LONG")"; [ -z "$OUT" ]; }
sc_prune()    { mkdir -p "$2/subagent-reports"; chmod 700 "$2" "$2/subagent-reports"; printf old > "$2/subagent-reports/stale.md"; age_file "$2/subagent-reports/stale.md" 30
                run_script "$1" "$2" "$(payload hmd:coder pr1 "$LONG")"; [ ! -e "$2/subagent-reports/stale.md" ]; }

mutant() { # mutant NAME SED_EXPRESSION SCENARIO -- the real script passes SCENARIO; the script with the one defect does not
  local name="$1" expr="$2" sc="$3" copy="$MUT/bin/heimdall-subagent-report-gate"
  sed -e "$expr" "$TOOL" > "$copy" && chmod +x "$copy"
  if cmp -s "$TOOL" "$copy"; then bad "mutant \"$name\": the edit changed nothing (the script no longer has that line)"; return; fi
  rm -rf "$TMP/mh-real" "$TMP/mh-mut"
  if ! "$sc" "$TOOL" "$TMP/mh-real"; then bad "mutant \"$name\": the real script fails $sc"; return; fi
  if "$sc" "$copy" "$TMP/mh-mut"; then bad "mutant \"$name\": $sc still passes with the defect"; else ok "mutant \"$name\": $sc goes red"; fi
}
mutant "the gate never blocks"                    's/^    if len(text) <= cap:$/    if True:/'                                                  sc_blocks
mutant "the cap is exclusive"                     's/len(text) <= cap/len(text) < cap/'                                                         sc_boundary
mutant "a second stop is blocked again"           's/ps\.create_once(/ps.write(/'                                                               sc_once
mutant "stop_hook_active is ignored"              's/payload\.get("stop_hook_active") is True/payload.get("stop_hook_active") is None/'         sc_active
mutant "every agent type is gated"                's/ or not agent_type\.startswith(NAMESPACE)//'                                               sc_not_hmd
mutant "the orchestrator is gated"                's/^ORCHESTRATORS = .*/ORCHESTRATORS = ()/'                                                   sc_orch
mutant "old reports are never pruned"             's/^MAX_AGE_S = .*/MAX_AGE_S = 10 ** 9/'                                                      sc_prune

printf '\n  subagent-report-gate: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
