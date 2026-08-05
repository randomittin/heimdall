#!/usr/bin/env bash
#
# install-team-secret.test.sh — acceptance harness for install.sh's per-repo
# TEAM-secret step (the multi-tenant team-invite path).
#
# The team-invite one-liner is
#     curl -fsSL <install.sh> | HEIMDALL_TEAM_SECRET='<secret>' bash
# A teammate who pastes it must land in the INVITER's team — not fall through to
# client auto-solo and end up in their OWN team. That only works if install.sh
# consumes HEIMDALL_TEAM_SECRET and writes it to the JOINING dev's per-repo store
# <repo>/.heimdall/team.json (0600, {team_secret,created}). This harness proves:
#
#   1. ENV-DRIVEN WRITE — a scripted install with HEIMDALL_TEAM_SECRET writes
#      <repo>/.heimdall/team.json (the git toplevel of the invocation CWD) with
#      the secret, mode 0600, in the {team_secret, created} shape, created an int.
#   2. IDEMPOTENT — a second identical run leaves the same secret, no error, exit 0.
#   3. PRECEDENCE OVER AUTO-SOLO — an already-present team.json carrying a DIFFERENT
#      secret (a solo team a prior presence beat minted) is overwritten by the
#      install-supplied invite secret, so the invite wins.
#   4. NON-INTERACTIVE CLEAN SKIP — with NO env and stdin not a TTY (curl|bash /
#      CI), install NEVER hangs, writes no team.json, and exits 0 (dev gets auto-solo).
#   5. NO SECRET LEAK — the team secret appears in NO tracked file and NEVER in the
#      install's own stdout/log (it lives 0600 in the per-repo store only).
#   6. GITIGNORE — <repo>/.heimdall/team.json can never be committed.
#
# Usage:  test/install-team-secret.test.sh
# Exit 0 = all guarantees hold. Non-zero = a guarantee regressed (prints which).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
REF="$(git -C "$REPO" rev-parse HEAD)"

# ── Hermeticity guard ────────────────────────────────────────────────────────
# This suite runs the REAL install.sh, which resolves an existing `hmd` via
# `command -v hmd`. If the dev's inherited PATH carries <repo>/bin, the installer
# would treat the repo's OWN tracked bin/hmd as a stale shadow and OVERWRITE it in
# place — mutating a tracked file (the dev-env-breaking bug). Two defenses:
#   1) run install.sh under a CONTROLLED PATH (SYS) — python3/git + system dirs
#      only, never the inherited PATH — so `command -v hmd` finds nothing to touch;
#   2) the clobber target is a PRIVATE CLONE (see $SRC below), diffed by content.
SYS="$(dirname "$(command -v python3)"):$(dirname "$(command -v git)"):/usr/bin:/bin"

# An obviously-fake secret (>= 32 chars so it passes the weak-secret gate) so the
# "no leak" grep is meaningful — it must appear in NO tracked file, only in the
# throwaway repo store under test. NOT a real token (secret-scan stays clean).
TEAM_SECRET="FAKETEAMSECRET-deadbeef-NEVER-COMMIT-0xCAFEBABE-aGVpbWRhbGw"
# A distinct fake "auto-solo" secret to prove the invite secret takes precedence.
SOLO_SECRET="FAKESOLOSECRET-c0ffee-AUTO-MINTED-0xDECAFBAD-c29sbw"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# ── Fake `claude`: satisfy install's preflight + plugin steps with no network ──
FAKE_DIR="$(mktemp -d)"
cat > "$FAKE_DIR/claude" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "1.5.0 (Claude Code)"; exit 0 ;;
  plugins)   exit 0 ;;
  *)         exit 0 ;;
esac
EOF
chmod +x "$FAKE_DIR/claude"

TMP_ROOT="$(mktemp -d)"
# Cleanup touches ONLY this suite's own temp dirs. It deliberately does NOT revert
# anything in the developer's tree — see the $SRC note below for why that reverting
# tripwire was removed.
cleanup() {
  rm -rf "$FAKE_DIR" "$TMP_ROOT"
}
trap cleanup EXIT

# ── THE CLOBBER TARGET: a PRIVATE source checkout ─────────────────────────────
# The guarantee under test is "install.sh, pointed at a LOCAL checkout, never writes
# into that checkout's bin/" (install.sh pins it via SOURCE_GUARD_ROOTS, keyed on
# HEIMDALL_REPO). This test used to point the installer at the DEVELOPER'S OWN worktree
# and diff `git status --porcelain -- bin/` before/after. That was unsound twice over:
#   - FALSE REDS: the snapshot spans the whole ~30s run, so ANY concurrent edit to bin/
#     by a teammate or a parallel agent was misattributed to install.sh (run-all.sh runs
#     suites in PARALLEL, so this was not hypothetical).
#   - DESTRUCTIVE: on mismatch the cleanup trap ran `git checkout -- bin/` against that
#     SHARED tree, discarding a teammate's uncommitted work to "restore" it. Measured:
#     a landed bin/heimdall-modules change was silently reverted mid-session.
# The installer now gets its own private clone, so the clobber target cannot be touched
# by anyone else. The guarantee is unchanged; the measurement is now deterministic and
# no shared tree is ever written to or reverted.
SRC="$TMP_ROOT/src"
git clone --quiet "$REPO" "$SRC" 2>/dev/null \
  || { echo "FATAL: could not create the private source clone of $REPO"; exit 2; }

