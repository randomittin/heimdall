#!/usr/bin/env bash
#
# rules-propose.test.sh — acceptance for `heimdall-rules propose` (V7).
#
# WHY. The corpus accumulates SCORED FAILURE DATA; SCHEMA.md §4 says "3+ cases
# sharing a root pattern graduate into a convention / stack-pack rule. Cases
# catch; rules prevent." V7 automates the FIRST half of that sentence only: it
# CLUSTERS the denies and DRAFTS a candidate with its evidence trail. Promotion
# stays human. Heimdall's public claims say triage is captured/shared — never
# that it "auto-synthesizes rules" — so the tool's output must be unmistakably a
# PROPOSAL AWAITING REVIEW, and the tool must never write outside its staging
# path.
#
# THE FAILURE MODE THIS FILE EXISTS TO KILL. A proposal engine that ALWAYS
# proposes something is noise, and noise trains RJ to ignore the gate. So the
# falsifiability guarantees are tested as a PAIR on the same fixture family:
# feed it the corpus where the answer is KNOWN and assert it finds that
# candidate (G3); then REMOVE the motivating cases and assert it proposes
# NOTHING (G4). The negative alone would also "pass" if the engine were dead
# code, so the positive is what proves the negative means something.
#
# Guarantees proved:
#   G1  tool exists, is executable, -h exits 0.
#   G2  REAL corpus -> >=1 candidate whose evidence trail names real case ids.
#   G3  KNOWN-ANSWER POSITIVE — a fixture holding the three D3/I4 ordering
#       denies proposes exactly that candidate, citing all three by id.
#   G4  KNOWN-ANSWER NEGATIVE (falsifiability) — the SAME fixture with the
#       motivating cases removed proposes NOTHING, honestly.
#   G5  EMPTY corpus -> honest "no candidate rules this period", exit 0, no crash.
#   G6  SUB-THRESHOLD — a 2-member cluster does NOT graduate (min support 3).
#   G7  PRIVACY: single identifiable team, NO recorded consent -> the team name
#       never appears in the output; the suppression is stated.
#   G8  PRIVACY: single identifiable team WITH recorded consent -> credited.
#   G9  PRIVACY: k-anonymity — a sub-k (n<5 teams) aggregate publishes no team
#       detail and no raw team_id_hash.
#   G10 NEVER PROMOTES — a real run leaves evals/ byte-identical in git.
#   G11 FRAMING — output carries PROPOSAL/NOT PROMOTED/human review, and never
#       claims to auto-synthesize or auto-promote.
#   G12 --json emits valid JSON pinning promoted:false.
#
# Usage:  test/rules-propose.test.sh   (exit 0 = every guarantee holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
RULES="$REPO/bin/heimdall-rules"
CORPUS="$REPO/evals/corpus"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Build a fixture corpus from REAL case dirs (the falsifiability proof must
# run on real data, not invented data). Args: <dir> <case-id>... ─────────────
mkfixture() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local id
  for id in "$@"; do
    mkdir -p "$dir/$id"
    cp "$CORPUS/$id/case.json" "$dir/$id/case.json"
    cp "$CORPUS/$id/expected.json" "$dir/$id/expected.json"
  done
  if [ "$#" -eq 0 ]; then
    printf '{"version":"fixture","cases":[]}\n' > "$dir/INDEX.json"
  else
    printf '%s\n' "$@" \
      | jq -R . \
      | jq -s '{version:"fixture", cases:[.[] | {id:., source:"mutation"}]}' \
      > "$dir/INDEX.json"
  fi
}

# Stamp an attribution block onto a fixture case (privacy fixtures only).
# Args: <fixture-dir> <case-id> <team_name> <team_id_hash> <consent-granted:true|false> [version]
attribute() {
  local dir="$1" id="$2" name="$3" hash="$4" granted="$5" ver="${6:-}"
  jq --arg n "$name" --arg h "$hash" --argjson g "$granted" --arg v "$ver" \
    '.attribution = {team_name:$n, team_id_hash:$h,
                     consent:{granted:$g, version:$v}}' \
    "$dir/$id/case.json" > "$dir/$id/case.json.tmp"
  mv "$dir/$id/case.json.tmp" "$dir/$id/case.json"
}

