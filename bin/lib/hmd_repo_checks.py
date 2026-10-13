#!/usr/bin/env python3
r"""heimdall-repo-checks -- a repository's OWN checks, run and recorded, so the push gate can pass a push on that record.

WHY. The PreToolUse push gate (bin/heimdall-precheck-bash) used to demand heimdall's sweep receipt of EVERY repository it was asked to
push, so a repository with six gates of its own (the site) was blocked for lacking a receipt that only heimdall's own test/run-all.sh
can write. A repository now declares its checks here and records a green run; the gate passes its push on that record (`status` below
is what the hook calls) and runs none of heimdall's sweep rules for it.

DECLARATION  <repo>/.heimdall/repo-checks.json  (tracked AND committed: the commit is what is read, never the work tree)
               {"schema":1,"checks":[{"name":"integrity","cmd":"python3 gates/site-integrity.py"}, ...]}
             name: unique, non-empty. cmd: a shell command, run with `bash -c` from the repository root.
RECEIPT      <repo>/.heimdall/receipts/repo-checks.json  (ignored build output; written by `run`, atomically)
               schema, head_sha, tree_sha, decl_sha256, dirty, exit_code, finished_at, checks[{name, cmd, exit_code, secs}]
             Its fields, their types and formats are defined ONCE, in bin/lib/hmd_repo_receipt.py, which `run` builds the receipt
             with and `status` verifies it against; test/heimdall-push-gate-per-repo.test.sh walks that definition.

Usage:
  heimdall-repo-checks run    [--repo PATH]   run every declared check, in order, from the repo root, one after the other even when
                                              one fails; record each check's exit code and seconds
  heimdall-repo-checks status [--repo PATH] [--pushes IDS]
                                              is the receipt green AND current? prints one verdict line
  heimdall-repo-checks -h | --help
  --repo PATH   any path inside the repository (default: the cwd); the toplevel is resolved with git
  --git-dir PATH  the git directory the push gate resolved TOGETHER with that work tree (--repo then names the work tree root): the two must name
                each other from both ends, and every git call runs with them pinned, so nothing is rediscovered from a path. A pair that does not
                match is refused (exit 2); the receipt is read inside that work tree
  --pushes IDS  what the push gate passes: the commits the push names as its sources (full object ids, comma separated; - when no commit
                travels; ? when they cannot be listed). Each must be the receipt's commit. Without it `status` only asks whether the
                receipt is green and current for HEAD.

GREEN AND CURRENT, all of it (anything less is NOT GREEN, and the push gate blocks). It is judged against the COMMIT (HEAD), not the
work tree: an uncommitted edit changes nothing about what a push carries.
  1. a receipt exists, is valid JSON, and has exactly the schema's fields, each of the right type and format
  2. head_sha is HEAD now (a commit after the run makes it STALE)
  3. tree_sha is the tree of that HEAD, recomputed now
  4. decl_sha256 is the sha256 of repo-checks.json as committed at HEAD, recomputed now: the receipt is for THESE checks, byte for byte
  5. dirty is false: no tracked file had uncommitted changes before or after the run, and the declaration on disk was the committed one
     (untracked files are not changes). A receipt that cannot prove a clean tree never counts.
  6. every recorded check exited 0 and exit_code is 0
  7. the recorded checks (name and cmd, in order) are the declared ones: a receipt listing fewer or other checks never counts
  8. (with --pushes) every commit the push names as a source IS head_sha: a receipt attests ONE commit, so another branch, HEAD~1:main, a
     sha, several refspecs naming other commits, --all, --mirror, --tags, a wildcard, or a list that is empty, malformed or `?` never counts

A COOPERATING-AGENT CONTROL, NOT A SECURITY BOUNDARY. head_sha + tree_sha + decl_sha256 tie a receipt to the commit, the content and the
check list it was recorded for, and the gate recomputes all three, so a receipt copied from another commit or checkout, left over from
an older declaration, or written by hand without them is refused. But the receipt is a plain local file, exactly like heimdall's own
.heimdall/receipts/last-sweep.json: anyone who can write it can also write all three values correctly, or edit the declaration. It
catches the stale, the mismatched, the copied and the hand-edited-by-accident; it does not stop a local adversary, and the native hook
of the repository and CI stay the backstop.

EXIT  run: 0 every check green and the receipt written | 1 a check failed (the red receipt is still written) | 2 refused
      status: 0 green and current | 1 not | 2 refused
      refused (2): HEAD carries no (or an irregular) .heimdall/repo-checks.json, an invalid declaration, not a git repository, a bad
      argument, or the receipt cannot be written. `run` on a dirty tree exits 0 and warns: the checks passed, but the receipt it wrote
      will not satisfy the gate until the changes are committed and the checks run again.

NO SECRETS. No flag takes a token; the environment is never printed or recorded (the checks inherit it unchanged); the receipt holds
names, commands (they are in the tracked declaration), exit codes and seconds, never output.

Python 3.7+, standard library only.
"""
import json
import os
import stat
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hmd_repo_receipt as rr  # noqa: E402  (the one definition of the receipt)