# Content manifest of bin/: sha256 of every file plus the set of executables. STRICTLY
# STRONGER than the old `git status --porcelain -- bin/`, which reports only files git
# tracks — a write to a gitignored or untracked path under bin/ was invisible to it and
# is caught here.
bin_manifest() {
  find "$1/bin" -type f -print0 2>/dev/null | LC_ALL=C sort -z \
    | xargs -0 shasum -a 256 2>/dev/null
  find "$1/bin" -type f -perm -u+x -print 2>/dev/null | LC_ALL=C sort
}
BIN_GUARD_BEFORE="$(bin_manifest "$SRC")"
# Anti-vacuous: an empty manifest would make the clobber assertion pass trivially.
[ -n "$BIN_GUARD_BEFORE" ] \
  || { echo "FATAL: private clone has no bin/ files — the clobber guard would be vacuous"; exit 2; }

# Owner perm bits of a path, portable across macOS (stat -f) and Linux (stat -c).
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }

# Read team.json's secret + created via python (mirrors bin/heimdall-team).
read_team() { # $1=team.json  -> prints "<secret>\t<created>"
  HMD_F="$1" python3 - <<'PY' 2>/dev/null
import json, os
d = json.load(open(os.environ["HMD_F"]))
c = d.get("created")
print("%s\t%s" % (d.get("team_secret",""), c if isinstance(c,int) else ""))
PY
}

# Run install.sh from this working tree (the installer under test — so uncommitted
# changes to install.sh ARE covered) against a fresh HOME, with a fake claude on PATH
# and the real environment's secrets unset. CWD is set to $1 (a fresh git repo) so the
# per-repo team store resolves there — never the developer's real tree. HEIMDALL_REPO
# points at the PRIVATE CLONE, so the tree the installer may write into is $SRC and
# never the developer's own. stdin is /dev/null so the TTY-gated prompt path is NOT
# taken (mirrors curl|bash).
run_install() { # $1=workdir(repo)  $2=HOME  $3=TEAM_SECRET (may be empty)
  ( cd "$1" && env -u CLAUDE_CONFIG_DIR -u HEIMDALL_HOME -u HEIMDALL_FORCE \
        -u HEIMDALL_CP_PKI_KEY -u PKI_SEED -u BASE_URL -u HEIMDALL_TEAM_DIR \
        HOME="$2" TERM="dumb" HEIMDALL_NO_COLOR=1 \
        HEIMDALL_REPO="$SRC" HEIMDALL_REF="$REF" \
        HEIMDALL_TEAM_SECRET="$3" \
        PATH="$FAKE_DIR:$SYS" \
        bash "$REPO/install.sh" </dev/null 2>&1 )
}

# Run a command with a hard wall-clock cap; return 124 if it had to be killed (hung).
run_capped() { # $1=secs  $2=outfile  rest=cmd…
  local secs="$1" out="$2"; shift 2
  "$@" > "$out" 2>&1 &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1; i=$((i+1))
    if [ "$i" -ge "$secs" ]; then
      kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124
    fi
  done
  wait "$pid"; return $?
}

# A fresh git repo to play the "joining dev's project" — team.json resolves to its
# toplevel, exactly as a teammate pasting the invite inside their checkout. Takes an
# explicit unique name (not a mutated counter — new_repo runs in a $() subshell, so a
# global counter would never persist and every call would collide on one dir).
new_repo() { # $1=name -> prints path
  local d="$TMP_ROOT/repo-$1"
  mkdir -p "$d"; git -C "$d" init -q 2>/dev/null
  printf '%s' "$d"
}

echo "install-team-secret harness  repo=$REPO  ref=${REF:0:12}"
echo "--------------------------------------------------------------------"

# ── (6) GITIGNORE: the per-repo team.json can never be committed ────────────────
( cd "$REPO"
  for p in team.json .heimdall/team.json; do
    if git check-ignore -q "$p"; then :; else echo "LEAK:$p"; fi
  done
) > "$TMP_ROOT/ignore.out" 2>/dev/null
if grep -q '^LEAK:' "$TMP_ROOT/ignore.out"; then
  bad "team.json is NOT gitignored: $(grep '^LEAK:' "$TMP_ROOT/ignore.out" | tr '\n' ' ')"
else
  ok  "gitignore: <repo>/.heimdall/team.json (and root team.json) are ignored"
fi

