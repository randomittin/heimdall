#!/usr/bin/env bash
# heimdall-run-receipt.test.sh — the Heimdall Run Receipt (bin/summary-card --receipt).
#
# The Run Receipt is the flagship shareable artifact: ONE screenshot bundling a
# whole run's proof — swarm + every gate + leaner-code + cost, sigil-branded. It
# is rendered by `summary-card --receipt` and auto-emitted at SessionEnd.
#
# This suite proves the receipt tells the TRUTH, never green-washes, and never
# fabricates a number:
#   * with real seeded data every row renders its REAL value (no dash where data
#     exists);
#   * a FAILING gate shows the cross (not the check) and closes the Bifrost;
#   * the "vs raw CC" slot is est./blank when the holdout has NO control arm —
#     a fabricated % is NEVER emitted (Heimdall's own measured-not-asserted rule);
#   * a missing source degrades ITS row without crashing (exit 0, box still drawn);
#   * pipe/CI mode is ANSI-clean (no raw escape codes).
#
# Every field is fed through an env-override seam (HEIMDALL_RECEIPT_*) so the card
# reads REAL emitter shapes (agent-pool status, verify-edits --json, oracle
# report.json, holdout figure JSON, reuse record, ponytail results) from fixtures
# — the SAME shapes the production defaults read.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CARD="$ROOT/bin/summary-card"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "heimdall-run-receipt — the flagship shareable proof artifact"

[ -x "$CARD" ] || { bad "summary-card not executable at $CARD"; echo "1..$((PASS+FAIL))"; exit 1; }

strip_ansi() { sed -E $'s/\x1b\\[[0-9;]*m//g'; }

# ── Seed a full, all-green run ────────────────────────────────────────────────
PROJ="$WORK/proj"
mkdir -p "$PROJ/.planning"
cat > "$PROJ/heimdall-state.json" <<'JSON'
{ "quality_gates": {"tests_passing": true, "lint_clean": true, "dirty": false},
  "budget": {"total_tokens": 34000, "token_limit": 600000} }
JSON
cat > "$PROJ/.planning/STATE.md" <<'MD'
title: ship the flagship run receipt
current_phase: S-flagship
MD

ORACLES="$WORK/oracles"
mkdir -p "$ORACLES/exchange-lob" "$ORACLES/emulator-gb"
echo '{"gate_id":"exchange-lob","status":"pass"}' > "$ORACLES/exchange-lob/report.json"
echo '{"gate_id":"emulator-gb","status":"pass"}'  > "$ORACLES/emulator-gb/report.json"

CORPUS="$WORK/CORPUS-STATUS.md"
cat > "$CORPUS" <<'MD'
| Version | Cases | Caught | Catch-rate |
| --- | ---: | ---: | ---: |
| 0.1 | 13 cases | 13/13 caught | 100% |
MD

# stub-code gate (verify-edits --json shape): warnings 0 + verdict PASS → check.
SGATE_OK="$WORK/sgate-ok.json"
echo '{"files_edited":3,"checks_passed":3,"checks_failed":0,"warnings":0,"verdict":"PASS"}' > "$SGATE_OK"

POOL="$WORK/pool.json"
cat > "$POOL" <<'JSON'
{ "active_count": 1, "max_agents": 10,
  "agents": {
    "a1": {"type": "coder",  "status": "done"},
    "a2": {"type": "test",   "status": "done"},
    "a3": {"type": "review", "status": "active"},
    "a4": {"type": "lint",   "status": "done"}
  } }
JSON

REUSE_DIR="$WORK/reuse"
mkdir -p "$REUSE_DIR"
echo '{"task":"seed","units_total":10,"units_reusing":6,"reuse_pct":0.62}' > "$REUSE_DIR/20260101T000000Z-seed.json"

PONY="$WORK/ponytail.jsonl"
cat > "$PONY" <<'JSON'
{"metric":"ponytail-ab","mode":"on","ladder":true,"loc":82,"tokens":100,"acceptance_pass":true}
{"metric":"ponytail-ab","mode":"off","ladder":false,"loc":100,"tokens":140,"acceptance_pass":true}
JSON

