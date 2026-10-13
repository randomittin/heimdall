#!/usr/bin/env python3
r"""hmd_push_target -- WHICH repository does this Bash command push, and which push gate does that repository owe?

bin/heimdall-precheck-bash used to run heimdall's own sweep gate in the session's cwd for any push, so a push of another repository
(a site with checks of its own) was held to a receipt only heimdall's sweep can write. It now asks this file, once per push command,
for the repositories the command pushes and the class of each, and runs the gate that class owes.

Protocol: the command text on stdin, the session's cwd as argv[1]; one line `class<TAB>toplevel[<TAB>extra]` per gate, in the order first met.
`extra` is, for a repo-checks row, the commits the push sends as sources (full ids, comma separated; `-` none, `?` cannot be listed) which
the hook hands to `heimdall-repo-checks status --pushes` (the receipt must be for every one of them); for a sweep row it is `fallback`
when the row is the strict class only because the command or git could not be read, not because a marker was found (the hook then also
refuses a gate that was never evaluated). Exit 0. Anything else (a crash, a timeout, no output) tells the hook to run the sweep gate on
the cwd repository exactly as before.

FAIL CLOSED, the one rule everything below serves. The warn-only class (unmanaged) is answered ONLY when every part of the command was
understood exactly, git itself resolved the repository, and none of the commits a push can carry (or its upstream holds) has either
marker. Anything else -- a construct this does not model exactly, an unknown git option or subcommand (an alias may be a push), a
variable or missing target, an unmodelled GIT_* variable, a repository git cannot place, a marker that cannot be inspected -- makes the
whole command UNCERTAIN, and then EVERY repository involved (the ones resolved and the cwd one) is given the strict class, `sweep`.
A wrong or missing answer can therefore only ever make a gate STRICTER than a repository's class says, never weaker. EVERY error path is
strict: git that exits non-zero, times out, prints something it does not print, a ref that cannot be placed, a marker that is a link, a
submodule or a directory, an exception anywhere (no answer at all: the hook runs the strict gate on the cwd). A repository that declares its
own checks keeps owing the receipt under uncertainty, for commits nobody can list, so it is refused until the command is restated.

WHICH REPOSITORY IS ASKED OF GIT, NOT READ OFF THE COMMAND. Every push found is rebuilt as the exact `git <global options> rev-parse`
call, started in the directory the shell would be in, with the same GIT_* environment, and git answers with the git directory the push
would operate on (`-C` accumulates the way git accumulates it, `--git-dir`, `GIT_DIR`, `-c core.worktree`, discovery from a subdirectory
or a linked worktree are all git's). `--work-tree` and `GIT_WORK_TREE` do not change which repository is pushed, so they cannot point a
push at a decoy. The work tree root of that git directory is taken from candidates (what `--show-toplevel` says, the parent of a
`.git`, the work tree a linked worktree records) and each is checked from the other end: git run from the candidate must name the same
git directory and the same toplevel, or the candidate is refused.

THE SHELL IS READ BY A MODEL, AND THE MODEL IS CONSERVATIVE. What it follows exactly: quotes, escapes, `~`, `;` `&&` `||` `|` `&`,
newlines, subshells, `$( )` and backticks (they run in a subshell, at the moment their command runs), the abstract working directory
through `cd`, `pushd` and `popd` as a SET of possible states (an `&&` or `||` runs its right side only on the left's success or failure,
and a `cd` into an existing directory cannot fail), a subshell's or pipeline element's directory changes going nowhere, `eval`
(it runs in the current shell), `sh -c`, a here-string, heredoc or pipe fed to a shell, `env`/`sudo`/`command`/`exec`/`time`/`nohup`/
`nice`/`xargs` wrappers, `export GIT_DIR=...`. What it does NOT model it flags: a `cd` that is dynamic, `cd -`, through CDPATH, inside an
if/while/for/case or a brace group, a function definition, `source`, `alias`, a sourced or piped script it cannot see, an expansion that
hides a substitution (`${x:-$(...)}`), a heredoc body the shell would expand, `find -exec` and other commands that carry a push in their
arguments (an argument naming git and push), `xargs` handing the subcommand over on stdin, `sudo -D`/`-i`. A shell cannot be read
completely (a command can build a verb or a path at run time), so the native hook (core.hooksPath) stays the hard backstop.

CLASS comes from the COMMITS, never the work tree. The commits read are HEAD, its upstream (`@{upstream}`, `@{push}`), the remote's
default and same-named branch (origin/HEAD, origin/<branch>), and whatever the push names (a remote and refspecs: `origin <ref>`, `src:dst`,
--all, --mirror, --tags). Each is read with `git ls-tree` and `git cat-file` -- an uncommitted edit, deletion or new file on disk changes nothing
-- and the STRICTEST class wins, so a pushed commit that drops a marker cannot downgrade a repository whose upstream still has it:
  sweep        the commit has test/run-all.sh as a regular file that names last-sweep.json. That is heimdall's own sweep regime: the
               script writes the receipt (.heimdall/receipts/last-sweep.json) that `heimdall-state check-quality-gates` demands. The
               marker is tracked CODE, never the receipt: deleting a receipt must not downgrade a repository, and another project's
               test/run-all.sh does not name that file. Also sweep: a marker that cannot be inspected (a link, a submodule, a directory
               where the file should be, a failing git), or a push whose commits cannot be named.
  repo-checks  the commit has .heimdall/repo-checks.json as a regular file: the repository declares its own checks
               (bin/heimdall-repo-checks) and passes only on a green, current receipt of them. Present-but-invalid is still this class
               and blocks.
  unmanaged    no inspected commit has either marker: the hook prints one warning and lets the push through. The secret and self-scan
               gates are not part of this class rule and still run.

Python 3.7+, standard library only. HMD_PUSH_TARGET_TIMEOUT_S (default 5) bounds the whole run.
"""
import os
import re
import signal
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hmd_repo_receipt as rr  # noqa: E402  (git helpers, and the path of the declaration a repository is classified by)

