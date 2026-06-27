#!/usr/bin/env bash
# cp-roster-public.test.sh — THE UNAUTHENTICATED, RATE-LIMITED, READ-ONLY ROSTER read
# (GET /roster-public?project=<id>) under the FIRESTORE backend (the deploy profile).
#
# WHY THIS EXISTS. The static web dashboard (heimdall-site) shows a team's ONLINE members
# from a BROWSER. A browser cannot PKI-sign, so the signed GET /roster 401s it. This gate
# proves the PUBLIC read seam cp_presence adds:
#   • served PRE-AUTH (no signature) but ONLY when public_surface_enabled() — off the public
#     surface it 404s like a nonexistent route (the gated service is unchanged);
#   • returns the SAME TTL-filtered online roster cp_presence.roster() computes, projected to
#     handle/verdict/file/age_seconds ONLY — NEVER the haid, a pubkey, or any secret;
#   • per-IP rate-limited (scope "roster_read") — a scrape flood trips 429;
#   • CORS-enabled (Access-Control-Allow-Origin:*) + an OPTIONS preflight (204 + CORS) so a
#     different-origin static site can fetch it;
#   • project required (missing -> 400); an unknown project is an honest empty 200, not an error;
#   • READ-ONLY — there is no (POST, /roster-public) in the public allowlist (no write seam).
#
#   A. ONLINE READ — a seeded online dev appears in the unsigned read (handle/verdict/file/
#      age_seconds), with NO haid/secret in the body, and the CORS header set.
#   B. MISSING PROJECT -> 400.
#   C. UNKNOWN PROJECT -> 200 with an empty online list (not an error).
#   D. RATE-LIMIT — a per-IP flood trips 429 (limit set low via env for determinism).
#   E. PREFLIGHT — OPTIONS /roster-public -> 204 + the CORS headers.
#   F. BOUNDARY — public_surface OFF: the read 404s; the allowlist permits GET (not POST)
#      /roster-public, still permits the signed GET /roster, and never permits a gated route.
#   G. FALSIFIABLE — a TTL-expired (stale) dev is ABSENT from the unsigned read (the window,
#      not the data, decides — same as the signed roster).
#
# DISCIPLINE (mirrors cp-presence.test.sh): isolated throwaway home + EXTERNAL store dir;
# firestore via the emulator when available, else the faithful in-process fake; ZERO real GCP.
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

for f in cp_presence cp_publicsurface cp_server cp_ratelimit cp_state cp_state_firestore; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

