#!/usr/bin/env bash
# cp-ratelimit.test.sh — the ABUSE GATE for the public control-plane surface (enroll+presence).
#
# WHAT THIS GATES. cp_ratelimit is a fixed-window counter on the StateBackend seam: allow(scope,
# key, limit, window) consumes one unit of a (scope, key) quota per window and refuses the
# (limit+1)th with a retry_after; enroll_budget_ok caps NEW enrollments deployment-wide. It is
# the ONLY abuse gate once /enroll + /presence are served --allow-unauthenticated. This suite
# proves the limit, the rollover, per-key independence, the registry-growth ceiling, the
# firestore-durable cross-process round-trip (no BackendUnavailable / no backend.path()), and a
# FALSIFIER (disable the increment -> the (limit+1)th wrongly passes -> the refusal assertion
# would go RED), in BOTH the local and firestore backends.
#
#   A. LIMIT + RETRY_AFTER (local): the first `limit` calls in a window pass; the (limit+1)th is
#      REFUSED with retry_after >= 1.
#   B. WINDOW ROLLOVER (local): the SAME key, read one window later, is RE-ALLOWED (the window,
#      not the data, decides — re-allow is the falsifiable opposite of A's refusal).
#   C. PER-KEY INDEPENDENCE (local): an exhausted key (a noisy IP) does NOT block a DIFFERENT key
#      (per-IP and per-token counters are independent — one hammering caller cannot starve all).
#   D. ENROLL-BUDGET CEILING (local): enroll_budget_ok allows `max_new` new enrollments per
#      window then REFUSES — the deployment-wide registry-growth bound.
#   E. FALSIFIER (local): with the counter increment DISABLED (put_record neutered to not
#      persist), the (limit+1)th call WRONGLY passes — proving A's refusal depends on the
#      increment (re-enable it and A is GREEN; disable it and A would be RED).
#   F. FIRESTORE ROUND-TRIP (firestore): process 1 exhausts the limit; a FRESH process 2 reads
#      the SAME shared counter and is REFUSED — cross-instance durable, with NO BackendUnavailable
#      and NO backend.path() on the serving path.
#   G. SOURCE DISCIPLINE: cp_ratelimit never calls backend.path() (AST) — every op is get/put,
#      which FirestoreBackend serves (the firestore-only incident class).
#
# DISCIPLINE (mirrors cp-presence / cp-getjobs-firestore): isolated throwaway home + EXTERNAL
# store dir; firestore via the emulator when available, else the SAME faithful in-process fake
# google.cloud.firestore the other firestore gates use (persists to a JSON file so SEPARATE
# processes share one durable store). ZERO real GCP / ZERO spend in fake mode. Exit 0 = every
# proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
RL_SRC="$LIB/cp_ratelimit.py"
export LIB REPO RL_SRC

