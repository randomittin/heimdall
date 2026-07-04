#!/usr/bin/env bash
# cp-rr-enqueue-drain.test.sh — THE PUBLIC-ENQUEUE ↔ GATED-DRAIN ROUND-TRIP GATE.
#
# THE INCIDENT THIS GATES (production Cloud Run, 2026-07-04). A task enqueued via the
# PUBLIC surface (POST /rr-task → cp_publicsurface.enqueue_rr_task → cp_team_queue.enqueue,
# under the caller's SERVER-DERIVED team_id partition teamq/<team_id>/queue.json) never
# reached the GATED drain's pick pool. The gated per-minute tick logged
#     drain cycle: teams_scanned=1 dispatched=0 retried=0 dead=0
#     drain team=<t> processed=0 ...
# i.e. the drain RAN, enumerated ONE team, but pick() returned NOTHING. Root cause: the
# drain (cp_maintainer_runner.drain_all_team_queues) enumerated ONLY the teams with a bound
# GitHub App installation (cp_ghinstall.known_team_ids) — the INSTALL set. A task whose
# enqueue-derived team_id is NOT in that install set is written to its OWN queue partition
# (teamq/<that_id>/queue.json) that the drain NEVER sweeps: a write-here / read-there gap.
# The queue key + Firestore doc path are already identical for a given team_id (proven
# below); the defect was purely ENUMERATION SCOPE — the drain looked in the install set for
# a partition the enqueue wrote under a team the install set did not contain.
#
# THE FIX (this gate locks it): drain_all_team_queues enumerates the UNION of the install
# teams AND the teams that actually HAVE a queued partition (cp_team_queue.known_team_ids),
# so EVERY partition that received a /rr-task write is swept. A queued-but-not-yet-installed
# team is enumerated + SKIPped gracefully (no_covered_repo — the task waits, VISIBLE + LOUD,
# never stranded); once an install binds, the SAME queued task drains and is PICKED.
#
# DEPLOYED-SHAPE + FIRESTORE-MODE AWARE. The whole round-trip runs under
# HEIMDALL_STATE_BACKEND=firestore (the prod backend) against the SAME faithful in-process
# google.cloud.firestore double the cp-durability / cp-flow-firestore gates use — the SHIPPED
# backend code (rel→doc encoding, put_record/get_record, list_names) is REAL; only the
# external Firestore service is a double persisting to one shared JSON store, exactly modeling
# the two-service split (public writer + gated reader hit ONE external store). ZERO real GCP.
#
# FALSIFIABLE claims proven:
#   (1) ROUND-TRIP  — a task enqueued by the PUBLIC enqueue_rr_task path for an INSTALLED
#                     team T is PICKED by the gated drain for T (its id lands in a drain
#                     outcome's task_ids), across the SAME firestore backend.
#   (2) ENUMERATION — a task enqueued for a team with NO install is STILL enumerated by the
#                     drain (cp_team_queue.known_team_ids includes it AND drain_all_team_queues
#                     returns an outcome for it). PRE-FIX this team is invisible (the bug).
#   (3) RECOVERY    — once that team binds an install, the SAME queued task then DRAINS and is
#                     PICKED (the enqueue-then-install operator flow completes).
#   (4) ISOLATION   — draining team T NEVER picks a task from another team's partition
#                     (the no-install team's task id never appears in T's outcome — INV-2).
#
# Exit 0 = all four hold. Nonzero = the gate failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB

for f in cp_team_queue cp_ghinstall cp_auth cp_publicsurface cp_maintainer_runner \
         cp_state cp_state_firestore; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

EXT="$(mktemp -d -t "cp-rr-enqdrain.$(printf 'X%.0s' 1 2 3 4 5 6)")"
cleanup() { rm -rf "$EXT"; }
trap cleanup EXIT

# ── the faithful in-process FAKE google.cloud.firestore (the SAME slice the cp-durability /
#    cp-flow-firestore gates use), persisting to one shared JSON store so the public writer
#    and gated reader share ONE external store — the deployed two-service shape. ──
FAKEPKG="$EXT/pylib"
mkdir -p "$FAKEPKG"
cat >"$FAKEPKG/_fake_firestore_impl.py" <<'PYEOF'
# Faithful in-process FAKE of the slice of google.cloud.firestore that
# cp_state_firestore.FirestoreBackend actually uses. PERSISTS the whole store to the JSON
# file named by HEIMDALL_FAKE_FS_STORE so reads after a write share one durable store.
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
    def __init__(self, project=None):
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
: >"$HEIMDALL_FAKE_FS_STORE"
export PYTHONPATH="$FAKEPKG${PYTHONPATH:+:$PYTHONPATH}"

