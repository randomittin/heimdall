#!/usr/bin/env bash
# test/heimdall-429-mark.test.sh -- hermetic tests for bin/heimdall-429-mark,
# the reactive HTTP-429 quota-exhaustion recorder (PHASE 4, 2026-08-30). See
# docs/analysis/2026-08-29-fallback-did-not-fire-rootcause.md for why this
# tool exists, and bin/heimdall-session-usage's own PHASE 4 docstring / this
# repo's test/heimdall-session-usage.test.sh cases 29-44 for the READER side
# of the same contract (this file tests only the WRITER/recorder itself).
#
# FALSIFIABLE CLAIMS TESTED:
#  1. `mark` writes a marker file containing a numeric marked_at, no 'reason'
#     key when none is given
#  2. `mark --reason` writes a slugged reason
#  3. reason slugging: lowercased, non-[a-z0-9_-] runs collapsed to one '-',
#     leading/trailing '-' stripped
#  4. reason capped at REASON_MAX (64) chars
#  5. a reason that slugs to empty (e.g. all punctuation) is dropped entirely
#     -- no 'reason' key at all, never an empty-string one
#  6. idempotent: a second `mark` call fully OVERWRITES the marker (a reason
#     from call 1 does not survive a reason-less call 2)
#  7. atomic write: no leftover `<path>.<pid>.tmp` file survives a `mark` call
#  8. `check` on a freshly-written marker -> fresh=true, rc=0
#  9. `check --ttl-secs` is a real, independent override: the SAME marker
#     reads fresh under a wide TTL and expired under a narrow one
# 10. `check` on an absent marker file -> fresh=false, rc=1, marked_at=null,
#     no crash
# 11. `check` on a corrupt (non-JSON) marker file -> fresh=false, rc=1, no
#     crash
# 12. `check`'s human-readable (non-JSON) text distinguishes FRESH / EXPIRED
#     / no-marker-at-all in three visibly different strings
# 13. `where` path precedence: --file > $HEIMDALL_429_MARKER_FILE (env) >
#     $HEIMDALL_HOME/429-marker.json (default) -- all three tiers hermetic,
#     never the operator's real $HOME
# 14. never-fails contract: an unrecognized subcommand degrades to exit 0 by
#     default, exit 2 under --strict
# 15. never-fails contract: a marker write that hits a real OSError (a path
#     component that is a FILE, not a directory) degrades to exit 0 by
#     default, exit 3 with a stderr message under --strict
# 16. `check --json` is always valid JSON with the exact documented key set,
#     fresh or not
# 17. exit-code contract: mark=0 (default), check=0/1 (fresh/not), where=0
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_ROOT/bin/heimdall-429-mark"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-429-mark-test.XXXXXX")"
trap 'chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# never let a real operator's real ~/.heimdall leak into any case that
# exercises the DEFAULT (unresolved-override) path -- see case 13c.
unset HEIMDALL_429_MARKER_FILE
export HEIMDALL_HOME="$WORK/unused-heimdall-home"

