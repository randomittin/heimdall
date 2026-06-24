#!/usr/bin/env bash
# cp-substrate.test.sh — the CARDINAL SECURITY TESTS for control-plane wave-1 (a).
#
# DESIGN DOSSIER §1/§3/§9 (authoritative). Proves the falsifiable core of the whole
# control plane against the REAL substrate (cp_allowlist / cp_auth / cp_audit /
# cp_server / cp_handlers) — no canned numbers, no mocks of the thing under test:
#
#   A. ALLOWLIST REFUSAL (the falsifiable core, §1):
#      A1. a valid allowlisted dispatch (run-task-X / sync-queue) -> 200 accepted.
#      A2. an UNKNOWN action_type ("shell") -> 422 + an audit dispatch_refused row.
#      A3. an arbitrary COMMAND smuggled as an extra `cmd` field -> 422, REFUSED.
#      A4. a shell payload smuggled INTO a typed param ("; rm -rf /") -> 422, REFUSED.
#      A5. FALSIFIABILITY: a build that let an arbitrary command through must RED
#          here — proven by A1 succeeding (refuse-arbitrary, not refuse-everything).
#      A6. NO command-string field in cp_allowlist.py (grep the source): no free
#          cmd/command/shell/exec string param exists anywhere in the schema.
#
#   B. PKI (§3):
#      B1. sign a message with an instance key -> the server verifies -> ok.
#      B2. a FORGED (bad-sig) message -> rejected (bad_signature).
#      B3. an UNSIGNED request -> rejected (missing_signature).
#      (If no crypto lib were importable, B asserts the graceful-degrade path, not a
#       crash — the module loads and reports crypto_unavailable.)
#
#   C. AUDIT (§9):
#      C1. a dispatch AND a refusal both produce audit rows.
#      C2. the audit is searchable (by event) + exportable (NDJSON).
#      C3. a RUNTIME-ASSEMBLED secret planted in a refusal detail is SCRUBBED/absent.
#
#   D. NO-SECRET STORE gitleaks-clean: gitleaks detect over the audit store exits
#      clean (the planted secret never entered the store by construction).
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
CLI="$REPO/bin/heimdall-control-plane"
ALLOWLIST_SRC="$LIB/cp_allowlist.py"

