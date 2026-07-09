#!/usr/bin/env bash
# gate.sh — issue-collection differential gate, the registry gate_command driver.
#
# The registry (evals/oracles/registry.json) resolves this domain to:
#     evals/oracles/issue-collection/gate.sh --differential --seeds 200
# (bin/oracle-select issue-collection prints exactly that). This is the LIVE
# seeded-differential arm: for each of N seeds the INDEPENDENT reference generator
# (reference/aggregate_ref.generate_stream) produces a deterministic issue_v1 stream;
# the SAME stream is fed to BOTH the impl aggregate (bin/lib/cp_issue_aggregate) and
# the independent reference aggregate (reference/aggregate_ref); both are normalized
# to the served/suppressed/excluded_security partition and DIFFED. PASS iff impl ==
# reference on every seed. On the first divergence the runner prints the seed + the
# first-divergence pinpoint and exits nonzero.
#
# differential.py is the SAME diff-truth run.sh drives on fixtures and that bin/falsify
# orchestrates — this script is the seeded-sweep arm, runnable + GREEN out of the box
# (the merged impl already matches the reference).
#
# Re-read INVARIANTS.md + COVERAGE.md before changing this gate. A green result that
# did not actually run the impl-vs-reference differential is a false-green.
set -euo pipefail

ORACLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIFF="$ORACLE_DIR/differential.py"

DIFFERENTIAL=0
SEEDS="${SEEDS:-200}"
SEED_START="${SEED_START:-1}"
KMIN=""
RECORDS="${RECORDS:-400}"
SIGNATURES="${SIGNATURES:-12}"
TEAMS="${TEAMS:-25}"

usage() {
  cat <<'EOF'
issue-collection gate.sh — seeded impl-vs-reference differential arm

Usage:
  gate.sh --differential [--seeds N] [--start S] [--k-min K]
          [--records R] [--signatures G] [--teams T]
  gate.sh --help

  --differential   Run the seeded impl-vs-reference k-anon differential (the only
                   supported mode). For each seed: generate one issue_v1 stream,
                   aggregate it through the impl AND the independent reference,
                   normalize both to served/suppressed/excluded_security, and diff.
  --seeds N        Seeds to sweep (default 200; the registered floor).
  --start S        First seed (default 1).
  --k-min K        k-anon floor override (default: issue_corpus.ISSUE_K_ANONYMITY_MIN).
  --records R      Records per generated stream (default 400).
  --signatures G   Distinct error signatures per stream (default 12).
  --teams T        Distinct teams per stream (default 25).

Exit: 0 = all seeds green (impl == reference), 1 = divergence found, 2 = usage/IO.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --differential) DIFFERENTIAL=1; shift ;;
    --seeds)        SEEDS="${2:?--seeds needs a value}"; shift 2 ;;
    --start)        SEED_START="${2:?--start needs a value}"; shift 2 ;;
    --k-min)        KMIN="${2:?--k-min needs a value}"; shift 2 ;;
    --records)      RECORDS="${2:?--records needs a value}"; shift 2 ;;
    --signatures)   SIGNATURES="${2:?--signatures needs a value}"; shift 2 ;;
    --teams)        TEAMS="${2:?--teams needs a value}"; shift 2 ;;
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

cmd=("$PY" "$DIFF" sweep --seeds "$SEEDS" --start "$SEED_START"
     --records "$RECORDS" --signatures "$SIGNATURES" --teams "$TEAMS")
[ -n "$KMIN" ] && cmd+=(--k-min "$KMIN")

# Capture without tripping `set -e` on a divergence (sweep exits 1 on divergence,
# which is the gate's own exit code, not a harness error).
RC=0
RESULT="$("${cmd[@]}")" || RC=$?
echo "$RESULT"
exit "$RC"
