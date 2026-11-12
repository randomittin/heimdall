#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2012  # `cond && ok || bad` is this repo's reporting idiom (ok never fails); ls -A only counts the entries of two canary directories
#
# skills-baseline-determinism.test.sh -- 3.x M1, T0.1: the recorder of what the LEGACY skill selection does.
#
# Plan: docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md ("Parity test design"). The 3.x skill registry replaces three hand-written
# selection mechanisms with one manifest and a resolver. "The resolver matches the old behaviour" is only worth something if the old behaviour was
# written down by something that is neither the resolver nor the manifest. test/lib/skills_baseline_record.sh is that something: it runs the
# UNMODIFIED legacy code (preinstall_plugins and discover_skills out of bin/heimdall, bin/skill-manager status, needed_plugins of
# bin/lib/skill_restore.py, bin/discover-skills detect | detect-file | gaps) over test/fixtures/skills-baseline/inputs.json and writes what it did.
# This suite proves the recorder is a sound reference BEFORE anything is committed as golden (T1.2):
#   A. the matrix is there, holds >= 150 cases, and exercises every token the legacy code can match on, read from the legacy source at test time
#      (every alternation token of the 8 prompt rules, every keyword of skills-registry.json, every file pattern of heimdall-skills.json, ...)
#   B. bad usage and a bad matrix are refused loudly: a typo'd key must never silently shrink the baseline
#   C. two recordings of one tree are byte-identical, answer exactly the cases asked, carry the tool versions, leak no path or time, and touch
#      neither the operator's HOME nor HEIMDALL_HOME (the legacy code installs things; the recorder runs it only inside throwaway sandboxes)
#   D. the plan's quirk probes hold: "build" selects frontend-design (the substring "ui"), a prompt that hits a prompt rule AND a file rule yields
#      frontend-design twice, rules fire in code order and not in prompt order, the installed check is an unanchored substring
#   E. the recorder really RUNS the legacy code: one rule of each of the four legacy readers is broken in a copy of the tree, and exactly the case
#      that exercises it changes (a recorder that replayed canned answers would not move)
#   F. every check above can go RED: each runs against a doctored input or recording and must object
# budget: 60 -- ~30 s solo: the full matrix (389 cases) is recorded twice, and every case runs the real legacy shell code (tens of process spawns each, the
# receipt writer alone is ~30). The matrix cannot shrink without dropping tokens the plan requires; the recorder already runs its cases in parallel.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
REC="$REPO/test/lib/skills_baseline_record.sh"
INPUTS="$REPO/test/fixtures/skills-baseline/inputs.json"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
finish() {
  echo "--------------------------------------------------------------------"
  printf 'skills-baseline-determinism: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# python3 straight to the real interpreter first on PATH: a version-manager shim (pyenv) costs ~0.4 s a call, and this suite starts the recorder a dozen times
PYREAL="$("$PY" -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
mkdir -p "$WORK/pybin"
if [ -n "$PYREAL" ] && [ -x "$PYREAL" ]; then
  ln -s "$PYREAL" "$WORK/pybin/python3"
  PY="$WORK/pybin/python3"
  export PATH="$WORK/pybin:$PATH"
fi

# ── the assertions that are easier in python: one program, one subcommand per check ──
cat > "$WORK/check.py" <<'PYEOF'
"""check.py -- the assertions of skills-baseline-determinism.test.sh that are easier in python than in bash.

    check.py matrix INPUTS                         the input matrix is well formed and holds >= 150 cases
    check.py legacy REPO INPUTS                    every token the legacy code can match on has a case that exercises it
    check.py coverage INPUTS GOLDEN                GOLDEN answers every case of INPUTS, and nothing else
    check.py header GOLDEN                         the tool versions the recording was made with
    check.py clean GOLDEN TMPBASE                  nothing machine- or time-specific leaked into the recording
    check.py known GOLDEN                          the known answers: the plan's quirk probes and the code order of the 8 rules
    check.py selftest REPO INPUTS GOLDEN TMPBASE   each check above goes RED on a doctored copy
    check.py changed A B                           the cases whose recorded answer differs between two recordings
Every check prints one problem per line and exits 1 when there is one.
"""
import copy
import fnmatch
import json
import re
import sys

MIN_CASES = 150
OFFICIAL = "@claude-plugins-official"
CODE_ORDER = [name + OFFICIAL for name in ("frontend-design", "devops-toolkit", "database-toolkit", "seo",
                                            "security-scanner", "api-design", "slack", "mcp-server-dev")]
FD = CODE_ORDER[0]
PERMANENT = ["caveman@caveman", "superpowers@claude-plugins-official"]
# (category, case id, field or None, expected, what it proves): exact answers the plan itself states
KNOWN = [
    ("preinstall", "pre-quirk-build", None, [FD], "the substring ui fires on build"),
    ("preinstall", "pre-dup-react-pkg", None, [FD, FD], "a prompt rule and a file rule both fire: frontend-design twice"),
    ("preinstall", "pre-multi-all8", None, CODE_ORDER, "eight rules fire in code order"),
    ("preinstall", "pre-multi-all8-reversed", None, CODE_ORDER, "code order, not prompt order"),
    ("preinstall", "pre-dup-file-after-prompt", None, [CODE_ORDER[5], CODE_ORDER[1]], "file rules come after every prompt rule"),
    ("preinstall", "pre-neg-hello", None, [], "a plain prompt selects nothing"),
    ("preinstall", "pre-file-dockerfile", None, [CODE_ORDER[1]], "A || B && C is (A || B) && C: a Dockerfile alone selects devops-toolkit"),
    ("preinstall_installed", "pre-inst-substring-slack", None, [], "the installed check is an unanchored substring"),
    ("preinstall_installed", "pre-inst-substring-miss", None, [CODE_ORDER[5]], "...but only of the whole plugin name"),
    ("keyword_match", "kw-edge-tokenizer", None, [], "the keyword matcher is word-bounded: tokenizer is not token"),
    ("keyword_match", "kw-edge-build-guide", None, [], "...unlike the prompt rules: build and guide select nothing here"),
    ("keyword_match", "kw-edge-registry-order", None,
     ["ui-ux-pro-max|nextlevelbuilder/ui-ux-pro-max-skill", "oh-my-mermaid|oh-my-mermaid/oh-my-mermaid",
      "claude-obsidian|AgriciDaniel/claude-obsidian", "claude-seo|AgriciDaniel/claude-seo", "get-shit-done|gsd-build/get-shit-done"],
     "matches come out in registry order, not prompt order"),
    ("activate", "act-empty", "needed", PERMANENT, "an empty project needs only the permanent pair"),
]
CONTAINS = [
    ("discover_gaps", "gaps-all-installed", "stdout", "All registry skills installed!"),
    ("discover_detect_file", "file-ext-tsx", "stdout", "Domain detected: design"),
    ("discover_detect_file", "file-missing", "rc", 1),
]
LEAKS = [re.compile(r"/(tmp|var/folders|private)/"), re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d"), re.compile(r"skills-baseline")]


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def function_text(source, name):
    """One top-level shell function: from `name() {` to the first `}` in column 0 (what the recorder extracts too)."""
    found = re.search(r"^%s\(\) \{\n.*?^\}\n" % re.escape(name), source, re.S | re.M)
    if not found:
        raise SystemExit("no function %s in the legacy source" % name)
    return found.group(0)


def matrix_problems(inputs):
    cases = inputs.get("cases")
    if not isinstance(cases, dict):
        return ["cases is not an object"]
    problems = []
    total = sum(len(rows) for rows in cases.values())
    if total < MIN_CASES:
        problems.append("%d cases, the plan asks for at least %d" % (total, MIN_CASES))
    for category in ("preinstall", "preinstall_installed", "keyword_match", "activate", "discover_detect",
                     "discover_detect_file", "discover_gaps"):
        if not cases.get(category):
            problems.append("no %s cases" % category)
    for category, rows in cases.items():
        ids = [row.get("id") for row in rows]
        if len(set(ids)) != len(ids):
            problems.append("%s: duplicate case ids" % category)
    return problems


def legacy_problems(repo, inputs):
    """Every token the legacy code can match on is read from the legacy SOURCE (never from a copy of it) and must have a case."""
    cases = inputs["cases"]
    problems = []

    pre = cases.get("preinstall", [])
    launcher = function_text(read(repo + "/bin/heimdall"), "preinstall_plugins")
    rules = re.findall(r"grep -qE '([^']+)' && _try_install \"([^\"]+)\"", launcher)
    if len(rules) != 8:
        problems.append("preinstall_plugins: expected 8 prompt rules, found %d" % len(rules))
    for ere, plugin in rules:
        for token in ere.split("|"):
            if not any(re.fullmatch(token, row["prompt"].lower()) for row in pre):
                problems.append("preinstall: no case whose whole prompt is the token %r of the %s rule" % (token, plugin))
    for name in sorted(set(re.findall(r"\$WORK_DIR/([A-Za-z0-9_./-]+)", launcher))):
        if not any(name in row.get("files", {}) for row in pre):
            problems.append("preinstall: no case with the project file %s" % name)
    words = re.search(r'grep -q "([^"]+)" "\$WORK_DIR/package.json"', launcher)
    for word in (words.group(1).split("\\|") if words else []):
        if not any(word in row.get("files", {}).get("package.json", "") for row in pre):
            problems.append("preinstall: no package.json that holds %r" % word)

    registry = load(repo + "/skills-registry.json")
    prompts = {row["prompt"].lower() for row in cases.get("keyword_match", [])}
    for skill in registry["skills"]:
        for keyword in skill["keywords"]:
            if keyword not in prompts:
                problems.append("keyword_match: no case whose whole prompt is the keyword %r of %s" % (keyword, skill["name"]))

    config = load(repo + "/heimdall-skills.json")
    paths = [path for row in cases.get("activate", []) for path in row.get("files", {})]
    for rule, spec in config["detection"].items():
        for pattern in spec["files"]:
            if not any(fnmatch.fnmatchcase(path, pattern) and path.count("/") == pattern.count("/") for path in paths):
                problems.append("activate: no top-level file for the pattern %r of the %s rule" % (pattern, rule))
        for prefix in ("pkg/", "pkg/deep/", "src/", "src/a/b/"):
            if not any(path.startswith(prefix) and fnmatch.fnmatchcase(path[len(prefix):], pattern)
                       for path in paths for pattern in spec["files"]):
                problems.append("activate: the %s rule has no file placed under %s" % (rule, prefix))
    if sum(1 for row in cases.get("activate", []) if "settings" in row) < 3:
        problems.append("activate: fewer than 3 cases with a settings.json (enabledPlugins states)")

    script = read(repo + "/bin/discover-skills")
    detect = cases.get("discover_detect_file", [])
    ext_arms = re.findall(r"^\s+([a-z|]+)\)\s+echo", function_text(script, "ext_to_domain"), re.M)
    for ext in [ext for arm in ext_arms for ext in arm.split("|")]:
        if not any(row["path"].endswith("." + ext) for row in detect):
            problems.append("discover_detect_file: no file with the extension .%s" % ext)
    for pattern in re.findall(r"grep -qiE '([^']+)'", function_text(script, "detect_domain_from_content")):
        for token in pattern.split("|"):
            if not any(re.search(token, text, re.I) for row in detect for text in row.get("files", {}).values()):
                problems.append("discover_detect_file: no file whose content matches %r" % token)

    total = len(registry["skills"])
    counts = {len(row.get("installed_skills", [])) for row in cases.get("discover_gaps", [])}
    if 0 not in counts or total not in counts or not any(0 < count < total for count in counts):
        problems.append("discover_gaps: want a case with none, some and all %d registry skills installed" % total)
    return problems


def coverage_problems(inputs, golden):
    problems = []
    asked = {category: [row["id"] for row in rows] for category, rows in inputs["cases"].items()}
    answered = golden.get("cases", {})
    for category in sorted(set(asked) | set(answered)):
        want, got = asked.get(category, []), list(answered.get(category, {}))
        if want != got:
            missing = [case for case in want if case not in got]
            extra = [case for case in got if case not in want]
            problems.append("%s: answered cases differ from the matrix (missing %s, extra %s, same order %s)"
                            % (category, missing[:3], extra[:3], not missing and not extra))
    return problems


def header_problems(golden):
    header = golden.get("header")
    if not isinstance(header, dict):
        return ["no header"]
    return ["header.%s is empty" % key for key in ("grep", "python3", "uname")
            if not isinstance(header.get(key), str) or not header[key].strip()]


def clean_problems(text, tmpbase):
    problems = []
    for leak in LEAKS:
        found = leak.search(text)
        if found:
            problems.append("the recording holds %r (matches %s)" % (found.group(0), leak.pattern))
    if tmpbase and tmpbase != "/" and tmpbase in text:
        problems.append("the recording holds the temp base %s" % tmpbase)
    return problems


def known_problems(golden):
    problems = []
    cases = golden.get("cases", {})
    for category, case, field, want, why in KNOWN:
        got = cases.get(category, {}).get(case, "<absent>")
        if field and isinstance(got, dict):
            got = got.get(field, "<absent>")
        if got != want:
            problems.append("%s/%s: %s -- wanted %r, recorded %r" % (category, case, why, want, got))
    for category, case, field, want in CONTAINS:
        got = cases.get(category, {}).get(case, {}).get(field, "<absent>")
        if (want not in got) if isinstance(want, str) and isinstance(got, str) else (got != want):
            problems.append("%s/%s: %s should hold %r, recorded %r" % (category, case, field, want, got))
    return problems


def changed(first, second):
    out = []
    for category in sorted(set(first["cases"]) | set(second["cases"])):
        one, two = first["cases"].get(category, {}), second["cases"].get(category, {})
        out.extend("%s/%s" % (category, case) for case in sorted(set(one) | set(two)) if one.get(case) != two.get(case))
    return out


def selftest(repo, inputs, golden, tmpbase):
    """Each check must object to a doctored copy. A check that cannot go red proves nothing."""
    failures = []

    def must_object(name, problems):
        if not problems:
            failures.append("%s did not object to its doctored input" % name)

    few = copy.deepcopy(inputs)
    few["cases"] = {"preinstall": few["cases"]["preinstall"][:5]}
    must_object("matrix (too few cases)", matrix_problems(few))
    twin = copy.deepcopy(inputs)
    twin["cases"]["keyword_match"].append(dict(twin["cases"]["keyword_match"][0]))
    must_object("matrix (duplicate id)", matrix_problems(twin))

    no_css = copy.deepcopy(inputs)
    no_css["cases"]["preinstall"] = [row for row in no_css["cases"]["preinstall"] if row["prompt"].lower() != "css"]
    must_object("legacy (the css token has no case)", legacy_problems(repo, no_css))
    no_kw = copy.deepcopy(inputs)
    no_kw["cases"]["keyword_match"] = [row for row in no_kw["cases"]["keyword_match"] if row["prompt"].lower() != "tailwind"]
    must_object("legacy (a registry keyword has no case)", legacy_problems(repo, no_kw))
    no_glob = copy.deepcopy(inputs)
    for row in no_glob["cases"]["activate"]:
        row["files"] = {path: text for path, text in row.get("files", {}).items() if not path.endswith(".vue")}
    must_object("legacy (a detection glob has no file)", legacy_problems(repo, no_glob))
    no_ext = copy.deepcopy(inputs)
    no_ext["cases"]["discover_detect_file"] = [row for row in no_ext["cases"]["discover_detect_file"] if not row["path"].endswith(".gd")]
    must_object("legacy (an extension has no case)", legacy_problems(repo, no_ext))

    short = copy.deepcopy(golden)
    del short["cases"]["preinstall"][next(iter(short["cases"]["preinstall"]))]
    must_object("coverage (a case left out)", coverage_problems(inputs, short))
    extra = copy.deepcopy(golden)
    extra["cases"]["preinstall"]["invented-case"] = []
    must_object("coverage (a case invented)", coverage_problems(inputs, extra))

    blank = copy.deepcopy(golden)
    blank["header"]["grep"] = " "
    must_object("header (blank grep version)", header_problems(blank))

    text = json.dumps(golden, ensure_ascii=False)
    must_object("clean (a sandbox path)", clean_problems(text + " /var/folders/zz/T/tmp.abc", tmpbase))
    must_object("clean (a timestamp)", clean_problems(text + " 2026-11-12T10:00:00Z", tmpbase))

    for category, case, field, want, _why in KNOWN:
        doctored = copy.deepcopy(golden)
        slot = doctored["cases"][category]
        if field:
            slot[case][field] = ["__doctored__"]
        else:
            slot[case] = ["__doctored__"]
        if not any(("%s/%s" % (category, case)) in line for line in known_problems(doctored)):
            failures.append("known (%s/%s) did not object when its answer was doctored" % (category, case))
    for category, case, field, _want in CONTAINS:
        doctored = copy.deepcopy(golden)
        doctored["cases"][category][case][field] = "__doctored__"
        if not any(("%s/%s" % (category, case)) in line for line in known_problems(doctored)):
            failures.append("known (%s/%s) did not object when its answer was doctored" % (category, case))
    return failures


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    if mode == "matrix" and len(argv) == 3:
        problems = matrix_problems(load(argv[2]))
        if not problems:
            rows = load(argv[2])["cases"]
            print("%d cases in %d categories" % (sum(len(v) for v in rows.values()), len(rows)))
    elif mode == "legacy" and len(argv) == 4:
        problems = legacy_problems(argv[2], load(argv[3]))
    elif mode == "coverage" and len(argv) == 4:
        problems = coverage_problems(load(argv[2]), load(argv[3]))
    elif mode == "header" and len(argv) == 3:
        problems = header_problems(load(argv[2]))
    elif mode == "clean" and len(argv) == 4:
        problems = clean_problems(read(argv[2]), argv[3])
    elif mode == "known" and len(argv) == 3:
        problems = known_problems(load(argv[2]))
    elif mode == "selftest" and len(argv) == 6:
        problems = selftest(argv[2], load(argv[3]), load(argv[4]), argv[5])
    elif mode == "changed" and len(argv) == 4:
        print("\n".join(changed(load(argv[2]), load(argv[3]))))
        problems = []
    else:
        sys.stderr.write(__doc__)
        return 2
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PYEOF
chk() { "$PY" -I "$WORK/check.py" "$@"; }

echo "skills-baseline-determinism -- the recorder of what the legacy skill selection does (3.x M1, T0.1)"

# ╔═ A. the recorder and the matrix exist; the matrix covers everything the legacy code can match on ═╗
if [ -x "$REC" ]; then ok "A: test/lib/skills_baseline_record.sh is executable"; else bad "A: test/lib/skills_baseline_record.sh is missing or not executable"; fi
if [ -f "$INPUTS" ]; then
  if OUT="$(chk matrix "$INPUTS" 2>&1)"; then ok "A: test/fixtures/skills-baseline/inputs.json: $OUT (>= 150)"; else bad "A: the matrix is malformed: $OUT"; fi
  if OUT="$(chk legacy "$REPO" "$INPUTS" 2>&1)"; then ok "A: every legacy token, keyword, glob, extension and content pattern has a case (read from the legacy source)"
  else bad "A: the matrix leaves legacy behaviour unexercised: $(printf '%s' "$OUT" | head -5 | tr '\n' ';')"; fi
else
  bad "A: test/fixtures/skills-baseline/inputs.json is missing"
fi
if [ ! -x "$REC" ] || [ ! -f "$INPUTS" ]; then
  echo "  nothing further can run without the recorder and its matrix"
  finish
fi

# ╔═ B. bad usage and a bad matrix are refused loudly ═══════════════════════════════════════════════╗
OUT="$(bash "$REC" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'usage' && ok "B: no arguments: usage on stderr, exit 2" || bad "B: no arguments: rc=$RC: $OUT"
OUT="$(bash "$REC" record 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "B: record without an output path: exit 2" || bad "B: record without a path: rc=$RC: $OUT"
OUT="$(bash "$REC" bogus "$WORK/x.json" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && [ ! -e "$WORK/x.json" ] && ok "B: an unknown subcommand: exit 2, nothing written" || bad "B: bogus subcommand: rc=$RC: $OUT"
OUT="$(bash "$REC" record "$WORK/nodir/x.json" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'nodir' && ok "B: an output directory that does not exist is refused before any work (exit 1, names it)" || bad "B: missing output dir: rc=$RC: $OUT"

# a throwaway tree: the recorder, a matrix, and exactly the legacy files the recorder runs. The recorder finds the legacy code relative to ITSELF.
# That includes the consent gate the legacy functions now ask before every install (T5.1) and the settings tool the gate reads: the recorder
# sources the first and pins HMD_SKILLS_CONSENT=auto, which is what "legacy" means to them.
mktree() {  # mktree <dir> <matrix json>
  local d="$1"
  mkdir -p "$d/bin/lib" "$d/test/lib" "$d/test/fixtures/skills-baseline"
  cp "$REPO/bin/heimdall" "$d/bin/heimdall"
  cp "$REPO/bin/skill-manager" "$d/bin/skill-manager"
  cp "$REPO/bin/discover-skills" "$d/bin/discover-skills"
  cp "$REPO/bin/lib/install-receipt.sh" "$d/bin/lib/install-receipt.sh"
  cp "$REPO/bin/lib/skills_consent.sh" "$d/bin/lib/skills_consent.sh"
  cp "$REPO/bin/lib/skills_config.py" "$d/bin/lib/skills_config.py"
  cp "$REPO/bin/lib/skill_restore.py" "$d/bin/lib/skill_restore.py"
  cp "$REPO/heimdall-skills.json" "$d/heimdall-skills.json"
  cp "$REPO/skills-registry.json" "$d/skills-registry.json"
  cp "$REC" "$d/test/lib/skills_baseline_record.sh"
  printf '%s\n' "$2" > "$d/test/fixtures/skills-baseline/inputs.json"
}
MINI_MATRIX='{"schema":1,"cases":{
 "preinstall":[{"id":"m-css","prompt":"css"},{"id":"m-docker","prompt":"docker"}],
 "keyword_match":[{"id":"m-tailwind","prompt":"tailwind"},{"id":"m-godot","prompt":"godot"}],
 "activate":[{"id":"m-vue","files":{"App.vue":""}},{"id":"m-rb","files":{"tool.rb":""}}],
 "discover_detect_file":[{"id":"m-file-vue","path":"a.vue","files":{"a.vue":""}},{"id":"m-file-gd","path":"p.gd","files":{"p.gd":""}}]}}'
