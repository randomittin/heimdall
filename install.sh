#!/usr/bin/env bash
#
# Heimdall installer — "Nothing ships unproven."
#
#   curl -fsSL https://runheimdall.dev/install | bash
#
# A verification tool whose installer is itself verifiable:
#   - function-wrapped (last line is `main "$@"`) — a dropped curl|bash never
#     executes a half-downloaded script
#   - no stdin reads and no prompts ON THE PIPED PATH (stdin IS the script under a
#     pipe). The one interactive prompt in this script — the optional team
#     control-plane URL — is gated on `[ -t 0 ]`, so it cannot fire under
#     `curl | bash` or in CI. A TTY operator who wants to set it is offered it;
#     nobody is ever blocked on a read that a pipe cannot answer.
#   - no sudo, no eval/base64/obfuscation
#   - pinned to a release ref (HEIMDALL_REF) — what you read is what runs
#   - idempotent: re-run upgrades cleanly, never errors "already exists"
#   - reversible: `hmd uninstall` removes everything, touches nothing else
#   - Gates run 100% locally. Your code never leaves your machine unless you pair a phone with hmd app connect.
#   - the ONLY thing this installer emits is LOCAL, on-machine step telemetry you
#     fully control (never a network phone-home) — every field is in DATA.md, and
#     it is off-by-default-capable (HEIMDALL_TELEMETRY=off / hmd telemetry off)
#
# Env overrides (all HEIMDALL_*, never HMD_*):
#   HEIMDALL_REF        git ref to install (default: the pinned release below)
#   HEIMDALL_REPO       repo URL or local path (default: GitHub clone URL)
#   HEIMDALL_NO_COLOR   set to force plain mode (NO_COLOR also honored)
#   HEIMDALL_NO_INTRO   reserved for first-run demo; ignored here
#   HEIMDALL_FORCE_HMD  install the `hmd` entry point even if a collider exists
#   HEIMDALL_CP_URL     team control-plane URL → cp-endpoint.json (optional; a public
#                       default is baked in, so first-run enrollment is automatic)
#   HEIMDALL_ENROLL_TOKEN  OPERATOR-ONLY bootstrap token for a token-gated (re-gated)
#                          deployment → 0600 cp-endpoint.json; never echoed/tracked.
#                          Unneeded on the open-bounded public CP — see OPERATORS.md.
#   HEIMDALL_FORCE      rewrite cp-endpoint.json even if values are unchanged
#   HEIMDALL_KEEP_CLAUDE_MEM    opt out of retiring the legacy claude-mem plugin on
#                               update (default: retire it — it ships its own
#                               fail-CLOSED UserPromptSubmit hook; see
#                               ensure_claude_mem_plugin_retired below)
#
# Flags:
#   --reset             switch an EXISTING install to the lean profile, in place: route guard, backup
#                       first, lean tree, Headroom off for the NEXT session, and the command that undoes
#                       it printed last (lean_reset below). Never wipes ~/.heimdall: user data lives there.
#                       Without it nothing here changes: a plain run is the upgrade it always was.
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
# Source-checkout guard (populated in main() once $REPO is known). link_entry
# REFUSES to write any link whose destination dir sits inside one of these roots,
# so a checkout-local run — or a curl|bash launched from inside a clone — can
# NEVER mutate a tracked file (e.g. the repo's own bin/hmd, when that bin/ is on
# PATH and gets picked up as the EXISTING_HMD "stale shadow" to overwrite).
# Newline-delimited; EMPTY ⇒ no guard, which is the normal curl|bash stranger
# install (it has no on-disk source tree to protect — zero false positives).
SOURCE_GUARD_ROOTS=""

link_entry() {
  local src="$1" dst="$2"
  # Refuse to write into the installer's OWN source checkout. dst may not exist
  # yet, so resolve its PARENT dir (real path) and refuse if it falls under a
  # guarded root. Returning 1 lets the EXISTING_HMD caller fall through to its
  # "left in place, remove it yourself" warning — never a silent clobber.
  if [ -n "${SOURCE_GUARD_ROOTS:-}" ]; then
    local _dp _root
    _dp="$(cd "$(dirname -- "$dst")" 2>/dev/null && pwd -P || true)"
    if [ -n "$_dp" ]; then
      while IFS= read -r _root; do
        [ -n "$_root" ] || continue
        case "$_dp/" in "$_root/"*) return 1 ;; esac
      done <<EOF
$SOURCE_GUARD_ROOTS
EOF
    fi
  fi
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

# Classify an existing `hmd` found on PATH as OURS (a heimdall/superx-owned binary,
# safe to overwrite — leaving a stale one behind is the very bug that strands
# teammates on an old version) or FOREIGN (a genuinely third-party tool, e.g. the
# PyPI `hmd-cli-app` — NEVER clobber it without an explicit force flag: data loss).
# OURS is signalled by ANY of:
#   - the binary, or its symlink target, lives under a heimdall/superx tree
#     ($HOME/.heimdall or $HOME/.superx — where our own and the legacy superx-era
#     installs put it);
#   - the file body carries a heimdall/superx marker (our launcher mentions
#     "heimdall" hundreds of times; the legacy superx launcher carries "superx").
# Prints exactly one word: "ours" or "foreign".
hmd_ownership() {
  local hmd_path="$1" real
  real="$(readlink -f "$hmd_path" 2>/dev/null || readlink "$hmd_path" 2>/dev/null || printf '%s' "$hmd_path")"
  case "$real" in
    *"/.heimdall/"*|*"/.superx/"*) printf 'ours'; return 0 ;;
  esac
  case "$hmd_path" in
    *"/.heimdall/"*|*"/.superx/"*) printf 'ours'; return 0 ;;
  esac
  # Body marker — only read a regular, readable file (skip dirs/sockets/broken links).
  if [ -f "$real" ] && [ -r "$real" ] \
     && LC_ALL=C grep -qiE 'heimdall|superx' "$real" 2>/dev/null; then
    printf 'ours'; return 0
  fi
  printf 'foreign'
}

# Best-effort version of an existing (stale) `hmd`, for a human-readable
# "(was <ver>)" note when we replace it. NEVER runs the stale binary (a broken
# launcher could hang or drop into an interactive path) — resolves the plugin tree
# behind the symlink and reads its version the same way resolved_version() does.
# Prints a bare X.Y.Z, or "unknown" when the tree can't be resolved.
hmd_probe_version() {
  local hmd_path="$1" real dir v=""
  real="$(readlink -f "$hmd_path" 2>/dev/null || readlink "$hmd_path" 2>/dev/null || printf '%s' "$hmd_path")"
  # The launcher lives at <tree>/bin/heimdall → the tree root is two levels up.
  dir="$(cd "$(dirname "$real")/.." 2>/dev/null && pwd || true)"
  if [ -n "$dir" ]; then
    v="$(resolved_version "$dir" 2>/dev/null || true)"
  fi
  if [ -n "$v" ] && [ "$v" != "?" ]; then
    printf '%s' "$v"
  else
    printf 'unknown'
  fi
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
                           "value": {"type": "command", "command": cmd("hooks/statusline.sh"),
                                     "refreshInterval": 2}},
    "subagentStatusLine": {"marker": "subagent-statusline.sh",
                           "value": {"type": "command", "command": cmd("hooks/subagent-statusline.sh")}},
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

# Cursor CLI sibling of ensure_statusline_registered() above — same install-time hook
# point, mirrored for the same reason: pattern-consistency with the one existing
# statusline registration this installer already does. Gated on Cursor CLI actually
# being present (bin/heimdall-ai-select detect's cursor-cli.available) so a machine
# that has never touched Cursor never gets a ~/.cursor/ dir created by this installer.
# Delegates ALL of idempotency/no-clobber/atomic-write to
# bin/heimdall-statusline-register-cursor — this wrapper only decides WHETHER to call
# it. Prints ONE state word (registered|not-applicable|skipped), always returns 0.
ensure_cursor_statusline_registered() {
  local plugin_dir="$1"
  local aisel="$plugin_dir/bin/heimdall-ai-select"
  local reg="$plugin_dir/bin/heimdall-statusline-register-cursor"
  [ -x "$aisel" ] && [ -x "$reg" ] || { printf 'skipped'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'skipped'; return 0; }
  local avail
  avail="$("$aisel" detect 2>/dev/null | jq -r '[.[] | select(.id=="cursor-cli")] | .[0].available // false' 2>/dev/null || echo false)"
  [ "$avail" = "true" ] || { printf 'not-applicable'; return 0; }
  "$reg" register 2>/dev/null || printf 'skipped'
}

# Drop the per-dev control-plane endpoint config so SERVER-SYNCED TEAM PRESENCE
# auto-resolves with ZERO manual exports. bin/heimdall-presence reads the CP url +
# enroll token from $HOME/.heimdall/cp-endpoint.json and persists per-dev Ed25519
# signing seeds under $HOME/.heimdall/pki/<haid>.seed (0600, client-generated +
# enrolled on first session). This installs ONLY the url+token config + the seed dir.
#
# SECRET HANDLING. The url is team-specific but NOT secret; the enroll token IS a
# secret — it is written mode 0600 into the $HOME store (OUT of any repo), NEVER a
# tracked file (gitignored both at the install-clone root and the in-repo .heimdall/
# case — see .gitignore). The caller resolves url/token from the env (preferred) or a
# TTY-gated prompt and passes them in; this function never prompts (it runs in a
# command substitution) and never echoes the token.
#
# IDEMPOTENT + MERGE. Provided non-empty values win; an empty value preserves whatever
# is already configured (a url-only or token-only install merges into the existing
# file). An unchanged config rewrites nothing unless $4=force. Prints ONE state word:
#   configured  — wrote/updated cp-endpoint.json (enrollment is automatic next session)
#   current     — already configured with these values; nothing written
#   absent      — no url/token given and no existing config; nothing touched (caller
#                 prints how to set it later — install never hangs or fails for this)
#   skipped     — python3 unavailable for a merge and not a fresh both-provided write
ensure_cp_endpoint() {
  local plugin_dir="$1" url="$2" tok="$3" force="${4:-}"
  local cfg="$plugin_dir/cp-endpoint.json"
  local pki="$plugin_dir/pki"
  # Nothing provided and nothing already there → clean skip, touch NOTHING.
  if [ -z "$url" ] && [ -z "$tok" ] && [ ! -f "$cfg" ]; then
    printf 'absent'; return 0
  fi
  # Per-dev secret stores live under the plugin home: dir 0700, seeds 0600 (the seeds
  # themselves are written by the client). mkdir/chmod are idempotent.
  mkdir -p "$plugin_dir" 2>/dev/null || true
  chmod 0700 "$plugin_dir" 2>/dev/null || true
  mkdir -p "$pki" 2>/dev/null || true
  chmod 0700 "$pki" 2>/dev/null || true
  if command -v python3 >/dev/null 2>&1; then
    HMD_CP_CFG="$cfg" HMD_CP_URL="$url" HMD_CP_TOK="$tok" HMD_CP_FORCE="$force" \
      python3 - <<'PY' 2>/dev/null || { printf 'skipped'; return 0; }
import json, os, sys, tempfile
cfg   = os.environ["HMD_CP_CFG"]
url   = os.environ.get("HMD_CP_URL", "").strip()
tok   = os.environ.get("HMD_CP_TOK", "").strip()
force = os.environ.get("HMD_CP_FORCE", "")
try:
    with open(cfg) as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
old = dict(data)
# Provided non-empty value wins; empty preserves the existing one (partial merge).
eff_url = url or data.get("url", "")
eff_tok = tok or data.get("enroll_token", "")
data["url"] = eff_url
data["enroll_token"] = eff_tok
changed = (old.get("url", "") != eff_url) or (old.get("enroll_token", "") != eff_tok)
if not os.path.exists(cfg):
    changed = True
if not changed and not force:
    print("current"); sys.exit(0)
d = os.path.dirname(cfg) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".cp-endpoint.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.chmod(tmp, 0o600)            # secret token → owner-only before it lands
    os.replace(tmp, cfg)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    print("skipped"); sys.exit(0)
print("configured")
PY
    return 0
  fi
  # python3 absent (rare — telemetry+statusline both need it): write only a FRESH
  # both-provided config (no merge possible without a JSON parser), else skip. The
  # temp-name X-run is assembled at runtime (never a source literal).
  if [ -n "$url" ] && [ -n "$tok" ] && [ ! -f "$cfg" ]; then
    local xs tmp
    xs="$(printf 'X%.0s' 1 2 3 4 5 6)"
    tmp="$(mktemp "$plugin_dir/.cp-endpoint.$xs" 2>/dev/null)" || { printf 'skipped'; return 0; }
    if printf '{\n  "url": "%s",\n  "enroll_token": "%s"\n}\n' "$url" "$tok" > "$tmp" 2>/dev/null \
       && chmod 0600 "$tmp" 2>/dev/null && mv "$tmp" "$cfg" 2>/dev/null; then
      printf 'configured'; return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
  fi
  printf 'skipped'
}