RUNNER = os.path.join(os.path.dirname(HERE), "heimdall-repo-checks")
PINNED = {}   # {GIT_DIR, GIT_WORK_TREE} once `--git-dir` hands over the pair the push gate resolved: every git call below runs with it


def genv():
    return rr.git_env(PINNED)


def refuse(message):
    sys.stderr.write("heimdall-repo-checks: %s\n" % message)
    sys.exit(2)


def not_green(reason, top, run_hint=True):
    """The one verdict line (stdout), ending with the command that turns it green unless re-running the checks is not the remedy."""
    sys.stdout.write("repo-checks: NOT GREEN - %s%s\n" % (reason, ". Run: %s run --repo %s" % (RUNNER, top) if run_hint else ""))
    sys.exit(1)


def top_of(repo_arg, gitdir=None):
    """The work tree root. With `--git-dir` (the pair the push gate resolved) nothing is discovered: the two must name each other from both ends,
    and from then on every git call runs with GIT_DIR and GIT_WORK_TREE pinned to them."""
    if gitdir is None:
        got = rr.run_git(["rev-parse", "--show-toplevel"], repo_arg, rr.git_env({}))
        if got is None or got[0] != 0 or not got[1].strip():
            refuse("not a git repository: %s" % repo_arg)
        return got[1].strip()
    top, gitdir = os.path.realpath(repo_arg), os.path.realpath(gitdir)
    got = rr.run_git(["rev-parse", "--absolute-git-dir", "--show-toplevel"], top, rr.git_env({})) if os.path.isdir(top) else None
    lines = got[1].split("\n") if got is not None and got[0] == 0 else []
    if len(lines) < 2 or os.path.realpath(lines[0]) != gitdir or os.path.realpath(lines[1]) != top:
        refuse("%s and %s do not belong to each other (git, started in the work tree, names another repository), so no receipt is read for this "
               "pair" % (repo_arg, gitdir))
    PINNED.update({"GIT_DIR": gitdir, "GIT_WORK_TREE": top})
    return top


def parse_declaration(data):
    """(the parsed declaration, None) or (None, why not)."""
    try:
        obj = json.loads(data.decode("utf-8"))
    except (ValueError, RecursionError):
        return None, "it is not valid JSON"
    problem = rr.declaration_problem(obj)
    return (None, problem) if problem else (obj, None)


def tree_dirty(top):
    """True when a tracked file has uncommitted changes, or when that cannot be read (what cannot be proven clean is not clean)."""
    got = rr.run_git(["status", "--porcelain", "--untracked-files=no"], top, genv())
    return got is None or got[0] != 0 or got[1].strip() != ""


def read_declaration_on_disk(top):
    try:
        return rr.read_inside(top, rr.DECLARATION)
    except rr.Unsafe as exc:
        refuse("cannot read the declaration on disk: %s" % exc)


def head_now(top):
    got = rr.run_git(["rev-parse", "-q", "--verify", "HEAD^{commit}"], top, genv())
    return got[1].strip() if got is not None and got[0] == 0 else ""


def prepare_receipt_dir(top):
    """The receipts directory inside the repository, created when missing, and REFUSED when any part of it is a link: a receipt written through a link
    would land outside the repository (and the gate would be asked to trust it from there)."""
    cur = top
    for part in rr.RECEIPT.split("/")[:-1]:
        cur = os.path.join(cur, part)
        try:
            info = os.lstat(cur)
        except FileNotFoundError:
            try:
                os.mkdir(cur)
            except OSError as exc:
                refuse("cannot create %s: %s" % (cur, exc))
            continue
        except OSError as exc:
            refuse("cannot inspect %s: %s" % (cur, exc))
        if not stat.S_ISDIR(info.st_mode):
            refuse("%s is a link, or not a directory: a receipt is never written through one (remove it)" % cur)
    return cur


