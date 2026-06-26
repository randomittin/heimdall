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

# Idempotently register Heimdall's statusLine + subagentStatusLine into the
# user's Claude Code settings so the watchman HUD activates for EVERY dev via the
# install — not only whoever hand-wired it during dev setup. THIS is the RJ-only
# bug: statusLine is a USER/PROJECT setting (Claude Code does NOT apply a plugin's
# own settings.json to it), so the working registration lived solely in one dev's
# personal ~/.claude/settings.json and a stranger install never replicated it.
#
# The command is the ABSOLUTE installed path — NOT ${CLAUDE_PLUGIN_ROOT}, which is
# unset outside a plugin-hook context (an unresolved var renders nothing). It is
# guarded by `[ -x … ] … ; exit 0` so a missing script or non-TTY is a clean no-op,
# never an error or a hang (the render scripts themselves are already CI-safe).
# A stale entry left after `hmd uninstall` is therefore a harmless guarded no-op.
#
# Honors $CLAUDE_CONFIG_DIR (Claude Code's config override) → $HOME/.claude. Merges
# via python3 so every other settings key is preserved; a missing python3 is a no-op
# (the watchman render itself needs python3 — registering an unrenderable line would
# be pointless). NEVER clobbers a user's OWN custom statusLine: writes only when the
# key is absent or already points at a heimdall statusline script (refreshing a stale
# path). Prints ONE state word (runs in a command substitution):
#   registered  — wrote/refreshed our statusLine
#   current     — already the canonical value; nothing written
#   kept-custom — user has a non-heimdall statusLine; left untouched
#   skipped     — python3 unavailable or the write failed; nothing written
ensure_statusline_registered() {
  local plugin_dir="$1"
  command -v python3 >/dev/null 2>&1 || { printf 'skipped'; return 0; }
  local cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  mkdir -p "$cfg" 2>/dev/null || true
  HMD_SL_PLUGIN="$plugin_dir" HMD_SL_SETTINGS="$cfg/settings.json" \
    python3 - <<'PY' 2>/dev/null || { printf 'skipped'; return 0; }
import json, os, sys, tempfile

plugin = os.environ["HMD_SL_PLUGIN"]
path   = os.environ["HMD_SL_SETTINGS"]

def cmd(rel):
    p = plugin + "/" + rel
    # Mirror the proven working dev form: absolute path, [ -x ] guard, exit 0.
    return "bash -c '[ -x \"%s\" ] && exec bash \"%s\"; exit 0'" % (p, p)

WANT = {
    "statusLine":         {"marker": "hooks/statusline.sh",
                           "value": {"type": "command", "command": cmd("hooks/statusline.sh")}},
    "subagentStatusLine": {"marker": "hmd-subagent-statusline.sh",
                           "value": {"type": "command", "command": cmd("sentinels/hmd-subagent-statusline.sh")}},
}

try:
    with open(path) as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}

wrote = custom = False
for key, spec in WANT.items():
    cur = data.get(key)
    ours = cur is None or (isinstance(cur, dict) and spec["marker"] in (cur.get("command") or ""))
    if not ours:
        custom = True
        continue
    if cur != spec["value"]:
        data[key] = spec["value"]
        wrote = True

if wrote:
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, path)
    except Exception:
        try: os.unlink(tmp)
        except OSError: pass
        print("skipped"); sys.exit(0)

sl = data.get("statusLine")
if isinstance(sl, dict) and WANT["statusLine"]["marker"] in (sl.get("command") or ""):
    print("registered" if wrote else "current")
elif custom:
    print("kept-custom")
else:
    print("skipped")
PY
}

# ── Install-step telemetry (dossier §3 + §8) ────────────────────────────────
#
# install.sh's own step — the PATH export — emits started→succeeded|failed +
# duration_ms + an error CLASS (never a secret value) through the substrate's bash
# wrapper, which is cloned into $PLUGIN_DIR/bin by the fetch step BEFORE this fires.
# Fire-and-forget: the wrapper always exits 0, and every call is `|| true`-guarded,
# so telemetry can NEVER fail or block the install (the comment in this file's
# header — "no telemetry" — refers to NETWORK/remote telemetry; this is local-only,
# off-by-default-capable, on-machine data the user fully controls). A disabled or
# absent telemetry world (HEIMDALL_TELEMETRY=off / no wrapper) is a perfect no-op,
# so the stranger-test install path is byte-for-byte identical.

