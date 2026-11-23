#!/usr/bin/env bash
# Hidden acceptance for 06-semver-compare. cwd = the agent's workdir.
set -u
: "${ACCEPT_DIR:?ACCEPT_DIR must be the absolute path of the task directory}"

[ -f semver.py ] || { echo "FAIL: semver.py missing in $PWD" >&2; exit 1; }

# 8 s hard cap so a hung solution cannot stall the runner (perl alarm survives exec).
limited() {
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' 8 "$@"
  else
    "$@"
  fi
}

PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PWD" limited python3 "$ACCEPT_DIR/hidden_test.py"
