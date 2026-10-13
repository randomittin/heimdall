#!/usr/bin/env python3
r"""hmd_push_target -- WHICH repository does this Bash command push, and which push gate does that repository owe?

bin/heimdall-precheck-bash used to run heimdall's own sweep gate in the session's cwd for any push, so a push of another
repository (a site with checks of its own) was held to a receipt only heimdall's sweep can write. It now asks this file, once
per push command, for the repositories the command pushes and the class of each, and runs the gate that class owes.

Protocol: the command text on stdin, the session's cwd as argv[1]; one line `class<TAB>toplevel` per gate, in the order first
met. Exit 0. Anything else (a crash, a timeout, no output) tells the hook to run the sweep gate on the cwd repository exactly as
before.

FAIL CLOSED, the one rule everything below serves. The warn-only class (unmanaged) is answered ONLY for a repository that git
itself resolved AND that positively carries none of heimdall's markers. Whatever is uncertain -- a command this cannot read in full,
a push whose directory or options are held in a variable, a git option or subcommand it does not know (an alias may be a push), a
GIT_* variable set in a way it does not model, a missing or unreadable path, a repository git cannot place, a marker file that is
there but cannot be read, a work tree missing the very files git tracks -- is answered with the strict class, `sweep`, for the
repository resolved or, failing that, the cwd. A wrong or missing answer can therefore only ever make a gate STRICTER than the
repository's class says, never weaker.

WHICH REPOSITORY IS ASKED OF GIT, NOT READ OFF THE COMMAND. Every push found is rebuilt as the exact `git <global options>
rev-parse` call, started in the directory the shell would be in, with the same GIT_* environment, and git answers with the git
directory the push would operate on (`-C` accumulates the way git accumulates it, `--git-dir`, `GIT_DIR`, `-c core.worktree`,
discovery from a subdirectory or a linked worktree are all git's). `--work-tree` and `GIT_WORK_TREE` do not change which repository
is pushed, so they cannot point a push at a decoy. The work tree root of that git directory is then taken from candidates (what
`--show-toplevel` says, the parent of a `.git`, the work tree a linked worktree records) and each is checked from the other end: git
run from the candidate must name the same git directory and the same toplevel, or the candidate is refused.
What this file reads itself is only what git cannot be asked: the shell (quotes, `;` `&&` `|` `(` `)`, `cd` and `pushd`, a subshell's
`cd` going nowhere, `env`/`sudo`/`command`/`exec`/`time`/`nohup`/`nice`/`xargs`, `sh -c` and `eval` strings, heredocs as data,
`export GIT_DIR=...`). A shell cannot be read completely (a command can build a verb or a path at run time), so the native hook
(core.hooksPath) stays the hard backstop; what this never does is turn "could not tell" into "no gate".

CLASS of a verified work tree root, first match wins:
  sweep        <root>/test/run-all.sh is a regular file that names last-sweep.json. That is heimdall's own sweep regime: the script
               writes the receipt (.heimdall/receipts/last-sweep.json) that `heimdall-state check-quality-gates` demands. The marker
               is TRACKED CODE, never the receipt: deleting a receipt must not downgrade a repository, and another project's
               test/run-all.sh does not name that file. Also sweep: that file, or .heimdall/repo-checks.json, being present but not a
               readable regular file (a dangling link, a directory), or tracked by git (index or HEAD) yet missing on disk (a sparse
               or no-checkout work tree), or git unable to say.
  repo-checks  <root>/.heimdall/repo-checks.json is a regular file: the repository declares its own checks (bin/heimdall-repo-checks)
               and passes only on a green, current receipt of them. Present-but-invalid is still this class and blocks.
  unmanaged    anything else: the hook prints one warning and lets the push through. The secret and self-scan gates are not part of
               this class rule and still run.

Python 3.7+, standard library only. HMD_PUSH_TARGET_TIMEOUT_S (default 5) bounds the whole run.
"""
import errno
import os
import re
import signal
import subprocess
import sys

SWEEP_MARK = b"last-sweep.json"
SWEEP_WRITER = "test/run-all.sh"
DECLARATION = ".heimdall/repo-checks.json"
MAX_DEPTH = 8        # shell strings (sh -c, eval) read inside shell strings
MAX_NESTING = 40     # substitutions and subshells inside each other
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\+?=")
NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
DURATION = re.compile(r"^[0-9.]+[smhd]?$")
RESERVED = frozenset(("if", "then", "else", "elif", "fi", "while", "until", "do", "done", "!", "{", "}"))
SKIPPED = frozenset(("for", "select", "case", "function", "in", "esac"))  # what follows is a name or a pattern, not a command
SHELLS = frozenset(("sh", "bash", "zsh", "dash", "ksh", "ash", "mksh"))
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
GIT_AMBIENT = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE")  # a stray one in THIS process must not redirect git
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

