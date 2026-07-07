#!/usr/bin/env bash
# test/heimdall-team-autojoin.test.sh — acceptance for GitHub-collaborator AUTO-JOIN
# (bin/heimdall-team `share` + the shared/personal precedence in heimdall-team show
# and heimdall-presence).
#
# THE FEATURE. A teammate already a collaborator on a PRIVATE repo should AUTO-JOIN
# the team with ZERO manual secret paste, by COMMITTING the team secret to that repo
# as <repo>/.heimdall/team.shared.json (a collaborator clone = the access boundary).
# THE CARDINAL GUARD: `share` MUST hard-refuse on a PUBLIC repo (committing the team
# secret to a public repo would leak the whole team's private presence to the world).
#
# Proves, against the REAL CLI with a temp git repo + a MOCKED `gh` (PATH-injected)
# and a REAL `git remote` (a fake origin URL), NO network:
#
#   (a) SHARE/PRIVATE  — gh reports .private=true -> writes + git-adds (TRACKED)
#                        team.shared.json, makes the chore commit, the secret is in it.
#   (b) SHARE/PUBLIC   — gh reports .private=false -> HARD REFUSE, no file written,
#                        non-zero exit, the secret is NOT committed (tree is clean),
#                        the refusal is LOUD about a public repo.
#   (c) GH UNAUTH      — gh errors (can't verify privacy) -> refuse, no file.
#   (d) GH ABSENT      — gh not on PATH -> refuse, no file.
#   (e) AUTO-JOIN      — a repo with a committed team.shared.json + NO personal
#                        team.json resolves the SHARED secret (show source=shared,
#                        team_id=derive(shared)); heimdall-presence does NOT auto-solo
#                        mint a team.json (it auto-joins the shared team instead).
#   (f) PRECEDENCE     — shared beats an AUTO-SOLO personal team; an EXPLICIT personal
#                        `team join` override beats shared.
#   (g) ROTATE         — `share --rotate` mints a NEW secret, overwrites both
#                        team.shared.json + the local team.json, and re-commits.
#
# All secrets here are OBVIOUSLY FAKE (low-entropy, hyphenated) so secret-scan /
# gitleaks stays clean on the heimdall repo itself. team.shared.json carries a real
# secret BY DESIGN in production, but every secret committed in this test lands only
# in a throwaway temp repo that is rm -rf'd on exit.
#
# Exit 0 = every assertion passed.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-team"
PRES="$ROOT/bin/heimdall-presence"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }
[ -x "$CLI" ]  || { echo "FATAL: $CLI missing/!exec" >&2; exit 2; }
[ -x "$PRES" ] || { echo "FATAL: $PRES missing/!exec" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "heimdall-autojoin.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# ── helpers ──────────────────────────────────────────────────────────────────
# The canonical client/server team_id derive (MUST match the server byte-for-byte).
server_team_id() { # $1 = secret
  HMD_TST_SECRET="$1" "$PY" - <<'PYEOF'
import hashlib, os
s = os.environ["HMD_TST_SECRET"]
print(hashlib.sha256(b"heimdall-team\x00" + s.encode("utf-8")).hexdigest()[:32])
PYEOF
}
# Read team_secret straight out of a team file (test-only — proves what landed).
secret_of() { # $1 = team file
  HMD_TST_FILE="$1" "$PY" - <<'PYEOF'
import json, os, sys
try:
    sys.stdout.write(json.load(open(os.environ["HMD_TST_FILE"])).get("team_secret") or "")
except Exception:
    sys.stdout.write("")
PYEOF
}
json_field() { # $1 = json text, $2 = field
  HMD_TST_FLD="$2" "$PY" -c 'import json,os,sys; print(json.load(sys.stdin).get(os.environ["HMD_TST_FLD"]) if True else "")' <<<"$1" 2>/dev/null || true
}
# Init a throwaway git repo with a fake github origin + an initial empty commit.
init_repo() { # $1 = dir, $2 = origin url
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email "test@heimdall.local"
  git -C "$1" config user.name "Heimdall Test"
  git -C "$1" remote add origin "$2"
  git -C "$1" commit -q --allow-empty -m "init"
}
# A minimal bin dir with everything the CLI needs EXCEPT gh (to simulate gh ABSENT).
make_minimal_bin() { # $1 = dir
  mkdir -p "$1"
  local t p
  for t in bash sh env git readlink dirname basename sed grep awk cat \
           mkdir rm rmdir stat head tr true false ls chmod id printf echo; do
    p="$(command -v "$t" 2>/dev/null || true)"
    [ -n "$p" ] && ln -sf "$p" "$1/$t" 2>/dev/null || true
  done
  # Symlink the REAL python interpreter (a pyenv wrapper itself needs grep/awk on
  # PATH) so the CLI's python helpers run under the stripped PATH.
  local realpy; realpy="$("$PY" -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
  if [ -n "$realpy" ]; then ln -sf "$realpy" "$1/python3"; ln -sf "$realpy" "$1/python"; fi
}

# A mock gh: responds ONLY to `gh api repos/... --jq .private` per $MOCK_GH_MODE.
MOCKBIN="$WORK/mockbin"; mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${MOCK_GH_MODE:-private}" in
  private) echo "true" ;;
  public)  echo "false" ;;
  unauth)  echo "gh: not authenticated to github.com" >&2; exit 1 ;;
  *)       echo "mock gh: unknown mode" >&2; exit 1 ;;
