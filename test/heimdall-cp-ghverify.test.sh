#!/usr/bin/env bash
# heimdall-cp-ghverify.test.sh — the SERVER-SIDE GitHub identity + repo-access verification for
# zero-touch auto-team-formation (design §3c, INV-AUTOTEAM AT1/AT2/AT4/AT5).
#
# THE GUARANTEE. The server trusts the client's {gh_user, repo} claims for NOTHING. Stratum A
# re-derives the caller's login from GitHub's OWN GET /user and refuses a mismatch (AT2). Stratum
# B reads the gh_user<->repo permission via an App installation token and applies RJ's threshold:
# PRIVATE => a collaborator (>= read) joins, PUBLIC => only a committer (>= write) joins, a
# read-only drive-by is denied (AT1/AT4). can_initiate is admin/push-only (AT5). The forwarded
# gh token + minted installation token are TRANSIT-ONLY — never stored, never in an error.
#
# HERMETIC. Zero real GitHub creds, zero network. The single GitHub HTTP chokepoint
# (cp_ghverify._http_get_json) is REPLACED in-process with a fake that returns canned responses
# keyed by URL + token; the App installation token is minted through the REAL cp_ghinstall with a
# FAKE gh-app-token minter (HEIMDALL_GH_APP_TOKEN_BIN). The store is the LocalBackend under an
# isolated throwaway HEIMDALL_HOME. Every temp is reaped on EXIT.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

for f in cp_ghverify cp_ghinstall cp_auth cp_state cp_allowlist; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

EXT="$(mktemp -d -t "cp-ghverify.$(printf 'X%.0s' 1 2 3 4 5 6)")"
HOME_T="$EXT/home"
FAKE_MINTER="$EXT/heimdall-gh-app-token"
mkdir -p "$HOME_T"
cleanup() { rm -rf "$EXT"; }
trap cleanup EXIT

# ── the FAKE gh-app-token minter: echoes ONLY a deterministic installation token to stdout
#    (embedding the installation id + repo scope it was handed via ENV). No real GitHub creds. ──
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
echo "SERVER-SIDE GH IDENTITY + REPO-ACCESS verification (hermetic)"
echo "  home=$HEIMDALL_HOME  fake-minter=$FAKE_MINTER"
echo "============================================================"
echo

cat >"$EXT/driver.py" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_ghverify as V
import cp_ghinstall as G

# ── install-map fixture: a PRIVATE repo (alice/widgets, inst 111) + a PUBLIC repo
#    (pub/site, inst 222). The reverse-lookup + minter path is exercised for real. ──
G.set_team_installation("teamPriv", 111, ["alice/widgets"])
G.set_team_installation("teamPub", 222, ["pub/site"])

# ── the fake GitHub HTTP chokepoint. Canned answers keyed by URL suffix (+ token for /user).
#    Records every token it was handed so the test can prove NONE of them ever persist. ──
SEEN_TOKENS = []

def fake_get(url, token, *, timeout=None):
    SEEN_TOKENS.append(token)
    # STRATUM A — GET /user re-derives the caller's TRUE login from the forwarded token.
    if url.endswith("/user"):
        if token == "tok_alice":
            return (200, {"login": "alice"})
        if token == "tok_admin":
            return (200, {"login": "adminuser"})
        if token == "tok_bad":            # an expired / revoked forwarded token
            return (401, {})
        return (200, {"login": "someoneelse"})
    # STRATUM B (metadata) — server-determined public/private via .private.
    if url.endswith("/repos/alice/widgets"):
        return (200, {"private": True})
    if url.endswith("/repos/pub/site"):
        return (200, {"private": False})
    # STRATUM B (permission) — {user, repo} -> level, or 404 for a non-collaborator.
    PERM = {
        "/repos/alice/widgets/collaborators/alice/permission":      (200, {"permission": "read"}),
        "/repos/alice/widgets/collaborators/adminuser/permission":  (200, {"permission": "admin"}),
        "/repos/alice/widgets/collaborators/mallory/permission":    (404, {}),
        "/repos/pub/site/collaborators/reader/permission":          (200, {"permission": "read"}),
        "/repos/pub/site/collaborators/committer/permission":       (200, {"permission": "write"}),
    }
    for suffix, resp in PERM.items():
        if url.endswith(suffix):
            return resp
    return (404, {})

