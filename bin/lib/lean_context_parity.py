#!/usr/bin/env python3
"""lean_context_parity.py -- the INDEPENDENT reference for lean-core INV-L1 (docs/superpowers/plans/2026-11-12-3x-lean-core.md, T1.2).

INV-L1: with profile `full`, every byte hmd injects into a session, and the files behind it, equal today's. This tool records
that surface from the unmodified tree (`record`) and answers whether a tree still matches it (`check`). It is written without
reading, importing or calling bin/heimdall-footprint, so a defect in the meter cannot hide a regression here.

    lean_context_parity.py measure [--root DIR] [--sections LIST]
    lean_context_parity.py record  [--root DIR] [--baseline FILE]
    lean_context_parity.py check   [--root DIR] [--baseline FILE] [--sections LIST]

    --root DIR       the plugin root to read (default: the repository this file lives in)
    --baseline FILE  the record (default: ROOT/evals/lean/context-baseline.json)
    --sections LIST  comma list of: files, settings, hooks_json, caveman, hook_stdout (default: all)

SECTIONS (each a dict keyed by name; values are sha256 and bytes, never the text):
  files        every file under agents/, commands/, skills/ as it lies on disk (the loader scans directories, not git): sha256,
               bytes and, for a file that opens with a --- line, the frontmatter span (both --- lines) hashed on its own, because
               that span is what a session lists. OS cruft (.DS_Store, __pycache__, *.pyc) is not part of the tree.
  settings     settings.json: its hash and the `agent` it selects as the main-session prompt.
  hooks_json   hooks/hooks.json: its hash and the hook count per event.
  caveman      stdout of `bin/heimdall-caveman rules` and `get`, run in the sandbox.
  hook_stdout  stdout and exit code of each SessionStart / UserPromptSubmit hook, run through the command in hooks.json with a
               fixed stdin in the sandbox (the two events whose stdout reaches the model). Only a hook named in RUN_HOOKS is run;
               every other one is recorded as skipped with its reason (a daemon, an update fetch, a process restart), so a hook
               that is added later is never executed unvetted. Its key is EVENT/NN-ID, NN being its position within the event.

THE SANDBOX. Every command runs with an environment built from nothing: a fresh HOME, HEIMDALL_HOME, project dir and TMPDIR per
run, CLAUDE_PLUGIN_ROOT at the tree under test, a PATH whose first entry holds tripwires for the Keychain, the network and the
GUI (security, curl, gh, ssh, ... each logs its call and exits 97), proxies pointing at a closed port, and no variable of the
caller's. A command that trips a wire, or runs past the timeout (HMD_PARITY_HOOK_TIMEOUT_S, default 60), makes the whole run
exit 2: a number the tool cannot trust is never printed. The sandbox path and the plugin root print as <SANDBOX> and <ROOT>,
so a record does not depend on where the tree sits.

RECORD refuses (exit 2) a tree that is not a git work tree or has uncommitted changes under agents/ commands/ skills/ hooks/
settings.json bin/, so a baseline is always of a commit, and writes atomically with a digest over the sections. CHECK refuses
(exit 2) a baseline whose digest does not match its sections, so a hash cannot be hand-edited to turn a gate green.

EXIT. 0 ok / equal; 1 check found differences (each printed as: changed|missing|extra, section, key, detail); 2 usage, an
unreadable or untrustworthy baseline, or a measurement that could not be trusted (stderr only, nothing on stdout).
stdlib only; run it as `python3 -I`.
"""
import argparse
import contextlib
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

SCHEMA = 1
SECTIONS = ("files", "settings", "hooks_json", "caveman", "hook_stdout")
CONTEXT_DIRS = ("agents", "commands", "skills")
CRUFT_FILES = frozenset((".DS_Store", "Thumbs.db"))
CRUFT_DIRS = frozenset(("__pycache__",))
CRUFT_SUFFIXES = (".pyc",)
CLEAN_PATHS = ("agents", "commands", "skills", "hooks", "settings.json", "bin")
TREE_PATHS = ("agents", "commands", "skills", "hooks", "settings.json")
HOOK_EVENTS = ("SessionStart", "UserPromptSubmit")
SESSION_ID = "lean-context-parity"
DEFAULT_TIMEOUT_S = 60.0
TIMEOUT_ENV = "HMD_PARITY_HOOK_TIMEOUT_S"
DEAD_PROXY = "http://127.0.0.1:9"
DENIED_TOOLS = ("security", "curl", "wget", "gh", "ssh", "scp", "sftp", "nc", "ncat", "osascript", "open", "claude", "codex", "gemini")
DEFAULT_ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

