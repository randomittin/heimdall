#!/usr/bin/env bash
#
# skills-resolver-mutants.test.sh -- 3.x M1, T3.4: the resolver's parity gate goes RED for every defect injected into the manifest.
#
#   bash test/skills-resolver-mutants.test.sh
#
# Plan: docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md ("Parity test design": Falsifiable; "Oracle gate"). test/skills-resolver-parity.test.sh is the
# differential gate: the resolver's answers against the recorded legacy answers (test/fixtures/skills-baseline/golden.json). A gate that has only ever been seen
# green proves nothing, so this suite copies skills.manifest.json, injects ONE defect into each copy with python, hands the copy to the gate (`--manifest PATH`)
# and requires the gate to fail, and to fail because of the defect. The score is the number of mutants the gate killed. It was written by an author who did not
# write the resolver or the gate and only knows the gate's public face: `--manifest PATH`, its exit code and the lines it prints.
#
#   A. prerequisites: the gate, the manifest, its validator, the resolver and the golden are all there, and the repo manifest is a valid manifest.
#   B. the verdict logic can say no: synthetic gate transcripts (a green run, a red run for the wrong reason, a run that did not finish, a collapse) get the
#      verdict they should. Without this a judge that always answers "killed" would score N/N too.
#   C. control: the manifest, rewritten by the code that writes every mutant but with nothing injected, passes the gate (exit 0, nothing red). If it did not,
#      every mutant would "die" of something that has nothing to do with it. Its transcript fixes the number of checks and the golden categories the mutants
#      are held to.
#   D. mutants: 11 defects, the plan's seven (a dropped keyword, a swapped plugin, a changed regex alternation, a dropped detection glob, two reordered rules, a
#      dropped glob that `src/**` placements rely on, a changed marketplace) and four more (a moved category, a changed repo, a swapped registry order, a dropped
#      file-trigger word). Each must (1) still be a valid manifest (skills_manifest.py validate), so the gate sees a wrong answer and not an unreadable file;
#      (2) make the gate exit 1; (3) turn red the golden categories it must, and no check the manifest cannot change (the gate's `contract:` checks compare its
#      `status` and `gaps` answers with the golden too, so they may go red with the categories; a static, coverage or driver check may not); (4) not turn every
#      category red, which is a broken manifest and not one defect; (5) leave the gate running as many checks as the control; (6) where it names a case, show that
#      case among the ones the gate lists as different (the gate lists the first four of a category, so only cases within them are named).
#      A mutant the gate does not see (exit 0) SURVIVES: a real finding, never removed from the list to make the score pass.
#
# Not scored, by construction: a defect in a field that no resolver subcommand reads cannot show in any answer, so parity cannot see it. marketplaces.<name>.source
# and .pin are such fields (they are install mechanics, outside the pass-through resolver); test/skills-manifest-transcription.test.sh owns them. The marketplace
# mutant below changes the marketplace a plugin REF names, which is read, and which the validator keeps in step with the entry's `marketplace`.
#
# It prints `falsifiability score N/N` (mutants killed / mutants) before its summary. Exit: 0 every check passed (the control is green and every mutant was
# killed), 1 a check failed, 2 usage or this machine cannot run the suite.
# budget: 240 -- measured 166 s on the first full run (2026-11-12, a developer laptop): 12 runs of test/skills-resolver-parity.test.sh back to back, ~10 s each once
# warm and ~25-35 s for the first two (each is ~480 resolver processes over at most 8 workers), plus a few validator calls. The sweep's receipt holds its own time.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
PARITY="$REPO/test/skills-resolver-parity.test.sh"
MANIFEST="$REPO/skills.manifest.json"
VALIDATOR="$REPO/bin/lib/skills_manifest.py"
RESOLVER="$REPO/bin/lib/skills_resolver.py"
GOLDEN="$REPO/test/fixtures/skills-baseline/golden.json"
INPUTS="$REPO/test/fixtures/skills-baseline/inputs.json"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
finish() {
  echo "--------------------------------------------------------------------"
  printf 'skills-resolver-mutants: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

[ "$#" -eq 0 ] || { echo "usage: bash test/skills-resolver-mutants.test.sh" >&2; exit 2; }
PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
# the real interpreter, not a version-manager shim (0.3-0.8 s a call)
REALPY="$("$PY" -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
case "$REALPY" in /*) ;; *) REALPY="" ;; esac
[ -n "$REALPY" ] && [ -x "$REALPY" ] || { echo "FATAL: cannot resolve the interpreter behind $PY"; exit 2; }
WORK="$(mktemp -d)" || { echo "FATAL: cannot make a temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

echo "A. prerequisites"
MISSING=""
for needed in "$PARITY" "$MANIFEST" "$VALIDATOR" "$RESOLVER" "$GOLDEN" "$INPUTS"; do
  [ -f "$needed" ] || MISSING="$MISSING ${needed#"$REPO"/}"
done
if [ -n "$MISSING" ]; then
  bad "the gate and everything it reads are present (missing:$MISSING)"
  finish
fi
ok "the parity gate, the manifest, its validator, the resolver and the golden are all present"
if VALID="$("$REALPY" -B -I "$VALIDATOR" validate "$MANIFEST" 2>&1)"; then
  ok "the repo manifest is a valid manifest, the base of every mutant: $VALID"
else
  bad "the repo manifest is a valid manifest (every mutant derives from it)"
  printf '    %s\n' "$VALID"
  finish
fi

echo "B-D. verdict logic, control, mutants"
cat > "$WORK/driver.py" <<'PYEOF'
"""driver.py -- injects one defect per mutant into a copy of skills.manifest.json and requires test/skills-resolver-parity.test.sh --manifest to go red.

    driver.py REPO WORK

One record per line: `PASS <what>`, `FAIL <what>` (indented detail lines follow it), `SCORE <killed> <total> <seconds> <gate runs>`, then `DONE`. No DONE
means the driver died. Importable: nothing runs until main() is called.
"""
import copy
import json
import os
import re
import signal
import subprocess
import sys
import time

REPO, WORK = sys.argv[1:3]
MANIFEST = REPO + "/skills.manifest.json"
PARITY = REPO + "/test/skills-resolver-parity.test.sh"
VALIDATOR = REPO + "/bin/lib/skills_manifest.py"
GATE_TIMEOUT_S = 300
GATE_RUNS = 0

# what the gate prints: a line per check (`  PASS ...` / `  FAIL ...`, colour codes around the word), the first cases that differ under a red golden
# category (4 spaces, the case id, a colon), then its summary
ANSI = re.compile(r"\x1b\[[0-9;]*m")
RESULT = re.compile(r"^\s+(PASS|FAIL) (.*)$")
CASE_FAIL = re.compile(r"^(\w+): (\d+) of (\d+) cases differ from the golden$")
CASE_PASS = re.compile(r"^(\w+): all (\d+) cases equal the golden, whole output$")
LISTED = re.compile(r"^ {4}([A-Za-z0-9_.-]+): ")
SUMMARY = re.compile(r"^skills-resolver-parity: (\d+) passed, (\d+) failed")


def say(verdict, what, *details):
    print("%s %s" % (verdict, what))
    for line in details:
        print("    " + line)
    sys.stdout.flush()


def short(value, limit=220):
    text = " ".join(str(value).split()).encode("ascii", "backslashreplace").decode("ascii")
    return text if len(text) <= limit else text[:limit - 3] + "..."


# ── the defects: each edits ONE thing a transcription of the legacy mappings could get wrong ──
class Inapplicable(Exception):
    """The defect's target is not in the manifest (renamed or removed since this suite was written): this suite needs an update, the gate is not at fault."""


def need(condition, what):
    if not condition:
        raise Inapplicable(what)


def entry(doc, ident):
    for item in doc["entries"]:
        if item["id"] == ident:
            return item
    raise Inapplicable("the manifest has no entry %s" % ident)


def drop_keyword(doc):
    words = entry(doc, "ui-ux-pro-max")["keywords"]
    need("landing page" in words, "ui-ux-pro-max has no keyword 'landing page'")
    words.remove("landing page")


def swap_plugin(doc):
    api, slack = entry(doc, "api-design"), entry(doc, "slack")
    need(api["ref"] != slack["ref"], "api-design and slack name the same plugin")
    api["ref"], slack["ref"] = slack["ref"], api["ref"]


def change_alternation(doc):
    trigger = entry(doc, "api-design")["triggers"]
    need("|rest|" in trigger["prompt_ere"], "the ERE of api-design has no |rest| token")
    trigger["prompt_ere"] = trigger["prompt_ere"].replace("|rest|", "|restful|")


def drop_glob(doc):
    globs = doc["detection_rules"]["playwright"]["files"]
    need("cypress.config.*" in globs, "the playwright rule has no glob cypress.config.*")
    globs.remove("cypress.config.*")


def reorder_rules(doc):
    devops, database = entry(doc, "devops-toolkit")["triggers"], entry(doc, "database-toolkit")["triggers"]
    need(devops["order"] != database["order"], "devops-toolkit and database-toolkit share a rule order")
    devops["order"], database["order"] = database["order"], devops["order"]


def drop_src_glob(doc):
    globs = doc["detection_rules"]["security"]["files"]
    need("*.go" in globs, "the security rule has no glob *.go")
    globs.remove("*.go")


def change_marketplace(doc):
    item = entry(doc, "frontend-design")
    need(item["ref"].endswith("@claude-plugins-official"), "frontend-design does not name claude-plugins-official")
    item["ref"], item["marketplace"] = "frontend-design@heimdall-marketplace", "heimdall-marketplace"


def move_category(doc):
    item = entry(doc, "claude-obsidian")
    need(item["category"] == "knowledge", "claude-obsidian is not in the category knowledge")
    item["category"] = "documentation"


def change_repo(doc):
    item = entry(doc, "claude-seo")
    item["repo"] = item["repo"] + "-fork"


def swap_registry_order(doc):
    order = doc["keyword_skills"]
    need("claude-obsidian" in order and "claude-seo" in order, "keyword_skills does not list claude-obsidian and claude-seo")
    one, other = order.index("claude-obsidian"), order.index("claude-seo")
    order[one], order[other] = order[other], order[one]


def drop_file_trigger_word(doc):
    words = entry(doc, "frontend-design")["triggers"]["files"][0]["contains_any"]
    need("svelte" in words, "the package.json trigger of frontend-design has no word svelte")
    words.remove("svelte")


def mutant(name, what, mutate, flips, ids=()):
    """flips: the golden categories that must turn red. ids: cases that must be among those the gate lists as different (it lists the first four of a
    category, so a case is named only where the mutant makes four or fewer of its category differ)."""
    return {"name": name, "what": what, "mutate": mutate, "flips": flips, "ids": ids}


MUTANTS = (
    mutant("drop-keyword", 'ui-ux-pro-max loses the keyword "landing page"', drop_keyword,
           ("keyword_match",), ("kw-ui-ux-pro-max-landing-space-page",)),
    mutant("swap-plugin", "api-design and slack trade plugin refs", swap_plugin,
           ("preinstall", "activate")),
    mutant("change-alternation", "the ERE token rest of api-design becomes restful", change_alternation,
           ("preinstall",), ("pre-tok-api-rest",)),
    mutant("drop-glob", "the playwright rule loses the glob cypress.config.*", drop_glob,
           ("activate",), ("act-top-cypress-dot-config-dot-cjs",)),
    mutant("reorder-rules", "devops-toolkit and database-toolkit trade rule order", reorder_rules,
           ("preinstall",)),
    mutant("drop-src-glob", "the security rule loses *.go, which its src/** placements rely on", drop_src_glob,
           ("activate",), ("act-place-security-src", "act-place-security-src-deep")),
    mutant("change-marketplace", "frontend-design moves to heimdall-marketplace", change_marketplace,
           ("preinstall", "activate")),
    mutant("move-category", "claude-obsidian moves from knowledge to documentation", move_category,
           ("discover_detect_file",)),
    mutant("change-repo", "claude-seo points at another repo", change_repo,
           ("keyword_match",)),
    mutant("swap-registry-order", "claude-obsidian and claude-seo trade places in keyword_skills", swap_registry_order,
           ("keyword_match", "discover_gaps")),
    mutant("drop-file-trigger-word", "the package.json trigger of frontend-design loses svelte", drop_file_trigger_word,
           ("preinstall",), ("pre-file-pkg-svelte",)),
)


# ── the gate: write a manifest, run it, read what it printed ──
def build(name, mutate):
    """Write the repo manifest, with `mutate` applied, to WORK/mutants/NAME.json. Returns (path, whether it differs from the repo manifest)."""
    with open(MANIFEST, encoding="utf-8") as handle:
        original = json.load(handle)
    doc = copy.deepcopy(original)
    if mutate is not None:
        mutate(doc)
    path = "%s/mutants/%s.json" % (WORK, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    return path, doc != original


def is_valid(path):
    done = subprocess.run([sys.executable, "-B", "-I", VALIDATOR, "validate", path], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=60)
    return done.returncode == 0, done.stderr.decode("utf-8", "replace").strip()


def run_gate(path):
    """The gate on a manifest -> (exit code, its output, seconds). A run past GATE_TIMEOUT_S is killed with its workers and reported as 124."""
    global GATE_RUNS
    GATE_RUNS += 1
    started = time.monotonic()
    proc = subprocess.Popen(["bash", PARITY, "--manifest", path], cwd=REPO, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=GATE_TIMEOUT_S)
        code = proc.returncode
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        out, _ = proc.communicate()
        code = 124
    return code, out.decode("utf-8", "replace"), time.monotonic() - started


def parse(text):
    """What the gate printed, as data: the golden categories it called red (with how many cases differ) and green, every red line, the cases it listed under
    each red category, its summary."""
    seen = {"fails": [], "red": {}, "green": set(), "listed": {}, "summary": None}
    current = None
    for line in ANSI.sub("", text).split("\n"):
        result = RESULT.match(line)
        if result:
            current = None
            verdict, what = result.groups()
            if verdict == "FAIL":
                seen["fails"].append(what)
                red = CASE_FAIL.match(what)
                if red:
                    current = red.group(1)
                    seen["red"][current] = (int(red.group(2)), int(red.group(3)))
                    seen["listed"][current] = []
            else:
                green = CASE_PASS.match(what)
                if green:
                    seen["green"].add(green.group(1))
            continue
        listed = LISTED.match(line)
        if listed and current is not None:
            seen["listed"][current].append(listed.group(1))
        summary = SUMMARY.match(line)
        if summary:
            seen["summary"] = (int(summary.group(1)), int(summary.group(2)))
    return seen


def judge(spec, control, code, text):
    """The gate's answer to one mutant -> (verdict, why). KILLED is the only verdict that scores."""
    seen = parse(text)
    if code == 0:
        return "SURVIVED", "the gate exits 0 with the defect in place: it cannot see it"
    if code != 1:
        return "INCONCLUSIVE", "the gate exited %d (1 means a check failed; anything else means it did not run to the end)" % code
    if seen["summary"] is None:
        return "INCONCLUSIVE", "the gate printed no summary line"
    passed, failed = seen["summary"]
    if failed != len(seen["fails"]) or passed + failed != control["checks"]:
        return "INCONCLUSIVE", "the gate ran %d checks and printed %d red lines for %d red; the control ran %d" % (
            passed + failed, len(seen["fails"]), failed, control["checks"])
    # the gate's `contract:` section answers status and gaps from the manifest under test and compares them with the golden, so it may go red with the
    # categories; its static, coverage and driver checks read nothing the manifest can change, so a red there is not this defect
    stray = [what for what in seen["fails"] if CASE_FAIL.match(what) is None and not what.startswith("contract: ")]
    if stray:
        return "WRONG_REASON", "red on a check the manifest cannot change: " + short(stray[0])
    red = set(seen["red"])
    if not set(spec["flips"]) <= red:
        return "WRONG_REASON", "expected %s red, red is %s" % (sorted(spec["flips"]), sorted(red))
    if not control["categories"] - red:
        return "WRONG_REASON", "every golden category is red: that is a broken manifest, not one defect"
    unlisted = [ident for ident in spec["ids"] if not any(ident in ids for ids in seen["listed"].values())]
    if unlisted:
        return "WRONG_REASON", "the gate does not list %s among the cases that differ" % ", ".join(unlisted)
    return "KILLED", "; ".join("%s %d of %d cases differ" % (name, seen["red"][name][0], seen["red"][name][1]) for name in sorted(red))


def tail(text):
    """The first red lines the gate printed (its last lines when it printed none): shown under a verdict that is not KILLED."""
    lines = [line.strip() for line in ANSI.sub("", text).split("\n") if line.strip()]
    reds = [line for line in lines if line.startswith("FAIL ")]
    return [short(line) for line in (reds[:4] or lines[-3:])]


# ── B. the verdict logic can say no ──
def transcript(red, green, other=(), ids=None):
    """What the gate prints for synthetic results: a red golden category is a FAIL line and the first case that differs, a green one a PASS line, `other` are
    red checks that are not golden categories, then the summary."""
    lines = []
    for name in red:
        lines += ["  FAIL %s: 1 of 5 cases differ from the golden" % name, "    %s: %s: expected [], got ['x']" % ((ids or {}).get(name, "case-1"), name)]
    lines += ["  PASS %s: all 5 cases equal the golden, whole output" % name for name in green]
    lines += ["  FAIL %s" % what for what in other]
    lines.append("skills-resolver-parity: %d passed, %d failed" % (len(green), len(red) + len(other)))
    return "\n".join(lines) + "\n"


def check_judge():
    control = {"checks": 3, "categories": {"preinstall", "activate", "keyword_match"}}
    plain = {"name": "probe", "flips": ("keyword_match",), "ids": ()}
    named = {"name": "probe-ids", "flips": ("keyword_match",), "ids": ("kw-wanted",)}
    contract = "contract: settings and installed skills default to HOME, and --skills-dir / --settings override it"
    coverage = "coverage: 5 of 6 golden cases were run through the resolver"
    probes = (
        ("a green run", "SURVIVED", plain, 0, transcript((), ("preinstall", "activate", "keyword_match"))),
        ("red in the category it must be", "KILLED", plain, 1, transcript(("keyword_match",), ("preinstall", "activate"))),
        ("red only in another category", "WRONG_REASON", plain, 1, transcript(("activate",), ("preinstall", "keyword_match"))),
        ("red also on a contract check, which reads the manifest", "KILLED", plain, 1,
         transcript(("keyword_match",), ("preinstall",), other=(contract,))),
        ("red also on a check no manifest can change", "WRONG_REASON", plain, 1,
         transcript(("keyword_match",), ("preinstall",), other=(coverage,))),
        ("every golden category red", "WRONG_REASON", plain, 1, transcript(("keyword_match", "activate", "preinstall"), ())),
        ("a named case missing from the listed ones", "WRONG_REASON", named, 1,
         transcript(("keyword_match",), ("preinstall", "activate"), ids={"keyword_match": "kw-other"})),
        ("a named case among the listed ones", "KILLED", named, 1,
         transcript(("keyword_match",), ("preinstall", "activate"), ids={"keyword_match": "kw-wanted"})),
        ("exit 2, the gate could not run", "INCONCLUSIVE", plain, 2, transcript(("keyword_match",), ("preinstall", "activate"))),
        ("fewer checks than the control ran", "INCONCLUSIVE", plain, 1, transcript(("keyword_match",), ("preinstall",))),
        ("no summary line", "INCONCLUSIVE", plain, 1,
         transcript(("keyword_match",), ("preinstall", "activate")).replace("skills-resolver-parity:", "elsewhere:")),
    )
    wrong = []
    for label, want, spec, code, text in probes:
        got, why = judge(spec, control, code, text)
        if got != want:
            wrong.append("%s: expected %s, got %s (%s)" % (label, want, got, why))
    if wrong:
        say("FAIL", "the verdict logic: %d of %d synthetic transcripts got the wrong verdict" % (len(wrong), len(probes)), *wrong)
    else:
        say("PASS", "the verdict logic: %d synthetic transcripts get the verdict they should (a green run SURVIVES; red for the wrong reason, a collapse, "
                    "a missing named case and a run that did not finish are not KILLED)" % len(probes))
    return not wrong


# ── C. control ──
def run_control():
    path, changed = build("control", None)
    if changed:
        say("FAIL", "control: the manifest written with nothing injected differs from the repo manifest")
        return None
    code, out, seconds = run_gate(path)
    seen = parse(out)
    if code != 0 or seen["summary"] is None or seen["summary"][1] != 0:
        say("FAIL", "control: the gate is not green on the manifest with nothing injected (exit %d), so a red gate on a mutant would prove nothing" % code,
            *tail(out))
        return None
    if len(seen["green"]) < 2:
        say("FAIL", "control: the gate listed %d golden categories as equal (its output changed, or the golden shrank): the verdicts below could not tell one "
                    "defect from a collapse" % len(seen["green"]), *tail(out))
        return None
    say("PASS", "control: the manifest written with nothing injected passes the gate (exit 0, %d checks, %d golden categories equal) [%.1f s]" % (
        sum(seen["summary"]), len(seen["green"]), seconds))
    return {"checks": sum(seen["summary"]), "categories": seen["green"]}


# ── D. mutants ──
def attempt(spec, control):
    """One mutant through the gate; prints its record, returns whether it was killed."""
    label = "mutant %s (%s)" % (spec["name"], spec["what"])
    try:
        path, changed = build(spec["name"], spec["mutate"])
    except (Inapplicable, KeyError, IndexError, TypeError, ValueError) as exc:
        say("FAIL", "%s: cannot be applied to skills.manifest.json: %s (this suite needs an update; the gate is not at fault)" % (label, short(exc)))
        return False
    if not changed:
        say("FAIL", "%s: injected nothing, the manifest is unchanged" % label)
        return False
    valid, reason = is_valid(path)
    if not valid:
        say("FAIL", "%s: the mutant is not a valid manifest, so a red gate would prove nothing" % label, *[short(line) for line in reason.split("\n")[:3]])
        return False
    code, out, seconds = run_gate(path)
    verdict, why = judge(spec, control, code, out)
    if verdict == "KILLED":
        say("PASS", "%s: killed, %s [%.1f s]" % (label, why, seconds))
        return True
    say("FAIL", "%s: %s, %s [%.1f s]" % (label, verdict, why, seconds), *tail(out))
    return False


def main():
    started = time.monotonic()
    check_judge()
    control = run_control()
    killed = 0
    if control is not None:
        for spec in MUTANTS:
            killed += 1 if attempt(spec, control) else 0
    print("SCORE %d %d %d %d" % (killed, len(MUTANTS), round(time.monotonic() - started), GATE_RUNS))
    print("DONE")


if __name__ == "__main__":
    main()
PYEOF
SYNTAX="$("$REALPY" -B -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$WORK/driver.py" 2>&1)" \
  || { bad "the mutant driver is not valid python"; printf '%s\n' "$SYNTAX"; finish; }

OUT="$("$REALPY" -B -I "$WORK/driver.py" "$REPO" "$WORK" 2>&1)"; RC=$?
SAW_DONE=0; KILLED=""; TOTAL=""; SECONDS_USED=""; RUNS_DONE=""
while IFS= read -r line; do
  case "$line" in
    "PASS "*) ok "${line#PASS }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
    "SCORE "*) read -r _ KILLED TOTAL SECONDS_USED RUNS_DONE <<< "$line" ;;
    DONE) SAW_DONE=1 ;;
    *) printf '%s\n' "$line" ;;
  esac
done <<< "$OUT"
{ [ "$SAW_DONE" -eq 1 ] && [ "$RC" -eq 0 ]; } || bad "the mutant driver did not finish (exit $RC)"
[ -z "$TOTAL" ] || echo "falsifiability score $KILLED/$TOTAL (${RUNS_DONE:-?} gate runs, ${SECONDS_USED:-?} s)"
finish
