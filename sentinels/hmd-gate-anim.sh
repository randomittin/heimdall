#!/usr/bin/env bash
# hmd-gate-anim.sh — the watchman reacts to a gate verdict, inline, animated.
# Hooks call this at gate events; it prints into the conversation flow (NOT the
# statusline). This is the dramatic moment — the deny flash is the screenshot.
#
#   hmd-gate-anim.sh deny  "oracle/falsify" rj-a3f9
#   hmd-gate-anim.sh pass  "secret-scan"    rj-a3f9
#   hmd-gate-anim.sh scan  "bloat-gate"     rj-a3f9
#
# Honest about TTY: animates only on an interactive terminal; on non-TTY (CI,
# pipes) it prints a single final frame so logs stay clean.
set -u
VERDICT="${1:-pass}"; GATE="${2:-gate}"; SEED="${3:-${HMD_HAID:-you}}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SIGIL="$HERE/hmd-sigil.py"
CY=$'\033[38;2;34;211;238m'; GR=$'\033[38;2;34;197;94m'; RD=$'\033[38;2;239;68;68m'
AM=$'\033[38;2;245;158;11m'; DIM=$'\033[38;2;90;100;114m'; B=$'\033[1m'; X=$'\033[0m'
N=4   # sigil row count

face() {  # $1 = eye rgb "r;g;b" or "" for transparent/closed
  if [ -n "$1" ]; then HMD_EYE="$1"; else HMD_EYE=""; fi
  HMD_EYE="$1" python3 - "$SEED" <<'PY'
import sys, os, importlib.util
spec = importlib.util.spec_from_file_location("s", os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])) if False else os.environ["HMD_SIGIL_DIR"], "hmd_sigil.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
e = os.environ.get("HMD_EYE","")
eye = tuple(int(x) for x in e.split(";")) if e else None
print("\n".join(m.render(sys.argv[1], eye_override=eye, pad="  ")))
PY
}
export HMD_SIGIL_DIR="$HERE"

draw() { printf '%b\n' "$1"; }   # print N-row face + caption
up()   { printf '\033[%dA' "$(( N + 1 ))"; }   # cursor up over face+caption

is_tty() { [ -t 1 ]; }

final_caption() {
  case "$VERDICT" in
    pass) printf '  %b\n' "${GR}${B}✓ proven${X}  ${DIM}${GATE} · nothing ships unproven${X}" ;;
    deny) printf '  %b\n' "${RD}${B}✗ BIFRÖST CLOSED${X}  ${RD}${GATE}${X} ${DIM}· merge blocked until proven${X}" ;;
    scan) printf '  %b\n' "${AM}▸ scanning${X}  ${DIM}${GATE}…${X}" ;;
  esac
}

if ! is_tty; then
  face "$( [ "$VERDICT" = deny ] && echo '239;68;68' || { [ "$VERDICT" = pass ] && echo '34;197;94' || echo '245;158;11'; } )"
  final_caption; exit 0
fi

printf '\n'
case "$VERDICT" in
  scan|deny|pass)
    # 1) scanning pulse (amber, eyes blinking)
    for fr in '245;158;11' '' '245;158;11' '120;80;6'; do
      face "$fr"; printf '  %b\n' "${AM}▸ scanning ${GATE}…${X}"; up; sleep 0.14
    done ;;
esac
case "$VERDICT" in
  deny)
    # 2) the flash: wide red eyes, three quick beats
    for fr in '239;68;68' '90;10;10' '239;68;68'; do
      face "$fr"; printf '  %b\n' "${RD}${B}✗ BIFRÖST CLOSED${X}"; up; sleep 0.10
    done
    face '239;68;68'; final_caption ;;
  pass)
    # 2) settle to green + a sparkle beat
    face '34;197;94'; printf '  %b\n' "${GR}…${X}"; up; sleep 0.18
    face '240;248;255'; printf '  %b\n' "${GR}✦${X}"; up; sleep 0.12
    face '34;197;94'; final_caption ;;
  scan)
    face '245;158;11'; final_caption ;;
esac
printf '\n'
