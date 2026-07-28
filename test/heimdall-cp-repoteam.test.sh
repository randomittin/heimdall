#!/usr/bin/env bash
# heimdall-cp-repoteam.test.sh — THE server-side repo -> team_id REGISTRY (Wave-1 primitive for
# zero-touch auto-team formation; design §2/§3, oracle INV-AUTOTEAM rows AT3/AT5).
#
# THE GUARANTEE. repo_slug() canonicalizes ANY git remote form to a lowercased host-stripped
# owner/name. A first auto-initiate MINTS a server-derived team_id and binds repo->team via a CAS
# (put_record_if). A SECOND initiate on the same repo returns the SAME team (no double-mint, the
# winner is never clobbered). get_team_for_repo returns None for an unbound repo. A wire team_id is
# never honored — the team is resolved SERVER-SIDE from the repo binding (INV-1 / AT3). Membership
# binds haid->team through the EXISTING cp_auth key registry (no duplicate registry).
#
# HERMETIC. Zero network. The store is the LocalBackend under an isolated throwaway HEIMDALL_HOME;
# team_ids are derived by cp_auth.derive_team_id (pure sha256). Every temp is reaped on EXIT.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

for f in cp_repoteam cp_state cp_auth cp_allowlist; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

EXT="$(mktemp -d -t "cp-repoteam.$(printf 'X%.0s' 1 2 3 4 5 6)")"
HOME_T="$EXT/home"
mkdir -p "$HOME_T"
cleanup() { rm -rf "$EXT"; }
trap cleanup EXIT

export HEIMDALL_HOME="$HOME_T"
export HEIMDALL_STATE_BACKEND="local"

echo "============================================================"
echo "repo -> team_id REGISTRY (Wave-1 primitive, hermetic)"
echo "  home=$HEIMDALL_HOME"
echo "============================================================"
echo

cat >"$EXT/driver.py" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_repoteam as R
import cp_auth

out = {}

# ── 1) repo_slug normalization across https / ssh / scp / .git / bare / enterprise ──
cases = {
    "https_git":   "https://github.com/Owner/Repo.git",
    "https_plain": "https://github.com/Owner/Repo",
    "http_slash":  "http://github.com/Owner/Repo/",
    "https_token": "https://x-access-token:TOKENabc@github.com/Owner/Repo.git",
    "ssh_scheme":  "ssh://git@github.com/Owner/Repo.git",
    "ssh_port":    "ssh://git@github.com:22/Owner/Repo.git",
    "git_proto":   "git://github.com/Owner/Repo.git",
    "scp":         "git@github.com:Owner/Repo.git",
    "enterprise":  "git@ghe.corp.example:Owner/Repo.git",
    "bare":        "Owner/Repo",
}
out["slugs"] = {k: R.repo_slug(v) for k, v in cases.items()}
# every well-formed remote for the same repo must canonicalize to the SAME lowercased slug.
out["all_canonical"] = all(v == "owner/repo" for v in out["slugs"].values())
# junk / unresolvable -> None (a read treats it as unbound, a write fails closed).
out["junk"] = {
    "empty":    R.repo_slug(""),
    "space":    R.repo_slug("not a url"),
    "one_seg":  R.repo_slug("onlyonesegment"),
    "none":     R.repo_slug(None),
}
out["junk_all_none"] = all(v is None for v in out["junk"].values())

# ── 2) get returns None for an UNBOUND repo ──
out["get_unbound"] = R.get_team_for_repo("owner/repo")

# ── 3) first initiate MINTS + BINDS a server-derived team_id ──
t1 = R.mint_team_for_repo("https://github.com/Owner/Repo.git")
out["mint1"] = t1
out["mint1_is_derive_shape"] = (isinstance(t1, str) and len(t1) == 32)
out["get_after_mint"] = R.get_team_for_repo("owner/repo")
out["get_matches_mint"] = (out["get_after_mint"] == t1)
# the team_id is SERVER-DERIVED, never a wire value: it must NOT equal any caller-provided token.
out["mint1_not_wire"] = (t1 != "wire_team_id_supplied_by_caller")

# ── 4) SECOND initiate on the SAME repo returns the SAME team (no double-mint) ──
#     even reached via a DIFFERENT remote form (scp) — canonical key convergence.
t2 = R.mint_team_for_repo("git@github.com:owner/repo.git")
out["mint2"] = t2
out["no_double_mint"] = (t2 == t1)

# ── 5) CAS first-writer-wins: binding a DIFFERENT team on a bound repo is REFUSED-BY-CONVERGENCE
#       (the incumbent is returned, NEVER clobbered) ──
wire_tid = cp_auth.derive_team_id("some-other-secret")
bound = R.bind_repo_team("owner/repo", wire_tid)
out["bind_returns_incumbent"] = (bound == t1)          # winner, not the new team
out["bind_did_not_clobber"] = (R.get_team_for_repo("owner/repo") == t1)
out["wire_tid_differs"] = (wire_tid != t1)             # sanity: they really are different ids

# ── 6) a WIRE team_id is IGNORED — the team is resolved SERVER-SIDE from the repo binding (AT3) ──
#     mint on an already-bound repo NEVER honors a caller's intent to set a new team.
out["resolve_ignores_wire"] = (R.get_team_for_repo("owner/repo") == t1 != wire_tid)

# ── 7) a SECOND distinct repo mints its OWN distinct team (per-repo partition) ──
tB = R.mint_team_for_repo("https://github.com/other/project.git")
out["repoB_team"] = tB
out["repoB_distinct"] = (tB != t1)
out["repoA_unchanged"] = (R.get_team_for_repo("owner/repo") == t1)

