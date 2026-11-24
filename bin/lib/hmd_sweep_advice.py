#!/usr/bin/env python3
r"""hmd_sweep_advice -- is this Bash command the FINAL merge, and what does the developer need to know about a full test run before it?

Operator directive 2026-11-12: full test runs are RECOMMENDED to developers, with the explanation and the token cost, and suggested just before a merge and not
before. Refined 2026-11-22: "only do the full sweep before final merge and not on every merge". An orchestrator lands a batch of agent worktree branches with one local
`git merge` per branch: each is an INTEGRATION step inside the batch and says nothing; the one recommendation comes at the final merge, the push, pull request
merge or pull that sends the batch to the default branch. bin/heimdall-precheck-bash asks this file, for a command that mentions merge, push or pull (and git or gh),
whether the command IS the final merge, and if so
prints the recommendation as hook JSON: systemMessage for the developer, hookSpecificOutput.additionalContext so the agent relays it. It never blocks (there is no
permissionDecision), it never speaks at any other moment, and the call stays the developer's: run it now, or merge without it. It reads the command the way a shell
does by reusing bin/lib/hmd_kill_guard.py's lexer and wrapper handling (quotes and escapes, env / time / timeout / sudo / xargs, ; && || | & and newlines, subshells,
substitutions, if / for / while bodies, sh -c, eval, heredocs fed to a shell), bin/lib/hmd_push_target.py's table of git's global options, and
bin/lib/hmd_sweep_guard.py's reading of the records (the receipt, the hooks' own journal paths, ancestry), so text that only MENTIONS a merge (echo, grep, a commit
message, a script written to disk) is no merge, as it is no sweep to the sweep guard.

  final merge the pr-merge subcommand of gh (not help, and not for ANOTHER repository: -R, --repo, GH_REPO: the records here are not that repo's)
              the pull subcommand of git, on the default branch, when it merges (a pull that rebases -- --rebase, -r, pull.rebase -- is no merge)
              the push subcommand of git, whose target is the default branch: main, master, or what origin/HEAD names, however the refspec is spelled (a bare push,
              HEAD, src:dst, refs/heads/..., --all, --mirror); a push of another branch, of tags, or a deletion is no merge
  not one     the merge subcommand of git, in every form (--no-ff, --squash, --abort, a bare `git merge`): it merges refs into a LOCAL branch, the default one too, an
              integration step inside a batch of agent worktree branches, so it gets no advice; the push that sends the result to the default branch is the final merge.
              merge-base, merge-tree and mergetool are other commands
  the subject the commits that stand to land: HEAD, plus what a pull brings in (the branch it names, else the upstream), or, for a push, the commits it sends.
              A ref that cannot be placed in this checkout is said so, and it keeps the commits from being called proven
  its class   read from the commit like the push gate does (bin/lib/hmd_push_target.py commit_class):
              sweep        test/run-all.sh names last-sweep.json: heimdall's own regime. Operator decision 2026-11-22 ("B"): a PUSH stands on EITHER of the two records the push gate
                           (bin/heimdall-state check-quality-gates) takes: a green use-case journey receipt (bash test/use-cases/run.sh writes receipts/use-cases.json; bin/lib/hmd_use_case_receipt.py
                           is its one definition and re-derives the commit and the tree from git), or a green full sweep (receipts/last-sweep.json, last-full-green.json, the anchor, and the archive
                           receipts/full-green/<head_sha>.json, in $HEIMDALL_HOME/receipts, else <repo>/.heimdall/receipts, as the runner works them out: a green full receipt of a clean tree that is
                           full-equivalent and recorded for this checkout). A commit is covered by a record when it is the record's own, or only the hooks' own journal and ledger records came after
                           it. Only a proof says "already proven". What to RUN is the use-case run (bash test/use-cases/run.sh, about 6 minutes for its journeys and their mutants); the full sweep is a
                           RELEASE's bar (release/ship.sh) and is named on the Release: line only, never recommended for a push, so a red or a running sweep changes nothing here. The Why and the
                           Cost measure from the NEWEST green record among those on file (the one that leaves the fewest commits uncovered, then the latest finished_at): a use-case receipt, a
                           full-sweep proof, or a green full run of a clean tree that is NOT full-equivalent. That last kind is why last-sweep.json is read at all: test/run-all.sh moves the anchor
                           and writes the archive only for a full-equivalent green (its anchor block, after the receipt is written), so a green sweep in which a suite's green has no cache record
                           (full_equivalent=false: a result the cache could not store; a suite that passed only on its solo re-run is stored since 2026-11-24) lives in last-sweep.json alone and the anchor lags behind it BY DESIGN, not by a runner bug
              repo-checks  .heimdall/repo-checks.json is declared: its own receipt (bin/lib/hmd_repo_receipt.py) must be green and current for the commit, and it
                           attests ONE commit. Run: bin/heimdall-repo-checks run --repo <repo>
              unmanaged    neither (or a declaration that cannot be used): lint plus the use-case suite, skills/heimdall/references/use-case-tests.md
  it says     proven       every commit that stands to land is covered: ONE line, "already proven green ... nothing to run", and nothing is recommended
              otherwise    four parts. Why: what changed since the last green full record (commits and files, the hooks' own records not counted), or "no green
                           record yet" and the reason. Run: the exact command. Cost: the suites (or checks), the last measured wall clock from the receipt, and the
                           tokens as ESTIMATES, always labelled: a run in the developer's own terminal costs no model tokens; an agent that runs it in the background
                           and reads only a 40-line summary tail reads 40 lines x 91 B / 4; an agent that reads all of it reads (suites + 40) rows x 91 B / 4 -- 91 is
                           the width of a row of the runner's own table (printf '%-9s %-52s %6s %6s %5s %7s\n'). Your call: run it now, or merge without it
  unread      a command that mentions a merge and that this cannot read, or a repository it cannot reach: an unbalanced quote, shell strings nested more than 8
              deep, a cd to a variable, a directory that is no repository, a timeout, an internal error. Exit 4: the hook warns on stderr (one line) and goes on.
              This is a COST and DISCIPLINE nudge, not a security gate (the CI waste guard's and the sweep guard's convention), so what it could not read is never
              an error. A merge it DID read wins over what it could not. A receipt that is missing, red, partial or foreign is not "unread": it is the answer
              ("no green record yet", and why)
  unseen      what no reading sees: a command or ref held in a variable, an alias, a script on disk that merges, a pull request merged from the web page. Best
              effort, not a security boundary

Protocol: the command text on stdin, the directory the shell is in as the one argument; stdout `ok` and exit 0 = not a merge, nothing to say; ONE line of hook JSON
and exit 3 = advice; one reason line and exit 4 = could not tell (allow, warn). Anything else (a crash, another status) is the hook's "the helper itself failed"
warning, also an allow. HMD_SWEEP_ADVICE_TIMEOUT_S (default 8) bounds the run. HMD_SWEEP_ADVICE=off (also 0, false, no) is read by the hook, which then never starts
this file; so is the switch `hmd guardrails off sweep-advice`.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hmd_kill_guard as kg  # noqa: E402  (the shell reader: lex, unwrap, opaque, the run-time budget)
import hmd_sweep_guard as sg  # noqa: E402  (the records: receipts, the hooks' own paths, ancestry; and the Unread that means "could not tell")
import hmd_push_target as pt  # noqa: E402  (git's global options, and the class of a commit)
import hmd_repo_receipt as rr  # noqa: E402  (a repo's own receipt: the facts it binds to, and the one definition of "green and current")
import hmd_use_case_receipt as ucr  # noqa: E402  (heimdall's own use-case journey receipt: the push gate's second record, and the one definition of it)

PLUGIN = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir))
MAX_DEPTH = kg.MAX_DEPTH  # shell strings (sh -c, eval, heredocs) read inside shell strings
try:
    TIMEOUT_S = float(os.environ.get("HMD_SWEEP_ADVICE_TIMEOUT_S", "8"))
except ValueError:
    TIMEOUT_S = 8.0

MENTION = re.compile(r"merge|push|pull")  # a command that names none of these is not this advice's business
ROW_BYTES = 91  # the width of one row of run-all.sh's table: printf '%-9s %-52s %6s %6s %5s %7s\n' is 9 + 52 + 6 + 6 + 5 + 7 + 5 spaces + a newline
TAIL_LINES = 40  # what an agent reads of a run when it reads only the summary: `tail -n 40`
BYTES_PER_TOKEN = 4  # the usual rule of thumb for English and code
DEFAULTS = ("main", "master")  # the default branch, besides what origin/HEAD names
NOUN = {"pr-merge": "pull request merge", "pull": "pull", "push": "push"}
PULL_VALUE_OPTS = frozenset(("-s", "--strategy", "-X", "--strategy-option", "--depth", "--deepen", "--shallow-since", "--shallow-exclude", "-j", "--jobs",
                             "-o", "--server-option", "--upload-pack", "--refmap"))
PUSH_VALUE_OPTS = pt.PUSH_VALUE_OPTS | frozenset(("--repo",))
GH_VALUE_OPTS = frozenset(("-R", "--repo"))
NAME_OK = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._/-]*$")
FULL_GREEN_KEEP = 20  # how many receipts/full-green/<head_sha>.json the runner keeps (test/run-all.sh FULL_GREEN_KEEP, newest by modification time): the most of them this reads
STAMP = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")  # a receipt's finished_at, `date -u '+%Y-%m-%dT%H:%M:%SZ'`: stamps of this form sort as text
NOT_FULL_EQUIVALENT = "not full-equivalent (a suite has no cache record, e.g. a green the cache could not store), so the push gate takes it for no proof"
TYPICAL_RUN = "about 6 minutes"  # one whole run of the use-case runner (every journey, then every mutant, three at a time) as measured on 2026-11-22; the wall clock of a receipt on file replaces it
TYPICAL_ON = "2026-11-22"
RELEASE_NOTE = ("this is the bar for a push. A release (release/ship.sh) is another one: it needs a green full sweep, bash test/run-all.sh; nothing here asks for that before a push.")

U_DEEP = sg.U_DEEP
U_TIMEOUT = "reading the command and the records took longer than %gs (HMD_SWEEP_ADVICE_TIMEOUT_S), so no advice was given"
U_ERROR = "an internal error (%s), so no advice was given"
U_CWD = "the directory the command runs in cannot be told (a cd to a variable, or cd -), so the repository it merges in is unknown"
U_VAR = "a directory option of git is held in a variable, so the repository it merges in is unknown"


class Op(object):
    """One simple command that may be the final merge: kind is pull, push or pr-merge; args are the words after the subcommand, opts git's
    global options (as words), cwd the directory the shell is in, text the command as shown to the developer."""
    __slots__ = ("kind", "args", "cwd", "opts", "text")

    def __init__(self, kind, args, cwd, opts, text):
        self.kind, self.args, self.cwd, self.opts, self.text = kind, args, cwd, opts, text


# ── reading the command ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

def shown(words):
    """The words as one short line for the developer: whitespace collapsed, cut at 80 characters."""
    return " ".join(" ".join(w.text for w in words).split())[:80]


def rebasing(args):
    """Does a pull's own command line say it rebases? --no-rebase and --rebase=false say it merges."""
    state = False
    for w in args:
        if w.dynamic:
            continue
        t = w.text
        if t in ("-r", "--rebase"):
            state = True
        elif t == "--no-rebase":
            state = False
        elif t.startswith("--rebase="):
            state = t.split("=", 1)[1] != "false"
    return state


