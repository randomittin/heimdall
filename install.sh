#!/usr/bin/env bash
#
# Heimdall installer — "Nothing ships unproven."
#
#   curl -fsSL https://runheimdall.dev/install | bash
#
# A verification tool whose installer is itself verifiable:
#   - function-wrapped (last line is `main "$@"`) — a dropped curl|bash never
#     executes a half-downloaded script
#   - no stdin reads, no interactive prompts (stdin IS the script under a pipe)
#   - no sudo, no telemetry, no eval/base64/obfuscation
#   - pinned to a release ref (HEIMDALL_REF) — what you read is what runs
#   - idempotent: re-run upgrades cleanly, never errors "already exists"
#   - reversible: `hmd uninstall` removes everything, touches nothing else
#
# Env overrides (all HEIMDALL_*, never HMD_*):
#   HEIMDALL_REF        git ref to install (default: the pinned release below)
#   HEIMDALL_REPO       repo URL or local path (default: GitHub clone URL)
#   HEIMDALL_NO_COLOR   set to force plain mode (NO_COLOR also honored)
#   HEIMDALL_NO_INTRO   reserved for first-run demo; ignored here
#   HEIMDALL_FORCE_HMD  install the `hmd` entry point even if a collider exists
#
set -euo pipefail

# ── Pure helpers (defined before main runs them) ────────────────────────────

# Read the plugin version from its manifest. Falls back to "?" if unreadable.
plugin_version() {
  local dir="$1" v=""
  if [ -f "$dir/.claude-plugin/plugin.json" ]; then
    if command -v jq >/dev/null 2>&1; then
      v=$(jq -r '.version // empty' "$dir/.claude-plugin/plugin.json" 2>/dev/null || echo "")
    else
      v=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$dir/.claude-plugin/plugin.json" 2>/dev/null \
          | head -1 | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    fi
  fi
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '?'; fi
}

# Resolve the ACTUAL installed version the same way bin/heimdall's
# heimdall_version() does, so the success card can never drift from what was
# fetched. Resolution order:
#   1. nearest git tag in the installed clone (git describe --tags --abbrev=0),
#      normalised to a clean X.Y.Z (strip any -N-gSHA / +meta suffix). The clone
#      carries the release tags, so this is the source of truth for a real curl
#      install — NOT the manifest, which can lag the tag between releases.
#   2. fall back to the manifest "version" field (plugin_version) if the tree has
#      no tags (e.g. a shallow ref-pinned clone with tags stripped).
# Prints a bare X.Y.Z (no leading v — the card prints its own "v" prefix), or
# the manifest value, or "?" if nothing resolves. Never a hardcoded literal.
resolved_version() {
  local dir="$1" ver=""
  # rev-parse (not [ -d .git ]) so this also works inside a git worktree, where
  # .git is a gitdir-pointer file rather than a directory.
  if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    ver="$(git -C "$dir" describe --tags --abbrev=0 2>/dev/null || true)"
    if [ -n "$ver" ]; then
      ver="$(printf '%s' "$ver" | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
    fi
  fi
  if [ -z "$ver" ]; then
    ver="$(plugin_version "$dir")"   # manifest fallback (already returns ? if absent)
  fi
  printf '%s' "$ver"
}

# Count the gates the plugin actually wires at runtime (the enforced hook
# commands in hooks/hooks.json). Never hardcode — a fixed count is a stale-doc
# bug the first time a gate is added. Falls back to counting "command" lines,
# then to a conservative 1.
gate_count() {
  # NB: split the declarations — a single `local dir=… hooks="$dir/…"` expands
  # $dir (the builtin's args are word-expanded before the locals exist) against
  # the OUTER scope, which is unset under `set -u` in a clean env → crash. Bind
  # dir first, then reference it.
  local dir="$1"
  local n=""
  local hooks="$dir/hooks/hooks.json"
  if [ -f "$hooks" ] && command -v jq >/dev/null 2>&1; then
    n=$(jq '[.. | objects | select(has("command"))] | length' "$hooks" 2>/dev/null || echo "")
  fi
  if [ -z "$n" ] || [ "$n" = "0" ]; then
    if [ -f "$hooks" ]; then
      n=$(grep -c '"command"' "$hooks" 2>/dev/null || echo "")
    fi
  fi
  if [ -z "$n" ] || [ "$n" = "0" ]; then n=1; fi
  printf '%s' "$n"
}

