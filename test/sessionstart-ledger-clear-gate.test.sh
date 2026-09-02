#!/usr/bin/env bash
# sessionstart-ledger-clear-gate.test.sh — falsifier for the SessionStart
# edit-tracker `clear` gate.
#
# THE BUG: hooks/hooks.json's SessionStart entry [0] fired `edit-tracker
# clear` UNCONDITIONALLY on every SessionStart event — a genuine fresh start,
# a `resume`, AND a `compact` alike — with no gate on the hook payload's own
# `source` field. Every compaction and every resume silently wiped the
# session's edit ledger mid-session. bin/edit-tracker.c's own header comment
# and bin/verify-edits' mid-session-clear cross-check both already document
# this exact defect (they mitigate the SYMPTOM; this test covers the ROOT
# CAUSE, in the hook itself).
#
# THE FIX: entry [0] now captures its own stdin (`INPUT=$(cat ...)`, mirroring
# entry [5]'s pre-existing `INPUT=$(cat)` precedent for the very same
# SessionStart event — each SessionStart entry is a separate array element,
# spawned as its own process with its own independent copy of the hook
# payload; entry [5] already proves an entry other than [0] can read stdin
# safely within this same event), extracts `.source`, and gates the `clear`
# call on `source == "startup"` (an ALLOWLIST, not a denylist: anything other
# than exactly "startup" — resume, compact, an unrecognized/future value, or
# an undeterminable source — skips the clear). `init` stays unconditional:
# do_init() is idempotent (create-if-absent, O_CREAT without O_TRUNC, never
# destroys existing content) so running it every SessionStart is always safe.
#
# This test drives the REAL SessionStart[0] command, extracted verbatim from
# hooks/hooks.json (the same technique test/heimdall-team-clone-join.test.sh
# uses for this identical entry), under /bin/sh — the actual shell hooks run
# under per this repo's hard constraint — feeding synthetic JSON payloads on
# stdin and observing the REAL bin/edit-tracker.c ledger, built fresh into a
# sandboxed $PLUGIN (never the tracked repo binary).
#
# RED-WITHOUT-FIX: G7 reconstructs the ORIGINAL unconditional-clear segment as
# a mutant and proves it DOES wipe a `compact` ledger — demonstrating this
# suite would have caught the real bug, not just rubber-stamped the fix.
#
# Hermetic: everything lives under a mktemp sandbox; TMPDIR and
# CLAUDE_CODE_SESSION_ID are overridden throughout, so this NEVER reads or
# writes any real session's ledger. Exit 0 = every guarantee holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HOOKS_JSON="$REPO/hooks/hooks.json"
TRACKER_SRC="$REPO/bin/edit-tracker.c"

[ -f "$HOOKS_JSON" ]  || { echo "FATAL: $HOOKS_JSON missing" >&2; exit 2; }
[ -f "$TRACKER_SRC" ] || { echo "FATAL: $TRACKER_SRC missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }
command -v jq    >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 2; }
command -v clang >/dev/null 2>&1 || { echo "FATAL: clang not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/sessionstart-clear-gate.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SID="sessionstart-clear-gate-test"
LEDGER="$SANDBOX/heimdall-edits/$SID.log"

echo "============================================================"
echo "SessionStart ledger-clear gate falsifier"
echo "  sandbox=$SANDBOX  session=$SID"
echo "============================================================"
echo

# ── sandboxed $PLUGIN: only edit-tracker.c is provided; every OTHER
#    $PLUGIN/bin/* the SessionStart command references is intentionally
#    ABSENT so its own [ -x ] guard skips it (same isolation pattern as
#    test/heimdall-team-clone-join.test.sh uses for this identical entry). ──
PLUGIN_SANDBOX="$SANDBOX/plugin"
mkdir -p "$PLUGIN_SANDBOX/bin"
cp "$TRACKER_SRC" "$PLUGIN_SANDBOX/bin/edit-tracker.c"
TRACKER="$PLUGIN_SANDBOX/bin/edit-tracker"
clang -O2 -Wall -Wextra -o "$TRACKER" "$PLUGIN_SANDBOX/bin/edit-tracker.c" 2>"$SANDBOX/build.err"
if [ -x "$TRACKER" ]; then
  ok "edit-tracker.c builds clean into the sandbox plugin"
else
  bad "edit-tracker.c failed to build"; cat "$SANDBOX/build.err" >&2
fi

# A clean throwaway CWD — never the repo itself (the repo's own real
# .planning/CHECKPOINT.md must never leak into this run).
WORKDIR="$SANDBOX/workdir"
mkdir -p "$WORKDIR"

# ── the REAL SessionStart[0] command, extracted verbatim from hooks.json ──
SS_CMD="$(HMD_HOOKS="$HOOKS_JSON" "$PY" - <<'PYEOF'
import json, os
d = json.load(open(os.environ["HMD_HOOKS"]))
print(d["hooks"]["SessionStart"][0]["hooks"][0]["command"], end="")
PYEOF
)"
[ -n "$SS_CMD" ] || { echo "FATAL: could not extract SessionStart[0] command" >&2; exit 2; }

