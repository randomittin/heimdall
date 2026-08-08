#!/usr/bin/env bash
# resume-probe.test.sh — acceptance for THE RESUME PROBE (spec PART 1.1): the
# falsifier for the whole memory stack.
#
# THE CLAIM THE PROBE EXISTS TO MAKE TRUE
# ---------------------------------------
# At the 150K meter, checkpoint + restart costs ~$0.02 and loses NOTHING. The stack
# that should make that true already exists — checkpoints, the observation store,
# the hmd/context worklog branch, git itself. What was missing is the PROOF, run
# every time. A restart nobody trusts is a restart nobody takes, and not restarting
# is what cost $913.54 in a single session.
#
# THE LOAD-BEARING DESIGN CONSTRAINT
# ----------------------------------
# The checkpoint writes the ANSWER KEY AT SAVE TIME — while the knowledge is still
# present. The probe re-derives the answers at RESUME time, from the persisted stack
# alone, and is graded against that key. A probe that derived both the question and
# the answer at resume would grade itself and prove nothing; that is the tautological
# gate this repo exists to prevent. The asymmetry is the whole mechanism:
#
#     key    = digest( the LIVE value, at save time )
#     answer = digest( what the STACK still yields, at resume time )
#
# So this file's central obligation is NEGATIVE: damage the stack in each of the ways
# it can actually decay, and prove the probe goes RED and NAMES THE FAILING LAYER. A
# probe that only ever runs green on undamaged state has proven nothing at all.
#
# WHAT THIS FILE PROVES
#   A. GREEN ON AN INTACT STACK   — a complete save probes green, exit 0.
#   B. A MISSING FIELD IS RED     — and names layer=checkpoint. ("checkpoint field absent?")
#   C. A MANGLED FIELD IS RED     — present-but-wrong is not present. Non-empty != correct.
#   D. NO ANSWER KEY IS RED       — a probe that CANNOT RUN is a RED, never a skip.
#   E. A LOST INDEX IS RED        — and names layer=index. ("index observation missing?")
#   F. A LOST/STALE CONTEXT BRANCH IS RED — names layer=context-branch. ("context branch stale?")
#   G. NO FALSE RED ON PROGRESS   — committing after the save must NOT go red. A gate
#      that cries wolf on normal work gets ignored, and then it protects nobody.
#   H. EVERY RESULT IS LOGGED     — the streak of greens is the receipt that restarts
#      are safe; the first red names exactly what to fix.
#   I. THE PROBE IS CHEAP         — it exists to make restarts cheap. A green verdict
#      that costs meaningful context defeats its own purpose. Measured, with a ceiling.
#   J. WIRED AT SESSION START     — before any work. A probe wired to nothing is a file.
#   K. NEVER CRASHES A SESSION    — garbage state exits RED, not with a stack trace.
#   L. HERMETIC                   — the real ~/.heimdall is never written.
#
# Usage:  bash test/resume-probe.test.sh    (exit 0 = every proof holds)

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CKPT="$REPO/bin/heimdall-checkpoint"
PROBE="$REPO/bin/heimdall-resume-probe"
HOOKS="$REPO/hooks/hooks.json"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
sec() { printf '\n%s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REAL_HOME_HMD="$HOME/.heimdall"
SENTINEL_TAG="resume-probe-sentinel-$$"

# A throwaway git project carrying real session knowledge in all six categories, so
# the probe is grading CONTENT and not a row of "none"s.
#
# WHY THIS IS BUILT ONCE AND THEN COPIED
# --------------------------------------
# One real `heimdall-checkpoint write` costs ~4s — it forks several hundred processes
# (six derivations, twelve sha256 read-backs) and runs a gitleaks-backed secret scan.
# This file needs SIXTEEN saved projects, one per damage case, which is ~70-100s of
# pure fixture construction during which the suite prints NOTHING. That silence is
# what made this file read as a hang; it was never hung, it was building.
#
# So the expensive save happens exactly once, into a template no case ever touches,
# and each case gets a byte-for-byte copy (~95ms — 47x cheaper). A copy is a fully
# independent, complete, correctly-keyed save: the answer key digests cover DERIVED
# VALUES (phase, goal, the recorded notes, HEAD, branch), and not one of them embeds
# the project path, so relocating the tree cannot change a single digest. Verified,
# not assumed — a copy probes GREEN 6/6, and still goes RED naming layer=checkpoint
# when a field is dropped from it.
PRISTINE="$TMP/pristine"

build_pristine() {
  mkdir -p "$PRISTINE"
  git -C "$PRISTINE" init -q
  git -C "$PRISTINE" config user.email t@t.t
  git -C "$PRISTINE" config user.name t
  printf 'hello\n' > "$PRISTINE/README.md"
  git -C "$PRISTINE" add README.md
  git -C "$PRISTINE" commit -qm "initial commit" --no-verify
  mkdir -p "$PRISTINE/.planning"
  HEIMDALL_HOME="$PRISTINE/.heimdall" "$CKPT" note in-progress "$SENTINEL_TAG wiring the probe; next step is the completeness gate" >/dev/null 2>&1
  HEIMDALL_HOME="$PRISTINE/.heimdall" "$CKPT" note gated       "human call pending: does a red probe block or advise" >/dev/null 2>&1
  HEIMDALL_HOME="$PRISTINE/.heimdall" "$CKPT" note refuted     "refuted: the meter estimates context; it reads the statusline blob" >/dev/null 2>&1
  HEIMDALL_HOME="$PRISTINE/.heimdall" "$CKPT" note warn        "fail-open observation 2026-08-05 still open" >/dev/null 2>&1
  HEIMDALL_HOME="$PRISTINE/.heimdall" "$CKPT" write "$PRISTINE" >/dev/null 2>&1
}

make_saved_project() { # -> project dir on stdout, already checkpointed
  local d
  [ -d "$PRISTINE/.git" ] || build_pristine
  d="$(mktemp -d "$TMP/proj.XXXXXX")"
  cp -R "$PRISTINE/." "$d/" 2>/dev/null
  printf '%s' "$d"
}

# Create the hmd/context orphan ref with a worklog, via plumbing (never touches the
# working tree) — the same shape bin/heimdall-context-sync publishes.
seed_context_branch() { # <project> <generated_ts>
  local d="$1" ts="$2" blob tree commit
  blob="$(printf '{"schema":"hmd-context/worklog@1","generated_ts":%s,"goal":"none","summary":"probe fixture"}\n' "$ts" \
          | git -C "$d" hash-object -w --stdin 2>/dev/null)" || return 1
  tree="$(printf '100644 blob %s\tworklog.json\n' "$blob" | git -C "$d" mktree 2>/dev/null)" || return 1
  commit="$(git -C "$d" commit-tree "$tree" -m "context fixture" 2>/dev/null)" || return 1
  git -C "$d" update-ref refs/heads/hmd/context "$commit" 2>/dev/null
}

# Run the probe against a project. Sets PROBE_OUT / PROBE_RC.
PROBE_OUT=""; PROBE_RC=0
run_probe() { # <project> [extra args...]
  local d="$1"; shift
  PROBE_OUT="$(HEIMDALL_HOME="$d/.heimdall" "$PROBE" run --repo "$d" "$@" 2>&1)"; PROBE_RC=$?
}
has()   { printf '%s' "$1" | grep -qF "$2"; }
hasre() { printf '%s' "$1" | grep -qE "$2"; }
# Case-insensitive variant. The probe SHOUTS the words it wants an operator to read
# ("a bug in the MEMORY STACK"), so an assertion about that wording must not be
# case-coupled to it — otherwise the check fails while the behaviour it asserts is
# correct, which is a broken test masquerading as a broken feature.
hasrei() { printf '%s' "$1" | grep -qiE "$2"; }

# Delete one "- **Label:** ..." line from a checkpoint — the printf-bug class, after
# the fact: the field is simply not in the bytes a resume reads.
drop_field() { # <checkpoint> <label>
  local ck="$1" label="$2" t
  t="$(mktemp "$TMP/ck.XXXXXX")"
  grep -v "^- \*\*$label:\*\* " "$ck" > "$t" 2>/dev/null
  mv "$t" "$ck"
}

# ── 0. the probe exists ──────────────────────────────────────────────────────────
sec "0. THE PROBE EXISTS:"
if [ -x "$PROBE" ]; then ok "bin/heimdall-resume-probe is executable"
else bad "bin/heimdall-resume-probe missing or not executable"; printf '\nresume-probe.test.sh: %s passed, %s failed.\n' "$PASS" "$((FAIL+1))"; exit 1; fi

# ── A. green on an intact stack ──────────────────────────────────────────────────
sec "A. GREEN ON AN INTACT STACK (a complete save resumes lossless):"
P="$(make_saved_project)"
run_probe "$P"
[ "$PROBE_RC" -eq 0 ] && ok "an intact stack probes exit 0" || bad "intact stack exited $PROBE_RC: $PROBE_OUT"
hasre "$PROBE_OUT" 'GREEN' && ok "the verdict reads GREEN" || bad "no GREEN verdict: $PROBE_OUT"
hasre "$PROBE_OUT" '6/6'   && ok "all six never-lose categories graded (6/6)" || bad "not 6/6: $PROBE_OUT"
# and the green verdict is not vacuous — it graded real content, not six blanks
JSONV="$(HEIMDALL_HOME="$P/.heimdall" "$PROBE" run --repo "$P" --json 2>/dev/null)"
if command -v jq >/dev/null 2>&1; then
  NEMPTY="$(printf '%s' "$JSONV" | jq -r '[.answers[] | select((.answer_len // 0) < 3)] | length' 2>/dev/null)"
  [ "${NEMPTY:-9}" = "0" ] && ok "anti-vacuous: every graded answer carries real content, not a blank" \
                           || bad "${NEMPTY} graded answers were effectively empty — a green over blanks proves nothing"
else
  bad "jq missing — cannot verify the green was non-vacuous"
fi
rm -rf "$P"

# ── B. a missing checkpoint field -> RED, layer named ────────────────────────────
sec "B. A MISSING FIELD IS RED, AND NAMES layer=checkpoint (\"checkpoint field absent?\"):"
for PAIR in "in_progress:In progress" "unpushed:Unpushed" "held_branches:Held branches" \
            "gated_decisions:Gated decisions" "refuted_claims:Refuted claims" "open_warnings:Open warnings"; do
  ID="${PAIR%%:*}"; LABEL="${PAIR#*:}"
  P="$(make_saved_project)"
  drop_field "$P/.planning/CHECKPOINT.md" "$LABEL"
  run_probe "$P"
  if [ "$PROBE_RC" -ne 0 ] && has "$PROBE_OUT" "$ID"; then
    ok "$ID absent -> RED (exit $PROBE_RC) naming the category"
  else
    bad "$ID absent -> exit $PROBE_RC, verdict did not name it: $PROBE_OUT"
  fi
  rm -rf "$P"
done
P="$(make_saved_project)"
drop_field "$P/.planning/CHECKPOINT.md" "In progress"
run_probe "$P"
hasre "$PROBE_OUT" 'layer=checkpoint|layer.*checkpoint' && ok "the RED names layer=checkpoint (the bug can be filed)" \
                                                        || bad "the RED names no layer: $PROBE_OUT"
hasre "$PROBE_OUT" 'RED' && ok "the verdict reads RED" || bad "no RED verdict: $PROBE_OUT"
hasrei "$PROBE_OUT" 'stack|memory' && ok "the RED says this is a bug in the STACK, not a probe failure" \
                                   || bad "the RED does not attribute the failure to the stack: $PROBE_OUT"
rm -rf "$P"

# ── C. a MANGLED field -> RED (present-but-wrong is not present) ─────────────────
sec "C. A MANGLED FIELD IS RED (non-empty is not the same as correct):"
P="$(make_saved_project)"
CK="$P/.planning/CHECKPOINT.md"
T="$(mktemp "$TMP/ck.XXXXXX")"
sed 's/^- \*\*In progress:\*\* .*/- **In progress:** something else entirely/' "$CK" > "$T" && mv "$T" "$CK"
run_probe "$P"
[ "$PROBE_RC" -ne 0 ] && ok "a rewritten field value -> RED (exit $PROBE_RC)" \
                      || bad "a rewritten field passed as correct — the key is not being compared"
has "$PROBE_OUT" 'in_progress' && ok "the RED names the mangled category" || bad "mangled category unnamed: $PROBE_OUT"
rm -rf "$P"

# ── D. no answer key -> RED (cannot run is a RED, never a skip) ──────────────────
sec "D. NO ANSWER KEY IS RED (gates fail closed — a probe that cannot run never skips):"
P="$(make_saved_project)"
rm -f "$P/.planning/RESUME-KEY.json"
run_probe "$P"
[ "$PROBE_RC" -ne 0 ] && ok "a missing answer key -> RED (exit $PROBE_RC), not a silent pass" \
                      || bad "a missing answer key was treated as a pass — the gate fails OPEN"
hasre "$PROBE_OUT" 'key' && ok "the RED says the answer key is the problem" || bad "the RED does not mention the key: $PROBE_OUT"
rm -rf "$P"
# a CORRUPT key is equally a RED, not a crash and not a pass
P="$(make_saved_project)"
printf 'not json at all {{{\n' > "$P/.planning/RESUME-KEY.json"
run_probe "$P"
[ "$PROBE_RC" -ne 0 ] && ok "a corrupt answer key -> RED" || bad "a corrupt key was trusted"
[ "$PROBE_RC" != 139 ] && ok "a corrupt key does not crash the probe" || bad "the probe crashed on a corrupt key"
rm -rf "$P"
# no checkpoint at ALL is a RED — a fresh session with nothing to resume from must
# never be told the stack is fine
P="$(make_saved_project)"
rm -f "$P/.planning/CHECKPOINT.md" "$P/.planning/RESUME-KEY.json"
run_probe "$P"
[ "$PROBE_RC" -ne 0 ] && ok "no checkpoint at all -> RED, never \"nothing to check, carry on\"" \
                      || bad "an absent checkpoint reported green"
rm -rf "$P"

# ── E. a lost/pruned index -> RED naming layer=index ─────────────────────────────
sec "E. A LOST OBSERVATION STORE IS RED, naming layer=index (\"index observation missing?\"):"
P="$(make_saved_project)"
NOTES="$P/.heimdall/resume-notes.ndjson"
[ -f "$NOTES" ] && ok "setup: the observation store exists after the save" || bad "setup: no observation store at $NOTES"
rm -f "$NOTES"
run_probe "$P"
[ "$PROBE_RC" -ne 0 ] && ok "the store deleted -> RED (exit $PROBE_RC)" || bad "a deleted observation store probed green"
hasre "$PROBE_OUT" 'index' && ok "the RED names layer=index" || bad "the RED does not name the index layer: $PROBE_OUT"
rm -rf "$P"
# PRUNED (not deleted) — entries silently disappearing is the subtler, likelier decay
P="$(make_saved_project)"
NOTES="$P/.heimdall/resume-notes.ndjson"
head -1 "$NOTES" > "$TMP/pruned.ndjson" 2>/dev/null && mv "$TMP/pruned.ndjson" "$NOTES"
run_probe "$P"
[ "$PROBE_RC" -ne 0 ] && ok "the store PRUNED (entries dropped) -> RED" || bad "a pruned observation store probed green"
hasre "$PROBE_OUT" 'index' && ok "the pruned-store RED names layer=index" || bad "pruned store did not name the index layer: $PROBE_OUT"
rm -rf "$P"

# ── F. a lost / stale context branch -> RED naming layer=context-branch ──────────
sec "F. A LOST OR STALE CONTEXT BRANCH IS RED, naming layer=context-branch:"
P="$(mktemp -d "$TMP/ctxproj.XXXXXX")"
git -C "$P" init -q
git -C "$P" config user.email t@t.t
git -C "$P" config user.name t
printf 'hello\n' > "$P/README.md"
git -C "$P" add README.md
git -C "$P" commit -qm "initial commit" --no-verify
mkdir -p "$P/.planning"
if seed_context_branch "$P" "$(date +%s)"; then
  ok "setup: seeded the hmd/context orphan ref"
  HEIMDALL_HOME="$P/.heimdall" "$CKPT" note in-progress "context-branch fixture" >/dev/null 2>&1
  HEIMDALL_HOME="$P/.heimdall" "$CKPT" write "$P" >/dev/null 2>&1
  run_probe "$P"
  [ "$PROBE_RC" -eq 0 ] && ok "with the context branch present and current -> GREEN" \
                        || bad "a present, current context branch probed RED: $PROBE_OUT"
  git -C "$P" update-ref -d refs/heads/hmd/context 2>/dev/null
  run_probe "$P"
  [ "$PROBE_RC" -ne 0 ] && ok "the context branch DELETED after the save -> RED" \
                        || bad "a vanished context branch probed green — the layer loss was invisible"
  hasre "$PROBE_OUT" 'context-branch' && ok "the RED names layer=context-branch" \
                                      || bad "the RED does not name the context branch: $PROBE_OUT"
else
  bad "could not seed the hmd/context ref — the context-branch layer went unproven"
fi
rm -rf "$P"
# a repo that never had a context branch must NOT be red for it (context-sync is
# opt-out by design; a permanently-red gate is an ignored gate)
P="$(make_saved_project)"
run_probe "$P"
[ "$PROBE_RC" -eq 0 ] && ok "a repo with no context branch is not red for its absence (it was never there)" \
                      || bad "absent-by-design context branch produced a false RED: $PROBE_OUT"
rm -rf "$P"

# ── G. no false red on ordinary progress ─────────────────────────────────────────
sec "G. NO FALSE RED ON PROGRESS (a gate that cries wolf gets ignored):"
P="$(make_saved_project)"
printf 'more\n' >> "$P/README.md"
git -C "$P" add README.md
git -C "$P" commit -qm "work done after the checkpoint" --no-verify >/dev/null 2>&1
run_probe "$P"
[ "$PROBE_RC" -eq 0 ] && ok "committing after the save does NOT go red (the probe grades the stack, not the world)" \
                      || bad "ordinary progress produced a false RED: $PROBE_OUT"
# ...but the drift is still REPORTED, or a resuming session would think HEAD is unchanged
JSONV="$(HEIMDALL_HOME="$P/.heimdall" "$PROBE" run --repo "$P" --json 2>/dev/null)"
hasre "$JSONV" 'drift' && ok "the drift between saved HEAD and current HEAD is reported (informational, not graded)" \
                       || bad "HEAD drift is invisible — a resume would assume nothing moved"
rm -rf "$P"

# ── H. every result is logged — the streak IS the receipt ────────────────────────
sec "H. EVERY RESULT IS LOGGED (a streak of greens is the receipt restarts are safe):"
P="$(make_saved_project)"
run_probe "$P"; run_probe "$P"
drop_field "$P/.planning/CHECKPOINT.md" "Unpushed"
run_probe "$P"
LOG="$(HEIMDALL_HOME="$P/.heimdall" "$PROBE" log --repo "$P" 2>&1)"
LOGF="$P/.heimdall/probe.ndjson"
[ -f "$LOGF" ] && ok "the probe log exists at .heimdall/probe.ndjson" || bad "no probe log written"
N="$(grep -c . "$LOGF" 2>/dev/null; true)"; N="${N:-0}"
[ "$N" -ge 3 ] && ok "every run appended a record ($N records for 3 runs)" || bad "only $N records for 3 runs"
has "$LOG" 'GREEN' && ok "the log surfaces the greens" || bad "log shows no greens: $LOG"
has "$LOG" 'RED'   && ok "the log surfaces the red"    || bad "log shows no red: $LOG"
hasre "$LOG" 'streak|GREEN' && ok "the log reads as a streak receipt" || bad "log is not a receipt: $LOG"
rm -rf "$P"

# ── I. the probe is CHEAP — it exists to make restarts cheap ─────────────────────
sec "I. THE PROBE IS CHEAP (a verdict that costs real context defeats its own purpose):"
P="$(make_saved_project)"
run_probe "$P"
BYTES="$(printf '%s' "$PROBE_OUT" | wc -c | tr -d ' ')"
LINES="$(printf '%s\n' "$PROBE_OUT" | grep -c .)"
printf '       measured green verdict: %s bytes, %s non-empty lines (~%s tokens)\n' \
  "$BYTES" "$LINES" "$(( (BYTES + 3) / 4 ))"
[ "$BYTES" -le 700 ] && ok "a green verdict is ${BYTES} bytes (ceiling 700 — roughly 175 tokens)" \
                     || bad "a green verdict costs ${BYTES} bytes — too expensive to run every restart"
[ "$LINES" -le 6 ]   && ok "a green verdict is ${LINES} non-empty lines (ceiling 6)" \
                     || bad "a green verdict is ${LINES} lines — too noisy for every restart"
# and it is FAST: it runs before any work, so it must not cost wall-clock either
S=$(date +%s); run_probe "$P"; E=$(date +%s)
[ $((E - S)) -le 5 ] && ok "a probe run completes in $((E - S))s (ceiling 5s)" \
                     || bad "the probe took $((E - S))s — too slow to gate every restart"
rm -rf "$P"

# ── J. wired at session start, before any work ───────────────────────────────────
sec "J. WIRED @ SessionStart — before any work (a probe wired to nothing is a file):"
# The probe is armed as its OWN SessionStart entry, which is what makes the rest of
# this section possible: the giant install command registers the statusline and
# self-heals ~/.claude, so it could never be executed under test. A dedicated entry
# can be, so the wiring here is EXECUTED verbatim out of hooks.json rather than
# merely grepped. A hook asserted only structurally is a hook nobody has ever run.
SS_CMD="$(jq -r '.hooks.SessionStart[]?.hooks[]?.command // empty' "$HOOKS" 2>/dev/null \
         | grep -F 'heimdall-resume-probe' | head -1)"

# Execute the real command string against a throwaway repo. Sets SS_OUT/SS_RC/SS_SECS.
SS_OUT=""; SS_RC=0; SS_SECS=0
run_ss() { # <project-dir> [plugin-root]
  local d="$1" plug="${2:-$REPO}" s e
  s=$(date +%s)
  SS_OUT="$(CLAUDE_PLUGIN_ROOT="$plug" CLAUDE_PROJECT_DIR="$d" HEIMDALL_HOME="$d/.heimdall" \
            sh -c "$SS_CMD" 2>&1)"
  SS_RC=$?
  e=$(date +%s); SS_SECS=$((e - s))
}

if [ -n "$SS_CMD" ]; then
  ok "a SessionStart hook invokes heimdall-resume-probe"
  has "$SS_CMD" 'CHECKPOINT.md' && ok "the invocation is guarded by an existing checkpoint (silent in repos with nothing to resume)" \
                                || bad "the probe fires unconditionally — it would speak in repos with no checkpoint"

  # Refuse to execute the install command by accident: if the probe is ever folded
  # into it, running it here would write the operator's real ~/.claude.
  if has "$SS_CMD" 'statusline-register' || has "$SS_CMD" 'cc-selfheal' || has "$SS_CMD" 'edit-tracker'; then
    bad "the probe is fused into the install/self-heal SessionStart command — it must be its own entry so it can fail without taking the install down, and so this suite can execute it hermetically"
  else
    ok "the probe's SessionStart wiring is a dedicated, self-contained entry"

    # A RED verdict is the WHOLE POINT of the probe, and it must still not fail the
    # session that surfaced it. A hook that exits non-zero on a red reads to the
    # operator as a broken install, and the first thing anyone does to a hook that
    # breaks session start is delete it.
    P="$(make_saved_project)"
    rm -f "$P/.planning/RESUME-KEY.json"
    run_ss "$P"
    [ "$SS_RC" -eq 0 ] && ok "a RED probe still exits the hook 0 (a red verdict must never break a session)" \
                       || bad "a RED probe exited the SessionStart hook $SS_RC — that surfaces as a broken session start"
    hasrei "$SS_OUT" 'RED' && ok "...and the RED still reaches the operator (bounded, not swallowed)" \
                           || bad "the RED was swallowed — the gate would be invisible: $SS_OUT"
    SSL="$(printf '%s\n' "$SS_OUT" | grep -c .)"
    [ "$SSL" -le 8 ] && ok "the RED stays inside the SessionStart output budget ($SSL lines, ceiling 8)" \
                     || bad "the RED spent $SSL lines of every session start"
    rm -rf "$P"

    # Nothing to resume -> the hook must cost NOTHING, or every repo without a
    # checkpoint pays for a feature it is not using.
    P="$(mktemp -d "$TMP/nockpt.XXXXXX")"
    run_ss "$P"
    [ "$SS_RC" -eq 0 ] && ok "a repo with no checkpoint exits 0" || bad "no-checkpoint repo exited $SS_RC: $SS_OUT"
    [ -z "$SS_OUT" ] && ok "...and says nothing at all (zero bytes)" || bad "the hook spoke in a repo with nothing to resume: $SS_OUT"
    rm -rf "$P"

    # A half-installed plugin must not break session start either.
    P="$(make_saved_project)"
    NOPLUG="$(mktemp -d "$TMP/noplug.XXXXXX")"
    run_ss "$P" "$NOPLUG"
    [ "$SS_RC" -eq 0 ] && ok "a missing probe binary exits 0 (a broken install never blocks a session)" \
                       || bad "a missing probe binary exited $SS_RC: $SS_OUT"
    [ -z "$SS_OUT" ] && ok "...and is silent rather than leaking a shell error" || bad "missing binary printed: $SS_OUT"
    rm -rf "$P" "$NOPLUG"

    # THE ONE THAT MATTERS. This subsystem exists to prove restarts are safe, so a
    # probe that could wedge would make restarting impossible — the exact inversion
    # that kept this feature unarmed. Grepping for an `alarm` only proves a ceiling
    # was TYPED. Substituting a probe that never returns proves it WORKS.
    WEDGE="$(mktemp -d "$TMP/wedge.XXXXXX")"
    mkdir -p "$WEDGE/bin"
    printf '#!/bin/sh\nsleep 300\n' > "$WEDGE/bin/heimdall-resume-probe"
    chmod +x "$WEDGE/bin/heimdall-resume-probe"
    P="$(make_saved_project)"
    run_ss "$P" "$WEDGE"
    [ "$SS_SECS" -le 30 ] && ok "a WEDGED probe (never returns) still releases the hook in ${SS_SECS}s — the ceiling is real, not decorative" \
                          || bad "a wedged probe held session start for ${SS_SECS}s — every new session would hang"
    [ "$SS_RC" -eq 0 ] && ok "...and a wedged probe still exits 0" || bad "a wedged probe exited $SS_RC"
    rm -rf "$P" "$WEDGE"
  fi
else
  bad "NOT WIRED — no SessionStart hook calls heimdall-resume-probe"
fi

# ── K. never crashes a session ───────────────────────────────────────────────────
sec "K. NEVER CRASHES (it runs at session start; a red is fine, a stack trace is not):"
for ARGS in "--repo /nonexistent-dir-$$" "--repo $TMP"; do
  RC=0; OUT="$("$PROBE" run $ARGS 2>&1)" || RC=$?
  [ "$RC" != 139 ] && [ "$RC" != 2 ] && ok "run $ARGS -> exit $RC (a verdict, not a crash)" \
                                     || bad "run $ARGS -> exit $RC: $OUT"
  hasre "$OUT" 'RED|GREEN' && ok "run $ARGS still renders a verdict" || bad "run $ARGS rendered nothing: $OUT"
done
RC=0; "$PROBE" no-such-verb >/dev/null 2>&1 || RC=$?
[ "$RC" -ne 0 ] && ok "an unknown verb is a real error (exit $RC), not a silent no-op" \
                || bad "unknown verb silently succeeded"

# ── L. hermetic ──────────────────────────────────────────────────────────────────
sec "L. HERMETIC (the real ~/.heimdall is never written):"
if [ -d "$REAL_HOME_HMD" ] && grep -rlF "$SENTINEL_TAG" "$REAL_HOME_HMD" 2>/dev/null | grep -q .; then
  bad "leaked the test sentinel into the real $REAL_HOME_HMD"
else
  ok "no test state leaked into the real ~/.heimdall"
fi

printf '\nresume-probe.test.sh: %s passed, %s failed.\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
