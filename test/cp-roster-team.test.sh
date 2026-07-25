#!/usr/bin/env bash
# cp-roster-team.test.sh — THE TEAM-PRIVATE, SECRET-HEADER-GATED, READ-ONLY ROSTER read
# (GET /roster-team?project=<id> + X-Heimdall-Team-Secret) under the FIRESTORE backend.
#
# WHY THIS EXISTS. The static web dashboard (heimdall-site) shows a team's ONLINE members from
# a BROWSER. A browser cannot PKI-sign, so the signed GET /roster 401s it. Under the multi-tenant
# model the team roster exposes haid + activity, which MUST NOT be public — so the old fully-
# public GET /roster-public is RETIRED (now 403) and REPLACED by /roster-team, whose app-layer
# auth is the team_secret presented in the X-Heimdall-Team-Secret HEADER (hashed -> team_id
# server-side; never the URL query — Risk 2). This gate proves that read seam:
#   • served PRE-AUTH (no signature) but ONLY when public_surface_enabled() — off the public
#     surface it 404s like a nonexistent route (the gated service is unchanged);
#   • NO secret header -> 403 (the read demands the capability; NOT an empty 200);
#   • WITH the secret header -> the FULL member view incl. haid (members see each other), scoped
#     to exactly the derived team_id partition (cp_presence.roster(project, team_id));
#   • team_id presented AS the secret (the hash, not the pre-image) -> a WRONG partition -> empty
#     (team_id is INERT, never a capability — Risk 3);
#   • a random/unknown secret -> {online: []} (no existence oracle — idle == nonexistent);
#   • per-IP rate-limited (scope "roster_read") — a scrape flood trips 429;
#   • CORS-enabled (Access-Control-Allow-Origin:*) + an OPTIONS preflight (204 + CORS incl.
#     Access-Control-Allow-Headers: X-Heimdall-Team-Secret) so a different-origin site can fetch;
#   • project required (missing -> 400);
#   • the RETIRED GET /roster-public -> 403 on the public surface (the old leak is closed
#     explicitly, not a flat 404);
#   • READ-ONLY — there is no (POST, /roster-team) in the public allowlist (no write seam).
#
#   A. SECRET-HEADER READ — a seeded online dev appears WITH the secret header (full view incl.
#      haid), with NO secret value in the body, and the CORS header set.
#   B. NO HEADER -> 403 (the capability is required; never an empty 200).
#   C. team_id-AS-SECRET -> empty + a random secret -> empty (team_id inert; no existence oracle).
#   D. RATE-LIMIT — a per-IP flood trips 429 (limit set low via env for determinism).
#   E. PREFLIGHT — OPTIONS /roster-team -> 204 + CORS incl. Allow-Headers: X-Heimdall-Team-Secret.
#   F. BOUNDARY — public_surface OFF: the read 404s; the allowlist permits GET (not POST)
#      /roster-team, still permits the signed GET /roster, retires /roster-public, never a gated
#      route. RETIRED GET /roster-public -> 403 on the public surface.
#   G. FALSIFIABLE — a TTL-expired (stale) dev is ABSENT from the secret-header read (the window,
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

for f in cp_presence cp_publicsurface cp_server cp_ratelimit cp_auth cp_state cp_state_firestore; do
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
# A low per-IP read cap so the flood (D) trips 429 deterministically.
export HEIMDALL_ROSTER_IP_LIMIT=3

echo "============================================================"
echo "ROSTER-TEAM (secret-header team-private read) under FIRESTORE (MODE=$MODE)"
echo "  home=$HEIMDALL_HOME  root=$HEIMDALL_FIRESTORE_ROOT"
echo "============================================================"
echo

PROJECT="acme/widget"
DEV_A="haid:rj.mbp-7f3a"
# A high-entropy team secret (>= 32 chars). team_id = derive_team_id(secret) is the partition
# handle; the read DERIVES it from the presented secret, so we seed presence under the SAME id.
TEAM_SECRET="team-secret-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
export TEAM_SECRET PROJECT DEV_A
TEAM_ID="$(TEAM_SECRET="$TEAM_SECRET" "$PY" -c "import os,sys;sys.path.insert(0,os.environ['LIB']);import cp_auth;print(cp_auth.derive_team_id(os.environ['TEAM_SECRET']))")"
export TEAM_ID
# A fake secret-looking file value: telemetry._scrub MUST drop it at write so it never surfaces.
SECRET_LIKE="AKIAIOSFODNN7EXAMPLE"
export SECRET_LIKE

