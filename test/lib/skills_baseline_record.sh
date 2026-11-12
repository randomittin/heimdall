#!/usr/bin/env bash
# skills_baseline_record.sh -- write down what the LEGACY skill and plugin selection code does (3.x M1, task T0.1).
#
#   test/lib/skills_baseline_record.sh record <out.json>
#
# WHY. The 3.x skill registry (docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md, "Parity test design") replaces three hand-written selection
# mechanisms with one manifest and a resolver, and proves the resolver by a differential test against what the old code did. That proof is worth
# something only if the old behaviour was written down by something that is neither the resolver nor the manifest. This is that something. It runs the
# UNMODIFIED legacy code over test/fixtures/skills-baseline/inputs.json and writes the answers; T1.2 commits them as golden.json BEFORE the resolver
# exists. It never reads the manifest, never imports the resolver, and holds no expected value of its own.
#
# WHAT IT RUNS (every case in its own throwaway HOME, HEIMDALL_HOME, project tree and fake-claude state):
#   preinstall, preinstall_installed   preinstall_plugins() of bin/heimdall, extracted with sed exactly as test/plugin-install-receipt.test.sh does, run
#                                      with the real bin/lib/install-receipt.sh against a recording fake `claude`. Recorded: the ordered
#                                      `claude plugins install <id>` attempts, duplicates kept (the plan's quirks C3 and C4).
#   keyword_match                      discover_skills() of bin/heimdall against skills-registry.json and a recording fake `git`. Recorded: the ordered
#                                      "name|repo" of every clone it started, which is the match list it computed.
#   activate                           needed_plugins() of bin/lib/skill_restore.py over heimdall-skills.json (the sorted needed set) and the stdout of
#                                      `bin/skill-manager status <project>` (the second, inline copy of the same glob logic).
#   discover_detect | _detect_file | _gaps
#                                      `bin/discover-skills detect <prompt>` | `detect-file <path>` | `gaps`. Recorded: exit status and stdout.
#
# THE ANSWER IS NORMALISED so two recordings of one tree are byte-identical: only the observable decisions are kept (ids, name|repo pairs, command output),
# never a path of the sandbox, a timestamp or a run id. The legacy code runs with a COMPLETE, minimal environment (PATH = the fakes, /usr/bin, /bin: the
# system grep, whatever the operator's PATH holds; LC_ALL=C; no inherited variable), so the operator's own settings cannot reach it. The header records
# `grep --version`, `python3 --version` and `uname -sm`: BSD and GNU grep differ, and a golden is only comparable on the same grep.
#
# FORMAT (one case per line, so a change to the legacy code diffs as the cases it moved):
#   {"schema": 1, "header": {"grep", "python3", "uname"}, "cases": {"<category>": {"<case id>": <answer>, ...}, ...}}
#   answer: preinstall* -> ["<plugin>@<marketplace>", ...]   keyword_match -> ["<name>|<repo>", ...]
#           activate -> {"needed": [...], "status": "<text>"}   discover_* -> {"rc": <0|1>, "stdout": "<text>"}
#
# SAFETY. The legacy code installs things. Here every `claude` and `git` is a recording fake, HOME and HEIMDALL_HOME are per-case throwaways, nothing is
# read from or written to the operator's home, the repository or the network. A case that exits unexpectedly, times out or cannot be parsed FAILS the
# whole recording (exit 1, naming it): a baseline with a silent gap is worse than none.
#
# Exit: 0 recorded, 1 could not record, 2 usage. SKILLS_BASELINE_JOBS=<n> sets the worker count (default: the CPU count, at most 8).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INPUTS="$REPO/test/fixtures/skills-baseline/inputs.json"

die() { printf 'skills_baseline_record: %s\n' "$1" >&2; exit 1; }
usage() { printf 'usage: skills_baseline_record.sh record <out.json>\n' >&2; exit 2; }