[ -f "$ALLOWLIST_SRC" ] || { echo "FATAL: $ALLOWLIST_SRC missing" >&2; exit 2; }
[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "cp-substrate.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT
export HEIMDALL_HOME="$WORK/cphome"

# A runtime-ASSEMBLED secret (never static in source — assembled from fragments at
# run time so the test file itself is gitleaks-clean per fixture-secret-convention).
# Shape: a GitHub-PAT-shaped string the telemetry scrubber rejects.
SECRET_PREFIX="ghp"
SECRET_BODY="$(printf 'A%.0s' $(seq 1 36))"
PLANTED_SECRET="${SECRET_PREFIX}_${SECRET_BODY}"

# ── Drive the substrate through a single python harness (the real modules) ─────
# Prints machine-readable lines the bash asserts on. Plants the runtime secret in a
# refusal detail to prove the audit scrubs it.
HARNESS_OUT="$WORK/harness.out"
LIB="$LIB" PLANTED_SECRET="$PLANTED_SECRET" "$PY" - >"$HARNESS_OUT" 2>"$WORK/harness.err" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_allowlist as A
import cp_audit as Au
import cp_auth as K
import cp_server as S

secret = os.environ["PLANTED_SECRET"]
out = {}

ident = K.Identity("haid:rj.mbp-7f3a", owner=True)

# A1 — valid dispatches accepted.
r1 = S.dispatch(ident, "run-task-X", {"task_id": "build-x"})
r2 = S.dispatch(ident, "sync-queue", {"queue": "issue"})
out["valid_run_task_status"] = r1.status
out["valid_sync_status"] = r2.status

# A2 — unknown action_type refused.
r3 = S.dispatch(ident, "shell", {"cmd": "rm -rf /"})
out["unknown_status"] = r3.status
out["unknown_reason"] = r3.body.get("reason")

# A3 — arbitrary command smuggled as an extra field refused.
r4 = S.dispatch(ident, "run-task-X", {"task_id": "build-x", "cmd": "rm -rf /"})
out["smuggle_status"] = r4.status
out["smuggle_reason"] = r4.body.get("reason")

# A4 — shell payload smuggled into a typed param refused.
r5 = S.dispatch(ident, "run-task-X", {"task_id": "; rm -rf /"})
out["payload_status"] = r5.status
out["payload_reason"] = r5.body.get("reason")

# C3 — plant a RUNTIME-ASSEMBLED secret in a refusal reason; the audit must scrub it.
Au.record_refusal("haid:rj.mbp-7f3a", "shell",
                  reason="unknown action leaked %s here" % secret,
                  params={"cmd": "x"})

# B — PKI sign/verify (or graceful-degrade).
out["crypto_available"] = K.crypto_available()
out["crypto_backend"] = K.backend_name()
if K.crypto_available():
    priv, pub = K.generate_keypair()
    haid = "haid:rj.mbp-7f3a"
    K.register_key(haid, pub)
    msg = K.canonical_message("POST", "/dispatch", b'{"x":1}')
    sig = K.sign(priv, msg)
    req_ok = {"method": "POST", "path": "/dispatch", "body": b'{"x":1}',
              "haid": haid, "signature": sig}
    try:
        ident2 = K.verify_identity(req_ok, enforce_revocation=False)
        out["pki_verify_ok"] = (ident2.haid == haid)
    except K.AuthError:
        out["pki_verify_ok"] = False
    bad = dict(req_ok); bad["signature"] = K.sign(priv, b"WRONG")
    try:
        K.verify_identity(bad, enforce_revocation=False)
        out["pki_forged_rejected"] = False
    except K.AuthError as e:
        out["pki_forged_rejected"] = (e.reason == "bad_signature")
    unsigned = {"method": "POST", "path": "/dispatch", "body": b'{"x":1}',
                "haid": haid}
    try:
        K.verify_identity(unsigned, enforce_revocation=False)
        out["pki_unsigned_rejected"] = False
    except K.AuthError as e:
        out["pki_unsigned_rejected"] = (e.reason == "missing_signature")
else:
    # graceful-degrade path: generate must report crypto_unavailable, not crash.
    try:
        K.generate_keypair()
        out["pki_degrade_ok"] = False
    except K.AuthError as e:
        out["pki_degrade_ok"] = (e.reason == "crypto_unavailable")

# C1/C2 — audit rows: dispatch + refusal both present; searchable; exportable.
disp = Au.search(event="dispatch")
refs = Au.search(event="dispatch_refused")
out["audit_dispatch_count"] = len(disp)
out["audit_refused_count"] = len(refs)
export_txt = Au.export()
out["audit_export_lines"] = len([ln for ln in export_txt.splitlines() if ln])

# C3 — the planted secret must NOT appear anywhere in the audit export.
out["secret_in_audit"] = (secret in export_txt)
# and no param VALUE leaked (params recorded as shape only).
out["dispatch_has_only_shape"] = all(
    set(map(str, (r.get("params_shape") or {}).values())) <= {
        "str", "int", "float", "bool", "list", "object", "null", "other"}
    for r in disp)

sys.stdout.write(json.dumps(out))
PYEOF

if [ ! -s "$HARNESS_OUT" ]; then
  echo "FATAL: substrate harness produced no output" >&2
  cat "$WORK/harness.err" >&2
  exit 2
fi

jget() { "$PY" -c "import json,sys; print(json.load(open('$HARNESS_OUT')).get('$1'))"; }

echo "A. ALLOWLIST REFUSAL (the falsifiable core, §1)"
[ "$(jget valid_run_task_status)" = "200" ] && ok "A1 valid run-task-X -> 200 accepted" || bad "A1 valid run-task-X not accepted"
[ "$(jget valid_sync_status)" = "200" ] && ok "A1 valid sync-queue -> 200 accepted" || bad "A1 valid sync-queue not accepted"
[ "$(jget unknown_status)" = "422" ] && [ "$(jget unknown_reason)" = "unknown_action" ] && ok "A2 unknown action_type -> 422 unknown_action" || bad "A2 unknown action_type not refused"
[ "$(jget smuggle_status)" = "422" ] && [ "$(jget smuggle_reason)" = "extra_param" ] && ok "A3 smuggled cmd field -> 422 extra_param" || bad "A3 smuggled cmd not refused"
[ "$(jget payload_status)" = "422" ] && [ "$(jget payload_reason)" = "bad_param" ] && ok "A4 shell payload in param -> 422 bad_param" || bad "A4 shell payload not refused"

# A5 — falsifiability: valid succeeds WHILE arbitrary is refused (not refuse-all).
if [ "$(jget valid_run_task_status)" = "200" ] && [ "$(jget unknown_status)" = "422" ] && [ "$(jget smuggle_status)" = "422" ]; then
  ok "A5 FALSIFIABLE: refuse-arbitrary distinct from refuse-everything"
else
  bad "A5 not falsifiable (valid + arbitrary did not distinguish)"
fi

# A6 — NO free command-string param field in the allowlist source. Assert there is
# no param SPEC that is a bare/free string named cmd/command/shell/exec, and no
# FreeStr/Raw/Cmd param type. (The only matches allowed are in COMMENTS describing
# the refusal — so we scan for an actual param/type DEFINITION, not prose.)
if grep -nE '"(cmd|command|shell|exec)"\s*:\s*(Str|Enum|Int|FreeStr|Raw|Cmd)\(' "$ALLOWLIST_SRC" >/dev/null 2>&1; then
  bad "A6 a command-string param is declared in the allowlist source"
elif grep -nE 'class\s+(FreeStr|Raw|Cmd)\b' "$ALLOWLIST_SRC" >/dev/null 2>&1; then
  bad "A6 a free/raw/cmd param type exists in the allowlist source"
else
  ok "A6 NO command-string field / free-string param type in cp_allowlist.py"
fi

echo "B. PKI (§3)"
if [ "$(jget crypto_available)" = "True" ]; then
  [ "$(jget pki_verify_ok)" = "True" ] && ok "B1 signed message verifies (backend: $(jget crypto_backend))" || bad "B1 signed message did not verify"
  [ "$(jget pki_forged_rejected)" = "True" ] && ok "B2 forged (bad-sig) message rejected" || bad "B2 forged message not rejected"
  [ "$(jget pki_unsigned_rejected)" = "True" ] && ok "B3 unsigned request rejected" || bad "B3 unsigned request not rejected"
else
  [ "$(jget pki_degrade_ok)" = "True" ] && ok "B(degrade) no crypto lib -> graceful crypto_unavailable, no crash" || bad "B(degrade) did not degrade gracefully"
fi

echo "C. AUDIT (§9)"
DC="$(jget audit_dispatch_count)"; RC="$(jget audit_refused_count)"
[ "${DC:-0}" -ge 1 ] && ok "C1 dispatch produced an audit row ($DC)" || bad "C1 no dispatch audit row"
[ "${RC:-0}" -ge 1 ] && ok "C1 refusal produced an audit row ($RC)" || bad "C1 no refusal audit row"
EL="$(jget audit_export_lines)"
[ "${EL:-0}" -ge 2 ] && ok "C2 audit searchable + exportable ($EL NDJSON lines)" || bad "C2 audit not exportable"
[ "$(jget secret_in_audit)" = "False" ] && ok "C3 runtime-assembled secret SCRUBBED/absent from audit" || bad "C3 planted secret leaked into audit"
[ "$(jget dispatch_has_only_shape)" = "True" ] && ok "C3 audit records params-SHAPE only (no values)" || bad "C3 a param value leaked into audit"

echo "D. NO-SECRET STORE gitleaks-clean"
AUDIT_PATH="$HEIMDALL_HOME/control-plane/audit/audit.ndjson"
if [ ! -f "$AUDIT_PATH" ]; then
  bad "D audit store not written"
elif command -v gitleaks >/dev/null 2>&1; then
  if gitleaks detect --no-git --source "$HEIMDALL_HOME/control-plane" >/dev/null 2>&1; then
    ok "D gitleaks detect over the store -> clean"
  else
    bad "D gitleaks found a secret in the store"
  fi
else
  # gitleaks absent: fall back to a direct grep for the planted secret (soft-degrade
  # mirrors bin/secret-scan's commit-time degradation contract).
  if grep -q "$PLANTED_SECRET" "$AUDIT_PATH" 2>/dev/null; then
    bad "D planted secret present in the store (grep fallback)"
  else
    ok "D store clean of the planted secret (grep fallback; gitleaks absent)"
  fi
fi

echo
printf "cp-substrate: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