for f in cp_ratelimit cp_state cp_state_firestore; do
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
EXT="$(mktemp -d -t "cp-ratelimit.$(printf 'X%.0s' 1 2 3 4 5 6)")"
HOME_T="$EXT/home"
mkdir -p "$HOME_T"
EMU_PID=""
cleanup() { [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1 || true; rm -rf "$EXT"; }
trap cleanup EXIT

export HEIMDALL_FIRESTORE_ROOT="ratelimit_firestore_gate"
export HEIMDALL_FIRESTORE_PROJECT="cp-ratelimit-test"

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
  EMU_HOST="localhost:8781"
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
echo "RATE LIMITER — public-surface abuse gate (firestore MODE=$MODE)"
echo "============================================================"
echo

# ──────────────────────────────────────────────────────────────────────────────
# A–E. CORE LOGIC under the LOCAL backend (deterministic, injected now).
# ──────────────────────────────────────────────────────────────────────────────
LOCAL_HOME="$EXT/local_home"
mkdir -p "$LOCAL_HOME"

echo "A–E. core logic (LOCAL backend, injected now)"
CORE_OUT="$(env HEIMDALL_STATE_BACKEND=local HEIMDALL_HOME="$LOCAL_HOME" LOCAL_HOME="$LOCAL_HOME" \
  "$PY" - <<'PYEOF' 2>"$EXT/core.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_ratelimit as R

home = os.environ["LOCAL_HOME"]
out = {}

# A. LIMIT + RETRY_AFTER. limit=3, window=10, fixed now in one bucket.
rl = R.RateLimiter(home=home)
limit, window, now = 3, 10, 1000.0
seq = [rl.allow("enroll", "1.2.3.4", now=now, limit=limit, window=window) for _ in range(4)]
out["A_first3_ok"] = [s[0] for s in seq[:3]]          # expect [True, True, True]
out["A_4th_ok"] = seq[3][0]                            # expect False
out["A_4th_retry_after"] = seq[3][1]                   # expect >= 1

# B. WINDOW ROLLOVER. The SAME exhausted key, one window later, is re-allowed.
roll = rl.allow("enroll", "1.2.3.4", now=now + window, limit=limit, window=window)
out["B_rollover_ok"] = roll[0]                         # expect True

# C. PER-KEY INDEPENDENCE. A DIFFERENT key is untouched by 1.2.3.4's exhaustion.
other = rl.allow("enroll", "9.9.9.9", now=now, limit=limit, window=window)
out["C_other_key_ok"] = other[0]                       # expect True
# And a per-TOKEN key (different scope/key namespace) is independent too.
tok = rl.allow("enroll", "tokhash-abc", now=now, limit=limit, window=window)
out["C_token_key_ok"] = tok[0]                         # expect True

# D. ENROLL-BUDGET CEILING. max_new=2 per window, then refused.
budget = [rl.enroll_budget_ok(now=5000.0, max_new=2, window=60) for _ in range(3)]
out["D_budget"] = budget                               # expect [True, True, False]

# E. FALSIFIER. Disable the counter increment (put_record neutered to NOT persist): the
# (limit+1)th call WRONGLY passes — proving A's refusal depends on the increment. If A were
# still "refused" here, A would be testing nothing.
rl2 = R.RateLimiter(home=home)
rl2._backend.put_record = lambda rel, record: True     # accept the write but DROP it (no persist)
falsi = [rl2.allow("enroll", "5.5.5.5", now=7000.0, limit=limit, window=window) for _ in range(4)]
out["E_falsifier_4th_ok"] = falsi[3][0]                # WRONGLY True with increment disabled

print(json.dumps(out))
PYEOF
)"

if [ -s "$EXT/core.err" ]; then
  bad "core logic raised on stderr"; cat "$EXT/core.err" >&2
fi
get() { printf '%s' "$CORE_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null; }

[ "$(get "['A_first3_ok']")" = "[True, True, True]" ] \
  && ok "A first 3 calls within the window PASS" \
  || bad "A first 3 calls did not all pass (out=$CORE_OUT)"
[ "$(get "['A_4th_ok']")" = "False" ] \
  && ok "A the (limit+1)th call is REFUSED" \
  || bad "A the (limit+1)th call was not refused (out=$CORE_OUT)"
RA="$(get "['A_4th_retry_after']")"
{ [ -n "$RA" ] && [ "$RA" -ge 1 ] 2>/dev/null; } \
  && ok "A the refusal carries retry_after >= 1 (got $RA)" \
  || bad "A retry_after was not >= 1 (got '$RA')"
[ "$(get "['B_rollover_ok']")" = "True" ] \
  && ok "B the window ROLLS OVER and the same key is re-allowed" \
  || bad "B the window did not roll over (out=$CORE_OUT)"
[ "$(get "['C_other_key_ok']")" = "True" ] && [ "$(get "['C_token_key_ok']")" = "True" ] \
  && ok "C per-IP and per-token counters are INDEPENDENT (a noisy key blocks only itself)" \
  || bad "C an exhausted key bled into a different key (out=$CORE_OUT)"
[ "$(get "['D_budget']")" = "[True, True, False]" ] \
  && ok "D enroll_budget_ok caps NEW enrollments at max_new per window" \
  || bad "D the enroll-budget ceiling did not hold (out=$CORE_OUT)"
[ "$(get "['E_falsifier_4th_ok']")" = "True" ] \
  && ok "E FALSIFIER: with the increment disabled the (limit+1)th WRONGLY passes — A's refusal genuinely depends on the increment" \
  || bad "E disabling the increment did NOT make the (limit+1)th pass — A is not actually testing the increment (out=$CORE_OUT)"

# ──────────────────────────────────────────────────────────────────────────────
# F. FIRESTORE ROUND-TRIP — process 1 exhausts the limit; a FRESH process 2 reads the SAME
#    shared counter and is REFUSED (cross-instance durable, no BackendUnavailable / no path()).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "F. firestore cross-process round-trip (no BackendUnavailable, no path())"
export HEIMDALL_STATE_BACKEND="firestore"
export HEIMDALL_HOME="$HOME_T"

F1="$("$PY" - <<'PYEOF' 2>"$EXT/f1.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_ratelimit as R
rl = R.RateLimiter()                                   # firestore backend (home ignored)
seq = [rl.allow("presence", "haid:rj.mbp", now=2000.0, limit=2, window=30) for _ in range(2)]
print(json.dumps([s[0] for s in seq]))                 # expect [True, True]
PYEOF
)"
F2="$("$PY" - <<'PYEOF' 2>"$EXT/f2.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_ratelimit as R
rl = R.RateLimiter()                                   # a FRESH process, same shared counter
ok, retry = rl.allow("presence", "haid:rj.mbp", now=2000.0, limit=2, window=30)
print(json.dumps({"ok": ok, "retry": retry}))          # expect ok False, retry >= 1
PYEOF
)"
F2_OK="$(printf '%s' "$F2" | "$PY" -c "import json,sys;print(json.load(sys.stdin)['ok'])" 2>/dev/null)"
if [ "$F1" = "[true, true]" ] && [ "$F2_OK" = "False" ] \
   && [ ! -s "$EXT/f1.err" ] && [ ! -s "$EXT/f2.err" ]; then
  ok "F process 1's 2 calls passed; a FRESH process 2 was REFUSED off the shared firestore counter — durable, no BackendUnavailable"