SWEEP_MARK = b"last-sweep.json"
SWEEP_WRITER = "test/run-all.sh"
DECLARATION = rr.DECLARATION
RANK = {"unmanaged": 0, "repo-checks": 1, "sweep": 2}
MAX_DEPTH = 8        # shell strings (sh -c, eval) read inside shell strings
MAX_NESTING = 40     # substitutions and subshells inside each other
MAX_STATES = 8       # possible (cwd, stack, GIT_*) states carried at once
MAX_REFS = 500       # refs a --all / --mirror / --tags push may name before the push is called uncertain
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\+?=")
NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
OID = rr.OID_RE
DURATION = re.compile(r"^[0-9.]+[smhd]?$")
GIT_PUSH_TEXT = re.compile(r"\bgit\b.*\bpush\b", re.S)   # an argument that carries a push to somewhere this cannot see
LIST_STARTS = ("", ";", "\n", "&")                       # an item whose `before` is one of these begins a new and-or list
PREFIX_WORDS = frozenset(("if", "then", "else", "elif", "while", "until", "do", "!", "time", "{"))
OPENERS = frozenset(("if", "while", "until"))            # open a conditional or loop; the command that follows is read on
LOOPS = frozenset(("for", "select", "case"))             # open one too, but what follows is a name or a pattern, not a command
CLOSERS = frozenset(("fi", "done", "esac"))
CONTINUERS = frozenset(("then", "else", "elif", "do", "in"))
SHELLS = frozenset(("sh", "bash", "zsh", "dash", "ksh", "ash", "mksh"))
EXPORTERS = frozenset(("export", "unset", "declare", "typeset", "readonly", "local"))
SHELL_BUILTINS = frozenset(("cd", "pushd", "popd", "eval", "source", ".", "alias", "unalias", "shopt")) | EXPORTERS
# wrappers that run what follows in THIS shell (`time` is a keyword, `builtin` says so). Every other wrapper starts a process, and a builtin
# behind one does not run here: `env cd X` is a no-op for the shell. `command` is not on this list: bash runs the builtin, zsh does not.
INTERNAL = frozenset(("builtin", "time"))
STATE_VARS = frozenset(("HOME", "CDPATH", "PWD", "OLDPWD", "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS"))   # decide where a cd goes, or what runs first
# commands that only read or print their arguments: a push named in one is text, not a command
DATA_ONLY = frozenset((
    "echo", "printf", "cat", "grep", "egrep", "fgrep", "rg", "ag", "ls", "head", "tail", "wc", "sort", "uniq", "cut", "tr", "tee",
    "test", "[", "[[", "true", "false", ":", "pwd", "date", "jq", "mkdir", "rm", "cp", "mv", "touch", "diff", "cmp", "basename",
    "dirname", "realpath", "readlink", "stat", "file", "du", "df", "which", "type", "sleep", "whoami", "id", "uname", "seq",
    "read", "wait", "base64", "shasum", "sha256sum", "md5", "md5sum", "xxd", "pbcopy"))
REDIRS = ("<<<", "<<-", "<<", "<&", "<>", ">>", ">&", ">|", "<", ">")
# git's global options. The ones that take a separate argument; the ones that decide WHICH repository are handed to git as they are.
GIT_VALUE_OPTS = frozenset(("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env", "--attr-source"))
GIT_WHICH_OPTS = frozenset(("-C", "-c", "--git-dir", "--work-tree"))
GIT_FLAGS = frozenset(("-p", "--paginate", "-P", "--no-pager", "--bare", "--no-replace-objects", "--literal-pathspecs",
                       "--glob-pathspecs", "--noglob-pathspecs", "--icase-pathspecs", "--no-optional-locks", "--no-advice",
                       "--no-lazy-fetch"))
GIT_ATTACHED = ("--git-dir=", "--work-tree=", "--namespace=", "--super-prefix=", "--config-env=", "--exec-path=", "--attr-source=")
# Built-in git subcommands that cannot push. Any other name (an alias, an external command, a push-like plumbing such as send-pack)
# may be a push, so a command holding one is not fully understood.
GIT_BUILTINS = frozenset((
    "add", "am", "annotate", "apply", "archive", "bisect", "blame", "branch", "bundle", "cat-file", "check-attr", "check-ignore",
    "check-mailmap", "check-ref-format", "checkout", "checkout-index", "cherry", "cherry-pick", "citool", "clean", "clone", "column",
    "commit", "commit-graph", "commit-tree", "config", "count-objects", "credential", "describe", "diff", "diff-files", "diff-index",
    "diff-tree", "difftool", "fast-export", "fast-import", "fetch", "fetch-pack", "filter-branch", "for-each-ref", "for-each-repo",
    "format-patch", "fsck", "gc", "get-tar-commit-id", "grep", "gui", "hash-object", "help", "hook", "index-pack", "init",
    "interpret-trailers", "log", "ls-files", "ls-remote", "ls-tree", "mailinfo", "mailsplit", "maintenance", "merge", "merge-base",
    "merge-file", "merge-index", "merge-tree", "mergetool", "mktag", "mktree", "multi-pack-index", "mv", "name-rev", "notes",
    "pack-objects", "pack-redundant", "pack-refs", "patch-id", "prune", "prune-packed", "pull", "range-diff", "read-tree", "rebase",
    "reflog", "remote", "repack", "replace", "replay", "request-pull", "rerere", "reset", "restore", "rev-list", "rev-parse", "revert",
    "rm", "shortlog", "show", "show-branch", "show-index", "show-ref", "sparse-checkout", "stage", "stash", "status", "stripspace",
    "submodule", "switch", "symbolic-ref", "tag", "unpack-file", "unpack-objects", "update-index", "update-ref", "update-server-info",
    "var", "verify-commit", "verify-pack", "verify-tag", "version", "whatchanged", "worktree", "write-tree"))
# a push's own options: the ones that take a separate argument, and the ones that widen what is pushed beyond HEAD
PUSH_VALUE_OPTS = frozenset(("-o", "--push-option", "--receive-pack", "--exec"))
PUSH_BROAD = frozenset(("--all", "--branches", "--mirror", "--tags"))
WRAPPERS = {  # wrapper -> its options that take a separate argument
    "env": ("-u", "-C", "--unset", "--chdir"),
    "sudo": ("-u", "-g", "-C", "-h", "-p", "-r", "-t", "-T", "-U", "-D", "--user", "--group"),
    "doas": ("-u", "-C"),
    "nohup": (),
    "command": (),
    "builtin": (),
    "exec": ("-a",),
    "time": (),
    "nice": ("-n",),
    "ionice": ("-c", "-n", "-p"),
    "setsid": (),
    "stdbuf": ("-i", "-o", "-e"),
    "caffeinate": ("-t", "-w"),
    "timeout": ("-k", "-s", "--signal", "--kill-after"),
    "xargs": ("-n", "-I", "-P", "-L", "-s", "-E", "-d", "-a", "-J", "-R", "-S"),
}

U_QUOTE = "an unbalanced quote, substitution or brace"
U_SYNTAX = "a substitution inside an expansion that is skipped, not read"

try:
    TIMEOUT_S = float(os.environ.get("HMD_PUSH_TARGET_TIMEOUT_S", "5"))
except ValueError:
    TIMEOUT_S = 5.0
