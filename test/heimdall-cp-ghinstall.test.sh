#!/usr/bin/env bash
# heimdall-cp-ghinstall.test.sh — THE PER-TEAM GitHub App INSTALLATION MAP + the repo<->team
# AUTHZ RED-line (design §2 / threat-model §5 "GH App token" + "Repo authorization" rows).
#
# THE GUARANTEE. A team's installation_id / scoped PR token is keyed STRICTLY by the caller's
# team_id. No path returns team B's installation to team A; mint_token_for_team REFUSES a repo
# the caller-team's own installation does not cover (defeats IDOR-via-repo-slug); the minted
# token is NEVER logged / argv / stored; every failure is fail-closed.
#
# HERMETIC. Zero real GitHub creds, zero network: bin/heimdall-gh-app-token is REPLACED via
# HEIMDALL_GH_APP_TOKEN_BIN with a FAKE minter (echoes a deterministic token embedding the
# installation id + repo scope it was handed, and appends one CALL line to a log). The store is
# the LocalBackend under an isolated throwaway HEIMDALL_HOME. Every temp is reaped on EXIT.
#
# THE TWO-TEAM FIXTURE (isolation proof): team A -> installation 111, repos [alice/widgets];
# team B -> installation 222, repos [bob/gadgets]. The falsifiable RED-line: mint for team A on
# B's repo (bob/gadgets) MUST refuse WITHOUT invoking the minter — drop team_covers_repo in
# mint_token_for_team and team A rides its OWN installation (111) to bob's repo => the fake
# minter is invoked => this test FAILS.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

for f in cp_ghinstall cp_state cp_allowlist; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

EXT="$(mktemp -d -t "cp-ghinstall.$(printf 'X%.0s' 1 2 3 4 5 6)")"
HOME_T="$EXT/home"
CALL_LOG="$EXT/minter-calls.log"
FAKE_MINTER="$EXT/heimdall-gh-app-token"
mkdir -p "$HOME_T"
: >"$CALL_LOG"
cleanup() { rm -rf "$EXT"; }
trap cleanup EXIT

# ── the FAKE minter: no real GitHub creds. Echoes ONLY a deterministic token to stdout
#    (embedding the installation id + repo scope it received via ENV, so the test can prove
#    which installation was used), and appends ONE CALL line to $MINTER_CALL_LOG. Mirrors the
#    real tool: installation id rides ENV (never argv), token goes to stdout ONLY. ──
cat >"$FAKE_MINTER" <<'FAKEEOF'
#!/usr/bin/env python3
import os, sys
inst = os.environ.get("HEIMDALL_GH_APP_INSTALLATION_ID", "")
repos = os.environ.get("HEIMDALL_GH_APP_REPOSITORIES", "")
log = os.environ.get("MINTER_CALL_LOG")
if log:
    with open(log, "a", encoding="utf-8") as fh:
        fh.write("CALL inst=%s repos=%s\n" % (inst, repos))
if not inst:
    sys.stderr.write("fake-minter: no HEIMDALL_GH_APP_INSTALLATION_ID (mirrors exit 2)\n")
    sys.exit(2)
# token ON STDOUT ONLY (no diagnostics on stdout), embedding what it was scoped to.
sys.stdout.write("ghs_faketok_inst_%s_repos_%s\n" % (inst, repos))
FAKEEOF
chmod +x "$FAKE_MINTER"

export HEIMDALL_HOME="$HOME_T"
export HEIMDALL_STATE_BACKEND="local"
export HEIMDALL_GH_APP_TOKEN_BIN="$FAKE_MINTER"
export MINTER_CALL_LOG="$CALL_LOG"

echo "============================================================"
echo "PER-TEAM GH-APP INSTALLATION MAP + repo<->team authz (hermetic)"
echo "  home=$HEIMDALL_HOME  fake-minter=$FAKE_MINTER"
echo "============================================================"
echo

cat >"$EXT/driver.py" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_ghinstall as G

out = {}

# ── two-team fixture: A -> 111/[alice/widgets], B -> 222/[bob/gadgets] ──
recA = G.set_team_installation("teamA", 111, ["alice/widgets"])
recB = G.set_team_installation("teamB", "222", "bob/gadgets")  # str-int + single-slug forms
out["setA_inst"] = recA.get("installation_id")
out["setA_repos"] = recA.get("repos")
out["setB_inst"] = recB.get("installation_id")            # "222" coerced to int 222
out["setB_repos"] = recB.get("repos")