try:
    TIMEOUT_S = float(os.environ.get("HMD_PUSH_TARGET_TIMEOUT_S", "5"))
except ValueError:
    TIMEOUT_S = 5.0


class Word(object):
    """One shell word: its text with quotes and escapes removed; dyn when an expansion or glob makes the value unknowable;
    tilde when it began with an unquoted ~."""
    __slots__ = ("text", "dyn", "tilde")

    def __init__(self, text, dyn, tilde):
        self.text, self.dyn, self.tilde = text, dyn, tilde


class Cmd(object):
    """A simple command: its words (redirections removed) and the operators that ended the command before it and ends it."""
    __slots__ = ("words", "before", "after")

    def __init__(self, words, before, after):
        self.words, self.before, self.after = words, before, after


class Lexer(object):
    """Text -> a list of items, each a Cmd or a nested list (a group whose directory changes go nowhere: a subshell, a
    substitution). A substitution's commands are listed just ahead of the command that holds it. Whatever cannot be read
    faithfully sets `unparsed` instead of being guessed at."""

    def __init__(self, text):
        self.s, self.n, self.i = text, len(text), 0
        self.unparsed = None
        self.heredocs = []   # (delimiter, tabs stripped) whose body starts on the line after the current one
        self.depth = 0

    def flag(self, why):
        if self.unparsed is None:
            self.unparsed = why

    def skip_heredoc(self, delim, tabs):
        s = self.s
        while self.i < self.n:
            j = s.find("\n", self.i)
            line = s[self.i:] if j < 0 else s[self.i:j]
            self.i = self.n if j < 0 else j + 1
            if (line.lstrip("\t") if tabs else line) == delim:
                return
        self.flag("a heredoc without its terminator")

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

    def expansion(self, i, hoist):
        """s[i] is '$': lex what it starts, return the index after it. A $( ... ) is lexed in place and its commands go to hoist."""
        s = self.s
        nx = s[i + 1] if i + 1 < self.n else ""
        if nx == "(":
            if s.startswith("$((", i):
                return self.skip_balanced(i + 1, "(", ")")
            self.i = i + 2
            hoist.append(self.parse(")"))
            return self.i
        if nx == "{":
            return self.skip_balanced(i + 1, "{", "}")
        if nx == "[":
            return self.skip_balanced(i + 1, "[", "]")
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
                self.i = i + 1
                hoist.append(self.parse("`"))
                out.append(s[i:self.i])
                dyn, i = True, self.i
            else:
                out.append(c)
                i += 1
        self.i = self.n
        self.flag(U_QUOTE)
        return "".join(out), dyn

    def parse(self, stop):
        """The commands up to `stop` (')' or a backtick closing a substitution; None = the end of the text)."""
        s, n = self.s, self.n
        out, words, hoist = [], [], []
        word = None                  # the pieces of the word being built, None between words
        dyn = tilde = brace = False
        redir = None                 # a redirection's operator while its target word is still to come ("<<" and "<<-": a heredoc)
        prev = ""                    # the operator that ended the command before this one
        self.depth += 1
        if self.depth > MAX_NESTING:
            self.flag("substitutions nested too deep")
            self.i = n
            self.depth -= 1
            return out

        def open_word(is_tilde=False):
            nonlocal word, dyn, tilde, brace
            if word is None:
                word, dyn, tilde, brace = [], False, is_tilde, False

        def end_word():
            nonlocal word, dyn, tilde, brace, redir
            if word is None:
                return
            text = "".join(word)
            if redir is not None:
                if redir in ("<<", "<<-"):
                    self.heredocs.append((text, redir == "<<-"))
                redir = None
            else:
                words.append(Word(text, dyn or (brace and text not in ("{", "}")), tilde))
            word, dyn, tilde, brace = None, False, False, False

        def end_cmd(op):
            nonlocal prev, redir
            end_word()
            redir = None
            out.extend(hoist)
            del hoist[:]
            if words:
                out.append(Cmd(list(words), prev, op))
                del words[:]
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
                for delim, tabs in self.heredocs:
                    self.skip_heredoc(delim, tabs)
                del self.heredocs[:]
            elif c == "#" and word is None:
                j = s.find("\n", i)
                self.i = n if j < 0 else j
            elif c == "\\":
                if s.startswith("\n", i + 1):
                    self.i = i + 2
                else:
                    open_word()
                    word.append(s[i + 1:i + 2])
                    self.i = i + 2
            elif c == "'":
                open_word()
                j = s.find("'", i + 1)
                if j < 0:
                    self.flag(U_QUOTE)
                word.append(s[i + 1:] if j < 0 else s[i + 1:j])
                self.i = n if j < 0 else j + 1
            elif c == '"':
                open_word()
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
                self.i = i + 1
                hoist.append(self.parse("`"))
                word.append(s[i:self.i])
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
                end_cmd("")
                self.i = i + 1
                out.append(self.parse(")"))
            elif c == ")":
                end_cmd(")")
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
                    hoist.append(self.parse(")"))
                    word.append(s[i:self.i])
                    dyn = True
                else:
                    op = next(o for o in REDIRS if s.startswith(o, i))
                    redir = op if op in ("<<", "<<-") else ""
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
        return out