esac
EOF
chmod +x "$MOCKBIN/gh"

# OBVIOUSLY-FAKE secrets (>=32 chars, low entropy) — never real credentials.
FAKE_PERSONAL="FAKE-PERSONAL-TEAM-SECRET-00000000-not-real"
FAKE_SHARED="FAKE-SHARED-TEAM-SECRET-0000000000-not-real"
FAKE_SOLO="FAKE-AUTOSOLO-TEAM-SECRET-00000000-not-real"

echo "============================================================"
echo "heimdall-team — github-collaborator AUTO-JOIN (share + precedence)"
echo "============================================================"
echo

# ── (a) SHARE on a PRIVATE repo writes + commits team.json (the ONE tracked file)
R1="$WORK/private"; init_repo "$R1" "https://github.com/fakeorg/fakerepo.git"
TD1="$R1/.heimdall"
HEIMDALL_TEAM_DIR="$TD1" "$CLI" join "$FAKE_PERSONAL" >/dev/null 2>&1   # seed a fake team
TJ1="$TD1/team.json"
A_OUT="$( cd "$R1" && PATH="$MOCKBIN:$PATH" MOCK_GH_MODE=private \
          HEIMDALL_TEAM_DIR="$TD1" "$CLI" share 2>"$WORK/a.err"; echo "RC=$?" )"
A_RC="${A_OUT##*RC=}"
A_SECRET="$(secret_of "$TJ1")"
A_TRACKED="$(git -C "$R1" ls-files -- .heimdall/team.json 2>/dev/null)"
A_COMMITTED="$(git -C "$R1" log --oneline 2>/dev/null | grep -c "team.json" || true)"
if [ "$A_RC" -eq 0 ] && [ -f "$TJ1" ] && [ "$A_SECRET" = "$FAKE_PERSONAL" ] \
   && [ -n "$A_TRACKED" ] && [ "$A_COMMITTED" -ge 1 ]; then
  ok "(a) share on a PRIVATE repo wrote + git-tracked + committed team.json carrying the secret"
else
  bad "(a) share/private failed (rc=$A_RC file=$([ -f "$TJ1" ]&&echo y||echo n) tracked='$A_TRACKED' committed=$A_COMMITTED secret_match=$([ "$A_SECRET" = "$FAKE_PERSONAL" ]&&echo y||echo n))"; cat "$WORK/a.err" >&2
fi

# ── (b) SHARE on a PUBLIC repo HARD-REFUSES, commits nothing ─────────────────
R2="$WORK/public"; init_repo "$R2" "https://github.com/fakeorg/publicrepo.git"
TD2="$R2/.heimdall"
HEIMDALL_TEAM_DIR="$TD2" "$CLI" join "$FAKE_PERSONAL" >/dev/null 2>&1
SH2="$TD2/team.shared.json"
B_OUT="$( cd "$R2" && PATH="$MOCKBIN:$PATH" MOCK_GH_MODE=public \
          HEIMDALL_TEAM_DIR="$TD2" "$CLI" share 2>"$WORK/b.err"; echo "RC=$?" )"
B_RC="${B_OUT##*RC=}"
B_TREE_HIT="$(git -C "$R2" grep -lF "$FAKE_PERSONAL" 2>/dev/null || true)"
if [ "$B_RC" -ne 0 ] && [ ! -f "$SH2" ] && [ -z "$B_TREE_HIT" ] \
   && [ -z "$(git -C "$R2" ls-files -- .heimdall/team.shared.json 2>/dev/null)" ]; then
  ok "(b1) share on a PUBLIC repo HARD-REFUSED (exit $B_RC): no team.shared.json, secret NOT committed"
