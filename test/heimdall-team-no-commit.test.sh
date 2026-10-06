#!/usr/bin/env bash
# heimdall-team-no-commit.test.sh — the HMD_TEAM_NO_COMMIT off switch.
#
# THE CLAIM. In a repo it can PROVE is private, `hmd team` commits <repo>/.heimdall/team.json
# (git add -f + a local commit, never pushed) so a clone auto-joins. Some teams do not want a
# bearer secret in git history at all. HMD_TEAM_NO_COMMIT=1 — or, persistently, the marker file
# ~/.heimdall/no-team-commit — keeps team.json fully maintained ON DISK (minted, joined, rotated:
# presence works exactly as before) but NEVER staged or committed: not by heimdall-team
# (new / share / rotate / auto / bare `hmd team`) and not by bin/heimdall-wip-commit, whose blanket
# `git add -A` would otherwise sweep a tracked-and-modified or un-ignored copy into a checkpoint.
#
# HOW IT IS PROVEN — real CLIs, real throwaway git repos, no network, no gh on PATH:
#   * a `git` SHIM on PATH logs every invocation, then execs the real git. "Never stages/commits"
#     is asserted as ZERO `add` / `commit` calls from heimdall-team — stronger than "HEAD did not
#     move", which a stage-then-unstage would also satisfy.
#   * repo state is asserted as well: HEAD unmoved, index empty, team.json untracked yet present
#     on disk (0600, a real secret) and invisible to a blanket `git add -A` (`git status` clean).
#   * the OFF case is the control: the same flows with the switch unset / 0 / off still commit.
#
# Sections: A control · B env switch · C marker file · D value parsing · E wip-commit ·
#           F public repo · G --help + docs
#
# Usage: bash test/heimdall-team-no-commit.test.sh   (exit 0 = every assertion held)
#
# SC2015 is silenced file-wide on purpose: every assertion is `[ cond ] && ok ... || bad ...`
# (the idiom of this suite family), and ok/bad are printf + arithmetic that always return 0,
# so `bad` can never run after a passing `ok` — the "A && B || C" hazard does not exist here.
# shellcheck disable=SC2015
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM="$ROOT/bin/heimdall-team"
WIP="$ROOT/bin/heimdall-wip-commit"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

