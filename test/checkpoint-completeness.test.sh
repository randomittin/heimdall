#!/usr/bin/env bash
# checkpoint-completeness.test.sh — acceptance for the CHECKPOINT COMPLETENESS GATE
# (spec PART 1.3) and the NEVER-LOSE ENUMERATION it gates (spec PART 1.4).
#
# THE BUG CLASS THIS EXISTS TO MAKE IMPOSSIBLE — and it is real, and it was recent
# ------------------------------------------------------------------------------
# `printf '- **Branch:** %s\n' "$branch"` parses the leading `-` as a FLAG under
# bash 3.2 (macOS /bin/bash). printf consumed it, printed nothing, and returned 0.
# So every checkpoint written on this machine silently lost Branch, HEAD, Phase,
# Active goal and the dirty count — for as long as the file existed. Nothing broke.
# Nothing warned. The checkpoint kept announcing "auto-saved". The knowledge was
# gone and the save reported success.
#
# test/checkpoint-depth.test.sh section 0 guards those five specific lines. That is
# a REGRESSION guard for the five fields that happened to be caught. THIS file
# guards the CLASS: the writer must verify, from the bytes it actually wrote, that
# every field the resume contract requires survived the write — and a save that
# dropped one must FAIL ITSELF, LOUDLY, rather than announce success.
#
# WHAT IS BEING GATED (spec 1.4 — "what must never be lost")
#   in-progress work + rationale · gated decisions · held branches + why ·
#   unpushed state · open ⚠ items · the session's refuted-claims list
# Six categories. Corrections (refuted claims) are in the list because they are the
# most expensive knowledge to re-derive: nothing in git records what a session
# learned was FALSE.
#
# WHAT THIS FILE PROVES
#   A. THE SIX FIELDS EXIST     — each is a dedicated, single-line, non-empty field.
#   B. NEGATIVES ARE MEASURED   — "nothing unpushed" is written as a measured
#      negative with its evidence, never as an empty field. Empty != none.
#   C. THE ANSWER KEY IS WRITTEN AT SAVE TIME — .planning/RESUME-KEY.json, one
#      digest per category, written while the knowledge is still present.
#   D. THE KEY IS A GRADER, NOT A CRIB SHEET — it carries digests only. A probe
#      that could read the answers out of the key would grade itself, which is the
#      tautological gate this repo exists to prevent. THIS IS THE LOAD-BEARING ONE.
#   E. A DROPPED FIELD FAILS ITS OWN SAVE, LOUDLY — positive control via the
#      documented fault seam HMD_CKPT_FAULT. A gate that cannot be shown to fire
#      makes every green result meaningless.
#   F. AN INCOMPLETE SAVE PUBLISHES NO KEY — and revokes any previous one, so the
#      probe can never grade a damaged checkpoint against a stale key (fail closed).
#   G. THE RECORDING SEAM WORKS — `heimdall-checkpoint note` is how session-only
#      knowledge (next step, gated decision, refuted claim, ⚠ item) reaches the
#      checkpoint at all. Without it three of the six categories could only ever
#      say "none", and the probe would be grading emptiness.
#   H. STILL NON-DESTRUCTIVE + IDEMPOTENT — the pre-existing contract holds.
#   I. HERMETIC — the real ~/.heimdall is never written.
#
# Usage:  bash test/checkpoint-completeness.test.sh   (exit 0 = every proof holds)

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CKPT="$REPO/bin/heimdall-checkpoint"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
sec() { printf '\n%s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REAL_HOME_HMD="$HOME/.heimdall"
SENTINEL_TAG="completeness-probe-$$"

# The six categories of the resume contract, as {id}={CHECKPOINT.md label}.
FIELD_IDS="in_progress gated_decisions held_branches unpushed open_warnings refuted_claims"
label_of() {
  case "$1" in
    in_progress)     printf 'In progress' ;;
    gated_decisions) printf 'Gated decisions' ;;
    held_branches)   printf 'Held branches' ;;
    unpushed)        printf 'Unpushed' ;;
    open_warnings)   printf 'Open warnings' ;;
    refuted_claims)  printf 'Refuted claims' ;;
  esac
}

# A fresh throwaway git project (mirrors checkpoint-depth.test.sh's make_project).
make_project() {
  local d
  d="$(mktemp -d "$TMP/proj.XXXXXX")"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  printf 'hello\n' > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -qm "initial commit" --no-verify
  mkdir -p "$d/.planning"
  printf '%s' "$d"
}

