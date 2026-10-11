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
#   6. SEVERITY SCOPE. CLAUDE.md defines the gate as "Lint clean (zero
#      warnings)", but shellcheck's own default threshold also counts info and
#      style notes, so lint_clean was stricter than the gate it feeds. The tool
#      now runs shellcheck at -S warning: a file with only an info-level finding
#      is clean, a file with a warning is not, and HMD_STOP_LINT_SEVERITY=
#      error|warning|info|style moves the bar (info/style opt in to stricter).
#      Cases 13-16 pin the argv the tool builds with a recording fake shellcheck
#      (independent of the installed version); 17-19 prove the verdicts end to
#      end with the real shellcheck, and say so loudly when it is not usable;
#      20 checks the tool and this suite pass the gate they implement.
#   7. ESLINT 9 + TOOL ERRORS. `eslint -f unix` (the unix formatter was removed
#      in ESLint 9) exits 2 for every file, and the tool counted each of those
#      as a lint finding, so a repo whose `eslint .` was clean read
#      lint_clean=false and the push gate blocked. The tool now reads `-f json`
#      (core in 8 and 9) from --output-file, and an eslint that fails to RUN
#      (config error, crash, missing interpreter) is a TOOL ERROR: reported
#      loudly, counted in the receipt's tool_errors, the run marked incomplete,
#      lint_clean left exactly as it was. Cases 21-23 use a fake ESLint 9.
#   8. SCOPE. Only files inside --repo are lint targets: `.claude/worktrees/`,
#      `.heimdall/`, `node_modules/` and anything outside the repo (a Claude
#      scratchpad, another checkout, a `..` escape) are excluded, and a session
#      whose repo IS a worktree still lints its own files. Cases 24-26.
#
# ISOLATION: edit-tracker keys its ledger on $TMPDIR/heimdall-edits/
# $CLAUDE_CODE_SESSION_ID.log. Every case here sets TMPDIR to a private temp
# dir and a unique session id, so the operator's real ledger is never read or
# written. HEIMDALL_STATE_FILE is likewise pointed at a fixture file.
# HMD_STOP_LINT_SEVERITY is unset up front so an operator running strict
# cannot change what the default-severity cases see; each case sets it itself.

set -u
unset HMD_STOP_LINT_SEVERITY

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
# Pre-arm the gate green: an INCOMPLETE run with no finding must leave it
# untouched (no evidence either way) — never upgrade, never downgrade.
HEIMDALL_STATE_FILE="$D/repo/heimdall-state.json" "$STATE" set '.quality_gates.lint_clean' true >/dev/null
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
   && ! grep -q 'Alarm clock' <<<"$err"; then
  ok "7. hung shellcheck: exit 0 in ${elapsed}s, timeout/skip reported, no bash job-notice leaked"
else
  bad "7. hung linter escaped the alarm (rc=$rc elapsed=${elapsed}s): $err"
fi
if [ "$(jq -r '.quality_gates.lint_last_run.complete | tostring' "$S")" = "false" ] \
   && [ "$(jq -r '.quality_gates.lint_last_run.timeouts // 0' "$S")" -ge 1 ] \
   && [ "$(lint_clean "$D")" = "true" ]; then
  ok "8. incomplete run: receipt complete=false, timeouts>=1, pre-armed lint_clean left UNCHANGED"
else
  bad "8. incomplete run misrecorded: $(jq -c '.quality_gates' "$S")"
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

# ── 13-16. severity contract: pin the argv the tool builds ──────────────────
# A recording fake shellcheck stands in for the real one, so these cases prove
# WHAT THE TOOL ASKS FOR with no dependence on the installed shellcheck's
# version, rc files, or rule levels.

# mk_fake_shellcheck <case-dir> → fakebin/shellcheck appends its argv to fakebin/argv.log
mk_fake_shellcheck() {
  mkdir -p "$1/fakebin"
  cat > "$1/fakebin/shellcheck" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$(dirname "$0")/argv.log"
exit 0
EOF
  chmod +x "$1/fakebin/shellcheck"
  : > "$1/fakebin/argv.log"
}

