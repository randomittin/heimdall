#!/usr/bin/env python3
r"""hmd_ci_guard -- would this Bash command pay for CI to re-roll a result instead of fixing it?

2026-10-19: in a client repo an hmd agent worked around a flaky test by pushing an EMPTY commit to retrigger CI and by re-running the
workflow twice, so every attempt cost GitHub Actions minutes and the test was still flaky. A failing run is a result to FIX or to REPORT,
never a die to roll again. bin/heimdall-precheck-bash asks this file, for a command that mentions one of the trigger words, whether the
command is one of the ways an agent re-rolls CI. It reads the command the way a shell does by reusing bin/lib/hmd_kill_guard.py's lexer and
wrapper handling (quotes and escapes, env / nice / timeout / sudo / xargs, ; && || | & and newlines, subshells, substitutions, if / for /
while bodies, sh -c, eval, heredocs fed to a shell) and bin/lib/hmd_push_target.py's table of git's global options.

  denied   git commit --allow-empty: the flag among the commit's OPTIONS (not as the value of one, not after --), behind any of git's
           global options (-C d, -c k=v, --git-dir, --no-pager, ...)
           gh run rerun, with any flags (--failed, --job, -R owner/repo, ...)
           gh workflow run (it dispatches the workflow again)
           gh api whose endpoint ends in /rerun, /rerun-failed-jobs, /dispatches or /rerequest, when the method is POST: -X POST or
           --method POST, or the POST gh api makes by itself once it is given a body (-f, -F, --field, --raw-field, --input), or a
           method that cannot be told (-X "$M")
  allowed  everything else: --allow-empty-message, --no-allow-empty, gh run list / view / watch / download / cancel, gh workflow list /
           view / enable / disable, a GET of those endpoints, and text that only MENTIONS a form (echo, grep, a commit message or its
           heredoc, a -m value, a gh field value, a file being written)
  unread   a command that mentions a trigger word and that this cannot read: an unbalanced quote, substitution or brace, a heredoc body
           the shell expands, $'...', shell strings nested more than 8 deep, an internal error, a timeout. Exit 4: the hook warns on
           stderr and ALLOWS. This is a COST guard, not a security gate (the disk floor's convention, not the kill guard's), so what it
           could not read is never a deny. A form it DID read wins over what it could not.
  unseen   what no reading sees: a command name or shell string held in a variable, a git or gh alias, a script on disk, curl against the API.
           Best effort, not a security boundary.

Protocol: the command text on stdin; stdout `ok` and exit 0 = nothing found; one reason line and exit 3 = deny; one reason line and exit 4
= could not read (allow, warn). Anything else (a crash, another status) is the hook's "the guard itself failed" warning, also an allow.
HMD_CI_GUARD_TIMEOUT_S (default 5) bounds the run. HMD_CI_RERUN_ALLOW=1 is read by the hook, bin/heimdall-precheck-bash, which then never
starts this file.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hmd_kill_guard as kg  # noqa: E402  (the shell reader: lex, unwrap, opaque, the run-time budget)
from hmd_push_target import GIT_VALUE_OPTS  # noqa: E402  (git's global options that take a separate argument)

MAX_DEPTH = kg.MAX_DEPTH  # shell strings (sh -c, eval, heredocs) read inside shell strings
try:
    TIMEOUT_S = float(os.environ.get("HMD_CI_GUARD_TIMEOUT_S", "5"))
except ValueError:
    TIMEOUT_S = 5.0

# git commit's options that take a value, which is never itself an option: `commit -m --allow-empty` commits with that message
COMMIT_VALUE_LONG = frozenset(("--message", "--file", "--reuse-message", "--reedit-message", "--template", "--fixup", "--squash",
                               "--author", "--date", "--cleanup", "--trailer", "--pathspec-from-file"))
COMMIT_VALUE_SHORT = "mFCct"  # -m -F -C -c -t: the rest of the cluster is the value, or the next word when nothing is left (-qm msg)
COMMIT_ATTACHED_SHORT = "Su"  # -S[<keyid>] -u[<mode>]: the rest of the cluster is the value, and the next word is not
GH_REPO = frozenset(("-R", "--repo"))  # the group's own flag (gh run -R o/r rerun): its value is not a word of the command
GH_API_ENDPOINT = re.compile(r"/(rerun|rerun-failed-jobs|dispatches|rerequest)/*$")
GH_API_VALUE = frozenset(("-X", "--method", "-f", "--raw-field", "-F", "--field", "--input", "-H", "--header", "-q", "--jq", "-t",
                          "--template", "--cache", "--hostname", "-p", "--preview"))
GH_API_METHOD = frozenset(("-X", "--method"))
GH_API_BODY = frozenset(("-f", "--raw-field", "-F", "--field", "--input"))  # a body makes gh api a POST on its own

# Reasons are fixed one-liners without quotes or backslashes: the hook puts them into a JSON deny.
R_EMPTY = "git commit --allow-empty: empty commits to retrigger CI waste minutes; fix the failing test or report it"
R_FLAKY = ("%s: a flaky failure is a defect, not a die to re-roll; fix it (make a timing-based test count steps, not seconds, "
           "or mark it local-only) or report it; never re-roll CI")
U_DEEP = "shell strings nested more than %d deep, so the guard cannot read the command" % MAX_DEPTH
U_TIMEOUT = "reading the command took longer than %gs (HMD_CI_GUARD_TIMEOUT_S), so the guard gave up"
U_ERROR = "an internal error (%s), so the guard cannot read the command"


def allows_empty(args):
    """Is --allow-empty one of this git commit's OPTIONS: not the value of one (-m, -F, ...) and not after `--`?"""
    k = 0
    while k < len(args):
        t = args[k].text
        k += 1
        if t == "--":
            return False
        if t == "--allow-empty":
            return True
        if t in COMMIT_VALUE_LONG:
            k += 1
        elif t.startswith("-") and not t.startswith("--"):
            cluster = t[1:]
            for i, c in enumerate(cluster):
                if c in COMMIT_VALUE_SHORT:
                    if i == len(cluster) - 1:
                        k += 1
                    break
                if c in COMMIT_ATTACHED_SHORT:
                    break
    return False


