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

# ── D. FIRESTORE-BACKED: diagnose is BACKEND-AWARE (no BackendUnavailable) ──────
# THE PATH()-UNDER-FIRESTORE CLASS (the same break already fixed on the serving paths).
# Several diagnose checks resolve store locations through a *_dir()/keys_path() accessor,
# each of which routes to backend.path() — and FirestoreBackend RAISES BackendUnavailable
# on path() by design (an external store has no local file to point at). So an operator who
# runs `diagnose` against a firestore-backed deploy — exactly when they want to debug that
# deploy — used to crash the run. This proves the fix: every check is backend-aware
# (mirrors cp_diag._stores_reachable), so diagnose runs CLEAN under
# HEIMDALL_STATE_BACKEND=firestore and reports a coherent verdict, never a crash.

# D1: run cp_selfcheck.run_all() against a FAKE firestore backend (path() refused like the
# real one; the read/get ops serve cleanly) — the hermetic unit, no firestore lib needed.
# NONE of the checks may raise; the backend-probed CRITICAL checks pass on a healthy backend.
# Mirrors cp-diag.test.sh's fake-backend harness.
D1="$(LIB="$REPO/bin/lib" HEIMDALL_STATE_BACKEND=firestore "$PY" - <<'PYEOF'
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_state, cp_selfcheck
# A fake firestore-shaped backend: path() is REFUSED exactly like FirestoreBackend.path(),
# while the read/write/get ops serve a healthy (empty) external store. get_record returns a
# populated key registry so pki_key passes — proving the registry is read THROUGH the backend
# (get_record), not a local file (keys_path -> path()).
class _Fake:
    def _db(self): return None
    def read_lines(self, rel): return []
    def get_record(self, rel):
        if rel.endswith("keys.json"):
            return {"version": "1.0.0", "keys": {"haid-fs-dev": {"pubkey": "x", "owner": False}}}
        return None
    def list_names(self, rel_dir, *, suffix=""): return []
    def exists(self, rel): return False
    def append_line(self, rel, record, *, fsync=False): return True
    def put_record(self, rel, record): return True
    def path(self, rel):
        raise cp_state.BackendUnavailable("FirestoreBackend has no local path for %r" % rel)
cp_state.get_backend = lambda home=None, backend=None: _Fake()
# run_all must NOT raise BackendUnavailable (the bug) — every check is backend-aware.
report = cp_selfcheck.run_all()
assert isinstance(report, dict) and report.get("checks"), report
ids = {c["id"]: c for c in report["checks"]}
# the four checks that used to crash through path() must now be present + structured.
for cid in ("stores_reachable", "audit_writable", "pki_key", "config_sane"):
    c = ids.get(cid)
    assert c is not None, "missing check %s" % cid
    assert isinstance(c["ok"], bool) and isinstance(c["status"], str) and c["status"], c
# on a HEALTHY firestore backend the backend-probed critical checks PASS (the backend serves).
for cid in ("stores_reachable", "audit_writable", "pki_key"):
    assert ids[cid]["ok"], "%s should pass on a healthy firestore backend: %r" % (cid, ids[cid])
# render_table must not raise either (it walks the same secret-free report).
txt = cp_selfcheck.render_table(report)
assert "PASS" in txt or "FAIL" in txt, txt
print(json.dumps({"overall": report["overall"],
                  "stores": ids["stores_reachable"]["status"],
                  "pki": ids["pki_key"]["status"]}))
PYEOF
)"
[ -n "$D1" ] && ok "D1 run_all() under a firestore backend runs WITHOUT BackendUnavailable, critical checks pass: $D1" \
             || bad "D1 diagnose crashed or misreported under a firestore backend (path()-under-firestore class)"

# D2: a firestore backend whose key registry is EMPTY → pki_key still FAILS critically
# (the check reads the registry THROUGH get_record, so it inspects real backend state, not
# canned) — and the run still does not crash. Proves the backend-aware path stays honest.
D2="$(LIB="$REPO/bin/lib" HEIMDALL_STATE_BACKEND=firestore "$PY" - <<'PYEOF'
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_state, cp_selfcheck
class _FakeEmpty:
    def _db(self): return None
    def read_lines(self, rel): return []
    def get_record(self, rel): return None          # empty registry
    def list_names(self, rel_dir, *, suffix=""): return []
    def exists(self, rel): return False
    def append_line(self, rel, record, *, fsync=False): return True
    def put_record(self, rel, record): return True
    def path(self, rel):
        raise cp_state.BackendUnavailable("no local path")
