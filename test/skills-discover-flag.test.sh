#!/usr/bin/env bash
#
# skills-discover-flag.test.sh -- 3.x M1, T3.3: the registry readers of bin/discover-skills are flag-gated. With skills.registry off they run the legacy
# code and never start the resolver; with it on they take the resolver's answer; whenever the resolver cannot answer they fall back to the legacy code.
#
#   bash test/skills-discover-flag.test.sh
#
# Plan: docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md (T3.3, INV-S1, INV-S2). The three readers are `discover-skills detect`, `detect-file` and
# `gaps`; the flag is `python3 -I bin/lib/skills_config.py get registry`; the resolver is bin/lib/skills_resolver.py (detect, detect-file, gaps).
#
# The reference is test/fixtures/skills-baseline/golden.json (the recorded answers of the unmodified legacy code), never the manifest or the resolver:
#   A. static: the files this suite needs are there, the script is valid shell.
#   B. flag off: every golden case of the three readers prints the golden answer, byte for byte, and the resolver never starts (INV-S1).
#   C. flag on: every golden case prints the golden answer and the resolver runs exactly once, with this manifest and the case's own arguments. The two
#      golden cases a legacy precondition answers first (an empty prompt, a missing file) never reach it.
#   D. where the flag comes from: the environment, a typo in the environment (never on), the environment over the file, a garbage file, a bad value.
#   E. the resolver's answer is the one used: a manifest copy with a reworded description changes the flag-on answer (and only that), and the flag-off
#      answer ignores the manifest. Without this a wiring that never branched would pass B and C.
#   F. fallback: flag on, but the resolver exits 3 (invalid, unparseable, missing manifest), exits 7 after printing part of an answer, or exits 1 with a
#      usage line. The answer is the legacy one, nothing of the failed answer reaches stdout, the resolver is tried once and stderr says so.
#   G. the legacy preconditions answer first: no registry file -> "No registry found", whatever the flag says.
#   H. data stays data (the pattern of 763c7abb): prompts and file names holding quotes, ''', command substitutions, newlines or a leading dash give the
#      same answer flag off and flag on, run nothing, and never reach the resolver's command line (a prompt goes in on stdin, a path as --file=PATH).
#   I. the commands that are not readers (install, usage) never start the resolver.
#
# The script runs from a COPY of the plugin directory (discover-skills derives its PLUGIN_DIR from its own location), so the suite can swap the manifest
# and put a spy in the resolver's place without a test seam in production code. Hermetic: throwaway HOME and HEIMDALL_HOME, no network, nothing installed
# (the sed of the install path that BSD sed rejects is not on any path run here: the install mechanics are untouched).
#
# Exit: 0 every check passed, 1 a check failed, 2 this machine cannot run the suite.
# budget: 30 -- an estimate, not a measurement: ~250 short processes (bash plus two python3 -I startups, tens of ms each) over at most 8 workers. The
# sweep's receipt holds the measured time.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
finish() {
  echo "--------------------------------------------------------------------"
  printf 'skills-discover-flag: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
# the real interpreter, not a version-manager shim (0.3-0.8 s a call, and this suite starts ~500 of them)
REALPY="$("$PY" -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
case "$REALPY" in /*) ;; *) REALPY="" ;; esac
[ -n "$REALPY" ] && [ -x "$REALPY" ] || { echo "FATAL: cannot resolve the interpreter behind $PY"; exit 2; }
WORK="$(mktemp -d)" || { echo "FATAL: cannot make a temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

echo "A. static"
MISSING=""
for needed in bin/discover-skills bin/lib/skills_config.py bin/lib/skills_manifest.py bin/lib/skills_resolver.py skills-registry.json skills.manifest.json \
              test/fixtures/skills-baseline/golden.json test/fixtures/skills-baseline/inputs.json; do
  [ -f "$REPO/$needed" ] || MISSING="$MISSING $needed"
done
if [ -n "$MISSING" ]; then
  bad "the files this suite runs against exist (missing:$MISSING)"
  finish
fi
ok "the call site, the flag reader, the resolver, the manifests and the golden are all there"
if bash -n "$REPO/bin/discover-skills" 2>/dev/null; then ok "bin/discover-skills is valid shell"; else bad "bin/discover-skills is not valid shell (bash -n)"; fi
BASH_BIN="$(PATH=/usr/bin:/bin command -v bash || true)"
[ -n "$BASH_BIN" ] || { echo "FATAL: no bash in /usr/bin or /bin"; exit 2; }

echo "B-I. flag off, flag on, fallback"
# discover-skills calls `python3` from PATH: a wrapper in front of PATH execs the real interpreter, so a version-manager shim costs nothing per call
mkdir -p "$WORK/bin" || { echo "FATAL: cannot make $WORK/bin"; exit 2; }
printf '#!/bin/sh\nexec "%s" "$@"\n' "$REALPY" > "$WORK/bin/python3"
chmod 755 "$WORK/bin/python3"

cat > "$WORK/driver.py" <<'PYEOF'
"""driver.py -- every golden case of the three readers through the real bin/discover-skills, flag off and flag on, and the paths that must fall back.

    driver.py REPO WORK BASH

One record per line: `PASS <what>`, `FAIL <what>` (indented detail lines follow it), then `DONE`. No DONE means the driver died.
"""
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys

REPO, BASH = sys.argv[1], sys.argv[3]
WORK = os.path.realpath(sys.argv[2])  # discover-skills resolves its own path (readlink -f): /var and /private/var must not differ
FIXTURES = REPO + "/test/fixtures/skills-baseline"
TIMEOUT_S = 90
JOBS = max(1, min(8, os.cpu_count() or 2))
SHOWN = 4  # mismatching cases listed under a failing category
STDIN = "/dev/stdin"  # where a flag-on `detect` hands the prompt to the resolver: data on stdin, never on the command line
FLAG_ON = json.dumps({"registry": "on"}) + "\n"
FLAG_OFF = json.dumps({"registry": "off"}) + "\n"
ABSENT = object()
KINDS = ("discover_detect", "discover_detect_file", "discover_gaps")

# what the plugin directory's skills_resolver.py is, in each scenario. All of them log their argv (one JSON list a line) first, so a call is always seen.
LOG_ARGV = ("import json, os, sys\n"
            "with open(os.environ['SKILLS_SPY_LOG'], 'a', encoding='utf-8') as log:\n"
            "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n")
SPY = LOG_ARGV + ("real = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'skills_resolver_real.py')\n"
                  "os.execv(sys.executable, [sys.executable, '-I', real] + sys.argv[1:])\n")
CRASH = LOG_ARGV + "sys.stdout.write('PARTIAL ANSWER\\n')\nsys.stdout.flush()\nsys.exit(7)\n"
USAGE_EXIT = LOG_ARGV + "sys.stdout.write('Usage: discover-skills detect <prompt or description>\\n')\nsys.stdout.flush()\nsys.exit(1)\n"
PLUGIN_FILES = ("bin/discover-skills", "bin/lib/skills_config.py", "bin/lib/skills_manifest.py", "skills-registry.json")


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


def load(path):
    with open(path, encoding="utf-8", newline="") as handle:
        return json.loads(handle.read())


GOLDEN = load(FIXTURES + "/golden.json")["cases"]
INPUTS = load(FIXTURES + "/inputs.json")["cases"]
BY_ID = {kind: {case["id"]: case for case in INPUTS[kind]} for kind in KINDS}
ALL = [(kind, case) for kind in KINDS for case in INPUTS[kind]]


def make_plugin(name, resolver=SPY, manifest=None, registry=True):
    """A copy of the plugin directory: the script, the flag reader, the manifest module, the legacy registry (unless `registry` is False), a manifest
    (the repo's, a given text, or none) and `resolver` in the resolver's place (the real one stays beside it as skills_resolver_real.py for the spy)."""
    root = "%s/%s" % (WORK, name)
    for rel in PLUGIN_FILES:
        if rel == "skills-registry.json" and not registry:
            continue
        os.makedirs(os.path.dirname("%s/%s" % (root, rel)), exist_ok=True)
        shutil.copy2("%s/%s" % (REPO, rel), "%s/%s" % (root, rel))
    shutil.copy2(REPO + "/bin/lib/skills_resolver.py", root + "/bin/lib/skills_resolver_real.py")
    write(root + "/bin/lib/skills_resolver.py", resolver)
    if manifest is None:
        shutil.copy2(REPO + "/skills.manifest.json", root + "/skills.manifest.json")
    elif manifest is not ABSENT:
        write(root + "/skills.manifest.json", manifest)
    return root


class Box(object):
    """One run's private world: HOME (the installed skills), HEIMDALL_HOME (the flag file), a project tree (the cwd) and the resolver's call log."""

    def __init__(self, tag, case, plugin, flag):
        self.root = "%s/%s" % (WORK, tag)
        self.plugin = plugin
        self.home, self.proj = self.root + "/home", self.root + "/proj"
        self.heimdall_home = self.home + "/.heimdall"
        self.spy = self.root + "/spy.log"
        os.makedirs(self.home)
        os.makedirs(self.proj)
        for rel, body in case.get("files", {}).items():
            write(self.proj + "/" + rel, body)
        for skill in case.get("installed_skills", []):
            os.makedirs(self.home + "/.claude/skills/" + skill)
        if flag is not None:
            write(self.heimdall_home + "/skills-config.json", flag)


def run(box, args, env=None):
    full = {"PATH": WORK + "/bin:/usr/bin:/bin", "HOME": box.home, "HEIMDALL_HOME": box.heimdall_home, "LC_ALL": "C", "PYTHONIOENCODING": "utf-8",
            "SKILLS_SPY_LOG": box.spy}
    full.update(env or {})
    done = subprocess.run([BASH, box.plugin + "/bin/discover-skills"] + args, env=full, cwd=box.proj, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=TIMEOUT_S)
    return done.returncode, done.stdout.decode("utf-8", "replace"), done.stderr.decode("utf-8", "replace")


def planted(box):
    """Whatever a payload left behind: a file whose name starts with `pwned` anywhere in the box (the payloads are `touch pwned-...`)."""
    return sorted(name for _dir, _dirs, names in os.walk(box.root) for name in names if name.startswith("pwned"))


def options_of(argv):
    """The resolver's argv as (command, {option: value}), whether an option is `--opt value` or `--opt=value`; anything else is kept as a `?N` entry."""
    command, rest, options, index = argv[0], argv[1:], {}, 0
    while index < len(rest):
        token = rest[index]
        if token.startswith("--") and "=" in token:
            key, value = token.split("=", 1)
            options[key] = value
            index += 1
        elif token.startswith("--") and index + 1 < len(rest):
            options[token] = rest[index + 1]
            index += 2
        else:
            options["?%d" % index] = token
            index += 1
    return command, options


def call_problems(box, want):
    """`want` None: the resolver must not have started. Else it must have run exactly once, with exactly the arguments `want` names."""
    try:
        with open(box.spy, encoding="utf-8") as handle:
            calls = [json.loads(line) for line in handle if line.strip()]
    except FileNotFoundError:
        calls = []
    if want is None:
        return ["the resolver started: %s" % short(calls)] if calls else []
    if len(calls) != 1:
        return ["the resolver should run exactly once, it ran %d times: %s" % (len(calls), short(calls))]
    got = options_of(calls[0])
    return [] if got == want else ["the resolver was called with %s, expected %s" % (short(got), short(want))]


def stderr_problems(err, note):
    """note False: a quiet run. note True: the fallback is said on stderr."""
    if note:
        return [] if "legacy" in err.lower() else ["stderr does not say the legacy code answered: %s" % short(err)]
    return [] if err == "" else ["unexpected stderr: %s" % short(err)]


def invocation(kind, case, plugin):
    """(the arguments of discover-skills, the resolver call a flag-on run must make)."""
    manifest = plugin + "/skills.manifest.json"
    if kind == "discover_detect":
        return ["detect", case["prompt"]], ("detect", {"--manifest": manifest, "--prompt-file": STDIN})
    if kind == "discover_detect_file":
        return ["detect-file", case["path"]], ("detect-file", {"--manifest": manifest, "--file": case["path"]})
    return ["gaps"], ("gaps", {"--manifest": manifest})


def check(prefix, item, plugin, flag, on, env=None, note=False, stdout=None):
    """One golden case through the real script. `on`: the flag is on, so the resolver is asked once -- unless a legacy precondition answers first (an
    empty prompt, a missing file: the golden exit is 1). `stdout` replaces the golden text (a case whose answer a changed manifest moves)."""
    kind, case = item
    expected = GOLDEN[kind][case["id"]]
    args, want = invocation(kind, case, plugin)
    box = Box("%s-%s-%s" % (prefix, kind, case["id"]), case, plugin, flag)
    rc, out, err = run(box, args, env)
    asked = on and expected["rc"] == 0
    want_out = expected["stdout"] if stdout is None else stdout
    problems = []
    if (rc, out) != (expected["rc"], want_out):
        problems.append("expected exit %d and %s, got exit %d and %s" % (expected["rc"], short(want_out), rc, short(out)))
    return problems + stderr_problems(err, note and asked) + call_problems(box, want if asked else None)


def sweep(label, items, fn):
    """Run `fn(item) -> [problems]` over every item, in parallel, and report ONE verdict for the category."""
    def one(item):
        name = "%s/%s" % (item[0], item[1]["id"])
        try:
            return name, fn(item)
        except Exception as exc:  # a worker that died is a failed case, not a dead driver
            return name, ["raised %s: %s" % (type(exc).__name__, exc)]

    with concurrent.futures.ThreadPoolExecutor(max_workers=JOBS) as pool:
        results = list(pool.map(one, items))
    failed = [(name, problems) for name, problems in results if problems]
    if failed:
        details = ["%s: %s" % (name, problem) for name, problems in failed[:SHOWN] for problem in problems[:3]]
        say("FAIL", "%s: %d of %d cases differ" % (label, len(failed), len(results)), *details)
    else:
        say("PASS", "%s: all %d cases" % (label, len(results)))


def verdict(label, problems):
    if problems:
        say("FAIL", label, *problems[:6])
    else:
        say("PASS", label)


def reworded_manifest():
    """(the repo's manifest with the description of ui-ux-pro-max reworded, the old text, the new one)."""
    doc = load(REPO + "/skills.manifest.json")
    entry = next(item for item in doc["entries"] if item["id"] == "ui-ux-pro-max")
    old, entry["description"] = entry["description"], entry["description"] + " (reworded)"
    return json.dumps(doc), old, entry["description"]


def compare_off_on(tag, kind, case, plugin, needle):
    """One input of our own through the real script, flag off then flag on: the same exit and stdout (and a stdout that shows the input did its job: it
    holds `needle`), a quiet stderr, one resolver call on and none off, and nothing the input could have run."""
    args, want = invocation(kind, case, plugin)
    problems, answers = [], {}
    for label, flag, expected in (("off", None, None), ("on", FLAG_ON, want)):
        box = Box("%s-%s" % (tag, label), case, plugin, flag)
        answers[label] = run(box, args)
        problems += ["flag %s: %s" % (label, problem) for problem in stderr_problems(answers[label][2], False) + call_problems(box, expected)]
        if planted(box):
            problems.append("flag %s: the input ran as code, it left %s behind" % (label, planted(box)))
    if answers["off"][:2] != answers["on"][:2]:
        problems.append("flag off answered %s, flag on %s" % (short(answers["off"][:2]), short(answers["on"][:2])))
    if needle not in answers["off"][1]:
        problems.append("the probe proves nothing: %s is not in the answer %s" % (short(needle), short(answers["off"][1])))
    return problems


def main():
    for kind in KINDS:
        golden_ids, input_ids = set(GOLDEN[kind]), [case["id"] for case in INPUTS[kind]]
        if golden_ids != set(input_ids) or len(input_ids) != len(set(input_ids)) or not input_ids:
            say("FAIL", "every golden %s case has an input and every input a golden answer" % kind, "inputs %d, golden %d" % (len(input_ids), len(golden_ids)))
            return
    say("PASS", "every golden case of the three readers has an input and every input a golden answer (%d cases)" % len(ALL))
    plugin = make_plugin("plugin")

    # B. flag off, C. flag on
    sweep("flag off: the golden answer, the resolver never starts", ALL, lambda item: check("off", item, plugin, None, False))
    sweep("flag on: the golden answer, one resolver call with this manifest and these arguments", ALL, lambda item: check("on", item, plugin, FLAG_ON, True))
    sweep("flag explicitly off in the file: the golden answer, the resolver never starts", ALL[::5],
          lambda item: check("fileoff", item, plugin, FLAG_OFF, False))

    # D. where the flag comes from
    probes = [(kind, BY_ID[kind][ident]) for kind, ident in (("discover_detect", "det-design-landing"), ("discover_detect_file", "file-ext-tsx"),
                                                              ("discover_gaps", "gaps-none-installed"))]
    sources = (("HMD_SKILLS_REGISTRY=on and no file", None, {"HMD_SKILLS_REGISTRY": "on"}, True),
               ("HMD_SKILLS_REGISTRY=maybe over a file that says on (a typo is off, never on)", FLAG_ON, {"HMD_SKILLS_REGISTRY": "maybe"}, False),
               ("HMD_SKILLS_REGISTRY=off over a file that says on (the environment wins)", FLAG_ON, {"HMD_SKILLS_REGISTRY": "off"}, False),
               ("a flag file that is not JSON", "not json\n", None, False),
               ("a flag file whose registry is not on or off", json.dumps({"registry": "maybe"}) + "\n", None, False))
    for number, (label, flag, env, resolver_runs) in enumerate(sources):
        problems = [problem for item in probes for problem in check("src%d" % number, item, plugin, flag, resolver_runs, env)]
        verdict("flag source: %s -> the resolver %s" % (label, "answers" if resolver_runs else "never starts"), problems)

    # E. the resolver's answer is the one used
    text, old, new = reworded_manifest()
    mutant = make_plugin("plugin-mutant", manifest=text)
    consumed = []
    for kind, ident in (("discover_detect", "det-design-landing"), ("discover_detect_file", "file-ext-tsx"),
                        ("discover_detect_file", "file-content-tailwind"), ("discover_gaps", "gaps-none-installed")):
        item, golden_out = (kind, BY_ID[kind][ident]), GOLDEN[kind][ident]["stdout"]
        if old not in golden_out:
            consumed.append("%s: the probe proves nothing, the golden answer does not hold the description %s" % (ident, short(old)))
            continue
        consumed += ["%s: %s" % (ident, problem) for problem in check("mut-on", item, mutant, FLAG_ON, True, stdout=golden_out.replace(old, new))]
        consumed += ["%s, flag off: %s" % (ident, problem) for problem in check("mut-off", item, mutant, None, False)]
    verdict("a manifest with a reworded description changes the flag-on answers, and not the flag-off ones", consumed)

    # F. fallback to the legacy code
    scenarios = (("a manifest that is not valid (the resolver exits 3)", make_plugin("plugin-invalid", manifest='{"schema": 1}')),
                 ("a manifest that is not JSON (exit 3)", make_plugin("plugin-garbage", manifest="not json")),
                 ("a manifest that is missing (exit 3)", make_plugin("plugin-nomanifest", manifest=ABSENT)),
                 ("a resolver that prints part of an answer and exits 7", make_plugin("plugin-crash", resolver=CRASH)),
                 ("a resolver that exits 1 with a usage line (its legacy answer, which a call site never asks for)",
                  make_plugin("plugin-usage-exit", resolver=USAGE_EXIT)))
    fallback_probes = probes + [("discover_detect_file", BY_ID["discover_detect_file"]["file-content-tailwind"])]
    for number, (label, broken) in enumerate(scenarios):
        problems = [problem for item in fallback_probes for problem in check("fb%d" % number, item, broken, FLAG_ON, True, note=True)]
        verdict("flag on, %s: the legacy answer, said on stderr, nothing of the failed answer on stdout" % label, problems)

    # G. the legacy preconditions answer first
    noreg = make_plugin("plugin-noreg", registry=False)
    problems = []
    for number, (kind, args) in enumerate((("discover_gaps", ["gaps"]), ("discover_detect", ["detect", "design a landing page"]))):
        box = Box("noreg-%d" % number, {}, noreg, FLAG_ON)
        rc, out, err = run(box, args)
        if (rc, out) != (0, "No registry found\n"):
            problems.append("%s: expected exit 0 and 'No registry found', got exit %d and %s" % (kind, rc, short(out)))
        problems += stderr_problems(err, False) + call_problems(box, None)
    verdict("flag on without the legacy registry file: 'No registry found', the resolver is not asked", problems)

    # H. data stays data
    prompts = (("''' and three kinds of command substitution", "x''' ; touch pwned-triple ; ''' $(touch pwned-sub) `touch pwned-tick` design"),
               ("newlines", "first line\nlanding page design\nthird line"),
               ("a leading dash that looks like the resolver's own options", "--manifest /etc/passwd design"),
               ("double quotes and a backslash", 'say "design" \\ \\n; touch pwned-quote'))
    paths = (("a space", "my file.tsx"), ("a single quote", "it's.tsx"), ("a double quote", 'q"uote.tsx'), ("a leading dash", "-lead.tsx"),
             ("a command substitution", "$(touch pwned-file).tsx"), ("a newline", "line\nbreak.tsx"))
    for number, (label, prompt) in enumerate(prompts):
        verdict("a prompt holding %s: the same answer flag off and on, nothing run, the prompt not in the resolver's arguments" % label,
                compare_off_on("data-p%d" % number, "discover_detect", {"id": "p%d" % number, "prompt": prompt}, plugin, "MISSING: ui-ux-pro-max"))
    for number, (label, path) in enumerate(paths):
        verdict("a file name holding %s: the same answer flag off and on, nothing run, the name reaches the resolver as --file=NAME" % label,
                compare_off_on("data-f%d" % number, "discover_detect_file", {"id": "f%d" % number, "path": path, "files": {path: ""}}, plugin,
                               "Domain detected: design (from %s)" % path))

    # I. the commands that are not readers
    problems = []
    for tag, args, needle in (("install", ["install", "no-such-skill"], "not in registry"), ("usage", [], "Commands:")):
        answers = {}
        for label, flag in (("off", None), ("on", FLAG_ON)):
            box = Box("raw-%s-%s" % (tag, label), {}, plugin, flag)
            answers[label] = run(box, args)
            problems += ["%s, flag %s: %s" % (tag, label, problem) for problem in call_problems(box, None)]
        if answers["off"] != answers["on"] or needle not in answers["off"][1]:
            problems.append("%s: flag off gave %s, flag on %s, expected the same text holding %s" % (tag, short(answers["off"]), short(answers["on"]), needle))
    verdict("install and the usage text: the same answer flag off and on, the resolver is not asked", problems)


main()
print("DONE")
PYEOF
SYNTAX="$("$REALPY" -B -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$WORK/driver.py" 2>&1)" \
  || { bad "the driver is not valid python"; printf '%s\n' "$SYNTAX"; finish; }

OUT="$("$REALPY" -B -I "$WORK/driver.py" "$REPO" "$WORK" "$BASH_BIN" 2>&1)"; RC=$?
SAW_DONE=0
while IFS= read -r line; do
  case "$line" in
    "PASS "*) ok "${line#PASS }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
    DONE) SAW_DONE=1 ;;
    *) printf '%s\n' "$line" ;;
  esac
done <<< "$OUT"
{ [ "$SAW_DONE" -eq 1 ] && [ "$RC" -eq 0 ]; } || bad "the driver did not finish (exit $RC)"

finish
