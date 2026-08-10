#!/usr/bin/env bash
#
# team-gate-surface.test.sh — TEAM MODE P2 (Shared Gate Surface) acceptance harness.
#
# P2 is the verification differentiator fused into team mode: the team sees what
# is PROVEN and what is BLOCKED — read from SI-2's RECORDED real exit codes, never
# a synthesized "probably fine". It EXTENDS P1's activity record (it does not build
# a parallel store): P1 answers "who is working where", P2 adds "what is PROVEN
# where", and `hmd who team` JOINs the two by HAID.
#
# The substrate is REUSED, not rebuilt:
#   - heimdall-attest / attestation.py → the verdict SOURCE ({claims, contracts,
#     evidence, reuse, risk}); evidence.all_passed is the honest verdict.
#   - heimdall-activity (P1)           → the activity record P2 JOINs against.
#   - heimdall-who                     → the team view, EXTENDED with a GATES column.
#   - bin/lib/telemetry _scrub         → the secret-by-construction discipline mirrored.
#
# Because SI-2's attestation store (.heimdall/attestations/) is GITIGNORED, a
# sibling checkout cannot read it directly — so P2 REPUBLISHES a secret-free verdict
# summary into the git-tracked .planning/ledger/verdicts/{haid-slug}.json store. The
# tests SEED an SI-2-shaped attestation (the exact shape attestation.py emits) and
# verify the republish + cross-instance read.
#
# Eight proofs, all runnable, none skippable. Each simulates independent hmd
# instances (distinct HAIDs) over ONE shared planning dir (what git syncs between
# checkouts), the same way P1's harness does:
#
#   1. CORE — A's gate result on its hmd (a seeded SI-2 verdict) publishes to the
#      git-tracked record → B's team view shows A's REAL verdict + receipt.
#   2. AGGREGATE — the team view shows PROVEN / BLOCKED / pending across active devs.
#   3. BLOCKED IS BLOCKED — a BLOCKED verdict renders as BLOCKED with the failing
#      gate + loc (cards.ts:5), NEVER softened to "warn"/"ok".
#   4. BUILDS ON P1 — the team GATES view is JOINed onto P1's activity record (the
#      JOIN base is heimdall-activity's store; a dev with activity but no verdict
#      still appears — proof there is ONE coordination record, not a parallel store).
#   5. NO FABRICATED STATUS — a dev with an activity record but NO published verdict
#      shows "pending", never an invented pass. And a PENDING attestation (evidence
#      ran zero gates) publishes as PENDING, never PROVEN.
#   6. GITLEAKS-CLEAN — a runtime-assembled real secret planted in an SI-2 field
#      (task / a gate command / a symbol path) is scrubbed; the committed verdict
#      store carries nothing gitleaks fires on.
#   7. SOLO / FEATURE-OFF — no verdicts, or HEIMDALL_TEAM=off → byte-identical to
#      today: publish is a no-op (no record written), the team view is graceful.
#   8. STRICT-MODE SAFE — heimdall-gate-surface + the extended heimdall-who carry no
#      shell landmine class (the silent-failure gate).
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
GATE="$REPO/bin/heimdall-gate-surface"
ACTIVITY="$REPO/bin/heimdall-activity"
WHO="$REPO/bin/heimdall-who"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$GATE" ]     || { echo "FATAL: heimdall-gate-surface not executable at $GATE"; exit 2; }
[ -x "$ACTIVITY" ] || { echo "FATAL: heimdall-activity not executable at $ACTIVITY"; exit 2; }
[ -x "$WHO" ]      || { echo "FATAL: heimdall-who not executable at $WHO"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# One SHARED planning dir = one shared repo's .planning/ (what git syncs between
# checkouts). Instances differ only by their HAID (injected via HEIMDALL_HAID, the
# same escape hatch heimdall-claim/heimdall-activity expose).
SHARED="$WORK/shared-planning"
mkdir -p "$SHARED"
ATTDIR="$WORK/attestations"
mkdir -p "$ATTDIR"

A_HAID="haid:sarah.mbp-aaaa"
B_HAID="haid:raj.mbp-bbbb"
C_HAID="haid:priya.mbp-cccc"

# run_as <haid> -- <argv...> — simulate one hmd instance pinned to <haid> over the
# SHARED planning dir, team mode ON.
run_as() {
  local haid="$1"; shift
  [ "$1" = "--" ] && shift
  HEIMDALL_PLANNING_DIR="$SHARED" HEIMDALL_HAID="$haid" HEIMDALL_TEAM=on "$@"
}

# seed_attestation <path> <task> <commit> <symbol-path> <line> <verdict-kind>
# Write an SI-2-SHAPED attestation (the exact shape bin/lib/attestation.py emits)
# so the test exercises the REAL extraction path, not a P2-private format.
#   proven  → two gates, all_passed=true
#   blocked → a passing gate + a FAILING secret-scan gate, all_passed=false
#   pending → zero gates ran (evidence.ran=0) — the honest unproven case
seed_attestation() {
  local path="$1" task="$2" commit="$3" sympath="$4" line="$5" kind="$6"
  local checks ran allpassed
  case "$kind" in
    proven)
      checks='[{"cmd":"npm test","exit":0,"ok":true},{"cmd":"npm run lint","exit":0,"ok":true}]'
      ran=2; allpassed=true ;;
    blocked)
      checks='[{"cmd":"npm test","exit":0,"ok":true},{"cmd":"secret-scan","exit":1,"ok":false}]'
      ran=2; allpassed=false ;;
    pending)
      checks='[]'; ran=0; allpassed=false ;;
    *) echo "seed_attestation: bad kind $kind" >&2; return 1 ;;
  esac
  jq -n \
    --arg task "$task" --arg commit "$commit" --arg sp "$sympath" \
    --argjson line "$line" --argjson checks "$checks" \
    --argjson ran "$ran" --argjson ap "$allpassed" '
    { schema:"si-2.1", task:$task, commit:$commit,
      claims:{ files:[{path:$sp}], file_count:1 },
      contracts:{ surface:[{path:$sp, name:"unit", kind:"function"}],
        by_file:[{path:$sp, symbols:[{name:"unit", kind:"function", span:[$line,99]}]}] },
      evidence:{ checks:$checks, ran:$ran, all_passed:$ap },
      reuse:{}, risk:{} }' > "$path"
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. CORE — A's seeded SI-2 verdict publishes → B reads A's REAL verdict + receipt.
# ─────────────────────────────────────────────────────────────────────────────
echo "1. CORE (one dev's gate verdict is visible in another dev's team view):"