D="$(mk_case sevargv)"
S="$D/repo/heimdall-state.json"
mk_fake_shellcheck "$D"
printf '#!/usr/bin/env bash\necho a\n' > "$D/repo/a.sh"
track "$D" "$D/repo/a.sh"

rc="$(PATH="$D/fakebin:$PATH" run_lint "$D")"
if [ "$rc" = "0" ] && [ -s "$D/fakebin/argv.log" ] \
   && ! grep -qv -- '^-S warning -f gcc ' "$D/fakebin/argv.log" \
   && [ "$(jq -r '.quality_gates.lint_last_run.shellcheck_severity' "$S")" = "warning" ]; then
  ok "13. default: shellcheck runs at -S warning, receipt records shellcheck_severity=warning"
else
  bad "13. default severity wrong (rc=$rc): argv=[$(head -1 "$D/fakebin/argv.log")] receipt=$(jq -c '.quality_gates.lint_last_run' "$S")"
fi

sev_bad=""
for pair in error:error warning:warning info:info style:style INFO:info Style:style; do
  given="${pair%%:*}"; want="${pair#*:}"
  : > "$D/fakebin/argv.log"
  rc="$(HMD_STOP_LINT_SEVERITY="$given" PATH="$D/fakebin:$PATH" run_lint "$D")"
  if [ "$rc" != "0" ] || [ ! -s "$D/fakebin/argv.log" ] \
     || grep -qv -- "^-S $want -f gcc " "$D/fakebin/argv.log"; then
    sev_bad="$sev_bad $given(want $want, got '$(head -1 "$D/fakebin/argv.log")', rc=$rc)"
  fi
done
if [ -z "$sev_bad" ] && [ "$(jq -r '.quality_gates.lint_last_run.shellcheck_severity' "$S")" = "style" ]; then
  ok "14. HMD_STOP_LINT_SEVERITY error|warning|info|style (any case) → shellcheck -S <that>, receipt follows"
else
  bad "14. severity env var not honoured:$sev_bad"
fi

: > "$D/fakebin/argv.log"
rc="$(HMD_STOP_LINT_SEVERITY=loud PATH="$D/fakebin:$PATH" run_lint "$D")"
err="$(cat "$TMPROOT/err")"
if [ "$rc" = "0" ] && [ -s "$D/fakebin/argv.log" ] \
   && ! grep -qv -- '^-S warning -f gcc ' "$D/fakebin/argv.log" \
   && [ "$(grep -c "unknown HMD_STOP_LINT_SEVERITY 'loud'" <<<"$err")" = "1" ] \
   && [ "$(jq -r '.quality_gates.lint_last_run.shellcheck_severity' "$S")" = "warning" ]; then
  ok "15. unknown severity → falls back to warning, said once on stderr, exit 0"
else
  bad "15. bad severity mishandled (rc=$rc): argv=[$(head -1 "$D/fakebin/argv.log")] stderr: $err"
fi

D="$(mk_case sevempty)"
rc="$(HMD_STOP_LINT_SEVERITY=loud run_lint "$D")"
if [ "$rc" = "0" ] && [ ! -s "$TMPROOT/err" ] && [ ! -s "$TMPROOT/out" ]; then
  ok "16. unknown severity with nothing edited stays silent (case 5's contract holds)"
else
  bad "16. unknown severity broke the nothing-edited silence (rc=$rc): $(cat "$TMPROOT/err")"
fi

# ── 17-19. severity verdicts end to end, with the REAL shellcheck ───────────
# SC2086 (unquoted expansion) is info level; SC2034 (unused variable) is
# warning level. The fixtures are classified under THIS shellcheck first: a
# version, or a ~/.shellcheckrc, that moves either rule makes 17-19 prove
# nothing, so they SKIP loudly rather than pass or fail for the wrong reason.
# 13-16 above still hold the contract in that case.

# mk_sc_fixtures <dir> → info.sh (only an info finding) and warn.sh (a warning)
mk_sc_fixtures() {
  cat > "$1/info.sh" <<'EOF'
#!/usr/bin/env bash
set -u
x="$1"
echo $x
EOF
  cat > "$1/warn.sh" <<'EOF'
#!/usr/bin/env bash
set -u
unused=1
echo ok
EOF
}

