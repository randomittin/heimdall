#!/usr/bin/env bash
# Hidden acceptance test for 03-extract-helper-refactor (refactor, tests must stay unchanged).
# Run as: ACCEPT_DIR=<abs task dir> bash "$ACCEPT_DIR/accept.sh"   (cwd = the agent's workdir)
# Exit 0 = pass, nonzero = fail.  Every stage runs so the output shows which ones failed.
set -u
: "${ACCEPT_DIR:?ACCEPT_DIR must be the absolute path of the task directory}"

export PYTHONDONTWRITEBYTECODE=1
rc=0

# Hard time limit without GNU timeout (absent on macOS): a pending alarm survives exec.
limited() {
  python3 -c 'import os, signal, sys; signal.alarm(int(sys.argv[1])); os.execvp(sys.argv[2], sys.argv[2:])' "$@"
}

# Stages tests-unchanged + refactor-static (tests/ byte-identical to the seed; one helper, >= 3 call sites).
limited 8 python3 "$ACCEPT_DIR/static_check.py" || rc=1

# Stage visible-tests: the seed's own tests must still be green.
if out=$(limited 8 python3 -m unittest discover -s tests 2>&1); then
  echo "STAGE visible-tests: ok"
else
  echo "STAGE visible-tests: FAIL"
  printf '%s\n' "$out" | tail -n 25
  rc=1
fi

# Stage hidden-behaviour: exact exceptions, messages and order of checks on all three functions.
if out=$(limited 8 env PYTHONPATH="$PWD" python3 "$ACCEPT_DIR/hidden_test.py" 2>&1); then
  echo "STAGE hidden-behaviour: ok"
else
  echo "STAGE hidden-behaviour: FAIL"
  printf '%s\n' "$out" | tail -n 40
  rc=1
fi

if [ "$rc" -eq 0 ]; then echo "ACCEPT PASS"; else echo "ACCEPT FAIL"; fi
exit "$rc"
