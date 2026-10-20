#!/usr/bin/env python3
r"""hmd_sweep_guard -- would this Bash command start a FULL sweep that the records on disk already answer?

A full run of test/run-all.sh takes 45-60 minutes. CLAUDE.md ("When the full gate runs", "Release convergence") says when one is worth it: once,
on the frozen tree, never after a red one (that is `--failed`), never at a HEAD already proven green, never beside another. Prose did not hold:
sweeps were started in all three situations. bin/heimdall-precheck-bash therefore asks this file, for a command that mentions run-all, whether the
command is a full sweep the repo's own records already answer. It reads the command the way a shell does by reusing bin/lib/hmd_kill_guard.py's
lexer and wrapper handling (quotes and escapes, env / time / timeout / nohup / caffeinate / sudo / xargs, ; && || | & and newlines, subshells,
substitutions, if / for / while bodies, sh -c, eval, source, heredocs fed to a shell), and follows `cd`, so a relative script path finds its repo.
Text that only MENTIONS run-all.sh (echo, grep, cat, git add, a commit message, a script written to disk) is no run, and `bash -n` is none either.

  a FULL sweep  run-all.sh with none of --failed, --since-green, --filter <non-empty regex>, --dry-run, -h, --help
  denied        the first that holds is the reason, in this order
     overlap    receipts/sweep.lock names a pid and that process is alive                           a sweep is already running (pid N)
     red        receipts/last-sweep.json is red (exit_code is not 0, or kind is aborted) and its head_sha is HEAD or an ancestor of HEAD
                                                                                                    last sweep was red at <sha>; fix, commit, then: bash test/run-all.sh --failed
     green      that receipt is a green, clean-tree, full-equivalent sweep of kind full that already covers HEAD -- head_sha is HEAD, or only
                commits that touch nothing but the hooks' own journal and ledger records came after it (the push gate calls such a receipt
                fresh too) -- and the work tree holds no uncommitted code (run-all.sh's own tree_clean predicate)
                                                                                                    already proven green at HEAD; nothing to re-test
  allowed       everything else: --failed, --since-green, --filter, --dry-run, help, single suites; a green receipt of an older HEAD; a dirty tree; a
                red receipt of other history; an incremental receipt, or one composed from the cache that is not full-equivalent; and --cold (or
                HMD_COLD=1) while the cache is cold anyway -- no suite-cache entry carries the salt of HEAD, so even a plain sweep runs every suite --
                which also still adds something to a green receipt composed from the cache (an x.y.0 ship wants a cold one)
  the repo      the one the SCRIPT belongs to (run-all.sh takes its repo from its own location: two levels above it), not the payload's cwd; its
                receipts are in $HEIMDALL_HOME/receipts or <repo>/.heimdall/receipts, as the runner works them out (HEIMDALL_HOME in the hook's
                environment, or as an inline assignment on the command). A receipt recorded for another checkout is not this tree's
  unread        a command that mentions run-all and that this cannot judge: a missing, garbled or foreign receipt, a git failure, a script that does
                not exist, a path or option held in a variable, a cd it cannot follow, an unbalanced quote, shell strings nested more than 8 deep,
                an internal error, a timeout. Exit 4: the hook warns on stderr and ALLOWS. This is a COST guard, not a security gate (the CI
                waste guard's and the disk floor's convention), so what it could not read or find is never a deny. A form it DID read wins over
                what it could not
  unseen        what no reading sees: a command name or path built at run time, a script on disk that starts a sweep, a pid that was recycled
                after a sweep was killed. Best effort, not a security boundary

The hook never runs what the session's repo ships: git is asked about the repo named, and the salt comes from the PLUGIN's closure engine
(bin/heimdall-suite-closure beside this lib), which reads that repo's committed files.

Protocol: the command text on stdin, the directory the shell is in as the one argument; stdout `ok` and exit 0 = nothing found; one reason line and
exit 3 = deny; one reason line and exit 4 = could not tell (allow, warn). Anything else (a crash, another status) is the hook's "the guard itself
failed" warning, also an allow. HMD_SWEEP_GUARD_TIMEOUT_S (default 8) bounds the run. HMD_SWEEP_ALLOW=1 is read by the hook, bin/heimdall-precheck-bash,
which then never starts this file.
"""
import json
import os
import re
import stat
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hmd_kill_guard as kg  # noqa: E402  (the shell reader: lex, unwrap, opaque, the run-time budget)

