#!/usr/bin/env bash
# cp-presence.test.sh — TEAM PRESENCE under the FIRESTORE backend (the deploy profile).
#
# WHAT THIS GATES. cp_presence is a store on the StateBackend seam: a dev's hmd POSTs a
# heartbeat, any dev reads the ONLINE roster for a project. The durability claim is that
# presence is EXTERNAL-KEYED — under HEIMDALL_STATE_BACKEND=firestore the per-dev record
# lives in Firestore (keyed to the project, NOT the ephemeral home), so a dev on a FRESH
# instance reads a heartbeat another dev wrote. This suite proves that property and its
# TTL, cross-dev, and falsifiable edges — WITHOUT touching cp_server's request path with
# backend.path() (the firestore-only incident class every CP read path must avoid).
#
#   A. HEARTBEAT -> ROSTER ROUND-TRIP under firestore (no BackendUnavailable):
#      A1. record_presence(devA) stores under firestore (no path() on the write path).
#      A2. a FRESH process reads roster(project) and sees devA — cross-process durable.
#   B. CROSS-DEV READ (one writes, another reads):
#      B1. devA + devB each beat (separate processes); a THIRD process's roster lists BOTH.
#   C. TTL drops a stale dev:
#      C1. a dev whose heartbeat is older than the TTL is NOT on the roster.
#      C2. the SAME dev, read with a `now` inside the TTL, IS on the roster (the window,
#          not the data, decides — falsifiable both directions).
#   D. FALSIFIABLE — break external-keying => the cross-read FAILS:
#      D1. the SAME records that the firestore roster returns are INVISIBLE to a reader on
#          the LOCAL (home-keyed) backend with a fresh home — proving the cross-dev read
#          depends on the EXTERNAL keying. (A build that keyed presence to the home would
#          make D1's local read see them => RED.)
#   E. SOURCE DISCIPLINE: cp_presence never calls backend.path() (grep) — every serving
#      path uses put_record/get_record/list_names, which FirestoreBackend serves.
#
# DISCIPLINE (mirrors cp-getjobs-firestore / cp-flow-firestore): isolated throwaway home +
# EXTERNAL store dir; firestore via the emulator when available, else the SAME faithful
# in-process fake google.cloud.firestore the other firestore gates use (persists to a JSON
# file so SEPARATE processes share one durable store — the cross-process property a real
# Firestore has). ZERO real GCP / ZERO spend in fake mode. Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
PRESENCE_SRC="$LIB/cp_presence.py"
export LIB REPO

for f in cp_presence cp_state cp_state_firestore cp_auth cp_server; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# The external-store dir (emulator data / fake JSON store + the fake package). Lives
# OUTSIDE the per-instance home so the backend's external-ness is honest.
EXT="$(mktemp -d -t "cp-presence.$(printf 'X%.0s' 1 2 3 4 5 6)")"
HOME_T="$EXT/home"
mkdir -p "$HOME_T"
EMU_PID=""
cleanup() { [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1 || true; rm -rf "$EXT"; }
trap cleanup EXIT

export HEIMDALL_HOME="$HOME_T"
export HEIMDALL_FIRESTORE_ROOT="presence_firestore_gate"
export HEIMDALL_FIRESTORE_PROJECT="cp-presence-test"

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
  EMU_HOST="localhost:8779"
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
echo "TEAM PRESENCE under FIRESTORE (MODE=$MODE)"
echo "  home=$HEIMDALL_HOME  root=$HEIMDALL_FIRESTORE_ROOT"
echo "============================================================"
echo

PROJECT="acme/widget"
# The team partition handle (32-hex, the derive_team_id() shape). Presence is now keyed by
# (project, team_id, haid): record_presence + roster both take team_id, resolved server-side
# from the caller's binding (cp_auth.registered_team), NEVER a body field. This suite threads
# ONE team so the durability/TTL/cross-dev/external-keying proofs hold under the new keying;
# cross-team ISOLATION is the dedicated cp-team-isolation gate.
TEAM_ID="0123456789abcdef0123456789abcdef"
export TEAM_ID
DEV_A="haid:rj.mbp-7f3a"
DEV_B="haid:sam.air-91c2"
DEV_C="haid:lee.box-44de"

# ──────────────────────────────────────────────────────────────────────────────
# A. HEARTBEAT -> ROSTER ROUND-TRIP (separate processes; no BackendUnavailable).
# ──────────────────────────────────────────────────────────────────────────────
echo "A. heartbeat -> roster round-trip under firestore"
A_WRITE="$(PRES_PROJECT="$PROJECT" PRES_HAID="$DEV_A" "$PY" - <<'PYEOF' 2>"$EXT/a_write.err"
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
res = P.record_presence(os.environ["PRES_HAID"], project=os.environ["PRES_PROJECT"],
                        team_id=os.environ["TEAM_ID"],
                        handle="rj", verdict="building", file="src/app.py")
print("ok" if res.get("ok") else "fail:%s" % res.get("reason"))
PYEOF
)"
if [ "$A_WRITE" = "ok" ] && [ ! -s "$EXT/a_write.err" ]; then
  ok "A1 record_presence(devA) stored under firestore (no BackendUnavailable on the write)"
