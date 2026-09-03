#!/usr/bin/env bash
# caveman-plugin-retire.test.sh — an hmd update must RETIRE the legacy external
# caveman plugin, because compression moved in-house.
#
# THE BUG THIS PINS: hmd used to install caveman@caveman as a companion
# (`claude plugins marketplace add JuliusBrussee/caveman`), so every user who
# installed hmd before compression was in-housed still has it. Both then inject
# a compression instruction at DISAGREEING levels — the plugin resets itself to
# "full" on restart (the defect that caused the move) while hmd holds "ultra".
# Two conflicting instructions are worse than either alone and silently
# invalidate any measurement taken afterwards. Verified on this machine: after
# the operator removed the marketplace, the cache dir AND .caveman-active
# (still reading "full") both survived.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

[ -f "$REPO/install.sh" ] || { echo "FATAL: install.sh missing"; exit 2; }

# ── A — the function exists and is wired into the install/update path ─────────
if grep -q 'ensure_caveman_plugin_retired()' "$REPO/install.sh"; then
  ok "A1 ensure_caveman_plugin_retired is defined in install.sh"
else
  bad "A1 retirement function absent — an update would leave the plugin installed"
fi

if grep -q 'CAV_STATE="\$(ensure_caveman_plugin_retired)"' "$REPO/install.sh"; then
  ok "A2 it is CALLED (defining it without calling it is dead code)"
else
  bad "A2 function defined but never invoked — dead on arrival"
fi

# ── B — behaviour, driven through a fake `claude` CLI ─────────────────────────
# install.sh is sourced-and-called with a stub CLI on PATH so no real plugin
# state is ever touched.
_extract() {
  sed -n '/^ensure_caveman_plugin_retired() {/,/^}/p' "$REPO/install.sh"
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
  PATH="$d:/usr/bin:/bin" HEIMDALL_KEEP_CAVEMAN_PLUGIN="$keep" \
    bash -c "$(_extract)
ensure_caveman_plugin_retired" 2>/dev/null
  rm -rf "$d"
}

S="$(_run_state 'superpowers@obra
claude-mem@thedotmack')"
if [ "$S" = "absent" ]; then
  ok "B1 plugin not installed -> 'absent' (cheap no-op steady state)"
else
  bad "B1 expected absent with no caveman installed, got '$S'"
fi

S="$(_run_state 'caveman@caveman
superpowers@obra' 1)"
if [ "$S" = "kept" ]; then
  ok "B2 HEIMDALL_KEEP_CAVEMAN_PLUGIN=1 -> 'kept' (opt-out honoured)"
else
  bad "B2 expected kept with the opt-out set, got '$S'"
fi

# `claude` absent entirely -> skipped, never a failure
S="$(PATH=/usr/bin:/bin bash -c "$(_extract)
ensure_caveman_plugin_retired" 2>/dev/null)"
if [ "$S" = "skipped" ]; then
  ok "B3 no claude CLI -> 'skipped' (never fatal)"
else
  bad "B3 expected skipped without the claude CLI, got '$S'"
fi

# ── C — scoping: it must never touch an unrelated plugin ─────────────────────
if grep -q 'claude plugins uninstall caveman@caveman' "$REPO/install.sh"; then
  ok "C1 uninstall targets caveman@caveman EXACTLY, not a wildcard"
else
  bad "C1 uninstall target is not the exact plugin id — scope risk"
fi

if grep -q 'marketplace remove JuliusBrussee' "$REPO/install.sh"; then
  ok "C2 marketplace removal targets JuliusBrussee only"
else
  bad "C2 marketplace removal target missing or broadened"
fi

# The marketplace removal must be GUARDED by a re-check that nothing from it
# remains — removing a marketplace another plugin needs breaks its updates.
if sed -n '/^ensure_caveman_plugin_retired() {/,/^}/p' "$REPO/install.sh" \
     | grep -B2 'marketplace remove' | grep -q 'grep -qi'; then
  ok "C3 marketplace removal is guarded by a post-uninstall re-check"
else
  bad "C3 marketplace removed unconditionally — could break another plugin"
fi

echo "caveman-plugin-retire.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