# The prod backend profile (the deployed shape that broke) + the multi-tenant drain flag.
export HEIMDALL_STATE_BACKEND="firestore"
export HEIMDALL_FIRESTORE_ROOT="heimdall_cp"
export HEIMDALL_FIRESTORE_PROJECT="cp-rr-enqdrain-test"
export HEIMDALL_RR_TENANT_AUTHZ="1"
export HEIMDALL_HOME="$EXT/home"
mkdir -p "$HEIMDALL_HOME"

echo "cp-rr-enqueue-drain: MODE=firestore-fake  (shared external store: $HEIMDALL_FAKE_FS_STORE)"
echo

DRIVER="$EXT/driver.py"
cat >"$DRIVER" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["LIB"])

import cp_auth
import cp_ghinstall
import cp_maintainer_runner
import cp_publicsurface
import cp_team_queue


class Ident:
    def __init__(self, haid):
        self.haid = haid


def enqueue_public(haid, text):
    """Drive the REAL public /rr-task enqueue handler for a signed caller (haid)."""
    body = json.dumps({"task": text, "nonce": "n-%s" % haid, "ts": 1})
    return cp_publicsurface.enqueue_rr_task(Ident(haid), {"body": body})


# ── two tenants, both enrolled with a team binding (as /enroll's register_key does) ──
INSTALLED_SECRET = "team-installed-secret"
QUEUEONLY_SECRET = "team-queue-only-secret"
T_INSTALLED = cp_auth.derive_team_id(INSTALLED_SECRET)
T_QUEUEONLY = cp_auth.derive_team_id(QUEUEONLY_SECRET)

cp_auth.register_key("haid:installed-member", "cHVia2V5", team_id=T_INSTALLED, project="p")
cp_auth.register_key("haid:queueonly-member", "cHVia2V5", team_id=T_QUEUEONLY, project="p")

# The INSTALLED team binds a GitHub App installation covering its repo (POST /team/install).
cp_ghinstall.set_team_installation(T_INSTALLED, 111, ["acme/installed"])
# The QUEUE-ONLY team binds NOTHING — it will enqueue with no install (the bug scenario).

# ── ENQUEUE via the PUBLIC surface for BOTH teams (server-derives each team_id) ──
r1 = enqueue_public("haid:installed-member", "fix the flaky login test")
r2 = enqueue_public("haid:queueonly-member", "run the migration audit")

# ── FIRST DRAIN (gated) — the union enumeration must sweep BOTH partitions ──
d1 = cp_maintainer_runner.drain_all_team_queues(base_env={})

# ── bind an install for the queue-only team, then DRAIN AGAIN (recovery) ──
cp_ghinstall.set_team_installation(T_QUEUEONLY, 222, ["acme/queueonly"])
d2 = cp_maintainer_runner.drain_all_team_queues(base_env={})

# ── cp_team_queue partition enumeration (the new enumeration source) ──
tq_known = cp_team_queue.known_team_ids()


def outcome_for(drains, team_id):
    for d in drains:
        if d.get("team_id") == team_id:
            return d
    return None


def all_task_ids(drains):
    out = []
    for d in drains:
        out.extend(d.get("task_ids") or [])
    return out


installed_out_d1 = outcome_for(d1, T_INSTALLED)
queueonly_out_d1 = outcome_for(d1, T_QUEUEONLY)
queueonly_out_d2 = outcome_for(d2, T_QUEUEONLY)

result = {
    "enqueue_installed": [r1[0], r1[1].get("id"), r1[1].get("team_id")],
    "enqueue_queueonly": [r2[0], r2[1].get("id"), r2[1].get("team_id")],
    "t_installed": T_INSTALLED,
    "t_queueonly": T_QUEUEONLY,
    "tq_known_includes_queueonly": T_QUEUEONLY in tq_known,
    "tq_known_includes_installed": T_INSTALLED in tq_known,
    # (1) round-trip: the installed team's task is PICKED by the drain (in its task_ids).
    "installed_task_picked": bool(
        installed_out_d1 and r1[1].get("id") in (installed_out_d1.get("task_ids") or [])),
    # (2) enumeration: the queue-only team is ENUMERATED by the drain (has an outcome).
    "queueonly_enumerated_d1": queueonly_out_d1 is not None,
    "queueonly_reason_d1": (queueonly_out_d1 or {}).get("reason"),
    # (3) recovery: after the install binds, the SAME task is PICKED on the next drain.
    "queueonly_task_picked_d2": bool(
        queueonly_out_d2 and r2[1].get("id") in (queueonly_out_d2.get("task_ids") or [])),
    # (4) isolation: the queue-only task NEVER appears under the installed team's outcome.
    "installed_outcome_excludes_queueonly_task": bool(
        installed_out_d1 is not None
        and r2[1].get("id") not in (installed_out_d1.get("task_ids") or [])),
    # cross-check: a direct pick of the installed partition never returns the other's task.
    "direct_pick_isolation": (
        r2[1].get("id") not in [
            (t or {}).get("id") for t in [cp_team_queue.pick(T_INSTALLED)] if t]),
}
print("RESULT " + json.dumps(result))
PYEOF

