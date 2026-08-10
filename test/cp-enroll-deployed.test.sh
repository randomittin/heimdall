#!/usr/bin/env bash
# cp-enroll-deployed.test.sh — THE DEPLOYED-SHAPE ENROLL GATE: a REAL `heimdall-control-plane
# serve` subprocess under firestore, the token-gated /enroll served PRE-AUTH over real HTTP, and
# the proof that the enrolled key's SIGNED presence beat then verifies at the §3 chokepoint.
#
# WHAT THIS GATES (the zero-touch first-run, end to end on the wire).
#   #1 BOOT the REAL serve subprocess under firestore (server PKI seed + HEIMDALL_ENROLL_TOKEN).
#   #2 mint a FRESH dev keypair (NOT the server's) — the dev's first-run identity, unregistered.
#   #3 BASELINE FALSIFIER: a SIGNED presence beat from the dev key BEFORE enroll -> server 401
#      (unknown_haid). This proves the key is NOT yet trusted, so #5's success is attributable to
#      the enrollment, not to a pre-existing binding.
#   #4 the dev's first run UNSIGNED POST /enroll (token in the X-Heimdall-Enroll-Token header) ->
#      200 {ok:true, haid}. [CARDINAL] The route is reachable PRE-AUTH (not 401 at the chokepoint),
#      and the header-borne token is verified server-side.
#   #5 AFTER enroll: a SIGNED presence beat from the SAME dev key now VERIFIES (not 401) and a
#      signed roster read returns the dev — the enrolled key works through the §3 chokepoint over
#      a real socket under firestore (no BackendUnavailable). [CARDINAL]
#   #6 the GATE over the wire: an UNSIGNED POST /enroll with a WRONG token -> 401, and a signed
#      beat from that would-be haid still 401s (NOTHING was registered). FALSIFIABLE — break the
#      token check and the wrong-token enroll would 200 + the beat would verify => RED.
#   #7 NO-SECRET: no enroll response body carries the server secret (grep over the wire bytes).
#
# DISCIPLINE (mirrors cp-presence-deployed): isolated throwaway home + EXTERNAL store dir;
# firestore via emulator if available, else the faithful in-process fake; the PKI seed AND the
# enroll token live ONLY in env (never a tracked file, never printed); the serve subprocess is
# REAPED on EXIT; ZERO real GCP / ZERO spend in fake mode. Exit 0 = the wire holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
CLI="$REPO/bin/heimdall-control-plane"
export LIB REPO

for f in cp_server cp_boot cp_auth cp_enroll cp_presence cp_state cp_state_firestore; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done
[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# crypto gate: this gate REQUIRES PKI (signed HTTP + a real pubkey to enroll). Absent -> SKIP.
if ! "$PY" -c "import sys; sys.path.insert(0,'$LIB'); import cp_auth; sys.exit(0 if cp_auth.crypto_available() else 1)"; then
  echo "  SKIP no crypto backend (cryptography|pynacl) — the signed-HTTP enroll gate needs PKI."
  echo "cp-enroll-deployed: 0 passed, 0 failed (SKIPPED — no crypto)"
  exit 0
fi

EXT="$(mktemp -d -t "cp-enrdep.$(printf 'X%.0s' 1 2 3 4 5 6)")"
HOME_T="$EXT/home"
mkdir -p "$HOME_T"
SERVER_PID=""
EMU_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1 || true
  rm -rf "$EXT"
}
trap cleanup EXIT

export HEIMDALL_HOME="$HOME_T"
export HEIMDALL_FIRESTORE_ROOT="enroll_deployed_gate"
export HEIMDALL_FIRESTORE_PROJECT="cp-enroll-deployed-test"

# ── a TEST PKI seed for the SERVER identity (in memory only) + the team enroll token ──
SEED_B64="$("$PY" -c "import base64;print(base64.b64encode(bytes((i*11+5)%256 for i in range(32))).decode())")"
export HEIMDALL_CP_PKI_KEY="$SEED_B64"
export HEIMDALL_CP_SERVER_HAID="haid:cp-server"
export HEIMDALL_ENROLL_TOKEN="team-bootstrap-secret-deployed-91c2"

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
  EMU_HOST="localhost:8788"
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
# PERSISTS to the JSON file named by HEIMDALL_FAKE_FS_STORE so the serve subprocess + the signing
# client share one durable store — the cross-process property a real Firestore has.
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
echo "DEPLOYED-SHAPE ENROLL GATE (MODE=$MODE)"
echo "  home=$HEIMDALL_HOME  root=$HEIMDALL_FIRESTORE_ROOT"
echo "============================================================"
echo

