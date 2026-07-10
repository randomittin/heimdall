#!/usr/bin/env bash
# test/heimdall-triage-team.test.sh — TEAM MODE (TRACK A) falsifiable spec test for
# team-triaging: claim-gated pick, suggest-only presence×expertise routing, and reap→checkpoint
# handoff. Proven against the REAL heimdall-claim engine + REAL issue_queue/triage_handoff libs
# (no canned data, no LLM), over throwaway ledgers under a mktemp dir.
#
# The RED-without-fix falsifiers this locks in:
#   (1) DOUBLE-PICK BLOCKED — a teammate's git-shared claim on an issue makes THIS instance's
#       pick SKIP it. RED before the fix: the machine-local in_flight bucket let both proceed
#       (the OFF path below still does — that contrast proves the gate is load-bearing).
#   (2) ROUTING SUGGEST-ONLY — routing SUGGESTS by presence×activity, NEVER auto-assigns:
#       offline teammates are never suggested, and the route call mutates NOTHING (no in_flight,
#       no claim). A regression that auto-assigned would flip assigned=false / write a claim.
#   (3) REAP → CHECKPOINT HANDOFF — a dropped teammate's TTL-expired issue claim reaps free AND
#       their checkpoint is read so the issue is ADOPTABLE (resume, not restart). RED before:
#       a stale claim never reaps (issue wedged) or no resume context (adopter restarts).
#   (4) TEAM ISOLATION — a DIFFERENT team's issue claims are never visible (different repo ==
#       different .planning ledger). Cross-team read must stay impossible (rr-multitenant-
#       isolation stays 1.0). A regression that shared a ledger would block the other team.
#
# Mechanical asserts; a skip is a finding (no fake passes). Two teammates are simulated on ONE
# machine by PLANTING a teammate's claim/checkpoint file directly (exactly what `git pull` would
# deliver from another machine) while THIS instance keeps its own git-derived HAID.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PYQ="$ROOT/bin/lib/issue_queue.py"
PYH="$ROOT/bin/lib/triage_handoff.py"
CLAIM="$ROOT/bin/heimdall-claim"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }
[ -f "$PYQ" ] || { echo "FATAL: $PYQ missing" >&2; exit 2; }
[ -f "$PYH" ] || { echo "FATAL: $PYH missing" >&2; exit 2; }
[ -x "$CLAIM" ] || { echo "FATAL: $CLAIM not executable (the reused claim engine)" >&2; exit 2; }

WORK="$(mktemp -d -t "triage-team.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

NOW="$(date -u +%FT%TZ)"
PAST="2020-01-01T00:00:00Z"   # a long-expired heartbeat (the dropped teammate)

# A_HAID is the teammate whose synced records we plant; it must differ from THIS instance's
# git-derived HAID so heimdall-claim treats it as "another agent".
A_HAID="haid:sarah.mbp-aaaa"
A_SLUG="haid_sarah.mbp-aaaa"

# X and Y are two github issues; X sorts first (ascending-id tie-break), so a free pick prefers
# X. issue surface of github:o/r#11 == issue:github_o_r_11 (issue_claim.issue_surface).
X_ID="github:o/r#11"; X_SURF="issue:github_o_r_11"
Y_ID="github:o/r#22"; Y_SURF="issue:github_o_r_22"
X_RAW='{"repo":"o/r","number":11,"title":"null deref in src/auth.ts login","created_at":"2026-01-01T00:00:00Z"}'
Y_RAW='{"repo":"o/r","number":22,"title":"slow query in src/pay.ts","created_at":"2026-01-01T00:00:00Z"}'

# plant_claim <planning-dir> <heartbeat-iso> <surface> — write teammate A's git-shared claim
# file directly (simulating a git-synced claim from A's machine).
plant_claim() {
  local planning="$1" hb="$2" surf="$3"
  mkdir -p "$planning/ledger/claims"
  jq -n --arg h "$A_HAID" --arg surf "$surf" --arg hb "$hb" \
    '{haid:$h, human:"sarah", claimed_surfaces:[$surf], task_ref:"issue-triage:github:o/r#11",
      claimed_at:$hb, ttl_minutes:90, heartbeat:$hb}' \
    > "$planning/ledger/claims/$A_SLUG.json"
}