def write_receipt(receipt, top):
    """Atomically: a temp file beside it, then a rename. A failed write leaves no half receipt behind."""
    folder = prepare_receipt_dir(top)
    path = os.path.join(folder, os.path.basename(rr.RECEIPT))
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(prefix=".repo-checks.", dir=folder)
        with os.fdopen(fd, "w") as fh:
            json.dump(receipt, fh, indent=2)
            fh.write("\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
        tmp = None
    except OSError as exc:
        refuse("cannot write %s: %s" % (path, exc))
    finally:
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError as exc:
                sys.stderr.write("heimdall-repo-checks: could not remove the temp file %s: %s\n" % (tmp, exc))


def cmd_run(top):
    try:
        facts = rr.facts(top, PINNED)
    except rr.Unreadable as exc:
        refuse(str(exc))
    disk = read_declaration_on_disk(top)
    source = disk if disk is not None else facts.declaration
    if source is None:
        refuse("%s declares no checks of its own: neither its work tree nor HEAD has %s. Declare them "
               "({\"schema\":1,\"checks\":[{\"name\":\"...\",\"cmd\":\"...\"}]}) and commit the file." % (top, rr.DECLARATION))
    declared, problem = parse_declaration(source)
    if problem:
        refuse("%s is not a valid declaration (%s): want {\"schema\":1,\"checks\":[{\"name\":\"...\",\"cmd\":\"...\"}, ...]} with at least "
               "one check, each with a non-empty name (unique) and cmd" % (rr.DECLARATION, problem))
    committed = facts.declaration
    # what the receipt attests is the COMMITTED declaration; running another one (or any with uncommitted changes around) is recorded dirty
    dirty = tree_dirty(top) or disk != committed
    decl_sha = rr.sha256_hex(committed if committed is not None else source)
    checks = declared["checks"]
    prepare_receipt_dir(top)    # refused up front when a link stands where the receipt goes: the checks are not run for a receipt that cannot be written
    sys.stderr.write("heimdall-repo-checks: running %d check(s) of %s at %s\n" % (len(checks), top, facts.head[:12]))
    results, failed = [], 0
    for i, check in enumerate(checks, 1):
        sys.stderr.write("== [%d/%d] %s\n" % (i, len(checks), check["name"]))
        sys.stderr.flush()
        started = time.monotonic()
        try:
            code = subprocess.run(["bash", "-c", check["cmd"]], cwd=top, stdin=subprocess.DEVNULL).returncode
        except (OSError, ValueError) as exc:
            sys.stderr.write("heimdall-repo-checks: cannot run %s: %s\n" % (check["name"], exc))
            code = 127
        secs = int(time.monotonic() - started)
        results.append({"name": check["name"], "cmd": check["cmd"], "exit_code": code, "secs": secs})
        if code == 0:
            sys.stderr.write("   PASS %s (%ds)\n" % (check["name"], secs))
        else:
            sys.stderr.write("   FAIL %s (exit %d, %ds)\n" % (check["name"], code, secs))
            failed += 1
    if tree_dirty(top):
        dirty = True
    if read_declaration_on_disk(top) != disk:
        dirty = True
        sys.stderr.write("heimdall-repo-checks: a check rewrote %s while it ran, so the receipt does not describe the declared checks\n" % rr.DECLARATION)
    if head_now(top) != facts.head:
        sys.stderr.write("heimdall-repo-checks: HEAD moved while the checks ran; the receipt describes %s, so it is stale already\n" % facts.head[:12])
    try:
        receipt = rr.build_receipt(facts.head, facts.tree, decl_sha, dirty, 1 if failed else 0,
                                   time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), results)
    except ValueError as exc:
        refuse("cannot build a valid receipt: %s" % exc)
    path = os.path.join(top, *rr.RECEIPT.split("/"))
    write_receipt(receipt, top)
    if dirty:
        sys.stderr.write("heimdall-repo-checks: WARNING - tracked files had uncommitted changes before or after the run (or the declaration "
                         "on disk is not the committed one), so the receipt records dirty:true and will NOT satisfy the push gate. "
                         "Commit, then run again.\n")
    if failed:
        sys.stderr.write("heimdall-repo-checks: %d of %d check(s) FAILED - the red receipt is at %s\n" % (failed, len(checks), path))
        return 1
    sys.stderr.write("heimdall-repo-checks: %d/%d check(s) passed - receipt %s\n" % (len(checks), len(checks), path))
    return 0


