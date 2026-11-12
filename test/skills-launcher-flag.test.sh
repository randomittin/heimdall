#!/usr/bin/env bash
#
# skills-launcher-flag.test.sh -- 3.x M1, T3.1: bin/heimdall takes the resolver's answer only when skills.registry is on, and takes the same decisions either way.
#
#   bash test/skills-launcher-flag.test.sh
#
# Plan: docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md (T3.1, INV-S1, INV-S2). preinstall_plugins() and discover_skills() of bin/heimdall ask
# `python3 -I bin/lib/skills_config.py get registry` and, on `on`, take the plugin refs / `name|repo` lines of bin/lib/skills_resolver.py instead of their
# inline matching. The install mechanics (hmd_install_known_plugin, hmd_skill_install) are the legacy ones in both modes. Each run below is the REAL launcher
# function, extracted with sed the way test/plugin-install-receipt.test.sh does, in a throwaway HOME / HEIMDALL_HOME / project with recording fakes of
# `claude`, `git` and `python3` on PATH (no network, nothing of the operator's home is read or written).
#
#   A. static: the file parses (bash -n) and the resolver is named only inside the two function bodies (the change is confined to them).
#   B. smoke: with the flag on each function really reaches the resolver. This runs first and stops the suite when it does not: a launcher without the
#      wiring would otherwise "pass" the comparison below by running the legacy code twice.
#   C. parity: for EVERY case of the golden's preinstall, preinstall_installed and keyword_match categories, flag off and flag on leave the same exit
#      status, stdout, stderr, `claude` call log and `git` call log (INV-S1/S2), and the comparison is not vacuous (a floor of cases that really installed).
#      Flag off never executes skills_resolver.py (the python3 wrapper's call log); flag on calls it once, as the subcommand that function replaces.
#      The skip of an already-installed skill (no matrix case has one) is checked on the keyword case with the most matches.
#   D. the prompt stays data: hostile prompts (quotes, command substitutions, newlines, a leading dash) take the same decisions in both modes and
#      run nothing (a canary file is never created).
#   E. a resolver that cannot answer (an unparseable or invalid manifest, a missing manifest, a missing resolver: exit 3 / 3 / 3 / 2) falls back to the
#      legacy code, says so on stderr, and takes the legacy decisions.
#   F. the switch: with no variable and no file the flag is off; `registry on` in the operator's skills-config.json turns it on without the variable.
#
# Exit: 0 every check passed, 1 a check failed, 2 this machine cannot run the suite.
# budget: 90 -- ~570 launcher runs (bash, a fake claude, 2-4 python3 starts each) over at most 8 workers; measured 53 s solo, the rest is headroom for a loaded sweep.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LAUNCHER="$REPO/bin/heimdall"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
finish() {
  echo "--------------------------------------------------------------------"
  printf 'skills-launcher-flag: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
# the real interpreter, not a version-manager shim (0.3-0.8 s a call, and this suite starts ~1500 of them)
REALPY="$("$PY" -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
case "$REALPY" in /*) ;; *) REALPY="" ;; esac
[ -n "$REALPY" ] && [ -x "$REALPY" ] || { echo "FATAL: cannot resolve the interpreter behind $PY"; exit 2; }
[ -f "$LAUNCHER" ] && [ -f "$REPO/skills.manifest.json" ] && [ -f "$REPO/bin/lib/skills_resolver.py" ] && [ -f "$REPO/bin/lib/skills_config.py" ] \
  || { echo "FATAL: the launcher, the manifest, the resolver or the config helper is missing"; exit 2; }
[ -f "$REPO/test/fixtures/skills-baseline/golden.json" ] && [ -f "$REPO/test/fixtures/skills-baseline/inputs.json" ] \
  || { echo "FATAL: the golden or the input matrix is missing (test/fixtures/skills-baseline)"; exit 2; }
WORK="$(mktemp -d)" || { echo "FATAL: cannot make a temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

echo "A. static"
if bash -n "$LAUNCHER" 2>"$WORK/syntax.err"; then ok "bin/heimdall parses (bash -n)"; else bad "bin/heimdall does not parse: $(head -c 300 "$WORK/syntax.err")"; fi
body() { sed -n "/^$1()/,/^}/p" "$LAUNCHER"; }
TOTAL="$(grep -c 'skills_resolver\.py' "$LAUNCHER" || true)"
INSIDE="$( { body preinstall_plugins; body discover_skills; } | grep -c 'skills_resolver\.py' || true)"
if [ "$TOTAL" -ge 2 ] && [ "$TOTAL" = "$INSIDE" ]; then
  ok "skills_resolver.py is named $TOTAL times in bin/heimdall, every one inside preinstall_plugins() or discover_skills()"
else
  bad "skills_resolver.py is named $TOTAL times in bin/heimdall, $INSIDE inside the two function bodies (want >= 2, all of them inside)"
fi
for fn in preinstall_plugins discover_skills; do
  if [ "$(body "$fn" | grep -c 'skills_config\.py" get registry')" -ge 1 ]; then
    ok "$fn() asks skills_config.py for the registry flag"
  else
    bad "$fn() never asks skills_config.py get registry"
  fi
done

echo "B-F. behaviour"
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
# a recording fake of the Claude CLI: every call is logged; `plugins` state lives in $FAKE_STATE/{installed,markets}
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
echo "claude $*" >> "${FAKE_CALLS:-/dev/null}"
case "${1:-}" in plugin|plugins) ;; *) exit 0 ;; esac
case "${2:-}" in
  install)
    echo "${3:-}" >> "$FAKE_STATE/installed"
    echo "Successfully installed plugin: ${3:-} (scope: user)" ;;
  list)
    if [ "${3:-}" = "--json" ]; then echo "[]"; else cat "$FAKE_STATE/installed"; fi ;;
  marketplace)
    case "${3:-}" in
      list) cat "$FAKE_STATE/markets" ;;
      add)
        src="${4%%#*}"
        echo "${src##*/}" >> "$FAKE_STATE/markets"
        echo "Successfully added marketplace: ${src##*/}" ;;
    esac ;;
