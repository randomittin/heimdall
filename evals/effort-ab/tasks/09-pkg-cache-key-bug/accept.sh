#!/usr/bin/env bash
# Hidden acceptance for 09-pkg-cache-key-bug. cwd = the agent's workdir.
set -u
: "${ACCEPT_DIR:?ACCEPT_DIR must be the absolute path of the task directory}"

for f in catalog/__init__.py catalog/keys.py catalog/cache.py catalog/client.py; do
  [ -f "$f" ] || { echo "FAIL: $f missing in $PWD" >&2; exit 1; }
done

# 8 s hard cap so a hung solution cannot stall the runner (perl alarm survives exec).
limited() {
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' 8 "$@"
  else
    "$@"
  fi
}

PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PWD" limited python3 "$ACCEPT_DIR/hidden_test.py"
