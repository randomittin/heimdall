#!/usr/bin/env bash
# hmd-banner.sh — the watchman wakes. Install / first-run wake-up + share card.
# Two modes:
#   (no args)  hmd_wake — eyes-closed → blink → eyes-open. Animated on a TTY;
#              on non-TTY prints ONE awake frame + the tagline (clean logs).
#   --share    a postable block: large sigil + handle + tagline. The install
#              success card / README avatar (the spec's `hmd sigil --share`).
#
#   bash hmd-banner.sh            # wake the watchman
#   bash hmd-banner.sh --share    # printable identity card
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
export HMD_SIGIL_DIR="$HERE"
# identity is FILE-controlled (bin/heimdall-identity): the SEED feeds the sigil, the
# HANDLE is the share/wall name. Fall back to the old HMD_HAID/USER seed if the bin errs.
IDENTITY_BIN="$HERE/../bin/heimdall-identity"
SEED="${HMD_HAID:-${USER:-you}}"; HANDLE="$SEED"
if [ -x "$IDENTITY_BIN" ]; then
  _s="$("$IDENTITY_BIN" 2>/dev/null)" && [ -n "$_s" ] && SEED="$_s"
  _h="$("$IDENTITY_BIN" --handle 2>/dev/null)" && [ -n "$_h" ] && HANDLE="$_h"
fi

CY=$'\033[38;2;34;211;238m'; GR=$'\033[38;2;34;197;94m'; DIM=$'\033[38;2;90;100;114m'
EYEC=$'\033[38;2;240;248;255m'; B=$'\033[1m'; X=$'\033[0m'
TAGLINE="${CY}${B}HEIMDALL${X} ${DIM}· nothing ships unproven${X}"
TAGLINE_PLAIN="HEIMDALL · nothing ships unproven"   # ANSI-free, for piped/non-TTY paste
N=4   # compact sigil row count

# The PUBLIC join URL printed on the share card. PUBLIC by design — the project's
# front door, NOT a team secret and NEVER the enroll token. Overridable for
# self-hosters via HEIMDALL_PUBLIC_URL; defaults to the canonical site (the same
# host install.sh's curl one-liner uses).
PUBLIC_URL="${HEIMDALL_PUBLIC_URL:-https://runheimdall.dev}"

