#!/usr/bin/env bash
# Hidden acceptance for 08-dst-business-days. cwd = the agent's workdir.
set -u
: "${ACCEPT_DIR:?ACCEPT_DIR must be the absolute path of the task directory}"

[ -f schedule.py ] || { echo "FAIL: schedule.py missing in $PWD" >&2; exit 1; }

# Environment guard: the hidden test needs the system tz database (not an agent failure).
if ! python3 -c "import zoneinfo; [zoneinfo.ZoneInfo(k) for k in ('America/New_York', 'Europe/London', 'UTC')]" 2>/dev/null; then
  echo "ENV: tz database (America/New_York, Europe/London, UTC) not available to zoneinfo" >&2
  exit 3
fi

# 8 s hard cap so a hung solution cannot stall the runner (perl alarm survives exec).
limited() {
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' 8 "$@"
  else
    "$@"
  fi
}

PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PWD" limited python3 "$ACCEPT_DIR/hidden_test.py"
