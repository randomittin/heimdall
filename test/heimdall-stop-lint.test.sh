#!/usr/bin/env bash
# test/heimdall-stop-lint.test.sh
#
# Proof for bin/heimdall-stop-lint — the Stop-hook consumer of `edit-tracker
# paths` that runs the repo's REAL linters over this session's edited files and
# writes the result into heimdall-state, so `.quality_gates.lint_clean` reflects
# a run rather than a hand flip (gap-analysis 2026-09-19, ranked item #2).
#
# Asserted head-on:
#   1. A broken .sh and a broken .py are REPORTED (per-file line on stderr) and
#      flip lint_clean to false with a receipt in lint_last_run.
#   2. Clean files → clean summary, lint_clean true.
#   3. Nothing edited → exit 0, no output at all.
#   4. A hung linter on PATH cannot hang Stop: exits 0 inside the budget, and
#      the receipt says complete=false rather than lying green.
#   5. Every path exits 0 — it is advisory, never a gate.
#
# ISOLATION: edit-tracker keys its ledger on $TMPDIR/heimdall-edits/
# $CLAUDE_CODE_SESSION_ID.log. Every case here sets TMPDIR to a private temp
# dir and a unique session id, so the operator's real ledger is never read or
# written. HEIMDALL_STATE_FILE is likewise pointed at a fixture file.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$REPO/bin/heimdall-stop-lint"
TRACKER="$REPO/bin/edit-tracker"
STATE="$REPO/bin/heimdall-state"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

echo "heimdall-stop-lint"

if [ ! -x "$TRACKER" ]; then
  echo "  SKIP: bin/edit-tracker not built (clang -O2 -o bin/edit-tracker bin/edit-tracker.c)"
  exit 0
fi

# mk_case <name> → creates $TMPROOT/<name>/{repo,tmp} with an initialised
# heimdall-state.json; echoes the case dir.
mk_case() {
  local d="$TMPROOT/$1"
  mkdir -p "$d/repo" "$d/tmp"
  ( cd "$d/repo" && HEIMDALL_STATE_FILE="$d/repo/heimdall-state.json" "$STATE" init >/dev/null 2>&1 )
  printf '%s' "$d"
}

# track <case> <file...> → log Write edits into the case's private ledger
track() {
  local d="$1"; shift
  local f
  for f in "$@"; do
    TMPDIR="$d/tmp" CLAUDE_CODE_SESSION_ID="stoplint-$(basename "$d")" "$TRACKER" log Write "$f" >/dev/null 2>&1
  done
}

# run_lint <case> [args...] → rc; stderr in $TMPROOT/err, stdout in $TMPROOT/out
run_lint() {
  local d="$1"; shift
  TMPDIR="$d/tmp" CLAUDE_CODE_SESSION_ID="stoplint-$(basename "$d")" \
    HEIMDALL_STATE_FILE="$d/repo/heimdall-state.json" \
    "$LINT" --repo "$d/repo" "$@" 2>"$TMPROOT/err" 1>"$TMPROOT/out"
  printf '%s' "$?"
}

lint_clean() { jq -r '.quality_gates.lint_clean' "$1/repo/heimdall-state.json"; }

# ── 1. shell syntax error is reported, gate flips false ─────────────────────
D="$(mk_case shbroken)"
printf '#!/usr/bin/env bash\nif [ 1 -eq 1 ]; then\n  echo unterminated\n' > "$D/repo/broken.sh"
track "$D" "$D/repo/broken.sh"
rc="$(run_lint "$D")"
err="$(cat "$TMPROOT/err")"
if [ "$rc" = "0" ] && grep -q 'broken.sh' <<<"$err" && grep -q 'bash -n FAIL' <<<"$err" \
   && [ "$(lint_clean "$D")" = "false" ]; then
  ok "1. broken .sh reported via bash -n, exit 0, lint_clean=false"
else
  bad "1. broken .sh not reported (rc=$rc lint_clean=$(lint_clean "$D")): $err"
fi

