#!/usr/bin/env bash
# heimdall-cp-autoteam.test.sh — the POST /team/auto handler: ZERO-TOUCH auto-initiate + auto-join
# (design §3; oracle INV-AUTOTEAM rows AT1-AT5). Wave-2 COMPOSITION test — it drives the REAL
# cp_autoteam.auto_team / auto_team_route against the REAL cp_repoteam + cp_ghverify primitives
# with a FAKE GitHub chokepoint + a FAKE gh-app-token minter + a LocalBackend under an isolated
# HEIMDALL_HOME. Zero real GitHub creds, zero network.
#
# THE GUARANTEE, mapped to the AT rows:
#   AT2  a forged gh identity (claim a real collaborator, fail the GET /user re-derive) -> 401.
#   AT3  a WIRE team_id in the body is IGNORED — the team is server-resolved from the repo binding.
#   AT1  a non-collaborator join is DENIED (403) — no binding written.
#   AT4  a PUBLIC repo read-only drive-by join is DENIED (403) — the world can't join the wall.
#   AT5  a non-admin caller cannot AUTO-INITIATE an unbound repo (403).
#   happy INITIATE (admin/push) mints a server-derived team + binds the enrolled HAID (mode
#     initiated); happy JOIN (a collaborator) binds to the SAME team (mode joined); a second
#     initiate on the now-bound repo CONVERGES on that one team (no double-mint).
#   enroll-then-autojoin: an UNENROLLED HAID (no registered pubkey) is refused enroll_required.
#   the abuse gate check_autoteam sheds a per-IP flood (429).
#   transit-only: the forwarded gh token + minted installation token are USED but never persist.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

for f in cp_autoteam cp_repoteam cp_ghverify cp_ghinstall cp_auth cp_state cp_allowlist cp_publicsurface cp_ratelimit; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

# AT6 (key-possession) VERIFIES real Ed25519 signatures, so every bind path now needs a crypto
# backend (cryptography/pynacl). Absent one, cp_auth.verify fail-closes crypto_unavailable and NO
# bind can succeed — the whole hermetic driver is meaningless. Detect + SKIP cleanly (exit 0),
# mirroring heimdall-presence-autoteam's CRYPTO gate.
CRYPTO="$("$PY" -c "import sys;sys.path.insert(0,'$LIB');import cp_auth;print('1' if cp_auth.crypto_available() else '0')" 2>/dev/null || echo 0)"
if [ "$CRYPTO" != "1" ]; then
  echo "SKIP heimdall-cp-autoteam: no Ed25519 backend (cryptography/pynacl) — AT6 possession verify unavailable"
  exit 0
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

EXT="$(mktemp -d -t "cp-autoteam.$(printf 'X%.0s' 1 2 3 4 5 6)")"
HOME_T="$EXT/home"
FAKE_MINTER="$EXT/heimdall-gh-app-token"
mkdir -p "$HOME_T"
cleanup() { rm -rf "$EXT"; }
trap cleanup EXIT

# ── the FAKE gh-app-token minter (echoes a deterministic installation token; no real creds) ──
cat >"$FAKE_MINTER" <<'FAKEEOF'
#!/usr/bin/env python3
import os, sys
inst = os.environ.get("HEIMDALL_GH_APP_INSTALLATION_ID", "")
repos = os.environ.get("HEIMDALL_GH_APP_REPOSITORIES", "")
if not inst:
    sys.stderr.write("fake-minter: no HEIMDALL_GH_APP_INSTALLATION_ID\n")
    sys.exit(2)
sys.stdout.write("ghs_faketok_inst_%s_repos_%s\n" % (inst, repos))
FAKEEOF
chmod +x "$FAKE_MINTER"

export HEIMDALL_HOME="$HOME_T"
export HEIMDALL_STATE_BACKEND="local"
export HEIMDALL_GH_APP_TOKEN_BIN="$FAKE_MINTER"

echo "============================================================"
echo "POST /team/auto — auto-initiate + auto-join (hermetic)"
echo "  home=$HEIMDALL_HOME  fake-minter=$FAKE_MINTER"
echo "============================================================"
echo

cat >"$EXT/driver.py" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_ghverify as V
import cp_ghinstall as G
import cp_repoteam as R
import cp_auth
import cp_autoteam as A
import cp_publicsurface as P

# ── install map: PRIVATE alice/widgets (111), PUBLIC pub/site (222), PRIVATE founder/newrepo (333). ──
G.set_team_installation("instPriv", 111, ["alice/widgets"])
G.set_team_installation("instPub", 222, ["pub/site"])
G.set_team_installation("instNew", 333, ["founder/newrepo"])

