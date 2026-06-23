#!/usr/bin/env bash
#
# telemetry-run.test.sh — per-run instrumentation + summary-card fill proofs
# (dossier piece c: bin/lib/run_telemetry.py + the bin/heimdall-demo card fill).
# Binds to the substrate (piece a, on main): telemetry.emit / read_events /
# new_run_id. These proofs pin the CONTRACT for the run-time half of the layer:
#
#   A. CORRELATED RUN — a simulated run emits phase + gate + token + outcome +
#      commit events, ALL under ONE run_id. read_events(run_id) returns them and
#      every event carries that run_id. FALSIFIABLE: a helper that wrote a
#      different run_id (or skipped an event_type) flips the assertion.
#
#   B. CARD FILLS FROM REAL TELEMETRY — given a run's token + commit events, the
#      card-data reader returns the SUMMED total_tokens and the commit COUNT, and
#      bin/heimdall-demo's card-state writer emits a heimdall-state.json whose
#      budget.total_tokens equals that real sum. Rendering summary-card over it
#      shows the REAL number — not the empty-dash, never a hand-typed constant.
#      FALSIFIABLE: a reader that returned 0/None, or a writer that hard-coded a
#      value, flips it.
#
#   C. DENY→FIX→PASS RECORD — the demo's staged secret-scan failure produces an
#      ORDERED gate arc for one run_id: gate{secret-scan, blocked, loc=file:line}
#      → a fix phase → gate{secret-scan, passed}. The blocked event carries a
#      loc (stage + file:line). FALSIFIABLE: a missing blocked/passed event, a
#      missing loc, or a passed-before-blocked order flips the assertion.
#
#   D. NO FABRICATED vs-raw-CC — the card-state the demo writes from real
#      telemetry carries NO invented savings figure: the budget block has
#      total_tokens (measured) but NO raw_cc / savings / vs_raw key, and the
#      token event's cost_source is an HONEST provenance tag (measured/derived/
#      reported/null), never an asserted bare savings number. FALSIFIABLE: a
#      writer that injected a "saved X vs raw-CC" number flips it.
#
#   E. DISABLED ⇒ CARD "—" IDENTICAL — HEIMDALL_TELEMETRY=off ⇒ the per-run
#      emitters are no-ops (no events.ndjson), card-data returns the honest-empty
#      shape, the card-state writer writes NO budget (so summary-card degrades to
#      "—" exactly as today), and nothing crashes (exit 0). FALSIFIABLE: an
#      emitter that wrote while disabled, or a writer that crashed, flips it.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
RUNLIB="$REPO/bin/lib/run_telemetry.py"
CARD="$REPO/bin/summary-card"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
[ -f "$RUNLIB" ] || { echo "FATAL: run_telemetry lib missing at $RUNLIB"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export REPO RUNLIB CARD PY

# A simulated run: drive the per-run emitters through the lib's CLI exactly as
# the orchestrator/demo would, under one run_id, into a pinned telemetry home.
HOME_A="$WORK/home-a"
RUN_ID="$("$PY" "$RUNLIB" new-run-id)"
[ -n "$RUN_ID" ] || { echo "FATAL: new-run-id produced nothing"; exit 2; }

# ─────────────────────────────────────────────────────────────────────────────
# A. CORRELATED RUN — phase+gate+token+outcome+commit under one run_id.
# ─────────────────────────────────────────────────────────────────────────────
echo "A. CORRELATED RUN (phase+gate+token+outcome+commit, one run_id):"
TOKENS_JSON='{"input_tokens":1200,"output_tokens":800,"cache_creation_tokens":0,"cache_read_tokens":15000,"total_tokens":17000,"total_cost_usd":0.21,"cost_source":"reported"}'
"$PY" "$RUNLIB" phase   --run-id "$RUN_ID" --home "$HOME_A" --phase planning --outcome succeeded --duration-ms 4200 >/dev/null
"$PY" "$RUNLIB" gate    --run-id "$RUN_ID" --home "$HOME_A" --gate test --outcome passed >/dev/null
"$PY" "$RUNLIB" token   --run-id "$RUN_ID" --home "$HOME_A" --tokens "$TOKENS_JSON" >/dev/null
"$PY" "$RUNLIB" outcome --run-id "$RUN_ID" --home "$HOME_A" --outcome passed >/dev/null
"$PY" "$RUNLIB" commit  --run-id "$RUN_ID" --home "$HOME_A" --commit aaa1111 >/dev/null
"$PY" "$RUNLIB" commit  --run-id "$RUN_ID" --home "$HOME_A" --commit bbb2222 >/dev/null

cat > "$WORK/check_corr.py" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "bin", "lib"))
import telemetry
ev = telemetry.read_events(home=os.environ["HOME_A"], run_id=os.environ["RUN_ID"])
types = sorted({e.get("event_type") for e in ev})
need = {"phase", "gate", "token", "outcome", "commit"}
if not need.issubset(set(types)):
    print("MISSING types=%s" % types); sys.exit(1)
