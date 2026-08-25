#!/usr/bin/env bash
# heimdall-portable-brief.test.sh — falsifiable coverage for
# bin/heimdall-portable-brief, the CHECKPOINT-TO-FALLBACK-MODEL scrubber.
#
# WHY THIS TOOL EXISTS: a quota-exhaustion fallback to a non-Claude model is
# handled elsewhere. Spend here is dominated by turns x context, and ~95.56%
# of tokens are served from Anthropic's prompt cache — switching providers
# means a cold cache, so replaying the whole conversation to a fallback model
# is the wrong move. Instead, hand the fallback model the EXISTING checkpoint
# (.planning/CHECKPOINT.md, written by bin/heimdall-checkpoint). This tool
# turns that checkpoint into a PORTABLE CONTEXT BRIEF safe to hand to a
# different, untrusted-for-secrets, model.
#
# THE PRIMARY CONSTRAINT under test: a fallback provider is, for trust
# purposes, PUBLIC. Security-incident material and credentials stay in
# .planning/ and must NEVER go public. The scrubber must FAIL CLOSED: any
# section it cannot confidently classify as safe is EXCLUDED, never included.
# Excluding useful context degrades the fallback model's answer; including a
# secret cannot be undone.
#
# Separately, the tool itself follows a never-fail-CALLER contract (distinct
# from fail-closed CONTENT scrubbing): a missing/unreadable checkpoint must
# never crash the process — it degrades to an honest empty/partial result at
# exit 0. Those are two different layers and this file proves both.
#
# Falsifiable claims proved below:
#   1. a planted fake secret (AWS-access-key-shaped) living INSIDE an in-zone,
#      heading-whitelisted section is scrubbed — never appears in the brief.
#   2. planted fake security-incident language living INSIDE an in-zone,
#      heading-whitelisted section is scrubbed — never appears in the brief.
#   3. a benign, non-sensitive section that is outside the recognized
#      mechanical zone/heading whitelist is EXCLUDED, not included — fail
#      closed on AMBIGUITY, not just on danger.
#   4. a size budget smaller than the content produces a brief whose total
#      byte size fits the budget, and whose manifest NAMES what it dropped
#      (priority order), rather than silently truncating.
#   5. a pathological budget too small even for the manifest text itself
#      (zero included sections still over budget) is reported HONESTLY with
#      a plain-text overshoot note — the manifest is never truncated to
#      force a fit, because the trade-off explanation matters more than
#      hitting the byte number exactly.
#   6. a missing checkpoint file exits 0 with an honest, explicit empty
#      result (never-fail-caller contract) — never a crash/traceback.
#   7. a garbage/unstructured checkpoint (no recognizable zone markers at
#      all) degrades the same way: whole file treated as manual/untrusted,
#      exit 0, no crash, honest (likely empty) result.
#   8. `--out FILE` writes the same brief to disk; the tool itself never
#      transmits anything anywhere — that statement is present in the output.
#   9. bad CLI usage (unknown subcommand) exits 2 — a usage error, kept
#      separate from the never-fail-caller contract on purpose (documented
#      deviation from bin/heimdall-metric / bin/heimdall-pressure's --strict
#      pattern: this is a directly-invoked, payload-producing CLI like
#      bin/heimdall-brief, not a fire-and-forget hook telemetry emitter).
#  10. the emitted script is syntactically valid Python (py_compile) and this
#      test file is syntactically valid bash (bash -n).
#
# HERMETIC: every case gets its own mktemp fixture checkpoint file / repo
# dir. Never touches the real .planning/CHECKPOINT.md. Fixtures use
# obviously fake secrets (AKIAFAKEFAKE... / a fabricated incident sentence)
# — never real repo credentials, never real incident text.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CLI="$REPO/bin/heimdall-portable-brief"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-portable-brief-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Unique markers so a grep-for-absence check can never accidentally match
# unrelated boilerplate text elsewhere in the brief.
FAKE_AWS_KEY="AKIAFAKEFAKE12345678"
FAKE_INCIDENT_PHRASE="a SECURITY INCIDENT (see SECURITY-REMEDIATION.md Step 6.2)"
BENIGN_MARKER="UNIQUE_BENIGN_MARKER_ZZZ_no_secret_here"

