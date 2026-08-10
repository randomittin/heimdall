#!/usr/bin/env bash
# cp-auth-durability.test.sh — THE PKI AUTH DURABILITY + IDENTITY GATE.
#
# THE GAP THIS CLOSES (the verifier finding). The control plane NEVER loaded its PKI
# signing key from Secret Manager: generate_keypair() minted a FRESH random Ed25519 key
# per `identity` call, and the `--set-secrets`-injected env HEIMDALL_CP_PKI_KEY was read
# by NOTHING. On Cloud Run cold-start every instance ran a DIFFERENT key universe with an
# EMPTY registry → broken PKI identity. And the pubkey registry (keys.json) was local
# NDJSON/JSON on ephemeral disk → vanished on scale-to-zero. The fix:
#   • load_signing_key() reads HEIMDALL_CP_PKI_KEY and DETERMINISTICALLY derives the SAME
#     keypair every instance/cold-start; FAIL-CLOSED in the cloud profile if absent.
#   • the keys.json registry is migrated onto StateBackend (Firestore-capable).
#
# THIS GATE asserts all three properties, each FALSIFIABLE:
#
#   (a) DETERMINISM — the SAME seed yields an IDENTICAL keypair across two SEPARATE
#       python processes (two "instances"). If the derivation were random (or ignored the
#       seed), the two pubkeys would differ and (a) FAILS.
#   (b) FAIL-CLOSED — in the cloud profile (K_SERVICE set) with the seed ABSENT, the
#       identity/boot path RAISES (refuses to mint a per-instance key); the LOCAL profile
#       with no seed still mints (dev preserved). If the cloud path silently minted, (b) FAILS.
#   (c) REGISTRY DURABILITY (scale-to-zero contrast, exactly like cp-durability) — a pubkey
#       registered by "instance A" (home A) must SURVIVE a wipe of home A and be readable by
#       "instance B" (home B):
#         · LOCAL backend     → pubkey was on the WIPED home A disk → LOST (expected).
#         · FIRESTORE backend → pubkey in the EXTERNAL store, untouched by the wipe → SURVIVES.
#       If local survives, the scale-to-zero simulation is wrong → FAIL. If firestore does
#       NOT survive, durability is broken → FAIL.
#
# ZERO REAL GCP / ZERO SPEND. The firestore half runs against (0) a caller-provided
# emulator (real client), else (1) a self-started gcloud emulator (real client; needs a
# Java 21+ JRE), else (2) a faithful in-process FAKE google.cloud.firestore — the SAME
# fake the shipped cp-durability gate uses. The test PRINTS which mode it used.
#
# CRITICAL — NO SECRET ON DISK. The PKI private seed used here is a TEST seed generated in
# memory; it is NEVER written to a tracked file and NEVER printed by this gate (only public
# keys / status are printed). The seed is passed to child processes via env only.
#
# Exit 0 = (a) AND (b) AND (c)'s both halves hold. Nonzero = the gate failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

