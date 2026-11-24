#!/usr/bin/env bash
# test/read-dedup.test.sh
# budget: ~16s solo -- each case starts one bash + one python (~50 ms), about 250 cases; no network, no claude.
#
# Proof for the read-dedup hook (docs/analysis/2026-11-24-market-token-techniques.md, gap 1; Cline/Roo precedent): a Read whose
# content is byte-identical to the SAME agent's last Read of the same path, offset and limit is replaced, through PostToolUse
# hookSpecificOutput.updatedToolOutput, by a one-line stub. Anything else passes through untouched (no output, exit 0).
#
# Runs the REAL command strings of hooks/hooks.json (the Read hook, and the EXISTING PreCompact hook) with `bash -c`, the way Claude
# Code runs them, fed payloads in the shape 2.1.331 sends (probed 2026-11-24: updatedToolOutput fires for a subagent's Read, and that
# payload carries agent_id and agent_type; transcript_path is the MAIN transcript, session_id the parent's).
#
#    1  wiring      one PostToolUse Read entry; kill-switch id in the sidecar (not locked), a recommended manifest row
#    2  stub        identical re-read -> stub naming path and lines, tool_response shape kept; the first read passes untouched
#    3  valve       a re-read right after a stub gets the real content (a stub that was not believed is never repeated)
#    4  changed     other content -> full; A,B,A -> full (the last read is B); a different offset/limit is its own key
#    5  compaction  the existing PreCompact hook forgets that session's reads; a compact_boundary written to the transcript (main, or
#                   the agent's own) since the first read blocks the stub with NO hook at all; an unreadable transcript never stubs
#    6  agents      state is per (session, agent): another agent, the main thread, another session are all first readers
#    7  skips       another tool, an image, a file whose content is shorter than the stub
#    8  hygiene     hashes only (no content on disk), 0700/0600, entry cap, old state files pruned
#    9  fail-open   garbage payloads, hostile ids, an unwritable home -> no output, exit 0
#   10  off switch  HMD_READ_DEDUP=off; hooks-disabled (what `hmd guardrails off read-dedup` writes)
#   11  left context ANY sign in the transcript since the first read that it may have left context blocks the stub: a system subtype
#                    containing "compact" (compact_boundary, microcompact_boundary, any case), the compaction summary entry, a
#                    compactMetadata key, a tool result swapped for the clearing placeholder, an API context edit that cleared tool
#                    uses, and a rewind or branch (the newest entry no longer descends from the entry that carried the first read).
#                    Prose that merely quotes a marker, a fork that is not a rewind and plain growth do not block it. A read whose
#                    tool call cannot be found in the transcript is never stubbed.
#   12  outline      an unsliced Read of a big (over 500 lines) python or shell file by a SUBAGENT is answered with its first 100
#                    lines and its outline, once: the second plain Read gets the whole file and dedup takes over from there. Never
#                    the main thread, a slice, a short file, another language, a test file, a Read cut short, a file with under 3
#                    symbols. HMD_READ_OUTLINE=off turns only the outline off; HMD_READ_DEDUP=off turns the whole hook off.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="$REPO/hooks/hooks.json"
META="$REPO/hooks/hooks.metadata.json"
MANIFEST="$REPO/guardrails.manifest.json"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
finish() { printf '\n  read-dedup: %d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }

command -v jq >/dev/null 2>&1   || { echo "FATAL: jq is required"; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "FATAL: perl is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required"; exit 1; }

TMP="$(mktemp -d)" || exit 1
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
HHOME="$TMP/home"            # HEIMDALL_HOME: where the hook keeps its state
USERHOME="$TMP/user"         # HOME and the working directory of every run
TDIR="$TMP/transcripts"      # the transcripts the payloads name
NOPROJ="$TMP/not-managed"    # CLAUDE_PROJECT_DIR for the PreCompact hook: no .planning, so no checkpoint is written
mkdir -p "$HHOME" "$USERHOME" "$TDIR" "$NOPROJ"
STATE="$HHOME/read-dedup"

mode_of() { perl -e 'printf "%o", (stat $ARGV[0])[2] & 07777' "$1"; }

# ── the hooks, as wired ─────────────────────────────────────────────────────────────────────────────────────────────────────────
CMD_READ="$(jq -r '[.hooks.PostToolUse[]? | select(.matcher == "Read") | .hooks[]?.command | select(contains("heimdall-read-dedup"))] | first // empty' "$HOOKS")"
CMD_COMPACT="$(jq -r '[.hooks.PreCompact[]?.hooks[]?.command | select(contains("heimdall-precompact-checkpoint"))] | first // empty' "$HOOKS")"

echo "1. wiring"
N_READ="$(jq '[.hooks.PostToolUse[]? | select(.matcher == "Read") | .hooks[]? | select(.command | contains("heimdall-read-dedup"))] | length' "$HOOKS")"
if [ "$N_READ" = 1 ]; then ok "hooks.json: exactly one PostToolUse Read entry runs heimdall-read-dedup"
else bad "hooks.json: exactly one PostToolUse Read entry runs heimdall-read-dedup" "found $N_READ"; finish; exit 1; fi
case "$CMD_READ" in *"hmd_hook_enabled read-dedup"*) ok "the entry carries the kill-switch prefix for id read-dedup" ;;
  *) bad "the entry carries the kill-switch prefix for id read-dedup" ;; esac