# Full fixture: mirrors the real structure emitted by bin/heimdall-checkpoint
# (marker-delimited auto zone with its exact known headings) plus manual
# human-authored sections before/after — confirmed against bin/heimdall-checkpoint
# source (BEGIN_MARK/END_MARK constants, and each `### ...` / `## ...` printf).
write_full_fixture() {
  local path="$1"
  cat >"$path" <<EOF
# Heimdall Checkpoint

## TL;dr

Manual save, written by a human via /hmd:save. Nothing sensitive here.

<!-- heimdall-auto-checkpoint:begin -->
## Auto-checkpoint — 2026-08-25T02:56:43Z

- Branch: worktree-agent-test
- HEAD: abc1234
- Phase: implementation
- Goal: build the portable brief CLI and its test
- Uncommitted files: 2

### What must never be lost (the resume contract)

- In progress: Building the portable brief CLI and tests.
- Gated decisions: none pending.
- Held branches: worktree-agent-test holds uncommitted work.
- Unpushed: 3 commits ahead of origin/main.
- Open warnings: none.
- Refuted claims: none.

### Worktree ledger — nothing-lost proof (1 of 1 worktree(s) scanned)

- /tmp/fake-worktree — branch worktree-agent-test — clean

### This session's edited files (edit-tracker — git log cannot attribute these)

- bin/heimdall-portable-brief
- test/heimdall-portable-brief.test.sh

### Gate state (push-gate verdict — GREEN)

All quality gates green as of last run. This note references $FAKE_INCIDENT_PHRASE
that was fully resolved and rotated; kept here only as a scrub-test fixture.

### Recent commits

abc1234 feat: rotate leaked key $FAKE_AWS_KEY during incident drill
def5678 chore: update deps

### Uncommitted changes (git status --porcelain)

 M bin/heimdall-portable-brief
 M test/heimdall-portable-brief.test.sh

### Resume
Runnable, in order:
\`\`\`bash
cat CHECKPOINT.md
\`\`\`
<!-- heimdall-auto-checkpoint:end -->

## Key Context

$BENIGN_MARKER — this is ordinary, non-sensitive manual prose written by a
human. It should still be excluded from the portable brief because it lives
outside the recognized mechanical checkpoint structure, not because it is
dangerous.
EOF
}

run() { python3 "$CLI" "$@"; }

echo "heimdall-portable-brief harness"
echo "--------------------------------------------------------------------"

# ── 1/2. planted fake secret + fake incident text are scrubbed ──────────────
CKPT="$WORK/ckpt1/CHECKPOINT.md"
mkdir -p "$(dirname "$CKPT")"
write_full_fixture "$CKPT"
OUT="$WORK/out1.md"
run build --checkpoint "$CKPT" --out "$OUT" >/dev/null; rc=$?
[ "$rc" -eq 0 ] || bad "1/2. build exited $rc, want 0"
if grep -qF "$FAKE_AWS_KEY" "$OUT"; then
  bad "1. planted fake AWS-shaped key leaked into the brief"
else
  ok "1. planted fake secret (AWS-shaped key) never appears in the brief"
fi
if grep -qi "security incident" "$OUT" || grep -qF "SECURITY-REMEDIATION" "$OUT"; then
  bad "2. planted fake security-incident language leaked into the brief"
else
  ok "2. planted fake security-incident language never appears in the brief"
fi
grep -q "credential-or-token" "$OUT" && grep -q "security-incident-keyword" "$OUT" \
  && ok "1b/2b. manifest names the scrub categories that fired (credential-or-token, security-incident-keyword)" \
  || bad "1b/2b. manifest did not name the expected scrub categories: $(grep -A2 'EXCLUDED: scrub' "$OUT")"

# ── 3. benign-but-unclassifiable section is excluded, not included ──────────
if grep -qF "$BENIGN_MARKER" "$OUT"; then
  bad "3. benign manual-zone section body leaked into the INCLUDED brief content"
else
  ok "3. benign-but-unclassifiable section body excluded from the brief"
fi
sed -n '/EXCLUDED: unclassifiable/,/EXCLUDED: budget/p' "$OUT" | grep -q "Key Context" \
  && ok "3b. manifest lists 'Key Context' under the unclassifiable/excluded group (named, not silently dropped)" \
  || bad "3b. manifest did not name 'Key Context' as excluded-unclassifiable: $(grep -A6 'EXCLUDED: unclassifiable' "$OUT")"

# ── sanity: legitimate, non-sensitive whitelisted sections DO make it in ────
grep -q "resume contract" "$OUT" \
  && ok "sanity. a clean, in-zone, whitelisted section (resume contract) is actually included" \
  || bad "sanity. resume-contract section missing entirely from a generous-budget brief"

# ── 4. size budget smaller than content: fits budget, names what was dropped ─
# TIGHT_BUDGET sits ABOVE this fixture's manifest-only floor (empirically
# ~2.9KB here: 6 non-scrubbed candidates + 2 scrub-excluded + 3 unclassified
# all listed by name costs bytes on its own) but below the full generous-
# budget size, so the normal priority-tightening loop runs and lands on a
# real subset — not the budget-too-small-for-even-the-manifest edge case
# (that is claim 5, tested separately below with a deliberately tiny budget).
OUT_SMALL="$WORK/out-small.md"
TIGHT_BUDGET=3200
run build --checkpoint "$CKPT" --budget-bytes "$TIGHT_BUDGET" --out "$OUT_SMALL" >/dev/null; rc=$?
[ "$rc" -eq 0 ] || bad "4. build under a tight budget exited $rc, want 0"
actual_size=$(wc -c <"$OUT_SMALL" | tr -d ' ')
[ "$actual_size" -le "$TIGHT_BUDGET" ] && ok "4a. brief under a $TIGHT_BUDGET-byte budget fits within budget (actual=$actual_size)" \
  || bad "4a. brief size $actual_size exceeds requested budget $TIGHT_BUDGET"
grep -q "EXCLUDED: budget" "$OUT_SMALL" \
  && ok "4b. manifest carries a budget-exclusion section" \
  || bad "4b. manifest has no budget-exclusion section: $(cat "$OUT_SMALL")"
big_out_size=$(wc -c <"$OUT" | tr -d ' ')
[ "$actual_size" -lt "$big_out_size" ] && ok "4c. tight-budget brief is materially smaller than the generous-budget brief ($actual_size < $big_out_size)" \
  || bad "4c. tight-budget brief ($actual_size) not smaller than generous one ($big_out_size)"

# ── 5. pathological budget: too small even for the manifest text alone ──────
# Never silently truncate the manifest to force a fit -- state the overshoot.
OUT_TINY="$WORK/out-tiny.md"
run build --checkpoint "$CKPT" --budget-bytes 500 --out "$OUT_TINY" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "5a. a budget too small for even the manifest -> still exits 0, never crashes" \
  || bad "5a. tiny-budget build exited $rc, want 0"
grep -qi "NOTE: actual size" "$OUT_TINY" && grep -q "requested budget of 500 bytes" "$OUT_TINY" \
  && ok "5b. tiny-budget brief honestly states it exceeds the requested budget, by how much" \
  || bad "5b. no honest overshoot note in tiny-budget brief: $(cat "$OUT_TINY")"

# ── 6. missing checkpoint: exit 0, honest empty result, no crash ────────────
OUT_MISSING="$WORK/out-missing.md"
run build --checkpoint "$WORK/does/not/exist/CHECKPOINT.md" --out "$OUT_MISSING" >/dev/null 2>"$WORK/err6.log"; rc=$?
[ "$rc" -eq 0 ] && ok "6a. missing checkpoint -> exit 0 (never-fail-caller)" \
  || bad "6a. missing checkpoint exited $rc, want 0"
[ -z "$(grep -i traceback "$WORK/err6.log" 2>/dev/null)" ] && ok "6b. missing checkpoint -> no traceback on stderr" \
  || bad "6b. traceback leaked: $(cat "$WORK/err6.log")"
grep -qi "not found" "$OUT_MISSING" && ok "6c. missing checkpoint -> brief honestly states the checkpoint was not found" \
  || bad "6c. brief did not say the checkpoint was missing: $(cat "$OUT_MISSING")"

# ── 7. garbage/unstructured checkpoint (no zone markers) -> whole file is
#      untrusted manual content; degrades honestly, never crashes ──────────
CKPT_GARBAGE="$WORK/ckpt-garbage/CHECKPOINT.md"
mkdir -p "$(dirname "$CKPT_GARBAGE")"
printf 'just some random unstructured text\nwith no headings or markers at all\n' >"$CKPT_GARBAGE"
OUT_GARBAGE="$WORK/out-garbage.md"
run build --checkpoint "$CKPT_GARBAGE" --out "$OUT_GARBAGE" >/dev/null 2>"$WORK/err7.log"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$(grep -i traceback "$WORK/err7.log" 2>/dev/null)" ] \
  && ok "7. markerless/garbage checkpoint -> exit 0, no crash (treated as untrusted manual text)" \
  || bad "7. rc=$rc err=$(cat "$WORK/err7.log")"

# ── 8. --out writes to disk; never-transmit statement is present; stdout
#      also carries the brief (not ONLY the --out file) ────────────────────
[ -s "$OUT" ] && ok "8a. --out wrote a non-empty brief to disk" || bad "8a. --out produced an empty/missing file"
grep -qi "never transmit" "$OUT" && ok "8b. brief states plainly that this tool never transmits anything itself" \
  || bad "8b. missing never-transmit statement in output"
stdout_out="$(run build --checkpoint "$CKPT")"
echo "$stdout_out" | grep -q "PORTABLE BRIEF MANIFEST" \
  && ok "8c. build also prints the brief to stdout (not silently swallowed when --out is absent)" \
  || bad "8c. stdout did not contain a manifest"

# ── 9. bad CLI usage exits 2 (usage error, not folded into never-fail) ──────
python3 "$CLI" totally-not-a-subcommand >/dev/null 2>"$WORK/err9.log"; rc=$?
[ "$rc" -eq 2 ] && ok "9. unknown subcommand -> exit 2 (usage error)" \
  || bad "9. unknown subcommand exited $rc, want 2"

# ── 10. syntax validity ──────────────────────────────────────────────────────
python3 -m py_compile "$CLI" 2>"$WORK/pyerr.log"; rc=$?
[ "$rc" -eq 0 ] && ok "10a. bin/heimdall-portable-brief is syntactically valid Python (py_compile)" \
  || bad "10a. py_compile failed: $(cat "$WORK/pyerr.log")"
bash -n "$SELF_DIR/heimdall-portable-brief.test.sh" \
  && ok "10b. this test file itself is syntactically valid bash (bash -n)" \
  || bad "10b. bash -n failed on this test file"

echo "--------------------------------------------------------------------"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