# The hook ids this tool executes: reporters that read state and print, or exit early. None starts a daemon, fetches, restarts a
# process or writes outside the sandbox (read against the commands in hooks/hooks.json). The id is the name each command passes to
# hmd_hook_enabled; a command without one is named bin:<first bin/ file it calls>.
RUN_HOOKS = frozenset((
    "resume-probe", "maintain-resume-hint", "quota-resume-hint", "dream-notice", "presence-connect-prompt", "ai-select",
    "caveman-rules", "settings-guard", "volatile-repo-guard", "continue-inject",
    "parallel-gate", "ctx-meter-notice", "bin:heimdall-secret-filter", "caveman-level-context", "inbox-deliver-prompt",
    "phone-control-prompt", "finished-agents-prompt",
))
NOT_RUN = {
    "session-bootstrap": "starts background jobs, may fetch updates, builds the trackers and writes into the plugin root and the project",
    "presence-keeper-start": "starts a detached keeper process that talks to the control plane",
    "bin:heimdall-scrub-claude-mem": "restarts a running claude-mem worker: it acts on real processes",
    "pair-window-start": "opens a pairing window from a detached process",
    "inbox-wake-register": "registers a wake watcher for the session",
    "inbox-wake-arm-start": "blocks for up to eight hours watching the inbox",
    "agents-auto-prune": "prunes agent worktrees from a detached process",
}

HOOK_ID = re.compile(r"hmd_hook_enabled\s+([A-Za-z0-9_-]+)")
HOOK_BIN = re.compile(r"/bin/([A-Za-z0-9._-]+)")
SHA_HEX = re.compile(r"[0-9a-f]{64}")


class MeasureError(Exception):
    """A measurement or a baseline that cannot be trusted: exit 2, stderr only."""


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def hashed(data):
    return {"sha256": sha256_hex(data), "bytes": len(data)}


def read_bytes(path):
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError as exc:
        raise MeasureError("cannot read %s: %s" % (path, exc.strerror or exc))


def frontmatter_span(data):
    """The bytes from the opening --- line through the closing --- line, both included; None when there is no such span."""
    lines = data.splitlines(True)
    if not lines or lines[0].rstrip(b"\r\n") != b"---":
        return None
    end = len(lines[0])
    for line in lines[1:]:
        end += len(line)
        if line.rstrip(b"\r\n") == b"---":
            return data[:end]
    return None


# ── files ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def walk(root, rel):
    """Yield (relpath, kind, target) for everything under root/rel in name order, links reported and never followed."""
    try:
        with os.scandir(os.path.join(root, rel)) as it:
            entries = sorted(it, key=lambda e: e.name)
    except OSError as exc:
        raise MeasureError("cannot list %s: %s" % (rel, exc.strerror or exc))
    for entry in entries:
        path = rel + "/" + entry.name
        if entry.is_symlink():
            yield path, "link", os.readlink(entry.path)
        elif entry.is_dir(follow_symlinks=False):
            if entry.name not in CRUFT_DIRS:
                for item in walk(root, path):
                    yield item
        elif entry.is_file(follow_symlinks=False):
            if entry.name not in CRUFT_FILES and not entry.name.endswith(CRUFT_SUFFIXES):
                yield path, "file", entry.path
        else:
            raise MeasureError("%s is not a file, a directory or a link" % path)


def measure_files(root):
    files = {}
    for top in CONTEXT_DIRS:
        if not os.path.isdir(os.path.join(root, top)):
            continue
        for path, kind, target in walk(root, top):
            if kind == "link":
                files[path] = {"symlink": target}
                continue
            data = read_bytes(target)
            entry = hashed(data)
            span = frontmatter_span(data)
            if span is not None:
                entry["frontmatter"] = hashed(span)
            files[path] = entry
    return files


