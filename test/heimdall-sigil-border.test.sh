#!/usr/bin/env bash
#
# heimdall-sigil-border.test.sh — 1px NEAR-BLACK SIGIL BORDER FRAME (FIX 4).
#
# RJ: "to fix the bleed you can add a black 1px border to the sigil." The sigil block
# now carries an in-footprint near-black frame (value 3 = BORDER, no growth): every
# PERIMETER pixel that was OFF/DIM becomes the frame, while a lit body/eye pixel at
# the edge is preserved (the silhouette survives). It contains edge speckle/bleed and
# crisps the block's bounding box.
#
# THIS SUITE LOCKS:
#   1. sigil_render(border=True) introduces the BORDER color; the default (border=False,
#      the CLI/banner path) does NOT — so the sigil-render goldens stay byte-exact.
#   2. FRAME INVARIANT: after the border, NO perimeter pixel is OFF/DIM (value 0) — the
#      block is fully ringed by frame-or-silhouette; the frame value is present.
#   3. WIDTH INVARIANT preserved: border is in-footprint (M stays 8 cols, S stays 4).
#   4. The REAL statusline full HUD renders the sigil with the BORDER frame on both the
#      top and bottom sigil rows.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SIG="$ROOT/sentinels/hmd_sigil.py"
SL="$ROOT/sentinels/hmd-statusline.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SIG" ] || { echo "FATAL: sigil core missing at $SIG"; exit 2; }

SIG="$SIG" SL="$SL" python3 - <<'PY'
import importlib.util, os, re, sys, tempfile, io, contextlib
def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    with contextlib.redirect_stdout(io.StringIO()):
        spec.loader.exec_module(m)
    return m
m = load(os.environ["SIG"], "sig")
A = re.compile(r"\033\[[0-9;]*m")
fail = 0
def ok(t):  print("  ok   " + t)
def bad(t):
    global fail; fail += 1; print("  FAIL " + t)
def want(cond, y, n):
    ok(y) if cond else bad(n)

BORDER_SGR = "38;2;%d;%d;%d" % m.BORDER

# 1) border=True introduces BORDER; default does not.
plain = "\n".join(m.sigil_render("rj", "M"))
bord  = "\n".join(m.sigil_render("rj", "M", border=True))
want(BORDER_SGR not in plain, "default render carries NO border (CLI/banner goldens safe)",
                              "default (border=False) leaked the frame color")
want(BORDER_SGR in bord, "border=True introduces the near-black frame color",
                         "border=True did not emit the frame color")

# 2) FRAME INVARIANT: no perimeter pixel is OFF (value 0) after the border; frame present.
for sz in ("S", "M"):
    vg, _, _ = m._size_grid("rj", sz)
    m._apply_border(vg)
    N = len(vg)
    perim = [vg[0][c] for c in range(N)] + [vg[N-1][c] for c in range(N)] \
          + [vg[r][0] for r in range(N)] + [vg[r][N-1] for r in range(N)]
    if 0 in perim:
        bad("%s: a perimeter pixel is still OFF/DIM (unframed edge)" % sz)
    elif 3 in perim:
        ok("%s: perimeter fully ringed by frame-or-silhouette (frame value present)" % sz)
    else:
        ok("%s: perimeter fully lit (silhouette reaches every edge — no frame needed)" % sz)

# 3) WIDTH INVARIANT: in-footprint (M=8, S=4) with the border on.
for sz, wd in (("S", 4), ("M", 8)):
    ws = set(len(A.sub("", l)) for l in m.sigil_render("rj", sz, border=True) if l != "")
    want(ws == {wd}, "%s width invariant holds with border (all lines = %d)" % (sz, wd),
                     "%s width changed with border: %r (want {%d})" % (sz, ws, wd))

# 4) the REAL statusline full HUD frames the sigil on the top AND bottom rows.
sl = os.environ["SL"]
ws_dir = tempfile.mkdtemp(); home = tempfile.mkdtemp()
os.makedirs(ws_dir + "/.heimdall", exist_ok=True)
open(ws_dir + "/.heimdall/identity.json", "w").write('{"handle":"rj","seed":"rj","created":0}\n')
open(ws_dir + "/.heimdall/statusline.json", "w").write('{"verdict":"pass","passed":3,"total":3}\n')
import subprocess
env = dict(PATH=os.environ.get("PATH", ""), HOME=home,
           HEIMDALL_IDENTITY_DIR=ws_dir + "/.heimdall", HMD_HAID="rj", HMD_NOW="7",
           HEIMDALL_CP_URL="http://127.0.0.1:1", COLUMNS="120", LANG="en_US.UTF-8",
           HEIMDALL_STATUSLINE_MODE="truecolor")
j = '{"workspace":{"current_dir":"%s","repo":{"name":"heimdall"}},"model":{"display_name":"Opus"},"context_window":{"used_percentage":42}}' % ws_dir
out = subprocess.run(["python3", sl], input=j.encode(), env=env, stdout=subprocess.PIPE).stdout.decode()
rows = [l for l in out.split("\n") if l != ""]
top_has = BORDER_SGR in rows[0]
bot_has = BORDER_SGR in rows[3] if len(rows) >= 4 else False
want(top_has, "full HUD: top sigil row carries the border frame", "full HUD: no frame on the top sigil row")
want(bot_has, "full HUD: bottom sigil row carries the border frame", "full HUD: no frame on the bottom sigil row")

print()
print("all passed" if fail == 0 else ("%d failed" % fail))
sys.exit(1 if fail else 0)
PY
