#!/usr/bin/env bash
# gate.sh — team-copilot differential gate, the registry gate_command driver (the REDUM
# TEAM-LENS arm).
#
# The registry (evals/oracles/registry.json) resolves this domain to:
#     evals/oracles/team-copilot/gate.sh --differential --seeds 200
# (bin/oracle-select team-copilot prints exactly that). The LIVE seeded arm: for each of N seeds
# the INDEPENDENT reference generator (reference.generate_stream) produces a deterministic
# teammate work-state stream; the SAME stream is folded by BOTH the REAL redum team lens (over a
# real on-disk ledger) and the independent reference; both are normalized to the team-candidate
# roster and DIFFED. PASS iff impl == reference on every seed.
#
# differential.py is the SAME diff-truth run.sh drives on fixtures and that bin/falsify
# orchestrates — this is the seeded-sweep arm, GREEN out of the box (the merged impl matches the
# reference). Re-read INVARIANTS.md + COVERAGE.md before changing this gate.
set -euo pipefail

ORACLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIFF="$ORACLE_DIR/differential.py"

DIFFERENTIAL=0
SEEDS="${SEEDS:-200}"
SEED_START="${SEED_START:-1}"
RECORDS="${RECORDS:-12}"

usage() {
  cat <<'EOF'
team-copilot gate.sh — seeded impl-vs-reference differential arm (redum team lens)

Usage:
  gate.sh --differential [--seeds N] [--start S] [--records R]
  gate.sh --help

  --differential   Run the seeded impl-vs-reference roster differential (the only mode). For
                   each seed: generate one teammate work-state stream, fold it through the REAL
                   redum team lens AND the independent reference, normalize to the team-candidate
                   roster, diff.
  --seeds N        Seeds to sweep (default 200; the registered floor).
  --start S        First seed (default 1).
  --records R      Records per generated stream (default 12).

Exit: 0 all seeds green (impl == reference), 1 divergence found, 2 usage/IO.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --differential) DIFFERENTIAL=1; shift ;;
    --seeds)        SEEDS="${2:?--seeds needs a value}"; shift 2 ;;
    --start)        SEED_START="${2:?--start needs a value}"; shift 2 ;;
    --records)      RECORDS="${2:?--records needs a value}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    --*)            echo "error: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)              echo "error: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$DIFFERENTIAL" -ne 1 ]; then
  echo "error: --differential is required (the only supported mode)" >&2
  usage >&2
  exit 2
fi

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "error: python3 is required to run $DIFF" >&2; exit 2; }
[ -f "$DIFF" ] || { echo "error: differential engine missing: $DIFF" >&2; exit 2; }

RC=0
RESULT="$("$PY" "$DIFF" sweep --seeds "$SEEDS" --start "$SEED_START" --records "$RECORDS")" || RC=$?
echo "$RESULT"
exit "$RC"