EXT="$(mktemp -d -t "cp-roster-pub.$(printf 'X%.0s' 1 2 3 4 5 6)")"
HOME_T="$EXT/home"
mkdir -p "$HOME_T"
EMU_PID=""
cleanup() { [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1 || true; rm -rf "$EXT"; }
trap cleanup EXIT

export HEIMDALL_HOME="$HOME_T"
export HEIMDALL_FIRESTORE_ROOT="roster_public_gate"
export HEIMDALL_FIRESTORE_PROJECT="cp-roster-public-test"

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
  EMU_HOST="localhost:8787"
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
# PERSISTS the whole store to the JSON file named by HEIMDALL_FAKE_FS_STORE so SEPARATE
# processes share one durable store — the cross-process property a real Firestore has.
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
echo "ROSTER-PUBLIC (unauthenticated read) under FIRESTORE (MODE=$MODE)"
echo "  home=$HEIMDALL_HOME  root=$HEIMDALL_FIRESTORE_ROOT"
echo "============================================================"
echo

PROJECT="acme/widget"
DEV_A="haid:rj.mbp-7f3a"
# A fake secret-looking handle: telemetry._scrub MUST drop it at write time, so it can never
# surface in the unauthenticated read (no-secret-by-construction).
SECRET_LIKE="AKIAIOSFODNN7EXAMPLE"

# ──────────────────────────────────────────────────────────────────────────────
# A. ONLINE READ — a seeded online dev appears in the UNSIGNED read; no haid/secret; CORS set.
# ──────────────────────────────────────────────────────────────────────────────
echo "A. an online dev appears in the unsigned roster-public read (no haid/secret; CORS set)"
A_OUT="$(PRES_PROJECT="$PROJECT" PRES_HAID="$DEV_A" SECRET_LIKE="$SECRET_LIKE" \
  HEIMDALL_PUBLIC_SURFACE=1 "$PY" - <<'PYEOF' 2>"$EXT/a.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
proj = os.environ["PRES_PROJECT"]
# seed an online dev; the file field carries a secret-looking token to prove it is scrubbed.
P.record_presence(os.environ["PRES_HAID"], project=proj, handle="rj",
                  verdict="building", file=os.environ["SECRET_LIKE"])
req = {"method": "GET", "route_path": "/roster-public",
       "query": {"project": proj}, "peer_ip": "10.0.0.1"}
resp = P.roster_public_route(req)
print(json.dumps({
    "status": resp.status,
    "body": resp.body,
    "cors": resp.headers.get("Access-Control-Allow-Origin"),
    "body_text": json.dumps(resp.body),
}))
PYEOF
)"
A_STATUS="$(printf '%s' "$A_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['status'])" 2>/dev/null)"
A_CORS="$(printf '%s' "$A_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['cors'])" 2>/dev/null)"
A_HAS_DEV="$(printf '%s' "$A_OUT" | "$PY" -c "import json,sys;b=json.load(sys.stdin)['body'];print(any(r.get('handle')=='rj' for r in b.get('online',[])))" 2>/dev/null)"
A_KEYS_OK="$(printf '%s' "$A_OUT" | "$PY" -c "import json,sys;b=json.load(sys.stdin)['body'];print(all(set(r.keys())=={'handle','verdict','file','age_seconds'} for r in b.get('online',[])))" 2>/dev/null)"
A_NO_HAID="$(printf '%s' "$A_OUT" | "$PY" -c "import json,sys;t=json.load(sys.stdin)['body_text'];print('haid' not in t)" 2>/dev/null)"
A_NO_SECRET="$(printf '%s' "$A_OUT" | SECRET_LIKE="$SECRET_LIKE" "$PY" -c "import json,os,sys;t=json.load(sys.stdin)['body_text'];print(os.environ['SECRET_LIKE'] not in t)" 2>/dev/null)"
if [ "$A_STATUS" = "200" ] && [ "$A_HAS_DEV" = "True" ]; then
  ok "A1 the seeded online dev appears in the unsigned read (status 200)"
else
  bad "A1 the online dev was missing from the unsigned read (out=$A_OUT)"; cat "$EXT/a.err" >&2
fi
[ "$A_KEYS_OK" = "True" ] \
  && ok "A2 each online entry exposes ONLY {handle,verdict,file,age_seconds} (no haid/pubkey/ts)" \
  || bad "A2 an online entry exposed extra keys (out=$A_OUT)"
[ "$A_NO_HAID" = "True" ] \
  && ok "A3 the response body carries NO 'haid' field (identity is never exposed)" \
  || bad "A3 the body leaked a haid (out=$A_OUT)"
[ "$A_NO_SECRET" = "True" ] \
  && ok "A4 the secret-looking field was scrubbed — NO secret in the body" \
  || bad "A4 a secret-looking value reached the body (out=$A_OUT)"
[ "$A_CORS" = "*" ] \
  && ok "A5 Access-Control-Allow-Origin:* is set (browser cross-origin fetch allowed)" \
  || bad "A5 the CORS allow-origin header was missing (got '$A_CORS')"

# ──────────────────────────────────────────────────────────────────────────────
# B. MISSING PROJECT -> 400.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "B. a missing project -> 400"
B_STATUS="$(HEIMDALL_PUBLIC_SURFACE=1 "$PY" - <<'PYEOF' 2>/dev/null
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
resp = P.roster_public_route({"method": "GET", "route_path": "/roster-public",
                              "query": {}, "peer_ip": "10.0.0.2"})