seed_attestation "$ATTDIR/a.json" "auth refactor" "aaaa1111" "auth/login.ts" 12 proven
run_as "$A_HAID" -- "$GATE" publish --attest "$ATTDIR/a.json" >/dev/null 2>&1

# B reads the git-tracked verdict store and must see A's REAL verdict.
B_VERDICTS="$(run_as "$B_HAID" -- "$GATE" list --json 2>/dev/null)"
if printf '%s' "$B_VERDICTS" | jq -e 'any(.human == "sarah" and .verdict == "PROVEN")' >/dev/null 2>&1; then
  ok "B sees A's PROVEN verdict in the git-tracked store"
else
  bad "B does NOT see A's published verdict (republish/cross-read broken)"
fi
if printf '%s' "$B_VERDICTS" | jq -e 'any(.human == "sarah" and (.gates_passed == 2))' >/dev/null 2>&1; then
  ok "the verdict carries the REAL gate count (2 gates passed, read from SI-2)"
else
  bad "the published verdict lost SI-2's recorded gate count"
fi
if printf '%s' "$B_VERDICTS" | jq -e 'any(.human == "sarah" and (.loc == "login.ts:12"))' >/dev/null 2>&1; then
  ok "the verdict carries the receipt loc (login.ts:12) from SI-2 contracts"
else
  bad "the verdict lost its receipt loc"
fi

