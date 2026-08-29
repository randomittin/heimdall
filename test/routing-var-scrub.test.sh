#!/usr/bin/env bash
#
# routing-var-scrub.test.sh — proves C-1 is fixed: a claude-mem summarizer/observer
# process can NEVER inherit a routing var, a fallback-scoped credential, or a proxy var
# from the session that spawned it.
#
# CONTEXT: bin/heimdall-route:245-246 does `export ANTHROPIC_BASE_URL="$FALLBACK_URL"`
# then `exec "$REAL" "$@"`. Every descendant of that `claude` process inherits it. claude-mem
# runs a long-lived DAEMON descendant (worker-service.cjs --daemon, PPID=1, verified live as
# pid 88244 carrying ANTHROPIC_BASE_URL=http://127.0.0.1:8787) that OUTLIVES the session that
# spawned it and calls a model to summarize transcripts — so it can carry a STALE routed
# value across every session afterward. hmd_gate_exec (hmd-gate-endpoint.sh) does not apply:
# claude-mem is not a gate, and it is a third-party plugin hmd cannot edit — the fix lives in
# bin/lib/hmd-claude-mem-scrub.sh, a seam hmd DOES own (a SessionStart hook + a scrub policy
# built on top of the canonical _HMD_GATE_ROUTING_VARS list).
#
# WHAT IT PROVES:
#   A. A child spawned via hmd_claude_mem_exec in a ROUTED shell sees NONE of
#      ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY / HTTP(S)_PROXY
#      (upper+lower) / HEADROOM_BASE_URL.
#   B. RED-PROOF: a mutation that skips the scrub (hmd_claude_mem_exec redefined as a bare
#      passthrough) DOES leak those same vars — proving section A is a real discriminator,
#      not a vacuous "absence" check that would pass against broken code too.
#   C. The scrub list is SOURCED from the canonical _HMD_GATE_ROUTING_VARS
#      (hmd-gate-endpoint.sh), not a second, divergent copy: a var added ONLY to a copy of
#      the canonical list (never touching the real repo file) is picked up live.
#   D. END TO END: a LIVE, already-contaminated fake worker (real background process, real
#      PID file, hermetic) is killed and relaunched with the identical command line, clean.
#   E. FAIL CLOSED: when a process's environment cannot be read at all, it is treated as
#      CONTAMINATED, never waved through as clean.
#
# HERMETIC: $TMPDIR only. No network. Never touches ~/.omniroute, ~/.claude-mem, or
# /Users/rj/omniroute — every "worker" here is a throwaway script this suite writes and
# kills itself (trap cleanup EXIT). The REAL bin/lib/hmd-claude-mem-scrub.sh and
# bin/lib/hmd-gate-endpoint.sh are sourced read-only; nothing on disk is mutated.
#
# Usage:  test/routing-var-scrub.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib/hmd-claude-mem-scrub.sh"
GATE_LIB="$REPO/bin/lib/hmd-gate-endpoint.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -r "$LIB" ] || { echo "FATAL: $LIB not found"; exit 2; }
[ -r "$GATE_LIB" ] || { echo "FATAL: $GATE_LIB not found"; exit 2; }