# ──────────────────────────────────────────────────────────────────────────────
# A. SECRET-HEADER READ — a seeded online dev appears WITH the X-Heimdall-Team-Secret header
#    (full member view incl. haid); NO secret in the body; CORS set.
# ──────────────────────────────────────────────────────────────────────────────
echo "A. the secret-header read returns the team's online dev (full view incl. haid; no secret leak)"
A_OUT="$(HEIMDALL_PUBLIC_SURFACE=1 "$PY" - <<'PYEOF' 2>"$EXT/a.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
proj = os.environ["PROJECT"]; tid = os.environ["TEAM_ID"]
# seed an online dev INTO the team partition; the file field carries a secret-looking token.
P.record_presence(os.environ["DEV_A"], project=proj, team_id=tid, handle="rj",
                  verdict="building", file=os.environ["SECRET_LIKE"])
req = {"method": "GET", "route_path": "/roster-team", "query": {"project": proj},
       "team_secret": os.environ["TEAM_SECRET"], "peer_ip": "10.0.0.1"}
resp = P.roster_team_route(req)
print(json.dumps({
    "status": resp.status, "body": resp.body,
    "cors": resp.headers.get("Access-Control-Allow-Origin"),
    "body_text": json.dumps(resp.body),
}))
PYEOF
)"
A_STATUS="$(printf '%s' "$A_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['status'])" 2>/dev/null)"
A_CORS="$(printf '%s' "$A_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['cors'])" 2>/dev/null)"
A_HAS_DEV="$(printf '%s' "$A_OUT" | "$PY" -c "import json,os,sys;b=json.load(sys.stdin)['body'];print(any(r.get('haid')==os.environ['DEV_A'] for r in b.get('online',[])))" 2>/dev/null)"
A_HAS_HAID="$(printf '%s' "$A_OUT" | "$PY" -c "import json,sys;b=json.load(sys.stdin)['body'];print(all('haid' in r for r in b.get('online',[])) and bool(b.get('online')))" 2>/dev/null)"
A_KEYS_OK="$(printf '%s' "$A_OUT" | "$PY" -c "import json,sys;b=json.load(sys.stdin)['body'];print(all(set(r.keys())=={'haid','handle','verdict','file','age_seconds','state'} for r in b.get('online',[])))" 2>/dev/null)"
A_NO_SECRETLIKE="$(printf '%s' "$A_OUT" | SECRET_LIKE="$SECRET_LIKE" "$PY" -c "import json,os,sys;t=json.load(sys.stdin)['body_text'];print(os.environ['SECRET_LIKE'] not in t)" 2>/dev/null)"
A_NO_TEAMSECRET="$(printf '%s' "$A_OUT" | TEAM_SECRET="$TEAM_SECRET" "$PY" -c "import json,os,sys;t=json.load(sys.stdin)['body_text'];print(os.environ['TEAM_SECRET'] not in t)" 2>/dev/null)"
if [ "$A_STATUS" = "200" ] && [ "$A_HAS_DEV" = "True" ]; then
  ok "A1 the seeded online dev appears in the secret-header read (status 200)"
else
  bad "A1 the dev was missing from the secret-header read (out=$A_OUT)"; cat "$EXT/a.err" >&2
fi
[ "$A_HAS_HAID" = "True" ] \
  && ok "A2 the MEMBER view INCLUDES haid (members see each other's identity — the deliberate difference)" \
  || bad "A2 the member view did not include haid (out=$A_OUT)"
[ "$A_KEYS_OK" = "True" ] \
  && ok "A3 each entry is exactly {haid,handle,verdict,file,age_seconds,state} (derived wall-state; no pubkey/ts/secret)" \
  || bad "A3 an entry exposed unexpected keys (out=$A_OUT)"
[ "$A_NO_SECRETLIKE" = "True" ] \
  && ok "A4 the secret-looking file value was scrubbed — NOT in the body" \
  || bad "A4 a secret-looking value reached the body (out=$A_OUT)"
[ "$A_NO_TEAMSECRET" = "True" ] \
  && ok "A5 the presented team_secret is NEVER echoed in the body (no-secret-by-construction)" \
  || bad "A5 the team_secret leaked into the body (out=$A_OUT)"
[ "$A_CORS" = "*" ] \
  && ok "A6 Access-Control-Allow-Origin:* is set (browser cross-origin fetch allowed)" \
  || bad "A6 the CORS allow-origin header was missing (got '$A_CORS')"

# ──────────────────────────────────────────────────────────────────────────────
# B. NO HEADER -> 403 (the read demands the capability; NEVER an empty 200).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "B. no secret header -> 403 (capability required, not an empty 200)"
B_OUT="$(HEIMDALL_PUBLIC_SURFACE=1 "$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
resp = P.roster_team_route({"method": "GET", "route_path": "/roster-team",
                            "query": {"project": os.environ["PROJECT"]}, "peer_ip": "10.0.0.2"})