GIT_TIMEOUT = max(TIMEOUT_S, 1.0)


def git(args, cwd, env):
    return rr.run_git(args, cwd, env, GIT_TIMEOUT)


def git_bytes(args, cwd, env):
    return rr.run_git_bytes(args, cwd, env, GIT_TIMEOUT)


class Word(object):
    """One shell word: its text with quotes and escapes removed; dyn when an expansion or glob makes the value unknowable;
    tilde when it began with an unquoted ~."""
    __slots__ = ("text", "dyn", "tilde")

    def __init__(self, text, dyn, tilde):
        self.text, self.dyn, self.tilde = text, dyn, tilde


class Cmd(object):
    """A simple command: its words (redirections removed), the operator that ended the command before it, the substitutions inside its
    words (they run in subshells when it runs) and the heredoc / here-string texts fed to it (None: a here-string that is not literal)."""
    __slots__ = ("words", "before", "subs", "bodies")

    def __init__(self, words, before, subs, bodies):
        self.words, self.before, self.subs, self.bodies = words, before, subs, bodies


class Group(object):
    """A subshell `( ... )`, or a substitution's commands: their own list of items, run with a copy of the state."""
    __slots__ = ("items", "before")

    def __init__(self, items, before):
        self.items, self.before = items, before


class Lexer(object):
    """Text -> a list of items (Cmd or Group), each carrying the operator that ended the item before it. Whatever cannot be read
    faithfully sets `unparsed` instead of being guessed at."""

    def __init__(self, text):
        self.s, self.n, self.i = text, len(text), 0
        self.unparsed = None
        self.heredocs = []   # (delimiter, tabs stripped, delimiter quoted, the owner's bodies list) whose body starts on the next line
        self.depth = 0

    def flag(self, why):
        if self.unparsed is None:
            self.unparsed = why

    def heredoc_body(self, delim, tabs):
        """(the body, whether its terminator line was found); self.i is left after the terminator."""
        s, lines = self.s, []
        while self.i < self.n:
            j = s.find("\n", self.i)
            line = s[self.i:] if j < 0 else s[self.i:j]
            self.i = self.n if j < 0 else j + 1
            if (line.lstrip("\t") if tabs else line) == delim:
                return "\n".join(lines), True
            lines.append(line)
        return "\n".join(lines), False

    def skip_balanced(self, i, opener, closer):
        """s[i] is `opener`: the index just past its matching `closer` (quotes inside are not told apart; good enough to skip)."""
        depth, j, s = 0, i, self.s
        while j < self.n:
            c = s[j]
            if c == "\\":
                j += 2
                continue
            if c == opener:
                depth += 1
            elif c == closer:
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        self.flag(U_QUOTE)
        return self.n

    def opaque(self, i, j):
        """s[i:j] is a ${...}, $((...)) or $[...] that is skipped, not read: a substitution inside it would run unseen."""
        if "$(" in self.s[i:j] or "`" in self.s[i:j]:
            self.flag(U_SYNTAX)
        return j

    def backtick(self, i, hoist):
        """s[i] is an opening backtick: lex the substitution into hoist and return the index after the closing one."""
        self.i = i + 1
        hoist.append(Group(self.parse("`"), ""))
        if "\\`" in self.s[i:self.i]:
            self.flag("escaped backticks nest a substitution this does not read")
        return self.i

    def expansion(self, i, hoist):
        """s[i] is '$': lex what it starts, return the index after it. A $( ... ) is lexed in place and its commands go to hoist."""
        s = self.s
        nx = s[i + 1] if i + 1 < self.n else ""
        if nx == "(":
            if s.startswith("$((", i):
                return self.opaque(i, self.skip_balanced(i + 1, "(", ")"))
            self.i = i + 2
            hoist.append(Group(self.parse(")"), ""))
            return self.i
        if nx == "{":
            return self.opaque(i, self.skip_balanced(i + 1, "{", "}"))
        if nx == "[":
            return self.opaque(i, self.skip_balanced(i + 1, "[", "]"))
        if nx == "'":
            j = s.find("'", i + 2)
            while j > 0 and s[j - 1] == "\\":
                j = s.find("'", j + 1)
            if j < 0:
                self.flag(U_QUOTE)
                return self.n
            return j + 1
        m = NAME.match(s, i + 1)
        if m:
            return m.end()
        return i + 2 if nx and nx in "0123456789!@*#?$-" else i + 1

    def dquote(self, hoist):
        """self.i is at an opening double quote: (text, dynamic); self.i is left after the closing quote."""
        s, i, out, dyn = self.s, self.i + 1, [], False
        while i < self.n:
            c = s[i]
            if c == '"':
                self.i = i + 1
                return "".join(out), dyn
            if c == "\\" and i + 1 < self.n:
                if s[i + 1] in '$`"\\':
                    out.append(s[i + 1])
                elif s[i + 1] != "\n":
                    out.append(s[i:i + 2])
                i += 2
            elif c == "$":
                j = self.expansion(i, hoist)
                out.append(s[i:j])
                dyn, i = dyn or j > i + 1, j
            elif c == "`":
                j = self.backtick(i, hoist)
                out.append(s[i:j])
                dyn, i = True, j
            else:
                out.append(c)
                i += 1
        self.i = self.n
        self.flag(U_QUOTE)
        return "".join(out), dyn

    def parse(self, stop):
        """The items up to `stop` (')' or a backtick closing a substitution; None = the end of the text)."""
        s, n = self.s, self.n
        out, words, hoist = [], [], []
        bodies = []                  # heredoc / here-string texts of the command being read
        has_body = False
        word = None                  # the pieces of the word being built, None between words
        dyn = tilde = brace = quoted = False
        redir = None                 # a redirection's operator while its target word is still to come ("<<" and "<<-": a heredoc)
        prev = ""                    # the operator that ended the item before this one
        self.depth += 1
        if self.depth > MAX_NESTING:
            self.flag("substitutions nested too deep")
            self.i = n
            self.depth -= 1
            return out

        def open_word(is_tilde=False):
            nonlocal word, dyn, tilde, brace, quoted
            if word is None:
                word, dyn, tilde, brace, quoted = [], False, is_tilde, False, False

        def end_word():
            nonlocal word, dyn, tilde, brace, quoted, redir, has_body
            if word is None:
                return
            text = "".join(word)
            if redir is not None:
                if redir in ("<<", "<<-"):
                    self.heredocs.append((text, redir == "<<-", quoted, bodies))
                    has_body = True
                elif redir == "<<<":
                    bodies.append(None if dyn else text)
                    has_body = True
                redir = None
            else:
                words.append(Word(text, dyn or (brace and text not in ("{", "}")), tilde))
            word, dyn, tilde, brace, quoted = None, False, False, False, False

        def end_cmd(op):
            nonlocal prev, redir, bodies, has_body
            end_word()
            redir = None
            if words or hoist or has_body:
                out.append(Cmd(list(words), prev, list(hoist), bodies))
                del words[:]
                del hoist[:]
                bodies, has_body = [], False
            prev = op

        while self.i < n:
            i = self.i
            c = s[i]
            if c in " \t":
                end_word()
                self.i = i + 1
            elif c == "\n":
                end_cmd("\n")
                self.i = i + 1
                for delim, tabs, delim_quoted, owner in self.heredocs:
                    body, found = self.heredoc_body(delim, tabs)
                    owner.append(body)
                    if not found:
                        self.flag("a heredoc without its terminator")
                    if not delim_quoted and ("$(" in body or "`" in body):
                        self.flag("a heredoc body the shell expands, and so runs")
                del self.heredocs[:]
            elif c == "#" and word is None:
                j = s.find("\n", i)
                self.i = n if j < 0 else j
            elif c == "\\":
                if s.startswith("\n", i + 1):
                    self.i = i + 2
                else:
                    open_word()
                    quoted = True
                    word.append(s[i + 1:i + 2])
                    self.i = i + 2
            elif c == "'":
                open_word()
                quoted = True
                j = s.find("'", i + 1)
                if j < 0:
                    self.flag(U_QUOTE)
                word.append(s[i + 1:] if j < 0 else s[i + 1:j])
                self.i = n if j < 0 else j + 1
            elif c == '"':
                open_word()
                quoted = True
                text, d = self.dquote(hoist)
                word.append(text)
                dyn = dyn or d
            elif c == "`":
                if stop == "`":
                    end_cmd("")
                    self.i = i + 1
                    self.depth -= 1
                    return out
                open_word()
                j = self.backtick(i, hoist)
                word.append(s[i:j])
                dyn = True
            elif c == "$":
                open_word()
                j = self.expansion(i, hoist)
                word.append(s[i:j])
                dyn = dyn or j > i + 1
                self.i = j
            elif c == ";":
                end_cmd(";")
                self.i = i + (2 if s.startswith(";;", i) else 1)
            elif c == "&":
                if s.startswith("&>", i):
                    end_word()
                    redir = ""
                    self.i = i + (3 if s.startswith("&>>", i) else 2)
                else:
                    op = "&&" if s.startswith("&&", i) else "&"
                    end_cmd(op)
                    self.i = i + len(op)
            elif c == "|":
                op = "||" if s.startswith("||", i) else ("|&" if s.startswith("|&", i) else "|")
                end_cmd(op)
                self.i = i + len(op)
            elif c == "(":
                end_word()
                if words:
                    if not all(not w.dyn and w.text in PREFIX_WORDS for w in words):
                        self.flag("a function definition, an array or other syntax this does not read")
                    end_cmd("")
                self.i = i + 1
                out.append(Group(self.parse(")"), prev))
            elif c == ")":
                end_cmd(";")
                self.i = i + 1
                if stop == ")":
                    self.depth -= 1
                    return out
            elif c in "<>":
                if word is not None and not dyn and "".join(word).isdigit():
                    word = None          # `2>file`: the digits name a descriptor, not an argument
                else:
                    end_word()
                if s.startswith("(", i + 1):      # <(cmd) and >(cmd): a substitution that is also a word
                    open_word()
                    self.i = i + 2
                    hoist.append(Group(self.parse(")"), ""))
                    word.append(s[i:self.i])
                    dyn = True
                else:
                    op = next(o for o in REDIRS if s.startswith(o, i))
                    redir = op if op in ("<<", "<<-", "<<<") else ""
                    self.i = i + len(op)
            else:
                open_word(c == "~")
                word.append(c)
                if c in "*?[":
                    dyn = True
                elif c == "{":
                    brace = True
                self.i = i + 1
        end_cmd("")
        self.depth -= 1
        if stop is not None:
            self.flag(U_QUOTE)           # ran off the end without the closing parenthesis or backtick
        elif self.heredocs:
            self.flag("a heredoc whose body never began")
        return out


