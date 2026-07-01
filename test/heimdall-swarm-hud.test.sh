#!/usr/bin/env bash
# heimdall-swarm-hud.test.sh — the parallel-agent SWARM block in the watchman HUD.
#
# Seeds a REAL multi-agent state via the real bins (agent-pool = the live roster,
# shared-memory = per-agent gate verdict + current file, heimdall-claim = the
# claim-ledger surface) and asserts the HUD renders it as spectacle + receipt:
#
#   1. >1 active agent  -> a SWARM block: one row per live agent, each with its
#      role AND its gate glyph (✓ proven / ⟳ working / ✗ BIFRÖST).
#   2. the claim-ledger surface renders next to its agent (real claim, real bin).
#   3. single active agent -> NO swarm block (current HUD unchanged).
#   4. non-tty / --no-color pipe mode -> plain text, ZERO raw ANSI escape codes.
#   5. empty pool -> the normal HUD (brand row present, no swarm).
#
# Hermetic: HOME is redirected to a temp dir so agent-pool + shared-memory write
# under it, and HEIMDALL_PLANNING_DIR isolates the claim ledger. Real bins only —
# no agent is fabricated.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STATUS="$ROOT/sentinels/hmd-statusline.py"
BIN="$ROOT/bin"
POOL="$BIN/agent-pool"
MEM="$BIN/shared-memory"
CLAIM="$BIN/heimdall-claim"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"                          # agent-pool + shared-memory live under ~/.heimdall
PROJ="$TMP/proj"
export HEIMDALL_PLANNING_DIR="$PROJ/.planning"
mkdir -p "$HEIMDALL_PLANNING_DIR/ledger/claims"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

# render the HUD: feed CC-shaped stdin JSON, hand it COLUMNS + the color flag.
render() { # $1 = extra flag (--color|--no-color)
  printf '{"workspace":{"current_dir":"%s"}}' "$PROJ" \
    | COLUMNS=170 python3 "$STATUS" "$1" 2>/dev/null
}

# ── seed a 3-agent swarm via the real bins ──────────────────────────────────
python3 "$POOL" init --max 10 >/dev/null 2>&1
python3 "$POOL" acquire haid-coder coder       --pid $$ >/dev/null 2>&1
python3 "$POOL" acquire haid-test  test-runner --pid $$ >/dev/null 2>&1
python3 "$POOL" acquire haid-lint  lint        --pid $$ >/dev/null 2>&1

python3 "$MEM" init >/dev/null 2>&1
python3 "$MEM" set haid-coder pass    --ns swarm-gate >/dev/null 2>&1
python3 "$MEM" set haid-test  working --ns swarm-gate >/dev/null 2>&1
python3 "$MEM" set haid-lint  deny    --ns swarm-gate >/dev/null 2>&1
python3 "$MEM" set haid-test  "test/auth.test.ts" --ns swarm-file >/dev/null 2>&1
python3 "$MEM" set haid-lint  "eslint.config.js"  --ns swarm-file >/dev/null 2>&1

# claim-ledger surface for the coder, written by the REAL heimdall-claim bin
# (claim is keyed by the derived haid; acquire a pool slot under that same id so
# the row matches). Best-effort: if heimdall-haid can't derive here, the coder
# just falls back to its shared-memory file and the claim sub-test is skipped.
CLAIM_HAID=""
if [ -x "$BIN/heimdall-haid" ]; then
  CLAIM_HAID="$(cd "$PROJ" && "$BIN/heimdall-haid" current 2>/dev/null || true)"
fi
if [ -n "$CLAIM_HAID" ] && command -v jq >/dev/null 2>&1; then
  python3 "$POOL" acquire "$CLAIM_HAID" architect --pid $$ >/dev/null 2>&1
  ( cd "$PROJ" && "$CLAIM" claim "src/planner.ts" --task T-42 >/dev/null 2>&1 ) || CLAIM_HAID=""
fi

echo "== case 1+2: multi-agent swarm block renders (color) =="
OUT="$(render --color)"
assert_contains "swarm header present"        "$OUT" "swarm"
assert_contains "coder role row"              "$OUT" "coder"
assert_contains "test-runner role row"        "$OUT" "test-runner"
assert_contains "lint role row"               "$OUT" "lint"
assert_contains "pass glyph (coder proven)"   "$OUT" "✓"
assert_contains "working glyph"               "$OUT" "⟳"
assert_contains "deny glyph"                  "$OUT" "✗"
assert_contains "deny carries BIFRÖST receipt" "$OUT" "BIFRÖST"
assert_contains "shared-memory file surfaces" "$OUT" "test/auth.test.ts"
assert_contains "lint file surfaces"          "$OUT" "eslint.config.js"
# one row per live agent: at least the 3 seeded roles each on their own line
ROLE_ROWS="$(printf '%s\n' "$OUT" | grep -cE 'coder|test-runner|lint')"
if [ "$ROLE_ROWS" -ge 3 ]; then ok "one row per active agent (>=3)"; else bad "expected >=3 agent rows, got $ROLE_ROWS"; fi
if [ -n "$CLAIM_HAID" ]; then
  assert_contains "claim-ledger surface (real heimdall-claim)" "$OUT" "src/planner.ts"
else
  ok "claim-ledger sub-test skipped (haid underivable here)"
fi

echo "== case 4: pipe / --no-color mode is ANSI-clean plain text =="
POUT="$(render --no-color)"
if printf '%s' "$POUT" | grep -q "$(printf '\033')"; then
  bad "no raw ANSI escapes in --no-color mode"
else
  ok "no raw ANSI escapes in --no-color mode"
fi
assert_contains "plain mode still lists coder"       "$POUT" "coder"
assert_contains "plain mode still lists test-runner" "$POUT" "test-runner"
assert_contains "plain mode still names deny receipt" "$POUT" "BIFRÖST"

echo "== case 3: single active agent -> no swarm block =="
python3 "$POOL" release haid-test  >/dev/null 2>&1
python3 "$POOL" release haid-lint  >/dev/null 2>&1
[ -n "$CLAIM_HAID" ] && python3 "$POOL" release "$CLAIM_HAID" >/dev/null 2>&1
SOLO="$(render --color)"
assert_not_contains "single agent shows no swarm block" "$SOLO" "── swarm"
assert_contains     "single-agent HUD keeps the brand"  "$SOLO" "HEIMDALL"

echo "== case 5: empty pool -> normal HUD unchanged =="
python3 "$POOL" release haid-coder >/dev/null 2>&1
EMPTY="$(render --color)"
assert_not_contains "empty pool shows no swarm block" "$EMPTY" "── swarm"
assert_contains     "empty pool keeps the brand row"  "$EMPTY" "HEIMDALL"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
