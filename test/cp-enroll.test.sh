#!/usr/bin/env bash
# cp-enroll.test.sh — TOKEN-GATED SELF-ENROLL under the FIRESTORE backend (deploy profile).
#
# WHAT THIS GATES. cp_enroll is the PKI-bootstrap route: a dev's first run POSTs its freshly
# generated pubkey to /enroll and is auto-registered haid->pubkey with ZERO manual steps, GATED
# by a shared TEAM BOOTSTRAP TOKEN (caller-presented) compared against a SERVER-SIDE secret
# (HEIMDALL_ENROLL_TOKEN). This suite drives the enroll() core + enroll_route() directly under
# HEIMDALL_STATE_BACKEND=firestore (the durable deploy profile), proving:
#
#   A. RIGHT TOKEN -> the haid->pubkey binding is registered THROUGH firestore (a FRESH process
#      reads it back — durable, no BackendUnavailable/path() on the registry write/read).
#   B. WRONG / ABSENT token -> REFUSED, and NOTHING is registered (the gate holds).
#   C. IDEMPOTENT: same haid + SAME pubkey -> ok (a harmless re-run).
#   D. CONFLICT: same haid + DIFFERENT pubkey -> refused (409 reason), binding UNCHANGED.
#   E. FAIL-CLOSED: server secret UNSET -> EVERY enroll refused (NEVER allow-all).
#   F. FALSIFIABLE (the cardinal): with the gate intact, an enroll presenting a WRONG token does
#      NOT register the haid. If the token check were broken (always-pass), this enroll WOULD
#      register and the "registry has no key for this haid" assertion FLIPS RED. This is the
#      guard that proves the token actually gates.
#   G. NO-SECRET: the route response (success AND refusal) NEVER carries the server secret.
#   H. SOURCE DISCIPLINE: cp_enroll never calls backend.path() (AST) — every registry op uses
#      cp_auth's StateBackend-seam accessors, which FirestoreBackend serves.
#
# DISCIPLINE (mirrors cp-presence.test.sh / cp-getjobs-firestore): isolated throwaway home +
# EXTERNAL store dir; firestore via the emulator when available, else the SAME faithful
# in-process fake google.cloud.firestore the other firestore gates use (persists to a JSON file
# so SEPARATE processes share one durable store). The server secret lives ONLY in env, never a
# tracked file, never printed. ZERO real GCP / ZERO spend in fake mode. Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
ENROLL_SRC="$LIB/cp_enroll.py"
export LIB REPO

for f in cp_enroll cp_auth cp_server cp_state cp_state_firestore; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