esac
exit 0
SH
# a recording fake of git: `clone` is logged (tab-separated url and destination) and creates its destination; `-C <dir> rev-parse` answers a fixed sha
cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  clone)
    dest="${@: -1}"; url="${@: -2:1}"
    printf 'clone\t%s\t%s\n' "$url" "$dest" >> "${FAKE_GIT_CALLS:-/dev/null}"
    mkdir -p "$dest/.git"
    exit 0 ;;
  -C)
    shift 2
    [ "${1:-}" = "rev-parse" ] && { echo "abc1234def56"; exit 0; } ;;
esac
exit 0
SH
# a recording python3: one line per call (every argument, cut at its first newline so a -c program is one short line), then the real interpreter.
# This is how "flag off never executes skills_resolver.py" is observed.
cat > "$FAKEBIN/python3" <<'SH'
#!/usr/bin/env bash
line="python3"
for arg in "$@"; do line="$line ${arg%%$'\n'*}"; done
printf '%s\n' "$line" >> "${FAKE_PY_CALLS:-/dev/null}"
exec "$REAL_PYTHON" "$@"
SH
chmod +x "$FAKEBIN/claude" "$FAKEBIN/git" "$FAKEBIN/python3"

cat > "$WORK/driver.py" <<'PYEOF'
"""driver.py -- runs the real launcher functions with the registry flag off and on and reports what differs.

    driver.py REPO WORK PYTHON

One record per line: `PASS <what>`, `FAIL <what>` (indented detail lines follow it), then `DONE`. No DONE means the driver died.
"""
import collections
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys

