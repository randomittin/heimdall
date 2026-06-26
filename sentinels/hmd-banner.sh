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
N=4   # compact sigil row count

# face <eye-rgb "r;g;b" or ""> [size]  — render the watchman sigil
face() {
  HMD_EYE="$1" HMD_SIZE="${2:-compact}" python3 - "$SEED" <<'PY'
import sys, os, importlib.util
spec = importlib.util.spec_from_file_location("s", os.path.join(os.environ["HMD_SIGIL_DIR"], "hmd_sigil.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
e = os.environ.get("HMD_EYE", "")
eye = tuple(int(x) for x in e.split(";")) if e else None
fn = m.render_large if os.environ.get("HMD_SIZE") == "large" else m.render
print("\n".join(fn(sys.argv[1], eye_override=eye, pad="  ")))
PY
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

hmd_share() {
  printf '\n'
  face "$OPEN" large
  printf '\n'
  printf '  %b\n' "${CY}${B}@${HANDLE}${X}   ${DIM}your watchman${X}"
  printf '  %b\n' "$TAGLINE"
  printf '\n'
}

case "${1:-}" in
  --share) hmd_share ;;
  *)       hmd_wake ;;
esac