def explicit_merge(args):
    """Does a pull say, on its command line, that it merges (so no configuration decides)?"""
    return any(not w.dynamic and w.text in ("--no-rebase", "--rebase=false") for w in args)


def note_git(rest, cwd, ops):
    """git <global options> <subcommand> ...: the words after `git`."""
    k, opts = 0, []
    while k < len(rest) and not rest[k].dynamic and rest[k].text.startswith("-"):
        opts.append(rest[k])
        if rest[k].text in pt.GIT_VALUE_OPTS and k + 1 < len(rest):
            k += 1
            opts.append(rest[k])
        k += 1
    if k >= len(rest) or rest[k].dynamic:
        return
    sub, args = rest[k].text, rest[k + 1:]
    text = "git " + shown(rest[k:])
    # no branch for `git merge`: a local merge of refs is an integration step inside a batch, not the final merge, so it is no op and gets no advice (2026-11-22)
    if sub == "pull":
        if not rebasing(args):  # the configuration (pull.rebase) is asked later, in the repository the pull is in
            ops.append(Op("pull", args, cwd, opts, text))
    elif sub == "push":
        ops.append(Op("push", args, cwd, opts, text))


def note_gh(cmd, head, rest, cwd, ops):
    """gh <flags> pr merge ...: the words after `gh`. A merge for another repository is not this checkout's."""
    words, k, other = [], 0, "GH_REPO" in sg.inline_env(cmd.words, head)
    while k < len(rest) and len(words) < 2:
        w = rest[k]
        k += 1
        if w.dynamic:
            return
        if w.text in GH_VALUE_OPTS:
            other, k = True, k + 1
        elif w.text.startswith("--repo="):
            other = True
        elif not w.text.startswith("-"):
            words.append(w.text)
    if tuple(words) != ("pr", "merge") or other:
        return
    for w in rest[k:]:  # help, or a repository named after the subcommand
        if not w.dynamic and (w.text in ("-h", "--help") or w.text in GH_VALUE_OPTS or w.text.startswith("--repo=")):
            return
    ops.append(Op("pr-merge", rest[k:], cwd, [], "gh " + shown(rest)))


