#!/usr/bin/env bash
# test/heimdall-arm-resolution-gate.test.sh — every dispatch arm in bin/heimdall's
# top-level `case "${1:-}" in ... esac` block must resolve to a target binary that
# actually exists and is executable on disk.
#
# WHY THIS EXISTS: 2026-08-23's arms audit (docs/analysis/2026-08-23-feature-audit-arms.md)
# hand-executed all ~45 dispatcher arms and found `metrics)` pointing at
# bin/heimdall-metrics — a binary that has never existed in any release
# (bin/heimdall-metric, singular, is a completely different tool: a local
# per-task telemetry emitter, not a report reader). That defect, and two earlier
# ones this same week (`watch)` pointing at a stale name, `heimdall-quota-advisor`
# having no arm at all so an unmatched call fell through to a live `claude -p`
# spawn), are all the SAME failure mode: a dispatch arm names a target that
# doesn't match what's actually on disk. All three needed a human to run the
# command and read the error before anyone noticed. This gate makes that
# mechanical and permanent — it would have caught `metrics` the day it broke.
#
# WHAT THIS DOES NOT CHECK: whether a target implements the verbs its arm
# forwards (that's the heimdall-metric-vs-heimdall-metrics trap specifically —
# repointing to a wrong-but-real binary passes this gate and still breaks).
# Narrower than the audit, but mechanical and near-free where the audit was a
# one-off human-directed pass.
#
# SCOPE: the DISPATCHER case block only — the same ~45-arm block the audit
# walked. Located dynamically as the LARGEST `case "${1:-}" in` ... `esac` span
# in the file (matched by an UNINDENTED `esac`), never a hardcoded line range —
# nested case blocks inside arms (sigil, guard) close with an INDENTED `esac`
# and are correctly excluded from ever being mistaken for the block's own close.
# Arms with zero `$PLUGIN_DIR/bin/...` references (version, help, ...) are
# genuinely inline handlers and are skipped, by design — nothing else is.
#
# Usage: bash test/heimdall-arm-resolution-gate.test.sh   (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_BIN="$ROOT/bin/heimdall"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/hmd-arm-gate.XXXXXX")"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT INT TERM

echo "heimdall-arm-resolution-gate acceptance  repo=$ROOT"
echo

[ -f "$REAL_BIN" ] || { bad "bin/heimdall not found at $REAL_BIN"; printf "\n  Results: %d passed, %d failed\n" "$PASS" "$FAIL"; exit 1; }