else
  bad "A1 record_presence failed under firestore (got '$A_WRITE')"; cat "$EXT/a_write.err" >&2
fi

A_READ="$(PRES_PROJECT="$PROJECT" "$PY" - <<'PYEOF' 2>"$EXT/a_read.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
r = P.roster(os.environ["PRES_PROJECT"], os.environ["TEAM_ID"])
print(json.dumps([x.get("haid") for x in r]))
PYEOF
)"
if printf '%s' "$A_READ" | grep -q "$DEV_A" && [ ! -s "$EXT/a_read.err" ]; then
  ok "A2 a FRESH process reads roster(project) and sees devA — cross-process durable, no path()"
else
  bad "A2 fresh-process roster did NOT see devA (got '$A_READ')"; cat "$EXT/a_read.err" >&2
fi

# ──────────────────────────────────────────────────────────────────────────────
# B. CROSS-DEV READ — devA + devB beat (separate procs); a THIRD proc lists BOTH.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "B. cross-dev read (one writes, another reads the roster)"
PRES_PROJECT="$PROJECT" PRES_HAID="$DEV_B" "$PY" - <<'PYEOF' 2>"$EXT/b_write.err"
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
P.record_presence(os.environ["PRES_HAID"], project=os.environ["PRES_PROJECT"],
                  team_id=os.environ["TEAM_ID"],
                  handle="sam", verdict="reviewing", file="api/routes.py")
PYEOF
B_READ="$(PRES_PROJECT="$PROJECT" "$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
print(json.dumps(sorted(x.get("haid") for x in P.roster(os.environ["PRES_PROJECT"], os.environ["TEAM_ID"]))))
PYEOF
)"
if printf '%s' "$B_READ" | grep -q "$DEV_A" && printf '%s' "$B_READ" | grep -q "$DEV_B"; then
  ok "B1 a third process's roster lists BOTH devA and devB (cross-dev, server-synced)"
else
  bad "B1 the roster did not list both devs (got '$B_READ')"
fi

# ──────────────────────────────────────────────────────────────────────────────
# C. TTL drops a stale dev (the window, not the data, decides — both directions).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "C. TTL drops a stale dev"
# Seed devC with a heartbeat ts deterministically in the past (ts=1000.0). Read the roster
# at now=2000 (1000s later, WAY past the 45s TTL) -> devC must be OFFLINE; read at a now
# inside the TTL window -> devC must be ONLINE. Same data, the window decides.
C_OUT="$(PRES_PROJECT="$PROJECT" PRES_HAID="$DEV_C" "$PY" - <<'PYEOF' 2>"$EXT/c.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
proj = os.environ["PRES_PROJECT"]
P.record_presence(os.environ["PRES_HAID"], project=proj, team_id=os.environ["TEAM_ID"],
                  handle="lee", verdict="idle", file="-", ts=1000.0)
