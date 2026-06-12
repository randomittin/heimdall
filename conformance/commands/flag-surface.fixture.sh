#!/usr/bin/env bash
# PARITY-ROW: covers the flags whose LIVE path launches `claude`/`tmux` (cannot be
#   executed under P2's no-model / no-side-effect rule), proving the rename/keep/add
#   landed at the routing + documentation surface:
#     - Command `superx --update` (kept)         -> heimdall --update
#     - Command `superx --setup`  (kept)         -> heimdall --setup
#     - Command `superx --team N` (kept)         -> heimdall --team
#     - Command `superx --auto`   (kept)         -> heimdall --auto  (Flag row too)
#     - Command `superx --resume`/`-r` (improved)-> heimdall --resume/-r (CHECKPOINT.md)
#     - Flag (none) -> improved(new) --reinstall/--fix
#     - Flag (none) -> improved(new) --skip-checkpoint/--fresh
#     - Flag (none) -> improved(new) --no-goal
#     - Flag (none) -> improved(new) --skills
# ASSERT: each flag (1) appears in `heimdall --help` usage text, and (2) is matched
#   by an explicit branch in bin/heimdall (so it is a recognized command, NOT
#   silently treated as a task prompt). We deliberately DO NOT invoke the live
#   path (it would exec claude / spawn tmux / git-pull); that is asserted by other
#   fixtures only where a side-effect-free contract exists.
ROW="cmd:flag-surface"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"
cd "$PLUGIN_ROOT" || { bad "cannot cd"; finish; }

HELP="$("$BIN/heimdall" --help 2>&1)"
SRC="$(cat "$BIN/heimdall")"

# flag | help-regex | source-branch-regex
check() {
  local flag="$1" hre="$2" sre="$3"
  assert_grep "$hre" "$HELP" "usage documents $flag"
  assert_grep "$sre" "$SRC" "bin/heimdall has an explicit branch for $flag"
}

check "--update"          '\-\-update'          '"--update"'
check "--setup"           '\-\-setup'           '"--setup"'
check "--team"            '\-\-team'            '"--team"'
check "--auto"            '\-\-auto'            '"--auto"'
check "--resume/-r"       '\-\-resume'          '"--resume"|"-r"'
check "--reinstall/--fix" '\-\-reinstall'       '"--reinstall"|"--fix"'
check "--skip-checkpoint" '\-\-skip-checkpoint' '"--skip-checkpoint"|"--fresh"'
check "--no-goal"         '\-\-no-goal'         '"--no-goal"'
check "--skills"          '\-\-skills'          '"--skills"'

# --resume improvement: it reads .planning/CHECKPOINT.md (not just STATE.md).
assert_grep 'CHECKPOINT\.md' "$SRC" "--resume improvement: reads .planning/CHECKPOINT.md"
finish