REPO, WORK, PYTHON = sys.argv[1:4]
FIXTURES = REPO + "/test/fixtures/skills-baseline"
CHILD_PATH = WORK + "/fakebin:/usr/bin:/bin"
BASH = shutil.which("bash", path="/usr/bin:/bin")
TIMEOUT_S = 120
JOBS = max(1, min(8, os.cpu_count() or 2))
SHOWN = 4  # offenders listed under a failing check

# category -> (the bin/heimdall function it exercises, the resolver subcommand that function's flag-on path calls)
CATEGORIES = {
    "preinstall": ("preinstall_plugins", "preinstall"),
    "preinstall_installed": ("preinstall_plugins", "preinstall"),
    "keyword_match": ("discover_skills", "keyword-match"),
}
FIELDS = (("exit status", "rc"), ("stdout", "out"), ("stderr", "err"), ("claude call log", "claude"), ("git call log", "git"))
LEGACY_FIELDS = tuple(field for field in FIELDS if field[1] != "err")  # a fallback adds a notice to stderr, on purpose
NOTICE = "using the built-in skill selection"

# The function of bin/heimdall, run unmodified. PLUGIN_DIR and WORK_DIR are what the launcher has set when it calls them; the shell is strict like the
# launcher's (set -euo pipefail), so a line that trips it fails the run instead of hiding.
SNIPPET = r'''
set -euo pipefail
. "$REPO/bin/lib/install-receipt.sh"
. "$REPO/bin/lib/skills_consent.sh"
eval "$(sed -n "/^${FN}()/,/^}/p" "$REPO/bin/heimdall")"
WORK_DIR="$PROJ"
PLUGIN_DIR="$PLUGIN"
"$FN" "$PROMPT"
'''

# every one carries ` ui react`, so each function has something to install; PWNED is what a prompt that reached a shell or python source would create
HOSTILE = (
    "'''; open('PWNED','w').close(); ''' ui react",
    '"""; import os; os.system("touch PWNED"); """ ui react',
    "$(touch PWNED) ui react",
    "`touch PWNED` ui react",
    "'; touch PWNED; ' ui react",
    "line one docker\nline two ui react",
    "back\\slash \\' \\n ui react",
    "-n ui react",
)

Run = collections.namedtuple("Run", "rc out err claude git py box")


def say(verdict, what, *details):
    print("%s %s" % (verdict, what))
    for line in details:
        print("    " + line)


def short(value):
    text = ascii(value)
    return text if len(text) <= 200 else text[:197] + "..."


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


class Box(object):
    """One run's private world: its own HOME, HEIMDALL_HOME, fake-claude state, call logs and project tree. Nothing is shared between runs."""

    def __init__(self, tag, case):
        self.root = "%s/%s" % (WORK, tag)
        self.home, self.hh, self.state, self.proj = (self.root + "/" + name for name in ("home", "hh", "state", "proj"))
        self.claude_log, self.git_log, self.py_log = (self.root + "/" + name for name in ("claude.log", "git.log", "python.log"))
        for directory in (self.home, self.hh, self.state, self.proj):
            os.makedirs(directory)
        write(self.state + "/installed", "".join(item + "\n" for item in case.get("installed", [])))
        write(self.state + "/markets", "")
        for log in (self.claude_log, self.git_log, self.py_log):
            write(log, "")
        for rel, body in case.get("files", {}).items():
            write(self.proj + "/" + rel, body)
        for skill in case.get("installed_skills", []):
            os.makedirs(self.home + "/.claude/skills/" + skill)