class Shell(object):
    """What the commands so far did to the shell: the working directory (None = cannot be known), the pushd stack, and the GIT_*
    variables exported to every later command."""
    __slots__ = ("cwd", "stack", "genv")

    def __init__(self, cwd, stack=(), genv=None):
        self.cwd, self.stack, self.genv = cwd, list(stack), dict(genv or {})

    def copy(self):
        return Shell(self.cwd, self.stack, self.genv)


class Push(object):
    """One push as the shell would run it: the directory git starts in, git's global options that decide WHICH repository (-C, -c,
    --git-dir, --work-tree, --bare: the literal words, in order) and the GIT_* environment it runs with."""
    __slots__ = ("cwd", "opts", "env")

    def __init__(self, cwd, opts, env):
        self.cwd, self.opts, self.env = cwd, opts, env


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


class Resolver(object):
    def __init__(self):
        self.targets = []        # one Push per push whose directory and options could be read
        self.complete = True     # False once anything could not be read or modelled exactly

    def read(self, text, shell, depth):
        if depth > MAX_DEPTH:
            self.complete = False
            return
        lexer = Lexer(text)
        items = lexer.parse(None)
        if lexer.unparsed:
            self.complete = False
        self.walk(items, shell, depth)

    def walk(self, items, shell, depth):
        for item in items:
            if isinstance(item, list):
                self.walk(item, shell.copy(), depth)
            else:
                self.command(item, shell, depth)

    def note_assignment(self, env, word):
        """VAR=value in front of a command (or after env): GIT_* ones reach git, and must be literal to be modelled."""
        m = ASSIGN.match(word.text)
        if not m.group(1).startswith("GIT_"):
            return
        value = word.text[m.end():]
        if word.dyn or value.startswith("~"):
            self.complete = False
        else:
            env[m.group(1)] = value

    def unwrap(self, base, args, cwd, env):
        """The words a wrapper (env, sudo, xargs, ...) runs, and the directory it runs them in."""
        takes, k = WRAPPERS[base], 0
        if base == "command" and args and args[0].text in ("-v", "-V"):
            return [], cwd           # only looks the name up
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
                    cwd = None       # runs elsewhere: where, this does not follow
                if base == "env" and (t in ("-S", "--split-string") or t.startswith("--split-string=")):
                    self.complete = False
                k += 2 if t in takes else 1
            else:
                break
        rest = args[k:]
        if base == "timeout" and rest and DURATION.match(rest[0].text):
            rest = rest[1:]
        return rest, cwd

    def command(self, cmd, shell, depth):
        words, env, cwd = list(cmd.words), {}, shell.cwd
        while words:
            w = words[0]
            if w.dyn and w.text[:1] in ("$", "`") and "/" not in w.text:
                self.complete = False    # a command name held in a variable (or a substitution) may be git
                return
            if ASSIGN.match(w.text):
                self.note_assignment(env, w)
                words.pop(0)
            elif not w.dyn and w.text in RESERVED:
                words.pop(0)
            elif not w.dyn and w.text in SKIPPED:
                return
            elif not w.dyn and os.path.basename(w.text).lower() in WRAPPERS:
                words, cwd = self.unwrap(os.path.basename(w.text).lower(), words[1:], cwd, env)
            else:
                break
        if not words:
            if env:
                self.complete = False    # a bare GIT_*=value may update a variable that is already exported: not modelled
            return
        head, rest = words[0], words[1:]
        if head.dyn:
            return
        name = os.path.basename(head.text)
        piped = cmd.before in ("|", "|&") or cmd.after in ("|", "|&", "&")   # a subshell of its own: a cd here goes nowhere
        if head.text == "cd":
            if not piped:
                shell.cwd = self.change_dir(shell.cwd, rest)
        elif head.text == "pushd":
            if not piped:
                if len(rest) == 1 and not rest[0].dyn and not rest[0].text.startswith(("-", "+")):
                    shell.stack.append(shell.cwd)
                    shell.cwd = self.change_dir(shell.cwd, rest)
                else:
                    shell.cwd = None
        elif head.text == "popd":
            if not piped:
                shell.cwd = shell.stack.pop() if shell.stack else None
        elif head.text in ("export", "declare", "typeset", "readonly", "local", "unset"):
            self.exports(head.text, rest, shell)
        elif head.text in ("source", "."):
            self.complete = False        # a sourced script may cd, export, or define anything
        elif name == "git":
            self.git(rest, cwd, env, shell)
        elif name in SHELLS:
            script = self.shell_string(rest)
            if script is not None:
                if script.dyn:
                    self.complete = False
                else:
                    self.read(script.text, Shell(cwd, shell.stack, shell.genv), depth + 1)
        elif head.text == "eval":
            if any(w.dyn for w in rest):
                self.complete = False
            self.read(" ".join(w.text for w in rest), Shell(cwd, shell.stack, shell.genv), depth + 1)

    def exports(self, verb, args, shell):
        """`export GIT_X=value` reaches every later command; anything else that touches a GIT_* name is not modelled."""
        for a in args:
            name = a.text.split("=", 1)[0]
            if a.text.startswith("-") or not name.startswith("GIT_"):
                continue
            value = a.text.split("=", 1)[1] if "=" in a.text else None
            if verb == "unset" and not a.dyn:
                shell.genv.pop(name, None)
            elif verb == "export" and value is not None and not a.dyn and not value.startswith("~"):
                shell.genv[name] = value
            else:
                self.complete = False

    @staticmethod
    def shell_string(args):
        """The -c script of `sh -c ...` (also -lc, -ec, ...), or None when this shell is not given one."""
        k = 0
        while k < len(args) and not args[k].dyn:
            t = args[k].text
            if t == "--" or not t.startswith(("-", "+")) or t in ("-", "+"):
                return None
            if t in ("-o", "+o", "-O", "+O"):
                k += 2
            elif t.startswith("-") and not t.startswith("--") and "c" in t[1:]:
                return args[k + 1] if k + 1 < len(args) else None
            else:
                k += 1
        return None

    @staticmethod
    def change_dir(cwd, args):
        """The directory after `cd <args>`: None when it cannot be known or does not exist (a command may be about to create it)."""
        args, physical = list(args), False
        while args and not args[0].dyn and args[0].text in ("-L", "-P", "-e", "-@"):
            physical = args[0].text == "-P" if args[0].text in ("-L", "-P") else physical
            args.pop(0)
        if args and not args[0].dyn and args[0].text == "--":
            args.pop(0)
        if not args:
            home = os.path.expanduser("~")
            return home if os.path.isdir(home) else None
        if len(args) != 1 or args[0].dyn or args[0].text == "-":
            return None
        text = args[0].text
        if os.environ.get("CDPATH") and not args[0].tilde and not text.startswith(("/", "./", "../")) and text not in (".", ".."):
            return None              # a relative name may be found through CDPATH, in the shell's own environment
        target = join_dir(cwd, args[0])
        if target is not None and physical:
            target = os.path.realpath(target)
        return target if target is not None and os.path.isdir(target) else None

    def git(self, args, cwd, env, shell):
        """`args` follow the git word: its global options, then the subcommand. A push is recorded with the options and GIT_*
        environment it would run with, for git itself to resolve; whatever is not understood exactly makes the command uncertain."""
        opts, k, known = [], 0, cwd is not None
        genv = dict(shell.genv)
        genv.update(env)
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
            return
        if sub.dyn:
            self.complete = False
        elif sub.text == "push":
            if known:
                self.targets.append(Push(cwd, opts, genv))
            else:
                self.complete = False
        elif sub.text not in GIT_BUILTINS:
            self.complete = False        # an alias, or an external subcommand: either may be a push