V._http_get_json = fake_get

out = {}

def reason_of(fn, *a, **k):
    try:
        fn(*a, **k)
        return "NO-RAISE"
    except V.AuthError as e:
        return e.reason

# ── STRATUM A (AT2): identity match returns the canonical login; mismatch + bad token refuse ──
out["A_match"] = V.verify_gh_identity("tok_alice", "alice")            # -> "alice"
out["A_match_caseins"] = V.verify_gh_identity("tok_alice", "ALICE")    # case-insensitive match
out["A_mismatch"] = reason_of(V.verify_gh_identity, "tok_alice", "mallory")  # forged claim
out["A_badtoken"] = reason_of(V.verify_gh_identity, "tok_bad", "alice")      # unverifiable token
out["A_empty"] = reason_of(V.verify_gh_identity, "", "alice")               # missing token

# ── STRATUM B (AT1): PRIVATE repo — a collaborator (read) joins, a non-collaborator is denied ──
out["B_priv_collab"] = V.check_repo_access("alice", "alice/widgets")        # is_public=None (server-determined)
out["B_priv_noncollab"] = reason_of(V.check_repo_access, "mallory", "alice/widgets")

# ── STRATUM B (AT4): PUBLIC repo — a read-only drive-by is DENIED, a committer (write) joins ──
out["B_pub_readonly"] = reason_of(V.check_repo_access, "reader", "pub/site")
out["B_pub_writer"] = V.check_repo_access("committer", "pub/site")          # write >= write -> allow

# ── the is_public flag is SERVER-DETERMINED (not the param): forcing is_public=False on the
#    PUBLIC repo flips the threshold to the PRIVATE policy, so the read-only user is admitted.
#    Proves the policy is threshold-driven + the param is the swap seam, not a client claim. ──
out["B_pub_forced_private"] = V.check_repo_access("reader", "pub/site", is_public=False)  # -> "read"

# ── can_initiate (AT5): admin/push True; read/none False ──
out["init_admin"] = V.can_initiate("adminuser", "alice/widgets")   # admin -> True
out["init_writer"] = V.can_initiate("committer", "pub/site")       # write -> True
out["init_reader"] = V.can_initiate("reader", "pub/site")          # read  -> False
out["init_noncollab"] = V.can_initiate("mallory", "alice/widgets") # none  -> False

# ── fail-closed: a repo with NO App installation cannot be permission-checked ──
out["no_install"] = reason_of(V.check_repo_access, "alice", "ghost/repo")

# ── the centralized threshold policy is the documented swap point ──
out["policy_private_min"] = V._PRIVATE_MIN_LEVEL
out["policy_public_min"] = V._PUBLIC_MIN_LEVEL
out["policy_initiate_min"] = V._INITIATE_MIN_LEVEL
out["req_public"] = V.required_level(True)
out["req_private"] = V.required_level(False)

# ── transit-only proof: tokens WERE handed to GitHub (so the calls really happened) but NONE of
#    them may ever appear in the store / anywhere under HEIMDALL_HOME. ──
out["saw_forwarded_gh_token"] = ("tok_alice" in SEEN_TOKENS)
out["saw_installation_token"] = any(t.startswith("ghs_faketok") for t in SEEN_TOKENS)

print(json.dumps(out))
PYEOF

R="$("$PY" "$EXT/driver.py" 2>"$EXT/py.err")"

if [ -s "$EXT/py.err" ]; then bad "python errored"; cat "$EXT/py.err" >&2; fi
[ -n "$R" ] || { bad "no JSON from the python driver"; }
j(){ printf '%s' "$R" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }

