#!/usr/bin/env bash
#
# heimdall-statusline-parity.test.sh — ONE SOURCE OF TRUTH, not two copies that
# drift. Claude Code's registered hooks/statusline.sh and the CLI-AGNOSTIC
# bin/heimdall-statusline (callable from any shell, and what Cursor CLI's own
# statusLine hook is registered against — bin/heimdall-statusline-register-cursor)
# must render BYTE-IDENTICAL output for identical input, because hooks/statusline.sh
# is now nothing but `exec bin/heimdall-statusline "$@"`.
#
# THIS SUITE LOCKS:
#   1. PARITY — for the SAME stdin blob + COLUMNS + env, hooks/statusline.sh and
#      bin/heimdall-statusline emit byte-identical stdout and the same exit code,
#      solo and with a team, at two different widths.
#   2. CURSOR WIDTH — Cursor's statusLine payload carries the usable width as a
#      JSON field (render_width_chars) instead of Claude Code's $COLUMNS env var
#      (~/.cursor/skills-cursor/statusline/SKILL.md: "usable terminal columns
#      minus built-in padding"). With $COLUMNS UNSET, bin/heimdall-statusline
#      reads render_width_chars from stdin and renders EXACTLY that width (no
#      double-reserve — Claude Code's undocumented 4-cell CC_REGION_RESERVE must
#      NOT also apply to a width Cursor already corrected on its own side).
#   3. MANUAL/TTY — a bare interactive run (`hmd status`, a REAL controlling tty,
#      NOTHING piped) renders the full multi-row null-safe HUD, not just the
#      1-line `⛭ HEIMDALL` placeholder (Spec: "a valid but empty {} -> the full
#      null-safe render").
#   4. PIPED-EMPTY UNCHANGED — a harness that deliberately pipes empty stdin
#      (a non-tty pipe, e.g. a CI runner or a misbehaving caller) still gets the
#      EXISTING, already-tested Spec v2 §8.4 branded-floor fallback — proving the
#      new tty-only richer path did not regress the old, locked contract.
#   5. NEVER-ERROR — every path above exits 0.
#
# FALSIFIER (verified by hand during development, not re-run here to keep this
# suite's runtime bounded): point hooks/statusline.sh at a second, independently
# maintained copy of the render logic instead of `exec`-delegating to
# bin/heimdall-statusline -> assertion set 1 goes RED the moment the two copies
# disagree on so much as one byte.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOK="$ROOT/hooks/statusline.sh"
CLI="$ROOT/bin/heimdall-statusline"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || {
  echo "SKIP: python3 unavailable"
  echo "heimdall-statusline-parity: 0 passed, 0 failed (SKIPPED — python3 unavailable)"
  exit 0
}
[ -x "$HOOK" ] || { echo "FATAL: $HOOK missing/not executable"; echo "heimdall-statusline-parity: 0 passed, 1 failed"; exit 1; }
[ -x "$CLI" ]  || { echo "FATAL: $CLI missing/not executable (bin/heimdall-statusline)"; echo "heimdall-statusline-parity: 0 passed, 1 failed"; exit 1; }

# ── a hermetic workspace: fixed identity + legacy verdict + (optional) team roster ──
mkws() {
  ws="$(mktemp -d)"; homed="$(mktemp -d)"; tmpd="$(mktemp -d)"
  mkdir -p "$ws/.heimdall"
  printf '{"handle":"rj","seed":"rj","created":0}\n' > "$ws/.heimdall/identity.json"
  printf '{"verdict":"pass","passed":3,"total":3}\n' > "$ws/.heimdall/statusline.json"
  if [ "$1" = team ]; then
    printf '%s\n' '[{"handle":"nadia","haid":"haid:nadia","verdict":"working","file":"auth.ts","age_seconds":4},{"handle":"arjun","haid":"haid:arjun","verdict":"watching","file":"db.go","age_seconds":9},{"handle":"priya","haid":"haid:priya","verdict":"deny","file":"api.py","age_seconds":6}]' \
      > "$ws/.heimdall/.roster-cache.json"
  fi
  # Pre-seed the throttle files _spawn_presence() (sentinels/hmd-statusline.py) checks
  # BEFORE forking its detached background refresh child (beat-stamp <20s fresh, wall
  # lock <120s fresh -> both due-checks False -> zero forks, per that function's own
  # "stat-only is-it-due gates -> ZERO forks when throttled" contract). Root-caused by
  # hand: without this, render #1 of a `team` workspace leaves roster_due/beat_due
  # false (our roster-cache.json is already fresh) but wall_due TRUE (no wall cache
  # exists yet) -> a detached `repo_roster.py --repo $ws --blocking` child fires,
  # writes .heimdall/.wall-cache.json + .repo-roster-*.json asynchronously, and can
  # complete before render #2 of the SAME workspace -> the second render's team merge
  # picks up the freshly-appeared wall cache and renders different member hues than
  # the first -> two renders of "the same input" silently stop being the same input.
  # Confirmed via direct repro: two consecutive bin/heimdall-statusline calls (no
  # hook involved at all) drifted identically, proving this is a pre-existing
  # property of the untouched renderer's own fire-and-forget cache warm, not a
  # hook-vs-cli routing bug — so the fix belongs here, in the test's own hermeticity,
  # never in sentinels/hmd-statusline.py.
  : > "$ws/.heimdall/.beat-stamp"
  : > "$ws/.heimdall/.wall-cache.json.lock"
  printf '%s|%s|%s' "$ws" "$homed" "$tmpd"
}

