#!/usr/bin/env bash
# claude-mem-plugin-retire.test.sh — an hmd update must RETIRE the legacy
# claude-mem companion, and every hmd surface that still references it must
# stay a silent no-op when it's absent — never a block, never an error.
#
# THE BUG THIS PINS: hmd used to install claude-mem@thedotmack as a companion,
# and that plugin's OWN UserPromptSubmit hook fails CLOSED — it blocked a real
# operator prompt ("claude-mem worker unreachable for 5 consecutive hooks"),
# the exact inverse of this repo's rule that hooks must fail OPEN. An
# hmd-installed dependency was breaking the thing hmd exists to keep working.
# FIX: hmd no longer installs or advertises claude-mem at all (measured 0%
# adoption of the per-task query mandate — see docs/analysis/2026-09-02-
# input-context-cost.md); an update actively retires an existing install
# (opt-out: HEIMDALL_KEEP_CLAUDE_MEM=1); and the one hmd-owned surface that
# still references claude-mem by design (the SessionStart routing/credential
# scrub) stays a silent, watchdog-bounded no-op when claude-mem is absent.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

[ -f "$REPO/install.sh" ] || { echo "FATAL: install.sh missing"; exit 2; }

# ── A — the function exists and is wired into the install/update path ─────────
if grep -q 'ensure_claude_mem_plugin_retired()' "$REPO/install.sh"; then
  ok "A1 ensure_claude_mem_plugin_retired is defined in install.sh"
else
  bad "A1 retirement function absent — an update would leave the plugin installed"
fi

if grep -q 'CM_STATE="\$(ensure_claude_mem_plugin_retired)"' "$REPO/install.sh"; then
  ok "A2 it is CALLED (defining it without calling it is dead code)"
else
  bad "A2 function defined but never invoked — dead on arrival"
fi

# ── B — behaviour, driven through a fake `claude` CLI ─────────────────────────
# install.sh is sourced-and-called with a stub CLI on PATH so no real plugin
# state is ever touched.
_extract() {
  sed -n '/^ensure_claude_mem_plugin_retired() {/,/^}/p' "$REPO/install.sh"
}

# Drive the real function with a STUB `claude` on PATH, so no real plugin state
# is ever touched. PATH keeps /usr/bin:/bin (bash itself must stay reachable —
# a bare PATH=/nonexistent breaks the shell, not just the CLI).
_run_state() {
  local listing="$1" keep="${2:-0}" d
  d="$(mktemp -d)"
  {
    printf '#!/bin/sh\n'
    printf 'if [ "$1 $2" = "plugins list" ]; then\n'
    printf '  cat "%s/listing"\n' "$d"
    printf 'elif [ "$1 $2" = "plugins uninstall" ]; then\n'
    printf '  : > "%s/listing"\n' "$d"
    printf 'fi\n'
    printf 'exit 0\n'
  } > "$d/claude"
  chmod +x "$d/claude"
  printf '%s\n' "$listing" > "$d/listing"
  PATH="$d:/usr/bin:/bin" HEIMDALL_KEEP_CLAUDE_MEM="$keep" \
    bash -c "$(_extract)
ensure_claude_mem_plugin_retired" 2>/dev/null
  rm -rf "$d"
}

S="$(_run_state 'superpowers@obra
caveman@caveman')"
if [ "$S" = "absent" ]; then
  ok "B1 plugin not installed -> 'absent' (cheap no-op steady state)"
else
  bad "B1 expected absent with no claude-mem installed, got '$S'"
fi

S="$(_run_state 'claude-mem@thedotmack
superpowers@obra' 1)"
if [ "$S" = "kept" ]; then
  ok "B2 HEIMDALL_KEEP_CLAUDE_MEM=1 -> 'kept' (opt-out honoured)"
else
  bad "B2 expected kept with the opt-out set, got '$S'"
fi

# `claude` absent entirely -> skipped, never a failure
S="$(PATH=/usr/bin:/bin bash -c "$(_extract)
ensure_claude_mem_plugin_retired" 2>/dev/null)"
if [ "$S" = "skipped" ]; then
  ok "B3 no claude CLI -> 'skipped' (never fatal)"
else
  bad "B3 expected skipped without the claude CLI, got '$S'"
