#!/usr/bin/env bash
# verify-flight-fix-dryrun.test.sh — LOCAL firestore-mode DRY RUN of deploy/cloud-run/
# verify-flight-fix.sh. Proves the PROD verify script's logic end-to-end BEFORE it touches
# the real Cloud Run target, so RJ's prod run is pure execution.
#
# WHAT IT PROVES (the same property the prod script proves, locally + for $0):
#   A signed client starts a server-hosted job over POST /jobs against a LOCAL wired server
#   running with HEIMDALL_STATE_BACKEND=firestore (against an EXTERNAL store that lives
#   OUTSIDE the server's HEIMDALL_HOME). The job runs durable. Then we SIMULATE Cloud Run
#   scale-to-zero by RESTARTING the server process against the SAME external store — a fresh
#   process is a fresh "instance" with a brand-new ephemeral home; the durable store persists.
#   The prod script's STEP 5 read-back then resolves the SAME job_id + its folded state from
#   the fresh process. PASS here == the script's start -> durable -> instance-replace ->
#   read-back logic is correct.
#
# ZERO REAL GCP / ZERO SPEND. The external "Firestore" is the SAME faithful in-process fake
# the durability gate (test/cp-durability.test.sh) ships: a sitecustomize.py on PYTHONPATH
# binds a fake google.cloud.firestore that PERSISTS to a JSON file OUTSIDE any HEIMDALL_HOME.
# If a real client lib + a caller-set FIRESTORE_EMULATOR_HOST are present, the SHIPPED
# backend talks to that real emulator instead (the same precedence cp-durability uses) — the
# dry run is correct either way because verify-flight-fix.sh only ever speaks signed HTTP.
#
# The instance-replacement hook is exercised via the script's SCALE_TO_ZERO=command + SCALE_CMD
# seam (the gcloud-free path the prod script documents) — here SCALE_CMD restarts the server.
#
# Exit 0 == verify-flight-fix.sh reported PASS in firestore mode across a process restart.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
CLI="$REPO/bin/heimdall-control-plane"
SCRIPT="$REPO/deploy/cloud-run/verify-flight-fix.sh"
export LIB

