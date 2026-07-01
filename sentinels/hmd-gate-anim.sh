#!/usr/bin/env bash
# hmd-gate-anim.sh — the watchman reacts to a gate verdict, inline, animated.
# Hooks call this at gate events; it prints into the conversation flow (NOT the
# statusline). This is the dramatic moment — the deny flash is the screenshot.
#
#   hmd-gate-anim.sh deny  "oracle/falsify" rj-a3f9
#   hmd-gate-anim.sh pass  "secret-scan"    rj-a3f9
#   hmd-gate-anim.sh scan  "bloat-gate"     rj-a3f9
#   hmd-gate-anim.sh replay <report.json>            # re-render a PAST gate event
#
# Honest about TTY: animates only on an interactive terminal; on non-TTY (CI,
# pipes) it prints a single final frame so logs stay clean.
#
# ── Shareable artifact (the viral clip) ─────────────────────────────────────
# On a deny (and, opt-in, a pass) the run ALSO writes a drop-in social asset and
# PRINTS its path, so the BIFRÖST CLOSED moment is postable with zero extra steps.
# The export reuses bin/heimdall-reel's rendering + graceful-degradation ladder
# and NEVER blocks the deny (best-effort; backgroundable):
#
#   asciinema + agg present → .gif of the animation (+ the .cast, itself replayable)
#   else an image tool (magick/convert) + a mono font → .png of the final frame
#   else → an honest .txt endframe (ALWAYS written — the guaranteed floor)
#
# The frame content reflects the ACTUAL verdict/domain — a passing gate never
# fabricates a "BIFRÖST CLOSED" frame. Artifacts land under .planning/reels/ as
# gate-<verdict>-<ts>.{gif,png,cast,txt} + a manifest .json (honest: which tools
# were present, which were missing).
#
# Env knobs (all optional):
#   HMD_REELS_DIR         output dir           (default <plugin>/.planning/reels)
#   HMD_GATE_NAME         artifact basename    (default gate-<verdict>-<ts>-<pid>)
#   HMD_GATE_EXPORT       on|off               (default on; off = animate only)
#   HMD_GATE_EXPORT_PASS  1 = also export on a pass verdict          (default 0)
#   HMD_GATE_EXPORT_SCAN  1 = also export on a scan verdict          (default 0)
#   HMD_GATE_EXPORT_ASYNC 1 = background the export, return instantly (default 0)
set -u

SELF="$0"
HERE="$(cd "$(dirname "$SELF")" && pwd)"
SIGIL="$HERE/hmd-sigil.py"
ROOT="$(cd "$HERE/.." && pwd)"
REELS_DIR="${HMD_REELS_DIR:-$ROOT/.planning/reels}"

CY=$'\033[38;2;34;211;238m'; GR=$'\033[38;2;34;197;94m'; RD=$'\033[38;2;239;68;68m'
AM=$'\033[38;2;245;158;11m'; DIM=$'\033[38;2;90;100;114m'; B=$'\033[1m'; X=$'\033[0m'
N=4   # sigil row count

export HMD_SIGIL_DIR="$HERE"

have() { command -v "$1" >/dev/null 2>&1; }

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

# ─────────────────────────────────────────────────────────────────────────────
# Shareable-artifact export. Best-effort, honest degradation. Never fabricates.
# ─────────────────────────────────────────────────────────────────────────────

# build_still <verdict> <gate> <seed> — a plain-text (ANSI-FREE) final frame: the
# watchman silhouette (from hmd-sigil --debug: ·/#/@) + the verdict caption. This
# is the .txt floor AND the source text for the .png. No color codes ever, so the
# .txt is clean in any log/CI (and the raw-ANSI check stays green).
build_still() {
  local v="$1" g="$2" s="$3"
  printf 'BIFRÖST — Heimdall gate\n\n'
  python3 "$SIGIL" --seed "$s" --debug 2>/dev/null || printf '(sigil unavailable)\n'
  printf '\n'
  case "$v" in
    deny) printf '✗ BIFRÖST CLOSED\n%s · merge blocked until proven\n' "$g" ;;
    pass) printf '✓ proven\n%s · nothing ships unproven\n' "$g" ;;
    scan) printf '▸ scanning\n%s …\n' "$g" ;;
    *)    printf '· %s\n%s\n' "$v" "$g" ;;
  esac
}

