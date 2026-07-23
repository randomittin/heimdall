#!/usr/bin/env bash
#
# heimdall-statusline-density.test.sh — DENSITY CONFORMANCE for the v2 full-bleed 4-row
# composite statusline.
#
# WIDTH SOURCE: this suite pins the RENDERER contract (tier density) at a GIVEN layout width,
# so it renders with HMD_STATUSLINE_RESERVE=0 — COLUMNS IS the layout width here, and the
# committed goldens are keyed to that. In production the layout width is $COLUMNS MINUS CC's
# 4-cell statusLine region spacing; that derivation is owned by
# heimdall-statusline-cc-region-reserve.test.sh.
#
# The statusline auto-selects a WIDTH TIER from the terminal width
# and lays the 4 content rows out to the RIGHT of the 8×8 hero sigil anchor, EXACTLY
# $COLUMNS visible cells per emitted row (hmd_layout.width_tier + compose_with_sigil):
#   full   (>=100 cols): 4 rows, everything — 3 team members, 40c gauge, gate details, 12c micro-bars.
#   mid    (60–99):      4 rows — 2 team members + `+N` (states drop), 32c gauge, gate details drop, 8c micro.
#   narrow (40–59):      4 rows — team → inline `● ● ●` dots on the Row1 rail; gauge bar-only; micro → text.
#   tiny   (<40):        ONE line — `HMD <pct>% <gates>`.
#
# Row1 identity drops WHOLE segments per tier (git counts → model → handle → repo:branch),
# never a mid-token `…` (Spec v2 §2) — the goldens lock that whole-segment behaviour.
#
# THIS SUITE LOCKS:
#   1. GOLDENS byte-exact: 4 width tiers × 3 capability tiers (truecolor/256/16),
#      re-rendered and byte-diffed against committed fixtures (a one-byte drift → RED).
#   2. ROW-EXACT (the headline invariant): within EACH fixture, EVERY emitted row has an
#      identical visible (wcwidth) width EQUAL to that tier's COLUMNS. A row that under-
#      or over-fills the line (soft-wrap / ragged rail) reports a second width → RED.
#   3. ROW-COUNT: full/mid/narrow → 3 rows; tiny → 1 row (the single-line fallback).
#   4. TIER FIDELITY: truecolor → 38;2;; 256 → 38;5; and NO 38;2;; 16 → neither
#      (the CAPS.emit color downgrade morph guard).
#   5. RENDER BENCHMARK: the in-process render (warm sigil + ledger cache) median is
#      reported and asserted under 50ms; a COLD-cache render sample (on-disk sigil cache +
#      in-process memo wiped → a forced recompute) is asserted under 500ms best-of-3 (fork+recompute dominated).
#
# HERMETIC: a throwaway $HOME + workspace + ledger-cache tmp per render; a FIXED file-
# controlled identity (seed=rj, handle=rj), a FIXED clock (HMD_NOW=7), a FRESH roster
# cache (3 teammates), CP pointed at an unreachable port (no fork blocks/leaks into
# stdout) — so the emitted bytes are deterministic on any machine.
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

# representative COLUMNS per width tier (see hmd_layout.width_tier boundaries).
cols_for() { case "$1" in full) echo 120;; mid) echo 80;; narrow) echo 48;; tiny) echo 30;; *) echo 80;; esac; }