# crypto gate: enroll binds an Ed25519 pubkey; absent a crypto backend the keypair cannot be
# minted, so SKIP cleanly (the in-process core needs PKI to generate a valid pubkey).
if ! "$PY" -c "import sys; sys.path.insert(0,'$LIB'); import cp_auth; sys.exit(0 if cp_auth.crypto_available() else 1)"; then
  echo "  SKIP no crypto backend (cryptography|pynacl) — enroll needs PKI to mint a pubkey."
  echo "cp-enroll: 0 passed, 0 failed (SKIPPED — no crypto)"
  exit 0
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# The external-store dir (emulator data / fake JSON store + the fake package). Lives OUTSIDE the
# per-instance home so the backend's external-ness is honest.
EXT="$(mktemp -d -t "cp-enroll.$(printf 'X%.0s' 1 2 3 4 5 6)")"
HOME_T="$EXT/home"
mkdir -p "$HOME_T"
EMU_PID=""
cleanup() { [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1 || true; rm -rf "$EXT"; }
trap cleanup EXIT

export HEIMDALL_HOME="$HOME_T"
export HEIMDALL_FIRESTORE_ROOT="enroll_firestore_gate"
export HEIMDALL_FIRESTORE_PROJECT="cp-enroll-test"

# The TEAM BOOTSTRAP TOKEN secret (server-side verifier). In env only — never a tracked file.
export HEIMDALL_ENROLL_TOKEN="team-bootstrap-secret-7f3a91"

# ── decide firestore mode: emulator (real client) vs faithful in-process fake ──
MODE=""
if [ -n "${FIRESTORE_EMULATOR_HOST:-}" ] \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  MODE="emulator"
fi
if [ -z "$MODE" ] \
   && command -v gcloud >/dev/null 2>&1 \
   && gcloud beta emulators firestore --help >/dev/null 2>&1 \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  EMU_HOST="localhost:8786"
  gcloud beta emulators firestore start --host-port="$EMU_HOST" >"$EXT/emu.log" 2>&1 &
  EMU_PID=$!
  for _ in $(seq 1 40); do
    grep -q "$EMU_HOST" "$EXT/emu.log" 2>/dev/null && break
    kill -0 "$EMU_PID" >/dev/null 2>&1 || break
    "$PY" -c "import time;time.sleep(0.25)"
  done
  if kill -0 "$EMU_PID" >/dev/null 2>&1 && grep -q "$EMU_HOST" "$EXT/emu.log" 2>/dev/null; then
    export FIRESTORE_EMULATOR_HOST="$EMU_HOST"; MODE="emulator"
  else
    [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1; EMU_PID=""
  fi
fi
if [ -z "$MODE" ]; then
  MODE="fake"
  FAKEPKG="$EXT/pylib"
  mkdir -p "$FAKEPKG"
  cat >"$FAKEPKG/_fake_firestore_impl.py" <<'PYEOF'
# Faithful in-process FAKE of the google.cloud.firestore slice FirestoreBackend uses.
# PERSISTS to the JSON file named by HEIMDALL_FAKE_FS_STORE so SEPARATE processes share one
# durable store — the cross-process property a real Firestore has.
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
    tmp = _store_path() + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    os.replace(tmp, _store_path())


class Client:
    def __init__(self, project=None, database=None):
        self.project = project
        self._database = database

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

export HEIMDALL_STATE_BACKEND="firestore"

echo "============================================================"
echo "TOKEN-GATED SELF-ENROLL under FIRESTORE (MODE=$MODE)"
echo "  home=$HEIMDALL_HOME  root=$HEIMDALL_FIRESTORE_ROOT"
echo "============================================================"
echo

# A FRESH client keypair (the dev's first-run identity). Minted once and shared (via env) so the
# write proc and a separate read proc agree on the pubkey. The private seed is NEVER sent to the
# server — only the pubkey enrolls.
KEYS_JSON="$("$PY" - <<'PYEOF'
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_auth
priv, pub = cp_auth.generate_keypair()
print(json.dumps({"priv": priv, "pub": pub}))
PYEOF
)"
DEV_PRIV="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['priv'])" "$KEYS_JSON")"
DEV_PUB="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['pub'])" "$KEYS_JSON")"
DEV_HAID="haid:rj.mbp-7f3a"
WRONG_KEYS="$("$PY" - <<'PYEOF'
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_auth
_p, pub2 = cp_auth.generate_keypair()
print(pub2)
PYEOF
)"
export DEV_PRIV DEV_PUB DEV_HAID WRONG_KEYS

# ──────────────────────────────────────────────────────────────────────────────
# A. RIGHT TOKEN -> registered THROUGH firestore; a FRESH process reads the binding back.
# ──────────────────────────────────────────────────────────────────────────────
echo "A. right token -> enroll registers haid->pubkey (firestore round-trip, no path())"
A_WRITE="$("$PY" - <<'PYEOF' 2>"$EXT/a.err"
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_enroll
r = cp_enroll.enroll(os.environ["DEV_HAID"], os.environ["DEV_PUB"],
                     provided_token=os.environ["HEIMDALL_ENROLL_TOKEN"], handle="rj")
print(json.dumps(r))
PYEOF
)"
A_OK="$(printf '%s' "$A_WRITE" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('ok'))" 2>/dev/null)"
if [ "$A_OK" = "True" ] && [ ! -s "$EXT/a.err" ]; then
  ok "A1 right token -> enroll() ok under firestore (no BackendUnavailable on the registry write)"
else
  bad "A1 enroll with the right token failed (got '$A_WRITE')"; cat "$EXT/a.err" >&2