print(resp.status)
PYEOF
)"
[ "$B_STATUS" = "400" ] \
  && ok "B1 a missing project -> 400 (the read needs a project to scope)" \
  || bad "B1 a missing project did not 400 (got '$B_STATUS')"

# ──────────────────────────────────────────────────────────────────────────────
# C. UNKNOWN PROJECT -> 200 with an empty online list (honest empty, not an error).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "C. an unknown project -> 200 with an empty online list"
C_OUT="$(HEIMDALL_PUBLIC_SURFACE=1 "$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
resp = P.roster_public_route({"method": "GET", "route_path": "/roster-public",
                              "query": {"project": "no/such-project-xyz"}, "peer_ip": "10.0.0.3"})
print(json.dumps({"status": resp.status, "online": resp.body.get("online")}))
PYEOF
)"
C_STATUS="$(printf '%s' "$C_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['status'])" 2>/dev/null)"
C_EMPTY="$(printf '%s' "$C_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['online']==[])" 2>/dev/null)"
if [ "$C_STATUS" = "200" ] && [ "$C_EMPTY" = "True" ]; then
  ok "C1 an unknown project -> 200 + empty online list (not an error)"
else
  bad "C1 an unknown project did not yield 200+[] (out=$C_OUT)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# D. RATE-LIMIT — a per-IP flood trips 429 (limit set low via env for determinism).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "D. a per-IP read flood trips 429 (HEIMDALL_ROSTER_IP_LIMIT=3)"
D_OUT="$(PRES_PROJECT="$PROJECT" HEIMDALL_PUBLIC_SURFACE=1 HEIMDALL_ROSTER_IP_LIMIT=3 "$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
proj = os.environ["PRES_PROJECT"]
codes = []
for _ in range(8):
    resp = P.roster_public_route({"method": "GET", "route_path": "/roster-public",
                                  "query": {"project": proj}, "peer_ip": "203.0.113.9"})
    codes.append(resp.status)
print(json.dumps(codes))
PYEOF
)"
D_HAS_429="$(printf '%s' "$D_OUT" | "$PY" -c "import json,sys;print(429 in json.load(sys.stdin))" 2>/dev/null)"
D_HAS_200="$(printf '%s' "$D_OUT" | "$PY" -c "import json,sys;print(200 in json.load(sys.stdin))" 2>/dev/null)"
if [ "$D_HAS_429" = "True" ] && [ "$D_HAS_200" = "True" ]; then
  ok "D1 the first reads pass (200) then the per-IP flood trips 429 (codes=$D_OUT)"
else
  bad "D1 the rate-limit did not trip 429 under flood (codes=$D_OUT)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# E. PREFLIGHT — OPTIONS /roster-public -> 204 + the CORS headers.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "E. an OPTIONS preflight -> 204 + CORS headers"
E_OUT="$(HEIMDALL_PUBLIC_SURFACE=1 "$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
resp = P.roster_public_preflight({"method": "OPTIONS", "route_path": "/roster-public"})
print(json.dumps({
    "status": resp.status,
    "origin": resp.headers.get("Access-Control-Allow-Origin"),
    "methods": resp.headers.get("Access-Control-Allow-Methods"),
}))
PYEOF
)"
E_STATUS="$(printf '%s' "$E_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['status'])" 2>/dev/null)"
E_ORIGIN="$(printf '%s' "$E_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['origin'])" 2>/dev/null)"
E_METHODS="$(printf '%s' "$E_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['methods'])" 2>/dev/null)"
if [ "$E_STATUS" = "204" ] && [ "$E_ORIGIN" = "*" ] && printf '%s' "$E_METHODS" | grep -q "GET"; then
  ok "E1 OPTIONS /roster-public -> 204 + Access-Control-Allow-Origin:* + Allow-Methods carries GET"
else
  bad "E1 the preflight did not return 204+CORS (out=$E_OUT)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# F. BOUNDARY — public_surface OFF: the read 404s; the allowlist permits GET (not POST)