[ -x "$CLI" ]      || { echo "FATAL: $CLI not executable" >&2; exit 2; }
[ -f "$SCRIPT" ]   || { echo "FATAL: $SCRIPT missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

# crypto gate: the verify script signs over HTTP — without an Ed25519 backend there is no
# PKI, so SKIP cleanly (the same posture cp-wired takes).
if ! "$PY" -c "import sys,os; sys.path.insert(0,os.environ['LIB']); import cp_auth; sys.exit(0 if cp_auth.crypto_available() else 1)"; then
  echo "verify-flight-fix-dryrun: SKIP (no Ed25519 crypto backend — PKI signing unavailable)"
  exit 0
fi

# ── isolated scratch: an EXTERNAL store dir (outside any server home) + the fake fs pkg ──
EXT="$(mktemp -d -t "vffx-ext.$(printf 'X%.0s' 1 2 3 4 5 6)")"
HOME_A="$EXT/home-instanceA"   # the FIRST server process's ephemeral home (gets "wiped").
HOME_B="$EXT/home-instanceB"   # the SECOND (fresh) server process's ephemeral home.

SERVER_PID=""
SERVER_PID_B=""
cleanup() {
  # Reap whichever server processes are still alive. Quiet (no job-control notice) and
  # always returns 0 so the trap never clobbers the script's explicit exit status.
  for _pid in "$SERVER_PID" "$SERVER_PID_B"; do
    if [ -n "$_pid" ]; then
      disown "$_pid" 2>/dev/null || true
      kill "$_pid" 2>/dev/null || true
    fi
  done
  rm -rf "$EXT"
  return 0
}
trap cleanup EXIT

# Shared firestore root + project so every backend instance addresses the same store.
export HEIMDALL_STATE_BACKEND="firestore"
export HEIMDALL_FIRESTORE_ROOT="flightfix_dryrun"
export HEIMDALL_FIRESTORE_PROJECT="flightfix-dryrun"

# ── decide firestore mode: real emulator (if caller pre-set one + client present) else fake ─
MODE=""
if [ -n "${FIRESTORE_EMULATOR_HOST:-}" ] \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  MODE="emulator"
  echo "verify-flight-fix-dryrun: using caller FIRESTORE_EMULATOR_HOST=$FIRESTORE_EMULATOR_HOST (real client)"
fi

if [ -z "$MODE" ]; then
  # FAKE MODE — the faithful in-process google.cloud.firestore double, persisting to a JSON
  # file OUTSIDE any home. Lifted verbatim from test/cp-durability.test.sh (the shipped
  # backend code runs unchanged; only the external service is a double).
  MODE="fake"
  FAKEPKG="$EXT/pylib"
  mkdir -p "$FAKEPKG"
  cat >"$FAKEPKG/_fake_firestore_impl.py" <<'PYEOF'
import json
import os

_STORE_ENV = "HEIMDALL_FAKE_FS_STORE"


def _store_path():
    p = os.environ.get(_STORE_ENV)
    if not p:
        raise RuntimeError("fake firestore needs %s set to a path" % _STORE_ENV)
    return p


def _load():
    try:
        with open(_store_path(), "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _save(data):
    tmp = _store_path() + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    os.replace(tmp, _store_path())


class Client:
    def __init__(self, project=None):
        self.project = project

    def collection(self, name):
        return CollectionRef(name)

    def transaction(self):
        return _Transaction()


class CollectionRef:
    def __init__(self, path):
        self._path = path

    def document(self, doc_id):
        return DocRef(self._path, doc_id)

    def order_by(self, field):
        return _Query(self._path, order_field=field)

    def stream(self):
        return _Query(self._path).stream()


class _Query:
    def __init__(self, coll_path, order_field=None):
        self._coll_path = coll_path
        self._order_field = order_field

    def order_by(self, field):
        return _Query(self._coll_path, order_field=field)

    def stream(self):
        data = _load()
        coll = data.get("collections", {}).get(self._coll_path, {})
        items = []
        for doc_id, doc in coll.items():
            items.append(_Snapshot(self._coll_path, doc_id, doc.get("fields")))
        if self._order_field:
            items.sort(key=lambda s: (s.to_dict() or {}).get(self._order_field))
        else:
            items.sort(key=lambda s: s.id)
        return iter(items)


class DocRef:
    def __init__(self, coll_path, doc_id):
        self._coll_path = coll_path
        self._doc_id = doc_id

    @property
    def id(self):
        return self._doc_id

    def collection(self, name):
        return CollectionRef("%s/%s/%s" % (self._coll_path, self._doc_id, name))

    def get(self, transaction=None):
        data = _load()
        doc = data.get("collections", {}).get(self._coll_path, {}).get(self._doc_id)
        fields = doc.get("fields") if doc else None
        return _Snapshot(self._coll_path, self._doc_id, fields)

    def set(self, fields, merge=False):
        data = _load()
        colls = data.setdefault("collections", {})
        coll = colls.setdefault(self._coll_path, {})
        doc = coll.setdefault(self._doc_id, {"fields": {}})
        if merge:
            cur = dict(doc.get("fields") or {})
            cur.update(fields)
            doc["fields"] = cur
        else:
            doc["fields"] = dict(fields)
        _save(data)


class _Snapshot:
    def __init__(self, coll_path, doc_id, fields):
        self._coll_path = coll_path
        self._doc_id = doc_id
        self._fields = fields

    @property
    def id(self):
        return self._doc_id

    @property
    def exists(self):
        return self._fields is not None

    def to_dict(self):
        return dict(self._fields) if self._fields is not None else None


class _Transaction:
    def set(self, ref, fields, merge=False):
        ref.set(fields, merge=merge)

    def get(self, ref):
        return ref.get()


def transactional(func):
    def _wrapped(transaction, *args, **kwargs):
        return func(transaction, *args, **kwargs)
    return _wrapped
PYEOF
  cat >"$FAKEPKG/sitecustomize.py" <<'PYEOF'
import importlib
import sys

import _fake_firestore_impl as _impl

for _name in ("google", "google.cloud"):
    if _name not in sys.modules:
        try:
            importlib.import_module(_name)
        except Exception:  # noqa: BLE001 — synthesize a bare package when google is absent.
            import types
            _pkg = types.ModuleType(_name)
            _pkg.__path__ = []
            sys.modules[_name] = _pkg

sys.modules["google.cloud.firestore"] = _impl
setattr(sys.modules["google.cloud"], "firestore", _impl)
PYEOF
  export HEIMDALL_FAKE_FS_STORE="$EXT/fake_fs.json"
  : >"$EXT/fake_fs.json"
  export PYTHONPATH="$FAKEPKG${PYTHONPATH:+:$PYTHONPATH}"
fi

echo "============================================================"
echo "verify-flight-fix DRY RUN (local firestore mode, MODE=$MODE)"
echo "  external store: $EXT  (outside both server homes)"
echo "============================================================"

# ── a DETERMINISTIC PKI seed so the registered identity is stable across the restart ──
# We DERIVE a deterministic keypair from a fixed 32-byte seed (the same shape the deploy's
# cp-pki-key seed has). Setting HEIMDALL_CP_PKI_KEY makes BOTH `identity` registration AND
# the server's boot ensure_server_identity use THIS seed — so the registered HAID->pubkey
# binding is identical in instance A and instance B. The seed is RUNTIME-ASSEMBLED here
# (32 bytes -> base64), never a committed literal — bin/secret-scan stays clean.
# NOTE: the python body is written to a TEMP FILE and run as `python3 "$file"`, NOT captured
# inline as `$(python3 <<...)`. A `)` inside the heredoc body (here `.digest()`/`.decode()`,
# and the JSON `.get(...)` calls in the P1/P2 blocks below) confuses bash's command-
# substitution parser — it closes the `$( )` early and corrupts everything that follows
# (passes `bash -n`, fails at runtime). The temp-file form is the proven pattern from
# test/cp-durability.test.sh (mk_create_advance/mk_read -> "$PY" "$file").
PKI_SEED_PY="$EXT/pki_seed.py"
cat >"$PKI_SEED_PY" <<'PYEOF'
import base64
import hashlib
import sys
# A deterministic but runtime-assembled 32-byte Ed25519 seed (sha256 of a fixed label).
seed = hashlib.sha256(b"heimdall-flightfix-dryrun-seed").digest()  # exactly 32 bytes
sys.stdout.write(base64.b64encode(seed).decode())
PYEOF
PKI_SEED="$("$PY" "$PKI_SEED_PY")"
export HEIMDALL_CP_PKI_KEY="$PKI_SEED"

CLIENT_HAID="haid:flightfix.dryrun"

# Register the identity into the EXTERNAL firestore store via the FIRST server's home. The
# registry (auth/keys.json) is itself written THROUGH the firestore backend, so it persists
# across the restart too — instance B re-reads the SAME registered pubkey. Owner so the
# server's own tick has a principal (irrelevant to the proof, but realistic).
"$CLI" identity --haid "$CLIENT_HAID" --owner --home "$HOME_A" \
  >"$EXT/ident.out" 2>"$EXT/ident.err"
IDENT_OK="$("$PY" -c "import json;print(json.load(open('$EXT/ident.out')).get('ok'))" 2>/dev/null)"
KEY_SOURCE="$("$PY" -c "import json;print(json.load(open('$EXT/ident.out')).get('key_source'))" 2>/dev/null)"
if [ "$IDENT_OK" = "True" ]; then
  echo "  registered $CLIENT_HAID into firestore (key_source=$KEY_SOURCE, seed-derived)"
else
  echo "FATAL: identity registration failed" >&2; cat "$EXT/ident.err" >&2; exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────────────
# CARDINAL PRE-CHECK — DETERMINISTIC CROSS-INSTANCE IDENTITY (seed + name = stable identity).
#
# The flight-fix's auth half: every Cloud Run instance must register the IDENTICAL
# haid->pubkey binding so a request signed by one instance verifies on ANY other. That holds
# IFF BOTH halves are pinned — the KEY (HEIMDALL_CP_PKI_KEY seed) AND the NAME
# (HEIMDALL_CP_SERVER_HAID). This block proves it with the SHIPPED cp_auth, BEFORE the full
# script run, by simulating TWO fresh server processes:
#
#   * process P1: SAME seed + SAME HEIMDALL_CP_SERVER_HAID, fresh ephemeral home HOME_P1.
#                 Runs ensure_server_identity (the real boot path) -> registers
#                 server_haid -> pubkey(seed) THROUGH the firestore backend, then SIGNS a
#                 canonical request as that HAID with the seed.
#   * process P2: a SEPARATE python process (a fresh "instance"), SAME seed + SAME HAID, a
#                 DIFFERENT fresh ephemeral home HOME_P2. Runs ensure_server_identity AGAIN
#                 and re-derives the binding INDEPENDENTLY.
#
# ASSERTED: (1) P1's and P2's registered haid->pubkey are BYTE-IDENTICAL (deterministic from
# the seed, bound to the SAME pinned name), and (2) the request P1 SIGNED VERIFIES on P2
# (cp_auth.verify against P2's independently-rebuilt registry). A FALSIFIER: with the SAME
# seed but a DIFFERENT HAID, P2's verify of P1's signature MUST fail (unknown_haid) — proving
# the NAME, not just the key, is load-bearing. This is the cross-instance-identity half of
# the flight-fix proof, run for $0 against the in-process firestore double.
echo
echo "── CARDINAL: deterministic cross-instance identity (two fresh processes) ──"
HOME_P1="$EXT/home-P1"
HOME_P2="$EXT/home-P2"
SERVER_HAID="haid:heimdall.flightfix-prod-0001"   # the PINNED server name (the §3 shape).

# P1 — a fresh process: pin seed+name, run the real boot identity path, register + sign.
# The python body is written to a TEMP FILE and run as `"$PY" "$file" args` — never inline
# `$(python3 <<...)`. The body calls `res.get("registered")` etc.: a `)` inside an inline
# heredoc-in-command-substitution closes bash's `$( )` early and corrupts the parse. The
# file form (the cp-durability.test.sh pattern) avoids it; runtime values arrive via argv.
# NOTE: assign the substitution result to its own var, THEN check $? on the next line. The
# `VAR="$(...)" || { ... }` form interacts badly with `set -u` (an empty/failed substitution
# can leave VAR effectively unbound for the handler), so we keep assignment and check apart.
P1_PY="$EXT/p1_identity.py"
cat >"$P1_PY" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth as K
home, server_haid = sys.argv[1], sys.argv[2]
# The boot path: HEIMDALL_CP_SERVER_HAID pins the NAME; HEIMDALL_CP_PKI_KEY pins the KEY.
os.environ["HEIMDALL_CP_SERVER_HAID"] = server_haid
res = K.ensure_server_identity(home=home)              # registers server_haid -> pubkey(seed)
# What name did the boot path resolve, and what pubkey did it register?
haid = K.server_haid(home)
pub = K.registered_pubkey(haid, home=home)
# Sign a canonical request AS the server's own identity, with the seed.
priv, _pub = K.load_signing_key()
msg = K.canonical_message("GET", "/jobs", b'{"job_id":"flightfix-xinstance"}')
sig = K.sign(priv, msg)
print(json.dumps({"haid": haid, "pubkey": pub, "registered": res.get("registered"),
                  "reason": res.get("reason"), "sig": sig}))
PYEOF
set +e
P1_OUT="$("$PY" "$P1_PY" "$HOME_P1" "$SERVER_HAID")"
P1_RC=$?
set -e
if [ "$P1_RC" -ne 0 ] || [ -z "${P1_OUT:-}" ]; then
  echo "FATAL: P1 identity/sign failed (rc=$P1_RC)" >&2; echo "${P1_OUT:-<no output>}" >&2; exit 1
fi

P1_HAID="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['haid'])" "$P1_OUT")"
P1_PUB="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['pubkey'])" "$P1_OUT")"
P1_SIG="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['sig'])" "$P1_OUT")"
P1_REG="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['registered'])" "$P1_OUT")"

