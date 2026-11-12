#!/usr/bin/env python3
"""skills_cli_read.py -- the read side of `hmd skills`: list, why and lock.

    skills_cli_read.py list [--json]   [--project-dir DIR] [--manifest FILE]
    skills_cli_read.py why ID          [--project-dir DIR] [--manifest FILE]
    skills_cli_read.py lock [--verify] [--project-dir DIR] [--manifest FILE]

(docs/superpowers/plans/2026-11-12-3x-m1-skill-registry.md, T4.1. The `hmd skills` dispatcher that routes here is T6.3.)

FOUR SOURCES. The manifest (skills.manifest.json, checked by skills_manifest.py) says what hmd knows about and why. The two
locks (bin/lib/skills_lock.py: <project>/.planning/skills.lock and $HEIMDALL_HOME/skills.lock) say what was installed or
suggested and why; `why` and `list` merge both. The machine says what is installed: `claude plugins list --json` for
plugins, the directories of ~/.claude/skills for skills (a git checkout is read at its commit). The install receipts
($HEIMDALL_HOME/receipts/installs-*.ndjson, HMD_RECEIPTS_DIR overrides) say how each install went. Only `lock` writes, only
to the locks, and only through skills_lock.py's own `record`: the append-only rules and the file format stay in one place.
The one thing run besides that CLI is `git rev-parse HEAD` in a skill checkout. Nothing here installs anything.

list. One row per manifest entry: tier, whether it is installed here, the source and pin the manifest declares, and what the
locks say (consent, state, scope), under a line giving the registry and consent modes (skills_config.py: environment, then
$HEIMDALL_HOME/skills-config.json, then the default). installed is yes/no, `?` when `claude plugins list --json` could not
answer (said once on stderr), `n/a` for a bundled entry (it ships in-tree). --json has the same rows, with null for the last
two.

why ID. The lock row's why (rule, evidence, via, run), the manifest entry's `why` and legacy[] pointers (which mechanism
each mapping came from), and the receipt lines. ID is a manifest or lock id, or a plugin's full name@marketplace. Exit 0
when a lock row explains it, or it is a manifest entry that is not installed; 1 when it is installed here and no lock row
says why (the goal metric is 100% explained; `lock` closes the gap); 4 when nothing knows the id.

lock [--verify]. Rebuilds the lock from what is installed. An install no row of either lock explains is adopted into the
MACHINE lock: state adopted, consent auto-legacy, why.rule adopted, why.via from its newest ok receipt (else hmd-skills-lock),
version and source from the CLI, the marketplace table, the receipt or the checkout's commit (content_hash). A row that says
installed or adopted but whose plugin version or skill commit has moved is refreshed (version, content_hash; the state and
the why stay). The project lock is never created here: it says what THIS project triggered, and the project does not need
every plugin on the machine. --verify prints exactly what a rebuild would change (`unlocked`, `drift`), exits 1 when
there is any, and writes nothing. A row whose plugin or skill is gone is left alone: the lock is append-only.

EXIT. 0 ok; 1 why: installed and unexplained, lock --verify: unlocked installs or drift; 2 bad usage; 3 the manifest or a
lock is unreadable or invalid, or a lock write failed (one line on stderr; nothing is overwritten); 4 why: unknown id.
Never a traceback: the callers are launchers and read the exit code. Text read from a lock, receipt or manifest is shown
with control and format characters replaced by `?`, so a hostile file cannot write to the operator's terminal.

Python API: main(argv) with argv the arguments after the program name. stdlib only.
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I keeps the script's directory off sys.path
import skills_config  # noqa: E402
import skills_lock  # noqa: E402
import skills_manifest  # noqa: E402

SCOPES = ("project", "machine")
ADOPTED = "adopted"
ADOPT_CONSENT = "auto-legacy"
ADOPT_RULE = "adopted"
ADOPT_VIA = "hmd-skills-lock"
EXIT_UNEXPLAINED = 1
EXIT_UNREADABLE = 3
EXIT_UNKNOWN = 4
CLAUDE_TIMEOUT_SECONDS = 20
GIT_TIMEOUT_SECONDS = 5
RECEIPT_FILES_MAX = 500
RECEIPT_BYTES_MAX = 1 << 20
RECEIPT_LINES_SHOWN = 10
NO_VALUE = (None, "", "unknown")


class Unreadable(Exception):
    """A source the answer needs (the manifest or a lock) cannot be read or is invalid (exit 3)."""


def clean(value):
    """The text on one printable line: control and format characters (a terminal escape, a bidi override) become '?'."""
    return "".join("?" if unicodedata.category(ch)[0] == "C" or ch in "  " else ch for ch in str(value))


def warn(message):
    sys.stderr.write("skills: %s\n" % clean(message))


def say(text):
    sys.stdout.write(clean(text) + "\n")


def text_field(record, key):
    value = record.get(key)
    return value if isinstance(value, str) else ""


def known(value):
    return value not in NO_VALUE


def differs(have, want):
    """True when both sides give a value (a version) and the two are not the same."""
    return known(have) and known(want) and have != want


def other_commit(have, want):
    """True when two commit ids, either of which may be abbreviated, name different commits."""
    return known(have) and known(want) and not (have.startswith(want) or want.startswith(have))


# ---- the manifest and the locks ----------------------------------------------------------------------------------

def load_manifest(path):
    try:
        doc = skills_manifest.load(path)
    except skills_manifest.ManifestError as exc:
        raise Unreadable(str(exc))
    reasons = skills_manifest.validate(doc)
    if reasons:
        raise Unreadable("%s is not a valid skills.manifest/%d: %s" % (path, skills_manifest.SCHEMA_VERSION, "; ".join(reasons[:3])))
    return doc


def load_locks(project_dir):
    """{scope: rows} of both locks (an absent lock has no rows). A lock that is unreadable or invalid is Unreadable."""
    locks = {}
    for scope in SCOPES:
        try:
            locks[scope] = skills_lock.load(skills_lock.lock_path(scope, project_dir))["entries"]
        except skills_lock.LockError as exc:
            raise Unreadable(str(exc))
    return locks


def rows_of(locks, ident, ref=None):
    """[(scope, row)]: the rows of both locks for `ident`, or for the plugin named `ref`."""
    return [(scope, row) for scope in SCOPES for row in locks[scope] if row["id"] == ident or (ref and row["ref"] == ref)]


def best(found):
    """The (scope, row) to show for one id: the first that says it is on the machine, else the first, else (None, None)."""
    return next((item for item in found if item[1]["state"] in skills_lock.PRESENT), found[0] if found else (None, None))


def entry_ref(entry):
    return entry.get("ref") or entry.get("repo") or entry["id"]


def declared(entry, markets):
    """(source, pin) the manifest declares for an entry: its marketplace's for a plugin, github.com/<repo> for a skill."""
    if entry["kind"] == "plugin":
        market = markets.get(entry["marketplace"], {})
        return market.get("source") or entry["marketplace"], market.get("pin") or "none"
    if entry["kind"] == "github-skill":
        return "github.com/" + entry["repo"], "none"
    return "bundled", "none"


