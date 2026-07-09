#!/usr/bin/env bash
# heimdall-watch-live.test.sh — FALSIFIER: `hmd watch` is a LIVE wall with ZERO extra deps.
#
# THE BUG (blocking the headline presence demo): `hmd watch` needed `textual` for a live
# TUI. Installing textual reliably defeats real users — `pipx install textual` lands in an
# ISOLATED venv hmd's python3 can't import from, and modern PEP-668 macOS python rejects a
# plain `pip install`. So watch fell back to a SINGLE static one-shot dump (one beat, no
# refresh) → no live wall → the 2-person presence demo was blocked.
#
# THE FIX (two parts):
#   PART 1 — a no-textual auto-refresh LIVE mode. With textual ABSENT, interactive
#     `hmd watch` (a TTY) runs a lightweight loop that clears the screen and re-renders the
#     wall+feed every ~2s AND emits the presence beat each cycle — a live, self-beating wall
#     with ZERO extra dependencies. Ctrl-C / cap restores the terminal. `--once` still gives
#     the single static dump for scripting; a NON-TTY (pipe/CI) degrades to a single dump,
#     NEVER an infinite loop. Textual, when importable, stays the ENHANCED path.
#   PART 2 — an interpreter-aware, PEP-668-aware install hint. Instead of the bogus
#     `pip install textual`, watch prints the EXACT interpreter (sys.executable) + a
#     PEP-668-aware command (`--user`, `--break-system-packages` when externally-managed).
#     NEVER `pipx install textual` (isolated).
#
# HERMETIC: no network, no textual required. Textual-absence is FORCED via
# HEIMDALL_WATCH_FORCE_NO_TEXTUAL so this runs identically whether or not textual is
# installed. The loop is driven with an injected cap (HEIMDALL_WATCH_MAX_CYCLES) + a zero
# clock (HEIMDALL_WATCH_INTERVAL=0) + a forced TTY (HEIMDALL_WATCH_ASSUME_TTY) so it NEVER
# hangs. The beat is an injected stub (HEIMDALL_PRESENCE_BIN) that logs each dispatch.
#
# Exit 0 = "N passed, 0 failed".

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/bin/heimdall-watch-tui"
DATA="$ROOT/bin/lib/watch_data.py"
ENTRY="$ROOT/bin/lib/watch_entry.py"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t watch-live.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$BIN" ]   || { echo "FATAL: $BIN missing" >&2; exit 2; }
[ -f "$DATA" ]  || { echo "FATAL: $DATA missing" >&2; exit 2; }
[ -f "$ENTRY" ] || { echo "FATAL: $ENTRY missing" >&2; exit 2; }
chmod +x "$BIN" 2>/dev/null || true

# ── compile ──────────────────────────────────────────────────────────────────
bash -n "$BIN" 2>/dev/null && ok "heimdall-watch-tui passes bash -n" || bad "heimdall-watch-tui FAILS bash -n"
"$PY" -m py_compile "$DATA" "$ENTRY" 2>/tmp/wl_pyc.txt \
  && ok "watch_data + watch_entry py_compile clean" \
  || { bad "py_compile FAILED"; cat /tmp/wl_pyc.txt; }

# ── fixture repo + beat stub ──────────────────────────────────────────────────
REPO="$WORK/repo"; mkdir -p "$REPO/.heimdall"
export HEIMDALL_HOME="$WORK/home"; mkdir -p "$HEIMDALL_HOME"

cat > "$REPO/.heimdall/roster-cache.json" <<'JSON'
{"team":"acme","members":[
  {"handle":"you","haid":"haid:rj-a3f9","verdict":"PASS","file":"api.py","age_seconds":5},
  {"handle":"K","haid":"haid:nadia","verdict":"DENY","file":"auth.py","age_seconds":42}
]}
JSON
cat > "$REPO/.heimdall/feed.jsonl" <<'JSON'
{"ts":1700000135,"verdict":"PASS","kind":"merge","ref":"a3f1b2","haid":"haid:rj-a3f9","handle":"you","summary":"merge proven"}
JSON

