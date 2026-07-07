#!/usr/bin/env bash
# cp-presence-firestore.test.sh — THE VIRAL-GATE DEPLOYED-SHAPE PRESENCE ROUND-TRIP GATE.
#
# THE INCIDENT CLASS THIS GATES (production Cloud Run, HEIMDALL_STATE_BACKEND=firestore). A
# valid signed presence BEAT (POST /presence) returned 2xx and the record WAS written to
# Firestore — yet GET /roster-team with the SAME team secret + project read back {"online":[]}.
# The write landed a durable doc, but the roster READ could not ENUMERATE it under Firestore.
#
# ROOT CAUSE (firestore-only, invisible on the local backend). A presence record's store key is
#   presence/<project_slug>/<team_id_slug>/<haid_slug>.json
# On Firestore this flattens to ONE doc id, slashes → "__":
#   presence__<project>__<team_id>__<haid>.json
# FirestoreBackend.list_names recovers the immediate child under a rel_dir by taking the segment
# BEFORE the FIRST "__" in the doc-id remainder — a subdirectory when a "__" is present, a leaf
# otherwise. That is CORRECT only while no single path SEGMENT contains "__". cp_presence._slug
# was DOCUMENTED to guarantee that ("only single '_' runs ... never the '__' rel separator") but
# VIOLATED it: it mapped every non-[A-Za-z0-9._-] char to a lone '_' INDIVIDUALLY, so two adjacent
# such chars in a HAID (e.g. a "://" or "//" run in a spawn-role/oddly-formed identity) produced a
# "__" INSIDE the haid_slug leaf. Under Firestore, list_names(presence/<p>/<t>, suffix=".json")
# then read that leaf as a SUBDIRECTORY name and — because a subdirectory carries no ".json"
# suffix — DROPPED it. The dev was invisible to their own team roster. On the LOCAL backend
# list_names is os.listdir, which returns the real filename verbatim regardless of any "__", so
# EVERY hermetic cp suite (local backend) stayed green and the firestore-only break shipped.
#
# THE FIX under test: cp_presence._slug now COLLAPSES a run of replacement chars to a SINGLE '_'
# (honoring its own documented invariant), so no path segment can ever contain "__". The WRITE
# doc id and the READ list_names prefix stay byte-identical AND unambiguous on Firestore, so the
# beat<->roster round-trip closes on Firestore exactly as it always did on local.
#
# THE DEPLOYED-SHAPE DISCIPLINE (why the fake-backend BUG2 test missed this). This gate runs the
# REAL FirestoreBackend code path — NOT the LocalBackend fake — under HEIMDALL_STATE_BACKEND=
# firestore, driving the ACTUAL beat_route/roster_team_route handlers. Mode selection mirrors
# cp-flow-firestore / cp-tick-firestore / cp-durability: (0) a caller-provided emulator, (1) a
# self-started gcloud emulator, else (2) the SAME faithful in-process FAKE google.cloud.firestore
# those gates use (registered into sys.modules by a sitecustomize.py on PYTHONPATH). ZERO real
# GCP / ZERO spend. NO SECRET on disk — the PKI seed lives only in memory. The test PRINTS its mode.
#
# PROOFS (each FALSIFIABLE; all run UNDER THE FIRESTORE BACKEND):
#   FS1 NORMAL ROUND-TRIP — an enrolled dev with a well-formed haid beats WITH the team secret →
#       roster-team(SAME secret + project) SHOWS the dev. The baseline: presence works on firestore.
#   FS2 DEPLOYED-SHAPE TRIGGER (the regression) — a dev whose haid slugs to a "__"-containing leaf
#       beats WITH the secret → roster-team(SAME secret) SHOWS the dev. PRE-FIX this was EMPTY under
#       firestore (the shipped break) while GREEN under local; the collapse fix closes the gap.
#   FS3 ISOLATION FALSIFIER — after FS2's beat, roster-team(project, a DIFFERENT secret) → empty
#       under firestore too (a different secret hashes to a different partition; no cross-team leak).
#
# Exit 0 = FS1 AND FS2 AND FS3 hold under the firestore backend. Nonzero = the gate failed.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

for f in cp_auth cp_presence cp_publicsurface cp_server cp_state cp_state_firestore; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# The external-store dir (emulator data / fake JSON store + the fake package). Lives OUTSIDE the
# per-instance home so the backend's external-ness is honest.
EXT="$(mktemp -d -t "cp-presfs-ext.XXXXXX")"
HOME_T="$EXT/home"
mkdir -p "$HOME_T"