def join_dir(cwd, word):
    """`word` (a directory named relative to cwd) as an absolute path, or None when it cannot be known."""
    if cwd is None or word is None or word.dyn:
        return None
    text = word.text
    if word.tilde:
        text = os.path.expanduser(text)
        if text.startswith("~"):
            return None
    return os.path.normpath(os.path.join(cwd, text))


UNKNOWN = (None, (), ())      # a shell state whose working directory cannot be known: (cwd, pushd stack, exported GIT_* pairs)


class Push(object):
    """One push as the shell would run it: the directory git starts in, git's global options that decide WHICH repository (-C, -c,
    --git-dir, --work-tree, --bare: the literal words, in order), the GIT_* environment it runs with, and the words after `push`."""
    __slots__ = ("cwd", "opts", "env", "args")

    def __init__(self, cwd, opts, env, args):
        self.cwd, self.opts, self.env, self.args = cwd, opts, env, args


class Resolver(object):
    def __init__(self):
        self.targets = []        # one Push per push whose directory and options could be read
        self.complete = True     # False once anything could not be read or modelled exactly
        self.cond = 0            # open if / while / until / for / select / case
        self.brace = 0           # open { ... } groups

    # ---- sets of possible states ------------------------------------------------------------------------------------------
    def pool(self, *groups):
        seen, out = set(), []
        for group in groups:
            for state in group:
                if state not in seen:
                    seen.add(state)
                    out.append(state)
        if len(out) > MAX_STATES:
            self.complete = False
            return (UNKNOWN,)
        return tuple(out)

    def read(self, text, sigma, depth):
        """Run `text` as shell commands starting from the states `sigma`; the states afterwards."""
        if depth > MAX_DEPTH:
            self.complete = False
            return (UNKNOWN,)
        lexer = Lexer(text)
        items = lexer.parse(None)
        if lexer.unparsed:
            self.complete = False
        return self.run_seq(items, sigma, depth)

    # ---- control flow: lists, and-or chains, pipelines --------------------------------------------------------------------
    def run_seq(self, items, sigma, depth):
        i = 0
        while i < len(items):
            j = i + 1
            while j < len(items) and items[j].before not in LIST_STARTS:
                j += 1
            backgrounded = j < len(items) and items[j].before == "&"
            after = self.run_andor(items[i:j], sigma, depth)
            if not backgrounded:        # a list sent to the background runs in a subshell: nothing of it carries out
                sigma = after
            i = j
        return sigma

    def run_andor(self, items, sigma, depth):
        pipes = []
        for item in items:
            if pipes and item.before in ("|", "|&"):
                pipes[-1].append(item)
            else:
                pipes.append([item])
        ok = bad = None
        for k, pipe in enumerate(pipes):
            op = pipe[0].before
            if k == 0:
                run_in = sigma
            elif op == "&&":
                run_in = ok
            elif op == "||":
                run_in = bad
            else:
                run_in = self.pool(ok, bad)
            now_ok, now_bad = self.run_pipeline(pipe, run_in, depth) if run_in else ((), ())
            if k > 0 and op == "&&":
                now_bad = self.pool(now_bad, bad)       # a failure earlier in the chain skips this command and stays a failure
            elif k > 0 and op == "||":
                now_ok = self.pool(now_ok, ok)
            ok, bad = now_ok, now_bad
        return self.pool(ok, bad)

    def run_pipeline(self, pipe, sigma, depth):
        if len(pipe) == 1:
            return self.run_item(pipe[0], sigma, depth)
        for item in pipe[:-1]:          # each of these is a subshell of its own: its directory changes go nowhere
            self.run_item(item, sigma, depth)
        # zsh (and bash with lastpipe) runs the LAST element in the current shell, so what it does may carry out: both outcomes are kept
        ok, bad = self.run_item(pipe[-1], sigma, depth)
        return self.pool(sigma, ok), self.pool(sigma, bad)

    def run_item(self, item, sigma, depth):
        """(the states after a success, the states after a failure)."""
        if isinstance(item, Group):
            self.run_seq(item.items, sigma, depth)
            return sigma, sigma
        for sub in item.subs:
            self.run_seq(sub.items, sigma, depth)
        return self.run_cmd(item, sigma, depth)

    # ---- one command ------------------------------------------------------------------------------------------------------
    def note_assignment(self, env, word):
        """VAR=value in front of a command (or after env): GIT_* ones reach git, and must be literal to be modelled."""
        m = ASSIGN.match(word.text)
        if m.group(1) in STATE_VARS:
            self.complete = False                # moves where a cd goes (HOME, CDPATH, PWD, OLDPWD) or runs a file first (BASH_ENV, ENV)
            return
        if not m.group(1).startswith("GIT_"):
            return
        value = word.text[m.end():]
        if word.dyn or value.startswith("~"):
            self.complete = False
        else:
            env[m.group(1)] = value

    def unwrap(self, base, args, env):
        """(the words a wrapper (env, sudo, xargs, ...) runs, whether it runs them somewhere else, whether xargs feeds them)."""
        takes, k, elsewhere = WRAPPERS[base], 0, False
        if base == "command" and args and args[0].text in ("-v", "-V"):
            return [], False, False
        while k < len(args):
            w = args[k]
            t = w.text
            if t == "--":
                k += 1
                break
            if base == "env" and ASSIGN.match(t):
                self.note_assignment(env, w)
                k += 1
            elif not w.dyn and t.startswith("-") and len(t) > 1:
                if base == "env" and (t in ("-C", "--chdir") or t.startswith("--chdir=")):
                    elsewhere = True
                if base == "env":
                    self.complete = False        # -u / -i change the environment git runs in, -C / -S where and what: not modelled
                if base in ("sudo", "doas") and (t in ("-D", "--chdir", "-i", "--login", "-s", "--shell") or t.startswith("--chdir=")):
                    elsewhere = True
                k += 2 if t in takes else 1
            else:
                break
        rest = args[k:]
        if base == "timeout" and rest and DURATION.match(rest[0].text):
            rest = rest[1:]
        return rest, elsewhere, base == "xargs"

    def run_cmd(self, cmd, sigma, depth):
        words, env, negate, xargs, elsewhere, external = list(cmd.words), {}, False, False, False, False
        while words:
            w = words[0]
            t = w.text
            if ASSIGN.match(t):
                self.note_assignment(env, w)
                words.pop(0)
            elif w.dyn:
                if t[:1] in ("$", "`") and "/" not in t:
                    self.complete = False        # a command name held in a variable or a substitution may be git
                    return sigma, sigma
                break
            elif t == "!":
                negate = not negate
                words.pop(0)
            elif t in OPENERS:
                self.cond += 1
                words.pop(0)
            elif t in CLOSERS:
                self.cond = max(0, self.cond - 1)
                words.pop(0)
            elif t == "{":
                self.brace += 1
                words.pop(0)
            elif t == "}":
                self.brace = max(0, self.brace - 1)
                words.pop(0)
            elif t in CONTINUERS:
                words.pop(0)
            elif t in LOOPS:
                self.cond += 1
                return sigma, sigma              # `for x in a b`, `case x in`: the words that follow are names and patterns
            elif t == "function":
                self.complete = False
                return sigma, sigma
            elif os.path.basename(t).lower() in WRAPPERS:
                wrapper = os.path.basename(t).lower()
                words, moved, fed = self.unwrap(wrapper, words[1:], env)
                elsewhere, xargs = elsewhere or moved, xargs or fed
                external = external or wrapper not in INTERNAL
            else:
                break
        if not words:
            if env:
                self.complete = False            # a bare GIT_*=value may update a variable that is already exported: not modelled
            return sigma, sigma
        head, rest = words[0], words[1:]
        name = os.path.basename(head.text)
        if head.dyn and "/" not in head.text:
            self.complete = False                # a glob or brace expansion where the command name is
            return sigma, sigma
        if external and not head.dyn and head.text in SHELL_BUILTINS:
            self.complete = False                # a process (env, nice, xargs, sudo, command in zsh) runs no builtin of THIS shell: what it does is lost
            return sigma, sigma
        ok = bad = sigma
        if not head.dyn and head.text in ("cd", "pushd", "popd"):
            ok, bad = self.run_cd(head.text, rest, sigma)
        elif not head.dyn and head.text in EXPORTERS:
            ok, bad = self.run_exports(head.text, rest, sigma)
        elif not head.dyn and head.text in ("source", "."):
            self.complete = False                # a sourced script may cd, export or define anything
            ok = bad = (UNKNOWN,)
        elif not head.dyn and head.text in ("alias", "unalias", "shopt"):
            self.complete = False                # an alias may turn any word into a push to anywhere
        elif not head.dyn and head.text == "eval":
            if any(w.dyn for w in rest):
                self.complete = False
            ok = bad = self.read(" ".join(w.text for w in rest), sigma, depth + 1)   # eval runs in the CURRENT shell
        elif name == "git":
            for state in sigma:
                self.git(rest, state, env, xargs, elsewhere)
        elif name in SHELLS:
            if head.dyn:
                self.complete = False            # a shell named through a variable's path: which, and what it runs, is not visible
            else:
                self.run_shell(cmd, rest, sigma, depth)
        else:
            self.scan_other(name, head, rest, cmd)
        return (bad, ok) if negate else (ok, bad)

    def run_cd(self, verb, args, sigma):
        """cd, pushd, popd on every possible state. A cd into a directory that exists (and can be entered) cannot fail; anything
        else leaves the directory unknown, and whether it worked unknown too."""
        ok, bad = [], []
        for cwd, stack, genv in sigma:
            if self.cond or self.brace:
                self.complete = False            # conditional or repeated: where this leaves the shell is not modelled
                nxt = (None, stack, genv)
            elif verb == "cd":
                nxt = (self.change_dir(cwd, args), stack, genv)
            elif verb == "pushd":
                if len(args) == 1 and not args[0].dyn and not args[0].text.startswith(("-", "+")):
                    nxt = (self.change_dir(cwd, args), stack + (cwd,), genv)
                else:
                    self.complete = False        # pushd with no argument swaps, +N rotates: not modelled
                    nxt = (None, stack, genv)
            elif args or not stack:
                self.complete = False
                nxt = (None, stack, genv)
            else:
                nxt = (stack[-1], stack[:-1], genv)
            ok.append(nxt)
            if nxt[0] is None:
                bad.append(nxt)
        return self.pool(ok), self.pool(bad)

    def run_exports(self, verb, args, sigma):
        """`export GIT_X=value` reaches every later command; anything else that touches a GIT_* name is not modelled."""
        out = []
        for cwd, stack, genv in sigma:
            pairs = dict(genv)
            for a in args:
                name = a.text.split("=", 1)[0]
                if name.rstrip("+") in STATE_VARS:
                    self.complete = False        # HOME, CDPATH, PWD, ...: where a cd goes is not modelled
                    continue
                if a.text.startswith("-") or not name.startswith("GIT_"):
                    continue
                value = a.text.split("=", 1)[1] if "=" in a.text else None
                if verb == "unset" and not a.dyn:
                    pairs.pop(name, None)
                elif verb == "export" and value is not None and not a.dyn and not value.startswith("~") and not (self.cond or self.brace):
                    pairs[name] = value
                else:
                    self.complete = False
            out.append((cwd, stack, tuple(sorted(pairs.items()))))
        return self.pool(out), ()

    def run_shell(self, cmd, args, sigma, depth):
        """sh -c "..." (a subshell: nothing carries out), and a shell reading its script from a heredoc, a here-string or a pipe."""
        mode, script = self.shell_mode(args)
        if mode == "c":
            if script is None or script.dyn:
                self.complete = False
            else:
                self.read(script.text, sigma, depth + 1)
        elif mode == "stdin":
            if not cmd.bodies:
                self.complete = False            # the commands arrive on a pipe or a terminal: not visible here
            for body in cmd.bodies:
                if body is None:
                    self.complete = False
                else:
                    self.read(body, sigma, depth + 1)
        elif mode == "unknown":
            self.complete = False

    @staticmethod
    def shell_mode(args):
        """How a shell gets its commands: ("c", the -c script), ("stdin", None), ("file", None) or ("unknown", None)."""
        k, reads_stdin = 0, False
        while k < len(args):
            w = args[k]
            if w.dyn:
                return "unknown", None
            t = w.text
            if t == "--":
                k += 1
                break
            if not t.startswith(("-", "+")) or t in ("-", "+"):
                break
            if t in ("-o", "+o", "-O", "+O"):
                k += 2
                continue
            if t.startswith("-") and not t.startswith("--"):
                if "c" in t[1:]:
                    return "c", (args[k + 1] if k + 1 < len(args) else None)
                if "s" in t[1:]:
                    reads_stdin = True
            k += 1
        if reads_stdin or k >= len(args) or args[k].text == "-":
            return "stdin", None
        return "file", None

    def scan_other(self, name, head, rest, cmd):
        """A command this does not model may carry a push in its arguments (python -c, find -exec, ssh, trap, ...): an argument, or a
        heredoc or here-string it is fed, that names git and push makes the command uncertain. Commands that only print are exempt."""
        if name in DATA_ONLY:
            return
        if GIT_PUSH_TEXT.search(" ".join([head.text] + [w.text for w in rest])):
            self.complete = False
        for body in cmd.bodies:
            if body is None or GIT_PUSH_TEXT.search(body):
                self.complete = False

    @staticmethod
    def change_dir(cwd, args):
        """The directory after `cd <args>`: None when it cannot be known, does not exist or cannot be entered."""
        args, physical = list(args), False
        while args and not args[0].dyn and args[0].text in ("-L", "-P", "-e", "-@"):
            physical = args[0].text == "-P" if args[0].text in ("-L", "-P") else physical
            args.pop(0)
        if args and not args[0].dyn and args[0].text == "--":
            args.pop(0)
        if not args:
            home = os.path.expanduser("~")
            return home if os.path.isdir(home) and os.access(home, os.X_OK) else None
        if len(args) != 1 or args[0].dyn or args[0].text == "-":
            return None
        text = args[0].text
        if os.environ.get("CDPATH") and not args[0].tilde and not text.startswith(("/", "./", "../")) and text not in (".", ".."):
            return None              # a relative name may be found through CDPATH, in the shell's own environment
        target = join_dir(cwd, args[0])
        if target is not None and physical:
            target = os.path.realpath(target)
        return target if target is not None and os.path.isdir(target) and os.access(target, os.X_OK) else None

    def git(self, args, state, env, xargs, elsewhere):
        """`args` follow the git word: its global options, then the subcommand. A push is recorded with the options and GIT_*
        environment it would run with, for git itself to resolve; whatever is not understood exactly makes the command uncertain."""
        cwd = None if elsewhere else state[0]
        genv = dict(state[2])
        genv.update(env)
        opts, k, known = [], 0, cwd is not None
        while k < len(args):
            w = args[k]
            t = w.text
            if w.dyn:
                self.complete = False
                known = False
                k += 1
            elif t in GIT_VALUE_OPTS:
                value = args[k + 1] if k + 1 < len(args) else None
                if value is None or value.dyn:
                    known = False
                elif t in GIT_WHICH_OPTS:
                    text = value.text
                    if value.tilde and t != "-c":
                        text = os.path.expanduser(text)
                        known = known and not text.startswith("~")
                    opts += [t, text]
                k += 2
            elif t.startswith(GIT_ATTACHED):
                if t.startswith(("--git-dir=", "--work-tree=")):
                    opts.append(t)
                k += 1
            elif t in GIT_FLAGS:
                if t == "--bare":
                    opts.append(t)
                k += 1
            elif t.startswith("-"):
                self.complete = False    # a global option this does not know: it may take a value, and shift the subcommand
                known = False
                k += 1
            else:
                break
        sub = args[k] if k < len(args) else None
        if sub is None:
            if xargs:
                self.complete = False    # xargs may hand the subcommand over on stdin
            return
        if sub.dyn:
            self.complete = False
        elif sub.text == "push":
            if known:
                self.targets.append(Push(cwd, opts, genv, args[k + 1:]))
            else:
                self.complete = False
        elif sub.text not in GIT_BUILTINS:
            self.complete = False        # an alias, or an external subcommand: either may be a push