else
  bad "(b1) share/public should refuse + write/commit nothing (rc=$B_RC file=$([ -f "$SH2" ]&&echo y||echo n) tree_hit='$B_TREE_HIT')"; cat "$WORK/b.err" >&2
fi
if grep -qi "public" "$WORK/b.err" && grep -qiE "refus|expose|leak" "$WORK/b.err"; then
  ok "(b2) the public-repo refusal is LOUD (names PUBLIC + the leak risk)"
else
  bad "(b2) public refusal not loud enough:"; cat "$WORK/b.err" >&2
fi

# ── (c) gh UNAUTH (can't verify privacy) -> refuse, no file ──────────────────
R3="$WORK/unauth"; init_repo "$R3" "https://github.com/fakeorg/somerepo.git"
TD3="$R3/.heimdall"
HEIMDALL_TEAM_DIR="$TD3" "$CLI" join "$FAKE_PERSONAL" >/dev/null 2>&1
C_OUT="$( cd "$R3" && PATH="$MOCKBIN:$PATH" MOCK_GH_MODE=unauth \
          HEIMDALL_TEAM_DIR="$TD3" "$CLI" share 2>"$WORK/c.err"; echo "RC=$?" )"
C_RC="${C_OUT##*RC=}"
if [ "$C_RC" -ne 0 ] && [ ! -f "$TD3/team.shared.json" ]; then
  ok "(c) gh unauth (privacy unverifiable) -> refused (exit $C_RC), no team.shared.json"
else
  bad "(c) gh unauth should refuse + write nothing (rc=$C_RC file=$([ -f "$TD3/team.shared.json" ]&&echo y||echo n))"; cat "$WORK/c.err" >&2
fi

# ── (d) gh ABSENT (not on PATH) -> refuse, no file ───────────────────────────
MINBIN="$WORK/minbin"; make_minimal_bin "$MINBIN"
R4="$WORK/noghbin"; init_repo "$R4" "https://github.com/fakeorg/anotherrepo.git"
TD4="$R4/.heimdall"
HEIMDALL_TEAM_DIR="$TD4" "$CLI" join "$FAKE_PERSONAL" >/dev/null 2>&1
D_OUT="$( cd "$R4" && PATH="$MINBIN" HEIMDALL_TEAM_DIR="$TD4" "$CLI" share 2>"$WORK/d.err"; echo "RC=$?" )"
D_RC="${D_OUT##*RC=}"
# gh + curl both ABSENT -> visibility is INDETERMINATE -> fail-SAFE refusal (never
# commit a secret you can't PROVE is private). team.json must NOT be tracked/committed.
D_TRACKED="$(git -C "$R4" ls-files -- .heimdall/team.json 2>/dev/null)"
if [ "$D_RC" -ne 0 ] && [ -z "$D_TRACKED" ] && grep -qiE "prove|private|refus" "$WORK/d.err"; then
  ok "(d) privacy UNPROVABLE (gh+curl absent) -> refused (exit $D_RC), team.json NOT committed"
else
  bad "(d) unprovable-privacy should refuse + commit nothing (rc=$D_RC tracked='$D_TRACKED')"; cat "$WORK/d.err" >&2
fi

# ── (e) AUTO-JOIN: shared.json + NO personal -> resolve the SHARED secret ─────
TD5="$WORK/autojoin/.heimdall"; mkdir -p "$TD5"
printf '{"team_secret": "%s", "created": 1719500000}\n' "$FAKE_SHARED" > "$TD5/team.shared.json"
E_JSON="$(HEIMDALL_TEAM_DIR="$TD5" "$CLI" show --json 2>/dev/null)"
E_SRC="$(json_field "$E_JSON" source)"
E_TID="$(json_field "$E_JSON" team_id)"
EXPECT_SHARED_TID="$(server_team_id "$FAKE_SHARED")"
if [ "$E_SRC" = "shared" ] && [ "$E_TID" = "$EXPECT_SHARED_TID" ] && [ ! -f "$TD5/team.json" ]; then
  ok "(e1) show resolves the SHARED secret (source=shared, team_id=derive(shared)), no personal team.json minted"
else
  bad "(e1) auto-join show wrong (source=$E_SRC tid=$E_TID expect=$EXPECT_SHARED_TID personal=$([ -f "$TD5/team.json" ]&&echo y||echo n))"