# ── (1) ENV-DRIVEN WRITE ───────────────────────────────────────────────────────
R1="$(new_repo env)"; H1="$TMP_ROOT/home-env"; mkdir -p "$H1"
run_install "$R1" "$H1" "$TEAM_SECRET" > "$TMP_ROOT/env.out" 2>&1
TJ="$R1/.heimdall/team.json"
if [ -f "$TJ" ]; then
  GOT="$(read_team "$TJ")"; GOT_SEC="${GOT%%	*}"; GOT_CREATED="${GOT##*	}"
  if [ "$GOT_SEC" = "$TEAM_SECRET" ]; then
    ok "env install wrote <repo>/.heimdall/team.json with the team_secret"
  else
    bad "team.json secret mismatch (wrote the wrong value)"
  fi
  if [ -n "$GOT_CREATED" ]; then
    ok "team.json carries an integer 'created' epoch (shape {team_secret,created})"
  else
    bad "team.json missing/invalid 'created' epoch"
  fi
  M="$(mode_of "$TJ")"
  [ "$M" = "600" ] && ok "team.json is mode 0600" || bad "team.json mode is $M, want 600"
else
  bad "env install did NOT write $TJ"
fi

# ── (2) IDEMPOTENT — second identical run, same secret, exit 0, no error ────────
run_install "$R1" "$H1" "$TEAM_SECRET" > "$TMP_ROOT/env2.out" 2>&1; RC2=$?
GOT2="$(read_team "$TJ")"; GOT2_SEC="${GOT2%%	*}"
if [ "$RC2" -eq 0 ] && [ "$GOT2_SEC" = "$TEAM_SECRET" ]; then
  ok "idempotent re-run: same secret preserved, exit 0"
else
  bad "idempotent re-run regressed — exit=$RC2 secret-match=$([ "$GOT2_SEC" = "$TEAM_SECRET" ] && echo yes || echo no)"
fi

# ── (3) PRECEDENCE OVER AUTO-SOLO — invite secret overwrites a different one ────
R3="$(new_repo solo)"; H3="$TMP_ROOT/home-solo"; mkdir -p "$H3"
# Pre-seed a "solo" team.json (what a prior presence beat would auto-mint).
mkdir -p "$R3/.heimdall"
printf '{"team_secret": "%s", "created": 1700000000}\n' "$SOLO_SECRET" > "$R3/.heimdall/team.json"
chmod 0600 "$R3/.heimdall/team.json"
run_install "$R3" "$H3" "$TEAM_SECRET" > "$TMP_ROOT/solo.out" 2>&1
GOT3="$(read_team "$R3/.heimdall/team.json")"; GOT3_SEC="${GOT3%%	*}"
if [ "$GOT3_SEC" = "$TEAM_SECRET" ]; then
  ok "invite secret takes precedence over an existing auto-solo team.json"
else
  bad "auto-solo team.json was NOT overwritten by the invite secret (got the solo value)"
fi

# ── (4) NON-INTERACTIVE CLEAN SKIP (no env, stdin /dev/null, must not hang) ─────
R4="$(new_repo noenv)"; H4="$TMP_ROOT/home-noenv"; mkdir -p "$H4"
run_capped 90 "$TMP_ROOT/noenv.out" run_install "$R4" "$H4" ""
RC4=$?
if [ "$RC4" -eq 124 ]; then
  bad "non-interactive install HUNG (no team secret, stdin /dev/null) — killed after 90s"
elif [ "$RC4" -ne 0 ]; then
  bad "non-interactive install exited $RC4 (want 0 — a missing team secret is a clean skip)"
elif [ -f "$R4/.heimdall/team.json" ]; then
  bad "non-interactive install wrote a team.json with no secret supplied"
else
  ok "non-interactive install: no hang, no team.json written, exit 0 (dev gets auto-solo)"
fi

# ── (5) NO SECRET LEAK — never in a tracked file, never in install's own stdout ──
SELF="test/install-team-secret.test.sh"
LEAK_TRACKED="$(cd "$REPO" && git grep -lF "$TEAM_SECRET" -- $(git ls-files) 2>/dev/null | grep -vxF "$SELF")"
if [ -n "$LEAK_TRACKED" ]; then
  bad "team secret leaked into a tracked file: $LEAK_TRACKED"
else
  ok "team secret never appears in any tracked file"
fi
# The installer must NEVER echo the secret to stdout/stderr (no logging of secrets).
if grep -qF "$TEAM_SECRET" "$TMP_ROOT/env.out" "$TMP_ROOT/env2.out" "$TMP_ROOT/solo.out" 2>/dev/null; then
  bad "install printed the team secret to its output (logging a secret)"
else
  ok "install never echoes the team secret to stdout/stderr"
fi

# ── (7) HERMETIC — the install runs left the source checkout's bin/ pristine ────
# Byte-for-byte over EVERY file under bin/ (not just the git-tracked ones), against a
# private clone no other process can touch — so a mismatch here can only have been
# caused by install.sh itself.
BIN_GUARD_AFTER="$(bin_manifest "$SRC")"
if [ "$BIN_GUARD_AFTER" = "$BIN_GUARD_BEFORE" ]; then
  ok "hermetic: install runs never mutated the source checkout's bin/ (no clobber)"
else
  bad "install run MUTATED the source checkout's bin/ (non-hermetic): $(
    diff <(printf '%s\n' "$BIN_GUARD_BEFORE") <(printf '%s\n' "$BIN_GUARD_AFTER") \
      | grep -E '^[<>]' | head -4 | tr '\n' ' ')"
fi

# ── Tally ──────────────────────────────────────────────────────────────────────
echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
