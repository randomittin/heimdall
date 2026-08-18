#!/usr/bin/env bash
#
# heimdall-statusline-cursor-payload.test.sh — pins REAL captured Cursor CLI
# traffic as a regression fixture, plus two host-mapping bugs found while
# closing the live-render evidence gap on bin/heimdall-statusline.
#
# PROVENANCE (test/fixtures/cursor-real-payload.json): captured verbatim from a
# live `~/.local/bin/agent` (Cursor CLI 2026.08.11-e8db854) TUI session, driven
# under a real pty on this machine, with the user's REAL
# ~/.cursor/cli-config.json `statusLine.command` temporarily pointed at a
# logging wrapper that tee'd Cursor's actual stdin blob to disk before exec'ing
# the real renderer — then restored to the canonical registration afterward.
# This is Cursor's OWN process spawning the statusLine child exactly as it does
# in normal use, not a hand-written approximation of the schema in
# ~/.cursor/skills-cursor/statusline/SKILL.md.
#
# THIS SUITE LOCKS:
#   1. FIXTURE RENDERS — the real captured blob renders the full HUD, exit 0.
#   2. WIDTH-ZERO GUARD — the real blob's `render_width_chars` is the literal
#      integer 0 (SKILL.md documents fields that "may be absent" and "may be
#      null" but never says the field may be 0 — this is undocumented,
#      real-host behavior this suite discovered, not something SKILL.md led us
#      to expect). bin/heimdall-statusline's resolve_render_width() already
#      guards `w > 0`, so a 0 must fall through to the tput/120 fallback chain
#      exactly like an absent field — never render at a collapsed zero width.
#   3. HOST LABEL — sentinels/hmd-statusline.py's own model-name fallback (when
#      model.display_name is absent) defaults to the literal string "Claude", a
#      holdover from when Claude Code was this bar's only host. That file is
#      out of this suite's scope to edit, so bin/heimdall-statusline normalizes
#      the blob at the boundary: under a detected-Cursor payload
#      (transcript_path/autorun present — both Cursor-exclusive per SKILL.md)
#      with no usable model.display_name, it injects "Cursor" before handing
#      the blob to the watchman, so the wrong-host label never reaches the
#      screen. A real, populated display_name (e.g. the "Auto" this suite's own
#      fixture carries) must pass through byte-unchanged, and a genuine Claude
#      Code payload (no transcript_path/autorun) must be completely unaffected
#      — still defaulting to "Claude", which is correct there.
#   4. TIMING — the real fixture renders with real margin under Cursor's
#      documented default timeoutMs (2000ms; ~/.cursor/skills-cursor/statusline/
#      SKILL.md — a non-zero exit past this kills the in-flight process).
#
# FALSIFIER (verified by hand — see the coder-agent report for this task, which
# quotes the exact pass/fail counts both ways): comment out the Cursor
# host-label normalization block in bin/heimdall-statusline -> section 3's
# "absent display_name -> Cursor" assertion goes RED (renders "Claude"
# instead); restoring the block returns it to GREEN with no other section
# affected.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-statusline"
FIXTURE="$ROOT/test/fixtures/cursor-real-payload.json"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || {
  echo "SKIP: python3 unavailable"
  echo "heimdall-statusline-cursor-payload: 0 passed, 0 failed (SKIPPED — python3 unavailable)"
  exit 0
}
[ -x "$CLI" ]     || { echo "FATAL: $CLI missing/not executable"; echo "heimdall-statusline-cursor-payload: 0 passed, 1 failed"; exit 1; }
[ -f "$FIXTURE" ] || { echo "FATAL: $FIXTURE missing"; echo "heimdall-statusline-cursor-payload: 0 passed, 1 failed"; exit 1; }