# every event correlates to the one run_id
if any(e.get("run_id") != os.environ["RUN_ID"] for e in ev):
    print("RUNID_MISMATCH"); sys.exit(1)
print("CORR_OK")
PYEOF
rc=0
OUT="$(HOME_A="$HOME_A" RUN_ID="$RUN_ID" "$PY" "$WORK/check_corr.py" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q CORR_OK; then
  ok "phase+gate+token+outcome+commit all present under one run_id"
else
  bad "correlation failed: $OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# B. CARD FILLS FROM REAL TELEMETRY — summed tokens + commit count → card.
# ─────────────────────────────────────────────────────────────────────────────
echo "B. CARD FILLS FROM REAL TELEMETRY (tokens + commits, not '—'):"
# card-data reports the real figures for the run.
CD_JSON="$("$PY" "$RUNLIB" card-data --run-id "$RUN_ID" --home "$HOME_A")"
cat > "$WORK/check_cd.py" <<'PYEOF'
import json, os, sys
d = json.loads(os.environ["CD"])
# 17000 from the single token event; 2 commit events
if d.get("total_tokens") != 17000:
    print("TOKENS_WRONG=%r" % d.get("total_tokens")); sys.exit(1)
if d.get("commits") != 2:
    print("COMMITS_WRONG=%r" % d.get("commits")); sys.exit(1)
print("CD_OK")
PYEOF
rc=0
OUT="$(CD="$CD_JSON" "$PY" "$WORK/check_cd.py" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q CD_OK; then
  ok "card-data returns summed total_tokens (17000) + commit count (2)"
else
  bad "card-data wrong: $OUT (raw: $CD_JSON)"
fi

# The card-state writer materializes a heimdall-state.json from REAL telemetry,
# and summary-card renders the real token figure (NOT "—") from it.
PROJ_B="$WORK/proj-b"
mkdir -p "$PROJ_B/.planning"
"$PY" "$RUNLIB" card-state --run-id "$RUN_ID" --home "$HOME_A" --project "$PROJ_B" >/dev/null
if [ -f "$PROJ_B/heimdall-state.json" ]; then
  ok "card-state wrote heimdall-state.json from real telemetry"
else
  bad "card-state did not write heimdall-state.json"
fi
cat > "$WORK/check_state.py" <<'PYEOF'
import json, os, sys
s = json.load(open(os.path.join(os.environ["PROJ_B"], "heimdall-state.json")))
b = s.get("budget", {}) or {}
if b.get("total_tokens") != 17000:
    print("STATE_TOKENS_WRONG=%r" % b.get("total_tokens")); sys.exit(1)
print("STATE_OK")
PYEOF
rc=0
OUT="$(PROJ_B="$PROJ_B" "$PY" "$WORK/check_state.py" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q STATE_OK; then
  ok "heimdall-state.json budget.total_tokens == real telemetry sum (17000)"
else
  bad "state token mismatch: $OUT"
fi
# Render the card; the tokens row must show the real figure (17.0k), not the dash.
if [ -x "$CARD" ]; then
  CARD_OUT="$(TERM=dumb COLORTERM= "$CARD" "$PROJ_B" 2>/dev/null || true)"
  # strip ANSI, find the tokens row
  TOK_ROW="$(printf '%s\n' "$CARD_OUT" | sed -E 's/\x1b\[[0-9;]*m//g' | grep -i 'tokens' || true)"
  if printf '%s' "$TOK_ROW" | grep -q '17.0k'; then
    ok "summary-card tokens row shows REAL 17.0k (filled from telemetry, not '—')"
  else
    bad "card tokens row not filled from real telemetry: [$TOK_ROW]"
  fi