# ascii_filter — fold the still down to ASCII-safe glyphs for image fonts that
# lack ö/✗/✓/▸/·. Keeps the meaning; only used for the .png raster path.
ascii_filter() {
  sed -e 's/BIFRÖST/BIFROST/g' -e 's/✗/X/g' -e 's/✓/OK/g' \
      -e 's/▸/>/g' -e 's/✦/*/g' -e 's/·/./g' -e 's/…/.../g' -e 's/—/-/g'
}

# find_font — first readable monospace font file (macOS + common Linux paths).
# Empty output → no font → the .png path is skipped (honest degrade to .txt).
find_font() {
  local c
  for c in \
    /System/Library/Fonts/Menlo.ttc \
    /System/Library/Fonts/Monaco.ttf \
    /System/Library/Fonts/SFNSMono.ttf \
    "/System/Library/Fonts/Supplemental/Courier New.ttf" \
    /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf \
    /usr/share/fonts/TTF/DejaVuSansMono.ttf \
    /usr/share/fonts/dejavu/DejaVuSansMono.ttf \
    /usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf \
    /usr/share/fonts/liberation/LiberationMono-Regular.ttf ; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

IMG_TOOL=""
# render_png <verdict> <gate> <seed> <outfile> — raster the final frame to PNG via
# ImageMagick, tinted by verdict (red deny / green pass / amber scan). Returns 0
# only on a real, non-empty PNG; on any failure it removes the partial and returns
# 1 so the caller degrades honestly to .txt.
render_png() {
  local v="$1" g="$2" s="$3" out="$4" tool font tmpf fill
  tool="$(command -v magick 2>/dev/null || command -v convert 2>/dev/null || true)"
  [ -n "$tool" ] || return 1
  font="$(find_font)" || return 1
  [ -n "$font" ] || return 1
  IMG_TOOL="$(basename "$tool")"
  tmpf="$(mktemp 2>/dev/null)" || return 1
  build_still "$v" "$g" "$s" | ascii_filter > "$tmpf" 2>/dev/null
  case "$v" in
    deny) fill='#ef4444' ;; pass) fill='#22c55e' ;;
    scan) fill='#f59e0b' ;; *) fill='#e6edf3' ;;
  esac
  if "$tool" -background '#0b0e14' -fill "$fill" -font "$font" -pointsize 22 \
       "label:@$tmpf" -bordercolor '#0b0e14' -border 28 "$out" >/dev/null 2>&1 \
     && [ -s "$out" ]; then
    rm -f "$tmpf" 2>/dev/null
    return 0
  fi
  rm -f "$tmpf" "$out" 2>/dev/null
  return 1
}

# render_gif <verdict> <gate> <seed> <castfile> <giffile> — record the animation
# (re-run in a pty via asciinema, export DISABLED in the child to avoid recursion)
# and render the cast → gif via agg. Echoes the primary path on success, empty on
# failure. Requires asciinema + agg (checked by the caller).
render_gif() {
  local v="$1" g="$2" s="$3" cast="$4" gif="$5" inner
  inner="$(printf 'HMD_GATE_EXPORT=off %q %q %q %q' "$SELF" "$v" "$g" "$s")"
  if asciinema rec --overwrite -c "$inner" "$cast" >/dev/null 2>&1 && [ -s "$cast" ]; then
    if agg "$cast" "$gif" >/dev/null 2>&1 && [ -s "$gif" ]; then
      printf '%s' "$gif"; return 0
    fi
    printf '%s' "$cast"; return 0   # cast alone is shareable/replayable
  fi
  return 1
}

