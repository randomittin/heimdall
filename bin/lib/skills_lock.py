#!/usr/bin/env python3
"""skills_lock.py -- the skills lockfile: what hmd installed or suggested, and WHY.

    skills_lock.py record --scope project|machine --id ID --state STATE [--kind KIND] [options]
    skills_lock.py read   --scope project|machine [--id ID]
    skills_lock.py verify --scope project|machine

THE FILES. One format (schema 1, docs/schemas/skills.lock.v1.json), two scopes. The project lock,
<project dir>/.planning/skills.lock (--project-dir, default the working directory), says "this project
triggered / needs it" and is meant to be committed. The machine lock, $HEIMDALL_HOME/skills.lock (default
~/.heimdall), holds the first-run rows (superpowers, the marketplace) and is written 0600. The install
receipt (bin/lib/install-receipt.sh) stays the per-run attempt log; the lock is the durable "what and why".

A ROW is {id, kind, ref, state, version, source, pin, content_hash, consent, at, why} with why = {entry,
rule, evidence, via, run}. One row per id per file, rows sorted by id, one row per line, a fixed key order:
the same records always give the same bytes, so a committed lock diffs and merges cleanly.

APPEND-ONLY, WITH STATE TRANSITIONS. A row is never removed. `record` for an id that has a row is a
transition: the fields given replace the row's, the ones omitted stay (so `--state installed` alone keeps
the rule and evidence that triggered the suggestion). suggested, declined and failed move freely among
themselves and into installed or adopted; installed never goes back (a failed retry or a late suggestion
cannot un-install it), and adopted can only become installed. A refused transition exits 3 and changes
nothing. A record that would change nothing writes nothing, so a committed lock does not churn on `at` or
`run` every session: they say when, and in which run, the row LAST changed.

EVIDENCE (INV-S10). why.evidence is the matched token or file path ONLY, at most 64 characters, with
control and format characters removed. The file is git-committed, so prompt text must never reach it, and
the API has no prompt field: `record` takes `--evidence` and nothing else. A longer string is cut, not
rejected. The other free-text fields are printable ASCII, cut to a cap, anything else becoming `?` (the
install receipt's own rule, so a receipt line and its lock row never disagree).

LOCKING. Every read-modify-write holds an exclusive flock(2) on the directory that holds the file: unlike
the file, the directory is never replaced by the rename below, and it leaves no stray lock file in a
committed .planning/. A writer waits HMD_SKILLS_LOCK_WAIT_S seconds (default 10, at most 60) and then gives
up (exit 1) rather than write without the lock; a file system without flock writes unlocked (the rename is
still atomic). Readers take no lock: the file is replaced by a rename of a flushed temp file, so they see
the old one or the new one, never half of either.

UNTRUSTED INPUT. A cloned repo supplies the project lock, so it is read like any untrusted file: a regular
file only (a link is refused), at most 1 MiB, strict JSON (a duplicate key or NaN is refused), every field
checked against the schema. A lock that fails any of it is reported and never overwritten.

EXIT STATUS. 0 ok; 1 the lock is unreadable, invalid, locked or unwritable (one line on stderr); 2 bad
usage; 3 a refused transition; 4 `read --id` found no row. Never a traceback: the callers are fail-open
launchers and read the exit code only.

Python API (what bin/lib/skills_cli_*.py import): lock_path(scope, project_dir=None) -> str,
load(path) -> dict (LockError when unreadable or invalid), dump(doc) -> str, problems(doc) -> list[str].
Environment: HEIMDALL_HOME, HMD_RUN_ID (the default for --run), HMD_SKILLS_LOCK_WAIT_S. stdlib only.
"""
import argparse
import contextlib
import errno
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import time
import unicodedata

try:
    import fcntl
except ImportError:  # no flock on this platform: writers run unlocked (the rename is still atomic)
    fcntl = None

SCHEMA = 1
MAX_BYTES = 1 << 20
LOCK_WAIT_SECONDS = 10.0
EVIDENCE_MAX = 64
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
DEFAULT_MANIFEST = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "skills.manifest.json"))

STATES = ("installed", "suggested", "declined", "failed", "adopted")
PRESENT = ("installed", "adopted")  # on the machine; the other three states are not
KINDS = ("plugin", "github-skill", "marketplace", "bundled")
CONSENTS = ("auto-legacy", "prompt", "allowlist", "yes-flag", "explicit", "n/a")