SC_OK=0
SC_WHY="shellcheck not on PATH"
if command -v shellcheck >/dev/null 2>&1; then
  P="$TMPROOT/scprobe"; mkdir -p "$P"; mk_sc_fixtures "$P"
  shellcheck -S info    -f gcc "$P/info.sh" >/dev/null 2>&1; info_at_info=$?
  shellcheck -S warning -f gcc "$P/info.sh" >/dev/null 2>&1; info_at_warn=$?
  shellcheck -S warning -f gcc "$P/warn.sh" >/dev/null 2>&1; warn_at_warn=$?
  if [ "$info_at_info" -eq 1 ] && [ "$info_at_warn" -eq 0 ] && [ "$warn_at_warn" -eq 1 ]; then
    SC_OK=1
  else
    SC_WHY="fixtures classify differently here: info.sh rc=$info_at_info@info/$info_at_warn@warning, warn.sh rc=$warn_at_warn@warning"
  fi
fi

if [ "$SC_OK" -ne 1 ]; then
  echo "  SKIP 17-19: real shellcheck not usable ($SC_WHY); contract cases 13-16 still ran"
else
  D="$(mk_case sevinfo)"
  S="$D/repo/heimdall-state.json"
  mk_sc_fixtures "$D/repo"
  track "$D" "$D/repo/info.sh"
  rc="$(run_lint "$D")"
  err="$(cat "$TMPROOT/err")"
  if [ "$rc" = "0" ] && grep -q '1 file(s) checked, clean' <<<"$err" && grep -q 'shellcheck ok' <<<"$err" \
     && [ "$(lint_clean "$D")" = "true" ] \
     && [ "$(jq -r '.quality_gates.lint_last_run.findings' "$S")" = "0" ]; then
    ok "17. info-only file (SC2086) → clean at the default severity, lint_clean=true"
  else
    bad "17. info-only file wrongly counted (rc=$rc lint_clean=$(lint_clean "$D")): $err"
  fi

  D="$(mk_case sevwarn)"
  S="$D/repo/heimdall-state.json"
  mk_sc_fixtures "$D/repo"
  track "$D" "$D/repo/warn.sh"
  # Pre-arm green so the flip to false is a real transition, not the initial value.
  HEIMDALL_STATE_FILE="$S" "$STATE" set '.quality_gates.lint_clean' true >/dev/null
  rc="$(run_lint "$D")"
  err="$(cat "$TMPROOT/err")"
  if [ "$rc" = "0" ] && grep -q 'shellcheck 1' <<<"$err" && grep -q 'SC2034' <<<"$err" \
     && [ "$(lint_clean "$D")" = "false" ] \
     && [ "$(jq -r '.quality_gates.lint_last_run.findings' "$S")" -ge 1 ]; then
    ok "18. warning-level file (SC2034) → NOT clean at the default severity, lint_clean flips false"
  else
    bad "18. warning-level file not flagged (rc=$rc lint_clean=$(lint_clean "$D")): $err"
  fi

  D="$(mk_case sevinfoopt)"
  S="$D/repo/heimdall-state.json"
  mk_sc_fixtures "$D/repo"
  track "$D" "$D/repo/info.sh"
  HEIMDALL_STATE_FILE="$S" "$STATE" set '.quality_gates.lint_clean' true >/dev/null
  rc="$(HMD_STOP_LINT_SEVERITY=info run_lint "$D")"
  err="$(cat "$TMPROOT/err")"
  if [ "$rc" = "0" ] && grep -q 'shellcheck 1' <<<"$err" && grep -q 'SC2086' <<<"$err" \
     && [ "$(lint_clean "$D")" = "false" ] \
     && [ "$(jq -r '.quality_gates.lint_last_run.shellcheck_severity' "$S")" = "info" ]; then
    ok "19. HMD_STOP_LINT_SEVERITY=info → the same info-only file is NOT clean, lint_clean flips false"
  else
    bad "19. info opt-in did not tighten the gate (rc=$rc lint_clean=$(lint_clean "$D")): $err"
  fi