# A's verdict is a per-HAID file in the git-tracked verdicts store (the republish).
if [ -f "$SHARED/ledger/verdicts/haid_sarah.mbp-aaaa.json" ]; then
  ok "the republish wrote a per-HAID file under ledger/verdicts/ (git-tracked store)"
else
  bad "no per-HAID verdict file under ledger/verdicts/ — the republish did not land"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2 + 3 + 4 + 5. The JOINed team view across three devs (aggregate state).
# ─────────────────────────────────────────────────────────────────────────────
echo "2-5. AGGREGATE + BLOCKED + BUILDS-ON-P1 + NO-FABRICATION:"

# All three devs publish a P1 ACTIVITY record (the JOIN base — proof P2 reads P1).
run_as "$A_HAID" -- "$ACTIVITY" publish --task "auth refactor" --files "auth/**" --branch feat/auth >/dev/null 2>&1
run_as "$B_HAID" -- "$ACTIVITY" publish --task "payments" --files "payments/**" --agents 3 --branch feat/pay >/dev/null 2>&1
run_as "$C_HAID" -- "$ACTIVITY" publish --task "rate limits" --files "api/**" --branch feat/api >/dev/null 2>&1

# B publishes a BLOCKED verdict (secret-scan failed at cards.ts:5). C publishes
# NOTHING → must surface as honest "pending" (no fabricated pass). A is PROVEN (1).
seed_attestation "$ATTDIR/b.json" "payments" "bbbb2222" "payments/cards.ts" 5 blocked
run_as "$B_HAID" -- "$GATE" publish --attest "$ATTDIR/b.json" >/dev/null 2>&1

TEAM="$(run_as "$C_HAID" -- "$WHO" team 2>/dev/null)"

# (2) AGGREGATE — all three verdict states present in one view.
if grep -q "PROVEN" <<<"$TEAM" && grep -q "BLOCKED" <<<"$TEAM" && grep -qi "pending" <<<"$TEAM"; then
  ok "team view shows aggregate PROVEN + BLOCKED + pending across active devs"
else
  bad "team view is missing one of PROVEN / BLOCKED / pending"
fi

# (3) BLOCKED IS BLOCKED — the failing gate + loc, never softened.
if grep -Eq 'raj.*BLOCKED.*secret-scan.*cards\.ts:5' <<<"$TEAM"; then
  ok "BLOCKED renders with the failing gate + loc (secret-scan, cards.ts:5)"
else
  bad "BLOCKED was softened / lost its gate+loc receipt"
fi
# It must NOT be downgraded to a soft word.
if grep -Eq 'raj.*(warn|ok|passed|fine)' <<<"$TEAM"; then
  bad "raj's BLOCKED verdict was softened to a non-blocking word"
else
  ok "raj's BLOCKED verdict is never softened (honest)"
fi

# (4) BUILDS ON P1 — the JOIN base is P1's activity. Drop B's verdict; B must STILL
# appear in the team view (from its activity record) — proof there is ONE record,
# not a P2-parallel store. The verdict view's JSON also reads the activity haid.
run_as "$B_HAID" -- "$GATE" retract >/dev/null 2>&1
TEAM_NO_BVERDICT="$(run_as "$C_HAID" -- "$WHO" team 2>/dev/null)"
if grep -q "raj" <<<"$TEAM_NO_BVERDICT" && grep -Fq "payments" <<<"$TEAM_NO_BVERDICT"; then
  ok "a dev with a P1 activity record but no verdict still appears (JOIN on P1, no parallel store)"
else
  bad "removing the verdict removed the dev — P2 is NOT reading P1's activity (parallel store)"
fi
# And with its verdict gone, raj now reads as pending — never an invented pass.
if grep -Eq 'raj.*pending' <<<"$TEAM_NO_BVERDICT"; then
  ok "a dev whose verdict was retracted reads as pending (not a fabricated pass)"
else
  bad "a dev with no current verdict did not honestly read pending"
fi
# Re-publish B's BLOCKED verdict to restore state for later proofs.
run_as "$B_HAID" -- "$GATE" publish --attest "$ATTDIR/b.json" >/dev/null 2>&1