fi
A_READ="$("$PY" - <<'PYEOF' 2>"$EXT/aread.err"
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth
print(cp_auth.registered_pubkey(os.environ["DEV_HAID"]) or "")
PYEOF
)"
if [ "$A_READ" = "$DEV_PUB" ] && [ ! -s "$EXT/aread.err" ]; then
  ok "A2 a FRESH process reads the haid->pubkey binding back from firestore (durable, no path())"
else
  bad "A2 fresh-process registry read did not return the enrolled pubkey (got '$A_READ')"; cat "$EXT/aread.err" >&2
fi

# ──────────────────────────────────────────────────────────────────────────────
# C. IDEMPOTENT: same haid + SAME pubkey -> ok (run before the conflict/wrong-token cases so
#    the binding established in A is what we re-enroll against).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "C. idempotent re-enroll (same haid + same pubkey)"
C_OUT="$("$PY" - <<'PYEOF' 2>/dev/null
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_enroll
print(json.dumps(cp_enroll.enroll(os.environ["DEV_HAID"], os.environ["DEV_PUB"],
                                  provided_token=os.environ["HEIMDALL_ENROLL_TOKEN"])))
PYEOF
)"
C_OK="$(printf '%s' "$C_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('ok'))" 2>/dev/null)"
[ "$C_OK" = "True" ] \
  && ok "C1 same haid + same pubkey re-enroll -> ok (idempotent, harmless re-run)" \
  || bad "C1 idempotent re-enroll did not return ok (got '$C_OUT')"

# ──────────────────────────────────────────────────────────────────────────────
# D. CONFLICT: same haid + DIFFERENT pubkey -> refused (409 reason), binding UNCHANGED.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "D. conflict: same haid + a DIFFERENT pubkey -> refused, binding unchanged"
D_OUT="$("$PY" - <<'PYEOF' 2>/dev/null
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_enroll
print(json.dumps(cp_enroll.enroll(os.environ["DEV_HAID"], os.environ["WRONG_KEYS"],
                                  provided_token=os.environ["HEIMDALL_ENROLL_TOKEN"])))
PYEOF
)"
D_REASON="$(printf '%s' "$D_OUT" | "$PY" -c "import json,sys;d=json.load(sys.stdin);print(d.get('reason') if not d.get('ok') else 'OK')" 2>/dev/null)"
D_STILL="$("$PY" -c "import os,sys;sys.path.insert(0,os.environ['LIB']);import cp_auth;print(cp_auth.registered_pubkey(os.environ['DEV_HAID']))" 2>/dev/null)"
if [ "$D_REASON" = "haid_pubkey_conflict" ] && [ "$D_STILL" = "$DEV_PUB" ]; then
  ok "D1 same haid + different pubkey -> refused (haid_pubkey_conflict); the original binding is UNCHANGED"
else
  bad "D1 a different-key re-enroll was not refused / rebound the key (reason='$D_REASON', now='$D_STILL')"
fi

# ──────────────────────────────────────────────────────────────────────────────
# B + F. WRONG / ABSENT token -> REFUSED and NOTHING registered (the gate holds). FALSIFIABLE:
#    a NEW haid presenting a WRONG token must NOT register; if the token check were broken
#    (always-pass), this enroll WOULD register and the assertion below FLIPS RED.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "B/F. wrong + absent token -> REFUSED, NOTHING registered [FALSIFIABLE — the gate]"
NEW_HAID="haid:mallory.box-dead"
export NEW_HAID
B_OUT="$("$PY" - <<'PYEOF' 2>/dev/null
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_enroll, cp_auth
wrong = cp_enroll.enroll(os.environ["NEW_HAID"], os.environ["DEV_PUB"], provided_token="NOT-THE-TOKEN")
absent = cp_enroll.enroll(os.environ["NEW_HAID"], os.environ["DEV_PUB"], provided_token=None)
registered = cp_auth.registered_pubkey(os.environ["NEW_HAID"])
print(json.dumps({"wrong": wrong, "absent": absent, "registered": registered}))
PYEOF
)"
B_WRONG_REASON="$(printf '%s' "$B_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['wrong'].get('reason'))" 2>/dev/null)"
B_ABSENT_REASON="$(printf '%s' "$B_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['absent'].get('reason'))" 2>/dev/null)"
B_REGISTERED="$(printf '%s' "$B_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['registered'])" 2>/dev/null)"
if [ "$B_WRONG_REASON" = "bad_enroll_token" ] && [ "$B_ABSENT_REASON" = "bad_enroll_token" ]; then
  ok "B1 a wrong token AND an absent token are BOTH refused (bad_enroll_token)"