# write_manifest — honest record: verdict/domain, artifacts present, tools missing.
write_manifest() {
  local mf="$1" name="$2" v="$3" g="$4" primary="$5" note="$6"; shift 6
  local arts="" f first=1
  for f in "$@"; do
    [ -s "$f" ] || continue
    [ "$first" = 1 ] || arts="$arts,"
    arts="$arts\"$(basename "$f")\""; first=0
  done
  {
    printf '{\n'
    printf '  "name": "%s",\n' "$name"
    printf '  "verdict": "%s",\n' "$v"
    printf '  "domain": "%s",\n' "$g"
    printf '  "primary": "%s",\n' "$(basename "$primary")"
    printf '  "artifacts": [%s],\n' "$arts"
    printf '  "has_asciinema": %s,\n' "$(have asciinema && echo true || echo false)"
    printf '  "has_agg": %s,\n' "$(have agg && echo true || echo false)"
    printf '  "has_image_tool": %s,\n' "$( { have magick || have convert; } && echo true || echo false)"
    printf '  "ts": "%s",\n' "$(date -u +%FT%TZ 2>/dev/null || echo unknown)"
    printf '  "note": "%s"\n' "$note"
    printf '}\n'
  } > "$mf" 2>/dev/null || true
}

# export_artifact <verdict> <gate> <seed> — write the shareable asset, degrading
# honestly, and PRINT the primary path. Guaranteed to leave a real .txt floor.
export_artifact() {
  local v="$1" g="$2" s="$3"
  local ts name base txt png gif cast manifest note primary got
  ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
  name="${HMD_GATE_NAME:-gate-$v-$ts-$$}"
  mkdir -p "$REELS_DIR" 2>/dev/null || { REELS_DIR="${TMPDIR:-/tmp}/heimdall-reels"; mkdir -p "$REELS_DIR" 2>/dev/null || true; }
  base="$REELS_DIR/$name"
  txt="$base.txt"; png="$base.png"; gif="$base.gif"; cast="$base.cast"; manifest="$base.json"

  # 1) the .txt floor — ALWAYS. ANSI-free by construction.
  build_still "$v" "$g" "$s" > "$txt" 2>/dev/null || true
  primary="$txt"; note="text endframe (no asciinema/agg or image tooling present)"

  # 2) best available upgrade — reuse heimdall-reel's ladder: gif > (png) > txt.
  if have asciinema && have agg; then
    got="$(render_gif "$v" "$g" "$s" "$cast" "$gif" || true)"
    if [ -n "$got" ]; then
      primary="$got"
      if [ "$got" = "$gif" ]; then note="animated gif via asciinema+agg"
      else note="asciinema cast kept (agg render failed); replay with 'asciinema play'"; fi
    fi
  elif render_png "$v" "$g" "$s" "$png"; then
    primary="$png"; note="final-frame png via ${IMG_TOOL} (install asciinema+agg for an animated gif)"
  fi

  write_manifest "$manifest" "$name" "$v" "$g" "$primary" "$note" "$txt" "$png" "$gif" "$cast"

  # Print to STDERR so stdout stays the pristine animation frame (non-TTY logs
  # remain the clean single frame; the user still sees the path on the terminal).
  printf 'hmd-gate-anim: artifact → %s\n' "$primary" >&2
  printf 'hmd-gate-anim: %s\n' "$note" >&2
  [ "$primary" != "$txt" ] && printf 'hmd-gate-anim: endframe → %s\n' "$txt" >&2
  printf 'hmd-gate-anim: manifest → %s\n' "$manifest" >&2
}

should_export() {
  [ "${HMD_GATE_EXPORT:-on}" != off ] || return 1
  case "$VERDICT" in
    deny) return 0 ;;
    pass) [ "${HMD_GATE_EXPORT_PASS:-0}" = 1 ] && return 0 || return 1 ;;
    *)    [ "${HMD_GATE_EXPORT_SCAN:-0}" = 1 ] && return 0 || return 1 ;;
  esac
}

run_export() {
  should_export || return 0
  if [ "${HMD_GATE_EXPORT_ASYNC:-0}" = 1 ]; then
    ( export_artifact "$VERDICT" "$GATE" "$SEED" >/dev/null 2>&1 & )   # backgrounded, never blocks the deny
  else
    export_artifact "$VERDICT" "$GATE" "$SEED"
  fi
}