# P2 — a SEPARATE fresh process (a different "instance"): SAME seed + SAME pinned name, a
# DIFFERENT fresh home. Re-derive the identity INDEPENDENTLY, then VERIFY P1's signature
# against P2's own rebuilt registry. Also run the FALSIFIER (a different name must fail).
# Body written to a TEMP FILE (its many `)` — `.get(...)`, `verify(...)`, `bool(...)` — would
# otherwise break an inline `$(python3 <<...)`); runtime values arrive via argv (incl. P1's sig).
P2_PY="$EXT/p2_verify.py"
cat >"$P2_PY" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth as K
home, server_haid, p1_sig = sys.argv[1], sys.argv[2], sys.argv[3]
os.environ["HEIMDALL_CP_SERVER_HAID"] = server_haid
res = K.ensure_server_identity(home=home)              # INDEPENDENT re-derivation on P2.
haid = K.server_haid(home)
pub = K.registered_pubkey(haid, home=home)
# VERIFY the signature P1 produced, against P2's independently-registered pubkey.
msg = K.canonical_message("GET", "/jobs", b'{"job_id":"flightfix-xinstance"}')
try:
    ok = K.verify(haid, msg, p1_sig, home=home, enforce_revocation=False)
    verify_ok = bool(ok)
    verify_err = ""