# The three denies that share the D3 (FIFO tiebreak) + I4 (price-time priority)
# root pattern — the KNOWN ANSWER this corpus contains.
ORDERING=(exchange-queue-jump exchange-lifo-tiebreak exchange-c2-racy)
# Denies that share NO 3-way root pattern (each a distinct invariant).
UNRELATED=(exchange-crossed-trade exchange-dropped-remainder exchange-off-by-one-qty)

echo "rules-propose harness  repo=$REPO"
echo "--------------------------------------------------------------------"

# ── G1: the tool exists and is runnable ───────────────────────────────────────
if [ -x "$RULES" ]; then ok "G1 bin/heimdall-rules is executable"
else bad "G1 bin/heimdall-rules missing or not executable"; fi
"$RULES" -h >/dev/null 2>&1 && ok "G1 -h exits 0" || bad "G1 -h did not exit 0"

# ── G2: the REAL corpus yields at least one candidate with an evidence trail ──
REAL_JSON="$TMP/real.json"
"$RULES" propose --out "$TMP/real.md" --json > "$REAL_JSON" 2>"$TMP/real.err"
rc=$?
[ "$rc" -eq 0 ] && ok "G2 real-corpus run exits 0 (rc=$rc)" \
  || bad "G2 real-corpus run exited $rc; stderr: $(cat "$TMP/real.err")"

if jq -e . "$REAL_JSON" >/dev/null 2>&1; then
  n="$(jq -r '.candidate_count' "$REAL_JSON")"
  [ "${n:-0}" -ge 1 ] \
    && ok "G2 real corpus produced $n candidate(s)" \
    || bad "G2 real corpus produced no candidate — a template that finds nothing on real data is not a pass"

  # The evidence trail must cite case ids that actually exist on disk.
  bogus=0
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    [ -f "$CORPUS/$cid/case.json" ] || { bogus=$((bogus+1)); echo "      fabricated case id: $cid"; }
  done <<< "$(jq -r '.candidates[].evidence[].case_id' "$REAL_JSON" 2>/dev/null)"
  [ "$bogus" -eq 0 ] \
    && ok "G2 every cited case id resolves to a real corpus case" \
    || bad "G2 $bogus cited case id(s) do not exist — fabricated evidence"
else
  bad "G2 real-corpus --json did not emit valid JSON"
fi

# ── G3: KNOWN-ANSWER POSITIVE ─────────────────────────────────────────────────
FX_POS="$TMP/fx-positive"
mkfixture "$FX_POS" "${ORDERING[@]}" "${UNRELATED[@]}"
POS_JSON="$TMP/pos.json"
"$RULES" propose --corpus "$FX_POS" --out "$TMP/pos.md" --json > "$POS_JSON" 2>/dev/null
pos_n="$(jq -r '.candidate_count // 0' "$POS_JSON" 2>/dev/null)"
[ "${pos_n:-0}" -eq 1 ] \
  && ok "G3 known-answer corpus proposes exactly 1 candidate" \
  || bad "G3 known-answer corpus proposed ${pos_n:-?} candidates, expected 1"

cited="$(jq -r '.candidates[0].evidence[].case_id' "$POS_JSON" 2>/dev/null | sort | tr '\n' ' ')"
missing=0
for id in "${ORDERING[@]}"; do
  case " $cited " in *" $id "*) ;; *) missing=$((missing+1)); echo "      not cited: $id" ;; esac
done
[ "$missing" -eq 0 ] \
  && ok "G3 candidate cites all three motivating denies ($cited)" \
  || bad "G3 candidate omitted $missing motivating deny/denies"