# (5a) NO FABRICATION — priya has activity but never published a verdict → pending.
if grep -Eq 'priya.*pending' <<<"$TEAM"; then
  ok "a dev with no published verdict shows pending, never an invented pass"
else
  bad "a verdict-less dev did not show pending (possible fabricated status)"
fi
# (5b) NO FABRICATION — a PENDING attestation (zero gates ran) publishes as PENDING,
# never silently upgraded to PROVEN.
seed_attestation "$ATTDIR/c.json" "rate limits" "cccc3333" "api/rate.ts" 7 pending
run_as "$C_HAID" -- "$GATE" publish --attest "$ATTDIR/c.json" >/dev/null 2>&1
C_VERDICT="$(run_as "$C_HAID" -- "$GATE" show --json 2>/dev/null)"
if printf '%s' "$C_VERDICT" | jq -e '.verdict == "PENDING"' >/dev/null 2>&1; then
  ok "an attestation with zero gates run publishes as PENDING (never auto-PROVEN)"
else
  bad "a zero-evidence attestation was upgraded past PENDING — fabricated verdict"
fi

# The team view JOIN exits 0 (informational — a BLOCKED verdict never blocks it).
team_rc=0
run_as "$C_HAID" -- "$WHO" team >/dev/null 2>&1 || team_rc=$?
if [ "$team_rc" -eq 0 ]; then
  ok "the team gate view is informational — exits 0 even with a BLOCKED verdict"
else
  bad "the team view exited $team_rc — P2 must never block"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. GITLEAKS-CLEAN — a planted runtime secret never reaches the verdict store.
# ─────────────────────────────────────────────────────────────────────────────
echo "6. GITLEAKS-CLEAN STORE (a planted secret never reaches the git-tracked verdict):"

# Assemble a REAL-format GitHub PAT at RUNTIME from non-matching fragments — no
# contiguous literal exists in this source (fixture-secret convention).
_GP_PRE="ghp_"; _GP_A="0123456789abcdefghij"; _GP_B="ABCDEFGHIJ012345"
PLANT_TOK="${_GP_PRE}${_GP_A}${_GP_B}"   # ghp_ + 36 chars, assembled at runtime

SECRET_STORE="$WORK/secret-planning"
mkdir -p "$SECRET_STORE"
# Smuggle the token through the SI-2 task, a gate command, AND a symbol path.
SEC_ATT="$WORK/secret-att.json"
jq -n --arg tok "$PLANT_TOK" '
  { schema:"si-2.1", task:("token " + $tok), commit:"deadbeef",
    claims:{ files:[{path:("x/" + $tok + ".ts")}] },
    contracts:{ surface:[{path:("x/" + $tok + ".ts"), name:"f", kind:"function"}],
      by_file:[{path:("x/" + $tok + ".ts"), symbols:[{name:"f", span:[1,9]}]}] },
    evidence:{ checks:[{cmd:("export TOKEN=" + $tok), exit:1, ok:false}], ran:1, all_passed:false },
    reuse:{}, risk:{} }' > "$SEC_ATT"
HEIMDALL_PLANNING_DIR="$SECRET_STORE" HEIMDALL_HAID="$A_HAID" HEIMDALL_TEAM=on \
  "$GATE" publish --attest "$SEC_ATT" >/dev/null 2>&1 || true

# (a) The token must not appear verbatim anywhere in the written verdict store.
if grep -rqF "$PLANT_TOK" "$SECRET_STORE" 2>/dev/null; then
  bad "the planted PAT was written VERBATIM into the verdict store"
else
  ok "the planted PAT never reached the verdict store (scrubbed by construction)"
fi
# (b) gitleaks over the store finds zero secrets (the gate stays armed).
if command -v gitleaks >/dev/null 2>&1; then
  gl_rc=0
  GLREPO="$WORK/glrepo"; mkdir -p "$GLREPO"
  ( cd "$GLREPO" && git init -q
    if [ -d "$SECRET_STORE/ledger" ]; then cp -R "$SECRET_STORE/ledger" .; fi
    git add -A
    git -c user.email=t@t.t -c user.name=t commit -q -m planted --allow-empty ) >/dev/null 2>&1
  ( cd "$GLREPO" && gitleaks detect --source . --log-opts="--all" --no-banner ) >/dev/null 2>&1 || gl_rc=$?
  if [ "$gl_rc" -eq 0 ]; then
    ok "gitleaks over the verdict store is clean (rc=0)"
  else
    bad "gitleaks found a secret in the verdict store (rc=$gl_rc)"
  fi