# ---- git decides which repository --------------------------------------------------------------------------------------


def owns(top, gitdir):
    """Does git, started in `top` with nothing else said, name `gitdir` as its repository and `top` as its work tree root?"""
    got = git(["rev-parse", "--absolute-git-dir", "--show-toplevel"], top, rr.git_env({}))
    if got is None or got[0] != 0:
        return False
    lines = got[1].split("\n")
    return len(lines) >= 2 and os.path.realpath(lines[0]) == gitdir and os.path.realpath(lines[1]) == os.path.realpath(top)


def linked_worktree(gitdir):
    """The work tree a linked worktree's git directory records (its `gitdir` file names <work tree>/.git), or None."""
    try:
        with open(os.path.join(gitdir, "gitdir")) as fh:
            text = fh.readline().strip()
    except (OSError, UnicodeDecodeError):
        return None
    return os.path.dirname(text) if os.path.basename(text) == ".git" else None


def repo_root(push):
    """The work tree root of the repository `push` operates on, or None when git cannot say or the two ends disagree. The git
    directory comes from git run with the push's own options, directory and GIT_* environment; the root is checked against it."""
    if not push.cwd or not os.path.isdir(push.cwd):
        return None
    env = rr.git_env(push.env)
    got = git(push.opts + ["rev-parse", "--absolute-git-dir"], push.cwd, env)
    if got is None or got[0] != 0 or not got[1].strip():
        return None
    gitdir = os.path.realpath(got[1].strip())
    candidates = []
    top = git(push.opts + ["rev-parse", "--show-toplevel"], push.cwd, env)
    if top is not None and top[0] == 0 and top[1].strip():
        candidates.append(top[1].strip())
    if os.path.basename(gitdir) == ".git":
        candidates.append(os.path.dirname(gitdir))
    linked = linked_worktree(gitdir)
    if linked:
        candidates.append(linked)
    for cand in candidates:
        if os.path.isdir(cand) and owns(cand, gitdir):
            return os.path.realpath(cand)
    return None


