#!/usr/bin/env bash
# session-liveness.sh — IS THIS CLAUDE SESSION STILL ALIVE?  One implementation.
#
# WHY THIS FILE EXISTS
# --------------------
# Two callers now need the same answer:
#
#   1. bin/heimdall-agents   — "may I reap this subagent?" (reaping a LIVE agent
#                              destroys work in flight)
#   2. bin/heimdall-conformance — "is this dirty worktree ABANDONED, or is an
#                              agent still typing into it?" (flagging a live
#                              agent for not having committed yet is a false
#                              accusation, and a conformance check that cries
#                              wolf gets muted — which is the disease the whole
#                              adherence-gate effort exists to cure)
#
# Both questions are the SAME question, and a second copy of the answer would be
# free to drift from the first. PROTOCOL.md already names this pattern as the
# house fix (bin/lib/brief-core.sh, shared by bin/heimdall-brief and
# sentinels/lib/brief.sh, "so the two entry points cannot drift into disagreeing
# about what counts as resolved"). This is that, for liveness.
#
# EVIDENCE ORDER MATTERS — and it is not the obvious one.
# MEASURED 2026-08-03 (recorded in the bin/heimdall-agents header): `pgrep -x
# claude` returned two pids whose cwds pointed at other repos, and the heimdall
# session that was ACTUALLY RUNNING AT THAT MOMENT appeared in neither. Deciding
# from the process table alone therefore produces false "dead" verdicts. So:
#
#   tier 1  explicit override (HMD_AGENT_LIVE_SLUGS, if DEFINED even when empty)
#   tier 2  the session transcript's mtime — the harness appends to it
#           continuously while the session runs, so a fresh mtime is direct,
#           read-only, unspoofable-by-accident evidence of life
#   tier 3  the process table (pgrep -x claude -> lsof cwd -> slug), cached
#
# FAIL DIRECTION: every tier fails toward "ALIVE". A false "alive" costs one
# unreaped agent / one unreported worktree; a false "dead" costs destroyed work
# or a wrong accusation. The asymmetry is deliberate.
#
# ENV (identical names to bin/heimdall-agents, so the knobs a caller already
# knows keep working):
#   HMD_AGENT_PROJECTS_DIR       override ~/.claude/projects (tests)
#   HMD_AGENT_SESSION_LIVE_SECS  transcript freshness window (default 900)
#   HMD_AGENT_STALE_SECS         default for the above when it is unset
#   HMD_AGENT_LIVE_SLUGS         if DEFINED (even empty), the verbatim list of
#                                live project slugs; no process probing at all
#   HMD_NOW                      override "now" epoch seconds (deterministic tests)
#
# Sourcing is side-effect free apart from defining functions and reading env.
# It sets no shell options and runs no command that can fail the caller.

# ── config, resolved at source time ───────────────────────────────────────────
_hmd_live_stale="${HMD_AGENT_STALE_SECS:-}"
case "$_hmd_live_stale" in ''|*[!0-9]*) _hmd_live_stale=900 ;; esac
HMD_LIVE_SECS="${HMD_AGENT_SESSION_LIVE_SECS:-}"
case "$HMD_LIVE_SECS" in ''|*[!0-9]*) HMD_LIVE_SECS="$_hmd_live_stale" ;; esac
unset _hmd_live_stale
HMD_LIVE_PROJECTS="${HMD_AGENT_PROJECTS_DIR:-${HOME:-}/.claude/projects}"

# ── portable mtime (follow symlink -> the transcript's real last-activity) ─────
# The .output entries in the task dir are symlinks to the transcript; -L makes
# both spellings of the same file agree.
hmd_live_mtime() {
  stat -L -f%m "$1" 2>/dev/null || stat -L -c%Y "$1" 2>/dev/null || echo 0
}

# "now", overridable so tests can pin an epoch instead of sleeping.
hmd_live_now() {
  local n="${HMD_NOW:-}"
  case "$n" in ''|*[!0-9]*) date +%s ;; *) printf '%s' "$n" ;; esac
}

# ── the Claude projects slug ──────────────────────────────────────────────────
# Every non-alphanumeric char -> '-'. This mirrors the harness's own naming, so
# we resolve the SAME directory it writes to.
hmd_live_slug_for_cwd() {
  local s="$1"
  printf '%s' "${s//[^A-Za-z0-9]/-}"
}