def canonical_id(ident, manifest, locks):
    """`ident` as the id the manifest and the locks use: a plugin may also be asked for by its full name@marketplace."""
    for entry in manifest["entries"]:
        if ident in (entry["id"], entry.get("ref")):
            return entry["id"]
    for scope in SCOPES:
        for row in locks[scope]:
            if ident in (row["id"], row["ref"]):
                return row["id"]
    return ident


# ---- the machine -------------------------------------------------------------------------------------------------

def read_plugins():
    """{id: version} from `claude plugins list --json` (ids are name@marketplace); None when the CLI cannot answer."""
    try:
        done = subprocess.run(["claude", "plugins", "list", "--json"], capture_output=True, text=True, errors="replace",
                              timeout=CLAUDE_TIMEOUT_SECONDS, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError) as exc:
        return plugins_unavailable("failed (%s)" % type(exc).__name__)
    if done.returncode != 0:
        return plugins_unavailable("exited %d" % done.returncode)
    try:
        data = json.loads(done.stdout)
    except (ValueError, RecursionError):
        return plugins_unavailable("printed something that is not JSON")
    if not isinstance(data, list):
        return plugins_unavailable("printed something that is not a list of plugins")
    plugins = {}
    for item in data:
        if isinstance(item, dict) and isinstance(item.get("id"), str):
            plugins.setdefault(item["id"], text_field(item, "version") or "unknown")
    return plugins