fi

# ── 20. the tool and its suite pass the gate they implement ─────────────────
# Self-hosting: source that reads lint_clean=false at the default severity
# turns its own gate red. Header prose is the usual way to trip it: shellcheck
# parses any comment line whose first word starts with "shellcheck" as a
# directive and reports SC1073 (an error) when the rest does not parse.
if command -v shellcheck >/dev/null 2>&1; then
  sc_out="$(shellcheck -S warning -f gcc "$LINT" "$REPO/test/heimdall-stop-lint.test.sh" 2>&1)"; sc_rc=$?
  if [ "$sc_rc" -eq 0 ]; then
    ok "20. bin/heimdall-stop-lint and its suite are clean at shellcheck -S warning"
  else
    bad "20. the tool or its suite fails its own gate (rc=$sc_rc): $sc_out"
  fi
else
  echo "  SKIP 20: shellcheck not on PATH, so the self-hosting check did not run"
fi

# ── 21-23. ESLint 9, and an eslint that cannot run is not a finding ──────────
# A fake ESLint 9 stands in for the real one: `json` is a core formatter, `unix`
# is not (it exits 2, as the real one does). It also writes Node's usual
# module-type warning to stderr on every run, so the tool must read the report
# from --output-file rather than from a stdout+stderr stream such noise corrupts.

# mk_fake_eslint <case-dir> [shebang] → fakebin/eslint, argv in fakebin/argv.log.
# FAKE_ESLINT_MODE is read at run time: clean (default) | findings | cfgerr | crash
mk_fake_eslint() {
  mkdir -p "$1/fakebin"
  printf '%s\n' "${2:-#!/bin/sh}" > "$1/fakebin/eslint"
  cat >> "$1/fakebin/eslint" <<'EOF'
printf '%s\n' "$*" >> "$(dirname "$0")/argv.log"
fmt=""; out=""; file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f) fmt="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *)  file="$1"; shift ;;
  esac
done
[ "${FAKE_ESLINT_MODE:-clean}" = silent ] && exit 1
echo "(node:1) Warning: Module type of file:///eslint.config.js is not specified" >&2
case "${FAKE_ESLINT_MODE:-clean}" in
  cfgerr) printf 'Oops! Something went wrong! :(\nESLint could not find an eslint.config file.\n' >&2; exit 2 ;;
  crash)  printf "TypeError: Cannot read properties of undefined (reading 'rules')\n" >&2; exit 1 ;;
esac
if [ "$fmt" != json ]; then
  printf 'Oops! Something went wrong! :(\nThe %s formatter is no longer part of core ESLint.\n' "$fmt" >&2
  exit 2
fi
if [ "${FAKE_ESLINT_MODE:-clean}" = findings ]; then
  report=$(printf '[{"filePath":"%s","messages":[{"ruleId":"no-undef","severity":2,"message":"x is not defined","line":1,"column":1},{"ruleId":"no-unused-vars","severity":1,"message":"y is never used","line":2,"column":5}],"errorCount":1,"warningCount":1}]' "$file")
  rc=1
else
  report=$(printf '[{"filePath":"%s","messages":[],"errorCount":0,"warningCount":0}]' "$file")
  rc=0
fi
if [ -n "$out" ]; then printf '%s\n' "$report" > "$out"; else printf '%s\n' "$report"; fi
exit "$rc"
EOF
  chmod +x "$1/fakebin/eslint"
  : > "$1/fakebin/argv.log"
}

# mk_js_case <name> [shebang] → a case with an eslint config, the fake eslint
# and a tracked a.js
mk_js_case() {
  local d; d="$(mk_case "$1")"
  printf 'export default [];\n' > "$d/repo/eslint.config.js"
  printf 'const a = 1;\nconsole.log(a);\n' > "$d/repo/a.js"
  mk_fake_eslint "$d" "${2:-}"
  track "$d" "$d/repo/a.js"
  printf '%s' "$d"
}