# ── settings and hooks.json ─────────────────────────────────────────────────────────────────────────────────────────────────────────
def load_json_file(root, rel):
    """(bytes, parsed) of a JSON file under root, or (None, None) when it is absent; a file that does not parse is an error."""
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        return None, None
    data = read_bytes(path)
    try:
        return data, json.loads(data)
    except ValueError as exc:
        raise MeasureError("%s is not valid JSON: %s" % (rel, exc))


def measure_settings(root):
    data, doc = load_json_file(root, "settings.json")
    if data is None:
        return {"settings.json": {"absent": True}}
    entry = hashed(data)
    entry["agent"] = doc.get("agent") if isinstance(doc, dict) else None
    return {"settings.json": entry}


def event_hooks(doc, event):
    """Each (matcher, hook) registered for an event, in file order."""
    hooks = doc.get("hooks") if isinstance(doc, dict) else None
    groups = hooks.get(event) if isinstance(hooks, dict) else None
    found = []
    for group in groups if isinstance(groups, list) else []:
        if not isinstance(group, dict):
            raise MeasureError("hooks/hooks.json: a %s entry is not an object" % event)
        inner = group.get("hooks")
        for hook in inner if isinstance(inner, list) else []:
            if not isinstance(hook, dict):
                raise MeasureError("hooks/hooks.json: a %s hook is not an object" % event)
            found.append((group.get("matcher"), hook))
    return found


def measure_hooks_json(root):
    data, doc = load_json_file(root, "hooks/hooks.json")
    if data is None:
        return {"hooks/hooks.json": {"absent": True}}
    entry = hashed(data)
    events = doc.get("hooks") if isinstance(doc, dict) else None
    entry["events"] = {name: len(event_hooks(doc, name)) for name in sorted(events)} if isinstance(events, dict) else {}
    return {"hooks/hooks.json": entry}


# ── the sandbox ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def hook_timeout():
    raw = os.environ.get(TIMEOUT_ENV)
    if not raw:
        return DEFAULT_TIMEOUT_S
    try:
        value = float(raw)
    except ValueError:
        raise MeasureError("%s=%r is not a number of seconds" % (TIMEOUT_ENV, raw))
    if value <= 0:
        raise MeasureError("%s=%r must be above zero" % (TIMEOUT_ENV, raw))
    return value


def tool_dirs():
    """The directories a sandboxed command may find tools in: the system ones, and where this interpreter, jq, git, perl and bash live."""
    dirs = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", os.path.dirname(os.path.realpath(sys.executable))]
    for tool in ("bash", "sh", "jq", "git", "perl"):
        found = shutil.which(tool)
        if found:
            dirs.append(os.path.dirname(found))
    unique = []
    for directory in dirs:
        if directory not in unique and os.path.isdir(directory):
            unique.append(directory)
    return unique


def kill_group(proc):
    """SIGKILL the command's whole process group, so nothing it started in the background outlives the measurement."""
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        return


