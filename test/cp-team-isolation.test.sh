#!/usr/bin/env bash
# cp-team-isolation.test.sh — THE FALSIFIABLE CROSS-TEAM ISOLATION GATE (threatmodel §1 /
# design §7), under the FIRESTORE backend, in BOTH shapes: PART 1 in-process (the deterministic
# core), PART 2 deployed real-HTTP (the cardinal cross-team leak over the wire).
#
# THE GUARANTEE. Presence is keyed by team_id = derive_team_id(team_secret) — a one-way hash,
# never a body field. Every roster read addresses exactly ONE team_id partition, where team_id
# comes from EITHER the signed member's registry binding (path b) OR the presented secret's hash
# (path a). Different secret => different team_id => different presence/<project>/<team_id>/ dir
# => a read for team A NEVER enumerates team B. THE LEAK FALSIFIER: A's roster (either path)
# containing B's haid ⇒ this test FAILS.
#
# Two secrets SA, SB; ONE project P. A enrolls+beats under SA, B under SB. Assertions (verbatim
# from the threat model):
#   1. team_id_A != team_id_B (each = derive of its own secret; high-entropy, not project-derived).
#   2. signed GET /roster as A -> contains A, NOT B; as B -> B, not A (binding-scoped, path b).
#   3. GET /roster-team -H X-Heimdall-Team-Secret:SA -> ONLY A; SB -> ONLY B (secret-hash, path a).
#   4. present team_id_A (the HASH) AS the secret -> empty (team_id is INERT, not a capability).
#   5. a random/unknown secret -> empty (no existence oracle); NO header -> 403 (outsider).
#   6. the RETIRED /roster-public -> 403 (the old fully-public leak is gone).
#   7. 409 anti-hijack: same haid, DIFFERENT pubkey -> haid_pubkey_conflict (a stolen secret can
#      never move someone else's enrolled HAID into the attacker's team).
#   8. owner=False on every self-enroll (a team secret can never mint an owner).
#   9. per-team cap (HEIMDALL_TEAM_MAX_MEMBERS) -> team_full once a team is full.
#  10. team-create GLOBAL cap -> a net-new team beyond the deployment ceiling -> 429.
#  11. default-team back-compat: a binding with no team_id reads as the default team.
#  12. boundary: gated routes are NOT public (is_public_route False).
#  13. NO secret (SA/SB) appears in ANY response body.
#
# DISCIPLINE (mirrors cp-presence-deployed / cp-roster-team-deployed): isolated throwaway home +
# EXTERNAL store dir; firestore via the emulator when available, else the faithful in-process
# fake; the PKI seed lives ONLY in memory; the serve subprocess is REAPED on EXIT; ZERO real GCP.
# Crypto-gated (the deployed beats are signed): SKIP cleanly when no cryptography|pynacl.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
CLI="$REPO/bin/heimdall-control-plane"
export LIB REPO

for f in cp_auth cp_enroll cp_presence cp_publicsurface cp_server cp_ratelimit cp_state cp_state_firestore; do
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
  echo "  SKIP no crypto backend (cryptography|pynacl) — the deployed beats are signed."
  printf "cp-team-isolation: %d passed, %d failed (SKIPPED — no crypto)\n" "$PASS" "$FAIL"
  exit 0
fi

EXT="$(mktemp -d -t "cp-teamiso.$(printf 'X%.0s' 1 2 3 4 5 6)")"
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
export HEIMDALL_FIRESTORE_ROOT="team_isolation_gate"
export HEIMDALL_FIRESTORE_PROJECT="cp-team-isolation-test"

# ── a TEST PKI seed (in memory only — never a tracked file, never printed) ──
SEED_B64="$("$PY" -c "import base64;print(base64.b64encode(bytes((i*7+3)%256 for i in range(32))).decode())")"
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
  EMU_HOST="localhost:8795"
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
echo "CROSS-TEAM ISOLATION (falsifiable) under FIRESTORE (MODE=$MODE)"
echo "  home=$HEIMDALL_HOME  root=$HEIMDALL_FIRESTORE_ROOT"
echo "============================================================"
echo

PROJECT="acme/widget"
# Two DIFFERENT high-entropy team secrets (>= 32 chars) on the SAME project.
SA="$("$PY" -c "import secrets;print(secrets.token_urlsafe(32))")"
SB="$("$PY" -c "import secrets;print(secrets.token_urlsafe(32))")"
export PROJECT SA SB

