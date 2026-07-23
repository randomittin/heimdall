#!/usr/bin/env bash
#
# heimdall-statusline-cc-columns.test.sh — CC LIVE-STATUSLINE WIDTH CONTRACT / NO-TRUNCATION.
#
# BUG (RJ, live render): the statusline renders correctly in a plain terminal but truncates in
# Claude Code's actual statusLine region — `7d 12% $…01.…` mid-token clip, team squished. Root
# cause is WIDTH RESOLUTION: CC runs the script with $COLUMNS set to the statusLine region's
# real width (CC docs v2.1.153+), but CAPTURES stdout and gives no controlling terminal, so a
# /dev/tty width probe FAILS there or resolves the WIDER outer terminal. If the tty probe were
# consulted before $COLUMNS, the render would use that too-wide width and every row would
# overflow CC's narrower region → CC truncates it mid-token.
#
# NOTE (superseding correction): $COLUMNS is NOT CC's statusLine region width — it is the FULL
# TERMINAL width. CC paints a region 4 cells narrower and hard-clips the right edge of anything
# wider, so the layout width is $COLUMNS - 4. Measured against the real claude binary; the
# measurement + the reserve contract live in heimdall-statusline-cc-region-reserve.test.sh.
# This suite therefore asserts rows == $COLUMNS - RESERVE (still the COLUMNS-first property).
#
# THIS SUITE LOCKS (driving the REAL statusline inside a sized pseudo-terminal, with a 3-person
# team so the right rail is fully exercised):
#   1. $COLUMNS WINS over a DIFFERENT /dev/tty width — COLUMNS ∈ {100,120,160,200} while the
#      pty reports a NARROWER width. resolve_cols MUST honour $COLUMNS first, so every row is
#      EXACTLY $COLUMNS - RESERVE cells. FALSIFIER: a tty-first resolution would render the pty
#      width (COLUMNS-40, nowhere near COLUMNS-4) → RED.
#   2. NO OVERFLOW / NO MID-TOKEN RIGHT-RAIL CLIP at any of those widths — the hard clamp holds
#      and the right rail (gauge readout + team) either fits whole or drops whole segments (no
#      stray `…` in the right half of a row).
#   3. $COLUMNS set + NO controlling tty (the real CC v2.1.153+ context) → exact region-width rows.
#   4. $COLUMNS UNSET + NO tty (a degraded CC context) → the conservative 80 floor, no row > 80.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/hmd-statusline.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SL" ] || { echo "FATAL: statusline missing at $SL"; exit 2; }

SL="$SL" python3 - <<'PY'
import os, sys, pty, struct, fcntl, termios, re, json, tempfile, shutil

SL = os.environ["SL"]
ANSI = re.compile(r"\x1b\[[0-9;]*m")

def _wide(o):
    return (o == 0x26A1 or 0x1100 <= o <= 0x115F or 0x2E80 <= o <= 0x303E or
            0x3041 <= o <= 0x33FF or 0x3400 <= o <= 0x4DBF or 0x4E00 <= o <= 0x9FFF or
            0xAC00 <= o <= 0xD7A3 or 0x1F000 <= o <= 0x1FAFF)

def vis(s):
    s = ANSI.sub("", s); n = 0
    for ch in s:
        o = ord(ch)
        if o in (0x200B, 0x200D, 0xFE0F) or 0x0300 <= o <= 0x036F:
            continue
        n += 2 if _wide(o) else 1
    return n

# CC sets $COLUMNS to the FULL TERMINAL width, but only paints a region 4 cells narrower and
# hard-clips the right edge of anything wider (measured against claude v2.1.211 — see
# heimdall-statusline-cc-region-reserve.test.sh). So the layout width CC actually gives us is
# $COLUMNS - RESERVE, and THAT is what every row must equal.
RESERVE = 4

_p = 0; _f = 0
def ok(m):
    global _p; _p += 1; print("  ok   " + m)
def bad(m):
    global _f; _f += 1; print("  FAIL " + m)

def _ws():
    ws = tempfile.mkdtemp(); os.makedirs(ws + "/.heimdall", exist_ok=True)
    open(ws + "/.heimdall/identity.json", "w").write('{"handle":"rj","seed":"rj","created":0}\n')
    open(ws + "/.heimdall/statusline.json", "w").write('{"verdict":"pass","passed":3,"total":3}\n')
    # a FRESH roster cache — three teammates so the top-half sigil rail renders in full.
    open(ws + "/.heimdall/.roster-cache.json", "w").write(json.dumps([
        {"handle": "akshat", "haid": "haid:akshat.mbp-1a2b", "verdict": "working", "file": "auth.ts", "age_seconds": 1},
        {"handle": "kai",    "haid": "haid:kai.mbp-9z8y",    "verdict": "watching", "file": "db.go",   "age_seconds": 1},
        {"handle": "mira",   "haid": "haid:mira.mbp-3c4d",   "verdict": "deny",     "file": "api.py",  "age_seconds": 1}]))
    return ws

