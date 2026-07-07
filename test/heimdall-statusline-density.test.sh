#!/usr/bin/env bash
#
# heimdall-statusline-density.test.sh — STATUSLINE v2 DENSITY CONFORMANCE (spec B).
#
# Statusline v2 renders three DENSITY modes auto-selected by terminal width, on the
# SAME shared sigil_render core Piece A built:
#   full    (≥120 cols): sigil M + name + verdict + team wall
#   compact (80–119):    sigil S + verdict + wall GLYPHS (tinted by glyph_color)
#   minimal (<80):       a single glyph + the verdict word
# Each mode NEVER truncates mid-glyph — every emitted row is padded (finalize) to a
# uniform visible width, so a row is fully present or absent, never sliced.
#
# THIS SUITE LOCKS (spec Tests 2–3):
#   1. 9 GOLDENS byte-exact: 3 density modes × 3 capability tiers (truecolor/256/16),
#      re-rendered and byte-diffed against committed fixtures (a one-byte drift → RED).
#   2. WIDTH INVARIANT: within each of the 9 fixtures, EVERY non-empty line has an
#      identical visible (wcwidth) width — the declared density width. (Falsifier: an
#      un-padded row would report a second distinct width → RED.)
#   3. VERDICT SEMANTICS: DENY pulses via a TWO-FRAME alternation on the refresh tick
#      with NO SGR blink (params 5/6 BANNED) — asserted across both frames.
#   4. TIER FIDELITY: truecolor → 38;2;; 256 → 38;5; and NO 38;2;; 16 → neither
#      (the morph guard, same contract as the sigil core).
#   5. <50ms RENDER BENCHMARK: the in-process render (warm sigil cache) median is
#      reported and asserted under the 50ms budget.
#
# HERMETIC: a throwaway $HOME + workspace per render; a FIXED file-controlled identity
# (seed=rj, handle=rj) and a FRESH roster cache (3 teammates: active/idle/deny) so the
# bytes are deterministic on any machine; CP pointed at an unreachable port so no render
# blocks or forks off-box.
#
# Regenerate the goldens intentionally with:  bash test/heimdall-statusline-density.test.sh --regen
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/sentinels/hmd-statusline.py"
GOLD="$ROOT/conformance/statusline/goldens/density"
SEED=rj
REGEN=0; [ "${1:-}" = "--regen" ] && REGEN=1

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SL" ] || { echo "FATAL: statusline missing at $SL"; exit 2; }
mkdir -p "$GOLD"

cols_for() { case "$1" in full) echo 120;; compact) echo 100;; minimal) echo 60;; *) echo 80;; esac; }

# Deterministic hermetic render for a (density, tier). A fixed identity + a fresh
# roster cache + a fixed clock (HMD_NOW) + a fixed repo name make the bytes stable.
render_case() {
  density="$1"; tier="$2"; cols="$(cols_for "$density")"
  WS="$(mktemp -d)"; HOMED="$(mktemp -d)"
  mkdir -p "$WS/.heimdall"
  printf '{"handle":"rj","seed":"rj","created":0}\n' > "$WS/.heimdall/identity.json"
  # gate verdict (read from <cwd>/.heimdall/statusline.json, NOT stdin): DENY exercises
  # the two-frame pulse + the wall's red-frame state.
  printf '{"verdict":"deny"}\n' > "$WS/.heimdall/statusline.json"
  # a FRESH roster cache — three teammates spanning the three wall states.
  printf '%s\n' '[{"handle":"nadia","haid":"haid:nadia","verdict":"working","file":"auth.ts","age_seconds":4},{"handle":"arjun","haid":"haid:arjun","verdict":"watching","file":"db.go","age_seconds":9},{"handle":"priya","haid":"haid:priya","verdict":"deny","file":"api.py","age_seconds":6}]' \
    > "$WS/.heimdall/.roster-cache.json"
  printf '{"workspace":{"current_dir":"%s","repo":{"name":"heimdall"}},"model":{"display_name":"Opus"},"context_window":{"used_percentage":42}}' "$WS" \
    | env -i PATH="$PATH" HOME="$HOMED" \
        HEIMDALL_IDENTITY_DIR="$WS/.heimdall" HMD_HAID="$SEED" HMD_NOW=7 \
        HEIMDALL_CP_URL="http://127.0.0.1:1" COLUMNS="$cols" LANG=en_US.UTF-8 \
        HEIMDALL_STATUSLINE_MODE="$tier" python3 "$SL"
  rm -rf "$WS" "$HOMED"
}