# ══════════════════════════════════════════════════════════════════════════════
# PART 1 — IN-PROCESS (the deterministic core): drive enroll/beat/roster directly.
# ══════════════════════════════════════════════════════════════════════════════
echo "PART 1 — in-process firestore: two secrets, one project, the full isolation matrix"
P1="$("$PY" - <<'PYEOF' 2>"$EXT/p1.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
# Tokenless enroll core (team_secret still required + drives team_id); the public-surface
# rate-limit caps are exercised separately below via cp_publicsurface.check_enroll.
os.environ["HEIMDALL_ENROLL_OPEN"] = "1"
import cp_auth as A, cp_enroll as E, cp_presence as P, cp_publicsurface as PS

proj = os.environ["PROJECT"]; SA = os.environ["SA"]; SB = os.environ["SB"]
out = {}

# keypairs for A and B (the private seed never leaves; only the pubkey is enrolled).
ka_priv, ka_pub = A.generate_keypair()
kb_priv, kb_pub = A.generate_keypair()
HA, HB = "haid:devA.box", "haid:devB.box"

ra = E.enroll(HA, ka_pub, provided_token=None, team_secret=SA, project=proj)
rb = E.enroll(HB, kb_pub, provided_token=None, team_secret=SB, project=proj)
out["enrollA_ok"] = bool(ra.get("ok")); out["enrollB_ok"] = bool(rb.get("ok"))
tidA = ra.get("team_id"); tidB = rb.get("team_id")
out["tidA"] = tidA; out["tidB"] = tidB
out["tid_differ"] = (tidA != tidB)
out["tidA_is_derive"] = (tidA == A.derive_team_id(SA))
out["tidB_is_derive"] = (tidB == A.derive_team_id(SB))

# owner=False on every self-enroll (a team secret can never mint an owner).
out["A_not_owner"] = (A.is_owner(HA) is False)
out["B_not_owner"] = (A.is_owner(HB) is False)

# BEAT as each — team_id is resolved from the BINDING (registered_team), never the body.
ba = P.beat_route(A.Identity(HA), {"body": json.dumps(
    {"project": proj, "handle": "alice", "verdict": "building", "file": "a.py"})})
bb = P.beat_route(A.Identity(HB), {"body": json.dumps(
    {"project": proj, "handle": "bob", "verdict": "reviewing", "file": "b.py"})})
out["beatA_team"] = ba.body.get("team_id"); out["beatB_team"] = bb.body.get("team_id")
out["beatA_to_A"] = (ba.body.get("team_id") == tidA)
out["beatB_to_B"] = (bb.body.get("team_id") == tidB)

# (path b) SIGNED-MEMBER read: A sees ONLY A; B sees ONLY B.
rosA = P.roster_route(A.Identity(HA), {"query": {"project": proj}}).body
rosB = P.roster_route(A.Identity(HB), {"query": {"project": proj}}).body
ha_in_A = [r.get("haid") for r in rosA.get("roster", [])]
hb_in_B = [r.get("haid") for r in rosB.get("roster", [])]
out["signedA_has_A"] = (HA in ha_in_A); out["signedA_no_B"] = (HB not in ha_in_A)
out["signedB_has_B"] = (HB in hb_in_B); out["signedB_no_A"] = (HA not in hb_in_B)
out["signedA_team"] = rosA.get("team_id")

# (path a) SECRET-HEADER read (public surface): SA -> only A; SB -> only B.
os.environ["HEIMDALL_PUBLIC_SURFACE"] = "1"
def team_read(secret_or_none, ip="9.9.9.1"):
    req = {"method": "GET", "route_path": "/roster-team", "query": {"project": proj}, "peer_ip": ip}
    if secret_or_none is not None:
        req["team_secret"] = secret_or_none
    return P.roster_team_route(req)

tA = team_read(SA); tB = team_read(SB)
ha_pa = [r.get("haid") for r in tA.body.get("online", [])]
hb_pa = [r.get("haid") for r in tB.body.get("online", [])]
out["headerSA_only_A"] = (ha_pa == [HA])
out["headerSB_only_B"] = (hb_pa == [HB])

# present team_id_A (the HASH) AS the secret -> wrong partition -> empty (team_id inert).
tHash = team_read(tidA)
out["hash_as_secret_empty"] = (tHash.status == 200 and tHash.body.get("online") == [])
# a random/unknown secret -> empty (no existence oracle).
import secrets as _s
tRand = team_read(_s.token_urlsafe(32))
out["random_secret_empty"] = (tRand.status == 200 and tRand.body.get("online") == [])
# NO header -> 403 (outsider).
tNone = team_read(None)
out["no_header_403"] = (tNone.status == 403)
# the RETIRED /roster-public -> 403.
rp = P.roster_public_route({"method": "GET", "route_path": "/roster-public",
                            "query": {"project": proj}, "peer_ip": "9.9.9.9"})