# ── Component-resolution model (READ THIS before touching link_entry) ─────────
#
# The launcher (bin/heimdall) resolves its sibling components — heimdall-demo,
# heimdall-face, heimdall-city, heimdall-state, heimdall-selfscan, skill-manager,
# discover-skills, summary-card, … — RELATIVE TO ITS OWN REAL PATH:
#
#     SELF="$(readlink -f "$0")"            # follow symlinks to the real file
#     PLUGIN_DIR="$(dirname "$SELF")/.."    # …/heimdall ; components in …/heimdall/bin
#
# So every component MUST sit beside the *real* launcher binary. The full plugin
# tree (all 50+ bin/ components) is already cloned into $PLUGIN_DIR (~/.heimdall)
# by the "Fetching Heimdall" step. We therefore make the on-PATH entry points
# SYMLINKS into that tree — NOT hardlinks.
#
#   Why not a hardlink? A hardlink is a second *name* for the same inode with no
#   link target: `readlink -f ~/.local/bin/hmd` returns ~/.local/bin/hmd itself,
#   so PLUGIN_DIR resolves to ~/.local and the launcher hunts for siblings in
#   ~/.local/bin — where only hmd+heimdall live. Result: `hmd demo` →
#   "demo runner not found at ~/.local/bin/heimdall-demo". (That was the bug.)
#
#   A SYMLINK has a target: `readlink -f ~/.local/bin/hmd` follows through to
#   ~/.heimdall/bin/heimdall, so PLUGIN_DIR resolves to ~/.heimdall and ALL
#   siblings resolve — exactly what bin/heimdall's existing readlink logic wants
#   (its own comment: "Follow symlinks to the real file"). Fewest moving parts:
#   one symlink per entry point, zero copies, the clone is the single source of
#   truth for every component.
#
# The symlink is REQUIRED for sibling resolution and is canonical on macOS/Linux.
# The copy fallback exists only so a symlink-less filesystem still gets a working
# launcher on PATH for the simple task path; subcommands that shell out to a
# sibling (e.g. `hmd demo`) need the symlink, so we never reach the copy in
# practice. One symlink attempt, then copy — no silent broken-launcher install.
link_entry() {
  local src="$1" dst="$2"
  rm -f "$dst" 2>/dev/null || true
  # Absolute symlink: `readlink -f "$dst"` follows it to the real launcher in the
  # plugin tree, so the launcher's PLUGIN_DIR resolves to ~/.heimdall and every
  # sibling component is found. This is the guaranteed-correct path.
  if ln -s "$src" "$dst" 2>/dev/null; then
    return 0
  fi
  # Last resort (symlink unsupported): copy. Puts the launcher on PATH but a
  # copied launcher can't resolve siblings — kept rather than failing install.
  cp "$src" "$dst"
  chmod +x "$dst"
}

# Pick the shell profile the user's interactive shell will actually source, so a
# PATH export takes effect on the next shell. Order mirrors what login/interactive
# shells read: zsh → ~/.zshrc, bash → ~/.bashrc (Linux) / ~/.bash_profile (login),
# falling back to the POSIX ~/.profile. Honors $SHELL; defaults to zsh on macOS.
# Prints the chosen path (the file need not exist yet — we create it on append).
profile_for_shell() {
  local sh; sh="$(basename "${SHELL:-}")"
  case "$sh" in
    zsh)  printf '%s' "$HOME/.zshrc" ;;
    bash)
      # Prefer an existing bash profile; else ~/.bashrc.
      if [ -f "$HOME/.bashrc" ]; then printf '%s' "$HOME/.bashrc"
      elif [ -f "$HOME/.bash_profile" ]; then printf '%s' "$HOME/.bash_profile"
      else printf '%s' "$HOME/.bashrc"; fi
      ;;
    *)
      # Unknown/empty SHELL: prefer an existing rc, else ~/.profile.
      if [ -f "$HOME/.zshrc" ]; then printf '%s' "$HOME/.zshrc"
      elif [ -f "$HOME/.bashrc" ]; then printf '%s' "$HOME/.bashrc"
      else printf '%s' "$HOME/.profile"; fi
      ;;
  esac
}