# ── the fake GitHub HTTP chokepoint (canned answers keyed by URL suffix + token). ──
SEEN_TOKENS = []

def fake_get(url, token, *, timeout=None):
    SEEN_TOKENS.append(token)
    if url.endswith("/user"):
        return {
            "tok_alice":   (200, {"login": "alice"}),
            "tok_founder": (200, {"login": "founder"}),
            "tok_dev2":    (200, {"login": "dev2"}),
            "tok_reader":  (200, {"login": "reader"}),
            "tok_mallory": (200, {"login": "mallory"}),
            "tok_bad":     (401, {}),
        }.get(token, (200, {"login": "someoneelse"}))
    if url.endswith("/repos/alice/widgets"):   return (200, {"private": True})
    if url.endswith("/repos/pub/site"):        return (200, {"private": False})
    if url.endswith("/repos/founder/newrepo"): return (200, {"private": True})
    PERM = {
        "/repos/alice/widgets/collaborators/alice/permission":       (200, {"permission": "read"}),
        "/repos/alice/widgets/collaborators/mallory/permission":     (404, {}),
        "/repos/pub/site/collaborators/reader/permission":           (200, {"permission": "read"}),
        "/repos/pub/site/collaborators/committer/permission":        (200, {"permission": "write"}),
        "/repos/founder/newrepo/collaborators/founder/permission":   (200, {"permission": "admin"}),
        "/repos/founder/newrepo/collaborators/dev2/permission":      (200, {"permission": "read"}),
        "/repos/founder/newrepo/collaborators/reader/permission":    (200, {"permission": "read"}),
    }
    for suffix, resp in PERM.items():
        if url.endswith(suffix):
            return resp
    return (404, {})

V._http_get_json = fake_get

import secrets, time

# ── enroll (register a REAL Ed25519 pubkey for) the HAIDs the happy paths bind. AT6 now VERIFIES a
#    key-possession signature against this registered pubkey, so a dummy pubkey no longer suffices —
#    each HAID gets a real keypair and we keep its private seed to sign the possession assertion. ──
SEEDS = {}   # haid -> private_b64 (the enrolled signing seed the client would hold locally)

def enroll_real(haid):
    priv, pub = cp_auth.generate_keypair()
    cp_auth.register_key(haid, pub, owner=False, project="proj")
    SEEDS[haid] = priv

for h in ("haid-alice", "haid-founder", "haid-dev2"):
    enroll_real(h)

def possession(haid, repo, gh_user, nonce, ts):
    """The client-side signing input: BYTE-IDENTICAL to cp_autoteam.possession_message over the
    SAME canonical slug (cp_repoteam.repo_slug) the server verifies against."""
    return A.possession_message(haid, R.repo_slug(repo), gh_user, nonce, ts)

out = {}

def call(repo, gh_user, gh_proof, haid, *, sign_as=None):
    """auto_team core -> {status, reason?, team_id?, mode?}. Signs a FRESH, valid key-possession
    assertion with `sign_as`'s (default `haid`'s) enrolled seed — the AT6 precondition every legit
    bind now carries. A haid with no enrolled seed (e.g. haid-ghost) sends NO sig (the server
    fail-closes enroll_required before it ever checks the sig)."""
    nonce = secrets.token_hex(16)
    ts = int(time.time())
    seed = SEEDS.get(sign_as or haid)
    sig = cp_auth.sign(seed, possession(haid, repo, gh_user, nonce, ts)) if seed else None
    status, body = A.auto_team(repo, gh_user, gh_proof, haid, sig=sig, nonce=nonce, ts=ts)
    r = {"status": status}
    r.update({k: body.get(k) for k in ("reason", "team_id", "mode", "ok")})
    return r

# ── pre-bind the JOIN-path repos to server-derived teams (a real repo->team binding). ──
Tw = R.mint_team_for_repo("alice/widgets")   # PRIVATE, bound
Tp = R.mint_team_for_repo("pub/site")        # PUBLIC, bound
out["Tw"] = Tw
out["Tp"] = Tp

# ── AT5: a non-admin (read-only) caller cannot AUTO-INITIATE the still-UNBOUND founder/newrepo ──
out["at5_reader_initiate"] = call("founder/newrepo", "reader", "tok_reader", "haid-dev2")
out["founder_unbound_before_initiate"] = (R.get_team_for_repo("founder/newrepo") is None)

# ── happy INITIATE: founder (admin) stands up a server-derived team for founder/newrepo ──
init = call("https://github.com/founder/newrepo.git", "founder", "tok_founder", "haid-founder")
out["happy_initiate"] = init
Tnew = init.get("team_id")
out["Tnew_bound_after"] = (R.get_team_for_repo("founder/newrepo") == Tnew)