def plugins_unavailable(reason):
    warn("claude plugins list --json %s: plugin installs are not checked" % reason)
    return None


def read_skills():
    """{name: directory} of ~/.claude/skills: a directory (or a link to one) whose name is an id a lock can hold."""
    root = os.path.join(os.path.expanduser("~"), ".claude", "skills")
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return {}
    return {name: os.path.join(root, name) for name in names
            if skills_lock.ID_RE.fullmatch(name) and os.path.isdir(os.path.join(root, name))}


def git_commit(path):
    """The commit a skill checkout is at, or None: not a checkout of its own (a parent repository's HEAD is not its
    commit), or git cannot say."""
    if not os.path.lexists(os.path.join(path, ".git")):
        return None
    try:
        done = subprocess.run(["git", "-C", path, "rev-parse", "HEAD"], capture_output=True, text=True, errors="replace",
                              timeout=GIT_TIMEOUT_SECONDS, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return None
    commit = done.stdout.strip().lower()
    return commit if done.returncode == 0 and skills_lock.HASH_RE.fullmatch(commit) else None


class Machine:
    """What is installed here: plugins {id: version} (None when the CLI could not say) and skill directories {name: path}."""

    def __init__(self):
        self.plugins = read_plugins()
        self.skills = read_skills()
        self.commits = {}

    def plugin(self, ident, ref=None):
        """The installed plugin id that `ref` or `ident` names (a bare name must be unambiguous), else None."""
        installed = self.plugins or {}
        for key in (ref, ident):
            if key in installed:
                return key
        named = [pid for pid in installed if pid.split("@", 1)[0] == ident]
        return named[0] if len(named) == 1 else None

    def commit(self, name):
        if name not in self.commits:
            self.commits[name] = git_commit(self.skills[name])
        return self.commits[name]


def present(machine, kind, ident, ref=None):
    """Is it installed here? True/False; None when that cannot be told (the plugin CLI did not answer) or does not apply
    (a bundled entry ships in-tree). A kind of None asks about a plugin and a skill both."""
    if kind == "bundled":
        return None
    if kind in (None, "plugin") and machine.plugin(ident, ref):
        return True
    if kind in (None, "github-skill") and ident in machine.skills:
        return True
    if kind == "plugin" and machine.plugins is None:
        return None
    return False


def read_receipts():
    """[(file name, record)] of every parsable line of the install receipts, oldest first. Other lines are skipped."""
    home = os.environ.get("HEIMDALL_HOME") or os.path.join(os.path.expanduser("~"), ".heimdall")
    directory = os.environ.get("HMD_RECEIPTS_DIR") or os.path.join(home, "receipts")
    records = []
    for path in sorted(glob.glob(os.path.join(glob.escape(directory), "installs-*.ndjson")))[-RECEIPT_FILES_MAX:]:
        try:
            with open(path, "rb") as handle:
                text = handle.read(RECEIPT_BYTES_MAX).decode("utf-8", "replace")
        except OSError:
            continue
        for line in text.splitlines():
            try:
                record = json.loads(line)
            except (ValueError, RecursionError):
                continue
            if isinstance(record, dict) and isinstance(record.get("name"), str):
                records.append((os.path.basename(path), record))
    records.sort(key=lambda item: (text_field(item[1], "ts"), item[0]))
    return records


def latest_ok(receipts, names):
    """The newest receipt line of an install that worked, for any of `names`; None when there is none."""
    found = [record for _, record in receipts if record.get("result") == "ok" and record["name"] in names]
    return found[-1] if found else None


# ---- list --------------------------------------------------------------------------------------------------------

def list_entries(manifest, locks, machine):
    markets = manifest["marketplaces"]
    entries = []
    for entry in manifest["entries"]:
        ref = entry_ref(entry)
        scope, row = best(rows_of(locks, entry["id"], ref if entry["kind"] == "plugin" else None))
        source, pin = declared(entry, markets)
        entries.append({
            "id": entry["id"], "kind": entry["kind"], "tier": entry["tier"], "ref": ref, "source": source, "pin": pin,
            "installed": present(machine, entry["kind"], entry["id"], ref),
            "consent": row["consent"] if row else None, "lock_state": row["state"] if row else None, "lock_scope": scope})
    return entries


def render_table(entries):
    header = ("ID", "KIND", "TIER", "INSTALLED", "SOURCE", "PIN", "CONSENT", "LOCK")
    rows = [header]
    for item in entries:
        installed = "n/a" if item["kind"] == "bundled" else {True: "yes", False: "no"}.get(item["installed"], "?")
        lock = "%s(%s)" % (item["lock_state"], item["lock_scope"]) if item["lock_state"] else "-"
        rows.append((item["id"], item["kind"], item["tier"], installed, item["source"], item["pin"], item["consent"] or "-", lock))
    rows = [tuple(clean(cell) for cell in row) for row in rows]
    widths = [max(len(row[i]) for row in rows) for i in range(len(header))]
    return "\n".join("  ".join(cell.ljust(width) for cell, width in zip(row, widths)).rstrip() for row in rows) + "\n"


def cmd_list(args):
    manifest = load_manifest(args.manifest)
    locks = load_locks(args.project_dir)
    entries = list_entries(manifest, locks, Machine())
    registry, consent = skills_config.resolve("registry"), skills_config.resolve("consent")
    if args.json:
        sys.stdout.write(json.dumps({"registry": registry, "consent": consent, "entries": entries}, indent=2) + "\n")
    else:
        sys.stdout.write("registry: %s  consent: %s\n%s" % (registry, consent, render_table(entries)))
    return 0


# ---- why ---------------------------------------------------------------------------------------------------------

def cmd_why(args):
    manifest = load_manifest(args.manifest)
    locks = load_locks(args.project_dir)
    ident = canonical_id(args.id, manifest, locks)
    entry = next((item for item in manifest["entries"] if item["id"] == ident), None)
    ref = entry_ref(entry) if entry and entry["kind"] == "plugin" else None
    found = rows_of(locks, ident, ref)
    kind = entry["kind"] if entry else found[0][1]["kind"] if found else None
    ref = ref or (found[0][1]["ref"] if found else None)
    installed = None if found or kind == "bundled" else present(Machine(), kind, ident, ref)
    if not (found or entry or installed):
        warn("%s is not in the manifest, in either lock or installed here" % ident)
        return EXIT_UNKNOWN
    if entry:
        say("%s: %s %s, tier %s" % (ident, entry["kind"], entry_ref(entry), entry["tier"]))
    elif found:
        say("%s: %s %s (not in the manifest)" % (ident, kind, ref))
    else:
        say("%s: installed here (not in the manifest)" % ident)
    for scope, row in found:
        say("lock[%s]: state=%s consent=%s version=%s source=%s pin=%s at=%s"
            % (scope, row["state"], row["consent"], row["version"], row["source"], row["pin"], row["at"]))
        why = row["why"]
        say("  why: entry=%s rule=%s evidence=%s via=%s run=%s" % (why["entry"], why["rule"], why["evidence"] or "-", why["via"], why["run"]))
    if not found:
        say("lock: no lock row (%s)" % ("installed here" if installed else "not installed here"))
    if entry:
        say("manifest: %s" % entry["why"])
        for item in entry["legacy"]:
            say("  legacy: %s (%s)" % (item["mechanism"], item["path"]))
    elif ident in manifest["marketplaces"]:
        market = manifest["marketplaces"][ident]
        say("manifest: marketplace %s source=%s pin=%s" % (ident, market["source"], market.get("pin") or "none"))
    else:
        say("manifest: no entry")
    names = {ident, ref} | {row["ref"] for _, row in found}
    shown = [item for item in read_receipts() if item[1]["name"] in names]
    if len(shown) > RECEIPT_LINES_SHOWN:
        say("  ... %d older receipt lines not shown" % (len(shown) - RECEIPT_LINES_SHOWN))
    for filename, record in shown[-RECEIPT_LINES_SHOWN:]:
        say("receipt: %s %s %s %s %s via=%s version=%s" % (
            filename, text_field(record, "ts"), text_field(record, "kind"), text_field(record, "name"),
            text_field(record, "result"), text_field(record, "via"), text_field(record, "version")))
    if installed:
        warn("%s is installed here but no lock row says why: run `hmd skills lock` to adopt it" % ident)
        return EXIT_UNEXPLAINED
    return 0


# ---- lock --------------------------------------------------------------------------------------------------------

def machine_things(manifest, machine, receipts):
    """Everything installed here that a lock row can describe, as the fields `record` takes: plugins, then skills."""
    entries = {item["id"]: item for item in manifest["entries"] if item["kind"] == "plugin"}
    entries.update({item["ref"]: item for item in manifest["entries"] if item["kind"] == "plugin"})
    skill_entries = {item["id"]: item for item in manifest["entries"] if item["kind"] == "github-skill"}
    plugins = machine.plugins or {}
    names = [pid.split("@", 1)[0] for pid in plugins] + list(machine.skills)
    things = []
    for pid, version in sorted(plugins.items()):
        name, _, market = pid.partition("@")
        entry = entries.get(pid)
        market_row = manifest["marketplaces"].get(market, {})
        things.append({"id": entry["id"] if entry else name if names.count(name) == 1 else pid, "kind": "plugin", "ref": pid,
                       "version": version, "source": market_row.get("source") or market or "unknown",
                       "pin": market_row.get("pin") or "none", "commit": None})
    for name in machine.skills:
        repo = skill_entries[name]["repo"] if name in skill_entries else None
        commit = machine.commit(name)
        things.append({"id": name, "kind": "github-skill", "ref": repo or name, "version": commit[:12] if commit else "unknown",
                       "source": "github.com/" + repo if repo else "unknown", "pin": "none", "commit": commit})
    usable = []
    for thing in things:
        if not skills_lock.ID_RE.fullmatch(thing["id"]):
            warn("%s cannot be recorded: %r is not an id a lock can hold" % (thing["ref"], thing["id"]))
            continue
        receipt = latest_ok(receipts, (thing["id"], thing["ref"]))
        thing["via"] = (text_field(receipt, "via") or ADOPT_VIA) if receipt else ADOPT_VIA
        for key in ("version", "source"):
            if receipt and thing[key] == "unknown":
                thing[key] = text_field(receipt, key) or "unknown"
        usable.append(thing)
    return usable


def find_drift(locks, machine):
    """[(scope, row, field, lock value, installed value, patch)]: rows that say a plugin or skill is here whose version
    or commit has moved."""
    found = []
    for scope in SCOPES:
        for row in locks[scope]:
            if row["state"] not in skills_lock.PRESENT:
                continue
            if row["kind"] == "plugin":
                pid = machine.plugin(row["id"], row["ref"])
                if pid and differs(row["version"], machine.plugins[pid]):
                    found.append((scope, row, "version", row["version"], machine.plugins[pid], {"version": machine.plugins[pid]}))
            elif row["kind"] == "github-skill" and row["id"] in machine.skills:
                commit = machine.commit(row["id"])
                held = row["content_hash"] or (row["version"] if skills_lock.HASH_RE.fullmatch(row["version"]) else None)
                if other_commit(held, commit):
                    found.append((scope, row, "commit", held, commit, {"version": commit[:12], "content_hash": commit}))
    return found


def record(argv):
    """One `skills_lock.py record`, in this process: its exit status (it says why on stderr when that is not 0)."""
    try:
        return skills_lock.main(["record"] + argv)
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else EXIT_UNREADABLE


def adoption_argv(thing, manifest_path):
    argv = ["--scope=machine", "--id=" + thing["id"], "--state=" + ADOPTED, "--kind=" + thing["kind"],
            "--consent=" + ADOPT_CONSENT, "--ref=" + thing["ref"], "--version=" + thing["version"],
            "--source=" + thing["source"], "--pin=" + thing["pin"], "--rule=" + ADOPT_RULE, "--via=" + thing["via"],
            "--manifest=" + manifest_path]
    if thing["commit"]:
        argv.append("--content-hash=" + thing["commit"])
    return argv


def refresh_argv(scope, row, patch, args):
    argv = ["--scope=" + scope, "--project-dir=" + args.project_dir, "--id=" + row["id"], "--state=" + row["state"],
            "--manifest=" + args.manifest]
    return argv + ["--%s=%s" % (key.replace("_", "-"), value) for key, value in patch.items()]


def cmd_lock(args):
    manifest = load_manifest(args.manifest)
    locks = load_locks(args.project_dir)
    machine = Machine()
    adopt = [thing for thing in machine_things(manifest, machine, read_receipts()) if not rows_of(locks, thing["id"], thing["ref"])]
    drift = find_drift(locks, machine)
    checked = sum(1 for scope in SCOPES for row in locks[scope] if row["state"] in skills_lock.PRESENT)
    if args.verify:
        for thing in adopt:
            say("unlocked %s: installed (%s %s), no lock row; `hmd skills lock` adopts it" % (thing["id"], thing["kind"], thing["ref"]))
        for scope, row, field, held, seen, _ in drift:
            say("drift %s [%s]: %s %s in the lock, %s installed" % (row["id"], scope, field, held, seen))
        problems = len(adopt) + len(drift)
        say("verify: %s" % ("%d problem%s" % (problems, "" if problems == 1 else "s") if problems
                            else "ok (%d locked installs match what is installed)" % checked))
        return EXIT_UNEXPLAINED if problems else 0
    failed = 0
    for thing in adopt:
        if record(adoption_argv(thing, args.manifest)) == 0:
            say("adopted %s (%s %s %s)" % (thing["id"], thing["kind"], thing["ref"], thing["version"]))
        else:
            failed += 1
    for scope, row, field, held, seen, patch in drift:
        if record(refresh_argv(scope, row, patch, args)) == 0:
            say("refreshed %s [%s]: %s %s -> %s" % (row["id"], scope, field, held, seen))
        else:
            failed += 1
    if failed:
        warn("%d lock write%s failed" % (failed, "" if failed == 1 else "s"))
        return EXIT_UNREADABLE
    if adopt or drift:
        say("lock: %d adopted, %d refreshed" % (len(adopt), len(drift)))
    else:
        say("lock: nothing to do (%d locked installs match what is installed)" % checked)
    return 0


# ---- the command line --------------------------------------------------------------------------------------------

def _id_arg(value):
    if skills_lock.ID_RE.fullmatch(value) is None:
        raise argparse.ArgumentTypeError(
            "%r is not an id (letters, digits and . _ @ / + : -, at most 128, starting with a letter or digit)" % value)
    return value


def build_parser():
    parser = argparse.ArgumentParser(
        prog="skills_cli_read.py", allow_abbrev=False,
        description="The read side of `hmd skills`: what is known, what is installed, and why.",
        epilog="exit status: 0 ok, 1 why: installed and unexplained / lock --verify: drift or unlocked installs, 2 bad usage, "
               "3 manifest or lock unreadable or invalid, 4 why: unknown id")
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--project-dir", metavar="DIR", help="the project whose .planning/skills.lock is read (default: the working directory)")
    common.add_argument("--manifest", metavar="FILE", default=skills_lock.DEFAULT_MANIFEST,
                        help="the skills.manifest.json to read (default <lib>/../../skills.manifest.json)")
    commands = parser.add_subparsers(dest="command", required=True, metavar="{list,why,lock}")
    listing = commands.add_parser("list", parents=[common], allow_abbrev=False, help="manifest entries by tier, install and lock state",
                                  description="Every manifest entry: tier, installed here?, source, pin, consent, lock state.")
    listing.add_argument("--json", action="store_true", help="the same rows as JSON")
    why = commands.add_parser("why", parents=[common], allow_abbrev=False, help="why an id is on this machine",
                              description="The lock row's why, the manifest's legacy[] pointers and the receipt lines for one id.")
    why.add_argument("id", type=_id_arg, help="a manifest or lock id, or a plugin's full name@marketplace")
    lock = commands.add_parser("lock", parents=[common], allow_abbrev=False, help="adopt what is installed; --verify reports drift",
                               description="Rebuild the lock from what is installed: adopt the unexplained, refresh the drifted.")
    lock.add_argument("--verify", action="store_true", help="report what a rebuild would change, write nothing, exit 1 if anything")
    return parser


COMMANDS = {"list": cmd_list, "why": cmd_why, "lock": cmd_lock}


def main(argv):
    args = build_parser().parse_args(argv)
    try:
        args.project_dir = os.path.abspath(args.project_dir or os.getcwd())
        return COMMANDS[args.command](args)
    except Unreadable as exc:
        warn(str(exc))
        return EXIT_UNREADABLE
    except Exception as exc:  # reported with a non-zero status, never swallowed, never a traceback
        warn("%s failed: %s: %s" % (args.command, type(exc).__name__, exc))
        return EXIT_UNREADABLE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