# ── 1) set/get round-trip per team ──
out["getA"] = G.get_installation("teamA")
out["getB"] = G.get_installation("teamB")
out["coversA_own"] = G.team_covers_repo("teamA", "alice/widgets")
out["coversB_own"] = G.team_covers_repo("teamB", "bob/gadgets")

# ── 2) cross-tenant DENIED: A never resolves B's installation / repo, and vice-versa ──
out["getA_not_B"] = (G.get_installation("teamA") != G.get_installation("teamB"))
out["A_no_B_repo"] = (G.team_covers_repo("teamA", "bob/gadgets") is False)
out["B_no_A_repo"] = (G.team_covers_repo("teamB", "alice/widgets") is False)

# ── 3) mint for a team's OWN repo -> a token scoped to THAT team's installation ──
tokA = G.mint_token_for_team("teamA", "alice/widgets")
tokB = G.mint_token_for_team("teamB", "bob/gadgets")
out["tokA"] = tokA
out["tokB"] = tokB
# the token embeds the installation the minter was handed: A's must carry 111 (not 222),
# B's must carry 222 (not 111) — proof each team rode its OWN installation.
out["tokA_uses_111"] = ("inst_111_" in tokA and "222" not in tokA)
out["tokB_uses_222"] = ("inst_222_" in tokB and "111" not in tokB)
# defense-in-depth repo scope = the repo NAME (after the slash).
out["tokA_scope_widgets"] = ("repos_widgets" in tokA)
out["tokB_scope_gadgets"] = ("repos_gadgets" in tokB)

# ── 4) THE repo<->team authz RED-line: mint for A on B's repo REFUSES (fail-closed),
#       and the minter is NOT invoked for it (falsifiable: drop the gate -> minter runs) ──
try:
    G.mint_token_for_team("teamA", "bob/gadgets")
    out["crossmint_refused"] = False
    out["crossmint_reason"] = "NO-RAISE"
except G.GhInstallError as exc:
    out["crossmint_refused"] = True
    out["crossmint_reason"] = exc.reason

# ── 5) fail-closed on NO installation (an unknown team) ──
out["coversZ_false"] = (G.team_covers_repo("teamZ", "alice/widgets") is False)
try:
    G.get_installation("teamZ")
    out["getZ_raised"] = False
except G.GhInstallError as exc:
    out["getZ_raised"] = (exc.reason == "no_installation")
try:
    G.mint_token_for_team("teamZ", "alice/widgets")
    out["mintZ_raised"] = False
    out["mintZ_reason"] = "NO-RAISE"
except G.GhInstallError as exc:
    out["mintZ_raised"] = True
    out["mintZ_reason"] = exc.reason

# ── 6) input validation (installation_id must be an int; repos must be slugs) ──
def _refuses(fn):
    try:
        fn(); return False
    except G.GhInstallError:
        return True
out["reject_nonint_inst"] = _refuses(lambda: G.set_team_installation("teamV", "not-int", ["a/b"]))
out["reject_bool_inst"]   = _refuses(lambda: G.set_team_installation("teamV", True, ["a/b"]))
out["reject_zero_inst"]   = _refuses(lambda: G.set_team_installation("teamV", 0, ["a/b"]))
out["reject_bad_repo"]    = _refuses(lambda: G.set_team_installation("teamV", 5, ["not a slug; rm -rf /"]))
out["reject_no_repos"]    = _refuses(lambda: G.set_team_installation("teamV", 5, []))
out["reject_pathy_team"]  = _refuses(lambda: G.set_team_installation("../escape", 5, ["a/b"]))

# ── 7) the store record carries NO token (installation_id + slugs are non-secret) ──
recpath = G._backend().path(G._rel("teamA"))
out["recpath"] = recpath
with open(recpath, "r", encoding="utf-8") as fh:
    out["record_text"] = fh.read()

print(json.dumps(out))
PYEOF

R="$("$PY" "$EXT/driver.py" 2>"$EXT/py.err")"

if [ -s "$EXT/py.err" ]; then bad "python errored"; cat "$EXT/py.err" >&2; fi
[ -n "$R" ] || { bad "no JSON from the python driver"; }
j(){ printf '%s' "$R" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }

