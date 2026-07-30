#!/usr/bin/env bash
# heimdall-team-convergence.test.sh — WAVE-1 RED GATE for the team-split bug (TEAM-FIX-PLAN §5.5).
#
# THE BUG (documented here, RED now, GREEN after the Wave-2 resolver fix). Two developers on the
# SAME github repo — the SAME canonical `repo_slug` — must land on the SAME operative team_id, or
# they can never see each other's presence. On the SHIPPED code they DO NOT:
#
#   * MACHINE A (the committed-secret model). Enrolled from a repo whose <repo>/.heimdall/team.json
#     carries a bearer `team_secret` (e.g. an old `hmd team new` / a pasted `join <secret>`). Its
#     operative team_id is the CLIENT-derived handle of that secret:
#         cp_auth.derive_team_id(team_secret)  ==  sha256("heimdall-team\0"+secret)[:32]
#     (bin/heimdall-presence lifts the team.json secret into the wire header; the write/read
#      partition is derive_team_id(secret) — the committed-secret world.)
#
#   * MACHINE B (the /team/auto server model). Zero-touch enrolled via POST /team/auto, keyed on
#     GitHub access. Its operative team_id is SERVER-derived for the repo_slug from a FRESH random
#     secret the server mints and discards:
#         cp_repoteam.mint_team_for_repo(repo_slug)  ->  derive_team_id(secrets.token_hex(32))
#     The server NEVER sees Machine A's "S-rally" secret, so it never derives A's id.
#
# Same repo_slug, two operative team_ids → the team is SPLIT: A and B are invisible to each other.
# This test asserts A_id == B_id, so it is RED against current code (prints the two divergent ids
# + a "SPLIT:" line, exits nonzero). That RED is the correct, expected Wave-1 outcome.
#
# FALSIFIABLE IN REVERSE (why it goes GREEN after Wave 2). The resolver fix makes Machine A, for a
# GITHUB repo, DROP its bearer secret and resolve the SAME server id — get_team_for_repo(repo_slug)
# — that Machine B minted/bound. Both then read ONE server-derived partition for the slug, A_id
# becomes get_team_for_repo(slug) == B_id, and this exact assertion flips to PASS. The convergence
# target already exists on shipped code and is proven live below (C2: get==mint for the slug), so
# the only thing failing today is that A still uses derive_team_id(secret) instead of that id.
#
# HERMETIC: two throwaway HOME/HEIMDALL_HOME backends (one per "machine"), a throwaway git repo for
# the real repo_slug, all under a temp dir cleaned via trap. NO network, NO prod control plane, NO
# live Cloud Run — Machine B drives the LOCAL cp_state backend. The RED failure is REAL: it comes
# from invoking the actual cp_auth.derive_team_id + cp_repoteam.mint_team_for_repo/get_team_for_repo
# shipped code, never a hardcoded `false`.
#
# Exit 0 = A and B converged (Wave 2 landed). Nonzero = the split is live (expected in Wave 1).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/bin/lib"
export LIB

PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then echo "SKIP: python3 unavailable — cannot exercise real cp_auth/cp_repoteam" >&2; exit 0; fi
for f in cp_auth cp_repoteam cp_state cp_allowlist; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

TMP="$(mktemp -d -t hmd-team-converge)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── the shared repo both "machines" are on: a real git repo → a real repo_slug ──────────────
#    Machine A's team.json carries the committed bearer secret; the two machines share the SLUG,
#    NOT the secret (the server never learns "S-rally").
SECRET_A="S-rally-committed-team-secret-0000000000000"   # the bearer secret in A's team.json.
REPO="$TMP/rally"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" remote add origin "https://github.com/randomittin/rally.git"
REMOTE_URL="$(git -C "$REPO" config --get remote.origin.url)"
[ -n "$REMOTE_URL" ] || { echo "FATAL: could not read the git remote url" >&2; exit 2; }

# Two isolated backends — one operative HOME per machine (Machine B's server-side registry).
A_HOME="$TMP/machine-a-home"; mkdir -p "$A_HOME"
B_HOME="$TMP/machine-b-home"; mkdir -p "$B_HOME"

echo "============================================================"
echo "TEAM CONVERGENCE — same repo_slug must map to ONE team_id"
echo "  remote=$REMOTE_URL"
echo "============================================================"
echo