# ── Per-repo TEAM secret (the multi-tenant team-invite path) ─────────────────
#
# A team = a high-entropy SECRET scoped to a repo; presence is visible ONLY to
# holders of that secret (docs/specs/2026-06-27-multi-tenant-teams.md §6). The
# team-invite one-liner is
#     curl -fsSL <install.sh> | HEIMDALL_TEAM_SECRET='<secret>' bash
# so a teammate who pastes it lands in the INVITER's team instead of falling
# through to client auto-solo (their OWN team). This consumes HEIMDALL_TEAM_SECRET
# from the install env and writes it to the JOINING dev's PER-REPO store
#     <repo>/.heimdall/team.json   { "team_secret": <s>, "created": <epoch> }   0600
# NOT the global ~/.heimdall/cp-endpoint.json — the CP URL is global, the team
# secret is per-repo (a dev may be on different teams in different repos), so it
# sits next to the per-repo identity.json. Mirrors bin/heimdall-team's writer
# byte-for-byte (0600 file, {team_secret,created} shape, secret crosses to python
# via the ENV, never argv).
#
# SECRET HYGIENE: the secret is written ONLY to team.json (0600); it crosses to
# python via the ENVIRONMENT, never argv (argv shows in `ps`); it is NEVER echoed,
# logged, or committed (.gitignore). The store is the git toplevel of the
# invocation CWD (install.sh never cd's), else the CWD; HEIMDALL_TEAM_DIR overrides
# the dir wholesale (tests + non-git trees) — same convention as bin/heimdall-team.
#
# IDEMPOTENT. No secret supplied → clean skip (the dev gets client auto-solo),
# touch NOTHING. A secret < 32 chars → reject (a weak hand-typed secret could
# collide into another team). An already-configured team.json with the SAME secret
# → nothing written; a DIFFERENT secret → the install-supplied secret WINS (so the
# invite takes precedence over an auto-solo team a prior presence beat minted).
# Prints ONE state word:
#   configured  — wrote/updated team.json (presence is scoped to this team)
#   current     — already configured with this exact secret; nothing written
#   absent      — no secret supplied; nothing touched (auto-solo handles presence)
#   weak        — secret shorter than the 32-char minimum; nothing written
#   skipped     — python3 unavailable for a merge and not a fresh write, or IO error
ensure_team_secret() {
  local secret="$1" force="${2:-}"
  # Nothing provided → clean skip (auto-solo handles presence). Touch NOTHING.
  [ -n "$secret" ] || { printf 'absent'; return 0; }
  # A weak/hand-typed secret could collide into another team — reject below MIN.
  if [ "${#secret}" -lt 32 ]; then printf 'weak'; return 0; fi
  # Per-repo store (mirrors bin/heimdall-team): git toplevel of the invocation
  # CWD, else the CWD; HEIMDALL_TEAM_DIR overrides wholesale (tests/non-git trees).
  local team_dir team_file
  if [ -n "${HEIMDALL_TEAM_DIR:-}" ]; then
    team_dir="$HEIMDALL_TEAM_DIR"
  else
    team_dir="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.heimdall"
  fi
  team_file="$team_dir/team.json"
  mkdir -p "$team_dir" 2>/dev/null || { printf 'skipped'; return 0; }
  chmod 0700 "$team_dir" 2>/dev/null || true
  if command -v python3 >/dev/null 2>&1; then
    HMD_TEAM_FILE="$team_file" HMD_TEAM_SEC="$secret" HMD_TEAM_FORCE="$force" \
      python3 - <<'PY' 2>/dev/null || { printf 'skipped'; return 0; }
import json, os, sys, time, tempfile
path  = os.environ["HMD_TEAM_FILE"]
sec   = os.environ["HMD_TEAM_SEC"]
force = os.environ.get("HMD_TEAM_FORCE", "")
try:
    with open(path) as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
old = data.get("team_secret", "")
# Same secret already configured → nothing to do (unless forced).
if old == sec and not force:
    print("current"); sys.exit(0)
# A new/different secret stamps a fresh 'created'; a forced same-secret rewrite
# preserves the existing epoch.
created = data.get("created")
if old != sec or not isinstance(created, (int, float)):
    created = int(time.time())
out = json.dumps({"team_secret": sec, "created": int(created)}) + "\n"
d = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".team.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as fh:
        fh.write(out)
    os.chmod(tmp, 0o600)            # secret -> owner-only BEFORE it lands
    os.replace(tmp, path)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    print("skipped"); sys.exit(0)
print("configured")
PY
    return 0
  fi
  # python3 absent (rare — telemetry+statusline both need it): write a FRESH 0600
  # file only when none exists (an idempotency/merge check needs the JSON parser);
  # else skip rather than risk clobbering. The secret reaches the file via a printf
  # BUILTIN (no child process), so it never crosses any argv.
  if [ ! -f "$team_file" ]; then
    local xs tmp now
    xs="$(printf 'X%.0s' 1 2 3 4 5 6)"
    tmp="$(mktemp "$team_dir/.team.$xs" 2>/dev/null)" || { printf 'skipped'; return 0; }
    now="$(date +%s 2>/dev/null || echo 0)"
    if printf '{"team_secret": "%s", "created": %s}\n' "$secret" "$now" > "$tmp" 2>/dev/null \
       && chmod 0600 "$tmp" 2>/dev/null && mv "$tmp" "$team_file" 2>/dev/null; then
      printf 'configured'; return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
  fi
  printf 'skipped'
}

# ── Ed25519 PKI crypto backend (the fix for the invisible-teammate outage) ────
#
# THE BUG (root cause of a multi-hour teammate-presence outage): a fresh curl|bash
# install had NO working presence because the python interpreter hmd invokes for
# heimdall-presence carried NEITHER `cryptography` NOR `pynacl`. The chain:
#   heimdall-presence beat → cp_auth.generate_keypair() raises
#   AuthError('crypto_unavailable') (cp_auth.py:143 — backend None when neither lib
#   imports) → the beat swallows it → no enroll → no signing seed → unsigned beats
#   dropped → the teammate is INVISIBLE on the wall, SILENTLY.
# Two real teammates (akshat, madhavan) lost hours to this.
#
# _crypto_importable — true iff the given interpreter can load an Ed25519 backend.
# Mirrors cp_auth.py's backend order EXACTLY (cryptography.hazmat…ed25519 first, then
# nacl.signing) so this check agrees byte-for-byte with what crypto_available() will
# decide at beat time. Quiet: all output discarded — only the exit code matters.
_crypto_importable() {
  local py="$1"
  "$py" - <<'PY' >/dev/null 2>&1
import sys
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: F401
except Exception:
    try:
        import nacl.signing  # noqa: F401
    except Exception:
        sys.exit(1)
sys.exit(0)
PY
}

# ensure_crypto_backend — GUARANTEE the presence interpreter can do Ed25519, or shout.
# Targets the EXACT interpreter heimdall-presence runs (bin/heimdall-presence:74,
# PY="$(command -v python3 || command -v python)") — NOT pipx (an isolated venv hmd
# can't import from), NOT a different python. Behaviour:
#   - IDEMPOTENT  — if a backend already imports, it's a silent no-op (nothing runs);
#   - PEP-668-AWARE — installs `cryptography` with `pip install --user`, falling back
#     to `--user --break-system-packages` for an externally-managed interpreter
#     (Homebrew / Debian / macOS system python) that refuses the plain --user write;
#   - NON-FATAL  — a failure NEVER aborts the install (the caller prints a loud
#     warning and continues);
#   - VERIFYING  — after any install attempt it RE-CHECKS the import, so the state it
#     returns reflects what the beat will actually see, not what pip claimed.
# Prints ONE state word (the caller renders the ✓/⚠ line + the manual-fix guidance):
#   present    — a backend already imported; nothing installed (idempotent no-op)
#   installed  — cryptography was installed and the backend now imports
#   failed     — a backend is still not importable after the install attempt (LOUD)
#   nopy       — no python interpreter on PATH at all (presence needs one — LOUD)
ensure_crypto_backend() {
  local py; py="$(command -v python3 || command -v python || true)"
  if [ -z "$py" ]; then printf 'nopy'; return 0; fi
  # Already importable → silent idempotent no-op (do NOT touch pip).
  if _crypto_importable "$py"; then printf 'present'; return 0; fi
  # Not importable → install `cryptography` into THAT interpreter's user site.
  # First a plain --user install; PEP-668 externally-managed interpreters refuse it,
  # so retry with --break-system-packages. Both are quiet + best-effort — pip's exit
  # is NOT trusted; the re-check below is the sole arbiter of success.
  "$py" -m pip install --user --quiet cryptography >/dev/null 2>&1 \
    || "$py" -m pip install --user --break-system-packages --quiet cryptography >/dev/null 2>&1 \
    || true
  if _crypto_importable "$py"; then printf 'installed'; return 0; fi
  printf 'failed'
}