SCRIPT = "run-all.sh"
ENGINE = os.path.normpath(os.path.join(HERE, os.pardir, "heimdall-suite-closure"))
HOOK_OWNED = os.path.join(HERE, "hook-owned-path.sh")  # the one definition of the paths the repo's own hooks write
MAX_DEPTH = kg.MAX_DEPTH  # shell strings (sh -c, eval, heredocs) read inside shell strings
try:
    TIMEOUT_S = float(os.environ.get("HMD_SWEEP_GUARD_TIMEOUT_S", "8"))
except ValueError:
    TIMEOUT_S = 8.0

VALUE_OPTS = frozenset(("--jobs", "--timeout", "--min", "--filter"))  # run-all.sh's options that take the next word
NO_SWEEP = frozenset(("--dry-run", "-h", "--help"))  # it stops before any suite, receipt or lock
PARTIAL = frozenset(("--failed", "--since-green"))
COMMIT = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
SALT = re.compile(r"^[0-9a-f]{64}$")
MAX_FILE = 8 << 20  # a receipt is about 300 KB
MAX_ENTRY = 16384  # a suite-cache entry is never larger (bin/lib/suite-cache.sh)

# Reasons are fixed one-liners without quotes or backslashes: the hook puts them into a JSON deny.
R_BUSY = "a sweep is already running (pid %d)"
R_RED = "last sweep was red at %s; fix, commit, then: bash test/run-all.sh --failed"
R_GREEN = "already proven green at HEAD; nothing to re-test"
U_DEEP = "shell strings nested more than %d deep, so the guard cannot read the command" % MAX_DEPTH
U_TIMEOUT = "reading the command and the sweep records took longer than %gs (HMD_SWEEP_GUARD_TIMEOUT_S), so the guard gave up"
U_ERROR = "an internal error (%s), so the guard cannot judge the command"
U_VAR = "the path of run-all.sh is held in a variable, so the guard cannot tell which repository it sweeps"
U_ARGS = "an option of run-all.sh is held in a variable, so the guard cannot tell whether this is a full sweep"
U_CWD = "the directory the command runs in cannot be told (a cd to a variable, or cd -), so the guard cannot find run-all.sh"


class Unread(Exception):
    """Something this could not tell. The hook warns on stderr and ALLOWS: a cost guard, not a security gate."""


class Run(object):
    """One simple command that runs run-all.sh: the script word, the words after it, the NAME=value words in front of it, the shell's directory."""
    __slots__ = ("script", "opts", "env", "cwd")

    def __init__(self, script, opts, env, cwd):
        self.script, self.opts, self.env, self.cwd = script, opts, env, cwd


# ── reading the command ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

def inline_env(words, program):
    """name -> value of the NAME=value words in front of `program` (an env wrapper's too): HEIMDALL_HOME and HMD_COLD change what the runner does."""
    env = {}
    for w in kg.plain(words):
        if w is program:
            break
        if not w.dynamic and kg.ASSIGN.match(w.text):
            name, _, value = w.text.partition("=")
            env[name.rstrip("+")] = value
    return env


def chdir(cwd, rest):
    """Where a cd leaves the shell; None when that cannot be told (a variable, `cd -`, a relative path from an unknown place)."""
    words = [w for w in rest if w.dynamic or w.text not in ("-L", "-P", "-e", "-@", "--")]
    if not words:
        return os.path.expanduser("~")
    target = words[0]
    if target.dynamic or target.text == "-":
        return None
    path = os.path.expanduser(target.text)
    if os.path.isabs(path):
        return os.path.abspath(path)
    return os.path.abspath(os.path.join(cwd, path)) if cwd else None


