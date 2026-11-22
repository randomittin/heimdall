#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329  # SC2016: the perl programs, awk filters and python source below are literal text, $VAR must NOT expand in them. SC2329: the helpers are run by NAME through verdict, which shellcheck does not follow
# test/demo-scaffold-use-cases.test.sh
#
# `hmd demo` is the first project a newcomer sees, so the spec it scaffolds has to teach the regime hmd really gates a managed repo on
# (skills/heimdall/references/use-case-tests.md): the built app is accepted on USER JOURNEYS -- a tests/use_cases/ suite, one scenario per
# journey, through the real routes, fakes only at external boundaries -- and a .heimdall/repo-checks.json declares `lint` + `use-cases` as
# its gate. It used to teach `pytest -q` over a test_app.py of endpoint tests (docs/analysis/2026-11-22-hmd-checks-usecase-audit.md, gap 6).
# The demo writes a SPEC the agent builds from; it ships no test code of its own.
#
# Drives the REAL bin/heimdall-demo (dry mode, a throwaway dir and HEIMDALL_HOME, no TTY so no narrated arc) and pins:
#   A  the scaffold       exactly the task file and the plan seed: no tests/, no test_*.py, nothing written on the agent's behalf
#   B  the journeys       tests/use_cases/, the seven scenarios named in the user's words as given / when / then rows, the external-boundary
#                         rule, the ?done= list filter, the page contract the open-the-app scenario holds the HTML to, and NO test code
#   C  the gate           the fenced json is a declaration heimdall-repo-checks accepts (the validator `run` itself uses), names exactly lint
#                         then use-cases, the acceptance criteria and the plan seed run those same two commands, and a pytest.ini puts the
#                         repo root on the import path (building the spec in a scratch dir showed that without it `pytest tests/use_cases`,
#                         the declared command, dies on ModuleNotFoundError: app)
#   D  nothing generic    no test_app.py, no bare `pytest -q`, no coverage threshold in the task or the plan seed
#   E  the text around    the banner, --help and the suggested follow-up say use-case scenarios; the narrated arc's staged plan (the script
#                         source: that arc needs a TTY and a live scanner) no longer names test_app.py
#   F  the suite can go RED: one-line breaks of a COPY of bin/heimdall-demo, each caught by the assertion it targets
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="$REPO/bin/heimdall-demo"
LIBDIR="$REPO/bin/lib"
TAB=$'\t'
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
finish() { printf '\n  demo-scaffold-use-cases: %d passed, %d failed (%d s)\n' "$PASS" "$FAIL" "$SECONDS"; [ "$FAIL" -eq 0 ]; exit $?; }

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT

echo "demo-scaffold-use-cases"

[ -f "$DEMO" ] || { bad "0. bin/heimdall-demo is missing"; finish; }
# the real interpreter first: a version-manager shim (pyenv) costs ~0.4 s a call, and the validator runs once per scaffold graded here
PY="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
[ -x "$PY" ] || { bad "0. python3 is required (the declaration is graded with the repo-checks validator)"; finish; }
[ -f "$LIBDIR/hmd_repo_receipt.py" ] || { bad "0. bin/lib/hmd_repo_receipt.py is missing (the validator heimdall-repo-checks run uses)"; finish; }