def check_git(rest):
    """git <global options> commit ...: the words after `git`."""
    k = 0
    while k < len(rest) and not rest[k].dynamic and rest[k].text.startswith("-"):
        k += 2 if rest[k].text in GIT_VALUE_OPTS else 1
    if k < len(rest) and not rest[k].dynamic and rest[k].text == "commit" and allows_empty(rest[k + 1:]):
        return R_EMPTY
    return None


def check_api(words):
    """gh api <flags> <endpoint>: the words after `api`. An endpoint that re-runs or re-dispatches CI, reached by a POST."""
    method, body, endpoint, k = None, False, None, 0
    while k < len(words):
        w = words[k]
        t = w.text
        k += 1
        if t.startswith("--") and len(t) > 2:
            name, eq, value = t.partition("=")
            attached = bool(eq)
        elif t.startswith("-") and len(t) > 1:
            name, value, attached = t[:2], t[2:].lstrip("="), len(t) > 2
        else:
            endpoint = endpoint or w
            continue
        if name not in GH_API_VALUE:
            continue  # a flag without a value (--paginate, -i, ...) or one this does not know
        dynamic = w.dynamic
        if not attached:  # the value is the next word
            if k >= len(words):
                break
            value, dynamic = words[k].text, words[k].dynamic
            k += 1
        if name in GH_API_METHOD:
            method = "?" if dynamic else value.upper()
        elif name in GH_API_BODY:
            body = True
    if endpoint is None or not GH_API_ENDPOINT.search(re.sub(r"[?#].*", "", endpoint.text)):
        return None
    if method is None:
        method = "POST" if body else "GET"
    return R_FLAKY % "gh api POST to a re-run or dispatch endpoint" if method in ("POST", "?") else None


def check_gh(rest):
    """gh <group> <subcommand> ...: the words after `gh`."""
    group, sub, k = None, None, 0
    while k < len(rest) and sub is None:
        w = rest[k]
        k += 1
        if w.text in GH_REPO:
            k += 1
        elif w.text.startswith("-"):
            continue
        elif w.dynamic:
            return None
        elif group is None:
            group = w.text
            if group == "api":
                return check_api(rest[k:])
        else:
            sub = w.text
    if (group, sub) == ("run", "rerun"):
        return R_FLAKY % "gh run rerun"
    if (group, sub) == ("workflow", "run"):
        return R_FLAKY % "gh workflow run"
    return None


def check_shell(cmd, rest, depth, unread):
    """sh / bash / ...: the -c string, and a heredoc or here-string fed to the shell, are commands too (as hmd_kill_guard.check_shell reads them)."""
    sources, k = list(cmd.bodies), 0
    while k < len(rest) and not rest[k].dynamic:
        t = rest[k].text
        if t == "--" or not t.startswith(("-", "+")) or t in ("-", "+"):
            break
        if t in ("-o", "+o", "-O", "+O"):
            k += 2
        elif t.startswith("-") and not t.startswith("--") and "c" in t[1:]:
            if k + 1 < len(rest) and not kg.opaque(rest[k + 1]):
                sources.append(rest[k + 1].text)
            break
        else:
            k += 1
    for source in sources:
        why = analyze(source, depth + 1, unread)
        if why:
            return why
    return None


def check(cmd, depth, unread):
    args, _ = kg.unwrap(cmd.words)
    if not args or args[0].dynamic:
        return None
    base, rest = os.path.basename(args[0].text).lower(), args[1:]
    if base == "git":
        return check_git(rest)
    if base == "gh":
        return check_gh(rest)
    if base in kg.SHELLS:
        return check_shell(cmd, rest, depth, unread)
    if base == "eval" and not (rest and kg.opaque(rest[0])):
        return analyze(" ".join(w.text for w in rest), depth + 1, unread)
    return None


def analyze(text, depth, unread):
    """The reason this command text must be denied, or None. Whatever could not be read is appended to `unread`."""
    if depth > MAX_DEPTH:
        unread.append(U_DEEP)
        return None
    cmds, unparsed = kg.lex(text)
    if unparsed:
        unread.append(unparsed)
    for cmd in cmds:
        why = check(cmd, depth, unread)
        if why:
            return why
    return None


def verdict(text):
    """(the reason to deny or None, the reason it could not be read or None): something found wins over something not read."""
    unread = []
    why = analyze(text, 0, unread)
    return why, (unread[0] if unread else None)


def main():
    why = unread = None
    try:
        kg.arm(TIMEOUT_S)
        why, unread = verdict(sys.stdin.buffer.read().decode("utf-8", "replace"))
    except kg.GuardTimeout:
        unread = U_TIMEOUT % TIMEOUT_S
    except Exception as exc:  # a command this could not read is one it cannot judge: say so, and let it through (a cost guard, not a gate)
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
