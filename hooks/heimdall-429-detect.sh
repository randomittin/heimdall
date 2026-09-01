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
[ -n "$match_ts" ] || exit 0

"$MARK_BIN" mark --reason "$safe_event-transcript-429" >/dev/null 2>&1 || true
exit 0