# plant_checkpoint <planning-dir> — write teammate A's SHARED checkpoint for issue X.
plant_checkpoint() {
  local planning="$1"
  mkdir -p "$planning/ledger/checkpoints"
  jq -n --arg h "$A_HAID" '
    {schema:"team_checkpoint_v1", haid:$h, human:"sarah", branch:"feat/fix-11",
     head_sha:"abc1234", phase:"triage", progress_pct:40,
     active_goal:"diagnosing the null deref in login", claimed_surfaces:["src/auth.ts#login"],
     task_ref:"issue-triage:github:o/r#11", updated_at:"2026-07-10T00:00:00Z", resumable:true}' \
    > "$planning/ledger/checkpoints/$A_SLUG.json"
}

# qrun <home> <planning> <team-flag> -- <argv...> — run the issue_queue CLI pinned to a ledger.
qrun() {
  local home="$1" planning="$2" team="$3"; shift 3
  [ "$1" = "--" ] && shift
  HEIMDALL_HOME="$home" HEIMDALL_PLANNING_DIR="$planning" HEIMDALL_TEAM="$team" \
    python3 "$PYQ" "$@"
}

# ════════════════════════════════════════════════════════════════════════════
# (1) DOUBLE-PICK BLOCKED — a teammate's claim on X makes THIS pick skip X.
# ════════════════════════════════════════════════════════════════════════════
S1="$WORK/case1"; H1="$S1/.heimdall"; P1="$S1/.planning"
mkdir -p "$H1" "$P1"
qrun "$H1" "$P1" off -- ingest --source github --raw "$X_RAW" >/dev/null 2>&1
qrun "$H1" "$P1" off -- ingest --source github --raw "$Y_RAW" >/dev/null 2>&1
plant_claim "$P1" "$NOW" "$X_SURF"   # teammate A holds an ACTIVE claim on X

PICK_ON="$(qrun "$H1" "$P1" on -- pick 2>/dev/null | jq -r '.picked.id // "none"')"
if [ "$PICK_ON" = "$Y_ID" ]; then
  ok "(1) claim-gated pick SKIPS teammate-claimed X (github:o/r#11) → picks free Y (github:o/r#22)"
else
  bad "(1) claim-gated pick did not skip the teammate-held issue (got '$PICK_ON', expected $Y_ID)"
fi

# THIS instance's claim now covers Y (git-shared, HAID-attributed) — proves the promotion wrote.
THIS_CLAIM="$(HEIMDALL_PLANNING_DIR="$P1" "$CLAIM" list --json 2>/dev/null \
  | jq -r '[.[] | select(.haid != "'"$A_HAID"'") | .claimed_surfaces[]] | index("'"$Y_SURF"'") != null' 2>/dev/null)"
if [ "$THIS_CLAIM" = "true" ]; then
  ok "(1b) the pick PROMOTED to a HAID-attributed git-shared claim on Y ($Y_SURF) via heimdall-claim"
else
  bad "(1b) pick did not write a git-shared issue claim for Y (list: $(HEIMDALL_PLANNING_DIR="$P1" "$CLAIM" list --json 2>/dev/null))"
fi

