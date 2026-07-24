#!/usr/bin/env bash
# cp-god-session-isolation.test.sh — the REAL cp-level proof that the python control plane
# ENFORCES the INV-LOGIN (L1-L5) + INV-GOD (G1-G4) invariants the rr-multitenant-isolation
# oracle MODELS. The oracle (evals/oracles/rr-multitenant-isolation) grades a JS model; THIS
# gate drives the actual cp_session + cp_god + cp_server handlers against each attack, so the
# python is proven to enforce what the oracle asserts — not merely that the model is faithful.
#
# The nine attacks, every one expected DENIED by the real handlers:
#   L1 session-cross-team    — a team-A session naming body/query team_id=B reads only A.
#   L2 tampered-session-teamids — a mint carrying a client teams=[A,B] mints teams=[A] only.
#   L3 expired-session       — an expired CP-signed token -> 401 before any roster read.
#   L4 bad-signature-mint    — an approve with a forged HAID signature -> 401, NO session.
#   L5 session-is-owner      — a session Identity (owner=false) fails the owner gate; mint
#                              is always owner=false.
#   G1/G2 god-on-public      — /god/* is never in PUBLIC_ROUTES + registered AUTHENTICATED
#                              (not public), so the public surface 404s it for anon + secret.
#   G3 nonowner-god          — a signed NON-owner Identity against /god/roster -> 401 not_owner.
#   G4 god-cross-partition   — the god aggregate ignores a forged body/query team_id and
#                              enumerates partitions SERVER-SIDE.
#
# Plus a DEPLOYED-SHAPE proof: every aggregate is re-run against a fake StateBackend whose
# path() RAISES (exactly like FirestoreBackend) — a handler that reached for backend.path()
# would crash, proving the firestore-safe read discipline (list_names/get_record only).
#
# stdlib-only python, LOCAL backend for the deterministic attack matrix + an in-process fake
# firestore backend for the deployed-shape check. ZERO real GCP. Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"

for f in cp_session cp_god cp_server cp_auth cp_presence cp_publicsurface cp_state cp_audit cp_approval; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

HOME_T="$(mktemp -d -t cp-god-session.XXXXXX)"
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT

export LIB REPO HOME_T

HEIMDALL_HOME="$HOME_T" "$PY" - <<'PYEOF'
import os, sys, time, json

sys.path.insert(0, os.environ["LIB"])
HOME = os.environ["HOME_T"]

import cp_auth, cp_state, cp_presence, cp_audit, cp_approval, cp_server, cp_session, cp_god
import cp_publicsurface

PASS = 0
FAIL = 0
def ok(m):
    global PASS; PASS += 1; print("  \033[32mPASS\033[0m " + m)
def bad(m):
    global FAIL; FAIL += 1; print("  \033[31mFAIL\033[0m " + m)
def check(cond, m):
    ok(m) if cond else bad(m)

# ── the CP signing seed (deterministic session-token identity) ──────────────────────────
cp_priv, cp_pub = cp_auth.generate_keypair()
os.environ["HEIMDALL_CP_PKI_KEY"] = cp_priv

# ── two enrolled tenants + one owner, bound in the key registry (server-derived teams) ──
TID_A = "aaaa0000aaaa0000aaaa0000aaaa0000"
TID_B = "bbbb1111bbbb1111bbbb1111bbbb1111"
FORGED = "cccc2222cccc2222cccc2222cccc2222"
PROJ_A = "alice/webapp"
PROJ_B = "bob/service"

priv_a, pub_a = cp_auth.generate_keypair()
priv_b, pub_b = cp_auth.generate_keypair()
priv_o, pub_o = cp_auth.generate_keypair()
HAID_A = "haid:alice"
HAID_B = "haid:bob"
HAID_O = "haid:owner"

cp_auth.register_key(HAID_A, pub_a, owner=False, team_id=TID_A, project=PROJ_A, home=HOME)
cp_auth.register_key(HAID_B, pub_b, owner=False, team_id=TID_B, project=PROJ_B, home=HOME)
cp_auth.register_key(HAID_O, pub_o, owner=True, home=HOME)

# server-derived team binding sanity (the INV-1 basis L2/L1 lean on)
check(cp_auth.registered_team(HAID_A, home=HOME) == TID_A, "setup: registered_team(alice)=A")
check(cp_auth.registered_team(HAID_B, home=HOME) == TID_B, "setup: registered_team(bob)=B")

# ── seed presence: A online in PROJ_A, B online in PROJ_B ───────────────────────────────
now = time.time()
cp_presence.record_presence(HAID_A, project=PROJ_A, team_id=TID_A, handle="alice",
                            verdict="PROVEN", file="app.py", home=HOME, ts=now)
