#!/usr/bin/env bash
# cp-roster-team-deployed.test.sh — THE DEPLOYED-SHAPE TEAM-PRIVATE ROSTER READ: a REAL
# `heimdall-control-plane serve` subprocess on the PUBLIC surface (HEIMDALL_PUBLIC_SURFACE=1)
# under firestore, read by a browser-shaped GET presenting X-Heimdall-Team-Secret over a socket.
#
# WHAT THIS GATES (the static-dashboard path, end to end). cp-roster-team.test.sh proves the
# handler in process; this proves the WIRE the browser hits: a SIGNED beat seeds presence into a
# team, then GET /roster-team?project=<p> with the team_secret in the X-Heimdall-Team-Secret
# HEADER returns the dev (full member view incl. haid) — scoped to the derived team_id. No header
# -> 403; the team_secret is never echoed; the RETIRED /roster-public -> 403. The deployment's
# DEFAULT team secret is pinned so the owner (identity-CLI-registered, no team binding) lands in
# team_id = derive(TEAM_SECRET), the same id the header read derives.
#
#   #1 register an OWNER signing identity (keys written THROUGH the firestore backend).
#   #2 BOOT the REAL serve subprocess on the PUBLIC surface (HEIMDALL_PUBLIC_SURFACE=1) under
#      firestore (HEIMDALL_DEFAULT_TEAM_SECRET pinned -> the owner's default team).
#   #3 a SIGNED beat (POST /presence with the {nonce, ts} the public surface's replay gate
#      requires) seeds the dev — recorded under the verified haid, in the default team partition.
#   #4 GET /roster-team?project=<p> + X-Heimdall-Team-Secret returns the dev (full view incl.
#      haid), 200, CORS set; NO header -> 403. [CARDINAL]
#   #5 NO raw secret in the body (team_secret + a secret-looking field both absent; haid IS
#      present — the member view exposes it by design).
#   #6 a missing project (with the secret header) -> 400.
#   #7 an OPTIONS /roster-team preflight -> 204 + CORS incl. Allow-Headers: X-Heimdall-Team-Secret.
#   #8 a per-IP read flood -> 429 (limit set low via env for determinism).
#   #9 BOUNDARY — an unsigned POST /dispatch (a gated route) -> 404 (the boundary holds), an
#      unsigned POST /roster-team -> 404 (READ-ONLY), and the RETIRED GET /roster-public -> 403.
#
# DISCIPLINE (mirrors cp-presence-deployed / cp-enroll-deployed): isolated throwaway home +
# EXTERNAL store dir; firestore via emulator if available, else the faithful in-process fake;
# the PKI seed lives ONLY in memory; the serve subprocess is REAPED on EXIT; ZERO real GCP.
# Crypto-gated (the seed beat is signed): SKIP cleanly when no cryptography|pynacl.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
CLI="$REPO/bin/heimdall-control-plane"
export LIB REPO