[ -n "$CMD_COMPACT" ] && ok "the existing PreCompact hook is still registered" || bad "the existing PreCompact hook is still registered"
if jq -e '[.hooks[] | select(.id == "read-dedup" and .event == "PostToolUse" and .matcher == "Read" and .locked == false)] | length == 1' "$META" >/dev/null 2>&1; then
  ok "sidecar: id read-dedup, PostToolUse, matcher Read, not locked"
else bad "sidecar: id read-dedup, PostToolUse, matcher Read, not locked"; fi
if jq -e '[.guardrails[] | select(.id == "read-dedup" and .layer == "hook" and .hook == "read-dedup" and .tier == "recommended")] | length == 1' "$MANIFEST" >/dev/null 2>&1; then
  ok "guardrails manifest: a recommended hook row for read-dedup"
else bad "guardrails manifest: a recommended hook row for read-dedup"; fi

# fire COMMAND PAYLOAD -- the way Claude Code runs a hook: bash -c <command>, the payload on stdin. Stdout lands in $OUT, the
# status in $RC, stderr in $TMP/stderr. FIRE_HOME is the HEIMDALL_HOME the hook sees; ENVX holds extra NAME=VALUE for one run.
FIRE_HOME="$HHOME"
ENVX=()
fire() {
  OUT="$(printf '%s' "$2" | ( cd "$USERHOME" && env CLAUDE_PLUGIN_ROOT="$REPO" HEIMDALL_HOME="$FIRE_HOME" HOME="$USERHOME" \
    CLAUDE_PROJECT_DIR="$NOPROJ" ${ENVX[@]+"${ENVX[@]}"} bash -c "$1" ) 2>"$TMP/stderr")"
  RC=$?
}

# body TAG LINES -- LINES lines of ~60 characters, so a slice of a few lines is longer than the stub
body() { awk -v t="$1" -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) printf "%s line %d ........................................\n", t, i }'; }

# payload SESSION AGENT PATH CONTENT [OFFSET] [LIMIT] -- a Read's PostToolUse payload (AGENT empty = the main thread). The call id is
# $TUID. totalLines says the file has 40 more lines than the Read returned, unless WHOLE=1 (the Read returned every line of the file).
TUID="toolu_0"
WHOLE=0
payload() {
  jq -cn --arg sid "$1" --arg agent "$2" --arg p "$3" --arg c "$4" --arg off "${5:-}" --arg lim "${6:-}" --arg tp "$TDIR/$1.jsonl" \
    --arg tuid "$TUID" --arg whole "$WHOLE" '
    ($c | split("\n") | length) as $n
    | {session_id: $sid, transcript_path: $tp, cwd: "/work", permission_mode: "default", hook_event_name: "PostToolUse",
       tool_name: "Read",
       tool_input: ({file_path: $p} + (if $off == "" then {} else {offset: ($off | tonumber)} end) + (if $lim == "" then {} else {limit: ($lim | tonumber)} end)),
       tool_response: {type: "text", file: {filePath: $p, content: $c, numLines: $n, startLine: (if $off == "" then 1 else ($off | tonumber) end), totalLines: (if $whole == "1" then $n else $n + 40 end)}},
       tool_use_id: $tuid, duration_ms: 4}
    + (if $agent == "" then {} else {agent_id: $agent, agent_type: "hmd:coder"} end)'
}

# A transcript is a chain: every entry names the one before it in parentUuid, and the assistant entry that carries a tool call holds its
# tool_use id, as Claude Code writes them. grow appends one such entry to FILE, chained on the last entry grow wrote there
# (FILE.last holds its uuid); ENTRY numbers them. grow runs in the main shell, never in a $( ).
ENTRY=0
SEQ=0
grow() {   # grow FILE call|result TOOL_USE_ID
  local f="$1" parent=null
  [ -f "$f.last" ] && parent="\"$(cat "$f.last")\""
  ENTRY=$((ENTRY + 1))
  if [ "$2" = call ]; then
    printf '{"parentUuid":%s,"type":"assistant","uuid":"e%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"Read","input":{}}]}}\n' "$parent" "$ENTRY" "$3" >> "$f"
  else
    printf '{"parentUuid":%s,"type":"user","uuid":"e%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"ok"}]}}\n' "$parent" "$ENTRY" "$3" >> "$f"
  fi
  printf 'e%s' "$ENTRY" > "$f.last"
}
transcript() {   # transcript SESSION -- a main transcript holding one root entry, and the directory a subagent's own transcript goes in
  mkdir -p "$TDIR/$1/subagents"
  printf '{"parentUuid":null,"type":"user","uuid":"root-%s","message":{"role":"user","content":"hi"}}\n' "$1" > "$TDIR/$1.jsonl"
  printf 'root-%s' "$1" > "$TDIR/$1.jsonl.last"
}