# ── happy JOIN: dev2 (a read collaborator on the now-PRIVATE-bound repo) joins the SAME team ──
out["happy_join"] = call("founder/newrepo", "dev2", "tok_dev2", "haid-dev2")
out["join_same_team"] = (out["happy_join"].get("team_id") == Tnew)

# ── CAS convergence: a SECOND initiate on the now-bound repo CONVERGES (join, one team, no re-mint) ──
out["converge"] = call("git@github.com:founder/newrepo.git", "founder", "tok_founder", "haid-founder")
out["converge_same_team"] = (out["converge"].get("team_id") == Tnew)

# ── AT1: a non-collaborator join of the BOUND private repo is DENIED — no binding written ──
out["at1_noncollab_join"] = call("alice/widgets", "mallory", "tok_mallory", "haid-alice")

# ── AT4: a PUBLIC repo read-only drive-by join is DENIED (public requires write/push) ──
out["at4_public_readonly"] = call("pub/site", "reader", "tok_reader", "haid-dev2")

# ── AT2: a FORGED gh identity (claim 'alice', but the token's true owner is 'mallory') -> 401,
#        BEFORE any repo/permission work. Verified login, never the claim, is authoritative. ──
out["at2_forged"] = call("alice/widgets", "alice", "tok_mallory", "haid-alice")

# ── AT3: a WIRE team_id in the body is IGNORED — the team is server-resolved from the repo binding.
#        Driven through the ROUTE (which parses the body) with an evil team_id; alice (read) joins.
#        Carries a VALID possession assertion so the route reaches the join (AT6 is not the subject). ──
_n3 = secrets.token_hex(16); _t3 = int(time.time())
_sig3 = cp_auth.sign(SEEDS["haid-alice"], possession("haid-alice", "alice/widgets", "alice", _n3, _t3))
req = {"body": json.dumps({
    "repo": "alice/widgets", "gh_user": "alice", "gh_proof": "tok_alice",
    "haid": "haid-alice", "team_id": "WIRE_EVIL_TEAM",
    "sig": _sig3, "nonce": _n3, "ts": _t3})}
resp = A.auto_team_route(req)
out["at3_route_status"] = resp.status
out["at3_returned_team"] = resp.body.get("team_id")
out["at3_ignores_wire"] = (resp.body.get("team_id") == Tw and resp.body.get("team_id") != "WIRE_EVIL_TEAM")
out["at3_no_secret_in_body"] = ("secret" not in json.dumps(resp.body).lower())

# ── enroll-then-autojoin: an UNENROLLED HAID (no registered pubkey) is refused enroll_required ──
out["enroll_required"] = call("alice/widgets", "alice", "tok_alice", "haid-ghost")

# ── the abuse gate check_autoteam: a per-IP flood is shed (429). Tighten the cap via env. ──
os.environ["HEIMDALL_AUTOTEAM_IP_LIMIT"] = "2"
os.environ["HEIMDALL_AUTOTEAM_IP_WINDOW"] = "60"
flood_req = {"x_forwarded_for": "203.0.113.9"}
shed = [P.check_autoteam(flood_req) for _ in range(3)]
out["ratelimit_first_two_allow"] = (shed[0] is None and shed[1] is None)
out["ratelimit_third_shed"] = (isinstance(shed[2], tuple) and shed[2][0] == 429
                               and shed[2][1].get("scope") == "autoteam_ip")

# ── AT6 (haid KEY-POSSESSION, residual vector §3c). An attacker who KNOWS a victim's already-
#    enrolled HAID must NOT be able to bind it: only the holder of the victim's registered Ed25519
#    key may bind haid=victim. We drive the JOIN path of the now-bound founder/newrepo (a private
#    repo where dev2 holds read) — possession is checked BEFORE the repo strata, so the sig is the
#    deciding factor. victim holds a real enrolled key; mallory holds a DIFFERENT (unrelated) key. ──
_vpriv, _vpub = cp_auth.generate_keypair()
cp_auth.register_key("haid-victim", _vpub, owner=False, project="proj")  # victim's REGISTERED key.
_mpriv, _mpub = cp_auth.generate_keypair()                              # attacker's key (NOT the victim's).
AT6_REPO = "founder/newrepo"   # bound to Tnew (private); dev2 has read -> join-eligible.

def at6_call(sig, nonce, ts):
    status, body = A.auto_team(AT6_REPO, "dev2", "tok_dev2", "haid-victim",
                               sig=sig, nonce=nonce, ts=ts)
    r = {"status": status}
    r.update({k: body.get(k) for k in ("reason", "team_id", "mode", "ok")})
    return r