[ "${1:-}" = record ] && [ $# -eq 2 ] || usage
OUT="$2"
[ -d "$(dirname "$OUT")" ] || die "the output directory $(dirname "$OUT") does not exist"
[ -f "$INPUTS" ] || die "the input matrix $INPUTS is missing"

PY="$(command -v python3)" || die "python3 is required"
# the real interpreter, not a version-manager shim (0.3-0.8 s a call, and the legacy code starts python for most cases); a wrapper rather than a symlink,
# the way test/lib/py-pin.sh does it, so a venv's pyvenv.cfg is still found
REALPY="$("$PY" -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
case "$REALPY" in /*) ;; *) REALPY="" ;; esac
[ -n "$REALPY" ] && [ -x "$REALPY" ] || die "cannot resolve the interpreter behind $PY"

WORK="$(mktemp -d)" || die "cannot make a temp dir"
trap 'rm -rf "$WORK"' EXIT
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"

QUOTED="$(printf '%s' "$REALPY" | sed "s/'/'\\\\''/g")"
printf '#!/bin/sh\nexec %s "$@"\n' "'$QUOTED'" > "$FAKEBIN/python3"

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
chmod +x "$FAKEBIN/python3" "$FAKEBIN/claude" "$FAKEBIN/git"

"$REALPY" -B -I - "$REPO" "$WORK" "$OUT" <<'PYEOF'
import concurrent.futures
import contextlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import threading

REPO, WORK, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
INPUTS = REPO + "/test/fixtures/skills-baseline/inputs.json"
FAKEBIN = WORK + "/fakebin"
CHILD_PATH = FAKEBIN + ":/usr/bin:/bin"
TIMEOUT_S = 120
NAME = re.compile(r"^[A-Za-z0-9._-]+$")
CLONE_URL = re.compile(r"^https://github\.com/(.+)\.git$")
BASH = shutil.which("bash", path="/usr/bin:/bin")

# The two functions of bin/heimdall, run unmodified. PLUGIN_DIR and WORK_DIR are what the launcher has set when it calls them. The shell is left
# strict (set -euo pipefail) like the launcher, so a legacy line that trips it fails the recording instead of hiding.
PREINSTALL = r'''
set -euo pipefail
. "$REPO/bin/lib/install-receipt.sh"
eval "$(sed -n '/^preinstall_plugins()/,/^}/p' "$REPO/bin/heimdall")"
WORK_DIR="$PROJ"
PLUGIN_DIR="$REPO"
preinstall_plugins "$PROMPT"
'''
KEYWORD = r'''
set -euo pipefail
. "$REPO/bin/lib/install-receipt.sh"
eval "$(sed -n '/^discover_skills()/,/^}/p' "$REPO/bin/heimdall")"
WORK_DIR="$PROJ"
PLUGIN_DIR="$REPO"
discover_skills "$PROMPT"
'''

# category -> (required keys, optional keys) besides "id"
SHAPES = {
    "preinstall": ({"prompt"}, {"files"}),
    "preinstall_installed": ({"prompt", "installed"}, {"files"}),
    "keyword_match": ({"prompt"}, set()),
    "activate": (set(), {"files", "settings"}),
    "discover_detect": ({"prompt"}, {"installed_skills"}),
    "discover_detect_file": ({"path"}, {"files", "installed_skills"}),
    "discover_gaps": (set(), {"installed_skills"}),
}


class RecordError(Exception):
    """A case cannot be recorded, or the matrix is not usable; the message names which."""


def fail(message):
    raise RecordError(message)


# ── the input matrix: strict, because a typo'd key or a swallowed case would silently shrink the baseline ──
def text_ok(value):
    return isinstance(value, str) and "\x00" not in value


def relative_ok(path):
    norm = os.path.normpath(path) if isinstance(path, str) and path else "."
    return text_ok(path) and not os.path.isabs(path) and norm != "." and norm != ".." and not norm.startswith("../")


def validate(data):
    if not isinstance(data, dict) or data.get("schema") != 1 or set(data) - {"schema", "about", "cases"}:
        fail("inputs.json: want an object with schema 1, an optional about, and cases")
    cases = data.get("cases")
    if not isinstance(cases, dict) or not cases:
        fail("inputs.json: cases must be a non-empty object of category -> list of cases")
    for category, rows in cases.items():
        if category not in SHAPES:
            fail("inputs.json: unknown category %r (known: %s)" % (category, ", ".join(sorted(SHAPES))))
        if not isinstance(rows, list) or not rows:
            fail("%s: want a non-empty list of cases" % category)
        required, optional = SHAPES[category]
        seen = set()
        for row in rows:
            if not isinstance(row, dict) or not isinstance(row.get("id"), str) or not NAME.match(row["id"]):
                fail("%s: every case needs an id matching %s" % (category, NAME.pattern))
            label = "%s/%s" % (category, row["id"])
            if row["id"] in seen:
                fail("%s: duplicate id" % label)
            seen.add(row["id"])
            keys = set(row) - {"id"}
            if not required <= keys or keys - required - optional:
                fail("%s: want keys %s (optional %s), got %s" % (label, sorted(required), sorted(optional), sorted(keys)))
            if "prompt" in row and not text_ok(row["prompt"]):
                fail("%s: prompt must be text without NUL" % label)
            if "path" in row and not relative_ok(row["path"]):
                fail("%s: path %r must stay inside the project" % (label, row["path"]))
            if "files" in row:
                if not isinstance(row["files"], dict):
                    fail("%s: files must be an object of path -> text" % label)
                for rel, body in row["files"].items():
                    if not relative_ok(rel):
                        fail("%s: the file path %r must stay inside the project" % (label, rel))
                    if not text_ok(body):
                        fail("%s: the file %r must hold text without NUL" % (label, rel))
            if "installed" in row and not (isinstance(row["installed"], list)
                                           and all(text_ok(item) and "\n" not in item for item in row["installed"])):
                fail("%s: installed must be a list of single-line plugin ids" % label)
            if "installed_skills" in row and not (isinstance(row["installed_skills"], list)
                                                  and all(isinstance(item, str) and NAME.match(item) for item in row["installed_skills"])):
                fail("%s: installed_skills must be a list of skill names" % label)
            if "settings" in row and not isinstance(row["settings"], dict):
                fail("%s: settings must be an object" % label)


# ── one case's private world, and how the legacy code is run inside it ──
def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)


def read_lines(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read().splitlines()


class Box(object):
    """Its own HOME, HEIMDALL_HOME, fake-claude state, call logs and project tree. Nothing is shared between cases."""

    def __init__(self, category, index, case):
        root = "%s/%s-%d" % (WORK, category, index)
        self.home, self.hh, self.state, self.proj = (root + "/" + name for name in ("home", "hh", "state", "proj"))
        self.claude_log, self.git_log = root + "/claude-calls.log", root + "/git-calls.log"
        for directory in (self.home, self.hh, self.state, self.proj):
            os.makedirs(directory)
        write_text(self.state + "/installed", "".join(item + "\n" for item in case.get("installed", [])))
        write_text(self.state + "/markets", "")
        write_text(self.claude_log, "")
        write_text(self.git_log, "")
        for rel, body in case.get("files", {}).items():
            write_text(self.proj + "/" + rel, body)
        for skill in case.get("installed_skills", []):
            os.makedirs(self.home + "/.claude/skills/" + skill)
        if "settings" in case:
            write_text(self.home + "/.claude/settings.json", json.dumps(case["settings"]))

    def env(self, **extra):
        """The COMPLETE environment of a legacy process. HMD_SKILLS_* pin the later M1 switches to what 'legacy' means: registry off, consent auto."""
        env = {
            "PATH": CHILD_PATH, "HOME": self.home, "HEIMDALL_HOME": self.hh, "HMD_RUN_ID": "skills-baseline",
            "LC_ALL": "C", "PYTHONIOENCODING": "utf-8",
            "HMD_SKILLS_REGISTRY": "off", "HMD_SKILLS_CONSENT": "auto",
            "FAKE_STATE": self.state, "FAKE_CALLS": self.claude_log, "FAKE_GIT_CALLS": self.git_log,
        }
        env.update(extra)
        return env


def run(label, argv, env, cwd):
    try:
        done = subprocess.run(argv, env=env, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        raise RecordError("%s: no answer after %d s" % (label, TIMEOUT_S))
    return done.returncode, done.stdout.decode("utf-8"), done.stderr.decode("utf-8", "replace")


def run_function(label, box, snippet, prompt):
    rc, _out, err = run(label, [BASH, "-c", snippet], box.env(REPO=REPO, PROJ=box.proj, PROMPT=prompt), box.proj)
    if rc != 0:
        raise RecordError("%s: the legacy function exited %d: %s" % (label, rc, err.strip()[-300:]))


def install_attempts(label, box):
    ids = []
    for line in read_lines(box.claude_log):
        words = line.split()
        if words[:3] == ["claude", "plugins", "install"]:
            if len(words) != 4:
                raise RecordError("%s: unreadable install call %r" % (label, line))
            ids.append(words[3])
    return ids


def clones(label, box):
    found = []
    for line in read_lines(box.git_log):
        parts = line.split("\t")
        url = CLONE_URL.match(parts[1]) if len(parts) == 3 and parts[0] == "clone" else None
        if not url:
            raise RecordError("%s: unreadable git call %r" % (label, line))
        found.append("%s|%s" % (os.path.basename(parts[2]), url.group(1)))
    return found


def discover(label, box, args):
    rc, out, err = run(label, [BASH, REPO + "/bin/discover-skills"] + args, box.env(), box.proj)
    if rc not in (0, 1):
        raise RecordError("%s: bin/discover-skills exited %d: %s" % (label, rc, err.strip()[-300:]))
    return {"rc": rc, "stdout": out}


def record_preinstall(label, box, case):
    run_function(label, box, PREINSTALL, case["prompt"])
    return install_attempts(label, box)


def record_keyword(label, box, case):
    run_function(label, box, KEYWORD, case["prompt"])
    return clones(label, box)


def record_activate(label, box, case):
    rc, out, err = run(label, [BASH, REPO + "/bin/skill-manager", "status", box.proj], box.env(), box.proj)
    if rc != 0:
        raise RecordError("%s: bin/skill-manager status exited %d: %s" % (label, rc, err.strip()[-300:]))
    return {"needed": sorted(LEGACY["needed_plugins"](LEGACY["config"], box.proj)), "status": out}


LEGACY = {}  # needed_plugins() and its config: the legacy python the activation cases exercise, loaded once, before any case runs

RECORDERS = {
    "preinstall": record_preinstall,
    "preinstall_installed": record_preinstall,
    "keyword_match": record_keyword,
    "activate": record_activate,
    "discover_detect": lambda label, box, case: discover(label, box, ["detect", case["prompt"]]),
    "discover_detect_file": lambda label, box, case: discover(label, box, ["detect-file", case["path"]]),
    "discover_gaps": lambda label, box, case: discover(label, box, ["gaps"]),
}


def record_case(category, index, case):
    label = "%s/%s" % (category, case["id"])
    try:
        box = Box(category, index, case)
        return case["id"], RECORDERS[category](label, box, case)
    except RecordError:
        raise
    except Exception as exc:
        raise RecordError("%s: %s: %s" % (label, type(exc).__name__, exc))


# ── the header, the output, the run ──
def tool_line(argv):
    done = subprocess.run(argv, env={"PATH": CHILD_PATH, "LC_ALL": "C"}, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, timeout=TIMEOUT_S)
    lines = done.stdout.decode("utf-8", "replace").strip().splitlines()
    return lines[0].strip() if lines else "unknown"


def job_count():
    raw = os.environ.get("SKILLS_BASELINE_JOBS", "")
    if not raw:
        return max(1, min(8, os.cpu_count() or 2))
    if not raw.isdigit() or int(raw) < 1:
        raise RecordError("SKILLS_BASELINE_JOBS must be a positive integer, got %r" % raw)
    return int(raw)


def emit(path, header, results):
    lines = ["{", '  "schema": 1,', '  "header": %s,' % json.dumps(header, ensure_ascii=False), '  "cases": {']
    categories = list(results.items())
    for ci, (category, answers) in enumerate(categories):
        lines.append("    %s: {" % json.dumps(category))
        items = list(answers.items())
        for ri, (case_id, value) in enumerate(items):
            lines.append("      %s: %s%s" % (json.dumps(case_id), json.dumps(value, ensure_ascii=False), "," if ri < len(items) - 1 else ""))
        lines.append("    }" + ("," if ci < len(categories) - 1 else ""))
    lines += ["  }", "}"]
    text = "\n".join(lines) + "\n"
    if json.loads(text) != {"schema": 1, "header": header, "cases": results}:
        raise RecordError("internal error: the recording does not parse back to what was recorded")
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def record_all():
    try:
        with open(INPUTS, encoding="utf-8") as handle:
            inputs = json.load(handle)
    except (OSError, ValueError) as exc:
        raise RecordError("inputs.json: %s" % exc)
    validate(inputs)
    if not BASH:
        raise RecordError("no bash in /usr/bin or /bin")
    try:
        # imported unmodified; bytecode is never written (-B), so the tree stays as it was found
        spec = importlib.util.spec_from_file_location("skill_restore", REPO + "/bin/lib/skill_restore.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        LEGACY["needed_plugins"] = module.needed_plugins
        LEGACY["config"] = module.read_json(REPO + "/heimdall-skills.json")
    except (OSError, ValueError, SyntaxError, AttributeError) as exc:
        raise RecordError("cannot load bin/lib/skill_restore.py and heimdall-skills.json: %s: %s" % (type(exc).__name__, exc))
    tasks = [(category, index, case) for category, rows in inputs["cases"].items() for index, case in enumerate(rows)]
    stop = threading.Event()

    def work(task):
        if stop.is_set():
            return None
        try:
            return record_case(*task)
        except BaseException:
            stop.set()
            raise

    with concurrent.futures.ThreadPoolExecutor(max_workers=job_count()) as pool:
        futures = [pool.submit(work, task) for task in tasks]
    for future in futures:
        error = future.exception()
        if error is not None:
            raise error
    results = {}
    for (category, _index, _case), future in zip(tasks, futures):
        case_id, value = future.result()
        results.setdefault(category, {})[case_id] = value
    header = {"grep": tool_line(["grep", "--version"]), "python3": tool_line(["python3", "--version"]),
              "uname": tool_line(["uname", "-sm"])}
    emit(OUT, header, results)
    print("recorded %d cases in %d categories" % (len(tasks), len(results)))


try:
    record_all()
except RecordError as exc:
    sys.stderr.write("skills_baseline_record: %s\n" % exc)
    sys.exit(1)
PYEOF