# fixture-staleness guards: if either shape disappears from entry [0], this
# suite is testing nothing real and must say so loudly rather than pass empty.
case "$SS_CMD" in
  *'INPUT=$(cat'*) : ;;
  *) echo "FATAL: entry [0] no longer captures stdin — test is stale" >&2; exit 2 ;;
esac
case "$SS_CMD" in
  *'"$ETRACKER" clear'*) : ;;
  *) echo "FATAL: entry [0] no longer calls edit-tracker clear at all — test is stale" >&2; exit 2 ;;
esac

trk() { env TMPDIR="$SANDBOX" CLAUDE_CODE_SESSION_ID="$SID" "$TRACKER" "$@"; }

# run_ss <payload> — feeds $1 (raw bytes, "" allowed) on stdin to the REAL
# SessionStart[0] command under /bin/sh (the actual hook shell), in the
# sandboxed plugin + a throwaway cwd. Never touches any real ledger.
run_ss() {
  ( cd "$WORKDIR" && printf '%s' "$1" | env \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_SANDBOX" TMPDIR="$SANDBOX" \
      CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PROJECT_DIR="$WORKDIR" \
      sh -c "$SS_CMD" ) >"$SANDBOX/last.out" 2>"$SANDBOX/last.err"
}

ledger_lines() { [ -f "$LEDGER" ] && wc -l < "$LEDGER" | tr -d ' ' || echo 0; }

reset_round() {
  rm -rf "$SANDBOX/heimdall-edits"
  trk init >/dev/null 2>&1
  trk log Write "$WORKDIR/seed-a.txt" >/dev/null 2>&1
  trk log Write "$WORKDIR/seed-b.txt" >/dev/null 2>&1
  trk log Write "$WORKDIR/seed-c.txt" >/dev/null 2>&1
}

# ══════════════════════════════════════════════════════════════════════════
# G1 — fresh start (source=startup): clear DOES run, ledger resets to empty.
# ══════════════════════════════════════════════════════════════════════════
reset_round
before="$(ledger_lines)"
run_ss '{"source":"startup","session_id":"abc"}'
after="$(ledger_lines)"
if [ "$before" -eq 3 ] && [ "$after" -eq 0 ]; then
  ok "G1 source=startup clears the ledger (before=$before after=$after)"
else
  bad "G1 source=startup should clear to 0 (before=$before after=$after)"; cat "$SANDBOX/last.err" >&2
fi
if [ -f "$LEDGER" ]; then
  ok "G1b init still runs after a startup clear (ledger file present, just empty — do_init is idempotent, never skipped)"
else
  bad "G1b ledger file missing after startup clear — init did not run"
fi

# ══════════════════════════════════════════════════════════════════════════
# G2 — compact: clear must NOT run, all 3 seeded entries survive.
# ══════════════════════════════════════════════════════════════════════════
reset_round
run_ss '{"source":"compact","session_id":"abc"}'
after="$(ledger_lines)"
if [ "$after" -eq 3 ]; then
  ok "G2 source=compact skips the clear — all 3 entries survive"
else
  bad "G2 source=compact should NOT clear (expected 3, got $after)"; cat "$SANDBOX/last.err" >&2
fi

# ══════════════════════════════════════════════════════════════════════════
# G3 — resume: clear must NOT run, all 3 seeded entries survive.
# ══════════════════════════════════════════════════════════════════════════
reset_round
run_ss '{"source":"resume","session_id":"abc"}'
after="$(ledger_lines)"
if [ "$after" -eq 3 ]; then
  ok "G3 source=resume skips the clear — all 3 entries survive"
else
  bad "G3 source=resume should NOT clear (expected 3, got $after)"; cat "$SANDBOX/last.err" >&2
fi

# ══════════════════════════════════════════════════════════════════════════
# G4 — malformed JSON on stdin: fails open (hook still exits 0, no wedge),
#      and the clear does NOT run (source undeterminable => skip, never wipe).
# ══════════════════════════════════════════════════════════════════════════
reset_round
run_ss '{not valid json'
rc=$?
after="$(ledger_lines)"
if [ "$rc" -eq 0 ]; then
  ok "G4a malformed JSON on stdin: hook still exits 0 (fails open, no wedge)"
else
  bad "G4a malformed JSON on stdin: hook exited $rc — session start would wedge"
fi
if [ "$after" -eq 3 ]; then
  ok "G4b malformed JSON on stdin: clear skipped, all 3 entries survive"
else
  bad "G4b malformed JSON on stdin should skip the clear (expected 3, got $after)"; cat "$SANDBOX/last.err" >&2
fi

# ── G4c — valid JSON, but no `source` key at all (jq's `.source // empty`
#    fallback path, distinct from a JSON parse failure): skip the clear. ──
reset_round
run_ss '{"session_id":"abc"}'
after="$(ledger_lines)"
if [ "$after" -eq 3 ]; then
  ok "G4c valid JSON with source key ABSENT: clear skipped, all 3 entries survive"
else
  bad "G4c valid JSON with no source key should skip the clear (expected 3, got $after)"; cat "$SANDBOX/last.err" >&2
fi

# ══════════════════════════════════════════════════════════════════════════
# G5 — absent JSON (empty stdin — e.g. a caller that never feeds a payload at
#      all, exactly how test/heimdall-team-clone-join.test.sh drives this same
#      entry via `bash -c` with no stdin redirect): fails open, clear does
#      NOT run.
# ══════════════════════════════════════════════════════════════════════════
reset_round
run_ss ''
rc=$?
after="$(ledger_lines)"
if [ "$rc" -eq 0 ]; then
  ok "G5a empty stdin: hook still exits 0 (fails open, no wedge)"
else
  bad "G5a empty stdin: hook exited $rc — session start would wedge"
fi
if [ "$after" -eq 3 ]; then
  ok "G5b empty stdin: clear skipped, all 3 entries survive"
else
  bad "G5b empty stdin should skip the clear (expected 3, got $after)"; cat "$SANDBOX/last.err" >&2
fi

# ══════════════════════════════════════════════════════════════════════════
# G6 — jq missing from PATH entirely: fails open, clear does NOT run (prefer
#      a stale ledger over losing one when `source` can't be determined).
# ══════════════════════════════════════════════════════════════════════════
reset_round
NOJQ="$SANDBOX/nojq-path"
mkdir -p "$NOJQ"
for b in sh cat printf clang env wc tr rm mkdir grep basename dirname mktemp date true false; do
  p="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$p" ] && ln -sf "$p" "$NOJQ/$b" 2>/dev/null || true
