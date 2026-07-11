#!/usr/bin/env bash
# heimdall-sigil-center.test.sh — the 8×8 sigil is VERTICALLY CENTERED in tall
# (multi-row) statusline layouts, not top-anchored.
#
# The sigil is a perfect 8×8 block: 8 cols × 4 half-block rows, prefixed on the
# statusline's content rows. In a SWARM / team-wall layout there are MORE than 4
# content rows (N > 4), so the 4-row sigil can't fill them all. It must sit in
# the MIDDLE — ⌊(N−4)/2⌋ blank 8-space prefixes above, the sigil's 4 rows
# contiguous, the rest blank below — never jammed at the top (SSSS…BBB).
#
# Detection: in color+unicode mode a SIGIL prefix row starts with an ANSI escape
# (the half-block glyph is color-coded); a BLANK 8-space prefix row starts with
# spaces. So the per-row "starts-with-ESC" pattern is the sigil's vertical mask.
#
# Asserts:
#   1. N>4 (3-agent swarm, N=6): exactly 4 sigil rows, CONTIGUOUS, and the count
#      of blank rows ABOVE == ⌊(N−4)/2⌋ (== 1). Top-anchor (0 above) FAILS.
#   2. the sigil stays a perfect 8×8 — exactly 4 sigil rows, never 3 or 5.
#   3. N≤4 (solo, N=4): top-anchored & unchanged — 4 sigil rows from row 0, no
#      blank above. (⌊(4−4)/2⌋ == 0.)
#
# Hermetic: HOME → temp dir (agent-pool + shared-memory), HEIMDALL_PLANNING_DIR
# isolates the ledger. Real bins only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STATUS="$ROOT/sentinels/hmd-statusline.py"
BIN="$ROOT/bin"
POOL="$BIN/agent-pool"
MEM="$BIN/shared-memory"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
PROJ="$TMP/proj"
export HEIMDALL_PLANNING_DIR="$PROJ/.planning"
mkdir -p "$HEIMDALL_PLANNING_DIR/ledger/claims"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# emit the per-row sigil mask: "1" = sigil prefix (row starts with ANSI ESC),
# "0" = blank 8-space prefix. One char per content row, in order.
mask() { # stdin = rendered HUD
  python3 -c '
import sys
out=[]
for line in sys.stdin:
    line=line.rstrip("\n")
    if not line: continue
    out.append("1" if line.startswith("\x1b") else "0")
print("".join(out))'
}

render() { # $1 = --color|--no-color
  printf '{"workspace":{"current_dir":"%s"}}' "$PROJ" \
    | COLUMNS=170 TERM=xterm-256color python3 "$STATUS" "$1" 2>/dev/null
}

# assert a mask is centered: 4 contiguous "1"s, with the expected # of leading 0s.
assert_centered() { # $1=label $2=mask $3=expected_blanks_above
  local label="$1" m="$2" want="$3"
  local ones above below body
  ones=$(printf '%s' "$m" | tr -cd 1 | wc -c | tr -d ' ')
  above=${m%%1*}; above=${#above}          # leading zeros
  below=${m##*1}; below=${#below}          # trailing zeros
  body=${m#"${m%%1*}"}; body=${body%"${m##*1}"}   # the 1..1 span, inclusive
  if [ "$ones" -ne 4 ]; then bad "$label: sigil must be a perfect 8×8 (4 rows), got $ones sigil rows (mask=$m)"; return; fi
  case "$body" in *0*) bad "$label: sigil rows not contiguous (mask=$m)"; return ;; esac
  if [ "$above" -ne "$want" ]; then bad "$label: expected $want blank row(s) above sigil, got $above (mask=$m)"; return; fi
  ok "$label: 4 contiguous sigil rows, $above above / $below below (mask=$m)"
}

# ── case 1+2: 3-agent swarm → N=6 content rows → sigil centered (1 above) ──
python3 "$POOL" init --max 10 >/dev/null 2>&1
python3 "$POOL" acquire haid-coder coder       --pid $$ >/dev/null 2>&1
python3 "$POOL" acquire haid-test  test-runner --pid $$ >/dev/null 2>&1
python3 "$POOL" acquire haid-lint  lint        --pid $$ >/dev/null 2>&1
python3 "$MEM" init >/dev/null 2>&1
python3 "$MEM" set haid-coder pass    --ns swarm-gate >/dev/null 2>&1
python3 "$MEM" set haid-test  working --ns swarm-gate >/dev/null 2>&1
python3 "$MEM" set haid-lint  deny    --ns swarm-gate >/dev/null 2>&1

echo "== case 1+2: N>4 swarm → sigil vertically centered (perfect 8×8) =="
SWARM_MASK="$(render --color | mask)"
N=${#SWARM_MASK}
echo "  (N=$N content rows, mask=$SWARM_MASK)"
if [ "$N" -le 4 ]; then bad "expected a swarm layout with N>4 content rows, got N=$N"; fi
# ⌊(N−4)/2⌋ blanks above
WANT_ABOVE=$(( (N - 4) / 2 ))
assert_centered "swarm sigil centered" "$SWARM_MASK" "$WANT_ABOVE"

# ── case 3: solo (N≤4) → top-anchored, unchanged ──
python3 "$POOL" release haid-test >/dev/null 2>&1
python3 "$POOL" release haid-lint >/dev/null 2>&1
python3 "$POOL" release haid-coder >/dev/null 2>&1
echo "== case 3: N≤4 solo → sigil fills top-down (unchanged) =="
SOLO_MASK="$(render --color | mask)"
echo "  (N=${#SOLO_MASK} content rows, mask=$SOLO_MASK)"
assert_centered "solo sigil top-anchored" "$SOLO_MASK" 0

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