else
  bad "summary-card not executable at $CARD"
fi

# ─────────────────────────────────────────────────────────────────────────────
# C. DENY→FIX→PASS RECORD — gate blocked(loc) → fix phase → gate passed.
# ─────────────────────────────────────────────────────────────────────────────
echo "C. DENY→FIX→PASS RECORD (blocked w/ loc → fix phase → passed):"
HOME_C="$WORK/home-c"
RUN_C="$("$PY" "$RUNLIB" new-run-id)"
"$PY" "$RUNLIB" gate  --run-id "$RUN_C" --home "$HOME_C" --gate secret-scan --outcome blocked --loc config.py:5 >/dev/null
"$PY" "$RUNLIB" phase --run-id "$RUN_C" --home "$HOME_C" --phase waves --outcome started >/dev/null
"$PY" "$RUNLIB" gate  --run-id "$RUN_C" --home "$HOME_C" --gate secret-scan --outcome passed >/dev/null
cat > "$WORK/check_arc.py" <<'PYEOF'
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "bin", "lib"))
import telemetry
ev = telemetry.read_events(home=os.environ["HOME_C"], run_id=os.environ["RUN_C"])
gates = [e for e in ev if e.get("event_type") == "gate" and e.get("gate") == "secret-scan"]
blocked = next((e for e in gates if e.get("outcome") == "blocked"), None)
passed  = next((e for e in gates if e.get("outcome") == "passed"), None)
if blocked is None:
    print("NO_BLOCKED"); sys.exit(1)
if not blocked.get("loc"):
    print("BLOCKED_NO_LOC"); sys.exit(1)
if passed is None:
    print("NO_PASSED"); sys.exit(1)
# ordering: blocked before passed in the recorded stream
ib = ev.index(blocked); ip = ev.index(passed)
if not (ib < ip):
    print("ORDER_WRONG ib=%d ip=%d" % (ib, ip)); sys.exit(1)
# a fix phase sits between them
fixes = [i for i, e in enumerate(ev) if e.get("event_type") == "phase" and ib < i < ip]
if not fixes:
    print("NO_FIX_PHASE_BETWEEN"); sys.exit(1)
print("ARC_OK loc=%s" % blocked.get("loc"))
PYEOF
rc=0
OUT="$(HOME_C="$HOME_C" RUN_C="$RUN_C" "$PY" "$WORK/check_arc.py" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q ARC_OK; then
  ok "recorded blocked(loc)→fix phase→passed for one run_id ($OUT)"
else
  bad "deny→fix→pass arc not recorded: $OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# D. NO FABRICATED vs-raw-CC — state carries measured tokens, NO savings figure.
# ─────────────────────────────────────────────────────────────────────────────
echo "D. NO FABRICATED vs-raw-CC (honest provenance, no invented savings):"
cat > "$WORK/check_honest.py" <<'PYEOF'
import json, os, sys
s = json.load(open(os.path.join(os.environ["PROJ_B"], "heimdall-state.json")))
flat = json.dumps(s).lower()
# the writer must never author a fabricated savings / vs-raw-CC number.
for banned in ("raw_cc", "raw-cc", "vs_raw", "savings", "saved", "percent_saved"):
    if banned in flat:
        print("FABRICATED_KEY=%s" % banned); sys.exit(1)
# but the measured figure IS present (honesty = measured-not-asserted).
if (s.get("budget", {}) or {}).get("total_tokens") != 17000:
    print("MEASURED_MISSING"); sys.exit(1)
print("HONEST_OK")
PYEOF
rc=0
OUT="$(PROJ_B="$PROJ_B" "$PY" "$WORK/check_honest.py" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q HONEST_OK; then
  ok "card-state carries measured tokens but NO fabricated vs-raw-CC number"
else
  bad "honesty violated: $OUT"