# ---- the class comes from the commits, never from the work tree ---------------------------------------------------------


RECORD = re.compile(rb"([0-7]{6}) (blob|tree|commit) ([0-9a-f]{40}(?:[0-9a-f]{24})?)")   # one `git ls-tree -z` entry, up to the tab


class Unnameable(Exception):
    """git failed, or answered with something it does not print: the commits a push can carry cannot be named, so the strict class applies."""


def push_scope(words):
    """What a push's own words name: (the source of each refspec as written, whether any refspec is named, whether the push is --all /
    --mirror / --tags or has a wildcard, whether it cannot be read)."""
    broad = uncertain = deleting = False
    positional, k = [], 0
    while k < len(words):
        w = words[k]
        k += 1
        if w.dyn:
            uncertain = True
        elif w.text in PUSH_VALUE_OPTS:
            k += 1
        elif w.text.startswith("-") and w.text != "-":
            if w.text in PUSH_BROAD:
                broad = True
            elif w.text in ("-d", "--delete"):
                deleting = True
            elif w.text == "--repo" or w.text.startswith("--repo="):
                uncertain = True         # the repository comes from an option, so the first word is a refspec: not worth parsing
        else:
            positional.append(w.text)
    refspecs, sources, i = positional[1:], [], 0
    while i < len(refspecs):
        spec = refspecs[i]
        i += 1
        if spec == "tag" and i < len(refspecs):      # `git push <remote> tag <name>` means refs/tags/<name>
            spec, i = "refs/tags/" + refspecs[i], i + 1
        source = spec.lstrip("+")
        if ":" in source:
            source = source.split(":", 1)[0]
        if deleting or not source:
            continue                     # `:branch` and --delete remove a ref: no commit travels
        if source.startswith(("-", "^")) or "\0" in source:
            uncertain = True
        elif any(ch in source for ch in "*?["):
            broad = True
        else:
            sources.append(source)
    return sources, bool(refspecs), broad, uncertain