out["roster_public_403"] = (rp.status == 403)

# 409 anti-hijack: same haid HA, a DIFFERENT pubkey, even presenting SA -> conflict (a stolen
# secret can never move an already-enrolled HAID into the attacker team).
_, evil_pub = A.generate_keypair()
hij = E.enroll(HA, evil_pub, provided_token=None, team_secret=SA, project=proj)
out["hijack_conflict"] = (hij.get("ok") is False and hij.get("reason") == "haid_pubkey_conflict")

# per-team cap: a fresh team SC, cap=2 -> the 3rd NET-NEW haid -> team_full.
os.environ["HEIMDALL_TEAM_MAX_MEMBERS"] = "2"
SC = _s.token_urlsafe(32)
c1 = E.enroll("haid:c1", A.generate_keypair()[1], provided_token=None, team_secret=SC, project=proj)
c2 = E.enroll("haid:c2", A.generate_keypair()[1], provided_token=None, team_secret=SC, project=proj)
c3 = E.enroll("haid:c3", A.generate_keypair()[1], provided_token=None, team_secret=SC, project=proj)
out["cap_c1_ok"] = bool(c1.get("ok")); out["cap_c2_ok"] = bool(c2.get("ok"))
out["cap_c3_full"] = (c3.get("ok") is False and c3.get("reason") == "team_full")
del os.environ["HEIMDALL_TEAM_MAX_MEMBERS"]

# team-create GLOBAL cap: budget=1 -> the 2nd distinct NET-NEW team pre-auth gate -> 429.
os.environ["HEIMDALL_TEAM_CREATE_BUDGET_MAX"] = "1"
def enroll_gate(secret, ip="9.9.9.2"):
    return PS.check_enroll({"team_secret": secret, "peer_ip": ip, "body": "{}"})
g1 = enroll_gate(_s.token_urlsafe(32))      # 1st net-new team -> allowed (consumes the 1 unit)
g2 = enroll_gate(_s.token_urlsafe(32))      # 2nd net-new team -> over the global ceiling -> 429
out["create_g1_allowed"] = (g1 is None)
out["create_g2_capped"] = (isinstance(g2, tuple) and g2[0] == 429 and g2[1].get("scope") == "team_create_budget")
del os.environ["HEIMDALL_TEAM_CREATE_BUDGET_MAX"]

# default-team back-compat: a binding with NO team_id reads as the default team.
os.environ["HEIMDALL_DEFAULT_TEAM_SECRET"] = "default-team-secret-AAAAAAAAAAAAAAAAAAAA"
HD = "haid:legacy.box"
A.register_key(HD, A.generate_keypair()[1], owner=False)  # NO team_id (legacy binding)
out["default_resolves"] = (A.registered_team(HD) == A.default_team_id())
P.record_presence(HD, project=proj, team_id=A.registered_team(HD), handle="leg", verdict="x", file="y")
td = team_read(os.environ["HEIMDALL_DEFAULT_TEAM_SECRET"])
out["default_read_sees_legacy"] = (HD in [r.get("haid") for r in td.body.get("online", [])])
out["default_read_no_A"] = (HA not in [r.get("haid") for r in td.body.get("online", [])])
del os.environ["HEIMDALL_DEFAULT_TEAM_SECRET"]

# boundary: gated routes are NOT public.
out["dispatch_not_public"] = (PS.is_public_route("POST", "/dispatch") is False)
out["jobs_not_public"] = (PS.is_public_route("POST", "/jobs") is False)

# NO secret (SA/SB) appears in ANY response body we produced.
blob = json.dumps([ra, rb, ba.body, bb.body, rosA, rosB, tA.body, tB.body, hij])
out["no_secret_in_bodies"] = (SA not in blob and SB not in blob)

print(json.dumps(out))
PYEOF
)"
if [ ! -s "$EXT/p1.err" ] && [ -n "$P1" ]; then
  :
else
  bad "PART 1 python errored"; cat "$EXT/p1.err" >&2
fi
j(){ printf '%s' "$P1" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }

[ "$(j enrollA_ok)" = "True" ] && [ "$(j enrollB_ok)" = "True" ] \
  && ok "1.1 both devs enrolled (A under SA, B under SB) — tokenless, team_secret-scoped" \
  || bad "1.1 enroll failed (P1=$P1)"
