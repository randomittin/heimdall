#!/usr/bin/env bash
# hmd-claude-retry.sh — retry-with-backoff wrapper for headless `claude -p` spawns.
#
# THE GAP IT CLOSES. When Heimdall's autonomous work spawns `claude -p` and the Anthropic
# API returns `529 Overloaded` (or Claude Code exhausts its OWN retries and exits non-zero
# still showing "529 Overloaded · Retrying 7/10"), the naive call site did
# `output=$(claude -p … 2>&1) || true` — the `|| true` swallowed the failure and the
# overloaded spawn's ERROR TEXT became "output", so the task silently produced garbage.
# This wrapper backs off + retries a transient overload, and on exhaustion returns a LOUD,
# distinct, non-silent failure so the caller marks the task FAILED — never fake output.
#
# THE DISCRIMINATION (the whole point):
#   * OVERLOAD  = claude exited NON-ZERO *and* its output carries an overload marker
#                 (529 / overloaded / 429 / rate limit / "Retrying …" / "attempt N/M").
#                 -> retryable: exponential backoff + jitter, capped, bounded attempts.
#   * REAL error = claude exited non-zero with NO overload marker (bad prompt, auth, …).
#                 -> NOT retried. Fail fast, propagate claude's real exit code. Never mask
#                    a real error as transient.
#   * SUCCESS   = claude exited 0. Return its stdout verbatim (stderr progress banners are
#                 captured internally, NOT merged into the returned output). Never retried.
#
# WHY exit-code-gated (not marker-alone): claude's live retry banner is written to stderr
# WHILE it recovers; a run that ultimately SUCCEEDS exits 0 with the real answer on stdout.
# Retrying only on (non-zero exit AND marker) means a recovered run is returned as success,
# and a genuinely-overloaded run (non-zero + banner) is retried — no false-positive reruns.
#
# USAGE:
#   source "…/bin/lib/hmd-claude-retry.sh"
#   out=$(hmd_claude_retry -p "$prompt" --model "$MODEL" --output-format text) || rc=$?
#     -> on rc 0: $out is claude's stdout. on rc = $HMD_OVERLOAD_EXIT (75): overloaded,
#        gave up (mark FAILED). on any other rc: claude's own real error (fail fast).
#   Or run directly: hmd-claude-retry.sh -p "$prompt" --model …   (transparent claude proxy)
#
# ENV / OVERRIDES (backoff params overridable so tests run fast, e.g. BASE=0):
#   HMD_OVERLOAD_MAX_ATTEMPTS   max attempts incl. the first (default 6).
#   HMD_OVERLOAD_BASE_SECS      backoff base seconds (default 5; 0 = no wait, for tests).
#   HMD_OVERLOAD_CAP_SECS       backoff cap seconds  (default 120).
#   HMD_OVERLOAD_EXIT           exit code returned on give-up (default 75 = EX_TEMPFAIL).
#   HMD_CLAUDE_BIN              claude binary to invoke (default `claude`). TEST seam.
#   HMD_OVERLOAD_LOG            log file (default $HEIMDALL_HOME/overload-heal.log).
#   HEIMDALL_HOME               state home (default ~/.heimdall).

# double-source guard (functions are idempotent; skip re-defining on re-source).
[ -n "${_HMD_CLAUDE_RETRY_SH:-}" ] && return 0 2>/dev/null || true
_HMD_CLAUDE_RETRY_SH=1

: "${HEIMDALL_HOME:=$HOME/.heimdall}"
: "${HMD_OVERLOAD_LOG:=$HEIMDALL_HOME/overload-heal.log}"
: "${HMD_OVERLOAD_EXIT:=75}"

# one-line, secret-free, best-effort: append to the heal log AND mirror to stderr.
_hmd_overload_log() {
  mkdir -p "$(dirname "$HMD_OVERLOAD_LOG")" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo now)" "$*" \
    >> "$HMD_OVERLOAD_LOG" 2>/dev/null || true
  printf '[hmd-overload] %s\n' "$*" >&2
}

# retryable-overload marker present in claude's output? (case-insensitive)
_hmd_is_overload_text() {
  printf '%s' "$1" | grep -qiE \
    '529|overloaded(_error)?|too many requests|429|rate.?limit|retrying( in)?|attempt[[:space:]]+[0-9]+/[0-9]+'
}

# hmd_claude_retry <claude-args…> — invoke claude, retry transient overload with
# exponential backoff + jitter, fail fast on a real error, give up loudly on exhaustion.
hmd_claude_retry() {
  local bin="${HMD_CLAUDE_BIN:-claude}"
  local max="${HMD_OVERLOAD_MAX_ATTEMPTS:-6}"
  local base="${HMD_OVERLOAD_BASE_SECS:-5}"
  local cap="${HMD_OVERLOAD_CAP_SECS:-120}"
  local attempt=1 out err rc combined delay shift jitter total=0
  local errfile
  errfile="$(mktemp 2>/dev/null || echo "/tmp/hmd-claude-retry.$$.err")"

  while : ; do
    # capture stdout and stderr SEPARATELY: stdout is the real answer we return on
    # success; stderr holds progress/retry banners used only for overload detection.
    out="$("$bin" "$@" 2>"$errfile")"; rc=$?
    err="$(cat "$errfile" 2>/dev/null || true)"
    combined="$out
$err"

    if [ "$rc" -eq 0 ]; then
      [ "$attempt" -gt 1 ] && _hmd_overload_log \
        "recovered: claude succeeded on attempt ${attempt}/${max} after ${total}s of backoff"
      rm -f "$errfile" 2>/dev/null || true
      printf '%s\n' "$out"
      return 0
    fi

    # non-zero exit. overload iff a marker is present; otherwise a REAL error -> fail fast.
    if ! _hmd_is_overload_text "$combined"; then
      [ "$attempt" -gt 1 ] && _hmd_overload_log \
        "non-overload error after ${attempt} attempt(s); not retrying (claude exit ${rc})"
      rm -f "$errfile" 2>/dev/null || true
      printf '%s\n' "$out"
      [ -n "$err" ] && printf '%s\n' "$err" >&2
      return "$rc"
    fi

    # overload confirmed. budget exhausted? -> loud, distinct, non-silent give-up.
    if [ "$attempt" -ge "$max" ]; then
      _hmd_overload_log \
        "GAVE UP: claude overloaded — gave up after ${attempt} attempts over ${total}s; task NOT completed (claude exit ${rc})"
      printf 'hmd-claude-retry: claude overloaded — gave up after %s attempts over %ss; task NOT completed\n' \
        "$attempt" "$total" >&2
      rm -f "$errfile" 2>/dev/null || true
      return "$HMD_OVERLOAD_EXIT"
    fi

    # exponential backoff: base * 2^(attempt-1), capped, + [0,base) jitter (anti-herd).
    shift=$((attempt - 1)); [ "$shift" -gt 20 ] && shift=20
    delay=$(( base * (1 << shift) ))
    [ "$delay" -gt "$cap" ] && delay="$cap"
    jitter=0; [ "$base" -gt 0 ] && jitter=$(( RANDOM % base ))
    delay=$(( delay + jitter ))
    _hmd_overload_log \
      "overload detected (claude exit ${rc}) on attempt ${attempt}/${max}; backoff ${delay}s; will-retry"
    sleep "$delay" 2>/dev/null || true
    total=$(( total + delay ))
    attempt=$(( attempt + 1 ))
  done
}

# CLI mode: when executed directly (not sourced), act as a transparent retrying `claude`.
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  hmd_claude_retry "$@"
  exit $?
fi