else
  bad "F firestore cross-process round-trip failed (f1='$F1' f2='$F2')"
  cat "$EXT/f1.err" "$EXT/f2.err" >&2
fi
# Explicit: no BackendUnavailable surfaced anywhere (path() refusal class).
if grep -qi "BackendUnavailable" "$EXT/f1.err" "$EXT/f2.err" 2>/dev/null; then
  bad "F BackendUnavailable surfaced on the firestore serving path (a path() call leaked in)"
else
  ok "F no BackendUnavailable on the firestore serving path"
fi

# ──────────────────────────────────────────────────────────────────────────────
# G. SOURCE DISCIPLINE — cp_ratelimit never calls backend.path() on a serving path (AST).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "G. source discipline (AST of cp_ratelimit.py — ignores docstring mentions)"
PATH_CALLS="$(RL_SRC="$RL_SRC" "$PY" - <<'PYEOF' 2>/dev/null
import ast, os
src = open(os.environ["RL_SRC"], encoding="utf-8").read()
n = 0
for node in ast.walk(ast.parse(src)):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
       and node.func.attr == "path":
        n += 1
print(n)
PYEOF
)"
[ "${PATH_CALLS:-1}" = "0" ] \
  && ok "G cp_ratelimit.py NEVER calls backend.path() (every op is get/put — firestore-safe)" \
  || bad "G cp_ratelimit.py has $PATH_CALLS real .path() call(s) — FirestoreBackend.path() RAISES on a serving path"

# ──────────────────────────────────────────────────────────────────────────────
# H. PARTIAL-CONFIG SAFETY — a LIMIT set WITHOUT its WINDOW partner (the prod incident: a cap
#    env was set but the *_WINDOW var was NOT). The limiter MUST default the window safely and
#    ENFORCE the cap — never TypeError the cap OPEN, never fail-closed-refuse a numeric-string
#    limit. Three falsifiable proofs: (H1) window=None enforces AND the refusal's retry_after
#    reflects the SANE DEFAULT window (not a 1s degrade); (H2) a numeric-STRING limit/window
#    coerces and enforces (the FIRST call PASSES — pre-fix a str limit fail-closed-refused the
#    first call); (H3) enroll_budget_ok with a missing window still enforces (no TypeError).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "H. partial-config safety (a LIMIT with a MISSING/str WINDOW enforces, never TypeErrors open)"
PART_OUT="$(env HEIMDALL_STATE_BACKEND=local HEIMDALL_HOME="$LOCAL_HOME" LOCAL_HOME="$LOCAL_HOME" \
  "$PY" - <<'PYEOF' 2>"$EXT/part.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_ratelimit as R
