#!/usr/bin/env bash
# heimdall-429-detect.sh -- mechanical HTTP-429/rate-limit detector wired to
# SubagentStop and Stop, closing the gap documented in
# docs/analysis/2026-08-29-fallback-did-not-fire-rootcause.md and
# .planning/skills/subagent-stop-delivery-scope.md: an in-process Agent-tool
# spawn's 429 reaches the ORCHESTRATOR only as a task-notification, never a
# hook, so nothing ever called bin/heimdall-429-mark's reactive marker for
# that path. Every fix upstream of this (PHASE 1-4 in
# bin/heimdall-session-usage, bin/heimdall-fallback's PHASE-4 read) already
# existed and already worked; only the WRITE side was missing. This file is
# the write side.
#
# THE SIGNAL, CONFIRMED BEFORE WRITING A LINE HERE (task brief
# brief-1788288873-84149's own Step 1 instruction -- do not build on an
# unconfirmed field). SubagentStop's and Stop's TOP-LEVEL payload fields
# carry no stop-reason/error-type/failure field of any kind -- confirmed
# against the official hooks reference (bin/heimdall-metric-hook's own
# header) and independently against this repo's 2026-08-25 hook-delivery
# spike (docs/analysis/2026-08-25-hook-delivery-spike.md Finding 2's
# "important caveat": last_assistant_message/stop_hook_active look IDENTICAL
# for a killed vs. a clean subagent -- presence of the hook is not evidence
# of success, absence of an error field is not evidence of failure). The one
# field that DOES carry evidence is a TRANSCRIPT PATH --
# agent_transcript_path (SubagentStop) or transcript_path (Stop) -- and
# Claude Code itself writes a stable, structural JSONL record into that
# transcript whenever a model call fails:
#   {"isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,...}
# proven real and abundant by direct corpus measurement, twice
# independently: docs/analysis/2026-08-25-transcript-529-detection.md (52
# real rate_limit/429 records out of 72 total API-error records, across this
# repo's own ~/.claude/projects/<slug>/*.jsonl), and again freshly here
# (2026-09-02) against this exact session's own transcript: 35+ further
# rate_limit/429 records spanning 2026-08-18 through 2026-09-01. That same
# fresh check also proved WHY this hook must read the SUBAGENT's own
# transcript, never the orchestrator's: the specific incident brief
# brief-1788288873-84149 quotes (request id req_011Ced53KtrwE3RzhyFjkZA7)
# exists in the orchestrator's own transcript ONLY as prose inside a
# task-notification string -- zero matches for that request id among that
# same file's own isApiErrorMessage records. The raw structured record
# lives in the DYING entity's own transcript -- agent_transcript_path /
# transcript_path -- never the parent's.
#
# NEVER A HEURISTIC. Matches ONLY the closed, structural triple
# (isApiErrorMessage==true AND error=="rate_limit" AND apiErrorStatus==429).
# Never a text/regex match on prose -- the sibling 2026-08-25 investigation
# measured a naive text search producing 162 false positives and zero true
# positives against this exact corpus -- and never any other `error` value:
# server_error/529/502 and oauth_org_not_allowed/403 are deliberately NOT
# rate-limit signals and must never mark (mirrors bin/heimdall-529-scan's own
# deliberate exclusion of rate_limit from ITS classification -- the two
# tools are each other's photographic negative, on purpose).
#
# RECENCY-BOUNDED, on purpose. A transcript can be long-lived; an old,
# already-recovered-from 429 sitting in history must never re-mark a session
# stopping now for an unrelated reason. Only a record whose own `timestamp`
# falls within HMD_429_DETECT_WINDOW_SECS (default 300s, mirrors
# bin/heimdall-529-scan's DEFAULT_WINDOW_SECS) of THIS hook's firing time
# counts. Age math runs entirely inside jq (`now`, `fromdateiso8601`) rather
# than shelling out to the system `date` binary, which forked GNU vs. BSD
# behavior right when this repo needs it to be boring and portable.
#
# NEVER REIMPLEMENTS THE MARKER. Calls bin/heimdall-429-mark mark --reason
# ... exactly as it already exists (TTL-bounded, atomic-write, fail-open) --
# read that tool's own header before touching this one.
#
# FAILS OPEN, ALWAYS. Every guard below falls through to a silent `exit 0`
# the moment it cannot PROVE a fresh, genuine rate_limit/429 record exists:
# no jq, no mark binary, no transcript path, an unreadable/missing
# transcript, malformed JSON, a structurally-wrong or stale record. Never
# marks on ambiguous evidence -- a false positive here routes real traffic
# to a local model (see bin/lib/hmd-route-claude's HMD_JUDGMENT=1 pin, which
# this hook must never weaken and does not touch).
#
# /bin/sh HAZARD: hooks run where `echo` can expand escapes -- always
# `printf '%s'` into jq, never `echo` (test/gate-echo-parser-guard.test.sh).
set -uo pipefail