BEATLOG="$WORK/beat.log"; : > "$BEATLOG"
BEAT_STUB="$WORK/heimdall-presence"
cat > "$BEAT_STUB" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BEATLOG"
exit 0
SH
chmod +x "$BEAT_STUB"

# has a hang-guard timeout if available (the cycle cap already bounds the loop).
TIMEOUT="$(command -v timeout || command -v gtimeout || true)"
guard() { if [ -n "$TIMEOUT" ]; then "$TIMEOUT" 30 "$@"; else "$@"; fi; }

CYCLES=3

# ── (1) LIVE LOOP: textual ABSENT + TTY re-renders >1 AND beats >1 (no hang) ──────────
: > "$BEATLOG"
LIVE="$(guard env \
    HEIMDALL_WATCH_FORCE_NO_TEXTUAL=1 HEIMDALL_WATCH_ASSUME_TTY=1 \
    HEIMDALL_WATCH_MAX_CYCLES="$CYCLES" HEIMDALL_WATCH_INTERVAL=0 \
    HEIMDALL_WATCH_ROOT="$REPO" HEIMDALL_HOME="$HEIMDALL_HOME" \
    HEIMDALL_PRESENCE_BIN="$BEAT_STUB" \
    NO_COLOR=1 HEIMDALL_STATUSLINE_MODE=mono \
    "$BIN" 2>&1)"
LRC=$?
WALLS="$(printf '%s' "$LIVE" | grep -ac 'WALL')"
BEATS="$(grep -c . "$BEATLOG" 2>/dev/null || echo 0)"

[ "$LRC" -eq 0 ] && ok "(1) live loop exits 0 (cap reached, no hang)" || bad "(1) live loop rc=$LRC"
[ "${WALLS:-0}" -gt 1 ] \
  && ok "(1) no-textual loop RE-RENDERED the wall >1 time ($WALLS renders over $CYCLES cycles — not a one-shot)" \
  || bad "(1) loop did not re-render (WALL count=$WALLS) — still a static one-shot"
[ "${WALLS:-0}" -eq "$CYCLES" ] \
  && ok "(1) render count matches the cycle cap ($WALLS == $CYCLES)" \
  || bad "(1) render count $WALLS != cap $CYCLES"
[ "${BEATS:-0}" -gt 1 ] \
  && ok "(1) loop EMITTED a presence beat each cycle >1 ($BEATS beats — self-beating live wall)" \
  || bad "(1) loop beat <=1 time ($BEATS) — not self-beating"
[ "${BEATS:-0}" -eq "$CYCLES" ] \
  && ok "(1) beat count matches the cycle cap ($BEATS == $CYCLES)" \
  || bad "(1) beat count $BEATS != cap $CYCLES"

# ── (2) LIVE LOOP restores the terminal (cursor) + uses an ANSI clear each cycle ──────
printf '%s' "$LIVE" | grep -qa $'\033\[?25h' \
  && ok "(2) live loop restores the cursor on exit (ESC[?25h — terminal restored)" \
  || bad "(2) live loop did NOT restore the cursor"
CLEARS="$(printf '%s' "$LIVE" | grep -oa $'\033\[2J' | grep -c .)"
[ "${CLEARS:-0}" -gt 1 ] \
  && ok "(2) live loop clears the screen each cycle (ESC[2J x$CLEARS — auto-refresh reprint)" \
  || bad "(2) live loop did not clear-screen per cycle (count=$CLEARS)"
printf '%s' "$LIVE" | grep -qa 'LIVE ·' \
  && ok "(2) live loop shows the LIVE footer" \
  || bad "(2) live loop missing the LIVE footer"

# ── (3) --once STILL one-shots (single static dump; NOT the loop) ─────────────────────
: > "$BEATLOG"
ONCE="$(guard env \
    HEIMDALL_WATCH_FORCE_NO_TEXTUAL=1 HEIMDALL_WATCH_ASSUME_TTY=1 \
    HEIMDALL_WATCH_ROOT="$REPO" HEIMDALL_HOME="$HEIMDALL_HOME" \
    HEIMDALL_PRESENCE_BIN="$BEAT_STUB" \
    NO_COLOR=1 HEIMDALL_STATUSLINE_MODE=mono \
    "$BIN" --once 2>&1)"