cp_presence.record_presence(HAID_B, project=PROJ_B, team_id=TID_B, handle="bob",
                            verdict="PROVEN", file="svc.go", home=HOME, ts=now)

# ── seed the §9 audit log (cross-team activity for /god/logs) ────────────────────────────
cp_audit.write("approval", actor_haid=HAID_O, action_type="run-suite", decision="approved",
               outcome="ok", home=HOME)
cp_audit.write("dispatch", actor_haid=HAID_A, action_type="fix-issue", outcome="ok", home=HOME)
cp_audit.write("job_state", actor_haid=HAID_B, action_type="fix-issue", outcome="ok", home=HOME)
cp_audit.write("auth_fail", actor_haid="haid:intruder", outcome="refused", home=HOME)

def signed_assertion(haid, priv, gh_user, device_code, nonce):
    msg = cp_session.assertion_message(haid, gh_user, device_code, nonce)
    return cp_auth.sign(priv, msg)

def approve_body(haid, gh_user, device_code, nonce, sig, **extra):
    body = {"haid": haid, "gh_user": gh_user, "device_code": device_code,
            "nonce": nonce, "sig": sig}
    body.update(extra)
    return {"body": json.dumps(body).encode("utf-8")}

# ════════════════════════════════════════════════════════════════════════════════════════
# INV-LOGIN
# ════════════════════════════════════════════════════════════════════════════════════════

# ── L4 — a forged HAID signature at approve mints NO session ─────────────────────────────
r = cp_session.init_route({"body": b""}, home=HOME)
dc = r.body["device_code"]
r_bad = cp_session.approve_route(
    approve_body(HAID_A, "alice-gh", dc, "n-1", "forged-signature-not-valid"), home=HOME)
check(r_bad.status == 401, "L4: forged-signature approve -> 401 (%s)" % r_bad.status)
rec = cp_session._load_session(dc, home=HOME)
check(rec.get("status") == "pending", "L4: device_code stays pending (no session minted)")

# a VALID signature DOES mint (positive control — the gate is real, not always-deny)
good_sig = signed_assertion(HAID_A, priv_a, "alice-gh", dc, "n-1")
r_good = cp_session.approve_route(
    approve_body(HAID_A, "alice-gh", dc, "n-1", good_sig), home=HOME)
check(r_good.status == 200 and r_good.body.get("status") == "ready",
      "L4 control: valid signature approve -> ready")

# ── L2 — a mint carrying a client teams=[A,B] mints teams=[A] only ──────────────────────
r2 = cp_session.init_route({"body": b""}, home=HOME)
dc2 = r2.body["device_code"]
sig2 = signed_assertion(HAID_A, priv_a, "alice-gh", dc2, "n-2")
cp_session.approve_route(
    approve_body(HAID_A, "alice-gh", dc2, "n-2", sig2,
                 teams=[TID_A, TID_B], team_id=TID_B), home=HOME)
status2 = cp_session.status_route(
    {"query": {"device_code": dc2}}, home=HOME)
tok2 = status2.body["token"]
payload2, reason2 = cp_session.verify_token(tok2)
check(payload2 is not None and payload2["teams"] == [TID_A],
      "L2: tampered teams=[A,B] -> session teams=[A] only (%s)" % (payload2 or {}).get("teams"))
check(TID_B not in (payload2 or {}).get("teams", []),
      "L2: injected team B never enters the session")

# ── L1 — a valid team-A session naming body/query team_id=B reads ONLY A ─────────────────
token_a, _ = cp_session.mint_token(HAID_A, [TID_A], "alice-gh")
req_l1 = {
    "authorization": "Bearer " + token_a,
    "query": {"team_id": TID_B},
    "body": json.dumps({"team_id": TID_B}).encode("utf-8"),
    "path": "/dashboard/rosters?team_id=" + TID_B,
}
r_l1 = cp_session.rosters_route(req_l1, home=HOME)
teams_seen = [t["team_id"] for t in r_l1.body["teams"]]
check(r_l1.status == 200 and teams_seen == [TID_A],
      "L1: team-A session + body/query team_id=B reads only A (%s)" % teams_seen)
check(TID_B not in teams_seen, "L1: team B invisible to the team-A session")

# ── L3 — an expired CP-signed token -> 401 before any read ──────────────────────────────
past = time.time() - 10
expired_tok, _ = cp_session.mint_token(HAID_A, [TID_A], "alice-gh", exp=int(past))
r_l3 = cp_session.rosters_route({"authorization": "Bearer " + expired_tok}, home=HOME)
check(r_l3.status == 401 and r_l3.body.get("error") == "expired",
      "L3: expired session -> 401 expired (%s/%s)" % (r_l3.status, r_l3.body.get("error")))
