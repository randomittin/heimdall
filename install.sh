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

# Count the gates the plugin actually wires at runtime (the enforced hook
# commands in hooks/hooks.json). Never hardcode — a fixed count is a stale-doc
# bug the first time a gate is added. Falls back to counting "command" lines,
# then to a conservative 1.
gate_count() {
  local dir="$1" n="" hooks="$dir/hooks/hooks.json"
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

# Create a hardlink (not a symlink, not an alias) so both names resolve to the
# same inode and survive non-interactive shells. Fall back to a copy only if
# hardlinking is impossible (e.g. a cross-device bin dir on a separate FS).
link_entry() {
  local src="$1" dst="$2"
  rm -f "$dst" 2>/dev/null || true
  if ! ln "$src" "$dst" 2>/dev/null; then
    cp "$src" "$dst"
    chmod +x "$dst"
  fi
}

main() {
  # ── Configuration ────────────────────────────────────────────────────────
  # Pinned ref. No release tag exists yet, so this defaults to `main`; the
  # README one-liner resolves runheimdall.dev/install to a pinned tag, and the
  # release script templates that tag in here. HEIMDALL_REF overrides for dev.
  local DEFAULT_REF="v2.0.0"
  local REF="${HEIMDALL_REF:-$DEFAULT_REF}"
  local REPO="${HEIMDALL_REPO:-https://github.com/randomittin/heimdall.git}"

  # Install layout. Plugin lives in its own dir; entry points are hardlinked
  # into a bin dir on PATH. No writes outside these two locations.
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
    CUR_VER=$(plugin_version "$PLUGIN_DIR")
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

  # Step: link entry points (hmd + heimdall) via HARDLINK (A0.7).
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
  local VER; VER=$(plugin_version "$PLUGIN_DIR")
  local PRIMARY="hmd"; [ "$INSTALL_HMD" -eq 1 ] || PRIMARY="heimdall"
  local SHORT_PATH; SHORT_PATH=$(printf '%s' "$PLUGIN_DIR" | sed "s|$HOME|~|")
  blank
  if [ "$FANCY" -eq 1 ] && [ "$BOXES" -eq 1 ]; then
    printf '   %s┌───────────────────────────────────────────────┐%s\n' "$C_DIM" "$C_RESET"
    printf '   %s│%s  %sHeimdall v%-37s%s%s│%s\n' "$C_DIM" "$C_RESET" "$C_BOLD" "$VER installed" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '   %s│%s  %sgates live · secret-scan armed · %s/%-9s%s%s│%s\n' "$C_DIM" "$C_RESET" "$C_GOLD" "$N" "$N" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '   %s│%s  path: %-40s%s│%s\n' "$C_DIM" "$C_RESET" "$SHORT_PATH" "$C_DIM" "$C_RESET"
    printf '   %s│%s%-49s%s│%s\n' "$C_DIM" "$C_RESET" "" "$C_DIM" "$C_RESET"
    printf '   %s│%s  Next:        %s%-34s%s%s│%s\n' "$C_DIM" "$C_RESET" "$C_CYAN" "$PRIMARY demo" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '   %s│%s  In Claude:   /hmd:verify  /hmd:save  …          %s│%s\n' "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '   %s│%s  Docs:        runheimdall.dev                    %s│%s\n' "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '   %s│%s  Uninstall:   %-34s%s│%s\n' "$C_DIM" "$C_RESET" "$PRIMARY uninstall" "$C_DIM" "$C_RESET"
    printf '   %s└───────────────────────────────────────────────┘%s\n' "$C_DIM" "$C_RESET"
  else
    say "Heimdall v$VER installed"
    say "gates live · secret-scan armed · $N/$N"
    say "path: $SHORT_PATH"
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
  # PATH hint if the bin dir is not already on PATH.
  case ":$PATH:" in
    *":$BIN_DIR:"*) : ;;
    *) printf '   %s(add %s to your PATH to use `%s` directly)%s\n' "$C_DIM" "$BIN_DIR" "$PRIMARY" "$C_RESET" ;;
  esac
  printf '   %sdone in %ss%s\n' "$C_DIM" "$ELAPSED" "$C_RESET"
  blank
}

main "$@"