[ "$(j tid_differ)" = "True" ] && [ "$(j tidA_is_derive)" = "True" ] && [ "$(j tidB_is_derive)" = "True" ] \
  && ok "1.2 team_id_A != team_id_B, each = derive_team_id(its own secret) (high-entropy, not project-derived)" \
  || bad "1.2 team_id derivation/partitioning wrong (P1=$P1)"
[ "$(j A_not_owner)" = "True" ] && [ "$(j B_not_owner)" = "True" ] \
  && ok "1.3 owner=False on every self-enroll (a team secret can NEVER mint an owner)" \
  || bad "1.3 a self-enroll granted owner (P1=$P1)"
[ "$(j beatA_to_A)" = "True" ] && [ "$(j beatB_to_B)" = "True" ] \
  && ok "1.4 each beat lands in its OWN team (team_id from the binding, never the body)" \
  || bad "1.4 a beat landed in the wrong team (P1=$P1)"
[ "$(j signedA_has_A)" = "True" ] && [ "$(j signedA_no_B)" = "True" ] \
  && ok "1.5 [path b] signed GET /roster as A -> contains A, NOT B (THE LEAK FALSIFIER)" \
  || bad "1.5 signed roster A LEAKED B or dropped A (P1=$P1)"
[ "$(j signedB_has_B)" = "True" ] && [ "$(j signedB_no_A)" = "True" ] \
  && ok "1.6 [path b] signed GET /roster as B -> contains B, NOT A" \
  || bad "1.6 signed roster B LEAKED A or dropped B (P1=$P1)"
[ "$(j headerSA_only_A)" = "True" ] && [ "$(j headerSB_only_B)" = "True" ] \
  && ok "1.7 [path a] X-Heimdall-Team-Secret SA -> ONLY A; SB -> ONLY B (mismatch either way isolates)" \
  || bad "1.7 secret-header read CROSSED teams (P1=$P1)"
[ "$(j hash_as_secret_empty)" = "True" ] \
  && ok "1.8 presenting team_id_A (the HASH) AS the secret -> empty (team_id is INERT, not a capability)" \
  || bad "1.8 team_id-as-secret was NOT inert (P1=$P1)"
[ "$(j random_secret_empty)" = "True" ] \
  && ok "1.9 a random/unknown secret -> empty (no existence oracle: idle == nonexistent)" \
  || bad "1.9 a random secret was not empty (P1=$P1)"
[ "$(j no_header_403)" = "True" ] \
  && ok "1.10 an outsider with NO secret header -> 403 (never an empty 200)" \
  || bad "1.10 a no-header read did not 403 (P1=$P1)"
[ "$(j roster_public_403)" = "True" ] \
  && ok "1.11 the RETIRED /roster-public -> 403 (the old fully-public leak is gone)" \
  || bad "1.11 /roster-public did not 403 (P1=$P1)"
[ "$(j hijack_conflict)" = "True" ] \
  && ok "1.12 409 anti-hijack: same haid + DIFFERENT pubkey + SA -> haid_pubkey_conflict (no HAID theft)" \
  || bad "1.12 a different pubkey rebind was NOT refused (P1=$P1)"
[ "$(j cap_c1_ok)" = "True" ] && [ "$(j cap_c2_ok)" = "True" ] && [ "$(j cap_c3_full)" = "True" ] \
  && ok "1.13 per-team cap (TEAM_MAX_MEMBERS=2): the 3rd net-new haid -> team_full" \
  || bad "1.13 the per-team cap did not enforce team_full (P1=$P1)"
[ "$(j create_g1_allowed)" = "True" ] && [ "$(j create_g2_capped)" = "True" ] \
  && ok "1.14 team-create GLOBAL cap (budget=1): the 2nd distinct net-new team -> 429 team_create_budget" \
  || bad "1.14 the team-create global ceiling did not trip (P1=$P1)"
[ "$(j default_resolves)" = "True" ] && [ "$(j default_read_sees_legacy)" = "True" ] && [ "$(j default_read_no_A)" = "True" ] \
  && ok "1.15 default-team back-compat: a no-team_id binding reads as the default team (and not team A)" \
  || bad "1.15 default-team back-compat broken (P1=$P1)"
[ "$(j dispatch_not_public)" = "True" ] && [ "$(j jobs_not_public)" = "True" ] \
  && ok "1.16 boundary: gated routes (/dispatch, /jobs) are NOT in the public allowlist" \
  || bad "1.16 a gated route leaked into the public allowlist (P1=$P1)"