HOLDOUT_BLANK="$WORK/holdout-blank.json"
printf '%s\n' '{"cost_source":null,"is_measured_fact":false,"label":"","basis":null,"value":null,"rendered":"—","n":{"control":0,"treatment":0}}' > "$HOLDOUT_BLANK"
HOLDOUT_EST="$WORK/holdout-est.json"
printf '%s\n' '{"cost_source":"estimated","is_measured_fact":false,"label":"est.","basis":"4x raw-CC baseline","value":0.41,"rendered":"~0.41 est. (4x raw-CC baseline)","n":{"control":0,"treatment":0}}' > "$HOLDOUT_EST"

GC="✓"; GX="✗"

render() { # $1 = holdout json ; optional SGATE env override
  HEIMDALL_RECEIPT_ORACLE_DIR="$ORACLES" \
  HEIMDALL_RECEIPT_CORPUS_STATUS="$CORPUS" \
  HEIMDALL_RECEIPT_STUB_JSON="${SGATE:-$SGATE_OK}" \
  HEIMDALL_RECEIPT_POOL_JSON="$POOL" \
  HEIMDALL_RECEIPT_REUSE_DIR="$REUSE_DIR" \
  HEIMDALL_RECEIPT_PONYTAIL="$PONY" \
  HEIMDALL_RECEIPT_HOLDOUT_JSON="$1" \
  HEIMDALL_RECEIPT_WHO="rj.mbp" \
  "$CARD" --receipt "$PROJ" 2>&1
}

# ── 1. Full green render: every row shows its REAL value ──────────────────────
OUT="$(render "$HOLDOUT_EST" | strip_ansi)"
echo "$OUT" | grep -q "HEIMDALL RUN RECEIPT" && ok "header: HEIMDALL RUN RECEIPT present" \
  || bad "header missing: $OUT"
echo "$OUT" | grep -q "rj.mbp" && ok "header: machine/who brand present" \
  || bad "who brand missing"
echo "$OUT" | grep -qi "ship the flagship run receipt" && ok "TASK row shows the real task line" \
  || bad "TASK row wrong"
echo "$OUT" | grep -q "agents" && echo "$OUT" | grep -q "coder" \
  && ok "SWARM row shows agent count + real roles" || bad "SWARM row wrong: $OUT"
echo "$OUT" | grep -q "falsify 2/2=1.0" && ok "GATES: falsify 2/2=1.0 (real oracle reports)" \
  || bad "falsify score wrong: $(echo "$OUT" | grep -i gates)"
echo "$OUT" | grep -q "corpus 13/13" && ok "GATES: corpus 13/13 (real CORPUS-STATUS.md)" \
  || bad "corpus wrong"
echo "$OUT" | grep -q "stub$GC" && ok "GATES: stub-code gate check (verify-edits warnings=0)" \
  || bad "stub gate glyph wrong: $(echo "$OUT" | grep -i gates)"
echo "$OUT" | grep -q "OPEN" && ok "BIFROST OPEN when every gate is green" \
  || bad "bifrost not open on green run"
echo "$OUT" | grep -q "18% LOC" && ok "LEANER: -18% LOC (ladder on) from real A/B" \
  || bad "LOC delta wrong: $(echo "$OUT" | grep -i lean)"
echo "$OUT" | grep -q "reuse 0.62" && ok "LEANER: reuse 0.62 (real reuse record)" \
  || bad "reuse wrong"
echo "$OUT" | grep -q "34k" && ok "COST: 34k tok (real token budget)" \
  || bad "token figure wrong: $(echo "$OUT" | grep -i cost)"
echo "$OUT" | grep -q "runheimdall.dev/proof" && ok "footer: runheimdall.dev/proof" \
  || bad "footer missing"

