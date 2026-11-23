#!/usr/bin/env bash
# Hidden acceptance test for 04-bash-log-summary.
# Run as: ACCEPT_DIR=<abs task dir> bash "$ACCEPT_DIR/accept.sh"   (cwd = the agent's workdir)
# Exit 0 = pass, nonzero = fail.  The test runs `bash summarize.sh` from cwd under the C locale
# (so "plain string order" is byte order everywhere) and cleans up its scratch logs on exit.
set -u
: "${ACCEPT_DIR:?ACCEPT_DIR must be the absolute path of the task directory}"

export PYTHONDONTWRITEBYTECODE=1 LC_ALL=C LANG=C
exec python3 "$ACCEPT_DIR/hidden_test.py"