SELF="$0"
if command -v readlink >/dev/null 2>&1; then
  SELF="$(readlink -f "$0" 2>/dev/null || readlink "$0" 2>/dev/null || echo "$0")"
fi
HOOKS_DIR="$(cd "$(dirname "$SELF")" && pwd)"
PLUGIN_DIR="$(cd "$HOOKS_DIR/.." && pwd)"
MARK_BIN="${HMD_429_MARK_BIN:-$PLUGIN_DIR/bin/heimdall-429-mark}"

REPO="${CLAUDE_PROJECT_DIR:-.}"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-$REPO}"; shift 2 ;;
    *) shift ;;
  esac
done
[ -d "$REPO" ] || exit 0

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
[ -x "$MARK_BIN" ] || exit 0

# Prefer SubagentStop's own field name; fall back to Stop's -- the same
# dual-field-name fallback bin/heimdall-claim-check already uses for the
# same two events (there the fields are last_assistant_message/
# transcript_path; here they are agent_transcript_path/transcript_path).
transcript_path="$(printf '%s' "$input" | jq -r '.agent_transcript_path // empty' 2>/dev/null || true)"
if [ -z "$transcript_path" ]; then
  transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
fi
# MEASURED 2026-09-02: SubagentStop does NOT fire when a subagent dies from
# a 429. Three real 429 deaths this session; .planning/metrics.jsonl (written
# by the SubagentStop metric handler) shows ZERO subagentstop rows at any of
# them. So the SubagentStop path above is real but never reached for THIS
# failure mode -- the detector was dead-on-arrival for its own purpose.
#
# The orchestrator's Stop hook DOES fire. But the parent transcript carries a
# 429 only as PROSE inside a task-notification string -- zero structural
# matches. The structural record lives solely in the dead SUBAGENT's own
# transcript, under <tmp>/<slug>/<session>/tasks/<agentId>.output.
#
# So on the Stop path we additionally scan sibling task transcripts. Bounded
# three ways so this can never become an unbounded scan on every turn:
#   - only files MODIFIED within the same recency window,
#   - at most HMD_429_DETECT_MAX_SIBLINGS files (newest first),
#   - the same bounded-tail read per file as the primary path.
# Fails open exactly like everything else here: any error yields no marker.
sibling_paths=""
if [ -z "$(printf '%s' "$input" | jq -r '.agent_transcript_path // empty' 2>/dev/null || true)" ]; then
  _win="${HMD_429_DETECT_WINDOW_SECS:-300}"
  case "$_win" in ''|*[!0-9]*) _win=300 ;; esac
  _max="${HMD_429_DETECT_MAX_SIBLINGS:-12}"
  case "$_max" in ''|*[!0-9]*) _max=12 ;; esac
  _mins=$(( (_win + 59) / 60 )); [ "$_mins" -ge 1 ] || _mins=1
  _tdir="${HMD_429_DETECT_TASKS_DIR:-}"
  _tdir_list=()
  if [ -n "$_tdir" ]; then
    # Explicit override: honor it exactly, never widen it, never fall
    # through to auto-discovery if it doesn't exist -- matches the old
    # behavior of this branch precisely.
    [ -d "$_tdir" ] && _tdir_list=("$_tdir")
  elif [ -n "$transcript_path" ]; then
    # Auto-discovery. Two independent, MEASURED bugs fixed together here
    # (2026-09-05, against the real req_011Cei32DAJf4WeXHXtwfENa incident) --
    # fixing only one leaves this dead-on-arrival for the other reason:
    #   1. Every real Task/Agent-tool sibling .output is a SYMLINK to the
    #      persistent transcript, never a regular file (`ls -la` on a live
    #      tasks/ dir: 12/12 agent-id-named .output entries were lrwxr-xr-x
    #      symlinks, 0 were regular files) -- `-type f` alone (no -L) uses
    #      lstat() and excludes every single one of them, unconditionally.
    #   2. The tmp-dir folder that actually holds a run's tasks/ dir does
    #      NOT reliably share a name with "$_sess" (transcript_path's own
    #      basename) -- confirmed directly against the real incident: the
    #      folder holding the dying subagent's sibling .output had no
    #      corresponding persisted .jsonl transcript AT ALL under that same
    #      name, while the JSONL records' own sessionId and the real
    #      persisted transcript filename both read a DIFFERENT id entirely.
    #      Only the repo/project slug is stable; the run/session-id segment
    #      must be wildcarded, and every match collected -- never just the
    #      first, never `break` on an exact-name guess that may not exist.
    _repo_abs="$(cd "$REPO" 2>/dev/null && pwd || true)"
    if [ -n "$_repo_abs" ]; then
      _slug="$(printf '%s' "$_repo_abs" | tr '/' '-')"
      for _c in "${TMPDIR:-/tmp}"/claude-*/"$_slug"/*/tasks /private/tmp/claude-*/"$_slug"/*/tasks; do
        [ -d "$_c" ] && _tdir_list+=("$_c")
      done
    fi
  fi
  if [ "${#_tdir_list[@]}" -gt 0 ]; then
    sibling_paths="$(find -L "${_tdir_list[@]}" -maxdepth 1 -type f -name '*.output' -mmin "-${_mins}" 2>/dev/null | sort -u | head -n "$_max" || true)"
  fi
fi

[ -n "$transcript_path" ] || exit 0
[ -f "$transcript_path" ] || exit 0
[ -r "$transcript_path" ] || exit 0

event_name="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
[ -n "$event_name" ] || event_name="hook"
safe_event="$(printf '%s' "$event_name" | tr -c 'A-Za-z0-9_-' '-' | tr '[:upper:]' '[:lower:]')"
[ -n "$safe_event" ] || safe_event="hook"

window_secs="${HMD_429_DETECT_WINDOW_SECS:-300}"
case "$window_secs" in ''|*[!0-9]*) window_secs=300 ;; esac

tail_bytes="${HMD_429_DETECT_TRANSCRIPT_TAIL_BYTES:-262144}"
case "$tail_bytes" in ''|*[!0-9]*) tail_bytes=262144 ;; esac

# Bounded-tail read, structural-only match, recency-bounded. try/catch
# discards any single malformed line without aborting the whole scan.
match_ts="$(tail -c "$tail_bytes" "$transcript_path" 2>/dev/null \
  | jq -R -r --argjson window "$window_secs" '
      try (
        (. | fromjson) as $r
        | select($r.isApiErrorMessage == true and $r.error == "rate_limit" and $r.apiErrorStatus == 429)
        | ($r.timestamp // empty) as $ts
        | select($ts != "")
        | ($ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $ts_epoch
        | (now - $ts_epoch) as $age
        | select($age >= 0 and $age <= $window)
        | $ts
      ) catch empty
    ' 2>/dev/null | tail -1 || true)"
# Primary path found nothing -- try the bounded sibling set (Stop path only).
if [ -z "$match_ts" ] && [ -n "$sibling_paths" ]; then
  for _sp in $sibling_paths; do
    [ -f "$_sp" ] && [ -r "$_sp" ] || continue
    match_ts="$(tail -c "$tail_bytes" "$_sp" 2>/dev/null \
      | jq -R -r --argjson window "$window_secs" '
          try (
            (. | fromjson) as $r
            | select($r.isApiErrorMessage == true and $r.error == "rate_limit" and $r.apiErrorStatus == 429)
            | ($r.timestamp // empty) as $ts
            | select($ts != "")
            | ($ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $ts_epoch
            | (now - $ts_epoch) as $age
            | select($age >= 0 and $age <= $window)
            | $ts
          ) catch empty
        ' 2>/dev/null | tail -1 || true)"
    if [ -n "$match_ts" ]; then safe_event="${safe_event}-sibling"; break; fi
  done
fi

[ -n "$match_ts" ] || exit 0

"$MARK_BIN" mark --reason "$safe_event-transcript-429" >/dev/null 2>&1 || true
exit 0
