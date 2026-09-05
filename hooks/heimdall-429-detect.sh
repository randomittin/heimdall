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
# STRUCTURAL-FIRST, ALWAYS. Tier 1 (primary transcript) and Tier 2 (sibling
# task-output files) match ONLY the closed, structural triple
# (isApiErrorMessage==true AND error=="rate_limit" AND apiErrorStatus==429).
# Never a text/regex match on prose -- the sibling 2026-08-25 investigation
# measured a naive text search producing 162 false positives and zero true
# positives against this exact corpus -- and never any other `error` value:
# server_error/529/502 and oauth_org_not_allowed/403 are deliberately NOT
# rate-limit signals and must never mark (mirrors bin/heimdall-529-scan's own
# deliberate exclusion of rate_limit from ITS classification -- the two
# tools are each other's photographic negative, on purpose).
#
# TIER 3 IS THE ONE EXCEPTION, AND IT IS NOT THAT NAIVE SEARCH. Measured
# 2026-09-06 across seven real subagent-death 429s: none left a structural
# record ANYWHERE (not the subagent's own transcript, not a sibling
# task-output file) -- the only trace was PROSE inside a queue-operation
# task-notification's <summary>, in the ORCHESTRATOR's own Stop-triggered
# transcript (180 accumulated occurrences confirmed via a direct grep
# against a real session jsonl). Tier 3 below (Stop path only) scans for
# that prose, but the classification decision is never a bash/jq substring
# match -- it runs through the SAME conservative, two-signal (anchor phrase
# AND wall-clock reset clause) bin/lib/quota_stop.py classifier every other
# quota-detection tool in this repo already uses, never a second
# implementation of it. A bare "hit your ... limit" substring alone, or a
# 529/overload string, still never marks -- see the Tier 3 block for the
# recency and classification gates that make this true.
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

# --- Diagnostic tracing ---------------------------------------------------
# THE OPEN QUESTION this file cannot otherwise answer: does Stop/SubagentStop
# actually fire when a subagent dies to a 429? Every guard below has been
# verified by driving this script directly with a constructed payload --
# none of that proves the MECHANISM runs in a real session. One line per
# invocation, appended below, is the only thing that can distinguish, from
# OUTSIDE this process, the three cases that otherwise look identical: hook
# never invoked (no trace line at all), hook invoked but found nothing (line
# present, outcome=no-match or skipped-<why>), hook invoked and marked (line
# present, outcome=marked).
#
# DEFAULT ON -- a deliberate reversal of the naive opt-in default. This exact
# defect has failed eight times in production, and this repo's own operator
# was told twice it was fixed and was wrong both times, because "the logic is
# correct" was mistaken for "the mechanism runs". An operator who has to
# remember to set a flag BEFORE an unpredictable 429 will, with very high
# probability, still have nothing to look at after failure #9 -- that is the
# exact failure mode an opt-in default reproduces. Disable with
# HMD_429_DETECT_TRACE=0. The write costs one small bounded append per
# Stop/SubagentStop call, guarded exactly like every other guard in this
# file: fails open, never blocks, never throws, and does not depend on jq --
# so it still fires in the exact scenario ("jq unavailable") that is one of
# the specific outcomes this trace exists to distinguish.
#
# BOUNDED, always. HMD_429_DETECT_TRACE_MAX_BYTES (default 256KiB) caps
# growth: once exceeded, the file is trimmed to its own last half before the
# new line lands -- the same bounded-tail philosophy this file already
# applies to transcript reads (HMD_429_DETECT_TRANSCRIPT_TAIL_BYTES above),
# so a long-lived, noisy session can never turn this into unbounded disk
# growth.
#
# NEVER VIA jq -- built with printf alone. Every embedded field is either a
# fixed-vocabulary literal this script writes itself, an integer counter, or
# a value already sanitized through the same `tr 'A-Za-z0-9_-'` transform
# safe_event uses below -- so this needs no generic JSON escaping, and it
# still works when jq itself is the thing missing.
#
# NEVER changes the hook's own exit code or control flow: trace_emit runs
# only via `trap ... EXIT`, strictly AFTER the real detection logic (mark or
# no-mark) has already completed, and its own body always resolves to a
# successful return regardless of what it encounters internally.
_trace_enabled=1
[ "${HMD_429_DETECT_TRACE:-}" = "0" ] && _trace_enabled=0
_trace_file="${HMD_429_DETECT_TRACE_FILE:-${HEIMDALL_HOME:-$HOME/.heimdall}/429-detect-trace.jsonl}"
_trace_had_agent_tp="null"
_trace_had_tp="null"
_trace_tier1_examined=0
_trace_tier2_examined=0
_trace_tier3_examined=0
_trace_outcome="unknown"
_trace_detail=""
_trace_event_name=""