fi
# The token event itself carries an honest cost_source provenance tag.
cat > "$WORK/check_prov.py" <<'PYEOF'
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "bin", "lib"))
import telemetry
ev = telemetry.read_events(home=os.environ["HOME_A"], run_id=os.environ["RUN_ID"])
toks = [e for e in ev if e.get("event_type") == "token"]
if not toks:
    print("NO_TOKEN_EVENT"); sys.exit(1)
t = toks[0].get("tokens") or {}
cs = t.get("cost_source")
if cs not in ("measured", "reported", "derived", None):
    print("BAD_PROVENANCE=%r" % cs); sys.exit(1)
print("PROV_OK cs=%r" % cs)
PYEOF
rc=0
OUT="$(HOME_A="$HOME_A" RUN_ID="$RUN_ID" "$PY" "$WORK/check_prov.py" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q PROV_OK; then
  ok "token event carries an honest cost_source provenance tag ($OUT)"
else
  bad "provenance tag missing/invalid: $OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# E. DISABLED ⇒ CARD "—" IDENTICAL — off ⇒ no events, card degrades, no crash.
# ─────────────────────────────────────────────────────────────────────────────
echo "E. DISABLED ⇒ CARD '—' IDENTICAL (off ⇒ no-op, no regression, no crash):"
HOME_E="$WORK/home-e"
RUN_E="$("$PY" "$RUNLIB" new-run-id)"
rc=0
HEIMDALL_TELEMETRY=off "$PY" "$RUNLIB" token  --run-id "$RUN_E" --home "$HOME_E" --tokens "$TOKENS_JSON" >/dev/null 2>&1 || rc=$?
HEIMDALL_TELEMETRY=off "$PY" "$RUNLIB" commit --run-id "$RUN_E" --home "$HOME_E" --commit ccc3333 >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$HOME_E/telemetry/events.ndjson" ]; then
  ok "disabled emitters are a no-op: no events.ndjson, exit 0"
else
  bad "disabled telemetry still wrote a store or crashed (rc=$rc)"
fi
# card-state under disabled telemetry writes NO budget (so the card stays "—").
PROJ_E="$WORK/proj-e"
mkdir -p "$PROJ_E/.planning"
rc=0
HEIMDALL_TELEMETRY=off "$PY" "$RUNLIB" card-state --run-id "$RUN_E" --home "$HOME_E" --project "$PROJ_E" >/dev/null 2>&1 || rc=$?
cat > "$WORK/check_disabled_state.py" <<'PYEOF'
import json, os, sys
p = os.path.join(os.environ["PROJ_E"], "heimdall-state.json")
if not os.path.exists(p):
    print("NO_STATE_OK"); sys.exit(0)   # absent state ⇒ card degrades to "—"
s = json.load(open(p))
b = s.get("budget", {}) or {}
# a state may exist (gate flags) but must carry NO real token figure when disabled
if b.get("total_tokens") not in (None, "-", 0):
    print("DISABLED_HAS_TOKENS=%r" % b.get("total_tokens")); sys.exit(1)
print("NO_STATE_OK")
PYEOF
rc2=0
OUT="$(PROJ_E="$PROJ_E" "$PY" "$WORK/check_disabled_state.py" 2>&1)" || rc2=$?
if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] && printf '%s' "$OUT" | grep -q NO_STATE_OK; then
  ok "disabled card-state writes no token budget (card degrades to '—'), no crash"
else
  bad "disabled card-state regressed: rc=$rc rc2=$rc2 out=$OUT"
fi
# Render the card over the disabled project: the tokens row must show "—".
if [ -x "$CARD" ]; then
  CARD_E="$(TERM=dumb COLORTERM= "$CARD" "$PROJ_E" 2>/dev/null || true)"
  TOK_E="$(printf '%s\n' "$CARD_E" | sed -E 's/\x1b\[[0-9;]*m//g' | grep -i 'tokens' || true)"
  if printf '%s' "$TOK_E" | grep -q '—'; then
    ok "summary-card tokens row degrades to '—' under disabled telemetry (no regression)"
  else
    bad "card did not degrade to '—' when telemetry disabled: [$TOK_E]"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# F. END-TO-END DEMO ARC — bin/heimdall-demo emits the REAL per-run record.