def commit_of(top, env, rev):
    """The commit `rev` names; None when git says plainly that it names none (exit 1, nothing printed); Unnameable on any other answer."""
    got = git(["rev-parse", "-q", "--verify", rev + "^{commit}"], top, env)
    if got is None:
        raise Unnameable("git gave no answer for %s" % rev)
    out = got[1].strip()
    if got[0] == 0 and OID.fullmatch(out):
        return out
    if got[0] == 1 and not out:
        return None
    raise Unnameable("git answered %s with exit %d and %r" % (rev, got[0], out[:40]))


def tracked_refs(top, env):
    """What the branch HEAD is on tracks (its upstream and push refs) and its namesake on origin, as full ref names; none when HEAD is detached."""
    got = git(["symbolic-ref", "-q", "HEAD"], top, env)
    if got is None or got[0] not in (0, 1):
        raise Unnameable("git could not say which branch HEAD is on")
    branch = got[1].strip() if got[0] == 0 else ""
    if not branch:
        return []
    if not branch.startswith("refs/heads/"):
        raise Unnameable("HEAD is a symbolic ref to %r, not to a branch" % branch[:60])
    refs = ["refs/remotes/origin/" + branch[len("refs/heads/"):]]
    got = git(["for-each-ref", "--format=%(upstream) %(push)", branch], top, env)
    if got is None or got[0] != 0:
        raise Unnameable("git could not list what %s tracks" % branch)
    for ref in got[1].split():
        if not ref.startswith("refs/"):
            raise Unnameable("git named a tracking ref %r" % ref[:60])
        refs.append(ref)
    return refs


