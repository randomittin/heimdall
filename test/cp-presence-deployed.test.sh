#!/usr/bin/env bash
# cp-presence-deployed.test.sh — THE DEPLOYED-SHAPE PRESENCE GATE: the SHIPPED
# bin/heimdall-presence client driving a REAL `heimdall-control-plane serve` subprocess
# under firestore, over real signed HTTP.
#
# WHAT THIS GATES (the prod profile, end to end). cp-presence.test.sh proves the store in
# process; this proves the WIRE: a heartbeat POSTed by the shipped client is signed,
# verified at the §3 chokepoint, recorded under the VERIFIED haid in firestore, and read
# back by a signed GET /roster?project=<p> from a FRESH read — the exact path a deployed
# fleet runs. It is the guard for "presence works locally but 401s / read-path-crashes on
# Cloud Run".
#
#   #1 register an OWNER signing identity (keys written THROUGH the firestore backend).
#   #2 BOOT the REAL `heimdall-control-plane serve` subprocess under firestore.
#   #3 the SHIPPED bin/heimdall-presence `beat` (signed POST /presence) records the dev —
#      proving the client signs correctly + the route stores under the verified haid.
#   #4 the SHIPPED bin/heimdall-presence `roster --json` (signed GET /roster?project=<p>,
#      EMPTY body — the GFE-safe shape) returns the dev: sig VERIFIES (not 401), read
#      crosses a real process + socket under firestore (no BackendUnavailable). [CARDINAL]
#   #5 FALSIFIABLE — the QUERY is signed + tamper-evident: a raw request that SIGNS one
#      ?project= but TRANSMITS another -> 401 (the signature covers the full
#      path-with-query; a swapped query does not verify). Mirrors cp-getjobs-query-param.
#   #6 GRACEFUL DEGRADE — the client with a WRONG seed (401 at the server) prints a CLEAN
#      EMPTY roster + exits 0, never a traceback (the statusline contract).
#
# DISCIPLINE (mirrors cp-getjobs-firestore): isolated throwaway home + EXTERNAL store dir;
# firestore via emulator if available, else the faithful in-process fake; the PKI seed
# lives ONLY in memory (env, never a tracked file, never printed); the serve subprocess is
# REAPED on EXIT; ZERO real GCP / ZERO spend in fake mode. Exit 0 = the wire holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
CLI="$REPO/bin/heimdall-control-plane"
PRES_CLI="$REPO/bin/heimdall-presence"
export LIB REPO

