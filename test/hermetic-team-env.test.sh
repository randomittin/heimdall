#!/usr/bin/env bash
# hermetic-team-env.test.sh — proves test/lib/hermetic-team-env.sh really neutralises the team off switch.
#
# THE CLAIM. bin/heimdall-team skips committing .heimdall/team.json when HMD_TEAM_NO_COMMIT is set or
# $HOME/.heimdall/no-team-commit exists. A suite that sources the helper therefore commits in its throwaway
# repo no matter what the operator's shell or real HOME carry (the 2026-10-06 sweep failures of
# test/heimdall-team-autojoin.test.sh and test/heimdall-team-clone-join.test.sh).
#
# HOW IT IS PROVEN — the real `heimdall-team share`, a real throwaway git repo, no network, no gh:
# a FAKE operator HOME holding the marker, plus the env var exported, stand in for the operator's box. The
# real ~/.heimdall is never read, written or removed here.
#   A. control, marker only  — share writes team.json but commits nothing (the vector is real, so C is falsifiable)
#   B. control, env var only — same, through the other vector
#   C. helper called with BOTH vectors on — HOME moved, switch cleared, share COMMITS, the marker is left alone
#   D. guards — a missing scratch dir is refused (rc 2, HOME untouched); python3 still resolves after HOME moves
#
# Usage: bash test/hermetic-team-env.test.sh   (exit 0 = every assertion held)
#
# SC2015 is silenced file-wide on purpose: every assertion is `[ cond ] && ok ... || bad ...` (the idiom of
# this suite family) and ok/bad are printf + arithmetic that always return 0, so `bad` can never run after a
# passing `ok`. SC1090/SC2030/SC2031 are silenced for the same kind of reason: sections C and D source the
# helper inside throwaway subshells ON PURPOSE, so a HOME/env change dies with the subshell and the parent's
# fake operator box stays intact for the next section.
# shellcheck disable=SC2015,SC1090,SC2030,SC2031
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM="$ROOT/bin/heimdall-team"
HELPER="$ROOT/test/lib/hermetic-team-env.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