print(json.dumps({"status": resp.status, "online": resp.body.get("online")}))
PYEOF
)"
B_STATUS="$(printf '%s' "$B_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['status'])" 2>/dev/null)"
[ "$B_STATUS" = "403" ] \
  && ok "B1 a read with NO X-Heimdall-Team-Secret header -> 403 (outsider sees nothing)" \
  || bad "B1 a no-header read did not 403 (out=$B_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# C. team_id-AS-SECRET -> empty + a random secret -> empty (team_id INERT; no existence oracle).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "C. team_id presented as the secret -> empty (inert); a random secret -> empty (no oracle)"
C_OUT="$(HEIMDALL_PUBLIC_SURFACE=1 "$PY" - <<'PYEOF' 2>/dev/null
import json, os, secrets, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
proj = os.environ["PROJECT"]
# (1) present the team_id (the HASH) AS the secret -> derive(team_id) != team_id -> wrong dir.
r_hash = P.roster_team_route({"method": "GET", "route_path": "/roster-team",
        "query": {"project": proj}, "team_secret": os.environ["TEAM_ID"], "peer_ip": "10.0.0.3"})
# (2) a random unknown secret -> a partition with no records.
r_rand = P.roster_team_route({"method": "GET", "route_path": "/roster-team",
        "query": {"project": proj}, "team_secret": secrets.token_urlsafe(32), "peer_ip": "10.0.0.3"})
print(json.dumps({"hash_status": r_hash.status, "hash_online": r_hash.body.get("online"),
                  "rand_status": r_rand.status, "rand_online": r_rand.body.get("online")}))
PYEOF
)"
C_HASH_EMPTY="$(printf '%s' "$C_OUT" | "$PY" -c "import json,sys;d=json.load(sys.stdin);print(d['hash_status']==200 and d['hash_online']==[])" 2>/dev/null)"
C_RAND_EMPTY="$(printf '%s' "$C_OUT" | "$PY" -c "import json,sys;d=json.load(sys.stdin);print(d['rand_status']==200 and d['rand_online']==[])" 2>/dev/null)"
[ "$C_HASH_EMPTY" = "True" ] \
  && ok "C1 presenting team_id AS the secret -> a WRONG partition -> empty (team_id is INERT, not a capability)" \
  || bad "C1 team_id-as-secret did not yield empty (out=$C_OUT)"
[ "$C_RAND_EMPTY" = "True" ] \
  && ok "C2 a random/unknown secret -> {online:[]} (no existence oracle: idle == nonexistent)" \
  || bad "C2 a random secret did not yield empty (out=$C_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# D. RATE-LIMIT — a per-IP flood trips 429 (HEIMDALL_ROSTER_IP_LIMIT=3).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "D. a per-IP read flood trips 429 (HEIMDALL_ROSTER_IP_LIMIT=3)"
D_OUT="$(HEIMDALL_PUBLIC_SURFACE=1 "$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
proj = os.environ["PROJECT"]; sec = os.environ["TEAM_SECRET"]
codes = []
for _ in range(8):
    resp = P.roster_team_route({"method": "GET", "route_path": "/roster-team",
            "query": {"project": proj}, "team_secret": sec, "peer_ip": "203.0.113.9"})
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
# E. PREFLIGHT — OPTIONS /roster-team -> 204 + CORS incl. Allow-Headers: X-Heimdall-Team-Secret.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "E. an OPTIONS preflight -> 204 + CORS incl. Allow-Headers: X-Heimdall-Team-Secret"
E_OUT="$(HEIMDALL_PUBLIC_SURFACE=1 "$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
resp = P.roster_team_preflight({"method": "OPTIONS", "route_path": "/roster-team"})
print(json.dumps({
    "status": resp.status,
    "origin": resp.headers.get("Access-Control-Allow-Origin"),
    "allow_headers": resp.headers.get("Access-Control-Allow-Headers"),
}))
PYEOF
)"
E_STATUS="$(printf '%s' "$E_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['status'])" 2>/dev/null)"
E_ORIGIN="$(printf '%s' "$E_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['origin'])" 2>/dev/null)"
E_AH="$(printf '%s' "$E_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['allow_headers'])" 2>/dev/null)"
if [ "$E_STATUS" = "204" ] && [ "$E_ORIGIN" = "*" ] && printf '%s' "$E_AH" | grep -q "X-Heimdall-Team-Secret"; then
  ok "E1 OPTIONS /roster-team -> 204 + Allow-Origin:* + Allow-Headers carries X-Heimdall-Team-Secret"
else
  bad "E1 the preflight did not return 204+CORS+Allow-Headers (out=$E_OUT)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# F. BOUNDARY — off-surface 404; the allowlist shape; the RETIRED /roster-public -> 403.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "F. boundary: off-surface 404 + allowlist shape + /roster-public retired (403)"