# a live token still reads (positive control)
r_l3c = cp_session.rosters_route({"authorization": "Bearer " + token_a}, home=HOME)
check(r_l3c.status == 200, "L3 control: a live token reads (200)")

# ── L5 — a login session is ALWAYS owner=false; it fails the owner gate ──────────────────
_, mint_payload = cp_session.mint_token(HAID_A, [TID_A], "alice-gh")
check(mint_payload["owner"] is False, "L5: minted session owner is always False")
session_identity = cp_auth.Identity(HAID_A, owner=False)  # exactly what a session confers.
r_l5 = cp_god.roster_route(session_identity, {}, home=HOME)
check(r_l5.status == 401 and r_l5.body.get("error") == "not_owner",
      "L5: session identity (owner=false) fails the god owner gate -> 401 not_owner")

# ════════════════════════════════════════════════════════════════════════════════════════
# INV-GOD
# ════════════════════════════════════════════════════════════════════════════════════════

# register the extended routes against the live seam (as serve() does)
reg = cp_server.register_extended_routes(home=HOME)

# ── G1/G2 — /god/* is NEVER on the public allowlist + registered AUTHENTICATED ───────────
check(not cp_publicsurface.is_public_route("GET", "/god/roster"),
      "G1/G2: (GET,/god/roster) not in PUBLIC_ROUTES")
check(not cp_publicsurface.is_public_route("GET", "/god/logs"),
      "G1/G2: (GET,/god/logs) not in PUBLIC_ROUTES")
check(("GET", "/god/roster") in cp_server._ROUTES
      and ("GET", "/god/roster") not in cp_server._PUBLIC_ROUTES,
      "G1/G2: /god/roster registered AUTHENTICATED, not pre-auth public")
check(("GET", "/god/logs") in cp_server._ROUTES
      and ("GET", "/god/logs") not in cp_server._PUBLIC_ROUTES,
      "G1/G2: /god/logs registered AUTHENTICATED, not pre-auth public")
# the exact routing-layer boundary decision the public surface makes: not-public => 404.
public_would_404 = (cp_publicsurface.public_surface_enabled(env={"HEIMDALL_PUBLIC_SURFACE": "1"})
                    and not cp_publicsurface.is_public_route("GET", "/god/roster"))
check(public_would_404, "G1/G2: on the public surface the boundary 404s /god/roster")

# ── G3 — a signed NON-owner identity -> 401 not_owner; the owner passes ──────────────────
r_g3 = cp_god.roster_route(cp_auth.Identity(HAID_A, owner=False), {}, home=HOME)
check(r_g3.status == 401 and r_g3.body.get("error") == "not_owner",
      "G3: signed non-owner -> 401 not_owner")
r_g3o = cp_god.roster_route(cp_auth.Identity(HAID_O, owner=True), {}, home=HOME)
check(r_g3o.status == 200, "G3 control: owner -> 200")

# ── G4 — the god aggregate ignores a forged body/query team_id, enumerates server-side ──
forged_req = {
    "query": {"team_id": FORGED},
    "body": json.dumps({"team_id": FORGED}).encode("utf-8"),
    "path": "/god/roster?team_id=" + FORGED,
}
r_g4 = cp_god.roster_route(cp_auth.Identity(HAID_O, owner=True), forged_req, home=HOME)
god_team_ids = sorted({t["team_id"] for t in r_g4.body["teams"]})
check(FORGED not in god_team_ids, "G4: forged wire team_id absent from god roster")
check(god_team_ids == sorted([TID_A, TID_B]),
      "G4: god roster enumerated server-side = {A,B} (%s)" % god_team_ids)
# the aggregate actually crosses tenants (not empty-by-accident): both teams' devs are present
onl = {t["team_id"]: [m["haid"] for m in t["online"]] for t in r_g4.body["teams"]}
check(onl.get(TID_A) == [HAID_A] and onl.get(TID_B) == [HAID_B],
      "G4 control: god roster folds BOTH tenants' online members")

# ── G4 (logs) — /god/logs ignores a forged team_id, aggregates cross-team ───────────────
r_g4l = cp_god.logs_route(cp_auth.Identity(HAID_O, owner=True), forged_req, home=HOME)
enroll_teams = sorted({e["team_id"] for e in r_g4l.body["enrollments"]})
check(FORGED not in enroll_teams, "G4(logs): forged team_id absent from enrollments")
check(TID_A in enroll_teams and TID_B in enroll_teams,
      "G4(logs): enrollments enumerated server-side from the registry (A+B)")