[ "$(j no_secret_in_bodies)" = "True" ] \
  && ok "1.17 NO team_secret (SA/SB) appears in ANY response body (no-secret-by-construction)" \
  || bad "1.17 a team_secret leaked into a response body (P1=$P1)"

# ══════════════════════════════════════════════════════════════════════════════
# PART 2 — DEPLOYED real-HTTP: the cardinal cross-team leak over the wire.
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "PART 2 — deployed real-HTTP: enroll A/B over /enroll, signed beats, isolation over the socket"
export HEIMDALL_ENROLL_OPEN=1   # tokenless enroll; team_secret (header) still required + scopes.
# A DISTINCT project for Part 2 so its (project, team_id) partitions are clean of Part 1's
# in-process records (Part 1 + Part 2 share the one firestore store and reuse SA/SB; a separate
# project keeps the over-the-wire isolation read EXACT — [wireA] not [devA, wireA]).
PROJECT2="acme/wire"
export PROJECT2

# A tiny status-only HTTP probe. Prints "STATUS".
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

CP_PORT="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
HEIMDALL_PUBLIC_SURFACE=1 "$CLI" serve --host 127.0.0.1 --port "$CP_PORT" --home "$HEIMDALL_HOME" --no-revocation \
  >"$EXT/serve.out" 2>"$EXT/serve.err" &
SERVER_PID=$!
CP_URL="http://127.0.0.1:$CP_PORT"
export CP_URL CP_PORT
UP=""
for _ in $(seq 1 60); do
  [ "$(httpstat GET "$CP_URL/healthz")" = "200" ] && { UP="1"; break; }
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 0.1
done
[ -n "$UP" ] \
  && ok "2.1 the REAL public-surface server is live on $CP_URL under firestore (pid $SERVER_PID)" \
  || { bad "2.1 the public-surface server did not come up"; cat "$EXT/serve.err" >&2; }

# Enroll A and B over real HTTP (team_secret in the header), beat each (signed), then read.
P2="$("$PY" - <<'PYEOF' 2>"$EXT/p2.err"
import json, os, secrets, sys, time, urllib.parse, urllib.request, urllib.error
sys.path.insert(0, os.environ["LIB"])
import cp_auth as A
base = os.environ["CP_URL"]; proj = os.environ["PROJECT2"]
SA = os.environ["SA"]; SB = os.environ["SB"]
out = {}