cp_state.get_backend = lambda home=None, backend=None: _FakeEmpty()
report = cp_selfcheck.run_all()                      # must not raise
pk = [c for c in report["checks"] if c["id"] == "pki_key"][0]
assert not pk["ok"], "pki_key must fail on an empty firestore registry: %r" % pk
assert report["overall"] == "fail" and "pki_key" in report["critical_failures"], report
print(json.dumps({"pki_ok": pk["ok"], "overall": report["overall"]}))
PYEOF
)"
[ -n "$D2" ] && ok "D2 empty firestore key registry → pki_key FAILS (reads via get_record, no crash): $D2" \
             || bad "D2 pki_key did not honestly fail on an empty firestore registry"

# D3: a firestore backend that CANNOT serve (read/get RAISE) → the backend-probed critical
# checks FAIL — a genuine backend error is still surfaced, never swallowed into a false pass.
D3="$(LIB="$REPO/bin/lib" HEIMDALL_STATE_BACKEND=firestore "$PY" - <<'PYEOF'
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_state, cp_selfcheck
class _FakeBroken:
    def _db(self): raise cp_state.BackendUnavailable("client cannot init")
    def read_lines(self, rel): raise cp_state.BackendUnavailable("client cannot init")
    def get_record(self, rel): raise cp_state.BackendUnavailable("client cannot init")
    def list_names(self, rel_dir, *, suffix=""): raise cp_state.BackendUnavailable("client cannot init")
    def exists(self, rel): return False
    def append_line(self, rel, record, *, fsync=False): return False
    def put_record(self, rel, record): return False
    def path(self, rel): raise cp_state.BackendUnavailable("no local path")
cp_state.get_backend = lambda home=None, backend=None: _FakeBroken()
report = cp_selfcheck.run_all()                      # must not crash even on a broken backend
ids = {c["id"]: c for c in report["checks"]}
assert not ids["stores_reachable"]["ok"], "a broken backend must fail stores_reachable: %r" % ids["stores_reachable"]
assert not ids["audit_writable"]["ok"], "a broken backend must fail audit_writable: %r" % ids["audit_writable"]
print(json.dumps({"stores": ids["stores_reachable"]["ok"], "audit": ids["audit_writable"]["ok"]}))
PYEOF
)"
[ -n "$D3" ] && ok "D3 a broken firestore backend → backend-probed checks FAIL (genuine error surfaced): $D3" \
             || bad "D3 a broken firestore backend was wrongly reported reachable"

# D4: the REAL CLI under HEIMDALL_STATE_BACKEND=firestore with the firestore lib import
# BLOCKED (the incident shape: backend selected, google-cloud-firestore dep missing). The
# `diagnose` command must still RUN and emit a JSON report — never an uncaught
# BackendUnavailable traceback. Hermetic via a usercustomize meta_path blocker on PYTHONPATH
# (mirrors cp-diag.test.sh G), so it does not depend on whether the lib is installed. The
# point is narrow and strong: the operator's debug tool does not crash on the very deploy it
# is meant to diagnose.
BLOCKER="$WORK/blocker"
mkdir -p "$BLOCKER"
cat >"$BLOCKER/usercustomize.py" <<'PYEOF'
import importlib.abc, sys
class _Block(importlib.abc.MetaPathFinder):
    def find_spec(self, name, path, target=None):
        if name == "google.cloud.firestore" or name.startswith("google.cloud.firestore."):
            raise ImportError("simulated missing google-cloud-firestore dep")
        return None
sys.meta_path.insert(0, _Block())
PYEOF
set +e
PYTHONPATH="$BLOCKER${PYTHONPATH:+:$PYTHONPATH}" HEIMDALL_STATE_BACKEND=firestore \
  "$CLI" diagnose --json --home "$HEIMDALL_HOME" >"$WORK/diagfs.json" 2>"$WORK/diagfs.err"
DFS_RC=$?
set -e
if grep -qE "BackendUnavailable|Traceback" "$WORK/diagfs.err"; then
  bad "D4 the real diagnose CLI crashed under HEIMDALL_STATE_BACKEND=firestore (BackendUnavailable/Traceback)"; cat "$WORK/diagfs.err" >&2
else
  "$PY" - "$WORK/diagfs.json" <<'PYEOF' && ok "D4 REAL CLI diagnose under firestore (dep blocked) RUNS, emits a report, no BackendUnavailable: $(cat "$WORK/diagfs.json" | tr -d '\n' | cut -c1-120)" || bad "D4 diagnose --json under firestore did not emit a structured report"
import json, sys
obj = json.load(open(sys.argv[1]))
assert isinstance(obj, dict) and obj.get("checks"), obj
ids = {c["id"] for c in obj["checks"]}
for cid in ("stores_reachable", "audit_writable", "pki_key", "config_sane"):
    assert cid in ids, "missing %s in %r" % (cid, sorted(ids))
PYEOF
fi

echo
echo "============================================================"
printf "cp-diagnose: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