# reread SESSION AGENT PATH CONTENT [OFFSET] [LIMIT] -- fire the Read hook with that payload, the way a session does: the assistant entry
# that carries the call is in the transcript of the reading agent (the main one, or the agent's own) before the hook runs, its result after
reread() {
  local f="$TDIR/$1.jsonl"
  [ -n "$2" ] && f="$TDIR/$1/subagents/agent-$2.jsonl"
  SEQ=$((SEQ + 1)); TUID="toolu_$SEQ"
  if [ -f "$f" ] || [ -n "$2" ]; then grow "$f" call "$TUID"; fi
  fire "$CMD_READ" "$(payload "$@")"
  if [ -f "$f" ]; then grow "$f" result "$TUID"; fi
}
passes_through() { [ "$RC" = 0 ] && [ -z "$OUT" ]; }
# stub_for PATH LINES -- $OUT is a stub for PATH covering LINES ("1-30"), in the shape of a Read result
stub_for() {
  printf '%s' "$OUT" | jq -e --arg p "$1" --arg l "$2" '
    .hookSpecificOutput.hookEventName == "PostToolUse"
    and .hookSpecificOutput.updatedToolOutput.type == "text"
    and .hookSpecificOutput.updatedToolOutput.file.filePath == $p
    and (.hookSpecificOutput.updatedToolOutput.file.content
         | startswith("unchanged since your earlier read of " + $p + " (lines " + $l + "); content is already in your context"))' >/dev/null 2>&1
}

S1="3f2a9c1e-7b44-4d2e-9a10-5c6e8d1b7f20"
P1="$TMP/proj/a.txt"
A="$(body alpha 30)"
B="$(body bravo 30)"
for s in "$S1" s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 other-session hyg cap brandnew off1; do transcript "$s"; done

echo "2. stub"
reread "$S1" "" "$P1" "$A"
passes_through && ok "the first read passes through untouched (no output, exit 0)" || bad "the first read passes through untouched" "rc=$RC out=$OUT"
reread "$S1" "" "$P1" "$A"
if [ "$RC" = 0 ] && stub_for "$P1" "1-30"; then ok "an identical re-read is replaced by the stub naming the path and lines 1-30"
else bad "an identical re-read is replaced by the stub naming the path and lines 1-30" "rc=$RC out=$OUT"; fi
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.updatedToolOutput.file.totalLines == 70 and (.hookSpecificOutput.updatedToolOutput.file.content | length) < ('"${#A}"')' >/dev/null 2>&1; then
  ok "the Read result shape is kept (totalLines survives) and the stub is shorter than the content it replaces"
else bad "the Read result shape is kept and the stub is shorter than the content" "out=$OUT"; fi

echo "3. valve"
reread "$S1" "" "$P1" "$A"
passes_through && ok "a re-read right after a stub gets the real content (nothing is stubbed twice in a row)" || bad "a re-read right after a stub gets the real content" "out=$OUT"
reread "$S1" "" "$P1" "$A"
stub_for "$P1" "1-30" && ok "and the read after that is stubbed again" || bad "and the read after that is stubbed again" "out=$OUT"

echo "4. changed content, other ranges"
# the reads below follow no stub of their own key, so only the content hash (or the key) tells them from an unchanged re-read
P2="$TMP/proj/b.txt"; P3="$TMP/proj/c.txt"; P4="$TMP/proj/d.txt"
reread "$S1" "" "$P2" "$A"
reread "$S1" "" "$P2" "$B"
passes_through && ok "a changed file is not stubbed (nothing but the content hash tells it from an unchanged one)" || bad "a changed file is not stubbed" "out=$OUT"
reread "$S1" "" "$P2" "$B"
stub_for "$P2" "1-30" && ok "the changed content is then recorded: its own re-read is stubbed" || bad "the changed content is then recorded" "out=$OUT"
reread "$S1" "" "$P3" "$A"; reread "$S1" "" "$P3" "$B"; reread "$S1" "" "$P3" "$A"
passes_through && ok "A, B, A: the last read was B, so A is a change and is not stubbed" || bad "A, B, A: A is not stubbed" "out=$OUT"
reread "$S1" "" "$P4" "$A"
reread "$S1" "" "$P4" "$A" 1 30
passes_through && ok "the same bytes asked for with an offset/limit are a different read: not stubbed" || bad "a different offset/limit is not stubbed" "out=$OUT"
reread "$S1" "" "$P4" "$A" 1 30
stub_for "$P4" "1-30" && ok "the same offset/limit again is stubbed" || bad "the same offset/limit again is stubbed" "out=$OUT"
reread "$S1" "" "$P4" "$A" 1 31
passes_through && ok "same offset, other limit: its own key, not stubbed" || bad "same offset, other limit is not stubbed" "out=$OUT"
reread "$S1" "" "$P4" "$A"
stub_for "$P4" "1-30" && ok "the whole-file key was untouched by the slices: still stubbed against its own last read" || bad "the whole-file key survives slice reads" "out=$OUT"
C="$(body charlie 5)"
reread "$S1" "" "$P4" "$C" 10 5; reread "$S1" "" "$P4" "$C" 10 5
stub_for "$P4" "10-14" && ok "a slice is stubbed naming its own lines (10-14)" || bad "a slice is stubbed naming its own lines" "out=$OUT"