def post(path, body, headers=None):
    req = urllib.request.Request(base + path, data=body.encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def get(path, headers=None):
    req = urllib.request.Request(base + path, method="GET")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

# keypairs
ka_priv, ka_pub = A.generate_keypair()
kb_priv, kb_pub = A.generate_keypair()
HA, HB = "haid:wireA.box", "haid:wireB.box"

# enroll over /enroll with the team secret in the HEADER
sa_enr, _ = post("/enroll", json.dumps({"haid": HA, "pubkey": ka_pub, "project": proj}),
                 {"X-Heimdall-Team-Secret": SA})
sb_enr, _ = post("/enroll", json.dumps({"haid": HB, "pubkey": kb_pub, "project": proj}),
                 {"X-Heimdall-Team-Secret": SB})
out["enrollA"] = sa_enr; out["enrollB"] = sb_enr

def beat(haid, priv, handle):
    body = json.dumps({"project": proj, "handle": handle, "verdict": "building",
                       "file": "x.py", "nonce": secrets.token_hex(16), "ts": time.time()})
    req = urllib.request.Request(base + "/presence", data=body.encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Heimdall-HAID", haid)
    req.add_header("X-Heimdall-Signature", A.sign(priv, A.canonical_message("POST", "/presence", body)))
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code

out["beatA"] = beat(HA, ka_priv, "alice")
out["beatB"] = beat(HB, kb_priv, "bob")

# (path a) header read: SA -> only A; SB -> only B.
def online_haids(status_body):
    st, bd = status_body
    try:
        return st, [r.get("haid") for r in json.loads(bd).get("online", [])]
    except Exception:
        return st, None

stA, hA = online_haids(get("/roster-team?" + urllib.parse.urlencode({"project": proj}),
                            {"X-Heimdall-Team-Secret": SA}))
stB, hB = online_haids(get("/roster-team?" + urllib.parse.urlencode({"project": proj}),
                            {"X-Heimdall-Team-Secret": SB}))
out["headerSA_only_A"] = (stA == 200 and hA == [HA])
out["headerSB_only_B"] = (stB == 200 and hB == [HB])

# present team_id_A (the hash) AS the secret -> empty.
tidA = A.derive_team_id(SA)
stH, hH = online_haids(get("/roster-team?" + urllib.parse.urlencode({"project": proj}),
                           {"X-Heimdall-Team-Secret": tidA}))
out["hash_as_secret_empty"] = (stH == 200 and hH == [])
# no header -> 403.
stN, _ = get("/roster-team?" + urllib.parse.urlencode({"project": proj}))
out["no_header_403"] = (stN == 403)
# RETIRED /roster-public -> 403.
stP, _ = get("/roster-public?" + urllib.parse.urlencode({"project": proj}))
out["roster_public_403"] = (stP == 403)

# (path b) SIGNED-member GET /roster as A (signed, empty body) -> only A, not B.
def signed_roster(haid, priv):
    path = "/roster?" + urllib.parse.urlencode({"project": proj})
    req = urllib.request.Request(base + path, method="GET")
    req.add_header("X-Heimdall-HAID", haid)
    req.add_header("X-Heimdall-Signature", A.sign(priv, A.canonical_message("GET", path, "")))
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status, [x.get("haid") for x in json.loads(r.read().decode()).get("roster", [])]
    except urllib.error.HTTPError as e:
        return e.code, None

stRA, rA = signed_roster(HA, ka_priv)
out["signedA_status"] = stRA
out["signedA_has_A"] = bool(rA is not None and HA in rA)
out["signedA_no_B"] = bool(rA is not None and HB not in rA)

# NO secret in any wire body.
blob = json.dumps([get("/roster-team?" + urllib.parse.urlencode({"project": proj}),
                       {"X-Heimdall-Team-Secret": SA})[1]])
out["no_secret_in_body"] = (SA not in blob and SB not in blob)
print(json.dumps(out))
PYEOF
)"
if [ -s "$EXT/p2.err" ]; then cat "$EXT/p2.err" >&2; fi
k(){ printf '%s' "$P2" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }

[ "$(k enrollA)" = "200" ] && [ "$(k enrollB)" = "200" ] \
  && ok "2.2 A enrolled under SA + B under SB over /enroll (team_secret in the header) -> 200" \
  || bad "2.2 the HTTP enroll failed (P2=$P2)"
[ "$(k beatA)" = "200" ] && [ "$(k beatB)" = "200" ] \
  && ok "2.3 each dev's signed beat was accepted (POST /presence, sig+nonce verified)" \
  || bad "2.3 a signed beat was rejected (P2=$P2)"
[ "$(k headerSA_only_A)" = "True" ] && [ "$(k headerSB_only_B)" = "True" ] \
  && ok "2.4 [wire, path a] SA -> ONLY A; SB -> ONLY B (THE CROSS-TEAM LEAK FALSIFIER over HTTP) [CARDINAL]" \
  || bad "2.4 the secret-header read CROSSED teams over the wire (P2=$P2)"
[ "$(k signedA_status)" = "200" ] && [ "$(k signedA_has_A)" = "True" ] && [ "$(k signedA_no_B)" = "True" ] \
  && ok "2.5 [wire, path b] signed GET /roster as A -> contains A, NOT B (binding-scoped over HTTP)" \
  || bad "2.5 the signed roster leaked B or dropped A over the wire (P2=$P2)"
[ "$(k hash_as_secret_empty)" = "True" ] \
  && ok "2.6 [wire] team_id_A AS the secret -> empty (team_id INERT over the wire)" \
  || bad "2.6 team_id-as-secret was not inert over the wire (P2=$P2)"
[ "$(k no_header_403)" = "True" ] \
  && ok "2.7 [wire] NO secret header -> 403 (outsider sees nothing over the wire)" \
  || bad "2.7 a no-header read did not 403 over the wire (P2=$P2)"
[ "$(k roster_public_403)" = "True" ] \
  && ok "2.8 [wire] the RETIRED /roster-public -> 403 (old fully-public leak closed over HTTP)" \
  || bad "2.8 /roster-public did not 403 over the wire (P2=$P2)"
[ "$(k no_secret_in_body)" = "True" ] \
  && ok "2.9 [wire] NO team_secret appears in any response body" \
  || bad "2.9 a team_secret leaked into a wire body (P2=$P2)"

# ── FOOTER — reap the serve subprocess ──
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
printf "cp-team-isolation (%s): %d passed, %d failed\n" "$MODE" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