# ── 2. A FAILING gate shows the cross (not the check) and CLOSES the Bifrost ───
ORA_FAIL="$WORK/oracles-fail"
mkdir -p "$ORA_FAIL/exchange-lob" "$ORA_FAIL/emulator-gb"
echo '{"status":"pass"}' > "$ORA_FAIL/exchange-lob/report.json"
echo '{"status":"fail"}' > "$ORA_FAIL/emulator-gb/report.json"
OUT_FAIL="$(HEIMDALL_RECEIPT_ORACLE_DIR="$ORA_FAIL" \
  HEIMDALL_RECEIPT_CORPUS_STATUS="$CORPUS" HEIMDALL_RECEIPT_STUB_JSON="$SGATE_OK" \
  HEIMDALL_RECEIPT_POOL_JSON="$POOL" HEIMDALL_RECEIPT_REUSE_DIR="$REUSE_DIR" \
  HEIMDALL_RECEIPT_PONYTAIL="$PONY" HEIMDALL_RECEIPT_HOLDOUT_JSON="$HOLDOUT_BLANK" \
  HEIMDALL_RECEIPT_WHO="rj.mbp" "$CARD" --receipt "$PROJ" 2>&1 | strip_ansi)"
echo "$OUT_FAIL" | grep -q "falsify 1/2" && ok "failing oracle → falsify 1/2 (honest count)" \
  || bad "falsify fail count wrong: $(echo "$OUT_FAIL" | grep -i gates)"
echo "$OUT_FAIL" | grep -q "$GX" && ok "a failed gate renders the cross (not check) — honest" \
  || bad "no cross shown on a failed gate"
echo "$OUT_FAIL" | grep -qi "CLOSED" && ok "BIFROST CLOSED when a gate is red" \
  || bad "bifrost did not close on a red gate"
echo "$OUT_FAIL" | grep -q "nothing shipped unproven" && bad "green-washed a bad run (OPEN copy leaked)" \
  || ok "bad run is NOT green-washed (no OPEN copy)"

# stub-code gate FAIL: warnings>0 → cross
SGATE_BAD="$WORK/sgate-bad.json"
echo '{"files_edited":2,"checks_passed":2,"checks_failed":0,"warnings":2,"verdict":"PASS"}' > "$SGATE_BAD"
OUT_SG="$(SGATE="$SGATE_BAD" render "$HOLDOUT_BLANK" | strip_ansi)"
echo "$OUT_SG" | grep -q "stub$GX" && ok "warnings>0 → stub cross (honest, not check)" \
  || bad "stub fail not shown: $(echo "$OUT_SG" | grep -i gates)"

# ── 3. HONESTY: vs-raw-CC slot is est./blank with NO control arm — never a % ───
COST_BLANK="$(render "$HOLDOUT_BLANK" | strip_ansi | grep -i "COST")"
if echo "$COST_BLANK" | grep -q "%"; then
  bad "FABRICATED %% in vs-raw-CC slot with no control arm: [$COST_BLANK]"
else
  ok "no control arm → NO fabricated %% in the vs-raw-CC slot"
fi
echo "$COST_BLANK" | grep -q "—" && ok "no control arm → vs-raw-CC renders blank em-dash (honest)" \
  || bad "blank vs-raw-CC not shown honestly: [$COST_BLANK]"
COST_EST="$(render "$HOLDOUT_EST" | strip_ansi | grep -i "COST")"
echo "$COST_EST" | grep -q "est" && ok "an estimate is LABELED est. (never a bare number)" \
  || bad "estimate not labeled: [$COST_EST]"

# ── 4. Missing sources degrade the row without crashing ───────────────────────
EMPTY="$WORK/empty"; mkdir -p "$EMPTY"
rc=0
OUT_MISS="$(HEIMDALL_RECEIPT_ORACLE_DIR="$EMPTY" HEIMDALL_RECEIPT_CORPUS_STATUS="$EMPTY/none.md" \
  HEIMDALL_RECEIPT_STUB_JSON="$EMPTY/none.json" HEIMDALL_RECEIPT_POOL_JSON="$EMPTY/none.json" \
  HEIMDALL_RECEIPT_REUSE_DIR="$EMPTY" HEIMDALL_RECEIPT_PONYTAIL="$EMPTY/none.jsonl" \
  HEIMDALL_RECEIPT_HOLDOUT_JSON="$EMPTY/none.json" HEIMDALL_RECEIPT_WHO="rj.mbp" \
  "$CARD" --receipt "$EMPTY" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok "missing every source → exit 0 (no crash)" \
  || bad "receipt crashed on missing sources (rc=$rc)"
