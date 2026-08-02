#!/usr/bin/env bash
# real-home.sh — the ONE answer to "is this process actually running as the real user,
# in the real user's home?" — for the side effects $HOME CANNOT isolate.
#
# WHY THIS EXISTS (a real incident, not a hypothetical)
#   Some of what Heimdall installs does NOT resolve through $HOME:
#     · `launchctl` targets the logged-in user's GUI session domain (gui/<uid>)
#     · ~/Library/LaunchAgents is read by that same per-user launchd
#   A harness that sets `HOME=$(mktemp -d)` therefore isolates the FILESYSTEM but NOT
#   the launchd domain. An agent running a real install under a throwaway HOME reached
#   the developer's REAL nightly scheduler and repointed it at an ephemeral agent
#   worktree — a path that is later reaped, so the nightly job was wired to something
#   that ceases to exist.
#
# THE GUARD SHAPE THAT WORKS: SELF-DETECTION, NOT AN OPT-OUT
#   An env-var opt-out (HEIMDALL_NO_DREAM_SCHEDULE=1) only works if EVERY future caller
#   remembers it. One forgot, and that is precisely how the incident happened. So the
#   answer here is read from the PASSWD DATABASE (getpwuid) — a source $HOME cannot
#   influence. A synthetic HOME self-identifies with ZERO cooperation from whoever
#   spawned the run. The opt-out remains; this is the floor underneath it.
#
# FAIL SAFE IS THE CONTRACT. Every "don't know" answers NO:
#   · no python3 and no dscl        → empty home  → heimdall_home_is_real is FALSE
#   · $HOME unset/empty             → FALSE
#   · either path not a directory   → FALSE
#   Callers MUST treat FALSE as "do not touch the domain".
#
# API (source this file, then):
#   heimdall_real_user_home            echo the passwd home ('' = could not determine)
#   heimdall_same_dir <a> <b>          rc 0 when both name the SAME physical directory
#   heimdall_home_is_real              rc 0 ONLY when $HOME is the real passwd home
#
# TEST SEAM
#   HEIMDALL_REAL_HOME overrides ONLY the RESOLVED passwd home, so an acceptance suite
#   can drive the real-user branch under a throwaway HOME. Setting it can never by
#   itself reach a real domain: the launchd call still goes through $LAUNCHCTL and the
#   plist still comes from $HEIMDALL_LAUNCH_AGENTS_DIR, both of which the suite
#   redirects into its sandbox. It is the same family of seam those two already are.
#
# Sourced by bin/heimdall (uninstall: unload+remove the LaunchAgent) and by
# bin/heimdall-dream-schedule (install: write+load it). ONE definition, so the two
# directions of the same guard cannot drift apart.

# heimdall_real_user_home — the home directory of the user this process actually runs
# as, from the passwd database. Prints EMPTY when it cannot be determined, which every
# caller must read as "unsafe".
heimdall_real_user_home() {
  local h user
  if [ -n "${HEIMDALL_REAL_HOME:-}" ]; then
    printf '%s' "${HEIMDALL_REAL_HOME}"
    return 0
  fi
  h=""
  if command -v python3 >/dev/null 2>&1; then
    h="$(python3 -c 'import pwd,os;print(pwd.getpwuid(os.getuid()).pw_dir)' 2>/dev/null || true)"
  fi
  if [ -z "$h" ] && command -v dscl >/dev/null 2>&1; then
    user="$(id -un 2>/dev/null || true)"
    if [ -n "$user" ]; then
      h="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
    fi
  fi
  printf '%s' "$h"
}

# heimdall_same_dir <a> <b> — TRUE when both arguments name the SAME directory.
# Compares PHYSICAL paths so a real user whose home is reached through a symlink is
# not misread as synthetic (that misread would refuse a real user's install — the
# false-negative side of this guard, which is just as much a bug as the false pass).
heimdall_same_dir() {
  local a="${1:-}" b="${2:-}"
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  [ -d "$a" ] && [ -d "$b" ] || return 1
  a="$(cd "$a" 2>/dev/null && pwd -P)" || return 1
  b="$(cd "$b" 2>/dev/null && pwd -P)" || return 1
  [ "$a" = "$b" ]
}

# heimdall_home_is_real — the single predicate every launchd/global-domain call site
# gates on. TRUE only when $HOME provably IS the real user's passwd home.
heimdall_home_is_real() {
  heimdall_same_dir "$(heimdall_real_user_home)" "${HOME:-}"
}
