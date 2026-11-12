#!/usr/bin/env bash
#
# skills-baseline-golden.test.sh -- 3.x M1, T1.2: the committed golden of what the LEGACY skill selection does.
#
# Plan: docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md ("Parity test design", INV-S3). The skill resolver (T2.1) is proven by a differential test
# against test/fixtures/skills-baseline/golden.json: what the UNMODIFIED legacy code answered for every case of test/fixtures/skills-baseline/inputs.json,
# written by test/lib/skills_baseline_record.sh (T0.1) and committed BEFORE the resolver exists (T2.1 asserts that order with git). This suite keeps the
# golden honest from then on:
#   A. the golden is there, is a well-formed recording that names the grep it was made with, answers exactly the cases of inputs.json (a matrix edit
#      that skipped the re-recording is caught), and the matrix holds no input with ''' (see below)
#   B. recording the legacy tree again gives the committed answers, case for case: the golden is reproducible, and the legacy selection code has not
#      moved. When the grep here is not the flavour and major version the golden was recorded with, B is SKIPPED -- loudly, with the reason, and counted
#      as neither a pass nor a fail (BSD and GNU grep differ in what an ERE matches; plan risk R6). Only grep decides this: the python3 and uname lines
#      of the header are provenance, not a condition.
#   C. every check above can go RED: each runs against a doctored copy of the golden or the matrix and must object, and the skip rule is exercised both
#      ways (a minor release of the same grep is compared, another major or flavour is skipped). B's own report is run on doctored goldens too: the same
#      answers count as a pass, another grep as a skip, a moved answer as a fail -- so "skipped, not passed" is proven on the machine that never skips.
#
# NO input may hold ''': discover_skills (bin/heimdall) puts the prompt inside a python ''' literal, so a prompt with ''' ends the literal (a SyntaxError,
# or code of the prompt's choosing). What the legacy code did with it is a defect, not a baseline, and the fix that passes the prompt as data would move it.
#
# Re-recording the golden changes what "legacy" means: do it only on purpose, as its own reviewed commit, on a tree whose legacy files are untouched:
#   git diff --quiet HEAD -- bin heimdall-skills.json skills-registry.json && bash test/lib/skills_baseline_record.sh record test/fixtures/skills-baseline/golden.json
# budget: 30 -- ~10-12 s solo: the full matrix (389 cases) is recorded once (9.9 s wall for the recorder alone), and every case runs the real legacy shell
# code (tens of process spawns each, the receipt writer alone is ~30). The recorder already runs its cases in parallel; the matrix cannot shrink without
# dropping tokens the plan requires.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
REC="$REPO/test/lib/skills_baseline_record.sh"
INPUTS="$REPO/test/fixtures/skills-baseline/inputs.json"
GOLDEN="$REPO/test/fixtures/skills-baseline/golden.json"
PASS=0; FAIL=0; SKIPPED=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }
finish() {
  echo "--------------------------------------------------------------------"
  if [ "$SKIPPED" -gt 0 ]; then
    printf 'skills-baseline-golden: %d passed, %d failed (%d SKIPPED, see above: a skip is not a pass)\n' "$PASS" "$FAIL" "$SKIPPED"
  else
    printf 'skills-baseline-golden: %d passed, %d failed\n' "$PASS" "$FAIL"
  fi
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
WORK="$(mktemp -d)" || { echo "FATAL: cannot make a temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# ── the assertions that are easier in python: one program, one subcommand per check ──
cat > "$WORK/check.py" <<'PYEOF'
"""check.py -- the assertions of skills-baseline-golden.test.sh that are easier in python than in bash.

    check.py structure GOLDEN         the golden is a schema-1 recording whose header names the grep it was made with
    check.py coverage INPUTS GOLDEN   GOLDEN answers every case of INPUTS, in order, and nothing else
    check.py triple INPUTS            no input of the matrix holds ''' (the end of the python literal discover_skills puts a prompt in)
    check.py compare GOLDEN FRESH     a new recording against GOLDEN: exit 0 the same answers, 1 answers moved, 3 not comparable on this grep
    check.py selftest INPUTS GOLDEN   each check above goes RED on a doctored copy, and compare is exercised all three ways
    check.py doctor KIND GOLDEN OUT   write a doctored copy of GOLDEN for the shell's own checks: KIND flavour (made with the other grep) or moved
Every check prints one problem per line and exits 1 when there is one.
"""
import copy
import json
import re
import sys

MISSING = object()


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def grep_key(line):
    """The grep a recording was made with, as far as it matters: its flavour and major version. BSD and GNU grep, and two majors of one of them,
    can differ in what an ERE matches, so their answers are not comparable; a minor or patch release is the same grep. None: a line this rule
    cannot place (ugrep, busybox, no version), which is never comparable with anything."""
    if not isinstance(line, str):
        return None
    flavour = "BSD" if "BSD" in line else "GNU" if "GNU" in line else None
    major = re.search(r"(\d+)\.\d+", line)
    return (flavour, int(major.group(1))) if flavour and major else None


def structure_problems(golden):
    if not isinstance(golden, dict) or golden.get("schema") != 1:
        return ["the golden is not a recording: want an object with schema 1"]
    problems = []
    header = golden.get("header")
    if not isinstance(header, dict):
        problems.append("no header")
    else:
        for key in ("grep", "python3", "uname"):
            if not isinstance(header.get(key), str) or not header[key].strip():
                problems.append("header.%s is empty" % key)
        if isinstance(header.get("grep"), str) and header["grep"].strip() and grep_key(header["grep"]) is None:
            problems.append("header.grep %r names neither BSD nor GNU grep with a version, so no machine could tell whether it has the grep "
                            "this was recorded with" % header["grep"])
    cases = golden.get("cases")
    if not isinstance(cases, dict) or not cases or not all(isinstance(rows, dict) and rows for rows in cases.values()):
        problems.append("cases must be a non-empty object of category -> non-empty object of case id -> answer")
    return problems


def coverage_problems(inputs, golden):
    answered = golden.get("cases") if isinstance(golden, dict) else None
    if not isinstance(answered, dict):
        return ["the golden has no cases object"]
    asked = {category: [row["id"] for row in rows] for category, rows in inputs["cases"].items()}
    problems = []
    for category in sorted(set(asked) | set(answered)):
        want = asked.get(category, [])
        got = list(answered[category]) if isinstance(answered.get(category), dict) else []
        if want != got:
            missing = [case for case in want if case not in got]
            extra = [case for case in got if case not in want]
            problems.append("%s: the golden's cases differ from the matrix (missing %s, extra %s, only the order differs: %s)"
                            % (category, missing[:3], extra[:3], not missing and not extra))
    return problems


def strings(value):
    """Every string inside a parsed JSON value, object keys included."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def triple_problems(inputs):
    return ["%s/%s: an input holds ''' (%r)" % (category, row.get("id"), text[:48])
            for category, rows in inputs["cases"].items() for row in rows for text in strings(row) if "'''" in text]


def moved(golden, fresh):
    """Every recorded answer that differs between two recordings, as category/case; a case present in one recording only counts."""
    out = []
    for category in sorted(set(golden["cases"]) | set(fresh["cases"])):
        one, two = golden["cases"].get(category, {}), fresh["cases"].get(category, {})
        out.extend("%s/%s" % (category, case) for case in sorted(set(one) | set(two))
                   if one.get(case, MISSING) != two.get(case, MISSING))
    return out


def compare(golden, fresh):
    """(verdict, lines): 'skip' when the two were not made with the same grep, 'moved' when an answer differs, else 'same'."""
    want, got = grep_key(golden["header"]["grep"]), grep_key(fresh["header"]["grep"])
    if want is None or got is None or want != got:
        return "skip", ["the legacy code ran on grep %r here and the golden was recorded on grep %r: BSD and GNU grep differ in what a pattern "
                        "matches, so answers are only compared on the same flavour and major version"
                        % (fresh["header"]["grep"], golden["header"]["grep"])]
    changed = moved(golden, fresh)
    if changed:
        return "moved", ["%d of %d recorded answers moved (first: %s): the legacy selection code changed, or the matrix or the recorder did"
                         % (len(changed), sum(len(rows) for rows in golden["cases"].values()), ", ".join(changed[:5]))]
    return "same", ["%d cases in %d categories answer exactly as committed"
                    % (sum(len(rows) for rows in fresh["cases"].values()), len(fresh["cases"]))]


def grep_line(flavour, major):
    """A `grep --version` first line of the given flavour and major version, with a minor release no machine has."""
    return "grep (BSD grep, GNU compatible) %d.99.0-FreeBSD" % major if flavour == "BSD" else "grep (GNU grep) %d.99" % major


def selftest(inputs, golden):
    """Each check must object to a doctored copy, and compare must be able to say 'same' as well as 'moved' and 'skip'."""
    failures = []
    category = next(iter(golden["cases"]))
    case = next(iter(golden["cases"][category]))
    flavour, major = grep_key(golden["header"]["grep"])

    def edited(base, edit):
        clone = copy.deepcopy(base)
        edit(clone)
        return clone

    def swap(clone):
        items = list(clone["cases"][category].items())
        items[0], items[1] = items[1], items[0]
        clone["cases"][category] = dict(items)

    def must_object(name, problems):
        if not problems:
            failures.append("%s did not object to its doctored input" % name)

    def verdict(name, fresh, want, names=()):
        got, lines = compare(golden, fresh)
        if got != want:
            failures.append("compare (%s): wanted %s, got %s" % (name, want, got))
        for word in names:
            if not any(word in line for line in lines):
                failures.append("compare (%s): the report does not name %s" % (name, word))

    must_object("structure (blank grep line)", structure_problems(edited(golden, lambda g: g["header"].update(grep=" "))))
    must_object("structure (a grep that is neither BSD nor GNU)", structure_problems(edited(golden, lambda g: g["header"].update(grep="ugrep 7.8.4"))))
    must_object("structure (no header)", structure_problems(edited(golden, lambda g: g.pop("header"))))
    must_object("structure (schema 2)", structure_problems(edited(golden, lambda g: g.update(schema=2))))
    must_object("structure (no cases)", structure_problems(edited(golden, lambda g: g.update(cases={}))))

    must_object("coverage (a case left out)", coverage_problems(inputs, edited(golden, lambda g: g["cases"][category].pop(case))))
    must_object("coverage (a case invented)", coverage_problems(inputs, edited(golden, lambda g: g["cases"][category].update({"invented-case": []}))))
    must_object("coverage (a category left out)", coverage_problems(inputs, edited(golden, lambda g: g["cases"].pop(category))))
    must_object("coverage (two cases swapped)", coverage_problems(inputs, edited(golden, swap)))

    must_object("triple (a prompt)", triple_problems(edited(inputs, lambda m: m["cases"]["keyword_match"][0].update(prompt="x ''' y"))))
    must_object("triple (a file body)", triple_problems(edited(inputs, lambda m: m["cases"]["activate"].append({"id": "t", "files": {"f": "'''"}}))))

    verdict("the same recording", copy.deepcopy(golden), "same")
    verdict("another python and another machine", edited(golden, lambda g: g["header"].update(python3="Python 0.0.0", uname="Plan9 vax")), "same")
    verdict("a minor release of the same grep", edited(golden, lambda g: g["header"].update(grep=grep_line(flavour, major))), "same")
    verdict("an answer moved", edited(golden, lambda g: g["cases"][category].update({case: ["__doctored__"]})), "moved", [category + "/" + case])
    verdict("a case missing", edited(golden, lambda g: g["cases"][category].pop(case)), "moved", [category + "/" + case])
    verdict("a case invented", edited(golden, lambda g: g["cases"][category].update({"invented-case": []})), "moved", [category + "/invented-case"])
    verdict("another major of the same grep", edited(golden, lambda g: g["header"].update(grep=grep_line(flavour, major + 1))), "skip")
    verdict("the other flavour of grep", edited(golden, lambda g: g["header"].update(grep=grep_line("GNU" if flavour == "BSD" else "BSD", major))), "skip")
    verdict("a grep that cannot be placed", edited(golden, lambda g: g["header"].update(grep="ugrep 7.8.4")), "skip", ["ugrep 7.8.4"])
    return failures


def doctor(kind, source, target):
    """A doctored copy of a recording, for the shell to prove its own exit-code and skip accounting: 'flavour' says it was made with the other
    flavour of grep, 'moved' changes the first answer."""
    golden = load(source)
    if kind == "flavour":
        flavour, major = grep_key(golden["header"]["grep"])
        golden["header"]["grep"] = grep_line("GNU" if flavour == "BSD" else "BSD", major)
    else:
        category = next(iter(golden["cases"]))
        golden["cases"][category][next(iter(golden["cases"][category]))] = ["__doctored__"]
    with open(target, "w", encoding="utf-8") as handle:
        json.dump(golden, handle)


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    try:
        if mode == "structure" and len(argv) == 3:
            problems = structure_problems(load(argv[2]))
        elif mode == "coverage" and len(argv) == 4:
            problems = coverage_problems(load(argv[2]), load(argv[3]))
        elif mode == "triple" and len(argv) == 3:
            problems = triple_problems(load(argv[2]))
        elif mode == "compare" and len(argv) == 4:
            verdict, lines = compare(load(argv[2]), load(argv[3]))
            print("\n".join(lines))
            return {"same": 0, "moved": 1, "skip": 3}[verdict]
        elif mode == "selftest" and len(argv) == 4:
            problems = selftest(load(argv[2]), load(argv[3]))
        elif mode == "doctor" and len(argv) == 5 and argv[2] in ("flavour", "moved"):
            doctor(argv[2], argv[3], argv[4])
            problems = []
        else:
            sys.stderr.write(__doc__)
            return 2
    except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError) as exc:
        print("check.py %s: cannot check a malformed file: %s: %s" % (mode, type(exc).__name__, exc))
        return 1
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PYEOF
chk() { "$PY" -I "$WORK/check.py" "$@"; }

# compare_report <golden> <recording>: the B row for one comparison. PASS when every answer is as committed, SKIP (never a pass) when this machine's grep is
# not the one the golden was made with, FAIL when an answer moved or the comparison could not be made. check.py compare says which by its exit code (0 / 3 / 1).
compare_report() {
  local out rc
  out="$(chk compare "$1" "$2" 2>&1)"; rc=$?
  case "$rc" in
    0) ok "B: recording the legacy tree again gives the committed golden: $out" ;;
    3) skip "B: not compared -- $out" ;;
    *) bad "B: the legacy selection no longer answers what the golden says: $(printf '%s' "$out" | head -3 | tr '\n' ';') Re-record only on purpose (see the header of this file)" ;;
  esac
}

echo "skills-baseline-golden -- the committed golden of what the legacy skill selection does (3.x M1, T1.2)"

# ╔═ A. the golden is there, well formed, and answers exactly the matrix; the matrix holds no ''' ═╗
MISSING=0
if [ -s "$GOLDEN" ]; then ok "A: test/fixtures/skills-baseline/golden.json exists and is not empty"
else bad "A: test/fixtures/skills-baseline/golden.json is missing or empty"; MISSING=1; fi
if [ -f "$INPUTS" ] && [ -x "$REC" ]; then ok "A: the matrix (inputs.json) and the recorder (T0.1) are there"
else bad "A: test/fixtures/skills-baseline/inputs.json or test/lib/skills_baseline_record.sh is missing"; MISSING=1; fi
if [ "$MISSING" -ne 0 ]; then
  echo "  nothing further can run without the golden, its matrix and the recorder"
  finish
fi

GOLDEN_OK=1
if OUT="$(chk structure "$GOLDEN" 2>&1)"; then ok "A: the golden is a schema-1 recording whose header names the grep (BSD or GNU, with a version), python3 and uname it was made with"
else bad "A: the golden is malformed: $(printf '%s' "$OUT" | head -3 | tr '\n' ';')"; GOLDEN_OK=0; fi
if OUT="$(chk coverage "$INPUTS" "$GOLDEN" 2>&1)"; then ok "A: the golden answers every case of inputs.json, in order, and nothing else"
else bad "A: the golden and the matrix disagree: $(printf '%s' "$OUT" | head -3 | tr '\n' ';')"; GOLDEN_OK=0; fi
if OUT="$(chk triple "$INPUTS" 2>&1)"; then ok "A: no input of the matrix holds ''' (discover_skills would read it as the end of its python literal)"
else bad "A: the matrix holds an input the legacy python literal cannot carry: $(printf '%s' "$OUT" | head -3 | tr '\n' ';')"; GOLDEN_OK=0; fi
if [ "$GOLDEN_OK" -ne 1 ]; then
  echo "  nothing further can run against a malformed golden or matrix"
  finish
fi

# ╔═ B. the legacy tree, recorded again, gives the committed answers (on the grep the golden was made with) ═╗
bash "$REC" record "$WORK/fresh.json" >"$WORK/record.log" 2>&1; RC=$?
if [ "$RC" -ne 0 ]; then
  bad "B: the recorder could not record the legacy tree (exit $RC): $(tail -3 "$WORK/record.log" | tr '\n' ' ')"
else
  compare_report "$GOLDEN" "$WORK/fresh.json"
fi

# ╔═ C. every check above goes RED on a doctored copy, and the skip rule works both ways ═════════════════╗
if OUT="$(chk selftest "$INPUTS" "$GOLDEN" 2>&1)"; then
  ok "C: structure, coverage, ''' and comparison checks each object to a doctored copy; the same grep is compared, another major or flavour is skipped"
else
  bad "C: a check cannot go red: $(printf '%s' "$OUT" | head -4 | tr '\n' ';')"
fi

# the report itself, run on doctored goldens against the real one (no second recording): what B would print and count on a machine whose grep differs,
# and when an answer moved. tally runs compare_report in a subshell with fresh counters, so the real ones stay as they are.
tally() { ( PASS=0; FAIL=0; SKIPPED=0; compare_report "$1" "$2" >/dev/null; echo "$PASS/$FAIL/$SKIPPED" ); }
if chk doctor flavour "$GOLDEN" "$WORK/other-grep.json" && chk doctor moved "$GOLDEN" "$WORK/moved.json"; then
  T_SAME="$(tally "$GOLDEN" "$GOLDEN")"; T_SKIP="$(tally "$WORK/other-grep.json" "$GOLDEN")"; T_MOVED="$(tally "$WORK/moved.json" "$GOLDEN")"
  if [ "$T_SAME" = "1/0/0" ] && [ "$T_SKIP" = "0/0/1" ] && [ "$T_MOVED" = "0/1/0" ]; then
    ok "C: the same answers count as a pass, another grep as a skip (neither a pass nor a fail), a moved answer as a fail"
  else
    bad "C: B's report is wrong (passed/failed/skipped): same answers $T_SAME (want 1/0/0), another grep $T_SKIP (want 0/0/1), a moved answer $T_MOVED (want 0/1/0)"
  fi
else
  bad "C: could not doctor a copy of the golden"
fi

finish
