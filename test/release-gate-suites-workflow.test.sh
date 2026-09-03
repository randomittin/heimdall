#!/usr/bin/env bash
#
# release-gate-suites-workflow.test.sh — acceptance for
# .github/workflows/release-gate-suites.yml, the CI workflow that runs the release-gate
# suite subset on GitHub's own infrastructure (see that file's header for the full WHY). A
# workflow file is easy to get subtly wrong in ways `git commit --no-verify` will never
# catch locally: a filter regex that silently drops a suite, a `continue-on-error: true`
# that turns a red suite into a green checkmark, a mutable tag pin instead of a SHA. This
# suite catches exactly those failure modes, and PROVE-REDs each one against a mutated
# throwaway copy of the real file so a "the check always passes" regression cannot hide.
#
#   bash test/release-gate-suites-workflow.test.sh    (exit 0 = all cases pass)
#
# THE PROPERTIES, each planted with a fixture a regression flips:
#   · the workflow file exists and is syntactically valid YAML                     (case 1)
#   · no `continue-on-error: true` anywhere — a red suite must fail the job        (case 2)
#   · the job carries a `timeout-minutes:` backstop                               (case 3)
#   · every `uses:` action reference is pinned to a full 40-hex commit SHA, never
#     a mutable tag (`@v4`, `@main`)                                              (case 4)
#   · the SAME actions/checkout SHA as the sibling public-repo-no-secrets.yml — no
#     second, unvetted pin introduced for the identical action                    (case 5)
#   · triggers on both `push` and `pull_request`                                  (case 6)
#   · `permissions:` is the least-privilege `contents: read`                      (case 7)
#   · the run step actually invokes test/run-all.sh (not a decorative comment)    (case 8)
#   · the embedded --filter regex, applied with test/run-all.sh's OWN matching
#     semantics (grep -qE against the full absolute path — see run-all.sh:224),
#     selects EXACTLY the intended 14 gate suites: no more, no less              (case 9)
#   · PROVE-RED: a mutated copy of the workflow flips cases 1-5 and 9 to FAIL,
#     proving these are real checks and not tautologies                         (case 10)
#
# No repo state is mutated: every mutant is a throwaway copy under a temp dir; the real
# workflow file is only ever read, never written.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
WORKFLOW="$REPO/.github/workflows/release-gate-suites.yml"
SIBLING="$REPO/.github/workflows/public-repo-no-secrets.yml"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -f "$SIBLING" ] || { echo "FATAL: $SIBLING not found — house-style baseline workflow missing"; exit 2; }

echo "release-gate-suites-workflow.test.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-gate-workflow-test.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# Expected set of 14 gate suites the workflow MUST run — named explicitly, independent of
# the workflow's own regex. This is the oracle case 9 checks the live regex against; deriving
# it FROM the regex under test would make that case tautological (it would always agree with
# itself).
EXPECTED_SUITES=(
  caveman-hook-wire.test.sh
  caveman-plugin-retire.test.sh
  edit-hook-matcher.test.sh
  gate-echo-parser-guard.test.sh
  gate-receipt-truth.test.sh
  git-guard-routing.test.sh
  git-guard-worktree.test.sh
  heimdall-429-detect.test.sh
  heimdall-caveman.test.sh
  heimdall-git-guard-selfheal.test.sh
  heimdall-git-guard.test.sh
  heimdall-run-receipt.test.sh
  sessionstart-ledger-clear-gate.test.sh
  sweep-receipt-gate.test.sh
)
EXPECTED_SORTED="$(printf '%s\n' "${EXPECTED_SUITES[@]}" | sort)"

# ── helper checks — each takes a FILE PATH, so the same function runs against the real
#    workflow (expect: pass) or a mutated throwaway copy (expect: flip to fail) ───────────

is_valid_yaml() {
  python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$1" >/dev/null 2>&1
}

has_continue_on_error_true() {
  grep -qE 'continue-on-error:[[:space:]]*true' "$1"
}

has_timeout_minutes() {
  grep -qE 'timeout-minutes:[[:space:]]*[0-9]+' "$1"
}

# every `uses: owner/repo@REF` must have REF = 40 hex chars (a commit SHA), never a bare tag.
all_actions_sha_pinned() {
  local f="$1" line ref
  while IFS= read -r line; do
    ref="$(sed -E 's/^[[:space:]]*uses:[[:space:]]*[^@]+@([^[:space:]]+).*/\1/' <<<"$line")"
    [[ "$ref" =~ ^[0-9a-f]{40}$ ]] || return 1
  done < <(grep -E '^[[:space:]]*uses:' "$f")
  return 0
}

extract_checkout_sha() {
  grep -E 'uses:[[:space:]]*actions/checkout@' "$1" | head -1 \
    | sed -E 's/.*actions\/checkout@([0-9a-f]+).*/\1/'
}