def read_shell(rest):
    """The words after a shell's name: (the -c string word or None, the script word or None, the words after the script). `-n` reads and runs nothing."""
    k, noexec = 0, False
    while k < len(rest) and not rest[k].dynamic:
        t = rest[k].text
        if t == "--":
            k += 1
            break
        if not t.startswith(("-", "+")) or t in ("-", "+"):
            break
        if t in ("-o", "+o", "-O", "+O"):
            k += 2
        elif t.startswith("-") and not t.startswith("--") and "c" in t[1:]:
            return (rest[k + 1] if k + 1 < len(rest) else None), None, []
        else:
            noexec = noexec or (t.startswith("-") and not t.startswith("--") and "n" in t[1:])
            k += 1
    if noexec or k >= len(rest):
        return None, None, []
    return None, rest[k], rest[k + 1:]


def visit(cmd, cwd, depth, unread, runs):
    """Read one simple command: a cd moves the shell, a command that runs run-all.sh is a run. Returns the shell's directory afterwards."""
    args, _ = kg.unwrap(cmd.words)
    if not args:
        return cwd
    head, rest = args[0], args[1:]
    base = os.path.basename(head.text).lower()
    if head.dynamic and base != SCRIPT:
        return cwd
    if base in ("cd", "pushd"):
        return chdir(cwd, rest)
    if base == SCRIPT:
        runs.append(Run(head, rest, inline_env(cmd.words, head), cwd))
    elif base in kg.SHELLS or base in ("source", "."):
        if base in kg.SHELLS:
            string, script, opts = read_shell(rest)
        else:
            string, script, opts = None, (rest[0] if rest else None), rest[1:]
        sources = list(cmd.bodies)
        if string is not None and not kg.opaque(string):
            sources.append(string.text)
        for source in sources:
            find_runs(source, cwd, depth + 1, unread, runs)
        if script is not None and os.path.basename(script.text).lower() == SCRIPT:
            runs.append(Run(script, opts, inline_env(cmd.words, head), cwd))
    elif base == "eval" and not (rest and kg.opaque(rest[0])):
        find_runs(" ".join(w.text for w in rest), cwd, depth + 1, unread, runs)
    return cwd


def find_runs(text, cwd, depth, unread, runs):
    """Append every run of run-all.sh in `text` to `runs`; whatever could not be read is appended to `unread`."""
    if depth > MAX_DEPTH:
        unread.append(U_DEEP)
        return
    cmds, unparsed = kg.lex(text)
    if unparsed:
        unread.append(unparsed)
    for cmd in cmds:
        cwd = visit(cmd, cwd, depth, unread, runs)


def classify(run):
    """None when the runner will not do a whole sweep (a partial run, a dry run, help); otherwise whether this one is cold (--cold, or HMD_COLD=1)."""
    flags, filt, k, opts = set(), None, 0, run.opts
    while k < len(opts):
        w = opts[k]
        k += 1
        if w.dynamic:
            raise Unread(U_ARGS)
        if w.text in VALUE_OPTS:
            if w.text == "--filter":
                filt = opts[k] if k < len(opts) else None
            k += 1
        else:
            flags.add(w.text)
    if flags & NO_SWEEP or flags & PARTIAL:
        return None
    if filt is not None and (filt.dynamic or filt.text):  # an empty --filter filters nothing: the runner does a full sweep
        return None
    return "--cold" in flags or run.env.get("HMD_COLD", os.environ.get("HMD_COLD", "")) == "1"


# ── reading the records ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

def locate(run):
    """(repo, receipts directory) as the runner works them out: its repo is two levels above the script, its receipts are in $HEIMDALL_HOME or <repo>/.heimdall."""
    if run.script.dynamic:
        raise Unread(U_VAR)
    path = os.path.expanduser(run.script.text)
    if not os.path.isabs(path):
        if not run.cwd:
            raise Unread(U_CWD)
        path = os.path.join(run.cwd, path)
    path = os.path.abspath(path)
    if not os.path.isfile(path):
        raise Unread("%s does not exist, so there is no sweep to compare with the records" % path)
    repo = os.path.dirname(os.path.dirname(path))
    home = run.env["HEIMDALL_HOME"] if "HEIMDALL_HOME" in run.env else os.environ.get("HEIMDALL_HOME", "")
    return repo, os.path.join(home or os.path.join(repo, ".heimdall"), "receipts")