class Sandbox(object):
    """One temp dir with the tripwires and, per command, a throwaway HOME / project / TMPDIR (see THE SANDBOX in the docstring)."""

    def __init__(self, root):
        self.root = os.path.realpath(root)
        self.timeout = hook_timeout()
        self.base = os.path.realpath(tempfile.mkdtemp(prefix="lean-parity."))
        self.stubs = os.path.join(self.base, "stubs")
        self.log = os.path.join(self.base, "denied.log")
        self.runs = 0
        os.mkdir(self.stubs)
        open(self.log, "w").close()
        for tool in DENIED_TOOLS:
            path = os.path.join(self.stubs, tool)
            with open(path, "w") as fh:
                fh.write("#!/bin/sh\nprintf '%%s %%s\\n' '%s' \"$*\" >> '%s'\nexit 97\n" % (tool, self.log))
            os.chmod(path, 0o755)
        self.path = os.pathsep.join([self.stubs] + tool_dirs())

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        shutil.rmtree(self.base, ignore_errors=True)

    def env(self, run_dir):
        home = os.path.join(run_dir, "home")
        env = {
            "PATH": self.path,
            "HOME": home,
            "HEIMDALL_HOME": os.path.join(home, ".heimdall"),
            "CLAUDE_PLUGIN_ROOT": self.root,
            "CLAUDE_PROJECT_DIR": os.path.join(run_dir, "project"),
            "TMPDIR": os.path.join(run_dir, "tmp"),
            "USER": "hmd-parity",
            "LOGNAME": "hmd-parity",
            "LC_ALL": "C",
            "LANG": "C",
            "TERM": "dumb",
            "NO_COLOR": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "NO_PROXY": "",
        }
        for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
            env[name] = DEAD_PROXY
        return env

    def normalize(self, data, run_dir):
        for text, token in ((run_dir, b"<SANDBOX>"), (self.root, b"<ROOT>")):
            data = data.replace(os.fsencode(text), token)
        return data

    def run(self, argv, make_stdin, label):
        """Run argv in a fresh sandbox dir, feeding make_stdin(project_dir) when given; return (exit code, normalized stdout)."""
        self.runs += 1
        run_dir = os.path.join(self.base, "r%03d" % self.runs)
        for sub in ("home/.heimdall", "project", "tmp"):
            os.makedirs(os.path.join(run_dir, sub))
        project = os.path.join(run_dir, "project")
        stdin = make_stdin(project) if make_stdin else b""
        proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                cwd=project, env=self.env(run_dir), start_new_session=True)
        try:
            out, _ = proc.communicate(stdin, timeout=self.timeout)
        except subprocess.TimeoutExpired:
            kill_group(proc)
            try:
                proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
            raise MeasureError("timed out after %gs: %s" % (self.timeout, label))
        finally:
            kill_group(proc)
        with open(self.log) as fh:
            tripped = fh.read().strip()
        if tripped:
            raise MeasureError("%s reached for a denied tool (Keychain, network or GUI):\n%s" % (label, tripped))
        return proc.returncode, self.normalize(out, run_dir)


# ── caveman and hook stdout ─────────────────────────────────────────────────────────────────────────────────────────────────────────
def measure_caveman(sb):
    tool = os.path.join(sb.root, "bin", "heimdall-caveman")
    if not os.access(tool, os.X_OK):
        return {"rules": {"absent": True}, "level": {"absent": True}}
    result = {}
    for name, arg in (("rules", "rules"), ("level", "get")):
        code, out = sb.run([tool, arg], None, "bin/heimdall-caveman " + arg)
        entry = hashed(out)
        entry["exit"] = code
        if name == "level":
            entry["value"] = out.decode("utf-8", "replace").strip()
        result[name] = entry
    return result


def hook_id(command):
    found = HOOK_ID.search(command)
    if found:
        return found.group(1)
    found = HOOK_BIN.search(command)
    if found:
        return "bin:" + found.group(1)
    return "cmd:" + sha256_hex(command.encode("utf-8"))[:10]