# ── Retire the legacy external caveman plugin ──────────────────────────────────
# hmd USED to install this as a companion:
#     claude plugins marketplace add JuliusBrussee/caveman
#     claude plugins install caveman@caveman
# Compression has since moved IN-HOUSE (bin/heimdall-caveman, wired via
# hooks.json SessionStart + UserPromptSubmit). Every user who installed hmd
# before that move still has the plugin, and leaving it is actively harmful
# rather than merely redundant: BOTH now inject a compression instruction, at
# levels that disagree. The plugin resets ITSELF to "full" on restart -- the
# documented defect that caused the move -- while hmd holds "ultra". Two
# conflicting instructions are worse than either alone, and they silently
# invalidate any compression measurement taken afterwards.
#
# So an update RETIRES it. Scoped tightly and reversibly:
#   * touches ONLY caveman@caveman and the JuliusBrussee marketplace, never
#     any other plugin or marketplace;
#   * fast no-op when already absent (the steady state after one update);
#   * opt out with HEIMDALL_KEEP_CAVEMAN_PLUGIN=1 for anyone who genuinely
#     prefers the upstream plugin to hmd own in-house level;
#   * NON-FATAL, fail-open -- a failed uninstall must never break an update.
# Reinstalling by hand is one documented command, so this stays recoverable.
#
# Prints ONE state word: absent | kept | retired | failed | skipped
ensure_caveman_plugin_retired() {
  command -v claude >/dev/null 2>&1 || { printf 'skipped'; return 0; }
  if ! claude plugins list 2>/dev/null | grep -qi 'caveman'; then
    printf 'absent'; return 0
  fi
  if [ "${HEIMDALL_KEEP_CAVEMAN_PLUGIN:-0}" = "1" ]; then
    printf 'kept'; return 0
  fi
  claude plugins uninstall caveman@caveman >/dev/null 2>&1 || true
  # Drop the marketplace too, but ONLY once nothing from it remains installed:
  # removing a marketplace another plugin still needs would break its updates.
  if ! claude plugins list 2>/dev/null | grep -qi 'caveman'; then
    claude plugins marketplace remove JuliusBrussee >/dev/null 2>&1 || true
    printf 'retired'; return 0
  fi
  printf 'failed'
}

# ── Retire the legacy claude-mem memory plugin ─────────────────────────────
# hmd used to set up claude-mem (the Claude Code PLUGIN claude-mem@thedotmack, opt-in
# via HEIMDALL_INSTALL_CLAUDE_MEM=1 — never on by default since 2026-08-22, after zero
# measured invocations across ~40 spawns and a 30GB Chroma index that blocked a build).
#
# It is now retired outright, not merely left opt-in: claude-mem ships its own
# UserPromptSubmit hook that can fail CLOSED (observed: "claude-mem worker unreachable
# for 5 consecutive hooks" blocked a real prompt) — the exact inverse of hmd's own
# fail-open hook policy. An optional companion that can block a session on its own
# outage is worse than one that simply does nothing, so hmd stops installing AND
# advertising it, and an update actively retires an existing install.
#
# Scoped tightly and reversibly, same shape as ensure_caveman_plugin_retired above:
#   * touches ONLY claude-mem@thedotmack and the thedotmack marketplace, never any
#     other plugin or marketplace;
#   * fast no-op when already absent (the steady state after one update);
#   * opt out with HEIMDALL_KEEP_CLAUDE_MEM=1 for anyone who wants to keep it anyway;
#   * NON-FATAL, fail-open — a failed uninstall must never break an update.
# Reinstalling by hand (claude plugins marketplace add thedotmack/claude-mem && claude
# plugins install claude-mem@thedotmack) stays possible, so this is recoverable.
#
# Prints ONE state word: absent | kept | retired | failed | skipped
ensure_claude_mem_plugin_retired() {
  command -v claude >/dev/null 2>&1 || { printf 'skipped'; return 0; }
  if ! claude plugins list 2>/dev/null | grep -qi 'claude-mem'; then
    printf 'absent'; return 0
  fi
  if [ "${HEIMDALL_KEEP_CLAUDE_MEM:-0}" = "1" ]; then
    printf 'kept'; return 0
  fi
  claude plugins uninstall claude-mem@thedotmack >/dev/null 2>&1 || true
  # Drop the marketplace too, but ONLY once nothing from it remains installed:
  # removing a marketplace another plugin still needs would break its updates.
  if ! claude plugins list 2>/dev/null | grep -qi 'claude-mem'; then
    claude plugins marketplace remove thedotmack >/dev/null 2>&1 || true
    printf 'retired'; return 0
  fi
  printf 'failed'
}

# ── Nightly /dream auto-schedule (the overnight maintainer sweep, hands-free) ──
#
# `/dream` (bin/heimdall-dream) is the overnight autoresearch + maintainer sweep that
# leaves a morning report. On-demand it is a manual `/dream`; this wires the installer
# to register it as a launchd LaunchAgent (com.heimdall.dream) so it fires nightly at
# 03:00 WITHOUT a live session and survives logout/reboot — zero user action.
#
# The schedule helper (bin/heimdall-dream-schedule) is already idempotent (fixed plist
# path, unload-before-load) and carries the OFF switch (`heimdall-dream-schedule
# uninstall`), so we just CALL it. We point --repo at the INSTALLED checkout ($PLUGIN_DIR)
# so the plist's dream bin ($PLUGIN_DIR/bin/heimdall-dream) is the STABLE installed path:
# when hmd auto-updates that tree in place, the nightly job automatically runs the NEW
# code — the schedule is never pinned to a version-frozen copy. heimdall-autoupdate
# additionally re-asserts this schedule post-update (idempotent) to heal a plist-format/
# path change.
#
# GATING (matches the crypto/statusline optional steps — graceful, never aborts install):
#   - OPT-OUT: HEIMDALL_NO_DREAM_SCHEDULE=1 → skip by request (a CI/headless dev declines).
#   - macOS-ONLY: launchd is the platform scheduler; a non-Darwin box or a missing
#     launchctl → skip cleanly (the cron/cloud routine in commands/dream.md covers those).
#   - NON-FATAL: a missing helper/dream bin or a launchctl load failure → skip, never fail.
#   - SANDBOX FLOOR: the helper REFUSES (exit 4) when $HOME is not this user's passwd
#     home. `launchctl` targets the logged-in user's GUI session domain (gui/<uid>) and
#     does NOT resolve through $HOME, so a harness running a real install under a
#     throwaway HOME would otherwise repoint the DEVELOPER'S live nightly job at its own
#     temp checkout — a tree that is then deleted. That happened; this is the floor that
#     stops it. It is SELF-DETECTING (passwd database, which $HOME cannot influence), so
#     unlike HEIMDALL_NO_DREAM_SCHEDULE it does not depend on the caller remembering
#     anything. The opt-out still works and still wins; this sits underneath it.
#   - EPHEMERAL FLOOR: the helper also REFUSES (exit 5) when the paths it would pin live
#     inside a LINKED git worktree. The same incident had a SECOND cause the passwd check
#     cannot see: that run had a genuine $HOME and still registered a job pointing at
#     .claude/worktrees/agent-<id>, a checkout built to be reaped. A nightly job pinned to
#     a reaped path does not fail loudly — it silently never runs again.
# Prints ONE state word (the caller renders the ✓ line + the disable hint). They are
# distinct because they are DIFFERENT operator actions, and a state word that collapses
# two causes into one is how a silent outage survives the next person who looks:
#   scheduled    — the nightly LaunchAgent was (re)installed + loaded (idempotent)
#   optout       — HEIMDALL_NO_DREAM_SCHEDULE=1 → skipped by request
#   unsupported  — not macOS, or launchctl absent → skipped (use the cron/cloud routine)
#   sandboxed    — synthetic $HOME → the helper refused to touch the real launchd domain
#   ephemeral    — worktree checkout → the helper refused to pin a job to a disposable tree
#   skipped      — schedule helper / dream bin missing, or launchctl load failed (non-fatal)
ensure_dream_schedule() {
  local plugin_dir="$1"
  # Opt-out FIRST — a declining dev/CI never touches launchd at all.
  [ "${HEIMDALL_NO_DREAM_SCHEDULE:-0}" = "1" ] && { printf 'optout'; return 0; }
  # macOS + launchctl only (the schedule helper targets launchd; anything else is a
  # clean skip, exactly as the helper's own is_macos guard would report).
  [ "$(uname -s 2>/dev/null)" = "Darwin" ] || { printf 'unsupported'; return 0; }
  command -v launchctl >/dev/null 2>&1 || { printf 'unsupported'; return 0; }
  local sched="$plugin_dir/bin/heimdall-dream-schedule"
  [ -x "$sched" ] || { printf 'skipped'; return 0; }
  # Idempotent register + load, pointed at the installed checkout. Quiet + best-effort:
  # a load failure (rc from the helper) degrades to 'skipped', never aborts the install.
  # The helper owns the sandbox refusal (it is the ONE place that calls launchctl, so
  # gating it there covers this caller and heimdall-autoupdate's re-assert alike); we
  # only have to render its distinct exit 4 honestly instead of as a scary "failed".
  local rc=0
  "$sched" install --repo "$plugin_dir" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) printf 'scheduled' ;;
    4) printf 'sandboxed' ;;
    5) printf 'ephemeral' ;;
    *) printf 'skipped' ;;
  esac
}

# ── The ONE permission the nightly /dream may need, asked at setup ────────────
#
# WHAT THE SCHEDULE STEP ABOVE LEAVES OPEN. It registers a LaunchAgent that will read
# $PLUGIN_DIR at 03:00. A LaunchAgent carries NO TCC grant, so if that directory sits
# inside ~/Downloads, ~/Documents or ~/Desktop, macOS refuses every read and the job is
# dead the moment it is created. The remedy needs a human — macOS exposes no API to
# request or set Full Disk Access — and until now nothing ever ASKED for it. The machine
# simply reported "blocked: tcc-denied" every night. This is the ask, placed at the one
# moment during setup when a person may actually be there.
#
# AND WHY IT DEFERS RATHER THAN PRINTS. The published install is `curl … | bash`. There
# is no terminal on that path, and this file's own header promises no stdin reads under a
# pipe. A prompt would wedge it. But the printed fallback is not harmless either: it
# scrolls past unread AND the helper records that the operator was asked, spending the
# one-shot on nobody — after which the first person to open a terminal gets silence.
# Not asking is recoverable; asking nobody is not.
#
# So we pass --interactive-only, which is the helper's own `[ -t 0 ] && [ -t 1 ]` gate
# used to choose between asking and DEFERRING: with a human it prints the block and puts
# the choice to him in this same flow; with a pipe it does nothing at all — no output, no
# stdin read, no marker — and the ask stays armed for the first interactive surface
# (`hmd --update`, or the SessionStart notice that already points at it). We deliberately
# do NOT re-test `[ -t 0 ]` here: two copies of that gate drift, and a drifted gate is the
# one that hangs the installer.
#
# THIS FUNCTION IS SILENT BY CONSTRUCTION. Every word the operator sees comes from the
# helper, so nothing here can leak a question into the pipe. It ALWAYS returns 0 — a
# permission ask must never be able to fail an install that otherwise succeeded — and it
# is macOS-gated exactly like the schedule it serves, because a grant with no LaunchAgent
# to grant it for is noise.
ensure_dream_permission() {
  local plugin_dir="$1"
  # The nightly job's OFF SWITCH is this ask's off switch too: no schedule, nothing to grant.
  [ "${HEIMDALL_NO_DREAM_SCHEDULE:-0}" = "1" ] && return 0
  [ "$(uname -s 2>/dev/null)" = "Darwin" ] || return 0
  local perm="$plugin_dir/bin/heimdall-dream-permission"
  [ -x "$perm" ] || return 0
  # `ask` already exits 0 on every path and stays silent unless a grant is genuinely
  # needed; the guard is belt-and-braces against a partial clone.
  "$perm" ask --repo "$plugin_dir" --interactive-only || true
  return 0
}

