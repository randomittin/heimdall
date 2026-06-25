#!/usr/bin/env bash
# cp-job-hardening.test.sh — TWO defensive hardening fixes for the Cloud Run Job
# execution path, same "the real target lacks what the local has" class the §4 flight
# fix addressed. Both were flagged by the incident diagnosis of the krdp7 red signature.
#
# THE TWO BUGS (both make a benign condition look like a hard FAILED execution):
#
#   FIX 1 — cp_server.make_context. It does os.makedirs(<home>/control-plane/scratch/<id>).
#     If HEIMDALL_HOME / the runtime home is ever ABSENT on a Cloud Run Job, that makedirs
#     hits the READ-ONLY container rootfs -> PermissionError -> run_job re-raises -> the
#     run-job entrypoint exits 1 with the job stuck `running`. The scratch is ephemeral
#     per-execution anyway, so when no home is supplied it must default to a guaranteed-
#     writable temp base instead of the read-only rootfs. When a home IS supplied the path
#     must stay BYTE-IDENTICAL to today (prod sets HEIMDALL_HOME=/app/state).
#
#   FIX 2 — the `run-job` CLI entrypoint. A BARE `run-job` with no job_id (the Cloud Run
#     Job's default args, or an accidental bare `gcloud run jobs execute`) used to exit 2,
#     which Cloud Run marks the execution red FAILED (the alarming-but-benign krdp7
#     signature). A no-id invocation is nothing to run — it must be a CLEAN no-op (exit 0
#     + a clear message). The genuine error — a DISPATCHED id that is MISSING from the
#     store — must STILL exit nonzero (2 + "no such job") so a real dispatch bug surfaces.
#
# WHAT THIS GATE ASSERTS (each runnable for $0, zero GCP):
#   1. bare `heimdall-control-plane run-job` (no id)      -> exit 0 + benign message.
#   2. `run-job <unknown-id>` (a dispatched id missing)   -> exit 2 + "no such job".
#   3. make_context with HEIMDALL_HOME UNSET              -> writable temp scratch, no
#                                                            PermissionError, usable ctx.
#   4. make_context with HEIMDALL_HOME SET                -> <home>/control-plane/scratch
#                                                            (byte-identical to today).
#
# Exit 0 == every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
CLI="$REPO/bin/heimdall-control-plane"
export LIB

[ -f "$LIB/cp_server.py" ] || { echo "FATAL: $LIB/cp_server.py missing" >&2; exit 2; }
[ -x "$CLI" ]              || { echo "FATAL: $CLI not executable" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "cp-jobhard.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# Scrub any inherited HEIMDALL_HOME so the FIX-1 "unset" case is genuinely unset, and the
# CLI cases use only the homes this test supplies explicitly.
unset HEIMDALL_HOME

# ── FIX 2, assertion 1 — bare run-job (no id) is a CLEAN no-op (exit 0 + benign msg) ──
# Simulates the Cloud Run Job default-args invocation: the entrypoint is `run-job` with
# no job_id. This is nothing to run, not an error.
set +e
OUT="$("$CLI" run-job 2>&1)"
RC=$?
set -e
if [ "$RC" -eq 0 ]; then
  ok "bare run-job (no id) exits 0 (clean no-op, not the FAILED-marking exit 2)"
else
  bad "bare run-job (no id) exited $RC (expected 0 — a no-id invocation is nothing to run)"
fi
case "$OUT" in
  *"no job_id"*) ok "bare run-job prints the benign no-id message (got: $OUT)" ;;
  *)             bad "bare run-job message did not name the no-id condition (got: $OUT)" ;;
esac

# ── FIX 2, assertion 2 — a DISPATCHED unknown id is a REAL error (exit 2 + no such job) ──
# A job_id WAS supplied (so it was dispatched) but is absent from the store — a genuine
# dispatch/operator bug worth surfacing as a failed execution. Must stay nonzero.
set +e
OUT2="$("$CLI" run-job no-such-id-xyz --home "$WORK/cphome" 2>&1)"
RC2=$?
set -e
if [ "$RC2" -eq 2 ]; then
  ok "run-job <unknown-id> exits 2 (a dispatched-but-missing job is a real error)"
else
  bad "run-job <unknown-id> exited $RC2 (expected 2 — the real-error path must be preserved)"
fi
case "$OUT2" in
  *"no such job"*) ok "run-job <unknown-id> prints 'no such job' (the real-error message)" ;;
  *)               bad "run-job <unknown-id> did not print 'no such job' (got: $OUT2)" ;;
esac