# ── helpers ───────────────────────────────────────────────────────────────────────────────────────────────────────────
has()      { [ -n "$2" ] && grep -qF -- "$2" "$1"; }          # has <file> <fixed text>; empty text never matches
lacks()    { [ -f "$1" ] && ! grep -qF -- "$2" "$1"; }         # lacks <file> <fixed text>; a file that is not there lacks nothing worth saying
lacks2()   { [ -f "$1" ] && [ -f "$2" ] && ! grep -qF -- "$3" "$1" "$2"; }   # lacks2 <file> <file> <fixed text>
has_re()   { grep -qE -- "$2" "$1"; }                          # has_re <file> <extended regex>
has_all()  { local f="$1" t; shift; for t in "$@"; do has "$f" "$t" || return 1; done; }
section() {  # section <file> <heading prefix>: the lines under "## <prefix>..." up to the next "## "
  awk -v h="## $2" 'index($0, h) == 1 { f = 1; next } /^## / { f = 0 } f' "$1"
}
section_has() { [ -n "$3" ] && section "$1" "$2" | grep -qF -- "$3"; }    # section_has <file> <heading prefix> <fixed text>
row_ok() {  # row_ok <file> <scenario>: a row of the scenario table with four non-empty cells (scenario, given, when, then)
  section "$1" "Use-case scenarios" \
    | awk -F'|' -v n="\`$2\`" 'index($2, n) && NF == 6 && $3 ~ /[^ ]/ && $4 ~ /[^ ]/ && $5 ~ /[^ ]/ { f = 1 } END { exit !f }'
}
one_json_block() { [ "$(grep -c '^```json$' "$1")" = 1 ]; }
ships_no_test_code() { [ -f "$1" ] && [ -f "$2" ] && ! grep -qE '(^|[[:space:]])def test_|^[[:space:]]*assert[[:space:]]|@pytest' "$1" "$2"; }
scaffolded() { [ "$1" = 0 ] && [ -f "$2" ] && [ -f "$3" ]; }   # scaffolded <exit code> <task file> <plan file>
banner_ok() { has "$1" 'use-case scenarios' && lacks "$1" '+ pytest +'; }
pythonpath_ok() { section_has "$1" "Files to create" 'pytest.ini' && has "$1" 'pythonpath = .'; }

# the fenced json block of the task as heimdall-repo-checks reads it: its validator's verdict, then one check=<name>=<cmd> line per check
declaration_report() {  # declaration_report <task file>
  awk '/^```json$/ { f = 1; next } /^```$/ { f = 0 } f' "$1" | "$PY" -I -S -c '
import json
import sys

sys.path.insert(0, sys.argv[1])
import hmd_repo_receipt as rr

try:
    declaration = json.loads(sys.stdin.read())
except ValueError as exc:
    print("problem=not json: %s" % exc)
    sys.exit(0)
print("problem=%s" % rr.declaration_problem(declaration))
checks = declaration.get("checks") if isinstance(declaration, dict) else None
for check in checks if isinstance(checks, list) else []:
    if isinstance(check, dict):
        print("check=%s=%s" % (check.get("name"), check.get("cmd")))
' "$LIBDIR"
}

# ── the check: scaffold with a demo script, grade what it wrote and printed ────────────────────────────────────────────
RESULTS=""   # one "PASS<TAB>label" / "FAIL<TAB>label" line per assertion of the last check_scaffold run
verdict() {  # verdict <label> <command...>: the command's exit status is the verdict
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then RESULTS="${RESULTS}PASS${TAB}${label}"$'\n'; else RESULTS="${RESULTS}FAIL${TAB}${label}"$'\n'; fi
}