def clean_env():
    """The environment without git's own variables (GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, ...): the repository asked about is the one named."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env["GIT_OPTIONAL_LOCKS"] = "0"
    return env


def git(repo, *args):
    """(exit status, stdout) of a read-only git command in `repo`."""
    try:
        p = subprocess.run(["git", "-C", repo, "-c", "core.fsmonitor=false"] + list(args), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, env=clean_env())
    except OSError as exc:
        raise Unread("git cannot be run (%s)" % exc.strerror)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def git_out(repo, *args):
    rc, out = git(repo, *args)
    if rc != 0:
        raise Unread("git %s failed in %s (exit %d)" % (args[0], repo, rc))
    return out


def read_object(path, what):
    """The JSON object in a regular file of a sane size, or Unread saying what is wrong with it."""
    try:
        st = os.stat(path)
    except OSError:
        raise Unread("no %s at %s (nothing to compare this sweep with)" % (what, path))
    if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_FILE:
        raise Unread("the %s at %s is not a regular file of a sane size" % (what, path))
    try:
        with open(path, "rb") as f:
            data = json.loads(f.read().decode("utf-8", "replace"))
    except (OSError, ValueError):
        raise Unread("the %s at %s is not valid JSON" % (what, path))
    if not isinstance(data, dict):
        raise Unread("the %s at %s is not a JSON object" % (what, path))
    return data


def running(rdir):
    """The pid in receipts/sweep.lock when that process is alive: the runner writes it once it holds the lock and blanks it when it ends."""
    try:
        with open(os.path.join(rdir, "sweep.lock"), "rb") as f:
            text = f.read(4096).decode("utf-8", "replace")
    except OSError:
        return None
    m = re.search(r"^pid=([0-9]{1,9})[ \t]*$", text, re.M)
    pid = int(m.group(1)) if m else 0
    if pid <= 1:
        return None
    try:
        os.kill(pid, 0)
    except PermissionError:
        return pid  # alive, another user's
    except OSError:
        return None
    return pid


def hook_owned():
    """The path shapes the repo's own hooks write (the regex run-all.sh and the push gate share), or None when it cannot be read."""
    try:
        with open(HOOK_OWNED, "r") as f:
            m = re.search(r"^HMD_HOOK_OWNED_PATH_RE='([^']+)'", f.read(), re.M)
        if not m:
            return None
        re.compile(m.group(1))
        return m.group(1)
    except (OSError, re.error):
        return None


def is_red(receipt):
    if receipt.get("kind") == "aborted":
        return True
    code = receipt.get("exit_code")
    if isinstance(code, bool) or not isinstance(code, int):
        raise Unread("the sweep receipt has no usable exit_code (a number), so it cannot be called red or green")
    return code != 0


def ancestor(repo, older, newer):
    """Is commit `older` the same as, or an ancestor of, `newer`? (git merge-base --is-ancestor: 0 yes, 1 no, anything else is git failing.)"""
    rc, _ = git(repo, "merge-base", "--is-ancestor", older, newer)
    if rc not in (0, 1):
        raise Unread("git could not compare the receipt's commit %s with %s in %s (exit %d)" % (older[:12], newer[:12], repo, rc))
    return rc == 0


def hooks_only_since(repo, sha, head, owned):
    """Did only the hooks' own journal and ledger records change between the receipt's commit and HEAD?"""
    if not owned or not ancestor(repo, sha, head):
        return False
    shape = re.compile("^(?:%s)$" % owned)
    return all(shape.match(name) for name in git_out(repo, "diff", "--name-only", "-z", sha, head).split("\0") if name)


def dirty(repo, owned):
    """Does the work tree hold uncommitted code? run-all.sh's own predicate (its receipt's tree_clean): a tracked change counts, so does an untracked file,
    except the hooks' own records and the receipts directory itself."""
    ignored = [re.compile(r"^\?\? \.heimdall/(receipts/)?$")]
    if owned:
        ignored.append(re.compile(r"^(?:\?\?|.M|M.|A.|.A) (?:%s)$" % owned))
    out = git_out(repo, "status", "--porcelain=v1", "--no-renames")
    return any(line and not any(p.match(line) for p in ignored) for line in out.splitlines())


