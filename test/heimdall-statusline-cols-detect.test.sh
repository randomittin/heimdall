#!/usr/bin/env bash
#
# heimdall-statusline-cols-detect.test.sh — REAL TERMINAL-WIDTH RESOLUTION / NO-WRAP.
#
# BUG (RJ, root-caused): when Claude Code does NOT export $COLUMNS the statusline
# BLINDLY defaulted to COLUMNS=120. On a narrower physical terminal (~95 cols) the
# full-mode rows (114 visible cells = 120 − RMARGIN) EXCEED the real width → the
# terminal SOFT-WRAPS each row → a thin wrapped continuation appears (the "0.5pt
# top row duplicating the sigil top"). The output bytes are a clean 4 rows; the bug
# is we RENDER for 120 when the terminal is ~95, so it wraps.
#
# FIX: resolve width in order — explicit $COLUMNS (numeric, >0) → the REAL controlling
# terminal via /dev/tty (`tput cols </dev/tty`, then `stty size </dev/tty`) → a
# CONSERVATIVE 80 default. Never over-assume 120; UNDER-render (compact) when width is
# genuinely unknown so a narrow terminal never wraps.
#
# THIS SUITE LOCKS (driving the REAL statusline inside a sized pseudo-terminal):
#   1. RJ's case: a 95-col terminal with COLUMNS UNSET → the width is DETECTED (95),
#      and NO row exceeds 95 (no wrap). At the detected 95 the v1 layout is the `mid`
#      tier — the three rows render (HEIMDALL wordmark present), each fitting 95.
#      FALSIFIER: the old blind-120 default emits 120-cell rows → >95 → RED.
#   2. COLUMNS=95 explicit → NO row exceeds 95.
#   3. COLUMNS=120 explicit → full tier (HEIMDALL present), NO row exceeds 120.
#   4. COLUMNS UNSET + NO controlling /dev/tty → the CONSERVATIVE 80 default (the `mid`
#      tier), NO row exceeds 80 (under-render, never over-render).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/hmd-statusline.py"
SEED=rj

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SL" ] || { echo "FATAL: statusline missing at $SL"; exit 2; }

# render the statusline inside a pseudo-terminal of a chosen width, with stdin (the CC
# JSON) and stdout as CAPTURED pipes (never the tty — exactly as Claude Code invokes it).
# The pty is the process's CONTROLLING terminal (setsid + TIOCSCTTY) so /dev/tty resolves
# to it and the width probes read its real winsize. `--no-tty` runs with NO controlling
# terminal so /dev/tty cannot be opened (the conservative-default path).
render_pty() {
  python3 - "$@" <<'PY'
import os, sys, pty, struct, fcntl, termios
SL = sys.argv[1]; ptw = int(sys.argv[2]); no_tty = "--no-tty" in sys.argv[3:]
JSON = sys.stdin.buffer.read()
ji, jo = os.pipe()          # child stdin  (CC JSON, a pipe → NOT a tty)
oi, oo = os.pipe()          # child stdout (captured, a pipe → NOT a tty)
sfd = mfd = None
if not no_tty:
    mfd, sfd = pty.openpty()
    fcntl.ioctl(sfd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, ptw, 0, 0))
pid = os.fork()
if pid == 0:                # ---- child ----
    os.setsid()
    if sfd is not None:
        fcntl.ioctl(sfd, termios.TIOCSCTTY, 0)   # pty becomes the controlling terminal
    os.dup2(ji, 0); os.dup2(oo, 1)
    devnull = os.open(os.devnull, os.O_WRONLY); os.dup2(devnull, 2)
    keep = set([ji, jo, oi, oo, devnull])
    if sfd is not None: keep |= {mfd, sfd}
    for fd in keep:
        if fd > 2:
            try: os.close(fd)
            except OSError: pass
    os.execvpe(sys.executable, [sys.executable, SL], os.environ.copy())
os.close(ji); os.close(oo)
if sfd is not None: os.close(sfd)
os.write(jo, JSON); os.close(jo)
out = b""
while True:
    try: chunk = os.read(oi, 4096)
    except OSError: break
    if not chunk: break
    out += chunk
os.close(oi)
if mfd is not None: os.close(mfd)
os.waitpid(pid, 0)
sys.stdout.buffer.write(out)
PY
}

