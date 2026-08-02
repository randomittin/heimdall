#!/usr/bin/env bash
# crontab-safe.sh — sourceable, NON-DESTRUCTIVE crontab replacement (the one shared helper).
#
# ONE job: replace the `MARKER` lines in a user's crontab and keep EVERYTHING else — without
# ever being able to wipe the crontab. The naive form this replaces was:
#
#     crontab -l 2>/dev/null | grep -v MARKER > "$tmp" || true ; crontab "$tmp"
#
# If `crontab -l` failed for ANY reason other than "no crontab exists" — denied permissions, a
# cron daemon hiccup, an unreadable spool, a silent non-zero — then $tmp was EMPTY, `|| true`
# swallowed the failure, and `crontab "$tmp"` REPLACED the user's entire crontab with just the
# appended lines. Every unrelated job, gone, silently, unrecoverable. An empty intermediate was
# treated as a valid result; here the consequence is destructive rather than a false pass.
#
# Fail-closed: any doubt about the READ → abort, install nothing, change nothing. A read that
# succeeded is backed up to a timestamped file (path printed) BEFORE anything is replaced, so
# even a correct-but-unwanted change is a one-line `crontab <backup>` away from being undone.
#
# The "no crontab exists" case is the one non-zero exit that is NOT a failure. We detect it by
# the `no crontab` substring on stderr, which vixie-cron/cronie (Debian, Ubuntu, RHEL), macOS
# cron and busybox all emit as `no crontab for <user>`; an implementation that instead exits 0
# with empty output is covered by the exit-0 path. Every OTHER non-zero exit aborts.
#
# API (source this file, then):
#   heimdall_crontab_install <marker> <line>...   run it HERE   → rc 0 installed, non-zero aborted
#   heimdall_crontab_script  <marker> <line>...   print the same program as self-contained POSIX
#                                                 sh, for shipping over ssh to a remote host
#   heimdall_crontab_quote   <string>             POSIX single-quote one string
#
# Both call sites (deploy/cloud-run/deploy-maintainer.sh runs it locally, deploy/gce/
# provision-maintainer-vm.sh ships it over `gcloud compute ssh --command`) go through the SAME
# program text, so the fix cannot drift between them. The remote side needs nothing installed:
# the emitted script is plain POSIX sh with only coreutils.