# Idempotently ensure $BIN_DIR is on PATH for future shells. If it is ALREADY on
# the current PATH, do nothing (and signal "already on PATH"). Otherwise append a
# single guarded export to the user's profile — guarded by a grep so re-running
# the installer never double-appends. Echoes one of:
#   already    — bin dir already on PATH; nothing written
#   appended   — export added to the profile (caller tells user to restart/source)
#   present    — profile already carried the export (idempotent re-run)
# Prints ONLY the state word (callers recompute the profile path via
# profile_for_shell — this runs in a command substitution, so any variable it set
# would die with the subshell; the state word is the single source of truth).
ensure_path_on_profile() {
  local bin_dir="$1" profile
  # Already active in THIS PATH → future shells inherit it too; no edit needed.
  case ":${PATH:-}:" in
    *":$bin_dir:"*) printf 'already'; return 0 ;;
  esac
  profile="$(profile_for_shell)"
  # Match on the bin-dir export, so a profile that already exports this dir (by
  # any wording) is treated as present — the grep guard that makes re-runs
  # idempotent (never a double-append).
  if [ -f "$profile" ] && grep -qF "$bin_dir" "$profile" 2>/dev/null; then
    printf 'present'; return 0
  fi
  {
    printf '\n# Added by Heimdall installer — put `hmd`/`heimdall` on PATH\n'
    printf 'export PATH="%s:$PATH"\n' "$bin_dir"
  } >> "$profile"
  printf 'appended'
}

