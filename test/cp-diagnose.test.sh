#!/usr/bin/env bash
# cp-diagnose.test.sh — the operator self-check command (`heimdall-control-plane
# diagnose`) over the REAL substrate.
#
# DESIGN DOSSIER §C (rich diagnostics — operator-facing self-check) + §3/§9/§10.
# The diagnose command is the operator's "is the control plane sane?" pre-flight:
# it runs cp_selfcheck against a real ${HEIMDALL_HOME}/control-plane/ tree and
# reports a PASS/FAIL table (text) or a structured object (--json), exiting nonzero
# iff a CRITICAL check fails. It NEVER prints secret/key material — status + paths
# only (the no-secret-by-construction discipline §5/§7 extended to the self-check).
#
# Proven here against the REAL CLI + cp_selfcheck (no mocks of the thing under test):
#
#   A. RUNS + STRUCTURE
#      A1. `diagnose --json` emits a single JSON object with overall + checks[].
#      A2. each check carries id/critical/ok/status/remedy — a structured pass/fail
#          plus a human remedy string.
#      A3. the text table prints a PASS/FAIL line per check + an overall verdict.
#
#   B. SEMANTICS (real home state drives the verdict)
#      B1. a freshly-initialized home with a registered identity → all critical
#          checks PASS → exit 0 (the happy operator path).
#      B2. removing the PKI key registry → the pki_key check FAILS (critical) →
#          nonzero exit (the self-check actually inspects real state, not canned).
#      B3. a writable audit store → audit_writable PASSES; the check probes the
#          real path under control-plane/audit/.
#
#   C. NO-LEAK (the privacy guarantee — falsifiable)
#      C1. a real private key is generated + registered, yet NEITHER the text NOR
#          the JSON diagnose output contains the private seed material. Status +
#          paths only — the self-check reports the key is PRESENT, never its bytes.
#
# Falsifiable: break the no-leak scrub (print the seed) → C1 FAILS; make a check
# ignore real state (always-true) → B2 FAILS.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$REPO/bin/heimdall-control-plane"
PY="$(command -v python3 || command -v python)"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

SUF="$(printf 'X%.0s' 1 2 3 4 5 6)"
WORK="$(mktemp -d -t "cp-diagnose.$SUF")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

export HEIMDALL_HOME="$WORK/cphome"
mkdir -p "$HEIMDALL_HOME"

echo "cp-diagnose: operator self-check over the real substrate"
echo "  home=$HEIMDALL_HOME"

# crypto-gate: the PKI checks need an Ed25519 backend. Without it the self-check
# still runs (degraded), but the key-present cardinals cannot be exercised.
export CLI
HAVE_CRYPTO="$("$PY" - <<'PYEOF'
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.environ["CLI"]), "lib"))
import cp_auth
print("1" if cp_auth.crypto_available() else "0")
PYEOF
)" 2>/dev/null || HAVE_CRYPTO="0"

# ── register a real identity so the happy-path checks have something to pass on ──
DEV_HAID="haid-diagnose-dev"
if [ "$HAVE_CRYPTO" = "1" ]; then
  "$CLI" identity --haid "$DEV_HAID" --home "$HEIMDALL_HOME" \
    >"$WORK/ident.json" 2>"$WORK/ident.err" \
    && ok "setup: real PKI identity registered ($DEV_HAID)" \
    || { bad "setup: identity registration failed"; cat "$WORK/ident.err" >&2; }
else
  echo "  (no crypto backend — PKI cardinals run in degraded mode)"
fi

# ── A. RUNS + STRUCTURE ────────────────────────────────────────────────────────
set +e
"$CLI" diagnose --json --home "$HEIMDALL_HOME" >"$WORK/diag.json" 2>"$WORK/diag.err"
JSON_RC=$?
set -e

"$PY" - "$WORK/diag.json" <<'PYEOF' && ok "A1 diagnose --json emits one JSON object with overall + checks[]" || bad "A1 diagnose --json not a valid object with overall+checks"
import json, sys
obj = json.load(open(sys.argv[1]))
assert isinstance(obj, dict), "not an object"
assert "overall" in obj, "no overall"
assert isinstance(obj.get("checks"), list) and obj["checks"], "no checks[]"
PYEOF

"$PY" - "$WORK/diag.json" <<'PYEOF' && ok "A2 every check has id/critical/ok/status/remedy" || bad "A2 a check is missing the structured fields"
import json, sys
obj = json.load(open(sys.argv[1]))
for c in obj["checks"]:
    for k in ("id", "critical", "ok", "status", "remedy"):
        assert k in c, "check %r missing %s" % (c.get("id"), k)
    assert isinstance(c["critical"], bool) and isinstance(c["ok"], bool)
    assert isinstance(c["remedy"], str) and c["remedy"]