trace_emit() {
  [ "$_trace_enabled" = "1" ] || return 0
  {
    _trace_dir="$(dirname "$_trace_file" 2>/dev/null || true)"
    [ -n "$_trace_dir" ] && mkdir -p "$_trace_dir" 2>/dev/null
    _trace_max_bytes="${HMD_429_DETECT_TRACE_MAX_BYTES:-262144}"
    case "$_trace_max_bytes" in ''|*[!0-9]*) _trace_max_bytes=262144 ;; esac
    if [ -f "$_trace_file" ]; then
      _trace_sz="$(wc -c < "$_trace_file" 2>/dev/null | tr -d ' ')"
      case "$_trace_sz" in ''|*[!0-9]*) _trace_sz=0 ;; esac
      if [ "$_trace_sz" -gt "$_trace_max_bytes" ]; then
        _trace_half=$(( _trace_max_bytes / 2 ))
        tail -c "$_trace_half" "$_trace_file" > "$_trace_file.trim.$$" 2>/dev/null \
          && mv "$_trace_file.trim.$$" "$_trace_file" 2>/dev/null
        rm -f "$_trace_file.trim.$$" 2>/dev/null
      fi
    fi
    _trace_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    printf '{"ts":"%s","hook_event_name":"%s","had_agent_transcript_path":%s,"had_transcript_path":%s,"tier1_examined":%s,"tier2_examined":%s,"tier3_examined":%s,"outcome":"%s","detail":"%s"}\n' \
      "$_trace_ts" "$_trace_event_name" "$_trace_had_agent_tp" "$_trace_had_tp" \
      "$_trace_tier1_examined" "$_trace_tier2_examined" "$_trace_tier3_examined" \
      "$_trace_outcome" "$_trace_detail" >> "$_trace_file" 2>/dev/null
  } 2>/dev/null || true
  return 0
}
trap 'trace_emit' EXIT
# --- end diagnostic tracing header; state updates continue inline below ---

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
[ -d "$REPO" ] || { _trace_outcome="skipped-no-repo-dir"; exit 0; }

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || { _trace_outcome="skipped-empty-input"; exit 0; }
command -v jq >/dev/null 2>&1 || { _trace_outcome="skipped-no-jq"; exit 0; }
[ -x "$MARK_BIN" ] || { _trace_outcome="skipped-no-mark-bin"; exit 0; }