D="$(mk_js_case eslintclean)"
rc="$(PATH="$D/fakebin:$PATH" run_lint "$D")"
err="$(cat "$TMPROOT/err")"
if [ "$rc" = "0" ] && grep -q 'eslint ok' <<<"$err" && grep -q '1 file(s) checked, clean' <<<"$err" \
   && [ "$(lint_clean "$D")" = "true" ] \
   && grep -q -- '-f json' "$D/fakebin/argv.log" && ! grep -q -- '-f unix' "$D/fakebin/argv.log"; then
  ok "21. ESLint 9 (no unix formatter): asks for -f json, clean file → 'eslint ok', lint_clean=true"
else
  bad "21. ESLint 9 clean file misreported (rc=$rc lint_clean=$(lint_clean "$D")): argv=[$(head -1 "$D/fakebin/argv.log")] $err"
fi

D="$(mk_js_case eslintfind)"
S="$D/repo/heimdall-state.json"
HEIMDALL_STATE_FILE="$S" "$STATE" set '.quality_gates.lint_clean' true >/dev/null
rc="$(FAKE_ESLINT_MODE=findings PATH="$D/fakebin:$PATH" run_lint "$D")"
err="$(cat "$TMPROOT/err")"
if [ "$rc" = "0" ] && grep -q 'eslint 2' <<<"$err" && grep -q 'no-undef' <<<"$err" \
   && [ "$(lint_clean "$D")" = "false" ] \
   && [ "$(jq -r '.quality_gates.lint_last_run.findings' "$S")" = "2" ] \
   && [ "$(jq -r '.quality_gates.lint_last_run.tool_errors' "$S")" = "0" ]; then
  ok "22. ESLint 9 problems are counted from the JSON report (2) and listed, lint_clean flips false"
else
  bad "22. ESLint 9 findings misreported (rc=$rc lint_clean=$(lint_clean "$D")): $err"
fi

# 23. Four ways eslint fails to RUN: a config error (exit 2), a crash (exit 1
# with no report), a crash that says nothing at all (exit 1, no report, no
# output: the tool must still be loud), a missing interpreter (exit 127). None
# is a lint finding, and
# none may move lint_clean: green would be evidence nobody produced, red would
# be the phantom findings this replaces, so it is left as it was, in BOTH states.
for variant in cfgerr crash silent nointerp; do
  shebang=""; mode="$variant"; want_text="Oops! Something went wrong"
  [ "$variant" = crash ] && want_text="TypeError"
  [ "$variant" = silent ] && want_text="ESLint exited 1 without a readable JSON report"
  if [ "$variant" = nointerp ]; then
    shebang="#!/usr/bin/env hmd_no_such_node"; mode=clean; want_text="No such file or directory"
  fi
  why=""
  for arm in true false; do
    D="$(mk_js_case "eslinterr-$variant-$arm" "$shebang")"
    S="$D/repo/heimdall-state.json"
    HEIMDALL_STATE_FILE="$S" "$STATE" set '.quality_gates.lint_clean' "$arm" >/dev/null
    rc="$(FAKE_ESLINT_MODE="$mode" PATH="$D/fakebin:$PATH" run_lint "$D")"
    err="$(cat "$TMPROOT/err")"
    if [ "$rc" != "0" ] || ! grep -q 'eslint tool error' <<<"$err" || grep -q 'eslint [0-9]' <<<"$err" \
       || grep -q 'finding(s)' <<<"$err" || ! grep -q "$want_text" <<<"$err" \
       || [ "$(lint_clean "$D")" != "$arm" ] \
       || [ "$(jq -r '.quality_gates.lint_last_run.findings' "$S")" != "0" ] \
       || [ "$(jq -r '.quality_gates.lint_last_run.tool_errors' "$S")" != "1" ] \
       || [ "$(jq -r '.quality_gates.lint_last_run.complete | tostring' "$S")" != "false" ]; then
      why="$why [armed=$arm rc=$rc lint_clean=$(lint_clean "$D") receipt=$(jq -c '.quality_gates.lint_last_run' "$S") stderr: $err]"
    fi
  done
  if [ -z "$why" ]; then
    ok "23. eslint $variant → loud tool error with its own diagnostics, no findings, run incomplete, lint_clean left as armed (true and false)"
  else
    bad "23. eslint $variant mishandled:$why"
  fi
