#!/usr/bin/env bash
#
# heimdall-ledger-reader.test.sh — the STATUSLINE LEDGER READER (sentinels/hmd_ledger.py).
#
# hmd_ledger.read_status(session_id) is how the full-bleed statusline consumes the
# ledger. It reads ${HEIMDALL_HOME:-~/.heimdall}/ledger/status.json (spec §6 schema
# {daemon, gates[]{id,state,detail}, verdict{state,label}, team[]{user,sigil,branch,
# state,ts}}) THROUGH a per-session 5s file cache (spec §5, keyed by session_id — NOT
# $$), and DEGRADES-not-crashes: missing / malformed → {daemon:"down", gates:[],
# verdict:None, team:[]}, with a LEGACY fallback to the old .heimdall/statusline.json
# {verdict,passed,total,gate,ts} when the new status.json is absent.
#
# THIS SUITE LOCKS:
#   1. mock status.json → the normalized shape (gates {id,state,detail}; verdict
#      {state,label}; team {user,sigil,branch,state,ts}).
#   2. missing file → daemon:"down" + empty gates/team, verdict None (no crash).
#   3. malformed JSON → the SAME safe default (no crash).
#   4. legacy statusline.json → mapped into the normalized shape.
#   5. team filter: drops heartbeats >5min old, EXCLUDES self, caps at 3 + "+N".
#   6. gate-deny teammate keeps state "deny" (the statusline colors the name red).
#   7. 5s cache HIT: a 2nd read within 5s does NOT re-read the source status.json
#      (proven by mutating the source after the 1st read — the cache wins);
#      then an expired cache (mtime aged past 5s) DOES re-read.
#   8. py_compile clean.
#   9. bin/falsify rr-multitenant-isolation --assert-score 1.0 == 1.0 (isolation).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MOD="$ROOT/sentinels/hmd_ledger.py"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f "$MOD" ] || { echo "FATAL: reader missing at $MOD"; exit 2; }

# Run a python snippet with hmd_ledger importable + a fully ISOLATED runtime home,
# legacy path, identity, and /tmp cache dir. $1=body. Extra env via caller.
pyrun() {
  env -i PATH="$PATH" LANG=en_US.UTF-8 \
      HEIMDALL_HOME="${HEIMDALL_HOME:-}" \
      HEIMDALL_STATE="${HEIMDALL_STATE:-}" \
      HEIMDALL_IDENTITY_DIR="${HEIMDALL_IDENTITY_DIR:-}" \
      HMD_STATUSLINE_TMP="${HMD_STATUSLINE_TMP:-}" \
      HMD_NOW="${HMD_NOW:-}" HMD_HANDLE="${HMD_HANDLE:-}" HMD_HAID="${HMD_HAID:-}" \
      python3 -c "
import sys
sys.path.insert(0, '$ROOT/sentinels')
import hmd_ledger as L
$1
"
}

fresh() { WS="$(mktemp -d)"; TMPC="$(mktemp -d)"; mkdir -p "$WS/ledger" "$WS/repo/.heimdall"; }
clean() { rm -rf "$WS" "$TMPC" 2>/dev/null; }

# ── 1) mock status.json → normalized shape ──────────────────────────────────
echo "== 1) full status.json parses to the normalized shape =="
fresh
cat > "$WS/ledger/status.json" <<'JSON'
{"daemon": true,
 "gates": [{"id":"tests","state":"pass","detail":"47/47"},
           {"id":"lint","state":"running","detail":""},
           {"id":"typecheck","state":"deny","detail":"3 errors"}],
 "verdict": {"state":"deny","label":"BIFRÖST CLOSED"},
 "team": []}
JSON
OUT="$(HEIMDALL_HOME="$WS" HMD_STATUSLINE_TMP="$TMPC" HMD_NOW=1000 pyrun '
r = L.read_status("sess-1")
g = r["gates"]
assert r["daemon"] == "up", r["daemon"]
assert len(g) == 3, g
assert g[0] == {"id":"tests","state":"pass","detail":"47/47"}, g[0]
assert g[1]["state"] == "running", g[1]
assert g[2]["state"] == "deny" and g[2]["detail"] == "3 errors", g[2]
assert r["verdict"] == {"state":"deny","label":"BIFRÖST CLOSED"}, r["verdict"]
assert r["team"] == [] and r["team_overflow"] == 0
print("OK")
' 2>&1)"
[ "$OUT" = "OK" ] && ok "status.json → {daemon,gates,verdict,team} normalized" || bad "shape mismatch: $OUT"
clean

