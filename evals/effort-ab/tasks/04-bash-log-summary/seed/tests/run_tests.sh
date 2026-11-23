#!/usr/bin/env bash
# Visible tests for summarize.sh.  Run from anywhere: bash tests/run_tests.sh
# Prints one PASS/FAIL line per check; exits nonzero if any check failed.
set -u
cd "$(dirname "$0")/.." || exit 2

failures=0

assert_eq() { # assert_eq <check name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "PASS $1"
  else
    echo "FAIL $1"
    echo "  expected: $(printf '%s' "$2" | tr '\n' '|')"
    echo "  actual:   $(printf '%s' "$3" | tr '\n' '|')"
    failures=$((failures + 1))
  fi
}

out=$(bash summarize.sh logs/access.log 2>/dev/null)
assert_eq "access.log default top 3" "4 203.0.113.7
3 198.51.100.23
2 192.0.2.44" "$out"

out=$(bash summarize.sh logs/access.log 1 2>/dev/null)
assert_eq "access.log N=1" "4 203.0.113.7" "$out"

out=$(bash summarize.sh logs/combined.log 2>/dev/null)
assert_eq "combined.log default" "3 203.0.113.7
2 198.51.100.23
1 192.0.2.44" "$out"

out=$(bash summarize.sh logs/no-such.log 2>/dev/null)
rc=$?
assert_eq "missing file prints nothing on stdout" "" "$out"
assert_eq "missing file exits 2" "2" "$rc"
err=$(bash summarize.sh logs/no-such.log 2>&1 >/dev/null)
assert_eq "missing file message on stderr" "error: no such file: logs/no-such.log" "$err"

if [ "$failures" -eq 0 ]; then
  echo "all checks passed"
else
  echo "$failures check(s) failed"
  exit 1
fi