#    /roster-public, still permits the signed GET /roster, and never permits a gated route.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "F. boundary: off-surface 404 + the allowlist shape (read-only, no write seam)"
F_OFF="$(env -u HEIMDALL_PUBLIC_SURFACE "$PY" - <<'PYEOF' 2>/dev/null
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
# With the public surface OFF the unauthenticated read does not exist -> 404.
resp = P.roster_public_route({"method": "GET", "route_path": "/roster-public",
                              "query": {"project": "acme/widget"}, "peer_ip": "10.0.0.4"})
print(resp.status)
PYEOF
)"
[ "$F_OFF" = "404" ] \
  && ok "F1 with the public surface OFF the read 404s (gated service unchanged)" \
  || bad "F1 the off-surface read did not 404 (got '$F_OFF')"

F_ALLOW="$("$PY" - <<'PYEOF' 2>/dev/null
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_publicsurface as PS
print(",".join([
    "get=%s" % PS.is_public_route("GET", "/roster-public"),
    "opt=%s" % PS.is_public_route("OPTIONS", "/roster-public"),
    "post=%s" % PS.is_public_route("POST", "/roster-public"),
    "roster=%s" % PS.is_public_route("GET", "/roster"),
    "dispatch=%s" % PS.is_public_route("POST", "/dispatch"),
]))
PYEOF
)"
echo "    allowlist: $F_ALLOW"
printf '%s' "$F_ALLOW" | grep -q "get=True" \
  && ok "F2 the allowlist permits GET /roster-public (the browser read)" \
  || bad "F2 GET /roster-public is NOT in the public allowlist (the boundary would 404 it)"
printf '%s' "$F_ALLOW" | grep -q "opt=True" \
  && ok "F3 the allowlist permits OPTIONS /roster-public (the CORS preflight)" \
  || bad "F3 OPTIONS /roster-public is NOT in the public allowlist"
printf '%s' "$F_ALLOW" | grep -q "post=False" \
  && ok "F4 the allowlist does NOT permit POST /roster-public — READ-ONLY, no write seam" \
  || bad "F4 POST /roster-public is in the allowlist (a write seam leaked)"
printf '%s' "$F_ALLOW" | grep -q "roster=True" \
  && ok "F5 the signed GET /roster is still allowed (the existing read is untouched)" \
  || bad "F5 the signed GET /roster fell out of the allowlist (regression)"
printf '%s' "$F_ALLOW" | grep -q "dispatch=False" \
  && ok "F6 a gated route (POST /dispatch) is still NOT public (the boundary holds)" \
  || bad "F6 a gated route leaked into the public allowlist"

# ──────────────────────────────────────────────────────────────────────────────
# G. FALSIFIABLE — a TTL-expired (stale) dev is ABSENT from the unsigned read.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "G. FALSIFIABLE: a TTL-expired (stale) dev is ABSENT from the unsigned read"
G_OUT="$(HEIMDALL_PUBLIC_SURFACE=1 HEIMDALL_PRESENCE_TTL_SECONDS=45 "$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
proj = "stale/proj"
# seed a dev with a heartbeat far in the past; the default-now read is WAY past the 45s TTL.
P.record_presence("haid:ghost.box", project=proj, handle="ghost", verdict="idle", file="-", ts=1000.0)
resp = P.roster_public_route({"method": "GET", "route_path": "/roster-public",
                              "query": {"project": proj}, "peer_ip": "10.0.0.5"})
handles = [r.get("handle") for r in resp.body.get("online", [])]
print(json.dumps({"status": resp.status, "handles": handles}))
PYEOF
)"
G_ABSENT="$(printf '%s' "$G_OUT" | "$PY" -c "import json,sys;print('ghost' not in json.load(sys.stdin)['handles'])" 2>/dev/null)"
[ "$G_ABSENT" = "True" ] \
  && ok "G1 FALSIFIABLE: a stale (TTL-expired) dev is DROPPED from the unsigned read (the window decides)" \
  || bad "G1 a stale dev stayed in the unsigned read (TTL not applied — out=$G_OUT)"

echo
echo "============================================================"
printf "cp-roster-public (%s): %d passed, %d failed\n" "$MODE" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