for f in cp_server cp_boot cp_auth cp_presence cp_publicsurface cp_state cp_state_firestore; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done
[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

if ! "$PY" -c "import sys; sys.path.insert(0,'$LIB'); import cp_auth; sys.exit(0 if cp_auth.crypto_available() else 1)"; then
  echo "  SKIP no crypto backend (cryptography|pynacl) — the seed beat is signed."
  printf "cp-roster-public-deployed: %d passed, %d failed (SKIPPED — no crypto)\n" "$PASS" "$FAIL"
  exit 0
fi

EXT="$(mktemp -d -t "cp-rpubdep.$(printf 'X%.0s' 1 2 3 4 5 6)")"
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
export HEIMDALL_FIRESTORE_ROOT="roster_public_deployed_gate"
export HEIMDALL_FIRESTORE_PROJECT="cp-roster-public-deployed-test"

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
  EMU_HOST="localhost:8791"
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
# A low per-IP read cap so the flood (#8) trips 429 deterministically.
export HEIMDALL_ROSTER_IP_LIMIT=5

echo "============================================================"
echo "DEPLOYED-SHAPE ROSTER-TEAM GATE (MODE=$MODE)"
echo "  home=$HEIMDALL_HOME  root=$HEIMDALL_FIRESTORE_ROOT"
echo "============================================================"
echo

PROJECT="acme/widget"
SECRET_LIKE="AKIAIOSFODNN7EXAMPLE"   # fake secret pattern; MUST be scrubbed, never in the read.
# The TEAM SECRET the browser presents in X-Heimdall-Team-Secret. We pin it as the deployment's
# DEFAULT team secret so the owner (registered via the identity CLI, no explicit team binding)
# resolves to team_id = derive(TEAM_SECRET) — the SAME id the header read derives — so a member's
# beat and the browser's secret-header read address ONE partition. (>= 32 chars.)
TEAM_SECRET="team-secret-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
export HEIMDALL_DEFAULT_TEAM_SECRET="$TEAM_SECRET"
export PROJECT SECRET_LIKE TEAM_SECRET

# A tiny status-only HTTP probe (browser-shaped: NO signing headers). Prints "STATUS".
httpstat(){ "$PY" - "$@" <<'PY'
import sys, urllib.request, urllib.error
m, u = sys.argv[1], sys.argv[2]
data = sys.argv[3].encode() if len(sys.argv) > 3 and sys.argv[3] else None
req = urllib.request.Request(u, data=data, method=m)
try:
    print(urllib.request.urlopen(req, timeout=6).status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print(0)
PY
}

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
# #2 BOOT the REAL serve subprocess on the PUBLIC surface under firestore.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#2 boot the REAL serve subprocess on the PUBLIC surface (HEIMDALL_PUBLIC_SURFACE=1)"
CP_PORT="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
HEIMDALL_PUBLIC_SURFACE=1 "$CLI" serve --host 127.0.0.1 --port "$CP_PORT" --home "$HEIMDALL_HOME" --no-revocation \
  >"$EXT/serve.out" 2>"$EXT/serve.err" &
SERVER_PID=$!
CP_URL="http://127.0.0.1:$CP_PORT"
UP=""
for _ in $(seq 1 60); do
  [ "$(httpstat GET "$CP_URL/healthz")" = "200" ] && { UP="1"; break; }
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 0.1
done
if [ -n "$UP" ]; then
  ok "#2 the REAL public-surface server is live on $CP_URL under firestore (pid $SERVER_PID)"
else
  bad "#2 the public-surface server did not come up"; cat "$EXT/serve.err" >&2
fi

# ──────────────────────────────────────────────────────────────────────────────
# #3 a SIGNED beat seeds the dev (POST /presence with the {nonce, ts} the public surface's
#    replay gate requires). Recorded under the verified haid, in the DEFAULT team partition.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#3 a signed beat seeds the dev (POST /presence, with nonce+ts for the public replay gate)"
export CP_PORT CP_HAID="$OWNER_HAID" CP_PRIV="$OWNER_PRIV"
BEAT_STATUS="$("$PY" - <<'PYEOF' 2>"$EXT/beat.err"
import json, os, secrets, sys, time, urllib.request, urllib.error
sys.path.insert(0, os.environ["LIB"])
import cp_auth as K
port = int(os.environ["CP_PORT"]); haid = os.environ["CP_HAID"]; priv = os.environ["CP_PRIV"]
body = json.dumps({
    "project": os.environ["PROJECT"], "handle": "rj", "verdict": "building",
    "file": os.environ["SECRET_LIKE"],   # a secret-looking field — must be scrubbed at write.
    "nonce": secrets.token_hex(16), "ts": time.time(),
}).encode()
req = urllib.request.Request("http://127.0.0.1:%d/presence" % port, data=body, method="POST")
req.add_header("X-Heimdall-HAID", haid)
req.add_header("Content-Type", "application/json")
req.add_header("X-Heimdall-Signature", K.sign(priv, K.canonical_message("POST", "/presence", body)))
try:
    with urllib.request.urlopen(req, timeout=8) as r:
        print(r.status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception as e:  # noqa: BLE001
    print("ERR:%s" % type(e).__name__)
PYEOF
)"
[ "$BEAT_STATUS" = "200" ] \
  && ok "#3 the signed beat was accepted on the public surface (200 — sig+nonce verified)" \
  || { bad "#3 the signed beat was not accepted (got '$BEAT_STATUS')"; cat "$EXT/beat.err" >&2; }

# ──────────────────────────────────────────────────────────────────────────────
# #4 the SECRET-HEADER GET /roster-team returns the dev (full member view incl. haid). The
#    browser presents X-Heimdall-Team-Secret over real HTTP; the server derives team_id and
#    returns ONLY that partition. [CARDINAL]
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#4 GET /roster-team + X-Heimdall-Team-Secret returns the dev (full view incl. haid) + CORS [CARDINAL]"
export CP_URL
R_OUT="$("$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys, urllib.parse, urllib.request, urllib.error
base = os.environ["CP_URL"]; proj = os.environ["PROJECT"]
url = base + "/roster-team?" + urllib.parse.urlencode({"project": proj})
req = urllib.request.Request(url, method="GET")
req.add_header("X-Heimdall-Team-Secret", os.environ["TEAM_SECRET"])
try:
    with urllib.request.urlopen(req, timeout=8) as r:
        print(json.dumps({"status": r.status, "cors": r.headers.get("Access-Control-Allow-Origin"), "body": r.read().decode()}))
except urllib.error.HTTPError as e:
    print(json.dumps({"status": e.code, "cors": None, "body": e.read().decode()}))
except Exception as e:  # noqa: BLE001
    print(json.dumps({"status": "ERR:%s" % type(e).__name__, "cors": None, "body": ""}))
PYEOF
)"
R_STATUS="$(printf '%s' "$R_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['status'])" 2>/dev/null)"
R_CORS="$(printf '%s' "$R_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['cors'])" 2>/dev/null)"
R_HAS_DEV="$(printf '%s' "$R_OUT" | OWNER_HAID="$OWNER_HAID" "$PY" -c "import json,os,sys;o=json.loads(json.load(sys.stdin)['body']);print(any(r.get('haid')==os.environ['OWNER_HAID'] for r in o.get('online',[])))" 2>/dev/null)"
if [ "$R_STATUS" = "200" ] && [ "$R_HAS_DEV" = "True" ]; then
  ok "#4 the secret-header read returns the seeded dev over real HTTP (full member view incl. haid) [CARDINAL]"
