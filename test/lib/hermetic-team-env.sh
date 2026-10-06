# shellcheck shell=bash
# hermetic-team-env.sh — pin a suite's world to "the team off switch is OFF", whatever this box says.
#
# WHY THIS EXISTS. bin/heimdall-team and bin/heimdall-wip-commit both honour one off switch for
# committing .heimdall/team.json: the env var HMD_TEAM_NO_COMMIT, or the persistent machine-wide marker
# $HOME/.heimdall/no-team-commit (the HOME one, not $HEIMDALL_HOME: the same idiom as
# ~/.heimdall/no-team-autoshare, documented in bin/heimdall-team's header). An operator who turned the
# switch on for their own repos has it on for every process they spawn, including a suite that mints a
# team in a throwaway repo and asserts the commit landed. That suite reads the operator's real marker
# through the inherited HOME, never commits, and goes red for a reason that says nothing about the code
# under test: test/heimdall-team-autojoin.test.sh and test/heimdall-team-clone-join.test.sh in the
# 2026-10-06 full sweep. The marker is the operator's, so the suite changes ITS world, never the marker.
#
# WHAT IT DOES (test harness only; nothing under bin/ reads any of it):
#   * unsets HMD_TEAM_NO_COMMIT, so an exported switch cannot leak in;
#   * moves HOME to an empty dir under the suite's scratch dir, so the marker (and any other
#     ~/.heimdall state, e.g. team-auto.log, vis-cache) is neither read from nor written to the real HOME;
#   * pins PYENV_ROOT to the real ~/.pyenv first, when one exists, because a pyenv python3 shim resolves
#     its interpreter under $PYENV_ROOT (default $HOME/.pyenv) and would otherwise stop working the
#     moment HOME moves.
#
# A suite that DELIBERATELY tests the switch (test/heimdall-team-no-commit.test.sh) uses it too: each of
# its cases sets the switch itself, per invocation, so all it loses is the ambient state it never meant to
# depend on. Proof the helper does what it says: test/hermetic-team-env.test.sh.
#
# HOW TO USE. Source it once the suite has a scratch dir, then call it BEFORE any suite code that runs a
# team command (and in the shell proper, not inside $( ... ), or the change dies with the subshell):
#
#   . "$SELF_DIR/lib/hermetic-team-env.sh"
#   hermetic_team_env "$WORK" || exit 2

hermetic_team_env() { # <existing scratch dir>
  local dir="${1:-}"
  [ -d "$dir" ] || { echo "error: hermetic_team_env needs an existing scratch dir" >&2; return 2; }
  unset HMD_TEAM_NO_COMMIT
  if [ -z "${PYENV_ROOT:-}" ] && [ -d "${HOME:-}/.pyenv" ]; then export PYENV_ROOT="$HOME/.pyenv"; fi
  mkdir -p "$dir/userhome" || return 2
  export HOME="$dir/userhome"
}