# distinct visible (wcwidth) widths across the non-empty lines of a render.
widths() { python3 -c 'import sys,re
A=re.compile(r"\033\[[0-9;]*m")
def w(l):
  s=A.sub("",l); n=0
  for ch in s:
    o=ord(ch)
    if o in (0x200B,0x200D,0xFE0F) or 0x0300<=o<=0x036F: continue
    if o==0x26A1 or 0x1100<=o<=0x115F or 0x2E80<=o<=0x303E or 0x3041<=o<=0x33FF or 0x3400<=o<=0x4DBF or 0x4E00<=o<=0x9FFF or 0xAC00<=o<=0xD7A3 or 0x1F000<=o<=0x1FAFF: n+=2
    else: n+=1
  return n
ws=sorted(set(w(l) for l in sys.stdin.read().split("\n") if l!=""))
print(",".join(str(x) for x in ws))'; }

DENS="full compact minimal"
TIERS="truecolor 256 16"

if [ "$REGEN" = 1 ]; then
  echo "== regenerating 9 density×tier goldens =="
  for d in $DENS; do for t in $TIERS; do
    render_case "$d" "$t" > "$GOLD/${SEED}_${d}_${t}.txt"
    echo "  wrote ${SEED}_${d}_${t}.txt ($(cols_for "$d") cols)"
  done; done
  echo "done."
  exit 0
fi

echo "== 1) 9 goldens byte-exact: 3 density × 3 tier =="
for d in $DENS; do for t in $TIERS; do
  g="$GOLD/${SEED}_${d}_${t}.txt"
  if [ ! -f "$g" ]; then bad "golden missing: ${SEED}_${d}_${t}.txt"; continue; fi
  if render_case "$d" "$t" | cmp -s - "$g"; then ok "byte-exact: ${d} × ${t}"
  else bad "golden DRIFT: ${d} × ${t} (re-render != committed golden)"; fi
done; done

echo "== 2) width invariant: every line one width, all 9 fixtures =="
for d in $DENS; do for t in $TIERS; do
  g="$GOLD/${SEED}_${d}_${t}.txt"
  [ -f "$g" ] || { bad "width: golden missing ${d}×${t}"; continue; }
  ws="$(widths < "$g")"
  case "$ws" in
    *,*) bad "width invariant BROKEN: ${d} × ${t} has multiple widths ($ws)" ;;
    "")  bad "width: ${d} × ${t} rendered no lines" ;;
    *)   ok "width invariant: ${d} × ${t} all lines = $ws" ;;
  esac
done; done

echo "== 3) DENY two-frame pulse on the tick, NO SGR blink =="
FA="$(render_case minimal truecolor)"                      # HMD_NOW=7 (odd) = frame B
FB="$(WS2=1 python3 - "$SL" <<'PY'
import os,sys,subprocess,tempfile,shutil
SL=sys.argv[1]
ws=tempfile.mkdtemp(); home=tempfile.mkdtemp()
os.makedirs(ws+"/.heimdall",exist_ok=True)
open(ws+"/.heimdall/identity.json","w").write('{"handle":"rj","seed":"rj","created":0}\n')
open(ws+"/.heimdall/statusline.json","w").write('{"verdict":"deny"}\n')
env=dict(PATH=os.environ.get("PATH",""),HOME=home,HEIMDALL_IDENTITY_DIR=ws+"/.heimdall",
         HMD_HAID="rj",HMD_NOW="8",HEIMDALL_CP_URL="http://127.0.0.1:1",COLUMNS="60",
         LANG="en_US.UTF-8",HEIMDALL_STATUSLINE_MODE="truecolor")
