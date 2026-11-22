#!/usr/bin/env bash
# Journey 02 -- uninstall hmd and get the machine back (README "hmd uninstall reverses all of it", install.sh "reversible: `hmd uninstall` removes everything,
# touches nothing else").
#
#   A developer installed hmd (the real installer, as in journey 01) onto a machine that already had their own .zshrc and ~/.claude/settings.json, and now leaves:
#     1. `hmd uninstall` with no terminal and no --yes refuses (exit 2) and removes nothing: it never hangs on a prompt nobody can answer
#     2. `hmd uninstall --yes` finishes (exit 0) and says hmd was removed
#     3. ~/.heimdall and both ~/.local/bin entry points are gone; Claude Code was told to uninstall the plugin and remove the marketplace
#     4. their profile is back to their own lines: the PATH export is gone, nothing else of theirs was touched
#     5. their settings.json is semantically what it was before the install: the statusLine entries went, their keys stayed; the one backup it announced exists
#     6. nothing else is left in HOME: only their own files and that backup; no keychain access
#
# Engines reused: test/install-stranger.test.sh sections 7a-7k (uninstall completeness, statusline splice).
# Mutants (test/use-cases/mutants.list): the PATH export is never removed, the install tree is never removed.
# shellcheck disable=SC2088  # the ~ in the check names is prose for the user's home, never a path this script expands
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"
uc_begin 02_uninstall_leaves_nothing_behind
uc_need_crypto
uc_tree
uc_fakebin
uc_sandbox uninstall

printf '# my zshrc\nexport EDITOR=vim\n' > "$UC_HOME/.zshrc"
ZSHRC_BEFORE="$(cat "$UC_HOME/.zshrc")"
mkdir -p "$UC_HOME/.claude"
printf '{"theme":"dark","model":"opus"}\n' > "$UC_HOME/.claude/settings.json"
SETTINGS_BEFORE="$(jq -S . "$UC_HOME/.claude/settings.json")"

uc_install "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh
uc_rc "(setup) the real installer puts hmd on the machine" 0
HMD="$UC_HOME/.local/bin/hmd"
if [ -d "$UC_HOME/.heimdall" ] && [ -L "$HMD" ]; then uc_ok "(setup) hmd is installed: ~/.heimdall and the entry point exist"; else uc_bad "(setup) the install left no ~/.heimdall or no hmd entry point: nothing to uninstall"; fi
: > "$UC_CLAUDE_LOG"     # only what the uninstall asks of Claude Code counts below

# 1. no terminal, no --yes: refuses, removes nothing
uc_run "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh -- "$HMD" uninstall
uc_rc "uninstall without --yes and without a terminal refuses" 2
uc_has "…and says to pass --yes" "$UC_ERR" '--yes'
if [ -d "$UC_HOME/.heimdall" ] && [ -L "$HMD" ]; then uc_ok "…and removed nothing"; else uc_bad "the refused uninstall removed something"; fi

# 2. uninstall --yes
uc_run "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh -- "$HMD" uninstall --yes
uc_rc "uninstall --yes finishes" 0
uc_has "…and says hmd was removed" "$UC_OUT" 'Heimdall removed'

# 3. the install tree, the entry points, the Claude Code registration
if [ ! -e "$UC_HOME/.heimdall" ]; then uc_ok "~/.heimdall is gone"; else uc_bad "~/.heimdall survived the uninstall"; fi
for name in hmd heimdall; do
  if [ ! -e "$UC_HOME/.local/bin/$name" ] && [ ! -L "$UC_HOME/.local/bin/$name" ]; then uc_ok "~/.local/bin/$name is gone"; else uc_bad "~/.local/bin/$name survived the uninstall"; fi
done
uc_has "Claude Code was told to uninstall the plugin" "$UC_CLAUDE_LOG" '^claude plugins uninstall hmd@heimdall$'
uc_has "…and to remove the marketplace" "$UC_CLAUDE_LOG" '^claude plugins marketplace remove heimdall$'

# 4. their profile: their lines only (the blank line the installer put before its comment may stay: $(...) ignores trailing newlines)
if [ "$(cat "$UC_HOME/.zshrc")" = "$ZSHRC_BEFORE" ]; then uc_ok "the profile is back to the developer's own lines"; else uc_bad "the profile differs from what it was before the install" "$(head -c 300 "$UC_HOME/.zshrc" | LC_ALL=C tr '\n' '|')"; fi
uc_lacks "…no PATH export for ~/.local/bin is left in it" "$UC_HOME/.zshrc" '\.local/bin'

# 5. their settings
if [ "$(jq -S . "$UC_HOME/.claude/settings.json" 2>/dev/null)" = "$SETTINGS_BEFORE" ]; then uc_ok "settings.json is what it was before the install (statusLine entries gone, their keys kept)"; else uc_bad "settings.json differs from before the install" "$(head -c 300 "$UC_HOME/.claude/settings.json" | LC_ALL=C tr '\n' ' ')"; fi
BACKUP="$(find "$UC_HOME/.claude" -name 'settings.json.heimdall-uninstall-*.bak' | head -1)"
if [ -n "$BACKUP" ]; then uc_ok "the backup the uninstall announced exists"; else uc_bad "no settings.json.heimdall-uninstall-*.bak was left"; fi
uc_has "…and the output names it" "$UC_OUT" 'backup.*settings\.json\.heimdall-uninstall-[0-9]+\.bak'
if [ -n "$BACKUP" ]; then uc_jq "…and it holds the file as the install left it (with the statusLine)" '.statusLine.command != null and .theme == "dark"' "$BACKUP"; fi

# 6. nothing else
extra="$(cd "$UC_HOME" && find . -mindepth 1 ! -path ./.zshrc ! -path ./.claude ! -path ./.claude/settings.json ! -path './.claude/settings.json.heimdall-uninstall-*.bak' \
  ! -path ./.local ! -path ./.local/bin | sort | LC_ALL=C tr '\n' ' ')"
if [ -z "$extra" ]; then uc_ok "HOME holds only the developer's own files, the backup and the empty ~/.local/bin"; else uc_bad "the uninstall left more behind" "$extra"; fi
if [ ! -s "$UC_SECURITY_LOG" ]; then uc_ok "the keychain was never asked"; else uc_bad "the uninstall asked the keychain" "$(head -c 200 "$UC_SECURITY_LOG")"; fi

uc_finish
