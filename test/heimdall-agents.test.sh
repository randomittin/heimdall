#!/usr/bin/env bash
# test/heimdall-agents.test.sh — falsifiable acceptance for bin/heimdall-agents.
#
# The tool's whole value is an HONEST live-subagent count: a dead/stale/failed/
# finished harness subagent must NOT be counted as live, and reaping must be
# idempotent so the count never drifts. Every assertion here is built to CATCH the
# tool lying.
#
# WHY THE ccc FIXTURE CHANGED ─────────────────────────────────────────────────
# ccc's "terminal" signal used to be a sibling ccc.status file. The harness NEVER
# writes .status files (`find /private/tmp/claude-501 -name '*.status'` -> 0 hits
# across ~50 session dirs holding 50 .output files), so that branch was unreachable
# in production and the old fixture tested a fiction. ccc keeps its exact ROLE here
# — fresh-but-terminal must not count as live, and must reap with reason=failed —
# but the signal is now the REAL one: a <status>failed</status> task-notification in
# the parent session transcript. Every original assertion survives; only the
# fixture's source of truth became truthful.
#
#   PART A fixture — task dir with 3 <id>.output files + a base transcript:
#     aaa  fresh (age << threshold), no transcript record        -> LIVE
#     bbb  stale (age >> threshold)                              -> STALE
#     ccc  fresh BUT a transcript notification says failed       -> FAILED
#          (terminal beats freshness — a failed-but-recent subagent is NOT live)
#
#   PART A assertions:
#     (1) list classifies aaa=live, bbb=stale, ccc=failed.
#     (2) count == 1 (ONLY the fresh live one). FALSIFIER: if a stale or failed
#         subagent is counted live, count != 1 and this fails.
#     (3) reap records the stale + failed ones (2 records).
#     (4) after reap: count STILL 1 and list shows bbb + ccc as "reaped".
#     (5) a SECOND reap is an idempotent no-op. FALSIFIER: if reap re-records an
#         already-reaped id, this fails.
#
#   PART B fixture — transcript-derived truth (its own dir + registry):
#     ddd  fresh BUT notified <status>completed</status>          -> DONE (not live)
#     eee  fresh, unnamed spawn, never notified                   -> LIVE
#     fff  fresh, notified, then WROTE AGAIN after the notify     -> LIVE (resumed)
#     ghost-agent  named spawn, never notified, no .output at all -> MAILBOX
#          (the zombie class: named spawns become persistent mailbox agents that
#           never self-terminate and never notify — measured 103 named spawns with
#           1 notified, vs 209 unnamed with 183 notified)
#
#   PART C — fail-closed degradation:
#     staleness still classifies with NO transcript; a missing transcript, a
#     directory-as-transcript, and a garbage/unparseable transcript all exit 0 and
#     never crash.
#
# Hermetic: HMD_AGENT_TASKDIR points the tool at the fixture (no real harness dir
# needed); HMD_AGENT_TRANSCRIPT points it at a synthetic .jsonl; HMD_AGENT_REAPED_FILE
# isolates the registry to a throwaway file (never touches ~/.heimdall); HMD_NOW pins
# "now" so staleness is deterministic.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AGENTS="$ROOT/bin/heimdall-agents"

[ -x "$AGENTS" ] || { echo "FATAL: $AGENTS not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-agents-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TASKDIR="$WORK/tasks"; mkdir -p "$TASKDIR"
REAPED="$WORK/agents-reaped.json"

# Deterministic clock + threshold.
NOW=2000000000
export HMD_NOW="$NOW"
export HMD_AGENT_STALE_SECS=900
export HMD_AGENT_TASKDIR="$TASKDIR"
export HMD_AGENT_REAPED_FILE="$REAPED"

# Portable mtime setter: GNU (touch -d @epoch) first, BSD (date -r → touch -t) fallback.
set_mtime() {
  local f="$1" e="$2" ts
  touch -d "@$e" "$f" 2>/dev/null && return 0
  ts="$(date -r "$e" +%Y%m%d%H%M.%S 2>/dev/null)" || return 1
  touch -t "$ts" "$f"
}

# Portable epoch → ISO8601 Z (the timestamp format harness records carry).
iso_of() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# ── synthetic transcript writers (mirror the REAL harness record shapes) ─────
# Notification: a `user` record whose content is a STRING carrying the task-id +
# status. Shape verified against production transcripts.
notif_line() { # $1=task-id $2=status $3=epoch
  local body
  body="<task-notification>\\n<task-id>$1</task-id>\\n<tool-use-id>toolu_for_$1</tool-use-id>\\n<output-file>/tmp/tasks/$1.output</output-file>\\n<status>$2</status>\\n<summary>Agent finished</summary>\\n</task-notification>"
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"%s"}}\n' \
    "$(iso_of "$3")" "$body"
}