# ── STRATUM A (AT2) ──
[ "$(j A_match)" = "alice" ] && [ "$(j A_match_caseins)" = "alice" ] \
  && [ "$(j A_mismatch)" = "gh_identity_mismatch" ] \
  && [ "$(j A_badtoken)" = "gh_identity_unverified" ] \
  && [ "$(j A_empty)" = "bad_input" ] \
  && ok "A Stratum A: GET /user re-derive — match returns canonical login, forged claim + bad/empty token REFUSED (AT2)" \
  || bad "A Stratum A identity check broken (R=$R)"

# ── STRATUM B private (AT1) ──
[ "$(j B_priv_collab)" = "read" ] && [ "$(j B_priv_noncollab)" = "repo_access_denied" ] \
  && ok "B1 Stratum B PRIVATE: a read collaborator JOINS, a non-collaborator is DENIED (AT1)" \
  || bad "B1 private-repo access policy broken (R=$R)"

# ── STRATUM B public (AT4) ──
[ "$(j B_pub_readonly)" = "repo_access_denied" ] && [ "$(j B_pub_writer)" = "write" ] \
  && ok "B2 Stratum B PUBLIC: a read-only drive-by is DENIED, only a write/push committer JOINS (AT4)" \
  || bad "B2 public-repo write-threshold broken — a read-only user could join (R=$R)"

# ── server-determined is_public + threshold swap ──
[ "$(j B_pub_forced_private)" = "read" ] \
  && ok "B3 the threshold is policy-driven: forcing the private policy admits the same read-only user (is_public is the swap seam)" \
  || bad "B3 threshold/is_public seam broken (R=$R)"

# ── can_initiate (AT5) ──
[ "$(j init_admin)" = "True" ] && [ "$(j init_writer)" = "True" ] \
  && [ "$(j init_reader)" = "False" ] && [ "$(j init_noncollab)" = "False" ] \
  && ok "C can_initiate: admin/push may INITIATE, read/none may NOT (AT5)" \
  || bad "C can_initiate authority broken (R=$R)"

# ── fail-closed on no installation ──
[ "$(j no_install)" = "no_installation" ] \
  && ok "D fail-closed: a repo with no App installation is REFUSED (no_installation)" \
  || bad "D a repo with no installation was not refused (R=$R)"

# ── the centralized threshold policy ──
[ "$(j policy_private_min)" = "read" ] && [ "$(j policy_public_min)" = "write" ] \
  && [ "$(j policy_initiate_min)" = "write" ] \
  && [ "$(j req_public)" = "write" ] && [ "$(j req_private)" = "read" ] \
  && ok "E threshold policy centralized: private>=read, public>=write, initiate>=write (one swap point)" \
  || bad "E threshold policy constants drifted (R=$R)"

# ── transit-only token handling: calls happened, but no token persists ──
SAW_GH="$(j saw_forwarded_gh_token)"
SAW_INST="$(j saw_installation_token)"
HOME_HAS_GH="$(grep -rl "tok_alice\|tok_admin\|tok_bad" "$HOME_T" 2>/dev/null | wc -l | tr -d ' ')"
HOME_HAS_INST="$(grep -rl "ghs_faketok" "$HOME_T" 2>/dev/null | wc -l | tr -d ' ')"
ERR_HAS_TOKEN="$(grep -c "tok_alice\|tok_admin\|tok_bad\|ghs_faketok" "$EXT/py.err" 2>/dev/null | tr -d ' ')"
if [ "$SAW_GH" = "True" ] && [ "$SAW_INST" = "True" ] \
   && [ "$HOME_HAS_GH" = "0" ] && [ "$HOME_HAS_INST" = "0" ] && [ "$ERR_HAS_TOKEN" = "0" ]; then
  ok "F transit-only: forwarded gh token + minted installation token were USED but NEVER stored under HEIMDALL_HOME nor leaked to stderr"
else
  bad "F a token leaked (home_gh=$HOME_HAS_GH home_inst=$HOME_HAS_INST err=$ERR_HAS_TOKEN saw_gh=$SAW_GH saw_inst=$SAW_INST)"
fi

echo
echo "============================================================"
printf "heimdall-cp-ghverify: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