extract_filter_regex() {
  grep -oE "'/[^']*'" "$1" | head -1 | sed "s/^'//; s/'\$//"
}

# Replicates run-all.sh:224's OWN matching semantics exactly: grep -qE "$FILTER" against
# each FULL ABSOLUTE PATH from the "$REPO"/test/*.test.sh glob — not a relative path or a
# bare filename. A leading "/" in the filter regex only means what it looks like it means
# if matched the same way run-all.sh matches it.
suites_matched_by_filter() {
  local filter="$1" s
  for s in "$REPO"/test/*.test.sh; do
    [ -f "$s" ] || continue
    printf '%s\n' "$s" | grep -qE "$filter" && basename "$s"
  done
}

# ── 1. workflow file exists and is valid YAML ─────────────────────────────────────────────
if [ -f "$WORKFLOW" ]; then ok "workflow file exists at .github/workflows/release-gate-suites.yml"
else bad "workflow file MISSING at .github/workflows/release-gate-suites.yml"; fi

if is_valid_yaml "$WORKFLOW"; then ok "workflow file is syntactically valid YAML (python3 yaml.safe_load)"
else bad "workflow file FAILED to parse as YAML"; fi

# ── 2. no continue-on-error: true anywhere (a red suite must fail the job) ────────────────
if has_continue_on_error_true "$WORKFLOW"; then bad "workflow sets continue-on-error: true — a red suite would NOT fail the job"
else ok "workflow has no continue-on-error: true (a red suite fails the job)"; fi

# ── 3. job carries a timeout-minutes: backstop ────────────────────────────────────────────
if has_timeout_minutes "$WORKFLOW"; then ok "workflow job sets timeout-minutes: (hard backstop against a wedged runner)"
else bad "workflow job has NO timeout-minutes: — a wedged runner could hang indefinitely"; fi

# ── 4. every uses: action is pinned to a full 40-hex commit SHA, never a mutable tag ──────
if all_actions_sha_pinned "$WORKFLOW"; then ok "every 'uses:' action reference is pinned to a full 40-hex commit SHA"
else bad "at least one 'uses:' action reference is NOT SHA-pinned (mutable tag risk)"; fi

# ── 5. same actions/checkout SHA as the sibling public-repo-no-secrets.yml ────────────────
mine_sha="$(extract_checkout_sha "$WORKFLOW")"
sibling_sha="$(extract_checkout_sha "$SIBLING")"
if [ -n "$mine_sha" ] && [ "$mine_sha" = "$sibling_sha" ]; then
  ok "actions/checkout is pinned to the SAME vetted SHA as public-repo-no-secrets.yml ($mine_sha)"
else
  bad "actions/checkout SHA diverges from the sibling workflow's vetted pin (mine=$mine_sha sibling=$sibling_sha)"
fi

# ── 6. triggers on both push and pull_request ─────────────────────────────────────────────
if grep -qE '^[[:space:]]*push:[[:space:]]*$' "$WORKFLOW" && grep -qE '^[[:space:]]*pull_request:[[:space:]]*$' "$WORKFLOW"; then
  ok "workflow triggers on both push and pull_request"
else
  bad "workflow does NOT trigger on both push and pull_request"
fi

# ── 7. permissions: is least-privilege contents: read ─────────────────────────────────────
if grep -qE '^[[:space:]]*permissions:[[:space:]]*$' "$WORKFLOW" && grep -qE '^[[:space:]]*contents:[[:space:]]*read[[:space:]]*$' "$WORKFLOW"; then
  ok "workflow sets least-privilege permissions: contents: read"
else
  bad "workflow does NOT set permissions: contents: read"
fi

# ── 8. the run step actually invokes test/run-all.sh (not a decorative comment) ───────────
if grep -vE '^[[:space:]]*#' "$WORKFLOW" | grep -qE 'bash[[:space:]]+test/run-all\.sh'; then
  ok "workflow's run step actually invokes 'bash test/run-all.sh' (outside comments)"
else
  bad "workflow does NOT invoke test/run-all.sh outside of comments"
fi

# ── 9. the embedded --filter regex selects EXACTLY the intended 14 suites ────────────────
FILTER_REGEX="$(extract_filter_regex "$WORKFLOW")"
if [ -z "$FILTER_REGEX" ]; then
  bad "could not extract a --filter regex from the workflow file at all"
else
  ACTUAL_SUITES="$(suites_matched_by_filter "$FILTER_REGEX" | sort)"
  if [ "$ACTUAL_SUITES" = "$EXPECTED_SORTED" ]; then
    ok "workflow's --filter regex selects EXACTLY the intended 14 gate suites (no more, no less)"
  else
    bad "workflow's --filter regex does NOT select exactly the intended 14 suites -- $(diff <(printf '%s\n' "$EXPECTED_SORTED") <(printf '%s\n' "$ACTUAL_SUITES") | tr '\n' ' ')"
  fi
fi

# ── 10. PROVE-RED: mutated throwaway copies flip cases 1-5 and 9 to FAIL ─────────────────
# Each mutant is a full copy of the REAL file (or, for the filter case, a hand-truncated
# regex) with exactly one property broken, proving the corresponding case above is a real,
# falsifiable check rather than a tautology that would pass against anything.

echo "  -- PROVE-RED: mutated copies must flip the corresponding check to FAIL --"

# 10a. YAML corruption (tab indent + unterminated flow sequence) must break the parser.
m_yaml="$WORK/mutant-yaml.yml"
{ cat "$WORKFLOW"; printf '\tbroken: [unterminated\n'; } > "$m_yaml"
if is_valid_yaml "$m_yaml"; then bad "PROVE-RED: corrupted-YAML mutant still parsed as valid (case 1 is not falsifiable)"
else ok "PROVE-RED: corrupted-YAML mutant is correctly rejected (case 1 is falsifiable)"; fi

# 10b. inject continue-on-error: true (plain append — the detector is a flat grep, so this
# is a faithful mutation of the exact property it checks).
m_coe="$WORK/mutant-continue-on-error.yml"
{ cat "$WORKFLOW"; printf '          continue-on-error: true\n'; } > "$m_coe"
if has_continue_on_error_true "$m_coe"; then ok "PROVE-RED: continue-on-error mutant is detected (case 2 is falsifiable)"
else bad "PROVE-RED: continue-on-error mutant was NOT detected (case 2 is not falsifiable)"; fi

# 10c. remove the timeout-minutes: line entirely.
m_to="$WORK/mutant-no-timeout.yml"
grep -v 'timeout-minutes:' "$WORKFLOW" > "$m_to"
if has_timeout_minutes "$m_to"; then bad "PROVE-RED: timeout-minutes-removed mutant still detected as present (case 3 is not falsifiable)"
else ok "PROVE-RED: timeout-minutes-removed mutant is detected (case 3 is falsifiable)"; fi

# 10d. replace the checkout SHA with a mutable tag (@v4) — must fail the sha-pin check.
m_tag="$WORK/mutant-tag-pin.yml"
sed -E 's/actions\/checkout@[0-9a-f]{40}/actions\/checkout@v4/' "$WORKFLOW" > "$m_tag"
if all_actions_sha_pinned "$m_tag"; then bad "PROVE-RED: tag-pin mutant still passes as SHA-pinned (case 4 is not falsifiable)"
else ok "PROVE-RED: tag-pin mutant is detected as NOT sha-pinned (case 4 is falsifiable)"; fi

# 10e. replace the checkout SHA with a DIFFERENT (fake) 40-hex SHA — stays sha-shaped (case 4
# would still pass) but must now diverge from the sibling's pin (case 5 specifically).
m_div="$WORK/mutant-sha-divergence.yml"
sed -E 's/actions\/checkout@[0-9a-f]{40}/actions\/checkout@0000000000000000000000000000000000000000/' "$WORKFLOW" > "$m_div"
div_sha="$(extract_checkout_sha "$m_div")"
if [ -n "$div_sha" ] && [ "$div_sha" = "$sibling_sha" ]; then
  bad "PROVE-RED: sha-divergence mutant still matches the sibling's SHA (case 5 is not falsifiable)"
else
  ok "PROVE-RED: sha-divergence mutant is detected as diverging from the sibling (case 5 is falsifiable)"
fi
if all_actions_sha_pinned "$m_div"; then
  ok "  (control) the divergence mutant still passes case 4's any-valid-sha check — confirms cases 4 and 5 are independent, not duplicates"
else
  bad "  (control) the divergence mutant unexpectedly failed case 4 too — cases 4/5 are not independent"
fi

# 10f. drop one alternative from the filter regex — must under-match (miss a suite).
TRUNCATED_REGEX="${FILTER_REGEX/|sweep-receipt-gate/}"
if [ "$TRUNCATED_REGEX" = "$FILTER_REGEX" ]; then
  bad "PROVE-RED: could not construct a truncated filter regex to mutate (unexpected regex shape)"
else
  TRUNC_ACTUAL="$(suites_matched_by_filter "$TRUNCATED_REGEX" | sort)"
  if [ "$TRUNC_ACTUAL" = "$EXPECTED_SORTED" ]; then
    bad "PROVE-RED: truncated filter regex still matches all 14 suites (case 9 is not falsifiable)"
  else
    ok "PROVE-RED: truncated filter regex now misses a suite — diverges from expected (case 9 is falsifiable)"
  fi
fi

echo
printf 'release-gate-suites-workflow: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