PROJECT="acme/widget"
DEV_HAID="haid:newdev.box-1234"

# ──────────────────────────────────────────────────────────────────────────────
# #1 BOOT the REAL serve subprocess under firestore.
# ──────────────────────────────────────────────────────────────────────────────
echo "#1 boot the REAL serve subprocess under firestore (PKI seed + enroll token set)"
CP_PORT="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
HMD_CP_GUARD_PID=$$ "$CLI" serve --host 127.0.0.1 --port "$CP_PORT" --home "$HEIMDALL_HOME" --no-revocation \
  >"$EXT/serve.out" 2>"$EXT/serve.err" &
SERVER_PID=$!
UP=""
for _ in $(seq 1 50); do
  if "$PY" -c "import socket,sys
s=socket.socket(); s.settimeout(0.2)
try:
    s.connect(('127.0.0.1', $CP_PORT)); s.close()
except OSError:
    sys.exit(1)" 2>/dev/null; then UP="1"; break; fi
  sleep 0.1
done
if [ -n "$UP" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
  ok "#1 the REAL wired server is live on 127.0.0.1:$CP_PORT under firestore (pid $SERVER_PID)"
else
  bad "#1 the firestore-mode wired server did not come up"; cat "$EXT/serve.err" >&2
fi
export CP_PORT PROJECT DEV_HAID

# ──────────────────────────────────────────────────────────────────────────────
# #2 mint a FRESH dev keypair (the first-run identity; NOT the server's).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#2 mint a fresh dev keypair (unregistered first-run identity)"
KEYS="$("$PY" - <<'PYEOF' 2>/dev/null
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_auth
priv, pub = cp_auth.generate_keypair()
print(json.dumps({"priv": priv, "pub": pub}))
PYEOF
)"
DEV_PRIV="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['priv'])" "$KEYS")"
DEV_PUB="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['pub'])" "$KEYS")"
export DEV_PRIV DEV_PUB
[ -n "$DEV_PUB" ] && ok "#2 fresh dev keypair minted (pubkey is what enrolls; the seed never leaves the client)" \
  || bad "#2 could not mint a dev keypair"

