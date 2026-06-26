#!/usr/bin/env bash
# cp-nonce.test.sh — the REPLAY GATE for the public control-plane surface (presence beats).
#
# WHAT THIS GATES. cp_nonce is a replay/freshness gate on the StateBackend seam:
# accept(scope, key, nonce, ts, now, window) returns (ok, reason). A signed beat's (nonce, ts)
# ride in the SIGNED body (cp_auth-covered → unforgeable, only replayable), so this module
# decides FRESHNESS (stale ts) + FIRST-USE (replay) only. It is the abuse gate that stops a
# CAPTURED signed beat from being re-POSTed against the --allow-unauthenticated surface. This
# suite proves the first-use accept, the replay refusal, the stale refusal, fresh-nonce accept,
# per-identity nonce independence, the TTL self-expiry (reuse after the window), the firestore-
# durable cross-process round-trip (no BackendUnavailable / no backend.path()), and a FALSIFIER
# (skip recording the nonce → the replay WRONGLY passes → the refusal assertion would go RED),
# in BOTH the local and firestore backends.
#
#   A. FIRST-USE + REPLAY (local): the first (nonce, ts) is ACCEPTED (reason "ok"); the SAME
#      (scope, key, nonce) again is REFUSED (reason "replay").
#   B. STALE (local): a beat whose ts is now-window-10 (outside ±window) is REFUSED (reason
#      "stale") — PURE check, the freshness bound a captured beat cannot outlive.
#   C. FRESH NONCE (local): a NEW nonce with a fresh ts is ACCEPTED (reason "ok") — the
#      falsifiable opposite of A's replay refusal (a different nonce is not a replay).
#   D. PER-IDENTITY INDEPENDENCE (local): two DIFFERENT haids reusing the SAME nonce value are
#      INDEPENDENT — both accepted (the nonce namespace is per-key, so devs cannot collide).
#   E. TTL SELF-EXPIRY (local): the SAME (key, nonce) read one window+ later is RE-ACCEPTED —
#      a record older than the window is self-expired (the stale check already bounds replay to
#      ±window, so the seen-set never grows unbounded).
#   F. FALSIFIER (local): with the nonce-recording write DISABLED (put_record neutered to not
#      persist), the REPLAY WRONGLY passes (reason "ok") — proving A's replay refusal depends on
#      the record (re-enable it and A is GREEN; disable it and A would be RED).
#   G. FIRESTORE ROUND-TRIP (firestore): process 1 accepts a nonce; a FRESH process 2 replays
#      the SAME (scope, key, nonce, ts) and is REFUSED off the SAME shared seen-set — cross-
#      instance durable, with NO BackendUnavailable and NO backend.path() on the serving path.
#   H. SOURCE DISCIPLINE: cp_nonce never calls backend.path() (AST) — every op is get/put,
#      which FirestoreBackend serves (the firestore-only incident class).
#
# DISCIPLINE (mirrors cp-ratelimit / cp-presence / cp-getjobs-firestore): isolated throwaway
# home + EXTERNAL store dir; firestore via the emulator when available, else the SAME faithful
# in-process fake google.cloud.firestore the other firestore gates use (persists to a JSON file
# so SEPARATE processes share one durable store). ZERO real GCP / ZERO spend in fake mode.
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
NONCE_SRC="$LIB/cp_nonce.py"
export LIB REPO NONCE_SRC