def launch(tag, function, case, registry, plugin=REPO, config=None):
    """The function over `case` in its own box. registry: "on" | "off" for HMD_SKILLS_REGISTRY, None for the variable unset."""
    box = Box(tag, case)
    if config is not None:
        write(box.hh + "/skills-config.json", config)
    env = {
        "PATH": CHILD_PATH, "HOME": box.home, "HEIMDALL_HOME": box.hh, "HMD_RUN_ID": "skills-launcher-flag", "LC_ALL": "C",
        "PYTHONIOENCODING": "utf-8", "HMD_SKILLS_CONSENT": "auto", "REAL_PYTHON": PYTHON,
        "FAKE_STATE": box.state, "FAKE_CALLS": box.claude_log, "FAKE_GIT_CALLS": box.git_log, "FAKE_PY_CALLS": box.py_log,
        "REPO": REPO, "PLUGIN": plugin, "PROJ": box.proj, "FN": function, "PROMPT": case["prompt"],
    }
    if registry is not None:
        env["HMD_SKILLS_REGISTRY"] = registry

    def clean(text):  # the two boxes of a pair differ only by their root: the destination of a clone is the one place it shows
        return text.replace(box.root, "<box>")

    try:
        done = subprocess.run([BASH, "-c", SNIPPET], env=env, cwd=box.proj, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return Run(-1, "", "no answer after %d s" % TIMEOUT_S, "", "", "", box)
    return Run(done.returncode, clean(done.stdout.decode("utf-8", "replace")), clean(done.stderr.decode("utf-8", "replace")),
               clean(read(box.claude_log)), clean(read(box.git_log)), read(box.py_log), box)


def differences(base, other, fields=FIELDS):
    return ["%s: legacy %s, registry %s" % (name, short(getattr(base, field)), short(getattr(other, field)))
            for name, field in fields if getattr(base, field) != getattr(other, field)]


def attempts(run):
    """What the run tried to install: the `claude plugins install` calls and the git clones."""
    return ([line for line in run.claude.splitlines() if line.startswith("claude plugins install ")]
            + [line for line in run.git.splitlines() if line.startswith("clone\t")])


def resolver_calls(run):
    return [line for line in run.py.splitlines() if "skills_resolver.py" in line]


def gate_calls(run):
    return [line for line in run.py.splitlines() if "skills_config.py get registry" in line]


def asked(run, subcommand):
    """The run called the resolver exactly once, as `subcommand`, with the plugin dir's manifest and the prompt on stdin."""
    calls = resolver_calls(run)
    return len(calls) == 1 and " %s " % subcommand in calls[0] and "--prompt-file /dev/stdin" in calls[0]


def verdict(good, passed, failed, offenders=()):
    if good:
        say("PASS", passed)
    else:
        say("FAIL", failed, *list(offenders)[:SHOWN])


def load():
    with open(FIXTURES + "/golden.json", encoding="utf-8") as handle:
        golden = json.load(handle)["cases"]
    with open(FIXTURES + "/inputs.json", encoding="utf-8") as handle:
        inputs = json.load(handle)["cases"]
    return golden, inputs


# ── B. the wiring is reached at all ──
def smoke(inputs):
    reached = True
    for category in ("preinstall", "keyword_match"):
        function, subcommand = CATEGORIES[category]
        run = launch("smoke-" + category, function, inputs[category][0], "on")
        if run.rc == 0 and asked(run, subcommand):
            say("PASS", "smoke: with the registry on, %s() calls the resolver as `%s`" % (function, subcommand))
        else:
            reached = False
            say("FAIL", "smoke: with the registry on, %s() did not call the resolver as `%s` (exit %d, resolver calls %s): bin/heimdall has no flag "
                "wiring in it (T3.1)" % (function, subcommand, run.rc, short(resolver_calls(run))), "stderr: " + short(run.err.strip()[-200:]))
    return reached


# ── C. parity over the whole matrix ──
def run_pair(category, case_id, case):
    function = CATEGORIES[category][0]
    tag = "%s-%s" % (category, case_id)
    return launch(tag + "-off", function, case, "off"), launch(tag + "-on", function, case, "on")


def matrix(golden, inputs):
    """{category: [(case id, case, flag-off run, flag-on run)]} in golden order; None when the golden and the inputs disagree on what the cases are."""
    plan = []
    for category in CATEGORIES:
        by_id = {row["id"]: row for row in inputs[category]}
        if set(by_id) != set(golden[category]):
            say("FAIL", "%s: the golden and the input matrix hold different cases (%s)" % (
                category, short(sorted(set(by_id) ^ set(golden[category]))[:6])))
            return None
        plan += [(category, case_id, by_id[case_id]) for case_id in golden[category]]
    with concurrent.futures.ThreadPoolExecutor(max_workers=JOBS) as pool:
        futures = [pool.submit(run_pair, *item) for item in plan]
    found = {category: [] for category in CATEGORIES}
    for (category, case_id, case), future in zip(plan, futures):
        found[category].append((case_id, case) + future.result())
    return found


def check_category(category, entries):
    function, subcommand = CATEGORIES[category]
    broken, differing, leaked, unconsulted, unanswered, attempted = [], [], [], [], [], 0
    for case_id, _case, off, on in entries:
        if off.rc != 0 or on.rc != 0:
            failed = off if off.rc != 0 else on
            broken.append("%s: exit %d (registry %s), stderr %s" % (case_id, failed.rc, "off" if failed is off else "on", short(failed.err.strip()[-160:])))
            continue
        differing += ["%s: %s" % (case_id, diff) for diff in differences(off, on)]
        attempted += 1 if attempts(off) else 0
        if resolver_calls(off):
            leaked.append(case_id)
        if not gate_calls(off):
            unconsulted.append(case_id)
        if not asked(on, subcommand):
            unanswered.append("%s: %s" % (case_id, short(resolver_calls(on))))
    total, floor = len(entries), max(1, len(entries) // 3)
    verdict(not broken and not differing,
            "%s: %d cases, registry off and on leave the same exit status, stdout, stderr, claude and git call logs (%s())" % (category, total, function),
            "%s: registry off and on differ, or a run failed" % category, broken + differing)
    verdict(attempted >= floor,
            "%s: not vacuous, %d of %d cases made install attempts (floor %d)" % (category, attempted, total, floor),
            "%s: only %d of %d cases made install attempts (floor %d): the comparison proves nothing" % (category, attempted, total, floor))
    verdict(not leaked and not unconsulted,
            "%s: registry off never executes skills_resolver.py and every run asks skills_config.py for the flag" % category,
            "%s: registry off executed the resolver in %d run(s) and skipped the flag check in %d" % (category, len(leaked), len(unconsulted)),
            ["resolver ran: " + ", ".join(leaked[:SHOWN])] * bool(leaked) + ["no flag check: " + ", ".join(unconsulted[:SHOWN])] * bool(unconsulted))
    verdict(not unanswered,
            "%s: registry on calls the resolver once per run, as `%s`, with the prompt on stdin" % (category, subcommand),
            "%s: registry on did not call the resolver exactly once as `%s` in %d run(s)" % (category, subcommand, len(unanswered)), unanswered)


# ── D. the prompt stays data ──
def planted_files(root):
    """Files below `root` named like the canary, in any case: the launcher lower-cases a prompt before anything that could run it sees it."""
    return ["%s/%s" % (directory, name) for directory, _subdirs, names in os.walk(root) for name in names if name.lower().startswith("pwned")]


def check_hostile():
    probe = WORK + "/canary-probe"
    write(probe + "/pwned", "")
    verdict(planted_files(probe) == [probe + "/pwned"], "hostile prompts: the canary scan finds a lower-case pwned file",
            "hostile prompts: the canary scan is blind to a lower-case pwned file, so it would never see a payload the launcher lower-cased")
    jobs = [(function, index, prompt) for function in ("preinstall_plugins", "discover_skills") for index, prompt in enumerate(HOSTILE)]

    def pair(job):
        function, index, prompt = job
        case = {"prompt": prompt}
        return (job,) + (launch("hostile-%s-%d-off" % (function, index), function, case, "off"),
                         launch("hostile-%s-%d-on" % (function, index), function, case, "on"))

    with concurrent.futures.ThreadPoolExecutor(max_workers=JOBS) as pool:
        results = list(pool.map(pair, jobs))
    problems, planted = [], []
    for (function, index, _prompt), off, on in results:
        label = "%s #%d" % (function, index)
        if off.rc != 0 or on.rc != 0:
            problems.append("%s: exit %d / %d, stderr %s" % (label, off.rc, on.rc, short((off.err or on.err).strip()[-160:])))
            continue
        problems += ["%s: %s" % (label, diff) for diff in differences(off, on)]
        if not attempts(off):
            problems.append("%s: nothing was installed, the case proves nothing" % label)
        if not asked(on, CATEGORIES["preinstall" if function == "preinstall_plugins" else "keyword_match"][1]):
            problems.append("%s: registry on did not call the resolver once with the prompt on stdin: %s" % (label, short(resolver_calls(on))))
        for run in (off, on):
            planted += ["%s: %s" % (label, path.replace(run.box.root, "<box>")) for path in planted_files(run.box.root)]
    verdict(not problems, "hostile prompts (%d, in both functions): the same decisions in both modes, the resolver reads them as data" % len(jobs),
            "hostile prompts: registry off and on differ, or the resolver was not reached", problems)
    verdict(not planted, "hostile prompts: nothing was run (no canary file in any box)", "hostile prompts ran code: canary file(s) created", planted)


# ── E. a resolver that cannot answer ──
def sandbox(tag, manifest="repo", resolver=True):
    """A copy of the plugin tree the launcher reads from, with one thing broken. manifest: "repo" keeps the real one, None leaves it out, text is written."""
    root = "%s/plugin-%s" % (WORK, tag)
    os.makedirs(root + "/bin/lib")
    for name in ["skills_config.py", "skills_manifest.py"] + (["skills_resolver.py"] if resolver else []):
        shutil.copy(REPO + "/bin/lib/" + name, root + "/bin/lib/" + name)
    shutil.copy(REPO + "/skills-registry.json", root + "/skills-registry.json")
    if manifest == "repo":
        shutil.copy(REPO + "/skills.manifest.json", root + "/skills.manifest.json")
    elif manifest is not None:
        write(root + "/skills.manifest.json", manifest)
    return root


VARIANTS = (
    ("an unparseable manifest", {"manifest": "this is not json\n"}, 3),
    ("an invalid manifest", {"manifest": '{"schema": 99}\n'}, 3),
    ("a missing manifest", {"manifest": None}, 3),
    ("a missing resolver", {"resolver": False}, 2),
)


def fallback_cases(golden, found):
    """Per category the case with the most install attempts and the first one with none (when there is one), with the flag-off run they are compared to."""
    chosen = []
    for category, entries in found.items():
        by_size = sorted(entries, key=lambda entry: (-len(golden[category][entry[0]]), entry[0]))
        chosen.append((category, by_size[0]))
        empty = [entry for entry in entries if not golden[category][entry[0]]]
        if empty:
            chosen.append((category, empty[0]))
    return chosen


def check_fallback(golden, found):
    chosen = fallback_cases(golden, found)
    for label, options, code in VARIANTS:
        plugin = sandbox(label.replace(" ", "-"), **options)

        def one(item, plugin=plugin, label=label):
            category, (case_id, case, off, _on) = item
            run = launch("fallback-%s-%s-%s" % (label.replace(" ", "-"), category, case_id), CATEGORIES[category][0], case, "on", plugin=plugin)
            return category, case_id, off, run

        with concurrent.futures.ThreadPoolExecutor(max_workers=JOBS) as pool:
            results = list(pool.map(one, chosen))
        problems = []
        for category, case_id, off, run in results:
            where = "%s/%s" % (category, case_id)
            if run.rc != 0:
                problems.append("%s: exit %d, stderr %s" % (where, run.rc, short(run.err.strip()[-160:])))
                continue
            problems += ["%s: %s" % (where, diff) for diff in differences(off, run, LEGACY_FIELDS)]
            if len(resolver_calls(run)) != 1:
                problems.append("%s: the resolver was not tried exactly once: %s" % (where, short(resolver_calls(run))))
            if NOTICE not in run.err or "exited %d" % code not in run.err:
                problems.append("%s: stderr does not say the resolver exited %d and the built-in selection is used: %s" % (where, code, short(run.err.strip()[-200:])))
        verdict(not problems,
                "fallback, %s: the resolver exits %d, the legacy decisions are taken and stderr says so (%d cases)" % (label, code, len(results)),
                "fallback, %s: the legacy code path did not take over" % label, problems)


# ── F. the switch ──
def check_switch(found):
    problems = []
    for category in ("preinstall", "keyword_match"):
        function, subcommand = CATEGORIES[category]
        case_id, case, off, _on = found[category][0]
        default = launch("default-" + category, function, case, None)
        from_file = launch("file-" + category, function, case, None, config='{"registry": "on"}\n')
        for what, run in (("no variable and no file", default), ("registry on in skills-config.json", from_file)):
            if run.rc != 0:
                problems.append("%s, %s: exit %d, stderr %s" % (function, what, run.rc, short(run.err.strip()[-160:])))
        problems += ["%s, default: %s" % (function, diff) for diff in differences(off, default)]
        problems += ["%s, from the file: %s" % (function, diff) for diff in differences(off, from_file)]
        if resolver_calls(default) or not gate_calls(default):
            problems.append("%s: with no variable and no file the flag is not off (resolver calls %s)" % (function, short(resolver_calls(default))))
        if not asked(from_file, subcommand):
            problems.append("%s: registry on in skills-config.json did not reach the resolver: %s" % (function, short(resolver_calls(from_file))))
    verdict(not problems, "switch: unset means off, and `registry on` in the operator's skills-config.json turns it on without the variable",
            "switch: the flag does not follow the config", problems)


# ── C (cont.). the skip of an installed skill: no matrix case has one, and the resolver does not know what is installed, so the launcher's skip is the wiring's ──
def check_installed_skills(golden, found):
    category = "keyword_match"
    function, subcommand = CATEGORIES[category]
    case_id, case, _off, _on = max(found[category], key=lambda entry: len(golden[category][entry[0]]))
    names = [line.split("|")[0] for line in golden[category][case_id]]
    installed = names[::2]
    variant = dict(case, installed_skills=installed)
    off = launch("installed-skills-off", function, variant, "off")
    on = launch("installed-skills-on", function, variant, "on")
    problems = []
    if off.rc != 0 or on.rc != 0:
        problems.append("exit %d (registry off) / %d (registry on), stderr %s" % (off.rc, on.rc, short((off.err or on.err).strip()[-160:])))
    else:
        problems += differences(off, on)
        if len(attempts(off)) != len(names) - len(installed) or not names or not attempts(off):
            problems.append("registry off cloned %d of the %d matched skills with %d already installed: the case proves nothing" % (
                len(attempts(off)), len(names), len(installed)))
        if not asked(on, subcommand):
            problems.append("registry on did not call the resolver once: %s" % short(resolver_calls(on)))
    verdict(not problems, "keyword_match/%s with %d of its %d skills already installed: both modes clone only the other %d" % (
        case_id, len(installed), len(names), len(names) - len(installed)),
        "keyword_match/%s with skills already installed: registry off and on differ" % case_id, problems)


def main():
    golden, inputs = load()
    if not smoke(inputs):
        print("DONE")
        return
    found = matrix(golden, inputs)
    if found is None:
        print("DONE")
        return
    for category in CATEGORIES:
        check_category(category, found[category])
    check_installed_skills(golden, found)
    check_hostile()
    check_fallback(golden, found)
    check_switch(found)
    print("DONE")


main()
PYEOF
SYNTAX="$("$REALPY" -B -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$WORK/driver.py" 2>&1)" \
  || { bad "the driver is not valid python"; printf '%s\n' "$SYNTAX"; finish; }

OUT="$("$REALPY" -B -I "$WORK/driver.py" "$REPO" "$WORK" "$REALPY" 2>&1)"; RC=$?
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