MINI="$WORK/mini"
mktree "$MINI" "$MINI_MATRIX"
reject() {  # reject <what> <matrix json> <word the message must name>
  printf '%s\n' "$2" > "$MINI/test/fixtures/skills-baseline/inputs.json"
  rm -f "$WORK/rej.json"
  local out rc
  out="$(bash "$MINI/test/lib/skills_baseline_record.sh" record "$WORK/rej.json" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q -- "$3" && ! printf '%s' "$out" | grep -q Traceback && [ ! -e "$WORK/rej.json" ]; then
    ok "B: $1 is refused (exit 1, names $3, no traceback, nothing written)"
  else
    bad "B: $1: rc=$rc out=$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
  fi
}
reject "an unknown category" '{"schema":1,"cases":{"bogus":[{"id":"a"}]}}' bogus
reject "an unknown key in a case" '{"schema":1,"cases":{"preinstall":[{"id":"a","prompt":"x","promt":"y"}]}}' promt
reject "a duplicate id" '{"schema":1,"cases":{"preinstall":[{"id":"a","prompt":"x"},{"id":"a","prompt":"y"}]}}' duplicate
reject "a file path that leaves the sandbox" '{"schema":1,"cases":{"preinstall":[{"id":"a","prompt":"x","files":{"../evil":"x"}}]}}' '\.\./evil'
reject "a case without its prompt" '{"schema":1,"cases":{"preinstall":[{"id":"a"}]}}' prompt
reject "malformed JSON" '{"schema":1,' inputs.json

