#!/usr/bin/env bash
#
# skills-resolver-parity.test.sh -- 3.x M1, T2.1: the skill resolver answers what the LEGACY code answered, for every case of the golden.
#
#   bash test/skills-resolver-parity.test.sh [--manifest PATH]
#
# Plan: docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md ("Resolver design", "Parity test design", INV-S2, INV-S3). bin/lib/skills_resolver.py
# reads skills.manifest.json and prints, for the same input, what bin/heimdall (preinstall_plugins, discover_skills), bin/lib/skill_restore.py
# (needed_plugins), bin/skill-manager (status) and bin/discover-skills (detect, detect-file, gaps) printed. The reference is
# test/fixtures/skills-baseline/golden.json: the answers of the UNMODIFIED legacy code, recorded by test/lib/skills_baseline_record.sh and committed
# before the resolver. This suite never builds an expectation from the manifest: it runs the resolver as a real process per call (throwaway HOME and
# project tree, the recorder's own world) and compares the WHOLE output with the golden, order and duplicates included.
#
#   A. static: the resolver never installs and never writes (no `claude plugins install`, no subprocess, no write-mode open), and the golden was
#      committed before the resolver (INV-S3, git ancestry).
#   B. parity: every case of every golden category, through the resolver CLI. Nothing is skipped silently: a golden case without an input, a category
#      without a handler or a count that does not add up is a failure.
#   C. contract: exit codes (2 usage, 3 unreadable or invalid manifest or input), the HOME defaults the parity runs override (settings.json, the
#      installed skills) and their --settings / --skills-dir overrides, and the resolver leaves the project, HOME and the plugin dir untouched.
#   D. the gate can go RED: four defects injected into a copy of the repo manifest (a dropped keyword, a dropped ERE token, a dropped glob, two
#      reordered rules) and --manifest handed to the resolver; each must flip exactly the case that depends on it. test/skills-resolver-mutants.test.sh
#      (T3.4) runs the wide version of this by calling this suite with --manifest.
#
# --manifest PATH points the resolver at another manifest (T3.4's mutants). Section D always starts from the repo manifest, never from PATH.
#
# What the resolver does NOT answer, and this suite therefore does not compare: whether a plugin is already installed. `preinstall` prints every match
# (it never installs and never asks `claude`); the skip of an installed plugin is `_try_install`'s, a `grep -q` of the plugin NAME in `claude plugins
# list`. The preinstall_installed cases apply that same substring skip to the resolver's list before comparing it with the recorded install attempts.
#
# Exit: 0 every check passed, 1 a check failed, 2 usage or this machine cannot run the suite.
# budget: 30 -- an estimate, not a measurement: ~480 resolver processes (python3 -I startup, a few tens of ms each) over at most 8 workers, plus ~20 for
# sections C and D. The sweep's receipt holds the measured time.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
RESOLVER="$REPO/bin/lib/skills_resolver.py"
GOLDEN="$REPO/test/fixtures/skills-baseline/golden.json"
INPUTS="$REPO/test/fixtures/skills-baseline/inputs.json"
MANIFEST="$REPO/skills.manifest.json"
PASS=0; FAIL=0; SKIPPED=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }
finish() {
  echo "--------------------------------------------------------------------"
  if [ "$SKIPPED" -gt 0 ]; then
    printf 'skills-resolver-parity: %d passed, %d failed (%d SKIPPED, see above: a skip is not a pass)\n' "$PASS" "$FAIL" "$SKIPPED"
  else
    printf 'skills-resolver-parity: %d passed, %d failed\n' "$PASS" "$FAIL"
  fi
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}
usage() { echo "usage: bash test/skills-resolver-parity.test.sh [--manifest PATH]" >&2; exit 2; }

case "$#" in
  0) ;;
  2) [ "$1" = "--manifest" ] || usage; MANIFEST="$2" ;;
  *) usage ;;