def hook_stdin(event, matcher):
    """The fixed JSON a hook of this event is fed: the same session, a missing transcript, source startup (compact for a compact matcher)."""
    def build(project):
        doc = {"session_id": SESSION_ID, "transcript_path": "/nonexistent/%s.jsonl" % SESSION_ID, "cwd": project, "hook_event_name": event}
        if event == "SessionStart":
            doc["source"] = "compact" if matcher == "compact" else "startup"
        else:
            doc["prompt"] = "lean context parity probe"
        return json.dumps(doc, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return build


def measure_hooks(sb):
    _, doc = load_json_file(sb.root, "hooks/hooks.json")
    result = {}
    if doc is None:
        return result
    bash = shutil.which("bash") or "/bin/bash"
    for event in HOOK_EVENTS:
        for index, (matcher, hook) in enumerate(event_hooks(doc, event)):
            command = hook.get("command") if hook.get("type") == "command" else None
            if isinstance(command, str):
                hid = hook_id(command)
                digest = sha256_hex(command.encode("utf-8"))
            else:
                hid = "type:%s" % hook.get("type")
                digest = sha256_hex(json.dumps(hook, sort_keys=True).encode("utf-8"))
            entry = {"id": hid, "matcher": matcher, "command_sha256": digest}
            if not isinstance(command, str):
                entry.update(run=False, skipped="not a command hook")
            elif hid in RUN_HOOKS:
                code, out = sb.run([bash, "-c", command], hook_stdin(event, matcher), "%s hook %s" % (event, hid))
                entry.update(run=True, exit=code, stdout=hashed(out))
            else:
                entry.update(run=False, skipped=NOT_RUN.get(hid, "not vetted for sandbox execution"))
            result["%s/%02d-%s" % (event, index, hid)] = entry
    return result


# ── measure, record, check ──────────────────────────────────────────────────────────────────────────────────────────────────────────
def measure(root, names):
    root = os.path.realpath(root)
    if not os.path.isdir(root):
        raise MeasureError("--root %s is not a directory" % root)
    sections = {}
    if "files" in names:
        sections["files"] = measure_files(root)
    if "settings" in names:
        sections["settings"] = measure_settings(root)
    if "hooks_json" in names:
        sections["hooks_json"] = measure_hooks_json(root)
    if "caveman" in names or "hook_stdout" in names:
        with Sandbox(root) as sb:
            if "caveman" in names:
                sections["caveman"] = measure_caveman(sb)
            if "hook_stdout" in names:
                sections["hook_stdout"] = measure_hooks(sb)
    return sections


def digest_of(sections):
    return sha256_hex(json.dumps(sections, sort_keys=True, separators=(",", ":")).encode("ascii"))


def git(root, *args):
    """Run git against root with none of the caller's GIT_* variables and no global config; return (exit code, stdout)."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")
    try:
        proc = subprocess.run(["git", "-C", root] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise MeasureError("git did not run: %s" % exc)
    return proc.returncode, proc.stdout.decode("utf-8", "replace")


def assert_committed(root):
    code, _ = git(root, "rev-parse", "--verify", "-q", "HEAD")
    if code != 0:
        raise MeasureError("%s is not a git work tree with a commit: a baseline is recorded from a commit" % root)
    code, out = git(root, "status", "--porcelain", "--untracked-files=all", "--", *CLEAN_PATHS)
    if code != 0:
        raise MeasureError("git status failed in %s" % root)
    if out.strip():
        shown = "\n".join(out.strip().splitlines()[:20])
        raise MeasureError("uncommitted changes under %s (a baseline is recorded from a commit):\n%s" % (", ".join(CLEAN_PATHS), shown))


def record_info(root, sections):
    """What a reader wants to know about a record and the tool never compares: provenance and size."""
    trees = {}
    for path in TREE_PATHS:
        code, out = git(root, "rev-parse", "--verify", "-q", "HEAD:" + path)
        trees[path] = out.strip() if code == 0 else None
    files = sections["files"]
    hooks = sections["hook_stdout"]
    return {
        "tool": "bin/lib/lean_context_parity.py",
        "recorded_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "git_trees": trees,
        "summary": {
            "agents": len([p for p in files if re.fullmatch(r"agents/[^/]+[.]md", p)]),
            "commands": len([p for p in files if re.fullmatch(r"commands/[^/]+[.]md", p)]),
            "skill_files": len([p for p in files if p.startswith("skills/")]),
            "bytes": sum(entry.get("bytes", 0) for entry in files.values()),
            "hooks_run": len([h for h in hooks.values() if h["run"]]),
            "hooks_skipped": len([h for h in hooks.values() if not h["run"]]),
        },
    }


def write_atomic(path, text):
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".context-baseline.")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def load_baseline(path):
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        raise MeasureError("cannot read the baseline %s: %s" % (path, exc.strerror or exc))
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        raise MeasureError("the baseline %s is not valid JSON: %s" % (path, exc))
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA or not isinstance(doc.get("sections"), dict):
        raise MeasureError("the baseline %s is not a schema-%d record" % (path, SCHEMA))
    if sorted(doc["sections"]) != sorted(SECTIONS):
        raise MeasureError("the baseline %s holds sections %s, want %s" % (path, sorted(doc["sections"]), sorted(SECTIONS)))
    if doc.get("digest") != digest_of(doc["sections"]):
        raise MeasureError("the baseline %s: its digest does not match its sections (hand-edited or corrupt); re-run record" % path)
    return doc


def short(value):
    if isinstance(value, str):
        return value[:12] + ".." if SHA_HEX.fullmatch(value) else value
    if isinstance(value, dict):
        return "{" + ", ".join("%s %s" % (k, short(v)) for k, v in sorted(value.items())) + "}"
    return json.dumps(value)


def detail(old, new):
    if isinstance(old, dict) and isinstance(new, dict):
        keys = sorted(k for k in set(old) | set(new) if old.get(k) != new.get(k))
        return "; ".join("%s %s -> %s" % (k, short(old.get(k)), short(new.get(k))) for k in keys)
    return "%s -> %s" % (short(old), short(new))


def compare(recorded, measured, names):
    lines = []
    for section in names:
        old, new = recorded[section], measured[section]
        for key in sorted(set(old) | set(new)):
            if key not in new:
                lines.append("missing  %s  %s" % (section, key))
            elif key not in old:
                lines.append("extra  %s  %s" % (section, key))
            elif old[key] != new[key]:
                lines.append("changed  %s  %s  %s" % (section, key, detail(old[key], new[key])))
    return lines


def cmd_measure(root, names):
    doc = {"schema": SCHEMA, "sections": measure(root, names)}
    if tuple(names) == SECTIONS:
        doc["digest"] = digest_of(doc["sections"])
    print(json.dumps(doc, indent=2, sort_keys=True))
    return 0


def cmd_record(root, baseline):
    root = os.path.realpath(root)
    assert_committed(root)
    sections = measure(root, SECTIONS)
    doc = {"schema": SCHEMA, "info": record_info(root, sections), "sections": sections, "digest": digest_of(sections)}
    write_atomic(baseline, json.dumps(doc, indent=2, sort_keys=True) + "\n")
    print("lean-context-parity: recorded %s  digest %s" % (baseline, doc["digest"][:12]))
    return 0


def cmd_check(root, baseline, names):
    recorded = load_baseline(baseline)
    measured = measure(root, names)
    lines = compare(recorded["sections"], measured, names)
    if not lines:
        print("lean-context-parity: PASS  sections %s  digest %s" % (",".join(names), recorded["digest"][:12]))
        return 0
    print("lean-context-parity: FAIL  %d difference(s) from %s" % (len(lines), baseline))
    for line in lines:
        print("  " + line)
    print("An intended change of injected context that is not lean-core work is re-recorded, after review, with:\n"
          "  python3 -I bin/lib/lean_context_parity.py record")
    return 1


def build_parser():
    parser = argparse.ArgumentParser(prog="lean_context_parity.py", description="Record and check the context hmd injects (lean-core INV-L1).")
    sub = parser.add_subparsers(dest="command", metavar="{measure,record,check}")
    sub.required = True
    for name, helptext in (("measure", "print what a tree injects, as JSON"),
                           ("record", "record the baseline from a committed tree"),
                           ("check", "compare a tree with the baseline: 0 equal, 1 differs, 2 untrustworthy")):
        p = sub.add_parser(name, help=helptext)
        p.add_argument("--root", default=DEFAULT_ROOT, help="the plugin root to read (default: this repository)")
        if name != "measure":
            p.add_argument("--baseline", default=None, help="the record (default: ROOT/evals/lean/context-baseline.json)")
        if name != "record":
            p.add_argument("--sections", default=None, help="comma list of: " + ", ".join(SECTIONS))
    return parser


def parse_sections(parser, text):
    if text is None:
        return SECTIONS
    wanted = [item.strip() for item in text.split(",") if item.strip()]
    for item in wanted:
        if item not in SECTIONS:
            parser.error("unknown section '%s' (known: %s)" % (item, ", ".join(SECTIONS)))
    if not wanted:
        parser.error("--sections is empty")
    return tuple(name for name in SECTIONS if name in wanted)


def main(argv):
    parser = build_parser()
    args = parser.parse_args(argv)
    root = os.path.realpath(args.root)
    baseline = getattr(args, "baseline", None) or os.path.join(root, "evals", "lean", "context-baseline.json")
    names = parse_sections(parser, getattr(args, "sections", None))
    try:
        if args.command == "measure":
            return cmd_measure(root, names)
        if args.command == "record":
            return cmd_record(root, baseline)
        return cmd_check(root, baseline, names)
    except MeasureError as exc:
        sys.stderr.write("lean-context-parity: %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
