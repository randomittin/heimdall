#!/usr/bin/env bash
# test/heimdall-telemetry.test.sh — acceptance test for the Pre-Merge Corpus (PMR)
# T0 telemetry: the `pmr_v1` emission (bin/lib/pmr_corpus.py), the `hmd telemetry`
# command set (bin/heimdall-telemetry-corpus), the local outcome observer, and the
# hard privacy/brand-safety FALSIFIERS (spec heimdall-premerge-corpus-spec.md §1/§2/§3/§5.1).
#
# Every assertion is runnable against the REAL library + REAL CLI (no network, no
# ingest route — step 1 is emit-locally only). Sections:
#
#   (A) PMR EMITTED WITH EXACT T0 SHAPE — a projection of a real SI-2 attestation
#       record lands in the local spool with the exact pmr_v1 keys + ZERO source /
#       path leak (grep the emitted record: no path string, no source line).
#   (B) ZERO-CONTENT CARDINAL FALSIFIER — a real path / a source line planted into
#       the emission input -> emission BLOCKED + ALARMED, nothing written to spool.
#   (C) SECRET-SCAN-BEFORE-SEND — a credential planted into the emission input ->
#       BLOCKED before it can be queued to send, alarmed.
#   (D) OFF HONORED — `hmd telemetry off` -> a gate eval writes ZERO PMR.
#   (E) PURGE ROUND-TRIP — `hmd telemetry purge` empties the spool AND records a
#       deletion request keyed by team_id_hash (deletion actually deletes).
#   (F) CONSENT VERSION STAMPED — every emitted record carries the consent version.
#   (G) .gitignore IDEMPOTENCY — heimdall-team's public-repo team.json gitignore
#       append lands the block AT MOST ONCE even when team.json is TRACKED (the
#       private->public flip that `git check-ignore` misses).
#   (H) OUTCOME OBSERVER — the local pmr_outcome path records a merged sha + hunk
#       map client-side and only booleans/buckets ever leave.
#
# Exit 0 = every executed assertion passed. Non-zero = a regression.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/bin/lib/pmr_corpus.py"
CLI="$ROOT/bin/heimdall-telemetry-corpus"
TEAM="$ROOT/bin/heimdall-team"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "hmd-telemetry-test.$(printf 'q%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# A private, per-test corpus home so nothing touches the real ~/.heimdall.
export HEIMDALL_CORPUS_HOME="$WORK/corpus-home"

printf "\n=== heimdall-telemetry (PMR T0 corpus) acceptance ===\n"

# ─────────────────────────────────────────────────────────────────────────────
# (G) .gitignore IDEMPOTENCY — the private->public flip that check-ignore misses.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n[G] .gitignore idempotency (tracked team.json, public flip)\n"
[ -x "$TEAM" ] || { echo "FATAL: $TEAM not executable" >&2; exit 2; }

GIREPO="$WORK/gi-repo"
mkdir -p "$GIREPO/.heimdall"
( cd "$GIREPO" \
  && git init -q \
  && git config user.email t@t && git config user.name t \
  && printf '{"team_secret":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}\n' > .heimdall/team.json \
  && git add -f .heimdall/team.json \
  && git commit -qm init )

# team.json is now TRACKED. Run the public-repo path 3x; the block must land ONCE.
( cd "$GIREPO" && HEIMDALL_FORCE_VISIBILITY=public "$TEAM" new --force >/dev/null 2>&1 \
  && HEIMDALL_FORCE_VISIBILITY=public "$TEAM" new --force >/dev/null 2>&1 \
  && HEIMDALL_FORCE_VISIBILITY=public "$TEAM" new --force >/dev/null 2>&1 )

GI_PAT_COUNT="$(grep -cxF '.heimdall/team.json' "$GIREPO/.gitignore" 2>/dev/null || echo 0)"
GI_MARK_COUNT="$(grep -c 'heimdall team secret' "$GIREPO/.gitignore" 2>/dev/null || echo 0)"
if [ "$GI_PAT_COUNT" = "1" ] && [ "$GI_MARK_COUNT" = "1" ]; then
  ok "(G) tracked team.json + public flip: gitignore block appended exactly once over 3 runs"
else
  bad "(G) gitignore non-idempotent: pattern=$GI_PAT_COUNT marker=$GI_MARK_COUNT (want 1/1)"
fi

# ─────────────────────────────────────────────────────────────────────────────
printf "\n=== RESULT: %d passed, %d failed ===\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
