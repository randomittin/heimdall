#!/usr/bin/env bash
# hmd-claude-mem-scrub.sh — C-1 fix: a summarizer/observer daemon must NEVER inherit a
# routing or fallback-credential var from whatever session happened to spawn it.
#
# THE LEAK (verified live, pid 88244). bin/heimdall-route exports ANTHROPIC_BASE_URL (and,
# on the fallback path, ANTHROPIC_AUTH_TOKEN) into the `claude` process it execs. claude-mem
# runs a long-lived DAEMON descendant (worker-service.cjs --daemon, PPID=1) that OUTLIVES the
# session that spawned it and calls a model to summarize transcripts — so it can carry a
# stale, routed value across every session afterward, including ones that are no longer
# fallback-routed themselves. hmd_gate_exec (hmd-gate-endpoint.sh) does not apply here:
# claude-mem is not a gate, and it is a third-party plugin hmd cannot edit.
#
# THE SEAM hmd owns: not claude-mem's code, but a NEW hook of hmd's own (wired in
# hooks.json — see the coder's final report for the exact entry, since that file is not
# edited from here) that inspects whatever claude-mem worker is ALREADY running via its own
# documented PID file (~/.claude-mem/worker.pid) and, if its LIVE environment is
# contaminated, restarts it — same argv, env scrubbed. An already-clean daemon, or no
# daemon at all, is left untouched.
#
# POLICY: the canonical _HMD_GATE_ROUTING_VARS list (sourced below, never re-typed) PLUS
# two credential-shaped vars that list deliberately excludes for judge calls, but that ARE
# part of this specific leak: ANTHROPIC_AUTH_TOKEN (how the OmniRoute fallback gateway
# authenticates — a summarizer has no legitimate reason to hold this) and ANTHROPIC_API_KEY
# (named explicitly in the finding this fixes). claude-mem's own real auth path (Claude
# Code's own OAuth/session credential) is untouched, exactly as hmd_gate_exec leaves
# CLAUDE_CODE_OAUTH_TOKEN untouched for judge calls — this scrub neutralizes ROUTING plus
# the one FALLBACK-scoped credential that can ride on it, never Claude Code's own auth.
#
# WHAT THIS DELIBERATELY DOES NOT DO: spawn a fresh daemon when none is running yet.
# Replicating claude-mem's own launch command (its hooks.json resolves a version-sorted
# plugin root via bun-runner.js) would duplicate fragile third-party logic that changes
# across claude-mem releases. A daemon that is not running yet has nothing live to leak,
# and the very next claude-mem hook invocation in an unrouted session spawns it clean on
# its own. This is a deliberate, disclosed scope limit: see the coder's final report for
# the residual gap it leaves open (a daemon FIRST spawned during an actively fallback-
# routed session, before this hook's next run, is contaminated until the next check) and
# why an automatic pre-emptive spawn was rejected — killing/restarting the SHARED daemon on
# every SessionStart risks interrupting a DIFFERENT, concurrently running session's
# in-flight summarization in this heavily parallel-agent codebase, so never touching an
# already-healthy daemon avoids that class of self-inflicted disruption.
#
# Covered by test/routing-var-scrub.test.sh.

[ -n "${_HMD_CLAUDE_MEM_SCRUB_SH:-}" ] && return 0 2>/dev/null || true
_HMD_CLAUDE_MEM_SCRUB_SH=1

_HMD_CM_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./hmd-gate-endpoint.sh
. "$_HMD_CM_SELF_DIR/hmd-gate-endpoint.sh"   # canonical _HMD_GATE_ROUTING_VARS — SOURCED, never duplicated

# Additive to the canonical list, never a replacement for it — see file header. A test
# fails if these ever collide with (rather than extend) _HMD_GATE_ROUTING_VARS.
_HMD_CM_EXTRA_SCRUB_VARS="ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY"

HMD_CLAUDE_MEM_PID_FILE="${HMD_CLAUDE_MEM_PID_FILE:-$HOME/.claude-mem/worker.pid}"
HMD_CLAUDE_MEM_LOG="${HMD_CLAUDE_MEM_LOG:-$HOME/.claude-mem/hmd-scrub-relaunch.log}"

# hmd_claude_mem_exec <cmd> [args…] — run CMD with the claude-mem summarizer policy
# applied: every canonical routing var unset, plus ANTHROPIC_AUTH_TOKEN/ANTHROPIC_API_KEY.
# Shape mirrors hmd_gate_exec (hmd-gate-endpoint.sh:75-84) exactly, but deliberately does
# NOT re-pin ANTHROPIC_BASE_URL to api.anthropic.com — a summarizer that loses its routing
# var should fall back to whatever default endpoint its own SDK ships with, not be
# redirected by hmd (hmd has no standing to decide claude-mem's default provider).
# Returns the command's own exit status verbatim.
hmd_claude_mem_exec() {
  [ "$#" -gt 0 ] || { echo "hmd_claude_mem_exec: no command given" >&2; return 2; }
  local unset_args=() var
  for var in $_HMD_GATE_ROUTING_VARS $_HMD_CM_EXTRA_SCRUB_VARS; do
    unset_args+=(-u "$var")
  done
  env "${unset_args[@]}" "$@"
}

