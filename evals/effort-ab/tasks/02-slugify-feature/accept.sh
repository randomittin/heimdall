#!/usr/bin/env bash
# Hidden acceptance test for 02-slugify-feature.
# Run as: ACCEPT_DIR=<abs task dir> bash "$ACCEPT_DIR/accept.sh"   (cwd = the agent's workdir)
# Exit 0 = pass, nonzero = fail.
set -u
: "${ACCEPT_DIR:?ACCEPT_DIR must be the absolute path of the task directory}"

export PYTHONDONTWRITEBYTECODE=1
PYTHONPATH="$PWD" exec python3 "$ACCEPT_DIR/hidden_test.py"