# ── tier 3: the process table, probed lazily and cached ───────────────────────
# Deliberately CONSERVATIVE: if ANY live claude process maps to the slug, every
# agent under it is treated as possibly-alive. Probing costs a pgrep + one lsof
# per pid, so it happens once per process and only when tiers 1-2 came up empty.
_HMD_LIVE_SLUGS=""
_HMD_LIVE_SLUGS_LOADED=""
hmd_live_slugs() {
  if [ -n "$_HMD_LIVE_SLUGS_LOADED" ]; then printf '%s' "$_HMD_LIVE_SLUGS"; return 0; fi
  _HMD_LIVE_SLUGS_LOADED=1
  if [ "${HMD_AGENT_LIVE_SLUGS+defined}" = "defined" ]; then
    # Test/explicit override: use verbatim, never probe the real process table.
    _HMD_LIVE_SLUGS=" $(printf '%s' "$HMD_AGENT_LIVE_SLUGS" | tr '\n' ' ') "
    printf '%s' "$_HMD_LIVE_SLUGS"; return 0
  fi
  local pid cwd acc=""
  for pid in $(pgrep -x claude 2>/dev/null); do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    cwd="$(lsof -p "$pid" 2>/dev/null | awk '$4=="cwd"{print $NF; exit}')"
    [ -n "$cwd" ] || continue
    acc="$acc $(hmd_live_slug_for_cwd "$cwd")"
  done
  _HMD_LIVE_SLUGS=" ${acc# } "
  printf '%s' "$_HMD_LIVE_SLUGS"
}

# ── tier 2: a session's own transcript ────────────────────────────────────────
# hmd_live_transcript <slug> <session>
hmd_live_transcript() {
  local slug="$1" sess="$2"
  [ -n "$slug" ] && [ -n "$sess" ] || return 0
  printf '%s' "$HMD_LIVE_PROJECTS/$slug/$sess.jsonl"
}

# ── the verdict ───────────────────────────────────────────────────────────────
# hmd_session_is_alive <slug> [session]   -> 0 alive, 1 not
hmd_session_is_alive() {
  local slug="$1" sess="${2:-}" f mt now
  [ -n "$slug" ] || return 1
  # Explicit override (hermetic tests / callers that already know) wins outright.
  if [ "${HMD_AGENT_LIVE_SLUGS+defined}" = "defined" ]; then
    case "$(hmd_live_slugs)" in *" $slug "*) return 0 ;; esac
    return 1
  fi
  if [ -n "$sess" ]; then
    f="$(hmd_live_transcript "$slug" "$sess")"
    if [ -n "$f" ] && [ -f "$f" ]; then
      mt="$(hmd_live_mtime "$f")"
      now="$(hmd_live_now)"
      if [ $(( now - mt )) -lt "$HMD_LIVE_SECS" ] 2>/dev/null; then return 0; fi
    fi
  fi
  case "$(hmd_live_slugs)" in *" $slug "*) return 0 ;; esac
  return 1
}

# ── a SUBAGENT's liveness, by task id ─────────────────────────────────────────
# A subagent does not get a top-level transcript. Its own transcript lives at
#   <projects>/<parent-slug>/<parent-session>/subagents/agent-<id>.jsonl
# and the harness appends to THAT while the subagent works. The parent session
# may be idle while the child is mid-tool-call, so the child's file is the
# closer evidence and is consulted first.
#
# hmd_subagent_transcript <task-id>  -> newest matching transcript path, or ""
hmd_subagent_transcript() {
  local id="$1" t best="" best_mt=-1 mt
  [ -n "$id" ] || return 0
  for t in "$HMD_LIVE_PROJECTS"/*/*/subagents/"agent-$id.jsonl"; do
    [ -f "$t" ] || continue
    mt="$(hmd_live_mtime "$t")"
    if [ "$mt" -gt "$best_mt" ] 2>/dev/null; then best_mt="$mt"; best="$t"; fi
  done
  printf '%s' "$best"
}

# hmd_subagent_is_alive <task-id>  -> 0 alive, 1 not
# NON_VERIFIED is NOT expressible here on purpose: "no transcript found" is
# returned as ALIVE (0) by the caller's choice below, because an id we cannot
# resolve is an id we have no evidence about, and this file fails toward alive.
# Callers that need to distinguish "no evidence" from "fresh evidence" should
# call hmd_subagent_transcript and inspect the empty string themselves.
hmd_subagent_is_alive() {
  local id="$1" t mt now
  t="$(hmd_subagent_transcript "$id")"
  [ -n "$t" ] || return 0          # no evidence -> fail toward alive
  mt="$(hmd_live_mtime "$t")"
  now="$(hmd_live_now)"
  [ $(( now - mt )) -lt "$HMD_LIVE_SECS" ] 2>/dev/null
}