home = os.environ["LOCAL_HOME"]
out = {}

# H1. A LIMIT set WITHOUT its WINDOW — window resolves to None. The cap must STILL enforce
#     (first `limit` pass, (limit+1)th refused) with NO exception, and the retry_after must
#     reflect the SANE DEFAULT window (>= 2s), proving it is not the old 1s divide-safety clamp.
rl = R.RateLimiter(home=home)
seq = [rl.allow("rr_dispatch", "team-none-window", now=1000.0, limit=3, window=None)
       for _ in range(4)]
out["H1_first3_ok"] = [s[0] for s in seq[:3]]      # expect [True, True, True]
out["H1_4th_ok"] = seq[3][0]                        # expect False (enforced, not opened)
out["H1_4th_retry_after"] = seq[3][1]               # expect >= 2 (the sane default window)

# H2. A numeric-STRING limit AND window (an un-coerced env value handed straight in). The
#     limiter must COERCE str->int and ENFORCE — the FIRST call must PASS (pre-fix a str limit
#     hit `not isinstance(limit,(int,float))` and fail-CLOSED-refused every call, incl. the 1st).
rl2 = R.RateLimiter(home=home)
seq2 = [rl2.allow("rr_dispatch", "team-str-cfg", now=2000.0, limit="3", window="10")
        for _ in range(4)]
out["H2_first_ok"] = seq2[0][0]                     # expect True (str limit coerced, not refused)
out["H2_first3_ok"] = [s[0] for s in seq2[:3]]      # expect [True, True, True]
out["H2_4th_ok"] = seq2[3][0]                        # expect False (coerced cap still enforces)

# H3. enroll_budget_ok with a MISSING window (None) still enforces its ceiling (no TypeError).
budget = [rl2.enroll_budget_ok(now=3000.0, max_new=2, window=None) for _ in range(3)]
out["H3_budget"] = budget                           # expect [True, True, False]

print(json.dumps(out))
PYEOF
)"
if [ -s "$EXT/part.err" ]; then
  bad "H partial-config raised on stderr (a TypeError leaked — the cap opened): $(cat "$EXT/part.err")"
fi
pget() { printf '%s' "$PART_OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null; }

[ "$(pget "['H1_first3_ok']")" = "[True, True, True]" ] && [ "$(pget "['H1_4th_ok']")" = "False" ] \
  && ok "H1 a LIMIT with a MISSING window ENFORCES (first 3 pass, 4th refused) — no TypeError, cap not opened" \
  || bad "H1 a missing-window cap did not enforce (out=$PART_OUT)"
H1RA="$(pget "['H1_4th_retry_after']")"
{ [ -n "$H1RA" ] && [ "$H1RA" -ge 2 ] 2>/dev/null; } \
  && ok "H1 the refusal's retry_after reflects the SANE DEFAULT window (got ${H1RA}s, not the 1s divide-safety degrade)" \
  || bad "H1 retry_after did not reflect a sane default window (got '$H1RA' — a missing window degraded to ~1s)"
[ "$(pget "['H2_first_ok']")" = "True" ] \
  && ok "H2 FALSIFIABLE: a numeric-STRING limit COERCES and the FIRST call PASSES (pre-fix a str limit fail-closed-refused every call)" \
  || bad "H2 a numeric-string limit did not coerce — the first call was refused (fail-closed) (out=$PART_OUT)"
[ "$(pget "['H2_first3_ok']")" = "[True, True, True]" ] && [ "$(pget "['H2_4th_ok']")" = "False" ] \
  && ok "H2 a str limit/window coerces AND still enforces the cap (first 3 pass, 4th refused)" \
  || bad "H2 a str-config cap did not enforce correctly (out=$PART_OUT)"
[ "$(pget "['H3_budget']")" = "[True, True, False]" ] \
  && ok "H3 enroll_budget_ok with a MISSING window still enforces its ceiling (no TypeError)" \
  || bad "H3 the enroll-budget ceiling broke under a missing window (out=$PART_OUT)"

echo
echo "============================================================"
printf "cp-ratelimit (%s): %d passed, %d failed\n" "$MODE" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
