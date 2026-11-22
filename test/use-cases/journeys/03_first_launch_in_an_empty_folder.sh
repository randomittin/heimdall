#!/usr/bin/env bash
# Journey 03 -- the first launch after install, in an empty folder, with no terminal (README "Install" then "Running on your own work"; the launcher's cold-start
# contract: nothing may ever wait on a prompt nobody can answer, and nothing is installed that nobody agreed to).
#
#   A developer just installed hmd (the real installer, as in journey 01), is not signed in to Claude Code, and runs their first task from a brand-new folder, piped
#   (no tty on stdin or stdout), the way CI, a script or an editor task runner does:  hmd "build a CLI that renames files"
#     1. it finishes (exit 0, no hang): nothing waited for a login, a persona answer or a consent that cannot arrive
#     2. setup is recorded as done ($HEIMDALL_HOME/setup-done): the next launch will not set up again, and it did not exist before this launch
#     3. nothing was installed without consent: the fake claude saw no plugins install and no marketplace add; the recommended skill (superpowers) is written to the
#        lock as `suggested` and the deferral is said on stderr; the consent mode is `ask`
#     4. not signed in is said plainly with how to sign in, and does not stop the task: it was handed to claude, whose answer is shown
#     5. a piped launch is silent about onboarding: no "New here?" orientation, no wake-up animation, no persona question (and no persona stored)
#     6. the empty folder became a project: a git repo and a CLAUDE.md of conventions
#     7. the second launch is warm: it does not say "First run" again
#
# Engines reused: test/skills-consent-launcher.test.sh section E (the real --setup), test/f1-onboarding.test.sh (cold run, non-tty), test/install-stranger.test.sh (5, 6).
# Mutants (test/use-cases/mutants.list): setup-done is never written, the consent gate always says yes (skills installed without asking).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"
uc_begin 03_first_launch_in_an_empty_folder
uc_need_crypto
uc_tree
uc_fakebin
uc_sandbox launch

uc_install "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh
uc_rc "(setup) the real installer puts hmd on the machine" 0
HMD="$UC_HOME/.local/bin/hmd"
HH="$UC_HOME/.heimdall"                  # hmd's state home: no HEIMDALL_HOME is set, so it is ~/.heimdall, as for a real user
if [ -x "$HMD" ]; then uc_ok "(setup) hmd is installed"; else uc_bad "(setup) no hmd entry point: nothing to launch"; fi
if [ ! -e "$HH/setup-done" ]; then uc_ok "(setup) it is a cold machine: no setup marker yet, and no Claude Code login"; else uc_bad "(setup) the installer already wrote the setup marker: this would not be a first launch"; fi
[ ! -e "$UC_HOME/.claude.json" ] || uc_bad "(setup) the sandbox HOME is already signed in to Claude Code"
: > "$UC_CLAUDE_LOG"                     # only what the launch asks of Claude Code counts below

PROJECT="$UC_ROOT/launch/newproject"
mkdir -p "$PROJECT"
TASK='build a CLI that renames files'

# 1. the first launch, piped
uc_run "$UC_HOME" "$PROJECT" -- "$HMD" "$TASK"
LAUNCH1_OUT="$UC_ROOT/launch-1.out"; LAUNCH1_ERR="$UC_ROOT/launch-1.err"; cp "$UC_OUT" "$LAUNCH1_OUT"; cp "$UC_ERR" "$LAUNCH1_ERR"
uc_rc "the first launch finishes" 0

# 2. setup recorded
if [ -f "$HH/setup-done" ]; then uc_ok "setup is recorded: \$HEIMDALL_HOME/setup-done exists"; else uc_bad "no setup-done marker after the first launch: the next launch would set up again"; fi

# 3. nothing installed without consent
if ! grep -Eq '^claude plugins (install|marketplace add)' "$UC_CLAUDE_LOG"; then uc_ok "no plugin was installed and no marketplace added (the fake claude saw neither)"; else uc_bad "the launch installed or registered something without consent" "$(grep -E '^claude plugins (install|marketplace add)' "$UC_CLAUDE_LOG" | head -3 | LC_ALL=C tr '\n' '|')"; fi
uc_jq "the recommended skill is on the lock as suggested, not installed" '[.entries[] | select(.id == "superpowers")][0].state == "suggested"' "$HH/skills.lock"
uc_has "the deferral is said on stderr" "$LAUNCH1_ERR" 'recommended skill superpowers not installed'
uc_jq "the consent mode is ask" '.consent == "ask"' "$HH/skills-config.json"

# 4. not signed in: said plainly, and the task still runs
uc_has "not being signed in is said, with how to sign in" "$LAUNCH1_OUT" 'Not signed in to Claude Code yet'
uc_has "…naming claude setup-token for a machine with no browser" "$LAUNCH1_OUT" 'claude setup-token'
uc_has "the task was handed to claude" "$UC_CLAUDE_LOG" "-p .*$TASK"
uc_has "…and claude's answer is shown" "$LAUNCH1_OUT" 'fake claude finished the task'

# 5. a piped launch is silent about onboarding
uc_lacks "no 'New here?' orientation on a pipe" "$LAUNCH1_OUT" 'New here\?'
uc_lacks "no wake-up animation on a pipe" "$LAUNCH1_OUT" 'watchman wakes'
uc_lacks "no persona question on a pipe" "$LAUNCH1_OUT" 'One-time question'
if [ ! -e "$HH/persona.json" ]; then uc_ok "…and no persona was stored from a question nobody could answer"; else uc_bad "a persona was stored by a piped launch"; fi

# 6. the folder became a project
if [ -d "$PROJECT/.git" ] || git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1; then uc_ok "the empty folder is now a git repo (agents need one for worktree isolation)"; else uc_bad "the first launch left the folder without a git repo"; fi
uc_has "…with a CLAUDE.md of project conventions" "$PROJECT/CLAUDE.md" 'Project Conventions'

# 7. the second launch is warm
uc_run "$UC_HOME" "$PROJECT" -- "$HMD" "add a dry-run flag"
uc_rc "the second launch finishes" 0
uc_lacks "…and does not set up again" "$UC_OUT" 'First run'
uc_has "(control) the first launch did say it was setting up" "$LAUNCH1_OUT" 'First run'

if [ ! -s "$UC_SECURITY_LOG" ]; then uc_ok "the keychain was never asked"; else uc_bad "a launch asked the keychain" "$(head -c 200 "$UC_SECURITY_LOG")"; fi

uc_finish