_trace_v="$(printf '%s' "$input" | jq -r 'if (.agent_transcript_path // "") != "" then "true" else "false" end' 2>/dev/null || true)"
case "$_trace_v" in true|false) _trace_had_agent_tp="$_trace_v" ;; esac
_trace_v="$(printf '%s' "$input" | jq -r 'if (.transcript_path // "") != "" then "true" else "false" end' 2>/dev/null || true)"
case "$_trace_v" in true|false) _trace_had_tp="$_trace_v" ;; esac

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
# The orchestrator's Stop hook DOES fire. RE-CHECKED FRESH (2026-09-05,
# incident req_011CejtBFAa4za5rx5wou8FP), not inherited: the parent transcript
# is NOT universally prose-only -- it also accumulates genuine structural
# isApiErrorMessage records of its OWN direct API calls (this session's own
# parent transcript held 46 of them, spanning 2026-08-18 through the
# present), so the primary scan above already catches a 429 that hits the
# top-level agent directly. What the parent NEVER carries structurally is a
# 429 that killed a Task/Agent-tool SUBAGENT -- that surfaces in the parent
# only as PROSE inside a task-notification string (confirmed again directly
# against req_011CejtBFAa4za5rx5wou8FP: present as a task-notification's
# summary text in the parent, absent from every one of that same file's own
# isApiErrorMessage records). The structural record for THAT death lives
# solely in the dying SUBAGENT's own transcript, which Claude Code persists
# at a location derivable with CERTAINTY from transcript_path alone -- no
# guessing required:
#   <dirname transcript_path>/<basename transcript_path .jsonl>/subagents/agent-<agentId>.jsonl
# (confirmed directly: req_011CejtBFAa4za5rx5wou8FP's own structural record
# lives at exactly that path, sibling agent-ad5c54bf1ae335de3.jsonl, under
# this same session's own subagents/ dir). This is the PREFERRED sibling
# source below -- a stable parent/child directory relationship, not a
# wildcarded guess -- tried before the legacy <tmp>/<slug>/<session>/tasks/
# location, which needed two rounds of real bug fixes (symlink-following,
# repo-slug-wildcarded run-id discovery) and may still not exist on every
# setup.
#
# So on the Stop path we scan sibling transcripts from BOTH sources, bounded
# four ways so this can never become an unbounded scan on every turn:
#   - only files MODIFIED within the same recency window,
#   - at most HMD_429_DETECT_MAX_SIBLINGS files per source (newest first for
#     the preferred source -- see below for why lexical order is not safe
#     here),
#   - the same bounded-tail read per file as the primary path,
#   - preferred-source candidates are gathered before legacy ones, but BOTH
#     are always gathered -- only a genuine MATCH (found by the shared scan
#     loop further down) ends the search, never merely finding candidates.
# Fails open exactly like everything else here: any error yields no marker.
sibling_paths=""
if [ -z "$(printf '%s' "$input" | jq -r '.agent_transcript_path // empty' 2>/dev/null || true)" ]; then
  _win="${HMD_429_DETECT_WINDOW_SECS:-300}"
  case "$_win" in ''|*[!0-9]*) _win=300 ;; esac
  _max="${HMD_429_DETECT_MAX_SIBLINGS:-12}"
  case "$_max" in ''|*[!0-9]*) _max=12 ;; esac
  _mins=$(( (_win + 59) / 60 )); [ "$_mins" -ge 1 ] || _mins=1

  # PREFERRED source: ~/.claude/projects/<slug>/<session>/subagents/*.jsonl,
  # derived directly from transcript_path's own dirname/basename above.
  # NEWEST-FIRST (ls -t), never lexical: this directory accumulates across a
  # session's ENTIRE lifetime -- a live production subagents/ dir was
  # measured directly holding 600+ files -- unlike the legacy tasks/ dir
  # below, which is bounded to one run. A lexical sort-then-cap could
  # silently drop the one fresh file a busy parallel wave (this repo's own
  # mandatory spawn-many-agents-at-once convention, and exactly the shape a
  # shared rate limit kills several siblings under at once) produces
  # alongside hundreds of older, unrelated files.
  _pref=""
  if [ -n "$transcript_path" ]; then
    _sess_dir="$(dirname "$transcript_path" 2>/dev/null || true)"
    _sess_base="$(basename "$transcript_path" .jsonl 2>/dev/null || true)"
    if [ -n "$_sess_dir" ] && [ -n "$_sess_base" ]; then
      _subagents_dir="$_sess_dir/$_sess_base/subagents"
      if [ -d "$_subagents_dir" ]; then
        _found="$(find -L "$_subagents_dir" -maxdepth 1 -type f -name '*.jsonl' -mmin "-${_mins}" 2>/dev/null || true)"
        if [ -n "$_found" ]; then
          _pref="$(printf '%s\n' "$_found" | xargs ls -1t -- 2>/dev/null | head -n "$_max" || true)"
        fi
      fi
    fi
  fi

  # SECONDARY/legacy source, always also gathered regardless of whether the
  # preferred source above found candidate FILES (a genuine MATCH is what
  # ends the search, decided later by the shared scan loop -- not this
  # discovery step): <tmp>/<slug>/<session-run-id>/tasks/<agentId>.output.
  _legacy=""
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
    _legacy="$(find -L "${_tdir_list[@]}" -maxdepth 1 -type f -name '*.output' -mmin "-${_mins}" 2>/dev/null | sort -u | head -n "$_max" || true)"
  fi

  # Preferred first, legacy second -- the shared scan loop below tries every
  # candidate in order and stops at the first genuine structural match.
  if [ -n "$_pref" ] && [ -n "$_legacy" ]; then
    sibling_paths="$_pref
$_legacy"
  else
    sibling_paths="${_pref}${_legacy}"
  fi
fi

[ -n "$transcript_path" ] || exit 0
[ -f "$transcript_path" ] || exit 0
[ -r "$transcript_path" ] || exit 0