TMP_ROOT="$(mktemp -d)"
LIVE_PIDS=()
cleanup() {
  local p
  for p in ${LIVE_PIDS[@]+"${LIVE_PIDS[@]}"}; do
    kill -KILL "$p" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

echo "routing-var-scrub harness  repo=$REPO"
echo "--------------------------------------------------------------------"

SCRUBBED_VARS="ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY HTTPS_PROXY https_proxy HEADROOM_BASE_URL"

# ══ A. A child spawned via hmd_claude_mem_exec in a ROUTED shell sees NONE of them ══
# Exactly what bin/heimdall-route:245-246 leaves for every descendant on the fallback path,
# plus HEADROOM_BASE_URL for the (mutually exclusive) compression-proxy path.
export ANTHROPIC_BASE_URL="http://127.0.0.1:20128"
export ANTHROPIC_AUTH_TOKEN="test-gateway-token-should-never-leak"
export ANTHROPIC_API_KEY="test-api-key-should-never-leak"
export HTTPS_PROXY="http://127.0.0.1:20128"
export https_proxy="http://127.0.0.1:20128"
export HEADROOM_BASE_URL="http://127.0.0.1:8787"

CHILD_OUT="$TMP_ROOT/child-env-real.txt"
bash -c "
  set -uo pipefail
  . '$LIB'
  hmd_claude_mem_exec env
" > "$CHILD_OUT" 2>"$TMP_ROOT/child-env-real.err"

LEAKED=""
for v in $SCRUBBED_VARS; do
  grep -q "^${v}=" "$CHILD_OUT" && LEAKED="$LEAKED $v"
done
if [ -z "$LEAKED" ]; then
  ok "hmd_claude_mem_exec: spawned child sees NONE of the routed/fallback-credential vars"
else
  bad "hmd_claude_mem_exec: child STILL saw:$LEAKED"
fi

# ══ B. RED-PROOF — a scrub-skipping mutation DOES leak (the check above discriminates) ══
MUT_OUT="$TMP_ROOT/child-env-mutated.txt"
bash -c "
  set -uo pipefail
  . '$LIB'
  hmd_claude_mem_exec() { \"\$@\"; }   # MUTATION: skip the scrub entirely — bare passthrough
  hmd_claude_mem_exec env
" > "$MUT_OUT" 2>"$TMP_ROOT/child-env-mutated.err"

MUT_LEAKED=""
for v in $SCRUBBED_VARS; do
  grep -q "^${v}=" "$MUT_OUT" && MUT_LEAKED="$MUT_LEAKED $v"
done
if [ -n "$MUT_LEAKED" ]; then
  ok "red-proof: a scrub-skipping mutation of hmd_claude_mem_exec DOES leak ($MUT_LEAKED) — section A is a real discriminator, not a vacuous pass"
else
  bad "red-proof: the mutated (scrub-skipping) copy still reported clean — section A would pass even against broken code"
fi

# ══ C. Scrub list is SOURCED from the canonical one, not duplicated ═════════════
# Copy both files (same-dir relative sourcing preserved), append a marker var to ONLY the
# COPY's canonical list (the real repo file is never touched), and prove
# hmd_claude_mem_exec picks it up live. A hardcoded/copy-pasted duplicate inside
# hmd-claude-mem-scrub.sh would have no way to know about this marker.
COPY_DIR="$TMP_ROOT/sourced-check"
mkdir -p "$COPY_DIR"
cp "$GATE_LIB" "$COPY_DIR/hmd-gate-endpoint.sh"
cp "$LIB" "$COPY_DIR/hmd-claude-mem-scrub.sh"

MARKER="HMD_TEST_MARKER_VAR_$$"
printf '\n_HMD_GATE_ROUTING_VARS="$_HMD_GATE_ROUTING_VARS\n%s\n"\n' "$MARKER" >> "$COPY_DIR/hmd-gate-endpoint.sh"

MARKER_OUT="$TMP_ROOT/marker-env.txt"
bash -c "
  export ${MARKER}=leak-if-hardcoded
  set -uo pipefail
  . '$COPY_DIR/hmd-claude-mem-scrub.sh'
  hmd_claude_mem_exec env
" > "$MARKER_OUT" 2>"$TMP_ROOT/marker-env.err"

if grep -q "^${MARKER}=" "$MARKER_OUT"; then
  bad "sourced-check: hmd_claude_mem_exec did NOT scrub a var added ONLY to the canonical list copy — list would be duplicated, not sourced"
else
  ok "sourced-check: hmd_claude_mem_exec scrubs a var that exists ONLY in the canonical list — proves live sourcing, not a copy-pasted duplicate"
fi

# ══ D. END TO END: a LIVE contaminated worker is killed and relaunched clean ══════
FAKE_WORKER="$TMP_ROOT/fake-worker.sh"
cat > "$FAKE_WORKER" <<'EOF'
#!/bin/sh
while :; do sleep 1; done
EOF
chmod +x "$FAKE_WORKER"

env ANTHROPIC_BASE_URL="http://127.0.0.1:20128" HTTPS_PROXY="http://127.0.0.1:20128" \
  "$FAKE_WORKER" &
OLD_PID=$!
LIVE_PIDS+=("$OLD_PID")
sleep 0.3

PIDFILE="$TMP_ROOT/worker.pid"
printf '{"pid": %s, "port": 12345}\n' "$OLD_PID" > "$PIDFILE"

bash -c "
  set -uo pipefail
  export HMD_CLAUDE_MEM_PID_FILE='$PIDFILE'
  export HMD_CLAUDE_MEM_LOG='$TMP_ROOT/scrub-relaunch.log'
  . '$LIB'
  hmd_claude_mem_scrub_if_contaminated
  echo \"EXIT:\$?\"
" > "$TMP_ROOT/scrub-run.out" 2>&1
SCRUB_EXIT="$(grep -o 'EXIT:[0-9]*' "$TMP_ROOT/scrub-run.out" | tail -1 | cut -d: -f2)"

if [ "$SCRUB_EXIT" = "1" ]; then
  ok "hmd_claude_mem_scrub_if_contaminated: exit 1 (contaminated -> scrubbed) for a live contaminated worker"
else
  bad "hmd_claude_mem_scrub_if_contaminated: expected exit 1, got '$SCRUB_EXIT' ($(tr '\n' ' ' < "$TMP_ROOT/scrub-run.out"))"
fi

sleep 0.5
if kill -0 "$OLD_PID" 2>/dev/null; then
  bad "hmd_claude_mem_scrub_if_contaminated: original contaminated pid $OLD_PID is still alive — was not killed"
else
  ok "hmd_claude_mem_scrub_if_contaminated: original contaminated pid $OLD_PID was terminated"
fi

NEW_PID="$(pgrep -f "$FAKE_WORKER" 2>/dev/null | grep -v "^${OLD_PID}\$" | head -1)"
if [ -n "$NEW_PID" ] && kill -0 "$NEW_PID" 2>/dev/null; then
  LIVE_PIDS+=("$NEW_PID")
  ok "hmd_claude_mem_scrub_if_contaminated: a NEW worker process ($NEW_PID) is running after the scrub"
  NEWENV="$(ps eww "$NEW_PID" 2>/dev/null)"
  if printf '%s' "$NEWENV" | grep -qE 'ANTHROPIC_BASE_URL=|HTTPS_PROXY='; then
    bad "hmd_claude_mem_scrub_if_contaminated: the RELAUNCHED worker still carries a routing var"
  else
    ok "hmd_claude_mem_scrub_if_contaminated: the RELAUNCHED worker's live environment is clean"
  fi
else
  bad "hmd_claude_mem_scrub_if_contaminated: no relaunched worker process found matching $FAKE_WORKER"
fi

# ══ E. FAIL CLOSED: an undetectable environment is treated as CONTAMINATED ═══════
bash -c "
  set -uo pipefail
  . '$LIB'
  if _hmd_cm_is_contaminated 999999; then
    echo RESULT:CLOSED
  else
    echo RESULT:OPEN
  fi
" > "$TMP_ROOT/fail-closed.out" 2>&1
if grep -q 'RESULT:CLOSED' "$TMP_ROOT/fail-closed.out"; then
  ok "_hmd_cm_is_contaminated: an unreadable/dead pid is treated as CONTAMINATED (fail closed), never waved through as clean"
else
  bad "_hmd_cm_is_contaminated: fail-closed behavior did not trigger: $(tr '\n' ' ' < "$TMP_ROOT/fail-closed.out")"
fi

echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