done
( cd "$WORKDIR" && printf '%s' '{"source":"startup"}' | env -i \
    PATH="$NOJQ" HOME="$SANDBOX/home" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_SANDBOX" TMPDIR="$SANDBOX" \
    CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PROJECT_DIR="$WORKDIR" \
    sh -c "$SS_CMD" ) >"$SANDBOX/last.out" 2>"$SANDBOX/last.err"
rc=$?
after="$(ledger_lines)"
if [ "$rc" -eq 0 ]; then
  ok "G6a jq missing from PATH: hook still exits 0 (fails open, no wedge)"
else
  bad "G6a jq missing from PATH: hook exited $rc — session start would wedge"
fi
if [ "$after" -eq 3 ]; then
  ok "G6b jq missing from PATH: clear skipped even though source=startup (can't confirm => don't wipe), all 3 entries survive"
else
  bad "G6b jq missing from PATH should skip the clear (expected 3, got $after)"; cat "$SANDBOX/last.err" >&2
fi

# ══════════════════════════════════════════════════════════════════════════
# G7 — RED-WITHOUT-FIX mutant: re-inject the ORIGINAL unconditional-clear
#      segment and confirm the compact case now LOSES all 3 entries —
#      proving this suite actually catches the defect it was written for.
# ══════════════════════════════════════════════════════════════════════════
# NOTE: this heredoc writes to a FILE, then a separate plain command
# substitution reads it back — deliberately NOT `X="$(... <<'EOF' ... EOF)"`.
# Bash mis-parses escaped apostrophes inside a heredoc body when that heredoc
# is itself nested inside a double-quoted `$(...)`  (reproduced in isolation
# during development: identical heredoc body, only the wrapping differs).
# Keeping the heredoc a top-level redirect sidesteps the interaction.
"$PY" - "$SS_CMD" >"$SANDBOX/mutant_cmd.txt" <<'PYEOF'
import sys
cmd = sys.argv[1]
old = ('SRC=$(printf \'%s\' "$INPUT" | jq -r \'.source // empty\' 2>/dev/null || true); '
       'if [ "$SRC" = "startup" ]; then "$ETRACKER" clear 2>/dev/null || true; fi; '
       '"$ETRACKER" init 2>/dev/null || true;')
new = '"$ETRACKER" clear 2>/dev/null || true; "$ETRACKER" init 2>/dev/null || true;'
assert cmd.count(old) == 1, f"fixed segment not found exactly once (found {cmd.count(old)})"
sys.stdout.write(cmd.replace(old, new, 1))
PYEOF
MUTANT_SS_CMD="$(cat "$SANDBOX/mutant_cmd.txt")"
[ -n "$MUTANT_SS_CMD" ] || { echo "FATAL: could not build mutant command (fixed segment shape drifted)" >&2; exit 2; }

reset_round
( cd "$WORKDIR" && printf '%s' '{"source":"compact","session_id":"abc"}' | env \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_SANDBOX" TMPDIR="$SANDBOX" \
    CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PROJECT_DIR="$WORKDIR" \
    sh -c "$MUTANT_SS_CMD" ) >"$SANDBOX/last.out" 2>"$SANDBOX/last.err"
mutant_after="$(ledger_lines)"
if [ "$mutant_after" -eq 0 ]; then
  ok "G7 RED-WITHOUT-FIX proof: the ORIGINAL unconditional-clear segment DOES wipe a compact's ledger (mutant_after=0) — this suite would have caught the real bug"
else
  bad "G7 mutant did not reproduce the original bug (mutant_after=$mutant_after, expected 0) — this suite may be vacuous"
fi

# ══════════════════════════════════════════════════════════════════════════
# G8 — hooks.json stays valid JSON.
# ══════════════════════════════════════════════════════════════════════════
if jq . "$HOOKS_JSON" >/dev/null 2>"$SANDBOX/jq.err"; then
  ok "G8 jq . hooks/hooks.json is valid JSON"
else
  bad "G8 hooks/hooks.json is NOT valid JSON"; cat "$SANDBOX/jq.err" >&2
fi

# ══════════════════════════════════════════════════════════════════════════
# G9/G10 — the other SessionStart entries are undisturbed: same count, and
#          entry [5]'s own pre-existing INPUT=$(cat) precedent is untouched.
#
# The count is pinned ON PURPOSE, as a tripwire: appending a SessionStart entry
# must be a deliberate act that trips this and gets reviewed, never a silent
# drive-by. It has already done its job once -- 9 -> 10 when the
# heimdall-caveman `rules` entry was wired (2026-09-03), which is what actually
# delivers hmd's ultra rule text into a session. The UserPromptSubmit entry
# carries only a per-turn pointer, so without this entry ultra was a pointer to
# nothing. Bumping this number is correct; bumping it WITHOUT knowing which
# entry arrived is the thing to refuse.
# ══════════════════════════════════════════════════════════════════════════
SS_COUNT="$(jq '.hooks.SessionStart | length' "$HOOKS_JSON")"
if [ "$SS_COUNT" -eq 10 ]; then
  ok "G9 all 10 SessionStart entries still present"
else
  bad "G9 expected 10 SessionStart entries, found $SS_COUNT"
fi

# The caveman `rules` entry specifically: it is the ONLY thing that puts hmd's
# real compression rules into a session, so silently losing it would revert
# ultra to a no-op with every other assertion here still green.
if jq -e '[.hooks.SessionStart[].hooks[]?.command] | map(select(test("heimdall-caveman"))) | length == 1' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "G9b the heimdall-caveman rules entry is wired exactly once"
else
  bad "G9b heimdall-caveman rules entry missing or duplicated in SessionStart"
fi

ENTRY5_CMD="$(jq -r '.hooks.SessionStart[5].hooks[0].command' "$HOOKS_JSON")"
case "$ENTRY5_CMD" in
  *'INPUT=$(cat)'*'keeper-start'*)
    ok "G10 entry [5]'s own pre-existing INPUT=\$(cat) + keeper-start beat is untouched" ;;
  *)
    bad "G10 entry [5] changed shape unexpectedly (INPUT capture or keeper-start beat missing)" ;;
esac

echo
echo "============================================================"
printf "sessionstart-ledger-clear-gate: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