# Extract the value of one "- **Label:** value" line. Empty when absent.
field_value() { # <checkpoint-file> <label>
  sed -n "s/^- \*\*$2:\*\* \(.*\)\$/\1/p" "$1" 2>/dev/null | head -1
}
field_count() { # <checkpoint-file> <label>
  local n
  n="$(grep -c "^- \*\*$2:\*\* " "$1" 2>/dev/null)"; printf '%s' "${n:-0}"
}

# ── 0. the writer exists ─────────────────────────────────────────────────────────
sec "0. THE WRITER EXISTS:"
if [ -x "$CKPT" ]; then ok "bin/heimdall-checkpoint is executable"
else bad "bin/heimdall-checkpoint missing"; printf '\ncheckpoint-completeness.test.sh: %s passed, %s failed.\n' "$PASS" "$((FAIL+1))"; exit 1; fi

# ── A. the six never-lose fields are present, single-line, non-empty ─────────────
sec "A. THE SIX NEVER-LOSE FIELDS (spec 1.4) are dedicated, single-line, non-empty:"
P="$(make_project)"
HEIMDALL_HOME="$P/.heimdall" "$CKPT" write "$P" >/dev/null 2>&1
RC_A=$?
CK="$P/.planning/CHECKPOINT.md"
[ "$RC_A" -eq 0 ] && ok "a complete save exits 0" || bad "a complete save exited $RC_A"
for ID in $FIELD_IDS; do
  L="$(label_of "$ID")"
  N="$(field_count "$CK" "$L")"
  V="$(field_value "$CK" "$L")"
  if [ "$N" = "1" ] && [ -n "$V" ]; then
    ok "$ID -> \"- **$L:**\" present exactly once and non-empty"
  else
    bad "$ID -> \"- **$L:**\" count=$N value=\"$V\" (want exactly 1, non-empty)"
  fi
done

# ── B. a measured negative, never an empty field ─────────────────────────────────
sec "B. NEGATIVES ARE MEASURED, NOT EMPTY (empty is a dropped field; none is an answer):"
UNP="$(field_value "$CK" "Unpushed")"
printf '%s' "$UNP" | grep -qiE 'none|0 ' && ok "fresh repo with nothing unpushed states it: \"$UNP\"" \
                                         || bad "unpushed field is not a measured negative: \"$UNP\""
printf '%s' "$UNP" | grep -qE '[0-9]' && ok "the unpushed answer carries a number (evidence, not an adjective)" \
                                      || bad "no count in the unpushed answer: \"$UNP\""
rm -rf "$P"

# ── C. the answer key is written AT SAVE TIME ────────────────────────────────────
sec "C. THE ANSWER KEY IS WRITTEN AT SAVE TIME (while the knowledge is still present):"
P="$(make_project)"
HEIMDALL_HOME="$P/.heimdall" "$CKPT" write "$P" >/dev/null 2>&1
KEY="$P/.planning/RESUME-KEY.json"
[ -f "$KEY" ] && ok ".planning/RESUME-KEY.json written by the save" || bad "no answer key written"
if command -v jq >/dev/null 2>&1 && [ -f "$KEY" ]; then
  jq -e . "$KEY" >/dev/null 2>&1 && ok "the key is valid JSON" || bad "the key is not valid JSON"
  NIDS="$(jq -r '[.answers[].id] | sort | join(" ")' "$KEY" 2>/dev/null)"
  WANT="$(printf '%s\n' $FIELD_IDS | sort | tr '\n' ' ' | sed 's/ $//')"
  [ "$NIDS" = "$WANT" ] && ok "the key carries a digest for all six categories" \
                        || bad "key ids = \"$NIDS\" (want \"$WANT\")"
  BADDIG="$(jq -r '[.answers[] | select((.digest // "") | test("^[0-9a-f]{64}$") | not)] | length' "$KEY" 2>/dev/null)"
  [ "$BADDIG" = "0" ] && ok "every key entry carries a sha256 digest" || bad "$BADDIG key entries lack a sha256 digest"
  BADLAYER="$(jq -r '[.answers[] | select((.layer // "") == "")] | length' "$KEY" 2>/dev/null)"
  [ "$BADLAYER" = "0" ] && ok "every key entry names the LAYER that sourced it (so a miss can be filed)" \
                        || bad "$BADLAYER key entries name no layer"
else
  bad "jq missing or key absent — cannot verify the key's shape"
fi