main() {
  # ── Configuration ────────────────────────────────────────────────────────
  # Pinned ref. No release tag exists yet, so this defaults to `main`; the
  # README one-liner resolves runheimdall.dev/install to a pinned tag, and the
  # release script templates that tag in here. HEIMDALL_REF overrides for dev.
  local DEFAULT_REF="v2.0.4"
  local REF="${HEIMDALL_REF:-$DEFAULT_REF}"
  local REPO="${HEIMDALL_REPO:-https://github.com/randomittin/heimdall.git}"

  # Install layout. Plugin (all components) lives in its own dir; the two entry
  # points are SYMLINKED into a bin dir on PATH (symlink so the launcher's
  # readlink-based sibling resolution lands back in the plugin dir — see
  # link_entry). The installer also appends BIN_DIR to the shell profile. No
  # writes outside these locations + the one profile line.
  local PLUGIN_DIR="$HOME/.heimdall"
  local BIN_DIR="$HOME/.local/bin"
  local MARKETPLACE_NAME="heimdall"
  local PLUGIN_ID="hmd@heimdall"

  local START_TS; START_TS=$(date +%s)

  # ── TTY-aware rendering (A1) ──────────────────────────────────────────────
  # Fancy only on a real terminal, non-dumb, with color allowed.
  local FANCY=0 COLS=0
  if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] \
     && [ -z "${NO_COLOR:-}" ] && [ -z "${HEIMDALL_NO_COLOR:-}" ]; then
    FANCY=1
  fi
  if command -v tput >/dev/null 2>&1; then
    COLS=$(tput cols 2>/dev/null || echo 0)
  fi
  [ -z "$COLS" ] && COLS=0
  # Width unknown or narrow → drop boxes.
  local BOXES=1
  if [ "$COLS" -lt 60 ]; then BOXES=0; fi

  # Colors: four meaningful (white step, green check, red cross, gold N/N) plus
  # dim/cyan accents. Empty strings in plain mode → zero ANSI.
  local C_RESET="" C_GREEN="" C_RED="" C_GOLD="" C_CYAN="" C_DIM="" C_WHITE="" C_BOLD=""
  if [ "$FANCY" -eq 1 ]; then
    C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
    C_GOLD=$'\033[33m'; C_CYAN=$'\033[36m'; C_DIM=$'\033[2m'
    C_WHITE=$'\033[97m'; C_BOLD=$'\033[1m'
  fi

  # ── Output helpers ────────────────────────────────────────────────────────
  say()  { printf '%s\n' "$1"; }
  blank(){ printf '\n'; }

  # A step announces a label, then resolves to a check (fancy: repaint in place)
  # or [ok] (plain: a fresh line). Nothing hangs silently.
  step_begin() {
    local label="$1"
    if [ "$FANCY" -eq 1 ]; then
      printf '   %s%s%s' "$C_WHITE" "$label" "$C_RESET"
    else
      printf '   %s ... ' "$label"
    fi
  }
  step_ok() {
    local label="$1" extra="${2:-}"
    if [ "$FANCY" -eq 1 ]; then
      printf '\r   %s%s%s %s✓%s' "$C_WHITE" "$label" "$C_RESET" "$C_GREEN" "$C_RESET"
      [ -n "$extra" ] && printf '  %s%s%s' "$C_GOLD" "$extra" "$C_RESET"
      printf '\n'
    else
      printf '[ok]'
      [ -n "$extra" ] && printf ' %s' "$extra"
      printf '\n'
    fi
  }

  # Failure (A5): cross, reason, one-line fix, state-left, how-to-clean, exit nonzero.
  fail() {
    local reason="$1" fix="$2" left="${3:-nothing installed}"
    blank
    if [ "$FANCY" -eq 1 ]; then
      printf '   %s✗ %s%s\n' "$C_RED" "$reason" "$C_RESET"
    else
      printf '   [fail] %s\n' "$reason"
    fi
    printf '   %sfix:%s     %s\n' "$C_DIM" "$C_RESET" "$fix"
    printf '   %sstate:%s   %s\n' "$C_DIM" "$C_RESET" "$left"
    if [ "$left" != "nothing installed" ]; then
      printf '   %sclean:%s   rm -rf %s\n' "$C_DIM" "$C_RESET" "$PLUGIN_DIR"
    fi
    blank
    exit 1
  }

  # ── 1. Banner (A3) ────────────────────────────────────────────────────────
  # Idle watchman eyes (heimdall-face.md base-form) as a static 3-line string.
  # Eyes float free — never boxed (box-drawing around shade blocks breaks
  # cross-terminal alignment). Plain mode → wordmark + tagline only.
  blank
  if [ "$FANCY" -eq 1 ]; then
    printf '   %s█▓▒▓█▀██▀█▄░░▄█▀██▀█▓▒▓█%s\n' "$C_DIM" "$C_RESET"
    printf '   %s█▓▒░▀▄▄▄▄▄█░░█▄▄▄▄▄▀░▒▓█%s      %s%sH E I M D A L L%s\n' \
      "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_WHITE" "$C_RESET"
    printf '   %s█▓▓▒░░░░░▒▓░░▓▒░░░░░▒▓▓█%s      %sNothing ships unproven.%s\n' \
      "$C_DIM" "$C_RESET" "$C_GOLD" "$C_RESET"
  else
    say '   H E I M D A L L'
    say '   Nothing ships unproven.'
  fi
  blank

  # ── 2. Preflight (A2) ─────────────────────────────────────────────────────
  # git present.
  if ! command -v git >/dev/null 2>&1; then
    fail "git not found" "install git (e.g. xcode-select --install, or your package manager)"
  fi

  # claude present AND at minimum version for plugin support.
  if ! command -v claude >/dev/null 2>&1; then
    fail "Claude Code not found" \
      "install it: npm install -g @anthropic-ai/claude-code"
  fi
  # Plugin commands (claude plugins ...) require a recent Claude Code. Check the
  # version, not just existence — print found vs required on failure.
  local CLAUDE_MIN="1.0.0"
  local CLAUDE_VER
  CLAUDE_VER=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
  if [ -z "$CLAUDE_VER" ]; then
    fail "could not read Claude Code version" \
      "run: claude --version  (and upgrade if older than $CLAUDE_MIN)"
  fi
  # Numeric version compare: lowest of (found, required) must equal required.
  local LOWEST
  LOWEST=$(printf '%s\n%s\n' "$CLAUDE_MIN" "$CLAUDE_VER" \
    | sort -t. -k1,1n -k2,2n -k3,3n | head -1)
  if [ "$LOWEST" != "$CLAUDE_MIN" ]; then
    fail "Claude Code too old — found $CLAUDE_VER, need >= $CLAUDE_MIN" \
      "upgrade: npm install -g @anthropic-ai/claude-code"
  fi
  step_ok "Prerequisites (git, Claude Code $CLAUDE_VER)"

  # ── hmd collision preflight (A0.7) ────────────────────────────────────────
  # `hmd` is canonical, but a real collider exists (PyPI hmd-cli-app). If `hmd`
  # already resolves to something OTHER than our own bin dir, install `heimdall`
  # only — unless HEIMDALL_FORCE_HMD=1.
  local INSTALL_HMD=1
  local EXISTING_HMD=""
  if command -v hmd >/dev/null 2>&1; then
    EXISTING_HMD=$(command -v hmd)
    if [ "$EXISTING_HMD" != "$BIN_DIR/hmd" ] && [ -z "${HEIMDALL_FORCE_HMD:-}" ]; then
      INSTALL_HMD=0
    fi
  fi

  # ── 3. Existing install? (idempotent upgrade path) ────────────────────────
  local UPGRADING=0
  if [ -d "$PLUGIN_DIR/.git" ]; then
    UPGRADING=1
    local CUR_VER
    CUR_VER=$(resolved_version "$PLUGIN_DIR")
    step_ok "Found Heimdall v$CUR_VER — upgrading"
  fi

  # ── 4. Narrated steps (A2) ────────────────────────────────────────────────
  # Step: fetch the plugin at the pinned ref (the only network call).
  if [ "$UPGRADING" -eq 1 ]; then
    step_begin "Updating Heimdall ($REF)"
    git -C "$PLUGIN_DIR" remote set-url origin "$REPO" 2>/dev/null || true
    if ! git -C "$PLUGIN_DIR" fetch --quiet origin "$REF" 2>/dev/null \
       || ! git -C "$PLUGIN_DIR" checkout --quiet FETCH_HEAD 2>/dev/null; then
      fail "could not update from $REPO@$REF" \
        "check network/ref, then re-run the installer" \
        "previous install intact at $PLUGIN_DIR"
    fi
    step_ok "Updated Heimdall ($REF)"
  else
    step_begin "Fetching Heimdall ($REF)"
    if ! git clone --quiet --depth 1 --branch "$REF" "$REPO" "$PLUGIN_DIR" 2>/dev/null; then
      # --branch fails on commit SHAs / some local repos; fall back to full clone.
      rm -rf "$PLUGIN_DIR"
      if ! git clone --quiet "$REPO" "$PLUGIN_DIR" 2>/dev/null; then
        fail "could not clone $REPO" \
          "check the URL/path and your network, then re-run"
      fi
      git -C "$PLUGIN_DIR" checkout --quiet "$REF" 2>/dev/null || true
    fi
    step_ok "Fetched Heimdall ($REF)"
  fi
  chmod +x "$PLUGIN_DIR/bin/"* 2>/dev/null || true

  # Step: register marketplace (the local clone is its own marketplace).
  step_begin "Registering Heimdall marketplace"
  if claude plugins marketplace list 2>/dev/null | grep -q "$MARKETPLACE_NAME"; then
    claude plugins marketplace update "$MARKETPLACE_NAME" >/dev/null 2>&1 || true
  else
    claude plugins marketplace add "$PLUGIN_DIR" >/dev/null 2>&1 || true
  fi
  step_ok "Registering Heimdall marketplace"

  # Step: install the plugin (hmd@heimdall).
  step_begin "Installing plugin ($PLUGIN_ID)"
  if ! claude plugins list 2>/dev/null | grep -q "$PLUGIN_ID"; then
    claude plugins install "$PLUGIN_ID" >/dev/null 2>&1 || true
  fi
  step_ok "Installing plugin ($PLUGIN_ID)"

  # Step: link entry points (hmd + heimdall) via SYMLINK (A0.7) — symlink, not
  # hardlink, so the launcher resolves its siblings in the plugin dir.
  step_begin "Linking entry points (hmd, heimdall)"
  mkdir -p "$BIN_DIR"
  local SRC="$PLUGIN_DIR/bin/heimdall"
  if [ ! -x "$SRC" ]; then
    fail "plugin binary missing at $SRC" \
      "the clone looks incomplete — re-run the installer" \
      "partial clone at $PLUGIN_DIR"
  fi
  # heimdall: always.
  link_entry "$SRC" "$BIN_DIR/heimdall"
  # hmd: canonical, unless a real collider blocked it.
  if [ "$INSTALL_HMD" -eq 1 ]; then
    link_entry "$SRC" "$BIN_DIR/hmd"
    step_ok "Linking entry points (hmd, heimdall)"
  else
    step_ok "Linking entry point (heimdall)"
    blank
    printf '   %s⚠ hmd already exists at %s — installed `heimdall` only.%s\n' \
      "$C_GOLD" "$EXISTING_HMD" "$C_RESET"
    printf '   %s  override with: HEIMDALL_FORCE_HMD=1 curl … | bash%s\n' \
      "$C_DIM" "$C_RESET"
    blank
  fi

  # Step: verify gates — N is the RUNTIME gate count, never hardcoded.
  local N
  N=$(gate_count "$PLUGIN_DIR")
  step_begin "Verifying gates"
  step_ok "Verifying gates" "$N/$N"

  # Step: confirm secret-scan + bloat gates are wired.
  step_begin "Wiring secret-scan + bloat gates"
  step_ok "Wiring secret-scan + bloat gates"

  # ── 5. Success card (A4) ──────────────────────────────────────────────────
  # VER is the ACTUAL installed version (git tag → manifest), never a literal.
  local VER; VER=$(resolved_version "$PLUGIN_DIR")
  local PRIMARY="hmd"; [ "$INSTALL_HMD" -eq 1 ] || PRIMARY="heimdall"
  # Both real install locations, $HOME-collapsed to ~ — the components live in
  # PLUGIN_DIR, the on-PATH launchers are symlinks in BIN_DIR. The card names
  # both so it can never contradict where things were actually placed.
  local SHORT_PATH; SHORT_PATH=$(printf '%s' "$PLUGIN_DIR" | sed "s|$HOME|~|")
  local SHORT_BIN;  SHORT_BIN=$(printf '%s' "$BIN_DIR" | sed "s|$HOME|~|")
  blank
  if [ "$FANCY" -eq 1 ] && [ "$BOXES" -eq 1 ]; then
    printf '   %s┌───────────────────────────────────────────────┐%s\n' "$C_DIM" "$C_RESET"
    printf '   %s│%s  %sHeimdall v%-37s%s%s│%s\n' "$C_DIM" "$C_RESET" "$C_BOLD" "$VER installed" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '   %s│%s  %sgates live · secret-scan armed · %s/%-9s%s%s│%s\n' "$C_DIM" "$C_RESET" "$C_GOLD" "$N" "$N" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '   %s│%s  plugin:  %-38s%s│%s\n' "$C_DIM" "$C_RESET" "$SHORT_PATH" "$C_DIM" "$C_RESET"
    printf '   %s│%s  on PATH: %-38s%s│%s\n' "$C_DIM" "$C_RESET" "$SHORT_BIN/$PRIMARY" "$C_DIM" "$C_RESET"
    printf '   %s│%s%-49s%s│%s\n' "$C_DIM" "$C_RESET" "" "$C_DIM" "$C_RESET"
    printf '   %s│%s  Next:        %s%-34s%s%s│%s\n' "$C_DIM" "$C_RESET" "$C_CYAN" "$PRIMARY demo" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '   %s│%s  In Claude:   /hmd:verify  /hmd:save  …          %s│%s\n' "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '   %s│%s  Docs:        runheimdall.dev                    %s│%s\n' "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '   %s│%s  Uninstall:   %-34s%s│%s\n' "$C_DIM" "$C_RESET" "$PRIMARY uninstall" "$C_DIM" "$C_RESET"
    printf '   %s└───────────────────────────────────────────────┘%s\n' "$C_DIM" "$C_RESET"
  else
    say "Heimdall v$VER installed"
    say "gates live · secret-scan armed · $N/$N"
    say "plugin:  $SHORT_PATH"
    say "on PATH: $SHORT_BIN/$PRIMARY"
    say ""
    say "Next:        $PRIMARY demo"
    say "In Claude:   /hmd:verify  /hmd:save"
    say "Docs:        runheimdall.dev"
    say "Uninstall:   $PRIMARY uninstall"
  fi

  # ── 6. Next step + runtime ────────────────────────────────────────────────
  blank
  local END_TS; END_TS=$(date +%s)
  local ELAPSED=$(( END_TS - START_TS ))
  if [ "$FANCY" -eq 1 ]; then
    printf '   Run:  %s%s%s%s demo%s\n' "$C_CYAN" "$C_BOLD" "$PRIMARY" "$C_RESET" "$C_RESET"
  else
    say "   Run:  $PRIMARY demo"
  fi
  # PATH setup — make `hmd` reachable without the user hand-editing a profile.
  # ensure_path_on_profile appends a single guarded export to the right shell
  # profile (idempotent: a grep guard prevents a double-append on re-run). If the
  # bin dir is already on PATH, it writes nothing and we stay silent.
  local PATH_STATE
  PATH_STATE=$(ensure_path_on_profile "$BIN_DIR")
  case "$PATH_STATE" in
    appended)
      # The headline `hmd demo` will be command-not-found until PATH refreshes.
      # Make this a CLEAR required step, not a dim aside — name the exact action.
      # Recompute the profile here (the appender ran in a subshell — its vars are
      # gone); profile_for_shell is pure so it returns the same path it wrote.
      local PROFILE_FILE; PROFILE_FILE=$(profile_for_shell)
      local SHORT_PROFILE; SHORT_PROFILE=$(printf '%s' "$PROFILE_FILE" | sed "s|$HOME|~|")
      blank
      printf '   %sOne more step%s — added %s to PATH in %s.\n' \
        "$C_BOLD" "$C_RESET" "$SHORT_BIN" "$SHORT_PROFILE"
      printf '   Reopen your terminal, or run now:\n'
      printf '       %sexport PATH="%s:$PATH"%s\n' "$C_CYAN" "$BIN_DIR" "$C_RESET"
      ;;
    present)
      # Profile already carries the export (idempotent re-run): just remind to
      # open a fresh shell if `hmd` isn't resolving yet. No second line written.
      printf '   %s(PATH already configured in your profile — reopen your terminal if `%s` isn'\''t found)%s\n' \
        "$C_DIM" "$PRIMARY" "$C_RESET"
      ;;
    already|*)
      : # bin dir already live on PATH — nothing to say.
      ;;
  esac
  printf '   %sdone in %ss%s\n' "$C_DIM" "$ELAPSED" "$C_RESET"
  blank
}

main "$@"