[ -x "$TEAM" ] || { echo "FATAL: $TEAM not executable" >&2; exit 2; }
[ -x "$WIP" ]  || { echo "FATAL: $WIP not executable" >&2; exit 2; }
bash -n "$TEAM" || { echo "FATAL: syntax error in $TEAM" >&2; exit 2; }
bash -n "$WIP"  || { echo "FATAL: syntax error in $WIP" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }
REAL_GIT="$(command -v git || true)"
[ -n "$REAL_GIT" ] || { echo "FATAL: git not found" >&2; exit 2; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Hermetic git: no global/system config, no ambient excludesFile — a developer's own
# ~/.gitignore_global must not change what `git add -A` sweeps in here.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$T/xdg"

# Hermetic against the operator's own switch too: every case below sets the switch itself (env var per
# `run`, marker in that case's own HOME), so an exported HMD_TEAM_NO_COMMIT must not leak into the A-section
# controls ("the commit still happens"). This suite tests the switch; it must not INHERIT it.
# shellcheck source=lib/hermetic-team-env.sh disable=SC1091  # plain shellcheck (no -x) never opens sourced files
. "$ROOT/test/lib/hermetic-team-env.sh"; hermetic_team_env "$T" || exit 2

# The git shim: every call is appended to $GIT_SHIM_LOG, then handed to the real git untouched.
SHIM="$T/shim"
mkdir -p "$SHIM"
cat > "$SHIM/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${GIT_SHIM_LOG:-/dev/null}"
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SHIM/git"

# A throwaway PRIVATE-looking client repo: a github origin, one initial commit that already carries
# the heimdall-active marker (.heimdall/identity.json, so `auto` treats heimdall as ACTIVE here), and
# NO .gitignore — the typical client repo, where nothing keeps .heimdall/team.json out of git.
# Each repo gets its OWN fresh HOME ($T/home-<name>) so the marker file is per-case.
mkrepo() { # <name> -> prints the repo dir
  local n="$1" r="$T/$1"
  mkdir -p "$r/.heimdall" "$T/home-$n"
  "$REAL_GIT" -C "$r" init -q
  "$REAL_GIT" -C "$r" remote add origin "https://github.com/fakeorg/$n.git"
  "$REAL_GIT" -C "$r" config user.email t@t.t
  "$REAL_GIT" -C "$r" config user.name t
  printf 'hello\n' > "$r/README.md"
  printf '{}' > "$r/.heimdall/identity.json"
  "$REAL_GIT" -C "$r" add README.md .heimdall/identity.json
  "$REAL_GIT" -C "$r" commit -q --no-verify -m "initial commit"
  : > "$T/log-$n"
  printf '%s' "$r"
}

# Run a command from inside repo $1 in heimdall-team's world: visibility forced to private (the
# documented HEIMDALL_FORCE_VISIBILITY seam — no gh / curl probe), the repo's own HOME, a PATH with
# the git shim and NO gh (so the GitHub AUTO path defers and the bearer-secret path is exercised).
# Later VAR=val arguments override the defaults, e.g. HEIMDALL_FORCE_VISIBILITY=public.
run() { # <repo> [VAR=val ...] <cmd...>
  local r="$1" n; n="$(basename "$1")"; shift
  ( cd "$r" && env PATH="$SHIM:/usr/bin:/bin" HOME="$T/home-$n" \
      HEIMDALL_FORCE_VISIBILITY=private GIT_SHIM_LOG="$T/log-$n" "$@" )
}

ncommits() { "$REAL_GIT" -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }
staged()   { "$REAL_GIT" -C "$1" diff --cached --name-only 2>/dev/null; }
tracked()  { "$REAL_GIT" -C "$1" ls-files -- .heimdall/team.json 2>/dev/null; }
ignored()  { "$REAL_GIT" -C "$1" check-ignore -q .heimdall/team.json 2>/dev/null; }
dirty()    { "$REAL_GIT" -C "$1" status --porcelain 2>/dev/null; }
mut_calls() { # number of `git add` / `git commit` invocations the shim has logged for repo $1
  local c; c="$(grep -cE '(^| )(add|commit)( |$)' "$T/log-$(basename "$1")" 2>/dev/null)"
  printf '%s' "${c:-0}"
}
jfield() { HMD_F="$1" HMD_K="$2" "$PY" -c 'import json,os; print(json.load(open(os.environ["HMD_F"])).get(os.environ["HMD_K"]) or "")' 2>/dev/null; }
perm_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null || echo '?'; }
sum_of()  { cksum < "$1" 2>/dev/null; }

# A pre-existing team, written straight to disk (no heimdall-team run — each of those costs ~2s of
# interpreter starts, and the flow under test should be the only thing exercising the CLI).
# `tracked` also commits it, exactly as a switch-OFF `hmd team` would have left the repo.
seed_team() { # <repo> [tracked]
  printf '{"team_secret": "seeded-team-secret-0123456789abcdef", "created": 1700000000, "source": "new"}\n' > "$1/.heimdall/team.json"
  chmod 600 "$1/.heimdall/team.json"
  if [ "${2:-}" = tracked ]; then
    "$REAL_GIT" -C "$1" add -f .heimdall/team.json
    "$REAL_GIT" -C "$1" commit -q --no-verify -m "track team.json"
  fi
}

# The full "switch is on and held" assertion bundle for a repo whose team.json was just touched by
# a flow that WOULD have committed. $1=repo $2=commit count before $3=label
assert_held() {
  local r="$1" before="$2" label="$3"
  [ "$(mut_calls "$r")" -eq 0 ] && ok "$label: ZERO git add/commit calls" || bad "$label: git add/commit was invoked $(mut_calls "$r")x"
  [ "$(ncommits "$r")" -eq "$before" ] && ok "$label: HEAD unmoved" || bad "$label: HEAD moved ($before -> $(ncommits "$r"))"
  [ -z "$(staged "$r")" ] && ok "$label: nothing staged" || bad "$label: staged: $(staged "$r" | tr '\n' ' ')"
  [ -z "$(tracked "$r")" ] && ok "$label: team.json not tracked" || bad "$label: team.json is TRACKED"
}
assert_on_disk() { # $1=repo $2=label — team.json is present, 0600, carries a real secret
  local f="$1/.heimdall/team.json" s
  s="$(jfield "$f" team_secret)"
  [ "${#s}" -eq 43 ] && ok "$2: team.json kept on disk (43-char secret)" || bad "$2: team.json missing/odd on disk (secret len ${#s})"
  [ "$(perm_of "$f")" = "600" ] && ok "$2: team.json is 0600" || bad "$2: team.json perms $(perm_of "$f")"
}
assert_swept_by_nothing() { # $1=repo $2=label — a blanket `git add -A` has nothing to take
  ignored "$1" && ok "$2: team.json excluded locally (blanket git add cannot sweep it)" || bad "$2: team.json is not ignored/excluded"
  [ -z "$(dirty "$1")" ] && ok "$2: git status clean" || bad "$2: git status dirty: $(dirty "$1" | tr '\n' '|')"
}