# ╔═ C. two recordings of one tree: identical, complete, versioned, clean, and harmless to the operator's machine ═╗
mkdir -p "$WORK/canary-home" "$WORK/canary-hh"
env HOME="$WORK/canary-home" HEIMDALL_HOME="$WORK/canary-hh" bash "$REC" record "$WORK/a.json" >"$WORK/a.log" 2>&1; RC_A=$?
bash "$REC" record "$WORK/b.json" >"$WORK/b.log" 2>&1; RC_B=$?
if [ "$RC_A" -eq 0 ] && [ "$RC_B" -eq 0 ]; then ok "C: the full matrix records twice, exit 0 both times"
else bad "C: recording failed (rc $RC_A / $RC_B): $(tail -3 "$WORK/a.log" "$WORK/b.log" | tr '\n' ' ')"; finish; fi
if cmp -s "$WORK/a.json" "$WORK/b.json"; then ok "C: the two recordings are byte-identical"
else bad "C: the recordings differ: $(chk changed "$WORK/a.json" "$WORK/b.json" | head -5 | tr '\n' ' ')"; fi
if OUT="$(chk coverage "$INPUTS" "$WORK/a.json" 2>&1)"; then ok "C: the recording answers every case of the matrix, in order, and nothing else"; else bad "C: $OUT"; fi
if OUT="$(chk header "$WORK/a.json" 2>&1)"; then ok "C: the header records grep, python3 and uname"; else bad "C: $OUT"; fi
if OUT="$(chk clean "$WORK/a.json" "$(dirname "$WORK")" 2>&1)"; then ok "C: no sandbox path, timestamp or run id leaked into the recording"; else bad "C: $OUT"; fi
if [ "$(ls -A "$WORK/canary-home" | wc -l | tr -d ' ')" = 0 ] && [ "$(ls -A "$WORK/canary-hh" | wc -l | tr -d ' ')" = 0 ]; then
  ok "C: the operator's HOME and HEIMDALL_HOME were not touched (the legacy code only ever ran in sandboxes)"