def render_pty(ptw, cols_env, no_tty=False):
    """Render inside a pty of width `ptw`, with stdin+stdout as CAPTURED pipes (exactly how CC
    invokes it). `cols_env` = the $COLUMNS to export (None = unset). `no_tty` = no controlling
    terminal (so /dev/tty cannot be opened — the degraded CC / conservative-floor path)."""
    ws = _ws()
    data = json.dumps({
        "workspace": {"current_dir": ws, "repo": {"name": "heimdall", "branch": "statusline-v1"}},
        "model": {"display_name": "Opus 4.8"},
        "context_window": {"used_percentage": 42, "total_input_tokens": 128000},
        "session_id": "cc", "cost": {"total_cost_usd": 0.87, "total_duration_ms": 3840000},
        "rate_limits": {"five_hour": {"used_percentage": 42, "resets_at": 7207},
                        "seven_day": {"used_percentage": 12}}}).encode()
    env = {"PATH": os.environ.get("PATH", ""), "HOME": ws, "TERM": "xterm-256color",
           "HEIMDALL_IDENTITY_DIR": ws + "/.heimdall", "HMD_HAID": "rj", "HMD_NOW": "7",
           "HEIMDALL_CP_URL": "http://127.0.0.1:1", "LANG": "en_US.UTF-8",
           "HMD_STATUSLINE_TMP": ws + "/tmp", "HEIMDALL_STATUSLINE_MODE": "truecolor"}
    if cols_env is not None:
        env["COLUMNS"] = str(cols_env)
    ji, jo = os.pipe(); oi, oo = os.pipe(); sfd = mfd = None
    if not no_tty:
        mfd, sfd = pty.openpty()
        fcntl.ioctl(sfd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, ptw, 0, 0))
    pid = os.fork()
    if pid == 0:
        os.setsid()
        if sfd is not None:
            fcntl.ioctl(sfd, termios.TIOCSCTTY, 0)
        os.dup2(ji, 0); os.dup2(oo, 1)
        dn = os.open(os.devnull, os.O_WRONLY); os.dup2(dn, 2)
        os.execvpe(sys.executable, [sys.executable, SL], env)
    os.close(ji); os.close(oo)
    if sfd is not None:
        os.close(sfd)
    os.write(jo, data); os.close(jo)
    out = b""
    while True:
        try:
            chunk = os.read(oi, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    os.close(oi)
    if mfd is not None:
        os.close(mfd)
    os.waitpid(pid, 0)
    shutil.rmtree(ws, ignore_errors=True)
    return out.decode("utf-8", "replace")

def rows(out):
    return [l for l in out.split("\n") if l != ""]

def right_clip(rs, width):
    """True if any row carries a truncation `…` in its RIGHT half (a mid-token right-rail clip
    — the RJ `$…01.…` symptom). A `…` in the LEFT half is the identity graceful-degrade and is
    NOT a right-rail clip."""
    for r in rs:
        s = ANSI.sub("", r)
        i = s.find("…")
        if i >= 0 and i > width * 0.5:
            return True
    return False

def heim(rs):
    return sum(1 for r in rs if "HEIMDALL" in ANSI.sub("", r))

# 1) $COLUMNS wins over a DIFFERENT (narrower) /dev/tty width.
print("== 1) $COLUMNS wins over a mismatched /dev/tty width ==")
for w in (100, 120, 160, 200):
    ptw = max(20, w - 40)   # the pty is NARROWER — a tty-first resolution would render this.
    want = w - RESERVE
    rs = rows(render_pty(ptw, w))
    widths = sorted(set(vis(r) for r in rs))
    if widths == [want]:
        ok("COLUMNS=%d (tty=%d) → every row == %d (COLUMNS honoured first, not the tty; CC region reserve applied)" % (w, ptw, want))
    else:
        bad("COLUMNS=%d (tty=%d) → row widths %s != [%d] (tty-first regression?)" % (w, ptw, widths, want))
    if not right_clip(rs, w):
        ok("COLUMNS=%d → no mid-token right-rail clip (right rail fits/drops whole)" % w)
    else:
        bad("COLUMNS=%d → a `…` mid-token clip in the right rail" % w)
    (ok if heim(rs) == 1 else bad)("COLUMNS=%d → HEIMDALL wordmark present (count %d)" % (w, heim(rs)))

# 2) $COLUMNS set + NO controlling tty (the real CC v2.1.153+ context).
print("== 2) $COLUMNS set + NO tty (real CC) → exact region width, no overflow ==")
for w in (100, 120, 160, 200):
    want = w - RESERVE
    rs = rows(render_pty(0, w, no_tty=True))
    widths = sorted(set(vis(r) for r in rs))
    over = [x for x in widths if x > want]
    if widths == [want] and not over and not right_clip(rs, want):
        ok("COLUMNS=%d, no-tty → every row == %d (CC's region), no overflow, no right clip" % (w, want))
    else:
        bad("COLUMNS=%d, no-tty → widths %s (want [%d]), rightclip=%s" % (w, widths, want, right_clip(rs, want)))

# 3) $COLUMNS UNSET + NO tty → the conservative 80 floor.
print("== 3) $COLUMNS UNSET + NO tty (degraded CC) → conservative 80, no row > 80 ==")
rs = rows(render_pty(0, None, no_tty=True))
mx = max((vis(r) for r in rs), default=0)
(ok if mx <= 80 else bad)("unset + no-tty → max row %d <= 80 (conservative floor, no overflow)" % mx)
(ok if heim(rs) == 1 else bad)("unset + no-tty → HEIMDALL wordmark present at the 80 floor")

print()
print("%d passed, %d failed" % (_p, _f))
sys.exit(1 if _f else 0)
PY