echo "A. CONTROL — switch unset / 0 / empty: the commit still happens (behavior unchanged)"
R="$(mkrepo ctl-new)"; B="$(ncommits "$R")"
run "$R" bash "$TEAM" new >/dev/null 2>&1
[ -n "$(tracked "$R")" ] && ok "new/private: team.json committed (TRACKED)" || bad "new/private: team.json not tracked"
[ "$(ncommits "$R")" -eq $((B + 1)) ] && ok "new/private: exactly one commit added" || bad "new/private: commits $B -> $(ncommits "$R")"
[ "$(mut_calls "$R")" -ge 2 ] && ok "new/private: shim saw git add + git commit" || bad "new/private: shim saw $(mut_calls "$R") add/commit calls"

R="$(mkrepo ctl-auto)"; B="$(ncommits "$R")"
run "$R" bash "$TEAM" auto >/dev/null 2>&1
[ -n "$(tracked "$R")" ] && [ "$(ncommits "$R")" -eq $((B + 1)) ] && ok "auto/private+active: team.json committed" || bad "auto/private+active: not committed"
grep -q "auto-committed" "$T/home-ctl-auto/.heimdall/team-auto.log" 2>/dev/null && ok "auto: logs the commit it made" || bad "auto: no 'auto-committed' log line"

for v in 0 ""; do
  R="$(mkrepo "ctl-val-${v:-empty}")"; B="$(ncommits "$R")"
  run "$R" "HMD_TEAM_NO_COMMIT=$v" bash "$TEAM" new >/dev/null 2>&1
  [ -n "$(tracked "$R")" ] && [ "$(ncommits "$R")" -eq $((B + 1)) ] \
    && ok "HMD_TEAM_NO_COMMIT='$v' is OFF: new still commits" || bad "HMD_TEAM_NO_COMMIT='$v' wrongly suppressed the commit"
done

echo "B. HMD_TEAM_NO_COMMIT=1 — team.json stays on disk, is never staged or committed"
R="$(mkrepo on-new)"; B="$(ncommits "$R")"
OUT="$(run "$R" HMD_TEAM_NO_COMMIT=1 bash "$TEAM" new 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "new: exit 0" || bad "new: exit $RC"
assert_held "$R" "$B" "new"
assert_on_disk "$R" "new"
assert_swept_by_nothing "$R" "new"
case "$OUT" in *"NOT committed"*) ok "new: says plainly that it did NOT commit" ;; *) bad "new: output never says NOT committed: $OUT" ;; esac

R="$(mkrepo on-auto)"; B="$(ncommits "$R")"
run "$R" HMD_TEAM_NO_COMMIT=1 bash "$TEAM" auto >/dev/null 2>&1
assert_held "$R" "$B" "auto"
assert_on_disk "$R" "auto"
assert_swept_by_nothing "$R" "auto"
grep -q "auto-committed" "$T/home-on-auto/.heimdall/team-auto.log" 2>/dev/null \
  && bad "auto: logged 'auto-committed' for a commit that never happened" || ok "auto: no false 'auto-committed' log line"

R="$(mkrepo on-share)"; seed_team "$R"
S0="$(jfield "$R/.heimdall/team.json" team_secret)"; B="$(ncommits "$R")"
OUT="$(run "$R" HMD_TEAM_NO_COMMIT=1 bash "$TEAM" share 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "share: exit 0" || bad "share: exit $RC"
assert_held "$R" "$B" "share"
[ "$(jfield "$R/.heimdall/team.json" team_secret)" = "$S0" ] && ok "share: the team secret is unchanged" || bad "share: secret changed"
case "$OUT" in *"NOT committed"*) ok "share: says plainly that it did NOT commit" ;; *) bad "share: output never says NOT committed: $OUT" ;; esac

