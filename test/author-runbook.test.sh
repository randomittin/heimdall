#!/usr/bin/env bash
# test/author-runbook.test.sh — doc-contract test for commands/author-runbook.md
#
# WHAT THIS GATES. author-runbook.md is a prompt-doc (no bin/ script backs it),
# so there is no runtime to execute — the deterministic, scriptable surface is
# the DOC CONTRACT itself:
#   1. The command file exists and carries the frontmatter every sibling
#      command carries (name/description/argument-hint) and reads $1.
#   2. The Step 1 error-handling rule (404-only DB fallback) is present in the
#      exact shape that keeps it from silently regressing:
#        - a 404 stops (no fallback)
#        - a connection-level "unreachable" (no HTTP response) DOES fall back
#          to the datastore
#        - any OTHER HTTP error status (401/403/500/etc, i.e. NOT a 404) MUST
#          NOT fall back to the datastore — never bypass app-layer authz.
#   3. Safety: the command must stop at `gh pr create` — no auto-merge,
#      force-push, branch-delete, or `gh pr merge`.
#   4. No hardcoded secrets/tokens in the doc.
#
# EXIT: 0 = all assertions pass; 1 = any FAIL.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
DOC="$REPO/commands/author-runbook.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# ── 1. file exists + frontmatter consistent with sibling commands ────────────
if [ -f "$DOC" ]; then ok "commands/author-runbook.md exists"; else bad "commands/author-runbook.md missing"; fi

if grep -qE '^name:[[:space:]]*author-runbook[[:space:]]*$' "$DOC" 2>/dev/null; then
  ok "frontmatter name: author-runbook"
else bad "frontmatter name is not 'author-runbook'"; fi

if grep -qE '^description:' "$DOC" 2>/dev/null; then
  ok "frontmatter has description"
else bad "frontmatter missing description"; fi

if grep -qE '^argument-hint:' "$DOC" 2>/dev/null; then
  ok "frontmatter has argument-hint"
else bad "frontmatter missing argument-hint"; fi

if grep -q '\$1' "$DOC" 2>/dev/null; then
  ok "doc references \$1 (ticketId argument)"
else bad "doc never references \$1"; fi

# ── 2. 404-only DB-fallback guard (the fix under test) ────────────────────────
if grep -qE '^- A 404 means' "$DOC" 2>/dev/null; then
  ok "Step 1 names the 404 case explicitly"
else bad "Step 1 no longer names the 404 case"; fi

# 404 must state it does NOT fall back to the datastore. Prose wraps across
# lines in the doc, so collapse newlines before matching.
if tr '\n' ' ' < "$DOC" | grep -qE 'Do not fall[[:space:]]+back to the datastore for a 404'; then
  ok "404 explicitly does NOT fall back to the datastore"
else bad "404 case missing explicit no-fallback statement"; fi

# the connection-level "unreachable" case must still fall back.
if grep -qE '\*\*If the API is unreachable\*\*.*connection-level failure' "$DOC" 2>/dev/null \
   && grep -q 'fall back to reading the proposal straight from' "$DOC" 2>/dev/null; then
  ok "connection-level unreachable case falls back to the datastore"
else bad "connection-level unreachable fallback wording missing/changed"; fi

# any OTHER HTTP status (not 404) must NOT fall back — this is the actual
# regression guard: without it, 401/403/500 could ambiguously route into the
# DB fallback and bypass app-layer authz.
if grep -qE '\*\*Any other HTTP error status \(401, 403, 500, etc\.\).*NOT a 404.*must STOP' "$DOC" 2>/dev/null; then
  ok "non-404 HTTP error statuses (401/403/500/etc) named explicitly"
else bad "non-404 HTTP error statuses not named — 404-only guard may have regressed"; fi

if grep -qE 'Do NOT fall back to the datastore for these' "$DOC" 2>/dev/null; then
  ok "non-404 HTTP errors explicitly forbidden from the datastore fallback"
else bad "missing explicit 'do not fall back' guard for non-404 statuses"; fi

if grep -qE 'bypass.*authz|authz.*bypass' "$DOC" 2>/dev/null; then
  ok "doc states the rationale: never bypass app-layer authz"
else bad "doc missing authz-bypass rationale"; fi

# ── 3. safety: must stop at `gh pr create` — never merge/force-push/delete ────
if grep -q 'gh pr create' "$DOC" 2>/dev/null; then
  ok "doc drives to 'gh pr create'"
else bad "doc never reaches 'gh pr create'"; fi

if grep -qE 'gh pr merge' "$DOC" 2>/dev/null; then
  bad "doc contains 'gh pr merge' — must stop at PR creation, never auto-merge"
else ok "doc contains no 'gh pr merge' (no auto-merge)"; fi

if grep -qE 'push[[:space:]]+--force|push[[:space:]]+-f\b' "$DOC" 2>/dev/null; then
  bad "doc contains a force-push — unsafe for a drafting command"
else ok "doc contains no force-push"; fi

if grep -qE 'branch[[:space:]]+-[dD]\b|push[[:space:]].*--delete' "$DOC" 2>/dev/null; then
  bad "doc contains a branch-delete — unsafe for a drafting command"
else ok "doc contains no branch-delete"; fi

# ── 4. no hardcoded secrets/tokens ─────────────────────────────────────────────
if grep -qE 'ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}' "$DOC" 2>/dev/null; then
  bad "doc contains a value shaped like a real credential"
else ok "doc contains no hardcoded credential-shaped values"; fi

if grep -qiE 'never print or log a password or any secret' "$DOC" 2>/dev/null; then
  ok "doc explicitly instructs never to print/log secrets"
else bad "doc missing the never-print-secrets instruction"; fi

echo
echo "  author-runbook tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