echo "5. compaction"
reread s2 "" "$P1" "$A"; reread s2 "" "$P1" "$A"
stub_for "$P1" "1-30" && ok "setup: a re-read in session s2 is stubbed" || bad "setup: a re-read in session s2 is stubbed" "out=$OUT"
reread s2 "" "$P1" "$A"                                   # the valve read: full, re-recorded
reread s3 "" "$P1" "$A"; reread s3 "" "$P1" "$A"; reread s3 "" "$P1" "$A"   # s3: full, stub, valve: its next read is a stub
fire "$CMD_COMPACT" "$(jq -cn --arg sid s2 --arg tp "$TDIR/s2.jsonl" '{session_id: $sid, transcript_path: $tp, cwd: "/work", hook_event_name: "PreCompact", trigger: "auto", custom_instructions: null}')"
[ "$RC" = 0 ] && ok "the existing PreCompact hook still exits 0" || bad "the existing PreCompact hook still exits 0" "rc=$RC"
reread s2 "" "$P1" "$A"
passes_through && ok "after the PreCompact hook the same read is NOT stubbed: the first read left context" || bad "after PreCompact the same read is not stubbed" "out=$OUT"
reread s3 "" "$P1" "$A"
stub_for "$P1" "1-30" && ok "the PreCompact hook cleared only its own session: s3 is still stubbed" || bad "PreCompact clears only its own session" "out=$OUT"
reread s2 "" "$P1" "$A"
stub_for "$P1" "1-30" && ok "and a read after the compaction is recorded afresh, so the next one is stubbed" || bad "reads after compaction are recorded afresh" "out=$OUT"

# no hook at all: the transcript itself says a compaction happened since the first read
reread s4 "" "$P1" "$A"
printf '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","level":"info","compactMetadata":{"trigger":"auto"}}\n' >> "$TDIR/s4.jsonl"
reread s4 "" "$P1" "$A"
passes_through && ok "a compact_boundary in the main transcript since the first read blocks the stub (no PreCompact hook ran)" || bad "compact_boundary in the transcript blocks the stub" "out=$OUT"
reread s4 "" "$P1" "$A"
stub_for "$P1" "1-30" && ok "a read after that boundary is recorded afresh and stubbed next time" || bad "a read after the boundary is recorded afresh" "out=$OUT"
reread s5 "" "$P1" "$A"
printf '{"type":"assistant","n":3,"text":"compact_boundary appears here only as prose"}\n' >> "$TDIR/s5.jsonl"
reread s5 "" "$P1" "$A"
stub_for "$P1" "1-30" && ok "transcript growth that is not a compaction does not block the stub" || bad "plain transcript growth does not block the stub" "out=$OUT"
reread s6 "agentX" "$P1" "$A"
printf '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}\n' >> "$TDIR/s6/subagents/agent-agentX.jsonl"
reread s6 "agentX" "$P1" "$A"
passes_through && ok "a compact_boundary in the AGENT's own transcript blocks that agent's stub" || bad "the agent's own compaction blocks the stub" "out=$OUT"
reread s7 "" "$P1" "$A"; rm -f "$TDIR/s7.jsonl"; reread s7 "" "$P1" "$A"
passes_through && ok "an unreadable transcript never stubs (the compaction check cannot be made)" || bad "an unreadable transcript never stubs" "out=$OUT"
NOTP="$(payload s8 "" "$P1" "$A" | jq -c 'del(.transcript_path)')"
fire "$CMD_READ" "$NOTP"; fire "$CMD_READ" "$NOTP"
passes_through && ok "a payload with no transcript_path never stubs" || bad "no transcript_path never stubs" "out=$OUT"
reread s10 "" "$P1" "$A"; : > "$TDIR/s10.jsonl"; reread s10 "" "$P1" "$A"
passes_through && ok "a transcript that SHRANK since the first read never stubs (it was rewritten under us)" || bad "a shrunk transcript never stubs" "out=$OUT"
reread s11 "" "$P1" "$A"; head -c 9000000 /dev/zero >> "$TDIR/s11.jsonl"; reread s11 "" "$P1" "$A"
passes_through && ok "more than 8 MiB written since the first read never stubs (too long a gap to vouch for)" || bad "a huge gap never stubs" "out=$OUT"

echo "6. agents"
reread s9 "agentA" "$P1" "$A"; reread s9 "agentA" "$P1" "$A"
stub_for "$P1" "1-30" && ok "an agent's own re-read is stubbed" || bad "an agent's own re-read is stubbed" "out=$OUT"
reread s9 "agentB" "$P1" "$A"
passes_through && ok "another agent of the same session reads it for the first time: not stubbed" || bad "another agent is a first reader" "out=$OUT"
reread s9 "" "$P1" "$A"
passes_through && ok "the main thread of that session is a first reader too: not stubbed" || bad "the main thread is a first reader" "out=$OUT"
reread "other-session" "agentA" "$P1" "$A"
passes_through && ok "the same agent id in another session is a first reader: not stubbed" || bad "another session is a first reader" "out=$OUT"