for f in cp_nonce cp_state cp_state_firestore; do
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
EXT="$(mktemp -d -t "cp-nonce.$(printf 'X%.0s' 1 2 3 4 5 6)")"
HOME_T="$EXT/home"
mkdir -p "$HOME_T"
EMU_PID=""
cleanup() { [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1 || true; rm -rf "$EXT"; }
trap cleanup EXIT

export HEIMDALL_FIRESTORE_ROOT="nonce_firestore_gate"
export HEIMDALL_FIRESTORE_PROJECT="cp-nonce-test"

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
  EMU_HOST="localhost:8782"
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
# Faithful in-process FAKE of the google.cloud.firestore slice FirestoreBackend uses. PERSISTS
# the whole store to the JSON file named by HEIMDALL_FAKE_FS_STORE so SEPARATE processes share
# one durable store — the cross-process property a real Firestore has.
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

echo "============================================================"
echo "REPLAY-NONCE — public-surface replay gate (firestore MODE=$MODE)"
echo "============================================================"
echo

# ──────────────────────────────────────────────────────────────────────────────
# A–F. CORE LOGIC under the LOCAL backend (deterministic, injected now).
# ──────────────────────────────────────────────────────────────────────────────
LOCAL_HOME="$EXT/local_home"
mkdir -p "$LOCAL_HOME"

echo "A–F. core logic (LOCAL backend, injected now)"
CORE_OUT="$(env HEIMDALL_STATE_BACKEND=local HEIMDALL_HOME="$LOCAL_HOME" LOCAL_HOME="$LOCAL_HOME" \
  "$PY" - <<'PYEOF' 2>"$EXT/core.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_state
import cp_nonce as N

home = os.environ["LOCAL_HOME"]
be = cp_state.get_backend(home=home)   # one pinned local backend for the whole core run
window, now = 300, 1000.0
out = {}

# A. FIRST-USE + REPLAY. First sight accepted; the SAME (scope, key, nonce) again -> replay.
first = N.accept("presence", "haid:rj.mbp", "nonce-A", now, now=now, window=window, backend=be)
again = N.accept("presence", "haid:rj.mbp", "nonce-A", now, now=now, window=window, backend=be)
out["A_first"] = list(first)           # expect [True, "ok"]
out["A_again"] = list(again)           # expect [False, "replay"]

# B. STALE. ts = now-window-10 (outside ±window) -> refused "stale" (pure check, fresh nonce).
stale = N.accept("presence", "haid:rj.mbp", "nonce-STALE", now - window - 10,
                 now=now, window=window, backend=be)
out["B_stale"] = list(stale)           # expect [False, "stale"]

# C. FRESH NONCE. A NEW nonce with a fresh ts is accepted (a different nonce is not a replay).
fresh = N.accept("presence", "haid:rj.mbp", "nonce-B", now, now=now, window=window, backend=be)
out["C_fresh"] = list(fresh)           # expect [True, "ok"]

# D. PER-IDENTITY INDEPENDENCE. Two DIFFERENT haids reusing the SAME nonce value -> independent.
d1 = N.accept("presence", "haid:alice", "shared-nonce", now, now=now, window=window, backend=be)
d2 = N.accept("presence", "haid:bob",   "shared-nonce", now, now=now, window=window, backend=be)
out["D_alice"] = list(d1)              # expect [True, "ok"]
out["D_bob"] = list(d2)                # expect [True, "ok"]  (the bob namespace is independent)

# E. TTL SELF-EXPIRY. Record a nonce at now; replay it >1 window later -> the prior record is
# self-expired (its ts is now-stale), so it is RE-ACCEPTED, not flagged a replay.
N.accept("presence", "haid:ttl", "nonce-TTL", now, now=now, window=window, backend=be)
later = now + window + 50
reuse = N.accept("presence", "haid:ttl", "nonce-TTL", later, now=later, window=window, backend=be)
out["E_reuse_after_window"] = list(reuse)   # expect [True, "ok"]

# F. FALSIFIER. Disable the nonce-recording write (put_record neutered to NOT persist): the
# REPLAY WRONGLY passes -> proving the A replay refusal depends on the record. If A still
# "replayed" here, A would be testing nothing.
class _NoPersist:
    def __init__(self, inner): self._inner = inner
    def get_record(self, rel): return self._inner.get_record(rel)
    def put_record(self, rel, record): return True   # accept the write but DROP it (no persist)
be_falsi = _NoPersist(be)
N.accept("presence", "haid:falsi", "nonce-F", now, now=now, window=window, backend=be_falsi)
fre = N.accept("presence", "haid:falsi", "nonce-F", now, now=now, window=window, backend=be_falsi)
out["F_falsifier_replay"] = list(fre)  # WRONGLY [True, "ok"] with the record disabled

print(json.dumps(out))
PYEOF
)"

if [ -s "$EXT/core.err" ]; then
  bad "core logic raised on stderr"; cat "$EXT/core.err" >&2