else
  bad "#4 the secret-header read did not return the dev (out=$R_OUT)"
fi
[ "$R_CORS" = "*" ] \
  && ok "#4b Access-Control-Allow-Origin:* present on the secret-header GET (browser can read it)" \
  || bad "#4b the CORS header was missing on the GET (got '$R_CORS')"

# #4c NO secret header -> 403 (the capability is required; never an empty 200).
N4="$(httpstat GET "$CP_URL/roster-team?project=$PROJECT")"
[ "$N4" = "403" ] \
  && ok "#4c GET /roster-team with NO secret header -> 403 (outsider sees nothing)" \
  || bad "#4c a no-header team read did not 403 (got '$N4')"

# ──────────────────────────────────────────────────────────────────────────────
# #5 NO raw SECRET leaks into the body (haid IS present — the member view exposes it by design).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#5 NO secret leaks into the body (the team_secret + a secret-looking field are never echoed)"
R_BODY="$(printf '%s' "$R_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['body'])" 2>/dev/null)"
if printf '%s' "$R_BODY" | grep -q "$SECRET_LIKE"; then
  bad "#5a the secret-looking value reached the body (body=$R_BODY)"
else
  ok "#5a the secret-looking field was scrubbed — NO secret in the body"
fi
if printf '%s' "$R_BODY" | grep -qF "$TEAM_SECRET"; then
  bad "#5b the presented team_secret was echoed into the body (body=$R_BODY)"
else
  ok "#5b the team_secret is NEVER echoed in the body (no-secret-by-construction)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# #6 a missing project (WITH the secret header) -> 400.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#6 a missing project (with the secret header) -> 400"
M6="$("$PY" - <<'PYEOF' 2>/dev/null
import os, sys, urllib.request, urllib.error
req = urllib.request.Request(os.environ["CP_URL"] + "/roster-team", method="GET")
req.add_header("X-Heimdall-Team-Secret", os.environ["TEAM_SECRET"])
try:
    print(urllib.request.urlopen(req, timeout=6).status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print(0)
PYEOF
)"
[ "$M6" = "400" ] \
  && ok "#6 GET /roster-team with a secret header but no project -> 400" \
  || bad "#6 a missing project did not 400 (got '$M6')"

