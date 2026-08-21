#!/usr/bin/env bash
#
# heimdall-statusline-agents-cache.test.sh — mechanism proof for the cached
# HMD_LIVE_SUBAGENTS refresh in bin/heimdall-statusline.
#
# WHY THIS EXISTS: heimdall-statusline-perf-budget.test.sh is the TIMING proof
# (median/max render time against the real fixture) and must stay a pure
# 3-assertion suite. It cannot also prove the CACHE is correct — dedup, honest
# staleness, eventual consistency — because none of that is observable from
# render output alone (nothing renders HMD_LIVE_SUBAGENTS today). This suite
# proves the mechanism instead, black-box, via the one thing that IS
# observable outside the process: the on-disk cache file's presence, content
# and mtime. That is the same precedent heimdall-statusline-parity.test.sh
# already sets for its ctx-meter-publish assertion — test the persisted
# side-effect, not an ephemeral env var nothing consumes yet.
#
# HERMETICITY: every case points HMD_AGENT_CWD at a fresh mktemp dir. No
# session's task dir ever matches a slug derived from a directory that never
# existed before this run, so `heimdall-agents count` deterministically
# returns "0" for every one of these cases — a real, honest recompute, not a
# stub. HMD_AGENTS_COUNT_TTL/HMD_AGENTS_LOCK_TTL are overridden small (1s/2s)
# purely so the staleness/expiry assertions don't need multi-second sleeps at
# the production default (4s/8s); the production constants are exercised by
# their own doc comment cross-referencing the roster cache's identical 4s/8s,
# not by this suite's timing.
#
# FALSIFIER (verified by hand for this task): reverting bin/heimdall-statusline
# to its pre-fix synchronous form makes cases 2, 4b and 5 go RED — no code
# path in the old version ever writes .agents-count-cache, so "eventually
# populated" and "stale cache gets overwritten" time out. Cases 3 and 4a stay
# green under the old code too (nothing to dedup against), which is expected:
# they exist to pin behavior going forward, not to distinguish old from new.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-statusline"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

[ -x "$CLI" ] || { echo "FATAL: $CLI missing/not executable"; echo "heimdall-statusline-agents-cache: 0 passed, 1 failed"; exit 1; }

# hermetic workspace — same identity/verdict shape as the other statusline
# suites' mkws(), plus a beat-stamp/wall-lock pre-seed so _spawn_presence()
# never forks during these renders and only OUR cache is under test.
mkws() {
  ws="$(mktemp -d)"; homed="$(mktemp -d)"
  mkdir -p "$ws/.heimdall"
  printf '{"handle":"rj","seed":"rj","created":0}\n' > "$ws/.heimdall/identity.json"
  printf '{"verdict":"pass","passed":3,"total":3}\n' > "$ws/.heimdall/statusline.json"
  : > "$ws/.heimdall/.beat-stamp"
  : > "$ws/.heimdall/.wall-cache.json.lock"
  printf '%s|%s' "$ws" "$homed"
}

BLOB='{"model":{"display_name":"Auto"}}'
CACHE_REL=".heimdall/.agents-count-cache"
LOCK_REL=".heimdall/.agents-count-cache.lock"

run_cli() {
  # $1 = workspace (becomes HMD_AGENT_CWD); $2 = homed
  printf '%s' "$BLOB" | HOME="$2" HEIMDALL_IDENTITY_DIR="$1/.heimdall" HMD_HAID=rj \
    HEIMDALL_CP_URL="http://127.0.0.1:1" TERM=xterm-256color \
    HEIMDALL_STATUSLINE_MODE=truecolor HMD_AGENT_CWD="$1" \
    HMD_AGENTS_COUNT_TTL=1 HMD_AGENTS_LOCK_TTL=2 \
    bash "$CLI" >/dev/null 2>&1
}

poll_for_file() {
  # $1 = path, $2 = max attempts (each 0.2s) — bounded wait, never hangs.
  local n=0
  while [ "$n" -lt "$2" ]; do
    [ -f "$1" ] && return 0
    sleep 0.2
    n=$((n+1))
  done
  [ -f "$1" ]
}

poll_for_change() {
  # $1 = path, $2 = original content, $3 = max attempts (each 0.2s)
  local n=0
  while [ "$n" -lt "$3" ]; do
    if [ -f "$1" ]; then
      cur="$(cat "$1" 2>/dev/null || echo '')"
      [ "$cur" != "$2" ] && return 0
    fi
    sleep 0.2
    n=$((n+1))
  done
  return 1
}