def git_env(extra):
    env = dict((k, v) for k, v in os.environ.items() if k not in GIT_AMBIENT)
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env.update(extra)
    return env


def run_git(args, cwd, env):
    """(exit status, stdout) of git, or None when it cannot run at all (no git, no such directory, a timeout)."""
    try:
        done = subprocess.run(["git"] + args, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=max(TIMEOUT_S, 1.0))
    except (OSError, subprocess.SubprocessError):
        return None
    return done.returncode, done.stdout.decode("utf-8", "replace")


def owns(top, gitdir):
    """Does git, started in `top` with nothing else said, name `gitdir` as its repository and `top` as its work tree root?"""
    got = run_git(["rev-parse", "--absolute-git-dir", "--show-toplevel"], top, git_env({}))
    if got is None or got[0] != 0:
        return False
    lines = got[1].split("\n")
    return len(lines) >= 2 and os.path.realpath(lines[0]) == gitdir and os.path.realpath(lines[1]) == os.path.realpath(top)


def linked_worktree(gitdir):
    """The work tree a linked worktree's git directory records (its `gitdir` file names <work tree>/.git), or None."""
    try:
        with open(os.path.join(gitdir, "gitdir")) as fh:
            text = fh.readline().strip()
    except OSError:
        return None
    return os.path.dirname(text) if os.path.basename(text) == ".git" else None


