#!/usr/bin/env python3
r"""heimdall-findings -- one review round per release, and only an open BLOCKER/HIGH holds the release (stdlib only).

WHY. CLAUDE.md "Release convergence" says: review the release diff ONCE, prove each fix by its own RED->GREEN test and never re-review it, let only
BLOCKER/HIGH block a release, and send MEDIUM/LOW to .planning/BACKLOG.md. Prose did not hold: one 2.4.9 batch went through six fix -> finding -> fix
rounds in an evening. This tool makes the rules mechanical. The round is recorded and a second one is refused, a MEDIUM/LOW finding is routed to the
backlog the moment it is recorded, and the release script asks `gate` before it creates a tag.

RELEASE BASE. The base of a release is the last release tag (v<digit>...) reachable from HEAD. Findings are kept per base, so a new release tag starts
an empty record and the old one stops mattering. A repository with no release tag has no base: `gate` does not apply and the other commands refuse.

Usage (every command takes --repo PATH, any path inside the repository; default: the cwd):
  heimdall-findings review start --range <base>..<head>
        record the ONE review round of this release. <base> must be the last release tag, <head> a descendant of it. A second round for the same
        base is refused (exit 3): fixes are proven by their own RED->GREEN tests, not re-review. The operator's override is HMD_REVIEW_AGAIN=1
        (exactly 1), set in the environment of the call; it records another round.
  heimdall-findings add --severity BLOCKER|HIGH|MEDIUM|LOW --title T --where file:line [--source review|security-bot|agent]
        record a finding. BLOCKER/HIGH stay open. MEDIUM/LOW are marked deferred and ONE line is appended to .planning/BACKLOG.md under a
        "## Deferred findings (YYYY-MM-DD)" heading (the last heading of the file when it is that one, a new one otherwise). Control characters and
        line breaks in --title/--where are collapsed to spaces, so a title is always one line. The same open finding (severity, title, where) is
        recorded once: a repeat prints its id. Prints the id (F1, F2, ...) of the finding.
  heimdall-findings close <id> --commit <sha>
        close a finding with the commit that fixes it (the commit must exist in this repository). Closing it again with the same commit is a no-op.
  heimdall-findings list [--open]
        show the findings of the current release base; --open shows only those still open (BLOCKER/HIGH nobody has closed), the ones that need a fix.
  heimdall-findings gate
        exit 0 unless a BLOCKER/HIGH is open for the current release base. MEDIUM/LOW, deferred or not, never block. With no store for the base the
        gate is not applied (exit 0): a repository that does not use findings is unaffected. The release script runs this in its preflight.

STATE. <repo>/.heimdall/findings/<sha of the base commit>.ndjson, one JSON event per line, append-only: `review` (one per round), `add`, `close`. A
finding's id is its place among the `add` events, F1, F2, ..., so concurrent reviewers never contend for an id and nothing is ever rewritten. The
file lives in the MAIN checkout of the repository (the parent of the common git directory), so every linked worktree of one repository shares one
store; `.heimdall/*` is ignored by git, so the store never dirties the tree, while the backlog line is a plain edit of the tracked file that the
caller commits with its fixes. A store line that cannot be read is an error (exit 1), never an empty store.

LINKS. Every read and write below the repository goes through bin/lib/hmd_nofollow_write.py (each component opened O_NOFOLLOW relative to the one
before). A link on the way down -- .heimdall, .heimdall/findings, the store file, .planning, .planning/BACKLOG.md -- or an entry that is not a regular
file is REFUSED (exit 4) and nothing is written or followed, `gate` included: a gate that cannot read its store is never green.

A COOPERATING-AGENT CONTROL, NOT A SECURITY BOUNDARY. The store is a plain local file, like the sweep receipt: it stops a loop that forgets the rule,
not someone who edits the file.

EXIT  0 done / gate green or not applied | 1 failed (an I/O error, a corrupt store) | 2 usage or invalid input | 3 review refused (already reviewed)
      | 4 REFUSED (a link or an entry that is not plain) | 5 gate RED (an open BLOCKER/HIGH)

Python 3.7+, standard library only.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hmd_nofollow_write as nf  # noqa: E402  (the no-follow walk, and the append every write goes through)

OK, FAILED, USAGE, AGAIN, REFUSED, RED = 0, 1, 2, 3, nf.REFUSED, 5
STORE_REL = ".heimdall/findings"
BACKLOG_REL, BACKLOG_NAME = ".planning", "BACKLOG.md"
SEVERITIES = ("BLOCKER", "HIGH", "MEDIUM", "LOW")
BLOCKING = ("BLOCKER", "HIGH")
SOURCES = ("review", "security-bot", "agent")
MAX_TITLE, MAX_WHERE = 500, 300
MAX_STORE_BYTES, MAX_BACKLOG_BYTES = 8 << 20, 16 << 20
GIT_AMBIENT = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE")  # a stray one in THIS process must not redirect git
OID_RE = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
HEADING_RE = re.compile(r"#{1,6} ")
ID_RE = re.compile(r"[Ff]?([0-9]{1,9})")


class Fail(Exception):
    """A refusal or failure with its exit status; the message is printed on stderr."""

    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code = code
        self.message = message


def say(text):
    sys.stdout.buffer.write((text + "\n").encode("utf-8", "replace"))
    sys.stdout.buffer.flush()


def warn(text):
    sys.stderr.buffer.write((text + "\n").encode("utf-8", "replace"))
    sys.stderr.buffer.flush()


def git(args, cwd):
    """(exit status, stdout, stderr) of git run in `cwd`."""
    env = dict((k, v) for k, v in os.environ.items() if k not in GIT_AMBIENT)
    env["GIT_OPTIONAL_LOCKS"] = "0"
    try:
        done = subprocess.run(["git"] + args, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        raise Fail(FAILED, "cannot run git: %s" % exc)
    return done.returncode, done.stdout.decode("utf-8", "replace"), done.stderr.decode("utf-8", "replace")


def locate(path):
    """(work tree, the checkout that holds the shared state) of the repository `path` is in. A linked worktree shares the store of the main checkout,
    the parent of the common git directory; a repository whose common directory is not <checkout>/.git keeps its own."""
    path = os.path.abspath(path)
    if not os.path.isdir(path):
        raise Fail(USAGE, "%s is not a directory" % path)
    rc, out, err = git(["rev-parse", "--show-toplevel", "--git-common-dir"], path)
    lines = out.split("\n")
    if rc != 0 or len(lines) < 2 or not lines[0] or not lines[1]:
        raise Fail(USAGE, "%s is not inside a git work tree%s" % (path, (": " + err.strip().split("\n")[0]) if err.strip() else ""))
    top = os.path.realpath(lines[0])
    common = os.path.realpath(os.path.join(path, lines[1]))
    root = os.path.dirname(common) if os.path.basename(common) == ".git" and os.path.isdir(common) else top
    return top, root


def commit_of(top, ref, what):
    """The full object id of the commit `ref` names, or a usage error."""
    if not ref or ref.startswith("-") or CONTROL_RE.search(ref):
        raise Fail(USAGE, "%s %r is not a commit" % (what, ref))
    rc, out, _ = git(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], top)
    sha = out.strip()
    if rc != 0 or not OID_RE.fullmatch(sha):
        raise Fail(USAGE, "%s %r is not a commit of this repository" % (what, ref))
    return sha


def last_release_tag(top, head):
    """(name, commit id) of the nearest release tag -- v<digit>... -- reachable from `head`, or None."""
    rc, out, _ = git(["describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", head], top)
    name = out.strip()
    if rc != 0 or not name:
        return None
    rc, out, _ = git(["rev-parse", "--verify", "--quiet", "refs/tags/%s^{commit}" % name], top)
    sha = out.strip()
    return (name, sha) if rc == 0 and OID_RE.fullmatch(sha) else None


def context(repo, need_base):
    """(work tree, state root, (tag name, base commit) or None). Without a release tag there is no base: a command that needs one refuses."""
    top, root = locate(repo)
    tag = last_release_tag(top, "HEAD")
    if tag is None and need_base:
        raise Fail(USAGE, "no release tag (v<N>...) is reachable from HEAD: the base of a review is the last release tag")
    return top, root, tag


# ── reading and writing below the repository, never through a link ────────────
class Capped(object):
    """The sink hmd_nofollow_write.read copies into: it keeps the chunks and refuses to hold more than `cap` bytes."""

    def __init__(self, cap, shown):
        self.chunks, self.size, self.cap, self.shown = [], 0, cap, shown

    def write(self, chunk):
        self.size += len(chunk)
        if self.size > self.cap:
            raise Fail(FAILED, "%s is larger than %d bytes" % (self.shown, self.cap))
        self.chunks.append(chunk)


def read_file(root, rel, name, cap):
    """The bytes of <root>/<rel>/<name>, None when it (or a directory above it) is not there. Refused when a link, a hard-linked file or an entry that
    is not a regular file is in the way (hmd_nofollow_write.read: every component opened without following a link, the file checked on the descriptor)."""
    sink = Capped(cap, "/".join(p for p in (rel, name) if p))
    try:
        nf.read(root, rel, name, sink)
    except FileNotFoundError:
        return None
    return b"".join(sink.chunks)


class Store(object):
    """What a findings file says: its review rounds, and its findings in the order they were recorded."""

    def __init__(self):
        self.reviews = []
        self.findings = []

    def find(self, fid):
        for f in self.findings:
            if f["id"] == fid:
                return f
        return None


def state_of(f):
    """closed, open (a BLOCKER/HIGH nobody closed) or deferred (a MEDIUM/LOW, routed to the backlog)."""
    if f["closed_by"]:
        return "closed"
    return "open" if f["severity"] in BLOCKING else "deferred"


def replay(raw, shown):
    store = Store()

    def corrupt(lineno, why):
        return Fail(FAILED, "%s is corrupt at line %d: %s (a store that cannot be read is never read as empty: repair or remove the file)" % (shown, lineno, why))

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise corrupt(0, "not UTF-8")
    for lineno, line in enumerate(text.split("\n"), 1):
        if not line.strip():
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            raise corrupt(lineno, "not JSON")
        kind = ev.get("ev") if isinstance(ev, dict) else None
        if kind == "review":
            if not all(isinstance(ev.get(k), str) and ev[k] for k in ("range", "base", "base_sha", "head_sha")):
                raise corrupt(lineno, "a review event without its range and commits")
            store.reviews.append(ev)
        elif kind == "add":
            if ev.get("severity") not in SEVERITIES or not all(isinstance(ev.get(k), str) and ev[k] for k in ("title", "where", "source", "nonce")):
                raise corrupt(lineno, "an add event that is not a finding")
            store.findings.append({"id": "F%d" % (len(store.findings) + 1), "severity": ev["severity"], "title": ev["title"], "where": ev["where"],
                                   "source": ev["source"], "nonce": ev["nonce"], "closed_by": None})
        elif kind == "close":
            f = store.find(ev.get("id")) if isinstance(ev.get("id"), str) else None
            if f is None or not isinstance(ev.get("commit"), str) or not OID_RE.fullmatch(ev["commit"]):
                raise corrupt(lineno, "a close event for a finding that was never recorded, or without its commit")
            f["closed_by"] = f["closed_by"] or ev["commit"]
        else:
            raise corrupt(lineno, "an event this tool does not know")
    return store


def store_name(tag):
    return tag[1] + ".ndjson"


def load(root, tag):
    """The Store of the release base `tag`, or None when nothing was ever recorded for it."""
    raw = read_file(root, STORE_REL, store_name(tag), MAX_STORE_BYTES)
    return None if raw is None else replay(raw, "%s/%s" % (STORE_REL, store_name(tag)))


def record(root, tag, event):
    event["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    nf.append(root, STORE_REL, store_name(tag), (json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii"), 0o600)


def backlog_tail(raw, heading, bullet):
    """The text to append to a BACKLOG.md holding `raw` (bytes, None when there is none) so that `bullet` sits under `heading`: under the last heading of
    the file when that is already `heading`, under a new one otherwise. Only ever appended, so nothing a person wrote is rewritten."""
    if raw is None or not raw.strip():
        return "# BACKLOG\n\n%s\n\n%s\n" % (heading, bullet)
    text = raw.decode("utf-8", "replace")
    last, fenced = "", False
    for line in text.split("\n"):
        if line.startswith(("```", "~~~")):
            fenced = not fenced
        elif not fenced and HEADING_RE.match(line):
            last = line.rstrip()
    lead = "" if text.endswith("\n") else "\n"
    if last == heading:
        return "%s%s\n" % (lead, bullet)
    return "%s\n%s\n\n%s\n" % (lead, heading, bullet)


def route_to_backlog(root, bullet):
    heading = "## Deferred findings (%s)" % time.strftime("%Y-%m-%d")
    raw = read_file(root, BACKLOG_REL, BACKLOG_NAME, MAX_BACKLOG_BYTES)
    nf.append(root, BACKLOG_REL, BACKLOG_NAME, backlog_tail(raw, heading, bullet).encode("utf-8", "replace"), 0o666)


def clean(value, limit, what):
    """`value` as one line: control characters and line breaks collapsed to single spaces."""
    text = " ".join(CONTROL_RE.sub(" ", value.encode("utf-8", "replace").decode("utf-8")).split())
    if not text:
        raise Fail(USAGE, "%s is empty" % what)
    if len(text) > limit:
        raise Fail(USAGE, "%s is longer than %d characters" % (what, limit))
    return text


def describe(f):
    line = "%-4s %-8s %-9s %s  %s  [%s]" % (f["id"], f["severity"], state_of(f), f["where"], f["title"], f["source"])
    return line + ("  closed by %s" % f["closed_by"][:12] if f["closed_by"] else "")


# ── commands ──────────────────────────────────────────────────────────────────
def cmd_review_start(args):
    top, root = locate(args.repo)
    parts = args.range.split("..")
    if len(parts) != 2 or not parts[0] or not parts[1] or parts[1].startswith("."):
        raise Fail(USAGE, "--range must be <base>..<head>, two refs and exactly two dots (got %r)" % args.range)
    base, head = commit_of(top, parts[0], "base"), commit_of(top, parts[1], "head")
    if git(["merge-base", "--is-ancestor", base, head], top)[0] != 0:
        raise Fail(USAGE, "%s is not an ancestor of %s: the range must run from the last release tag to the head under review" % (parts[0], parts[1]))
    tag = last_release_tag(top, head)
    if tag is None:
        raise Fail(USAGE, "no release tag (v<N>...) is reachable from %s: the base of a review is the last release tag" % parts[1])
    if tag[1] != base:
        raise Fail(USAGE, "the base of a review is the last release tag, %s: one round covers the whole release since it, never a narrower range" % tag[0])
    store = load(root, tag)
    rounds = len(store.reviews) if store else 0
    if rounds and os.environ.get("HMD_REVIEW_AGAIN") != "1":
        raise Fail(AGAIN, "already reviewed for %s; fixes are proven by their own RED→GREEN tests, not re-review" % tag[0])
    record(root, tag, {"ev": "review", "round": rounds + 1, "range": args.range, "base": tag[0], "base_sha": base, "head_sha": head})
    say("review round %d recorded for %s (%s)" % (rounds + 1, tag[0], args.range))
    return OK


def cmd_add(args):
    title, where = clean(args.title, MAX_TITLE, "--title"), clean(args.where, MAX_WHERE, "--where")
    _, root, tag = context(args.repo, True)
    store = load(root, tag)
    for f in (store.findings if store else []):
        if state_of(f) != "closed" and (f["severity"], f["title"], f["where"]) == (args.severity, title, where):
            say("already recorded as %s (%s)" % (f["id"], state_of(f)))
            return OK
    if args.severity not in BLOCKING:   # routed first: a finding that could not be routed is never recorded as deferred
        route_to_backlog(root, "- [ ] %s: %s (%s; %s; release after %s)" % (args.severity, title, where, args.source, tag[0]))
    nonce = os.urandom(4).hex()
    record(root, tag, {"ev": "add", "severity": args.severity, "title": title, "where": where, "source": args.source, "nonce": nonce})
    mine = next((f for f in load(root, tag).findings if f["nonce"] == nonce), None)   # its place in the file is its id, whoever else appended meanwhile
    if mine is None:
        raise Fail(FAILED, "the finding was recorded but could not be read back from %s" % STORE_REL)
    say("recorded %s: %s %s (%s)%s" % (mine["id"], args.severity, title, where,
                                        "; deferred, one line added to .planning/BACKLOG.md" if args.severity not in BLOCKING else ""))
    return OK


def cmd_close(args):
    m = ID_RE.fullmatch(args.id)
    if not m:
        raise Fail(USAGE, "%r is not a finding id (F1, F2, ...)" % args.id)
    fid = "F%d" % int(m.group(1))
    top, root, tag = context(args.repo, True)
    sha = commit_of(top, args.commit, "--commit")
    store = load(root, tag)
    f = store.find(fid) if store else None
    if f is None:
        raise Fail(USAGE, "no finding %s for %s (heimdall-findings list shows them)" % (fid, tag[0]))
    if f["closed_by"]:
        if f["closed_by"] == sha:
            say("%s is already closed by %s" % (fid, sha[:12]))
            return OK
        raise Fail(USAGE, "%s is already closed by %s" % (fid, f["closed_by"][:12]))
    record(root, tag, {"ev": "close", "id": fid, "commit": sha})
    say("closed %s by %s" % (fid, sha[:12]))
    return OK


def cmd_list(args):
    _, root, tag = context(args.repo, False)
    if tag is None:
        say("no release tag is reachable from HEAD: no findings")
        return OK
    store = load(root, tag)
    if store is None:
        say("no findings recorded for %s" % tag[0])
        return OK
    counts = dict((s, sum(1 for f in store.findings if state_of(f) == s)) for s in ("open", "deferred", "closed"))
    first = store.reviews[0]["range"] if store.reviews else None
    say("%s (base %s): %s; %d open, %d deferred, %d closed" % (
        tag[0], tag[1][:12], "review round %d of %s" % (len(store.reviews), first) if first else "no review round recorded",
        counts["open"], counts["deferred"], counts["closed"]))
    for f in store.findings:
        if not args.open or state_of(f) == "open":
            say(describe(f))
    return OK


def cmd_gate(args):
    _, root, tag = context(args.repo, False)
    if tag is None:
        say("no release tag is reachable from HEAD: gate not applied")
        return OK
    store = load(root, tag)
    if store is None:
        say("no findings store for %s: gate not applied" % tag[0])
        return OK
    blocking = [f for f in store.findings if state_of(f) == "open"]
    if blocking:
        warn("findings gate RED for %s: %d open BLOCKER/HIGH" % (tag[0], len(blocking)))
        for f in blocking:
            warn("  " + describe(f))
        warn("fix each in its own commit, proven by its own RED→GREEN test (no re-review), then: heimdall-findings close <id> --commit <sha>")
        return RED
    say("findings gate green for %s: no open BLOCKER/HIGH (%d deferred, %d closed)" % (
        tag[0], sum(1 for f in store.findings if state_of(f) == "deferred"), sum(1 for f in store.findings if state_of(f) == "closed")))
    return OK


def build_parser():
    parser = argparse.ArgumentParser(prog="heimdall-findings", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--repo", default=".", metavar="PATH", help="any path inside the repository (default: the cwd)")
    review = sub.add_parser("review", help="record the review round of a release")
    start = review.add_subparsers(dest="action", required=True, metavar="ACTION").add_parser("start", parents=[common], help="record the ONE review round of the release")
    start.add_argument("--range", required=True, metavar="BASE..HEAD", help="the last release tag, two dots, the head under review")
    start.set_defaults(func=cmd_review_start)
    add = sub.add_parser("add", parents=[common], help="record a finding (MEDIUM/LOW are deferred to the backlog)")
    add.add_argument("--severity", required=True, type=str.upper, choices=SEVERITIES)
    add.add_argument("--title", required=True)
    add.add_argument("--where", required=True, metavar="FILE:LINE")
    add.add_argument("--source", choices=SOURCES, default="review")
    add.set_defaults(func=cmd_add)
    close = sub.add_parser("close", parents=[common], help="close a finding with the commit that fixes it")
    close.add_argument("id", metavar="ID")
    close.add_argument("--commit", required=True, metavar="SHA")
    close.set_defaults(func=cmd_close)
    lst = sub.add_parser("list", parents=[common], help="show the findings of the current release base")
    lst.add_argument("--open", action="store_true", help="only the BLOCKER/HIGH nobody has closed")
    lst.set_defaults(func=cmd_list)
    sub.add_parser("gate", parents=[common], help="exit 5 while a BLOCKER/HIGH is open for the current release base").set_defaults(func=cmd_gate)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except Fail as exc:
        warn("heimdall-findings: %s" % exc.message)
        return exc.code
    except nf.Refused as exc:
        warn("heimdall-findings: refused: %s (nothing was written or followed)" % exc)
        return REFUSED
    except OSError as exc:
        warn("heimdall-findings: %s" % exc)
        return FAILED


if __name__ == "__main__":
    sys.exit(main())