check_scaffold() {  # check_scaffold <demo script> <scaffold dir>  -> RESULTS
  local script="$1" dir="$2" task plan out help rc rep problem names uc lint listing name
  RESULTS=""
  rm -rf "$dir"
  HEIMDALL_HOME="$WORK/home" HEIMDALL_NO_INTRO=1 bash "$script" "$dir" --no-intro </dev/null >"$dir.raw" 2>"$dir.err"
  rc=$?
  task="$dir/.heimdall-demo-task.md"
  plan="$dir/.planning/PLAN.md"
  out="$dir.out"
  help="$dir.help"
  LC_ALL=C sed $'s/\033\\[[0-9;]*[a-zA-Z]//g' "$dir.raw" >"$out"
  bash "$script" --help 2>&1 </dev/null | LC_ALL=C sed $'s/\033\\[[0-9;]*[a-zA-Z]//g' >"$help"
  rep="$(declaration_report "$task")"
  problem="$(printf '%s\n' "$rep" | sed -n 's/^problem=//p')"
  names="$(printf '%s\n' "$rep" | sed -n 's/^check=\([^=]*\)=.*/\1/p' | paste -sd, -)"
  uc="$(printf '%s\n' "$rep" | sed -n 's/^check=use-cases=//p')"
  lint="$(printf '%s\n' "$rep" | sed -n 's/^check=lint=//p')"
  listing="$(cd "$dir" 2>/dev/null && find . -type f | LC_ALL=C sort | paste -sd, -)"

  verdict "A1 the scaffold exits 0 and writes the task file and the plan seed" scaffolded "$rc" "$task" "$plan"
  verdict "A2 it writes nothing else: no tests/, no test file, no declaration (the spec is what the agent builds from)" test "$listing" = "./.heimdall-demo-task.md,./.planning/PLAN.md"

  verdict "B1 the acceptance suite lives in tests/use_cases/" has "$task" 'tests/use_cases/'
  for name in test_open_the_app test_create_a_todo test_complete_a_todo test_filter_the_list test_delete_a_todo test_blank_title_creates_nothing test_unknown_todo_is_not_found; do
    verdict "B2 scenario $name is a given / when / then row" row_ok "$task" "$name"
  done
  verdict "B3 the scenario table is headed Scenario / Given / When / Then" has_re "$task" '^\| Scenario \| Given \| When \| Then \|'
  verdict "B4 fakes only at external boundaries is stated" has "$task" 'external boundaries'
  verdict "B5 the API contract has the list filter (?done=true, ?done=false)" has_all "$task" '?done=true' '?done=false'
  verdict "B6 the page contract names the controls the open-the-app scenario holds the HTML to" has_all "$task" 'id="todo-list"' 'id="new-todo"' 'id="add-todo"' 'data-filter'
  verdict "B7 the task and the plan seed ship no test code (no def test_, no assert, no @pytest)" ships_no_test_code "$task" "$plan"

  verdict "C1 exactly one fenced json block holds the declaration" one_json_block "$task"
  verdict "C2 the declaration is accepted by heimdall-repo-checks' own validator (declaration_problem)" test "$problem" = None
  verdict "C3 the declaration names exactly lint, then use-cases" test "$names" = lint,use-cases
  verdict "C4 an acceptance criterion runs the declared use-cases command" section_has "$task" "Acceptance criteria" "$uc"
  verdict "C5 an acceptance criterion runs the declared lint command" section_has "$task" "Acceptance criteria" "$lint"
  verdict "C6 the declaration is one of the files to create" section_has "$task" "Files to create" '.heimdall/repo-checks.json'
  verdict "C7 the plan seed runs the declared use-cases command" has "$plan" "$uc"
  verdict "C8 pytest.ini (pythonpath = .) is a file to create, so the declared use-cases command can import app.py" pythonpath_ok "$task"

  verdict "D1 neither the task nor the plan seed names test_app.py" lacks2 "$task" "$plan" 'test_app.py'
  verdict "D2 neither teaches a bare 'pytest -q' acceptance" lacks2 "$task" "$plan" 'pytest -q'
  verdict "D3 neither sets a coverage threshold" lacks2 "$task" "$plan" '--cov'

  verdict "E1 the banner says use-case scenarios, not pytest" banner_ok "$out"
  verdict "E2 the suggested follow-up names tests/use_cases" has "$out" 'tests/use_cases'
  verdict "E2b the suggested follow-up does not ask for the whole suite" lacks "$out" 'whole suite'
  verdict "E3 --help says use-case scenarios" has "$help" 'use-case scenarios'
  verdict "E4 the narrated arc's staged plan (the script source) names no test_app.py" lacks "$script" 'test_app.py'
}

# ── 1. the real script ─────────────────────────────────────────────────────────────────────────────────────────────────
echo "-- 1. the scaffold bin/heimdall-demo writes, graded --"
check_scaffold "$DEMO" "$WORK/app"
while IFS="$TAB" read -r status label; do
  [ -n "$status" ] || continue
  if [ "$status" = PASS ]; then ok "$label"; else bad "$label"; fi
done <<EOF
$RESULTS
EOF
if [ "$FAIL" -gt 0 ]; then
  echo "       (what the demo printed, first 40 lines, and its stderr:)"
  head -n 40 "$WORK/app.out" | sed 's/^/       | /'
  sed 's/^/       ! /' "$WORK/app.err"
fi