def cmd_status(top, pushes):
    try:
        facts = rr.facts(top, PINNED)
    except rr.Unreadable as exc:
        not_green(str(exc), top)
    if facts.state != "ok":
        why = {"absent": "it is absent", "irregular": "it is a link, a submodule or a directory, not a file",
               "oversized": "it is larger than %d bytes" % rr.MAX_BYTES}[facts.state]
        refuse("HEAD of %s carries no usable %s (%s): this repo declares no checks of its own at the commit being pushed. Declare them "
               "({\"schema\":1,\"checks\":[{\"name\":\"...\",\"cmd\":\"...\"}]}) and commit the file." % (top, rr.DECLARATION, why))
    declared, problem = parse_declaration(facts.declaration)
    if problem:
        refuse("%s at HEAD of %s is not a valid declaration (%s): want {\"schema\":1,\"checks\":[{\"name\":\"...\",\"cmd\":\"...\"}, ...]}"
               % (rr.DECLARATION, top, problem))
    path = os.path.join(top, *rr.RECEIPT.split("/"))
    try:
        raw = rr.read_inside(top, rr.RECEIPT)
    except rr.Unsafe as exc:
        not_green("the receipt cannot be trusted: %s" % exc, top, run_hint=False)
    if raw is None:
        not_green("no receipt at %s (the declared checks have never been recorded in this checkout)" % path, top)
    try:
        receipt = json.loads(raw.decode("utf-8"))
    except (ValueError, RecursionError):
        not_green("the receipt at %s is not valid JSON" % path, top)
    ok, why = rr.verify_receipt(receipt, facts.head, facts.tree, facts.decl_sha256, declared["checks"])
    if not ok:
        not_green(why, top)
    if pushes is not None:
        ok, why = rr.verify_pushed(receipt, rr.parse_pushed(pushes))
        if not ok:
            not_green(why, top, run_hint=False)
    sys.stdout.write("repo-checks: GREEN - %d check(s) passed at %s on a clean tree (finished %s)\n"
                     % (len(receipt["checks"]), facts.head[:12], receipt["finished_at"]))
    return 0


def main(argv):
    if not argv:
        sys.stderr.write(__doc__)
        return 2
    sub = argv[0]
    if sub in ("-h", "--help"):
        sys.stdout.write(__doc__)
        return 0
    if sub not in ("run", "status"):
        sys.stderr.write("heimdall-repo-checks: unknown command: %s\n" % sub)
        sys.stderr.write(__doc__)
        return 2
    repo_arg, pushes, gitdir, rest = ".", None, None, argv[1:]
    while rest:
        arg = rest.pop(0)
        if arg == "--repo":
            if not rest:
                refuse("--repo needs a path")
            repo_arg = rest.pop(0)
        elif arg.startswith("--repo="):
            repo_arg = arg[len("--repo="):]
        elif arg == "--git-dir":
            if not rest:
                refuse("--git-dir needs a path")
            gitdir = rest.pop(0)
        elif arg.startswith("--git-dir="):
            gitdir = arg[len("--git-dir="):]
        elif sub == "status" and arg == "--pushes":
            if not rest:
                refuse("--pushes needs a value")
            pushes = rest.pop(0)
        elif sub == "status" and arg.startswith("--pushes="):
            pushes = arg[len("--pushes="):]
        elif arg in ("-h", "--help"):
            sys.stdout.write(__doc__)
            return 0
        else:
            refuse("unexpected argument: %s (usage: heimdall-repo-checks run|status [--repo PATH] [--pushes IDS])" % arg)
    top = top_of(repo_arg, gitdir)
    return cmd_run(top) if sub == "run" else cmd_status(top, pushes)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as exc:  # the gate calls this: no answer must read as "not green", never as "green"
        sys.stderr.write("heimdall-repo-checks: %s: %s\n" % (type(exc).__name__, exc))
        sys.exit(2)