for f in cp_server cp_boot cp_auth cp_presence cp_state cp_state_firestore; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done
[ -x "$CLI" ]      || { echo "FATAL: $CLI not executable" >&2; exit 2; }
[ -x "$PRES_CLI" ] || { echo "FATAL: $PRES_CLI not executable" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# crypto gate: this gate REQUIRES PKI (signed HTTP). Absent crypto -> SKIP cleanly.
if ! "$PY" -c "import sys; sys.path.insert(0,'$LIB'); import cp_auth; sys.exit(0 if cp_auth.crypto_available() else 1)"; then
  echo "  SKIP no crypto backend (cryptography|pynacl) — the signed-HTTP gate needs PKI."
  printf "cp-presence-deployed: %d passed, %d failed (SKIPPED — no crypto)\n" "$PASS" "$FAIL"
  exit 0
fi

EXT="$(mktemp -d -t "cp-presdep.$(printf 'X%.0s' 1 2 3 4 5 6)")"
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
export HEIMDALL_FIRESTORE_ROOT="presence_deployed_gate"
export HEIMDALL_FIRESTORE_PROJECT="cp-presence-deployed-test"

# ── a TEST PKI seed (in memory only — never a tracked file, never printed) ──
SEED_B64="$("$PY" -c "import base64;print(base64.b64encode(bytes((i*11+5)%256 for i in range(32))).decode())")"
export HEIMDALL_CP_PKI_KEY="$SEED_B64"
export HEIMDALL_CP_SERVER_HAID="haid:cp-server"

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
  EMU_HOST="localhost:8783"
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
# PERSISTS to the JSON file named by HEIMDALL_FAKE_FS_STORE so the serve subprocess + the
# signing client share one durable store — the cross-process property a real Firestore has.
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
echo "DEPLOYED-SHAPE PRESENCE GATE (MODE=$MODE)"
echo "  home=$HEIMDALL_HOME  root=$HEIMDALL_FIRESTORE_ROOT"
echo "============================================================"
echo

PROJECT="acme/widget"

# ──────────────────────────────────────────────────────────────────────────────
# #1 register an OWNER signing identity (keys written THROUGH the firestore backend).
# ──────────────────────────────────────────────────────────────────────────────
echo "#1 register a signing OWNER identity under firestore"
OWNER_HAID="haid:rj.owner"
"$CLI" identity --haid "$OWNER_HAID" --owner --home "$HEIMDALL_HOME" \
  >"$EXT/ident.json" 2>"$EXT/ident.err"
IDENT_OK="$("$PY" -c "import json;print(json.load(open('$EXT/ident.json')).get('ok'))" 2>/dev/null)"
[ "$IDENT_OK" = "True" ] \
  && ok "#1 owner identity registered via the REAL CLI auth path under firestore ($OWNER_HAID)" \
  || { bad "#1 CLI identity registration failed under firestore"; cat "$EXT/ident.err" >&2; }
OWNER_PRIV="$("$PY" -c "import json;print(json.load(open('$EXT/ident.json'))['private_key'])" 2>/dev/null)"

# ──────────────────────────────────────────────────────────────────────────────
# #2 BOOT the REAL serve subprocess under firestore (real process + HTTP socket).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#2 boot the REAL serve subprocess under firestore"
CP_PORT="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
"$CLI" serve --host 127.0.0.1 --port "$CP_PORT" --home "$HEIMDALL_HOME" --no-revocation \
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
  ok "#2 the REAL wired server is live on 127.0.0.1:$CP_PORT under firestore (pid $SERVER_PID)"
else
  bad "#2 the firestore-mode wired server did not come up"; cat "$EXT/serve.err" >&2
fi

CP_URL="http://127.0.0.1:$CP_PORT"

# ──────────────────────────────────────────────────────────────────────────────
# #3 the SHIPPED bin/heimdall-presence `beat` (signed POST /presence). The client signs
#    as OWNER_HAID with the seed (HEIMDALL_CP_PKI_KEY) and the route records under the
#    VERIFIED haid in firestore.
# ──────────────────────────────────────────────────────────────────────────────
echo
# The shipped client signs with the OWNER's key via the documented HMD_PRESENCE_SEED override
# (the dev-scoped seed input — the SAME key #5 drives as CP_PRIV). OWNER_HAID is PRE-REGISTERED
# in #1, so the client's auto-bootstrap-enroll would 409 (no rebind of an enrolled identity) and
# yield no seed -> a silent no-op beat; the enroll bootstrap is gated + tested in cp-enroll. This
# gate guards the WIRE (sign -> verify -> store-under-verified-haid -> signed GET /roster read).
echo "#3 the shipped client beats (signed POST /presence) under firestore"
HEIMDALL_CP_URL="$CP_URL" HMD_HAID="$OWNER_HAID" HMD_PRESENCE_SEED="$OWNER_PRIV" \
HMD_HANDLE="rj" HMD_VERDICT="building" HMD_FILE="src/app.py" \
  "$PRES_CLI" beat --project "$PROJECT" >"$EXT/beat.out" 2>"$EXT/beat.err"
BEAT_RC=$?
# A beat is fire-and-forget (always exit 0); the proof is the roster read in #4. Assert it
# at least did not error out / hang.
[ "$BEAT_RC" = "0" ] \
  && ok "#3 the shipped heimdall-presence beat ran clean (signed POST /presence, exit 0)" \
  || { bad "#3 the client beat exited nonzero ($BEAT_RC)"; cat "$EXT/beat.err" >&2; }

# ──────────────────────────────────────────────────────────────────────────────
# #4 the SHIPPED bin/heimdall-presence `roster --json` (signed GET /roster?project=<p>,
#    EMPTY body) returns the dev: the sig VERIFIES (not 401) + the read crosses a real
#    process/socket under firestore. [CARDINAL]
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#4 the shipped client reads the roster (signed GET /roster?project) -> sees the dev [CARDINAL]"
HEIMDALL_CP_URL="$CP_URL" HMD_HAID="$OWNER_HAID" HMD_PRESENCE_SEED="$OWNER_PRIV" \
  "$PRES_CLI" roster --json --project "$PROJECT" >"$EXT/roster.out" 2>"$EXT/roster.err"
ROSTER_HAS_OWNER="$("$PY" - <<PYEOF 2>/dev/null
import json
try:
    rows = json.load(open("$EXT/roster.out"))
except Exception:
    rows = []
print(any(r.get("haid") == "$OWNER_HAID" for r in rows) if isinstance(rows, list) else False)
PYEOF
)"
if [ "$ROSTER_HAS_OWNER" = "True" ]; then
  ok "#4 the roster returns the dev over signed HTTP under firestore — sig verifies (not 401), no BackendUnavailable [CARDINAL]"