# ── extraction + check engine ───────────────────────────────────────────────
# gate_check <script> <bindir>
# Populates (globals, reset each call): GATE_CHECKED, GATE_INLINE, GATE_FAILED,
# GATE_ARMS, FAIL_DETAILS[]. Resolves every "$PLUGIN_DIR/bin/<name>" reference
# found inside each top-level arm's body against "<bindir>/bin/<name>".
gate_check() {
  local script="$1" bindir="$2"
  GATE_CHECKED=0 GATE_INLINE=0 GATE_FAILED=0 GATE_ARMS=0
  FAIL_DETAILS=()

  # 1. Locate the dispatcher: the case/esac pair (unindented esac) with the
  #    largest line span. Every OTHER top-level case in this file is a
  #    handful of lines; the real dispatcher is ~1000.
  local span dstart dend
  span="$(awk '
    /^case "\$\{1:-\}" in$/ { starts[++n] = NR }
    /^esac$/ { ends[++m] = NR }
    END {
      si = 1; beststart = 0; bestend = 0; bestspan = -1
      for (ei = 1; ei <= m; ei++) {
        if (si > n) break
        if (ends[ei] < starts[si]) continue
        sp = ends[ei] - starts[si]
        if (sp > bestspan) { bestspan = sp; beststart = starts[si]; bestend = ends[ei] }
        si++
      }
      print beststart, bestend
    }
  ' "$script")"
  dstart="${span% *}"; dend="${span#* }"
  if [ -z "$dstart" ] || [ "$dstart" -le 0 ] || [ -z "$dend" ] || [ "$dend" -le "$dstart" ]; then
    GATE_FAILED=1
    FAIL_DETAILS+=("could not locate the dispatcher case block in $script")
    return
  fi

  # 2. Tag-stream the block in order: "ARM<TAB>header" opens a new arm,
  #    "TARGET<TAB>name" is a $PLUGIN_DIR/bin/<name> reference in its body.
  local tagged
  tagged="$(awk -v s="$dstart" -v e="$dend" '
    NR < s || NR > e { next }
    /^  [^ ]+\)[[:space:]]*$/ {
      line = $0
      sub(/^  /, "", line)
      sub(/\)[[:space:]]*$/, "", line)
      print "ARM\t" line
      next
    }
    {
      line = $0
      while (match(line, /\$PLUGIN_DIR\/bin\/[A-Za-z0-9_.-]+/)) {
        tok = substr(line, RSTART, RLENGTH)
        sub(/^.*\/bin\//, "", tok)
        print "TARGET\t" tok
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$script")"

  # 3. Walk the tagged stream: each ARM flushes the previous arm's collected
  #    targets (deduped) — zero targets = inline (skip), one or more = check.
  local cur_arm="" first=1
  local -a cur_targets=()

  _flush_arm() {
    [ -n "$cur_arm" ] || return
    GATE_ARMS=$((GATE_ARMS+1))
    if [ "${#cur_targets[@]}" -eq 0 ]; then
      GATE_INLINE=$((GATE_INLINE+1))
      return
    fi
    local t
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      GATE_CHECKED=$((GATE_CHECKED+1))
      if [ ! -x "$bindir/bin/$t" ]; then
        GATE_FAILED=$((GATE_FAILED+1))
        FAIL_DETAILS+=("$cur_arm -> bin/$t MISSING or not executable (resolved: $bindir/bin/$t)")
      fi
    done < <(printf '%s\n' "${cur_targets[@]}" | sort -u)
  }

  while IFS=$'\t' read -r tag val; do
    case "$tag" in
      ARM)
        [ "$first" -eq 1 ] || _flush_arm
        first=0
        cur_arm="$val"
        cur_targets=()
        ;;
      TARGET)
        cur_targets+=("$val")
        ;;
    esac
  done <<< "$tagged"
  _flush_arm
}

# ── Section A: the real gate — bin/heimdall as it stands right now ─────────
echo "Section A: every arm in $REAL_BIN resolves"
gate_check "$REAL_BIN" "$ROOT"
if [ "$GATE_FAILED" -eq 0 ]; then
  ok "all $GATE_ARMS top-level arms resolve ($GATE_CHECKED external target(s) checked, $GATE_INLINE inline/no-target)"
else
  for d in "${FAIL_DETAILS[@]}"; do bad "$d"; done
fi
[ "$GATE_ARMS" -ge 40 ] && ok "arm count sane ($GATE_ARMS >= 40 — the audit counted ~45)" || bad "arm count suspiciously low ($GATE_ARMS) — extraction may be broken"

echo
echo "Section B: falsifiability — the gate must be able to fail"
# `rr)` (bin/heimdall:1688) forwards to bin/rr, which is real; corrupt that one
# reference in a scratch COPY of bin/heimdall (never the real file) and confirm
# the checker — resolving against the REAL, unmodified $ROOT/bin — catches it.
MUTANT="$SCRATCH/heimdall-mutant"
sed 's#PLUGIN_DIR/bin/rr"#PLUGIN_DIR/bin/rr-DOES-NOT-EXIST-MUTANT"#' "$REAL_BIN" > "$MUTANT"
chmod +x "$MUTANT"

if ! grep -q 'rr-DOES-NOT-EXIST-MUTANT' "$MUTANT"; then
  bad "falsifiability setup: the sed mutation did not apply — fix the test, not the gate"
else
  gate_check "$MUTANT" "$ROOT"
  if [ "$GATE_FAILED" -ge 1 ] && printf '%s\n' "${FAIL_DETAILS[@]}" | grep -q 'rr-DOES-NOT-EXIST-MUTANT'; then
    ok "RED: a deliberately broken target IS caught -- ${FAIL_DETAILS[0]}"
  else
    bad "RED expected but not observed: a deliberately broken target went undetected -- the gate has no teeth"
  fi
fi

# Re-run against the real script to prove GREEN afterward (no shared state leaked
# from the mutant run into the real one).
gate_check "$REAL_BIN" "$ROOT"
if [ "$GATE_FAILED" -eq 0 ]; then
  ok "GREEN: bin/heimdall is clean again on a fresh check after the mutant run"
else
  bad "bin/heimdall unexpectedly failing after the mutant run (state leak between runs?)"
fi

printf "\n  Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
