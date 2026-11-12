#!/usr/bin/env bash
#
# skills-activate-flag.test.sh -- 3.x M1, T3.2: the activation call sites are flag-gated. With skills.registry off they run the legacy code and never
# start the resolver; with it on they take the resolver's answer; whenever the resolver cannot answer they fall back to the legacy code.
#
#   bash test/skills-activate-flag.test.sh
#
# Plan: docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md (T3.2, INV-S1, INV-S2). The two call sites are `skill-manager status` (the inline
# python of cmd_status in bin/skill-manager) and `skill_restore.py activate` (needed_plugins in bin/lib/skill_restore.py, which `skill-manager activate`
# runs). The flag is `python3 -I bin/lib/skills_config.py get registry`; the resolver is bin/lib/skills_resolver.py (activate-set, status).
#
# The reference is test/fixtures/skills-baseline/golden.json (the recorded answers of the unmodified legacy code), never the manifest or the resolver:
#   A. static: the files this suite needs are there, the wiring is valid shell / python and installs nothing.
#   B. status: every golden activation case through `skill-manager status`, flag off and flag on: the golden text, byte for byte.
#   C. activate and restore: every golden activation case through `skill_restore.py activate` and `restore`, flag off and flag on. The expectation is a
#      small model of the documented restore rules fed with the golden `needed` set: the summary line, settings.json (bytes), the restore file
#      ({"t", "changes"}, bytes) and the undo must all match it. Flag off the resolver must never start (INV-S1); flag on it must start once, with
#      exactly the manifest, project and settings of the call.
#   D. where the flag comes from: the environment, a typo in the environment (never on), the environment over the file, a garbage file, a bad value.
#   E. the resolver's answer is the one used: a manifest copy in which caveman is no longer permanent changes the flag-on answer (and only that), and the
#      flag-off answer ignores the manifest. Without this a wiring that never branched would pass B and C.
#   F. fallback: flag on, but the resolver exits 3 (invalid, unparseable, missing manifest), exits 7 after printing part of an answer, or hangs. The
#      answer is the legacy one, nothing of a partial answer reaches stdout, and stderr says so.
#   G. the whole chain, `skill-manager activate` then `restore`, flag off and flag on.
#
# The call sites run from a COPY of the plugin directory (skill-manager derives its PLUGIN_DIR from its own location), so the suite can swap the
# manifest and put a spy in the resolver's place without a test seam in production code. Hermetic: throwaway HOME and HEIMDALL_HOME, no network.
#
# Exit: 0 every check passed, 1 a check failed, 2 this machine cannot run the suite.
# budget: 30 -- an estimate, not a measurement: ~550 short processes (bash or python3 -I startup, tens of ms each) over at most 8 workers, plus the 3 s
# timeout of section F. The sweep's receipt holds the measured time.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
finish() {
  echo "--------------------------------------------------------------------"
  printf 'skills-activate-flag: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
# the real interpreter, not a version-manager shim (0.3-0.8 s a call, and this suite starts ~550 of them)
REALPY="$("$PY" -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
case "$REALPY" in /*) ;; *) REALPY="" ;; esac
[ -n "$REALPY" ] && [ -x "$REALPY" ] || { echo "FATAL: cannot resolve the interpreter behind $PY"; exit 2; }
WORK="$(mktemp -d)" || { echo "FATAL: cannot make a temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

echo "A. static"
MISSING=""
for needed in bin/skill-manager bin/lib/skill_restore.py bin/lib/skills_config.py bin/lib/skills_manifest.py bin/lib/skills_resolver.py \
              heimdall-skills.json skills.manifest.json test/fixtures/skills-baseline/golden.json test/fixtures/skills-baseline/inputs.json; do
  [ -f "$REPO/$needed" ] || MISSING="$MISSING $needed"
done
if [ -n "$MISSING" ]; then
  bad "the files this suite runs against exist (missing:$MISSING)"
  finish
fi
ok "the call sites, the flag reader, the resolver, the manifests and the golden are all there"

if bash -n "$REPO/bin/skill-manager" 2>/dev/null; then ok "bin/skill-manager is valid shell"; else bad "bin/skill-manager is not valid shell (bash -n)"; fi
if SYNTAX="$("$REALPY" -B -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$REPO/bin/lib/skill_restore.py" 2>&1)"; then
  ok "bin/lib/skill_restore.py is valid python"
else
  bad "bin/lib/skill_restore.py is not valid python"; printf '%s\n' "$SYNTAX"
fi
INSTALLS="$(grep -cE 'claude plugins install|hmd_install_known_plugin|hmd_skill_install' "$REPO/bin/skill-manager" "$REPO/bin/lib/skill_restore.py" | grep -vc ':0$' || true)"
if [ "$INSTALLS" = "0" ]; then
  ok "the activation call sites install nothing: the resolver is pass-through, the install mechanics stay in the launcher"
else
  bad "an activation call site names an install command ($INSTALLS file(s)): it must only read the resolver's answer"
fi

echo "B-G. flag off, flag on, fallback"
# skill-manager calls `python3` from PATH: a wrapper in front of PATH execs the real interpreter, so a version-manager shim costs nothing per call
mkdir -p "$WORK/bin" || { echo "FATAL: cannot make $WORK/bin"; exit 2; }
printf '#!/bin/sh\nexec "%s" "$@"\n' "$REALPY" > "$WORK/bin/python3"
chmod 755 "$WORK/bin/python3"

cat > "$WORK/driver.py" <<'PYEOF'
"""driver.py -- every golden activation case through the two call sites, flag off and flag on, and the paths that must fall back.

    driver.py REPO WORK PYTHON

One record per line: `PASS <what>`, `FAIL <what>` (indented detail lines follow it), then `DONE`. No DONE means the driver died.
"""
import concurrent.futures
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import time

REPO, PYTHON = sys.argv[1], sys.argv[3]
WORK = os.path.realpath(sys.argv[2])  # skill-manager resolves its own path (readlink -f): /var and /private/var must not differ
FIXTURES = REPO + "/test/fixtures/skills-baseline"
TIMEOUT_S = 90
JOBS = max(1, min(8, os.cpu_count() or 2))
SHOWN = 4  # mismatching cases listed under a failing category
UNRELATED = "unrelated@elsewhere"  # a plugin no rule names: it is paused whatever the project holds
FLAG_ON = json.dumps({"registry": "on"}) + "\n"
FLAG_OFF = json.dumps({"registry": "off"}) + "\n"
ABSENT = object()

# what the plugin directory's skills_resolver.py is, in each scenario. All of them log their argv first, so a call is always seen.
LOG_ARGV = ("import os, sys\n"
            "with open(os.environ['SKILLS_SPY_LOG'], 'a', encoding='utf-8') as log:\n"
            "    log.write('\\t'.join(sys.argv[1:]) + '\\n')\n")
SPY = LOG_ARGV + ("real = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'skills_resolver_real.py')\n"
                  "os.execv(sys.executable, [sys.executable, '-I', real] + sys.argv[1:])\n")
CRASH = LOG_ARGV + "sys.stdout.write('PARTIAL ANSWER\\n')\nsys.stdout.flush()\nsys.exit(7)\n"
HANG = LOG_ARGV + "import time\ntime.sleep(120)\n"
PLUGIN_FILES = ("bin/skill-manager", "bin/lib/skill_restore.py", "bin/lib/skills_config.py", "bin/lib/skills_manifest.py", "heimdall-skills.json")


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


def read(path):
    with open(path, encoding="utf-8", newline="") as handle:
        return handle.read()


def load(path):
    return json.loads(read(path))


def make_plugin(name, resolver=SPY, manifest=None):
    """A copy of the plugin directory: the two call sites, the flag reader, the manifest module and the legacy config, a manifest (the repo's, a given
    text, or none) and `resolver` in the resolver's place (the real one stays beside it as skills_resolver_real.py for the spy to run)."""
    root = "%s/%s" % (WORK, name)
    for rel in PLUGIN_FILES:
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
    """One run's private world: HOME (settings.json), HEIMDALL_HOME (the flag file, the restore directory), a project tree and the resolver's call log."""

    def __init__(self, tag, case, plugin, flag, settings):
        root = "%s/%s" % (WORK, tag)
        self.plugin = plugin
        self.home, self.proj = root + "/home", root + "/proj"
        self.heimdall_home = self.home + "/.heimdall"
        self.state_dir = self.heimdall_home + "/skill-restore"
        self.restore_file = "%s/%d.json" % (self.state_dir, os.getpid())
        self.settings = self.home + "/.claude/settings.json"
        self.spy = root + "/spy.log"
        os.makedirs(self.proj)
        for rel, body in case.get("files", {}).items():
            write(self.proj + "/" + rel, body)
        if settings is not None:
            write(self.settings, json.dumps(settings))
        if flag is not None:
            write(self.heimdall_home + "/skills-config.json", flag)


def run(box, argv, env=None):
    full = {"PATH": WORK + "/bin:/usr/bin:/bin", "HOME": box.home, "HEIMDALL_HOME": box.heimdall_home, "LC_ALL": "C", "SKILLS_SPY_LOG": box.spy}
    full.update(env or {})
    done = subprocess.run(argv, env=full, cwd=box.proj, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=TIMEOUT_S)
    return done.returncode, done.stdout.decode("utf-8", "replace"), done.stderr.decode("utf-8", "replace")


def call_problems(box, command):
    """`command` None: the resolver must not have started. Else it must have run exactly once, with exactly the arguments of this call."""
    try:
        with open(box.spy, encoding="utf-8") as handle:
            calls = [line.rstrip("\n").split("\t") for line in handle if line.strip()]
    except FileNotFoundError:
        calls = []
    if command is None:
        return ["the resolver started although the flag is off: %s" % short(calls)] if calls else []
    if len(calls) != 1:
        return ["the resolver should run exactly once, it ran %d times: %s" % (len(calls), short(calls))]
    got = dict(zip(calls[0][1::2], calls[0][2::2]))
    got["command"] = calls[0][0]
    want = {"command": command, "--manifest": box.plugin + "/skills.manifest.json", "--project": box.proj}
    if command == "status":
        want["--settings"] = box.settings
    return [] if got == want else ["the resolver was called with %s, expected %s" % (short(got), short(want))]


def stderr_problems(err, note):
    """note False: a quiet run. note True: the fallback is said on stderr."""
    if note:
        return [] if "legacy" in err.lower() else ["stderr does not say the legacy code answered: %s" % short(err)]
    return [] if err == "" else ["unexpected stderr: %s" % short(err)]


# ── the activation model: what the documented rules of bin/lib/skill_restore.py make of a settings file and a needed set ──
def activation_settings(case, universe):
    """The case's own settings.json, or (none given) one that lists every plugin the legacy config knows, all on, plus one no rule names."""
    if "settings" in case:
        return case["settings"]
    return {"enabledPlugins": dict.fromkeys(universe + [UNRELATED], True)}


def expected_activation(settings, needed):
    """(summary line, settings after, restore changes) of `activate` for a project that needs `needed`. A boolean plugin whose state differs from
    `name in needed` is flipped and the flip recorded as {"from", "to"}; a value that is not a boolean, and a settings file without an enabledPlugins
    map, are left alone. Written from the module's documented rules, not from its code."""
    plugins = settings.get("enabledPlugins")
    if not isinstance(plugins, dict):
        return "OK|0|0||", settings, {}
    after, changes, turned_on, turned_off = dict(plugins), {}, [], []
    for name, enabled in plugins.items():
        wanted = name in needed
        if isinstance(enabled, bool) and enabled != wanted:
            changes[name] = {"from": enabled, "to": wanted}
            after[name] = wanted
            (turned_on if wanted else turned_off).append(name)
    active = sum(1 for value in after.values() if value)
    paused = sum(1 for value in after.values() if not value)
    if changes:
        return "CHANGED|%d|%d|%s|%s" % (active, paused, ",".join(turned_on), ",".join(turned_off)), dict(settings, enabledPlugins=after), changes
    return "OK|%d|%d||" % (active, paused), settings, changes


def check_status(tag, case, expected, plugin, flag, command, env=None, note=False):
    box = Box(tag, case, plugin, flag, case.get("settings"))
    rc, out, err = run(box, [plugin + "/bin/skill-manager", "status", box.proj], env)
    problems = []
    if (rc, out) != (0, expected):
        problems.append("status: expected exit 0 and %s, got exit %d and %s" % (short(expected), rc, short(out)))
    return problems + stderr_problems(err, note) + call_problems(box, command)


def check_activate(tag, case, needed, universe, plugin, flag, command, env=None, note=False):
    """`skill_restore.py activate`, then `restore`, against the model fed with the golden needed set."""
    settings = activation_settings(case, universe)
    box = Box(tag, case, plugin, flag, settings)
    before = read(box.settings)
    base = [PYTHON, plugin + "/bin/lib/skill_restore.py"]
    rc, out, err = run(box, base + ["activate", plugin + "/heimdall-skills.json", box.settings, box.proj, box.restore_file, box.state_dir], env)
    summary, after, changes = expected_activation(settings, set(needed))
    problems = []
    if (rc, out) != (0, summary + "\n"):
        problems.append("activate: expected exit 0 and %s, got exit %d and %s" % (short(summary + "\n"), rc, short(out)))
    problems += stderr_problems(err, note)
    want_text = json.dumps(after, indent=2) + "\n" if changes else before
    if read(box.settings) != want_text:
        problems.append("settings.json after activate: expected %s, got %s" % (short(want_text), short(read(box.settings))))
    if changes:
        try:
            raw = read(box.restore_file)
            record = json.loads(raw)
        except (OSError, ValueError) as exc:
            problems.append("the restore file is missing or not JSON: %s" % exc)
        else:
            stamp = record.get("t") if isinstance(record, dict) else None
            if not isinstance(stamp, float) or raw != json.dumps({"t": stamp, "changes": changes}):
                problems.append("restore file: expected {\"t\": <float>, \"changes\": %s}, got %s" % (short(changes), short(raw)))
    elif os.path.exists(box.restore_file):
        problems.append("a restore file was written although nothing was flipped")
    rc, out, err = run(box, base + ["restore", box.settings, box.restore_file, box.state_dir], env)
    if (rc, out, err) != (0, "", ""):
        problems.append("restore: expected a quiet exit 0, got exit %d, stdout %s, stderr %s" % (rc, short(out), short(err)))
    if json.loads(read(box.settings)) != settings:
        problems.append("settings.json is not back to the original after restore")
    if os.path.exists(box.restore_file):
        problems.append("the restore file is still there after restore")
    return problems + call_problems(box, command)


def sweep(label, cases, check):
    """Run `check(case) -> [problems]` over every case, in parallel, and report ONE verdict for the category."""
    def one(case):
        try:
            return case["id"], check(case)
        except Exception as exc:  # a worker that died is a failed case, not a dead driver
            return case["id"], ["raised %s: %s" % (type(exc).__name__, exc)]

    with concurrent.futures.ThreadPoolExecutor(max_workers=JOBS) as pool:
        results = list(pool.map(one, cases))
    failed = [(ident, problems) for ident, problems in results if problems]
    if failed:
        details = ["%s: %s" % (ident, problem) for ident, problems in failed[:SHOWN] for problem in problems[:3]]
        say("FAIL", "%s: %d of %d cases differ" % (label, len(failed), len(results)), *details)
    else:
        say("PASS", "%s: all %d cases" % (label, len(results)))


def verdict(label, problems):
    if problems:
        say("FAIL", label, *problems[:6])
    else:
        say("PASS", label)


def without_permanent(status, ref):
    """The golden status text with `ref` taken out of the PERMANENT block: what a manifest that no longer lists it as permanent must print."""
    lines = status.split("\n")
    end = lines.index("")  # the blank line that closes the PERMANENT block
    return "\n".join(line for number, line in enumerate(lines) if not (number < end and line.endswith("  " + ref)))


def caveman_not_permanent():
    doc = load(REPO + "/skills.manifest.json")
    next(item for item in doc["entries"] if item["id"] == "caveman")["activate"]["permanent"] = False
    return json.dumps(doc)


def main():
    golden = load(FIXTURES + "/golden.json")["cases"]["activate"]
    inputs = load(FIXTURES + "/inputs.json")["cases"]["activate"]
    legacy = load(REPO + "/heimdall-skills.json")
    universe = legacy["permanent"] + [ref for rule in legacy["detection"].values() for ref in rule["plugins"]] + legacy["on_demand"]
    by_id = {case["id"]: case for case in inputs}
    if set(by_id) != set(golden) or len(by_id) != len(inputs) or not inputs:
        say("FAIL", "every golden activation case has an input and every input a golden answer", "inputs %d, golden %d" % (len(inputs), len(golden)))
        return
    say("PASS", "every golden activation case has an input and every input a golden answer (%d cases)" % len(inputs))
    plugin = make_plugin("plugin")

    # B. status
    sweep("status, flag off: the golden text, the resolver never starts", inputs,
          lambda case: check_status("st-off-" + case["id"], case, golden[case["id"]]["status"], plugin, None, None))
    sweep("status, flag on: the golden text, one resolver call with this manifest, project and settings", inputs,
          lambda case: check_status("st-on-" + case["id"], case, golden[case["id"]]["status"], plugin, FLAG_ON, "status"))

    # C. activate and restore
    sweep("activate and restore, flag off: the model's summary, settings and restore file, the resolver never starts", inputs,
          lambda case: check_activate("ac-off-" + case["id"], case, golden[case["id"]]["needed"], universe, plugin, None, None))
    sweep("activate and restore, flag on: the model's summary, settings and restore file, one resolver call with this manifest and project", inputs,
          lambda case: check_activate("ac-on-" + case["id"], case, golden[case["id"]]["needed"], universe, plugin, FLAG_ON, "activate-set"))
    sweep("activate and restore, flag explicitly off in the file: the resolver never starts", inputs[:12],
          lambda case: check_activate("ac-fileoff-" + case["id"], case, golden[case["id"]]["needed"], universe, plugin, FLAG_OFF, None))

    # D. where the flag comes from
    probe = by_id["act-everything"]
    sources = (("HMD_SKILLS_REGISTRY=on and no file", None, {"HMD_SKILLS_REGISTRY": "on"}, True),
               ("HMD_SKILLS_REGISTRY=maybe over a file that says on (a typo is off, never on)", FLAG_ON, {"HMD_SKILLS_REGISTRY": "maybe"}, False),
               ("HMD_SKILLS_REGISTRY=off over a file that says on (the environment wins)", FLAG_ON, {"HMD_SKILLS_REGISTRY": "off"}, False),
               ("a flag file that is not JSON", "not json\n", None, False),
               ("a flag file whose registry is not on or off", json.dumps({"registry": "maybe"}) + "\n", None, False))
    for number, (label, flag, env, resolver_runs) in enumerate(sources):
        problems = check_status("src-st-%d" % number, probe, golden[probe["id"]]["status"], plugin, flag, "status" if resolver_runs else None, env)
        problems += check_activate("src-ac-%d" % number, probe, golden[probe["id"]]["needed"], universe, plugin, flag,
                                   "activate-set" if resolver_runs else None, env)
        verdict("flag source: %s -> the resolver %s" % (label, "answers" if resolver_runs else "never starts"), problems)

    # E. the resolver's answer is the one used
    mutant = make_plugin("plugin-mutant", manifest=caveman_not_permanent())
    consumed = []
    for ident in ("act-empty", "act-top-app-dot-tsx", "act-everything", "act-settings-mixed"):
        case, status = by_id[ident], golden[ident]["status"]
        consumed += ["%s: %s" % (ident, problem) for problem in check_status("mut-st-on-" + ident, case, without_permanent(status, "caveman@caveman"),
                                                                             mutant, FLAG_ON, "status")]
        consumed += ["%s, flag off: %s" % (ident, problem) for problem in check_status("mut-st-off-" + ident, case, status, mutant, None, None)]
        if "settings" not in case:
            needed = [ref for ref in golden[ident]["needed"] if ref != "caveman@caveman"]
            consumed += ["%s: %s" % (ident, problem) for problem in check_activate("mut-ac-on-" + ident, case, needed, universe, mutant, FLAG_ON, "activate-set")]
            consumed += ["%s, flag off: %s" % (ident, problem)
                         for problem in check_activate("mut-ac-off-" + ident, case, golden[ident]["needed"], universe, mutant, None, None)]
    verdict("a manifest without caveman as a permanent plugin changes the flag-on status and activation, and not the flag-off ones", consumed)

    # F. fallback to the legacy code
    scenarios = (("a manifest that is not valid (the resolver exits 3)", make_plugin("plugin-invalid", manifest='{"schema": 1}')),
                 ("a manifest that is not JSON (exit 3)", make_plugin("plugin-garbage", manifest="not json")),
                 ("a manifest that is missing (exit 3)", make_plugin("plugin-nomanifest", manifest=ABSENT)),
                 ("a resolver that prints part of an answer and exits 7", make_plugin("plugin-crash", resolver=CRASH)))
    for number, (label, broken) in enumerate(scenarios):
        problems = check_status("fb-st-%d" % number, probe, golden[probe["id"]]["status"], broken, FLAG_ON, "status", note=True)
        problems += check_activate("fb-ac-%d" % number, probe, golden[probe["id"]]["needed"], universe, broken, FLAG_ON, "activate-set", note=True)
        verdict("flag on, %s: the legacy answer, said on stderr, nothing of the failed answer on stdout" % label, problems)
    hang_falls_back(probe, golden[probe["id"]]["needed"], universe)

    # G. the whole chain
    chain = []
    for ident in ("act-empty", "act-everything"):
        chain += ["%s: %s" % (ident, problem) for problem in check_chain(by_id[ident], golden[ident]["needed"], universe, plugin)]
    verdict("skill-manager activate then restore: the same output and the same settings, flag off and flag on", chain)


def check_chain(case, needed, universe, plugin):
    problems, outputs = [], {}
    for label, flag, command in (("off", None, None), ("on", FLAG_ON, "activate-set")):
        settings = activation_settings(case, universe)
        box = Box("chain-%s-%s" % (label, case["id"]), case, plugin, flag, settings)
        manager = plugin + "/bin/skill-manager"
        rc, out, err = run(box, [manager, "activate", box.proj, box.restore_file])
        summary, after, changes = expected_activation(settings, set(needed))
        _status, active, paused = summary.split("|")[:3]
        if rc != 0 or err != "" or "%s active" % active not in out or "%s paused" % paused not in out:
            problems.append("%s: activate printed %s on stdout and %s on stderr (exit %d), expected %s active and %s paused"
                            % (label, short(out), short(err), rc, active, paused))
        if json.loads(read(box.settings)) != after:
            problems.append("%s: settings.json after activate is not the model's" % label)
        outputs[label] = out
        rc, out, err = run(box, [manager, "restore", box.restore_file])
        if (rc, out, err) != (0, "", "") or json.loads(read(box.settings)) != settings or os.path.exists(box.restore_file):
            problems.append("%s: restore did not put settings.json back quietly (exit %d, stdout %s, stderr %s)" % (label, rc, short(out), short(err)))
        problems += call_problems(box, command)
    if outputs["off"] != outputs["on"]:
        problems.append("the printed summary differs: off %s, on %s" % (short(outputs["off"]), short(outputs["on"])))
    return problems


def hang_falls_back(probe, needed, universe):
    """A resolver that never answers must not hang a launch: after REGISTRY_TIMEOUT_SECONDS the legacy rules answer. In process, so the bound can be
    shortened; the flag file and the spy log reach the children skill_restore starts through the environment."""
    plugin = make_plugin("plugin-hang", resolver=HANG)
    settings = activation_settings(probe, universe)
    box = Box("hang", probe, plugin, FLAG_ON, settings)
    os.environ.update(HEIMDALL_HOME=box.heimdall_home, SKILLS_SPY_LOG=box.spy)
    sys.path.insert(0, plugin + "/bin/lib")
    import skill_restore
    skill_restore.REGISTRY_TIMEOUT_SECONDS = 3
    problems, noted = [], io.StringIO()
    started = time.monotonic()
    try:
        with contextlib.redirect_stderr(noted):
            summary = skill_restore.activate(plugin + "/heimdall-skills.json", box.settings, box.proj, box.restore_file, box.state_dir)
    except Exception as exc:
        problems.append("activate raised %s: %s" % (type(exc).__name__, exc))
        summary = None
    elapsed = time.monotonic() - started
    expected = expected_activation(settings, set(needed))[0]
    if summary != expected:
        problems.append("the summary is %s, the legacy answer is %s" % (short(summary), short(expected)))
    if elapsed > 60:
        problems.append("activation waited %.0f s for a resolver that sleeps 120 s: the timeout did not cut it" % elapsed)
    if "legacy" not in noted.getvalue().lower():
        problems.append("stderr does not say the legacy rules answered: %s" % short(noted.getvalue()))
    problems += call_problems(box, "activate-set")
    verdict("flag on, a resolver that hangs: cut after the timeout, the legacy answer, said on stderr", problems)


main()
print("DONE")
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