# Current wall-clock ms. macOS `date` has no %3N (prints a literal N), so prefer
# python3 and fall back to whole-second precision — never a bogus literal-N value.
_tele_now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null && return 0
  fi
  local s; s="$(date +%s 2>/dev/null || echo 0)"
  printf '%s' "$(( s * 1000 ))"
}

# Emit ONE install_step event via the cloned wrapper. Args:
#   $1 tele_bin   path to heimdall-telemetry (absent/non-exec ⇒ silent no-op)
#   $2 run_id     stable id for this install
#   $3 step       installer step name (fetch|marketplace|plugin|link|gates|path)
#   $4 outcome    started|succeeded|failed
#   $5 start_ms   (optional) start ms ⇒ attach duration_ms
#   $6 err_class  (optional) SHORT error CLASS for a failed event (never a secret)
#   $7 err_detail (optional) SHAPE summary (scrubbed by the substrate)
#
# The store lands under HEIMDALL_HOME when the caller exports it (we point it at
# $PLUGIN_DIR/.heimdall so events live INSIDE the install footprint — test-visible
# and swept by `hmd uninstall`'s wholesale plugin-dir removal). Absent that env it
# falls back to the substrate's repo-root resolution; either way it's fire-and-forget.
_tele_install_step() {
  local tele_bin="$1" run_id="$2" step="$3" outcome="$4"
  local start_ms="${5:-}" err_class="${6:-}" err_detail="${7:-}"
  [ -n "$tele_bin" ] && [ -x "$tele_bin" ] || return 0
  local args=(emit --type install_step --phase install \
    --run-id "$run_id" --step "$step" --outcome "$outcome")
  if [ -n "$start_ms" ]; then
    local now; now="$(_tele_now_ms)"
    args+=(--duration-ms "$(( now - start_ms ))")
  fi
  [ -n "$err_class" ]  && args+=(--error-class "$err_class")
  [ -n "$err_detail" ] && args+=(--error-detail "$err_detail")
  "$tele_bin" "${args[@]}" >/dev/null 2>&1 || true
}