case_dir() {
  d="$WORK/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

echo "=== 1. mark writes a marker with numeric marked_at, no reason key when none given ==="
d=$(case_dir c1); mk="$d/429-marker.json"
python3 "$BIN" mark --file "$mk" >/dev/null; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$mk" ] && python3 -c "
import json
p = json.load(open('$mk'))
assert isinstance(p.get('marked_at'), float), p
assert 'reason' not in p, p
" 2>/dev/null; then ok; else bad "case1 rc=$rc mk_exists=$([ -f "$mk" ] && echo yes || echo no)"; fi

echo "=== 2. mark --reason writes a slugged reason ==="
d=$(case_dir c2); mk="$d/429-marker.json"
python3 "$BIN" mark --file "$mk" --reason "hmd-claude-retry" >/dev/null; rc=$?
if [ "$rc" -eq 0 ] && python3 -c "
import json
p = json.load(open('$mk'))
assert p.get('reason') == 'hmd-claude-retry', p
" 2>/dev/null; then ok; else bad "case2 rc=$rc"; fi

echo "=== 3. reason slugging: lowercased, punctuation runs collapsed to one '-', trimmed ==="
d=$(case_dir c3); mk="$d/429-marker.json"
python3 "$BIN" mark --file "$mk" --reason "Hello World! 123" >/dev/null
if python3 -c "
import json
p = json.load(open('$mk'))
assert p.get('reason') == 'hello-world-123', p
" 2>/dev/null; then ok; else bad "case3 got=$(python3 -c "import json; print(json.load(open('$mk')).get('reason'))" 2>/dev/null)"; fi

echo "=== 4. reason capped at REASON_MAX (64) chars ==="
d=$(case_dir c4); mk="$d/429-marker.json"
long_reason=$(python3 -c "print('a' * 200)")
python3 "$BIN" mark --file "$mk" --reason "$long_reason" >/dev/null
len=$(python3 -c "import json; print(len(json.load(open('$mk'))['reason']))")
if [ "$len" -eq 64 ]; then ok; else bad "case4 expected len 64, got $len"; fi

echo "=== 5. a reason that slugs to empty is dropped entirely -- no 'reason' key ==="
d=$(case_dir c5); mk="$d/429-marker.json"
python3 "$BIN" mark --file "$mk" --reason "!!!   ---" >/dev/null
if python3 -c "
import json
p = json.load(open('$mk'))
assert 'reason' not in p, p
" 2>/dev/null; then ok; else bad "case5 got=$(cat "$mk")"; fi

echo "=== 6. idempotent: a second, reason-less mark call fully OVERWRITES -- reason does not survive ==="
d=$(case_dir c6); mk="$d/429-marker.json"
python3 "$BIN" mark --file "$mk" --reason "first-call" >/dev/null
first_marked_at=$(python3 -c "import json; print(json.load(open('$mk'))['marked_at'])")
python3 "$BIN" mark --file "$mk" >/dev/null
if python3 -c "
import json
p = json.load(open('$mk'))
assert 'reason' not in p, p
assert p['marked_at'] >= $first_marked_at, p
" 2>/dev/null; then ok; else bad "case6 got=$(cat "$mk")"; fi

echo "=== 7. atomic write: no leftover <path>.<pid>.tmp file survives a mark call ==="
d=$(case_dir c7); mk="$d/429-marker.json"
python3 "$BIN" mark --file "$mk" >/dev/null
tmp_leftovers=$(find "$d" -name '*.tmp' 2>/dev/null | wc -l | tr -d ' ')
if [ "$tmp_leftovers" -eq 0 ]; then ok; else bad "case7 found $tmp_leftovers leftover tmp file(s)"; fi

echo "=== 8. check on a freshly-written marker -> fresh=true, rc=0 ==="
d=$(case_dir c8); mk="$d/429-marker.json"
python3 "$BIN" mark --file "$mk" >/dev/null
out=$(python3 "$BIN" check --file "$mk" --json); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"fresh": true'; then ok; else bad "case8 rc=$rc out=$out"; fi

echo "=== 9. --ttl-secs is a real, independent override: same marker reads fresh under a wide TTL, expired under a narrow one ==="
d=$(case_dir c9); mk="$d/429-marker.json"
python3 -c "
import json, time
json.dump({'marked_at': time.time() - 100}, open('$mk', 'w'))
"
out_wide=$(python3 "$BIN" check --file "$mk" --ttl-secs 200 --json); rc_wide=$?
out_narrow=$(python3 "$BIN" check --file "$mk" --ttl-secs 10 --json); rc_narrow=$?
if [ "$rc_wide" -eq 0 ] && printf '%s' "$out_wide" | grep -q '"fresh": true' \
   && [ "$rc_narrow" -eq 1 ] && printf '%s' "$out_narrow" | grep -q '"fresh": false'; then
  ok
else
  bad "case9 wide(rc=$rc_wide,$out_wide) narrow(rc=$rc_narrow,$out_narrow)"
fi

echo "=== 10. check on an absent marker file -> fresh=false, rc=1, marked_at=null, no crash ==="
d=$(case_dir c10)
out=$(python3 "$BIN" check --file "$d/does-not-exist.json" --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"fresh": false' && printf '%s' "$out" | grep -q '"marked_at": null'; then ok; else bad "case10 rc=$rc out=$out"; fi

echo "=== 11. check on a corrupt (non-JSON) marker file -> fresh=false, rc=1, no crash ==="
d=$(case_dir c11); mk="$d/429-marker.json"
printf 'not json {{{' > "$mk"
out=$(python3 "$BIN" check --file "$mk" --json); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && printf '%s' "$out" | grep -q '"fresh": false'; then ok; else bad "case11 rc=$rc out=$out"; fi

echo "=== 12. human-readable text distinguishes FRESH / EXPIRED / no-marker-at-all ==="
d=$(case_dir c12)
mk_fresh="$d/fresh.json"; mk_expired="$d/expired.json"
python3 "$BIN" mark --file "$mk_fresh" >/dev/null
python3 -c "
import json, time
json.dump({'marked_at': time.time() - 999999}, open('$mk_expired', 'w'))
"
out_fresh=$(python3 "$BIN" check --file "$mk_fresh")
out_expired=$(python3 "$BIN" check --file "$mk_expired")
out_absent=$(python3 "$BIN" check --file "$d/nope.json")
if printf '%s' "$out_fresh" | grep -q "FRESH --" \
   && printf '%s' "$out_expired" | grep -q "EXPIRED --" \
   && printf '%s' "$out_absent" | grep -q "no marker at"; then
  ok
else
  bad "case12 fresh='$out_fresh' expired='$out_expired' absent='$out_absent'"
fi

echo "=== 13a. where: --file overrides everything ==="
out=$(HEIMDALL_429_MARKER_FILE="/should/not/win" python3 "$BIN" where --file "/explicit/path.json")
if [ "$out" = "/explicit/path.json" ]; then ok; else bad "case13a out=$out"; fi

echo "=== 13b. where: HEIMDALL_429_MARKER_FILE (env) used when no --file given ==="
out=$(HEIMDALL_429_MARKER_FILE="$WORK/env-marker.json" python3 "$BIN" where)
if [ "$out" = "$WORK/env-marker.json" ]; then ok; else bad "case13b out=$out"; fi

echo "=== 13c. where: default is \$HEIMDALL_HOME/429-marker.json, hermetically overridden -- never the real \$HOME ==="
d=$(case_dir c13c)
out=$(HEIMDALL_HOME="$d" python3 "$BIN" where)
if [ "$out" = "$d/429-marker.json" ]; then ok; else bad "case13c out=$out"; fi

echo "=== 14. never-fails: unrecognized subcommand -> exit 0 default, exit 2 --strict ==="
python3 "$BIN" bogus-subcommand >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then ok; else bad "case14(default) rc=$rc"; fi
python3 "$BIN" --strict bogus-subcommand >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok; else bad "case14(strict) rc=$rc"; fi

echo "=== 15. never-fails: a real OSError on write (parent path component is a FILE) -> exit 0 default, exit 3 + stderr under --strict ==="
d=$(case_dir c15)
blocker="$d/blocker"
printf 'i am a file, not a directory' > "$blocker"
bad_path="$blocker/subdir/429-marker.json"
python3 "$BIN" mark --file "$bad_path" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$bad_path" ]; then ok; else bad "case15(default) rc=$rc exists=$([ -e "$bad_path" ] && echo yes || echo no)"; fi
err=$(python3 "$BIN" --strict mark --file "$bad_path" 2>&1 >/dev/null); rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$err" | grep -qi "could not write marker"; then ok; else bad "case15(strict) rc=$rc err=$err"; fi

echo "=== 16. check --json is always valid JSON with the exact documented key set ==="
d=$(case_dir c16); mk="$d/429-marker.json"
python3 "$BIN" mark --file "$mk" >/dev/null
for target in "$mk" "$d/absent.json"; do
  out=$(python3 "$BIN" check --file "$target" --json)
  if printf '%s' "$out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
expected = {'fresh', 'marked_at', 'age_secs', 'ttl_secs', 'reason', 'marker_path'}
assert set(d.keys()) == expected, d
" 2>/dev/null; then
    ok
  else
    bad "case16($target) out=$out"
  fi
done

echo "=== 17. exit-code contract sanity: mark=0, check=0/1 (fresh/not), where=0 ==="
d=$(case_dir c17); mk="$d/429-marker.json"
python3 "$BIN" mark --file "$mk" >/dev/null 2>&1; rc_mark=$?
python3 "$BIN" check --file "$mk" --json >/dev/null 2>&1; rc_check_fresh=$?
python3 "$BIN" check --file "$d/absent.json" --json >/dev/null 2>&1; rc_check_absent=$?
python3 "$BIN" where --file "$mk" >/dev/null 2>&1; rc_where=$?
if [ "$rc_mark" -eq 0 ] && [ "$rc_check_fresh" -eq 0 ] && [ "$rc_check_absent" -eq 1 ] && [ "$rc_where" -eq 0 ]; then
  ok
else
  bad "case17 mark=$rc_mark check_fresh=$rc_check_fresh check_absent=$rc_check_absent where=$rc_where"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