# Spawn: an `assistant` record with a tool_use block named "Agent". A `name` in the
# input is what makes the harness create a persistent MAILBOX agent.
spawn_line() { # $1=tool_use id $2=name-or-empty $3=epoch
  local input
  if [ -n "$2" ]; then
    input="{\"description\":\"d\",\"prompt\":\"p\",\"name\":\"$2\"}"
  else
    input="{\"description\":\"d\",\"prompt\":\"p\"}"
  fi
  printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"Agent","input":%s}]}}\n' \
    "$(iso_of "$3")" "$1" "$input"
}

# Spawn tool_result: named spawns return `agent_id: <name>@session-x` (a mailbox
# handle, NOT a task-id); unnamed spawns return `agentId: <task-id>` (hex).
result_line() { # $1=tool_use id $2=agent-id-text $3=mailbox|async
  local txt
  if [ "$3" = "mailbox" ]; then
    txt="Spawned successfully.\\nagent_id: $2\\nname: $2\\nThe agent is now running and will receive instructions via mailbox."
  else
    txt="Async agent launched successfully.\\nagentId: $2 (internal ID)"
  fi
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"%s"}]}}\n' \
    "$(iso_of "$NOW")" "$1" "$txt"
}

state_of() { "$AGENTS" list --json | jq -r --arg id "$1" '.[]|select(.id==$id)|.state'; }

# ══ PART A — original acceptance, with ccc's signal re-sourced to the real one ══
: > "$TASKDIR/aaa.output"; set_mtime "$TASKDIR/aaa.output" $((NOW - 10))    # live
: > "$TASKDIR/bbb.output"; set_mtime "$TASKDIR/bbb.output" $((NOW - 5000))  # stale
: > "$TASKDIR/ccc.output"; set_mtime "$TASKDIR/ccc.output" $((NOW - 10))    # fresh...

BASE_TR="$WORK/base.jsonl"
# ccc notified as FAILED at NOW-5, i.e. AFTER its last write (NOW-10) -> terminal.
notif_line ccc failed $((NOW - 5)) > "$BASE_TR"
export HMD_AGENT_TRANSCRIPT="$BASE_TR"

# ── (1) classification ────────────────────────────────────────────────────────
[ "$(state_of aaa)" = "live"   ] && ok "aaa classified live"   || bad "aaa not live (got '$(state_of aaa)')"
[ "$(state_of bbb)" = "stale"  ] && ok "bbb classified stale"  || bad "bbb not stale (got '$(state_of bbb)')"
[ "$(state_of ccc)" = "failed" ] && ok "ccc classified failed" || bad "ccc not failed (got '$(state_of ccc)')"

# ── (2) count is LIVE-only ────────────────────────────────────────────────────
C="$("$AGENTS" count)"
[ "$C" = "1" ] && ok "count==1 (live only; stale+failed excluded)" || bad "count expected 1, got '$C'"

# ── (3) reap records the stale + failed ones ──────────────────────────────────
"$AGENTS" reap >/dev/null
RN="$(jq 'keys|length' "$REAPED" 2>/dev/null)"
[ "$RN" = "2" ] && ok "reap recorded 2 (stale+failed)" || bad "reaped registry has $RN keys, expected 2"
[ "$(jq -r '.bbb.reason' "$REAPED")" = "stale"  ] && ok "bbb recorded reason=stale"  || bad "bbb reason wrong"
[ "$(jq -r '.ccc.reason' "$REAPED")" = "failed" ] && ok "ccc recorded reason=failed" || bad "ccc reason wrong"