# ── 8) write paths FAIL-CLOSED on a garbage slug / bad team_id ──
def _refuses(fn):
    try:
        fn(); return False
    except R.RepoTeamError:
        return True
out["mint_bad_repo"]  = _refuses(lambda: R.mint_team_for_repo("not a repo"))
out["bind_bad_repo"]  = _refuses(lambda: R.bind_repo_team("no-slash", t1))
out["bind_bad_team"]  = _refuses(lambda: R.bind_repo_team("owner/repo", "bad team id"))

# ── 9) membership: bind haid->team through the EXISTING key registry (no dup registry) ──
#     an UNREGISTERED haid cannot be bound (fail-closed: no key to sign with).
out["bind_unregistered"] = R.bind_haid_to_team("haid-ghost", t1)   # False expected
# register a key, then bind membership to the repo's server-derived team; registered_team resolves it.
cp_auth.register_key("haid-alice", "cHVia2V5LWJ5dGVz", owner=False, project="proj-x")
out["bind_member"] = R.bind_haid_to_team("haid-alice", t1)
out["member_team"] = cp_auth.registered_team("haid-alice")
out["member_team_is_server_derived"] = (out["member_team"] == t1)
# owner/project/pubkey preserved across the membership swap (non-destructive, no dup registry).
entry = cp_auth._load_keys()["keys"].get("haid-alice") or {}
out["member_pubkey_preserved"] = (entry.get("pubkey") == "cHVia2V5LWJ5dGVz")
out["member_project_preserved"] = (entry.get("project") == "proj-x")

# ── 10) the store record carries the plaintext slug + team_id, NO secret ──
rel = R._rel("owner/repo")
rec = R._backend().get_record(rel)
out["record"] = rec
out["record_has_slug"] = (isinstance(rec, dict) and rec.get("repo_slug") == "owner/repo")

print(json.dumps(out))
PYEOF

R="$("$PY" "$EXT/driver.py" 2>"$EXT/py.err")"

if [ -s "$EXT/py.err" ]; then bad "python errored"; cat "$EXT/py.err" >&2; fi
[ -n "$R" ] || { bad "no JSON from the python driver"; }
j(){ printf '%s' "$R" | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }

# ── 1) repo_slug normalization ──
[ "$(j all_canonical)" = "True" ] && [ "$(j junk_all_none)" = "True" ] \
  && ok "1 repo_slug canonicalizes https/ssh/scp/.git/bare/enterprise -> owner/repo; junk -> None" \
  || bad "1 repo_slug normalization broken (R=$R)"

# ── 2) unbound read ──
[ "$(j get_unbound)" = "None" ] \
  && ok "2 get_team_for_repo returns None for an unbound repo" \
  || bad "2 get_team_for_repo did not return None for an unbound repo (R=$R)"

# ── 3) first initiate mints + binds a server-derived team ──
[ "$(j mint1_is_derive_shape)" = "True" ] && [ "$(j get_matches_mint)" = "True" ] \
  && [ "$(j mint1_not_wire)" = "True" ] \
  && ok "3 first initiate MINTS a server-derived team_id (32-hex) + binds repo->team" \
  || bad "3 first initiate did not mint/bind a server-derived team (R=$R)"

# ── 4) no double-mint ──
[ "$(j no_double_mint)" = "True" ] \
  && ok "4 second initiate (via a different remote form) returns the SAME team — no double-mint / CAS" \
  || bad "4 DOUBLE-MINT: a second initiate minted a new team (R=$R)"

# ── 5) CAS first-writer-wins ──
[ "$(j bind_returns_incumbent)" = "True" ] && [ "$(j bind_did_not_clobber)" = "True" ] \
  && [ "$(j wire_tid_differs)" = "True" ] \
  && ok "5 CAS first-writer-wins: binding a DIFFERENT team returns the incumbent, never clobbers" \
  || bad "5 CAS clobbered the winner / did not converge (R=$R)"

# ── 6) wire team_id ignored (AT3) ──
[ "$(j resolve_ignores_wire)" = "True" ] \
  && ok "6 a WIRE team_id is IGNORED — team resolved SERVER-SIDE from the repo binding (AT3/INV-1)" \
  || bad "6 a wire team_id was honored (R=$R)"

# ── 7) per-repo partition ──
[ "$(j repoB_distinct)" = "True" ] && [ "$(j repoA_unchanged)" = "True" ] \
  && ok "7 a distinct repo mints its OWN distinct team; repo A's binding is unchanged" \
  || bad "7 per-repo partition leaked (R=$R)"

# ── 8) write fail-closed ──
[ "$(j mint_bad_repo)" = "True" ] && [ "$(j bind_bad_repo)" = "True" ] \
  && [ "$(j bind_bad_team)" = "True" ] \
  && ok "8 write paths FAIL-CLOSED on a garbage slug / malformed team_id (RepoTeamError)" \
  || bad "8 a garbage write input was accepted (R=$R)"

# ── 9) membership via the existing registry ──
[ "$(j bind_unregistered)" = "False" ] && [ "$(j bind_member)" = "True" ] \
  && [ "$(j member_team_is_server_derived)" = "True" ] \
  && [ "$(j member_pubkey_preserved)" = "True" ] && [ "$(j member_project_preserved)" = "True" ] \
  && ok "9 membership: unregistered haid refused; a registered haid binds to the server-derived team (pubkey/project preserved, no dup registry)" \
  || bad "9 membership binding broken (R=$R)"

# ── 10) store record: plaintext slug + team_id, no secret ──
[ "$(j record_has_slug)" = "True" ] \
  && ok "10 the store record carries the plaintext repo_slug + team_id (a minted secret is never stored)" \
  || bad "10 the store record is malformed (R=$R)"

echo
echo "============================================================"
printf "heimdall-cp-repoteam: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