TOP_FIELDS = ("schema", "manifest_sha256", "entries")
ROW_FIELDS = ("id", "kind", "ref", "state", "version", "source", "pin", "content_hash", "consent", "at", "why")
WHY_FIELDS = ("entry", "rule", "evidence", "via", "run")
CAPS = {"ref": 200, "version": 64, "source": 200, "pin": 64, "rule": 64, "via": 64, "run": 64}
PATCH_ROW = tuple(key for key in ROW_FIELDS if key not in ("id", "at", "why"))
PATCH_WHY = tuple(key for key in WHY_FIELDS if key != "run")

# Used with fullmatch, never match: `$` would let a trailing newline through. The schema file spells each as ^...$.
ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._@/+:-]{0,127}")
HASH_RE = re.compile(r"[0-9a-f]{7,64}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
AT_RE = re.compile(r"[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z")
TEXT_RE = re.compile(r"[ -~]+")


class LockError(Exception):
    """The lock cannot be read, written or locked, or is invalid (exit 1)."""


class Refused(Exception):
    """The record would break the append-only rules (exit 3)."""


class Usage(Exception):
    """An argument problem that only shows once the lock is read (exit 2)."""


def warn(message):
    sys.stderr.write("skills-lock: %s\n" % message)


def ascii_text(value, cap):
    """Printable ASCII only (anything else becomes '?'), trimmed, cut to `cap` characters."""
    return re.sub(r"[^ -~]", "?", value).strip()[:cap].rstrip()


def clean_evidence(text):
    """The matched token or path: control, format, separator and surrogate characters removed, cut to EVIDENCE_MAX."""
    kept = "".join(ch for ch in text if unicodedata.category(ch)[0] != "C" and ch not in "  ")
    return kept.strip()[:EVIDENCE_MAX].rstrip()


def empty_doc():
    return {"schema": SCHEMA, "manifest_sha256": None, "entries": []}


# ---- validation: the rules of docs/schemas/skills.lock.v1.json, in code ------------------------------------------

def _match(regex):
    return lambda value: isinstance(value, str) and regex.fullmatch(value) is not None


def _in(options):
    return lambda value: isinstance(value, str) and value in options


def _or_null(check):
    return lambda value: value is None or check(value)


def _real_time(value):
    if not (isinstance(value, str) and AT_RE.fullmatch(value)):
        return False
    try:
        time.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:  # the pattern allows 30 February; the calendar does not
        return False
    return True


def _evidence_ok(value):
    return isinstance(value, str) and value != "" and clean_evidence(value) == value


def _text(cap):
    return lambda value: isinstance(value, str) and len(value) <= cap and TEXT_RE.fullmatch(value) is not None


def _text_rule(key):
    return (key, "must be 1-%d printable ASCII characters" % CAPS[key], _text(CAPS[key]))


ROW_RULES = (
    ("id", "must match %s" % ID_RE.pattern, _match(ID_RE)),
    ("kind", "must be one of %s" % "|".join(KINDS), _in(KINDS)),
    _text_rule("ref"),
    ("state", "must be one of %s" % "|".join(STATES), _in(STATES)),
    _text_rule("version"),
    _text_rule("source"),
    _text_rule("pin"),
    ("content_hash", "must be null or 7-64 lowercase hex digits", _or_null(_match(HASH_RE))),
    ("consent", "must be one of %s" % "|".join(CONSENTS), _in(CONSENTS)),
    ("at", "must be a real UTC time, YYYY-MM-DDTHH:MM:SSZ", _real_time),
)
WHY_RULES = (
    ("entry", "must match %s" % ID_RE.pattern, _match(ID_RE)),
    _text_rule("rule"),
    ("evidence", "must be null or 1-%d characters with no control characters" % EVIDENCE_MAX, _or_null(_evidence_ok)),
    _text_rule("via"),
    _text_rule("run"),
)
TOP_RULES = (
    ("schema", "must be %d" % SCHEMA, lambda value: type(value) is int and value == SCHEMA),
    ("manifest_sha256", "must be null or 64 lowercase hex digits", _or_null(_match(SHA256_RE))),
    ("entries", "must be an array", lambda value: isinstance(value, list)),
)


def _object_problems(obj, fields, label, rules):
    """Reasons `obj` is not an object with exactly `fields`, each obeying its rule."""
    if not isinstance(obj, dict):
        return ["%s: not an object" % label]
    found = ["%s: missing key %s" % (label, key) for key in fields if key not in obj]
    found += ["%s: unexpected key %s" % (label, key) for key in obj if key not in fields]
    found += ["%s.%s: %s" % (label, key, rule) for key, rule, check in rules if key in obj and not check(obj[key])]
    return found


def problems(doc):
    """Every reason `doc` is not a valid skills.lock/1; an empty list when it is one."""
    found = _object_problems(doc, TOP_FIELDS, "top level", TOP_RULES)
    if not isinstance(doc, dict) or not isinstance(doc.get("entries"), list):
        return found
    seen = set()
    for index, row in enumerate(doc["entries"]):
        label = "entries[%d]" % index
        found += _object_problems(row, ROW_FIELDS, label, ROW_RULES)
        if not isinstance(row, dict):
            continue
        if "why" in row:
            found += _object_problems(row["why"], WHY_FIELDS, label + ".why", WHY_RULES)
        if isinstance(row.get("id"), str):
            if row["id"] in seen:
                found.append("%s: duplicate id %s" % (label, row["id"]))
            seen.add(row["id"])
    return found


# ---- reading and writing the file --------------------------------------------------------------------------------

def read_text(path):
    """The bytes of the lock at `path`, or None when there is no file. A link, a non-regular file or a big one is refused."""
    try:
        fd = os.open(path, os.O_RDONLY | NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            raise LockError("%s is a symbolic link: a lock is never read or replaced through a link" % path)
        raise LockError("cannot open %s: %s" % (path, exc.strerror))
    with os.fdopen(fd, "rb") as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            raise LockError("%s is not a regular file" % path)
        raw = handle.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise LockError("%s is larger than %d bytes" % (path, MAX_BYTES))
    return raw


def _no_duplicates(pairs):
    found = {}
    for key, value in pairs:
        if key in found:
            raise ValueError("duplicate key %r" % key)
        found[key] = value
    return found


def _no_constants(name):
    raise ValueError("%s is not allowed" % name)


def parse(path):
    """(document, reasons): what is at `path` (an empty lock when there is no file) and everything wrong with it."""
    raw = read_text(path)
    if raw is None:
        return empty_doc(), []
    try:
        doc = json.loads(raw.decode("utf-8"), object_pairs_hook=_no_duplicates, parse_constant=_no_constants)
    except (ValueError, RecursionError) as exc:
        return None, ["not valid JSON: %s" % exc]
    return doc, problems(doc)


def load(path):
    """The lock at `path` (an empty one when there is no file). LockError when it is unreadable or invalid."""
    doc, reasons = parse(path)
    if reasons:
        raise LockError("%s is not a valid skills.lock/1: %s" % (path, "; ".join(reasons[:5])))
    return doc


def canonical(row):
    """The row with its keys in the fixed order."""
    ordered = {key: row[key] for key in ROW_FIELDS}
    ordered["why"] = {key: row["why"][key] for key in WHY_FIELDS}
    return ordered


def dump(doc):
    """The canonical text of a lock: fixed key order, rows sorted by id, one row per line, ASCII only."""
    rows = sorted(doc["entries"], key=lambda row: row["id"])
    lines = ["    " + json.dumps(canonical(row)) for row in rows]
    entries = "[\n" + ",\n".join(lines) + "\n  ]" if lines else "[]"
    return '{\n  "schema": %d,\n  "manifest_sha256": %s,\n  "entries": %s\n}\n' % (
        SCHEMA, json.dumps(doc["manifest_sha256"]), entries)


def write(path, doc, mode):
    """Atomically: a temp file in the same directory, flushed to disk, then renamed over the lock."""
    data = dump(doc).encode("ascii")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".skills.lock.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def lock_wait():
    """Seconds a writer waits for the lock: HMD_SKILLS_LOCK_WAIT_S when it is a number from 0 to 60, else the default."""
    try:
        wait = float(os.environ.get("HMD_SKILLS_LOCK_WAIT_S", ""))
    except ValueError:
        return LOCK_WAIT_SECONDS
    return wait if 0 <= wait <= 60 else LOCK_WAIT_SECONDS


@contextlib.contextmanager
def locked(directory):
    """Exclusive advisory lock on the directory that holds the lock file (see LOCKING)."""
    try:
        fd = os.open(directory, os.O_RDONLY)
    except OSError as exc:
        raise LockError("cannot open %s to lock it: %s" % (directory, exc.strerror))
    held = False
    try:
        if fcntl is not None:
            deadline = time.monotonic() + lock_wait()
            while not held:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    held = True
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise LockError("%s is locked by another writer; gave up waiting" % directory)
                    time.sleep(0.01)
                except OSError:  # this file system has no flock: write unlocked, the rename is still atomic
                    break
        yield
    finally:
        if held:
            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def lock_path(scope, project_dir=None):
    """Where the lock of `scope` lives."""
    if scope == "machine":
        home = os.environ.get("HEIMDALL_HOME") or os.path.join(os.path.expanduser("~"), ".heimdall")
        return os.path.join(home, "skills.lock")
    return os.path.join(project_dir or os.getcwd(), ".planning", "skills.lock")


def prepare(path, scope):
    """The directory that holds the lock, created if need be (the project itself must already exist)."""
    directory = os.path.dirname(path)
    project = os.path.dirname(directory)
    if scope == "project" and not os.path.isdir(project):
        raise LockError("project directory %s does not exist" % project)
    try:
        os.makedirs(directory, mode=0o700 if scope == "machine" else 0o755, exist_ok=True)
    except OSError as exc:
        raise LockError("cannot create %s: %s" % (directory, exc.strerror))
    return directory


def manifest_hash(path):
    """sha256 of the manifest the lock is written against; None when it cannot be read (the write goes on)."""
    try:
        with open(path or DEFAULT_MANIFEST, "rb") as handle:
            return hashlib.sha256(handle.read()).hexdigest()
    except OSError:
        return None


# ---- the transition ----------------------------------------------------------------------------------------------

def transition_ok(old, new):
    """installed never goes back to suggested, declined or failed; adopted can only become installed."""
    if old == new or old not in PRESENT:
        return True
    return old == "adopted" and new == "installed"


def stable(row):
    """The row without the two fields that change on every run: when it last changed, and in which run."""
    return ([row[key] for key in PATCH_ROW], [row["why"][key] for key in PATCH_WHY])


def apply(doc, change, run, now):
    """Upsert one row into `doc`. Returns True when the lock changed (a record that changes nothing is not a change)."""
    current = next((row for row in doc["entries"] if row["id"] == change["id"]), None)
    if current is None:
        if "kind" not in change:
            raise Usage("--kind is required for an id that has no row yet")
        doc["entries"].append({
            "id": change["id"], "kind": change["kind"], "ref": change.get("ref", change["id"]), "state": change["state"],
            "version": change.get("version", "unknown"), "source": change.get("source", "unknown"),
            "pin": change.get("pin", "none"), "content_hash": change.get("content_hash"),
            "consent": change.get("consent", "n/a"), "at": now,
            "why": {"entry": change.get("entry", change["id"]), "rule": change.get("rule", "unspecified"),
                    "evidence": change.get("evidence"), "via": change.get("via", "unspecified"), "run": run}})
        return True
    if not transition_ok(current["state"], change["state"]):
        raise Refused("%s is %s: it cannot go back to %s" % (change["id"], current["state"], change["state"]))
    before = stable(current)
    for key in PATCH_ROW:
        if key in change:
            current[key] = change[key]
    for key in PATCH_WHY:
        if key in change:
            current["why"][key] = change[key]
    if stable(current) == before:
        return False
    current["at"] = now
    current["why"]["run"] = run
    return True


# ---- the command line --------------------------------------------------------------------------------------------

def _id_arg(value):
    if ID_RE.fullmatch(value) is None:
        raise argparse.ArgumentTypeError(
            "%r is not an id (letters, digits and . _ @ / + : -, at most 128, starting with a letter or digit)" % value)
    return value


def _at_arg(value):
    if not _real_time(value):
        raise argparse.ArgumentTypeError("%r is not a real UTC time, YYYY-MM-DDTHH:MM:SSZ" % value)
    return value


def _hash_arg(value):
    low = value.lower()
    if low in ("", "unknown", "none", "n/a"):
        return ""
    if HASH_RE.fullmatch(low) is None:
        raise argparse.ArgumentTypeError("%r is not a git commit id or sha256 (7-64 hex digits)" % value)
    return low


def build_parser():
    parser = argparse.ArgumentParser(
        prog="skills_lock.py", allow_abbrev=False,
        description="The skills lockfile: what hmd installed or suggested, and why. "
                    "Give a value that may start with '-' as --flag=VALUE.",
        epilog="exit status: 0 ok, 1 unreadable/invalid/locked/unwritable lock, 2 bad usage, 3 transition refused, "
               "4 no such row")
    commands = parser.add_subparsers(dest="command", required=True, metavar="{record,read,verify}")
    sub = {}
    for name, summary in (("record", "add a row, or move one to a new state"),
                          ("read", "print the lock (or one row) as canonical JSON"),
                          ("verify", "check the lock against the schema; exit 1 and name every problem if it fails")):
        sub[name] = commands.add_parser(name, help=summary, description=summary, allow_abbrev=False)
        sub[name].add_argument("--scope", required=True, choices=("project", "machine"),
                               help="project: <project dir>/.planning/skills.lock; machine: $HEIMDALL_HOME/skills.lock")
        sub[name].add_argument("--project-dir", metavar="DIR",
                               help="the project (default: the working directory); ignored for --scope machine")
    sub["read"].add_argument("--id", type=_id_arg, help="print only this row, on one line (exit 4 when there is none)")
    rec = sub["record"]
    rec.add_argument("--id", type=_id_arg, required=True)
    rec.add_argument("--state", choices=STATES, required=True)
    rec.add_argument("--kind", choices=KINDS, help="required for an id that has no row yet")
    rec.add_argument("--consent", choices=CONSENTS, help="how the install was agreed to (default n/a)")
    rec.add_argument("--ref", help="e.g. frontend-design@claude-plugins-official (default the id)")
    rec.add_argument("--version", help="the version the CLI resolved, or a git commit (default unknown)")
    rec.add_argument("--source", help="e.g. anthropics/claude-plugins-official, github.com/owner/repo (default unknown)")
    rec.add_argument("--pin", help="the pinned ref (default none)")
    rec.add_argument("--content-hash", type=_hash_arg, metavar="HEX",
                     help="a git commit id or sha256 (7-64 hex digits); 'unknown' or '' for none")
    rec.add_argument("--entry", type=_id_arg, help="why.entry: the manifest entry that caused this (default the id)")
    rec.add_argument("--rule", help="why.rule: which trigger fired, e.g. prompt_ere, files, adopted, explicit")
    rec.add_argument("--evidence",
                     help="why.evidence: the matched token or file path ONLY; cut to %d characters, control characters "
                          "stripped. Never prompt text." % EVIDENCE_MAX)
    rec.add_argument("--via", help="why.via: the install path, e.g. prompt-preinstall, hmd-skills-install")
    rec.add_argument("--run", help="why.run: the run id (default $HMD_RUN_ID, else manual)")
    rec.add_argument("--manifest", metavar="PATH",
                     help="the skills.manifest.json whose sha256 is recorded (default <lib>/../../skills.manifest.json)")
    rec.add_argument("--at", type=_at_arg, metavar="TIME", help="when, as YYYY-MM-DDTHH:MM:SSZ (default now, UTC)")
    return parser


def change_from(args):
    """What the caller said, cleaned. Only the fields it gave: a value that cleans to nothing counts as not given."""
    change = {"id": args.id, "state": args.state}
    for key, cap in CAPS.items():
        text = ascii_text(getattr(args, key) or "", cap)
        if text:
            change[key] = text
    for key in ("kind", "consent", "entry"):
        if getattr(args, key):
            change[key] = getattr(args, key)
    if args.content_hash is not None:
        change["content_hash"] = args.content_hash or None
    if args.evidence is not None:
        change["evidence"] = clean_evidence(args.evidence) or None
    return change


def cmd_record(args):
    path = lock_path(args.scope, args.project_dir)
    directory = prepare(path, args.scope)
    change = change_from(args)
    run = change.pop("run", None) or ascii_text(os.environ.get("HMD_RUN_ID", ""), CAPS["run"]) or "manual"
    now = args.at or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with locked(directory):
        doc = load(path)
        if apply(doc, change, run, now):
            doc["manifest_sha256"] = manifest_hash(args.manifest)
            write(path, doc, 0o600 if args.scope == "machine" else 0o644)
    return 0


def cmd_read(args):
    path = lock_path(args.scope, args.project_dir)
    doc = load(path)
    if args.id is None:
        sys.stdout.write(dump(doc))
        return 0
    for row in doc["entries"]:
        if row["id"] == args.id:
            sys.stdout.write(json.dumps(canonical(row)) + "\n")
            return 0
    warn("no row for %s in %s" % (args.id, path))
    return 4


def cmd_verify(args):
    path = lock_path(args.scope, args.project_dir)
    doc, reasons = parse(path)
    if reasons:
        for reason in reasons:
            warn("%s: %s" % (path, reason))
        return 1
    sys.stdout.write("ok %s (%s)\n" % (path, "%d entries" % len(doc["entries"]) if os.path.lexists(path) else "absent"))
    return 0


COMMANDS = {"record": cmd_record, "read": cmd_read, "verify": cmd_verify}


def main(argv):
    args = build_parser().parse_args(argv)
    try:
        return COMMANDS[args.command](args)
    except Usage as exc:
        warn(str(exc))
        return 2
    except Refused as exc:
        warn(str(exc))
        return 3
    except LockError as exc:
        warn(str(exc))
        return 1
    except Exception as exc:  # reported with a non-zero status, never swallowed, never a traceback
        warn("%s failed: %s: %s" % (args.command, type(exc).__name__, exc))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