canned() {  # $1=cwd $2=cols -> a Claude-Code-shaped statusLine JSON blob
  printf '{"workspace":{"current_dir":"%s","repo":{"name":"heimdall","branch":"parity"}},"model":{"display_name":"Opus 4.8"},"context_window":{"used_percentage":55,"total_input_tokens":256000},"cost":{"total_cost_usd":1.23,"total_duration_ms":1800000},"rate_limits":{"five_hour":{"used_percentage":28,"resets_at":1752417200},"seven_day":{"used_percentage":41}},"session_id":"parity-%s"}' "$1" "$2"
}

# render via either entry point ($1=hook|cli). Fixed clock, unreachable CP, no
# team-refresh forks, env -i hermetic — the two paths share EVERY env value.
render() {
  via="$1"; cwd="$2"; homed="$3"; tmpd="$4"; cols="$5"; json="$6"
  bin="$HOOK"; [ "$via" = cli ] && bin="$CLI"
  printf '%s' "$json" | env -i PATH="$PATH" HOME="$homed" LANG=en_US.UTF-8 \
      HEIMDALL_IDENTITY_DIR="$cwd/.heimdall" HMD_HAID=rj HMD_NOW=1752410000 \
      HEIMDALL_CP_URL="http://127.0.0.1:1" COLUMNS="$cols" TERM=xterm-256color \
      HMD_STATUSLINE_TMP="$tmpd" HEIMDALL_STATUSLINE_MODE=truecolor \
      bash "$bin"
}

echo "== 1) PARITY: hooks/statusline.sh == bin/heimdall-statusline, byte-identical =="
for team in solo team; do
  for cols in 60 120; do
    TRIPLE="$(mkws "$team")"
    IFS='|' read -r WS HOMED TMPD <<<"$TRIPLE"
    J="$(canned "$WS" "$cols")"
    OUT_HOOK="$(render hook "$WS" "$HOMED" "$TMPD" "$cols" "$J")"; RC_HOOK=$?
    OUT_CLI="$(render cli  "$WS" "$HOMED" "$TMPD" "$cols" "$J")"; RC_CLI=$?
    rm -rf "$WS" "$HOMED" "$TMPD"
    if [ "$OUT_HOOK" = "$OUT_CLI" ] && [ "$RC_HOOK" = 0 ] && [ "$RC_CLI" = 0 ]; then
      ok "parity: $team @${cols}c — hooks/statusline.sh == bin/heimdall-statusline (exit 0/0)"
    else
      bad "parity DRIFT: $team @${cols}c — outputs differ or nonzero exit (hook_rc=$RC_HOOK cli_rc=$RC_CLI)"
    fi
  done
done

echo "== 2) CURSOR WIDTH: render_width_chars (JSON) drives width with \$COLUMNS unset =="
TRIPLE="$(mkws solo)"
IFS='|' read -r WS HOMED TMPD <<<"$TRIPLE"
CURSOR_J="{\"cwd\":\"$WS\",\"workspace\":{\"current_dir\":\"$WS\"},\"model\":{\"display_name\":\"Composer\"},\"context_window\":{\"used_percentage\":30},\"render_width_chars\":88,\"session_id\":\"cursor-1\"}"
OUT="$(printf '%s' "$CURSOR_J" | env -i PATH="$PATH" HOME="$HOMED" LANG=en_US.UTF-8 \
    HEIMDALL_IDENTITY_DIR="$WS/.heimdall" HMD_HAID=rj HMD_NOW=1752410000 \
    HEIMDALL_CP_URL="http://127.0.0.1:1" TERM=xterm-256color \
    HMD_STATUSLINE_TMP="$TMPD" HEIMDALL_STATUSLINE_MODE=truecolor \
    bash "$CLI")"