esac
case "$MANIFEST" in /*) ;; *) MANIFEST="$PWD/$MANIFEST" ;; esac

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
# the real interpreter, not a version-manager shim (0.3-0.8 s a call, and this suite starts ~500 of them)
REALPY="$("$PY" -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
case "$REALPY" in /*) ;; *) REALPY="" ;; esac
[ -n "$REALPY" ] && [ -x "$REALPY" ] || { echo "FATAL: cannot resolve the interpreter behind $PY"; exit 2; }
[ -f "$GOLDEN" ] && [ -f "$INPUTS" ] || { echo "FATAL: the golden or the input matrix is missing (test/fixtures/skills-baseline)"; exit 2; }
WORK="$(mktemp -d)" || { echo "FATAL: cannot make a temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

echo "A. static"
if [ -f "$RESOLVER" ]; then
  ok "bin/lib/skills_resolver.py exists"
else
  bad "bin/lib/skills_resolver.py exists (T2.1 creates it)"
  finish
fi

INSTALLS="$(grep -c 'claude plugins install' "$RESOLVER" || true)"
[ "$INSTALLS" = "0" ] && ok "the resolver never installs: 0 lines name 'claude plugins install'" \
  || bad "the resolver names 'claude plugins install' on $INSTALLS line(s): it must never install"

# read-only and offline: no process, no file removal or creation, no network, no write-mode open
WRITERS="$(grep -nE 'subprocess|os\.system|os\.popen|os\.exec|shutil|os\.(remove|unlink|rename|replace|makedirs|mkdir|rmdir|symlink|link|chmod)|urllib|socket|http\.client|open\([^)]*,[[:space:]]*["'"'"'][rbt]*[wax+][bt+]*["'"'"']' "$RESOLVER" || true)"
[ -z "$WRITERS" ] && ok "the resolver starts no process, writes no file and opens no socket" \
  || { bad "the resolver can write, run a process or reach the network"; printf '       %s\n' "$WRITERS"; }

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  skip "golden precedes the resolver: not a git checkout"
elif [ "$(git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
  skip "golden precedes the resolver: a shallow clone has no history to compare"
else
  GOLDEN_SHA="$(git -C "$REPO" log --diff-filter=A --format=%H -1 -- test/fixtures/skills-baseline/golden.json)"
  RESOLVER_SHA="$(git -C "$REPO" log --diff-filter=A --format=%H -1 -- bin/lib/skills_resolver.py)"
  if [ -z "$GOLDEN_SHA" ]; then
    bad "golden precedes the resolver: golden.json is not committed (INV-S3: it is committed before the resolver exists)"
  elif [ -z "$RESOLVER_SHA" ]; then
    ok "golden precedes the resolver: golden.json is committed at ${GOLDEN_SHA:0:8}, the resolver is not committed yet"
  elif [ "$GOLDEN_SHA" != "$RESOLVER_SHA" ] && git -C "$REPO" merge-base --is-ancestor "$GOLDEN_SHA" "$RESOLVER_SHA"; then
    ok "golden precedes the resolver: ${GOLDEN_SHA:0:8} is an ancestor of ${RESOLVER_SHA:0:8}"
  else
    bad "golden precedes the resolver: golden.json (${GOLDEN_SHA:0:8}) is not an ancestor of skills_resolver.py (${RESOLVER_SHA:0:8}) -- INV-S3"
  fi
fi

echo "B-D. parity, contract, mutants"
cat > "$WORK/driver.py" <<'PYEOF'
"""driver.py -- runs every case of the golden through the resolver CLI (a real process per call) and reports what differs.

    driver.py REPO WORK MANIFEST PYTHON

One record per line: `PASS <what>`, `FAIL <what>` (indented detail lines follow it), then `DONE`. No DONE means the driver died.
"""
import concurrent.futures
import hashlib
import json
import os
import re
import subprocess
import sys

REPO, WORK, MANIFEST, PYTHON = sys.argv[1:5]
REPO_MANIFEST = REPO + "/skills.manifest.json"
RESOLVER = REPO + "/bin/lib/skills_resolver.py"
FIXTURES = REPO + "/test/fixtures/skills-baseline"
TIMEOUT_S = 60
JOBS = max(1, min(8, os.cpu_count() or 2))
SHOWN = 4  # mismatching cases listed under a failing category

DOMAIN_LINE = re.compile(r"^Domain detected: (\S+) \(from ")
SKILL_LINE = re.compile("^  (⚠|✔) " + r"(\S+) " + "—" + r" (.*)$")


def say(verdict, what, *details):
    print("%s %s" % (verdict, what))
    for line in details:
        print("    " + line)


def short(value):
    text = ascii(value)
    return text if len(text) <= 240 else text[:237] + "..."


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)


class Box(object):
    """One case's private world: its own HOME (installed skills, settings.json) and project tree. Nothing is shared between cases."""

    def __init__(self, tag, case):
        root = "%s/%s" % (WORK, tag)
        self.home, self.proj = root + "/home", root + "/proj"
        os.makedirs(self.home)
        os.makedirs(self.proj)
        for rel, body in case.get("files", {}).items():
            write(self.proj + "/" + rel, body)
        for skill in case.get("installed_skills", []):
            os.makedirs(self.home + "/.claude/skills/" + skill)
        if "settings" in case:
            write(self.home + "/.claude/settings.json", json.dumps(case["settings"]))
        self.settings = self.home + "/.claude/settings.json"
        self.prompt_file = root + "/prompt.txt"
        write(self.prompt_file, case.get("prompt", ""))


def run(box, argv, bytecode=False):
    flags = [PYTHON, "-I"] if bytecode else [PYTHON, "-B", "-I"]
    done = subprocess.run(flags + [RESOLVER] + argv, env={"PATH": "/usr/bin:/bin", "HOME": box.home, "LC_ALL": "C"}, cwd=box.proj,
                          stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=TIMEOUT_S)
    return done.returncode, done.stdout.decode("utf-8", "replace"), done.stderr.decode("utf-8", "replace")


def resolve(box, manifest, command, *args):
    return run(box, [command, "--manifest", manifest] + list(args))


def as_lines(text):
    """The stdout of a subcommand that prints a list, as its lines; None when it is not a clean newline-terminated list."""
    if text == "":
        return []
    lines = text.split("\n")
    if lines.pop() != "" or "" in lines:
        return None
    return lines


def check_list(what, expected, rc, out, err, keep=None):
    if rc != 0:
        return ["%s: exit %d, stderr %s" % (what, rc, short(err.strip()[-200:]))]
    lines = as_lines(out)
    if lines is None:
        return ["%s: stdout is not a clean list of lines: %s" % (what, short(out))]
    if keep is not None:
        lines = [item for item in lines if keep(item)]
    if lines != expected:
        return ["%s: expected %s, got %s" % (what, short(expected), short(lines))]
    return []


def check_text(what, expected, rc, out, err):
    if rc != expected["rc"] or out != expected["stdout"]:
        return ["%s: expected exit %d %s, got exit %d %s %s" % (what, expected["rc"], short(expected["stdout"]), rc, short(out),
                                                              short(err.strip()[-120:]) if err.strip() else "")]
    return []


def check_preinstall(box, case, expected, manifest):
    rc, out, err = resolve(box, manifest, "preinstall", "--prompt-file", box.prompt_file, "--project", box.proj)
    keep = None
    if "installed" in case:
        listed = "".join(item + "\n" for item in case["installed"])  # what the fake `claude plugins list` printed
        keep = lambda ref: ref.split("@", 1)[0] not in listed
    return check_list("preinstall", expected, rc, out, err, keep)


def check_keyword(box, case, expected, manifest):
    rc, out, err = resolve(box, manifest, "keyword-match", "--prompt-file", box.prompt_file)
    return check_list("keyword-match", expected, rc, out, err)


def check_activate(box, case, expected, manifest):
    rc, out, err = resolve(box, manifest, "activate-set", "--project", box.proj)
    problems = check_list("activate-set", expected["needed"], rc, out, err)
    rc, out, err = resolve(box, manifest, "status", "--project", box.proj, "--settings", box.settings)
    return problems + check_text("status", {"rc": 0, "stdout": expected["status"]}, rc, out, err)


def check_detect(box, case, expected, manifest):
    return check_text("detect", expected, *resolve(box, manifest, "detect", "--prompt-file", box.prompt_file))


def check_gaps(box, case, expected, manifest):
    return check_text("gaps", expected, *resolve(box, manifest, "gaps"))


def check_detect_file(box, case, expected, manifest):
    problems = check_text("detect-file", expected, *resolve(box, manifest, "detect-file", "--file", case["path"]))
    domain = DOMAIN_LINE.match(expected["stdout"])
    if domain is None:
        return problems
    # domain-skills is the reader detect-file is built on: what it lists must be what the legacy script printed for that domain
    printed = [(m.group(2), "installed" if m.group(1) == "✔" else "NOT INSTALLED", m.group(3))
               for m in map(SKILL_LINE.match, expected["stdout"].split("\n")) if m]
    rc, out, err = resolve(box, manifest, "domain-skills", "--domain", domain.group(1))
    lines = as_lines(out)
    if rc != 0 or lines is None:
        return problems + ["domain-skills: exit %d, stdout %s" % (rc, short(out))]
    listed = [(f[0], f[2], f[3]) for f in (line.split("|", 3) for line in lines) if len(f) == 4]
    if listed != printed:
        problems.append("domain-skills %s: expected %s, got %s" % (domain.group(1), short(printed), short(listed)))
    return problems


CHECKS = {
    "preinstall": check_preinstall,
    "preinstall_installed": check_preinstall,
    "keyword_match": check_keyword,
    "activate": check_activate,
    "discover_detect": check_detect,
    "discover_detect_file": check_detect_file,
    "discover_gaps": check_gaps,
}


def check_case(tag, category, case, expected, manifest):
    try:
        return CHECKS[category](Box(tag, case), case, expected, manifest)
    except Exception as exc:  # a case that cannot run is a case that differs, never a case that is skipped
        return ["raised %s: %s" % (type(exc).__name__, exc)]


# ── B. parity: every case of the golden ──
def parity():
    with open(FIXTURES + "/golden.json", encoding="utf-8") as handle:
        golden = json.load(handle)["cases"]
    with open(FIXTURES + "/inputs.json", encoding="utf-8") as handle:
        inputs = json.load(handle)["cases"]
    tasks, structural = [], []
    for category, answers in golden.items():
        if category not in CHECKS:
            structural.append("golden category %s has no check in this suite: it would go unchecked" % category)
            continue
        by_id = {row["id"]: row for row in inputs.get(category, [])}
        for index, (case_id, expected) in enumerate(answers.items()):
            if case_id not in by_id:
                structural.append("golden case %s/%s has no input in inputs.json" % (category, case_id))
                continue
            tasks.append((category, case_id, "%s-%d" % (category, index), by_id[case_id], expected))
    total = sum(len(answers) for answers in golden.values())
    with concurrent.futures.ThreadPoolExecutor(max_workers=JOBS) as pool:
        results = list(pool.map(lambda t: (t[0], t[1], check_case(t[2], t[0], t[3], t[4], MANIFEST)), tasks))
    for category in golden:
        rows = [(case_id, problems) for cat, case_id, problems in results if cat == category]
        failed = [(case_id, problems) for case_id, problems in rows if problems]
        if not rows:
            continue
        if failed:
            say("FAIL", "%s: %d of %d cases differ from the golden" % (category, len(failed), len(rows)),
                *["%s: %s" % (case_id, " | ".join(problems)) for case_id, problems in failed[:SHOWN]])
        else:
            say("PASS", "%s: all %d cases equal the golden, whole output" % (category, len(rows)))
    if structural:
        say("FAIL", "coverage: the golden and the matrix do not line up", *structural[:SHOWN])
    elif len(results) != total or total == 0:
        say("FAIL", "coverage: %d of %d golden cases were run" % (len(results), total))
    else:
        say("PASS", "coverage: all %d golden cases were run through the resolver" % total)
    return golden, inputs


# ── C. contract ──
def snapshot(*roots):
    state = {}
    for root in roots:
        for base, dirs, files in os.walk(root):
            dirs.sort()
            for name in dirs:
                state[os.path.join(base, name)] = "dir"
            for name in sorted(files):
                path = os.path.join(base, name)
                with open(path, "rb") as handle:
                    state[path] = hashlib.sha256(handle.read()).hexdigest()
    return state


def bytecode_state():
    cache = REPO + "/bin/lib/__pycache__"
    if not os.path.isdir(cache):
        return None
    return {name: (os.stat(cache + "/" + name).st_mtime_ns, os.stat(cache + "/" + name).st_size) for name in os.listdir(cache)}


def contract(golden, inputs):
    box = Box("contract", {})
    empty = WORK + "/empty-manifest.json"
    write(empty, "{}")
    write(box.settings, "[]")
    scenarios = [
        ("no subcommand is a usage error (exit 2)", [], 2),
        ("an unknown subcommand is a usage error (exit 2)", ["bogus", "--manifest", MANIFEST], 2),
        ("a missing --manifest is a usage error (exit 2)", ["gaps"], 2),
        ("a manifest that does not exist exits 3 and prints nothing", ["gaps", "--manifest", WORK + "/none.json"], 3),
        ("a manifest that is not a valid manifest exits 3 and prints nothing", ["gaps", "--manifest", empty], 3),
        ("a prompt file that does not exist exits 3 and prints nothing",
         ["keyword-match", "--manifest", MANIFEST, "--prompt-file", WORK + "/none.txt"], 3),
        ("settings that are not an object exit 3 and print nothing",
         ["status", "--manifest", MANIFEST, "--project", box.proj, "--settings", box.settings], 3),
    ]
    for label, argv, want in scenarios:
        rc, out, err = run(box, argv)
        if rc == want and out == "" and err.strip():
            say("PASS", "contract: " + label)
        else:
            say("FAIL", "contract: " + label, "exit %d, stdout %s, stderr %s" % (rc, short(out), short(err.strip()[-160:])))

    # the two defaults the parity runs above always override: settings.json and the installed skills are read from HOME unless told otherwise
    mixed = next(row for row in inputs["activate"] if row["id"] == "act-settings-mixed")
    mixed_box = Box("home-settings", mixed)
    problems = check_text("status without --settings", {"rc": 0, "stdout": golden["activate"]["act-settings-mixed"]["status"]},
                          *run(mixed_box, ["status", "--manifest", MANIFEST, "--project", mixed_box.proj]))
    full = next(row for row in inputs["discover_gaps"] if row["id"] == "gaps-all-installed")
    elsewhere = Box("skills-dir", {})  # its HOME has no skills: only --skills-dir can make every skill installed
    for skill in full["installed_skills"]:
        os.makedirs("%s/elsewhere/%s" % (elsewhere.home, skill))
    problems += check_text("gaps --skills-dir", golden["discover_gaps"]["gaps-all-installed"],
                           *run(elsewhere, ["gaps", "--manifest", MANIFEST, "--skills-dir", elsewhere.home + "/elsewhere"]))
    if problems:
        say("FAIL", "contract: settings and installed skills default to HOME, and --skills-dir / --settings override it", *problems)
    else:
        say("PASS", "contract: settings.json and ~/.claude/skills are read from HOME by default, and --skills-dir overrides the skills directory")

    case = next(row for row in inputs["activate"] if row["id"] == "act-everything")
    rich = Box("readonly", dict(case, prompt="react docker sql seo auth api slack mcp", installed_skills=["godogen", "claude-seo"]))
    target = sorted(case["files"])[0]
    before, cache_before = snapshot(rich.home, rich.proj), bytecode_state()
    calls = [["activate-set", "--manifest", MANIFEST, "--project", rich.proj],
             ["status", "--manifest", MANIFEST, "--project", rich.proj, "--settings", rich.settings],
             ["preinstall", "--manifest", MANIFEST, "--prompt-file", rich.prompt_file, "--project", rich.proj],
             ["keyword-match", "--manifest", MANIFEST, "--prompt-file", rich.prompt_file],
             ["domain-skills", "--manifest", MANIFEST, "--domain", "marketing"],
             ["gaps", "--manifest", MANIFEST],
             ["detect", "--manifest", MANIFEST, "--prompt-file", rich.prompt_file],
             ["detect-file", "--manifest", MANIFEST, "--file", target]]
    refused = [argv[0] for argv in calls if run(rich, argv, bytecode=True)[0] != 0]
    if refused:
        say("FAIL", "contract: every subcommand answers on a populated tree", "exit != 0 for: " + ", ".join(refused))
    elif snapshot(rich.home, rich.proj) != before:
        say("FAIL", "contract: the resolver changed the project or HOME it was reading")
    elif bytecode_state() != cache_before:
        say("FAIL", "contract: the resolver wrote bytecode into bin/lib (python run without -B)")
    else:
        say("PASS", "contract: all 8 subcommands read a populated tree and leave the project, HOME and bin/lib exactly as they were")


# ── D. the gate can go RED ──
def entry(doc, ident):
    return next(item for item in doc["entries"] if item["id"] == ident)


def drop_keyword(doc):
    entry(doc, "claude-seo")["keywords"].remove("serp")


def drop_ere_token(doc):
    trig = entry(doc, "frontend-design")["triggers"]
    if "|ui|" not in trig["prompt_ere"]:
        raise ValueError("the ERE of frontend-design has no |ui| token to drop")
    trig["prompt_ere"] = trig["prompt_ere"].replace("|ui|", "|")


def drop_glob(doc):
    doc["detection_rules"]["code-review"]["files"].remove("*.rs")


def reorder_rules(doc):
    first, second = entry(doc, "frontend-design")["triggers"], entry(doc, "devops-toolkit")["triggers"]
    first["order"], second["order"] = second["order"], first["order"]


MUTANTS = (("a dropped keyword", drop_keyword, "keyword_match", "kw-claude-seo-serp"),
           ("a dropped ERE token", drop_ere_token, "preinstall", "pre-tok-fe-ui"),
           ("a dropped detection glob", drop_glob, "activate", "act-top-lib-dot-rs"),
           ("two reordered rules", reorder_rules, "preinstall", "pre-multi-all8"))


def mutants(golden, inputs):
    for number, (label, mutate, category, case_id) in enumerate(MUTANTS):
        with open(REPO_MANIFEST, encoding="utf-8") as handle:
            doc = json.load(handle)
        mutate(doc)
        path = "%s/mutant-%d.json" % (WORK, number)
        write(path, json.dumps(doc))
        case = next(row for row in inputs[category] if row["id"] == case_id)
        pristine = check_case("pristine-%d" % number, category, case, golden[category][case_id], REPO_MANIFEST)
        mutated = check_case("mutant-%d" % number, category, case, golden[category][case_id], path)
        if pristine:
            say("FAIL", "mutant: %s -- the repo manifest itself differs on %s/%s" % (label, category, case_id), *pristine)
        elif not mutated:
            say("FAIL", "mutant: %s did NOT turn %s/%s red: the gate cannot see this defect" % (label, category, case_id))
        else:
            say("PASS", "mutant: %s turns %s/%s red (--manifest is honoured, the comparison is order and token sensitive)" % (label, category, case_id))


def main():
    golden, inputs = parity()
    contract(golden, inputs)
    mutants(golden, inputs)
    print("DONE")


main()
PYEOF
SYNTAX="$("$REALPY" -B -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$WORK/driver.py" 2>&1)" \
  || { bad "the parity driver is not valid python"; printf '%s\n' "$SYNTAX"; finish; }

OUT="$("$REALPY" -B -I "$WORK/driver.py" "$REPO" "$WORK" "$MANIFEST" "$REALPY" 2>&1)"; RC=$?
SAW_DONE=0
while IFS= read -r line; do
  case "$line" in
    "PASS "*) ok "${line#PASS }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
    DONE) SAW_DONE=1 ;;
    *) printf '%s\n' "$line" ;;
  esac
done <<< "$OUT"
{ [ "$SAW_DONE" -eq 1 ] && [ "$RC" -eq 0 ]; } || bad "the parity driver did not finish (exit $RC)"

finish