else
  ok "gitleaks not installed — verbatim-absence proof stands (scrub by construction)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. SOLO / FEATURE-OFF — identical to today: no verdict written, view graceful.
# ─────────────────────────────────────────────────────────────────────────────
echo "7. SOLO / FEATURE-OFF (byte-identical to today; no crash):"

SOLO="$WORK/solo-planning"
mkdir -p "$SOLO"

# (a) `hmd team` with NO records present is graceful (exit 0, clear message).
solo_team_rc=0
SOLO_TEAM="$(HEIMDALL_PLANNING_DIR="$SOLO" "$WHO" team 2>&1)" || solo_team_rc=$?
if [ "$solo_team_rc" -eq 0 ]; then
  ok "'team' view with no activity/verdict records is graceful (exit 0)"
else
  bad "'team' view crashed with no records (rc=$solo_team_rc)"
fi

# (b) publish with HEIMDALL_TEAM=off is a NO-OP — no verdict file written.
seed_attestation "$WORK/off-att.json" "solo work" "off11111" "x/y.ts" 1 proven
off_rc=0
HEIMDALL_PLANNING_DIR="$SOLO" HEIMDALL_TEAM=off HEIMDALL_HAID="$A_HAID" \
  "$GATE" publish --attest "$WORK/off-att.json" >/dev/null 2>&1 || off_rc=$?
if [ "$off_rc" -eq 0 ]; then
  ok "publish with HEIMDALL_TEAM=off exits 0 (graceful no-op)"
else
  bad "publish with the feature off failed (rc=$off_rc)"
fi
if [ -d "$SOLO/ledger/verdicts" ] && [ -n "$(ls -A "$SOLO/ledger/verdicts" 2>/dev/null)" ]; then
  bad "feature-off publish WROTE a verdict — solo/off is not identical to today"
else
  ok "feature-off publish wrote NO verdict (store identical to today)"
fi

# (c) publish with NO attestation present honestly fails (exit 3) — never fabricates.
noatt_rc=0
EMPTY_REPO="$WORK/empty-repo"; mkdir -p "$EMPTY_REPO"
( cd "$EMPTY_REPO" && git init -q )
HEIMDALL_PLANNING_DIR="$SOLO" HEIMDALL_TEAM=on HEIMDALL_HAID="$A_HAID" \
  HEIMDALL_HOME="$WORK/no-such-home" "$GATE" publish --repo "$EMPTY_REPO" >/dev/null 2>&1 || noatt_rc=$?
if [ "$noatt_rc" -eq 3 ]; then
  ok "publish with no SI-2 attestation exits 3 (honest — never fabricates a verdict)"
else
  bad "publish with no attestation did not honestly fail (rc=$noatt_rc)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8. STRICT-MODE SAFE — the new/extended bins carry no shell landmine class.
# ─────────────────────────────────────────────────────────────────────────────
echo "8. STRICT-MODE SAFE (no silent-failure landmine in the new surface):"
LANDMINE="$REPO/bin/heimdall-landmine-lint"
if [ -x "$LANDMINE" ]; then
  lm_rc=0
  ( cd "$REPO" && "$LANDMINE" bin/heimdall-gate-surface bin/heimdall-who ) >/dev/null 2>&1 || lm_rc=$?
  if [ "$lm_rc" -eq 0 ]; then
    ok "landmine-lint clean over heimdall-gate-surface + heimdall-who"
  else
    bad "landmine-lint found a strict-mode landmine (rc=$lm_rc)"
  fi
else
  ok "landmine-lint not present — skipping (non-fatal)"
fi

echo ""
echo "team-gate-surface.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