verdict_events = {v["event"] for v in r_g4l.body["verdicts"]}
run_events = {v["event"] for v in r_g4l.body["runs"]}
sec_events = {v["event"] for v in r_g4l.body["security"]}
check("approval" in verdict_events, "G4(logs): gate verdicts include approval rows")
check(run_events >= {"dispatch", "job_state"}, "G4(logs): run outcomes include dispatch+job_state")
check("auth_fail" in sec_events, "G4(logs): security signals include auth_fail")

# ════════════════════════════════════════════════════════════════════════════════════════
# DEPLOYED-SHAPE — every aggregate must serve under a backend whose path() RAISES
# (exactly like FirestoreBackend); a handler that reached for backend.path() would crash.
# ════════════════════════════════════════════════════════════════════════════════════════

class FakeFirestore(cp_state.StateBackend):
    """An in-process StateBackend modeling the DEPLOYED firestore shape: keyed records +
    NDJSON in memory, nested-child list_names (first segment after the dir prefix), and a
    path() that RAISES BackendUnavailable — the exact firestore-only read-path failure mode."""
    def __init__(self):
        self.recs = {}
        self.lines = {}
    def put_record(self, rel, record):
        self.recs[rel] = json.loads(json.dumps(record)); return True
    def get_record(self, rel):
        return json.loads(json.dumps(self.recs[rel])) if rel in self.recs else None
    def put_record_if(self, rel, record, expected_rev):
        return self.put_record(rel, record)
    def append_line(self, rel, record, *, fsync=False):
        self.lines.setdefault(rel, []).append(json.loads(json.dumps(record))); return True
    def read_lines(self, rel):
        return [json.loads(json.dumps(r)) for r in self.lines.get(rel, [])]
    def exists(self, rel):
        keys = list(self.recs) + list(self.lines)
        return rel in self.recs or rel in self.lines or any(k.startswith(rel + "/") for k in keys)
    def path(self, rel):
        raise cp_state.BackendUnavailable("fake firestore has no path for %r" % rel)
    def list_names(self, rel_dir, *, suffix=""):
        prefix = rel_dir.rstrip("/") + "/"
        names = set()
        for k in list(self.recs) + list(self.lines):
            if not k.startswith(prefix):
                continue
            rest = k[len(prefix):]
            head, sep, _tail = rest.partition("/")
            if sep:
                if suffix:
                    continue
                names.add(head)
            else:
                if suffix and not rest.endswith(suffix):
                    continue
                names.add(rest)
        return sorted(names)

FAKE = FakeFirestore()
_orig_get_backend = cp_state.get_backend
cp_state.get_backend = lambda home=None, backend=None, namespace=None: FAKE
try:
    # re-seed the durable state into the firestore-shaped backend
    cp_auth.register_key(HAID_A, pub_a, owner=False, team_id=TID_A, project=PROJ_A)
    cp_auth.register_key(HAID_B, pub_b, owner=False, team_id=TID_B, project=PROJ_B)
    cp_auth.register_key(HAID_O, pub_o, owner=True)
    cp_presence.record_presence(HAID_A, project=PROJ_A, team_id=TID_A, handle="alice", ts=now)
    cp_presence.record_presence(HAID_B, project=PROJ_B, team_id=TID_B, handle="bob", ts=now)

    # god roster + logs serve without touching path()
    rr = cp_god.roster_route(cp_auth.Identity(HAID_O, owner=True), {})
    ds_ids = sorted({t["team_id"] for t in rr.body["teams"]})
    check(rr.status == 200 and ds_ids == sorted([TID_A, TID_B]),
          "deployed-shape: god roster cross-enumerates under firestore-path()-raising backend")
    rl = cp_god.logs_route(cp_auth.Identity(HAID_O, owner=True), {})
    check(rl.status == 200 and {e["team_id"] for e in rl.body["enrollments"]} >= {TID_A, TID_B},
          "deployed-shape: god logs enrollments enumerate under firestore backend")

    # session rosters read serves under firestore too (token minted from env seed)
    tok_ds, _ = cp_session.mint_token(HAID_A, [TID_A], "alice-gh")
    rs = cp_session.rosters_route({"authorization": "Bearer " + tok_ds})
    ds_teams = [t["team_id"] for t in rs.body["teams"]]
    check(rs.status == 200 and ds_teams == [TID_A],
          "deployed-shape: session rosters read scopes to A under firestore backend")
finally:
    cp_state.get_backend = _orig_get_backend

print()
print("cp-god-session-isolation: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PYEOF
rc=$?
if [ "$rc" -eq 0 ]; then
  printf "\n\033[32mALL PROOFS HELD\033[0m — cp_session + cp_god enforce INV-LOGIN + INV-GOD\n"
else
  printf "\n\033[31mFAILURES\033[0m — see above\n"
fi
exit $rc