ORC=$?
OWALLS="$(printf '%s' "$ONCE" | grep -ac 'WALL')"
OBEATS="$(grep -c . "$BEATLOG" 2>/dev/null || echo 0)"
[ "$ORC" -eq 0 ] && ok "(3) --once exits 0" || bad "(3) --once rc=$ORC"
[ "${OWALLS:-0}" -eq 1 ] \
  && ok "(3) --once renders the wall EXACTLY once (single static dump, not the loop)" \
  || bad "(3) --once rendered $OWALLS walls (expected 1)"
printf '%s' "$ONCE" | grep -qa 'LIVE ·' \
  && bad "(3) --once entered the live loop (LIVE footer present) — must stay a one-shot" \
  || ok "(3) --once is NOT the live loop (no LIVE footer)"
[ "${OBEATS:-0}" -eq 1 ] \
  && ok "(3) --once beats exactly once" \
  || bad "(3) --once beat $OBEATS times (expected 1)"

# ── (4) NON-TTY guard: piped/CI degrades to a single dump, NEVER an infinite loop ─────
: > "$BEATLOG"
NOTTY="$(guard env \
    HEIMDALL_WATCH_FORCE_NO_TEXTUAL=1 HEIMDALL_WATCH_ASSUME_NOTTY=1 \
    HEIMDALL_WATCH_ROOT="$REPO" HEIMDALL_HOME="$HEIMDALL_HOME" \
    HEIMDALL_PRESENCE_BIN="$BEAT_STUB" \
    NO_COLOR=1 HEIMDALL_STATUSLINE_MODE=mono \
    "$BIN" 2>&1)"
NRC=$?
NWALLS="$(printf '%s' "$NOTTY" | grep -ac 'WALL')"
[ "$NRC" -eq 0 ] && ok "(4) non-TTY exits 0 (no hang)" || bad "(4) non-TTY rc=$NRC"
[ "${NWALLS:-0}" -eq 1 ] \
  && ok "(4) non-TTY (pipe/CI) is a SINGLE static dump (never an infinite loop)" \
  || bad "(4) non-TTY rendered $NWALLS walls (expected 1 — must not loop)"
printf '%s' "$NOTTY" | grep -qa 'LIVE ·' \
  && bad "(4) non-TTY entered the live loop — a pipe must never loop" \
  || ok "(4) non-TTY did NOT enter the live loop"

# ── (5) _choose_mode: the branch selector is correct for all 5 modes ──────────────────
MODES="$("$PY" - "$ENTRY" <<'PY' 2>&1
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("we", sys.argv[1])
we = importlib.util.module_from_spec(spec); spec.loader.exec_module(we)
def A(once=False, install_tui=False):
    return types.SimpleNamespace(once=once, install_tui=install_tui, pane=False)
print("install_tui", we._choose_mode(A(install_tui=True), True,  True))
print("once",        we._choose_mode(A(once=True),        False, True))
print("textual",     we._choose_mode(A(),                 True,  True))
print("live",        we._choose_mode(A(),                 False, True))
print("dump",        we._choose_mode(A(),                 False, False))
PY
)"
chkmode() { printf '%s' "$MODES" | grep -qx "$1 $2" && ok "(5) mode select: $1 -> $2" || { bad "(5) mode $1 != $2"; printf '%s\n' "$MODES" | sed 's/^/      /'; }; }
chkmode install_tui install_tui
chkmode once once
chkmode textual textual
chkmode live live
chkmode dump dump

