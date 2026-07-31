#!/usr/bin/env bash
# test/heimdall-agents.test.sh — falsifiable acceptance for bin/heimdall-agents.
#
# The tool's whole value is an HONEST live-subagent count: a dead/stale/failed
# harness subagent must NOT be counted as live, and reaping must be idempotent so
# the count never drifts. Every assertion here is built to CATCH the tool lying:
#
#   Fixture — a fake harness task dir with 3 <id>.output files:
#     aaa  fresh (age << threshold)                        → must classify LIVE
#     bbb  stale (age >> threshold)                         → must classify STALE
#     ccc  fresh BUT a sibling ccc.status marks "failed"    → must classify FAILED
#          (terminal beats freshness — a failed-but-recent subagent is NOT live)
#
#   Assertions:
#     (1) list classifies aaa=live, bbb=stale, ccc=failed.
#     (2) count == 1  (ONLY the fresh live one). FALSIFIER: if a stale or failed
#         subagent is counted live, count != 1 and this fails.
#     (3) reap records the stale + failed ones (2 records) in heimdall's registry.
#     (4) after reap: count STILL 1 (the live one is never reaped) and list shows
#         bbb + ccc as "reaped".
#     (5) a SECOND reap is an idempotent no-op (records nothing new). FALSIFIER: if
#         reap re-records an already-reaped id, this fails.
#
# Hermetic: HMD_AGENT_TASKDIR points the tool at the fixture (no real harness dir
# needed); HMD_AGENT_REAPED_FILE isolates the registry to a throwaway file (never
# touches ~/.heimdall); HMD_NOW pins "now" so staleness is deterministic.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AGENTS="$ROOT/bin/heimdall-agents"

[ -x "$AGENTS" ] || { echo "FATAL: $AGENTS not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-agents-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TASKDIR="$WORK/tasks"; mkdir -p "$TASKDIR"
REAPED="$WORK/agents-reaped.json"

# Deterministic clock + threshold.
NOW=2000000000
export HMD_NOW="$NOW"
export HMD_AGENT_STALE_SECS=900
export HMD_AGENT_TASKDIR="$TASKDIR"
export HMD_AGENT_REAPED_FILE="$REAPED"

# Portable mtime setter: GNU (touch -d @epoch) first, BSD (date -r → touch -t) fallback.
set_mtime() {
  local f="$1" e="$2" ts
  touch -d "@$e" "$f" 2>/dev/null && return 0
  ts="$(date -r "$e" +%Y%m%d%H%M.%S 2>/dev/null)" || return 1
  touch -t "$ts" "$f"
}

# ── fixture ───────────────────────────────────────────────────────────────────
: > "$TASKDIR/aaa.output"; set_mtime "$TASKDIR/aaa.output" $((NOW - 10))    # live
: > "$TASKDIR/bbb.output"; set_mtime "$TASKDIR/bbb.output" $((NOW - 5000))  # stale
: > "$TASKDIR/ccc.output"; set_mtime "$TASKDIR/ccc.output" $((NOW - 10))    # fresh…
printf 'failed\n' > "$TASKDIR/ccc.status"                                   # …but terminal

state_of() { "$AGENTS" list --json | jq -r --arg id "$1" '.[]|select(.id==$id)|.state'; }

# ── (1) classification ────────────────────────────────────────────────────────
[ "$(state_of aaa)" = "live"   ] && ok "aaa classified live"   || bad "aaa not live (got '$(state_of aaa)')"
[ "$(state_of bbb)" = "stale"  ] && ok "bbb classified stale"  || bad "bbb not stale (got '$(state_of bbb)')"
[ "$(state_of ccc)" = "failed" ] && ok "ccc classified failed" || bad "ccc not failed (got '$(state_of ccc)')"

# ── (2) count is LIVE-only ────────────────────────────────────────────────────
C="$("$AGENTS" count)"
[ "$C" = "1" ] && ok "count==1 (live only; stale+failed excluded)" || bad "count expected 1, got '$C'"

# ── (3) reap records the stale + failed ones ──────────────────────────────────
"$AGENTS" reap >/dev/null
RN="$(jq 'keys|length' "$REAPED" 2>/dev/null)"
[ "$RN" = "2" ] && ok "reap recorded 2 (stale+failed)" || bad "reaped registry has $RN keys, expected 2"
[ "$(jq -r '.bbb.reason' "$REAPED")" = "stale"  ] && ok "bbb recorded reason=stale"  || bad "bbb reason wrong"
[ "$(jq -r '.ccc.reason' "$REAPED")" = "failed" ] && ok "ccc recorded reason=failed" || bad "ccc reason wrong"

# ── (4) post-reap: count still 1; reaped ones show state=reaped ───────────────
C2="$("$AGENTS" count)"
[ "$C2" = "1" ] && ok "post-reap count STILL 1 (live untouched)" || bad "post-reap count expected 1, got '$C2'"
[ "$(state_of bbb)" = "reaped" ] && ok "bbb now shows reaped" || bad "bbb not reaped (got '$(state_of bbb)')"
[ "$(state_of ccc)" = "reaped" ] && ok "ccc now shows reaped" || bad "ccc not reaped (got '$(state_of ccc)')"
[ "$(state_of aaa)" = "live"   ] && ok "aaa still live"       || bad "aaa no longer live (got '$(state_of aaa)')"

# ── (5) idempotency: a second reap records NOTHING new ───────────────────────
J2="$("$AGENTS" reap --json)"
[ "$J2" = "[]" ] && ok "second reap is idempotent no-op" || bad "second reap not idempotent (got '$J2')"
RN2="$(jq 'keys|length' "$REAPED" 2>/dev/null)"
[ "$RN2" = "2" ] && ok "registry still exactly 2 after re-reap" || bad "registry drifted to $RN2 keys"

# ── fail-closed: an absent task dir → count 0, never a crash ──────────────────
CZERO="$(HMD_AGENT_TASKDIR="$WORK/does-not-exist" "$AGENTS" count)"
[ "$CZERO" = "0" ] && ok "absent task dir → count 0 (fail-closed)" || bad "absent task dir count expected 0, got '$CZERO'"

echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