# face <eye-rgb "r;g;b" or ""> [size]  — render the watchman sigil
face() {
  HMD_EYE="$1" HMD_SIZE="${2:-compact}" python3 - "$SEED" <<'PY'
import sys, os, importlib.util
spec = importlib.util.spec_from_file_location("s", os.path.join(os.environ["HMD_SIGIL_DIR"], "hmd_sigil.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
e = os.environ.get("HMD_EYE", "")
eye = tuple(int(x) for x in e.split(";")) if e else None
sz = os.environ.get("HMD_SIZE")
# The share card / README avatar (a TTY / screen-recording surface with room to
# spare) renders the DETAILED 16×16 sprite — RJ's hand-authored animal with real
# character detail + tonal shading, richer than the compact statusline face. The
# wake animation stays on the compact face (it re-draws in place; the eyes blink
# through eye_override). Everything routes through the ONE shared render core.
if sz == "detailed":
    print("\n".join(m.render_detailed(sys.argv[1], pad="  ")))
else:
    fn = m.render_large if sz == "large" else m.render
    print("\n".join(fn(sys.argv[1], eye_override=eye, pad="  ")))
PY
}

# face_mono — the ANSI-FREE watchman, for the piped/non-TTY share block. The
# colored half-block sigil is unreadable as plain text (every cell is a filled
# block; without color the face vanishes into a rectangle), so a pasteable card
# needs a monochrome glyph map. Uses the SAME deterministic grid (grid_for) the
# colored renderer uses — same seed -> same face — and maps each full-resolution
# pixel to a 2-wide glyph: off=blank (the face floats, no boxy frame), body=▓▓
# (medium shade), eye=██ (the bright glint). Trailing blanks are trimmed so the
# block pastes clean into GitHub / HN with no ragged whitespace. NO escape codes.
face_mono() {
  python3 - "$SEED" <<'PY'
import sys, os, importlib.util
spec = importlib.util.spec_from_file_location("s", os.path.join(os.environ["HMD_SIGIL_DIR"], "hmd_sigil.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
g, _hue, _eye = m.grid_for(sys.argv[1])
GLYPH = {0: "  ", 1: "▓▓", 2: "██"}  # off / body / eye-glint
for row in g:
    print(("  " + "".join(GLYPH[v] for v in row)).rstrip())
PY
}

# avatar_png — render the DETAILED sigil as a CRISP PNG (option C): the true-fidelity
# avatar for the surfaces that can display an image. The terminal card keeps its
# half-block face; THIS writes a clean upscaled pixel-art PNG (matching RJ's gallery)
# to a deterministic cache path and echoes it. Reuses the SAME value→color palette as
# the terminal sigil (sentinels/hmd_sigil.py) via sentinels/hmd_sigil_png.py, so the
# terminal and the image agree hue-for-hue. The PRESENCE WALL consumes the same
# convention: <cache>/sigil/<seed>.png. Public material only (deterministic art from
# the seed — no secret). Non-fatal: a missing python3 / renderer just skips the line.
PNG_PY="$HERE/hmd_sigil_png.py"
avatar_png() {
  command -v python3 >/dev/null 2>&1 || return 1
  [ -f "$PNG_PY" ] || return 1
  local dir="${HOME:-/tmp}/.heimdall/sigil"
  local safe; safe="$(printf '%s' "$SEED" | tr -c 'A-Za-z0-9_-' '_')"
  local out="$dir/$safe.png"
  python3 "$PNG_PY" --seed "$SEED" --scale 24 --out "$out" >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

is_tty() { [ -t 1 ]; }
up() { printf '\033[%dA' "$(( N + 1 ))"; }   # cursor up over face + caption

# eye states: closed (dim, near-bg) → squint → open (full EYE glint)
CLOSED='40;46;54'; SQUINT='120;134;152'; OPEN='240;248;255'

hmd_wake() {
  if ! is_tty; then
    face "$OPEN"; printf '  %b\n' "$TAGLINE"; return 0
  fi
  printf '\n'
  # 1) asleep — eyes closed
  face "$CLOSED"; printf '  %b\n' "${DIM}…${X}"; up; sleep 0.30
  # 2) stir — a squint
  face "$SQUINT"; printf '  %b\n' "${DIM}▸${X}"; up; sleep 0.16
  # 3) blink shut once more
  face "$CLOSED"; printf '  %b\n' "${DIM}…${X}"; up; sleep 0.10
  # 4) eyes open — awake, watching
  face "$OPEN";  printf '  %b\n' "${EYEC}✦${X}"; up; sleep 0.18
  face "$OPEN";  printf '  %b\n' "$TAGLINE"
  printf '\n'
}

# hmd_share — the postable "claim your watchman" card. Carries ONLY public
# material: the deterministic sigil art, the public HANDLE, the tagline, and the
# PUBLIC join URL. NEVER a secret (no cp-endpoint / enroll token is read here).
#   TTY      → colored large sigil (renders in a terminal / screen-recording).
#   non-TTY  → ANSI-free block (pastes as clean text into GitHub / HN).
hmd_share() {
  if is_tty; then
    printf '\n'
    face "$OPEN" detailed
    printf '\n'
    printf '  %b\n' "${CY}${B}@${HANDLE}${X}   ${DIM}your watchman${X}"
    printf '  %b\n' "$TAGLINE"
    printf '  %b\n' "${DIM}join${X}  ${CY}${PUBLIC_URL}${X}"
    # the crisp PNG avatar for image surfaces (share, presence wall) — deterministic
    # cache path; skipped silently if the renderer/python3 is unavailable.
    _png="$(avatar_png)" && [ -n "$_png" ] \
      && printf '  %b\n' "${DIM}avatar${X}  ${CY}${_png}${X}"
    printf '\n'
    printf '  %b\n' "${DIM}my Heimdall watchman — ${PUBLIC_URL}${X}"
    printf '\n'
  else
    printf '\n'
    face_mono
    printf '\n'
    printf '  @%s — your watchman\n' "$HANDLE"
    printf '  %s\n' "$TAGLINE_PLAIN"
    printf '  join  %s\n' "$PUBLIC_URL"
    printf '\n'
    printf '  my Heimdall watchman — %s\n' "$PUBLIC_URL"
    printf '\n'
  fi
}

case "${1:-}" in
  --share) hmd_share ;;
  *)       hmd_wake ;;
esac