# ── 1) round-trip ──
[ "$(j setA_inst)" = "111" ] && [ "$(j getA)" = "111" ] && [ "$(j getB)" = "222" ] \
  && [ "$(j setB_inst)" = "222" ] && [ "$(j coversA_own)" = "True" ] && [ "$(j coversB_own)" = "True" ] \
  && ok "1 set/get round-trips per team (A->111/[alice/widgets], B->222/[bob/gadgets]; str-int coerced)" \
  || bad "1 set/get round-trip broken (R=$R)"

# ── 2) cross-tenant denial ──
[ "$(j getA_not_B)" = "True" ] && [ "$(j A_no_B_repo)" = "True" ] && [ "$(j B_no_A_repo)" = "True" ] \
  && ok "2 team A NEVER resolves team B's installation/repo, and vice-versa (keyed by caller team_id)" \
  || bad "2 CROSS-TENANT LEAK: a team resolved another team's installation/repo (R=$R)"

# ── 3) each team's mint rides its OWN installation ──
[ "$(j tokA_uses_111)" = "True" ] && [ "$(j tokB_uses_222)" = "True" ] \
  && [ "$(j tokA_scope_widgets)" = "True" ] && [ "$(j tokB_scope_gadgets)" = "True" ] \
  && ok "3 mint_token_for_team scopes to the CALLER-team's own installation (A=111/widgets, B=222/gadgets)" \
  || bad "3 a mint used the wrong installation or repo scope (R=$R)"

# ── 4) THE repo<->team authz RED-line ──
CROSS_CALLS="$(grep -c "repos=gadgets" "$CALL_LOG" 2>/dev/null | tr -d ' ')"
# after step 3, the minter WAS called once for B's own mint (inst=222 repos=gadgets). The
# falsifier is a SECOND gadgets call (inst=111 repos=gadgets) caused by team A's cross-mint if
# the gate were dropped. So exactly ONE legitimate gadgets call is expected; A's refused
# cross-mint must add NONE.
[ "$(j crossmint_refused)" = "True" ] && [ "$(j crossmint_reason)" = "repo_not_covered" ] \
  && [ "$CROSS_CALLS" = "1" ] \
  && ok "4 repo<->team authz: A minting on B's repo (bob/gadgets) REFUSED (repo_not_covered) + minter NOT invoked [RED-line]" \
  || bad "4 CROSS-TENANT REPO MINT was not refused / the minter was invoked (reason=$(j crossmint_reason) gadgets_calls=$CROSS_CALLS R=$R)"

# ── 5) fail-closed on no installation ──
[ "$(j coversZ_false)" = "True" ] && [ "$(j getZ_raised)" = "True" ] \
  && [ "$(j mintZ_raised)" = "True" ] && [ "$(j mintZ_reason)" = "no_installation" ] \
  && ok "5 fail-closed on an unknown team: covers=False, get_installation + mint both raise no_installation" \
  || bad "5 an unknown team did not fail closed (R=$R)"

# ── 6) input validation ──
[ "$(j reject_nonint_inst)" = "True" ] && [ "$(j reject_bool_inst)" = "True" ] \
  && [ "$(j reject_zero_inst)" = "True" ] && [ "$(j reject_bad_repo)" = "True" ] \
  && [ "$(j reject_no_repos)" = "True" ] && [ "$(j reject_pathy_team)" = "True" ] \
  && ok "6 validation: non-int/bool/zero installation_id, off-slug repo, empty repos, pathy team_id all REFUSED" \
  || bad "6 an invalid input was accepted (R=$R)"

# ── 7) token NEVER logged / stored ──
TOKA="$(j tokA)"; TOKB="$(j tokB)"
STORE_HAS_TOKEN="$(grep -c "ghs_faketok" <<<"$(j record_text)" 2>/dev/null | tr -d ' ')"
# sweep the ENTIRE throwaway home for the token string (nothing under HEIMDALL_HOME may hold it).
HOME_HAS_TOKEN="$(grep -rl "ghs_faketok" "$HOME_T" 2>/dev/null | wc -l | tr -d ' ')"
if [ -n "$TOKA" ] && [ -n "$TOKB" ] && [ "$STORE_HAS_TOKEN" = "0" ] && [ "$HOME_HAS_TOKEN" = "0" ]; then
  ok "7 the minted token is returned ONLY (never in the store record, never anywhere under HEIMDALL_HOME)"
else
  bad "7 a minted token leaked into the store/home (store=$STORE_HAS_TOKEN home=$HOME_HAS_TOKEN)"
fi

echo
echo "============================================================"
printf "heimdall-cp-ghinstall: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