R="$(mkrepo on-rotate)"; seed_team "$R"
S0="$(jfield "$R/.heimdall/team.json" team_secret)"; B="$(ncommits "$R")"
run "$R" HMD_TEAM_NO_COMMIT=1 bash "$TEAM" rotate >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "rotate: exit 0" || bad "rotate: exit $RC"
S1="$(jfield "$R/.heimdall/team.json" team_secret)"
[ -n "$S1" ] && [ "$S1" != "$S0" ] && ok "rotate: a FRESH secret was written to disk" || bad "rotate: secret not rotated on disk"
assert_held "$R" "$B" "rotate"

R="$(mkrepo on-bare)"; seed_team "$R"
SUM0="$(sum_of "$R/.heimdall/team.json")"; B="$(ncommits "$R")"
OUT="$(run "$R" HMD_TEAM_NO_COMMIT=1 bash "$TEAM" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "bare 'hmd team': exit 0" || bad "bare 'hmd team': exit $RC"
assert_held "$R" "$B" "bare 'hmd team'"
[ "$(sum_of "$R/.heimdall/team.json")" = "$SUM0" ] && ok "bare 'hmd team': team.json not rewritten on every call" || bad "bare 'hmd team': team.json rewritten"
case "$OUT" in *"configured: yes"*) ok "bare 'hmd team': shows status instead of a promotion" ;; *) bad "bare 'hmd team': no status shown: $OUT" ;; esac

R="$(mkrepo on-bare-fresh)"; B="$(ncommits "$R")"
run "$R" HMD_TEAM_NO_COMMIT=1 bash "$TEAM" >/dev/null 2>&1
assert_held "$R" "$B" "bare 'hmd team' (no team yet)"
assert_on_disk "$R" "bare 'hmd team' (no team yet)"

JOIN_SECRET="$(printf 'fake-team-%.0s' 1 2 3 4)"                # 40 chars: past join's 32-char floor, never a real credential
R="$(mkrepo on-join)"; B="$(ncommits "$R")"
run "$R" HMD_TEAM_NO_COMMIT=1 bash "$TEAM" join "$JOIN_SECRET" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "join: exit 0" || bad "join: exit $RC"
assert_held "$R" "$B" "join"
[ "$(jfield "$R/.heimdall/team.json" team_secret)" = "$JOIN_SECRET" ] && ok "join: the teammate's secret is on disk" || bad "join: secret not written"
assert_swept_by_nothing "$R" "join"
R="$(mkrepo ctl-join)"
run "$R" bash "$TEAM" join "$JOIN_SECRET" >/dev/null 2>&1
[ -z "$(tracked "$R")" ] && ! ignored "$R" && ok "control: join WITHOUT the switch touches nothing in git (untracked, not excluded)" || bad "control: join without the switch changed git state"

R="$(mkrepo on-tracked)"; seed_team "$R" tracked              # committed earlier, as a switch-OFF run would
S0="$(jfield "$R/.heimdall/team.json" team_secret)"; B="$(ncommits "$R")"
OUT="$(run "$R" HMD_TEAM_NO_COMMIT=1 bash "$TEAM" rotate 2>&1)"
S1="$(jfield "$R/.heimdall/team.json" team_secret)"
[ -n "$S1" ] && [ "$S1" != "$S0" ] && ok "already-tracked + rotate: new secret written to disk" || bad "already-tracked + rotate: disk secret not updated"
[ "$(mut_calls "$R")" -eq 0 ] && ok "already-tracked + rotate: ZERO git add/commit calls" || bad "already-tracked + rotate: git add/commit invoked"
[ "$(ncommits "$R")" -eq "$B" ] && ok "already-tracked + rotate: HEAD unmoved" || bad "already-tracked + rotate: HEAD moved"
[ -z "$(staged "$R")" ] && ok "already-tracked + rotate: nothing staged" || bad "already-tracked + rotate: staged $(staged "$R")"
[ -n "$(tracked "$R")" ] && ok "already-tracked + rotate: file stays tracked (never silently untracked)" || bad "already-tracked + rotate: file got untracked"
case "$OUT" in *"git rm --cached"*) ok "already-tracked + rotate: tells the dev how to stop tracking" ;; *) bad "already-tracked + rotate: no 'git rm --cached' hint: $OUT" ;; esac