def covers_head(repo, receipt, sha, cold):
    """Is this a green full sweep that already proves HEAD as it stands? (A --cold run still adds something to a receipt composed from the cache.)"""
    cache = receipt.get("cache")
    if receipt.get("kind", "full") != "full" or receipt.get("tree_clean") is not True or receipt.get("full_equivalent") is False:
        return False
    if cold and isinstance(cache, dict) and cache.get("cold") is False:
        return False
    head = git_out(repo, "rev-parse", "HEAD").strip()
    owned = hook_owned()
    if sha != head and not hooks_only_since(repo, sha, head, owned):
        return False
    return not dirty(repo, owned)


def cache_is_cold(repo, rdir):
    """True when no suite-cache entry carries the salt of HEAD, so even a plain sweep runs every suite and --cold asks for nothing more."""
    try:
        p = subprocess.run([ENGINE, "salt", "--repo", repo, "--rev", "HEAD"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, env=clean_env())
    except OSError as exc:
        raise Unread("the closure engine (%s) cannot be run: %s, so the salt of HEAD is unknown" % (ENGINE, exc.strerror))
    salt = p.stdout.decode("utf-8", "replace").strip()
    if p.returncode != 0 or not SALT.match(salt):
        raise Unread("the closure engine printed no salt for HEAD (exit %d), so it cannot tell whether the cache is cold" % p.returncode)
    cdir = os.path.join(rdir, "suite-cache")
    try:
        names = os.listdir(cdir)
    except OSError:
        return True  # nothing cached: the next sweep is cold by itself
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(cdir, name), "rb") as f:
                entry = json.loads(f.read(MAX_ENTRY).decode("utf-8", "replace"))
        except (OSError, ValueError):
            continue
        if isinstance(entry, dict) and entry.get("salt") == salt:
            return False
    return True


def judge(run):
    """The reason to deny this run, or None. Raises Unread when the records cannot be read."""
    cold = classify(run)
    if cold is None:
        return None
    repo, rdir = locate(run)
    pid = running(rdir)
    if pid:
        return R_BUSY % pid
    receipt = read_object(os.path.join(rdir, "last-sweep.json"), "sweep receipt")
    sha = receipt.get("head_sha")
    if not isinstance(sha, str) or not COMMIT.match(sha):
        raise Unread("the sweep receipt names no commit (head_sha), so it cannot be compared with HEAD")
    top = git_out(repo, "rev-parse", "--show-toplevel").strip()
    owner = receipt.get("repo")
    if isinstance(owner, str) and os.path.realpath(owner) != os.path.realpath(top):
        raise Unread("the sweep receipt was recorded for another checkout (%s), not for %s" % (owner, top))
    why = None
    if is_red(receipt):
        if ancestor(repo, sha, "HEAD"):
            why = R_RED % sha[:12]
    elif covers_head(repo, receipt, sha, cold):
        why = R_GREEN
    if why and cold and cache_is_cold(repo, rdir):
        return None
    return why


def verdict(text, cwd):
    """(the reason to deny or None, the reason it could not be judged or None): something found wins over something not read."""
    unread, runs = [], []
    find_runs(text, cwd, 0, unread, runs)
    for run in runs:
        try:
            why = judge(run)
        except Unread as exc:
            unread.append(str(exc))
            continue
        if why:
            return why, None
    return None, (unread[0] if unread else None)


def main():
    cwd = (sys.argv[1] if len(sys.argv) > 1 else "") or os.getcwd()
    why = unread = None
    try:
        kg.arm(TIMEOUT_S)
        why, unread = verdict(sys.stdin.buffer.read().decode("utf-8", "replace"), cwd)
    except kg.GuardTimeout:
        unread = U_TIMEOUT % TIMEOUT_S
    except Exception as exc:  # a command or a record this could not read is one it cannot judge: say so, and let it through (a cost guard, not a gate)
        unread = U_ERROR % type(exc).__name__
    kg.arm(0)
    if why:
        sys.stdout.write(why + "\n")
        return 3
    if unread:
        sys.stdout.write(unread + "\n")
        return 4
    sys.stdout.write("ok\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