else
  bad "B1 a wrong/absent token was not refused (wrong='$B_WRONG_REASON' absent='$B_ABSENT_REASON')"
fi
if [ "$B_REGISTERED" = "None" ]; then
  ok "F1 FALSIFIABLE: a wrong/absent-token enroll registered NOTHING — the token gate holds (break it -> RED)"
else
  bad "F1 a wrong/absent-token enroll REGISTERED a key ('$B_REGISTERED') — the token check is NOT gating (RED)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# E. FAIL-CLOSED: server secret UNSET -> EVERY enroll refused (NEVER allow-all).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "E. fail-closed: server secret UNSET -> every enroll refused (never allow-all)"
E_OUT="$(env -u HEIMDALL_ENROLL_TOKEN "$PY" - <<'PYEOF' 2>/dev/null
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_enroll, cp_auth
# No server secret. EVEN presenting a plausible token must be refused, and even an EMPTY token,
# and nothing registers — the route is disabled, never allow-all.
r1 = cp_enroll.enroll("haid:nobody.box-1", os.environ["DEV_PUB"], provided_token="anything-at-all")
r2 = cp_enroll.enroll("haid:nobody.box-2", os.environ["DEV_PUB"], provided_token="")
reg1 = cp_auth.registered_pubkey("haid:nobody.box-1")
reg2 = cp_auth.registered_pubkey("haid:nobody.box-2")
print(json.dumps({"r1": r1, "r2": r2, "reg1": reg1, "reg2": reg2}))
PYEOF
)"
# The reason is "enroll_disabled" locally and "enroll_disabled_cloud_profile" in the cloud
# profile (firestore mode IS the cloud profile here); both are the fail-closed refusal — assert
# on the common "enroll_disabled" prefix so either profile passes.
E_R1="$(printf '%s' "$E_OUT" | "$PY" -c "import json,sys;d=json.load(sys.stdin)['r1'];print(d.get('reason') if not d.get('ok') else 'OK')" 2>/dev/null)"
E_REG="$(printf '%s' "$E_OUT" | "$PY" -c "import json,sys;d=json.load(sys.stdin);print(d['reg1'] is None and d['reg2'] is None)" 2>/dev/null)"
case "$E_R1" in enroll_disabled|enroll_disabled_cloud_profile) E_R1_OK=1 ;; *) E_R1_OK=0 ;; esac
if [ "$E_R1_OK" = "1" ] && [ "$E_REG" = "True" ]; then
  ok "E1 server secret unset -> $E_R1, NOTHING registered (fail-closed, never allow-all)"
else
  bad "E1 a secret-unset enroll was not fail-closed (reason='$E_R1', none-registered='$E_REG')"
fi

# ──────────────────────────────────────────────────────────────────────────────
# G. NO-SECRET: the route response (success AND refusal) NEVER carries the server secret.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "G. no-secret: the route response never carries the server secret"
G_OUT="$("$PY" - <<'PYEOF' 2>/dev/null
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_enroll
secret = os.environ["HEIMDALL_ENROLL_TOKEN"]
# A success (new haid) and a refusal (wrong token), both as the wire route would render them.
ok_resp = cp_enroll.enroll_route({"body": json.dumps(
    {"haid": "haid:fresh.box-9", "pubkey": os.environ["DEV_PUB"], "enroll_token": secret}).encode()})
bad_resp = cp_enroll.enroll_route({"body": json.dumps(
    {"haid": "haid:fresh.box-9", "pubkey": os.environ["DEV_PUB"], "enroll_token": "WRONG"}).encode()})
blob = json.dumps([ok_resp.status, ok_resp.body, bad_resp.status, bad_resp.body])
print(json.dumps({"leak": secret in blob, "ok_body": ok_resp.body, "bad_status": bad_resp.status}))
PYEOF
)"
G_LEAK="$(printf '%s' "$G_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['leak'])" 2>/dev/null)"
if [ "$G_LEAK" = "False" ]; then
  ok "G1 neither the success nor the refusal response carries the server secret (no-secret-by-construction)"