# ── 2) missing file → safe default ──────────────────────────────────────────
echo "== 2) missing status.json → daemon:down + empty (no crash) =="
fresh
OUT="$(HEIMDALL_HOME="$WS" HEIMDALL_STATE="$WS/repo/.heimdall/statusline.json" \
       HMD_STATUSLINE_TMP="$TMPC" HMD_NOW=1000 pyrun '
r = L.read_status("sess-missing")
assert r == {"daemon":"down","gates":[],"verdict":None,"team":[],"team_overflow":0}, r
print("OK")
' 2>&1)"
[ "$OUT" = "OK" ] && ok "missing file → exact safe default" || bad "missing-file default wrong: $OUT"
clean

# ── 3) malformed JSON → same safe default ───────────────────────────────────
echo "== 3) malformed status.json → same safe default (no crash) =="
fresh
printf '{ this is not json ][' > "$WS/ledger/status.json"
OUT="$(HEIMDALL_HOME="$WS" HEIMDALL_STATE="$WS/repo/.heimdall/statusline.json" \
       HMD_STATUSLINE_TMP="$TMPC" HMD_NOW=1000 pyrun '
r = L.read_status("sess-bad")
assert r["daemon"] == "down" and r["gates"] == [] and r["verdict"] is None and r["team"] == [], r
print("OK")
' 2>&1)"
[ "$OUT" = "OK" ] && ok "malformed JSON → safe default" || bad "malformed default wrong: $OUT"
clean

# ── 4) legacy statusline.json → mapped ──────────────────────────────────────
echo "== 4) legacy .heimdall/statusline.json → mapped into shape =="
fresh   # NOTE: no ledger/status.json written → forces the legacy fallback
printf '{"verdict":"pass","passed":3,"total":3,"gate":"quality-gates","ts":900}' \
  > "$WS/repo/.heimdall/statusline.json"
OUT="$(HEIMDALL_HOME="$WS" HEIMDALL_STATE="$WS/repo/.heimdall/statusline.json" \
       HMD_STATUSLINE_TMP="$TMPC" HMD_NOW=1000 pyrun '
r = L.read_status("sess-legacy")
assert r["daemon"] == "down", r["daemon"]
assert len(r["gates"]) == 1, r["gates"]
assert r["gates"][0]["id"] == "quality-gates", r["gates"][0]
assert r["gates"][0]["state"] == "pass", r["gates"][0]
assert r["gates"][0]["detail"] == "3/3", r["gates"][0]
assert r["verdict"]["state"] == "pass", r["verdict"]
print("OK")
' 2>&1)"
[ "$OUT" = "OK" ] && ok "legacy statusline.json mapped to normalized shape" || bad "legacy mapping wrong: $OUT"
clean

# ── 5) team filter: stale-drop + self-exclude + cap 3 (+N) + deny-preserve ──
echo "== 5) team filter: >5min drop, self-exclude, cap 3 (+N), deny preserved =="
fresh
# now=100000. self = "rj". stale entry ts=99000 (>300s old) must drop. 5 fresh
# non-self members (one denies) → capped to 3 + overflow 2. self excluded.
cat > "$WS/ledger/status.json" <<'JSON'
{"daemon": false, "gates": [], "verdict": null,
 "team": [
   {"user":"rj",    "sigil":"A","branch":"main","state":"pass",   "ts":99999},
   {"user":"stale", "sigil":"S","branch":"old", "state":"pass",   "ts":99000},
   {"user":"mira",  "sigil":"M","branch":"feat","state":"deny",   "ts":99900},
   {"user":"kai",   "sigil":"K","branch":"feat","state":"running","ts":99950},
   {"user":"lena",  "sigil":"L","branch":"dev", "state":"pass",   "ts":99960},
   {"user":"omar",  "sigil":"O","branch":"dev", "state":"pass",   "ts":99970},
   {"user":"priya", "sigil":"P","branch":"dev", "state":"pass",   "ts":99980}
 ]}