def repo_root(push):
    """The work tree root of the repository `push` operates on, or None when git cannot say or the two ends disagree. The git
    directory comes from git run with the push's own options, directory and GIT_* environment; the root is checked against it."""
    if not push.cwd or not os.path.isdir(push.cwd):
        return None
    env = git_env(push.env)
    got = run_git(push.opts + ["rev-parse", "--absolute-git-dir"], push.cwd, env)
    if got is None or got[0] != 0 or not got[1].strip():
        return None
    gitdir = os.path.realpath(got[1].strip())
    candidates = []
    top = run_git(push.opts + ["rev-parse", "--show-toplevel"], push.cwd, env)
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


def probe(path):
    """'file' (a regular file, or a link to one), 'absent', or 'unknown': something is there that is not a plain file, or the
    answer is an error."""
    try:
        os.lstat(path)
    except OSError as exc:
        return "absent" if exc.errno in (errno.ENOENT, errno.ENOTDIR) else "unknown"
    return "file" if os.path.isfile(path) else "unknown"


def tracked(top, paths):
    """The members of `paths` git holds in its index or in HEAD for the work tree `top`; None when git cannot say."""
    env = git_env({})
    got = run_git(["ls-files", "-z", "--"] + paths, top, env)
    if got is None or got[0] != 0:
        return None
    held = set(name for name in got[1].split("\0") if name)
    got = run_git(["ls-tree", "-r", "--name-only", "-z", "HEAD", "--"] + paths, top, env)
    if got is None:
        return None
    if got[0] == 0:
        held.update(name for name in got[1].split("\0") if name)
    else:
        unborn = run_git(["rev-parse", "-q", "--verify", "HEAD"], top, env)
        if unborn is None or unborn[0] == 0:
            return None                  # HEAD exists and ls-tree still failed: git cannot say
    return held


def classify(top):
    """sweep, repo-checks or unmanaged for a work tree root git resolved; unmanaged only when the markers are positively absent."""
    run_all = probe(os.path.join(top, *SWEEP_WRITER.split("/")))
    decl = probe(os.path.join(top, *DECLARATION.split("/")))
    if run_all == "file":
        try:
            with open(os.path.join(top, *SWEEP_WRITER.split("/")), "rb") as fh:
                if SWEEP_MARK in fh.read(4 * 1024 * 1024):
                    return "sweep"
        except OSError:
            return "sweep"
    if "unknown" in (run_all, decl):
        return "sweep"
    gone = [rel for rel, state in ((SWEEP_WRITER, run_all), (DECLARATION, decl)) if state == "absent"]
    if gone:
        held = tracked(top, gone)
        if held is None or held:
            return "sweep"               # git has it, the disk does not (sparse, no-checkout, half deleted), or git cannot say
    return "repo-checks" if decl == "file" else "unmanaged"


def plan(text, base):
    """[(class, directory), ...]: the gates a command that pushes owes. `base` is the session's cwd."""
    found = Resolver()
    found.read(text, Shell(base), 0)
    uncertain = not found.targets or not found.complete
    rows = []

    def add(cls, top):
        if "\n" in top or "\t" in top:
            return False
        if (cls, top) not in rows:
            rows.append((cls, top))
        return True

    for push in found.targets:
        top = repo_root(push)
        if top is None or not add(classify(top), top):
            uncertain = True
    if uncertain:
        add("sweep", repo_root(Push(base, [], {})) or base)
    return rows


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
    sys.stdout.write("".join("%s\t%s\n" % row for row in rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