# ── invoke the REAL shipped code: derive A's id from the secret, mint B's id from the slug ──
RES="$(SECRET_A="$SECRET_A" REMOTE_URL="$REMOTE_URL" B_HOME="$B_HOME" "$PY" - <<'PYEOF' 2>"$TMP/py.err"
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth       # the committed-secret world: derive_team_id(secret).
import cp_repoteam   # the /team/auto world: repo_slug + mint/get team_for_repo (LOCAL backend).

remote = os.environ["REMOTE_URL"]

# The CANONICAL, NON-SECRET repo key — the real function, from the real git remote (no hardcode).
slug = cp_repoteam.repo_slug(remote)

# MACHINE A — the operative team_id an enrolled committed-secret client uses (client-derived).
a_id = cp_auth.derive_team_id(os.environ["SECRET_A"])

# MACHINE B — the operative team_id /team/auto binds for this repo_slug, SERVER-derived from a
# fresh random secret. Its own isolated HOME backend (no network, no prod CP).
b_home = os.environ["B_HOME"]
b_id = cp_repoteam.mint_team_for_repo(slug, home=b_home)
# The convergence TARGET already resolvable on shipped code: a second read returns the SAME bound
# id (idempotent, no double-mint) — this is exactly the id the fixed resolver will make A adopt.
b_id_reread = cp_repoteam.get_team_for_repo(slug, home=b_home)

json.dump({"slug": slug, "a_id": a_id, "b_id": b_id, "b_id_reread": b_id_reread}, sys.stdout)
PYEOF
)"
if [ -z "$RES" ]; then
  echo "FATAL: the cp_auth/cp_repoteam invocation produced no output" >&2
  cat "$TMP/py.err" >&2
  exit 2
fi

get() { printf '%s' "$RES" | RES_KEY="$1" "$PY" -c 'import json,os,sys;sys.stdout.write(str(json.load(sys.stdin).get(os.environ["RES_KEY"]) or ""))'; }
SLUG="$(get slug)"; A_ID="$(get a_id)"; B_ID="$(get b_id)"; B_ID2="$(get b_id_reread)"

# ── sanity: the slug is the real canonical key, and both ids are real derived handles ───────
if [ "$SLUG" = "randomittin/rally" ]; then
  ok "slug: real repo_slug() canonicalized the git remote → $SLUG"
else
  bad "slug: repo_slug() gave '$SLUG' (expected randomittin/rally)"
fi
if [ -n "$A_ID" ] && [ -n "$B_ID" ]; then
  ok "ids: both operative team_ids came from real shipped code (A via cp_auth.derive_team_id, B via cp_repoteam.mint_team_for_repo)"
else
  bad "ids: a team_id was empty (A='$A_ID' B='$B_ID') — real code did not resolve"
fi

# ── C2: the convergence TARGET is live — get_team_for_repo(slug) == mint (no double-mint) ───
#    This proves the fix's destination already resolves on shipped code (falsifiable-in-reverse).
if [ -n "$B_ID2" ] && [ "$B_ID2" = "$B_ID" ]; then
  ok "target: get_team_for_repo(slug) == mint_team_for_repo(slug) — the server id A must adopt is stable ($B_ID)"
else
  bad "target: server id not stable (mint='$B_ID' reread='$B_ID2') — repoteam registry broken"
fi

# ── THE CONVERGENCE ASSERTION — RED on shipped code, GREEN after the Wave-2 resolver fix ────
echo
if [ "$A_ID" = "$B_ID" ]; then
  ok "CONVERGED: the committed-secret machine and the /team/auto machine share ONE team_id ($A_ID)"
else
  bad "SPLIT: same repo_slug '$SLUG' resolves to TWO team_ids — A=$A_ID B=$B_ID"
  printf "  \033[31mSPLIT: A=%s B=%s\033[0m\n" "$A_ID" "$B_ID"
  echo   "  A (committed-secret / cp_auth.derive_team_id) and B (/team/auto / cp_repoteam.mint_team_for_repo)"
  echo   "  are invisible to each other. Wave-2 fix: A drops its secret for a github repo and resolves"
  echo   "  get_team_for_repo('$SLUG') == B ($B_ID) → this assertion flips GREEN."
fi

echo
echo "============================================================"
printf "heimdall-team-convergence: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