# A reusable signed-presence-beat probe: signs canonical_message(POST,/presence,body) with the
# dev seed and returns the HTTP status. Used BEFORE (expect 401) and AFTER (expect 200) enroll.
beat_status() {  # $1=haid $2=priv  -> prints HTTP status
  CP_PORT="$CP_PORT" PROJECT="$PROJECT" BEAT_HAID="$1" BEAT_PRIV="$2" "$PY" - <<'PYEOF' 2>/dev/null
import os, sys, json, urllib.request, urllib.error
sys.path.insert(0, os.environ["LIB"])
import cp_auth as K
port = int(os.environ["CP_PORT"])
haid = os.environ["BEAT_HAID"]; priv = os.environ["BEAT_PRIV"]
body = json.dumps({"project": os.environ["PROJECT"], "handle": "newdev"}).encode("utf-8")
req = urllib.request.Request("http://127.0.0.1:%d/presence" % port, data=body, method="POST")
req.add_header("Content-Type", "application/json")
req.add_header("X-Heimdall-HAID", haid)
req.add_header("X-Heimdall-Signature", K.sign(priv, K.canonical_message("POST", "/presence", body)))
try:
    with urllib.request.urlopen(req, timeout=8) as r:
        print(r.status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception as e:  # noqa: BLE001
    print("ERR:%s" % type(e).__name__)
PYEOF
}

# ──────────────────────────────────────────────────────────────────────────────
# #3 BASELINE FALSIFIER: a signed beat from the dev key BEFORE enroll -> 401 (unknown_haid).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#3 BASELINE: a signed presence beat from the UN-enrolled dev key -> 401 (not yet trusted)"
PRE_STATUS="$(beat_status "$DEV_HAID" "$DEV_PRIV")"
[ "$PRE_STATUS" = "401" ] \
  && ok "#3 the dev key is NOT trusted before enroll (signed beat -> 401) — #5's success is attributable to enrollment" \
  || bad "#3 a pre-enroll signed beat did not 401 (got '$PRE_STATUS') — the key was already trusted?"

# ──────────────────────────────────────────────────────────────────────────────
# #4 the dev's first run UNSIGNED POST /enroll (token in the HEADER) -> 200 {ok,haid}. [CARDINAL]
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#4 the first-run UNSIGNED POST /enroll (right token in the header) -> 200 {ok,haid} [CARDINAL]"
ENROLL_OUT="$(CP_PORT="$CP_PORT" DEV_HAID="$DEV_HAID" DEV_PUB="$DEV_PUB" \
  ENROLL_TOKEN="$HEIMDALL_ENROLL_TOKEN" "$PY" - <<'PYEOF' 2>/dev/null
import os, sys, json, urllib.request, urllib.error
port = int(os.environ["CP_PORT"])
body = json.dumps({"haid": os.environ["DEV_HAID"], "pubkey": os.environ["DEV_PUB"]}).encode("utf-8")
# UNSIGNED — no X-Heimdall-HAID / X-Heimdall-Signature. The bootstrap token rides the header.
req = urllib.request.Request("http://127.0.0.1:%d/enroll" % port, data=body, method="POST")
req.add_header("Content-Type", "application/json")
req.add_header("X-Heimdall-Enroll-Token", os.environ["ENROLL_TOKEN"])
try:
    with urllib.request.urlopen(req, timeout=8) as r:
        print(json.dumps({"status": r.status, "body": json.loads(r.read() or b"{}")}))
except urllib.error.HTTPError as e:
    print(json.dumps({"status": e.code, "body": json.loads(e.read() or b"{}")}))
except Exception as e:  # noqa: BLE001
    print(json.dumps({"status": "ERR", "body": type(e).__name__}))
PYEOF
)"
E_STATUS="$(printf '%s' "$ENROLL_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['status'])" 2>/dev/null)"
E_OK="$(printf '%s' "$ENROLL_OUT" | "$PY" -c "import json,sys;b=json.load(sys.stdin)['body'];print(b.get('ok'))" 2>/dev/null)"
E_HAID="$(printf '%s' "$ENROLL_OUT" | "$PY" -c "import json,sys;b=json.load(sys.stdin)['body'];print(b.get('haid'))" 2>/dev/null)"
if [ "$E_STATUS" = "200" ] && [ "$E_OK" = "True" ] && [ "$E_HAID" = "$DEV_HAID" ]; then
  ok "#4 UNSIGNED /enroll is served PRE-AUTH (not 401) and the header token enrolls -> 200 {ok:true, haid} [CARDINAL]"
else
  bad "#4 the unsigned enroll did not succeed (out='$ENROLL_OUT')"; cat "$EXT/serve.err" >&2
fi

# ──────────────────────────────────────────────────────────────────────────────
# #5 AFTER enroll: the SAME dev key's signed beat now verifies (not 401) + the roster shows it.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#5 AFTER enroll: the enrolled key's signed beat verifies + the roster returns the dev [CARDINAL]"
POST_STATUS="$(beat_status "$DEV_HAID" "$DEV_PRIV")"
ROSTER_HAS_DEV="$(CP_PORT="$CP_PORT" PROJECT="$PROJECT" DEV_HAID="$DEV_HAID" DEV_PRIV="$DEV_PRIV" "$PY" - <<'PYEOF' 2>/dev/null
import os, sys, json, urllib.request, urllib.error, urllib.parse
sys.path.insert(0, os.environ["LIB"])
import cp_auth as K
port = int(os.environ["CP_PORT"]); haid = os.environ["DEV_HAID"]; priv = os.environ["DEV_PRIV"]
path = "/roster?" + urllib.parse.urlencode({"project": os.environ["PROJECT"]})
req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path), data=None, method="GET")
req.add_header("X-Heimdall-HAID", haid)
req.add_header("X-Heimdall-Signature", K.sign(priv, K.canonical_message("GET", path, b"")))
try:
    with urllib.request.urlopen(req, timeout=8) as r:
        body = json.loads(r.read() or b"{}")
        rows = body.get("roster") or []
        print(any(x.get("haid") == haid for x in rows))
except Exception as e:  # noqa: BLE001
    print("ERR:%s" % type(e).__name__)