# ── (4) post-reap: count still 1; reaped ones show state=reaped ───────────────
C2="$("$AGENTS" count)"
[ "$C2" = "1" ] && ok "post-reap count STILL 1 (live untouched)" || bad "post-reap count expected 1, got '$C2'"
[ "$(state_of bbb)" = "reaped" ] && ok "bbb now shows reaped" || bad "bbb not reaped (got '$(state_of bbb)')"
[ "$(state_of ccc)" = "reaped" ] && ok "ccc now shows reaped" || bad "ccc not reaped (got '$(state_of ccc)')"
[ "$(state_of aaa)" = "live"   ] && ok "aaa still live"       || bad "aaa no longer live (got '$(state_of aaa)')"

# ── (5) idempotency: a second reap records NOTHING new ───────────────────────
J2="$("$AGENTS" reap --json)"
[ "$J2" = "[]" ] && ok "second reap is idempotent no-op" || bad "second reap not idempotent (got '$J2')"
RN2="$(jq 'keys|length' "$REAPED" 2>/dev/null)"
[ "$RN2" = "2" ] && ok "registry still exactly 2 after re-reap" || bad "registry drifted to $RN2 keys"

# ── fail-closed: an absent task dir → count 0, never a crash ──────────────────
CZERO="$(HMD_AGENT_TASKDIR="$WORK/does-not-exist" HMD_AGENT_TRANSCRIPT="$WORK/none.jsonl" "$AGENTS" count)"
[ "$CZERO" = "0" ] && ok "absent task dir → count 0 (fail-closed)" || bad "absent task dir count expected 0, got '$CZERO'"

# ══ PART B — transcript-derived truth: done / mailbox / resumed ═══════════════
echo
BDIR="$WORK/b/tasks"; mkdir -p "$BDIR"
BTR="$WORK/b.jsonl"
BREAPED="$WORK/b-reaped.json"

: > "$BDIR/ddd.output"; set_mtime "$BDIR/ddd.output" $((NOW - 20))   # fresh, notified done
: > "$BDIR/eee.output"; set_mtime "$BDIR/eee.output" $((NOW - 20))   # fresh, never notified
: > "$BDIR/fff.output"; set_mtime "$BDIR/fff.output" $((NOW - 5))    # wrote AFTER its notify

{
  notif_line ddd completed $((NOW - 10))
  spawn_line toolu_ddd "" $((NOW - 40))
  result_line toolu_ddd ddd async
  spawn_line toolu_eee "" $((NOW - 30))
  result_line toolu_eee eee async
  notif_line fff completed $((NOW - 60))
  # the zombie: a NAMED spawn, never notified, with no .output file anywhere
  spawn_line toolu_ghost ghost-agent $((NOW - 100))
  result_line toolu_ghost "ghost-agent@session-abc" mailbox
} > "$BTR"

export HMD_AGENT_TASKDIR="$BDIR"
export HMD_AGENT_TRANSCRIPT="$BTR"
export HMD_AGENT_REAPED_FILE="$BREAPED"

[ "$(state_of ddd)" = "done" ] && ok "ddd notified completed → done (not live)" || bad "ddd expected done, got '$(state_of ddd)'"
[ "$(state_of eee)" = "live" ] && ok "eee unnamed+recent+unnotified → live"     || bad "eee expected live, got '$(state_of eee)'"
[ "$(state_of fff)" = "live" ] && ok "fff wrote after notify → live (resumed)"  || bad "fff expected live, got '$(state_of fff)'"

# the mailbox zombie is keyed by its handle, NOT a task-id (it has none)
MB_STATE="$("$AGENTS" list --json | jq -r '.[]|select(.name=="ghost-agent")|.state')"
[ "$MB_STATE" = "mailbox" ] && ok "named spawn → mailbox state" || bad "ghost-agent expected mailbox, got '$MB_STATE'"

# count excludes done AND mailbox: only eee + fff are live
CB="$("$AGENTS" count)"
[ "$CB" = "2" ] && ok "count==2 (done+mailbox excluded, resumed counted)" || bad "count expected 2, got '$CB'"

# orphans surfaces ONLY the mailbox agents, with their names
ORPH="$("$AGENTS" orphans --json)"
ON="$(printf '%s' "$ORPH" | jq -r '.[]|.name' | tr '\n' ' ' | sed 's/ *$//')"
[ "$ON" = "ghost-agent" ] && ok "orphans lists ONLY ghost-agent" || bad "orphans names expected 'ghost-agent', got '$ON'"
OC="$(printf '%s' "$ORPH" | jq 'length')"
[ "$OC" = "1" ] && ok "orphans count==1 (no task-dir rows leak in)" || bad "orphans length expected 1, got '$OC'"
ORPH_TXT="$("$AGENTS" orphans)"
case "$ORPH_TXT" in *ghost-agent*) ok "orphans plain text names the agent" ;; *) bad "orphans text missing name: '$ORPH_TXT'" ;; esac