# heimdall_crontab_quote <string> — wrap in single quotes, POSIX-escaping embedded quotes, so a
# value like `$(hostname)` or `$HOME` survives into the crontab LITERALLY for cron to expand.
heimdall_crontab_quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# heimdall_crontab_body — the fixed program. Reads $hc_marker and the positional params (the
# lines to append), both set by the preamble heimdall_crontab_script emits.
heimdall_crontab_body() {
cat <<'HEIMDALL_CRONTAB_BODY'
set -u
hc_die() { printf 'heimdall: %s\n' "$*" >&2; exit 1; }

[ "$#" -gt 0 ] || hc_die "no crontab lines supplied — refusing to rewrite a crontab for nothing."

hc_tmpdir="${TMPDIR:-/tmp}"
hc_read="$(mktemp "$hc_tmpdir/heimdall-cron-read.XXXXXX")" || hc_die "cannot create a temp file in $hc_tmpdir."
hc_err="$(mktemp "$hc_tmpdir/heimdall-cron-err.XXXXXX")"   || { rm -f "$hc_read"; hc_die "cannot create a temp file in $hc_tmpdir."; }
hc_new="$(mktemp "$hc_tmpdir/heimdall-cron-new.XXXXXX")"   || { rm -f "$hc_read" "$hc_err"; hc_die "cannot create a temp file in $hc_tmpdir."; }
trap 'rm -f "$hc_read" "$hc_err" "$hc_new"' EXIT

# ── 1. READ, and separate the three outcomes. This is the whole bug.
crontab -l >"$hc_read" 2>"$hc_err"; hc_rc=$?
hc_msg="$(cat "$hc_err" 2>/dev/null)"
if [ "$hc_rc" -ne 0 ]; then
  if printf '%s' "$hc_msg" | grep -qi 'no crontab'; then
    : > "$hc_read"          # expected: the user simply has no crontab yet. Empty IS the truth.
  else
    printf 'heimdall: `crontab -l` FAILED (exit %s).\n' "$hc_rc" >&2
    [ -n "$hc_msg" ] && printf 'heimdall: crontab said: %s\n' "$hc_msg" >&2
    hc_die "refusing to install a crontab derived from a failed read — your crontab was NOT modified."
  fi
fi

# ── 2. BACK UP before replacing anything. Cheap insurance on a destructive operation.
hc_bdir="$hc_tmpdir"
if [ -n "${HOME:-}" ] && mkdir -p "$HOME/.heimdall/crontab-backups" 2>/dev/null; then
  hc_bdir="$HOME/.heimdall/crontab-backups"
fi
hc_backup="$hc_bdir/crontab-$(date +%Y%m%d-%H%M%S).bak"
if [ -s "$hc_read" ]; then
  ( umask 077; cp "$hc_read" "$hc_backup" ) \
    || hc_die "could not write the crontab backup to $hc_backup — your crontab was NOT modified."
  printf 'heimdall: existing crontab backed up → %s\n' "$hc_backup"
  printf 'heimdall: undo this change at any time with: crontab %s\n' "$hc_backup"
else
  hc_backup=""
  printf 'heimdall: no existing crontab to back up — installing a fresh one.\n'
fi

# ── 3. FILTER: drop our own marker lines, keep every other job untouched.
if [ -s "$hc_read" ]; then
  grep -v -F -e "$hc_marker" "$hc_read" >"$hc_new"; hc_g=$?
  # grep rc: 0 = lines kept, 1 = nothing kept (every line was ours), >1 = a REAL grep error.
  [ "$hc_g" -le 1 ] || hc_die "could not filter the existing crontab (grep exit $hc_g) — your crontab was NOT modified.${hc_backup:+ Backup: $hc_backup}"
else
  : > "$hc_new"
fi

# ── 4. APPEND. Guarantee a separating newline first: a kept crontab whose last line lacks one
#       would otherwise be JOINED to our first entry, corrupting BOTH. `$(...)` strips trailing
#       newlines, so a non-empty result means the last byte was not a newline.
if [ -s "$hc_new" ] && [ -n "$(tail -c 1 "$hc_new")" ]; then
  printf '\n' >>"$hc_new" || hc_die "could not write to $hc_new — your crontab was NOT modified."
fi
for hc_line in "$@"; do
  printf '%s\n' "$hc_line" >>"$hc_new" \
    || hc_die "could not stage the new crontab in $hc_new — your crontab was NOT modified."
done

# ── 5. INSTALL, and check it. The old code ignored this exit status too.
if crontab "$hc_new"; then
  printf 'heimdall: crontab installed — %s entry/entries for "%s"; every other job kept.\n' "$#" "$hc_marker"
else
  hc_irc=$?
  printf 'heimdall: installing the new crontab FAILED (exit %s).\n' "$hc_irc" >&2
  [ -n "$hc_backup" ] && printf 'heimdall: your previous crontab is safe at %s — restore with: crontab %s\n' "$hc_backup" "$hc_backup" >&2
  exit 1
fi
HEIMDALL_CRONTAB_BODY
}

# heimdall_crontab_script <marker> <line>... — the complete self-contained POSIX sh program.
heimdall_crontab_script() {
  local marker="$1"; shift
  local args="" line
  for line in "$@"; do args="$args $(heimdall_crontab_quote "$line")"; done
  printf 'hc_marker=%s\nset --%s\n' "$(heimdall_crontab_quote "$marker")" "$args"
  heimdall_crontab_body
}

# heimdall_crontab_install <marker> <line>... — run that program on THIS host.
heimdall_crontab_install() {
  local script
  script="$(heimdall_crontab_script "$@")" || return 1
  sh -c "$script"
}