OUT="$("$PY" "$DRIVER" 2>"$EXT/driver.err")"
RC=$?
echo "driver: $OUT"
[ -s "$EXT/driver.err" ] && { echo "  driver stderr:"; sed 's/^/    /' "$EXT/driver.err"; }
echo

if [ "$RC" -ne 0 ] || ! printf '%s' "$OUT" | grep -q "^RESULT "; then
  bad "the driver did not complete (rc=$RC) — see stderr above"
  echo
  echo "cp-rr-enqueue-drain: $PASS passed, $FAIL failed"
  exit 1
fi

JSON="${OUT#RESULT }"
field() { printf '%s' "$JSON" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))"; }

# ── (0) both enqueues succeeded (200) via the PUBLIC handler ──
[ "$(field enqueue_installed | grep -o '^\[200' )" = "[200" ] 2>/dev/null || true
if printf '%s' "$JSON" | grep -q '"enqueue_installed": \[200'; then
  ok "0a PUBLIC enqueue_rr_task(installed) → 200 (server-derived team partition)"
else
  bad "0a installed enqueue did not return 200: $(field enqueue_installed)"
fi
if printf '%s' "$JSON" | grep -q '"enqueue_queueonly": \[200'; then
  ok "0b PUBLIC enqueue_rr_task(queue-only) → 200 (server-derived team partition)"
else
  bad "0b queue-only enqueue did not return 200: $(field enqueue_queueonly)"
fi

# ── (1) ROUND-TRIP — the installed team's task is PICKED by the gated drain ──
if [ "$(field installed_task_picked)" = "True" ]; then
  ok "1 round-trip: the installed team's /rr-task enqueue is PICKED by the gated drain (same firestore backend)"
else
  bad "1 the installed team's task was NOT picked by the drain (write-here/read-there)"
fi

# ── (2) ENUMERATION FIX — the queue-only team is swept even with NO install ──
if [ "$(field tq_known_includes_queueonly)" = "True" ]; then
  ok "2a cp_team_queue.known_team_ids() enumerates the queued-but-uninstalled team's partition"
else
  bad "2a cp_team_queue.known_team_ids() MISSED the queue-only partition (the enumeration gap)"
fi
if [ "$(field queueonly_enumerated_d1)" = "True" ]; then
  ok "2b drain_all_team_queues() enumerates the queue-only team (union of install + queue partitions)"
else
  bad "2b the queue-only team was INVISIBLE to the drain (the prod incident: teams_scanned missed it)"
fi
if [ "$(field queueonly_reason_d1)" = "no_covered_repo" ]; then
  ok "2c the queue-only team SKIPs gracefully (no_covered_repo) — task preserved, VISIBLE + LOUD, not stranded"
else
  bad "2c the queue-only team's drain outcome was not the graceful no_covered_repo skip: $(field queueonly_reason_d1)"
fi

# ── (3) RECOVERY — once the install binds, the SAME queued task drains + is PICKED ──
if [ "$(field queueonly_task_picked_d2)" = "True" ]; then
  ok "3 recovery: after the install binds, the SAME queued task is PICKED (enqueue-then-install flow completes)"
else
  bad "3 the queued task did not drain after its install bound (recovery broken)"
fi

# ── (4) ISOLATION (falsifier) — a partition's task is never picked under another team ──
if [ "$(field installed_outcome_excludes_queueonly_task)" = "True" ]; then
  ok "4a isolation: the queue-only task NEVER appears under the installed team's drain outcome (INV-2)"
else
  bad "4a a task LEAKED across partitions in the drain (INV-2 isolation breach)"
fi
if [ "$(field direct_pick_isolation)" = "True" ]; then
  ok "4b isolation: a direct pick(installed) never returns the other team's task (partition boundary holds)"
else
  bad "4b pick() crossed the partition boundary (INV-2 breach)"
fi

echo
echo "============================================================"
echo "cp-rr-enqueue-drain: $PASS passed, $FAIL failed"
echo "  round-trip · enumeration-union · recovery · isolation — all under firestore"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