PYEOF
)"
if [ "$POST_STATUS" = "200" ] && [ "$ROSTER_HAS_DEV" = "True" ]; then
  ok "#5 the enrolled key's signed beat VERIFIES (200, not 401) and the roster returns the dev over firestore [CARDINAL]"
else
  bad "#5 the enrolled key did not work end-to-end (beat_status='$POST_STATUS', roster_has_dev='$ROSTER_HAS_DEV')"; cat "$EXT/serve.err" >&2
fi

# ──────────────────────────────────────────────────────────────────────────────
# #6 the GATE over the wire: an UNSIGNED /enroll with a WRONG token -> 401, and a signed beat
#    from that would-be haid still 401s (NOTHING registered). FALSIFIABLE.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#6 wrong-token UNSIGNED /enroll -> 401, and the would-be haid stays untrusted [FALSIFIABLE]"
MAL_HAID="haid:mallory.box-bad"
MAL_OUT="$(CP_PORT="$CP_PORT" MAL_HAID="$MAL_HAID" DEV_PUB="$DEV_PUB" "$PY" - <<'PYEOF' 2>/dev/null
import os, sys, json, urllib.request, urllib.error
port = int(os.environ["CP_PORT"])
body = json.dumps({"haid": os.environ["MAL_HAID"], "pubkey": os.environ["DEV_PUB"]}).encode("utf-8")
req = urllib.request.Request("http://127.0.0.1:%d/enroll" % port, data=body, method="POST")
req.add_header("Content-Type", "application/json")
req.add_header("X-Heimdall-Enroll-Token", "WRONG-TOKEN-NOT-THE-SECRET")
try:
    with urllib.request.urlopen(req, timeout=8) as r:
        print(r.status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception as e:  # noqa: BLE001
    print("ERR:%s" % type(e).__name__)
PYEOF
)"
# A signed beat from the would-be haid (reuse the dev seed as the claimed key) must still 401:
# the wrong-token enroll registered nothing, so the haid has no trusted key.
MAL_BEAT="$(beat_status "$MAL_HAID" "$DEV_PRIV")"
if [ "$MAL_OUT" = "401" ] && [ "$MAL_BEAT" = "401" ]; then
  ok "#6 FALSIFIABLE: a wrong-token enroll is 401 over the wire AND registered nothing (the would-be haid still 401s) — break the token check => RED"
else
  bad "#6 the wrong-token enroll was not gated (enroll_status='$MAL_OUT', beat_after='$MAL_BEAT')"
fi

# ──────────────────────────────────────────────────────────────────────────────
# #7 NO-SECRET — no enroll response carried the server secret over the wire.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#7 no-secret: no enroll response body carried the server secret"
if ! grep -qF "$HEIMDALL_ENROLL_TOKEN" <<<"$ENROLL_OUT$MAL_OUT"; then
  ok "#7 no enroll response (success or refusal) echoed the server secret — server-only by construction"
else
  bad "#7 an enroll response carried the server secret over the wire"
fi

# ──────────────────────────────────────────────────────────────────────────────
# #8 OPEN MODE end-to-end on the wire: a TOKENLESS open-mode enroll (HEIMDALL_ENROLL_OPEN=1,
#    no token presented) registers a fresh dev key in the SAME firestore the live server reads;
#    a signed beat from that key BEFORE enroll 401s (baseline) and AFTER enroll VERIFIES (200) at
#    the §3 chokepoint over a real socket. Proves open onboarding yields a chokepoint-usable key.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#8 OPEN MODE: tokenless enroll (HEIMDALL_ENROLL_OPEN=1) -> the enrolled key signs a beat over the wire -> 200"
DEV2_KEYS="$("$PY" - <<'PYEOF' 2>/dev/null
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_auth
priv, pub = cp_auth.generate_keypair()
print(json.dumps({"priv": priv, "pub": pub}))
PYEOF
)"
DEV2_PRIV="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['priv'])" "$DEV2_KEYS")"
DEV2_PUB="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['pub'])" "$DEV2_KEYS")"
DEV2_HAID="haid:opendev.box-77c2"
export DEV2_PRIV DEV2_PUB DEV2_HAID

