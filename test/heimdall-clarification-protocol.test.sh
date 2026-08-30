#!/usr/bin/env bash
# test/heimdall-clarification-protocol.test.sh — falsifies §2d Clarification Protocol
# in agents/heimdall.md.
#
# WHY THIS EXISTS. Owner directive: batch every open question into ONE round; if
# still unclear after that round, offer concrete OPTIONS instead of a second round
# of open questions; once the goal is clear, execute relentlessly with no further
# questioning. Two failure modes named it explicitly — OVER-QUESTIONING (asking when
# the answer was already determinable) and OVER-ASSUMING (proceeding on a guess when
# the cost of being wrong was high) — the latter measured three times in one real
# session: work reported "queued" with no queue entry behind it, a tool reported
# "landed" when it was unreachable dead code, a sweep reported "running" when it had
# exited three hours earlier (see bin/heimdall-delivery-audit's own header, which
# exists BECAUSE of those three instances).
#
# Before adding this section, agents/heimdall.md already carried three scattered,
# underspecified clarification references (§2b's skill-mapping table row for
# `superpowers:brainstorming`, §6f's "Blocking ... escalate to user", §8 Level 3's
# "ambiguous requirements needing clarification") — none said HOW. This suite proves
# the new §2d section exists, states all three states and both failure modes with
# their concrete examples, and that the two behavioral cross-points (§6f, §8) now
# point back at it instead of standing alone with a rule a second author could
# contradict later.
#
# ENFORCEABILITY, MEASURED NOT ASSUMED: §2d itself states plainly that it is
# behavioral prose, not a gate. Two candidate mechanical checks were evaluated (not
# just claimed) before writing that sentence:
#   - bin/heimdall-conformance reads the real session transcript but classifies ONLY
#     tool-use events (a full-gate Bash call, a Write/Edit/NotebookEdit call) and
#     explicitly ignores message prose — "asked a clarifying question" has no tool
#     call, so it is invisible to that classifier by design.
#   - bin/heimdall-delivery-audit does NOT read the transcript at all (grep for
#     "transcript" in it returns nothing) — it audits queue/task stores and bin/
#     reachability, never conversation content. The brief that spawned this task
#     named heimdall-delivery-audit as the transcript reader; that premise was
#     checked here and found wrong, and §2d says so rather than repeating it.
#   - the narrative journal's `communication` entry type is the closest structured,
#     non-transcript trace, but it logs any non-trivial claim to the user, not
#     specifically a clarifying question, and logging it is optional.
# Section [5] below cross-checks those three claims against the real repo, so if any
# of those files' behavior drifts, this suite goes red instead of the doc quietly
# going stale.
#
# HERMETIC where it matters: sections [1]-[7] read the real agents/heimdall.md (the
# artifact under test — there is no synthetic stand-in for "did the real doc get
# edited correctly"). Section [8] is the one red-proof case, and it runs the
# detector against a throwaway temp file, never the real repo.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FILE="$ROOT/agents/heimdall.md"
CONF="$ROOT/bin/heimdall-conformance"
AUDIT="$ROOT/bin/heimdall-delivery-audit"
JOURNAL="$ROOT/skills/heimdall/references/journal.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  PASS: %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  FAIL: %s\n" "$1"; }

[ -f "$FILE" ] || { echo "FATAL: $FILE missing"; exit 2; }

# have PATTERN LABEL — fixed-string grep against the real doc under test.
have() {
  if grep -qF -- "$1" "$FILE"; then ok "$2"; else bad "$2 (pattern not found: $1)"; fi
}
# absent PATTERN LABEL — the pattern must NOT appear (contradiction guard).
absent() {
  if grep -qF -- "$1" "$FILE"; then bad "$2 (unexpectedly found: $1)"; else ok "$2"; fi
}

echo "[1] section exists, once, in the right neighborhood"
count="$(grep -cF -- '### 2d. Clarification Protocol' "$FILE")"
[ "$count" -eq 1 ] && ok "§2d heading present exactly once" || bad "§2d heading count=$count, want 1"
# It must live under "## 2. Prompt Analysis" (after 2c, before "## 3."), not floated
# elsewhere — otherwise it is a bolted-on second protocol rather than an integrated one.
between="$(awk '/^### 2c\. Auto-Install Required Plugins/{f=1} f && /^## 3\. Image Triage/{exit} f' "$FILE")"
printf '%s' "$between" | grep -qF '### 2d. Clarification Protocol' \
  && ok "§2d sits between §2c and §3 (integrated into prompt-analysis flow, not bolted on)" \
  || bad "§2d is not positioned between §2c and §3"