# ── (6) interpreter-aware, PEP-668-aware install hint (PART 2) ─────────────────────────
HINT="$("$PY" - "$DATA" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wd", sys.argv[1])
wd = importlib.util.module_from_spec(spec); spec.loader.exec_module(wd)
print("HINT " + wd.textual_install_hint({}))
print("EXE " + (sys.executable or ""))
# simulate an externally-managed interpreter -> the --break-system-packages escape appears
wd._externally_managed = lambda: True
print("MANAGED " + wd.textual_install_hint({}))
PY
)"
EXE_LINE="$(printf '%s' "$HINT" | sed -n 's/^EXE //p')"
printf '%s' "$HINT" | grep -qa 'HINT .*-m pip install .*textual' \
  && ok "(6) hint targets '<python> -m pip install ... textual' (PEP-668 safe)" \
  || { bad "(6) hint is not a '-m pip install textual' form"; printf '%s\n' "$HINT" | sed 's/^/      /'; }
printf '%s' "$HINT" | grep -qaF "HINT $EXE_LINE" \
  && ok "(6) hint targets hmd-watch's EXACT interpreter (sys.executable=$EXE_LINE)" \
  || { bad "(6) hint does NOT target sys.executable"; printf '%s\n' "$HINT" | sed 's/^/      /'; }
printf '%s' "$HINT" | grep -qai 'pipx' \
  && bad "(6) hint suggests pipx (isolated venv — hmd's python can't import it)" \
  || ok "(6) hint NEVER suggests pipx (avoids the isolation footgun)"
printf '%s' "$HINT" | grep -qa 'MANAGED .*--break-system-packages' \
  && ok "(6) externally-managed (PEP-668) hint carries --break-system-packages" \
  || { bad "(6) externally-managed hint missing --break-system-packages"; printf '%s\n' "$HINT" | sed 's/^/      /'; }

# ── (7) the textual-absent DUMP trailer uses the interpreter-aware hint (not bare pip) ─
printf '%s' "$ONCE" | grep -qa 'textual not installed' \
  && ok "(7) textual-absent dump explains textual is not installed" \
  || bad "(7) textual-absent dump missing the not-installed line"
printf '%s' "$ONCE" | grep -qa '\-m pip install' && printf '%s' "$ONCE" | grep -qa 'textual' \
  && ok "(7) textual-absent dump prints the interpreter-aware install hint" \
  || bad "(7) textual-absent dump missing the interpreter-aware hint"

# ── (8) --install-tui argv installs into hmd's OWN interpreter (not pipx) ──────────────
INST="$("$PY" - "$ENTRY" "$DATA" <<'PY' 2>&1
import importlib.util, sys
we_spec = importlib.util.spec_from_file_location("we", sys.argv[1])
we = importlib.util.module_from_spec(we_spec); we_spec.loader.exec_module(we)
wd_spec = importlib.util.spec_from_file_location("wd", sys.argv[2])
wd = importlib.util.module_from_spec(wd_spec); wd_spec.loader.exec_module(wd)
argv = we._install_tui_argv(wd)
print("ARGV " + " ".join(argv))
print("EXE " + (sys.executable or ""))
PY
)"
IEXE="$(printf '%s' "$INST" | sed -n 's/^EXE //p')"
printf '%s' "$INST" | grep -qaF "ARGV $IEXE -m pip install --user textual" \
  && ok "(8) --install-tui targets hmd's own interpreter: $IEXE -m pip install --user textual" \
  || { bad "(8) --install-tui argv wrong"; printf '%s\n' "$INST" | sed 's/^/      /'; }
printf '%s' "$INST" | grep -qai 'pipx' \
  && bad "(8) --install-tui uses pipx (isolated)" \
  || ok "(8) --install-tui never uses pipx"

# ── (9) the no-textual fallback path depends on NO textual at all ─────────────────────
if grep -qE '^[[:space:]]*(import[[:space:]]+textual|from[[:space:]]+textual)' "$ENTRY" "$DATA"; then
  bad "(9) the fallback path (watch_entry/watch_data) imports textual — not a zero-dep fallback"
else
  ok "(9) fallback path imports NO textual (watch_entry + watch_data are textual-free)"
fi

# ── summary ───────────────────────────────────────────────────────────────────
printf "\n  Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
