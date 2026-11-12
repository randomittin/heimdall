#!/usr/bin/env bash
#
# skills-consent-launcher.test.sh -- 3.x M1, T5.1: the launcher asks before it installs anything NEW, and an existing user sees nothing change.
#
#   bash test/skills-consent-launcher.test.sh
#
# Plan: docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md (T5.1, INV-S7, INV-S8, R1). first_run_setup(), preinstall_plugins() and discover_skills() of
# bin/heimdall ask hmd_skills_consent (bin/lib/skills_consent.sh) before each install, and a grandfather `init` runs at launcher start. Every run below is the REAL
# launcher code in a throwaway HOME / HEIMDALL_HOME / project with recording fakes of `claude`, `git` and `python3` on PATH (no network, nothing of the operator's
# home is read or written). No consent variable is set unless a check says so: the gate reads the config file the launcher's own `init` wrote.
#
#   A. static: the file parses, sources the gate, names it in the three functions, calls the grandfather init after the run-count bump, and the injected
#      prompt sends agents through `hmd skills install` (no raw `claude plugins install <id>@...` is left in it).
#   B. INV-S7, marker present: for EVERY case of the golden's preinstall, preinstall_installed and keyword_match categories the install attempts equal the legacy
#      golden, after the launcher's `init` (config consent auto, grandfathered) and, for every 4th case, with no config at all (the gate's in-memory grandfather
#      rule: nothing is written). The gate adds no `claude` or `git` call, and every installed id's lock row says consent auto-legacy.
#   C. INV-S8, marker absent, no terminal, consent at its default (ask): zero `plugins install`, `marketplace add` and `git clone` calls, the lock rows of what
#      would have installed are `suggested`, and the deferral is said on stderr.
#   D. consent given: HMD_SKILLS_YES=1 installs exactly what the legacy code installs and the lock says yes-flag; an allowlist installs only the listed id
#      (consent allowlist) and defers the rest.
#   E. the real `bin/heimdall --setup` (first_run_setup, in a sandbox copy of the plugin tree): an existing user (marker present, no config yet) gets the legacy
#      calls byte for byte and a grandfathered config; a new user gets no install, a `ask` config, a `suggested` row and the setup marker; HMD_SKILLS_YES=1
#      installs and records yes-flag.
#
# SKILLS_CONSENT_LAUNCHER=<path> points the suite at another copy of bin/heimdall (how the RED run against the pre-change launcher is made).
# Exit: 0 every check passed, 1 a check failed, 2 this machine cannot run the suite.
# budget: 90 -- ~310 launcher-function runs (bash, a fake claude, 4-12 python3 starts each: the gate asks skills_config.py twice per install) over at most 8
# workers plus five real `--setup` launches; the matrix cannot shrink without dropping the INV-S7 differential the plan requires.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LAUNCHER="${SKILLS_CONSENT_LAUNCHER:-$REPO/bin/heimdall}"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
finish() {
  echo "--------------------------------------------------------------------"
  printf 'skills-consent-launcher: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
# the real interpreter, not a version-manager shim (this suite starts ~2000 of them); a wrapper script below, so a venv's pyvenv.cfg is still found
REALPY="$("$PY" -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
case "$REALPY" in /*) ;; *) REALPY="" ;; esac
[ -n "$REALPY" ] && [ -x "$REALPY" ] || { echo "FATAL: cannot resolve the interpreter behind $PY"; exit 2; }
for f in "$LAUNCHER" "$REPO/skills.manifest.json" "$REPO/skills-registry.json" "$REPO/bin/lib/skills_consent.sh" "$REPO/bin/lib/skills_config.py" \
         "$REPO/bin/lib/skills_lock.py" "$REPO/bin/lib/select.sh" "$REPO/bin/lib/install-receipt.sh" \
         "$REPO/test/fixtures/skills-baseline/golden.json" "$REPO/test/fixtures/skills-baseline/inputs.json"; do
  [ -f "$f" ] || { echo "FATAL: $f is missing"; exit 2; }
done
WORK="$(mktemp -d)" || { echo "FATAL: cannot make a temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

echo "A. static"
if bash -n "$LAUNCHER" 2>"$WORK/syntax.err"; then ok "bin/heimdall parses (bash -n)"; else bad "bin/heimdall does not parse: $(head -c 300 "$WORK/syntax.err")"; fi
body() { sed -n "/^$1()/,/^}/p" "$LAUNCHER"; }
if grep -q 'bin/lib/skills_consent\.sh' "$LAUNCHER"; then ok "bin/heimdall sources bin/lib/skills_consent.sh"; else bad "bin/heimdall never sources bin/lib/skills_consent.sh"; fi
for fn in first_run_setup preinstall_plugins discover_skills; do
  if [ "$(body "$fn" | grep -c 'hmd_skills_consent ')" -ge 1 ]; then ok "$fn() asks hmd_skills_consent before it installs"; else bad "$fn() never asks hmd_skills_consent"; fi
done
if [ "$(body discover_skills | grep -c 'hmd_skills_consent ')" -ge 2 ]; then ok "discover_skills() gates both its loops (registry on and off)"; else bad "discover_skills() does not gate both of its loops"; fi
if [ "$(body hmd_skills_consent_init | grep -c 'skills_config\.py')" -ge 1 ] && grep -A1 '^hmd_bump_run_count || true$' "$LAUNCHER" | grep -q '^hmd_skills_consent_init$'; then
  ok "the grandfather init is called right after the run-count bump, before any subcommand runs"
else
  bad "the grandfather init (hmd_skills_consent_init) is missing or not called at launcher start"
fi
if grep -q 'hmd skills install frontend-design' "$LAUNCHER" && ! grep -q 'claude plugins install frontend-design@' "$LAUNCHER"; then
  ok "the injected prompt sends agents through \`hmd skills install\` and no raw \`claude plugins install <id>@...\` is left in it"
else
  bad "the injected prompt still tells agents to run a raw \`claude plugins install\`, or does not name \`hmd skills install\`"
fi

echo "B-E. behaviour"
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
QUOTED="$(printf '%s' "$REALPY" | sed "s/'/'\\\\''/g")"
printf '#!/bin/sh\nexec %s "$@"\n' "'$QUOTED'" > "$FAKEBIN/python3"
# a recording fake of the Claude CLI: every call is logged; `plugins` state lives in $FAKE_STATE/{installed,markets}
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
echo "claude $*" >> "${FAKE_CALLS:-/dev/null}"
[ "${1:-}" = "--version" ] && { echo "1.99.0 (Claude Code)"; exit 0; }
case "${1:-}" in plugin|plugins) ;; *) exit 0 ;; esac
case "${2:-}" in
  install)
    echo "${3:-}" >> "$FAKE_STATE/installed"
    echo "Successfully installed plugin: ${3:-} (scope: user)" ;;
  list)
    if printf '%s\n' "$@" | grep -qx -- '--json'; then
      printf '['; n=0
      while IFS= read -r id; do
        [ -n "$id" ] || continue; [ "$n" -eq 0 ] || printf ','; n=1
        printf '\n  {\n    "id": "%s",\n    "version": "5.0.7",\n    "scope": "user",\n    "enabled": true\n  }' "$id"
      done < "$FAKE_STATE/installed"
      printf '\n]\n'
    else
      cat "$FAKE_STATE/installed"
    fi ;;
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
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/node"
chmod +x "$FAKEBIN/python3" "$FAKEBIN/claude" "$FAKEBIN/git" "$FAKEBIN/node"

# the sandbox plugin tree the REAL launcher runs from (section E): the launcher under test and exactly the files it reads
TPLUG="$WORK/plugin"
mkdir -p "$TPLUG/bin/lib"
cp "$LAUNCHER" "$TPLUG/bin/heimdall"
cp "$REPO/skills-registry.json" "$REPO/skills.manifest.json" "$TPLUG/"
for f in install-receipt.sh skills_consent.sh skills_config.py skills_lock.py select.sh; do cp "$REPO/bin/lib/$f" "$TPLUG/bin/lib/$f"; done
chmod +x "$TPLUG/bin/heimdall"

cat > "$WORK/driver.py" <<'PYEOF'
"""driver.py -- runs the real launcher code under the consent gate and reports what it did.

    driver.py REPO WORK LAUNCHER

One record per line: `PASS <what>`, `FAIL <what>` (indented detail lines follow it), then `DONE`. No DONE means the driver died.
"""
import collections
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys

REPO, WORK, LAUNCHER = sys.argv[1:4]
FIXTURES = REPO + "/test/fixtures/skills-baseline"
TPLUG = WORK + "/plugin"
CHILD_PATH = WORK + "/fakebin:/usr/bin:/bin"
BASH = shutil.which("bash", path="/usr/bin:/bin")
TIMEOUT_S = 180
JOBS = max(1, min(8, os.cpu_count() or 2))
SHOWN = 4
FUNCTIONS = {"preinstall": "preinstall_plugins", "preinstall_installed": "preinstall_plugins", "keyword_match": "discover_skills"}
CLAUDE_VERBS = ("claude plugins list", "claude plugins marketplace list", "claude plugins marketplace add", "claude plugins install", "claude --version")
GRANDFATHERED = {"consent": "auto", "grandfathered": True}
NEW_INSTALL = {"consent": "ask", "grandfathered": False}

# The launcher's own functions, run unmodified. PLUGIN_DIR and WORK_DIR are what the launcher has set when it calls them; RUN_INIT adds the launcher-start
# grandfather init the way the launcher reaches it: the marker is looked at, nothing else has run. The shell is strict like the launcher's.
SNIPPET = r'''
set -euo pipefail
. "$REPO/bin/lib/install-receipt.sh"
. "$REPO/bin/lib/skills_consent.sh"
eval "$(sed -n "/^${FN}()/,/^}/p" "$LAUNCHER")"
if [ -n "${RUN_INIT:-}" ]; then
  eval "$(sed -n '/^_heimdall_home_ensure()/,/^}/p' "$LAUNCHER")"
  eval "$(sed -n '/^hmd_skills_consent_init()/,/^}/p' "$LAUNCHER")"
  HEIMDALL_HOME_DIR="$HEIMDALL_HOME"; SETUP_MARKER="$HEIMDALL_HOME/setup-done"; HEIMDALL_TEARDOWN=0; PLUGIN_DIR="$REPO"
  hmd_skills_consent_init
fi
WORK_DIR="$PROJ"
PLUGIN_DIR="$REPO"
"$FN" "$PROMPT"
'''

Run = collections.namedtuple("Run", "rc out err claude git box")


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
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def verdict(good, passed, failed, offenders=()):
    if good:
        say("PASS", passed)
    else:
        say("FAIL", failed, *list(offenders)[:SHOWN])


class Box(object):
    """One run's private world: its own HOME, HEIMDALL_HOME, fake-claude state, call logs and project tree."""

    def __init__(self, tag, case=None, marker=False, config=None):
        case = case or {}
        self.root = "%s/%s" % (WORK, tag)
        self.home, self.hh, self.state, self.proj = (self.root + "/" + name for name in ("home", "hh", "state", "proj"))
        self.claude_log, self.git_log = self.root + "/claude.log", self.root + "/git.log"
        for directory in (self.home, self.hh, self.state, self.proj):
            os.makedirs(directory)
        write(self.state + "/installed", "".join(item + "\n" for item in case.get("installed", [])))
        write(self.state + "/markets", "")
        write(self.claude_log, "")
        write(self.git_log, "")
        for rel, body in case.get("files", {}).items():
            write(self.proj + "/" + rel, body)
        if marker:
            write(self.hh + "/setup-done", "")
        if config is not None:
            write(self.hh + "/skills-config.json", json.dumps(config))

    def env(self, **extra):
        env = {"PATH": CHILD_PATH, "HOME": self.home, "HEIMDALL_HOME": self.hh, "HMD_RUN_ID": "skills-consent-launcher", "LC_ALL": "C",
               "PYTHONIOENCODING": "utf-8", "FAKE_STATE": self.state, "FAKE_CALLS": self.claude_log, "FAKE_GIT_CALLS": self.git_log}
        env.update(extra)
        return env

    def run(self, argv, env):
        try:
            done = subprocess.run(argv, env=env, cwd=self.proj, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=TIMEOUT_S)
        except subprocess.TimeoutExpired:
            return Run(-1, "", "no answer after %d s" % TIMEOUT_S, "", "", self)
        return Run(done.returncode, done.stdout.decode("utf-8", "replace"), done.stderr.decode("utf-8", "replace"),
                   read(self.claude_log).replace(self.root, "<box>"), read(self.git_log).replace(self.root, "<box>"), self)

    def function(self, name, prompt, init=False, **extra):
        env = self.env(REPO=REPO, LAUNCHER=LAUNCHER, PROJ=self.proj, FN=name, PROMPT=prompt, **extra)
        if init:
            env["RUN_INIT"] = "1"
        return self.run([BASH, "-c", SNIPPET], env)

    def setup(self, plugin_marker=False, **extra):
        # The launcher carries a pre-migration marker ($PLUGIN_DIR/.setup-done) into the home before anything else, and the grandfather rule reads that home
        # marker. Every `--setup` writes one, so the shared sandbox tree must not hand one run's marker to the next box: it is removed here, or planted.
        marker = TPLUG + "/.setup-done"
        if plugin_marker:
            write(marker, "")
        elif os.path.lexists(marker):
            os.unlink(marker)
        return self.run([TPLUG + "/bin/heimdall", "--setup"], self.env(ANTHROPIC_API_KEY="sk-test-not-a-real-key", **extra))

    def config(self):
        try:
            return json.loads(read(self.hh + "/skills-config.json"))
        except ValueError:
            return None

    def rows(self, scope="project"):
        path = (self.proj + "/.planning/skills.lock") if scope == "project" else (self.hh + "/skills.lock")
        try:
            return {row["id"]: row for row in json.loads(read(path)).get("entries", [])}
        except ValueError:
            return {}


def attempts(run):
    """What a run tried to install: ids of `claude plugins install` calls, and the `name|repo` of every clone."""
    plugins = [line.split()[3] for line in run.claude.splitlines() if line.startswith("claude plugins install ")]
    clones = []
    for line in run.git.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[0] == "clone":
            clones.append("%s|%s" % (os.path.basename(parts[2]), parts[1][len("https://github.com/"):-len(".git")]))
    return plugins, clones


def foreign_calls(run):
    """claude calls that are not one of the legacy install-path verbs, and git calls that are not clones: the gate must add none."""
    return [line for line in run.claude.splitlines() if not line.startswith(CLAUDE_VERBS)] + \
           [line for line in run.git.splitlines() if not line.startswith("clone\t")]


def load():
    with open(FIXTURES + "/golden.json", encoding="utf-8") as handle:
        golden = json.load(handle)["cases"]
    with open(FIXTURES + "/inputs.json", encoding="utf-8") as handle:
        inputs = json.load(handle)["cases"]
    return golden, inputs


# ── B. INV-S7: marker present, the golden's matrix, nothing changes ──
def grandfathered_job(job):
    category, index, case, both = job
    runs = []
    for init in ((True, False) if both else (True,)):
        box = Box("b-%s-%d-%s" % (category, index, "init" if init else "mem"), case, marker=True)
        runs.append((category, case["id"], init, box.function(FUNCTIONS[category], case["prompt"], init=init)))
    return runs


def check_grandfathered(golden, inputs):
    jobs = [(category, index, case, index % 4 == 0) for category in FUNCTIONS for index, case in enumerate(inputs[category])]
    with concurrent.futures.ThreadPoolExecutor(max_workers=JOBS) as pool:
        results = [run for runs in pool.map(grandfathered_job, jobs) for run in runs]
    broken, moved, foreign, consent, config, attempted = [], [], [], [], [], 0
    for category, case_id, init, run in results:
        label = "%s/%s%s" % (category, case_id, "" if init else " (no config)")
        if run.rc != 0:
            broken.append("%s: exit %d, stderr %s" % (label, run.rc, short(run.err.strip()[-160:])))
            continue
        plugins, clones = attempts(run)
        got = clones if category == "keyword_match" else plugins
        want = golden[category][case_id]
        attempted += 1 if want else 0
        if got != want:
            moved.append("%s: legacy %s, now %s" % (label, short(want), short(got)))
        foreign += ["%s: %s" % (label, line) for line in foreign_calls(run)]
        rows = run.box.rows()
        for name in {entry.split("@")[0].split("|")[0] for entry in want}:
            if rows.get(name, {}).get("state") != "installed" or rows[name].get("consent") != "auto-legacy":
                consent.append("%s: lock row of %s is %s" % (label, name, short(rows.get(name))))
        if run.box.config() != (GRANDFATHERED if init else None):
            config.append("%s: skills-config.json is %s" % (label, short(run.box.config())))
    total = len(results)
    verdict(not broken and not moved, "INV-S7: %d runs over every preinstall, preinstall_installed and keyword_match case: the install attempts equal the legacy golden" % total,
            "INV-S7: a grandfathered run installs something other than the legacy golden, or failed", broken + moved)
    verdict(attempted >= total // 3, "INV-S7: not vacuous, %d of %d runs installed something" % (attempted, total),
            "INV-S7: only %d of %d runs installed anything: the comparison proves nothing" % (attempted, total))
    verdict(not foreign, "INV-S7: the gate adds no `claude` or `git` call (only plugins list / marketplace / install and clones)",
            "INV-S7: a call outside the legacy install path was made", foreign)
    verdict(not consent, "INV-S7: every installed id has a lock row with state installed and consent auto-legacy", "INV-S7: lock rows do not say auto-legacy", consent)
    verdict(not config, "INV-S7: the launcher's init wrote consent auto + grandfathered once, and the in-memory rule wrote nothing", "INV-S7: skills-config.json is not as the grandfather rule says", config)


# ── C. INV-S8: marker absent, no terminal, the default consent ──
def check_new_install(golden, inputs):
    pre = max(inputs["preinstall"], key=lambda case: len(golden["preinstall"][case["id"]]))
    kw = max(inputs["keyword_match"], key=lambda case: len(golden["keyword_match"][case["id"]]))
    for category, case in (("preinstall", pre), ("keyword_match", kw)):
        function = FUNCTIONS[category]
        want = sorted({entry.split("@")[0].split("|")[0] for entry in golden[category][case["id"]]})
        run = Box("c-" + category, case, marker=False).function(function, case["prompt"], init=True)
        rows, plugins, clones = run.box.rows(), *attempts(run)
        problems = []
        if run.rc != 0:
            problems.append("exit %d, stderr %s" % (run.rc, short(run.err.strip()[-200:])))
        if plugins or clones or "marketplace add" in run.claude:
            problems.append("something was installed: %s" % short((plugins, clones, run.claude)))
        problems += ["%s: lock row is %s, want suggested" % (name, short(rows.get(name, {}).get("state"))) for name in want if rows.get(name, {}).get("state") != "suggested"]
        problems += ["%s: stderr does not say it was not installed and how to see it" % name for name in want if "recommended skill %s not installed" % name not in run.err]
        if os.path.isdir(run.box.home + "/.claude/skills") and os.listdir(run.box.home + "/.claude/skills"):
            problems.append("the skills directory is not empty")
        if run.box.config() != NEW_INSTALL:
            problems.append("skills-config.json is %s, want consent ask" % short(run.box.config()))
        verdict(bool(want) and not problems,
                "INV-S8: %s/%s, marker absent, no terminal: zero installs, %d `suggested` lock rows, the deferral on stderr, config consent ask" % (category, case["id"], len(want)),
                "INV-S8: %s/%s installed or mis-recorded something without consent (%d ids expected)" % (category, case["id"], len(want)), problems)


# ── D. consent given ──
def check_consent_given(golden, inputs):
    pre = max(inputs["preinstall"], key=lambda case: len(golden["preinstall"][case["id"]]))
    want = golden["preinstall"][pre["id"]]
    run = Box("d-yes", pre, marker=False).function("preinstall_plugins", pre["prompt"], init=True, HMD_SKILLS_YES="1")
    rows = run.box.rows()
    bad_rows = ["%s: %s" % (entry, short(rows.get(entry.split("@")[0]))) for entry in want
                if rows.get(entry.split("@")[0], {}).get("state") != "installed" or rows[entry.split("@")[0]].get("consent") != "yes-flag"]
    verdict(run.rc == 0 and attempts(run)[0] == want and not bad_rows,
            "consent: HMD_SKILLS_YES=1 on a new install installs exactly the legacy set (%d plugins) and the lock says yes-flag" % len(want),
            "consent: HMD_SKILLS_YES=1 did not install the legacy set with consent yes-flag (exit %d, attempts %s)" % (run.rc, short(attempts(run)[0])), bad_rows)
    case = {"prompt": "react and docker deploy"}
    legacy = Box("d-legacy", case, marker=False).function("preinstall_plugins", case["prompt"], init=True, HMD_SKILLS_CONSENT="auto")
    listed = Box("d-allow", case, marker=False, config={"consent": "allowlist", "allowlist": ["frontend-design"], "grandfathered": False})
    run = listed.function("preinstall_plugins", case["prompt"], init=True)
    rows = run.box.rows()
    problems = []
    if attempts(legacy)[0][:2] != ["frontend-design@claude-plugins-official", "devops-toolkit@claude-plugins-official"]:
        problems.append("the reference run did not install frontend-design and devops-toolkit: %s" % short(attempts(legacy)[0]))
    if attempts(run)[0] != ["frontend-design@claude-plugins-official"]:
        problems.append("allowlist [frontend-design] installed %s" % short(attempts(run)[0]))
    if rows.get("frontend-design", {}).get("state") != "installed" or rows.get("frontend-design", {}).get("consent") != "allowlist":
        problems.append("frontend-design row is %s, want installed with consent allowlist" % short(rows.get("frontend-design")))
    if rows.get("devops-toolkit", {}).get("state") != "suggested":
        problems.append("devops-toolkit row is %s, want suggested" % short(rows.get("devops-toolkit")))
    verdict(run.rc == 0 and not problems, "consent: an allowlist installs the listed id (consent allowlist) and defers the other one (suggested)",
            "consent: the allowlist did not behave", problems)


# ── E. the real `--setup` ──
def check_setup():
    legacy = Box("e-legacy", marker=False).setup(HMD_SKILLS_CONSENT="auto")
    existing = Box("e-existing", marker=True).setup()
    new = Box("e-new", marker=False).setup()
    yes = Box("e-yes", marker=False).setup(HMD_SKILLS_YES="1")
    old = Box("e-premigration", marker=False).setup(plugin_marker=True)
    for name, run in (("legacy", legacy), ("existing", existing), ("new", new), ("yes", yes), ("pre-migration", old)):
        if run.rc != 0:
            say("FAIL", "--setup (%s user) exited %d: %s" % (name, run.rc, short(run.err.strip()[-300:])))
    legacy_plugins = attempts(legacy)[0]
    verdict(legacy_plugins == ["superpowers@claude-plugins-official"] and "marketplace add randomittin/heimdall-marketplace" in legacy.claude,
            "--setup reference (consent pinned to auto): superpowers and the heimdall marketplace are installed",
            "--setup reference run did not install the first-run set: %s" % short(legacy.claude))
    problems = []
    if existing.claude != legacy.claude or existing.git != legacy.git:
        problems.append("calls differ from the legacy run: %s vs %s" % (short(existing.claude), short(legacy.claude)))
    if existing.out != legacy.out:
        problems.append("stdout differs from the legacy run: %s vs %s" % (short(existing.out), short(legacy.out)))
    if existing.box.config() != GRANDFATHERED:
        problems.append("skills-config.json is %s, want consent auto + grandfathered" % short(existing.box.config()))
    row = existing.box.rows("machine").get("superpowers", {})
    if row.get("state") != "installed" or row.get("consent") != "auto-legacy":
        problems.append("machine lock row of superpowers is %s, want installed with consent auto-legacy" % short(row))
    verdict(not problems, "--setup, existing user (marker present, no config): the same calls and output as the legacy run, a grandfathered config, consent auto-legacy",
            "--setup changed for an existing user", problems)
    problems = []
    if old.claude != legacy.claude or old.git != legacy.git:
        problems.append("calls differ from the legacy run: %s vs %s" % (short(old.claude), short(legacy.claude)))
    if old.box.config() != GRANDFATHERED:
        problems.append("skills-config.json is %s, want consent auto + grandfathered" % short(old.box.config()))
    verdict(not problems, "--setup, install with only the pre-migration marker in the plugin dir: grandfathered too, the legacy calls",
            "--setup treated an install that predates the home marker as a new one", problems)
    problems = []
    if attempts(new)[0] or "marketplace add" in new.claude:
        problems.append("something was installed or registered: %s" % short(new.claude))
    row = new.box.rows("machine").get("superpowers", {})
    if row.get("state") != "suggested":
        problems.append("machine lock row of superpowers is %s, want suggested" % short(row))
    if new.box.config() != NEW_INSTALL:
        problems.append("skills-config.json is %s, want consent ask" % short(new.box.config()))
    if not os.path.isfile(new.box.hh + "/setup-done"):
        problems.append("the setup marker was not written, so the next launch would ask again")
    if "recommended skill superpowers not installed" not in new.err or "+ superpowers" in new.out:
        problems.append("the deferral is not said on stderr, or stdout claims an install: %s" % short(new.err.strip()[-200:]))
    verdict(not problems, "--setup, new user, no terminal: no install and no marketplace registered, a `suggested` row, consent ask, the marker written, the deferral on stderr",
            "--setup installed or mis-recorded something for a new user without consent", problems)
    problems = []
    if yes.claude != legacy.claude:
        problems.append("calls differ from the legacy run: %s" % short(yes.claude))
    row = yes.box.rows("machine").get("superpowers", {})
    if row.get("state") != "installed" or row.get("consent") != "yes-flag":
        problems.append("machine lock row of superpowers is %s, want installed with consent yes-flag" % short(row))
    verdict(not problems, "--setup, new user with HMD_SKILLS_YES=1: the legacy calls, lock row consent yes-flag", "--setup with HMD_SKILLS_YES=1 did not install as the legacy run does", problems)


def main():
    golden, inputs = load()
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        setup = pool.submit(check_setup)
        check_grandfathered(golden, inputs)
        check_new_install(golden, inputs)
        check_consent_given(golden, inputs)
        setup.result()
    print("DONE")


main()
PYEOF
SYNTAX="$("$REALPY" -B -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$WORK/driver.py" 2>&1)" \
  || { bad "the driver is not valid python"; printf '%s\n' "$SYNTAX"; finish; }

OUT="$("$REALPY" -B -I "$WORK/driver.py" "$REPO" "$WORK" "$LAUNCHER" 2>&1)"; RC=$?
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