echo "C. ~/.heimdall/no-team-commit — the persistent equivalent (no env var at all)"
R="$(mkrepo mk-new)"; B="$(ncommits "$R")"
mkdir -p "$T/home-mk-new/.heimdall"; : > "$T/home-mk-new/.heimdall/no-team-commit"
run "$R" bash "$TEAM" new >/dev/null 2>&1
assert_held "$R" "$B" "marker/new"
assert_on_disk "$R" "marker/new"
assert_swept_by_nothing "$R" "marker/new"

R="$(mkrepo mk-auto)"; B="$(ncommits "$R")"
mkdir -p "$T/home-mk-auto/.heimdall"; : > "$T/home-mk-auto/.heimdall/no-team-commit"
run "$R" bash "$TEAM" auto >/dev/null 2>&1
assert_held "$R" "$B" "marker/auto"
assert_on_disk "$R" "marker/auto"

echo "D. value parsing — fail-safe: anything but empty/0/false/no/off turns the switch ON"
# Repo names are numbered, never derived from the value: macOS's default filesystem is
# case-insensitive, so val-true and val-TRUE would be the SAME directory.
i=0
for v in true yes 2; do
  i=$((i + 1)); R="$(mkrepo "von$i")"; B="$(ncommits "$R")"
  run "$R" "HMD_TEAM_NO_COMMIT=$v" bash "$TEAM" new >/dev/null 2>&1
  [ "$(mut_calls "$R")" -eq 0 ] && [ "$(ncommits "$R")" -eq "$B" ] && [ -z "$(tracked "$R")" ] \
    && ok "HMD_TEAM_NO_COMMIT=$v is ON (no commit)" || bad "HMD_TEAM_NO_COMMIT=$v failed OPEN and committed a secret"
done
i=0
for v in FALSE No off; do
  i=$((i + 1)); R="$(mkrepo "voff$i")"; B="$(ncommits "$R")"
  run "$R" "HMD_TEAM_NO_COMMIT=$v" bash "$TEAM" new >/dev/null 2>&1
  [ -n "$(tracked "$R")" ] && [ "$(ncommits "$R")" -eq $((B + 1)) ] \
    && ok "HMD_TEAM_NO_COMMIT=$v is OFF (commits as before)" || bad "HMD_TEAM_NO_COMMIT=$v wrongly suppressed the commit"
done

echo "E. bin/heimdall-wip-commit honors the same switch (its blanket 'git add -A' would sweep team.json)"
# wip_case <name> <tracked|untracked> [VAR=val ...] -> prints "yes"/"no": did team.json ride the
# checkpoint commit? A real change to another file always rides it, so the commit always exists.
wip_case() {
  local n="$1" mode="$2" r; shift 2
  r="$(mkrepo "$n")"
  printf '{"team_secret":"fake-a"}\n' > "$r/.heimdall/team.json"
  if [ "$mode" = tracked ]; then
    "$REAL_GIT" -C "$r" add -f .heimdall/team.json
    "$REAL_GIT" -C "$r" commit -q --no-verify -m "track team.json"
    printf '{"team_secret":"fake-b"}\n' > "$r/.heimdall/team.json"   # a later on-disk update
  fi
  printf 'work\n' > "$r/other.txt"
  ( cd "$r" && env PATH="$SHIM:/usr/bin:/bin" HOME="$T/home-$n" "$@" bash "$WIP" checkpoint ) >/dev/null 2>&1
  if ! "$REAL_GIT" -C "$r" show --name-only --format= HEAD | grep -qx 'other.txt'; then
    printf 'NOCOMMIT'; return
  fi
  if "$REAL_GIT" -C "$r" show --name-only --format= HEAD | grep -qx '.heimdall/team.json'; then printf 'yes'; else printf 'no'; fi
}
[ "$(wip_case wip-tr-ctl tracked)" = yes ]                          && ok "control (tracked, no switch): checkpoint carries team.json" || bad "control (tracked): checkpoint did not carry team.json"
[ "$(wip_case wip-un-ctl untracked)" = yes ]                        && ok "control (untracked, no switch): checkpoint carries team.json" || bad "control (untracked): checkpoint did not carry team.json"
[ "$(wip_case wip-tr-off tracked HMD_TEAM_NO_COMMIT=off)" = yes ]   && ok "HMD_TEAM_NO_COMMIT=off is OFF for wip-commit too" || bad "wip-commit: =off wrongly suppressed"
[ "$(wip_case wip-tr-1 tracked HMD_TEAM_NO_COMMIT=1)" = no ]        && ok "tracked + =1: checkpoint excludes team.json" || bad "tracked + =1: team.json rode the checkpoint"
[ "$(wip_case wip-tr-true tracked HMD_TEAM_NO_COMMIT=true)" = no ]  && ok "tracked + =true: checkpoint excludes team.json (same parsing as heimdall-team)" || bad "tracked + =true: team.json rode the checkpoint"
[ "$(wip_case wip-un-1 untracked HMD_TEAM_NO_COMMIT=1)" = no ]      && ok "untracked + =1: checkpoint excludes team.json" || bad "untracked + =1: team.json rode the checkpoint"
R="$T/wip-tr-1"
[ -n "$(tracked "$R")" ] && [ "$(jfield "$R/.heimdall/team.json" team_secret)" = "fake-b" ] \
  && ok "the excluded edit stays on disk, still tracked (never discarded)" || bad "the on-disk team.json edit was lost or untracked"