event_name="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
[ -n "$event_name" ] || event_name="hook"
safe_event="$(printf '%s' "$event_name" | tr -c 'A-Za-z0-9_-' '-' | tr '[:upper:]' '[:lower:]')"
[ -n "$safe_event" ] || safe_event="hook"
_trace_event_name="$safe_event"

window_secs="${HMD_429_DETECT_WINDOW_SECS:-300}"
case "$window_secs" in ''|*[!0-9]*) window_secs=300 ;; esac

tail_bytes="${HMD_429_DETECT_TRANSCRIPT_TAIL_BYTES:-262144}"
case "$tail_bytes" in ''|*[!0-9]*) tail_bytes=262144 ;; esac

_trace_tier1_examined=1
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
    _trace_tier2_examined=$((_trace_tier2_examined + 1))
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

# Tier 3 (2026-09-06): the FINAL fallback -- scan for PROSE, never
# structural, evidence of a 429. See the TIER 3 header comment above for why
# this exists. Gated to the Stop path only (agent_transcript_path absent) --
# a SubagentStop's own transcript is the DYING agent's, which cannot
# structurally contain a task-notification about itself. Only runs at all
# when Tier 1 and Tier 2 found nothing ($match_ts still empty) -- this is
# strictly a last resort, never a parallel check.
#
# The raw (still JSON-encoded) line text is piped into quota_stop.py as-is:
# neither ANCHOR_RE nor RESET_RE need to span a JSON-escaped character, so
# this needs no per-field extraction and matches exactly how the
# 180-occurrence count above was itself confirmed (a literal grep against
# the raw transcript file).
#
# RECENCY IS EVERYTHING with 180 accumulated historical occurrences already
# sitting in a real transcript: each CANDIDATE LINE's OWN `timestamp` is
# checked against the identical jq age computation used twice above --
# never the hook's firing time alone, and never a bare substring match. A
# match without a fresh timestamp on that exact line never marks. Candidates
# are prefiltered by a cheap case-insensitive grep (never the actual
# classification decision -- that is quota_stop.py's job alone) and capped
# at HMD_429_DETECT_MAX_PROSE_LINES (default 20, newest last) so a long
# history of stale hits can never turn into an unbounded number of python
# invocations. Fails open exactly like everything else here: no python3, no
# readable quota_stop.py, or any parse error yields no marker.
if [ -z "$match_ts" ] && [ -z "$(printf '%s' "$input" | jq -r '.agent_transcript_path // empty' 2>/dev/null || true)" ]; then
  QUOTA_STOP_PY="${HMD_QUOTA_STOP_PY:-$PLUGIN_DIR/bin/lib/quota_stop.py}"
  PROSE_PY_BIN="$(command -v python3 2>/dev/null || true)"
  _prose_max="${HMD_429_DETECT_MAX_PROSE_LINES:-20}"
  case "$_prose_max" in ''|*[!0-9]*) _prose_max=20 ;; esac
  if [ -n "$PROSE_PY_BIN" ] && [ -r "$QUOTA_STOP_PY" ]; then
    _prose_candidates="$(tail -c "$tail_bytes" "$transcript_path" 2>/dev/null \
      | grep -a -i -F 'hit your' 2>/dev/null | tail -n "$_prose_max" || true)"
    if [ -n "$_prose_candidates" ]; then
      while IFS= read -r _prose_line; do
        [ -n "$_prose_line" ] || continue
        _trace_tier3_examined=$((_trace_tier3_examined + 1))
        _prose_ts="$(printf '%s' "$_prose_line" | jq -R -r --argjson window "$window_secs" '
            try (
              (. | fromjson) as $r
              | ($r.timestamp // empty) as $ts
              | select($ts != "")
              | ($ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $ts_epoch
              | (now - $ts_epoch) as $age
              | select($age >= 0 and $age <= $window)
              | $ts
            ) catch empty
          ' 2>/dev/null || true)"
        [ -n "$_prose_ts" ] || continue
        _prose_class="$(printf '%s' "$_prose_line" | "$PROSE_PY_BIN" "$QUOTA_STOP_PY" classify 2>/dev/null \
          | jq -r '.class // empty' 2>/dev/null || true)"
        if [ "$_prose_class" = "quota" ]; then
          match_ts="$_prose_ts"
          safe_event="${safe_event}-prose"
        fi
      done <<< "$_prose_candidates"
    fi
  fi
fi

[ -n "$match_ts" ] || exit 0

"$MARK_BIN" mark --reason "$safe_event-transcript-429" >/dev/null 2>&1 || true
exit 0
