#!/usr/bin/env bash
# heimdall-gate-anim-export.test.sh — the BIFRÖST deny is a drop-in social asset.
#
# hmd-gate-anim.sh renders the live gate animation (cyan scan → red beats → the
# ✗ BIFRÖST CLOSED deny). This suite proves the SHAREABLE-ARTIFACT extension:
#
#   1. A deny run WRITES an artifact under the reels path AND PRINTS its path.
#      (the primary is a .gif with asciinema+agg, else a .png with an image tool,
#       else an honest .txt endframe — but a .txt is ALWAYS written as the floor.)
#   2. DEGRADATION: with agg/asciinema AND image tools hidden (PATH mocked to
#      /usr/bin:/bin), the artifact degrades to a .txt fallback and STILL exits 0.
#   3. REPLAY: `hmd-gate-anim.sh replay <report.json>` reconstructs the correct
#      verdict/domain from a crafted falsify/oracle report.json — a "fail"/first-
#      divergence report → deny (writes ✗ BIFRÖST CLOSED); a "pass" report → pass
#      (NEVER fabricates a CLOSED frame for a passing gate).
#   4. NON-TTY honesty: the .txt artifact carries NO raw ANSI escape sequences.
#
# The export is best-effort and never blocks the deny; these tests drive it
# synchronously (default) into a throwaway HMD_REELS_DIR so nothing pollutes the
# repo. Real, runnable, no mocks of the script itself.
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$TEST_DIR/.." && pwd)"
ANIM="$PLUGIN/sentinels/hmd-gate-anim.sh"

[ -f "$ANIM" ] || { echo "FATAL: hmd-gate-anim.sh not found at $ANIM"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 1; }

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }

WORK="$(mktemp -d 2>/dev/null || echo /tmp/gate-anim-test.$$)"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

esc=$'\033'   # ANSI escape byte for the raw-ANSI check

# ── 1. deny run writes an artifact + prints its path ────────────────────────
R1="$WORK/reels1"
out1="$(HMD_REELS_DIR="$R1" HMD_GATE_NAME="gate-deny-fixed" \
        bash "$ANIM" deny "oracle/falsify" test-haid 2>&1)"; rc1=$?
if [ "$rc1" -eq 0 ]; then ok "deny run exits 0"; else bad "deny run exits 0 (rc=$rc1)"; fi
if grep -q 'artifact' <<<"$out1"; then ok "deny run prints an artifact line"; else bad "deny run prints an artifact line"; fi
# the printed primary path must point at a real, non-empty file
prim1="$(printf '%s\n' "$out1" | sed -nE 's/.*artifact[^/]*([/][^ ]*).*/\1/p' | head -1)"
if [ -n "$prim1" ] && [ -s "$prim1" ]; then ok "printed artifact path is a real non-empty file"; else bad "printed artifact path is a real non-empty file (got '$prim1')"; fi
# the .txt floor is ALWAYS written under the reels dir
if [ -s "$R1/gate-deny-fixed.txt" ]; then ok "deny always writes the .txt endframe floor"; else bad "deny always writes the .txt endframe floor"; fi
# a manifest records the artifact honestly
if [ -s "$R1/gate-deny-fixed.json" ]; then ok "deny writes a manifest.json"; else bad "deny writes a manifest.json"; fi
# the artifact reflects the ACTUAL verdict/domain (no fabrication)
if grep -q 'BIFRÖST CLOSED' "$R1/gate-deny-fixed.txt"; then ok "deny endframe shows BIFRÖST CLOSED"; else bad "deny endframe shows BIFRÖST CLOSED"; fi
if grep -q 'oracle/falsify' "$R1/gate-deny-fixed.txt"; then ok "deny endframe shows the domain"; else bad "deny endframe shows the domain"; fi

# ── 2. degradation: hide agg/asciinema/image tools → honest .txt, exit 0 ────
R2="$WORK/reels2"
out2="$(PATH="/usr/bin:/bin" HMD_REELS_DIR="$R2" HMD_GATE_NAME="gate-deny-degraded" \
        bash "$ANIM" deny "secret-scan" test-haid 2>&1)"; rc2=$?