#    The unit proofs above pin the lib's CLI surface; this proof pins the WIRING:
#    the narrated demo arc (planning→waves→secret-scan blocked→fix→passed) emits
#    phase+gate+commit+outcome events under ONE run_id, with the deny→fix→pass
#    gate record (blocked w/ loc → fix phase → passed) the dossier §4 demands, and
#    materializes its heimdall-state.json from REAL telemetry (no token event ⇒
#    card stays honest "—", never a fabricated savings number).
#
#    The arc only renders under a TTY (should_narrate needs -t 1/-t 0) and its
#    catch needs a real secret-scan verdict. We drive it under a real PTY via
#    `script` and route the gate through a FAITHFUL gitleaks wrapper that scans
#    the STAGED DIFF via the real gitleaks (real scanner, correct staged scope) —
#    the verdict stays genuine, only the staged-scan invocation is normalized for
#    the local gitleaks. When `script` or `gitleaks` is unavailable, the proof
#    SKIPS (counted neither pass nor fail) rather than giving a false signal.
# ─────────────────────────────────────────────────────────────────────────────
echo "F. END-TO-END DEMO ARC (real deny→fix→pass record + honest card fill):"
DEMO="$REPO/bin/heimdall-demo"
SCRIPT_BIN="$(command -v script || true)"
GL_BIN="$(command -v gitleaks || true)"
if [ ! -x "$DEMO" ]; then
  bad "bin/heimdall-demo not executable at $DEMO"
elif [ -z "$SCRIPT_BIN" ] || [ -z "$GL_BIN" ]; then
  printf '  \033[33mSKIP\033[0m demo arc (needs `script` + `gitleaks`; not on PATH)\n'
else
  DHOME="$WORK/demo-home"; mkdir -p "$DHOME"
  DWRAP="$WORK/demo-bin"; mkdir -p "$DWRAP"
  # Faithful gitleaks wrapper: `gitleaks git --staged …` → scan ONLY the staged
  # diff through the REAL gitleaks `stdin` mode (correct scope + a genuine
  # verdict); every other gitleaks invocation passes straight through untouched.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "$1" = "git" ]; then shift; git diff --cached | %q stdin --no-banner --redact >/dev/null 2>&1; exit $?; fi\n' "$GL_BIN"
    printf 'exec %q "$@"\n' "$GL_BIN"
  } > "$DWRAP/gitleaks"
  chmod +x "$DWRAP/gitleaks"
  DLOG="$WORK/demo.log"
  # Drive the first-run narrated arc once under a real PTY. `script` differs by
  # platform: BSD/macOS is `script -q FILE CMD…`; GNU is `script -q -c "CMD" FILE`.
  if "$SCRIPT_BIN" -q "$DLOG" true </dev/null >/dev/null 2>&1; then
    PATH="$DWRAP:$PATH" HEIMDALL_HOME="$DHOME" TERM=xterm-256color \
      "$SCRIPT_BIN" -q "$DLOG" bash "$DEMO" --intro </dev/null >/dev/null 2>&1 || true
  else
    PATH="$DWRAP:$PATH" HEIMDALL_HOME="$DHOME" TERM=xterm-256color \
      "$SCRIPT_BIN" -qc "bash '$DEMO' --intro" "$DLOG" </dev/null >/dev/null 2>&1 || true
  fi

  cat > "$WORK/check_demo.py" <<'PYEOF'
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "bin", "lib"))
import telemetry
ev = telemetry.read_events(home=os.environ["DHOME"])
if not ev:
    print("NO_EVENTS"); sys.exit(1)
# one run_id correlates the whole arc
rids = {e.get("run_id") for e in ev}
if len(rids) != 1 or None in rids:
    print("RUNID_NOT_SINGLE=%r" % rids); sys.exit(1)
types = {e.get("event_type") for e in ev}
for need in ("phase", "gate", "commit", "outcome"):
    if need not in types:
        print("MISSING_TYPE=%s have=%s" % (need, sorted(types))); sys.exit(1)
