#!/usr/bin/env bash
# Journey 01 -- install hmd on a clean machine (README "Install", "What the installer writes outside the repo", docs/INSTALL.md).
#
#   A developer with Claude Code, git and their own dotfiles runs install.sh. The installer is the real one, pinned to the tag of the checkout under test and
#   fed from a local snapshot of it (no network), against a throwaway HOME with their own .zshrc and ~/.claude/settings.json:
#     1. it finishes (exit 0, no prompt, no hang), says "Heimdall v<this version> installed" and that all systems go
#     2. ~/.heimdall is a clone at exactly the installed commit; ~/.local/bin/hmd and /heimdall are symlinks into it
#     3. in a new shell (their profile sourced) `hmd` resolves by name and `hmd version` reports this version and commit
#     4. it wrote only what the README documents: ~/.heimdall, the two symlinks, the statusLine entries in ~/.claude/settings.json, ONE PATH line in the profile.
#        Their own profile line and settings key are still there; Claude Code was told about the plugin (marketplace add, plugins install); no keychain access
#     5. running it again is idempotent: exit 0, still one PATH line, same commit
#     6. the next step the README gives works from the installed hmd: `hmd attack ~/.heimdall/fixtures/attack/buggy-webhook --yes` is DENIED
#
# Engines reused: test/install-stranger.test.sh (stranger HOME, PATH setup, statusline, idempotency), test/install-validate.test.sh (fake claude, local source).
# Mutants (test/use-cases/mutants.list): the PATH line is never written, the entry points are copies instead of symlinks.
# shellcheck disable=SC2088  # the ~ in the check names is prose for the user's home, never a path this script expands
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"
uc_begin 01_install_on_a_clean_machine
uc_need_node
uc_need_crypto
uc_tree
uc_fakebin
uc_sandbox install

# the developer's own machine: a profile with a line of theirs and a Claude Code settings file with a key of theirs
printf '# my zshrc\nexport EDITOR=vim\n' > "$UC_HOME/.zshrc"
mkdir -p "$UC_HOME/.claude"
printf '{"theme":"dark"}\n' > "$UC_HOME/.claude/settings.json"

# 1. the installer, from the tree under test
uc_install "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh
CARD="$UC_ROOT/install-1.out"; cp "$UC_OUT" "$CARD"
uc_rc "install.sh finishes" 0
uc_has "the card says this version was installed" "$CARD" "Heimdall v$UC_VERSION installed"
uc_has "the validation gate says all systems go" "$CARD" 'all systems go'
uc_lacks "…and never NOT READY" "$CARD" 'NOT READY'

# 2. what was placed
INSTALLED="$UC_HOME/.heimdall"
if [ "$(git -C "$INSTALLED" rev-parse HEAD 2>/dev/null)" = "$UC_SHA" ]; then uc_ok "~/.heimdall is a clone at exactly the installed commit"; else uc_bad "~/.heimdall is not a clone of the tree under test at $UC_SHA"; fi
real_launcher="$(cd "$INSTALLED/bin" && pwd -P)/heimdall"
for name in hmd heimdall; do
  link="$UC_HOME/.local/bin/$name"
  if [ -L "$link" ] && [ "$(cd "$(dirname "$(readlink -f "$link")")" && pwd -P)/$(basename "$(readlink -f "$link")")" = "$real_launcher" ]; then
    uc_ok "~/.local/bin/$name is a symlink to the installed launcher"
  else
    uc_bad "~/.local/bin/$name is not a symlink into ~/.heimdall/bin/heimdall" "$(ls -l "$link" 2>&1 | head -c 200)"
  fi
done

# 3. a new shell: the profile is sourced, hmd resolves by name
uc_run "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh -- bash -c '. "$HOME/.zshrc"; command -v hmd; hmd version'
uc_rc "in a new shell hmd resolves and runs" 0
uc_has "…as the installed symlink" "$UC_OUT" '/\.local/bin/hmd'
uc_has "hmd version reports this version" "$UC_OUT" "Heimdall v$UC_VERSION"
uc_has "…and the installed commit" "$UC_OUT" "commit $(printf '%s' "$UC_SHA" | cut -c1-7)"