# ── FIX 1 — make_context falls back to a writable temp when HEIMDALL_HOME is ABSENT ──
# Drives the REAL cp_server.make_context with HEIMDALL_HOME unset, asserting it does NOT
# raise (no PermissionError on a read-only rootfs), returns a usable context, and the
# scratch dir lives under the system temp base (the guaranteed-writable fallback) — NOT
# under any control-plane/scratch tree rooted at a (possibly read-only) home.
HARNESS="$WORK/ctx_unset.out"
set +e
LIB="$LIB" "$PY" - >"$HARNESS" 2>&1 <<'PYEOF'
import os, sys, tempfile
# HEIMDALL_HOME must be ABSENT for this case — scrub it from the child env.
os.environ.pop("HEIMDALL_HOME", None)
sys.path.insert(0, os.environ["LIB"])
import cp_server
ctx = cp_server.make_context("act-unset-home")
scratch = ctx.scratch_dir
tmp = os.path.realpath(tempfile.gettempdir())
real = os.path.realpath(scratch)
under_tmp = real == tmp or real.startswith(tmp + os.sep)
exists = os.path.isdir(scratch)
print("SCRATCH %s" % scratch)
print("UNDER_TMP %s" % ("yes" if under_tmp else "no"))
print("EXISTS %s" % ("yes" if exists else "no"))
PYEOF
RC3=$?
set -e
if [ "$RC3" -eq 0 ]; then
  ok "make_context with HEIMDALL_HOME unset does NOT raise (no read-only-rootfs PermissionError)"
else
  bad "make_context with HEIMDALL_HOME unset raised (exit $RC3): $(cat "$HARNESS")"
fi
if grep -q "^UNDER_TMP yes" "$HARNESS"; then
  ok "make_context scratch falls back UNDER the system temp base when home is absent"
else
  bad "make_context scratch is NOT under the temp base when home absent: $(grep '^SCRATCH' "$HARNESS")"
fi
if grep -q "^EXISTS yes" "$HARNESS"; then
  ok "make_context returns a usable (existing) scratch dir when home is absent"
else
  bad "make_context scratch dir does not exist when home absent: $(grep '^SCRATCH' "$HARNESS")"
fi

# ── FIX 1 — with HEIMDALL_HOME SET, the path is BYTE-IDENTICAL to today's behavior ──
# The prod config sets HEIMDALL_HOME=/app/state; the supplied-home path must not move.
# Assert the scratch is EXACTLY <home>/control-plane/scratch/<action_id> for both the
# explicit `home=` arg and the HEIMDALL_HOME env (the two ways a home is supplied).
# IsolatedContext abspath()s its scratch_dir, so the expected is abspath'd to match.
HARNESS2="$WORK/ctx_set.out"
SETHOME="$WORK/sethome"
set +e
LIB="$LIB" SETHOME="$SETHOME" "$PY" - >"$HARNESS2" 2>&1 <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_server
sethome = os.environ["SETHOME"]

# (a) explicit home= argument.
ctx_arg = cp_server.make_context("act-set-arg", home=sethome)
want_a = os.path.abspath(os.path.join(sethome, "control-plane", "scratch", "act-set-arg"))
print("ARG %s" % ("ok" if ctx_arg.scratch_dir == want_a
                  else "MISMATCH got=%s want=%s" % (ctx_arg.scratch_dir, want_a)))

# (b) HEIMDALL_HOME env (no explicit arg) — resolved via issue_queue.heimdall_home().
os.environ["HEIMDALL_HOME"] = sethome
ctx_env = cp_server.make_context("act-set-env")
want_e = os.path.abspath(os.path.join(sethome, "control-plane", "scratch", "act-set-env"))
print("ENV %s" % ("ok" if ctx_env.scratch_dir == want_e
                  else "MISMATCH got=%s want=%s" % (ctx_env.scratch_dir, want_e)))
PYEOF
RC4=$?
set -e
if [ "$RC4" -eq 0 ] && grep -q "^ARG ok" "$HARNESS2"; then
  ok "make_context with explicit home= uses <home>/control-plane/scratch (byte-identical)"
else
  bad "make_context explicit-home path moved: $(grep '^ARG' "$HARNESS2" || cat "$HARNESS2")"
fi
if grep -q "^ENV ok" "$HARNESS2"; then
  ok "make_context with HEIMDALL_HOME set uses <home>/control-plane/scratch (byte-identical)"
else
  bad "make_context HEIMDALL_HOME path moved: $(grep '^ENV' "$HARNESS2" || cat "$HARNESS2")"
fi

# ── verdict ──
echo
echo "============================================================"
echo "cp-job-hardening: $PASS passed, $FAIL failed"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