[ -x "$TEAM" ]   || { echo "FATAL: $TEAM not executable" >&2; exit 2; }
[ -f "$HELPER" ] || { echo "FATAL: $HELPER missing" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1 || { echo "FATAL: python not found" >&2; exit 2; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$T/xdg"

# The operator's box, faked: a HOME that carries the persistent marker. The marker path is asserted at the end.
OPERATOR="$T/operator"; CLEAN="$T/clean"; SCRATCH="$T/scratch"
mkdir -p "$OPERATOR/.heimdall" "$CLEAN" "$SCRATCH"
: > "$OPERATOR/.heimdall/no-team-commit"

# A throwaway client repo: github origin + one initial commit; visibility is forced private via the
# documented HEIMDALL_FORCE_VISIBILITY seam, so `share` goes down the commit branch.
mkrepo() { # <name> -> prints the repo dir
  local r="$T/repo-$1"
  mkdir -p "$r"
  git -C "$r" init -q
  git -C "$r" remote add origin "https://github.com/fakeorg/$1.git"
  git -C "$r" config user.email t@t.t
  git -C "$r" config user.name t
  git -C "$r" commit -q --allow-empty -m "initial commit"
  printf '%s' "$r"
}
ncommits() { git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }
tracked()  { git -C "$1" ls-files -- .heimdall/team.json 2>/dev/null; }
# share_in <repo> <home> [VAR=val ...] — the real CLI, private-looking repo, the given HOME
share_in() {
  local r="$1" h="$2"; shift 2
  ( cd "$r" && env HOME="$h" HEIMDALL_FORCE_VISIBILITY=private "$@" bash "$TEAM" share ) >/dev/null 2>&1
}

echo "A. control — marker file only: team.json is written, never committed"
R="$(mkrepo ctl-marker)"; B="$(ncommits "$R")"
share_in "$R" "$OPERATOR"
[ -f "$R/.heimdall/team.json" ] && ok "marker: share ran to the commit step (team.json on disk)" || bad "marker: share never wrote team.json"
[ -z "$(tracked "$R")" ] && [ "$(ncommits "$R")" -eq "$B" ] && ok "marker: nothing committed (the ambient vector is real)" || bad "marker: team.json was committed despite the marker"

echo "B. control — HMD_TEAM_NO_COMMIT only: same result through the other vector"
R="$(mkrepo ctl-env)"; B="$(ncommits "$R")"
share_in "$R" "$CLEAN" HMD_TEAM_NO_COMMIT=1
[ -f "$R/.heimdall/team.json" ] && ok "env: share ran to the commit step (team.json on disk)" || bad "env: share never wrote team.json"
[ -z "$(tracked "$R")" ] && [ "$(ncommits "$R")" -eq "$B" ] && ok "env: nothing committed (the ambient vector is real)" || bad "env: team.json was committed despite the env var"

echo "C. helper — both vectors on, hermetic_team_env called: share COMMITS, the marker is untouched"
R="$(mkrepo helper-on)"; B="$(ncommits "$R")"
RES="$(
  export HOME="$OPERATOR" HMD_TEAM_NO_COMMIT=1
  # shellcheck source=lib/hermetic-team-env.sh disable=SC1091
  . "$HELPER"
  hermetic_team_env "$SCRATCH" || { echo "HELPER_RC=$?"; exit 0; }
  echo "HELPER_RC=0"
  [ "${HOME#"$SCRATCH"/}" != "$HOME" ] && echo "HOME_MOVED=yes" || echo "HOME_MOVED=no"
  [ -z "${HMD_TEAM_NO_COMMIT+x}" ] && echo "ENV_UNSET=yes" || echo "ENV_UNSET=no"
  ( cd "$R" && HEIMDALL_FORCE_VISIBILITY=private bash "$TEAM" share ) >/dev/null 2>&1
)"
printf '%s\n' "$RES" | grep -qx 'HELPER_RC=0'  && ok "hermetic_team_env returns 0" || bad "hermetic_team_env failed: $RES"
printf '%s\n' "$RES" | grep -qx 'HOME_MOVED=yes' && ok "HOME now lives under the suite's scratch dir" || bad "HOME was not moved: $RES"
printf '%s\n' "$RES" | grep -qx 'ENV_UNSET=yes'  && ok "HMD_TEAM_NO_COMMIT is unset" || bad "HMD_TEAM_NO_COMMIT leaked through: $RES"
[ -n "$(tracked "$R")" ] && [ "$(ncommits "$R")" -eq $((B + 1)) ] && ok "share committed team.json (TRACKED, exactly one commit added)" || bad "share did not commit team.json (tracked='$(tracked "$R")', commits $B -> $(ncommits "$R"))"
[ -f "$OPERATOR/.heimdall/no-team-commit" ] && ok "the operator's marker was left exactly where it was" || bad "the helper removed the operator's marker"

echo "D. guards"
RC_MISSING="$( ( export HOME="$OPERATOR"; . "$HELPER"; hermetic_team_env "$T/does-not-exist" >/dev/null 2>&1; echo "$?:$HOME" ) )"
[ "$RC_MISSING" = "2:$OPERATOR" ] && ok "a missing scratch dir is refused (rc 2) and HOME is left alone" || bad "missing scratch dir: got '$RC_MISSING'"
RC_EMPTY="$( ( export HOME="$OPERATOR"; . "$HELPER"; hermetic_team_env "" >/dev/null 2>&1; echo "$?:$HOME" ) )"
[ "$RC_EMPTY" = "2:$OPERATOR" ] && ok "an empty scratch-dir argument is refused (rc 2) and HOME is left alone" || bad "empty scratch dir: got '$RC_EMPTY'"
# python3 must survive the HOME move: with PYENV_ROOT unset, a pyenv shim would look under the NEW home.
PYRES="$( ( unset PYENV_ROOT; . "$HELPER"; hermetic_team_env "$SCRATCH" >/dev/null 2>&1; python3 -c 'print("py-ok")' 2>&1 ) )"
[ "$PYRES" = "py-ok" ] && ok "python3 still resolves after HOME moves (PYENV_ROOT pinned when a pyenv exists)" || bad "python3 broke after HOME moved: $PYRES"

echo ""
echo "hermetic-team-env.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