# ── D. THE LOAD-BEARING ONE: the key grades, it does not answer ──────────────────
sec "D. THE KEY IS A GRADER, NOT A CRIB SHEET (a probe that reads its own answers is worthless):"
HEIMDALL_HOME="$P/.heimdall" "$CKPT" note refuted "the $SENTINEL_TAG claim was refuted by measurement" >/dev/null 2>&1
HEIMDALL_HOME="$P/.heimdall" "$CKPT" write "$P" >/dev/null 2>&1
CK="$P/.planning/CHECKPOINT.md"
grep -qF "$SENTINEL_TAG" "$CK" 2>/dev/null \
  && ok "the sentinel answer reached CHECKPOINT.md (the stack a resume actually reads)" \
  || bad "the sentinel answer never reached CHECKPOINT.md — nothing to grade"
if grep -qF "$SENTINEL_TAG" "$KEY" 2>/dev/null; then
  bad "the ANSWER TEXT is inside RESUME-KEY.json — the key is a crib sheet, so the probe would grade itself"
else
  ok "the answer text is NOT in the key — the key can only GRADE, never SUPPLY, an answer"
fi
KEYWORDS="$(tr -c 'A-Za-z0-9' ' ' < "$KEY" 2>/dev/null | tr ' ' '\n' | grep -c '^[0-9a-f]\{64\}$')"
[ "${KEYWORDS:-0}" -ge 6 ] && ok "the key body is digests (${KEYWORDS} sha256 tokens), not prose" \
                           || bad "the key body does not look like digests (${KEYWORDS:-0} sha256 tokens)"
rm -rf "$P"