else
  bad "#4 the roster did NOT return the dev (heartbeat->roster wire broken)"; cat "$EXT/roster.out" "$EXT/roster.err" >&2
fi

# ──────────────────────────────────────────────────────────────────────────────
# #5 FALSIFIABLE — the QUERY is signed + tamper-evident. A raw request that SIGNS one
#    ?project= but TRANSMITS another must 401 (the signature covers the full
#    path-with-query). This proves the read shape is authenticated, not a bare GET.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#5 FALSIFIABLE: a query-mismatch (sign one project, send another) -> 401"
export CP_PORT CP_HAID="$OWNER_HAID" CP_PRIV="$OWNER_PRIV"
MISMATCH_STATUS="$("$PY" - <<'PYEOF' 2>/dev/null
import os, sys, urllib.request, urllib.error, urllib.parse
sys.path.insert(0, os.environ["LIB"])
import cp_auth as K
port = int(os.environ["CP_PORT"]); haid = os.environ["CP_HAID"]; priv = os.environ["CP_PRIV"]
# SIGN over project=acme/widget but TRANSMIT project=other/repo — the signed bytes cover
# the full path-with-query, so the swapped query must NOT verify (401).
signed_path = "/roster?" + urllib.parse.urlencode({"project": "acme/widget"})
sent_path = "/roster?" + urllib.parse.urlencode({"project": "other/repo"})
req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, sent_path), data=None, method="GET")
req.add_header("X-Heimdall-HAID", haid)
req.add_header("X-Heimdall-Signature", K.sign(priv, K.canonical_message("GET", signed_path, b"")))
try:
    with urllib.request.urlopen(req, timeout=8) as r:
        print(r.status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception as e:  # noqa: BLE001
    print("ERR:%s" % type(e).__name__)
PYEOF
)"
[ "$MISMATCH_STATUS" = "401" ] \
  && ok "#5 FALSIFIABLE: a signed-vs-sent query mismatch is 401 — the ?project= is signed + tamper-evident" \
  || bad "#5 a query mismatch did NOT 401 (got '$MISMATCH_STATUS') — the query is not covered by the signature"

# ──────────────────────────────────────────────────────────────────────────────
# #6 GRACEFUL DEGRADE — the client with a WRONG seed (server 401s) prints a CLEAN EMPTY
#    roster + exits 0, never a traceback (the statusline contract).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#6 graceful degrade: a 401'd client prints an empty roster + exits 0 (no traceback)"
BAD_SEED="$("$PY" -c "import base64;print(base64.b64encode(bytes((i*3+1)%256 for i in range(32))).decode())")"
HEIMDALL_CP_URL="$CP_URL" HMD_HAID="$OWNER_HAID" HMD_PRESENCE_SEED="$BAD_SEED" \
  "$PRES_CLI" roster --json --project "$PROJECT" >"$EXT/degrade.out" 2>"$EXT/degrade.err"
DEGRADE_RC=$?
DEGRADE_BODY="$(tr -d '[:space:]' <"$EXT/degrade.out")"
if [ "$DEGRADE_RC" = "0" ] && [ "$DEGRADE_BODY" = "[]" ] && [ ! -s "$EXT/degrade.err" ]; then
  ok "#6 a wrong-seed (401) client degrades to an empty roster + exit 0, no traceback"
else
  bad "#6 the client did not degrade cleanly (rc=$DEGRADE_RC body='$DEGRADE_BODY')"; cat "$EXT/degrade.err" >&2
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
printf "cp-presence-deployed (%s): %d passed, %d failed\n" "$MODE" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