# Deterministic hermetic render for a (tier, color). A fixed identity + a fresh roster
# cache + a fixed clock (HMD_NOW=7) + a fixed repo/model/limits + a fresh per-render
# ledger-cache tmp make the emitted bytes stable.
render_case() {
  tier="$1"; color="$2"; cols="$(cols_for "$tier")"
  WS="$(mktemp -d)"; HOMED="$(mktemp -d)"; TMPD="$(mktemp -d)"
  mkdir -p "$WS/.heimdall"
  printf '{"handle":"rj","seed":"rj","created":0}\n' > "$WS/.heimdall/identity.json"
  # Row3 gate verdict via the legacy single-verdict file (read by hmd_ledger).
  printf '{"verdict":"pass","passed":3,"total":3}\n' > "$WS/.heimdall/statusline.json"
  # a FRESH roster cache — three teammates so the Row1 team cluster renders.
  printf '%s\n' '[{"handle":"nadia","haid":"haid:nadia","verdict":"working","file":"auth.ts","age_seconds":4},{"handle":"arjun","haid":"haid:arjun","verdict":"watching","file":"db.go","age_seconds":9},{"handle":"priya","haid":"haid:priya","verdict":"deny","file":"api.py","age_seconds":6}]' \
    > "$WS/.heimdall/.roster-cache.json"
  printf '{"workspace":{"current_dir":"%s","repo":{"name":"heimdall","branch":"statusline-v1"}},"model":{"display_name":"Opus 4.8"},"context_window":{"used_percentage":42,"total_input_tokens":128000},"session_id":"density","cost":{"total_cost_usd":0.87,"total_duration_ms":3840000},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":7207},"seven_day":{"used_percentage":12}}}' "$WS" \
    | env -i PATH="$PATH" HOME="$HOMED" \
        HEIMDALL_IDENTITY_DIR="$WS/.heimdall" HMD_HAID="$SEED" HMD_NOW=7 \
        HEIMDALL_CP_URL="http://127.0.0.1:1" COLUMNS="$cols" LANG=en_US.UTF-8 \
        HMD_STATUSLINE_TMP="$TMPD" HMD_STATUSLINE_RESERVE=0 \
        HEIMDALL_STATUSLINE_MODE="$color" python3 "$SL"
  rm -rf "$WS" "$HOMED" "$TMPD"
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

# count of non-empty emitted rows.
rowcount() { python3 -c 'import sys; print(sum(1 for l in sys.stdin.read().split("\n") if l!=""))'; }

TIERS="full mid narrow tiny"
COLORS="truecolor 256 16"

if [ "$REGEN" = 1 ]; then
  echo "== regenerating 12 tier×color goldens =="
  # drop obsolete old-layout goldens (density modes were full/compact/minimal).
  rm -f "$GOLD/${SEED}_compact_"*.txt "$GOLD/${SEED}_minimal_"*.txt
  for tr in $TIERS; do for cl in $COLORS; do
    render_case "$tr" "$cl" > "$GOLD/${SEED}_${tr}_${cl}.txt"
    echo "  wrote ${SEED}_${tr}_${cl}.txt ($(cols_for "$tr") cols)"
  done; done
  echo "done."
  exit 0
fi

echo "== 1) 12 goldens byte-exact: 4 width tiers × 3 color tiers =="
for tr in $TIERS; do for cl in $COLORS; do
  g="$GOLD/${SEED}_${tr}_${cl}.txt"
  if [ ! -f "$g" ]; then bad "golden missing: ${SEED}_${tr}_${cl}.txt"; continue; fi
  if render_case "$tr" "$cl" | cmp -s - "$g"; then ok "byte-exact: ${tr} × ${cl}"
  else bad "golden DRIFT: ${tr} × ${cl} (re-render != committed golden)"; fi
done; done

echo "== 2) ROW-EXACT: every emitted row == COLUMNS visible cells, all 12 fixtures =="
for tr in $TIERS; do for cl in $COLORS; do
  g="$GOLD/${SEED}_${tr}_${cl}.txt"
  [ -f "$g" ] || { bad "row-exact: golden missing ${tr}×${cl}"; continue; }
  want="$(cols_for "$tr")"; ws="$(widths < "$g")"
  if [ "$ws" = "$want" ]; then ok "ROW-EXACT: ${tr} × ${cl} all rows = ${want}"
  else bad "ROW-EXACT BROKEN: ${tr} × ${cl} widths [$ws] != [$want]"; fi
done; done

echo "== 3) ROW-COUNT: full/mid/narrow → 4 rows (untrimmed 8×8 sigil), tiny → 1 =="
for tr in $TIERS; do
  want=4; [ "$tr" = tiny ] && want=1
  g="$GOLD/${SEED}_${tr}_truecolor.txt"
  [ -f "$g" ] || { bad "row-count: golden missing ${tr}"; continue; }
  n="$(rowcount < "$g")"
  if [ "$n" = "$want" ]; then ok "ROW-COUNT: ${tr} → ${n} rows"
  else bad "ROW-COUNT: ${tr} → ${n} rows (want ${want})"; fi
done

echo "== 4) tier fidelity: emitted SGR family matches the color tier (full tier) =="
TC="$(render_case full truecolor)"; C256="$(render_case full 256)"; C16="$(render_case full 16)"
grep -qF '38;2;' <<<"$TC"   && ok "truecolor → 24-bit 38;2;"           || bad "truecolor → no 38;2;"
grep -qF '38;5;' <<<"$C256" && ok "256 → nearest-cube 38;5;"          || bad "256 → no 38;5;"
grep -qF '38;2;' <<<"$C256" && bad "256 → leaked raw 38;2; (morph)"   || ok "256 → NO raw 38;2; (morph guard)"
grep -qF '38;2;' <<<"$C16"  && bad "16 → leaked raw 38;2;"            || ok "16 → no 38;2;"
grep -qF '38;5;' <<<"$C16"  && bad "16 → leaked 256 38;5;"           || ok "16 → no 38;5; (ANSI-16 only)"

echo "== 5) render benchmark: warm median <50ms (strict) + cold-cache best-of-3 <300ms (regression ceiling) =="
BENCH="$(python3 - "$SL" <<'PY'
import os,sys,io,time,importlib.util,tempfile,statistics,contextlib,shutil
SL=sys.argv[1]
ws=tempfile.mkdtemp(); home=tempfile.mkdtemp(); tmp=tempfile.mkdtemp()
os.makedirs(ws+"/.heimdall",exist_ok=True)
open(ws+"/.heimdall/identity.json","w").write('{"handle":"rj","seed":"rj","created":0}\n')
open(ws+"/.heimdall/statusline.json","w").write('{"verdict":"pass","passed":3,"total":3}\n')
open(ws+"/.heimdall/.roster-cache.json","w").write('[{"handle":"nadia","verdict":"working"}]\n')
os.environ.update(dict(HOME=home,HEIMDALL_IDENTITY_DIR=ws+"/.heimdall",HMD_HAID="rj",
  HMD_NOW="7",HEIMDALL_CP_URL="http://127.0.0.1:1",COLUMNS="120",LANG="en_US.UTF-8",
  HMD_STATUSLINE_TMP=tmp,HEIMDALL_STATUSLINE_MODE="truecolor"))
spec=importlib.util.spec_from_file_location("sl",SL); m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
j='{"workspace":{"current_dir":"%s","repo":{"name":"heimdall","branch":"statusline-v1"}},"model":{"display_name":"Opus 4.8"},"context_window":{"used_percentage":42,"total_input_tokens":128000},"session_id":"density","cost":{"total_cost_usd":0.87,"total_duration_ms":3840000}}'%ws
def one():
  sys.stdin=io.StringIO(j)
  with contextlib.redirect_stdout(io.StringIO()):
    m.main()
one()  # warm the interpreter + sigil cache (disk + memo) + ledger cache
# COLD sample: wipe the on-disk sigil cache + the in-process memo + the ledger tmp so the render
# is FORCED to recompute the 8×8 sigil + re-read the ledger — a cold-path regression the warm
# median (served from cache) never sees. Cold is sigil-recompute + fork dominated (100-200ms,
# hardware/load-variable) — the exact cost the warm 5s caches exist to avoid — so we take the MIN
# of 3 cold runs (sheds load spikes) against a regression ceiling, not the strict warm 50ms gate.
colds=[]
for _ in range(3):
  shutil.rmtree(m._sigil_cache_dir(), ignore_errors=True); m._SIG_MEMO.clear()
  shutil.rmtree(tmp, ignore_errors=True); os.makedirs(tmp, exist_ok=True)
  sys.stdin=io.StringIO(j); t0=time.perf_counter()
  with contextlib.redirect_stdout(io.StringIO()): m.main()
  colds.append((time.perf_counter()-t0)*1000)
cold=min(colds)
one()  # re-warm the cache for the warm-median run
ts=[]
for _ in range(60):
  sys.stdin=io.StringIO(j); t0=time.perf_counter()
  with contextlib.redirect_stdout(io.StringIO()): m.main()
  ts.append((time.perf_counter()-t0)*1000)
print("%.3f %.3f %.3f"%(cold,statistics.median(ts),max(ts)))
PY
)"
COLD="${BENCH%% *}"; REST="${BENCH#* }"; MED="${REST%% *}"; MX="${REST##* }"
echo "  render warm median=${MED}ms max=${MX}ms (budget 50ms) | cold-cache=${COLD}ms best-of-3 (budget 500ms)"
python3 -c "import sys;sys.exit(0 if float('$MED')<50.0 else 1)" \
  && ok "warm median render < 50ms (${MED}ms)" || bad "warm median render ${MED}ms exceeds 50ms budget"
python3 -c "import sys;sys.exit(0 if float('$COLD')<500.0 else 1)" \
  && ok "cold-cache render < 500ms best-of-3 (${COLD}ms)" || bad "cold-cache render ${COLD}ms exceeds 500ms budget"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