JSON
OUT="$(HEIMDALL_HOME="$WS" HMD_STATUSLINE_TMP="$TMPC" HMD_NOW=100000 HMD_HANDLE=rj pyrun '
r = L.read_status("sess-team")
t = r["team"]
users = [m["user"] for m in t]
assert "rj" not in users, ("self not excluded", users)
assert "stale" not in users, ("stale not dropped", users)
assert len(t) == 3, ("cap not 3", users)
assert r["team_overflow"] == 2, ("overflow wrong", r["team_overflow"])
# deny teammate keeps state deny → statusline reds the name
mira = [m for m in t if m["user"]=="mira"]
assert mira and mira[0]["state"] == "deny", ("deny not preserved", t)
# normalized member shape
for m in t:
    assert set(m.keys()) >= {"user","sigil","branch","state","ts"}, m
print("OK")
' 2>&1)"
[ "$OUT" = "OK" ] && ok "team filter: stale-drop + self-exclude + cap3(+2) + deny kept" || bad "team filter wrong: $OUT"
clean

# ── 6) 5s cache hit: 2nd read within 5s does NOT re-read the source ──────────
echo "== 6) 5s cache: mutate source after 1st read → cache wins; expiry re-reads =="
fresh
cat > "$WS/ledger/status.json" <<'JSON'
{"daemon": true, "gates": [{"id":"g","state":"pass","detail":"1/1"}], "verdict": {"state":"pass","label":"GATE"}, "team": []}
JSON
OUT="$(HEIMDALL_HOME="$WS" HMD_STATUSLINE_TMP="$TMPC" pyrun '
import os, json, time
sp = os.path.join(os.environ["HEIMDALL_HOME"], "ledger", "status.json")
# 1st read (real now) — populates the per-session cache
r1 = L.read_status("cache-key")
assert r1["gates"][0]["state"] == "pass", r1
# MUTATE the source to a deny verdict + bump mtime — if the reader re-reads disk
# within 5s it would see this; the cache MUST hide it.
json.dump({"daemon":True,"gates":[{"id":"g","state":"deny","detail":"0/1"}],
           "verdict":{"state":"deny","label":"CLOSED"},"team":[]}, open(sp,"w"))
os.utime(sp, None)
r2 = L.read_status("cache-key")
assert r2["gates"][0]["state"] == "pass", ("cache did NOT win — disk was re-read", r2)
# now AGE the cache file past the 5s TTL → the reader must re-read the source
cp = L._cache_path("cache-key")
assert os.path.exists(cp), ("no cache file written", cp)
old = time.time() - 10
os.utime(cp, (old, old))
r3 = L.read_status("cache-key")
assert r3["gates"][0]["state"] == "deny", ("expired cache did not re-read", r3)
# cache never keys on the pid
assert str(os.getpid()) not in os.path.basename(cp), cp
print("OK")
' 2>&1)"
[ "$OUT" = "OK" ] && ok "5s cache: hit hides mutated source; expiry re-reads; not pid-keyed" || bad "cache behavior wrong: $OUT"
clean

# ── 7) py_compile ───────────────────────────────────────────────────────────
echo "== 7) py_compile =="
if python3 -m py_compile "$MOD" 2>/tmp/hmd_ledger_pc.$$; then ok "py_compile clean"
else bad "py_compile failed: $(cat /tmp/hmd_ledger_pc.$$)"; fi
rm -f /tmp/hmd_ledger_pc.$$

# ── 8) isolation falsifier ──────────────────────────────────────────────────
echo "== 8) bin/falsify rr-multitenant-isolation --assert-score 1.0 == 1.0 =="
if "$ROOT/bin/falsify" rr-multitenant-isolation --assert-score 1.0 >/tmp/hmd_ledger_fz.$$ 2>&1 \
   && grep -q "= 1.0000 (golden passing)" /tmp/hmd_ledger_fz.$$; then
  ok "multitenant isolation falsifiability score == 1.0"
else bad "falsify isolation != 1.0: $(tail -3 /tmp/hmd_ledger_fz.$$)"; fi
rm -f /tmp/hmd_ledger_fz.$$

echo
echo "  ── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ] || exit 1