# deny→fix→pass: gate blocked(loc) → fix phase → gate passed, in order
gates = [(i, e) for i, e in enumerate(ev)
         if e.get("event_type") == "gate" and e.get("gate") == "secret-scan"]
blk = next((i for i, e in gates if e.get("outcome") == "blocked"), None)
pas = next((i for i, e in gates if e.get("outcome") == "passed"), None)
if blk is None:
    print("NO_BLOCKED"); sys.exit(1)
if not ev[blk].get("loc"):
    print("BLOCKED_NO_LOC"); sys.exit(1)
if pas is None:
    print("NO_PASSED"); sys.exit(1)
fix = [i for i, e in enumerate(ev)
       if e.get("event_type") == "phase" and blk < i < pas]
if not (blk < pas and fix):
    print("ARC_ORDER_WRONG blk=%s fix=%s pas=%s" % (blk, fix, pas)); sys.exit(1)
# outcome passed at the end
if not any(e.get("event_type") == "outcome" and e.get("outcome") == "passed" for e in ev):
    print("NO_PASS_OUTCOME"); sys.exit(1)
# the commit event carries a real short SHA (non-empty)
csha = [e.get("commit") for e in ev if e.get("event_type") == "commit" and e.get("commit")]
if not csha:
    print("NO_COMMIT_SHA"); sys.exit(1)
print("DEMO_ARC_OK loc=%s sha=%s" % (ev[blk].get("loc"), csha[0]))
PYEOF
  rc=0
  OUT="$(DHOME="$DHOME" "$PY" "$WORK/check_demo.py" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q DEMO_ARC_OK; then
    ok "demo arc emits one-run_id phase+gate+commit+outcome with deny→fix→pass ($OUT)"
  else
    bad "demo arc telemetry wiring failed: $OUT"
  fi

  # HONESTY: the demo spends no model tokens ⇒ NO token event ⇒ card-data shows
  # tokens '—' and NO fabricated savings figure anywhere in the run's record.
  cat > "$WORK/check_demo_honest.py" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "bin", "lib"))
import telemetry, run_telemetry
ev = telemetry.read_events(home=os.environ["DHOME"])
rid = next((e.get("run_id") for e in ev if e.get("run_id")), None)
cd = run_telemetry.card_data(rid, home=os.environ["DHOME"])
# no token event ⇒ honest-empty tokens (the card degrades to "—", not a number)
if cd.get("total_tokens") is not None or cd.get("has_tokens"):
    print("UNEXPECTED_TOKENS=%r" % cd.get("total_tokens")); sys.exit(1)
# no event in the whole run carries a fabricated savings / vs-raw-CC figure
flat = json.dumps(ev).lower()
for banned in ("raw_cc", "raw-cc", "vs_raw", "savings", "percent_saved"):
    if banned in flat:
        print("FABRICATED=%s" % banned); sys.exit(1)
print("DEMO_HONEST_OK tokens=%r commits=%d" % (cd.get("total_tokens"), cd.get("commits")))
PYEOF
  rc=0
  OUT="$(DHOME="$DHOME" "$PY" "$WORK/check_demo_honest.py" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q DEMO_HONEST_OK; then
    ok "demo run carries NO token event (card '—') + NO fabricated vs-raw-CC ($OUT)"
  else
    bad "demo honesty violated: $OUT"
  fi

  # The demo no longer hard-codes its state from a literal: the card-state writer
  # is the data source. Assert the demo source routes the arc through the lib
  # (the wiring the proof above exercises) — falsifiable if a refactor drops it.
  # The emit calls may wrap across lines (gate on one, --outcome on the next), so
  # match the flags directly rather than on a single physical line.
  if grep -q -- '--outcome blocked' "$DEMO" \
     && grep -q -- '--outcome passed' "$DEMO" \
     && grep -q 'tlm gate ' "$DEMO" \
     && grep -q 'tlm card-state' "$DEMO"; then
    ok "bin/heimdall-demo routes the deny→fix→pass arc + card fill through the telemetry lib"
  else
    bad "bin/heimdall-demo is missing the telemetry wiring calls"
  fi
fi

echo
TOTAL=$((PASS + FAIL))
printf 'telemetry-run.test.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