# The unrelated denies must NOT be swept into the cluster.
overreach=0
for id in "${UNRELATED[@]}"; do
  case " $cited " in *" $id "*) overreach=$((overreach+1)); echo "      over-cited: $id" ;; esac
done
[ "$overreach" -eq 0 ] \
  && ok "G3 unrelated denies are not swept into the cluster" \
  || bad "G3 $overreach unrelated deny/denies pulled into the evidence trail"

# ── G4: KNOWN-ANSWER NEGATIVE — remove the motivating cases ───────────────────
FX_NEG="$TMP/fx-negative"
mkfixture "$FX_NEG" "${UNRELATED[@]}"
NEG_JSON="$TMP/neg.json"
"$RULES" propose --corpus "$FX_NEG" --out "$TMP/neg.md" --json > "$NEG_JSON" 2>/dev/null
rc=$?
neg_n="$(jq -r '.candidate_count // -1' "$NEG_JSON" 2>/dev/null)"
[ "${neg_n:-1}" -eq 0 ] \
  && ok "G4 removing the motivating cases proposes NOTHING (candidate_count=0)" \
  || bad "G4 proposed ${neg_n:-?} candidate(s) after the motivating cases were removed — fabrication"
[ "$rc" -eq 0 ] \
  && ok "G4 an honest empty result still exits 0" \
  || bad "G4 empty result exited $rc (an honest 'nothing' is not an error)"
grep -qi 'no candidate rules this period' "$TMP/neg.md" \
  && ok "G4 staged report says 'no candidate rules this period'" \
  || bad "G4 staged report lacks the honest no-candidate line"

# G4 ANTI-FALSE-GREEN. "0 candidates" is only meaningful if the tool actually
# READ the remaining denies. A fixture the reader silently choked on would also
# report 0, for entirely the wrong reason — and would make G4 a green that
# proves nothing. Pin that the denies were ingested and that the zero came from
# the support threshold, not from an empty read.
neg_denies="$(jq -r '.generated_from.denies // 0' "$NEG_JSON" 2>/dev/null)"
neg_skipped="$(jq -r '.generated_from.cases_skipped // -1' "$NEG_JSON" 2>/dev/null)"
[ "${neg_denies:-0}" -eq "${#UNRELATED[@]}" ] \
  && ok "G4 the negative fixture was really read ($neg_denies denies ingested, not an empty read)" \
  || bad "G4 negative fixture ingested ${neg_denies:-?} denies, expected ${#UNRELATED[@]} — the zero is a false green"
[ "${neg_skipped:-1}" -eq 0 ] \
  && ok "G4 no case was silently skipped in the negative fixture" \
  || bad "G4 ${neg_skipped:-?} case(s) skipped — the zero may be an ingestion failure"

# ── G5: EMPTY corpus ──────────────────────────────────────────────────────────
FX_EMPTY="$TMP/fx-empty"
mkfixture "$FX_EMPTY"
"$RULES" propose --corpus "$FX_EMPTY" --out "$TMP/empty.md" --json > "$TMP/empty.json" 2>/dev/null
rc=$?
[ "$rc" -eq 0 ] && ok "G5 empty corpus exits 0" || bad "G5 empty corpus exited $rc"
[ "$(jq -r '.candidate_count // -1' "$TMP/empty.json" 2>/dev/null)" = "0" ] \
  && ok "G5 empty corpus proposes nothing" \
  || bad "G5 empty corpus fabricated a candidate"
grep -qi 'no candidate rules this period' "$TMP/empty.md" \
  && ok "G5 empty corpus states the honest no-candidate line" \
  || bad "G5 empty corpus lacks the honest no-candidate line"

# ── G6: SUB-THRESHOLD — 2 members must not graduate ───────────────────────────
FX_SUB="$TMP/fx-sub"
mkfixture "$FX_SUB" exchange-queue-jump exchange-lifo-tiebreak
"$RULES" propose --corpus "$FX_SUB" --out "$TMP/sub.md" --json > "$TMP/sub.json" 2>/dev/null
[ "$(jq -r '.candidate_count // -1' "$TMP/sub.json" 2>/dev/null)" = "0" ] \
  && ok "G6 a 2-member cluster does NOT graduate (min support 3)" \
  || bad "G6 a 2-member cluster graduated — the engine proposes on thin evidence"
