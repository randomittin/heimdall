#!/usr/bin/env bash
# test/read-dedup.test.sh
# budget: ~8s solo -- each case starts one bash + one python (~50 ms); no network, no claude.
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

# payload SESSION AGENT PATH CONTENT [OFFSET] [LIMIT] -- a Read's PostToolUse payload (AGENT empty = the main thread)
payload() {
  jq -cn --arg sid "$1" --arg agent "$2" --arg p "$3" --arg c "$4" --arg off "${5:-}" --arg lim "${6:-}" --arg tp "$TDIR/$1.jsonl" '
    ($c | split("\n") | length) as $n
    | {session_id: $sid, transcript_path: $tp, cwd: "/work", permission_mode: "default", hook_event_name: "PostToolUse",
       tool_name: "Read",
       tool_input: ({file_path: $p} + (if $off == "" then {} else {offset: ($off | tonumber)} end) + (if $lim == "" then {} else {limit: ($lim | tonumber)} end)),
       tool_response: {type: "text", file: {filePath: $p, content: $c, numLines: $n, startLine: (if $off == "" then 1 else ($off | tonumber) end), totalLines: ($n + 40)}},
       tool_use_id: "toolu_01abc", duration_ms: 4}
    + (if $agent == "" then {} else {agent_id: $agent, agent_type: "hmd:coder"} end)'
}
transcript() { mkdir -p "$TDIR/$1/subagents"; printf '{"type":"user","n":1}\n{"type":"assistant","n":2}\n' > "$TDIR/$1.jsonl"; }

# reread SESSION AGENT PATH CONTENT [OFFSET] [LIMIT] -- fire the Read hook with that payload
reread() { fire "$CMD_READ" "$(payload "$@")"; }
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

finish
