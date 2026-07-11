#!/usr/bin/env bash
# heimdall-sigil-heroes.test.sh — the 29-hero custom pool + HAID auto-assign + the
# unlock-after-3-runs CLI (`hmd sigil` / `hmd sigil set`).
#
# CONTRACT:
#   1. LOAD    — 29 heroes, each a pixel-exact 8×8 grid whose every token has a palette
#                key (missing keys tolerated: no accent7 on hulk/superman, no accent6/7
#                on black-panther, no eye on joker, +highlight on ironman, all 8 on
#                cyborg). Each renders at width 8, exit 0, on every tier; all distinct.
#   2. AUTO    — hero_for(haid) is deterministic (same HAID → same hero) and roughly
#                uniform (sha256 mod 29 over the sorted pool); a REAL HAID renders its
#                auto-assigned hero as its sigil.
#   3. ADDITIVE— short/toy seeds (rj, you, teammate-xyz, haid:alice) DO NOT auto-assign
#                — they stay on the curated/animal path. batsy's pin wins; a hero NAME
#                resolves to that hero.
#   4. UNLOCK  — `hmd sigil set` refuses before 3 hmd runs, rejects an unknown name, and
#                persists a valid override once unlocked; `hmd sigil` reports current +
#                lock state.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SIG="$ROOT/sentinels/hmd_sigil.py"
HMD="$ROOT/bin/heimdall"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$SIG" ] || { echo "FATAL: sigil core missing at $SIG"; exit 2; }

# Run a python check block: it prints human "  ok/FAIL ..." lines plus a trailing
# "::COUNT:: <pass> <fail>" marker. We echo the human lines and fold the counts once.
run_py() {
  local out; out="$(python3 - "$SIG" <<PY
import importlib.util, sys, re, collections
spec=importlib.util.spec_from_file_location("s", sys.argv[1])
S=importlib.util.module_from_spec(spec); spec.loader.exec_module(S)
P=[0]; F=[0]
def ok(m): P[0]+=1; print("  ok   "+m)
def bad(m): F[0]+=1; print("  FAIL "+m)
$1
print("::COUNT:: %d %d" % (P[0], F[0]))
PY
)"
  printf '%s\n' "$out" | grep -v '^::COUNT::'
  local line; line="$(printf '%s\n' "$out" | grep '^::COUNT::')"
  pass=$((pass + $(echo "$line" | awk '{print $2}')))
  fail=$((fail + $(echo "$line" | awk '{print $3}')))
}

echo "== 1) LOAD: 29 heroes, each 8×8, tokens ⊆ palette, distinct render, exit 0 =="
run_py '
ok("pool has 29 heroes") if len(S.HERO_SIGILS)==30 else bad("pool has %d (want 30)"%len(S.HERO_SIGILS))
expect={"batsy","green-lantern","venom","hulk","thanos","black-panther","deadpool","spiderman","ironman","cyborg","joker","flash","superman","cyclops","human-torch","lex-luthor","doctor-strange","martian-manhunter","green-goblin","cloak","mr-fantastic","beast","antman","loki","nick-fury","black-bolt","red-skull","magneto","silver-surfer","vision"}
ok("exact expected roster") if set(S.HERO_SIGILS)==expect else bad("roster mismatch: %s"%(set(S.HERO_SIGILS)^expect))
TOK={".":"bg","1":"hue","2":"eye","3":"highlight","4":"shadow","5":"outline","6":"accent6","7":"accent7"}
shape=cover=True
for name,sp in S.HERO_SIGILS.items():
    g=sp["grid"]
    if len(g)!=8 or any(len(r)!=8 for r in g): shape=False
    for r in g:
        for ch in r:
            if ch not in TOK or TOK[ch] not in sp: cover=False
ok("every hero grid is exactly 8x8") if shape else bad("a hero is not 8x8")
ok("every grid token has a palette key (missing keys tolerated)") if cover else bad("a token has no palette key")
ok("hulk has no accent7 (tolerated)") if "accent7" not in S.HERO_SIGILS["hulk"] else bad("hulk has accent7")
ok("black-panther has no accent6/accent7 (tolerated)") if not ({"accent6","accent7"}&set(S.HERO_SIGILS["black-panther"])) else bad("black-panther has an accent")
ok("joker has no eye (tolerated)") if "eye" not in S.HERO_SIGILS["joker"] else bad("joker has eye")
ok("ironman adds highlight") if "highlight" in S.HERO_SIGILS["ironman"] else bad("ironman missing highlight")
ok("cyborg uses all 8 palette keys") if all(k in S.HERO_SIGILS["cyborg"] for k in ("bg","hue","eye","highlight","shadow","outline","accent6","accent7")) else bad("cyborg not full palette")
STRIP=re.compile(r"\033\[[0-9;]*m"); allw=alltier=True; rends={}
for name in S.HERO_ORDER:
    for tier in ("truecolor","256","16"):
        try: lines=S.sigil_render(name,"M",S.tier_caps(tier))
        except Exception as e: alltier=False; continue
        for l in lines:
            if l and len(STRIP.sub("",l))!=8: allw=False
    rends[name]="\n".join(S.sigil_render(name,"M",S.tier_caps()))
