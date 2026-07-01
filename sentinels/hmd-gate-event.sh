#!/usr/bin/env bash
# hmd-gate-event.sh — turn a gate verdict into watchman HUD state.
#
# ONE job: when a gate decides, drive the viral statusline + (on a TTY) the
# inline deny/pass animation, and — only with explicit per-repo consent —
# heartbeat this agent onto the team watch wall.
#
#   hmd-gate-event.sh <pass|deny|scan|watching> <gate> [passed] [total]
#
#     pass     — gate proven green
#     deny     — gate blocked (the screenshot moment)
#     scan     — gate running  (mapped to "scanning" in state)
#     watching — idle / did-not-run
#
# Writes <cwd>/.heimdall/statusline.json (read by hmd-statusline.py):
#     {verdict, passed, total, gate, ts}
#
# Team presence is OPT-IN per repo: only when <cwd>/.heimdall/team/CONSENT
# exists do we write <cwd>/.heimdall/team/<haid>.json. The watchman watches
# your gates, not your team.
#
# Best-effort by contract: NEVER errors, NEVER blocks. On a non-TTY it skips
# the animation so nothing hangs; every write tolerates failure silently.
set -u

VERDICT="${1:-watching}"; GATE="${2:-gate}"; PASSED="${3:-}"; TOTAL="${4:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# ── identity: FILE-controlled via bin/heimdall-identity (the sigil SEED + the wall
# HANDLE). Falls back to heimdall-haid > HMD_HAID > USER > "you" if the bin is absent. ──
seed_fallback() {
  local h
  if [ -x "$ROOT/bin/heimdall-haid" ]; then
    h="$("$ROOT/bin/heimdall-haid" current 2>/dev/null)" && [ -n "$h" ] && { printf '%s' "$h"; return; }
  fi
  printf '%s' "${HMD_HAID:-${USER:-you}}"
}
ID_BIN="$ROOT/bin/heimdall-identity"
HAID=""; HANDLE=""
if [ -x "$ID_BIN" ]; then
  HAID="$("$ID_BIN" 2>/dev/null)" || HAID=""
  HANDLE="$("$ID_BIN" --handle 2>/dev/null)" || HANDLE=""
fi
[ -n "$HAID" ]   || HAID="$(seed_fallback)"   # SEED feeds the sigil + the heartbeat identity
[ -n "$HANDLE" ] || HANDLE="$HAID"            # HANDLE is the display name on the wall
# file-safe slug for the team heartbeat filename (haids/seeds carry ':' and '/').
SLUG="$(printf '%s' "$HAID" | tr -c 'A-Za-z0-9._-' '-')"

# ── state verdict mapping (scan -> scanning) ─────────────────────────────────
STATE_VERDICT="$VERDICT"
[ "$VERDICT" = scan ] && STATE_VERDICT="scanning"

NOW="$(date +%s 2>/dev/null || echo 0)"
DIR=".heimdall"
mkdir -p "$DIR" 2>/dev/null || true

# ── 1) statusline.json (atomic tmp+mv) ───────────────────────────────────────
write_state() {
  local out="$DIR/statusline.json" tmp="$DIR/.statusline.$$.$RANDOM"
  local pj tj
  if [ -n "$PASSED" ]; then pj="$PASSED"; else pj="null"; fi
  if [ -n "$TOTAL" ];  then tj="$TOTAL";  else tj="null"; fi
  printf '{"verdict":"%s","passed":%s,"total":%s,"gate":"%s","ts":%s}\n' \
    "$STATE_VERDICT" "$pj" "$tj" "$GATE" "$NOW" >"$tmp" 2>/dev/null \
    && mv -f "$tmp" "$out" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}
write_state

# ── 2) team heartbeat — ONLY with explicit consent ───────────────────────────
if [ -f "$DIR/team/CONSENT" ]; then
  TEAM_VERDICT="$VERDICT"
  case "$VERDICT" in
    scan) TEAM_VERDICT="working" ;;
    pass|deny|watching) : ;;
    *) TEAM_VERDICT="working" ;;
  esac
  AGENT="${HMD_AGENT:-${HMD_ROLE:-gate}}"
  out="$DIR/team/$SLUG.json"
  tmp="$DIR/team/.hb.$$.$RANDOM"
  printf '{"haid":"%s","name":"%s","agent":"%s","verdict":"%s","file":"%s","claim":"%s","ts":%s}\n' \
    "$HAID" "$HANDLE" "$AGENT" "$TEAM_VERDICT" "$GATE" "$GATE" "$NOW" >"$tmp" 2>/dev/null \
    && mv -f "$tmp" "$out" 2>/dev/null || rm -f "$tmp" 2>/dev/null
fi

# ── 3) inline animation — interactive only (non-TTY must not hang) ───────────
if [ -t 1 ]; then
  case "$VERDICT" in
    pass|deny|scan) "$HERE/hmd-gate-anim.sh" "$VERDICT" "$GATE" "$HAID" || true ;;
  esac
fi

exit 0