# parse_report <report.json> — reconstruct verdict/domain/seed from a falsify /
# oracle report.json (or a claim-ledger entry). Sets VERDICT/GATE/SEED. status is
# the source of truth; if absent, first_divergence decides (null = pass).
parse_report() {
  local rp="${1:-}"
  [ -n "$rp" ] && [ -f "$rp" ] || { echo "error: replay needs an existing report.json (got '${rp:-}')" >&2; exit 2; }
  local out
  out="$(python3 - "$rp" <<'PY' 2>/dev/null
import json, sys
try:
    j = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(3)
if not isinstance(j, dict):
    j = {}
status = str(j.get("status") or j.get("verdict") or j.get("result") or "").strip().lower()
PASS = {"pass", "passed", "green", "ok", "proven", "true", "success"}
DENY = {"fail", "failed", "deny", "denied", "red", "block", "blocked", "closed", "false", "error"}
if status in PASS:
    v = "pass"
elif status in DENY:
    v = "deny"
else:
    fd = j.get("first_divergence")
    v = "pass" if fd in (None, "", False) else "deny"
dom = j.get("gate_id") or j.get("domain") or j.get("gate") or j.get("surface") or "gate"
seed = j.get("haid") or j.get("seed") or j.get("agent") or "replay"
print(v)
print(dom)
print(seed)
PY
)" || { echo "error: could not parse report: $rp" >&2; exit 2; }
  [ -n "$out" ] || { echo "error: unreadable report json: $rp" >&2; exit 2; }
  VERDICT="$(printf '%s\n' "$out" | sed -n 1p)"
  GATE="$(printf '%s\n' "$out" | sed -n 2p)"
  SEED="$(printf '%s\n' "$out" | sed -n 3p)"
  [ -n "$VERDICT" ] || VERDICT="deny"
  [ -n "$GATE" ] || GATE="gate"
  [ -n "$SEED" ] || SEED="replay"
}

# ── arg parse (+ replay reconstruction) ──────────────────────────────────────
if [ "${1:-}" = replay ]; then
  parse_report "${2:-}"
  # replay is an explicit "make me a clip" — export regardless of verdict, honestly.
  : "${HMD_GATE_EXPORT:=on}"; HMD_GATE_EXPORT_PASS=1; HMD_GATE_EXPORT_SCAN=1
else
  VERDICT="${1:-pass}"; GATE="${2:-gate}"; SEED="${3:-${HMD_HAID:-you}}"
fi

# ── non-TTY collapse: one final frame, then best-effort export ───────────────
if ! is_tty; then
  face "$( [ "$VERDICT" = deny ] && echo '239;68;68' || { [ "$VERDICT" = pass ] && echo '34;197;94' || echo '245;158;11'; } )"
  final_caption
  run_export
  exit 0
fi

# ── live animation (interactive TTY) — UNCHANGED live behavior ───────────────
printf '\n'
case "$VERDICT" in
  scan|deny|pass)
    # 1) scanning track: the eyes narrow/track via an amber brightness pulse —
    #    a bright look, a steady watch, a narrowed squint. EVERY frame is a lit,
    #    visible amber eye (never blank/dark), so a still is never eyeless.
    for fr in '245;158;11' '252;205;110' '245;158;11' '200;120;20'; do
      face "$fr"; printf '  %b\n' "${AM}▸ scanning ${GATE}…${X}"; up; sleep 0.14
    done ;;
esac
case "$VERDICT" in
  deny)
    # 2) the flash: WIDE red eyes blow open — three quick beats, every frame a
    #    bright red eye (never a dark/eyeless beat), the alarm IS the eyes.
    for fr in '239;68;68' '255;130;130' '239;68;68'; do
      face "$fr"; printf '  %b\n' "${RD}${B}✗ BIFRÖST CLOSED${X}"; up; sleep 0.10
    done
    face '239;68;68'; final_caption ;;
  pass)
    # 2) settle to green, then a bright SPARKLE in the eyes (pure white) and back
    face '34;197;94'; printf '  %b\n' "${GR}…${X}"; up; sleep 0.18
    face '255;255;255'; printf '  %b\n' "${GR}✦${X}"; up; sleep 0.12
    face '34;197;94'; final_caption ;;
  scan)
    face '245;158;11'; final_caption ;;
esac
printf '\n'

# after the animation renders, write the shareable asset (best-effort).
run_export