if [ "$rc2" -eq 0 ]; then ok "degraded deny exits 0"; else bad "degraded deny exits 0 (rc=$rc2)"; fi
if [ -s "$R2/gate-deny-degraded.txt" ]; then ok "degraded deny writes .txt fallback"; else bad "degraded deny writes .txt fallback"; fi
# with tools hidden there must be NO gif/png (honest degradation, never a broken file)
if [ ! -e "$R2/gate-deny-degraded.gif" ] && [ ! -e "$R2/gate-deny-degraded.png" ]; then ok "degraded deny produces no gif/png (honest)"; else bad "degraded deny produces no gif/png (honest)"; fi
# the primary the run prints must be the .txt
if grep -q '\.txt' <<<"$out2"; then ok "degraded deny prints the .txt as artifact"; else bad "degraded deny prints the .txt as artifact"; fi

# ── 3. replay reconstructs verdict/domain from a crafted report.json ────────
# a fail report → deny
cat > "$WORK/fail.report.json" <<'JSON'
{ "gate_id": "oracle/exchange-lob", "status": "fail",
  "first_divergence": {"index": 2}, "haid": "haid:rj-a3f9",
  "ts": "2026-06-24T17:47:20Z" }
JSON
R3="$WORK/reels3"
out3="$(HMD_REELS_DIR="$R3" HMD_GATE_NAME="replay-fail" \
        bash "$ANIM" replay "$WORK/fail.report.json" 2>&1)"; rc3=$?
if [ "$rc3" -eq 0 ]; then ok "replay(fail) exits 0"; else bad "replay(fail) exits 0 (rc=$rc3)"; fi
if [ -s "$R3/replay-fail.txt" ] && grep -q 'BIFRÖST CLOSED' "$R3/replay-fail.txt"; then ok "replay(fail) reconstructs a DENY frame"; else bad "replay(fail) reconstructs a DENY frame"; fi
if grep -q 'oracle/exchange-lob' "$R3/replay-fail.txt"; then ok "replay(fail) reconstructs the domain"; else bad "replay(fail) reconstructs the domain"; fi
if grep -q '"verdict": "deny"' "$R3/replay-fail.json"; then ok "replay(fail) manifest verdict=deny"; else bad "replay(fail) manifest verdict=deny"; fi

# a pass report → pass, and NEVER a fabricated CLOSED
cat > "$WORK/pass.report.json" <<'JSON'
{ "gate_id": "bloat", "status": "pass", "first_divergence": null,
  "haid": "haid:local", "ts": "2026-06-24T17:47:20Z" }
JSON
R4="$WORK/reels4"
out4="$(HMD_REELS_DIR="$R4" HMD_GATE_NAME="replay-pass" \
        bash "$ANIM" replay "$WORK/pass.report.json" 2>&1)"; rc4=$?
if [ "$rc4" -eq 0 ]; then ok "replay(pass) exits 0"; else bad "replay(pass) exits 0 (rc=$rc4)"; fi
if [ -s "$R4/replay-pass.txt" ] && ! grep -q 'BIFRÖST CLOSED' "$R4/replay-pass.txt"; then ok "replay(pass) does NOT fabricate BIFRÖST CLOSED"; else bad "replay(pass) does NOT fabricate BIFRÖST CLOSED"; fi
if grep -q 'proven' "$R4/replay-pass.txt"; then ok "replay(pass) reconstructs a PASS frame"; else bad "replay(pass) reconstructs a PASS frame"; fi
if grep -q '"verdict": "pass"' "$R4/replay-pass.json"; then ok "replay(pass) manifest verdict=pass"; else bad "replay(pass) manifest verdict=pass"; fi

# replay on a missing report is a clean usage error (exit 2), not a crash
bash "$ANIM" replay "$WORK/does-not-exist.json" >/dev/null 2>&1; rcM=$?
if [ "$rcM" -eq 2 ]; then ok "replay(missing report) → usage exit 2"; else bad "replay(missing report) → usage exit 2 (rc=$rcM)"; fi

# ── 4. non-tty .txt artifact carries NO raw ANSI escape sequences ───────────
if grep -q "$esc" "$R1/gate-deny-fixed.txt"; then bad "deny .txt has raw ANSI (must be clean)"; else ok "deny .txt has NO raw ANSI"; fi
if grep -q "$esc" "$R3/replay-fail.txt"; then bad "replay .txt has raw ANSI (must be clean)"; else ok "replay .txt has NO raw ANSI"; fi

echo
echo "----"
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