# ── 2. the receipt records a real run ───────────────────────────────────────
S="$D/repo/heimdall-state.json"
if [ "$(jq -r '.quality_gates.lint_last_run.findings' "$S")" -ge 1 ] \
   && [ "$(jq -r '.quality_gates.lint_last_run.checked' "$S")" = "1" ] \
   && [ "$(jq -r '.quality_gates.lint_last_run.complete' "$S")" = "true" ] \
   && jq -e '.quality_gates.lint_last_run.tools | index("bash -n")' "$S" >/dev/null \
   && [ "$(jq -r '.quality_gates.tests_passing' "$S")" = "false" ] \
   && jq -e '.project and .plan and .maintainer' "$S" >/dev/null; then
  ok "2. lint_last_run receipt written (findings>=1, checked=1, tools has bash -n); rest of schema intact"
else
  bad "2. receipt missing or schema damaged: $(jq -c '.quality_gates' "$S")"
fi

# ── 3. python syntax error is reported ──────────────────────────────────────
D="$(mk_case pybroken)"
printf 'def f(:\n    return 1\n' > "$D/repo/broken.py"
track "$D" "$D/repo/broken.py"
rc="$(run_lint "$D")"
err="$(cat "$TMPROOT/err")"
if [ "$rc" = "0" ] && grep -q 'broken.py' <<<"$err" && grep -q 'ast FAIL' <<<"$err" \
   && [ "$(lint_clean "$D")" = "false" ]; then
  ok "3. broken .py reported via ast.parse, exit 0, lint_clean=false"
else
  bad "3. broken .py not reported (rc=$rc): $err"
fi

# ── 4. clean files → clean summary, lint_clean true ─────────────────────────
D="$(mk_case clean)"
printf '#!/usr/bin/env bash\nset -u\necho "ok"\n' > "$D/repo/good.sh"
printf 'def f():\n    return 1\n' > "$D/repo/good.py"
track "$D" "$D/repo/good.sh" "$D/repo/good.py"
# Isolate PATH so an operator's shellcheck/ruff style opinions cannot make a
# syntactically clean fixture "dirty" — this case proves the clean path only.
rc="$(PATH="$(dirname "$(command -v bash)"):$(dirname "$(command -v python3)"):$(dirname "$(command -v jq)"):/usr/bin:/bin" run_lint "$D")"
err="$(cat "$TMPROOT/err")"
if [ "$rc" = "0" ] && grep -q '2 file(s) checked, clean' <<<"$err" \
   && [ "$(lint_clean "$D")" = "true" ]; then
  ok "4. clean .sh + .py → 'clean' summary, lint_clean=true"
else
  bad "4. clean files misreported (rc=$rc lint_clean=$(lint_clean "$D")): $err"
fi

# ── 5. nothing edited → exit 0, totally silent, state untouched ─────────────
D="$(mk_case empty)"
before="$(cat "$D/repo/heimdall-state.json")"
rc="$(run_lint "$D")"
after="$(cat "$D/repo/heimdall-state.json")"
if [ "$rc" = "0" ] && [ ! -s "$TMPROOT/err" ] && [ ! -s "$TMPROOT/out" ] && [ "$before" = "$after" ]; then
  ok "5. no edited paths → exit 0, no output, state byte-identical"
else
  bad "5. empty ledger produced output or mutated state (rc=$rc)"
fi

# ── 6. edited-then-deleted paths are ignored, not errors ────────────────────
D="$(mk_case deleted)"
track "$D" "$D/repo/gone.sh"
rc="$(run_lint "$D")"
if [ "$rc" = "0" ] && [ ! -s "$TMPROOT/err" ]; then
  ok "6. a tracked path that no longer exists is skipped silently"
else
  bad "6. missing file produced output or non-zero (rc=$rc): $(cat "$TMPROOT/err")"
fi