else
  bad "C: the recorder wrote into the operator's HOME or HEIMDALL_HOME: $(ls -A "$WORK/canary-home" "$WORK/canary-hh" | tr '\n' ' ')"
fi

# ╔═ D. the plan's quirk probes and known answers ════════════════════════════════════════════════════╗
if OUT="$(chk known "$WORK/a.json" 2>&1)"; then ok "D: build selects frontend-design; prompt+file hits repeat it; rules fire in code order; the matchers differ as recorded"
else bad "D: a known answer is wrong: $(printf '%s' "$OUT" | head -4 | tr '\n' ';')"; fi

# ╔═ E. the recorder runs the legacy code: break one rule of each legacy reader, exactly that case moves ═╗
mktree "$WORK/mini-orig" "$MINI_MATRIX"
mktree "$WORK/mini-mutant" "$MINI_MATRIX"
mutate() {  # mutate <file> <sed expression>: rewrite the file in place (mode kept), then require that it really changed
  local f="$1" before
  before="$(cksum < "$f")"
  sed "$2" "$f" > "$f.new" && cat "$f.new" > "$f" && rm -f "$f.new"
  [ "$(cksum < "$f")" != "$before" ]
}
M="$WORK/mini-mutant"
if mutate "$M/bin/heimdall" 's/react|vue|angular|css|responsive/react|vue|angular|responsive/' \
   && mutate "$M/skills-registry.json" 's/"tailwind", //' \
   && mutate "$M/heimdall-skills.json" 's/"\*\.vue", //' \
   && mutate "$M/bin/discover-skills" 's/tsx|jsx|vue|svelte|css|scss|less)/tsx|jsx|svelte|css|scss|less)/'; then
  ok "E: four legacy rules broken in a copy of the tree (the css token, the tailwind keyword, the *.vue glob, the .vue extension)"
