#!/usr/bin/env python3
"""split_baseline.py -- write down, from the UNMODIFIED tree, what the skills and statusline files and renders are BEFORE the repo split (T0.1).

Plan: docs/superpowers/plans/2026-11-22-split-skills-statusline-repos.md (sections 1a, 1b and 5; task T0.1). The later waves mirror these files into
two new repos and prove against this recording that nothing moved: INV-S1 (the same bytes at the same path), INV-S2 (the registered entry points
unchanged) and INV-S3 (the same rendered bytes). This tool holds NO expected value of its own: `record` measures the tree it is pointed at, `check`
measures it again and compares with evals/split/baseline.json. It never reads bin/heimdall-suite-closure (plan section 1b: the static closure of a
statusline suite is the whole of heimdall): the boundary is the explicit path lists below, taken from the plan's two inventories.

  split_baseline.py record [--root DIR] [--out FILE]
  split_baseline.py check  [--root DIR] [--baseline FILE] [--only paths|host-calls|renders]... [--match TEXT]

--root is the tree that is measured (default: the tree this file lives in); --baseline / --out default to <this tree>/evals/split/baseline.json
whatever --root is, so a doctored copy of the files can be checked against the real recording.

WHAT IS RECORDED
  paths       sha256, byte count and exec bit of every moved file: skills (21: stacks, designmatch, self-improve, system-health, mac-deep-clean),
              statusline runtime (18: hooks, bin, sentinels), conformance/statusline (26: invariants, 21 goldens, 4 fixtures) and the statusline,
              sigil, status-json and cursor-statusline suites (35). A link or a directory where a file belongs is a difference, not a file.
  host-calls  per suite of the 35: which HOST files (the plan's "stays core" list and the reverse-dependency list) the suite names. Read from the
              suite's text without its full-line comments, so it is what the suite can call, not what it talks about. A one-word name (heimdall,
              falsify) is also prose, so it counts only with its directory (bin/heimdall); a name followed by `.ext` is another file (agent-pool.json
              is a data file, not bin/agent-pool).
  renders     sha256 and byte count of what the renderers print for fixed inputs, run from the root with a COMPLETE, minimal environment (nothing
              inherited, a throwaway HOME and workspace, a fixed clock, an unreachable control plane): the density fixtures of
              test/heimdall-statusline-density.test.sh, the sigil fixtures of test/heimdall-sigil-render.test.sh (and the hyphen twin and the CLI),
              the two registered entry points (hooks/statusline.sh for Claude Code, bin/heimdall-statusline for Cursor and by hand) in the setups of
              test/heimdall-statusline-parity.test.sh, and the subagent row of hooks/subagent-statusline.sh.

`record` renders every fixture twice and refuses to write when the two renders differ or a render exits non-zero, writes to stderr or prints nothing:
a baseline with a silent gap, or of a render that is not reproducible, is worse than none.

Exit: 0 ok (check: no difference), 1 a difference or a measurement that failed, 2 usage or an unreadable baseline.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

SCHEMA = 1
PLAN = "docs/superpowers/plans/2026-11-22-split-skills-statusline-repos.md"
TOOL_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_BASELINE = os.path.join(TOOL_ROOT, "evals", "split", "baseline.json")
PHASES = ("paths", "host-calls", "renders")
RENDER_TIMEOUT_S = 60


def render_jobs():
    """Render workers: SPLIT_BASELINE_JOBS, else the CPU count at most 8 (the way test/lib/skills_baseline_record.sh does it)."""
    wanted = os.environ.get("SPLIT_BASELINE_JOBS")
    if wanted is not None:
        if wanted.isdigit() and int(wanted) > 0:
            return int(wanted)
        print("split_baseline: SPLIT_BASELINE_JOBS=%r is not a positive integer, using the default" % wanted, file=sys.stderr)
    return max(1, min(8, os.cpu_count() or 1))

# ── the moved set: plan sections 1a and 1b, as explicit paths ────────────────────────────────────────────────────────────────────────────────────
SKILLS = """
skills/designmatch/SKILL.md skills/designmatch/assets/visual-qa.ts skills/designmatch/package-lock.json skills/designmatch/package.json
skills/designmatch/references/anti-patterns.md skills/designmatch/references/canonical-values.md
skills/designmatch/scripts/emit-parity.js skills/designmatch/scripts/fetch-canonical.js skills/designmatch/scripts/iterate-screen.sh
skills/designmatch/scripts/render-canonical.js skills/designmatch/scripts/render-web-candidate.js skills/designmatch/scripts/visual-diff.js
skills/mac-deep-clean/SKILL.md skills/self-improve/SKILL.md skills/system-health/SKILL.md
skills/stacks/README.md skills/stacks/SKILL.md
skills/stacks/fastapi/PACK.md skills/stacks/nextjs/PACK.md skills/stacks/react-native/PACK.md skills/stacks/spring-boot/PACK.md
""".split()

RUNTIME = """
hooks/statusline.sh hooks/subagent-statusline.sh
bin/heimdall-statusline bin/heimdall-statusline-register bin/heimdall-statusline-register-cursor bin/heimdall-sigil bin/heimdall-sigil-png
sentinels/hmd-statusline.py sentinels/hmd_sigil.py sentinels/hmd_gauge.py sentinels/hmd_sigil_png.py sentinels/subagent-statusline.py
sentinels/hmd-subagent-statusline.sh sentinels/hmd-sigil.py
sentinels/hmd_layout.py sentinels/hmd_termcaps.py sentinels/hmd_ledger.py sentinels/hmd_wall.py
""".split()

DENSITY_COLUMNS = {"full": 120, "mid": 80, "narrow": 48, "tiny": 30}
SIGIL_SIZES = ("L", "M", "S")
COLORS = ("16", "256", "truecolor")
CONFORMANCE = (
    ["conformance/statusline/INVARIANTS.md"]
    + ["conformance/statusline/goldens/density/rj_%s_%s.txt" % (tier, color) for tier in DENSITY_COLUMNS for color in COLORS]
    + ["conformance/statusline/goldens/sigil/rj_%s_%s.txt" % (size, color) for size in SIGIL_SIZES for color in COLORS]
    + ["conformance/statusline/%s.fixture.sh" % name for name in ("prefix-and-elements", "viral-gate-anim", "viral-sigil", "viral-statusline")]
)

STATUSLINE_SUITES = """
agent-tiers agents-cache cc-columns cc-region-reserve cols-detect crossbranch cursor-payload density eyestrip fullbleed gauge host-boundary
identity-flip member-age panel-floor parity perf-budget portability rate-limit-persist register-cursor terminals update-notice width
""".split()
SIGIL_SUITES = "cache custom detailed eyestrip-mini heroes micro png render sprites team-mini".split()
TESTS = (
    ["test/heimdall-statusline-%s.test.sh" % name for name in STATUSLINE_SUITES]
    + ["test/heimdall-sigil-%s.test.sh" % name for name in SIGIL_SUITES]
    + ["test/heimdall-status-json.test.sh", "test/heimdall-init-cursor-statusline.test.sh"]
)

GROUPS = (("skills", SKILLS), ("statusline-runtime", RUNTIME), ("statusline-conformance", CONFORMANCE), ("statusline-tests", TESTS))
PATHS = [(group, rel) for group, rels in GROUPS for rel in sorted(rels)]

# The HOST side of the statusline: the plan's "not moved, stays core" list (section 1b) and the core files that consume the moved code.
HOST_PATHS = sorted("""
bin/heimdall-status-json bin/heimdall-face bin/heimdall-ctx-meter bin/heimdall-agents bin/heimdall-identity bin/heimdall-presence bin/heimdall-tier
bin/agent-pool bin/shared-memory bin/lib/hmd-python.sh bin/lib/hmd_session_code.py bin/lib/hmd_private_state.py bin/lib/repo_roster.py
hooks/hooks.json install.sh bin/heimdall bin/heimdall-board bin/summary-card bin/falsify bin/lib/watch_data.py bin/lib/watch_tui.py
sentinels/hmd-banner.sh sentinels/hmd-gate-anim.sh sentinels/hmd-ui.py bin/heimdall-doctor-install
""".split())


class Usage(Exception):
    """A request or a baseline this tool cannot work with (exit 2)."""


def short(value):
    return value[:12] + ".." if isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) else repr(value)


# ── paths ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def measure_file(root, rel):
    """{"sha256", "bytes", "exec"} of the regular file root/rel, or the text of why it is not one."""
    full = os.path.join(root, rel)
    try:
        info = os.lstat(full)
        if not stat.S_ISREG(info.st_mode):
            return "not a regular file (a link or a directory)"
        with open(full, "rb") as fh:
            data = fh.read()
    except OSError as exc:
        return "cannot read: %s" % exc.strerror
    return {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "exec": bool(info.st_mode & 0o111)}


def measure_paths(root):
    out = {}
    for group, rel in PATHS:
        got = measure_file(root, rel)
        out[rel] = got if isinstance(got, str) else dict(group=group, **got)
    return out


# ── host calls ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def host_pattern(path):
    base = os.path.basename(path)
    name = path if re.fullmatch(r"[a-z]+", base) else base
    return re.compile(r"(?<![\w.-])" + re.escape(name) + r"(?![\w-]|\.\w)")


def measure_host_calls(root):
    patterns = [(path, host_pattern(path)) for path in HOST_PATHS]
    out = {}
    for suite in TESTS:
        try:
            with open(os.path.join(root, suite), "rb") as fh:
                text = fh.read().decode("utf-8", "replace")
        except OSError as exc:
            out[suite] = "cannot read: %s" % exc.strerror
            continue
        code = "\n".join(line for line in text.split("\n") if not line.lstrip().startswith("#"))
        out[suite] = [path for path, rx in patterns if rx.search(code)]
    return out


# ── renders ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
class Fixture(object):
    """One render: an id, the entry point it exercises and prep(root, work) -> (argv, stdin text, environment) inside a throwaway directory."""

    def __init__(self, ident, entry, prep):
        self.ident, self.entry, self.prep = ident, entry, prep


def _dirs(work):
    ws, home, tmp = (os.path.join(work, name) for name in ("ws", "home", "tmp"))
    for path in (os.path.join(ws, ".heimdall"), home, tmp):
        os.makedirs(path)
    return ws, home, tmp


def _write(path, text):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def _env(home, extra):
    env = {"PATH": os.pathsep.join([os.path.dirname(sys.executable), "/usr/bin", "/bin"]), "HOME": home, "LANG": "en_US.UTF-8"}
    env.update(extra)
    return env


def _identity(ws):
    _write(os.path.join(ws, ".heimdall", "identity.json"), '{"handle":"rj","seed":"rj","created":0}\n')
    _write(os.path.join(ws, ".heimdall", "statusline.json"), '{"verdict":"pass","passed":3,"total":3}\n')


ROSTER = ('[{"handle":"nadia","haid":"haid:nadia","verdict":"working","file":"auth.ts","age_seconds":4},'
          '{"handle":"arjun","haid":"haid:arjun","verdict":"watching","file":"db.go","age_seconds":9},'
          '{"handle":"priya","haid":"haid:priya","verdict":"deny","file":"api.py","age_seconds":6}]\n')
CODE_SEED = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"


def density_fixture(tier, color):
    """test/heimdall-statusline-density.test.sh render_case: the committed goldens are what this prints."""
    def prep(root, work):
        ws, home, tmp = _dirs(work)
        _identity(ws)
        _write(os.path.join(ws, ".heimdall", ".roster-cache.json"), ROSTER)
        os.makedirs(os.path.join(home, ".heimdall"), mode=0o700)
        _write(os.path.join(home, ".heimdall", "session-code.key"), CODE_SEED + "\n")
        os.chmod(os.path.join(home, ".heimdall", "session-code.key"), 0o600)
        payload = {
            "workspace": {"project_dir": "/hmd-density-fixture/repo", "current_dir": ws, "repo": {"name": "heimdall", "branch": "statusline-v1"}},
            "model": {"display_name": "Opus 4.8"},
            "context_window": {"used_percentage": 42, "total_input_tokens": 128000},
            "session_id": "density",
            "cost": {"total_cost_usd": 0.87, "total_duration_ms": 3840000},
            "rate_limits": {"five_hour": {"used_percentage": 42, "resets_at": 7207}, "seven_day": {"used_percentage": 12}},
        }
        env = _env(home, {"HEIMDALL_IDENTITY_DIR": os.path.join(ws, ".heimdall"), "HMD_HAID": "rj", "HMD_NOW": "7",
                          "HEIMDALL_CP_URL": "http://127.0.0.1:1", "COLUMNS": str(DENSITY_COLUMNS[tier]), "HMD_STATUSLINE_TMP": tmp,
                          "HMD_STATUSLINE_RESERVE": "0", "HEIMDALL_STATUSLINE_MODE": color})
        return [sys.executable, os.path.join(root, "sentinels", "hmd-statusline.py")], json.dumps(payload, separators=(",", ":")), env
    return Fixture("density:%s:%s" % (tier, color), "sentinels/hmd-statusline.py", prep)


def sigil_fixture(ident, entry, size, color, via_bash=False):
    """test/heimdall-sigil-render.test.sh: `<entry> --seed rj --size S|M|L --tier <color>` (the committed sigil goldens for hmd_sigil.py)."""
    def prep(root, work):
        _, home, _ = _dirs(work)
        argv = [os.path.join(root, entry), "--seed", "rj", "--size", size, "--tier", color]
        return (["bash"] if via_bash else [sys.executable]) + argv, "", _env(home, {})
    return Fixture(ident, entry, prep)


def entry_fixture(ident, entry, mode, cols):
    """test/heimdall-statusline-parity.test.sh: a Claude-Code-shaped payload through one registered entry point, solo or with a team roster."""
    def prep(root, work):
        ws, home, tmp = _dirs(work)
        _identity(ws)
        if mode == "team":
            _write(os.path.join(ws, ".heimdall", ".roster-cache.json"), ROSTER)
        _write(os.path.join(ws, ".heimdall", ".beat-stamp"), "")
        _write(os.path.join(ws, ".heimdall", ".wall-cache.json.lock"), "")
        payload = {
            "workspace": {"current_dir": ws, "repo": {"name": "heimdall", "branch": "parity"}},
            "model": {"display_name": "Opus 4.8"},
            "context_window": {"used_percentage": 55, "total_input_tokens": 256000},
            "cost": {"total_cost_usd": 1.23, "total_duration_ms": 1800000},
            "rate_limits": {"five_hour": {"used_percentage": 28, "resets_at": 1752417200}, "seven_day": {"used_percentage": 41}},
            "session_id": "parity-%d" % cols,
        }
        return ["bash", os.path.join(root, entry)], json.dumps(payload, separators=(",", ":")), _env(home, {
            "HEIMDALL_IDENTITY_DIR": os.path.join(ws, ".heimdall"), "HMD_HAID": "rj", "HMD_NOW": "1752410000", "HEIMDALL_CP_URL": "http://127.0.0.1:1",
            "COLUMNS": str(cols), "TERM": "xterm-256color", "HMD_STATUSLINE_TMP": tmp, "HEIMDALL_STATUSLINE_MODE": "truecolor"})
    return Fixture(ident, entry, prep)


def cursor_fixture():
    """A Cursor payload: the width comes from render_width_chars, COLUMNS is unset (test/heimdall-statusline-parity.test.sh, section 2)."""
    def prep(root, work):
        ws, home, tmp = _dirs(work)
        _identity(ws)
        _write(os.path.join(ws, ".heimdall", ".beat-stamp"), "")
        _write(os.path.join(ws, ".heimdall", ".wall-cache.json.lock"), "")
        payload = {"cwd": ws, "workspace": {"current_dir": ws}, "model": {"display_name": "Composer"}, "context_window": {"used_percentage": 30},
                   "render_width_chars": 88, "session_id": "cursor-1"}
        return ["bash", os.path.join(root, "bin", "heimdall-statusline")], json.dumps(payload, separators=(",", ":")), _env(home, {
            "HEIMDALL_IDENTITY_DIR": os.path.join(ws, ".heimdall"), "HMD_HAID": "rj", "HMD_NOW": "1752410000", "HEIMDALL_CP_URL": "http://127.0.0.1:1",
            "TERM": "xterm-256color", "HMD_STATUSLINE_TMP": tmp, "HEIMDALL_STATUSLINE_MODE": "truecolor"})
    return Fixture("entry:cli:cursor-88", "bin/heimdall-statusline", prep)


def subagent_fixture(cols):
    """hooks/subagent-statusline.sh: one running subagent (and a finished one that must not print) at a roomy and a tight width."""
    def prep(root, work):
        _, home, _ = _dirs(work)
        payload = {"columns": cols, "tasks": [
            {"id": "t-run", "name": "coder", "description": "implement the authentication middleware for the gateway", "status": "running",
             "startTime": 1000, "tokenCount": 708000, "model": "opus", "contextWindowSize": 1000000},
            {"id": "t-done", "name": "reviewer", "description": "review pr", "status": "completed", "startTime": 1000, "tokenCount": 42000,
             "model": "sonnet", "contextWindowSize": 1000000}]}
        return ["bash", os.path.join(root, "hooks", "subagent-statusline.sh")], json.dumps(payload, separators=(",", ":")), _env(home, {
            "HMD_NOW": "1250", "TERM": "xterm-256color", "HEIMDALL_STATUSLINE_MODE": "truecolor"})
    return Fixture("subagent:%d" % cols, "hooks/subagent-statusline.sh", prep)


def fixtures():
    out = [density_fixture(tier, color) for tier in DENSITY_COLUMNS for color in COLORS]
    out += [sigil_fixture("sigil:%s:%s" % (size, color), "sentinels/hmd_sigil.py", size, color) for size in SIGIL_SIZES for color in COLORS]
    out += [sigil_fixture("sigil-twin:%s:256" % size, "sentinels/hmd-sigil.py", size, "256") for size in SIGIL_SIZES]
    out.append(sigil_fixture("sigil-cli:M:256", "bin/heimdall-sigil", "M", "256", via_bash=True))
    for name, entry in (("hook", "hooks/statusline.sh"), ("cli", "bin/heimdall-statusline")):
        out += [entry_fixture("entry:%s:%s:%d" % (name, mode, cols), entry, mode, cols) for mode, cols in (("solo", 120), ("team", 60))]
    out.append(cursor_fixture())
    out += [subagent_fixture(cols) for cols in (120, 40)]
    return out


def run_fixture(root, fixture):
    """{"entry", "sha256", "bytes"} of what the fixture prints, or the text of why it printed nothing usable."""
    work = tempfile.mkdtemp(prefix="split-baseline.")
    try:
        argv, stdin, env = fixture.prep(root, work)
        try:
            done = subprocess.run(argv, input=stdin.encode("utf-8"), env=env, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  timeout=RENDER_TIMEOUT_S)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return "could not run: %s" % exc
        if done.returncode != 0:
            return "exit %d: %s" % (done.returncode, done.stderr.decode("utf-8", "replace").strip()[:200])
        if done.stderr:
            return "wrote to stderr: %s" % done.stderr.decode("utf-8", "replace").strip()[:200]
        if not done.stdout:
            return "printed nothing"
        return {"entry": fixture.entry, "sha256": hashlib.sha256(done.stdout).hexdigest(), "bytes": len(done.stdout)}
    finally:
        shutil.rmtree(work, ignore_errors=True)


def measure_renders(root, match=""):
    chosen = [fx for fx in fixtures() if match in fx.ident]
    with concurrent.futures.ThreadPoolExecutor(max_workers=render_jobs()) as pool:
        results = list(pool.map(lambda fx: run_fixture(root, fx), chosen))
    return {fx.ident: result for fx, result in zip(chosen, results)}


# ── the recording ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def _failures(kind, measured):
    return ["FAIL %s %s: %s" % (kind, ident, got) for ident, got in sorted(measured.items()) if isinstance(got, str)]


def build(root):
    """(document, failures): the measurements of root as a baseline document, and every measurement that did not work."""
    paths, calls = measure_paths(root), measure_host_calls(root)
    problems = _failures("paths", paths) + _failures("host-calls", calls)
    problems += ["FAIL host-paths %s: the plan names it as host, root has no such file" % path
                 for path in HOST_PATHS if not os.path.isfile(os.path.join(root, path))]
    if problems:
        return None, problems
    first, second = measure_renders(root), measure_renders(root)
    problems = _failures("renders", first)
    problems += ["FAIL renders %s: two renders of one fixture differ, so it cannot be a baseline" % ident
                 for ident in sorted(first) if isinstance(first[ident], dict) and first[ident] != second[ident]]
    if problems:
        return None, problems
    doc = {"schema": SCHEMA, "plan": PLAN,
           "paths": [dict(path=rel, **paths[rel]) for _, rel in PATHS],
           "host_paths": HOST_PATHS,
           "host_calls": calls,
           "renders": [dict(id=ident, **first[ident]) for ident in sorted(first)]}
    return doc, []


def dumps(doc):
    """One entry per line, so a change to the tree diffs as the entries it moved."""
    def one(value):
        return json.dumps(value, separators=(", ", ": "), ensure_ascii=False)

    def rows(items):
        return ",\n".join("    " + item for item in items)
    parts = ['  "schema": %d' % doc["schema"], '  "plan": %s' % one(doc["plan"]),
             '  "paths": [\n%s\n  ]' % rows(one(entry) for entry in doc["paths"]),
             '  "host_paths": [\n%s\n  ]' % rows(one(path) for path in doc["host_paths"]),
             '  "host_calls": {\n%s\n  }' % rows("%s: %s" % (one(suite), one(doc["host_calls"][suite])) for suite in sorted(doc["host_calls"])),
             '  "renders": [\n%s\n  ]' % rows(one(entry) for entry in doc["renders"])]
    return "{\n" + ",\n".join(parts) + "\n}\n"


def write_atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


HEX = object()
SHAPES = {
    "paths": {"path": str, "group": str, "sha256": HEX, "bytes": int, "exec": bool},
    "renders": {"id": str, "entry": str, "sha256": HEX, "bytes": int},
}


def _is(value, kind):
    if kind is HEX:
        return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None
    if kind is int:
        return isinstance(value, int) and not isinstance(value, bool)
    return isinstance(value, kind)


def load_baseline(path):
    try:
        with open(path, "rb") as fh:
            doc = json.loads(fh.read().decode("utf-8"))
    except (OSError, ValueError) as exc:
        raise Usage("cannot read the baseline %s: %s" % (path, exc))
    well_formed = (
        isinstance(doc, dict) and doc.get("schema") == SCHEMA
        and all(isinstance(doc.get(key), list) and all(isinstance(e, dict) and set(e) == set(shape) and all(_is(e[k], t) for k, t in shape.items())
                                                       for e in doc[key]) for key, shape in SHAPES.items())
        and isinstance(doc.get("host_paths"), list) and all(isinstance(p, str) for p in doc["host_paths"])
        and isinstance(doc.get("host_calls"), dict)
        and all(isinstance(v, list) and all(isinstance(p, str) for p in v) for v in doc["host_calls"].values()))
    if not well_formed:
        raise Usage("the baseline %s is not a schema-%d recording (paths, host_paths, host_calls, renders)" % (path, SCHEMA))
    return doc


def describe(expected, got):
    if isinstance(got, str):
        return got
    if isinstance(expected, dict):
        return ", ".join("%s %s -> %s" % (key, short(expected.get(key)), short(got.get(key))) for key in sorted(got) if expected.get(key) != got.get(key))
    gone, new = sorted(set(expected) - set(got)), sorted(set(got) - set(expected))
    return "; ".join(part for part in ("no longer names " + ", ".join(gone) if gone else "", "now also names " + ", ".join(new) if new else "") if part)


def compare(kind, expected, measured):
    out = []
    for ident in sorted(set(expected) | set(measured)):
        if ident not in measured:
            out.append("FAIL %s %s: in the baseline, but not something this tool measures" % (kind, ident))
        elif ident not in expected:
            out.append("FAIL %s %s: measured, but the baseline does not list it" % (kind, ident))
        elif expected[ident] != measured[ident]:
            out.append("FAIL %s %s: %s" % (kind, ident, describe(expected[ident], measured[ident])))
    return out


def check(root, baseline, phases, match):
    doc = load_baseline(baseline)
    fails, counts = [], []
    if "paths" in phases:
        expected = {e["path"]: {k: v for k, v in e.items() if k != "path"} for e in doc["paths"]}
        fails += compare("paths", expected, measure_paths(root))
        counts.append("%d paths" % len(expected))
    if "host-calls" in phases:
        fails += compare("host-paths", {p: p for p in doc["host_paths"]}, {p: p for p in HOST_PATHS})
        fails += compare("host-calls", doc["host_calls"], measure_host_calls(root))
        counts.append("%d suites" % len(doc["host_calls"]))
    if "renders" in phases:
        if match and not any(match in fx.ident for fx in fixtures()):
            raise Usage("--match %r selects no render fixture" % match)
        expected = {e["id"]: {k: v for k, v in e.items() if k != "id"} for e in doc["renders"] if match in e["id"]}
        fails += compare("renders", expected, measure_renders(root, match))
        counts.append("%d renders" % len(expected))
    for line in fails:
        print(line)
    print("split-baseline check: %s compared against %s: %s" % (", ".join(counts), os.path.relpath(baseline, TOOL_ROOT) if baseline.startswith(TOOL_ROOT) else baseline,
                                                                "%d difference(s)" % len(fails) if fails else "no difference"))
    return 1 if fails else 0


def record(root, out):
    doc, problems = build(root)
    for line in problems:
        print(line)
    if problems:
        print("split-baseline record: nothing written, %d measurement(s) failed" % len(problems))
        return 1
    write_atomic(out, dumps(doc))
    print("split-baseline record: wrote %s (%d paths, %d suites, %d renders)" % (out, len(doc["paths"]), len(doc["host_calls"]), len(doc["renders"])))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="split_baseline.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    rec = sub.add_parser("record", help="measure the tree and write the baseline")
    chk = sub.add_parser("check", help="measure the tree and compare it with the baseline")
    for sp in (rec, chk):
        sp.add_argument("--root", default=TOOL_ROOT, help="the tree to measure (default: the tree this file lives in)")
    rec.add_argument("--out", default=DEFAULT_BASELINE, help="where to write the baseline (default: evals/split/baseline.json)")
    chk.add_argument("--baseline", default=DEFAULT_BASELINE, help="the recording to compare with (default: evals/split/baseline.json)")
    chk.add_argument("--only", action="append", choices=PHASES, help="check only this phase (repeatable; default: all three)")
    chk.add_argument("--match", default="", help="with the renders phase: only the fixtures whose id contains this text")
    args = parser.parse_args(argv)
    root = os.path.abspath(args.root)
    try:
        if not os.path.isdir(root):
            raise Usage("--root %s is not a directory" % root)
        if args.command == "record":
            return record(root, os.path.abspath(args.out))
        return check(root, os.path.abspath(args.baseline), tuple(args.only or PHASES), args.match)
    except Usage as exc:
        print("split_baseline: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