# AT6a — a VALID own-key possession sig BINDS (mode joined, the server-derived team Tnew).
_n6 = secrets.token_hex(16); _t6 = int(time.time())
_sig6ok = cp_auth.sign(_vpriv, possession("haid-victim", AT6_REPO, "dev2", _n6, _t6))
out["at6_valid"] = at6_call(_sig6ok, _n6, _t6)
out["at6_valid_binds"] = (out["at6_valid"]["status"] == 200 and out["at6_valid"]["team_id"] == Tnew)

# AT6b — a MISSING possession sig is DENIED (possession_required); nothing binds.
out["at6_missing"] = at6_call(None, secrets.token_hex(16), int(time.time()))

# AT6c — a sig under a DIFFERENT key (mallory's, over the victim's assertion) is DENIED
#        (bad_signature): it does NOT verify under the victim's REGISTERED pubkey.
_nw = secrets.token_hex(16); _tw = int(time.time())
_sig6wrong = cp_auth.sign(_mpriv, possession("haid-victim", AT6_REPO, "dev2", _nw, _tw))
out["at6_wrongkey"] = at6_call(_sig6wrong, _nw, _tw)

# AT6d — a REPLAYED nonce is DENIED (possession_replay): the SAME accepted (sig, nonce, ts) resent.
_nr = secrets.token_hex(16); _tr = int(time.time())
_sig6r = cp_auth.sign(_vpriv, possession("haid-victim", AT6_REPO, "dev2", _nr, _tr))
out["at6_replay_first"] = at6_call(_sig6r, _nr, _tr)    # first use: accepted + binds.
out["at6_replay_second"] = at6_call(_sig6r, _nr, _tr)   # replay: same signed bytes -> denied.

# ── transit-only proof: tokens WERE used (calls happened) but must NEVER persist anywhere. ──
out["saw_forwarded_gh_token"] = ("tok_founder" in SEEN_TOKENS)
out["saw_installation_token"] = any(t.startswith("ghs_faketok") for t in SEEN_TOKENS)

print(json.dumps(out))
PYEOF

R="$("$PY" "$EXT/driver.py" 2>"$EXT/py.err")"