# max visible (wcwidth-aware) row width + a HEIMDALL-header count, over a render.
metrics() {
  python3 -c 'import sys,re
A=re.compile(r"\033\[[0-9;]*m")
def w(l):
  s=A.sub("",l); n=0
  for ch in s:
    o=ord(ch)
    if o in (0x200B,0x200D,0xFE0F) or 0x0300<=o<=0x036F: continue
    if o==0x26A1 or 0x1100<=o<=0x115F or 0x2E80<=o<=0x303E or 0x3041<=o<=0x33FF or 0x3400<=o<=0x4DBF or 0x4E00<=o<=0x9FFF or 0xAC00<=o<=0xD7A3 or 0x1F000<=o<=0x1FAFF: n+=2
    else: n+=1
  return n
ls=[l for l in sys.stdin.read().split("\n") if l!=""]
print(max((w(l) for l in ls), default=0))
print(sum(1 for l in ls if "HEIMDALL" in A.sub("",l)))'
}

# a hermetic workspace + fixed identity/roster/verdict, rendered inside a pty. $2 chooses
# whether COLUMNS is exported (empty string = UNSET). $3.. forwarded to render_pty.
run_case() {
  ptw="$1"; cols_env="$2"; shift 2
  WS="$(mktemp -d)"; HOMED="$(mktemp -d)"
  mkdir -p "$WS/.heimdall"
  printf '{"handle":"rj","seed":"rj","created":0}\n' > "$WS/.heimdall/identity.json"
  printf '{"verdict":"pass","passed":3,"total":3}\n' > "$WS/.heimdall/statusline.json"
  printf '%s\n' '[{"handle":"nadia","haid":"haid:nadia","verdict":"working","file":"auth.ts","age_seconds":4},{"handle":"arjun","haid":"haid:arjun","verdict":"watching","file":"db.go","age_seconds":9},{"handle":"priya","haid":"haid:priya","verdict":"deny","file":"api.py","age_seconds":6}]' \
    > "$WS/.heimdall/.roster-cache.json"
  local -a envv=(PATH="$PATH" HOME="$HOMED" TERM=xterm-256color
                 HEIMDALL_IDENTITY_DIR="$WS/.heimdall" HMD_HAID="$SEED" HMD_NOW=7
                 HEIMDALL_CP_URL="http://127.0.0.1:1" LANG=en_US.UTF-8
                 HEIMDALL_STATUSLINE_MODE=truecolor)
  [ -n "$cols_env" ] && envv+=(COLUMNS="$cols_env")
  printf '{"workspace":{"current_dir":"%s","repo":{"name":"heimdall"}},"model":{"display_name":"Opus 4.8"},"context_window":{"used_percentage":42}}' "$WS" \
    | env -i "${envv[@]}" bash -c "$(declare -f render_pty); render_pty \"\$@\"" _ "$SL" "$ptw" "$@"
  rm -rf "$WS" "$HOMED"
}

echo "== 1) RJ's case: 95-col terminal, COLUMNS UNSET — width detected, no wrap =="
{ read -r MX; read -r HC; } <<EOF
$(run_case 95 "" | metrics)
EOF
[ "$MX" -le 95 ] && ok "95-col unset: max row $MX <= 95 (real width detected, no wrap)" \
                 || bad "95-col unset: a row is $MX cells > 95 (blind-120 default → wraps)"
[ "$HC" = 1 ] && ok "95-col unset: mid tier (HEIMDALL wordmark present) — fits 95" \
             || bad "95-col unset: HEIMDALL count $HC (expected 1 at the detected 95)"

echo "== 2) COLUMNS=95 explicit — no row exceeds 95 =="
MX="$(run_case 95 95 | metrics | head -1)"
[ "$MX" -le 95 ] && ok "COLUMNS=95: max row $MX <= 95 (no wrap)" \
                 || bad "COLUMNS=95: a row is $MX cells > 95 (wraps)"

echo "== 3) COLUMNS=120 explicit — full mode, no row exceeds 120 =="
{ read -r MX; read -r HC; } <<EOF
$(run_case 120 120 | metrics)
EOF
[ "$MX" -le 120 ] && ok "COLUMNS=120: max row $MX <= 120 (full mode fits, no wrap)" \
                  || bad "COLUMNS=120: a row is $MX cells > 120 (wraps)"
[ "$HC" = 1 ] && ok "COLUMNS=120: full mode (HEIMDALL wordmark present)" \
             || bad "COLUMNS=120: HEIMDALL count $HC (expected full mode, 1)"

echo "== 4) COLUMNS UNSET + NO /dev/tty — conservative 80, compact, no row exceeds 80 =="
{ read -r MX; read -r HC; } <<EOF
$(run_case 0 "" --no-tty | metrics)
EOF
[ "$MX" -le 80 ] && ok "no-tty unset: max row $MX <= 80 (conservative default, under-render)" \
                 || bad "no-tty unset: a row is $MX cells > 80 (over-render)"
[ "$HC" = 1 ] && ok "no-tty unset: mid tier (HEIMDALL present) at the conservative 80 default" \
             || bad "no-tty unset: HEIMDALL count $HC (expected 1 at the conservative 80)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