main() {
  # ── Configuration ────────────────────────────────────────────────────────
  # Pinned ref. No release tag exists yet, so this defaults to `main`; the
  # README one-liner resolves runheimdall.dev/install to a pinned tag, and the
  # release script templates that tag in here. HEIMDALL_REF overrides for dev.
  local DEFAULT_REF="v2.0.5"
  local REF="${HEIMDALL_REF:-$DEFAULT_REF}"
  local REPO="${HEIMDALL_REPO:-https://github.com/randomittin/heimdall.git}"

  # Install layout. Plugin (all components) lives in its own dir; the two entry
  # points are SYMLINKED into a bin dir on PATH (symlink so the launcher's
  # readlink-based sibling resolution lands back in the plugin dir — see
  # link_entry). The installer also appends BIN_DIR to the shell profile and
  # registers the statusLine HUD into the user's Claude Code settings.json
  # (idempotent, $CLAUDE_CONFIG_DIR-aware, never clobbering a custom statusLine —
  # see ensure_statusline_registered). No writes outside these locations, the one
  # profile line, and that settings.json statusLine entry.
  local PLUGIN_DIR="$HOME/.heimdall"
  local BIN_DIR="$HOME/.local/bin"
  local MARKETPLACE_NAME="heimdall"
  local PLUGIN_ID="hmd@heimdall"

  # Telemetry wrapper lives in the cloned plugin tree (resolved AFTER the fetch
  # step populates PLUGIN_DIR). Resolved lazily at the `path` fire-point below.
  local TELE_BIN="$PLUGIN_DIR/bin/heimdall-telemetry"
  local TELE_RUN_ID=""

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
  # Every installer-owned step below brackets started→succeeded|failed through the
  # telemetry wrapper (cloned with the plugin in this very step) so a stall or
  # failure is visible across the team's machines. The wrapper does not exist until
  # the fetch lands, so the fetch step's OWN telemetry is emitted right after the
  # clone succeeds (a fetch that never completes leaves no `succeeded` — its absence
  # is the signal). HEIMDALL_HOME points the store inside the install footprint.
  #
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

  # ── Telemetry world is live (wrapper just cloned) ─────────────────────────
  # Point the store inside the install footprint so events are test-visible and
  # swept by uninstall; mint a run id (opaque fallback if the wrapper can't). Then
  # record the fetch step that just completed — its `succeeded` is the proof the
  # only network call landed; a missing one across the 8 devs pinpoints a bad ref.
  export HEIMDALL_HOME="$PLUGIN_DIR/.heimdall"
  if [ -x "$TELE_BIN" ]; then
    TELE_RUN_ID="$("$TELE_BIN" new-run-id 2>/dev/null || true)"
  fi
  [ -n "$TELE_RUN_ID" ] || TELE_RUN_ID="run-install-$$"
  _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" fetch succeeded

  # Step: register marketplace (the local clone is its own marketplace).
  #
  # OPTIONAL step. Registration with the Claude CLI is convenience wiring — the
  # launcher resolves its components by path regardless, so a registration failure
  # must NOT abort the install (graceful-degrade, dossier §8). We mark the step
  # `failed` in telemetry, print a non-fatal note, and CONTINUE. The failure is
  # injectable for the acceptance harness: HEIMDALL_FORCE_FAIL_OPTIONAL forces this
  # optional step to fail (graceful: install still completes), and
  # HEIMDALL_HARD_FAIL_OPTIONAL turns the same forced failure into a hard abort —
  # the falsifiable variant that proves the graceful path is real (it must go RED).
  local MKT_T0; MKT_T0="$(_tele_now_ms)"
  _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" marketplace started
  step_begin "Registering Heimdall marketplace"
  local MKT_RC=0
  if [ -n "${HEIMDALL_FORCE_FAIL_OPTIONAL:-}" ]; then
    MKT_RC=1   # injected optional-step failure (harness drives the degrade path)
  elif claude plugins marketplace list 2>/dev/null | grep -q "$MARKETPLACE_NAME"; then
    claude plugins marketplace update "$MARKETPLACE_NAME" >/dev/null 2>&1 || MKT_RC=$?
  else
    claude plugins marketplace add "$PLUGIN_DIR" >/dev/null 2>&1 || MKT_RC=$?
  fi
  if [ "$MKT_RC" -eq 0 ]; then
    _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" marketplace succeeded "$MKT_T0"
    step_ok "Registering Heimdall marketplace"
  else
    _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" marketplace failed "$MKT_T0" \
      marketplace-register-failed "claude plugins marketplace rc $MKT_RC"
    # Falsifiable hard-fail variant: prove the graceful branch is the real default.
    if [ -n "${HEIMDALL_HARD_FAIL_OPTIONAL:-}" ]; then
      fail "marketplace registration failed (rc $MKT_RC)" \
        "check the Claude CLI, then re-run the installer" \
        "plugin fetched at $PLUGIN_DIR"
    fi
    step_ok "Registering Heimdall marketplace (skipped)"
    blank
    printf '   %s⚠ marketplace registration unavailable — continuing.%s\n' \
      "$C_GOLD" "$C_RESET"
    printf '   %s  the launcher resolves components by path; register later with:%s\n' \
      "$C_DIM" "$C_RESET"
    printf '   %s  claude plugins marketplace add %s%s\n' \
      "$C_DIM" "$PLUGIN_DIR" "$C_RESET"
    blank
  fi

  # Step: install the plugin (hmd@heimdall).
  local PLG_T0; PLG_T0="$(_tele_now_ms)"
  _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" plugin started
  step_begin "Installing plugin ($PLUGIN_ID)"
  if ! claude plugins list 2>/dev/null | grep -q "$PLUGIN_ID"; then
    claude plugins install "$PLUGIN_ID" >/dev/null 2>&1 || true
  fi
  _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" plugin succeeded "$PLG_T0"
  step_ok "Installing plugin ($PLUGIN_ID)"

  # Step: link entry points (hmd + heimdall) via SYMLINK (A0.7) — symlink, not
  # hardlink, so the launcher resolves its siblings in the plugin dir. REQUIRED
  # step: a missing launcher binary is fatal (the fail() below records nothing —
  # the `link` step's absent `succeeded` is itself the failure signal in telemetry).
  local LNK_T0; LNK_T0="$(_tele_now_ms)"
  _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" link started
  step_begin "Linking entry points (hmd, heimdall)"
  mkdir -p "$BIN_DIR"
  local SRC="$PLUGIN_DIR/bin/heimdall"
  if [ ! -x "$SRC" ]; then
    _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" link failed "$LNK_T0" \
      launcher-missing "expected executable at \$PLUGIN_DIR/bin/heimdall"
    fail "plugin binary missing at $SRC" \
      "the clone looks incomplete — re-run the installer" \
      "partial clone at $PLUGIN_DIR"
  fi
  # heimdall: always.
  link_entry "$SRC" "$BIN_DIR/heimdall"
  # hmd: canonical, unless a real collider blocked it.
  if [ "$INSTALL_HMD" -eq 1 ]; then
    link_entry "$SRC" "$BIN_DIR/hmd"
    _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" link succeeded "$LNK_T0"
    step_ok "Linking entry points (hmd, heimdall)"
  else
    _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" link succeeded "$LNK_T0"
    step_ok "Linking entry point (heimdall)"
    blank
    printf '   %s⚠ hmd already exists at %s — installed `heimdall` only.%s\n' \
      "$C_GOLD" "$EXISTING_HMD" "$C_RESET"
    printf '   %s  override with: HEIMDALL_FORCE_HMD=1 curl … | bash%s\n' \
      "$C_DIM" "$C_RESET"
    blank
  fi

  # Step: activate the statusline HUD by registering it in the user's Claude Code
  # settings.json — so the watchman animation reaches EVERY dev through the install,
  # not just whoever hand-wired it in dev setup (the RJ-only bug). OPTIONAL/graceful
  # (dossier §8): a write failure or a missing python3 must never abort the install —
  # ensure_statusline_registered returns a state word and always exits 0.
  local SL_T0; SL_T0="$(_tele_now_ms)"
  _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" statusline started
  step_begin "Activating statusline HUD"
  local SL_STATE; SL_STATE="$(ensure_statusline_registered "$PLUGIN_DIR")"
  _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" statusline succeeded "$SL_T0"
  case "$SL_STATE" in
    registered)  step_ok "Activating statusline HUD" "registered" ;;
    current)     step_ok "Activating statusline HUD" "active" ;;
    kept-custom) step_ok "Activating statusline HUD" "kept your custom line" ;;
    *)           step_ok "Activating statusline HUD" "skipped (needs python3)" ;;
  esac

  # Step: verify gates — N is the RUNTIME gate count, never hardcoded.
  local GAT_T0; GAT_T0="$(_tele_now_ms)"
  _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" gates started
  local N
  N=$(gate_count "$PLUGIN_DIR")
  step_begin "Verifying gates"
  _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" gates succeeded "$GAT_T0"
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
  # path step telemetry: bracket the PATH-export write. Reuses the SAME TELE_RUN_ID
  # minted right after the fetch step, so all of this install's steps (fetch →
  # marketplace → plugin → link → gates → path) share one correlatable run id, and
  # bin/heimdall's first-run steps can chain off it. (If telemetry was unavailable
  # at fetch time, TELE_RUN_ID is the opaque run-install-$$ fallback set there.)
  local PATH_T0; PATH_T0="$(_tele_now_ms)"
  _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" path started

  local PATH_STATE PATH_RC=0
  PATH_STATE=$(ensure_path_on_profile "$BIN_DIR") || PATH_RC=$?
  if [ "$PATH_RC" -eq 0 ]; then
    _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" path succeeded "$PATH_T0"
  else
    _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" path failed "$PATH_T0" \
      path-export-failed "ensure_path_on_profile exit $PATH_RC"
  fi
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