except K.AuthError as exc:
    verify_ok, verify_err = False, exc.reason
# FALSIFIER: the SAME seed/sig but a DIFFERENT (unpinned/wrong) name must NOT verify — the
# name is load-bearing, not just the key.
other = haid + ".impostor"
try:
    K.verify(other, msg, p1_sig, home=home, enforce_revocation=False)
    falsifier_rejected = False           # BAD: a wrong name verified — name not load-bearing.
except K.AuthError as exc:
    falsifier_rejected = (exc.reason == "unknown_haid")
print(json.dumps({"haid": haid, "pubkey": pub, "registered": res.get("registered"),
                  "verify_ok": verify_ok, "verify_err": verify_err,
                  "falsifier_rejected": falsifier_rejected}))
PYEOF
set +e
P2_OUT="$("$PY" "$P2_PY" "$HOME_P2" "$SERVER_HAID" "$P1_SIG")"
P2_RC=$?
set -e
if [ "$P2_RC" -ne 0 ] || [ -z "${P2_OUT:-}" ]; then
  echo "FATAL: P2 identity/verify failed (rc=$P2_RC)" >&2; echo "${P2_OUT:-<no output>}" >&2; exit 1
fi

P2_HAID="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['haid'])" "$P2_OUT")"
P2_PUB="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['pubkey'])" "$P2_OUT")"
P2_VERIFY="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['verify_ok'])" "$P2_OUT")"
P2_FALSIFY="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['falsifier_rejected'])" "$P2_OUT")"