def visit(cmd, cwd, depth, unread, ops):
    """Read one simple command: a cd moves the shell, a command that merges is an op. Returns the shell's directory afterwards."""
    args, _ = kg.unwrap(cmd.words)
    if not args or args[0].dynamic:
        return cwd
    head, rest = args[0], args[1:]
    base = os.path.basename(head.text).lower()
    if base in ("cd", "pushd"):
        return sg.chdir(cwd, rest)
    if base == "git":
        note_git(rest, cwd, ops)
    elif base == "gh":
        note_gh(cmd, head, rest, cwd, ops)
    elif base in kg.SHELLS:
        string = sg.read_shell(rest)[0]
        sources = list(cmd.bodies)
        if string is not None and not kg.opaque(string):
            sources.append(string.text)
        for source in sources:
            find_ops(source, cwd, depth + 1, unread, ops)
    elif base == "eval" and not (rest and kg.opaque(rest[0])):
        find_ops(" ".join(w.text for w in rest), cwd, depth + 1, unread, ops)
    return cwd


def find_ops(text, cwd, depth, unread, ops):
    """Append every merge in `text` to `ops`; whatever could not be read is appended to `unread`."""
    if depth > MAX_DEPTH:
        unread.append(U_DEEP)
        return
    cmds, unparsed = kg.lex(text)
    if unparsed:
        unread.append(unparsed)
    for cmd in cmds:
        cwd = visit(cmd, cwd, depth, unread, ops)


# ── git ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

def locate(op):
    """The work tree root the op is in: its directory with the `-C` chain of git's global options applied. Unread when that cannot be told."""
    here, opts, k = op.cwd, op.opts, 0
    while k < len(opts):
        w = opts[k]
        value = opts[k + 1] if k + 1 < len(opts) else None
        if w.dynamic or (w.text in pt.GIT_VALUE_OPTS and value is not None and value.dynamic):
            raise sg.Unread(U_VAR)
        if w.text == "-C" and value is not None:
            if not here:
                raise sg.Unread(U_CWD)
            here = os.path.normpath(os.path.join(here, os.path.expanduser(value.text)))
        k += 2 if w.text in pt.GIT_VALUE_OPTS else 1
    if not here:
        raise sg.Unread(U_CWD)
    if not os.path.isdir(here):
        raise sg.Unread("%s does not exist, so there is no repository to read" % here)
    return sg.git_out(here, "rev-parse", "--show-toplevel").strip()