EMU_PID=""
cleanup() {
  [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1
  rm -rf "$EXT"
}
trap cleanup EXIT

# A dedicated root collection so this gate never collides with another gate's docs.
export HEIMDALL_FIRESTORE_ROOT="presence_firestore_gate"
export HEIMDALL_FIRESTORE_PROJECT="cp-presence-firestore-test"
export HEIMDALL_HOME="$HOME_T"
# The public surface must be ON so roster_team_route serves (it 404s off the public surface).
export HEIMDALL_PUBLIC_SURFACE=1

# ── a TEST seed (in memory only — NEVER written to a tracked file, NEVER printed) ──
SEED_B64="$("$PY" -c "import base64;print(base64.b64encode(bytes((i*7+3)%256 for i in range(32))).decode())")"
export HEIMDALL_CP_PKI_KEY="$SEED_B64"
export HEIMDALL_CP_SERVER_HAID="haid:cp-server"

# ── decide the firestore mode: emulator (real client) vs faithful in-process fake ──
MODE=""

# (0) EXTERNAL EMULATOR — caller pre-started one and exported its host.
if [ -n "${FIRESTORE_EMULATOR_HOST:-}" ] \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  MODE="emulator"
  echo "cp-presence-firestore: using caller-provided FIRESTORE_EMULATOR_HOST=$FIRESTORE_EMULATOR_HOST (real client, external emulator)"
fi

# (1) SELF-STARTED EMULATOR — only when the caller did not pre-set a host.
if [ -z "$MODE" ] \
   && command -v gcloud >/dev/null 2>&1 \
   && gcloud beta emulators firestore --help >/dev/null 2>&1 \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  EMU_HOST="localhost:8772"
  gcloud beta emulators firestore start --host-port="$EMU_HOST" >"$EXT/emu.log" 2>&1 &
  EMU_PID=$!
  for _ in $(seq 1 60); do
    if grep -qi "running\|$EMU_HOST" "$EXT/emu.log" 2>/dev/null; then break; fi
    if ! kill -0 "$EMU_PID" >/dev/null 2>&1; then break; fi
    "$PY" -c "import time;time.sleep(0.25)"
  done
  if kill -0 "$EMU_PID" >/dev/null 2>&1 && grep -qi "running\|$EMU_HOST" "$EXT/emu.log" 2>/dev/null; then
    export FIRESTORE_EMULATOR_HOST="$EMU_HOST"
    MODE="emulator"
  else
    echo "cp-presence-firestore: self-started emulator did not come up — falling back to fake." >&2
    tail -3 "$EXT/emu.log" >&2 2>/dev/null || true
    [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1
    EMU_PID=""
  fi
fi

if [ -z "$MODE" ]; then
  # FAKE MODE — the SAME faithful in-process google.cloud.firestore the cp-durability /
  # cp-tick-firestore / cp-flow-firestore gates use (a sitecustomize.py on PYTHONPATH registers it
  # into sys.modules before any import), persisting to a JSON file so reads after a write see the
  # same store. The SHIPPED FirestoreBackend code is real; only the external service is a double.
  # NB: the fake degrades cp_state_firestore._prefix_query to a full-collection scan, but the
  # list_names LEAF-vs-SUBDIR partition logic (the code this gate exercises) runs post-stream in
  # the REAL FirestoreBackend, so the "__"-leaf drop reproduces faithfully in fake mode too.
  MODE="fake"
  FAKEPKG="$EXT/pylib"
  mkdir -p "$FAKEPKG"
  cat >"$FAKEPKG/_fake_firestore_impl.py" <<'PYEOF'
# Faithful in-process FAKE of the slice of google.cloud.firestore FirestoreBackend uses. PERSISTS
# the whole store to the JSON file named by HEIMDALL_FAKE_FS_STORE so reads after a write share
# one durable store.
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
    def __init__(self, project=None, database=None):
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

echo "cp-presence-firestore: MODE=$MODE  (external store: $EXT)"
echo

# Everything from here runs under the firestore backend (the deploy profile that broke).
export HEIMDALL_STATE_BACKEND="firestore"

PROJECT="github.com/acme/widget"
SECRET="team-secret-FSAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"   # >= 32 chars (the client mints 43).
OTHER="team-secret-FSZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"
# A well-formed identity (FS1) and a DEPLOYED-SHAPE identity whose _slug leaf contains "__"
# (FS2): the ":/" run in the haid maps to a lone '_' per char PRE-FIX, i.e. "haid_a__b-1".
NORMAL_HAID="haid:rj.mbp-7f3a"
TRIGGER_HAID="haid:a:/b-1"
export PROJECT SECRET OTHER NORMAL_HAID TRIGGER_HAID

echo "============================================================"
echo "VIRAL-GATE deployed-shape presence round-trip — UNDER THE FIRESTORE BACKEND ($MODE)"
echo "  home=$HEIMDALL_HOME  backend=$HEIMDALL_STATE_BACKEND"
echo "============================================================"
echo

# ── the driver: one process that enrolls, beats, and reads roster-team through the REAL route
#    handlers UNDER FIRESTORE, then prints a single JSON status line the bash gate parses. It IS
#    the handler body, so a firestore-only write/read key divergence surfaces here. ──
DRIVER="$EXT/pres_driver.py"
cat >"$DRIVER" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["LIB"])
import cp_auth
import cp_presence as P

HOME = os.environ["HEIMDALL_HOME"]
PROJECT = os.environ["PROJECT"]
SECRET = os.environ["SECRET"]
OTHER = os.environ["OTHER"]


def enroll_and_beat(haid, secret):
    """Enroll a member bound to `secret`'s team, then drive the REAL POST /presence beat_route
    WITH the secret in the lifted header slot — exactly the deployed request shape."""
    _, pub = cp_auth.generate_keypair()
    cp_auth.register_key(haid, pub, owner=False, team_id=cp_auth.derive_team_id(secret), home=HOME)
    req = {"team_secret": secret,
           "body": json.dumps({"project": PROJECT, "handle": "dev",
                               "verdict": "building", "file": "x.py"})}
    return P.beat_route(cp_auth.Identity(haid), req, home=HOME)


def roster_team(secret):
    """Drive the REAL GET /roster-team roster_team_route with `secret` — the browser read shape."""
    return P.roster_team_route({"method": "GET", "route_path": "/roster-team",
                                "query": {"project": PROJECT},
                                "team_secret": secret, "peer_ip": "10.0.0.1"}, home=HOME)


# FS1 — a well-formed haid round-trips under firestore.
b1 = enroll_and_beat(os.environ["NORMAL_HAID"], SECRET)
r1 = roster_team(SECRET)
fs1_haids = [r.get("haid") for r in r1.body.get("online", [])]

# FS2 — the DEPLOYED-SHAPE trigger: a haid whose _slug leaf contains "__". PRE-FIX this beat
# was written to firestore but roster-team could not enumerate it (empty). POST-FIX it appears.
trig = os.environ["TRIGGER_HAID"]
b2 = enroll_and_beat(trig, SECRET)
r2 = roster_team(SECRET)
fs2_haids = [r.get("haid") for r in r2.body.get("online", [])]

# FS3 — isolation: a DIFFERENT secret sees an empty roster under firestore too.
r3 = roster_team(OTHER)
fs3_online = r3.body.get("online")

print(json.dumps({
    "slug_trigger": P._slug(trig),
    "fs1_beat": b1.status, "fs1_rt": r1.status, "fs1_haids": fs1_haids,
    "fs2_beat": b2.status, "fs2_rt": r2.status, "fs2_haids": fs2_haids,
    "fs3_rt": r3.status, "fs3_online": fs3_online,
}))
PYEOF

OUT="$("$PY" "$DRIVER" 2>"$EXT/driver.err")"
if [ -z "$OUT" ]; then
  bad "driver produced no output (see stderr)"; cat "$EXT/driver.err" >&2
  echo; echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi
echo "  driver: $OUT"
echo

# FS1 — normal round-trip.
FS1="$(printf '%s' "$OUT" | "$PY" -c "import json,sys,os;d=json.load(sys.stdin);print(d['fs1_beat']==200 and d['fs1_rt']==200 and os.environ['NORMAL_HAID'] in d['fs1_haids'])" 2>/dev/null)"
[ "$FS1" = "True" ] \
  && ok "FS1 a well-formed haid's beat is VISIBLE in roster-team(same secret) UNDER FIRESTORE" \
  || bad "FS1 the normal round-trip failed under firestore — out=$OUT"

# FS2 — the deployed-shape "__"-leaf trigger (the regression this gate exists for). The dev MUST
# round-trip under firestore. PRE-FIX the raw slug held a "__" and the record vanished; the fix
# collapses the run so the leaf is unambiguous — either way the property under test is: the
# adjacent-special-run haid is VISIBLE to its own roster-team UNDER FIRESTORE.
FS2="$(printf '%s' "$OUT" | "$PY" -c "import json,sys,os;d=json.load(sys.stdin);print(d['fs2_beat']==200 and d['fs2_rt']==200 and os.environ['TRIGGER_HAID'] in d['fs2_haids'])" 2>/dev/null)"
[ "$FS2" = "True" ] \
  && ok "FS2 a deployed-shape haid (adjacent-special run) is VISIBLE in roster-team UNDER FIRESTORE (the gap is closed)" \
  || bad "FS2 the deployed-shape haid was INVISIBLE to its own roster-team UNDER FIRESTORE (the shipped break) — out=$OUT"

# FS3 — isolation falsifier.
FS3="$(printf '%s' "$OUT" | "$PY" -c "import json,sys;d=json.load(sys.stdin);print(d['fs3_rt']==200 and d['fs3_online']==[])" 2>/dev/null)"
[ "$FS3" = "True" ] \
  && ok "FS3 a DIFFERENT secret sees an EMPTY roster UNDER FIRESTORE (no cross-team leak)" \
  || bad "FS3 a different secret leaked the team's roster under firestore — out=$OUT"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