# ── E. POSITIVE CONTROL: a dropped field fails its own save, loudly ─────────────
sec "E. A DROPPED FIELD FAILS ITS OWN SAVE, LOUDLY (the printf-bug class, made impossible):"
for ID in $FIELD_IDS; do
  P="$(make_project)"
  ERRF="$TMP/err.$ID.txt"
  HEIMDALL_HOME="$P/.heimdall" HMD_CKPT_FAULT="$ID" "$CKPT" write "$P" >/dev/null 2>"$ERRF"
  RC=$?
  ERR="$(cat "$ERRF" 2>/dev/null)"
  L="$(label_of "$ID")"
  if [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -qF "$L"; then
    ok "$ID dropped -> save FAILS (exit $RC) and stderr names the field"
  else
    bad "$ID dropped -> exit $RC, stderr did not name \"$L\": $ERR"
  fi
  rm -rf "$P"
done
# and the failure is LOUD: it must not be a quiet exit code with no words
P="$(make_project)"
HEIMDALL_HOME="$P/.heimdall" HMD_CKPT_FAULT="in_progress" "$CKPT" write "$P" >/dev/null 2>"$TMP/loud.txt"
LOUD="$(cat "$TMP/loud.txt" 2>/dev/null)"
printf '%s' "$LOUD" | grep -qiE 'incomplete|failed|not saved' \
  && ok "the failure says, in words, that the checkpoint is incomplete" \
  || bad "the failure is silent-ish — no incomplete/failed wording: $LOUD"
printf '%s' "$LOUD" | grep -qi 'checkpoint' \
  && ok "the failure names the subsystem (a resuming operator can act on it)" \
  || bad "the failure does not name the subsystem"

# ── F. an incomplete save publishes NO key, and revokes a stale one ─────────────
sec "F. AN INCOMPLETE SAVE PUBLISHES NO KEY (never grade damaged state against a stale key):"
KEY="$P/.planning/RESUME-KEY.json"
[ -f "$KEY" ] && bad "an incomplete save still published an answer key" \
              || ok "no answer key after a failed save"
CK="$P/.planning/CHECKPOINT.md"
if [ -f "$CK" ]; then
  grep -qi 'INCOMPLETE' "$CK" \
    && ok "the written checkpoint is STAMPED INCOMPLETE (a resume cannot mistake it for whole)" \
    || bad "the checkpoint carries no INCOMPLETE stamp — a resume would trust it"
else
  ok "the incomplete save left no checkpoint at all"
fi
rm -rf "$P"

# a PREVIOUS valid key must be revoked when a later save comes up incomplete
P="$(make_project)"
HEIMDALL_HOME="$P/.heimdall" "$CKPT" write "$P" >/dev/null 2>&1
KEY="$P/.planning/RESUME-KEY.json"
[ -f "$KEY" ] && ok "setup: a complete save published a key" || bad "setup: no key from the complete save"
HEIMDALL_HOME="$P/.heimdall" HMD_CKPT_FAULT="unpushed" "$CKPT" write "$P" >/dev/null 2>&1
[ -f "$KEY" ] && bad "the STALE key survived an incomplete save — the probe would grade damaged state as green" \
              || ok "the stale key was REVOKED by the incomplete save (fail closed)"
rm -rf "$P"

# ── G. the recording seam — session-only knowledge can reach the checkpoint ──────
sec 'G. THE RECORDING SEAM (`note`) — without it, three categories could only say "none":'
P="$(make_project)"
export HEIMDALL_HOME="$P/.heimdall"
"$CKPT" note in-progress "wiring the resume probe; next step is the SessionStart hook" >/dev/null 2>&1
RC_N=$?
"$CKPT" note gated       "awaiting a human call on whether the probe blocks or advises" >/dev/null 2>&1
"$CKPT" note refuted     "claimed the meter reads its own estimate; it reads the statusline blob" >/dev/null 2>&1
"$CKPT" note warn        "fail-open observation from 2026-08-05 is still open" >/dev/null 2>&1
[ "$RC_N" -eq 0 ] && ok "note exits 0" || bad "note exited $RC_N"
"$CKPT" write "$P" >/dev/null 2>&1
CK="$P/.planning/CHECKPOINT.md"
grep -qF "next step is the SessionStart hook" "$CK" 2>/dev/null && ok "an in-progress note reaches the In progress field" || bad "in-progress note lost"
grep -qF "awaiting a human call"              "$CK" 2>/dev/null && ok "a gated note reaches the Gated decisions field"  || bad "gated note lost"
grep -qF "it reads the statusline blob"       "$CK" 2>/dev/null && ok "a refuted note reaches the Refuted claims field" || bad "refuted note lost"
grep -qF "fail-open observation from 2026-08-05" "$CK" 2>/dev/null && ok "a warn note reaches the Open warnings field"  || bad "warn note lost"
# the notes land in the right fields, not smeared across all of them
RCLAIMS="$(field_value "$CK" "Refuted claims")"
printf '%s' "$RCLAIMS" | grep -qF "it reads the statusline blob" \
  && ok "the refuted claim is IN the Refuted claims field (categories are not smeared)" \
  || bad "Refuted claims field does not carry the refuted note: \"$RCLAIMS\""
printf '%s' "$RCLAIMS" | grep -qF "awaiting a human call" \
  && bad "the gated note leaked into Refuted claims — categories are smeared" \
  || ok "the gated note did NOT leak into Refuted claims"
# a bad category is a real error, never a silent no-op that loses the knowledge
RC_N=0; "$CKPT" note no-such-category "should not vanish" >/dev/null 2>&1 || RC_N=$?
[ "$RC_N" -ne 0 ] && ok "an unknown note category is a real error (exit $RC_N), not a silent swallow" \
                  || bad "an unknown category silently succeeded — the knowledge would vanish"
unset HEIMDALL_HOME
rm -rf "$P"

# ── H. the pre-existing contract still holds ─────────────────────────────────────
sec "H. STILL IDEMPOTENT AND NON-DESTRUCTIVE (the old contract is not traded away):"
P="$(make_project)"
CK="$P/.planning/CHECKPOINT.md"
SENT="MANUAL-LLM-HANDOFF-do-not-clobber-77"
printf '# Checkpoint — manual\n\n%s\n' "$SENT" > "$CK"
HEIMDALL_HOME="$P/.heimdall" "$CKPT" write "$P" >/dev/null 2>&1
grep -qF "$SENT" "$CK" 2>/dev/null && ok "a manual handoff is still preserved" || bad "manual content CLOBBERED"
HEIMDALL_HOME="$P/.heimdall" "$CKPT" write "$P" >/dev/null 2>&1
N="$(grep -cF "heimdall-auto-checkpoint:begin" "$CK" 2>/dev/null; true)"; N="${N:-0}"
[ "$N" -eq 1 ] && ok "exactly one auto block after repeated writes" || bad "auto block count=$N (want 1)"
NF="$(field_count "$CK" "Unpushed")"
[ "$NF" = "1" ] && ok "the never-lose fields do not duplicate across runs" || bad "Unpushed field count=$NF after two runs"
rm -rf "$P"

# ── I. hermetic ──────────────────────────────────────────────────────────────────
sec "I. HERMETIC (the real ~/.heimdall is never written):"
if [ -d "$REAL_HOME_HMD" ] && grep -rlF "$SENTINEL_TAG" "$REAL_HOME_HMD" 2>/dev/null | grep -q .; then
  bad "leaked the test sentinel into the real $REAL_HOME_HMD"
else
  ok "no test state leaked into the real ~/.heimdall"
fi

printf '\ncheckpoint-completeness.test.sh: %s passed, %s failed.\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