# ── RED contrast: with the gate OFF (the old machine-local world) X is NOT skipped. ──
S1B="$WORK/case1b"; H1B="$S1B/.heimdall"; P1B="$S1B/.planning"
mkdir -p "$H1B" "$P1B"
qrun "$H1B" "$P1B" off -- ingest --source github --raw "$X_RAW" >/dev/null 2>&1
plant_claim "$P1B" "$NOW" "$X_SURF"
PICK_OFF="$(qrun "$H1B" "$P1B" off -- pick 2>/dev/null | jq -r '.picked.id // "none"')"
# and with the gate ON and ONLY X queued (all held) → nothing pickable.
S1C="$WORK/case1c"; H1C="$S1C/.heimdall"; P1C="$S1C/.planning"
mkdir -p "$H1C" "$P1C"
qrun "$H1C" "$P1C" off -- ingest --source github --raw "$X_RAW" >/dev/null 2>&1
plant_claim "$P1C" "$NOW" "$X_SURF"
PICK_ON_ONLYX="$(qrun "$H1C" "$P1C" on -- pick 2>/dev/null | jq -r '.picked.id // "none"')"
if [ "$PICK_OFF" = "$X_ID" ] && [ "$PICK_ON_ONLYX" = "none" ]; then
  ok "(1c) FALSIFIABLE: gate OFF picks the teammate-claimed X (double-work); gate ON returns none — the guard is load-bearing"
else
  bad "(1c) gate contrast failed (off='$PICK_OFF' expected $X_ID ; on-only-X='$PICK_ON_ONLYX' expected none)"
fi

# ════════════════════════════════════════════════════════════════════════════
# (2) ROUTING SUGGEST-ONLY — presence×expertise, offline excluded, zero mutation.
# ════════════════════════════════════════════════════════════════════════════
S2="$WORK/case2"; H2="$S2/.heimdall"; P2="$S2/.planning"
mkdir -p "$H2" "$P2"
qrun "$H2" "$P2" off -- ingest --source github --raw "$X_RAW" >/dev/null 2>&1
# roster: ONLINE+overlap (sarah, touched src/auth.ts) ; ONLINE no-overlap (raj) ; OFFLINE overlap (priya)
TEAM_JSON="$WORK/roster.json"
cat > "$TEAM_JSON" <<'EOF'
[
  {"haid":"haid:sarah.x","human":"sarah","files_touched":["src/auth.ts#login"],"ts":1000.0},
  {"haid":"haid:raj.x","human":"raj","files_touched":["src/pay.ts"],"ts":1000.0},
  {"haid":"haid:priya.x","human":"priya","files_touched":["src/auth.ts"],"ts":0.0}
]
EOF
ROUTE="$(qrun "$H2" "$P2" on -- route --id "$X_ID" --teammates "@$TEAM_JSON" --now 1000 --ttl 45 2>/dev/null)"
R_TOP="$(echo "$ROUTE" | jq -r '.suggestions[0].human // "none"')"
R_N="$(echo "$ROUTE" | jq -r '.suggestions | length')"
R_ASSIGNED="$(echo "$ROUTE" | jq -r '.assigned')"
R_HAS_PRIYA="$(echo "$ROUTE" | jq -r '[.suggestions[].human] | index("priya") != null')"
if [ "$R_TOP" = "sarah" ] && [ "$R_N" = "1" ] && [ "$R_ASSIGNED" = "false" ] && [ "$R_HAS_PRIYA" = "false" ]; then
  ok "(2) routing SUGGESTS sarah (online×overlap), excludes raj (no overlap) + priya (OFFLINE), assigned=false"
else
  bad "(2) routing wrong (top='$R_TOP' n=$R_N assigned=$R_ASSIGNED has_priya=$R_HAS_PRIYA)"
  echo "$ROUTE" | jq '{assigned,suggestions:[.suggestions[]|{human,score,online}]}' 2>/dev/null
fi

# routing MUST NOT mutate — no in_flight, no claim written by the route call.
INFLIGHT_AFTER="$(qrun "$H2" "$P2" on -- status 2>/dev/null | jq -r '.in_flight')"
CLAIMS_AFTER="$([ -d "$P2/ledger/claims" ] && ls -1 "$P2/ledger/claims" 2>/dev/null | grep -c '\.json$' || echo 0)"
if [ "$INFLIGHT_AFTER" = "0" ] && [ "$CLAIMS_AFTER" = "0" ]; then
  ok "(2b) SUGGEST-ONLY: the route call assigned/claimed NOTHING (in_flight=0, 0 claim files) — a human confirms"