echo "$OUT_MISS" | grep -q "HEIMDALL RUN RECEIPT" && ok "box still drawn with all sources absent" \
  || bad "no box drawn on missing sources"
echo "$OUT_MISS" | strip_ansi | grep -qE "n/a|—" && ok "absent rows degrade to n/a/dash (never faked)" \
  || bad "degraded rows not honest: $OUT_MISS"

# ── 5. Pipe/CI mode is ANSI-clean (no raw escape codes) ───────────────────────
PIPED="$(render "$HOLDOUT_EST" | cat)"
if printf '%s' "$PIPED" | grep -q $'\x1b'; then
  bad "pipe mode emitted raw ANSI escape codes"
else
  ok "pipe mode is ANSI-clean (no escape codes)"
fi
printf '%s' "$PIPED" | grep -q "HEIMDALL RUN RECEIPT" && ok "piped receipt still readable (plain text)" \
  || bad "piped receipt lost its content"

# ── 6. NON_VERIFIED — the THIRD state: "could not verify" is NOT a pass ───────
# bin/verify-edits exits 2 with verdict NON_VERIFIED when the session edit ledger
# is absent: the tracker hook never fired, so NOTHING was checked. Rendering that
# as the green check would be the exact false-green the ledger-presence fix closed
# one layer DOWN, reappearing one layer UP. The receipt must treat it as its own
# state: never the green check, never silently identical to a real FAIL.
#
# render_rc SGATE_FIXTURE HOLDOUT -> sets NV_OUT (ansi-stripped) + NV_RC (card's
# own exit status, NOT the tail of a pipe — pipefail is off in this suite).
render_rc() {
  local raw
  NV_RC=0
  raw="$(SGATE="$1" render "$2")" || NV_RC=$?
  NV_OUT="$(printf '%s\n' "$raw" | strip_ansi)"
}

# Byte-for-byte the payload bin/verify-edits emits on an absent ledger,
# tripwire (warnings:1) included.
SGATE_NV="$WORK/sgate-nonverified.json"
cat > "$SGATE_NV" <<'JSON'
{"verdict":"NON_VERIFIED","reason":"edit-ledger-absent","ledger":"/tmp/heimdall-edits/ledger-x.log","files_edited":null,"checks_passed":0,"checks_failed":0,"warnings":1,"paths":[]}
JSON

render_rc "$SGATE_NV" "$HOLDOUT_EST"
echo "$NV_OUT" | grep -q "stub$GC" && bad "NON_VERIFIED rendered the GREEN check — false-green: $(echo "$NV_OUT" | grep -i gates)" \
  || ok "NON_VERIFIED never renders the green stub check"
echo "$NV_OUT" | grep -q "nothing shipped unproven" && bad "NON_VERIFIED green-washed the Bifrost (OPEN copy leaked)" \
  || ok "NON_VERIFIED does NOT open the Bifrost"
echo "$NV_OUT" | grep -qi "CLOSED" && ok "NON_VERIFIED closes the Bifrost (nothing ships unverified)" \
  || bad "Bifrost stayed open on a NON_VERIFIED gate: $(echo "$NV_OUT" | grep -i bif)"
[ "$NV_RC" -eq 2 ] && ok "NON_VERIFIED → receipt exits 2 (mirrors verify-edits' own code)" \
  || bad "NON_VERIFIED exit did not reflect it (want 2, got $NV_RC)"