# ── a hermetic workspace, same shape as heimdall-statusline-parity.test.sh's
# mkws() — the fixture's own JSON `cwd` is a real absolute path on the machine
# it was captured on (display text only: repo_str falls back to a pure
# os.path.basename() string op, never a filesystem read), but every actual
# filesystem read the renderer performs (identity, gate verdict, roster) is
# driven by these env vars, not by the blob, so overriding them keeps the test
# hermetic and machine-independent regardless of what the fixture's cwd says. ──
mkws() {
  ws="$(mktemp -d)"; homed="$(mktemp -d)"; tmpd="$(mktemp -d)"
  mkdir -p "$ws/.heimdall"
  printf '{"handle":"rj","seed":"rj","created":0}\n' > "$ws/.heimdall/identity.json"
  printf '{"verdict":"pass","passed":3,"total":3}\n' > "$ws/.heimdall/statusline.json"
  : > "$ws/.heimdall/.beat-stamp"
  : > "$ws/.heimdall/.wall-cache.json.lock"
  printf '%s|%s|%s' "$ws" "$homed" "$tmpd"
}

render() {  # $1=ws $2=homed $3=tmpd $4=cols(""=unset) $5=json -> stdout
  # Deliberately NOT self-contained (no mkws/cleanup in here): a command
  # substitution `$(render ...)` runs in a SUBSHELL, so any `rc=$?` captured
  # AFTER the render's own last command but INSIDE this function would be lost
  # the instant that subshell exits — the caller's `$?` right after
  # `OUT="$(render ...)"` needs to see render's OWN exit status, unshadowed by
  # a trailing `rm -rf`. Workspace lifecycle is the caller's job (same split as
  # heimdall-statusline-parity.test.sh's render()/loop pairing).
  ws="$1"; homed="$2"; tmpd="$3"; cols="$4"; json="$5"
  # No bash arrays here (not `"${arr[@]}"`-safe under `set -u` on bash 3.2, this
  # repo's floor — an empty array expansion is an "unbound variable" there) — two
  # explicit branches instead of a conditionally-built COLUMNS arg.
  if [ -n "$cols" ]; then
    printf '%s' "$json" | env -i PATH="$PATH" HOME="$homed" LANG=en_US.UTF-8 \
        HEIMDALL_IDENTITY_DIR="$ws/.heimdall" HMD_HAID=rj HMD_NOW=1752410000 \
        HEIMDALL_CP_URL="http://127.0.0.1:1" TERM=xterm-256color COLUMNS="$cols" \
        HMD_STATUSLINE_TMP="$tmpd" HEIMDALL_STATUSLINE_MODE=truecolor \
        bash "$CLI"
  else
    printf '%s' "$json" | env -i PATH="$PATH" HOME="$homed" LANG=en_US.UTF-8 \
        HEIMDALL_IDENTITY_DIR="$ws/.heimdall" HMD_HAID=rj HMD_NOW=1752410000 \
        HEIMDALL_CP_URL="http://127.0.0.1:1" TERM=xterm-256color \
        HMD_STATUSLINE_TMP="$tmpd" HEIMDALL_STATUSLINE_MODE=truecolor \
        bash "$CLI"
  fi
}

# visual column width per row, ANSI stripped, wide-glyph aware — same algorithm
# as heimdall-statusline-parity.test.sh's CURSOR WIDTH section (section 2).
row_widths() {
  python3 -c 'import sys,re
A=re.compile(r"\033\[[0-9;]*m")
def w(l):
  s=A.sub("",l); n=0
  for ch in s:
    o=ord(ch)
    if o in (0x200B,0x200D,0xFE0F) or 0x0300<=o<=0x036F: continue
    n += 2 if (o==0x26A1 or 0x1100<=o<=0x115F or 0x2E80<=o<=0x303E or 0x3041<=o<=0x33FF or 0x3400<=o<=0x4DBF or 0x4E00<=o<=0x9FFF or 0xAC00<=o<=0xD7A3 or 0x1F000<=o<=0x1FAFF) else 1
  return n
ws=sorted(set(w(l) for l in sys.stdin.read().split(chr(10)) if l!=""))
print(",".join(str(x) for x in ws))'
}

FIXTURE_JSON="$(cat "$FIXTURE")"