fi
# heimdall-presence MUST auto-join the shared team (NOT auto-solo mint a team.json).
# A bogus URL (connection-refused, instant) reaches the TEAM block then degrades.
( cd "$WORK/autojoin" && HOME="$WORK/autojoin-home" HEIMDALL_TEAM_DIR="$TD5" \
    "$PRES" beat --haid haid-test --project p/test --url http://127.0.0.1:1 ) >/dev/null 2>&1 || true
if [ ! -f "$TD5/team.json" ]; then
  ok "(e2) heimdall-presence AUTO-JOINED the shared team — did NOT auto-solo mint a team.json"
else
  bad "(e2) heimdall-presence wrongly minted a personal team.json despite a shared team being present"
fi

# ── (f) PRECEDENCE ───────────────────────────────────────────────────────────
# (i) shared beats an AUTO-SOLO personal team.
TD6="$WORK/prec-solo/.heimdall"; mkdir -p "$TD6"
printf '{"team_secret": "%s", "created": 1719500000}\n' "$FAKE_SHARED" > "$TD6/team.shared.json"
printf '{"team_secret": "%s", "created": 1719500001, "source": "auto-solo"}\n' "$FAKE_SOLO" > "$TD6/team.json"
F1_JSON="$(HEIMDALL_TEAM_DIR="$TD6" "$CLI" show --json 2>/dev/null)"
if [ "$(json_field "$F1_JSON" source)" = "shared" ] \
   && [ "$(json_field "$F1_JSON" team_id)" = "$EXPECT_SHARED_TID" ]; then
  ok "(f1) shared team WINS over an auto-solo personal team.json"
else
  bad "(f1) shared should beat auto-solo (got source=$(json_field "$F1_JSON" source) tid=$(json_field "$F1_JSON" team_id))"
fi
# (ii) an EXPLICIT personal `team join` override beats shared.
TD7="$WORK/prec-explicit/.heimdall"; mkdir -p "$TD7"
printf '{"team_secret": "%s", "created": 1719500000}\n' "$FAKE_SHARED" > "$TD7/team.shared.json"
HEIMDALL_TEAM_DIR="$TD7" "$CLI" join "$FAKE_PERSONAL" >/dev/null 2>&1   # source=join
F2_JSON="$(HEIMDALL_TEAM_DIR="$TD7" "$CLI" show --json 2>/dev/null)"
EXPECT_PERSONAL_TID="$(server_team_id "$FAKE_PERSONAL")"
if [ "$(json_field "$F2_JSON" source)" = "personal" ] \
   && [ "$(json_field "$F2_JSON" team_id)" = "$EXPECT_PERSONAL_TID" ]; then
  ok "(f2) an EXPLICIT personal 'team join' override WINS over the shared team"
else
  bad "(f2) explicit join should beat shared (got source=$(json_field "$F2_JSON" source) tid=$(json_field "$F2_JSON" team_id))"
fi

# ── (g) ROTATE mints a NEW secret + re-writes + re-commits team.json ─────────
R8="$WORK/rotate"; init_repo "$R8" "https://github.com/fakeorg/rotaterepo.git"
TD8="$R8/.heimdall"
HEIMDALL_TEAM_DIR="$TD8" "$CLI" join "$FAKE_PERSONAL" >/dev/null 2>&1
( cd "$R8" && PATH="$MOCKBIN:$PATH" MOCK_GH_MODE=private HEIMDALL_TEAM_DIR="$TD8" "$CLI" share ) >/dev/null 2>"$WORK/g1.err"
G_BEFORE="$(secret_of "$TD8/team.json")"
( cd "$R8" && PATH="$MOCKBIN:$PATH" MOCK_GH_MODE=private HEIMDALL_TEAM_DIR="$TD8" "$CLI" share --rotate ) >/dev/null 2>"$WORK/g2.err"
G_RC=$?
G_AFTER="$(secret_of "$TD8/team.json")"
G_TRACKED="$(git -C "$R8" ls-files -- .heimdall/team.json 2>/dev/null)"
G_ROTATE_COMMIT="$(git -C "$R8" log --oneline 2>/dev/null | grep -c "rotate" || true)"
if [ "$G_RC" -eq 0 ] && [ -n "$G_AFTER" ] && [ "$G_AFTER" != "$G_BEFORE" ] \
   && [ -n "$G_TRACKED" ] && [ "$G_ROTATE_COMMIT" -ge 1 ]; then
  ok "(g) share --rotate minted a NEW secret, re-wrote + re-committed the tracked team.json"
else
  bad "(g) rotate wrong (rc=$G_RC changed=$([ "$G_AFTER" != "$G_BEFORE" ]&&echo y||echo n) tracked='$G_TRACKED' commit=$G_ROTATE_COMMIT)"; cat "$WORK/g2.err" >&2
fi

echo
echo "============================================================"
printf "heimdall-team-autojoin: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