echo "[2] the three states, in order, all present"
have "UNCLEAR → one batched clarification round" "state 1: unclear -> batched round"
have "STILL UNCLEAR after that round → concrete OPTIONS, not more open questions" "state 2: still unclear -> options, not more questions"
have "CLEAR → execute relentlessly to completion" "state 3: clear -> execute relentlessly"

echo "[3] both failure modes, named, with their concrete examples"
have "OVER-QUESTIONING" "failure mode named: OVER-QUESTIONING"
have "OVER-ASSUMING" "failure mode named: OVER-ASSUMING"
have 'reporting work as "queued" with no queue entry behind it' "concrete example 1: queued with nothing behind it"
have 'reporting a tool as "landed" when it was unreachable dead code' "concrete example 2: landed on dead code"
have 'reporting a sweep as "running" when it had exited three hours earlier' "concrete example 3: running three hours after it finished"

echo "[4] calibration rule present"
have "ask when the cost of a wrong assumption is high AND the answer is not derivable by you" "calibration rule: ask-vs-measure threshold"
have "STATE the assumption you made so it can be corrected" "calibration rule: state assumptions instead of hiding them"

echo "[5] enforceability honesty — stated plainly, and its claims checked against the real repo"
have "this protocol is enforced by judgment and review, not by a gate" "doc states plainly: protocol, not a gate"
have "bin/heimdall-delivery-audit\` does not read the transcript at all" "doc correctly attributes transcript-reading to conformance, not delivery-audit"
[ -x "$CONF" ] || [ -f "$CONF" ] \
  && ok "bin/heimdall-conformance the doc cites actually exists" \
  || bad "bin/heimdall-conformance missing — doc cites a file that isn't there"
[ -f "$AUDIT" ] \
  && ok "bin/heimdall-delivery-audit the doc cites actually exists" \
  || bad "bin/heimdall-delivery-audit missing — doc cites a file that isn't there"
if [ -f "$CONF" ]; then
  grep -qF -- "gate-runs-once" "$CONF" && grep -qF -- "gates-at-end" "$CONF" \
    && ok "heimdall-conformance really does gate gate-runs-once + gates-at-end (doc's cited evidence is real)" \
    || bad "heimdall-conformance no longer mentions gate-runs-once/gates-at-end — doc claim is stale"
  if [ -r "$CONF" ]; then
    (grep -qF -- "transcript" "$AUDIT" 2>/dev/null) \
      && bad "heimdall-delivery-audit now mentions 'transcript' — the doc's negative claim is stale, update §2d" \
      || ok "heimdall-delivery-audit still has zero 'transcript' mentions (doc's negative claim still holds)"
  fi
fi
if [ -f "$JOURNAL" ]; then
  grep -qF -- "communication" "$JOURNAL" \
    && ok "journal.md still documents the 'communication' entry type the doc cites" \
    || bad "journal.md no longer documents 'communication' — doc claim is stale"
fi

echo "[6] the two pre-existing clarification references now point back at §2d instead of standing alone"
have "Escalate to user via §2d Clarification Protocol" "§6f Blocking bullet cross-references §2d"
have "Ambiguous requirements needing clarification — per §2d Clarification Protocol" "§8 Level-3 bullet cross-references §2d"

echo "[7] no leftover phrasing contradicts the batched-round rule"
absent "one question at a time" "no drip-fed-question phrasing survives elsewhere in the doc"
absent "ask questions one by one" "no one-by-one questioning phrasing survives elsewhere in the doc"

echo "[8] red-proof — the same style of check DOES fail on input missing the marker"
# Mirrors operational-model-pin.test.sh's PROVE-DETECTS guarantee: a green suite is
# worthless if the pattern stopped matching. Prove the checker can go red before
# trusting that it stayed green above. Runs against a throwaway temp file, never FILE.
TMP="$(mktemp "${TMPDIR:-/tmp}/hmd-clarify-proto-XXXXXX")"
trap 'rm -f "$TMP"' EXIT INT TERM
printf 'this fixture deliberately omits the failure-mode markers\n' > "$TMP"
if grep -qF -- "OVER-ASSUMING" "$TMP"; then
  bad "red-proof: detector reported a marker present in a fixture that omits it"
else
  ok "red-proof: detector correctly reports OVER-ASSUMING absent from a fixture that omits it"
fi
printf '%s\n' "OVER-ASSUMING" >> "$TMP"
if grep -qF -- "OVER-ASSUMING" "$TMP"; then
  ok "red-proof: same detector correctly flips to present once the marker is added back"
else
  bad "red-proof: detector failed to find a marker that was just written"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
