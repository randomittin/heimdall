# shellcheck shell=bash
# test/lib/py-pin.sh -- pin `python3` to the real interpreter for a test run.
#
# SOURCED, never executed (run-all.sh globs test/*.test.sh only, so this file is not a suite). Used by
# test/run-all.sh (once, for every suite it runs) and by test/lib/app-relay-common.sh (so a relay suite run
# standalone gets the same pin).
#
# WHY: on a box where python3 resolves through a pyenv shim (or the macOS xcrun stub) every `python3` call pays
# a bash + version-resolution tax before it execs the real interpreter -- 0.3-0.8 s per call under load, against
# 0.05 s for the interpreter itself -- and the suites make thousands of calls (every JSON field extraction,
# every sealed command, every poll iteration). That tax, not the code under test, was most of the wall clock of
# the app-relay / companion-push / controls suites.
#
# HOW: resolve the interpreter ONCE (the single shimmed call) and put a one-line exec wrapper first on PATH.
# A wrapper, not a symlink: a symlink would hide a venv's pyvenv.cfg (the interpreter finds it next to the path
# it was started by), and a PATH entry for the interpreter's own bin dir would also expose every other tool
# installed beside it. The wrapper execs the SAME interpreter python3 already resolved to, so nothing a suite
# imports changes. It is only installed when python3 resolves to something other than that interpreter.
#
# TEST HARNESS ONLY: nothing under bin/, install.sh or the product's own PATH handling reads or writes any of
# this. The pin exists in the environment of a test run and dies with it (the caller owns WRAPPER_DIR).
#
#   hmd_test_pin_python3 WRAPPER_DIR
#     HMD_TEST_NO_PY_PIN=1   opt out: PATH untouched, nothing resolved
#     sets HMD_PY_PIN_NOTE   one human line saying what happened (run-all.sh prints it in the run header)
#     on a pin, exports HMD_TEST_PY_PIN_DIR / HMD_TEST_PY_PIN_REAL so a nested run, or a suite that calls this
#     again, sees the pin is already in place and does not wrap it a second time
#   Always returns 0: the pin is an optimisation, never a reason for a run to fail. When it cannot pin it says
#   why in HMD_PY_PIN_NOTE and leaves PATH exactly as it found it.
# shellcheck disable=SC2034  # HMD_PY_PIN_NOTE is read by the sourcing caller, never inside this file
hmd_test_pin_python3() {
  local dir="$1" cur real q
  if [ "${HMD_TEST_NO_PY_PIN:-}" = 1 ]; then
    HMD_PY_PIN_NOTE="off (HMD_TEST_NO_PY_PIN=1)"
    return 0
  fi
  cur="$(command -v python3)" || { HMD_PY_PIN_NOTE="off (no python3 on PATH)"; return 0; }
  if [ -n "${HMD_TEST_PY_PIN_DIR:-}" ] && [ "$cur" = "$HMD_TEST_PY_PIN_DIR/python3" ]; then
    HMD_PY_PIN_NOTE="inherited -> ${HMD_TEST_PY_PIN_REAL:-?} (pinned by an outer run)"
    return 0
  fi
  real="$("$cur" -c 'import sys; print(sys.executable)' 2>/dev/null)"
  case "$real" in /*) ;; *) real="" ;; esac
  if [ -z "$real" ] || [ ! -x "$real" ]; then
    HMD_PY_PIN_NOTE="off (could not resolve the interpreter behind $cur)"
    return 0
  fi
  if [ "$cur" -ef "$real" ]; then
    HMD_PY_PIN_NOTE="not needed ($cur already is the interpreter)"
    return 0
  fi
  # The interpreter path is embedded in the wrapper (not read from the environment, which a suite may scrub),
  # single-quoted for sh: a ' inside the path becomes '\''.
  q="$(printf '%s' "$real" | sed "s/'/'\\\\''/g")"
  if mkdir -p "$dir" \
     && printf '#!/bin/sh\nexec %s "$@"\n' "'$q'" > "$dir/python3" \
     && chmod +x "$dir/python3"; then
    export PATH="$dir:$PATH" HMD_TEST_PY_PIN_DIR="$dir" HMD_TEST_PY_PIN_REAL="$real"
    HMD_PY_PIN_NOTE="pinned -> $real (python3 resolved via $cur)"
  else
    HMD_PY_PIN_NOTE="off (could not write the wrapper under $dir)"
  fi
  return 0
}