CARDINAL_FAIL=0
# (1) the two fresh processes resolved the SAME pinned name.
if [ "$P1_HAID" = "$SERVER_HAID" ] && [ "$P2_HAID" = "$SERVER_HAID" ]; then
  echo "  PASS both fresh processes resolved the SAME pinned HAID ($SERVER_HAID)"
else
  echo "  FAIL HAID mismatch (P1=$P1_HAID P2=$P2_HAID pinned=$SERVER_HAID)"; CARDINAL_FAIL=1
fi
# (2) the registered pubkeys are BYTE-IDENTICAL across the two independent boots.
if [ -n "$P1_PUB" ] && [ "$P1_PUB" = "$P2_PUB" ]; then
  echo "  PASS the registered haid->pubkey is IDENTICAL across both processes (deterministic from the seed)"
else
  echo "  FAIL pubkey mismatch across processes (P1=$P1_PUB P2=$P2_PUB)"; CARDINAL_FAIL=1
fi
# (3) both boots actually wrote the binding (registered=True).
if [ "$P1_REG" = "True" ]; then
  echo "  PASS process P1 registered its seeded identity (registered=$P1_REG)"
else
  echo "  FAIL process P1 did not register (registered=$P1_REG)"; CARDINAL_FAIL=1
fi
# (4) the request P1 SIGNED VERIFIES on the SECOND (fresh) process.
if [ "$P2_VERIFY" = "True" ]; then
  echo "  PASS a request signed by P1 VERIFIES on the fresh process P2 (cross-instance auth holds)"
else
  echo "  FAIL P2 could not verify P1's signature (cross-instance auth broken)"; CARDINAL_FAIL=1
fi
# (5) FALSIFIER: the SAME seed/sig under a DIFFERENT name must be REJECTED (name is load-bearing).
if [ "$P2_FALSIFY" = "True" ]; then
  echo "  PASS FALSIFIER: same seed+sig under a DIFFERENT HAID is REJECTED (unknown_haid) — the NAME is load-bearing, not just the key"
else
  echo "  FAIL FALSIFIER did not reject a wrong-name signature — the name is not actually enforced"; CARDINAL_FAIL=1
fi
if [ "$CARDINAL_FAIL" -ne 0 ]; then
  echo "FATAL: deterministic cross-instance identity NOT proven — aborting before the full script run" >&2
  exit 1
fi
echo "  → cross-instance identity proven: pinned seed + pinned name => identical haid->pubkey on every fresh instance"

# pick a free ephemeral port for the local wired server.
CP_PORT="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"