echo "== 1) FIXTURE RENDERS: real captured Cursor payload -> full HUD, exit 0 =="
TRIPLE="$(mkws)"; IFS='|' read -r WS HOMED TMPD <<<"$TRIPLE"
OUT="$(render "$WS" "$HOMED" "$TMPD" "" "$FIXTURE_JSON")"; RC=$?
rm -rf "$WS" "$HOMED" "$TMPD"
LC="$(printf '%s\n' "$OUT" | grep -c .)"
[ "$RC" = 0 ] && ok "real fixture: exits 0" || bad "real fixture: exit $RC"
[ "$LC" -gt 1 ] 2>/dev/null && ok "real fixture: renders the full multi-row HUD ($LC rows)" \
                            || bad "real fixture: only $LC row(s) — degraded instead of full render"
case "$OUT" in
  *HEIMDALL*) ok "real fixture: HEIMDALL brand present" ;;
  *) bad "real fixture: HEIMDALL brand missing from output" ;;
esac

echo "== 2) WIDTH-ZERO GUARD: render_width_chars:0 must NOT collapse width to 0 =="
# 2a) minimal synthetic payload isolating the exact field this guards.
ZERO_J='{"session_id":"zw","transcript_path":"/x","autorun":false,"cwd":"/tmp","workspace":{"current_dir":"/tmp"},"render_width_chars":0,"model":{"display_name":"Auto"},"context_window":{"used_percentage":null}}'
TRIPLE="$(mkws)"; IFS='|' read -r WS HOMED TMPD <<<"$TRIPLE"
OUT="$(render "$WS" "$HOMED" "$TMPD" "" "$ZERO_J")"; RC=$?
rm -rf "$WS" "$HOMED" "$TMPD"
WIDTHS="$(printf '%s\n' "$OUT" | row_widths)"
[ "$RC" = 0 ] && ok "render_width_chars=0 (synthetic): exits 0" || bad "render_width_chars=0 (synthetic): exit $RC"
if [ "$WIDTHS" = "0" ] || [ -z "$WIDTHS" ]; then
  bad "render_width_chars=0 (synthetic): rows collapsed to width {$WIDTHS} — the w>0 guard did not fall through to a safe default"
else
  ok "render_width_chars=0 (synthetic): falls through to a safe non-zero width ({$WIDTHS}, COLUMNS unset -> tput/120 default)"
fi
# 2b) the REAL captured fixture — same field, real bytes, strongest evidence.
TRIPLE="$(mkws)"; IFS='|' read -r WS HOMED TMPD <<<"$TRIPLE"
OUT="$(render "$WS" "$HOMED" "$TMPD" "" "$FIXTURE_JSON")"; RC=$?
rm -rf "$WS" "$HOMED" "$TMPD"
WIDTHS="$(printf '%s\n' "$OUT" | row_widths)"
if [ "$WIDTHS" = "0" ] || [ -z "$WIDTHS" ]; then
  bad "render_width_chars=0 (real fixture): rows collapsed to width {$WIDTHS}"
else
  ok "render_width_chars=0 (real fixture): falls through to a safe non-zero width ({$WIDTHS})"
fi

echo "== 3) HOST LABEL: Cursor payload never shows the Claude Code default =="
# 3a) Cursor-shaped (transcript_path present), model omitted entirely.
NOMODEL_J='{"session_id":"hl1","transcript_path":"/x","autorun":false,"cwd":"/tmp","workspace":{"current_dir":"/tmp"},"render_width_chars":120,"context_window":{"used_percentage":null}}'
TRIPLE="$(mkws)"; IFS='|' read -r WS HOMED TMPD <<<"$TRIPLE"
OUT="$(render "$WS" "$HOMED" "$TMPD" "" "$NOMODEL_J")"
rm -rf "$WS" "$HOMED" "$TMPD"
case "$OUT" in
  *"· Cursor"*) ok "cursor, no model field: labeled Cursor" ;;
  *"· Claude"*) bad "cursor, no model field: mislabeled Claude (host-label fix regressed)" ;;
  *) bad "cursor, no model field: no model label found at all — unexpected output" ;;