F_OFF="$(env -u HEIMDALL_PUBLIC_SURFACE "$PY" - <<'PYEOF' 2>/dev/null
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
resp = P.roster_team_route({"method": "GET", "route_path": "/roster-team",
        "query": {"project": os.environ["PROJECT"]},
        "team_secret": os.environ["TEAM_SECRET"], "peer_ip": "10.0.0.4"})
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
    "team_get=%s" % PS.is_public_route("GET", "/roster-team"),
    "team_opt=%s" % PS.is_public_route("OPTIONS", "/roster-team"),
    "team_post=%s" % PS.is_public_route("POST", "/roster-team"),
    "roster=%s" % PS.is_public_route("GET", "/roster"),
    "pub=%s" % PS.is_public_route("GET", "/roster-public"),
    "dispatch=%s" % PS.is_public_route("POST", "/dispatch"),
]))
PYEOF
)"
echo "    allowlist: $F_ALLOW"
printf '%s' "$F_ALLOW" | grep -q "team_get=True" \
  && ok "F2 the allowlist permits GET /roster-team (the browser team read)" \
  || bad "F2 GET /roster-team is NOT in the public allowlist"
printf '%s' "$F_ALLOW" | grep -q "team_opt=True" \
  && ok "F3 the allowlist permits OPTIONS /roster-team (the CORS preflight)" \
  || bad "F3 OPTIONS /roster-team is NOT in the public allowlist"
printf '%s' "$F_ALLOW" | grep -q "team_post=False" \
  && ok "F4 the allowlist does NOT permit POST /roster-team — READ-ONLY, no write seam" \
  || bad "F4 POST /roster-team is in the allowlist (a write seam leaked)"
printf '%s' "$F_ALLOW" | grep -q "roster=True" \
  && ok "F5 the signed GET /roster is still allowed (the existing read is untouched)" \
  || bad "F5 the signed GET /roster fell out of the allowlist (regression)"
printf '%s' "$F_ALLOW" | grep -q "dispatch=False" \
  && ok "F6 a gated route (POST /dispatch) is still NOT public (the boundary holds)" \
  || bad "F6 a gated route leaked into the public allowlist"

F_PUB="$(HEIMDALL_PUBLIC_SURFACE=1 "$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
resp = P.roster_public_route({"method": "GET", "route_path": "/roster-public",
        "query": {"project": os.environ["PROJECT"]}, "peer_ip": "10.0.0.6"})
print(json.dumps({"status": resp.status, "online": resp.body.get("online")}))
PYEOF
)"
F_PUB_403="$(printf '%s' "$F_PUB" | "$PY" -c "import json,sys;d=json.load(sys.stdin);print(d['status']==403 and d.get('online')==[])" 2>/dev/null)"
[ "$F_PUB_403" = "True" ] \
  && ok "F7 the RETIRED GET /roster-public -> 403 on the public surface (the old leak is closed, never a roster)" \
  || bad "F7 /roster-public did not 403 (out=$F_PUB — the old public leak is NOT closed)"

# ──────────────────────────────────────────────────────────────────────────────
# G. FALSIFIABLE — a TTL-expired (stale) dev is ABSENT from the secret-header read.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "G. FALSIFIABLE: a TTL-expired (stale) dev is ABSENT from the secret-header read"
G_OUT="$(HEIMDALL_PUBLIC_SURFACE=1 HEIMDALL_PRESENCE_TTL_SECONDS=45 "$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
proj = "stale/proj"; tid = os.environ["TEAM_ID"]
# seed a dev with a heartbeat far in the past; the default-now read is WAY past the 45s TTL.
P.record_presence("haid:ghost.box", project=proj, team_id=tid, handle="ghost",
                  verdict="idle", file="-", ts=1000.0)
resp = P.roster_team_route({"method": "GET", "route_path": "/roster-team",
        "query": {"project": proj}, "team_secret": os.environ["TEAM_SECRET"], "peer_ip": "10.0.0.5"})
handles = [r.get("handle") for r in resp.body.get("online", [])]
print(json.dumps({"status": resp.status, "handles": handles}))
PYEOF
)"
G_ABSENT="$(printf '%s' "$G_OUT" | "$PY" -c "import json,sys;print('ghost' not in json.load(sys.stdin)['handles'])" 2>/dev/null)"
[ "$G_ABSENT" = "True" ] \
  && ok "G1 FALSIFIABLE: a stale (TTL-expired) dev is DROPPED from the secret-header read (the window decides)" \
  || bad "G1 a stale dev stayed in the read (TTL not applied — out=$G_OUT)"

echo
echo "============================================================"
printf "cp-roster-team (%s): %d passed, %d failed\n" "$MODE" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