# ...and the near-miss is reported, so a human can see what almost qualified.
jq -e '.rejected_clusters | length >= 1' "$TMP/sub.json" >/dev/null 2>&1 \
  && ok "G6 the sub-threshold cluster is reported as rejected (not silently dropped)" \
  || bad "G6 sub-threshold cluster vanished silently"

# ── G7: PRIVACY — identifiable team, NO recorded consent ──────────────────────
SECRET_TEAM='Northwind Payments Team'
FX_NOCONSENT="$TMP/fx-noconsent"
mkfixture "$FX_NOCONSENT" "${ORDERING[@]}"
attribute "$FX_NOCONSENT" exchange-queue-jump    "$SECRET_TEAM" 'sha256:aaa1' false ''
attribute "$FX_NOCONSENT" exchange-lifo-tiebreak "$SECRET_TEAM" 'sha256:aaa1' false ''
attribute "$FX_NOCONSENT" exchange-c2-racy       "$SECRET_TEAM" 'sha256:aaa1' false ''
"$RULES" propose --corpus "$FX_NOCONSENT" --out "$TMP/nc.md" --json > "$TMP/nc.json" 2>/dev/null
if grep -qF "$SECRET_TEAM" "$TMP/nc.md" "$TMP/nc.json" 2>/dev/null; then
  bad "G7 an unconsented team name LEAKED into the proposal"
else
  ok "G7 unconsented team name never appears in the proposal (anonymised/dropped)"
fi
if grep -qF 'sha256:aaa1' "$TMP/nc.md" "$TMP/nc.json" 2>/dev/null; then
  bad "G7 the raw team_id_hash leaked into the proposal"
else
  ok "G7 no raw team_id_hash in the proposal"
fi
grep -qiE 'withheld|suppress|anonymis|anonymiz|no recorded consent' "$TMP/nc.md" \
  && ok "G7 the suppression is stated, not silent" \
  || bad "G7 attribution was dropped silently — a reviewer cannot see it happened"

# ── G8: PRIVACY — identifiable team WITH recorded consent ─────────────────────
CONSENT_TEAM='Aurora Trading Guild'
FX_CONSENT="$TMP/fx-consent"
mkfixture "$FX_CONSENT" "${ORDERING[@]}"
attribute "$FX_CONSENT" exchange-queue-jump    "$CONSENT_TEAM" 'sha256:bbb2' true 't0-2026-07'
attribute "$FX_CONSENT" exchange-lifo-tiebreak "$CONSENT_TEAM" 'sha256:bbb2' true 't0-2026-07'
attribute "$FX_CONSENT" exchange-c2-racy       "$CONSENT_TEAM" 'sha256:bbb2' true 't0-2026-07'
"$RULES" propose --corpus "$FX_CONSENT" --out "$TMP/cs.md" --json > "$TMP/cs.json" 2>/dev/null
grep -qF "$CONSENT_TEAM" "$TMP/cs.md" \
  && ok "G8 a CONSENTED team is credited by name" \
  || bad "G8 consented attribution was dropped — consent must be honoured too"
grep -qF 't0-2026-07' "$TMP/cs.md" \
  && ok "G8 the credit records the consent version" \
  || bad "G8 credit shipped without the consent version it rests on"