else
  bad "G1 the route response LEAKED the server secret (out='$G_OUT')"
fi

# ──────────────────────────────────────────────────────────────────────────────
# H. SOURCE DISCIPLINE — cp_enroll never calls backend.path() on a serving path.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "H. source discipline (AST of cp_enroll.py — ignores docstring mentions)"
PATH_CALLS="$(ENROLL_SRC="$ENROLL_SRC" "$PY" - <<'PYEOF' 2>/dev/null
import ast, os
src = open(os.environ["ENROLL_SRC"], encoding="utf-8").read()
n = 0
for node in ast.walk(ast.parse(src)):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
       and node.func.attr == "path":
        n += 1
print(n)
PYEOF
)"
if [ "${PATH_CALLS:-1}" = "0" ]; then
  ok "H cp_enroll.py NEVER calls backend.path() — the registry op goes through cp_auth's StateBackend seam (firestore-safe)"
else
  bad "H cp_enroll.py has $PATH_CALLS real .path() call(s) — FirestoreBackend.path() RAISES on a serving path"
fi

# ──────────────────────────────────────────────────────────────────────────────
# I. OPEN MODE: HEIMDALL_ENROLL_OPEN=1, NO token presented (server token STILL set) -> a fresh
#    haid enrolls; the enrolled key then signs a presence message that VERIFIES against the
#    registered pubkey. Proves tokenless onboarding works AND the key is usable at the §3 chokepoint.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "I. OPEN MODE: HEIMDALL_ENROLL_OPEN=1, NO token -> fresh haid enrolls + the key signs/verifies"
I_OUT="$(env HEIMDALL_ENROLL_OPEN=1 "$PY" - <<'PYEOF' 2>"$EXT/i.err"
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_enroll, cp_auth
# Server token is STILL configured (env), but NO token is presented — open mode must allow it.
priv, pub = cp_auth.generate_keypair()
haid = "haid:opendev.box-aa01"
r = cp_enroll.enroll(haid, pub, provided_token=None)
got = cp_auth.registered_pubkey(haid)
owner = cp_auth.is_owner(haid)
msg = cp_auth.canonical_message("POST", "/presence", b"{}")
sig = cp_auth.sign(priv, msg)
verified = bool(got) and cp_auth.verify_raw(got, msg, sig)
print(json.dumps({"ok": r.get("ok"), "reason": r.get("reason"),
                  "bound": got == pub, "owner": owner, "verified": verified}))
PYEOF
)"
I_OK="$(printf '%s' "$I_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('ok'))" 2>/dev/null)"
I_BOUND="$(printf '%s' "$I_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('bound'))" 2>/dev/null)"
I_OWNER="$(printf '%s' "$I_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('owner'))" 2>/dev/null)"
I_VERIFIED="$(printf '%s' "$I_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('verified'))" 2>/dev/null)"
if [ "$I_OK" = "True" ] && [ "$I_BOUND" = "True" ] && [ "$I_VERIFIED" = "True" ] && [ "$I_OWNER" = "False" ]; then
  ok "I1 open mode: a TOKENLESS enroll binds the haid (owner=False) and the key signs+verifies (durable firestore)"
else
  bad "I1 open-mode tokenless enroll/verify failed (out='$I_OUT')"; cat "$EXT/i.err" >&2
fi

# ──────────────────────────────────────────────────────────────────────────────
# J. REGISTRY CAP [FALSIFIABLE]: with HEIMDALL_ENROLL_MAX_KEYS=start+3, three NET-NEW haids
#    enroll OK, the 4th (which would exceed the cap) is REFUSED (enroll_registry_full); an
#    EXISTING haid re-enroll is STILL ok (never blocked by the cap). Remove the cap check ->
#    the 4th wrongly succeeds -> this section FLIPS RED.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "J. REGISTRY CAP: the (cap+1)th NET-NEW haid -> refused (enroll_registry_full); existing re-enroll ok [FALSIFIABLE]"
J_OUT="$("$PY" - <<'PYEOF' 2>"$EXT/j.err"
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_enroll, cp_auth
token = os.environ["HEIMDALL_ENROLL_TOKEN"]
start = cp_enroll._registry_key_count()
os.environ["HEIMDALL_ENROLL_MAX_KEYS"] = str(start + 3)   # room for exactly 3 more net-new keys
_, pub = cp_auth.generate_keypair()
res = []
for i in range(4):                                        # 3 fit, the 4th must be refused
    res.append(cp_enroll.enroll("haid:capdev.box-%02d" % i, pub, provided_token=token))