echo "7. skips"
tmp_in="$(payload "$S1" "" "$P1" "$A" | jq -c '.tool_name = "Bash"')"
fire "$CMD_READ" "$tmp_in"; fire "$CMD_READ" "$tmp_in"
passes_through && ok "a payload for another tool is left alone" || bad "another tool is left alone" "out=$OUT"
IMG="$(payload "$S1" "" "$TMP/pic.png" "$A" | jq -c '.tool_response.type = "image"')"   # same bytes as a text read: only the type can keep it out
fire "$CMD_READ" "$IMG"; fire "$CMD_READ" "$IMG"
passes_through && ok "an image result is never stubbed" || bad "an image result is never stubbed" "out=$OUT"
SMALL="tiny file"
reread "$S1" "" "$TMP/small.txt" "$SMALL"; reread "$S1" "" "$TMP/small.txt" "$SMALL"
passes_through && ok "a file shorter than the stub is not stubbed (the stub would be the bigger output)" || bad "a short file is not stubbed" "out=$OUT"

echo "8. hygiene"
SECRET="TOPSECRETMARKER-$$-9f3c"
reread hyg "" "$P1" "$(body "$SECRET" 30)"
if [ -d "$STATE" ] && [ "$(mode_of "$STATE")" = 700 ]; then ok "the state directory is 0700"; else bad "the state directory is 0700" "mode=$(mode_of "$STATE" 2>/dev/null)"; fi
BAD_MODE=""
for f in "$STATE"/*.json; do [ "$(mode_of "$f")" = 600 ] || BAD_MODE="$f"; done
[ -z "$BAD_MODE" ] && ok "every state file is 0600" || bad "every state file is 0600" "$BAD_MODE"
if grep -rq "$SECRET" "$STATE" 2>/dev/null; then bad "state holds hashes only: file content found on disk"; else ok "state holds hashes only: the file's content is nowhere on disk"; fi
if grep -rqF "$P1" "$STATE" 2>/dev/null; then bad "state holds hashes only: a path was stored"; else ok "state holds hashes only: not even the path is stored"; fi

ENVX=(HMD_READ_DEDUP_MAX_ENTRIES=3)
for i in 1 2 3 4 5; do reread cap "" "$TMP/f$i.txt" "$(body "file$i" 20)"; done
reread cap "" "$TMP/f1.txt" "$(body file1 20)"
passes_through && ok "past the entry cap the oldest read is forgotten (not stubbed)" || bad "the oldest read is forgotten past the cap" "out=$OUT"
reread cap "" "$TMP/f5.txt" "$(body file5 20)"
stub_for "$TMP/f5.txt" "1-20" && ok "the newest read is still remembered (stubbed)" || bad "the newest read is remembered" "out=$OUT"
ENVX=()

mkdir -p "$STATE"
printf '{}' > "$STATE/oldsess._main.json"; chmod 600 "$STATE/oldsess._main.json"; touch -t 202001010000 "$STATE/oldsess._main.json"
printf '{}' > "$STATE/freshsess._main.json"; chmod 600 "$STATE/freshsess._main.json"
reread brandnew "" "$P1" "$A"
[ ! -e "$STATE/oldsess._main.json" ] && ok "a state file untouched for over a day is pruned when a new session starts recording" || bad "an old state file is pruned"
[ -e "$STATE/freshsess._main.json" ] && ok "a recent state file of another session is kept" || bad "a recent state file is kept"

echo "9. fail-open"
for junk in '' 'not json' '[]' '"str"' '{}' '{"tool_name":"Read"}' \
            '{"tool_name":"Read","session_id":"x","tool_input":{"file_path":"/a"},"tool_response":"plain string"}' \
            '{"tool_name":"Read","session_id":"x","tool_input":{"file_path":"/a"},"tool_response":{"type":"text","file":{"content":7}}}' \
            '{"tool_name":"Read","session_id":"x","tool_input":"nope","tool_response":{"type":"text","file":{"content":"c"}}}'; do
  fire "$CMD_READ" "$junk"
  if passes_through; then ok "payload $(printf '%.40s' "${junk:-<empty>}") -> no output, exit 0"; else bad "payload ${junk:-<empty>} fails open" "rc=$RC out=$OUT"; fi
done
HOSTILE="$(payload '../../etc/evil' "" "$P1" "$A")"; fire "$CMD_READ" "$HOSTILE"; fire "$CMD_READ" "$HOSTILE"
passes_through && [ ! -e "$HHOME/../etc" ] && ok "a hostile session id is refused, not turned into a path" || bad "a hostile session id is refused" "out=$OUT"
HOSTILE="$(payload s9 '../x' "$P1" "$A")"; fire "$CMD_READ" "$HOSTILE"; fire "$CMD_READ" "$HOSTILE"
passes_through && ok "a hostile agent id is refused" || bad "a hostile agent id is refused" "out=$OUT"
: > "$TMP/homefile"; FIRE_HOME="$TMP/homefile"
reread s9 "agentA" "$P1" "$A"; reread s9 "agentA" "$P1" "$A"
passes_through && ok "an unwritable HEIMDALL_HOME (a plain file) fails open: no output, exit 0" || bad "an unwritable home fails open" "rc=$RC out=$OUT"
FIRE_HOME="$HHOME"
printf 'garbage' > "$STATE/s9.agentA.json"; chmod 600 "$STATE/s9.agentA.json"
reread s9 "agentA" "$P1" "$A"
passes_through && ok "a corrupt state file is treated as no state: the read passes through" || bad "a corrupt state file fails open" "out=$OUT"
reread s9 "agentA" "$P1" "$A"
stub_for "$P1" "1-30" && ok "and the corrupt file is replaced by a good one" || bad "the corrupt state file is replaced" "out=$OUT"

echo "10. off switch"
ENVX=(HMD_READ_DEDUP=off)
reread off1 "" "$P1" "$A"; reread off1 "" "$P1" "$A"
passes_through && ok "HMD_READ_DEDUP=off: no stub" || bad "HMD_READ_DEDUP=off: no stub" "out=$OUT"
[ ! -e "$STATE/off1._main.json" ] && ok "HMD_READ_DEDUP=off: nothing recorded either" || bad "HMD_READ_DEDUP=off records nothing"
ENVX=()
transcript off2
printf 'read-dedup\n' > "$HHOME/hooks-disabled"
reread off2 "" "$P1" "$A"; reread off2 "" "$P1" "$A"
passes_through && [ ! -e "$STATE/off2._main.json" ] && ok "hooks-disabled lists read-dedup (hmd guardrails off): no stub, nothing recorded" || bad "hooks-disabled switches the hook off" "out=$OUT"
rm -f "$HHOME/hooks-disabled"
reread off2 "" "$P1" "$A"; reread off2 "" "$P1" "$A"
stub_for "$P1" "1-30" && ok "removed from the list (hmd guardrails on): stubbing resumes" || bad "stubbing resumes when enabled again" "out=$OUT"

echo "11. any sign the read left context"
# blocked NAME SESSION LINE -- read, append LINE to that session's transcript, read again: the second read is not stubbed
blocked() {
  transcript "$2"
  reread "$2" "" "$P1" "$A"
  printf '%s\n' "$3" >> "$TDIR/$2.jsonl"
  reread "$2" "" "$P1" "$A"
  if passes_through; then ok "$1"; else bad "$1" "out=$OUT"; fi
}
blocked "a microcompact_boundary entry since the first read blocks the stub" m1 \
  '{"type":"system","subtype":"microcompact_boundary","content":"Context microcompacted","microcompactMetadata":{"trigger":"auto","tokensSaved":9000}}'
blocked "any system subtype containing compact blocks it, in any case (Conversation_COMPACTED)" m2 \
  '{"type":"system","subtype":"Conversation_COMPACTED","content":"x"}'
blocked "a compaction summary entry (isCompactSummary) blocks it with no boundary line at all" m3 \
  '{"type":"user","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"This session is being continued from a previous conversation."}}'
blocked "a compactMetadata key alone blocks it (a boundary under a subtype nobody listed)" m3b \
  '{"type":"system","subtype":"context_reset","compactMetadata":{"trigger":"manual","preTokens":180000}}'
blocked "a tool result swapped for the clearing placeholder blocks it" m4 \
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_old","content":"[Old tool result content cleared]"}]}}'
blocked "an API context edit that cleared tool uses blocks it" m5 \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]},"context_management":{"applied_edits":[{"type":"clear_tool_uses_20250919","cleared_tool_uses":2,"cleared_input_tokens":9000}]}}'

transcript m6; reread m6 "" "$P1" "$A"
jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: "notes: \"subtype\":\"compact_boundary\", \"isCompactSummary\":true, \"content\":\"[Old tool result content cleared]\", \"type\":\"clear_tool_uses_20250919\", \"cleared_tool_uses\":3, compactMetadata"}]}}' >> "$TDIR/m6.jsonl"
reread m6 "" "$P1" "$A"
stub_for "$P1" "1-30" && ok "markers quoted inside a message's text are prose, not markers: the stub stands" || bad "quoted markers are prose" "out=$OUT"

transcript m7; ROOT="$(cat "$TDIR/m7.jsonl.last")"
reread m7 "" "$P1" "$A"
printf '{"parentUuid":"%s","type":"user","uuid":"branch-m7","message":{"role":"user","content":"a new prompt, sent after rewinding to before the read"}}\n' "$ROOT" >> "$TDIR/m7.jsonl"
printf 'branch-m7' > "$TDIR/m7.jsonl.last"                      # what follows the rewind chains on the new prompt
reread m7 "" "$P1" "$A"
passes_through && ok "a rewind (the newest entry no longer descends from the entry that carried the first read) blocks the stub" || bad "a rewind blocks the stub" "out=$OUT"
reread m7 "" "$P1" "$A"
stub_for "$P1" "1-30" && ok "and the read after the rewind is recorded afresh: the next one is stubbed" || bad "a read after a rewind is recorded afresh" "out=$OUT"

transcript m9
SEQ=$((SEQ + 1)); TUID="toolu_$SEQ"; grow "$TDIR/m9.jsonl" call "$TUID"; CALL="e$ENTRY"
fire "$CMD_READ" "$(payload m9 "" "$P1" "$A")"; grow "$TDIR/m9.jsonl" result "$TUID"
SEQ=$((SEQ + 1)); TUID="toolu_$SEQ"; grow "$TDIR/m9.jsonl" call "$TUID"
printf '{"parentUuid":"%s","type":"attachment","uuid":"att-m9","attachment":{"type":"hook_success"}}\n' "$CALL" >> "$TDIR/m9.jsonl"
fire "$CMD_READ" "$(payload m9 "" "$P1" "$A")"
stub_for "$P1" "1-30" && ok "a fork that is not a rewind (a result and an attachment off one assistant entry, the attachment newest) does not block it" || bad "a benign fork does not block the stub" "out=$OUT"

transcript m11
NOID="$(payload m11 "" "$P1" "$A" | jq -c 'del(.tool_use_id)')"
fire "$CMD_READ" "$NOID"; fire "$CMD_READ" "$NOID"
passes_through && ok "a payload with no tool_use_id never stubs (its read cannot be found in the transcript)" || bad "no tool_use_id never stubs" "out=$OUT"
transcript m12; TUID="toolu_ghost"
fire "$CMD_READ" "$(payload m12 "" "$P1" "$A")"; fire "$CMD_READ" "$(payload m12 "" "$P1" "$A")"
passes_through && ok "a read whose tool call is nowhere in the transcript never stubs (the chain cannot be walked)" || bad "an unknown tool call never stubs" "out=$OUT"

echo "12. outline"
# pybody N -- a python module of N lines made of 6-line functions fn_1, fn_2, ...: every line carries its function's number
pybody() {
  awk -v n="$1" 'BEGIN { for (i = 1; i <= int(n / 6) + 1; i++) printf "def fn_%d(x):\n    y = x + %d\n    z = y * 2 + %d\n    if z > %d:\n        return z - %d\n    return y + %d\n", i, i, i, i * 10, i, i }' | head -n "$1"
}
# shbody N M -- a shell script of N functions of M lines each
shbody() {
  awk -v n="$1" -v m="$2" 'BEGIN { for (i = 1; i <= n; i++) { printf "fn_%d() {\n", i; for (j = 1; j <= m - 2; j++) printf "  echo step %d of %d\n", j, i; print "}" } }'
}
outlined() {
  printf '%s' "$OUT" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and .hookSpecificOutput.updatedToolOutput.type == "text"
    and (.hookSpecificOutput.updatedToolOutput.file.content | contains("[hmd read-outline:"))' >/dev/null 2>&1
}
out_content() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedToolOutput.file.content'; }
BIGPY="/work/src/big.py"
PYBIG="$(pybody 702)"                          # 117 functions
SHBIG="$(shbody 12 50)"                        # 600 lines, 12 functions
H100="$(printf '%s\n' "$PYBIG" | head -n 100)"
L101="$(printf '%s\n' "$PYBIG" | sed -n 101p)"
transcript o1; WHOLE=1
reread o1 ag1 "$BIGPY" "$PYBIG"
if [ "$RC" = 0 ] && outlined; then ok "an unsliced Read of a 702-line python file by a subagent is answered with its head and outline"
else bad "an unsliced Read of a 702-line python file by a subagent is outlined" "rc=$RC out=$(printf '%.200s' "$OUT")"; fi
C1="$(out_content)"
case "$C1" in "$H100"*) ok "the head is the file's first 100 lines, verbatim" ;; *) bad "the head is the first 100 lines" "got: $(printf '%.120s' "$C1")" ;; esac
case "$C1" in *"$L101"*) bad "line 101 is not in what the model gets" ;; *) ok "line 101 is not in what the model gets (the rest is reached with offset/limit)" ;; esac
case "$C1" in *"[hmd read-outline: $BIGPY has 702 lines;"*"Read again with offset/limit, or Read with limit 100000 for the whole file]"*) ok "the note names the file and its length and says exactly how to get the whole text" ;;
  *) bad "the note says how to get the whole text" "got: $C1" ;; esac
case "$C1" in *"1-6 function fn_1"*"475-480 function fn_80"*"+37 more symbols"*) ok "the outline lists span, kind and name, capped at 80, the rest counted" ;; *) bad "the outline lists spans, kinds and names" "got: $C1" ;; esac
case "$C1" in *"fn_81"*) bad "nothing past the cap is listed" ;; *) ok "nothing past the cap is listed" ;; esac
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.updatedToolOutput.file | .totalLines == 702 and .startLine == 1 and .filePath == "'"$BIGPY"'"
    and (.content | length) < '"${#PYBIG}"' and .numLines == (.content | split("\n") | length)' >/dev/null 2>&1; then
  ok "the Read result shape is kept: totalLines survives, numLines counts the lines now returned, and the text is shorter"
else bad "the Read result shape is kept" "out=$(printf '%.300s' "$OUT")"; fi
reread o1 ag1 "$BIGPY" "$PYBIG"
passes_through && ok "the second plain Read of that file gets the whole file (an outline is never repeated: no trap)" || bad "the second plain Read gets the whole file" "out=$(printf '%.200s' "$OUT")"
reread o1 ag1 "$BIGPY" "$PYBIG"
stub_for "$BIGPY" "1-702" && ok "the whole file read after the outline is what dedup remembers: the third plain Read is its stub" || bad "dedup takes over after the whole file" "out=$(printf '%.200s' "$OUT")"

reread o1 ag1 /work/src/slice.py "$PYBIG" 1 700
passes_through && ok "a slice (offset/limit) of a big file is never outlined" || bad "a slice is never outlined" "out=$(printf '%.200s' "$OUT")"
reread o1 "" /work/src/mainthread.py "$PYBIG"
passes_through && ok "the main thread is never outlined" || bad "the main thread is never outlined" "out=$(printf '%.200s' "$OUT")"
reread o1 ag1 /work/src/at500.py "$(pybody 500)"
passes_through && ok "a 500-line file is not over the threshold: it comes whole" || bad "a 500-line file comes whole" "out=$(printf '%.200s' "$OUT")"
reread o1 ag1 /work/src/at501.py "$(pybody 501)"
outlined && ok "a 501-line file is over it: outlined" || bad "a 501-line file is outlined" "out=$(printf '%.200s' "$OUT")"
reread o1 ag1 /work/src/big.ts "$(body ts 700)"
passes_through && ok "a language the symbol graph does not index (.ts) comes whole" || bad "an unindexed language comes whole" "out=$(printf '%.200s' "$OUT")"
reread o1 ag1 /work/docs/big.md "$(body md 700)"
passes_through && ok "a non-code file (.md) comes whole" || bad "a non-code file comes whole" "out=$(printf '%.200s' "$OUT")"
reread o1 ag1 /work/src/broken.py "$(printf '%s\ndef broken(:\n' "$PYBIG")"
passes_through && ok "a python file that does not parse has no outline: it comes whole (fail open)" || bad "an unparsable file comes whole" "out=$(printf '%.200s' "$OUT")"
reread o1 ag1 /work/test/big.test.sh "$SHBIG"
passes_through && ok "a test file (a script under test/) is not outlined" || bad "a test file is not outlined" "out=$(printf '%.200s' "$OUT")"
reread o1 ag1 /work/fixtures/big.py "$PYBIG"
passes_through && ok "a path under fixtures/ is not outlined" || bad "fixtures/ is not outlined" "out=$(printf '%.200s' "$OUT")"
FEW="$(awk 'BEGIN { print "def a():\n    return 1\n\ndef b():\n    return 2"; for (i = 1; i <= 600; i++) printf "x_%d = %d\n", i, i }')"
reread o1 ag1 /work/src/flat.py "$FEW"
passes_through && ok "a file with under 3 symbols has nothing to navigate by: it comes whole" || bad "a file with few symbols comes whole" "out=$(printf '%.200s' "$OUT")"
reread o1 ag1 /work/bin/tool.sh "$SHBIG"
if outlined; then case "$(out_content)" in *"1-50 function fn_1"*"551-600 function fn_12"*) ok "a 600-line shell file is outlined (the graph's shell extractor: kind function, true spans)" ;; *) bad "a shell file's outline" "got: $(out_content)" ;; esac
else bad "a 600-line shell file is outlined" "out=$(printf '%.200s' "$OUT")"; fi
reread o1 ag1 /work/bin/heimdall-tool "$(printf '#!/usr/bin/env bash\n%s' "$SHBIG")"
outlined && ok "an extensionless executable is read as the graph reads it, by its shebang" || bad "a shebang file is outlined" "out=$(printf '%.200s' "$OUT")"
reread o1 ag1 /work/bin/plain-tool "$SHBIG"
passes_through && ok "an extensionless file with no shebang is not a language the graph knows: whole" || bad "no shebang, no outline" "out=$(printf '%.200s' "$OUT")"
WHOLE=0
reread o1 ag1 /work/src/cut.py "$PYBIG"
passes_through && ok "a Read cut short (fewer lines returned than the file has) is left alone: the outline would miss the end" || bad "a cut Read is left alone" "out=$(printf '%.200s' "$OUT")"
WHOLE=1

transcript o2; ENVX=(HMD_READ_OUTLINE=off)
reread o2 ag1 "$BIGPY" "$PYBIG"
passes_through && ok "HMD_READ_OUTLINE=off: no outline" || bad "HMD_READ_OUTLINE=off: no outline" "out=$(printf '%.200s' "$OUT")"
reread o2 ag1 "$BIGPY" "$PYBIG"
stub_for "$BIGPY" "1-702" && ok "HMD_READ_OUTLINE=off leaves dedup on: the second whole read is stubbed" || bad "HMD_READ_OUTLINE=off leaves dedup on" "out=$(printf '%.200s' "$OUT")"
transcript o3; ENVX=(HMD_READ_DEDUP=off)
reread o3 ag1 "$BIGPY" "$PYBIG"
passes_through && [ ! -e "$STATE/o3.ag1.json" ] && ok "HMD_READ_DEDUP=off, the hook's own switch, turns the outline off too: whole, nothing recorded" || bad "HMD_READ_DEDUP=off turns the whole hook off" "out=$(printf '%.200s' "$OUT")"
ENVX=()

transcript o4
reread o4 ag1 "$BIGPY" "$PYBIG"
fire "$CMD_COMPACT" "$(jq -cn --arg sid o4 --arg tp "$TDIR/o4.jsonl" '{session_id: $sid, transcript_path: $tp, cwd: "/work", hook_event_name: "PreCompact", trigger: "auto", custom_instructions: null}')"
reread o4 ag1 "$BIGPY" "$PYBIG"
outlined && ok "after a compaction cleared the session the file is outlined again (the first outline left context too)" || bad "outlined again after a compaction" "out=$(printf '%.200s' "$OUT")"
if grep -rqF "$BIGPY" "$STATE" 2>/dev/null; then bad "the outline mark is a hash: a path was stored"; else ok "the outline mark is a hash: not even the path is stored"; fi
WHOLE=0

finish