# _hmd_cm_live_pid — echoes the live worker pid from its own documented PID file, or
# returns 1 if the file is absent/unreadable/unparsable or the pid it names is not alive.
_hmd_cm_live_pid() {
  local f="$HMD_CLAUDE_MEM_PID_FILE" pid
  [ -r "$f" ] || return 1
  pid="$(grep -o '"pid"[[:space:]]*:[[:space:]]*[0-9]\+' "$f" 2>/dev/null | grep -o '[0-9]\+' | head -1)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

# _hmd_cm_read_env <pid> — NAME=VALUE lines from the live process's own environment.
# macOS/BSD: `ps eww` (proven live on this host). Linux fallback: /proc/<pid>/environ.
# Empty OUTPUT (not just exit status) is the caller's signal that detection failed — a
# live process always has SOME env, so zero lines means "could not read", never "really
# has no env at all".
_hmd_cm_read_env() {
  local pid="$1"
  if ps eww "$pid" >/dev/null 2>&1; then
    ps eww "$pid" 2>/dev/null | tail -n +2 | tr ' ' '\n' | grep -E '^[A-Za-z_][A-Za-z0-9_]*='
  elif [ -r "/proc/$pid/environ" ]; then
    tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -E '^[A-Za-z_][A-Za-z0-9_]*='
  fi
}

# _hmd_cm_is_contaminated <pid> — true (0) if the live process's environment carries ANY
# scrub-policy var set to a non-empty value, OR if the environment could not be read at
# all. FAIL CLOSED: "cannot determine" scrubs; it never waves a process through as clean.
_hmd_cm_is_contaminated() {
  local pid="$1" dump var
  dump="$(_hmd_cm_read_env "$pid")"
  [ -n "$dump" ] || return 0   # unreadable -> fail closed -> treat as contaminated
  for var in $_HMD_GATE_ROUTING_VARS $_HMD_CM_EXTRA_SCRUB_VARS; do
    printf '%s\n' "$dump" | grep -q "^${var}=." && return 0
  done
  return 1
}

# _hmd_cm_kill_gracefully <pid> — SIGTERM, wait up to 5s, SIGKILL if still alive. Mirrors
# claude-mem's own worker-wrapper.cjs shutdown sequence (same SIGTERM -> wait -> SIGKILL
# shape: scripts/worker-wrapper.cjs's `d()`), so an externally issued restart behaves the
# way claude-mem's own supervisor would.
_hmd_cm_kill_gracefully() {
  local pid="$1" waited=0
  kill -TERM "$pid" 2>/dev/null || return 0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge 5 ]; then
      kill -KILL "$pid" 2>/dev/null
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

# hmd_claude_mem_scrub_if_contaminated — public entry point (wired from a SessionStart
# hook; see the coder's final report for the exact hooks.json entry). Checks the
# CURRENTLY live claude-mem worker only; never spawns one that is not already running
# (see file header for why). Exit codes:
#   0 = nothing to do (not running, or already clean)
#   1 = was contaminated; killed and relaunched with the scrub policy applied
hmd_claude_mem_scrub_if_contaminated() {
  local pid argv unset_args var
  pid="$(_hmd_cm_live_pid)" || { echo "hmd-claude-mem-scrub: worker not running, nothing to do" >&2; return 0; }

  if ! _hmd_cm_is_contaminated "$pid"; then
    echo "hmd-claude-mem-scrub: worker (pid $pid) environment is clean" >&2
    return 0
  fi

  argv="$(ps -p "$pid" -o command= 2>/dev/null)"
  if [ -z "$argv" ]; then
    echo "hmd-claude-mem-scrub: worker (pid $pid) looked contaminated but exited before its argv could be captured — nothing relaunched" >&2
    return 0
  fi

  echo "hmd-claude-mem-scrub: worker (pid $pid) environment carries a routing/fallback-credential var — restarting it clean" >&2
  _hmd_cm_kill_gracefully "$pid"

  unset_args=()
  for var in $_HMD_GATE_ROUTING_VARS $_HMD_CM_EXTRA_SCRUB_VARS; do
    unset_args+=(-u "$var")
  done
  mkdir -p "$(dirname "$HMD_CLAUDE_MEM_LOG")" 2>/dev/null || true
  # shellcheck disable=SC2086
  nohup env "${unset_args[@]}" sh -c "$argv" </dev/null >>"$HMD_CLAUDE_MEM_LOG" 2>&1 &
  disown 2>/dev/null || true
  echo "hmd-claude-mem-scrub: relaunched clean (previously pid $pid)" >&2
  return 1
}
