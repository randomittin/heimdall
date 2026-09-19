#!/usr/bin/env bash
# hmd-python.sh — resolve the interpreter hmd's hot-path scripts should use for JSON work.
#
# ── WHY THIS EXISTS, MEASURED ────────────────────────────────────────────────────────
# `python3` on PATH is frequently a version-manager SHIM (pyenv, asdf, mise). A shim is a
# script that re-execs the real interpreter after a version lookup, and hmd pays that cost
# on a per-hook basis rather than once. Measured on an idle machine, this one:
#
#   ~/.pyenv/shims/python3 -c pass    145 ms
#   /usr/bin/python3       -c pass     31 ms      -> a 114 ms tax, every call
#
# heimdall-ctx-meter runs on EVERY user prompt and parses the hook payload with it. The
# same call, changing nothing but which python3 resolves: 168 ms -> 63 ms. That is latency
# in front of the user's own turn, not background work.
#
# ── RESOLUTION ORDER, and why each step sits where it does ──────────────────────────
#   1. HMD_PYTHON            an operator or a test says which interpreter to use; it wins.
#   2. the cached path       written by a previous run under $HEIMDALL_HOME, revalidated
#                            with one -x test so a removed interpreter cannot be served
#                            from cache. This is what keeps the probe in step 3 from
#                            running once per hook invocation.
#   3. /usr/bin/python3      present and non-shim on macOS and every mainstream Linux. It
#                            is PROBED, never assumed: on a Mac without Command Line Tools
#                            that path exists but is a stub that prompts instead of
#                            running, so it only wins if `-c pass` actually succeeds.
#   4. `command -v python3`  the previous behaviour, unchanged. A machine with no
#                            /usr/bin/python3 ends up exactly where it was before.
#
# ABSENCE IS A SUPPORTED ANSWER. Printing nothing means "no python here", and every caller
# in this repo already has a jq fallback for exactly that case. This file never installs
# anything, never writes outside $HEIMDALL_HOME, and never fails a caller.

[ -n "${_HMD_PYTHON_SH:-}" ] && return 0 2>/dev/null || true
_HMD_PYTHON_SH=1

# Resolved once per process. Hooks are short-lived processes, so this saves the repeated
# probes WITHIN one hook (heimdall-ctx-meter makes three JSON calls per prompt); the
# on-disk cache below is what saves the probe ACROSS processes.
_HMD_PYTHON_RESOLVED=""

_hmd_python_cache_file() {
  printf '%s' "${HEIMDALL_HOME:-$HOME/.heimdall}/.python3-path"
}

# _hmd_python_works <path> — does it exist, and does it actually execute?
_hmd_python_works() {
  [ -n "$1" ] && [ -x "$1" ] && "$1" -c pass >/dev/null 2>&1
}

# hmd_python — print the interpreter path, or nothing.
hmd_python() {
  [ -n "$_HMD_PYTHON_RESOLVED" ] && { printf '%s' "$_HMD_PYTHON_RESOLVED"; return 0; }

  local cand cache
  if [ -n "${HMD_PYTHON:-}" ]; then
    # An explicit override is honoured without probing: a test seam that has to spend 31ms
    # proving itself is a test seam that changes the thing it measures.
    _HMD_PYTHON_RESOLVED="$HMD_PYTHON"
    printf '%s' "$_HMD_PYTHON_RESOLVED"; return 0
  fi

  cache="$(_hmd_python_cache_file)"
  if [ -r "$cache" ]; then
    # Pure bash read: this lib runs inside hooks whose PATH may not carry coreutils,
    # and a resolver that needs `cat` to find python is a resolver with two failure
    # modes instead of one.
    cand=""; IFS= read -r cand < "$cache" 2>/dev/null || cand=""
    # RUN it, do not just stat it. An earlier revision checked `-x` only, to save the
    # ~31ms a `-c pass` costs, on the theory that a broken-but-executable path "falls
    # through to the caller's own error handling". Measured 2026-09-19, that theory
    # failed in the field: a macOS CLT update re-armed the Xcode license prompt and
    # /usr/bin/python3 became a stub that is executable, exits 69, and prints a license
    # nag. The cache named it; `-x` blessed it; every consumer -- the statusline
    # watchman, its face fallback, ctx-meter -- died silently and the status bar read
    # "[ heimdall ]" for the rest of the day. The callers' "error handling" is to fall
    # back to nothing, because a resolver that returns a path is asserting the path
    # works. 31ms is the price of that assertion being true; the cache still saves
    # the ~400ms shim launch it was built to avoid. A cached path that no longer runs
    # is deleted so the probe below runs fresh and the cache cannot outlive the
    # interpreter it names.
    if _hmd_python_works "$cand"; then
      _HMD_PYTHON_RESOLVED="$cand"
      printf '%s' "$_HMD_PYTHON_RESOLVED"; return 0
    fi
    rm -f "$cache" 2>/dev/null || true
  fi

  cand=""
  # Probe order: the system interpreter (fastest, present on every macOS/Linux), then
  # Homebrew's -- a real binary, not a shim, in the same ~30ms class -- and only then
  # whatever PATH resolves, which on a pyenv machine is the ~400ms shim. Every
  # candidate is RUN before it is accepted, the PATH one included: a shim pointing at a
  # broken version is the same defect as the license-nag stub above, and the PATH
  # fallback is the last line -- if it is broken too, the honest answer is "no
  # interpreter", which every caller already handles.
  for cand in /usr/bin/python3 /opt/homebrew/bin/python3 "$(command -v python3 2>/dev/null || true)"; do
    if _hmd_python_works "$cand"; then break; fi
    cand=""
  done

  if [ -n "$cand" ]; then
    _HMD_PYTHON_RESOLVED="$cand"
    # Best-effort cache. A read-only or absent HEIMDALL_HOME costs correctness nothing —
    # the next process simply probes again.
    mkdir -p "${cache%/*}" 2>/dev/null && printf '%s\n' "$cand" > "$cache" 2>/dev/null || true
    printf '%s' "$cand"
    return 0
  fi
  return 1
}