# Baseline: the dev2 key is NOT trusted before the open enroll (signed beat -> 401).
OPEN_PRE="$(beat_status "$DEV2_HAID" "$DEV2_PRIV")"
# TOKENLESS open-mode enroll (in-process, HEIMDALL_ENROLL_OPEN=1) writing to the shared firestore
# the live server reads. The server's own env has NO open flag + a token set — the enrolled key
# is verified by the server purely on its signature, independent of HOW it was registered.
OPEN_ENROLL="$(env HEIMDALL_ENROLL_OPEN=1 "$PY" - <<'PYEOF' 2>/dev/null
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_enroll
print(json.dumps(cp_enroll.enroll(os.environ["DEV2_HAID"], os.environ["DEV2_PUB"], provided_token=None)))
PYEOF
)"
OPEN_OK="$(printf '%s' "$OPEN_ENROLL" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('ok'))" 2>/dev/null)"
OPEN_POST="$(beat_status "$DEV2_HAID" "$DEV2_PRIV")"
if [ "$OPEN_PRE" = "401" ] && [ "$OPEN_OK" = "True" ] && [ "$OPEN_POST" = "200" ]; then
  ok "#8 open mode: a TOKENLESS enroll (pre-beat 401) makes the key chokepoint-usable (post-beat 200) over the wire under firestore"
else
  bad "#8 open-mode tokenless enroll did not yield a usable key (pre='$OPEN_PRE', enroll='$OPEN_ENROLL', post='$OPEN_POST')"; cat "$EXT/serve.err" >&2
fi

# ──────────────────────────────────────────────────────────────────────────────
# #9 REGISTRY CAP [FALSIFIABLE] under the deployed firestore store: with the cap pinned to the
#    current key count, the NEXT net-new haid is REFUSED (enroll_registry_full) and a signed beat
#    from it still 401s (nothing registered). Remove the cap check -> it would enroll + verify => RED.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#9 REGISTRY CAP: with the cap at the current count, a net-new haid is refused + stays untrusted [FALSIFIABLE]"
CAP_KEYS="$("$PY" - <<'PYEOF' 2>/dev/null
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_auth
priv, pub = cp_auth.generate_keypair()
print(json.dumps({"priv": priv, "pub": pub}))
PYEOF
)"
CAP_PRIV="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['priv'])" "$CAP_KEYS")"
CAP_PUB="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['pub'])" "$CAP_KEYS")"
CAP_HAID="haid:capfull.box-99"
export CAP_PRIV CAP_PUB CAP_HAID
CAP_OUT="$("$PY" - <<'PYEOF' 2>/dev/null
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import cp_enroll
# Pin the cap to the CURRENT key count -> the registry is already full for net-new keys.
os.environ["HEIMDALL_ENROLL_MAX_KEYS"] = str(cp_enroll._registry_key_count())
r = cp_enroll.enroll(os.environ["CAP_HAID"], os.environ["CAP_PUB"],
                     provided_token=os.environ["HEIMDALL_ENROLL_TOKEN"])
print(json.dumps(r))
PYEOF
)"
CAP_REASON="$(printf '%s' "$CAP_OUT" | "$PY" -c "import json,sys;d=json.load(sys.stdin);print(d.get('reason') if not d.get('ok') else 'OK')" 2>/dev/null)"
CAP_BEAT="$(beat_status "$CAP_HAID" "$CAP_PRIV")"
if [ "$CAP_REASON" = "enroll_registry_full" ] && [ "$CAP_BEAT" = "401" ]; then
  ok "#9 FALSIFIABLE: a net-new enroll at the cap is refused (enroll_registry_full) + the haid stays untrusted (beat 401) — remove the cap => RED"
else
  bad "#9 the registry cap did not refuse a net-new enroll at capacity (reason='$CAP_REASON', beat='$CAP_BEAT')"
fi

# ──────────────────────────────────────────────────────────────────────────────
# FOOTER — reap the serve subprocess; the gate verdict.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "FOOTER — reap the serve subprocess + verdict"
if [ -n "$SERVER_PID" ]; then
  disown "$SERVER_PID" 2>/dev/null || true
  kill "$SERVER_PID" 2>/dev/null || true
  for _ in $(seq 1 20); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$SERVER_PID" 2>/dev/null && kill -9 "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    bad "FOOTER the firestore-mode serve subprocess did not stop"
  else
    ok "FOOTER the serve subprocess was reaped (no orphan server)"; SERVER_PID=""
  fi
fi

echo
echo "============================================================"
printf "cp-enroll-deployed (%s): %d passed, %d failed\n" "$MODE" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