def resolve(top, rev):
    """The commit `rev` names in this checkout, or None. A word that could be read as an option, or that cannot be an argument, names nothing."""
    if not rev or rev.startswith("-") or "\0" in rev:
        return None
    rc, out = sg.git(top, "rev-parse", "-q", "--verify", rev + "^{commit}")
    return out.strip() if rc == 0 and sg.COMMIT.match(out.strip()) else None


def current_branch(top):
    """The branch HEAD is on, or "" when it is detached."""
    rc, out = sg.git(top, "symbolic-ref", "-q", "--short", "HEAD")
    return out.strip() if rc == 0 else ""


def default_branches(top, remotes):
    """main, master and whatever origin/HEAD (or the remote named) says the default branch is."""
    names = set(DEFAULTS)
    for remote in remotes:
        if NAME_OK.match(remote):
            rc, out = sg.git(top, "symbolic-ref", "-q", "--short", "refs/remotes/%s/HEAD" % remote)
            if rc == 0 and "/" in out.strip():
                names.add(out.strip().split("/", 1)[1])
    return names


def upstream(top):
    """(the upstream branch's short name, its commit) when the current branch has one that is known here."""
    rc, out = sg.git(top, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
    name = out.strip()
    sha = resolve(top, name) if rc == 0 and name else None
    return (name, sha) if sha else None


def config_rebases(top, branch):
    """Does git's own configuration make a bare pull rebase (branch.<name>.rebase, then pull.rebase)?"""
    for key in ("branch.%s.rebase" % branch, "pull.rebase"):
        rc, out = sg.git(top, "config", "--get", key)
        if rc == 0:
            return out.strip().lower() not in ("false", "0", "no", "off", "")
    return False


class Subjects(object):
    """The commits that stand to land: [(labels, sha)], one entry per commit, and the names that could not be placed in this checkout."""

    def __init__(self):
        self.items, self.unplaced = [], []

    def add(self, label, sha):
        for labels, known in self.items:
            if known == sha:
                if label not in labels:
                    labels.append(label)
                return
        self.items.append(([label], sha))

    def shas(self):
        return [sha for _, sha in self.items]

    def describe(self, only=None):
        return ", ".join("%s %s" % (" = ".join(labels), sha[:12]) for labels, sha in self.items if only is None or sha in only)


def positional(args, value_opts):
    """The words of a command that are neither options nor the values of options."""
    out, k = [], 0
    while k < len(args):
        t = args[k].text
        k += 1
        if t == "--":
            out.extend(w.text for w in args[k:])
            break
        if args[k - 1].dynamic or not t.startswith("-") or t == "-":
            out.append(t)
        elif t in value_opts:
            k += 1
    return out


def pull_subjects(op, top, head, branch, names):
    """None unless this pull merges into the default branch."""
    if branch not in names or rebasing(op.args) or (not explicit_merge(op.args) and config_rebases(top, branch)):
        return None
    subs = Subjects()
    subs.add("HEAD", head)
    pos = positional(op.args, PULL_VALUE_OPTS)
    if len(pos) >= 2 and NAME_OK.match(pos[0]) and NAME_OK.match(pos[1]):
        label = "%s/%s" % (pos[0], pos[1])
        sha = resolve(top, "refs/remotes/" + label)
        found = (label, sha) if sha else None
        if not sha:
            subs.unplaced.append(label)
    else:
        found = upstream(top)
    if found:
        subs.add(*found)
    return subs


def push_shape(args):
    """(the remote and refspecs as written, whether it is --all / --mirror, whether it deletes, whether it names tags, whether the remote came from --repo)."""
    words, broad, deleting, tags, repo_opt, k = [], False, False, False, False, 0
    while k < len(args):
        t = args[k].text
        k += 1
        if t == "--":
            words.extend(w.text for w in args[k:])
            break
        if args[k - 1].dynamic or not t.startswith("-") or t == "-":
            words.append(t)
        elif t in PUSH_VALUE_OPTS:
            repo_opt = repo_opt or t == "--repo"
            k += 1
        elif t.startswith("--repo="):
            repo_opt = True
        elif t in ("--all", "--branches", "--mirror"):
            broad = True
        elif t in ("-d", "--delete"):
            deleting = True
        elif t == "--tags":
            tags = True
    return words, broad, deleting, tags, repo_opt


def push_subjects(op, top, head, branch):
    """The commits a push sends to a default branch; None when it sends none."""
    words, broad, deleting, tags, repo_opt = push_shape(op.args)
    if deleting:
        return None
    names = default_branches(top, ["origin"] + ([words[0]] if words and not repo_opt else []))
    refspecs = words if repo_opt else words[1:]
    subs = Subjects()
    if broad or any(ch in spec for spec in refspecs for ch in "*?["):
        for name in sorted(names):
            sha = resolve(top, "refs/heads/" + name)
            if sha:
                subs.add(name, sha)
    elif not refspecs:
        if tags or branch not in names:  # a bare push sends the current branch to its namesake; --tags alone sends only tags
            return None
        subs.add("HEAD", head)
    else:
        i = 0
        while i < len(refspecs):
            spec = refspecs[i]
            i += 1
            if spec == "tag" and i < len(refspecs):  # `push <remote> tag <name>` is refs/tags/<name>
                i += 1
                continue
            src, colon, dst = spec.lstrip("+").partition(":")
            if not src:
                continue  # `:branch` deletes it
            if not colon:
                dst = branch if src == "HEAD" else src
            if dst.startswith("refs/heads/"):
                dst = dst[len("refs/heads/"):]
            if dst in names:
                sha = resolve(top, src)
                if sha:
                    subs.add(src, sha)
                else:
                    subs.unplaced.append(src)
    return subs if subs.items or subs.unplaced else None


def subjects_of(op, top):
    """(the Subjects or None, the commit HEAD is at): None when the op merges nothing into anything that matters."""
    rc, out = sg.git(top, "rev-parse", "-q", "--verify", "HEAD^{commit}")
    head = out.strip()
    if rc != 0 or not sg.COMMIT.match(head):
        raise sg.Unread("HEAD of %s names no commit (a repository with no commits yet)" % top)
    branch = current_branch(top)
    if op.kind == "pr-merge":
        subs = Subjects()
        subs.add("HEAD", head)
        return subs, head
    if op.kind == "pull":
        return pull_subjects(op, top, head, branch, default_branches(top, ["origin"])), head
    return push_subjects(op, top, head, branch), head


# ── the records ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

def plural(n, noun):
    return "%d %s" % (n, noun if n == 1 else noun + "s")


def fmt_secs(n):
    n = int(n)
    if n < 60:
        return "%ds" % n
    if n < 3600:
        return "%dm%02ds" % (n // 60, n % 60)
    return "%dh%02dm" % (n // 3600, (n % 3600) // 60)


def fmt_tokens(n):
    return "~%d" % n if n < 1000 else "~%.1fk" % (n / 1000.0)


def summary_tokens():
    return TAIL_LINES * ROW_BYTES // BYTES_PER_TOKEN


def tokens_text(rows):
    """The token estimates, each labelled: a run in the developer's terminal costs none; an agent reading a summary tail, or the whole output."""
    full = (rows + TAIL_LINES) * ROW_BYTES // BYTES_PER_TOKEN
    return ("Tokens (estimates): no model tokens if you run it yourself in a terminal; %s if an agent runs it in the background and reads only a %d-line summary tail "
            "(%d lines x %d B / %d); up to %s if an agent reads all of it (%d rows + %d lines x %d B / %d)."
            % (fmt_tokens(summary_tokens()), TAIL_LINES, TAIL_LINES, ROW_BYTES, BYTES_PER_TOKEN, fmt_tokens(full), rows, TAIL_LINES, ROW_BYTES, BYTES_PER_TOKEN))


def owned_shape():
    """(the hooks' own path regex, compiled with anchors), or (None, None) when the shared file cannot be read."""
    owned = sg.hook_owned()
    return owned, (re.compile("^(?:%s)$" % owned) if owned else None)


def count_since(top, base, shas):
    """(commits, files) that came after `base` on the way to `shas`, the hooks' own records not counted; None when git cannot say."""
    rc, out = sg.git(top, "rev-list", "--count", *(list(shas) + ["^" + base]))
    if rc != 0 or not out.strip().isdigit():
        return None
    names, shape = set(), owned_shape()[1]
    for sha in shas:
        rc, listed = sg.git(top, "diff", "--name-only", "-z", base + "..." + sha)
        if rc != 0:
            return None
        names.update(n for n in listed.split("\0") if n and not (shape and shape.match(n)))
    return int(out.strip()), len(names)


def counted(top, base, shas):
    found = count_since(top, base, shas)
    if found is None:
        return "what changed since it could not be counted"
    return "%s and %s changed" % (plural(found[0], "commit"), plural(found[1], "file"))


def journeys_on_disk(top):
    """The journeys of test/use-cases/journeys, counted on disk."""
    try:
        return len([n for n in os.listdir(os.path.join(top, "test", "use-cases", "journeys")) if n.endswith(".sh")])
    except OSError:
        return 0


def mutants_on_disk(top):
    """The mutants of test/use-cases/mutants.list, counted on disk (a blank line and a # line are none)."""
    try:
        with open(os.path.join(top, "test", "use-cases", "mutants.list"), "r", errors="replace") as handle:
            return len([line for line in handle if line.strip() and not line.lstrip().startswith("#")])
    except OSError:
        return 0
def load_receipt(rdir, name, top):
    """(the receipt, None), or (None, the sentence for why there is none): missing, unreadable, or recorded for another checkout."""
    try:
        receipt = sg.read_object(os.path.join(rdir, name), "sweep receipt")
    except sg.Unread as exc:
        text = str(exc)
        if text.startswith("no sweep receipt"):
            return None, "there is no sweep receipt for this checkout yet"
        return None, "the sweep receipt is unreadable (%s)" % text
    owner = receipt.get("repo")
    if isinstance(owner, str) and os.path.realpath(owner) != os.path.realpath(top):
        return None, "the sweep receipt on file was recorded for another checkout (%s), not this one" % owner
    return receipt, None


def receipt_kind(receipt):
    """("proof", None) for a green full receipt of a clean tree that is full-equivalent and names a commit; ("green", None) for the same that is NOT full-equivalent (the run was
    green, but a suite has no cache record (its green could not be stored), so the gate takes no commit on its word); ("red", None); or ("partial", why it is none of those)."""
    sha = receipt.get("head_sha")
    if not isinstance(sha, str) or not sg.COMMIT.match(sha):
        return "partial", "the sweep receipt names no commit"
    try:
        red = sg.is_red(receipt)
    except sg.Unread:
        return "partial", "the sweep receipt has no usable exit code"
    if red:
        return "red", None
    kind = receipt.get("kind", "full")
    if kind != "full":
        return "partial", "the last sweep receipt is of kind %s, not a full run" % kind
    if receipt.get("tree_clean") is not True:
        return "partial", "the last sweep ran on a tree with uncommitted changes, so it proves no commit"
    return ("green", None) if receipt.get("full_equivalent") is False else ("proof", None)


def archived(rdir):
    """The names under receipts/full-green/ that are <head_sha>.json, newest first (the runner's own order: modification time), at most FULL_GREEN_KEEP of them."""
    folder = os.path.join(rdir, "full-green")
    try:
        names = [n for n in os.listdir(folder) if n.endswith(".json") and sg.COMMIT.match(n[:-5])]
        names.sort(key=lambda n: os.stat(os.path.join(folder, n)).st_mtime, reverse=True)
    except OSError:
        return []
    return ["full-green/" + n for n in names[:FULL_GREEN_KEEP]]


def finished(receipt):
    """finished_at when it is the runner's own UTC stamp (those sort as text), else "": a receipt with no usable time counts as the oldest."""
    stamp = receipt.get("finished_at")
    return stamp if isinstance(stamp, str) and STAMP.match(stamp) else ""


def green_sweeps(rdir, top, last):
    """[(receipt, "proof" or "green")], newest finished_at first, of every green full sweep of a clean tree on file for this checkout: last-sweep.json (`last`, already read),
    last-full-green.json and the receipts/full-green/ archive. The runner moves the anchor and writes the archive only for a sweep that is full-equivalent, so a green run in which a
    suite has no cache record (kind "green") lives in last-sweep.json alone and the anchor lags behind it by design: only all three together hold the last green run.
    Receipts of equal time keep that order, and one run found under two names counts once. A record that is missing, unreadable, red, partial or of another checkout is not one."""
    found, seen = [], set()
    for r in [last] + [load_receipt(rdir, name, top)[0] for name in ["last-full-green.json"] + archived(rdir)]:
        kind = receipt_kind(r)[0] if r is not None else None
        key = (r["head_sha"], finished(r)) if kind in ("proof", "green") else None
        if key is not None and key not in seen:
            seen.add(key)
            found.append((r, kind))
    return sorted(found, key=lambda f: finished(f[0]), reverse=True)


def covered(top, receipt, sha, owned):
    """Is `sha` the commit the receipt proves, or only the hooks' own journal and ledger records after it? Whatever git cannot say is not covered."""
    base = receipt["head_sha"]
    if sha == base:
        return True
    try:
        return sg.hooks_only_since(top, base, sha, owned)
    except sg.Unread:
        return False


def cost_use_cases(top, receipt):
    """The Cost line for the heimdall regime: what one run of the use-case runner covers (journeys and mutants), the wall clock of the last run from its receipt (or the typical one when
    none is on record, then what is on disk), and the token estimates."""
    if receipt:
        journeys, mutants = receipt["journeys"]["total"], receipt["mutants"]["total"]
        covers_ = "%s and %s" % (plural(journeys, "journey"), plural(mutants, "mutant"))
        took = "%s of machine time last run (from the receipt)" % fmt_secs(receipt["duration_s"])
    else:
        journeys, mutants = journeys_on_disk(top), mutants_on_disk(top)
        covers_ = "%s and %s on disk (test/use-cases)" % (plural(journeys, "journey"), plural(mutants, "mutant"))
        took = "no run on record here, so no measured wall clock (%s when it was last measured, %s)" % (TYPICAL_RUN, TYPICAL_ON)
    return "%s, %s. %s" % (covers_, took, tokens_text(journeys + mutants))


def use_case_record(top):
    """(the receipt, None) for a green use-case journey receipt that is genuinely this checkout's (the schema, a green run, a commit and tree as git says), else (None, why it is none)."""
    receipt, why = ucr.read(top)
    if receipt is None:
        return None, why
    problem = ucr.record_problem(top, receipt)
    return (None, problem) if problem else (receipt, None)


def proven_by(receipt, kind):
    """What the 'already proven' line names: the use-case run, or the full sweep."""
    if kind == "use-cases":
        return "the last use-case run (%s, %s, %s killed)" % (receipt["finished_at"], plural(receipt["journeys"]["total"], "journey"), plural(receipt["mutants"]["total"], "mutant"))
    suites = receipt.get("suites_total")
    count = ", %s" % plural(suites, "suite") if isinstance(suites, int) and not isinstance(suites, bool) else ""
    return "the last full sweep (%s%s)" % (receipt.get("finished_at", "time unknown"), count)


def assess_sweep(top, subs, head):
    """The finding for a repo in heimdall's own regime. A push stands on EITHER record the push gate takes -- a green use-case journey receipt (bash test/use-cases/run.sh) or a green full
    sweep -- so what is recommended is the first; the full sweep is a release's bar, said on the Release: line and nowhere else (operator decision 2026-11-22)."""
    home = os.environ.get("HEIMDALL_HOME", "")
    rdir = os.path.join(home or os.path.join(top, ".heimdall"), "receipts")
    owned = owned_shape()[0]
    last = load_receipt(rdir, "last-sweep.json", top)[0]
    uc, why_uc = use_case_record(top)
    records = green_sweeps(rdir, top, last) + ([(uc, "use-cases")] if uc is not None else [])
    records.sort(key=lambda f: finished(f[0]), reverse=True)  # newest first; records of equal time keep the order they were found in
    shas = subs.shas()
    scored = [(r, kind, [sha for sha in shas if not covered(top, r, sha, owned)]) for r, kind in records]  # (record, kind, what it leaves uncovered), newest first
    baseline = min(scored, key=lambda s: len(s[2]), default=None)  # what the Why measures from: the newest of the records that leave the fewest commits uncovered
    red = False  # a red last sweep at an ancestor of HEAD voids a full sweep's "proven" (the gate reads last-sweep.json); it never voids a use-case receipt: either record is enough for the gate
    if last is not None and receipt_kind(last)[0] == "red":
        try:
            red = sg.ancestor(top, last["head_sha"], head)
        except sg.Unread:
            red = False
    proof = min((s for s in scored if s[1] == "use-cases" or (s[1] == "proof" and not red)), key=lambda s: len(s[2]), default=None)  # what may say "proven": never a green sweep that is not full-equivalent
    unplaced = ("; %s cannot be placed in this checkout, so what it brings is not counted" % ", ".join(subs.unplaced)) if subs.unplaced else ""
    if proof is not None and not proof[2] and not subs.unplaced:
        return {"proven": True, "what": subs.describe(), "by": proven_by(proof[0], proof[1])}
    if baseline is not None:
        base, kind, left = baseline
        why = "%s since the last green %s (%s, %s)" % (counted(top, base["head_sha"], left or shas), "use-case run" if kind == "use-cases" else "full sweep",
                                                       base["head_sha"][:12], base.get("finished_at", "time unknown"))
        if kind == "green":
            why += ", which is " + NOT_FULL_EQUIVALENT
        if left:
            why += "; not covered: %s" % subs.describe(left)
        why += unplaced
    else:
        why = "no green record yet: %s%s" % (why_uc, unplaced)
    return {"proven": False, "run_noun": "use-case journey run", "why": why, "run": ucr.RUNNER, "release": RELEASE_NOTE,
            "where": "(in %s, on a clean, committed tree: a green full run writes .heimdall/receipts/%s for the commit it ran on, and the push gate takes that receipt in place of a full sweep)" % (top, ucr.NAME),
            "cost": cost_use_cases(top, uc)}
def declared_checks(facts):
    """(the declared checks, None) or (None, why the declaration cannot be used)."""
    if facts.state != "ok":
        return None, "it is %s" % {"absent": "absent", "irregular": "a link, a submodule or a directory", "oversized": "too large"}[facts.state]
    try:
        declared = json.loads(facts.declaration.decode("utf-8"))
    except (ValueError, RecursionError):
        return None, "it is not valid JSON"
    problem = rr.declaration_problem(declared)
    return (None, problem) if problem else (declared["checks"], None)


def read_checks_receipt(top):
    """(the receipt, None), or (None, why there is none that can be used)."""
    path = os.path.join(top, *rr.RECEIPT.split("/"))
    try:
        raw = rr.read_inside(top, rr.RECEIPT)
    except rr.Unsafe as exc:
        return None, "the receipt cannot be trusted: %s" % exc
    if raw is None:
        return None, "the declared checks have never been recorded in this checkout"
    try:
        receipt = json.loads(raw.decode("utf-8"))
    except (ValueError, RecursionError):
        return None, "the receipt at %s is not valid JSON" % path
    return (receipt, None) if isinstance(receipt, dict) else (None, "the receipt at %s is not a JSON object" % path)


def assess_checks(top, subs, checks, facts):
    """The finding for a repo that declares its own checks: its receipt must be green and current for the commit, and it attests ONE commit."""
    receipt, why = read_checks_receipt(top)
    if receipt is not None:
        ok, why = rr.verify_receipt(receipt, facts.head, facts.tree, facts.decl_sha256, checks)
        if ok:
            others = [sha for sha in subs.shas() if sha != receipt["head_sha"]]
            if not others and not subs.unplaced:
                return {"proven": True, "what": subs.describe(),
                        "by": "the repo-checks receipt (%s, %s)" % (receipt["finished_at"], plural(len(receipt["checks"]), "check"))}
            why = "the repo-checks receipt attests one commit (%s)" % receipt["head_sha"][:12]
            if others:
                why += ", and %s %s a different commit" % (subs.describe(others), "is" if len(others) == 1 else "are")
            if subs.unplaced:
                why += "; %s cannot be placed in this checkout" % ", ".join(subs.unplaced)
        base = receipt.get("head_sha")
        stamp = receipt.get("finished_at", "time unknown")
        if isinstance(base, str) and sg.COMMIT.match(base) and base != facts.head:
            why = "%s; %s since the last recorded run (%s, %s)" % (why, counted(top, base, subs.shas()), base[:12], stamp)
        else:
            why = "%s (recorded %s)" % (why, stamp)
    else:
        why = "no green record yet: " + why
    lead = plural(len(checks), "check")
    secs = dict((c["name"], c["secs"]) for c in receipt["checks"]) if receipt is not None and rr.shape_problem(receipt) is None else {}
    parts = ", ".join(("%s %s" % (c["name"], fmt_secs(secs[c["name"]]))) if c["name"] in secs else c["name"] for c in checks)
    if secs:
        took = "%s (%s), %s in all last time (from the receipt)" % (lead, parts, fmt_secs(sum(secs[c["name"]] for c in checks if c["name"] in secs)))
    else:
        took = "%s (%s); no run on record, so no measured time" % (lead, parts)
    rows = 2 * len(checks) + 2
    cost = ("%s. Tokens (estimates): no model tokens if you run it yourself in a terminal; %s if an agent runs it and reads only the runner's own lines "
            "(2 per check + 2, %d lines x %d B / %d); the checks' own output (the linter, the test runner) is not on record, so no upper bound can be given."
            % (took, fmt_tokens(rows * ROW_BYTES // BYTES_PER_TOKEN), rows, ROW_BYTES, BYTES_PER_TOKEN))
    return {"proven": False, "why": why, "run": "%s run --repo %s" % (os.path.join(PLUGIN, "bin", "heimdall-repo-checks"), top),
            "where": "(the receipt binds to one commit: run it on the tree you are about to land)", "cost": cost}


def assess_unmanaged(why):
    """The finding for a repo with no record hmd can read: lint plus the use-case suite."""
    return {"proven": False, "why": "no green record yet: %s" % why,
            "run": "lint plus the use-case suite: one scenario per user journey (%s)" % os.path.join(PLUGIN, "skills", "heimdall", "references", "use-case-tests.md"),
            "where": "(declare them in .heimdall/repo-checks.json to give the push gate a record to read)",
            "cost": "no run on record, so no measured time. Tokens (estimates): no model tokens if you run it yourself in a terminal; %s if an agent runs it in the "
                    "background and reads only a %d-line summary tail (%d lines x %d B / %d); the size of a whole run depends on the suite and is not on record."
                    % (fmt_tokens(summary_tokens()), TAIL_LINES, TAIL_LINES, ROW_BYTES, BYTES_PER_TOKEN)}


# ── the advice ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

def compose(op, found):
    """The hook JSON, on one line: systemMessage for the developer, additionalContext so the agent relays it. Never a permissionDecision."""
    lead = "hmd merge-time advice (%s)" % op.text
    noun = NOUN[op.kind]
    if found["proven"]:
        text = "%s: %s already proven green by %s; nothing to run before this %s." % (lead, found["what"], found["by"], noun)
    else:
        lines = ["%s: a %s before this %s is worth considering." % (lead, found.get("run_noun", "full test run"), noun), "Why: " + found["why"], "Run: " + found["run"]]
        if found.get("where"):
            lines.append("  " + found["where"])
        lines.append("Cost: " + found["cost"])
        if found.get("release"):
            lines.append("Release: " + found["release"])
        lines.append("Your call: run it now, or merge without it. This note shows only at the final merge (a push to the default branch, a pull request merge, a pull on it) and never blocks anything.")
        text = "\n".join(lines)
    context = ("hmd merge-time advice: a recommendation from the hmd hook, not a block; the developer decides. Tell the developer about it in your next message, in a line "
               "or two (why, what to run, what it costs), and let them choose between running it now and going ahead without it. Do not start the full test run yourself "
               "unless the developer asks for it. The advice:\n" + text)
    return json.dumps({"systemMessage": text, "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": context}}, ensure_ascii=True)


def judge(op):
    """The hook JSON for this op, or None when it is a merge into nothing that matters. Raises sg.Unread when the repository cannot be reached."""
    top = locate(op)
    subs, head = subjects_of(op, top)
    if subs is None:
        return None
    gitdir = os.path.realpath(sg.git_out(top, "rev-parse", "--absolute-git-dir").strip())
    cls = pt.commit_class(pt.Repo(gitdir, os.path.realpath(top)), head)
    if cls == "sweep":
        return compose(op, assess_sweep(top, subs, head))
    if cls == "repo-checks":
        try:
            facts = rr.facts(top)
        except rr.Unreadable as exc:
            return compose(op, assess_unmanaged("the repo-checks declaration cannot be read (%s)" % exc))
        checks, problem = declared_checks(facts)
        if checks is None:
            return compose(op, assess_unmanaged("this repo's declaration of its own checks (%s) cannot be used (%s)" % (rr.DECLARATION, problem)))
        return compose(op, assess_checks(top, subs, checks, facts))
    return compose(op, assess_unmanaged("this checkout has no hmd record of a test run (no sweep receipt, no %s)" % rr.DECLARATION))


def verdict(text, cwd):
    """(the hook JSON or None, the reason it could not be judged or None): a merge it read wins over something it could not."""
    if not MENTION.search(text):
        return None, None
    unread, ops = [], []
    find_ops(text, cwd, 0, unread, ops)
    for op in ops:
        try:
            found = judge(op)
        except sg.Unread as exc:
            unread.append(str(exc))
            continue
        if found:
            return found, None
    return None, (unread[0] if unread else None)


def main():
    cwd = (sys.argv[1] if len(sys.argv) > 1 else "") or os.getcwd()
    found = unread = None
    try:
        kg.arm(TIMEOUT_S)
        found, unread = verdict(sys.stdin.buffer.read().decode("utf-8", "replace"), cwd)
    except kg.GuardTimeout:
        unread = U_TIMEOUT % TIMEOUT_S
    except Exception as exc:  # a command or a record this could not read is one it cannot advise on: say so, and let it through (a nudge, not a gate)
        unread = U_ERROR % type(exc).__name__
    kg.arm(0)
    if found:
        sys.stdout.write(found + "\n")
        return 3
    if unread:
        sys.stdout.write(unread + "\n")
        return 4
    sys.stdout.write("ok\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