# ── The one token-saver question, asked at setup: `hmd compact-window` ───────────────────────────────────
#
# It sets the agent's native auto-compact window (one key in the user-level settings.json) to 300,000 tokens, the biggest measured lever on a long
# session's spend (about 40% of main-thread spend in the one session replayed). That file is the person's, so this step only ever ASKS: the helper
# (bin/heimdall-compact-window offer) draws the question when stdin AND stdout are a terminal, writes nothing without a yes, asks once and keeps the
# answer. Under `curl | bash`, in CI or in any pipe it prints nothing, reads nothing and writes nothing, so the install never blocks and a
# non-interactive install leaves ~/.claude/settings.json exactly as it was; the question waits for the next `hmd --update` at a terminal. We do not
# re-test the terminal here (two copies of that gate drift). Every word the person sees comes from the helper, and this ALWAYS returns 0: an offer
# must never fail an install that otherwise succeeded.
ensure_compact_window_offer() {
  local plugin_dir="$1"
  local cw="$plugin_dir/bin/heimdall-compact-window"
  [ -x "$cw" ] || return 0
  "$cw" offer || true
  return 0
}

# ── Install-step telemetry (dossier §3 + §8) ────────────────────────────────
#
# install.sh's own step — the PATH export — emits started→succeeded|failed +
# duration_ms + an error CLASS (never a secret value) through the substrate's bash
# wrapper, which is cloned into $PLUGIN_DIR/bin by the fetch step BEFORE this fires.
# Fire-and-forget: the wrapper always exits 0, and every call is `|| true`-guarded,
# so telemetry can NEVER fail or block the install (this install-step telemetry is
# LOCAL-only, off-by-default-capable, on-machine data the user fully controls — see
# DATA.md; it is never a network phone-home). A disabled or
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

# Render the dev's watchman sigil for the success card — the "claim your
# watchman" moment. Truecolor ANSI half-blocks, so it is ONLY meaningful on a
# real terminal: callers MUST gate on FANCY (TTY + color) or it is garbage in a
# pipe/CI. Resolves the sigil SEED from the installed identity bin ($USER
# fallback — heimdall-identity never errors) and renders the compact face via
# the SINGLE sigil renderer (sentinels/hmd_sigil.py). Missing python3 / sigil
# script is a clean no-op (prints nothing) — never an error. No secret is read
# or printed: the seed is a public handle/username, never the enroll token.
render_sigil() {
  local plugin_dir="$1"
  local sigil="$plugin_dir/sentinels/hmd_sigil.py"
  local idbin="$plugin_dir/bin/heimdall-identity"
  command -v python3 >/dev/null 2>&1 || return 0
  [ -f "$sigil" ] || return 0
  local seed=""
  [ -x "$idbin" ] && seed="$("$idbin" 2>/dev/null || true)"
  [ -n "$seed" ] || seed="${USER:-you}"
  HMD_SIGIL="$sigil" python3 - "$seed" <<'PY' 2>/dev/null || true
import sys, os, importlib.util
spec = importlib.util.spec_from_file_location("s", os.environ["HMD_SIGIL"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for line in m.render(sys.argv[1], pad="   "):
    print(line)
PY
}

# The display HANDLE for the success card's watchman label. Resolves via the
# installed identity bin ($USER fallback); never errors. Prints the bare handle.
sigil_handle() {
  local idbin="$1/bin/heimdall-identity" h=""
  [ -x "$idbin" ] && h="$("$idbin" --handle 2>/dev/null || true)"
  [ -n "$h" ] || h="${USER:-you}"
  printf '%s' "$h"
}

# install_hmd_plugin PLUGIN_DIR PLUGIN_ID REF — install the Heimdall plugin from the marketplace its own
# clone provides (the clone IS the pin: it sits at the ref this installer fetched). A no-op when already
# installed. The attempt is receipted and a failure is reported on stderr as `install failed, continuing
# without <id>` (bin/lib/install-receipt.sh). The status is the CLI's; the caller carries on without the
# plugin — the launcher resolves its components by path regardless — but never silently.
install_hmd_plugin() {
  local dir="$1" id="$2" ref="$3" rc=0
  if claude plugins list 2>/dev/null | grep -q "$id"; then
    return 0
  fi
  if declare -F hmd_plugin_install >/dev/null 2>&1; then
    hmd_plugin_install "$id" "$dir" "$ref" install.sh "$(resolved_version "$dir")" || rc=$?
  else
    # A clone fetched at a ref older than the receipt lib: install as before, but still say so on failure.
    claude plugins install "$id" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '  ⚠ hmd: install failed, continuing without %s (no install receipt: this ref predates it)\n' "$id" >&2
    fi
  fi
  return "$rc"
}

# ── Lean reset: `install.sh --reset` (3.x lean-core plan, T4.4: docs/superpowers/plans/2026-11-12-3x-lean-core.md) ───────────────────
# An EXISTING install becomes lean, in place, on request. It runs only for --reset and only after the fetch, so a plain run is untouched (INV-L8).
# It never removes a file: ~/.heimdall is both the plugin clone and the home of the user's ledger, receipts, memory, team, pairing and data/, which
# sparse-checkout and the one-key `set` helpers leave alone (INV-L10); `hmd --reinstall`, which wipes that directory, is not how this works.
# lean_reset only SEQUENCES helpers that carry their own proofs:
#   1 route guard   2 backup   3 consent ask + not grandfathered   4 profile lean   5 lean tree   6 lean prompt   7 Headroom off   8 the undo command
# Steps 5 and 7 are the two a live session can feel, and step 4 travels with step 5: a plain `install.sh` run applies the RECORDED profile (T3.4,
# INV-L7), so a `lean` recorded beside a full tree would narrow that tree under the live session on the next plain run, earlier than "next session".
# When THIS session is routed through Headroom (the guard says defer, INV-L11) steps 4, 5 and 7 are left for the next run: named on stdout, recorded
# in <runtime home>/backups/lean-reset-pending, never skipped silently, and no profile is recorded until the tree step runs (the install reads `full`,
# which a plain run leaves alone: INV-L8). The next `--reset` records the profile and applies the tree together and keeps that FIRST backup, so the
# printed undo still returns the install to what it was before the reset began. A guard that cannot tell (refuse), a library this release lacks, or a
# backup that fails stops before anything changes. A failed 3 or 4 stops the reset (the install would be half converted) and prints the undo. A failed
# 5, 6 or 7 warns and the install carries on: lean never costs an install. The `claude` wrapper (the hmd launcher) is kept and no proxy is installed
# or routed (INV-L12); Headroom is only ever switched OFF, by its own CLI, and never for the live session.

# lean_reset_record RECORD BACKUP [STEP...] -- the unfinished-reset record: the backup to keep and the steps still pending, one key=value per line
lean_reset_record() {
  local record="$1" bdir="$2" step
  shift 2
  { printf 'backup=%s\n' "$bdir"; for step in "$@"; do printf 'pending=%s\n' "$step"; done; } > "$record.tmp" && mv "$record.tmp" "$record"
}

# lean_reset_prompt PLUGIN_DIR -- step 6: select the lean main prompt (`agent: hmd:heimdall-lean` in the USER-level Claude settings, which outranks the
# plugin's own settings.json agent: docs/analysis/2026-11-12-lean-agent-override.md, the namespaced form is the one that memo verified) ONLY when this
# release ships agents/heimdall-lean.md AND its prompt-parity receipt (evals/lean/prompt-parity.receipt.json: "verdict": "green" and "lean_prompt_sha256",
# the sha256 of that very prompt, so a green receipt cannot vouch for an edited one) is green. Both are read at HEAD of the clone, not from the work
# tree: the lean tree itself drops evals/. Prints ONE state word, the pattern of ensure_statusline_registered:
#   no-prompt | not-green | selected | current | kept-custom (the user's own agent) | skipped (settings.json unreadable or unwritable)
# settings.json is only ever merged into: every other key, its indent and its mode stay.
lean_reset_prompt() {
  HMD_LR_PLUGIN="$1" HMD_LR_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" \
    python3 -I - <<'PY' || printf 'skipped'
import hashlib, json, os, stat, subprocess, sys, tempfile

PROMPT = "agents/heimdall-lean.md"
RECEIPT = "evals/lean/prompt-parity.receipt.json"
AGENT = "hmd:heimdall-lean"
OURS = (AGENT, "heimdall-lean", "hmd:heimdall", "heimdall")
plugin = os.environ["HMD_LR_PLUGIN"]
path = os.path.realpath(os.environ["HMD_LR_SETTINGS"])
git_env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def at_head(rel):
    done = subprocess.run(["git", "-C", plugin, "cat-file", "blob", "HEAD:" + rel], capture_output=True, env=git_env)
    return done.stdout if done.returncode == 0 else None


def say(word):
    print(word)
    sys.exit(0)


prompt = at_head(PROMPT)
if prompt is None:
    say("no-prompt")
try:
    receipt = json.loads(at_head(RECEIPT) or b"")
except (ValueError, RecursionError):
    receipt = None
if not (isinstance(receipt, dict) and receipt.get("verdict") == "green"
        and receipt.get("lean_prompt_sha256") == hashlib.sha256(prompt).hexdigest()):
    say("not-green")
try:
    with open(path, encoding="utf-8") as fh:
        raw = fh.read()
except FileNotFoundError:
    raw = None
except (OSError, UnicodeDecodeError):
    say("skipped")
data = {}
if raw is not None:
    try:
        data = json.loads(raw)
    except (ValueError, RecursionError):
        data = None
    if not isinstance(data, dict):
        say("skipped")
current = data.get("agent")
if current == AGENT:
    say("current")
if current is not None and current not in OURS:
    say("kept-custom")
data["agent"] = AGENT
indent = "  "
for line in (raw or "").splitlines():
    if line[:1] in (" ", "\t"):
        indent = line[: len(line) - len(line.lstrip(" \t"))]
        break
text = json.dumps(data, indent=indent, ensure_ascii=False) + ("\n" if raw is None or raw.endswith("\n") else "")
tmp = ""
try:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".settings.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    if raw is not None:
        os.chmod(tmp, stat.S_IMODE(os.stat(path).st_mode))
    os.replace(tmp, path)
except OSError:
    if tmp and os.path.exists(tmp):
        os.unlink(tmp)
    say("skipped")
say("selected")
PY
}

# lean_reset PLUGIN_DIR RUNTIME_HOME -- 0 = done (steps 4, 5 and 7 may be pending), 1 = stopped (the reason is on stderr, the install is not left half converted)
lean_reset() {
  local plugin="$1" rt="$2"
  local lib="$1/bin/lib" headroom="$1/bin/heimdall-headroom" record="$2/backups/lean-reset-pending"
  local guard="$lib/lean_route_guard.sh" backup="$lib/lean_backup.py" config="$lib/skills_config.py" profile="$lib/hmd_profile.py" sparse="$lib/lean_sparse.sh"
  local f g_out g_rc word rc=0 bdir="" pending="" undo="" envp="" deferred=0
  printf '   Lean reset (install.sh --reset)\n'
  command -v python3 >/dev/null 2>&1 || { printf '  ✗ hmd: --reset needs python3 (nothing was changed)\n' >&2; return 1; }
  for f in "$guard" "$backup" "$config" "$profile" "$sparse"; do
    [ -f "$f" ] || { printf '  ✗ hmd: --reset needs %s and this release does not ship it (nothing was changed)\n' "${f#"$plugin"/}" >&2; return 1; }
  done

  # 1/8 route guard: exit 0 + `ok:` proceeds, 10 + `defer:` leaves steps 4, 5 and 7 for the next run, anything else (11 refuse, a crash, a verdict that
  # does not match its exit status) fails closed before a byte changes
  g_out="$(bash "$guard" check)" && g_rc=0 || g_rc=$?
  case "$g_rc:$g_out" in
    0:ok:*) ;;
    10:defer:*) deferred=1 ;;
    *) printf '  ✗ hmd: --reset refused, nothing was changed: %s\n' "${g_out:-the route guard gave no answer (exit $g_rc)}" >&2; return 1 ;;
  esac
  printf '   1/8 route guard: %s\n' "$g_out"

  # 2/8 backup: first, and only once per unfinished reset (a re-run keeps the backup of what the install was before the reset began)
  if [ -f "$record" ]; then bdir="$(sed -n 's/^backup=//p' "$record" | head -1)" || bdir=""; fi
  if [ -n "$bdir" ] && [ -f "$bdir/manifest.json" ]; then
    printf '   2/8 backup: kept from the unfinished reset: %s\n' "$bdir"
  else
    bdir="$(HEIMDALL_HOME="$rt" python3 -I "$backup" backup)" && rc=0 || rc=$?
    if [ "$rc" -ne 0 ] || [ ! -f "$bdir/manifest.json" ]; then
      printf '  ✗ hmd: --reset could not take its backup, nothing was changed\n' >&2
      return 1
    fi
    printf '   2/8 backup: %s\n' "$bdir"
  fi
  if [ -n "${HEIMDALL_HOME:-}" ]; then envp="HEIMDALL_HOME=$(printf '%q' "$rt") "; fi
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then envp="${envp}CLAUDE_CONFIG_DIR=$(printf '%q' "$CLAUDE_CONFIG_DIR") "; fi
  undo="${envp}hmd lean restore $(printf '%q' "$bdir")"
  lean_reset_record "$record" "$bdir" || printf '  ⚠ hmd: could not write %s\n' "$record" >&2

  # 3/8 consent ask + grandfathered false: M1's `init` refuses to touch an existing file, so `set` is how a reset changes it
  if HEIMDALL_HOME="$rt" python3 -I "$config" set grandfathered false && HEIMDALL_HOME="$rt" python3 -I "$config" set consent ask; then
    printf '   3/8 consent: ask, not grandfathered\n'
  else
    printf '  ✗ hmd: --reset could not update skills-config.json and stopped there; to go back: %s\n' "$undo" >&2
    return 1
  fi

  # 4/8 profile lean: recorded before the tree changes, as `hmd lean on` does. Not while the guard defers: the recorded profile is what a plain install.sh
  # run re-applies (T3.4, INV-L7), so `lean` on record beside a full tree would narrow it under this session on the next plain run. The next --reset records
  # it together with the tree, and until then the install reads `full`.
  if [ "$deferred" -eq 1 ]; then
    pending="$pending lean-profile"
    printf '   4/8 profile: PENDING, this session is routed through Headroom (the next --reset records lean and applies the tree together)\n'
  elif HEIMDALL_HOME="$rt" python3 -I "$profile" set lean; then
    printf '   4/8 profile: lean\n'
  else
    printf '  ✗ hmd: --reset could not record the lean profile and stopped there; to go back: %s\n' "$undo" >&2
    return 1
  fi

  # 5/8 lean tree
  if [ "$deferred" -eq 1 ]; then
    pending="$pending lean-tree"
    printf '   5/8 lean tree: PENDING, this session is routed through Headroom (the next --reset applies it)\n'
  elif bash "$sparse" apply lean "$plugin" >/dev/null; then
    printf '   5/8 lean tree: applied (the on-demand parts stay in git)\n'
  else
    pending="$pending lean-tree"
    printf '  ⚠ hmd: the lean tree was not applied, the full tree is kept (the next --reset or `hmd lean on` tries again)\n' >&2
    printf '   5/8 lean tree: PENDING, the apply failed\n'
  fi

  # 6/8 lean prompt
  word="$(lean_reset_prompt "$plugin")" || word=skipped
  case "$word" in
    selected)    printf '   6/8 lean prompt: selected (agent hmd:heimdall-lean in the user settings, from the next session)\n' ;;
    current)     printf '   6/8 lean prompt: already selected\n' ;;
    kept-custom) printf '   6/8 lean prompt: skipped, the user settings already name another agent (kept)\n' ;;
    not-green)   printf '   6/8 lean prompt: skipped, this release has no green prompt-parity receipt for it\n' ;;
    no-prompt)   printf '   6/8 lean prompt: skipped, this release ships no lean prompt\n' ;;
    *)           printf '   6/8 lean prompt: skipped, the user settings could not be updated\n' ;;
  esac

  # 7/8 Headroom off, for the NEXT session only: the Headroom CLI's own `off --next-session` (what `hmd headroom off --next-session` execs; called by path
  # so a dispatcher that predates its arm can never turn it into a task prompt). It changes configuration only and never stops the proxy; it is never
  # reimplemented here, and an install without it gets one warning and no switch. Its own backup (CHANGES.txt: each change and its undo) is kept INSIDE the reset's
  # backup, $bdir/headroom: a launchd job it disables is state no file of that backup holds, so `hmd lean restore` finds the record there and switches the job back on
  # before it writes a Headroom route back (bin/lib/lean_backup.py); without that the login after an undo would route every claude session to a proxy that cannot start.
  if [ "$deferred" -eq 1 ]; then
    pending="$pending headroom-off"
    printf '   7/8 headroom: PENDING, this session is routed through Headroom (the next --reset switches it off for the session after)\n'
  elif [ -x "$headroom" ]; then
    if HEIMDALL_HOME="$rt" "$headroom" off --next-session --backup-dir "$bdir/headroom"; then
      printf '   7/8 headroom: off for the next session (hmd headroom off --next-session)\n'
    else
      rc=$?
      pending="$pending headroom-off"
      printf '  ⚠ hmd: hmd headroom off --next-session failed (exit %s): run it yourself\n' "$rc" >&2
      printf '   7/8 headroom: PENDING, the switch failed\n'
    fi
  else
    printf '  ⚠ hmd: bin/heimdall-headroom is not in this install, so Headroom was not switched off (hmd headroom off --next-session, once it is)\n' >&2
    printf '   7/8 headroom: skipped, not in this install\n'
  fi

  # 8/8 what is left, and how to go back
  if [ -n "$pending" ]; then
    # shellcheck disable=SC2086  # the pending steps are plain words
    lean_reset_record "$record" "$bdir" $pending || printf '  ⚠ hmd: could not write %s\n' "$record" >&2
    printf '   unfinished:%s (noted in %s; run install.sh --reset again once this session has ended)\n' "$pending" "$record"
  else
    rm -f "$record" || true
  fi
  printf '   8/8 to undo: %s\n' "$undo"
}