else
  bad "(2b) routing had a side effect (in_flight=$INFLIGHT_AFTER, claim files=$CLAIMS_AFTER) — must be pure suggest"
fi

# ════════════════════════════════════════════════════════════════════════════
# (3) REAP → CHECKPOINT HANDOFF — dropped teammate's issue reaps + is adoptable.
# ════════════════════════════════════════════════════════════════════════════
S3="$WORK/case3"; H3="$S3/.heimdall"; P3="$S3/.planning"
mkdir -p "$H3" "$P3"
qrun "$H3" "$P3" off -- ingest --source github --raw "$X_RAW" >/dev/null 2>&1
plant_claim "$P3" "$PAST" "$X_SURF"   # teammate A DROPPED: claim heartbeat long expired
plant_checkpoint "$P3"                # A's resumable checkpoint for X survives (git-shared)

hrun() { HEIMDALL_PLANNING_DIR="$P3" python3 "$PYH" "$@"; }

# find_handoff recovers A's in-flight triage context (resume, not restart).
HAND="$(hrun find --id "$X_ID" 2>/dev/null)"
H_FROM="$(echo "$HAND" | jq -r '.from_haid // "none"')"
H_PHASE="$(echo "$HAND" | jq -r '.phase // "none"')"
H_PCT="$(echo "$HAND" | jq -r '.progress_pct // "none"')"
H_RESUMABLE="$(echo "$HAND" | jq -r '.resumable')"
if [ "$H_FROM" = "$A_HAID" ] && [ "$H_PHASE" = "triage" ] && [ "$H_PCT" = "40" ] && [ "$H_RESUMABLE" = "true" ]; then
  ok "(3) handoff: dropped teammate's checkpoint READ → resume context recovered (from=sarah, phase=triage, 40%, resumable)"
else
  bad "(3) handoff context not recovered (from='$H_FROM' phase='$H_PHASE' pct='$H_PCT' resumable='$H_RESUMABLE')"
fi

# after reap, the dropped teammate's EXPIRED claim is gone → X is pickable again (re-queued).
hrun reap >/dev/null 2>&1
PICK_AFTER_REAP="$(qrun "$H3" "$P3" on -- pick 2>/dev/null | jq -r '.picked.id // "none"')"
if [ "$PICK_AFTER_REAP" = "$X_ID" ]; then
  ok "(3b) reap freed the dropped teammate's TTL-expired claim → X is re-pickable (adoptable, not wedged)"
else
  bad "(3b) X not re-pickable after reap (got '$PICK_AFTER_REAP', expected $X_ID) — stale-claim-not-reaped"
fi

# ════════════════════════════════════════════════════════════════════════════
# (4) TEAM ISOLATION — a DIFFERENT team's claim ledger is never visible.
# ════════════════════════════════════════════════════════════════════════════
TA="$WORK/teamA"; TB="$WORK/teamB"
mkdir -p "$TA/.planning" "$TB/.heimdall" "$TB/.planning"
plant_claim "$TA/.planning" "$NOW" "$X_SURF"   # team A actively holds X in ITS ledger
qrun "$TB/.heimdall" "$TB/.planning" off -- ingest --source github --raw "$X_RAW" >/dev/null 2>&1
PICK_TEAMB="$(qrun "$TB/.heimdall" "$TB/.planning" on -- pick 2>/dev/null | jq -r '.picked.id // "none"')"
if [ "$PICK_TEAMB" = "$X_ID" ]; then
  ok "(4) team isolation: team B never sees team A's issue claim (different .planning ledger) → picks X freely"
else
  bad "(4) team B was blocked by team A's claim — cross-team leak (got '$PICK_TEAMB', expected $X_ID)"
fi

# ════════════════════════════════════════════════════════════════════════════
echo ""
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "  triage-team tests: \033[32m%d passed\033[0m, 0 failed (of %d)\n" "$PASS" "$TOTAL"
  exit 0
else
  printf "  triage-team tests: %d passed, \033[31m%d failed\033[0m (of %d)\n" "$PASS" "$FAIL" "$TOTAL"
  exit 1
fi