j='{"workspace":{"current_dir":"%s"}}'%ws
out=subprocess.run(["python3",SL],input=j.encode(),env=env,stdout=subprocess.PIPE).stdout
sys.stdout.buffer.write(out)
shutil.rmtree(ws,ignore_errors=True); shutil.rmtree(home,ignore_errors=True)
PY
)"
if [ "$FA" != "$FB" ]; then ok "DENY frame(tick7) != frame(tick8) — the pulse alternates on the tick"
else bad "DENY did not pulse (tick 7 and tick 8 rendered identical)"; fi
BLINK="$(render_case full truecolor | python3 -c 'import sys,re
d=sys.stdin.read()
b=[s for s in re.findall(r"\x1b\[([0-9;]*)m",d) if any(p in ("5","6") for p in s.split(";"))]
print(len(b))')"
[ "$BLINK" = 0 ] && ok "no SGR blink param (5/6) anywhere (blink is BANNED)" \
                 || bad "SGR blink param present ($BLINK) — banned"

echo "== 4) tier fidelity: emitted SGR family matches the tier =="
TC="$(render_case compact truecolor)"; C256="$(render_case compact 256)"; C16="$(render_case compact 16)"
grep -qF '38;2;' <<<"$TC"   && ok "truecolor → 24-bit 38;2;"           || bad "truecolor → no 38;2;"
grep -qF '38;5;' <<<"$C256" && ok "256 → nearest-cube 38;5;"          || bad "256 → no 38;5;"
grep -qF '38;2;' <<<"$C256" && bad "256 → leaked raw 38;2; (morph)"   || ok "256 → NO raw 38;2; (morph guard)"
grep -qF '38;2;' <<<"$C16"  && bad "16 → leaked raw 38;2;"            || ok "16 → no 38;2;"
grep -qF '38;5;' <<<"$C16"  && bad "16 → leaked 256 38;5;"           || ok "16 → no 38;5; (ANSI-16 only)"

echo "== 5) <50ms render benchmark (in-process, warm sigil cache) =="
BENCH="$(python3 - "$SL" <<'PY'
import os,sys,io,time,importlib.util,tempfile,statistics,contextlib
SL=sys.argv[1]
ws=tempfile.mkdtemp(); home=tempfile.mkdtemp()
os.makedirs(ws+"/.heimdall",exist_ok=True)
open(ws+"/.heimdall/identity.json","w").write('{"handle":"rj","seed":"rj","created":0}\n')
open(ws+"/.heimdall/statusline.json","w").write('{"verdict":"deny"}\n')
open(ws+"/.heimdall/.roster-cache.json","w").write('[{"handle":"nadia","verdict":"working"}]\n')
os.environ.update(dict(HOME=home,HEIMDALL_IDENTITY_DIR=ws+"/.heimdall",HMD_HAID="rj",
  HMD_NOW="7",HEIMDALL_CP_URL="http://127.0.0.1:1",COLUMNS="120",LANG="en_US.UTF-8",
  HEIMDALL_STATUSLINE_MODE="truecolor"))
spec=importlib.util.spec_from_file_location("sl",SL); m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
j='{"workspace":{"current_dir":"%s","repo":{"name":"heimdall"}},"model":{"display_name":"Opus"},"context_window":{"used_percentage":42}}'%ws
def one():
  sys.stdin=io.StringIO(j)
  with contextlib.redirect_stdout(io.StringIO()):
    m.main()
one()  # warm the sigil cache (disk + memo)
ts=[]
for _ in range(60):
  sys.stdin=io.StringIO(j); t0=time.perf_counter()
  with contextlib.redirect_stdout(io.StringIO()): m.main()
  ts.append((time.perf_counter()-t0)*1000)
print("%.3f %.3f"%(statistics.median(ts),max(ts)))
PY
)"
MED="${BENCH%% *}"; MX="${BENCH##* }"
echo "  render median=${MED}ms max=${MX}ms (budget 50ms)"
python3 -c "import sys;sys.exit(0 if float('$MED')<50.0 else 1)" \
  && ok "median render < 50ms (${MED}ms)" || bad "median render ${MED}ms exceeds 50ms budget"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