# ── 2. the suite can go RED ──────────────────────────────────────────────────────────────────────────────────────────
echo "-- 2. the suite can go RED: a one-line break of a copy of bin/heimdall-demo is caught by the assertion it targets --"
mutate() {  # mutate <name> <perl -pe program> <label prefix that must turn FAIL> <what the break is>
  local name="$1" prog="$2" want="$3" what="$4" copy="$WORK/mut-$1/bin/heimdall-demo"
  mkdir -p "$WORK/mut-$name/bin"
  if ! perl -pe "$prog" "$DEMO" >"$copy" 2>/dev/null || [ ! -s "$copy" ]; then bad "mutant $name: its perl program failed (a broken mutation proves nothing): $what"; return; fi
  chmod +x "$copy"
  if cmp -s "$DEMO" "$copy"; then bad "mutant $name changed nothing (its pattern no longer matches bin/heimdall-demo): $what"; return; fi
  check_scaffold "$copy" "$WORK/mut-$name/app"
  # the mutant must still be a WORKING demo that is wrong in one respect: a script that no longer scaffolds at all would turn every assertion red and "catch" anything
  if ! printf '%s' "$RESULTS" | grep -qF "PASS${TAB}A1"; then bad "mutant $name no longer scaffolds at all (a broken demo proves nothing): $what"; return; fi
  if printf '%s' "$RESULTS" | grep -qF "FAIL${TAB}${want}"; then ok "mutant $name: $what -> RED on '$want'"; else bad "mutant $name survives: $what" "no FAIL line starting '$want'"; fi
}
mutate generic-acceptance 's/^(\d+\. `)pytest tests\/use_cases -q`/${1}pytest -q`/' 'C4 an acceptance criterion runs the declared use-cases' \
  "the acceptance criterion is a bare pytest -q again"
mutate test-app-is-back 's/^(3\. )`tests\/use_cases\/test_todo_journeys\.py`/${1}`test_app.py`/' 'D1 neither the task nor the plan seed names test_app.py' \
  "the scenario file is test_app.py again"
mutate schema-2 's/\{"schema":1,/{"schema":2,/' 'C2 the declaration is accepted' \
  "the declaration says schema 2 (the validator refuses it)"
mutate duplicate-check-name 's/"name":"use-cases"/"name":"lint"/' 'C3 the declaration names exactly lint, then use-cases' \
  "the use-cases check is renamed lint (names must be unique)"
mutate use-cases-cmd-drift 's/"cmd":"pytest tests\/use_cases -q"/"cmd":"pytest tests\/use_cases -q --maxfail=1"/' 'C4 an acceptance criterion runs the declared use-cases' \
  "the declared use-cases command drifts from the acceptance criterion"
mutate lint-cmd-drift 's/"cmd":"ruff check \."/"cmd":"ruff check . --select ALL"/' 'C5 an acceptance criterion runs the declared lint' \
  "the declared lint command drifts from the acceptance criterion"
mutate pytest-ini-dropped '$_ = "" if /^6\. `pytest\.ini`/' 'C8 pytest.ini' \
  "pytest.ini is no longer a file to create (the declared command would die on ModuleNotFoundError: app)"
mutate scenario-dropped '$_ = "" if /^\| `test_filter_the_list` \|/' 'B2 scenario test_filter_the_list' \
  "the list-filter journey has no scenario row"
mutate test-code-shipped 's/^(## Out of scope.*)$/def test_x(client):\n    assert client.get("\/api\/todos").json() == []\n\n$1/' 'B7 the task and the plan seed ship no test code' \
  "a hand-written test body is in the spec"
mutate scaffold-ships-tests 's/^(mkdir -p "\$TARGET_DIR\/\.planning")$/$1\nmkdir -p "\$TARGET_DIR\/tests\/use_cases" \&\& : > "\$TARGET_DIR\/tests\/use_cases\/test_todo_journeys.py"/' 'A2 it writes nothing else' \
  "the scaffold drops an empty test file into the project"
mutate banner-generic 's/frontend \+ use-case scenarios \+ README/frontend + pytest + README/g' 'E1 the banner says use-case scenarios' \
  "the banner says pytest again"
mutate usage-generic 's/^  \+ use-case scenarios \+ README\) to/  + tests + README) to/' 'E3 --help says use-case scenarios' \
  "--help says tests again"
mutate followup-generic 's/Write its scenario in tests\/use_cases first, then prove lint and use-cases are still green\./Add tests and prove the whole suite is still green./' 'E2 the suggested follow-up names tests/use_cases' \
  "the suggested follow-up asks for the whole suite again"
mutate narrated-plan-old 's/<name>test_todo_journeys\.py<\/name>/<name>test_app.py<\/name>/' 'E4 the narrated arc' \
  "the narrated arc stages a test_app.py task again"

finish