# 4. only what the README documents, and nothing of theirs lost
if [ "$(grep -c '\.local/bin' "$UC_HOME/.zshrc")" = 1 ]; then uc_ok "the profile gained exactly one PATH line"; else uc_bad "the profile has $(grep -c '\.local/bin' "$UC_HOME/.zshrc") lines naming .local/bin, want 1"; fi
uc_has "…and their own profile line is still there" "$UC_HOME/.zshrc" '^export EDITOR=vim$'
uc_jq "their own settings key is still there" '.theme == "dark"' "$UC_HOME/.claude/settings.json"
uc_jq "the statusLine and subagentStatusLine point at the installed scripts, not at an unresolved variable" \
  '(.statusLine.command | contains("/.heimdall/hooks/statusline.sh")) and (.subagentStatusLine.command | contains("/.heimdall/hooks/subagent-statusline.sh")) and ([.statusLine.command, .subagentStatusLine.command] | all(contains("CLAUDE_PLUGIN_ROOT") | not))' \
  "$UC_HOME/.claude/settings.json"
uc_has "Claude Code was asked to register the marketplace" "$UC_CLAUDE_LOG" "^claude plugins marketplace add .*/\\.heimdall\$"
uc_has "…and to install the plugin" "$UC_CLAUDE_LOG" '^claude plugins install hmd@heimdall$'
extra="$(cd "$UC_HOME" && find . -mindepth 1 -maxdepth 1 ! -name .heimdall ! -name .local ! -name .claude ! -name .zshrc | sort | tr '\n' ' ')"
if [ -z "$extra" ]; then uc_ok "HOME holds only .heimdall, .local, .claude and the profile"; else uc_bad "the installer wrote outside the documented paths" "$extra"; fi
extra="$(cd "$UC_HOME/.local" && find . -mindepth 1 ! -path ./bin ! -path ./bin/hmd ! -path ./bin/heimdall | sort | tr '\n' ' ')"
if [ -z "$extra" ]; then uc_ok "~/.local holds only bin/hmd and bin/heimdall"; else uc_bad "unexpected files under ~/.local" "$extra"; fi
extra="$(cd "$UC_HOME/.claude" && find . -mindepth 1 ! -name settings.json | sort | tr '\n' ' ')"
if [ -z "$extra" ]; then uc_ok "~/.claude holds only settings.json"; else uc_bad "unexpected files under ~/.claude" "$extra"; fi
if [ ! -s "$UC_SECURITY_LOG" ]; then uc_ok "the keychain was never asked"; else uc_bad "the installer asked the keychain" "$(head -c 200 "$UC_SECURITY_LOG")"; fi

# 5. again: idempotent
uc_install "$UC_HOME" "$UC_WORK" SHELL=/bin/zsh
uc_rc "running install.sh again" 0
uc_has "…recognises the existing install and updates it in place" "$UC_OUT" "Updating Heimdall \\($UC_REF\\)"
if [ "$(grep -c '\.local/bin' "$UC_HOME/.zshrc")" = 1 ]; then uc_ok "…and does not append a second PATH line"; else uc_bad "the second install appended another PATH line"; fi
if [ "$(git -C "$INSTALLED" rev-parse HEAD 2>/dev/null)" = "$UC_SHA" ]; then uc_ok "…and stays at the same commit"; else uc_bad "the second install moved ~/.heimdall off $UC_SHA"; fi

# 6. the README's next step, from the installed hmd
uc_run "$UC_HOME" "$UC_WORK" -- "$UC_HOME/.local/bin/hmd" attack "$UC_HOME/.heimdall/fixtures/attack/buggy-webhook" --yes
uc_rc "hmd attack ~/.heimdall/fixtures/attack/buggy-webhook, as the README says, is DENIED" 1
uc_has "…with the verdict card" "$UC_OUT" 'VERDICT: DENIED'

uc_finish