# ── 7. a hung linter on PATH cannot hang Stop ───────────────────────────────
# Fake shellcheck that sleeps far past the budget. With --budget 3 the tool
# must return well inside 15s (per-call alarm = min(per-call, remaining)),
# exit 0, and the receipt must NOT claim a complete clean run.
D="$(mk_case slow)"
mkdir -p "$D/fakebin"
cat > "$D/fakebin/shellcheck" <<'EOF'
#!/bin/sh
sleep 60
EOF
chmod +x "$D/fakebin/shellcheck"
printf '#!/usr/bin/env bash\necho a\n' > "$D/repo/a.sh"
printf '#!/usr/bin/env bash\necho b\n' > "$D/repo/b.sh"
track "$D" "$D/repo/a.sh" "$D/repo/b.sh"
t0=$(date +%s)
rc="$(PATH="$D/fakebin:$PATH" run_lint "$D" --budget 3 --per-call 2)"
t1=$(date +%s)
elapsed=$((t1 - t0))
err="$(cat "$TMPROOT/err")"
S="$D/repo/heimdall-state.json"
if [ "$rc" = "0" ] && [ "$elapsed" -le 15 ] && grep -q 'timed out\|skipped (budget)' <<<"$err" \
   && [ "$(lint_clean "$D")" = "false" ]; then
  ok "7. hung shellcheck: exit 0 in ${elapsed}s, timeout/skip reported, lint_clean stays false"
else
  bad "7. hung linter escaped the alarm (rc=$rc elapsed=${elapsed}s lint_clean=$(lint_clean "$D")): $err"
fi
if [ "$(jq -r '.quality_gates.lint_last_run.complete // "missing"' "$S")" != "true" ] \
   || [ "$(lint_clean "$D")" != "true" ]; then
  ok "8. a budget-cut run never records lint_clean=true with complete=true"
else
  bad "8. incomplete run was recorded as a complete clean pass"
fi

# ── 9. no state file → still runs, reports, exits 0, creates nothing ───────
D="$TMPROOT/nostate"; mkdir -p "$D/repo" "$D/tmp"
printf 'def f(:\n' > "$D/repo/x.py"
track "$D" "$D/repo/x.py"
TMPDIR="$D/tmp" CLAUDE_CODE_SESSION_ID="stoplint-nostate" "$LINT" --repo "$D/repo" 2>"$TMPROOT/err" >"$TMPROOT/out"; rc=$?
if [ "$rc" = "0" ] && grep -q 'ast FAIL' "$TMPROOT/err" && [ ! -f "$D/repo/heimdall-state.json" ]; then
  ok "9. without heimdall-state.json it still reports and does not create one"
else
  bad "9. no-state path failed (rc=$rc, state created: $([ -f "$D/repo/heimdall-state.json" ] && echo yes || echo no))"
fi

# ── 10. js/ts with no linter installed → one stderr notice, exit 0 ─────────
D="$(mk_case nojs)"
printf 'const x: number = "s";\n' > "$D/repo/t.ts"
track "$D" "$D/repo/t.ts"
rc="$(PATH="/usr/bin:/bin" run_lint "$D")"
err="$(cat "$TMPROOT/err")"
if [ "$rc" = "0" ] && grep -q 'no js/ts linter found' <<<"$err" && [ "$(grep -c 'no js/ts linter' <<<"$err")" = "1" ]; then
  ok "10. js/ts edits with no biome/eslint/tsc → said once on stderr, exit 0"
else
  bad "10. no-linter notice missing or repeated (rc=$rc): $err"
fi

# ── 11. --quiet suppresses the report but still records ────────────────────
D="$(mk_case quiet)"
printf 'def f(:\n' > "$D/repo/q.py"
track "$D" "$D/repo/q.py"
rc="$(run_lint "$D" --quiet)"
if [ "$rc" = "0" ] && [ ! -s "$TMPROOT/err" ] && [ "$(lint_clean "$D")" = "false" ]; then
  ok "11. --quiet prints nothing yet lint_clean still reflects the run"
else
  bad "11. --quiet leaked output or skipped recording (rc=$rc)"
fi

# ── 12. the tool's own source passes its own shell checks ──────────────────
if bash -n "$LINT" 2>/dev/null; then
  ok "12. bin/heimdall-stop-lint parses under bash -n"
else
  bad "12. bin/heimdall-stop-lint has a syntax error"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