echo "== 1) COLD: render with no cache/lock present completes cleanly (never hangs/errors) =="
# Strict timing is heimdall-statusline-perf-budget.test.sh's job alone (see its own
# header: a dedicated, undilutable gate). This just proves the new code path exits
# 0 and renders something on a totally cold cache — a liveness check, not a budget.
TRIPLE="$(mkws)"; IFS='|' read -r WS HOMED <<<"$TRIPLE"
OUT="$(printf '%s' "$BLOB" | HOME="$HOMED" HEIMDALL_IDENTITY_DIR="$WS/.heimdall" HMD_HAID=rj \
    HEIMDALL_CP_URL="http://127.0.0.1:1" TERM=xterm-256color \
    HEIMDALL_STATUSLINE_MODE=truecolor HMD_AGENT_CWD="$WS" \
    HMD_AGENTS_COUNT_TTL=1 HMD_AGENTS_LOCK_TTL=2 \
    bash "$CLI" 2>/dev/null)"
RC=$?
if [ "$RC" -eq 0 ] && [ -n "$OUT" ]; then
  ok "cold render exits 0 with non-empty output"
else
  bad "cold render failed: exit=$RC output-len=${#OUT}"
fi

echo "== 2) EVENTUAL: cold cache is populated by the background refresh =="
if poll_for_file "$WS/$CACHE_REL" 15; then
  CONTENT="$(cat "$WS/$CACHE_REL" 2>/dev/null || echo '')"
  case "$CONTENT" in
    ''|*[!0-9]*) bad "cache populated but content is non-numeric: '$CONTENT'" ;;
    *) ok "cache populated with a digit count ('$CONTENT') within 3s" ;;
  esac
else
  bad "cache never appeared within 3s of the cold render"
fi
rm -rf "$WS" "$HOMED"

echo "== 3) DEDUP (fresh cache): a fresh cache is served, not recomputed =="
TRIPLE="$(mkws)"; IFS='|' read -r WS HOMED <<<"$TRIPLE"
printf '42' > "$WS/$CACHE_REL"
run_cli "$WS" "$HOMED"
sleep 0.5
AFTER="$(cat "$WS/$CACHE_REL" 2>/dev/null || echo '')"
if [ "$AFTER" = "42" ]; then
  ok "fresh cache (sentinel 42) left untouched — no duplicate recompute"
else
  bad "fresh cache was overwritten (now '$AFTER') while still within TTL"
fi
rm -rf "$WS" "$HOMED"

echo "== 4) DEDUP (fresh lock): a fresh lock suppresses a duplicate spawn, then expires =="
TRIPLE="$(mkws)"; IFS='|' read -r WS HOMED <<<"$TRIPLE"
: > "$WS/$LOCK_REL"
run_cli "$WS" "$HOMED"
sleep 0.8
if [ -f "$WS/$CACHE_REL" ]; then
  bad "cache appeared despite a fresh lock — dedup gate did not suppress the spawn"
else
  ok "cache stayed absent while the lock was fresh — dedup gate held"
fi
sleep 1.5   # lock TTL=2s; total 2.3s elapsed since the lock was seeded — now stale
run_cli "$WS" "$HOMED"
if poll_for_file "$WS/$CACHE_REL" 15; then
  ok "cache populated once the lock aged past its TTL — refresh is not wedged forever"
else
  bad "cache never appeared even after the lock expired — refresh is permanently stuck"
fi
rm -rf "$WS" "$HOMED"

echo "== 5) HONESTY: a stale cache is not trusted forever — refresh overwrites it =="
TRIPLE="$(mkws)"; IFS='|' read -r WS HOMED <<<"$TRIPLE"
printf '99' > "$WS/$CACHE_REL"
sleep 1.5   # count TTL=1s; now stale
run_cli "$WS" "$HOMED"
if poll_for_change "$WS/$CACHE_REL" "99" 15; then
  NEWVAL="$(cat "$WS/$CACHE_REL" 2>/dev/null || echo '')"
  case "$NEWVAL" in
    ''|*[!0-9]*) bad "stale cache changed but new content is non-numeric: '$NEWVAL'" ;;
    *) ok "stale sentinel (99) was overwritten by a real recompute ('$NEWVAL')" ;;
  esac
else
  bad "stale cache (99) was never refreshed — staleness is not being detected"
fi
rm -rf "$WS" "$HOMED"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