# ...and it SAYS which: not-verified is distinguishable from a real failure.
echo "$NV_OUT" | grep -q "could not verify" && ok "receipt SAYS 'could not verify' (distinct from 'a gate is red')" \
  || bad "NON_VERIFIED not distinguished from FAIL in the copy: $(echo "$NV_OUT" | grep -i bif)"
echo "$NV_OUT" | grep -q "is red, held back" && bad "NON_VERIFIED mislabelled as a red/failed gate" \
  || ok "NON_VERIFIED is NOT mislabelled as a failure"

# ── 6b. TRIPWIRE INDEPENDENCE — the assertion that keeps this fix honest ──────
# verify-edits currently also sets warnings:1 on that payload purely to trip the
# old `warnings>0` reddening. That is a workaround living in another file. With
# warnings forced to 0 the receipt MUST still refuse to go green — otherwise this
# card depends on a magic field value and anyone "tidying up" that 1 silently
# restores the false-green.
SGATE_NV0="$WORK/sgate-nonverified-nowarn.json"
cat > "$SGATE_NV0" <<'JSON'
{"verdict":"NON_VERIFIED","reason":"edit-ledger-absent","ledger":"/tmp/heimdall-edits/ledger-x.log","files_edited":null,"checks_passed":0,"checks_failed":0,"warnings":0,"paths":[]}
JSON

render_rc "$SGATE_NV0" "$HOLDOUT_EST"
echo "$NV_OUT" | grep -q "stub$GC" && bad "warnings:0 NON_VERIFIED went GREEN — card depends on the warnings tripwire" \
  || ok "warnings:0 NON_VERIFIED still NOT green (no dependency on the tripwire)"
echo "$NV_OUT" | grep -q "nothing shipped unproven" && bad "warnings:0 NON_VERIFIED opened the Bifrost (tripwire-dependent)" \
  || ok "warnings:0 NON_VERIFIED still closes the Bifrost"
[ "$NV_RC" -eq 2 ] && ok "warnings:0 NON_VERIFIED still exits 2 (verdict alone drives it)" \
  || bad "warnings:0 NON_VERIFIED exit regressed to $NV_RC — tripwire-dependent"

# ── 6c. The other two states are UNCHANGED by the third one ───────────────────
render_rc "$SGATE_OK" "$HOLDOUT_EST"
echo "$NV_OUT" | grep -q "stub$GC" && ok "PASS payload still renders the green check" \
  || bad "PASS regressed: $(echo "$NV_OUT" | grep -i gates)"
echo "$NV_OUT" | grep -q "nothing shipped unproven" && ok "PASS payload still OPENs the Bifrost" \
  || bad "PASS no longer opens the Bifrost: $(echo "$NV_OUT" | grep -i bif)"
[ "$NV_RC" -eq 0 ] && ok "PASS payload still exits 0" \
  || bad "PASS exit regressed (want 0, got $NV_RC)"

# verdict FAIL with warnings:0 — the verdict alone must redden (not just warnings).
SGATE_FAILV="$WORK/sgate-failverdict.json"
echo '{"files_edited":2,"checks_passed":1,"checks_failed":1,"warnings":0,"verdict":"FAIL","paths":[]}' > "$SGATE_FAILV"
render_rc "$SGATE_FAILV" "$HOLDOUT_EST"
echo "$NV_OUT" | grep -q "stub$GX" && ok "FAIL payload still renders the red cross" \
  || bad "FAIL regressed: $(echo "$NV_OUT" | grep -i gates)"
echo "$NV_OUT" | grep -q "is red, held back" && ok "FAIL still reads as a RED gate (not 'could not verify')" \
  || bad "FAIL copy regressed: $(echo "$NV_OUT" | grep -i bif)"
[ "$NV_RC" -eq 1 ] && ok "FAIL payload exits 1 (distinct from NON_VERIFIED's 2)" \
  || bad "FAIL exit wrong (want 1, got $NV_RC)"

echo ""
echo "──────────────────────────────────────────────"
echo "  $PASS passed, $FAIL failed"
echo "──────────────────────────────────────────────"
[ "$FAIL" -eq 0 ] || exit 1