esac
# 3b) Cursor-shaped WITH a real display_name (the fixture's own shape: "Auto")
#     — must pass through unchanged, proving the normalizer never overwrites
#     real data.
TRIPLE="$(mkws)"; IFS='|' read -r WS HOMED TMPD <<<"$TRIPLE"
OUT="$(render "$WS" "$HOMED" "$TMPD" "" "$FIXTURE_JSON")"
rm -rf "$WS" "$HOMED" "$TMPD"
case "$OUT" in
  *"· Auto"*) ok "cursor, model.display_name=Auto (real fixture): passes through unchanged" ;;
  *"· Cursor"*) bad "cursor, model.display_name=Auto (real fixture): normalizer overwrote real data with the fallback" ;;
  *) bad "cursor, model.display_name=Auto (real fixture): no model label found in output" ;;
esac
# 3c) genuine Claude-Code-shaped payload (no transcript_path/autorun) is
#     completely unaffected — still defaults to "Claude", which is correct
#     there. Forced wide so the model segment isn't a width-budget casualty
#     (see the coder-agent report: this is a pre-existing, unrelated behavior
#     of row1_left()'s greedy fit, not something this suite is pinning).
CC_J='{"session_id":"hl3","cwd":"/tmp","workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":12.5}}'
TRIPLE="$(mkws)"; IFS='|' read -r WS HOMED TMPD <<<"$TRIPLE"
OUT="$(render "$WS" "$HOMED" "$TMPD" 200 "$CC_J")"
rm -rf "$WS" "$HOMED" "$TMPD"
case "$OUT" in
  *"· Claude"*) ok "claude code, no model field: still defaults to Claude (legacy unchanged)" ;;
  *) bad "claude code, no model field: expected the legacy Claude default, got something else" ;;
esac

echo "== 4) TIMING: real fixture render time vs Cursor's default timeoutMs (2000ms) =="
TIMING="$(FIXTURE_JSON="$FIXTURE_JSON" CLI="$CLI" python3 - <<'PY'
import os, subprocess, tempfile, time, statistics
json_blob = os.environ["FIXTURE_JSON"]
cli = os.environ["CLI"]
ws = tempfile.mkdtemp(); home = tempfile.mkdtemp(); tmp = tempfile.mkdtemp()
os.makedirs(ws + "/.heimdall", exist_ok=True)
open(ws + "/.heimdall/identity.json", "w").write('{"handle":"rj","seed":"rj","created":0}\n')
open(ws + "/.heimdall/statusline.json", "w").write('{"verdict":"pass","passed":3,"total":3}\n')
open(ws + "/.heimdall/.beat-stamp", "w").close()
open(ws + "/.heimdall/.wall-cache.json.lock", "w").close()
env = dict(os.environ, HOME=home, HEIMDALL_IDENTITY_DIR=ws + "/.heimdall", HMD_HAID="rj",
           HMD_NOW="1752410000", HEIMDALL_CP_URL="http://127.0.0.1:1", TERM="xterm-256color",
           HMD_STATUSLINE_TMP=tmp, HEIMDALL_STATUSLINE_MODE="truecolor")
env.pop("COLUMNS", None)
ts = []
for _ in range(15):
    t0 = time.perf_counter()
    subprocess.run(["bash", cli], input=json_blob, capture_output=True, text=True, env=env)
    ts.append((time.perf_counter() - t0) * 1000)
print("%.3f %.3f" % (statistics.median(ts), max(ts)))
PY
)"
MED="${TIMING%% *}"; MX="${TIMING##* }"
BUDGET_MS=1000
MARGIN_PCT="$(python3 -c "print('%.1f' % ((2000.0-$MED)/2000.0*100))")"
echo "  render (real fixture, full subprocess path) median=${MED}ms max=${MX}ms — Cursor default timeoutMs=2000ms (${MARGIN_PCT}% margin at median)"
python3 -c "import sys; sys.exit(0 if float('$MED') < $BUDGET_MS else 1)" \
  && ok "median render ${MED}ms < ${BUDGET_MS}ms (half of Cursor's 2000ms default timeoutMs)" \
  || bad "median render ${MED}ms exceeds the ${BUDGET_MS}ms safety-margin budget"
python3 -c "import sys; sys.exit(0 if float('$MX') < 2000.0 else 1)" \
  && ok "max render ${MX}ms < Cursor's 2000ms default timeoutMs" \
  || bad "max render ${MX}ms would be KILLED by Cursor's default timeoutMs"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