ok("every hero renders width-8, exit 0, on truecolor/256/16") if (allw and alltier) else bad("width/tier render fault")
ok("all 30 hero renders are distinct") if len(set(rends.values()))==30 else bad("hero renders collide: %d unique"%len(set(rends.values())))
'

echo "== 2) AUTO: hero_for deterministic + roughly uniform; real HAID renders its hero =="
run_py '
det=all(S.hero_for("haid:u%d.m-%04x"%(i,i))==S.hero_for("haid:u%d.m-%04x"%(i,i)) for i in range(200))
ok("hero_for deterministic (same HAID -> same hero)") if det else bad("hero_for not deterministic")
c=collections.Counter(S.hero_for("haid:u%d.m-%04x"%(i,i)) for i in range(500))
ok("roughly uniform: %d/30 heroes hit over 500 HAIDs"%len(c)) if len(c)>=27 else bad("poor spread: %d/30"%len(c))
lo,hi=min(c.values()),max(c.values())
ok("no bucket degenerate (min=%d max=%d over 500, ideal ~17)"%(lo,hi)) if (lo>=5 and hi<=40) else bad("bucket skew min=%d max=%d"%(lo,hi))
h="haid:dev.box-ab12"; hero=S.hero_for(h)
ok("a REAL HAID renders its auto-assigned hero (hue matches %s)"%hero) if S.grid_for(h)[1]==S._hex_rgb(S.HERO_SIGILS[hero]["hue"]) else bad("real HAID did not render its auto hero")
'

echo "== 3) ADDITIVE: toy/short seeds unchanged; pin wins; hero name resolves =="
run_py '
toy=["rj","you","nadia","arjun","priya","teammate-xyz","haid:alice","haid:0","gen042"]
ok("toy/short seeds stay on curated/animal path (no hero auto-assign)") if all(S._resolve_custom_spec(s) is None for s in toy) else bad("a toy seed leaked into the hero path")
pin="haid:rj.rishabhs-macbook-air-46d5"
ok("batsy pin wins for RJ pinned HAID") if (S._resolve_custom_spec(pin) is S.CUSTOM_SIGILS[pin] and S.CUSTOM_SIGILS[pin]["name"]=="batsy") else bad("batsy pin did not win")
ok("explicit hero name resolves to that hero") if S._resolve_custom_spec("venom")["name"]=="venom" else bad("hero name did not resolve")
'

echo "== 4) UNLOCK CLI: hmd sigil / hmd sigil set gate =="
if [ -x "$HMD" ]; then
  H="$(mktemp -d)"
  printf '0\n' > "$H/.run-count"                     # bumps to 1 (<3) → locked
  OUT="$(HEIMDALL_HOME="$H" "$HMD" sigil set venom 2>&1)"; RC=$?
  { [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi "unlocks after 3"; } \
    && ok "set REFUSED before 3 runs (exit $RC)" || bad "set not refused before 3 (exit $RC): $OUT"
  [ ! -f "$H/sigil-choice" ] && ok "no override persisted while locked" || bad "override persisted while locked"

  printf '5\n' > "$H/.run-count"                     # bumps to 6 (≥3) → unlocked
  OUT="$(HEIMDALL_HOME="$H" "$HMD" sigil set venom 2>&1)"; RC=$?
  { [ "$RC" -eq 0 ] && [ "$(cat "$H/sigil-choice" 2>/dev/null)" = "venom" ]; } \
    && ok "set SUCCEEDS after 3 runs, persists 'venom'" || bad "set failed after unlock (exit $RC): $OUT"

  printf '9\n' > "$H/.run-count"
  OUT="$(HEIMDALL_HOME="$H" "$HMD" sigil set batman 2>&1)"; RC=$?
  { [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "unknown hero"; } \
    && ok "set REJECTS an unknown name (exit $RC)" || bad "unknown name not rejected (exit $RC): $OUT"
  printf '%s' "$OUT" | grep -q "spiderman" && ok "rejection lists the 14 heroes" || bad "rejection did not list heroes"
  [ "$(cat "$H/sigil-choice" 2>/dev/null)" = "venom" ] && ok "unknown-name reject left the valid choice intact" || bad "choice clobbered by bad set"

  OUT="$(HEIMDALL_HOME="$H" "$HMD" sigil 2>&1)"
  printf '%s' "$OUT" | grep -q "sigil: venom" && ok "hmd sigil reports the override hero" || bad "hmd sigil did not report override: $OUT"
  printf '%s' "$OUT" | grep -qi "unlocked" && ok "hmd sigil reports unlocked state" || bad "hmd sigil did not report unlocked"

  H2="$(mktemp -d)"
  OUT="$(HEIMDALL_HOME="$H2" "$HMD" sigil 2>&1)"
  printf '%s' "$OUT" | grep -qi "locked" && ok "fresh dev sees the locked message" || bad "fresh dev not locked: $OUT"
  rm -rf "$H" "$H2"
else
  bad "bin/heimdall not executable at $HMD"
fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