main() {
  # TEST SEAM: let the acceptance harness `source` this installer purely to unit-test
  # the pure helpers (ensure_dream_schedule gating, etc.) WITHOUT running a real network
  # install. Unset in EVERY production path — a curl|bash stranger install never sets it,
  # so the trailing `main "$@"` contract is byte-for-byte unchanged. Return at once when set.
  [ -n "${HEIMDALL_INSTALL_SOURCE_ONLY:-}" ] && return 0

  # ── Configuration ────────────────────────────────────────────────────────
  # Pinned ref = the CURRENT released tag. release/ship.sh rewrites this on every
  # release (see bump_default_ref) so a fresh `curl|bash` install and hmd --update's
  # reinstall fallback fetch THIS release, never a stale default. bin/heimdall-autoupdate
  # ALSO pins HEIMDALL_REF to the version it verified, so an auto-update installs the
  # exact resolved release regardless of this default. HEIMDALL_REF overrides for dev.
  local DEFAULT_REF="v2.4.17"
  local REF="${HEIMDALL_REF:-$DEFAULT_REF}"
  local REPO="${HEIMDALL_REPO:-https://github.com/randomittin/heimdall.git}"

  # ── Source-checkout guard roots (see SOURCE_GUARD_ROOTS above link_entry) ────
  # A stranger install (curl|bash) has NO local source tree — both branches below
  # no-op and the guard stays empty. A checkout-local or dev/test run pins the
  # tree(s) the installer must never write into, so it cannot clobber a tracked
  # file (the repo's own bin/hmd) if that bin/ happens to be on PATH.
  SOURCE_GUARD_ROOTS=""
  # (a) The installer's own on-disk dir — only when it is a real file on disk
  #     (a piped curl|bash has no BASH_SOURCE path, so this is skipped).
  local _gsrc="${BASH_SOURCE[0]:-}" _gr=""
  if [ -n "$_gsrc" ] && [ -f "$_gsrc" ]; then
    _gr="$(cd "$(dirname -- "$_gsrc")" 2>/dev/null && pwd -P || true)"
    [ -n "$_gr" ] && SOURCE_GUARD_ROOTS="${SOURCE_GUARD_ROOTS}${_gr}
"
  fi
  # (b) A LOCAL HEIMDALL_REPO checkout (tests/dev point REPO at a path; the
  #     default is an https:// clone URL, which is not a dir → skipped).
  if [ -d "$REPO" ]; then
    _gr="$(cd "$REPO" 2>/dev/null && pwd -P || true)"
    [ -n "$_gr" ] && SOURCE_GUARD_ROOTS="${SOURCE_GUARD_ROOTS}${_gr}
"
  fi

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
  # `hmd` is canonical, but a real collider exists (PyPI hmd-cli-app). When an
  # `hmd` already resolves to something OTHER than our own bin dir we must decide:
  #   - OURS (a heimdall/superx-owned binary, incl. the legacy ~/.superx/bin/hmd):
  #     OVERWRITE it by default. Leaving a stale, PATH-shadowing hmd behind is the
  #     bug that silently strands teammates on an old version despite reinstalling.
  #   - FOREIGN (a genuine third-party tool): PRESERVE it — install `heimdall` only
  #     — unless HEIMDALL_FORCE_HMD=1 explicitly authorizes taking the name.
  local INSTALL_HMD=1
  local EXISTING_HMD=""
  local HMD_OWNED=""   # "ours" | "foreign" | "" (none, or already at our target)
  if command -v hmd >/dev/null 2>&1; then
    EXISTING_HMD=$(command -v hmd)
    if [ "$EXISTING_HMD" != "$BIN_DIR/hmd" ]; then
      HMD_OWNED="$(hmd_ownership "$EXISTING_HMD")"
      # Only a FOREIGN hmd blocks the `hmd` link (unless forced). Our own stale hmd
      # is always installed over — the fix below also overwrites it in place if it
      # shadows the canonical link from an earlier PATH dir.
      if [ "$HMD_OWNED" = "foreign" ] && [ -z "${HEIMDALL_FORCE_HMD:-}" ]; then
        INSTALL_HMD=0
      fi
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

  # ── Install profile: lean or full (3.x lean-core plan, T3.4) ──────────────
  # `lean` narrows the clone to what runs (git sparse-checkout, bin/lib/lean_sparse.sh: every object stays in .git, so what the tree lacks
  # is one local `add` away); `full` is the whole tree, today's install. bin/lib/hmd_profile.py decides ONCE, on a fresh install (a runtime
  # home that holds the setup marker or a grandfathered skills-config.json is `full`, anything else `lean`) and records it in the runtime
  # home (INV-L2). A re-run re-applies the RECORDED profile and never decides again, so an upgrade cannot reset it (INV-L7). An install with
  # no record (every install from before this step) reads as `full`: a re-run over it writes nothing and changes nothing (INV-L8). Lean
  # never costs an install: the clone is whole when this starts and a failed apply leaves the tree as it was. It installs no proxy and
  # routes no session (INV-L12). This runs BEFORE the export below: the runtime home is the launcher's rule (HEIMDALL_HOME, else
  # ~/.heimdall) and that export points HEIMDALL_HOME at the installer's own telemetry store.
  local RT_HOME="${HEIMDALL_HOME:-$HOME/.heimdall}"
  local PROFILE_PY="$PLUGIN_DIR/bin/lib/hmd_profile.py"
  local PROFILE_SPARSE="$PLUGIN_DIR/bin/lib/lean_sparse.sh"
  if [ -f "$PROFILE_PY" ] && [ -f "$PROFILE_SPARSE" ] && command -v python3 >/dev/null 2>&1; then
    if [ "$UPGRADING" -eq 0 ]; then
      local PROFILE_MARKER="--marker-absent"
      if [ -f "$RT_HOME/setup-done" ]; then PROFILE_MARKER="--marker-present"; fi
      HEIMDALL_HOME="$RT_HOME" python3 -I "$PROFILE_PY" init "$PROFILE_MARKER" || true
    fi
    if [ "$(HEIMDALL_HOME="$RT_HOME" python3 -I "$PROFILE_PY" get || true)" = "lean" ]; then
      step_begin "Applying lean profile"
      if bash "$PROFILE_SPARSE" apply lean "$PLUGIN_DIR" >/dev/null; then
        step_ok "Applying lean profile" "on-demand parts stay in git"
      else
        printf '  ⚠ hmd: lean profile not applied, keeping the full tree (the next install.sh run tries again)\n' >&2
        step_ok "Applying lean profile" "skipped, full tree kept"
      fi
    fi
  fi
  chmod +x "$PLUGIN_DIR/bin/"* 2>/dev/null || true

  # ── --reset: an existing install becomes lean, on request (3.x lean-core plan, T4.4) ──────────────────────────────────────────────────
  # Only with the flag: a run without it never enters the branch below, so the install it makes is the one it always made (INV-L8). RT_HOME is the
  # runtime home read above, before the export below points HEIMDALL_HOME at the installer's telemetry store. A stopped reset ends the run here (the
  # fetch and the profile step above are the plain upgrade); the re-run after the fix does the rest of the install. Other arguments are ignored, as
  # they always were (`hmd reinstall --reset --yes` hands install.sh both).
  local RESET=0 RESET_ARG
  for RESET_ARG in "$@"; do
    case "$RESET_ARG" in --reset) RESET=1 ;; esac
  done
  if [ "$RESET" -eq 1 ]; then
    lean_reset "$PLUGIN_DIR" "$RT_HOME" || exit 1
  fi

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

  # Install receipt (bin/lib/install-receipt.sh ships in the clone just fetched): the marketplace
  # registration and plugin install below are receipted like every other auto-install. One id per
  # installer run; the receipt lands in ~/.heimdall/receipts beside the launcher's own, not in the
  # telemetry store (HEIMDALL_HOME above points that inside the footprint).
  export HMD_RUN_ID="$TELE_RUN_ID"
  export HMD_RECEIPTS_DIR="$PLUGIN_DIR/receipts"
  if [ -f "$PLUGIN_DIR/bin/lib/install-receipt.sh" ]; then
    # shellcheck disable=SC1091
    . "$PLUGIN_DIR/bin/lib/install-receipt.sh" || true
  fi

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
    # Named on stderr, not only in the stdout note below: the install goes on, but not silently.
    printf '  ⚠ hmd: install failed, continuing without marketplace %s (source %s)\n' "$MARKETPLACE_NAME" "$PLUGIN_DIR" >&2
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

  # Receipt the registration just attempted: the local clone, at the ref this installer pinned — not a
  # marketplace anyone else controls. (Skipped only when the clone predates the receipt lib.)
  if declare -F hmd_install_receipt >/dev/null 2>&1; then
    if [ "$MKT_RC" -eq 0 ]; then
      hmd_install_receipt marketplace "$MARKETPLACE_NAME" n/a "$PLUGIN_DIR" "$REF" ok install.sh || true
    else
      hmd_install_receipt marketplace "$MARKETPLACE_NAME" n/a "$PLUGIN_DIR" "$REF" failed install.sh \
        "claude plugins marketplace rc $MKT_RC" || true
    fi
  fi

  # Step: install the plugin (hmd@heimdall).
  local PLG_T0; PLG_T0="$(_tele_now_ms)"
  _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" plugin started
  step_begin "Installing plugin ($PLUGIN_ID)"
  local PLG_RC=0
  install_hmd_plugin "$PLUGIN_DIR" "$PLUGIN_ID" "$REF" || PLG_RC=$?
  if [ "$PLG_RC" -eq 0 ]; then
    _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" plugin succeeded "$PLG_T0"
    step_ok "Installing plugin ($PLUGIN_ID)"
  else
    # The helper already named the failure on stderr and in the receipt; the install carries on
    # without the plugin, and telemetry now says so instead of recording an unconditional success.
    _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" plugin failed "$PLG_T0" \
      plugin-install-failed "claude plugins install exit $PLG_RC"
    step_ok "Installing plugin ($PLUGIN_ID)" "failed, continuing without it"
  fi

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
  # hmd: canonical, unless a genuinely FOREIGN collider blocked it.
  if [ "$INSTALL_HMD" -eq 1 ]; then
    link_entry "$SRC" "$BIN_DIR/hmd"
    # If an existing hmd resolves from a DIFFERENT PATH dir than our canonical
    # $BIN_DIR/hmd (e.g. ~/.superx/bin earlier on PATH than ~/.local/bin), the link
    # above is MASKED — the stale binary keeps answering `hmd`. That is exactly the
    # bug. Fix it at the shadowing path itself.
    if [ -n "$EXISTING_HMD" ] && [ "$EXISTING_HMD" != "$BIN_DIR/hmd" ]; then
      if [ "$HMD_OWNED" = "ours" ]; then
        # OURS → overwrite in place so PATH resolves to the new launcher regardless
        # of dir order. Safe: it is our own stale binary. If the dir is read-only
        # (e.g. a root-owned sudo install), link_entry fails → warn LOUDLY with the
        # exact removal command rather than silently leaving the shadow.
        local OLDVER; OLDVER="$(hmd_probe_version "$EXISTING_HMD")"
        if link_entry "$SRC" "$EXISTING_HMD" 2>/dev/null; then
          blank
          printf '   %sreplacing stale heimdall hmd at %s (was %s)%s\n' \
            "$C_GOLD" "$EXISTING_HMD" "$OLDVER" "$C_RESET"
          blank
        else
          blank
          printf '   %s⚠ a stale heimdall hmd at %s (was %s) SHADOWS the new install%s\n' \
            "$C_GOLD" "$EXISTING_HMD" "$OLDVER" "$C_RESET"
          printf '   %s  and could not be overwritten — remove it so `hmd` picks up the new version:%s\n' \
            "$C_DIM" "$C_RESET"
          printf '       %srm -f %s%s\n' "$C_CYAN" "$EXISTING_HMD" "$C_RESET"
          blank
        fi
      else
        # FOREIGN but forced (HEIMDALL_FORCE_HMD=1): we installed our canonical hmd
        # but must NOT clobber the third-party binary (data-loss risk). It may still
        # shadow us from an earlier PATH dir — say so, with the exact removal command.
        blank
        printf '   %s⚠ a foreign hmd at %s may SHADOW the new install%s\n' \
          "$C_GOLD" "$EXISTING_HMD" "$C_RESET"
        printf '   %s  it was left untouched — to use heimdall'\''s hmd, remove it:%s\n' \
          "$C_DIM" "$C_RESET"
        printf '       %srm -f %s%s\n' "$C_CYAN" "$EXISTING_HMD" "$C_RESET"
        blank
      fi
    fi
    _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" link succeeded "$LNK_T0"
    step_ok "Linking entry points (hmd, heimdall)"
  else
    _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" link succeeded "$LNK_T0"
    step_ok "Linking entry point (heimdall)"
    blank
    printf '   %s⚠ hmd already exists at %s and looks like a different tool — installed `heimdall` only.%s\n' \
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

  # Cursor CLI sibling — silent unless it actually registers something, so a
  # non-Cursor machine sees no new install-log noise at all.
  local CURSOR_SL_STATE; CURSOR_SL_STATE="$(ensure_cursor_statusline_registered "$PLUGIN_DIR")"
  if [ "$CURSOR_SL_STATE" = "registered" ]; then
    step_ok "Activating Cursor CLI statusline HUD" "registered (undo: heimdall cursor-statusline unregister)"
  fi

  # Step: configure the control-plane endpoint so SERVER-SYNCED TEAM PRESENCE
  # auto-resolves for THIS dev with zero manual exports. The url comes from the
  # install env (HEIMDALL_CP_URL) or, ONLY on a real interactive TTY, a one-time
  # prompt; a non-interactive run with no env (curl|bash, whose stdin is the script
  # pipe — or CI) skips cleanly with guidance and NEVER hangs. Enrollment is
  # automatic (open-bounded) — there is NO token to paste. An OPERATOR re-gating a
  # private deployment may still pre-seed HEIMDALL_ENROLL_TOKEN via the env (a SECRET:
  # read without echo, written 0600, never printed — see OPERATORS.md). OPTIONAL/
  # graceful — a skip or failure never aborts the install.
  local CP_URL="${HEIMDALL_CP_URL:-}"
  local CP_TOK="${HEIMDALL_ENROLL_TOKEN:-}"
  local CP_FORCE=""
  [ -n "${HEIMDALL_FORCE:-}" ] && CP_FORCE=1
  step_begin "Configuring control-plane endpoint"
  # Prompt ONLY on an interactive TTY, and only when the env did not supply a value
  # and no config exists yet. Under curl|bash / CI, [ -t 0 ] is false → no read, no
  # hang. NO token prompt: enrollment is open-bounded (tokenless) — the url is all a
  # dev ever supplies, and even that has a baked default. An operator re-gating a
  # private deployment passes HEIMDALL_ENROLL_TOKEN via the env (see OPERATORS.md),
  # which leaves CP_TOK non-empty and skips this interactive block entirely.
  if [ -z "$CP_URL" ] && [ -z "$CP_TOK" ] && [ ! -f "$PLUGIN_DIR/cp-endpoint.json" ] && [ -t 0 ]; then
    printf '\n   %sTeam control-plane URL%s (blank for the default public CP): ' "$C_WHITE" "$C_RESET"
    IFS= read -r CP_URL || CP_URL=""
  fi
  local CP_STATE; CP_STATE="$(ensure_cp_endpoint "$PLUGIN_DIR" "$CP_URL" "$CP_TOK" "$CP_FORCE")"
  case "$CP_STATE" in
    configured)
      step_ok "Configuring control-plane endpoint" "enrolls on first session" ;;
    current)
      step_ok "Configuring control-plane endpoint" "already set" ;;
    absent)
      step_ok "Configuring control-plane endpoint" "skipped"
      # SHORT_PATH is computed later (success card); derive a local one here.
      local CP_SHORT; CP_SHORT=$(printf '%s' "$PLUGIN_DIR" | sed "s|$HOME|~|")
      blank
      printf '   %s⚠ no control-plane endpoint set — team presence stays offline.%s\n' \
        "$C_GOLD" "$C_RESET"
      printf '   %s  configure it any time (no re-install needed):%s\n' "$C_DIM" "$C_RESET"
      printf '   %s    HEIMDALL_CP_URL=<url> bash install.sh%s\n' \
        "$C_DIM" "$C_RESET"
      printf '   %s  (writes %s/cp-endpoint.json, 0600; enrollment is automatic thereafter)%s\n' \
        "$C_DIM" "$CP_SHORT" "$C_RESET"
      blank
      ;;
    *)
      step_ok "Configuring control-plane endpoint" "skipped (needs python3)" ;;
  esac

  # Step: join a TEAM if a team-invite secret was supplied. A teammate who pastes
  #   curl -fsSL <install.sh> | HEIMDALL_TEAM_SECRET='<secret>' bash
  # must land in the INVITER's team — not fall through to client auto-solo (their
  # OWN team), which silently breaks "teammates join the same team". The secret is
  # consumed from the install env ONLY, written 0600 to the joining dev's per-repo
  # <repo>/.heimdall/team.json, and NEVER echoed/logged/argv'd/committed. No env →
  # clean skip (the dev gets auto-solo); OPTIONAL/graceful — a skip or weak/failed
  # write never aborts the install. force re-stamps an existing same-secret file.
  local TEAM_SEC="${HEIMDALL_TEAM_SECRET:-}"
  local TEAM_FORCE=""
  [ -n "${HEIMDALL_FORCE:-}" ] && TEAM_FORCE=1
  step_begin "Joining team"
  local TEAM_STATE; TEAM_STATE="$(ensure_team_secret "$TEAM_SEC" "$TEAM_FORCE")"
  case "$TEAM_STATE" in
    configured) step_ok "Joining team" "presence scoped to your team" ;;
    current)    step_ok "Joining team" "already joined" ;;
    absent)     step_ok "Joining team" "solo (no invite)" ;;
    weak)       step_ok "Joining team" "skipped (secret too short)" ;;
    *)          step_ok "Joining team" "skipped" ;;
  esac

  # Step: ensure the Ed25519 PKI crypto backend for the presence interpreter.
  # THE FIX for the invisible-teammate outage (see ensure_crypto_backend above):
  # a fresh install must end with the interpreter heimdall-presence uses able to
  # sign beats, or SHOUT — never silently leave presence broken. Idempotent (silent
  # ✓ when the backend already imports), PEP-668-aware, NON-FATAL. The re-checked
  # ✓/⚠ line is the signal that would have saved akshat + madhavan hours.
  local CR_T0; CR_T0="$(_tele_now_ms)"
  _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" crypto started
  step_begin "Ensuring PKI crypto backend (Ed25519)"
  # Resolve the SAME interpreter for the manual-fix message (matches the presence
  # bin + ensure_crypto_backend); fall back to a literal `python3` label if none.
  local PRES_PY; PRES_PY="$(command -v python3 || command -v python || true)"
  local CRYPTO_STATE; CRYPTO_STATE="$(ensure_crypto_backend)"
  case "$CRYPTO_STATE" in
    present)
      _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" crypto succeeded "$CR_T0"
      step_ok "Ensuring PKI crypto backend (Ed25519)" "present" ;;
    installed)
      _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" crypto succeeded "$CR_T0"
      step_ok "Ensuring PKI crypto backend (Ed25519)" "installed cryptography" ;;
    nopy)
      _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" crypto failed "$CR_T0" \
        crypto-backend-unavailable "no python interpreter on PATH"
      step_ok "Ensuring PKI crypto backend (Ed25519)" "no python found"
      blank
      printf '   %s⚠ no python interpreter found — TEAM PRESENCE WILL NOT WORK.%s\n' \
        "$C_GOLD" "$C_RESET"
      printf '   %s  heimdall-presence signs its beats with an Ed25519 backend; without%s\n' \
        "$C_DIM" "$C_RESET"
      printf '   %s  python3 your beats stay unsigned and teammates never see you online.%s\n' \
        "$C_DIM" "$C_RESET"
      printf '   %s  install python3, then run:%s\n' "$C_DIM" "$C_RESET"
      printf '       %spython3 -m pip install --user cryptography%s\n' "$C_CYAN" "$C_RESET"
      blank
      ;;
    *)  # failed — the backend is still missing; NEVER silent, ALWAYS the loud fix.
      _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" crypto failed "$CR_T0" \
        crypto-backend-unavailable "cryptography/pynacl not importable after install attempt"
      step_ok "Ensuring PKI crypto backend (Ed25519)" "UNAVAILABLE"
      blank
      printf '   %s⚠ Ed25519 crypto backend MISSING — TEAM PRESENCE WILL BE SILENTLY BROKEN.%s\n' \
        "$C_GOLD" "$C_RESET"
      printf '   %s  heimdall-presence cannot sign its beats, so teammates will NOT see you%s\n' \
        "$C_DIM" "$C_RESET"
      printf '   %s  online — the exact outage that cost real teammates hours. Fix it (installs%s\n' \
        "$C_DIM" "$C_RESET"
      printf '   %s  into the SAME interpreter hmd uses for presence):%s\n' "$C_DIM" "$C_RESET"
      printf '       %s%s -m pip install --user cryptography%s\n' \
        "$C_CYAN" "${PRES_PY:-python3}" "$C_RESET"
      printf '   %s  (on an externally-managed python add --break-system-packages)%s\n' \
        "$C_DIM" "$C_RESET"
      blank
      ;;
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

  # Step: retire legacy companion plugins hmd no longer installs — compression
  # moved in-house (caveman) and claude-mem is retired outright: it ships its own
  # fail-CLOSED UserPromptSubmit hook (observed blocking a real prompt) — see
  # ensure_claude_mem_plugin_retired above. OPTIONAL/graceful either way — a
  # failure here is LOUD but never aborts the install.
  local CM_T0; CM_T0="$(_tele_now_ms)"
  _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" claude-mem started
  step_begin "Retiring legacy companion plugins"
  local CAV_STATE; CAV_STATE="$(ensure_caveman_plugin_retired)"
  if [ "$CAV_STATE" = "retired" ]; then
    printf '   %s  retired the legacy caveman plugin (compression is in-house: hmd caveman get)\n' "$OK"
  elif [ "$CAV_STATE" = "failed" ]; then
    printf '   %s  caveman plugin still installed and will conflict. Remove: claude plugins uninstall caveman@caveman\n' "$WARN"
  fi
  local CM_STATE; CM_STATE="$(ensure_claude_mem_plugin_retired)"
  case "$CM_STATE" in
    retired)
      _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" claude-mem succeeded "$CM_T0"
      printf '   %s  retired the legacy claude-mem plugin (it can fail CLOSED — see CLAUDE.md)\n' "$OK"
      step_ok "Retiring legacy companion plugins" ;;
    absent)
      _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" claude-mem succeeded "$CM_T0"
      step_ok "Retiring legacy companion plugins" ;;
    kept)
      _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" claude-mem succeeded "$CM_T0"
      step_ok "Retiring legacy companion plugins" "claude-mem kept (HEIMDALL_KEEP_CLAUDE_MEM=1)" ;;
    skipped)
      _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" claude-mem succeeded "$CM_T0"
      step_ok "Retiring legacy companion plugins" "skipped (no claude CLI)" ;;
    *)  # failed — LOUD, non-fatal.
      _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" claude-mem failed "$CM_T0" \
        claude-mem-plugin-uninstall-failed "plugin uninstall returned nonzero / still listed"
      step_ok "Retiring legacy companion plugins" "claude-mem still installed"
      printf '   %s  claude-mem still installed and can fail CLOSED. Remove: claude plugins uninstall claude-mem@thedotmack \&\& claude plugins marketplace remove thedotmack\n' "$WARN"
      ;;
  esac

  # Step: schedule the nightly /dream overnight sweep as a launchd LaunchAgent so the
  # maintainer sweep + morning report happen hands-free at 03:00 — surviving logout/
  # reboot, no live session needed. macOS-only (launchd), OPT-OUT via
  # HEIMDALL_NO_DREAM_SCHEDULE=1, and OPTIONAL/graceful (dossier §8): a non-Darwin box,
  # a missing launchctl, or a load failure NEVER aborts the install. --repo points at
  # the INSTALLED checkout ($PLUGIN_DIR) so the plist's dream bin is the stable installed
  # path — auto-updates that refresh that tree keep the nightly job on the CURRENT code.
  local DS_T0; DS_T0="$(_tele_now_ms)"
  _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" dream-schedule started
  step_begin "Scheduling nightly /dream (03:00)"
  local DS_STATE; DS_STATE="$(ensure_dream_schedule "$PLUGIN_DIR")"
  case "$DS_STATE" in
    scheduled)
      _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" dream-schedule succeeded "$DS_T0"
      step_ok "Scheduling nightly /dream (03:00)" "enabled"
      blank
      printf '   %s▸ nightly /dream scheduled (03:00) — disable: heimdall-dream-schedule uninstall%s\n' \
        "$C_DIM" "$C_RESET"
      blank
      ;;
    optout)
      _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" dream-schedule succeeded "$DS_T0"
      step_ok "Scheduling nightly /dream (03:00)" "skipped (opted out)" ;;
    unsupported)
      _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" dream-schedule succeeded "$DS_T0"
      step_ok "Scheduling nightly /dream (03:00)" "skipped (macOS only)" ;;
    sandboxed)
      # NOT a failure: the helper proved this is not the real user's home and refused,
      # so the real per-user launchd domain (which $HOME does not isolate) was never
      # touched. Say so in the same words the uninstall side uses.
      _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" dream-schedule succeeded "$DS_T0"
      step_ok "Scheduling nightly /dream (03:00)" \
        "skipped (synthetic HOME — refusing to touch the real launchd domain)" ;;
    ephemeral)
      # NOT a failure either: this install is running out of a disposable checkout (a
      # linked git worktree), so pinning the nightly job here would wire it to a path
      # that disappears when the tree is reaped — a job that then silently never runs.
      # Named distinctly from 'sandboxed' so the operator knows the fix is "re-run from
      # the main checkout", not "fix your HOME".
      _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" dream-schedule succeeded "$DS_T0"
      step_ok "Scheduling nightly /dream (03:00)" \
        "skipped (ephemeral checkout — re-run from the main worktree to schedule)" ;;
    *)  # skipped — helper/dream bin missing or launchctl load failed. Non-fatal.
      _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" dream-schedule failed "$DS_T0" \
        dream-schedule-unavailable "schedule helper missing or launchctl load failed"
      step_ok "Scheduling nightly /dream (03:00)" "skipped" ;;
  esac

  # A job now exists that will read $PLUGIN_DIR unattended at 03:00 — so this is the
  # moment to ask for the one macOS permission that can stop it, while a human may still
  # be here. ONLY when the schedule was actually registered: 'sandboxed', 'ephemeral' and
  # the rest mean no LaunchAgent was created, and a permission question for a job that
  # does not exist is noise the operator learns to ignore. Silent by construction, silent
  # under a pipe, and it can never fail the install (see ensure_dream_permission).
  if [ "$DS_STATE" = "scheduled" ]; then
    ensure_dream_permission "$PLUGIN_DIR" || true
  fi

  # The one token-saver question (hmd compact-window): only at a terminal, once, never a write without a yes, never a failed install.
  ensure_compact_window_offer "$PLUGIN_DIR" || true

  # PATH setup — make `hmd` reachable without the user hand-editing a profile.
  # ensure_path_on_profile appends a single guarded export to the right shell
  # profile (idempotent: a grep guard prevents a double-append on re-run). If the
  # bin dir is already on PATH, it writes nothing and we stay silent.
  #
  # Computed BEFORE the success card below (both this one AND the later "Run:"
  # line in Section 6 depend on it) — this used to run AFTER both, which meant
  # every next-step line printed first and the PATH caveat second. On a fresh
  # install PATH_STATE is "appended": the profile FILE now has the export, but
  # *this* shell's live $PATH does not — ensure_path_on_profile only ever writes
  # a file for future shells, it cannot mutate the running process's PATH. So
  # the next-step commands a brand-new user was told to paste were, in the
  # single most common case, dead on arrival: command-not-found. Measured: 0
  # dispatcher invocations of `hmd demo` across 384 real sessions. Computing
  # PATH_STATE first lets every next-step line either bake the export in or
  # point at the one that does, so nothing printed is a broken promise.
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

  # ── 5. Success card (A4) ──────────────────────────────────────────────────
  # VER is the ACTUAL installed version (git tag → manifest), never a literal.
  local VER; VER=$(resolved_version "$PLUGIN_DIR")
  local PRIMARY="hmd"; [ "$INSTALL_HMD" -eq 1 ] || PRIMARY="heimdall"
  # This card's "Next:" is a fixed-width box cell (34 chars) — too narrow to
  # ever bake in `export PATH=... && $PRIMARY demo` for a real home directory.
  # Rather than print a command that's dead on arrival on a fresh install (the
  # measured bug), point at the Run: line in Section 6 below, which computed
  # the same PATH_STATE and DOES have room to spell the export out in full.
  local NEXT_HINT="$PRIMARY demo"
  [ "$PATH_STATE" = "appended" ] && NEXT_HINT="see Run: below ↓"
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
    printf '   %s│%s  Next:        %s%-34s%s%s│%s\n' "$C_DIM" "$C_RESET" "$C_CYAN" "$NEXT_HINT" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '   %s│%s  In Claude:   /hmd:status  /hmd:save  …          %s│%s\n' "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '   %s│%s  Docs:        runheimdall.dev                    %s│%s\n' "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '   %s│%s  Data:        %-34s%s│%s\n' "$C_DIM" "$C_RESET" "DATA.md — telemetry contract" "$C_DIM" "$C_RESET"
    printf '   %s│%s  Uninstall:   %-34s%s│%s\n' "$C_DIM" "$C_RESET" "$PRIMARY uninstall" "$C_DIM" "$C_RESET"
    printf '   %s└───────────────────────────────────────────────┘%s\n' "$C_DIM" "$C_RESET"
    printf '   %s# gates local · presence opt-out · telemetry documented & killable · the watchman does not sleep%s\n' "$C_DIM" "$C_RESET"
  else
    say "Heimdall v$VER installed"
    say "gates live · secret-scan armed · $N/$N"
    say "plugin:  $SHORT_PATH"
    say "on PATH: $SHORT_BIN/$PRIMARY"
    say ""
    say "Next:        $NEXT_HINT"
    say "In Claude:   /hmd:status  /hmd:save"
    say "Docs:        runheimdall.dev"
    say "Data:        DATA.md — telemetry contract"
    say "Uninstall:   $PRIMARY uninstall"
    say "# gates local · presence opt-out · telemetry documented & killable · the watchman does not sleep"
  fi

  # ── 5a. MANDATORY post-install validation gate (the ready-gate) ───────────
  # RJ's directive: as soon as claude-mem setup completes, VALIDATE the whole
  # install before handing off — never run CC while a part is silently broken.
  # heimdall-doctor-install exercises EVERY part (crypto, presence, statusline,
  # gates, claude-mem, hooks, PATH) AND runs the FIRST cc/claude invocation
  # HEADLESS + BOUNDED in the background (--cc-verify) purely to fire the
  # SessionStart wiring — it NEVER drops into an interactive session. Its exit
  # code is the gate: any ✗ → we WITHHOLD the "ready" hand-off (no watchman
  # claim, no `Run: hmd demo` go-ahead) and print the loud NOT-READY block. The
  # install itself stays non-fatal (artifacts are on disk); only the go-ahead is
  # gated. A missing harness (should never happen) defaults to validated so we
  # never block on our own absent tool.
  local VALIDATED=1
  local DOC_BIN="$PLUGIN_DIR/bin/heimdall-doctor-install"
  if [ -x "$DOC_BIN" ]; then
    local VAL_T0; VAL_T0="$(_tele_now_ms)"
    _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" validate started
    # Bound the headless first-run (default 30s; HEIMDALL_CC_VERIFY_TIMEOUT overrides).
    if HMD_DOCTOR_PLUGIN_DIR="$PLUGIN_DIR" "$DOC_BIN" --cc-verify \
         --plugin-dir "$PLUGIN_DIR" --timeout "${HEIMDALL_CC_VERIFY_TIMEOUT:-30}"; then
      VALIDATED=1
      _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" validate succeeded "$VAL_T0"
    else
      VALIDATED=0
      _tele_install_step "$TELE_BIN" "$TELE_RUN_ID" validate failed "$VAL_T0" \
        validation-gate-failed "post-install validation found a broken part"
    fi
    # HEAL: the headless first-run boots real Claude Code, which rewrites the user's
    # ~/.claude/settings.json on startup and can DROP the statusLine we registered
    # earlier. Re-assert it now (idempotent, never clobbers a user's own line) so a
    # first-run write can NEVER leave the watchman HUD unregistered — for the dev AND
    # for the validation the dev will re-run. Silent + non-fatal.
    ensure_statusline_registered "$PLUGIN_DIR" >/dev/null 2>&1 || true
    # Symmetric defense-in-depth for the Cursor sibling — not a targeted fix for a
    # known Cursor-side clobber (Cursor CLI never runs during this Claude Code
    # headless verify), just consistency with the line above. Silent + non-fatal.
    ensure_cursor_statusline_registered "$PLUGIN_DIR" >/dev/null 2>&1 || true
  fi

  # ── 5b. Claim your watchman (the identity hook) ───────────────────────────
  # The "claim your watchman" moment: show the dev THEIR deterministic sigil and
  # the two ways to spread it — `hmd invite` (recruit the team) and the share
  # card (post it). TTY-ONLY (FANCY): the sigil is truecolor half-blocks that
  # would be garbage in a pipe/CI, so a non-interactive install (curl|bash / CI)
  # renders NONE of this — a clean no-op. No secret is read or printed (the sigil
  # seed is a public handle/username, never the enroll token).
  if [ "$FANCY" -eq 1 ]; then
    local WM_HANDLE; WM_HANDLE="$(sigil_handle "$PLUGIN_DIR")"
    blank
    printf '   %s%sYour watchman%s  %s@%s%s %s— claim it.%s\n' \
      "$C_BOLD" "$C_WHITE" "$C_RESET" "$C_CYAN" "$WM_HANDLE" "$C_RESET" "$C_DIM" "$C_RESET"
    render_sigil "$PLUGIN_DIR"
    blank
    printf '   %srecruit your team%s   %s%s invite%s\n' \
      "$C_DIM" "$C_RESET" "$C_CYAN" "$PRIMARY" "$C_RESET"
    printf '   %spost your watchman%s  %s%s/sentinels/hmd-banner.sh --share%s\n' \
      "$C_DIM" "$C_RESET" "$C_CYAN" "$SHORT_PATH" "$C_RESET"
  fi

  # ── 6. Next step + runtime ────────────────────────────────────────────────
  blank
  local END_TS; END_TS=$(date +%s)
  local ELAPSED=$(( END_TS - START_TS ))
  # PATH_STATE was computed earlier (right before the Section 5 success card,
  # which needs the same PATH-aware judgment call for ITS "Next:" line) — see
  # the comment there for why. Reused here unchanged; ensure_path_on_profile is
  # idempotent but is only ever called ONCE per install so the two call sites
  # can never observe different states.
  # The go-ahead is GATED on validation: only a fully-verified install hands the
  # dev on to `hmd demo`. A red gate prints a loud NOT-READY block instead — the
  # exact fix is in the validation output above — and NEVER auto-runs a session.
  if [ "$VALIDATED" -eq 1 ]; then
    local RUN_CMD="$PRIMARY demo"
    # PATH_STATE=appended → $BIN_DIR isn't live in *this* shell yet (only the
    # profile file has it, for future shells) — bake the export into the printed
    # command so it works verbatim right now, not just after a restart.
    [ "$PATH_STATE" = "appended" ] && RUN_CMD="export PATH=\"$BIN_DIR:\$PATH\" && $PRIMARY demo"
    if [ "$FANCY" -eq 1 ]; then
      printf '   Run:  %s%s%s%s%s\n' "$C_CYAN" "$C_BOLD" "$RUN_CMD" "$C_RESET" "$C_RESET"
    else
      say "   Run:  $RUN_CMD"
    fi
  else
    if [ "$FANCY" -eq 1 ]; then
      printf '   %s%s⛔ NOT READY%s — do not start a session yet.\n' "$C_RED" "$C_BOLD" "$C_RESET"
    else
      say "   NOT READY — do not start a session yet."
    fi
    printf '   %s  a validation check above failed — fix it, then re-verify:%s\n' "$C_DIM" "$C_RESET"
    printf '       %s%s/bin/heimdall-doctor-install --cc-verify%s\n' "$C_CYAN" "$SHORT_PATH" "$C_RESET"
    printf '   %s  (the install itself completed — the artifacts are in %s)%s\n' \
      "$C_DIM" "$SHORT_PATH" "$C_RESET"
  fi
  case "$PATH_STATE" in
    appended)
      # The Run: line above already embeds the export, so it works verbatim in
      # THIS shell — this is just the explanation, for anyone who reads on.
      local PROFILE_FILE; PROFILE_FILE=$(profile_for_shell)
      local SHORT_PROFILE; SHORT_PROFILE=$(printf '%s' "$PROFILE_FILE" | sed "s|$HOME|~|")
      printf '   %s(added %s to PATH in %s — new shells will have it automatically)%s\n' \
        "$C_DIM" "$SHORT_BIN" "$SHORT_PROFILE" "$C_RESET"
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

  # ── Δ6 funnel: record the `install` growth-loop stage — the very top of the
  #    funnel. Client-side into the shared telemetry spool, consent-gated + zero-
  #    content (no CP route, no model call). Fire-and-forget: never blocks or fails
  #    the install, and the engine no-ops when consent is off.
  local FUNNEL_BIN="$PLUGIN_DIR/bin/heimdall-funnel"
  [ -x "$FUNNEL_BIN" ] && ( "$FUNNEL_BIN" emit install --context installer >/dev/null 2>&1 & ) || true
}

main "$@"

# gates local · presence opt-out · telemetry documented & killable · the watchman does not sleep