case "$(dirty "$R")" in
  *" M .heimdall/team.json"*) ok "the edit is still pending as an UNSTAGED change (backed out of the index, not committed)" ;;
  *) bad "team.json is no longer a pending unstaged edit: $(dirty "$R" | tr '\n' '|')" ;;
esac
[ -z "$(staged "$R")" ] && ok "nothing left staged after the checkpoint" || bad "staged leftovers: $(staged "$R" | tr '\n' ' ')"
# the marker sits in this case's own HOME, which mkrepo (called inside wip_case) reuses as it is
mkdir -p "$T/home-wip-tr-marker/.heimdall"; : > "$T/home-wip-tr-marker/.heimdall/no-team-commit"
[ "$(wip_case wip-tr-marker tracked)" = no ] && ok "tracked + marker file: checkpoint excludes team.json" || bad "tracked + marker: team.json rode the checkpoint"

echo "F. a PUBLIC repo is unaffected by the switch (it never committed there; still gitignores)"
R="$(mkrepo on-public)"; B="$(ncommits "$R")"
run "$R" HEIMDALL_FORCE_VISIBILITY=public HMD_TEAM_NO_COMMIT=1 bash "$TEAM" auto >/dev/null 2>&1
assert_on_disk "$R" "public"
[ "$(mut_calls "$R")" -eq 0 ] && [ "$(ncommits "$R")" -eq "$B" ] && [ -z "$(tracked "$R")" ] \
  && ok "public: nothing committed or tracked" || bad "public: something was committed/tracked"
grep -qxF '.heimdall/team.json' "$R/.gitignore" 2>/dev/null \
  && ok "public: team.json still gitignored exactly as before" || bad "public: .gitignore no longer protects team.json"

echo "G. documented — --help and the docs name the switch"
HELP="$(bash "$TEAM" --help 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "--help exits 0" || bad "--help exit $RC"
case "$HELP" in *HMD_TEAM_NO_COMMIT*) ok "--help names HMD_TEAM_NO_COMMIT" ;; *) bad "--help never mentions HMD_TEAM_NO_COMMIT" ;; esac
case "$HELP" in *no-team-commit*)     ok "--help names the persistent marker file" ;; *) bad "--help never mentions ~/.heimdall/no-team-commit" ;; esac
for doc in DATA.md commands/team.md docs/team-validation-runbook.md; do
  if grep -q 'HMD_TEAM_NO_COMMIT' "$ROOT/$doc" 2>/dev/null && grep -q 'no-team-commit' "$ROOT/$doc" 2>/dev/null; then
    ok "$doc documents both the env var and the marker file"
  else
    bad "$doc is missing HMD_TEAM_NO_COMMIT and/or no-team-commit"
  fi
done

echo ""
echo "heimdall-team-no-commit.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