# reap treats done + mailbox as reapable, leaves the live ones alone
"$AGENTS" reap >/dev/null
[ "$(jq -r '.ddd.reason' "$BREAPED")" = "done" ] && ok "reap recorded ddd reason=done" || bad "ddd reap reason wrong: $(jq -r '.ddd.reason' "$BREAPED")"
MBKEY="$(jq -r 'to_entries[]|select(.value.reason=="mailbox")|.key' "$BREAPED" 2>/dev/null)"
[ -n "$MBKEY" ] && ok "reap recorded the mailbox zombie ($MBKEY)" || bad "mailbox zombie not reaped"
CB2="$("$AGENTS" count)"
[ "$CB2" = "2" ] && ok "post-reap count STILL 2 (live untouched)" || bad "post-reap count expected 2, got '$CB2'"

# ══ PART C — fail-closed degradation without transcript truth ════════════════
echo
CDIR="$WORK/c/tasks"; mkdir -p "$CDIR"
: > "$CDIR/ggg.output"; set_mtime "$CDIR/ggg.output" $((NOW - 9000))  # stale
: > "$CDIR/hhh.output"; set_mtime "$CDIR/hhh.output" $((NOW - 30))    # live
export HMD_AGENT_TASKDIR="$CDIR"
export HMD_AGENT_REAPED_FILE="$WORK/c-reaped.json"

# (no transcript at all — the tool must fall back to pure staleness)
CNO="$(unset HMD_AGENT_TRANSCRIPT; "$AGENTS" count)"
[ "$CNO" = "1" ] && ok "no transcript → staleness still works (count 1)" || bad "no-transcript count expected 1, got '$CNO'"
SNO="$(unset HMD_AGENT_TRANSCRIPT; "$AGENTS" list --json | jq -r '.[]|select(.id=="ggg")|.state')"
[ "$SNO" = "stale" ] && ok "no transcript → ggg still stale" || bad "no-transcript ggg expected stale, got '$SNO'"

# missing transcript path → exit 0, no crash
export HMD_AGENT_TRANSCRIPT="$WORK/definitely-not-here.jsonl"
CMISS="$("$AGENTS" count)"; RC=$?
[ "$RC" = "0" ] && [ "$CMISS" = "1" ] && ok "missing transcript degrades gracefully (exit 0, count 1)" || bad "missing transcript rc=$RC count='$CMISS'"

# garbage / unparseable transcript → exit 0, no crash, still classifies by age
GARB="$WORK/garbage.jsonl"
printf 'not json at all\n{"broken":\nbinary junk \001\002\n{"type":"user","message":{"content":123}}\n{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent"}]}}\n' > "$GARB"
export HMD_AGENT_TRANSCRIPT="$GARB"
CGARB="$("$AGENTS" count)"; RC2=$?
[ "$RC2" = "0" ] && [ "$CGARB" = "1" ] && ok "garbage transcript degrades gracefully (exit 0, count 1)" || bad "garbage transcript rc=$RC2 count='$CGARB'"
LGARB="$("$AGENTS" list --json | jq -r 'length')"
[ "$LGARB" = "2" ] && ok "garbage transcript still lists both task rows" || bad "garbage transcript list length expected 2, got '$LGARB'"

# a transcript path that is a DIRECTORY (not a readable file) → exit 0
mkdir -p "$WORK/dir.jsonl"
export HMD_AGENT_TRANSCRIPT="$WORK/dir.jsonl"
CDIRTR="$("$AGENTS" count)"; RC3=$?
[ "$RC3" = "0" ] && [ "$CDIRTR" = "1" ] && ok "directory-as-transcript degrades gracefully" || bad "dir transcript rc=$RC3 count='$CDIRTR'"

# orphans with no mailbox agents → empty, exit 0
unset HMD_AGENT_TRANSCRIPT
OEMPTY="$("$AGENTS" orphans --json)"; RC4=$?
[ "$RC4" = "0" ] && [ "$OEMPTY" = "[]" ] && ok "orphans with none → [] (exit 0)" || bad "orphans empty expected [], rc=$RC4 got '$OEMPTY'"

echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