done

# ── 24-26. only the session's repo is linted ───────────────────────────────
# Stale agent worktrees (.claude/worktrees/*), the Claude scratchpad under
# $TMPDIR, node_modules, .heimdall/ and a `..` escape all sit in the edit
# ledger, none is part of what gets pushed, and linting them burned the budget.
D="$(mk_case scope)"
R="$D/repo"
S="$R/heimdall-state.json"
mkdir -p "$R/.claude/worktrees/agent-x" "$R/node_modules/pkg" "$R/.heimdall/hooks" "$D/tmp/scratchpad" "$D/outside"
for f in "$R/.claude/worktrees/agent-x/broken.sh" "$R/node_modules/pkg/broken.sh" \
         "$R/.heimdall/hooks/broken.sh" "$D/tmp/scratchpad/broken.sh" "$D/outside/broken.sh"; do
  printf '#!/usr/bin/env bash\nif [ 1 -eq 1 ]; then\n  echo unterminated\n' > "$f"
done
track "$D" "$R/.claude/worktrees/agent-x/broken.sh" "$R/node_modules/pkg/broken.sh" \
  "$R/.heimdall/hooks/broken.sh" "$D/tmp/scratchpad/broken.sh" "$R/../outside/broken.sh"
HEIMDALL_STATE_FILE="$S" "$STATE" set '.quality_gates.lint_clean' true >/dev/null
before="$(cat "$S")"
rc="$(run_lint "$D")"
after="$(cat "$S")"
if [ "$rc" = "0" ] && [ ! -s "$TMPROOT/err" ] && [ ! -s "$TMPROOT/out" ] && [ "$before" = "$after" ]; then
  ok "24. broken files only under worktrees/node_modules/.heimdall/scratchpad/outside the repo → silent, state untouched"
else
  bad "24. out-of-repo paths were linted or recorded (rc=$rc lint_clean=$(lint_clean "$D")): $(cat "$TMPROOT/err")"
fi

printf '#!/usr/bin/env bash\nset -u\necho "ok"\n' > "$R/good.sh"
track "$D" "$R/good.sh"
rc="$(PATH="$(dirname "$(command -v bash)"):$(dirname "$(command -v python3)"):$(dirname "$(command -v jq)"):/usr/bin:/bin" run_lint "$D")"
err="$(cat "$TMPROOT/err")"
if [ "$rc" = "0" ] && grep -q '1 file(s) checked, clean' <<<"$err" && ! grep -q 'broken.sh' <<<"$err" \
   && [ "$(lint_clean "$D")" = "true" ] \
   && [ "$(jq -r '.quality_gates.lint_last_run.files' "$S")" = "1" ] \
   && [ "$(jq -r '.quality_gates.lint_last_run.excluded' "$S")" = "5" ]; then
  ok "25. next to the 5 excluded paths, the in-repo file is still linted; receipt files=1 excluded=5"
else
  bad "25. in-repo file not isolated from excluded paths (rc=$rc lint_clean=$(lint_clean "$D")): $err receipt=$(jq -c '.quality_gates.lint_last_run' "$S")"
fi

D="$TMPROOT/wtself"; W="$D/main/.claude/worktrees/agent-1"
mkdir -p "$W" "$D/tmp"
printf '#!/usr/bin/env bash\nif [ 1 -eq 1 ]; then\n  echo unterminated\n' > "$W/broken.sh"
track "$D" "$W/broken.sh"
TMPDIR="$D/tmp" CLAUDE_CODE_SESSION_ID="stoplint-wtself" "$LINT" --repo "$W" 2>"$TMPROOT/err" >"$TMPROOT/out"; rc=$?
if [ "$rc" = "0" ] && grep -q 'bash -n FAIL' "$TMPROOT/err"; then
  ok "26. a session whose repo IS a worktree still lints its own files (exclusion is repo-relative)"
else
  bad "26. repo-inside-worktree files were skipped (rc=$rc): $(cat "$TMPROOT/err")"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