PYEOF

set +e
"$CLI" diagnose --home "$HEIMDALL_HOME" >"$WORK/diag.txt" 2>&1
TXT_RC=$?
set -e
grep -qiE "PASS|FAIL" "$WORK/diag.txt" \
  && grep -qiE "overall|verdict|result" "$WORK/diag.txt" \
  && ok "A3 text table prints per-check PASS/FAIL + an overall verdict" \
  || { bad "A3 text table missing PASS/FAIL lines or overall verdict"; cat "$WORK/diag.txt"; }

# ── B. SEMANTICS ───────────────────────────────────────────────────────────────
if [ "$HAVE_CRYPTO" = "1" ]; then
  # B1: a fresh, identity-registered home → all CRITICAL checks pass → exit 0.
  "$PY" - "$WORK/diag.json" <<'PYEOF' && ok "B1 fresh+registered home → all critical checks PASS" || bad "B1 a critical check failed on the happy path"
import json, sys
obj = json.load(open(sys.argv[1]))
broke = [c["id"] for c in obj["checks"] if c["critical"] and not c["ok"]]
assert not broke, "critical fail: %r" % broke
PYEOF
  [ "$JSON_RC" -eq 0 ] && ok "B1 happy-path diagnose exits 0" || bad "B1 happy-path exit was $JSON_RC, want 0"
else
  echo "  (skipped B1 — needs crypto for the key-present cardinal)"
fi

# B2: remove the key registry → the pki_key critical check FAILS → nonzero exit.
KEYS="$HEIMDALL_HOME/control-plane/auth/keys.json"
if [ "$HAVE_CRYPTO" = "1" ] && [ -f "$KEYS" ]; then
  mv "$KEYS" "$KEYS.bak"
  set +e
  "$CLI" diagnose --json --home "$HEIMDALL_HOME" >"$WORK/diag2.json" 2>/dev/null
  RC2=$?
  set -e
  mv "$KEYS.bak" "$KEYS"
  "$PY" - "$WORK/diag2.json" <<'PYEOF' && ok "B2 missing PKI key registry → pki_key check FAILS" || bad "B2 pki_key did not fail on a missing registry (canned?)"
import json, sys
obj = json.load(open(sys.argv[1]))
pk = [c for c in obj["checks"] if c["id"] == "pki_key"]
assert pk and not pk[0]["ok"], "pki_key still ok with no registry"
PYEOF
  [ "$RC2" -ne 0 ] && ok "B2 a failing critical check → nonzero exit ($RC2)" || bad "B2 exit was 0 despite a critical failure"
else
  echo "  (skipped B2 — needs a registered key to remove)"
fi

# B3: the audit store is writable in a real home → audit_writable PASSES.
"$PY" - "$WORK/diag.json" <<'PYEOF' && ok "B3 writable audit store → audit_writable PASSES (probes the real path)" || bad "B3 audit_writable did not pass on a writable home"
import json, sys
obj = json.load(open(sys.argv[1]))
aw = [c for c in obj["checks"] if c["id"] == "audit_writable"]
assert aw, "no audit_writable check"
assert aw[0]["ok"], "audit_writable failed on a writable home"
PYEOF

# ── C. NO-LEAK (falsifiable privacy guarantee) ─────────────────────────────────
if [ "$HAVE_CRYPTO" = "1" ]; then
  # the registered private seed (kept locally; must NEVER appear in diagnose output).
  SEED="$("$PY" - "$WORK/ident.json" <<'PYEOF'
import json, sys
print(json.load(open(sys.argv[1])).get("private_key", ""))
PYEOF
)"
  if [ -n "$SEED" ]; then
    if grep -qF "$SEED" "$WORK/diag.txt" "$WORK/diag.json" 2>/dev/null; then
      bad "C1 the private seed LEAKED into diagnose output"
    else
      ok "C1 the private seed is ABSENT from BOTH the text + JSON diagnose output"
    fi
    # the self-check still reports the key is PRESENT (status, not bytes).
    "$PY" - "$WORK/diag.json" <<'PYEOF' && ok "C1 pki_key reports PRESENT (status+path, never the seed)" || bad "C1 pki_key did not report the key present on a registered home"
import json, sys
obj = json.load(open(sys.argv[1]))
pk = [c for c in obj["checks"] if c["id"] == "pki_key"]
assert pk and pk[0]["ok"], "pki_key not ok on a registered home"
PYEOF
  else
    bad "C1 could not extract the seed to assert no-leak"
  fi
else
  echo "  (skipped C1 — needs crypto to generate a real seed)"
fi

echo
echo "============================================================"
printf "cp-diagnose: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