RC=$?
rm -rf "$WS" "$HOMED" "$TMPD"
WIDTHS="$(printf '%s\n' "$OUT" | python3 -c 'import sys,re
A=re.compile(r"\033\[[0-9;]*m")
def w(l):
  s=A.sub("",l); n=0
  for ch in s:
    o=ord(ch)
    if o in (0x200B,0x200D,0xFE0F) or 0x0300<=o<=0x036F: continue
    n += 2 if (o==0x26A1 or 0x1100<=o<=0x115F or 0x2E80<=o<=0x303E or 0x3041<=o<=0x33FF or 0x3400<=o<=0x4DBF or 0x4E00<=o<=0x9FFF or 0xAC00<=o<=0xD7A3 or 0x1F000<=o<=0x1FAFF) else 1
  return n
ws=sorted(set(w(l) for l in sys.stdin.read().split(chr(10)) if l!=""))
print(",".join(str(x) for x in ws))')"
[ "$RC" = 0 ] && ok "cursor width: exits 0" || bad "cursor width: exit $RC"
[ "$WIDTHS" = "88" ] && ok "cursor width: rows render at EXACTLY render_width_chars=88 (no double-reserve)" \
                      || bad "cursor width: row widths {$WIDTHS}, expected 88 (COLUMNS unset, driven by the JSON field)"

echo "== 3) MANUAL/TTY: a real controlling tty with NOTHING piped renders the full multi-row HUD =="
TRIPLE="$(mkws solo)"
IFS='|' read -r WS HOMED TMPD <<<"$TRIPLE"
TTY_OUT="$(CLI="$CLI" WS="$WS" HOMED="$HOMED" TMPD="$TMPD" python3 - <<'PY'
import os, sys, pty, subprocess
CLI = os.environ["CLI"]; WS = os.environ["WS"]; HOMED = os.environ["HOMED"]; TMPD = os.environ["TMPD"]
env = dict(os.environ, HOME=HOMED, HEIMDALL_IDENTITY_DIR=os.path.join(WS, ".heimdall"),
           HMD_HAID="rj", HMD_NOW="1752410000", HEIMDALL_CP_URL="http://127.0.0.1:1",
           COLUMNS="120", TERM="xterm-256color", HMD_STATUSLINE_TMP=TMPD,
           HEIMDALL_STATUSLINE_MODE="truecolor")
mfd, sfd = pty.openpty()   # a REAL pty slave -> isatty(0) is true inside the script,
                           # no controlling-terminal setsid dance needed for [ -t 0 ].
p = subprocess.Popen(["bash", CLI], stdin=sfd, stdout=subprocess.PIPE,
                      stderr=subprocess.DEVNULL, env=env, cwd=WS, close_fds=True)
os.close(sfd)
out = p.stdout.read(); p.wait()
os.close(mfd)
sys.stdout.buffer.write(out)
PY
)"
RC_TTY=$?
rm -rf "$WS" "$HOMED" "$TMPD"
LC="$(printf '%s\n' "$TTY_OUT" | grep -c .)"
[ "$RC_TTY" = 0 ] && ok "manual/tty: exits 0" || bad "manual/tty: exit $RC_TTY"
[ "$LC" -gt 1 ] 2>/dev/null && ok "manual/tty: renders the full multi-row HUD, not the 1-line branded floor ($LC rows)" \
                            || bad "manual/tty: only $LC row(s) — degraded to the branded floor instead of the full null-safe render"

echo "== 4) PIPED-EMPTY UNCHANGED: a harness piping deliberately empty stdin keeps the existing §8.4 branded floor =="
EMPTY_HOME="$(mktemp -d)"
EMPTY_OUT="$(printf '' | env -i PATH="$PATH" HOME="$EMPTY_HOME" COLUMNS=120 TERM=xterm-256color bash "$CLI" 2>/dev/null)"
RC_EMPTY=$?
rm -rf "$EMPTY_HOME"
[ "$RC_EMPTY" = 0 ] && ok "piped-empty: exits 0" || bad "piped-empty: exit $RC_EMPTY"
case "$EMPTY_OUT" in
  *HEIMDALL*) ok "piped-empty: falls back to the branded ⛭ HEIMDALL floor (§8.4 unchanged)" ;;
  *) bad "piped-empty: unexpected output: $EMPTY_OUT" ;;
esac

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