else
  bad "E: a mutation did not apply: the legacy source no longer reads as this suite expects"
fi
bash "$WORK/mini-orig/test/lib/skills_baseline_record.sh" record "$WORK/orig.json" >"$WORK/orig.log" 2>&1; RC_O=$?
bash "$M/test/lib/skills_baseline_record.sh" record "$WORK/mutant.json" >"$WORK/mutant.log" 2>&1; RC_M=$?
if [ "$RC_O" -eq 0 ] && [ "$RC_M" -eq 0 ]; then
  GOT="$(chk changed "$WORK/orig.json" "$WORK/mutant.json" | tr '\n' ' ')"
  WANT="activate/m-vue discover_detect_file/m-file-vue keyword_match/m-tailwind preinstall/m-css "
  [ "$GOT" = "$WANT" ] && ok "E: exactly the four cases that exercise the broken rules changed; the four controls did not" \
    || bad "E: changed cases: [$GOT] wanted [$WANT]"
else
  bad "E: a mini recording failed (rc $RC_O / $RC_M): $(tail -2 "$WORK/orig.log" "$WORK/mutant.log" | tr '\n' ' ')"
fi

# ╔═ F. every check above goes RED on a doctored input or recording ══════════════════════════════════╗
if OUT="$(chk selftest "$REPO" "$INPUTS" "$WORK/a.json" "$(dirname "$WORK")" 2>&1)"; then
  ok "F: matrix, legacy-coverage, coverage, header, clean and known-answer checks each object to a doctored copy"
else
  bad "F: a check cannot go red: $(printf '%s' "$OUT" | head -4 | tr '\n' ';')"
fi

finish