if [ -s "$EXT/py.err" ]; then bad "python errored"; cat "$EXT/py.err" >&2; fi
[ -n "$R" ] || { bad "no JSON from the python driver"; }
j(){ printf '%s' "$R" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
jk(){ printf '%s' "$R" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1',{}).get('$2'))" 2>/dev/null; }

# ── AT2 forged identity ──
[ "$(jk at2_forged status)" = "401" ] && [ "$(jk at2_forged reason)" = "gh_identity_mismatch" ] \
  && ok "AT2 a forged gh identity (claim a real collaborator, fail GET /user re-derive) -> 401, no bind" \
  || bad "AT2 forged-identity not rejected (R=$R)"

# ── AT3 wire team_id ignored ──
[ "$(j at3_route_status)" = "200" ] && [ "$(j at3_ignores_wire)" = "True" ] \
  && [ "$(j at3_no_secret_in_body)" = "True" ] \
  && ok "AT3 a WIRE team_id is IGNORED — team resolved SERVER-SIDE from the repo binding (INV-1); no secret in body" \
  || bad "AT3 a wire team_id leaked into the bind (R=$R)"

# ── AT1 non-collaborator join ──
[ "$(jk at1_noncollab_join status)" = "403" ] && [ "$(jk at1_noncollab_join reason)" = "repo_access_denied" ] \
  && ok "AT1 a non-collaborator auto-join is DENIED (403 repo_access_denied)" \
  || bad "AT1 a non-collaborator was not denied (R=$R)"

# ── AT4 public read-only join ──
[ "$(jk at4_public_readonly status)" = "403" ] && [ "$(jk at4_public_readonly reason)" = "repo_access_denied" ] \
  && ok "AT4 a PUBLIC repo read-only drive-by auto-join is DENIED (public requires write/push)" \
  || bad "AT4 a public read-only user could join (R=$R)"

# ── AT5 non-admin initiate ──
[ "$(jk at5_reader_initiate status)" = "403" ] && [ "$(jk at5_reader_initiate reason)" = "initiate_denied" ] \
  && [ "$(j founder_unbound_before_initiate)" = "True" ] \
  && ok "AT5 a non-admin caller cannot AUTO-INITIATE an unbound repo (403 initiate_denied)" \
  || bad "AT5 a non-admin initiated a team (R=$R)"

# ── happy initiate ──
[ "$(jk happy_initiate status)" = "200" ] && [ "$(jk happy_initiate mode)" = "initiated" ] \
  && [ "$(j Tnew_bound_after)" = "True" ] \
  && ok "happy INITIATE: admin/push mints a server-derived team + binds the enrolled HAID (mode=initiated)" \
  || bad "happy initiate broken (R=$R)"

# ── happy join ──
[ "$(jk happy_join status)" = "200" ] && [ "$(jk happy_join mode)" = "joined" ] \
  && [ "$(j join_same_team)" = "True" ] \
  && ok "happy JOIN: a collaborator binds to the SAME server-derived team (mode=joined)" \
  || bad "happy join broken (R=$R)"

# ── CAS convergence ──
[ "$(jk converge status)" = "200" ] && [ "$(j converge_same_team)" = "True" ] \
  && ok "CAS convergence: a second initiate on the now-bound repo CONVERGES on the one team (no double-mint)" \
  || bad "CAS convergence broken — a second initiate diverged (R=$R)"

# ── enroll-then-autojoin ──
[ "$(jk enroll_required status)" = "403" ] && [ "$(jk enroll_required reason)" = "enroll_required" ] \
  && ok "enroll-then-autojoin: an UNENROLLED HAID is refused enroll_required (enroll first, then re-call)" \
  || bad "enroll-required precondition broken (R=$R)"

# ── AT6 key-possession: valid own-key sig BINDS ──
[ "$(jk at6_valid status)" = "200" ] && [ "$(j at6_valid_binds)" = "True" ] \
  && ok "AT6 a VALID own-key possession sig binds the haid (verifies under the registered pubkey)" \
  || bad "AT6 valid own-key possession did not bind (R=$R)"

# ── AT6 key-possession: MISSING sig denied ──
[ "$(jk at6_missing status)" = "401" ] && [ "$(jk at6_missing reason)" = "possession_required" ] \
  && ok "AT6 a MISSING possession sig is DENIED (401 possession_required) — no bind" \
  || bad "AT6 a missing possession sig was not denied (R=$R)"

# ── AT6 key-possession: sig under a DIFFERENT key denied ──
[ "$(jk at6_wrongkey status)" = "401" ] && [ "$(jk at6_wrongkey reason)" = "bad_signature" ] \
  && ok "AT6 a sig under a DIFFERENT key is DENIED (401 bad_signature) — only the key-holder binds their haid" \
  || bad "AT6 a forged (different-key) possession sig was not denied (R=$R)"

# ── AT6 key-possession: REPLAYED nonce denied ──
[ "$(jk at6_replay_first status)" = "200" ] && [ "$(jk at6_replay_second status)" = "401" ] \
  && [ "$(jk at6_replay_second reason)" = "possession_replay" ] \
  && ok "AT6 a REPLAYED possession nonce is DENIED (401 possession_replay) — a captured sig cannot re-bind" \
  || bad "AT6 a replayed possession nonce was not denied (R=$R)"

# ── rate-limit shed ──
[ "$(j ratelimit_first_two_allow)" = "True" ] && [ "$(j ratelimit_third_shed)" = "True" ] \
  && ok "abuse gate check_autoteam sheds a per-IP flood (429 autoteam_ip) after the cap" \
  || bad "rate-limit shed broken (R=$R)"

# ── transit-only token handling ──
SAW_GH="$(j saw_forwarded_gh_token)"
SAW_INST="$(j saw_installation_token)"
HOME_HAS_GH="$(grep -rl "tok_founder\|tok_alice\|tok_dev2\|tok_reader\|tok_mallory" "$HOME_T" 2>/dev/null | wc -l | tr -d ' ')"
HOME_HAS_INST="$(grep -rl "ghs_faketok" "$HOME_T" 2>/dev/null | wc -l | tr -d ' ')"
ERR_HAS_TOKEN="$(grep -c "tok_founder\|tok_alice\|ghs_faketok" "$EXT/py.err" 2>/dev/null | tr -d ' ')"
if [ "$SAW_GH" = "True" ] && [ "$SAW_INST" = "True" ] \
   && [ "$HOME_HAS_GH" = "0" ] && [ "$HOME_HAS_INST" = "0" ] && [ "$ERR_HAS_TOKEN" = "0" ]; then
  ok "transit-only: forwarded gh token + minted installation token were USED but NEVER stored under HEIMDALL_HOME nor leaked to stderr"
else
  bad "a token leaked (home_gh=$HOME_HAS_GH home_inst=$HOME_HAS_INST err=$ERR_HAS_TOKEN saw_gh=$SAW_GH saw_inst=$SAW_INST)"
fi

echo
echo "============================================================"
printf "heimdall-cp-autoteam: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