# ──────────────────────────────────────────────────────────────────────────────
# #7 an OPTIONS preflight -> 204 + CORS incl. Allow-Headers: X-Heimdall-Team-Secret.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#7 an OPTIONS /roster-team preflight -> 204 + CORS incl. Allow-Headers"
P7="$("$PY" - <<'PYEOF' 2>/dev/null
import os, sys, urllib.request, urllib.error
base = os.environ["CP_URL"]
req = urllib.request.Request(base + "/roster-team", method="OPTIONS")
try:
    with urllib.request.urlopen(req, timeout=6) as r:
        print("%s|%s|%s" % (r.status, r.headers.get("Access-Control-Allow-Origin"), r.headers.get("Access-Control-Allow-Headers")))
except urllib.error.HTTPError as e:
    print("%s|%s|%s" % (e.code, e.headers.get("Access-Control-Allow-Origin"), e.headers.get("Access-Control-Allow-Headers")))
except Exception as e:  # noqa: BLE001
    print("ERR:%s||" % type(e).__name__)
PYEOF
)"
P7_STATUS="${P7%%|*}"; P7_REST="${P7#*|}"; P7_ORIGIN="${P7_REST%%|*}"; P7_AH="${P7_REST#*|}"
if [ "$P7_STATUS" = "204" ] && [ "$P7_ORIGIN" = "*" ] && printf '%s' "$P7_AH" | grep -q "X-Heimdall-Team-Secret"; then
  ok "#7 OPTIONS /roster-team -> 204 + Allow-Origin:* + Allow-Headers carries X-Heimdall-Team-Secret"
else
  bad "#7 the preflight did not return 204+CORS+Allow-Headers (got '$P7')"
fi

# ──────────────────────────────────────────────────────────────────────────────
# #8 a per-IP read flood -> 429 (HEIMDALL_ROSTER_IP_LIMIT=5).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#8 a per-IP read flood -> 429 (limit=5)"
HIT429=0
for i in $(seq 1 20); do
  c="$("$PY" - <<'PYEOF' 2>/dev/null
import os, sys, urllib.parse, urllib.request, urllib.error
url = os.environ["CP_URL"] + "/roster-team?" + urllib.parse.urlencode({"project": os.environ["PROJECT"]})
req = urllib.request.Request(url, method="GET")
req.add_header("X-Heimdall-Team-Secret", os.environ["TEAM_SECRET"])
try:
    print(urllib.request.urlopen(req, timeout=6).status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print(0)
PYEOF
)"
  [ "$c" = "429" ] && { HIT429=1; break; }
done
[ "$HIT429" = "1" ] \
  && ok "#8 the per-IP read flood trips 429 (the roster_read gate is wired over the wire)" \
  || bad "#8 no 429 under 20 rapid reads at limit=5 (rate-limit not wired?)"

# ──────────────────────────────────────────────────────────────────────────────
# #9 BOUNDARY — a gated route 404s; POST /roster-team 404s; the RETIRED /roster-public -> 403.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "#9 boundary: gated route 404 + POST /roster-team 404 (read-only) + /roster-public retired 403"
G9="$(httpstat POST "$CP_URL/dispatch" '{}')"
[ "$G9" = "404" ] \
  && ok "#9a an unsigned POST /dispatch (gated) -> 404 on the public surface (the boundary holds)" \
  || bad "#9a a gated route did not 404 (got '$G9' — the boundary leaked)"
W9="$(httpstat POST "$CP_URL/roster-team" '{"project":"acme/widget","handle":"evil"}')"
[ "$W9" = "404" ] \
  && ok "#9b an unsigned POST /roster-team -> 404 — READ-ONLY, there is no public write seam" \
  || bad "#9b POST /roster-team did not 404 (got '$W9' — a write seam leaked)"
RP9="$(httpstat GET "$CP_URL/roster-public?project=$PROJECT")"
[ "$RP9" = "403" ] \
  && ok "#9c the RETIRED GET /roster-public -> 403 over real HTTP (the old fully-public leak is closed)" \
  || bad "#9c /roster-public did not 403 (got '$RP9' — the old public roster leak is NOT closed)"

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
    bad "FOOTER the serve subprocess did not stop"
  else
    ok "FOOTER the serve subprocess was reaped (no orphan server)"; SERVER_PID=""
  fi
fi

echo
echo "============================================================"
printf "cp-roster-team-deployed (%s): %d passed, %d failed\n" "$MODE" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