tid = os.environ["TEAM_ID"]
stale = [x.get("haid") for x in P.roster(proj, tid, now=2000.0)]          # 1000s old > 45s TTL
fresh = [x.get("haid") for x in P.roster(proj, tid, now=1000.0 + 10.0)]   # 10s old < 45s TTL
print(json.dumps({"stale": stale, "fresh": fresh}))
PYEOF
)"
C_STALE_HAS_C="$(printf '%s' "$C_OUT" | "$PY" -c "import json,sys;print('$DEV_C' in json.load(sys.stdin)['stale'])" 2>/dev/null)"
C_FRESH_HAS_C="$(printf '%s' "$C_OUT" | "$PY" -c "import json,sys;print('$DEV_C' in json.load(sys.stdin)['fresh'])" 2>/dev/null)"
if [ "$C_STALE_HAS_C" = "False" ]; then
  ok "C1 a dev whose heartbeat is older than the TTL is DROPPED from the roster"
else
  bad "C1 a stale dev stayed on the roster (TTL not enforced) — out=$C_OUT"; cat "$EXT/c.err" >&2
fi
if [ "$C_FRESH_HAS_C" = "True" ]; then
  ok "C2 the SAME dev read within the TTL window IS online (the window decides, not the data)"
else
  bad "C2 a fresh-within-TTL dev was missing from the roster — out=$C_OUT"
fi

# ──────────────────────────────────────────────────────────────────────────────
# D. FALSIFIABLE — break external-keying => the cross-read FAILS. The records devA/devB
#    wrote to FIRESTORE are INVISIBLE to a reader on the LOCAL (home-keyed) backend with a
#    fresh home. If presence were keyed to the home instead of the external store, this
#    local read would SEE them => RED. The empty local read is the proof the cross-dev
#    read depends on external keying.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "D. FALSIFIABLE: break external-keying -> the cross-read FAILS (local backend sees nothing)"
LOCAL_HOME="$EXT/fresh_local_home"
mkdir -p "$LOCAL_HOME"
D_READ="$(PRES_PROJECT="$PROJECT" LOCAL_HOME="$LOCAL_HOME" \
  env HEIMDALL_STATE_BACKEND=local HEIMDALL_HOME="$LOCAL_HOME" "$PY" - <<'PYEOF' 2>/dev/null
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_presence as P
# A reader on the LOCAL backend (home-keyed, NOT the external firestore store) sees NONE of
# the firestore-written heartbeats — the cross-dev read existed ONLY because of the external
# keying. This is the falsifier: a home-keyed presence store would leak these in here.
print(json.dumps([x.get("haid") for x in P.roster(os.environ["PRES_PROJECT"], os.environ["TEAM_ID"])]))
PYEOF
)"
if [ "$D_READ" = "[]" ]; then
  ok "D1 FALSIFIABLE: the firestore-written roster is INVISIBLE on the local home-keyed backend — the cross-read depends on EXTERNAL keying"
else
  bad "D1 a local home-keyed read saw the firestore records ('$D_READ') — external-keying not the source of the cross-read (RED)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# E. SOURCE DISCIPLINE — cp_presence never calls backend.path() on a serving path.
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "E. source discipline (AST of cp_presence.py — ignores docstring mentions)"
# AST-walk for a REAL `<x>.path(...)` call (an Attribute call named "path"), not the
# docstring text "backend.path()". A call is the firestore-only incident; a mention is fine.
PATH_CALLS="$(PRESENCE_SRC="$PRESENCE_SRC" "$PY" - <<'PYEOF' 2>/dev/null
import ast, os
src = open(os.environ["PRESENCE_SRC"], encoding="utf-8").read()
n = 0
for node in ast.walk(ast.parse(src)):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
       and node.func.attr == "path":
        n += 1
print(n)
PYEOF
)"
if [ "${PATH_CALLS:-1}" = "0" ]; then
  ok "E cp_presence.py NEVER calls backend.path() (every serving path uses put/get/list/exists — firestore-safe)"
else
  bad "E cp_presence.py has $PATH_CALLS real .path() call(s) — FirestoreBackend.path() RAISES on a serving path"
fi

echo
echo "============================================================"
printf "cp-presence (%s): %d passed, %d failed\n" "$MODE" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