[ -f "$LIB/cp_auth.py" ]            || { echo "FATAL: $LIB/cp_auth.py missing" >&2; exit 2; }
[ -f "$LIB/cp_state.py" ]           || { echo "FATAL: $LIB/cp_state.py missing" >&2; exit 2; }
[ -f "$LIB/cp_state_firestore.py" ] || { echo "FATAL: $LIB/cp_state_firestore.py missing" >&2; exit 2; }
[ -x "$REPO/bin/heimdall-control-plane" ] || { echo "FATAL: bin/heimdall-control-plane missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# The external-store dir (Firestore emulator data / fake JSON store + the fake package).
# Lives OUTSIDE both per-instance homes so the scale-to-zero wipe cannot touch it.
EXT="$(mktemp -d -t "cp-authdur-ext.$(printf 'X%.0s' 1 2 3 4 5 6)")"

# The two per-instance ephemeral homes (distinct disks).
HOME_A="/tmp/authdurA"
HOME_B="/tmp/authdurB"
rm -rf "$HOME_A" "$HOME_B"

EMU_PID=""
cleanup() {
  [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1
  rm -rf "$EXT" "$HOME_A" "$HOME_B"
}
trap cleanup EXIT

# Shared root collection so both FirestoreBackend instances address the same store.
export HEIMDALL_FIRESTORE_ROOT="auth_durability_gate"
export HEIMDALL_FIRESTORE_PROJECT="cp-auth-durability-test"

# ── a TEST seed (in memory only — NEVER written to a tracked file, NEVER printed) ──
# A fixed 32-byte seed makes determinism reproducible. It is exported to children via env
# only (the same channel --set-secrets uses for the real seed); it is a throwaway test key.
# The generator is written to a scratch file under $EXT (outside the repo tree) and run —
# the same write-then-run pattern the cp-durability gate uses for its driver fragments.
MK_SEED="$EXT/mk_seed.py"
cat >"$MK_SEED" <<'PYEOF'
import base64
# A deterministic 32-byte test seed (not a real key; lives only in this process's memory).
print(base64.b64encode(bytes((i * 7 + 3) % 256 for i in range(32))).decode())
PYEOF
SEED_B64="$("$PY" "$MK_SEED")"
export HEIMDALL_CP_PKI_KEY="$SEED_B64"

# ── decide the firestore mode: emulator (real client) vs faithful in-process fake ──
MODE=""

# (0) EXTERNAL EMULATOR — caller pre-started one and exported its host.
if [ -n "${FIRESTORE_EMULATOR_HOST:-}" ] \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  EMU_PID=""
  MODE="emulator"
  echo "cp-auth-durability: using caller-provided FIRESTORE_EMULATOR_HOST=$FIRESTORE_EMULATOR_HOST (real client, external emulator)"
fi

# (1) SELF-STARTED EMULATOR — only when the caller did not pre-set a host.
if [ -z "$MODE" ] \
   && command -v gcloud >/dev/null 2>&1 \
   && gcloud beta emulators firestore --help >/dev/null 2>&1 \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  EMU_HOST="localhost:8766"
  gcloud beta emulators firestore start --host-port="$EMU_HOST" \
      >"$EXT/emu.log" 2>&1 &
  EMU_PID=$!
  for _ in $(seq 1 40); do
    if grep -q "$EMU_HOST" "$EXT/emu.log" 2>/dev/null; then break; fi
    if ! kill -0 "$EMU_PID" >/dev/null 2>&1; then break; fi
    "$PY" -c "import time;time.sleep(0.25)"
  done
  if kill -0 "$EMU_PID" >/dev/null 2>&1 && grep -q "$EMU_HOST" "$EXT/emu.log" 2>/dev/null; then
    export FIRESTORE_EMULATOR_HOST="$EMU_HOST"
    MODE="emulator"
  else
    echo "cp-auth-durability: self-started emulator did not advertise $EMU_HOST — falling back to fake." >&2
    tail -3 "$EXT/emu.log" >&2 2>/dev/null || true
    echo "cp-auth-durability: to force REAL mode, start an emulator yourself and export FIRESTORE_EMULATOR_HOST (needs a Java 21+ JRE)." >&2
    [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1
    EMU_PID=""
  fi
fi

if [ -z "$MODE" ]; then
  # FAKE MODE — the SAME faithful in-process google.cloud.firestore the cp-durability gate
  # uses (a sitecustomize.py on PYTHONPATH registers it into sys.modules before any import),
  # persisting to a JSON file OUTSIDE both homes so two backend instances + a home wipe see
  # the same store. SHIPPED backend code is real; only the external service is a double.
  MODE="fake"
  FAKEPKG="$EXT/pylib"
  mkdir -p "$FAKEPKG"
  cat >"$FAKEPKG/_fake_firestore_impl.py" <<'PYEOF'
# Faithful in-process FAKE of the slice of google.cloud.firestore that
# cp_state_firestore.FirestoreBackend actually uses (the same surface the cp-durability
# gate fakes). PERSISTS the whole store to the JSON file named by HEIMDALL_FAKE_FS_STORE so
# two Client() instances (or one process after a "home wipe") share one durable external store.
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

echo "cp-auth-durability: MODE=$MODE  (external store: $EXT)"
echo

# ── driver fragments (each a SEPARATE python process pinned to one home + backend) ──

# derive the keypair from the seed and print ONLY the public key (never the seed/private).
mk_derive_pub() {
cat <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth as A
_priv, pub = A.load_signing_key()   # reads HEIMDALL_CP_PKI_KEY; deterministic.
sys.stdout.write(pub)               # PUBLIC key only — the private seed never leaves here.
PYEOF
}

# instance A: register the server's seeded pubkey under a fixed HAID in THIS home+backend.
mk_register() {
cat <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth as A
home = os.environ["HEIMDALL_HOME"]
res = A.ensure_server_identity(home=home)   # derives seeded pubkey + registers it.
if not (res.get("seeded") and res.get("registered")):
    sys.stderr.write("register failed: %r\n" % res)
    sys.exit(1)
sys.stdout.write("%s|%s" % (res["haid"], res["public_key"]))
PYEOF
}

# instance B: read the registered pubkey by HAID from THIS home+backend.
mk_read() {
cat <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth as A
home = os.environ["HEIMDALL_HOME"]
haid = sys.argv[1]
pub = A.registered_pubkey(haid, home)
sys.stdout.write("MISSING" if not pub else ("FOUND|%s" % pub))
PYEOF
}

DERIVE_PUB="$EXT/derive_pub.py"; mk_derive_pub >"$DERIVE_PUB"
REGISTER="$EXT/register.py";     mk_register   >"$REGISTER"
READ_KEY="$EXT/read_key.py";     mk_read       >"$READ_KEY"

# The fixed server HAID the seeded identity binds to (so A registers and B reads the same key).
export HEIMDALL_CP_SERVER_HAID="haid:cp-server"

# ============================================================================
# (a) DETERMINISM — same seed -> identical keypair across two SEPARATE processes.
# ============================================================================
echo "(a) DETERMINISM — same HEIMDALL_CP_PKI_KEY seed across two separate processes"
PUB1="$(HEIMDALL_STATE_BACKEND=local "$PY" "$DERIVE_PUB" 2>"$EXT/d1.err")"
PUB2="$(HEIMDALL_STATE_BACKEND=local "$PY" "$DERIVE_PUB" 2>"$EXT/d2.err")"
if [ -n "$PUB1" ] && [ "$PUB1" = "$PUB2" ]; then
  ok "a1 two instances derived the SAME public key from the seed (deterministic)"
  echo "  → pubkey (process 1): $PUB1"
  echo "  → pubkey (process 2): $PUB2  [identical]"
else
  bad "a1 derived public keys DIFFER across processes ('$PUB1' vs '$PUB2') — not deterministic"
  cat "$EXT/d1.err" "$EXT/d2.err" >&2
fi
echo

# ============================================================================
# (b) FAIL-CLOSED — cloud profile + absent seed RAISES; local + absent still mints.
# ============================================================================
echo "(b) FAIL-CLOSED — cloud profile (K_SERVICE) with the seed ABSENT must REFUSE"
# Cloud profile, seed ABSENT: the identity CLI path must fail-closed (nonzero, no mint).
set +e
CLOUD_OUT="$(env -u HEIMDALL_CP_PKI_KEY K_SERVICE=svc HEIMDALL_HOME="$(mktemp -d)" \
  "$REPO/bin/heimdall-control-plane" identity --haid haid:cp-server 2>/dev/null)"
CLOUD_RC=$?
set -e
if [ "$CLOUD_RC" -ne 0 ] && grep -q '"pki_key_absent"' <<<"$CLOUD_OUT"; then
  ok "b1 cloud profile + absent seed REFUSED (exit $CLOUD_RC, reason pki_key_absent) — no per-instance mint"
else
  bad "b1 cloud profile + absent seed did NOT fail-closed (exit $CLOUD_RC, out=$CLOUD_OUT)"
fi
# Local profile, seed ABSENT: dev mint path still works (preserved).
set +e
LOCAL_OUT="$(env -u HEIMDALL_CP_PKI_KEY -u K_SERVICE -u HEIMDALL_STATE_BACKEND \
  HEIMDALL_HOME="$(mktemp -d)" \
  "$REPO/bin/heimdall-control-plane" identity --haid haid:dev 2>/dev/null)"
LOCAL_RC=$?
set -e
if [ "$LOCAL_RC" -eq 0 ] && grep -q '"key_source": "minted"' <<<"$LOCAL_OUT"; then
  ok "b2 local profile + absent seed still MINTS a dev key (exit 0, key_source=minted) — dev preserved"
else
  bad "b2 local profile + absent seed broke the dev mint path (exit $LOCAL_RC, out=$LOCAL_OUT)"
fi
echo

# ============================================================================
# (c) REGISTRY DURABILITY — scale-to-zero contrast (local LOST vs firestore SURVIVES).
# ============================================================================

# ---- HALF 1: LOCAL backend — the registry was on the wiped home A disk → LOST ----
echo "(c) HALF 1 — LOCAL backend: registered pubkey must be LOST on home wipe"
export HEIMDALL_STATE_BACKEND="local"
rm -rf "$HOME_A"
A_LOCAL="$(HEIMDALL_HOME="$HOME_A" "$PY" "$REGISTER" 2>"$EXT/a_local.err")"
A_LOCAL_HAID="${A_LOCAL%%|*}"
A_LOCAL_PUB="${A_LOCAL#*|}"
if [ -n "$A_LOCAL_HAID" ] && [ -n "$A_LOCAL_PUB" ]; then
  ok "c1 instance A registered the seeded pubkey under $A_LOCAL_HAID (home A, local)"
else
  bad "c1 instance A failed to register (local)"; cat "$EXT/a_local.err" >&2
fi
# sanity: instance A on its OWN home reads it back before the wipe.
A_SELF="$(HEIMDALL_HOME="$HOME_A" "$PY" "$READ_KEY" "$HEIMDALL_CP_SERVER_HAID" 2>/dev/null)"
[ "${A_SELF%%|*}" = "FOUND" ] \
  && ok "c2 instance A reads its own registered pubkey before the wipe (store works)" \
  || bad "c2 instance A could not read its own pubkey before the wipe (got '$A_SELF')"
# SCALE-TO-ZERO: instance A's ephemeral disk vanishes.
rm -rf "$HOME_A"
ok "c3 SCALE-TO-ZERO: instance A home ($HOME_A) wiped"
# instance B: a FRESH instance on a DIFFERENT home reads the registry.
rm -rf "$HOME_B"
B_LOCAL="$(HEIMDALL_HOME="$HOME_B" "$PY" "$READ_KEY" "$HEIMDALL_CP_SERVER_HAID" 2>/dev/null)"
if [ "$B_LOCAL" = "MISSING" ]; then
  ok "c4 instance B does NOT see the pubkey (registry was in the wiped home A) — LOST"
  echo "  → local: registry LOST on scale-to-zero (expected)"
else
  bad "c4 LOCAL SHOULD HAVE LOST THE REGISTRY but instance B found it ('$B_LOCAL') — scale-to-zero sim WRONG (homes not isolated)"
fi
echo

# ---- HALF 2: FIRESTORE backend — registry in the external store → SURVIVES ----
echo "(c) HALF 2 — FIRESTORE backend: registered pubkey must SURVIVE the home wipe"
export HEIMDALL_STATE_BACKEND="firestore"
rm -rf "$HOME_A"
A_FS="$(HEIMDALL_HOME="$HOME_A" "$PY" "$REGISTER" 2>"$EXT/a_fs.err")"
A_FS_HAID="${A_FS%%|*}"
A_FS_PUB="${A_FS#*|}"
if [ -n "$A_FS_HAID" ] && [ -n "$A_FS_PUB" ]; then
  ok "c5 instance A registered the seeded pubkey under $A_FS_HAID (home A, firestore)"
else
  bad "c5 instance A failed to register (firestore)"; cat "$EXT/a_fs.err" >&2
fi
# Prove the registry is NOT on the per-instance disk: home A holds no keys.json for it.
if [ ! -e "$HOME_A/control-plane/auth/keys.json" ]; then
  ok "c6 the firestore-backed registry has NO local keys.json under home A (state is external)"
else
  bad "c6 firestore-backed registry wrote a local keys.json under home A — NOT external (durability broken)"
fi
# SCALE-TO-ZERO: instance A's ephemeral disk vanishes.
rm -rf "$HOME_A"
ok "c7 SCALE-TO-ZERO: instance A home ($HOME_A) wiped"
# instance B: a FRESH instance on a DIFFERENT home reads the registry from the external store.
rm -rf "$HOME_B"
B_FS="$(HEIMDALL_HOME="$HOME_B" "$PY" "$READ_KEY" "$HEIMDALL_CP_SERVER_HAID" 2>"$EXT/b_fs.err")"
B_FS_FOUND="${B_FS%%|*}"
B_FS_PUB="${B_FS#*|}"
if [ "$B_FS_FOUND" = "FOUND" ]; then
  ok "c8 instance B SEES the registered pubkey from the external store (home wiped) — SURVIVED"
  echo "  → firestore: registry SURVIVED scale-to-zero (durability proven)"
else
  bad "c8 instance B did NOT resolve the firestore-backed pubkey after the wipe (got '$B_FS') — durability FAILED"
  cat "$EXT/b_fs.err" >&2
fi
# the surviving pubkey is the SAME deterministic key the seed derives (identity is stable).
if [ "$B_FS_FOUND" = "FOUND" ] && [ "$B_FS_PUB" = "$A_FS_PUB" ] && [ "$B_FS_PUB" = "$PUB1" ]; then
  ok "c9 the surviving pubkey EQUALS the seed-derived key — identity is stable across cold-start"
else
  bad "c9 surviving pubkey differs from the seed-derived key (B='$B_FS_PUB' A='$A_FS_PUB' seed='$PUB1')"
fi

echo
echo "============================================================"
echo "cp-auth-durability ($MODE): $PASS passed, $FAIL failed"
echo "  (a) determinism: same seed -> identical keypair across processes"
echo "  (b) fail-closed: cloud profile + absent seed REFUSES (no per-instance mint)"
echo "  (c) registry:    local LOST on scale-to-zero | firestore SURVIVED (durability proven)"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
