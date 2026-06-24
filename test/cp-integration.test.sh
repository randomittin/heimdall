#!/usr/bin/env bash
# cp-integration.test.sh — THE CONTROL-PLANE END-TO-END INTEGRATION GATE (wave-3, §11).
#
# DESIGN DOSSIER §11 (authoritative) + §1/§2/§3/§4/§5/§7/§8/§9. This is NOT a unit
# test of any one piece — every cp_* unit suite already exists (cp-substrate / cp-jobs
# / cp-approval / cp-notify / cp-observe / cp-scheduler). THIS gate drives the REAL,
# WIRED cross-piece flow end-to-end against the whole substrate present on main HEAD
# (the metering lesson: a unit-only gate proves the pieces, not the SEAM between them).
#
# THE HEADLINE FLOW (one wired story, §11 L223):
#   a client STARTS a server-hosted allowlisted job -> the CLIENT PROCESS EXITS
#   (disconnect) -> the job CONTINUES server-side in a DETACHED OS process + COMPLETES
#   -> NOTIFY fires (job_complete, DATA only) -> a gated action surfaces to the OWNER
#   who APPROVES it -> AND an arbitrary-command dispatch is REFUSED. The falsifiable
#   core: the refusal half is proven by a VALID dispatch also succeeding.
#
# THE 8 ASSERTIONS (each a committed block; the three CARDINALS are falsifiable):
#   1. THE FLIGHT FIX (cardinal) — job survives client-process exit via a DETACHED OS
#      process (NOT inline start_route); a FRESH process reads state=done + result.
#      Falsifiable: a job that died on client exit reds F2.
#   2. NOTIFY FIRES — job completion produces a job_complete ping to the owner, DATA
#      ONLY (the notification carries no executable/command field; notification_executes
#      is always False — the inverse-of-RCE).
#   3. OWNER-GATED ACTION — a requires_gate action does NOT dispatch, surfaces to the
#      owner, OWNER APPROVES -> dispatches (audited); owner can OVERRIDE; a NON-owner
#      approve is REJECTED.
#   4. ALLOWLIST REFUSAL (cardinal) — an arbitrary-command dispatch (unknown action /
#      smuggled cmd / shell payload in a param) is REFUSED (422 + audit dispatch_refused);
#      a VALID dispatch succeeds. Falsifiable: a build that let arbitrary through reds it.
#   5. PKI — instance<->server comms are SIGNED+VERIFIED over the REAL http server; a
#      forged/unsigned request is rejected (401).
#   6. NO-SECRET — a RUNTIME-ASSEMBLED secret pushed via ingest is scrubbed/absent;
#      gitleaks over the observe + audit + job + approval + notify stores is clean.
#   7. AUDIT CAPTURES EVERYTHING — every dispatch + approval + refusal is in the audit
#      log (searchable + exportable).
#   8. CONTROL != FLEET (cardinal) — the isolated job worker CANNOT read the PKI private
#      key / audit log (the §2 isolation boundary). Falsifiable: a breach flips a flag.
#
# DISCIPLINE: isolated throwaway HOME + ephemeral Ed25519 keys; planted secret is
# RUNTIME-ASSEMBLED (never static — heimdall-fixture-secret-convention.md); no live
# network (notify uses no connectors, the inbox is a local data file); detached worker
# processes are REAPED; the tree is clean after. Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
CLI="$REPO/bin/heimdall-control-plane"

for f in cp_server.py cp_auth.py cp_audit.py cp_allowlist.py cp_handlers.py \
         cp_jobstore.py cp_worker.py cp_approval.py cp_notify.py cp_ingest.py \
         cp_scheduler.py cp_dashboard.py; do
  [ -f "$LIB/$f" ] || { echo "FATAL: $LIB/$f missing (wired server not present)" >&2; exit 2; }
done
[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "cp-integration.$(printf 'X%.0s' 1 2 3 4 5 6)")"
# Track detached worker PIDs so the trap REAPS them (no orphan processes after).
WORKER_PIDS=""
cleanup() {
  for p in $WORKER_PIDS; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

export HEIMDALL_HOME="$WORK/cphome"
export LIB
export WORK
CP_HOME="$HEIMDALL_HOME/control-plane"

# A RUNTIME-ASSEMBLED secret — never a static literal in source (per the fixture-secret
# convention). The fragments are individually non-matching; only the concatenation forms
# a gitleaks-detectable GitHub-PAT-shaped token at run time. Used to prove the ingest +
# audit stores scrub it / never store it (assertion #6).
_GP_PRE="ghp_"
_GP_A="$(printf 'a%.0s' $(seq 1 20))"
_GP_B="$(printf 'B%.0s' $(seq 1 16))"
PLANTED_SECRET="${_GP_PRE}${_GP_A}${_GP_B}"
export PLANTED_SECRET

echo "============================================================"
echo "CONTROL-PLANE END-TO-END INTEGRATION GATE (§11)"
echo "  home=$HEIMDALL_HOME"
echo "============================================================"