# an EXISTING haid re-enroll (same key) is never blocked by the cap, even now that it is full:
reenroll = cp_enroll.enroll("haid:capdev.box-00", pub, provided_token=token)
print(json.dumps({
    "net_new_ok": all(r.get("ok") for r in res[:3]),
    "capped_reason": res[3].get("reason"),
    "capped_ok": res[3].get("ok"),
    "reenroll_ok": reenroll.get("ok"),
}))
PYEOF
)"
J_NEWOK="$(printf '%s' "$J_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('net_new_ok'))" 2>/dev/null)"
J_REASON="$(printf '%s' "$J_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('capped_reason'))" 2>/dev/null)"
J_CAPOK="$(printf '%s' "$J_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('capped_ok'))" 2>/dev/null)"
J_REOK="$(printf '%s' "$J_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('reenroll_ok'))" 2>/dev/null)"
if [ "$J_NEWOK" = "True" ] && [ "$J_REASON" = "enroll_registry_full" ] && [ "$J_CAPOK" != "True" ] && [ "$J_REOK" = "True" ]; then
  ok "J1 FALSIFIABLE: 3 net-new fit, the 4th is refused (enroll_registry_full), existing re-enroll still ok — remove the cap => RED"
else
  bad "J1 the registry cap did not bound net-new growth (out='$J_OUT')"; cat "$EXT/j.err" >&2
fi

# ──────────────────────────────────────────────────────────────────────────────
# K. OPEN-MODE RATE: a per-IP flood through cp_publicsurface.check_enroll (NO token presented)
#    trips the per-IP cap -> 429. Proves the limiter fires tokenlessly in open mode (the
#    load-bearing flood control), at the tightened open-mode per-IP default (5).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "K. OPEN-MODE RATE: a tokenless per-IP flood through check_enroll -> 429 (no token needed to trip it)"
K_OUT="$(env HEIMDALL_ENROLL_OPEN=1 "$PY" - <<'PYEOF' 2>"$EXT/k.err"
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_publicsurface
# NO enroll token in the request — the per-IP cap (open default 5) is the load-bearing limit.
req = {"peer_ip": "203.0.113.9",
       "body": json.dumps({"haid": "haid:flood", "pubkey": "x"})}
statuses = []
for _ in range(7):                       # 5 allowed, then refused for the same IP+window
    r = cp_publicsurface.check_enroll(req, now=1000.0)
    statuses.append(None if r is None else r[0])
print(json.dumps({"statuses": statuses, "ip_limit": cp_publicsurface._enroll_ip_limit()}))
PYEOF
)"
K_LIMIT="$(printf '%s' "$K_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('ip_limit'))" 2>/dev/null)"
K_ALLOWED="$(printf '%s' "$K_OUT" | "$PY" -c "import json,sys;s=json.load(sys.stdin)['statuses'];print(sum(1 for x in s if x is None))" 2>/dev/null)"
K_REFUSED="$(printf '%s' "$K_OUT" | "$PY" -c "import json,sys;s=json.load(sys.stdin)['statuses'];print(429 in s)" 2>/dev/null)"
if [ "$K_LIMIT" = "5" ] && [ "$K_ALLOWED" = "5" ] && [ "$K_REFUSED" = "True" ]; then
  ok "K1 open mode: a tokenless per-IP flood is rate-limited -> 429 after the tightened cap (5) — the limiter fires with NO token"
else
  bad "K1 the open-mode per-IP flood was not rate-limited tokenlessly (out='$K_OUT')"; cat "$EXT/k.err" >&2
fi

echo
echo "============================================================"
printf "cp-enroll (%s): %d passed, %d failed\n" "$MODE" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
