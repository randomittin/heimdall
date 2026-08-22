#!/usr/bin/env bash
# tcc-paths.sh — the ONE answer to "is this path inside a folder macOS TCC protects?"
#
# WHY THIS IS A SHARED LIB AND NOT A LOCAL HELPER
#   Two callers now need the same answer for OPPOSITE reasons, and they must not be able
#   to disagree:
#     · bin/heimdall-dream-schedule asks it of the job's OWN ARTIFACTS (program, log,
#       plist) and REFUSES to install when any of them is protected — a reporter behind
#       the same locked door as the thing it reports on is the shape of the 10-night
#       silence in commit 245ede5.
#     · bin/heimdall-dream-permission asks it of the REPO — which the schedule guard
#       deliberately EXEMPTS — and, when it is protected, ASKS the operator for the grant
#       that would restore unattended runs.
#   A drifted copy would produce the worst possible pair: an install that happily
#   registers a job it privately knows cannot run, and an ask that never fires. The same
#   reasoning already put bin/lib/real-home.sh here ("two copies of a guard drift, and a
#   drifted guard is an unguarded one" — bin/heimdall-dream-schedule).
#
# WHAT MACOS ACTUALLY PROTECTS
#   ~/Downloads, ~/Documents and ~/Desktop are gated by per-service TCC entitlements
#   (kTCCServiceSystemPolicyDownloadsFolder and friends). A LaunchAgent carries NO TCC
#   grant, so every read under those trees returns EPERM at 03:00 — measured, not assumed:
#   a probe LaunchAgent whose program sat at a NON-protected path was refused every read
#   under ~/Downloads while a write to ~/.heimdall succeeded.
#
# BOTH HOMES ARE CONSULTED. $HOME may be synthetic while the path under test is written in
# terms of the real user's home (or the reverse), so the passwd home is checked as well
# when bin/lib/real-home.sh has been sourced. Neither answer is trusted over the other:
# a hit on EITHER is a hit, because a false "reachable" is the failure that goes silent.
#
# API (source this file, then):
#   heimdall_absolute_physical <path>     absolutise + resolve, even for a path that does
#                                         not exist yet; prints the result, rc 1 on failure
#   heimdall_tcc_protected_root <path>    prints the protected root and returns 0 when
#                                         <path> is inside one; rc 1 otherwise
#   heimdall_tcc_folder_service <root>    prints the 3 lines (service id / pane anchor /
#                                         human-visible row label) for a root returned by
#                                         heimdall_tcc_protected_root above; rc 1 when
#                                         <root> is not one of the folders this recognizes

# The folder names macOS gates behind a per-service TCC entitlement. Kept as a plain
# word list so a caller can read it in a message without re-deriving it.
HEIMDALL_TCC_PROTECTED_SUBDIRS="Downloads Documents Desktop"

# heimdall_absolute_physical <path> — <path> made absolute and physically resolved, FOR A
# PATH THAT MAY NOT EXIST YET.
#
# real-home.sh's heimdall_physical_path resolves an EXISTING path. The artifact
# directories the schedule guard checks are created BY the install, so on a first run they
# are absent and that helper cannot answer. This walks up to the deepest ancestor that DOES
# exist, resolves THAT physically (so a symlinked $HOME cannot launder a path past the
# guard), then re-appends the tail it walked off.
heimdall_absolute_physical() {
  local p="${1:-}" tail="" base
  [ -n "$p" ] || return 1
  case "$p" in /*) : ;; *) p="$PWD/$p" ;; esac
  while [ ! -d "$p" ] && [ "$p" != "/" ]; do
    base="$(basename "$p")"
    tail="/$base$tail"
    p="$(dirname "$p")"
  done
  p="$(cd "$p" 2>/dev/null && pwd -P)" || return 1
  case "$p" in
    /) printf '%s' "$tail" ;;
    *) printf '%s%s' "$p" "$tail" ;;
  esac
}

# heimdall_tcc_protected_root <path> — prints the protected root containing <path> and
# returns 0; returns 1 when <path> is not inside one.
#
# The trailing-slash comparison is deliberate: matching "$home/$sub"* without it would
# also match a sibling like ~/Downloads-archive, which macOS does not protect — and a
# guard that refuses paths the OS allows trains people to disable it.
heimdall_tcc_protected_root() {
  local abs home sub homes real
  abs="$(heimdall_absolute_physical "${1:-}")" || return 1
  real=""
  if type heimdall_real_user_home >/dev/null 2>&1; then
    real="$(heimdall_real_user_home 2>/dev/null || true)"
  fi
  homes="${HOME:-}
$real"
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    home="$(cd "$home" 2>/dev/null && pwd -P)" || continue
    for sub in $HEIMDALL_TCC_PROTECTED_SUBDIRS; do
      case "$abs/" in
        "$home/$sub/"*) printf '%s' "$home/$sub"; return 0 ;;
      esac
    done
  done <<EOF
$homes
EOF
  return 1
}

# heimdall_tcc_folder_service <protected-root> — maps a root PRINTED BY
# heimdall_tcc_protected_root (never a raw path — the caller is expected to have already
# resolved one) to the THREE things a caller needs to ask for the RIGHT permission instead
# of the broadest one that happens to also work:
#   line 1: the TCC service identifier (documentation/logging only — never queried or set;
#           this file still never touches the TCC database, see tcc-paths.sh's own header)
#   line 2: the System Settings deep-link anchor, for
#           x-apple.systempreferences:com.apple.preference.security?<anchor>
#   line 3: the human-visible row label, exactly as System Settings' own Files & Folders
#           category prints it (confirmed against a live SecurityPrivacyExtension.appex)
#
# GENERIC BY DESIGN — NEVER HARDCODES ONE FOLDER. Downloads, Documents and Desktop each
# get their own TCC service; a caller that assumed "Downloads" for every protected root
# would send an operator whose repo sits in ~/Documents to the wrong pane. rc 1 for any
# root this does not recognize, so a caller can fall back to naming Full Disk Access
# instead of guessing a service name that might be wrong.
heimdall_tcc_folder_service() {
  local root="${1:-}" base
  [ -n "$root" ] || return 1
  base="$(basename "$root")"
  case "$base" in
    Downloads) printf 'kTCCServiceSystemPolicyDownloadsFolder\nPrivacy_DownloadsFolder\nDownloads Folder\n' ;;
    Documents) printf 'kTCCServiceSystemPolicyDocumentsFolder\nPrivacy_DocumentsFolder\nDocuments Folder\n' ;;
    Desktop)   printf 'kTCCServiceSystemPolicyDesktopFolder\nPrivacy_DesktopFolder\nDesktop Folder\n' ;;
    *) return 1 ;;
  esac
}