fi
get() { printf '%s' "$CORE_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null; }

[ "$(get "['A_first']")" = "[True, 'ok']" ] \
  && ok "A first (nonce, ts) is ACCEPTED (reason ok)" \
  || bad "A first sight was not accepted (out=$CORE_OUT)"
[ "$(get "['A_again']")" = "[False, 'replay']" ] \
  && ok "A the SAME (scope, key, nonce) again is REFUSED (reason replay)" \
  || bad "A the replay was not refused (out=$CORE_OUT)"
[ "$(get "['B_stale']")" = "[False, 'stale']" ] \
  && ok "B a ts outside ±window is REFUSED (reason stale) — the pure freshness bound" \
  || bad "B a stale ts was not refused (out=$CORE_OUT)"
[ "$(get "['C_fresh']")" = "[True, 'ok']" ] \
  && ok "C a NEW nonce with a fresh ts is ACCEPTED (a different nonce is not a replay)" \
  || bad "C a fresh nonce was not accepted (out=$CORE_OUT)"
[ "$(get "['D_alice']")" = "[True, 'ok']" ] && [ "$(get "['D_bob']")" = "[True, 'ok']" ] \
  && ok "D two haids reusing the SAME nonce are INDEPENDENT (per-identity namespace)" \
  || bad "D a shared nonce across haids was not independent (out=$CORE_OUT)"
[ "$(get "['E_reuse_after_window']")" = "[True, 'ok']" ] \
  && ok "E a nonce is REUSABLE after the window (TTL self-expiry — seen-set never grows unbounded)" \
  || bad "E the nonce was not reusable after the window (out=$CORE_OUT)"
[ "$(get "['F_falsifier_replay']")" = "[True, 'ok']" ] \
  && ok "F FALSIFIER: with the record disabled the replay WRONGLY passes — A's refusal genuinely depends on recording the nonce" \
  || bad "F disabling the record did NOT make the replay pass — A is not actually testing the record (out=$CORE_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# G. FIRESTORE ROUND-TRIP — process 1 accepts a nonce; a FRESH process 2 replays the SAME
#    (scope, key, nonce, ts) and is REFUSED off the SAME shared seen-set (cross-instance
#    durable, no BackendUnavailable / no path()).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "G. firestore cross-process round-trip (no BackendUnavailable, no path())"
export HEIMDALL_STATE_BACKEND="firestore"
export HEIMDALL_HOME="$HOME_T"

G1="$("$PY" - <<'PYEOF' 2>"$EXT/g1.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_nonce as N
ok, reason = N.accept("presence", "haid:rj.mbp", "nonce-G", 2000.0, now=2000.0, window=300)
print(json.dumps([ok, reason]))                        # expect [true, "ok"]
PYEOF
)"
G2="$("$PY" - <<'PYEOF' 2>"$EXT/g2.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_nonce as N
ok, reason = N.accept("presence", "haid:rj.mbp", "nonce-G", 2000.0, now=2000.0, window=300)
print(json.dumps({"ok": ok, "reason": reason}))        # expect ok False, reason "replay"
PYEOF
)"
G2_OK="$(printf '%s' "$G2" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['ok'])" 2>/dev/null)"
G2_REASON="$(printf '%s' "$G2" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['reason'])" 2>/dev/null)"
if [ "$G1" = "[true, \"ok\"]" ] && [ "$G2_OK" = "False" ] && [ "$G2_REASON" = "replay" ] \
   && [ ! -s "$EXT/g1.err" ] && [ ! -s "$EXT/g2.err" ]; then
  ok "G process 1 accepted; a FRESH process 2 was REFUSED (replay) off the shared firestore seen-set — durable, no BackendUnavailable"
else
  bad "G firestore cross-process round-trip failed (g1='$G1' g2='$G2')"
  cat "$EXT/g1.err" "$EXT/g2.err" >&2
fi
# Explicit: no BackendUnavailable surfaced anywhere (path() refusal class).
if grep -qi "BackendUnavailable" "$EXT/g1.err" "$EXT/g2.err" 2>/dev/null; then
  bad "G BackendUnavailable surfaced on the firestore serving path (a path() call leaked in)"
else
  ok "G no BackendUnavailable on the firestore serving path"
fi

# ──────────────────────────────────────────────────────────────────────────────
# H. SOURCE DISCIPLINE — cp_nonce never calls backend.path() on a serving path (AST).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "H. source discipline (AST of cp_nonce.py — ignores docstring mentions)"
PATH_CALLS="$(NONCE_SRC="$NONCE_SRC" "$PY" - <<'PYEOF' 2>/dev/null
import ast, os
src = open(os.environ["NONCE_SRC"], encoding="utf-8").read()
n = 0
for node in ast.walk(ast.parse(src)):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
       and node.func.attr == "path":
        n += 1
print(n)
PYEOF
)"
[ "${PATH_CALLS:-1}" = "0" ] \
  && ok "H cp_nonce.py NEVER calls backend.path() (every op is get/put — firestore-safe)" \
  || bad "H cp_nonce.py has $PATH_CALLS real .path() call(s) — FirestoreBackend.path() RAISES on a serving path"

echo
echo "============================================================"
printf "cp-nonce (%s): %d passed, %d failed\n" "$MODE" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