# ── G9: PRIVACY — k-anonymity on a sub-k multi-team aggregate ─────────────────
FX_SUBK="$TMP/fx-subk"
mkfixture "$FX_SUBK" "${ORDERING[@]}"
attribute "$FX_SUBK" exchange-queue-jump    'Team Alpha' 'sha256:c1' false ''
attribute "$FX_SUBK" exchange-lifo-tiebreak 'Team Beta'  'sha256:c2' false ''
attribute "$FX_SUBK" exchange-c2-racy       'Team Gamma' 'sha256:c3' false ''
"$RULES" propose --corpus "$FX_SUBK" --out "$TMP/subk.md" --json > "$TMP/subk.json" 2>/dev/null
leaked=0
for t in 'Team Alpha' 'Team Beta' 'Team Gamma'; do
  grep -qF "$t" "$TMP/subk.md" "$TMP/subk.json" 2>/dev/null && { leaked=$((leaked+1)); echo "      leaked: $t"; }
done
[ "$leaked" -eq 0 ] \
  && ok "G9 sub-k (3 teams < k=5) publishes no team name" \
  || bad "G9 $leaked team name(s) published below the k-anonymity threshold"
grep -qiE 'k-anonymit|sub-k|k *>?= *5|below the k' "$TMP/subk.md" \
  && ok "G9 the k-anonymity decision is stated in the report" \
  || bad "G9 the k-anonymity check is invisible to the reviewer"

# ── G10: NEVER PROMOTES ───────────────────────────────────────────────────────
dirty="$(git -C "$REPO" status --porcelain -- evals/ 2>/dev/null)"
[ -z "$dirty" ] \
  && ok "G10 a real run left evals/ untouched (proposes, never promotes)" \
  || bad "G10 the tool modified evals/: $dirty"

# ── G11: FRAMING ──────────────────────────────────────────────────────────────
grep -qi 'PROPOSAL' "$TMP/real.md" \
  && ok "G11 report is labelled a PROPOSAL" || bad "G11 report is not labelled a proposal"
grep -qiE 'NOT PROMOTED|awaiting review|human review' "$TMP/real.md" \
  && ok "G11 report states it awaits human review" \
  || bad "G11 report does not say promotion is human"
# The overclaim this project polices: never assert the tool synthesizes/promotes rules.
if grep -qiE 'auto-?(synthesi[sz]|promot|appl)|automatically (synthesi|promot)' "$TMP/real.md"; then
  bad "G11 report contains an auto-synthesis/auto-promotion overclaim"
else
  ok "G11 no auto-synthesis / auto-promotion overclaim"
fi

# ── G12: --json shape ─────────────────────────────────────────────────────────
[ "$(jq -r '.promoted' "$REAL_JSON" 2>/dev/null)" = "false" ] \
  && ok "G12 --json pins promoted:false" \
  || bad "G12 --json does not pin promoted:false"

# ── G13: `hmd rules propose` routes to the tool ───────────────────────────────
# The documented entry point is the router, not the bare bin. If the arm is ever
# dropped, every doc line that says `hmd rules propose` becomes a lie.
ROUTED_JSON="$TMP/routed.json"
if "$REPO/bin/hmd" rules propose --corpus "$FX_POS" --out "$TMP/routed.md" --json \
     > "$ROUTED_JSON" 2>"$TMP/routed.err"; then
  ok "G13 \`hmd rules propose\` routes and exits 0"
else
  bad "G13 \`hmd rules propose\` failed: $(cat "$TMP/routed.err")"
fi
[ "$(jq -r '.tool' "$ROUTED_JSON" 2>/dev/null)" = "heimdall-rules" ] \
  && ok "G13 the router reaches heimdall-rules (tool=heimdall-rules)" \
  || bad "G13 the router did not reach heimdall-rules"
# Routed and direct invocations must agree — a router that silently drops flags
# would otherwise surface as a mysteriously different proposal.
if [ "$(jq -Sc '.candidates' "$ROUTED_JSON" 2>/dev/null)" \
   = "$(jq -Sc '.candidates' "$POS_JSON" 2>/dev/null)" ]; then
  ok "G13 routed invocation forwards flags verbatim (same candidates as direct)"
else
  bad "G13 routed and direct invocations disagree — flags are not forwarded verbatim"
fi

echo "--------------------------------------------------------------------"
printf 'rules-propose: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