def config_picks_refs(push):
    """Does push configuration choose the refs a bare `git push` sends (push.default=matching, any remote.<name>.push)? The push's own
    `-c` options and GIT_* environment count, as they do for the real push. Unnameable when git cannot say."""
    got = git(push.opts + ["config", "--get-regexp", r"^(push\.default|remote\..*\.push)$"], push.cwd, rr.git_env(push.env))
    if got is None or got[0] not in (0, 1):
        raise Unnameable("git could not read the push configuration")
    picks = False
    for line in got[1].splitlines():
        key, _, value = line.partition(" ")
        if key == "push.default":
            picks = picks or value.strip().lower() == "matching"
        elif key.startswith("remote.") and key.endswith(".push"):
            picks = True
        else:
            raise Unnameable("git printed %r for a query about push configuration" % line[:60])
    return picks


def scope(top, push):
    """(every commit whose markers decide the class: HEAD, what its branch tracks, origin/HEAD and what the push names; the commits the push
    names as sources, None when they cannot be listed). Unnameable when git fails, or a ref the push names cannot be placed."""
    env = rr.git_env({})
    head = commit_of(top, env, "HEAD")
    if head is None:
        raise Unnameable("HEAD names no commit")
    shas = [head]

    def note(sha):
        if sha not in shas:
            shas.append(sha)

    for ref in tracked_refs(top, env) + ["refs/remotes/origin/HEAD"]:
        sha = commit_of(top, env, ref)
        if sha:
            note(sha)
    sources, explicit, broad, uncertain = push_scope(push.args)
    if uncertain:
        raise Unnameable("the push names refs this does not read")
    named = []
    for rev in sources:
        sha = commit_of(top, env, rev)
        if sha is None:
            raise Unnameable("%s names no commit" % rev)
        note(sha)
        if sha not in named:
            named.append(sha)
    if broad:
        got = git(["for-each-ref", "--format=%(objectname)", "refs/heads", "refs/tags"], top, env)
        tips = got[1].split() if got is not None and got[0] == 0 else None
        if tips is None or len(tips) > MAX_REFS or not all(OID.fullmatch(tip) for tip in tips):
            raise Unnameable("the refs a broad push would send cannot be listed")
        for tip in tips:
            note(tip)
        return shas, None
    if not explicit:
        return shas, None if config_picks_refs(push) else [head]
    return shas, named


def commit_class(top, sha):
    """sweep, repo-checks or unmanaged for ONE commit, read from git objects; None when a marker cannot be inspected."""
    env = rr.git_env({})
    got = git_bytes(["ls-tree", "-z", sha, "--", SWEEP_WRITER, DECLARATION], top, env)
    if got is None or got[0] != 0:
        return None
    entries = {}
    for record in got[1].split(b"\0"):
        if not record:
            continue
        meta, tab, path = record.partition(b"\t")
        found = RECORD.fullmatch(meta)
        name = path.decode("utf-8", "replace")
        if not tab or found is None or name not in (SWEEP_WRITER, DECLARATION):
            return None                  # not what `ls-tree -z` prints for the two paths asked about
        entries[name] = found.groups()
    run_all = entries.get(SWEEP_WRITER)
    if run_all is not None:
        if run_all[1] != b"blob" or run_all[0] not in rr.REGULAR_MODES:
            return None                  # a link, a submodule or a directory where the marker file should be
        blob = git_bytes(["cat-file", "blob", run_all[2].decode("ascii")], top, env)
        if blob is None or blob[0] != 0:
            return None
        if SWEEP_MARK in blob[1]:
            return "sweep"
    declaration = entries.get(DECLARATION)
    if declaration is not None:
        if declaration[1] != b"blob" or declaration[0] not in rr.REGULAR_MODES:
            return None
        return "repo-checks"
    return "unmanaged"


def classify(top, push):
    """(the STRICTEST class over every commit the push can carry or its upstream holds, the commits it names as sources, whether the class is
    only the strict fallback because something could not be read). Sweep, with no sources, when the commits cannot be named or read."""
    try:
        shas, sources = scope(top, push)
    except Unnameable:
        return "sweep", None, True
    best, fallback = "unmanaged", False
    for sha in shas:
        found = commit_class(top, sha)
        if found is None:
            found, fallback = "sweep", True
        if RANK[found] > RANK[best]:
            best = found
    return best, sources, fallback


def extra(cls, sources, fallback):
    """A row's third column: for repo-checks the commits the pushes send, for a sweep row `fallback` when it is only the strict class."""
    if cls == "repo-checks":
        return rr.render_pushed(sources)
    return "fallback" if cls == "sweep" and fallback else ""


def plan(text, base):
    """[(class, directory, extra), ...]: the gates a command that pushes owes. `base` is the session's cwd."""
    found = Resolver()
    found.read(text, ((base, (), ()),), 0)
    uncertain = not found.targets or not found.complete
    rows = {}            # (class, directory) -> [the commits the pushes there send (a list, None when they cannot be listed), strict fallback?]

    def add(cls, top, sources, fallback):
        if "\n" in top or "\t" in top:
            return False
        row = rows.setdefault((cls, top), [[], False])
        row[0] = None if row[0] is None or sources is None else row[0] + [s for s in sources if s not in row[0]]
        row[1] = row[1] or fallback
        return True

    for push in found.targets:
        top = repo_root(push)
        if top is None:
            uncertain = True
            continue
        cls, sources, fallback = classify(top, push)
        if not add(cls, top, sources, fallback):
            uncertain = True
    if uncertain:
        # a command that is not understood exactly: no repository involved gets less than the strict gate, and a repository that declares its
        # own checks still owes the receipt (for commits nobody can list, so it cannot be had until the command is restated)
        seen = list(rows)
        rows.clear()
        for cls, top in seen:
            add("sweep", top, None, True)
            if cls == "repo-checks":
                add("repo-checks", top, None, False)
        add("sweep", repo_root(Push(base, [], {}, [])) or base, None, True)
    return [(cls, top, extra(cls, sources, fallback)) for (cls, top), (sources, fallback) in rows.items()]


class Timeout(Exception):
    """HMD_PUSH_TARGET_TIMEOUT_S ran out before the command was read."""


def _timed_out(signum, frame):
    raise Timeout()


def main():
    if hasattr(signal, "setitimer"):
        signal.signal(signal.SIGALRM, _timed_out)
        signal.setitimer(signal.ITIMER_REAL, TIMEOUT_S)
    base = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 and os.path.isdir(sys.argv[1]) else os.getcwd()
    try:
        rows = plan(sys.stdin.buffer.read().decode("utf-8", "replace"), base)
    except Exception as exc:  # no answer is not "no gate": the hook falls back to the sweep gate on the cwd
        sys.stderr.write("hmd_push_target: %s: %s\n" % (type(exc).__name__, exc))
        return 1
    if hasattr(signal, "setitimer"):
        signal.setitimer(signal.ITIMER_REAL, 0)
    sys.stdout.write("".join("\t".join(row if row[2] else row[:2]) + "\n" for row in rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
