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
#   heimdall_path_is_ephemeral <p>     rc 0 when <p> lives in a DISPOSABLE checkout
#
# Two questions, one incident. `heimdall_home_is_real` answers "am I allowed to touch
# this domain at all?"; `heimdall_path_is_ephemeral` answers "is the path I am about to
# pin into a durable side effect going to outlive me?". The same run can pass the first
# and fail the second — that is exactly what happened. See the EPHEMERAL-TREE DETECTION
# block below for the second half.
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

# ═══ EPHEMERAL-TREE DETECTION ═══════════════════════════════════════════════════
#
# THE SECOND MECHANISM BEHIND THE SAME INCIDENT. The passwd guard above answers "is
# this the real user's launchd domain?". It does NOT answer "is the path I am about to
# pin into a nightly job still going to exist next week?" — and that is what actually
# broke. The run that rewrote the developer's live com.heimdall.dream.plist had a
# GENUINE $HOME (real user, real passwd home, real domain); every check above passed.
# What was wrong was the TREE: the plist was left pointing at
#   <repo>/.claude/worktrees/agent-<id>/bin/heimdall-dream
# an agent worktree, which is reaped when the agent finishes. A scheduled job pinned to
# a reaped path does not error at register time — it fails silently at 03:00, forever,
# and the only symptom is that dreams stop arriving.
#
# THE RULE: refuse a path inside a LINKED GIT WORKTREE. Not a substring match on
# ".claude/worktrees" — that spelling is one project's convention and misses a worktree
# created anywhere else. The structural question git itself answers is whether a
# checkout is the MAIN worktree or a linked one, and `git worktree` exists precisely to
# make DISPOSABLE checkouts (`git worktree prune` reaps them). So "linked worktree" is
# not a heuristic about ephemerality — it is a declaration of it, by the tool that owns
# the tree's lifecycle.
#
# WHY THE POLARITY IS INVERTED HERE (deliberate, not an oversight). Everything above
# demands PROOF OF SAFETY and refuses on "don't know". This predicate demands PROOF OF
# DANGER and allows on "don't know". The asymmetry is forced: the real user's passwd
# home is ALWAYS knowable, so demanding proof there costs nothing — but tree durability
# is not. A released install unpacked to a plain directory carries no git metadata at
# all, and "no metadata → refuse" would refuse every ordinary user. Demanding proof of
# danger is therefore the only rule that catches the incident WITHOUT breaking the
# people it protects, and a guard that refuses real users is a guard someone deletes.
#
# WHAT IS DELIBERATELY *NOT* CHECKED: $TMPDIR / /tmp membership. A tmp path is also
# short-lived, but it is an inference from a filesystem convention rather than a
# declaration, it keys off a caller-controlled variable (so it is not self-detecting the
# way the passwd check is), and it false-refuses every hermetic install probe — which
# pushes suites toward a bypass seam, and a guard with a bypass seam is the guard that
# gets bypassed. Missing paths need no rule here: callers already stat the command
# before registering it.

# heimdall_physical_path <path> — <path> with symlinks resolved, in both the directory
# components AND a symlinked leaf. Without the leaf hop a symlink parked in a durable
# directory would launder a worktree path straight through the guard. Stock macOS bash
# 3.2 has no `realpath`, so the hops are walked by hand (bounded, so a symlink cycle
# terminates instead of hanging). Prints nothing / rc 1 when the path cannot be resolved.
heimdall_physical_path() {
  local p="${1:-}" hops=0 target dir base
  [ -n "$p" ] || return 1
  while [ -L "$p" ] && [ "$hops" -lt 16 ]; do
    target="$(readlink "$p" 2>/dev/null)" || return 1
    [ -n "$target" ] || return 1
    case "$target" in
      /*) p="$target" ;;
      *)  p="$(dirname "$p")/$target" ;;
    esac
    hops=$((hops + 1))
  done
  dir="$(dirname "$p")"
  base="$(basename "$p")"
  dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  case "$dir" in
    /) printf '/%s' "$base" ;;
    *) printf '%s/%s' "$dir" "$base" ;;
  esac
}

# heimdall_git_linked_worktree <dir> — rc 0 when git itself reports <dir> is inside a
# LINKED worktree. The test is the one git documents: a linked worktree's own git dir
# is <common>/worktrees/<name>, so --git-dir and --git-common-dir DIFFER; in the main
# worktree they are the same directory. rc 1 on "main worktree" AND on "cannot tell"
# (no git, not a repo) — the filesystem detector below is the independent backstop.
heimdall_git_linked_worktree() {
  local d="${1:-}" gitdir common
  [ -n "$d" ] && [ -d "$d" ] || return 1
  command -v git >/dev/null 2>&1 || return 1
  gitdir="$(cd "$d" 2>/dev/null && git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  common="$(cd "$d" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$gitdir" ] && [ -n "$common" ] || return 1
  # --git-common-dir may come back relative to the directory git ran in.
  case "$common" in /*) : ;; *) common="$d/$common" ;; esac
  # Same directory → main worktree → durable. Different → linked worktree → disposable.
  if heimdall_same_dir "$gitdir" "$common"; then return 1; fi
  return 0
}

# heimdall_dotgit_linked_worktree <dir> — the no-git-binary backstop, pure filesystem.
# Walks up to the nearest `.git`. A DIRECTORY is the main worktree (durable, stop). A
# FILE is a gitdir redirect, and its TARGET distinguishes the two things that look
# alike: a linked worktree redirects into <common>/worktrees/<name>, while a SUBMODULE
# redirects into <common>/modules/<name> and is perfectly durable. Only the worktrees/
# shape counts — and because it matches git's own metadata layout rather than the
# checkout's location, a repo that merely LIVES under a directory named "worktrees"
# is not mistaken for one (its .git is still a directory, and the walk stops there).
heimdall_dotgit_linked_worktree() {
  local d="${1:-}" line target=""
  [ -n "$d" ] || return 1
  d="$(cd "$d" 2>/dev/null && pwd -P)" || return 1
  while : ; do
    if [ -d "$d/.git" ]; then return 1; fi
    if [ -f "$d/.git" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          gitdir:*) target="${line#gitdir:}"; target="${target# }"; break ;;
        esac
      done < "$d/.git"
      case "$target" in
        */worktrees/*) return 0 ;;
        *) return 1 ;;
      esac
    fi
    [ "$d" = "/" ] && return 1
    d="$(dirname "$d")"
  done
}

# heimdall_path_is_ephemeral <path> — THE predicate the register path gates on.
# rc 0 ONLY when <path> is provably inside a disposable checkout. Two independent
# detectors, either of which is sufficient: git's own answer, and the on-disk .git
# shape for boxes where git is unavailable or the tree is a bare copy of a worktree.
heimdall_path_is_ephemeral() {
  local p="${1:-}" phys dir
  [ -n "$p" ] || return 1
  phys="$(heimdall_physical_path "$p")" || return 1
  if [ -d "$phys" ]; then dir="$phys"; else dir="$(dirname "$phys")"; fi
  [ -d "$dir" ] || return 1
  if heimdall_git_linked_worktree "$dir"; then return 0; fi
  if heimdall_dotgit_linked_worktree "$dir"; then return 0; fi
  return 1
}