fi

# ── C — scoping: it must never touch an unrelated plugin ─────────────────────
if grep -q 'claude plugins uninstall claude-mem@thedotmack' "$REPO/install.sh"; then
  ok "C1 uninstall targets claude-mem@thedotmack EXACTLY, not a wildcard"
else
  bad "C1 uninstall target is not the exact plugin id — scope risk"
fi

if grep -q 'marketplace remove thedotmack' "$REPO/install.sh"; then
  ok "C2 marketplace removal targets thedotmack only"
else
  bad "C2 marketplace removal target missing or broadened"
fi

# The marketplace removal must be GUARDED by a re-check that nothing from it
# remains — removing a marketplace another plugin needs breaks its updates.
if sed -n '/^ensure_claude_mem_plugin_retired() {/,/^}/p' "$REPO/install.sh" \
     | grep -B2 'marketplace remove' | grep -q 'grep -qi'; then
  ok "C3 marketplace removal is guarded by a post-uninstall re-check"
else
  bad "C3 marketplace removed unconditionally — could break another plugin"
fi

# ── D — an ABSENT claude-mem must never block or error a real hmd session ────
# The motivating incident was a HOOK blocking a session, not the installer.
# bin/heimdall-scrub-claude-mem is the one hmd-owned surface still wired to
# claude-mem by design (SessionStart routing/credential scrub) — drive the
# REAL script, not a re-extracted fragment, under a hard watchdog with
# claude-mem unreachable, and prove it completes fast, clean, exit 0.
# Portable timeout: perl alarm+fork+exec+waitpid, exit 124 on timeout. This is
# not a stylistic choice — macOS ships neither GNU `timeout` nor `gtimeout`
# (verified absent on this machine), and it is the same idiom already used by
# both test/run-all.sh's timeout_run() and hooks.json's own claude-mem entry
# ("perl -e 'alarm 10; exec @ARGV'").
_timeout_run() {
  local secs="$1"; shift
  perl -e '
    my $t = shift @ARGV;
    my $pid = fork();
    die "timeout_run: fork failed: $!\n" unless defined $pid;
    if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127; }
    my $timed_out = 0;
    $SIG{ALRM} = sub {
      $timed_out = 1;
      kill("TERM", -$pid);
      select(undef, undef, undef, 2);
      kill("KILL", -$pid);
    };
    alarm $t;
    my $got = waitpid($pid, 0);
    my $st  = $?;
    $got = waitpid($pid, 0) if $got == -1 && !$timed_out;
    alarm 0;
    exit 124 if $timed_out;
    exit(($st & 127) ? 128 + ($st & 127) : ($st >> 8));
  ' -- "$secs" "$@"
}

SCRUB="$REPO/bin/heimdall-scrub-claude-mem"
if [ ! -x "$SCRUB" ]; then
  bad "D0 bin/heimdall-scrub-claude-mem missing or not executable"
else
  DABS="$(mktemp -d)"
  # A fresh, empty HOME/HEIMDALL_HOME and a PATH with no claude-mem-named
  # binary reachable — claude-mem is genuinely unreachable from this process.
  SECONDS=0
  OUT="$(HOME="$DABS" PATH="/usr/bin:/bin" HEIMDALL_HOME="$DABS/.heimdall" \
    _timeout_run 10 "$SCRUB" </dev/null 2>&1)"
  RC=$?
  ELAPSED=$SECONDS
  rm -rf "$DABS"

  if [ "$RC" -eq 124 ]; then
    bad "D1 scrub hook HUNG on an absent claude-mem (killed by the 10s watchdog)"
  elif [ "$RC" -eq 0 ]; then
    ok "D1 scrub hook exits 0 with claude-mem absent (fail-open, never blocks)"
  else
    bad "D1 scrub hook exited $RC (nonzero) with claude-mem absent — must be 0 (out: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-160))"
  fi

  if [ "$ELAPSED" -lt 5 ]; then
    ok "D2 scrub hook returned in ${ELAPSED}s (well under the 10s watchdog — not merely timeout-rescued)"
  else
    bad "D2 scrub hook took ${ELAPSED}s — approaching the watchdog, not genuinely fast"
  fi
fi

echo "claude-mem-plugin-retire.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