# ── start the LOCAL wired server (firestore backend) on HOME_A ──────────────────────
start_server() {
  local home="$1"
  "$CLI" serve --host 127.0.0.1 --port "$CP_PORT" --home "$home" --no-revocation \
    >"$EXT/serve.out" 2>"$EXT/serve.err" &
  SERVER_PID=$!
  # wait for the socket to accept.
  for _ in $(seq 1 50); do
    if "$PY" -c "import socket,sys;s=socket.socket();s.settimeout(0.2)
try:
    s.connect(('127.0.0.1', $CP_PORT)); s.close()
except OSError:
    sys.exit(1)" 2>/dev/null; then return 0; fi
    "$PY" -c "import time;time.sleep(0.1)"
  done
  return 1
}

if start_server "$HOME_A"; then
  echo "  instance A live on 127.0.0.1:$CP_PORT (home=$HOME_A, firestore backend, pid $SERVER_PID)"
else
  echo "FATAL: instance A did not come up" >&2; cat "$EXT/serve.err" >&2; exit 1
fi

# ── the SCALE_CMD: replace the serving instance = kill instance A, wipe its home, start a
#    FRESH instance B on a NEW home against the SAME external firestore store. A fresh process
#    with a brand-new ephemeral home == a Cloud Run cold start; the durable store persists.
#    Written to a file so the verify script's `bash -c "$SCALE_CMD"` runs it with the env.
RESTART_HOOK="$EXT/restart_hook.sh"
cat >"$RESTART_HOOK" <<HOOKEOF
#!/usr/bin/env bash
set -uo pipefail
# kill instance A (the process that ran the job) + WIPE its ephemeral home.
kill "$SERVER_PID" 2>/dev/null || true
for _ in \$(seq 1 20); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.1; done
kill -9 "$SERVER_PID" 2>/dev/null || true
rm -rf "$HOME_A"
# start a FRESH instance B on a NEW home, SAME external firestore store + SAME port.
"$CLI" serve --host 127.0.0.1 --port "$CP_PORT" --home "$HOME_B" --no-revocation \
  >"$EXT/serveB.out" 2>"$EXT/serveB.err" &
echo \$! >"$EXT/serverB.pid"
# wait for instance B's socket.
for _ in \$(seq 1 50); do
  if "$PY" -c "import socket,sys;s=socket.socket();s.settimeout(0.2)
try:
    s.connect(('127.0.0.1', $CP_PORT)); s.close()
except OSError:
    sys.exit(1)" 2>/dev/null; then exit 0; fi
  "$PY" -c "import time;time.sleep(0.1)"
done
echo "instance B did not come up" >&2
cat "$EXT/serveB.err" >&2
exit 1
HOOKEOF
chmod +x "$RESTART_HOOK"

echo
echo "── running deploy/cloud-run/verify-flight-fix.sh against the local server ──"
echo

# Drive the PROD script against the local server. SCALE_TO_ZERO=command + SCALE_CMD wires the
# gcloud-free instance-replacement seam to our restart hook (the durable-store-preserving
# instance swap). No PROJECT_ID -> the script's Firestore doc-check is the print-only path.
set +e
BASE_URL="http://127.0.0.1:$CP_PORT" \
CLIENT_HAID="$CLIENT_HAID" \
PKI_SEED="$PKI_SEED" \
HEIMDALL_FIRESTORE_ROOT="$HEIMDALL_FIRESTORE_ROOT" \
SCALE_TO_ZERO="command" \
SCALE_CMD="bash '$RESTART_HOOK'" \
POLL_SECONDS=30 \
COLD_POLL_SECONDS=20 \
bash "$SCRIPT"
SCRIPT_RC=$?
set -e

# instance A was killed inside the hook; disown it so its async exit prints no job-control
# notice, and adopt instance B's pid for the trap to reap.
disown "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
if [ -f "$EXT/serverB.pid" ]; then
  SERVER_PID_B="$(cat "$EXT/serverB.pid" 2>/dev/null || true)"
fi

echo
echo "============================================================"
if [ "$SCRIPT_RC" -eq 0 ]; then
  echo "verify-flight-fix-dryrun: PASS — the prod script reported PASS in firestore mode"
  echo "  across a process restart (job survived, read back from the external store)."
  echo "============================================================"
  exit 0
else
  echo "verify-flight-fix-dryrun: FAIL — the prod script reported FAIL (rc=$SCRIPT_RC)"
  echo "============================================================"
  exit 1
fi
