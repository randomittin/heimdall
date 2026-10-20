#!/usr/bin/env python3
r"""suite_closure -- the static dependency closure of every test suite, the hash of it, the salt that invalidates every cached result at
once, and `verify-receipt`, which re-derives all of it at a graded commit instead of trusting a receipt's flag.

WHY. A per-suite result cache may reuse a green result only if nothing the suite could have read has changed. Dynamic tracing needs
root on macOS, so the closure is STATIC and deliberately OVER-approximating: a suite re-runs more often than strictly needed, never less
often than it should. What a static scan cannot see (a computed path, a binary injected through the environment) is bounded by the
cache's audit sample and age limit, and named in test/closure-hints.json. test/suite-closure.test.sh is the mutation proof: each kind of
dependency below is edited one byte at a time and the closure hash must change.

THE GRAPH (everything is read from git OBJECTS at one commit, never from the work tree).
  nodes     every tracked file except the hooks' own journal and ledger writes (bin/lib/hook-owned-path.sh: they change on every
            auto-commit and no suite reads them as input; run-all.sh and the sweep gate exempt them the same way).
  suite     test/<name>.test.sh. The root of one closure.
  code      has outgoing edges: bin/ hooks/ sentinels/ release/ adapters/ relay/ test/lib/ .heimdall/hooks/, anything with an executable bit,
            and any .sh/.py/.js/.ts/... anywhere. Extensionless files in those directories are code.
  data      every other file (.md .json .yaml .txt, fixtures, images). A leaf: it enters the hash, it never leads anywhere.
  edge      A -> B when A contains B as a WHOLE TOKEN (a maximal run of letters, digits and _ . - /; `rr` is not in "error", `heimdall`
            is not in `heimdall-state`):
              - a path: the token, or any suffix of it that starts at a `/` (so `$REPO/bin/x`, `"$HERE"/lib/x.sh`, `../bin/x` all find
                bin/x), equals a tracked path or the tail of one. The most specific suffix that matches wins.
              - a bare name matches the basename of a CODE node (`tool-x` finds bin/tool-x). A PLAIN word (no - _ . : `heimdall`, `hmd`,
                `corpus`) names a tool only in command position (`hmd init`, `exec "$dir/heimdall"`): the project's own name is in every
                log line and usage text. A bare data name (README.md, .gitignore, VERSION) is OUR file only in a suite; in a tool it is
                the target project's.
              - Python `import x` / `from x import y` (also inside `python3 -c` and heredocs in shell) and JS `require('./x')` /
                `import ... from './x'` reach the module's file.
              - a SUITE that names a directory (a token with a `/`, written under the repo root or the test directory) takes every tracked
                file under it into its closure: they are hashed, but what THEY reach is not followed. A glob after a path in a suite
                (`$REPO/bin/*`) takes the directory AND follows what it reaches. A tool's directories and globs count for nothing (a hub
                script that prints "see docs/" or copies skills/ made 94% of the suites depend on 90% of the tree, measured), neither does
                a directory on a `PATH=` line, an absolute system path (/usr/bin) or a fixture repo's `"$d/bin"`.
              - a tool (or run-all.sh's list of live suites) that names a suite file takes it as a leaf: only a suite RUNS another suite.
              - text a shell file only PRINTS is no edge (DisplayScan lexes the file the way bash does): a quoted word with a space in an `echo` or
                `printf` that prints to the terminal, the body of a bare `cat` here-document (written to a file too, unless a `#!` line says it is
                a script), a trailing comment. Kept, because the file may read or run what they name: a lone path-like word (how a function hands back
                a value), anything redirected to a file, piped, captured by `$( )` or an array, a word with a substitution, a script-like line
                (`exec`, `source`, `&&`, `$@`). A file the lexer cannot read to its end drops nothing.
            Comment lines and Python docstrings count for a SUITE only as FILE names (its header names what it tests): never a plain word,
            a directory or another suite. For a tool they count for nothing (the 2026-10-12 comment-chain incident, bin/lib/sweep-chain.sh).
  dispatch  bin/heimdall routes `hmd <word>` to one arm of its top-level `case "${1:-}"`. What an arm names is followed only when the
            suite's closure invokes that word; a function of the dispatcher only when some followed text names it (a call, a trap, a string);
            what the dispatcher names OUTSIDE its arms and functions is always followed. An invocation is `heimdall`, `hmd`, a path ending in
            one, or a variable that may hold one, in COMMAND position, followed by a word: a mention in text (`die "run hmd init"`) is no call,
            and `FACE_BIN="$DIR/heimdall-face"` then `"$FACE_BIN" "$mode"` is another tool. A variable the file never sets counts when some
            file in the repository sets it to the dispatcher. bin/hmd is a pure forwarder and its own `"$@"` is not an invocation. An
            invocation with a non-literal word (`hmd "$cmd"`, `hmd "$@"`) follows every arm.
  wildcard  a SUITE whose code enumerates the tree depends on the WHOLE tree: `git ls-files|ls-tree|grep`, `find`/`grep -r`/`cp -r`
            on the repo root, a glob right after the repo root variable. A tool that does (bin/heimdall-team runs `git ls-files`) works on
            whatever repository it is pointed at, a fixture in nearly every suite, so it is not followed: a suite that points one at the
            real repo belongs in the hints as always_run. Measured: following them made all 538 suites whole-tree.
  hints     test/closure-hints.json {"<suite>": {"extra": [paths|dirs], "always_run": bool}}: extra paths join that suite's closure
            (and what they reach); always_run makes the closure the whole tree (the suite re-runs on ANY change, and is reusable only
            on a byte-identical tree). A hint that names nothing is an error, never a silent no-op.

closure_sha  sha256 over the sorted lines `path<TAB>id` of the closure. A file's id is its blob id, except for a SHELL or PYTHON file (by suffix, or by
             the #! line of a file that has none), whose id is the digest of what it does without what it only says:
               shell   without blank lines, full-line comments (a #! line stays) and trailing blanks; NOT inside a here-document body, a multi-line
                       quoted string, or on the line a backslash joins to the one before (a comment or a blank there is data, or changes where a
                       command ends); a trailing comment and `\r` stay. A line the scanner cannot place is kept: it over-approximates.
               python  its tokens without comments (a #! first line stays) and non-logical newlines; docstrings and other strings stay (they are
                       visible at run time), and so do the indentation and the encoding.
             The blob id, as committed, stands wherever the file can be read as TEXT: a shell script that holds a command that reads or copies text AND
             expands its own path ($0, ${0##*/}, $BASH_SOURCE) anywhere, a Python file that does not tokenize or names its own path (__file__,
             sys.argv[0]) and opens a file, a shell file with a `$( )`, `${ }` or backtick inside double quotes whose quotes the scanner cannot pair
             (it runs past the line, holds a backslash or a `#`), the paths a hint adds, everything a SUITE or any file it runs hands to a command
             that reads (grep, sed, cat, shasum, shellcheck, find, a `<` redirect) or enumerates with one, and every file of a suite whose closure
             is the whole tree: a lint that greps comments for a version pin sees a comment as a change. A file only SOURCED, RUN or IMPORTED does
             not; what a suite reads through a variable or a loop cannot be seen, and is bounded like any unseen read by the audit sample and the
             age limit.
salt         sha256 over the RUNNER's own infrastructure and nothing else: the schema; test/run-all.sh with its FULL-LINE comments stripped
             (a `#!` line stays; its raw blob when a heredoc body line starts with `#`, because that line is data and the stripper
             could hide a real change); the two runner libraries test/lib/run-all-guards.sh and test/lib/py-pin.sh; bin/lib/sweep-chain.sh
             and bin/lib/hook-owned-path.sh; the hints; bin/lib/suite-cache.sh (all as committed); the engine's own files (this file,
             its launcher, hook-owned-path.sh); the bash/jq/python3/git versions and `uname -sm`. The other test/lib files are per-suite
             helpers: closure edges, so editing one re-runs the suites that name it and does not make the whole sweep cold (measured:
             2.4.8's comment-only edit of run-all.sh and four test/lib/*_cases.py files would have made every suite re-run).
             Any change to a salted input = every cached result invalid.
verify-receipt  a sweep receipt (kind "full") carries a `cache` block:
               {mode:"closure", salt, suites_fresh, suites_cached, audited, cold, oldest_entry_age_days,
                entries:[{suite, closure_sha, finished_at}]}
             and is accepted only when, recomputed at its head_sha: the salt is the same; every entry's closure_sha is the same; every
             suite that is not live (test/run-all.sh's own live_reason) has an entry; no entry is older than 7 days (a cold receipt, in
             which every suite ran in that sweep, is exempt); and the audit sample was drawn: audited >= min(hits, max(20, 10% of the
             hits)), hits = suites_cached + audited. HMD_SUITE_CACHE_MAX_DAYS may only LOWER the 7, HMD_SUITE_CACHE_AUDIT_PCT may only
             RAISE the 10.

A cooperating-agent control, not a security boundary: like last-sweep.json it is a plain local file, and it catches stale, copied and
hand-edited-by-accident receipts, not someone who can recompute every hash.

Python 3.7+, standard library only.
"""
import argparse
import datetime
import fnmatch
import hashlib
import io
import json
import math
import os
import platform
import re
import signal
import subprocess
import sys
import tokenize

SCHEMA = 3                      # part of the salt: bump it whenever the rules above change what a closure is (2: shell and Python files are hashed without their comments; 3: text a shell file only prints is no edge, the dispatcher follows only the arms a suite can reach, files any node reads as text and any self-reading script are hashed as committed)
HINTS = "test/closure-hints.json"
RUN_ALL = "test/run-all.sh"
CACHE_LIB = "bin/lib/suite-cache.sh"
# the runner's infrastructure beyond RUN_ALL, salted as committed. The rest of test/lib is per-suite helpers: closure edges, not salt.
RUNNER_LIBS = ("test/lib/run-all-guards.sh", "test/lib/py-pin.sh", "bin/lib/sweep-chain.sh", "bin/lib/hook-owned-path.sh")
SUITE_RE = re.compile(r"^test/[^/]+\.test\.sh$")
MAX_AGE_DAYS = 7
AUDIT_FLOOR = 20
AUDIT_PCT = 10
MAX_SCAN = 4 << 20              # a file over 4 MiB is not scanned: a data leaf
MAX_RECEIPT = 64 << 20
WHOLE = "\0whole-tree"          # the pseudo-path "everything": an edge to it makes the closure the whole tree
DISPATCHERS = frozenset(["bin/heimdall"])
FORWARDERS = frozenset(["bin/hmd"])
GIT_AMBIENT = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE")   # a stray one in THIS process must not redirect git

EXEC_DIRS = ("bin/", "hooks/", "sentinels/", "release/", "adapters/", "relay/", "test/lib/", ".heimdall/hooks/")
CODE_SUFFIXES = frozenset([".sh", ".bash", ".zsh", ".py", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".rb", ".pl", ".awk", ".c", ".h"])
DATA_SUFFIXES = frozenset([".md", ".json", ".yaml", ".yml", ".txt", ".toml", ".csv", ".tsv", ".ndjson", ".jsonl", ".svg", ".png", ".jpg", ".jpeg",
                           ".gif", ".ico", ".pdf", ".lock", ".html", ".css", ".ref", ".example", ".patch", ".pub", ".minisig", ".gbdoctor", ".map"])
C_STYLE = frozenset([".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".c", ".h"])      # // and /* */ comments; a `#` line is code (#include)
JS_STYLE = frozenset([".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx"])

TOK_RE = re.compile(r"([A-Za-z0-9_.\-/]+)([*?\[])?")
# /usr/bin, /tmp/x, /Users/..: a filesystem path, not a repo path (unless it is glued to a variable: "$REPO"/bin/x)
SYSTEM_ABS_RE = re.compile(r"^/(?:usr|bin|sbin|etc|dev|tmp|var|opt|private|Users|System|Library|Applications|home|proc|sys|lib|run|mnt|Volumes|root|nix|snap|srv)(?:/|$)")
PATH_ASSIGN_RE = re.compile(r"\b[A-Z_]*PATH=")
VAR_BEFORE_RE = re.compile(r"\$\{?(\w+)\}?[\"']?$")
ROOT_NAMES = ("REPO", "ROOT", "REPO_ROOT", "REPO_DIR", "PLUGIN_DIR", "PLUGIN_ROOT", "PLUGIN", "PROJECT_ROOT", "HMD_ROOT", "SRC_DIR", "CLAUDE_PLUGIN_ROOT")
# variables that name the repo root or the test directory: a directory written under one of them is the REAL one (a fixture repo's
# `"$d/bin"` is not, and pulling in the real bin/ for every suite that builds a fixture would defeat the point)
DIR_VARS = frozenset(ROOT_NAMES + ("HERE", "SELF_DIR", "SCRIPT_DIR", "TEST_DIR", "TESTS_DIR", "THIS_DIR", "SUITE_DIR", "ROOT_DIR", "BASE_DIR"))
ROOT_VARS = r"(?:" + "|".join(ROOT_NAMES) + r")"
ROOT_REF = r'"?\$\{?' + ROOT_VARS + r'\}?"?'
ROOT_BEFORE_RE = re.compile(ROOT_REF + r"$")
QUICK_WHOLE_RE = re.compile(r"\b(?:git|find|grep|cp|rsync|tar|ditto)\b")
WHOLE_RES = (
    re.compile(r"\bgit\b(?:\s+(?:-C\s+\S+|-c\s+\S+|--[\w-]+(?:=\S+)?))*\s+(?:ls-files|ls-tree|grep)\b"),
    re.compile(r"\bfind\s+(?:-[A-Za-z]+\s+)*" + ROOT_REF + r"(?=\s|$)"),
    re.compile(r"\bgrep\s+-[A-Za-z]*[rR][A-Za-z]*\s[^|;&\n]*" + ROOT_REF + r"/?(?=\s|$)"),
    re.compile(r"\b(?:cp|rsync|tar|ditto)\s[^|;&\n]*" + ROOT_REF + r"/?(?=\s|$)"),
)
# the dispatcher's name as a command: heimdall, hmd or a path ending in one (not heimdall-state, not .heimdall), or a variable that may hold it ($HMD, $BIN, $HEIMDALL_BIN)
DISP_TOK_RE = re.compile(r"""(?<![\w.$/-])(?:[\w$"'{}.~/-]*/)?(?:heimdall|hmd)(?![\w.-])""")
DISP_VAR_RE = re.compile(r"""\$\{?(\w*(?:HMD|HEIMDALL|BIN)\w*)\}?""")
# what follows the name: [closing quote] blanks, flags, then a literal word (a sub-command) or a `$` (a word nobody can read)
CALL_ARGS_RE = re.compile(r"""["']?[ \t]+(?:--?[A-Za-z][\w=-]*[ \t]+)*(?:(["']?\$)|([A-Za-z][A-Za-z0-9-]*)\b)""")
# the words that put a command after them (the same set CMD_BEFORE_RE uses); `bash -c "hmd init"` is a shell's -c, not any command's
PREFIX_WORD_RE = re.compile(r"(?<![\w-])(?:then|do|else|elif|if|while|until|exec|command|env|time|nohup|sudo|xargs|eval|bash|sh|zsh|(?:bash|sh|zsh|dash|ksh)\s+(?:-[A-Za-z]+\s+)*-c)$")
ASSIGN_TAIL_RE = re.compile(r"""(?<![\w-])[A-Za-z_]\w*\+?=(?!\()(?:"[^"]*"|'[^']*'|\S*)$""")        # not `arr=(`: an array literal that is still open
DEFAULT_VALUE_RE = re.compile(r"\$\{(\w+):?[-=](.*)\}")
ASSIGN_VALUE_RE = re.compile(r"""(?:^|[\s;&|({])(?:(?:export|local|readonly|declare|typeset)[ \t]+(?:-\w+[ \t]+)*)?([A-Za-z_]\w*)\+?=(?:"((?:[^"\\]|\\.)*)"|'([^']*)'|([^\s;&|)]*))""")
BARE_DISPATCHER_RE = re.compile(r"(?<![\w-])(?:hmd|heimdall)(?![\w-])")
FN_WORD_RE = re.compile(r"[A-Za-z_][\w-]*")
SUBSTITUTION_RE = re.compile(r"\$\(|`")
RESOLVER_RE = re.compile(r"\$\(\s*(?:command\s+-v|which|type\s+-P)\s|`\s*(?:command\s+-v|which)\s")     # `command -v node` names its tool
VAR_REF_RE = re.compile(r"\$\{[^}]*\}|\$\w+")
CASE_OPEN_RE = re.compile(r'^case "\$\{1:-\}" in\s*$')
ESAC_RE = re.compile(r"^esac(?:\s|$)")
ARM_RE = re.compile(r"^  ([^\s#][^()]*)\)")
LABEL_RE = re.compile(r"[a-z][a-z0-9-]*")
PY_IMPORT_RE = re.compile(r"^\s*(?:from\s+\.*([A-Za-z_][\w.]*)\s+import\b|import\s+([A-Za-z_][\w.]*(?:\s*,\s*[A-Za-z_][\w.]*)*))")
VAR_OPEN_RE = re.compile(r"\$\{?$")
PLAIN_TAIL_RE = re.compile(r"(?:^|/)[A-Za-z0-9]+$")       # a token whose last component is a plain word (no - _ .)
# the text before a word that makes it a COMMAND: line start, ; && || | ( { [ ` $( , then/do/else/exec/time/command/env/sudo/nohup/xargs/which/type, bash -c
CMD_BEFORE_RE = re.compile(r"(?:(?:^\s*\(?|[;&|{`!]|\$\()\s*|\b(?:then|do|else|if|elif|while|until|exec|time|command|env|sudo|nohup|xargs|which|type|bash|sh)\s+(?:-\w+\s+)*[\"']?)$")
SHELL_IMPORT_RE = re.compile(r"\b(?:from|import)\s+([A-Za-z_]\w*)")
JS_IMPORT_RE = re.compile(r"""(?:require\s*\(|\bfrom\s+|\bimport\s*\(?\s*)['"](\.{1,2}/[^'"\n]+)['"]""")
OID_RE = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
STAMP_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
SHELL_BLANKS = " \t\r\x0b\x0c"       # the blanks of a shell line: not str.strip()'s, which also eats unicode spaces a shell treats as text
# a heredoc start: `<<` or `<<-` (never the here-string `<<<`), then its delimiter: 'quoted', "quoted" (may hold blanks), \escaped or a bare word
HEREDOC_RE = re.compile(r"""(?<!<)<<(-?)[ \t]*(?:'([^']*)'|"([^"]*)"|\\?([^\s;&|()<>'"\\]+))""")


SHELL_SUFFIXES = (".sh", ".bash", ".zsh")
SHELL_INTERPRETERS = frozenset(["sh", "bash", "dash", "zsh", "ksh"])
# what one shell line can do to the quoting state: an escaped character, the next quote, or a comment (what follows a `#` that starts a word is text)
UNQUOTED_RE = re.compile(r"""\\.|\$'|'|"|(?<![^ \t;&|])#""")
# a double-quoted string's own tokens: an escape, the closing quote, and the three constructs inside it that open a quoting context of their own (`$(`, `${`, a backtick)
DOUBLE_RE = re.compile(r'\\.|"|\$[({]|`')
ANSI_RE = re.compile(r"\\.|'")
QUOTED_RE = re.compile("'[^']*'|\"[^\"]*\"")
# the script's own path, in any form: $0, ${0}, ${0##*/}, $BASH_SOURCE, ${BASH_SOURCE[0]}
SELF_REF_RE = re.compile(r"\$(?:0\b|\{0|\{BASH_SOURCE|BASH_SOURCE\b)")
SHELL_EVAL_RE = re.compile(r"\beval\b|\b(?:ba|z|da|k)?sh\s+(?:-\w+\s+)*-c\b|\bsource\s+<\(|\.\s+<\(")
# Python: its own path (__file__, sys.argv[0]) or its own source (inspect, linecache), and anything that opens or reads a file
PY_SOURCE_RE = re.compile(rb"getsource|getcomments|getsourcelines|getsourcefile|linecache")
PY_SELF_RE = re.compile(rb"__file__|\bargv\s*\[\s*0\s*\]")
PY_OPEN_RE = re.compile(rb"\bopen\s*\(|\.read(?:_text|_bytes|lines?)?\s*\(|fileinput|tokenize\.open")
# a Python line that opens, reads or enumerates files: every path on it is read as text
PY_LINE_READ_RE = re.compile(r"\bopen\s*\(|\.read(?:_text|_bytes|lines?)?\s*\(|\.r?glob\(|os\.walk|iterdir|scandir|listdir|json\.load|\bcat\b|\bgrep\b|\bsed\b|\bawk\b")
# a command that reads the text of the file it is given: a suite that hands one a file, or a directory, sees its comments
READERS = ("grep|egrep|fgrep|rg|ag|sed|awk|gawk|perl|head|tail|cat|tac|nl|cut|tr|wc|diff|cmp|comm|sort|uniq|less|more|od|xxd|hexdump|strings|"
           "shasum|sha1sum|sha256sum|sha512sum|md5sum|md5|cksum|openssl|shellcheck|find|xargs|read|mapfile|readarray")
READER_RE = re.compile(r"\b(?:" + READERS + r")\b")
# for a script's reading of ITSELF the list is wider: whatever can turn its text into output or into another file
SELF_READER_RE = re.compile(r"\b(?:" + READERS + r"|cp|rsync|install|base64|gzip|zcat|bzip2|xz|tee)\b")
READS_OPERAND_RE = re.compile(r"(?:^|[|;&(`{'\"]|\$\()\s*(?:(?:if|then|elif|while|until|do|else|!)\s+)*(?:\w+=\S*\s+)*(?:" + READERS
                              + r")\b[^|;&)`]*$|(?<!<)<[ \t]*[\"']?$")


class Fail(Exception):
    """A refusal or a usage error: the message goes to stderr and the exit status is 2."""


# ── git ───────────────────────────────────────────────────────────────────────────────────────────────────────────────

def git_env():
    env = dict((k, v) for k, v in os.environ.items() if k not in GIT_AMBIENT)
    env["GIT_OPTIONAL_LOCKS"] = "0"
    return env


class Repo(object):
    def __init__(self, path):
        self.env = git_env()
        self.top = None
        done = self.git(["rev-parse", "--show-toplevel"], cwd=path, check=False)
        if done.returncode != 0 or not done.stdout.strip():
            raise Fail("%s is not inside a git repository" % path)
        self.top = done.stdout.decode("utf-8", "surrogateescape").strip()

    def git(self, args, cwd=None, check=True):
        try:
            done = subprocess.run(["git"] + args, cwd=cwd or self.top, env=self.env, stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
        except (OSError, subprocess.SubprocessError) as exc:
            raise Fail("cannot run git in %s: %s" % (cwd or self.top, exc))
        if check and done.returncode != 0:
            raise Fail("git %s failed: %s" % (" ".join(args[:2]), done.stderr.decode("utf-8", "replace").strip()))
        return done

    def resolve(self, rev):
        """The full id of the commit `rev` names, or None."""
        done = self.git(["rev-parse", "--verify", "--quiet", rev + "^{commit}"], check=False)
        got = done.stdout.decode("ascii", "replace").strip()
        return got if done.returncode == 0 and OID_RE.fullmatch(got) else None

    def dirty(self, owned):
        """Tracked paths with uncommitted changes (staged or not), the hooks' own writes excluded."""
        out = self.git(["status", "--porcelain=v1", "-z", "--untracked-files=no", "--no-renames"]).stdout
        paths = [rec[3:].decode("utf-8", "surrogateescape") for rec in out.split(b"\0") if len(rec) > 3]
        return sorted(p for p in paths if not (owned is not None and owned.match(p)))


class Blobs(object):
    """`git cat-file --batch`, one request and one answer at a time (so neither pipe can fill and stall the other)."""

    def __init__(self, repo):
        try:
            self.proc = subprocess.Popen(["git", "cat-file", "--batch"], cwd=repo.top, env=repo.env, stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError as exc:
            raise Fail("cannot run git cat-file: %s" % exc)

    def get(self, oid):
        self.proc.stdin.write(oid.encode("ascii") + b"\n")
        self.proc.stdin.flush()
        head = self.proc.stdout.readline().split()
        if len(head) != 3 or head[1] != b"blob":
            raise Fail("cannot read blob %s" % oid)
        size = int(head[2])
        data = self.proc.stdout.read(size)
        self.proc.stdout.read(1)
        if len(data) != size:
            raise Fail("short read of blob %s" % oid)
        return data

    def close(self):
        try:
            self.proc.stdin.close()
        finally:
            self.proc.stdout.close()
            self.proc.wait()


def hook_owned_re():
    """The regex of bin/lib/hook-owned-path.sh (the one shared definition), or None when it cannot be read."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hook-owned-path.sh")
    try:
        with open(path, encoding="utf-8") as fh:
            found = re.search(r"^HMD_HOOK_OWNED_PATH_RE='([^']*)'", fh.read(), re.M)
    except OSError:
        found = None
    if not found:
        sys.stderr.write("heimdall-suite-closure: warning: %s is unreadable, so no path is treated as hook-owned\n" % path)
        return None
    return re.compile("^(?:%s)$" % found.group(1))


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def file_sha(path):
    try:
        with open(path, "rb") as fh:
            return sha256_hex(fh.read())
    except OSError:
        return "absent"


def tool_version(argv):
    try:
        done = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return "absent"
    lines = done.stdout.decode("utf-8", "replace").strip().splitlines()
    return lines[0].strip() if lines else "unknown"


# ── classification and lexing ─────────────────────────────────────────────────────────────────────────────────────────

def classify(path, mode):
    if SUITE_RE.match(path):
        return "suite"
    if mode in ("120000", "160000"):
        return "data"
    base = path.rsplit("/", 1)[-1]
    suffix = os.path.splitext(base)[1].lower()
    if suffix in CODE_SUFFIXES:
        return "code"
    if suffix in DATA_SUFFIXES or (base.startswith(".") and suffix == ""):
        return "data"
    if path.startswith(EXEC_DIRS) or mode == "100755":
        return "code"
    return "data"


def is_comment(stripped, c_style):
    if c_style:
        return stripped.startswith(("//", "/*", "*"))
    return stripped.startswith("#") and not stripped.startswith("#!")


def strip_docstrings(lines):
    """(code lines, docstring lines) of a Python file: a docstring is prose ("`hmd ui` backend", "heimdall/* branches"), like a comment."""
    code, prose, inside = [], [], None
    for line in lines:
        s = line.strip()
        if inside:
            prose.append(line)
            if inside in s:
                inside = None
            continue
        quote = next((q for q in ('"""', "'''") if s.lstrip("rRuUbBfF").startswith(q)), None)
        if quote is None:
            code.append(line)
            continue
        prose.append(line)
        if quote not in s.lstrip("rRuUbBfF")[3:]:
            inside = quote
    return code, prose


def strip_full_line_comments(text):
    """`text` without its full-line comments (a line whose first non-blank character is `#`, `#!` lines excepted), or None when that is not safe.

    Not safe = a line of a heredoc BODY starts with `#`. A here-document is data, so that line may be real input and dropping it would hide a change; the caller then
    salts the raw file. The tracker reads bash heredocs: `<<` and `<<-` (tabs, and only tabs, stripped from the terminator), a bare, 'quoted', "quoted" or \\escaped
    delimiter, several on one line; not here-strings (`<<<`). A false positive (a `<<` in arithmetic or in a string) can only turn the answer into None, never hide a line.
    A `#` line inside a multi-line QUOTED perl, awk or jq program is a comment of that language, so dropping it is as harmless as dropping a shell comment: the real
    test/run-all.sh has such lines and no heredoc at all (test/suite-closure.test.sh proves both)."""
    kept, pending = [], []          # pending: (delimiter, tabs_stripped) of every heredoc whose body is still to come, in order
    for line in text.split("\n"):
        stripped = line.lstrip(SHELL_BLANKS)
        if pending:
            delim, dash = pending[0]
            if (line.lstrip("\t") if dash else line) == delim:
                pending.pop(0)
            elif stripped.startswith("#"):
                return None
            kept.append(line)
            continue
        if is_comment(stripped, False):
            continue
        for m in HEREDOC_RE.finditer(line):
            single, double, bare = m.group(2), m.group(3), m.group(4)
            pending.append((single if single is not None else double if double is not None else bare, m.group(1) == "-"))
        kept.append(line)
    return "\n".join(kept)


def language(path, data):
    """Which language the file `path` (committed bytes `data`) is written in for the hash: "shell", "python" or None. By suffix, or by the #! line of a file that has none."""
    suffix = os.path.splitext(path)[1].lower()
    if suffix in SHELL_SUFFIXES:
        return "shell"
    if suffix == ".py":
        return "python"
    if suffix or not data.startswith(b"#!"):
        return None
    words = data.split(b"\n", 1)[0][2:].decode("utf-8", "replace").split()
    if words and os.path.basename(words[0]) == "env":
        words = [w for w in words[1:] if not w.startswith("-") and "=" not in w]      # `#!/usr/bin/env -S bash -e`
    name = os.path.basename(words[0]) if words else ""
    return "shell" if name in SHELL_INTERPRETERS else "python" if name.startswith("python") else None


def nested_span(line, at):
    """(end, unsafe) for the `$(`, `${` or backtick at `at` of `line`, written inside a double-quoted string, where the shell opens a quoting context of its own. unsafe = the scanner cannot be sure it pairs the
    quotes inside the way the shell does: the construct does not close on this line, its body holds a backslash, in code (`$(`, a backtick) a `#` (a comment there), or quotes that do not pair up and close on their
    own (the body is run through quote_state itself, so `"$(printf '%s' "${X:-a}" | tr -c 'a-z' _)"` is followed exactly). `end` is the index after it. The caller skips the whole construct, so the quotes inside
    it never toggle the outer state."""
    if line[at] == "`":
        end = line.find("`", at + 1)
        if end < 0:
            return len(line), True
        body, after, code = line[at + 1:end], end + 1, True
    else:
        opener, closer = ("(", ")") if line[at + 1] == "(" else ("{", "}")
        depth, j = 1, at + 2
        while j < len(line) and depth:
            depth += (line[j] == opener) - (line[j] == closer)
            j += 1
        if depth:
            return len(line), True
        body, after = line[at + 2:j - 1], j
        code = opener == "(" and not body.startswith("(")                   # `$(( ))` is arithmetic: a `#` in it is a number base (10#$v), not a comment
    if "\\" in body or (code and "#" in body):
        return after, True
    inner, unsafe = quote_state(body, "")
    return after, unsafe or inner != ""


def quote_state(line, state):
    """(the quoting state at the end of `line` ("" none, "'", '"' or "$'") for a line that starts in `state`, whether the scan met nested quoting it cannot follow). A comment ends the scan: what follows a `#` that
    starts a word is text, so an apostrophe in it opens nothing. Inside double quotes a `$(`, `${` or backtick that holds quotes (nested_span) makes the state unknowable: the second value is True and the
    caller hashes the file as committed."""
    pos = 0
    while True:
        if state == "'":
            end = line.find("'", pos)
            if end < 0:
                return state, False
            pos, state = end + 1, ""
            continue
        rx = DOUBLE_RE if state == '"' else ANSI_RE if state == "$'" else UNQUOTED_RE
        for m in rx.finditer(line, pos):
            tok = m.group()
            if state == '"' and tok in ("$(", "${", "`"):
                pos, unsafe = nested_span(line, m.start())
                if unsafe:
                    return state, True
                break
            if state:
                if tok[0] != "\\":                          # the quote that closes it
                    pos, state = m.end(), ""
                    break
            elif tok == "#":
                return state, False
            elif tok[0] != "\\":
                pos, state = m.end(), tok
                break
        else:
            return state, False


def reads_own_text(lines):
    """True when a shell script can hand its own text to anything: it holds a command that reads or copies text (grep, sed, awk, head, tail, cat, read, cp ...) AND a reference to its own path ($0, ${0##*/},
    $BASH_SOURCE) anywhere, however the two meet (`sed -n '2,40p' "$0"` prints the header comment as --help; so does `SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"` and a later `sed -n 2,9p "$SELF"`). A comment of
    such a script IS its behaviour, so it is hashed as committed. Whole-file on purpose: this errs toward re-running."""
    text = "\n".join(lines)
    if SELF_READER_RE.search(text) is None:
        return False
    if SHELL_EVAL_RE.search(text):                                          # eval and `sh -c` run quoted text as shell: every `$0` in it counts
        return SELF_REF_RE.search(text) is not None
    scan = DisplayScan(text)
    try:
        scan.run()
    except (Bail, IndexError, RecursionError):
        return SELF_REF_RE.search(text) is not None
    return scan.self_ref                                                    # `$0` inside single quotes is an awk or sed program's own, not this script's path


def python_reads_self(data):
    """True when a Python file can read its own text: it asks inspect or linecache for its source, or it names its own path (__file__, sys.argv[0]) and opens or reads a file anywhere."""
    return PY_SOURCE_RE.search(data) is not None or (PY_SELF_RE.search(data) is not None and PY_OPEN_RE.search(data) is not None)


def shell_normal_form(text):
    """`text` without what cannot change what a shell does with it, or None when it must be hashed as committed. Dropped: blank lines, full-line comments (a `#!` line stays) and the trailing blanks of a code line.
    Kept as they are: a here-document body (data, up to its terminator, whatever it starts with), a multi-line quoted string, a line a backslash joins to the one before it (a comment or a blank there changes where the
    command ends), a line that ends in a backslash (a blank after it makes it no continuation) and `\\r`. A trailing comment is part of its code line. This is a line scanner, not a parser: where it cannot tell it keeps the
    line (a `<<` inside a string only turns the rest of the file into data), never the other way. None: the script reads its own text (reads_own_text)."""
    out, pending, quote, joined = [], [], "", False       # pending: (delimiter, tabs_stripped) of the here-documents whose body is still to come
    for line in text.split("\n"):
        if pending:
            delim, dash = pending[0]
            if (line.lstrip("\t") if dash else line) == delim:
                pending.pop(0)
            out.append(line)
            joined = False
            continue
        bare = line.lstrip(" \t")
        if not quote and not joined and (not bare or (bare[0] == "#" and not bare.startswith("#!"))):
            continue
        for m in HEREDOC_RE.finditer(line):
            single, double, word = m.group(2), m.group(3), m.group(4)
            pending.append((single if single is not None else double if double is not None else word, m.group(1) == "-"))
        end, unknowable = quote_state(line, quote)
        if unknowable:
            return None
        joined = line.rstrip(" \t\r").endswith("\\")
        out.append(line.rstrip(" \t") if not quote and not end and not joined else line)
        quote = end
    return None if reads_own_text(out) else "\n".join(out)


def python_digest(data):
    """sha256 over the tokens of the Python source `data` without its comments (a `#!` first line stays) and its non-logical newlines, or None when it must be hashed as committed: it does not tokenize, or it reads its
    own source. A docstring and every other string is a token, so it stays, and so do the indentation and the encoding."""
    if python_reads_self(data):
        return None
    h = hashlib.sha256(b"python\0")
    try:
        for tok in tokenize.tokenize(io.BytesIO(data).readline):
            if tok.type == tokenize.ERRORTOKEN:
                return None
            if tok.type == tokenize.NL or (tok.type == tokenize.COMMENT and not (tok.start == (1, 0) and tok.string.startswith("#!"))):
                continue
            blob = tok.string.encode("utf-8", "surrogatepass")
            h.update(b"%d:%d:" % (tok.type, len(blob)))
            h.update(blob)
    except (tokenize.TokenError, SyntaxError, ValueError, LookupError):     # IndentationError is a SyntaxError; a bad coding cookie a SyntaxError or LookupError; bytes it cannot decode a ValueError
        return None
    return h.hexdigest()


def normal_digest(path, data):
    """sha256 of the committed bytes `data` of `path` without what cannot change what a shell or Python file does, or None: hash the blob as committed."""
    kind = language(path, data)
    if kind == "python":
        return python_digest(data)
    if kind == "shell":
        text = shell_normal_form(data.decode("utf-8", "surrogateescape"))
        return None if text is None else sha256_hex(b"shell\0" + text.encode("utf-8", "surrogateescape"))
    return None


def reads_operand(line, pos):
    """True when the token that starts at `pos` of `line` is the operand of a command that reads text: `grep -q x TOKEN`, `cat TOKEN`, `... < TOKEN`."""
    return READS_OPERAND_RE.search(QUOTED_RE.sub("Q", line[max(0, pos - 400):pos])) is not None


# ── display-only text: what a shell file SAYS and never reads or runs ────────────────────────────────────────────────────

class Bail(Exception):
    """The shell text uses something the display scanner does not model (an unclosed quote, a here-document that never ends, a `(` it cannot place): nothing is dropped from that file."""


# a line or word that can be SCRIPT text a later process runs (a generated hook, a wrapper): never display text
CODE_MARK_RE = re.compile(r"#!|\$@|\$\{@|&&|\|\||\s\|\s|;\s*(?:then|do|fi|done|exit|return)\b|(?:^|\s)(?:exec|source)\s|^\s*\.\s|>\s*/dev/|2>&1|\bset\s+-[euxo]")
ASSIGN_WORD_RE = re.compile(r"[A-Za-z_]\w*\+?=")
IDENT_RE = re.compile(r"[A-Za-z_][\w:.-]*")
FUNC_HEADER_RE = re.compile(r"\(\s*\)")
SEP_RE = re.compile(r";;&|;;|;&|&&|\|\||\|&|[;&|]")
FD_REDIR_RE = re.compile(r"\d+[<>]")
FD_OP_RE = re.compile(r"(\d*)(<<<|<<-|<<|&>>|&>|>>|>\||>&|<&|<>|>|<)")
PLAIN_RE = re.compile(r"""[^ \t\n;&|()<>\\'"$`]+""")
DQ_PLAIN_RE = re.compile(r'[^"\\$`]+')
VARNAME_RE = re.compile(r"\w+|[@*#?$!-]")
OUTPUT_OPS = frozenset([">", ">>", ">|", ">&", "&>", "&>>", "<>"])
LEADERS = frozenset(["if", "then", "else", "elif", "do", "while", "until", "!", "time", "for", "select", "case", "{"])
SKIPPED = frozenset(["if", "then", "else", "elif", "do", "while", "until", "!", "time"])
OPENERS = {"if": "fi", "while": "done", "until": "done", "for": "done", "select": "done", "case": "esac", "{": "}"}
DISPLAY_TARGETS = frozenset(["1", "2", "-", "/dev/null", "/dev/stderr", "/dev/stdout", "/dev/tty"])


class Word(object):
    __slots__ = ("s", "e", "lit", "code")

    def __init__(self, s, e, lit, code):
        """`lit` is the word's text with its quotes taken off, a variable or a substitution as a NUL; `code` is True when a substitution (`$( )`, a backtick, `<( )`) is part of it."""
        self.s, self.e, self.lit, self.code = s, e, lit, code


class Cmd(object):
    __slots__ = ("idx", "words", "piped", "to_file", "captured", "group")

    def __init__(self, idx, captured):
        """`captured`: inside a `$( )`, a backtick or an array, so whatever it prints is a value. `piped`: followed by a pipe. `to_file`: a redirection of stdout that is not the terminal. `group`: the index
        of the first command of the group (`{ }`, `( )`, if, for, while, case) this command closes."""
        self.idx, self.words, self.piped, self.to_file, self.captured, self.group = idx, [], False, False, captured, None


class DisplayScan(object):
    """The spans of a shell file's text that are provably only PRINTED, found by lexing it the way bash does (quotes, `$( )`, `${ }`, here-documents, `;` `&&` `|`, redirections, groups) and judging each simple command.

    Display text, and nothing else: (1) a trailing comment; (2) a quoted word of an `echo` or `printf` that prints to the terminal (no redirection to a file, no pipe after it, not inside a substitution, an
    array or a group whose output is piped or redirected) when the word holds a space (a message; a lone path-like word is how a function hands back a VALUE: `echo "$dir/x.json"`), holds no substitution and no
    script-like syntax (CODE_MARK_RE: `exec`, `source`, `&&`, `$@`: a generated hook's lines); (3) the body of a here-document that a bare `cat` prints (no file, no pipe, not captured), line by line by the
    same rule, and not at all when any line is a `#!` line. Everything else is kept, which only ever ADDS edges. Bail: the file is not lexed at all."""

    def __init__(self, text):
        self.t, self.n, self.i, self.cap, self.bid, self.seq = text, len(text), 0, False, 0, 0
        self.cmds, self.spans, self.pending, self.hdocs, self.stack = [], [], [], [], []
        self.functions, self.pending_fn = [], None      # (name, start, end) of every function definition `name() { ... }`; the header of one whose `{` is still to come: (name, start)
        self.self_ref = False                           # the shell expands the script's own path somewhere ($0, ${0##*/}, $BASH_SOURCE, outside single quotes)

    def run(self):
        self.block("", False)
        if self.pending:
            raise Bail()
        self.decide()
        return self.spans

    # -- lexing -----------------------------------------------------------------------------------------------------
    def new_cmd(self):
        cmd = Cmd(len(self.cmds), self.cap)
        self.cmds.append(cmd)
        return cmd

    def add(self, cmd, word):
        if word.e <= word.s:
            raise Bail()
        cmd = cmd or self.new_cmd()
        lit = word.lit
        if not cmd.words:
            if self.stack and lit == self.stack[-1][0]:
                entry = self.stack.pop()
                cmd.group = entry[1]
                if len(entry) == 5:                                         # the `}` of a function: its name and where its header started
                    self.functions.append((entry[3], entry[4], word.e))
        function_form = len(cmd.words) == 2 and cmd.words[0].lit == "function"
        if (all(w.lit in LEADERS for w in cmd.words) or function_form) and lit in OPENERS:
            entry = (OPENERS[lit], cmd.idx, self.bid)
            if lit == "{" and (self.pending_fn or function_form):
                name, start = self.pending_fn or (cmd.words[1].lit, cmd.words[0].s)
                entry += (name, start)
            self.stack.append(entry)
        self.pending_fn = None
        cmd.words.append(word)
        return cmd

    def finish(self, cmd, op):
        if cmd is None:
            return
        cmd.piped = op in ("|", "|&")
        if cmd.group is not None and (cmd.piped or cmd.to_file):
            for c in self.cmds[cmd.group:]:
                c.captured = True

    def block(self, closer, captured):
        """Lex commands until the unquoted `closer` (`)`) or the end of the text."""
        saved, saved_id = self.cap, self.bid
        self.seq += 1
        mine = self.bid = self.seq
        self.cap = captured
        t, n = self.t, self.n
        cmd = None
        while True:
            if self.i >= n:
                if closer:
                    raise Bail()
                self.finish(cmd, "")
                break
            c = t[self.i]
            if c in " \t":
                self.i += 1
            elif c == "\\" and t.startswith("\n", self.i + 1):
                self.i += 2
            elif c == "\n":
                self.finish(cmd, "\n")
                cmd = None
                self.i += 1
                self.bodies()
            elif c == "#":
                eol = t.find("\n", self.i)
                eol = n if eol < 0 else eol
                if t[t.rfind("\n", 0, self.i) + 1:self.i].strip(" \t"):      # a trailing comment; a full-line one is the caller's to classify
                    self.spans.append((self.i, eol))
                self.i = eol
            elif c in ";&|" and not t.startswith("&>", self.i):
                op = SEP_RE.match(t, self.i).group()
                self.finish(cmd, op)
                cmd = None
                self.i += len(op)
            elif c == ")":
                self.finish(cmd, ")")
                cmd = None
                self.i += 1
                pattern = self.stack and self.stack[-1][0] == "esac" and self.stack[-1][2] == mine      # `a|b)` ends a case pattern, it closes nothing
                if closer == ")" and not pattern:
                    break
            elif c == "(":
                cmd = self.paren(cmd)
            elif c in "<>&" or (c.isdigit() and FD_REDIR_RE.match(t, self.i)):
                if t.startswith("<(", self.i) or t.startswith(">(", self.i):
                    cmd = self.add(cmd, self.word())
                else:
                    cmd = self.redirect(cmd)
            else:
                cmd = self.add(cmd, self.word())
                if cmd.words[-1].lit == "[[" and all(w.lit in LEADERS for w in cmd.words[:-1]):
                    self.test()
        self.cap, self.bid = saved, saved_id

    def test(self):
        """Skip the rest of a `[[ ... ]]`: inside it `(` `)` `<` `>` `&&` `||` are operators of the test, not of the shell."""
        t = self.t
        while self.i < self.n:
            c = t[self.i]
            if c in " \t\n":
                self.i += 1
            elif t.startswith("]]", self.i):
                self.i += 2
                return
            elif c in "()<>&|":
                self.i += 1
            else:
                before = self.i
                self.word()
                if self.i == before:
                    raise Bail()
        raise Bail()

    def paren(self, cmd):
        t = self.t
        words = cmd.words if cmd is not None else []
        if all(w.lit in LEADERS for w in words):
            cmd = cmd or self.new_cmd()
            if t.startswith("((", self.i):                                  # ((expr)) as a command
                self.i = self.arith(self.i)
            else:                                                           # a subshell (or a case pattern `(a|b)`): it prints wherever what follows its `)` sends it
                self.i += 1
                self.block(")", self.cap)
                cmd.group = cmd.idx
                cmd.words.append(Word(0, 1, "(", True))
                j = self.i
                while t[j:j + 1] in (" ", "\t"):
                    j += 1
                return cmd if t[j:j + 1] in ("|", ">", "<", "&") else None      # a command after it is its own, a pipe or a redirection is the group's
            cmd.words.append(Word(0, 1, "(", True))
            return cmd
        if words and words[0].lit == "case" and words[-1].lit == "in":      # case x in (a|b) ...: the opening parenthesis of the first pattern
            self.i += 1
            return cmd
        header = FUNC_HEADER_RE.match(t, self.i)
        if header and len(words) in (1, 2) and IDENT_RE.fullmatch(words[-1].lit) and (len(words) == 1 or words[0].lit == "function"):
            self.i = header.end()                                           # name() { ... }
            self.pending_fn = (words[-1].lit, words[0].s)
            return None
        raise Bail()

    def arith(self, pos):
        """The index after the `))` that closes the arithmetic that starts at `pos` (a `((` or the `(` after a `$`)."""
        depth, j = 0, pos
        while j < self.n:
            c = self.t[j]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        raise Bail()

    def backtick(self):
        t = self.t
        self.i += 1
        while self.i < self.n:
            c = t[self.i]
            self.i += 2 if c == "\\" else 1
            if c == "`":
                return
        raise Bail()

    def param(self):
        """Skip a `${ ... }` whose `${` has been consumed; True when a substitution is inside it."""
        t, code = self.t, False
        while self.i < self.n:
            c = t[self.i]
            if c == "}":
                self.i += 1
                return code
            if c == "\\":
                self.i += 2
            elif c == "$":
                code |= self.dollar([])
            elif c == '"':
                code |= self.dquote([])
            elif c == "'":
                end = t.find("'", self.i + 1)
                if end < 0:
                    raise Bail()
                self.i = end + 1
            elif c == "`":
                self.backtick()
                code = True
            else:
                self.i += 1
        raise Bail()

    def dollar(self, lit):
        """Consume the `$...` at the cursor into `lit`; True when it is a substitution."""
        t, i = self.t, self.i
        nxt = t[i + 1:i + 2]
        if SELF_REF_RE.match(t, i):
            self.self_ref = True
        if nxt == "(":
            if t.startswith("((", i + 1):
                self.i = self.arith(i + 1)
            else:
                self.i = i + 2
                self.block(")", True)
            lit.append("\0")
            return True
        if nxt == "{":
            self.i = i + 2
            code = self.param()
            lit.append("\0")
            return code
        if nxt == "'":
            j = i + 2
            while j < self.n and t[j] != "'":
                j += 2 if t[j] == "\\" else 1
            if j >= self.n:
                raise Bail()
            lit.append(t[i + 2:j])
            self.i = j + 1
            return False
        m = VARNAME_RE.match(t, i + 1)
        if m:
            lit.append("\0")
            self.i = m.end()
        else:
            lit.append("$")
            self.i = i + 1
        return False

    def dquote(self, lit):
        t, code = self.t, False
        self.i += 1
        while self.i < self.n:
            c = t[self.i]
            if c == '"':
                self.i += 1
                return code
            if c == "\\":
                lit.append(t[self.i + 1:self.i + 2])
                self.i += 2
            elif c == "$":
                code |= self.dollar(lit)
            elif c == "`":
                self.backtick()
                lit.append("\0")
                code = True
            else:
                m = DQ_PLAIN_RE.match(t, self.i)
                lit.append(m.group())
                self.i = m.end()
        raise Bail()

    def word(self):
        t, n = self.t, self.n
        start, lit, code = self.i, [], False
        while self.i < n:
            m = PLAIN_RE.match(t, self.i)
            if m:
                lit.append(m.group())
                self.i = m.end()
                continue
            c = t[self.i]
            if c in " \t\n;&|)":
                break
            if c == "(":
                joined = "".join(lit)
                if joined.endswith("=") and ASSIGN_WORD_RE.fullmatch(joined):             # arr=( ... ): the elements are values, never commands
                    self.i += 1
                    self.block(")", True)
                    lit.append("\0")
                    code = True
                    continue
                break
            if c in "<>":
                if t.startswith("(", self.i + 1):                                           # <( ... ) and >( ... )
                    self.i += 2
                    self.block(")", True)
                    lit.append("\0")
                    code = True
                    continue
                break
            if c == "\\":
                if t.startswith("\n", self.i + 1):
                    self.i += 2
                else:
                    lit.append(t[self.i + 1:self.i + 2])
                    self.i += 2
            elif c == "'":
                end = t.find("'", self.i + 1)
                if end < 0:
                    raise Bail()
                lit.append(t[self.i + 1:end])
                self.i = end + 1
            elif c == '"':
                code |= self.dquote(lit)
            elif c == "$":
                code |= self.dollar(lit)
            else:
                self.backtick()
                lit.append("\0")
                code = True
        return Word(start, self.i, "".join(lit), code)

    def redirect(self, cmd):
        t = self.t
        cmd = cmd or self.new_cmd()
        m = FD_OP_RE.match(t, self.i)
        if m is None:
            raise Bail()
        fd, op = m.group(1), m.group(2)
        self.i = m.end()
        while t[self.i:self.i + 1] in (" ", "\t"):
            self.i += 1
        target = self.word()
        if op in ("<<", "<<-"):
            if not target.lit or "\0" in target.lit:
                raise Bail()
            self.pending.append((cmd, target.lit, op == "<<-", self.t[target.s:target.e] != target.lit))      # a quoted delimiter makes the body literal text
        elif op in OUTPUT_OPS and fd != "2" and not (target.lit in DISPLAY_TARGETS and not target.code):
            cmd.to_file = True
        return cmd

    def bodies(self):
        """At a newline: the bodies of the here-documents opened on the line that just ended, up to their delimiters."""
        t, n = self.t, self.n
        while self.pending:
            cmd, delim, dash, quoted = self.pending.pop(0)
            start = self.i
            while True:
                if self.i >= n:
                    raise Bail()
                eol = t.find("\n", self.i)
                eol = n if eol < 0 else eol
                line = t[self.i:eol]
                if (line.lstrip("\t") if dash else line) == delim:
                    self.hdocs.append((cmd, start, self.i, quoted))
                    self.i = min(eol + 1, n)
                    break
                self.i = eol + 1

    # -- judging ----------------------------------------------------------------------------------------------------
    @staticmethod
    def command_of(cmd):
        """(name, argument words) of a simple command: the leading reserved words and NAME=value words are not the command."""
        k = 0
        while k < len(cmd.words) and (cmd.words[k].lit in SKIPPED or ASSIGN_WORD_RE.match(cmd.words[k].lit)):
            k += 1
        return (cmd.words[k].lit, cmd.words[k + 1:]) if k < len(cmd.words) else ("", [])

    def decide(self):
        for cmd in self.cmds:
            if cmd.captured or cmd.piped or cmd.to_file or not cmd.words:
                continue
            name, args = self.command_of(cmd)
            if name == "printf" and any(w.lit == "-v" for w in args[:2]):
                continue                                                    # printf -v puts the text in a variable
            if name not in ("echo", "printf"):
                continue
            for w in args:
                if not w.code and any(ch in w.lit for ch in " \t\n") and not CODE_MARK_RE.search(w.lit):      # an option (-n, -e) has no space
                    self.spans.append((w.s, w.e))
        for cmd, start, end, quoted in self.hdocs:
            if cmd.captured or cmd.piped:                                   # to a file is fine: a document (AGENTS.md text), unless a line says it is a script (below)
                continue
            name, args = self.command_of(cmd)
            if name != "cat" or any(not w.lit.startswith("-") for w in args):
                continue
            body = self.t[start:end]
            if any(line.startswith("#!") for line in body.split("\n")):
                continue
            pos = start
            for line in body.split("\n"):
                if line.strip() and (quoted or ("$(" not in line and "`" not in line)) and not CODE_MARK_RE.search(line):
                    self.spans.append((pos, pos + len(line)))
                pos += len(line) + 1


def scan_text(text):
    """(display-only spans, function definitions (name, start, end)) of a shell text, or None when it cannot be lexed completely."""
    try:
        scan = DisplayScan(text)
        return scan.run(), scan.functions
    except (Bail, IndexError, RecursionError):
        return None


def blank_spans(text, spans):
    """`text` with the character ranges `spans` replaced by blanks, newlines kept (an overlapping range is skipped: the outer one already blanked it)."""
    out, pos = [], 0
    for s, e in sorted(spans):
        if s < pos:
            continue
        out.append(text[pos:s])
        out.append(re.sub(r"[^\n]", " ", text[s:e]))
        pos = e
    out.append(text[pos:])
    return "".join(out)


def drop_display_text(text):
    """`text` of a shell file with its display-only spans (DisplayScan) blanked out, newlines kept, or `text` itself when it cannot be lexed completely."""
    scanned = scan_text(text)
    return text if scanned is None or not scanned[0] else blank_spans(text, scanned[0])


def cut_functions(text, functions):
    """(`text` with the outermost function definitions blanked out, {function name: its text}): what a shell script runs on every call, and the bodies that run only when something calls them by name."""
    units, spans = {}, []
    for name, s, e in sorted(functions, key=lambda f: f[1]):
        if spans and s < spans[-1][1]:
            continue                                                        # defined inside the previous one: its text goes with it
        spans.append((s, e))
        units[name] = units.get(name, "") + "\n" + text[s:e]
    return blank_spans(text, spans), units


def in_command_position(before):
    """True when the word that follows `before` (the text of its line up to it) can be a COMMAND: it starts the line or follows `;` `&` `|` `(` `{` an unescaped backtick or `$(`, with nothing but reserved words,
    wrappers (env, sudo, exec, `bash -c` ...), the quote that opens such a script and whole NAME=value words between. `die "run hmd init"` is not (the word is text), and `X="$HMD"` is not (the word is a value)."""
    s = before
    for _ in range(16):
        glued = s[-1:] in ("'", '"')                                        # the word starts right after a quote: a script string, or text
        s = s.rstrip("\"'") if glued else s
        blank = s[-1:] in (" ", "\t")
        s = s.rstrip(" \t")
        if not s or s[-1] in ";&|({!" or s.endswith("$(") or (s[-1] == "`" and not s.endswith("\\`")):
            return True
        m = PREFIX_WORD_RE.search(s)
        if m is None and blank:
            m = ASSIGN_TAIL_RE.search(s)                                    # `FOO=1 hmd init`: a complete assignment word, then a blank
        if m is None:
            return False
        s = s[:m.start()]
    return False


def may_be_dispatcher(value, names=frozenset(), strict=False):
    """True when the text a variable is set to can name the dispatcher. `names` are the variables already known to hold it. A path that ends in a literal name is that tool (`$(dirname "$0")/heimdall-face`,
    `${X:-$DIR/heimdall-face}`: not the dispatcher; `$DIR/hmd`: it is); `${X:-default}` is X or the default. Otherwise it can when it holds the word heimdall or hmd or a variable in `names`, and, unless `strict`, when it says
    nothing about what it is: `"$1"`, `"$ROOT/$name"`, the output of a command (`$(command -v node)` names its tool, so that one is not)."""
    v = value.strip("\"'")
    default = DEFAULT_VALUE_RE.fullmatch(v)
    if default:
        return default.group(1) in names or (default.group(2) != "" and may_be_dispatcher(default.group(2), names, strict))
    last = v.rsplit("/", 1)[-1]
    if "/" in v and last and re.search(r"[A-Za-z]", last) and not re.search(r"[$`}]", last):
        return BARE_DISPATCHER_RE.fullmatch(last) is not None
    refs = re.findall(r"\$\{?(\w+)", value)
    if BARE_DISPATCHER_RE.search(value) or any(r in names for r in refs):
        return True
    if strict:
        return False
    if SUBSTITUTION_RE.search(value):
        return RESOLVER_RE.search(value) is None
    return re.search(r"[A-Za-z]", VAR_REF_RE.sub("", value)) is None and (re.search(r"\$[@*]|\$\{[@*]", value) is not None or any(r.isdigit() for r in refs))      # an argument


def bit_indices(bits):
    """The positions of the set bits of `bits`, ascending."""
    return [i for i, c in enumerate(bin(bits)[:1:-1]) if c == "1"]


def condense(adj, leaf, values):
    """(component of each node, reach bitmask of each component, OR of `values` over each component's reach) of the directed graph `adj` (node -> successors), iteratively (Tarjan):
    a component is finished after every component it reaches, so its reach is its own members OR the reach of its successors.
    leaf[v] is a bitmask of nodes that belong to v's closure without being followed (weak edges); values[v] is a bitmask that every component reaching v takes along (the files v reads as text)."""
    n = len(adj)
    index, low, on_stack, comp = [None] * n, [0] * n, [False] * n, [None] * n
    stack, comps, counter = [], [], 0
    for root in range(n):
        if index[root] is not None:
            continue
        work = [(root, 0)]
        while work:
            v, i = work.pop()
            if i == 0:
                index[v] = low[v] = counter
                counter += 1
                stack.append(v)
                on_stack[v] = True
            descended = False
            for j in range(i, len(adj[v])):
                w = adj[v][j]
                if index[w] is None:
                    work.append((v, j + 1))
                    work.append((w, 0))
                    descended = True
                    break
                if on_stack[w]:
                    low[v] = min(low[v], index[w])
            if descended:
                continue
            if low[v] == index[v]:
                members = []
                while True:
                    w = stack.pop()
                    on_stack[w] = False
                    comp[w] = len(comps)
                    members.append(w)
                    if w == v:
                        break
                comps.append(members)
            if work:
                parent = work[-1][0]
                low[parent] = min(low[parent], low[v])
    reach, vreach = [0] * len(comps), [0] * len(comps)
    for c, members in enumerate(comps):
        bits = vbits = 0
        for v in members:
            bits |= (1 << v) | leaf[v]
            vbits |= values[v]
        for v in members:
            for w in adj[v]:
                if comp[w] != c:
                    bits |= reach[comp[w]]
                    vbits |= vreach[comp[w]]
        reach[c], vreach[c] = bits, vbits
    return comp, reach, vreach


def split_arms(lines):
    """(always-followed lines, {word: lines of its arm}) for a dispatcher: the arms of each top-level `case "${1:-}" in`. Only an arm whose
    labels are all plain words is lazy; flags (`--version`), '' and * are always followed."""
    eager, arms, current, in_case = [], {}, None, False
    for line in lines:
        if CASE_OPEN_RE.match(line):
            in_case, current = True, None
        elif in_case and ESAC_RE.match(line):
            in_case, current = False, None
        elif in_case:
            arm = ARM_RE.match(line)
            if arm:
                labels = [a.strip() for a in arm.group(1).split("|")]
                current = labels if all(LABEL_RE.fullmatch(a) for a in labels) else None
            if current is not None:
                for word in current:
                    arms.setdefault(word, []).append(line)
                continue
        eager.append(line)
    return eager, arms


class Node(object):
    __slots__ = ("path", "oid", "mode", "kind")

    def __init__(self, path, oid, mode, kind):
        self.path, self.oid, self.mode, self.kind = path, oid, mode, kind


class Graph(object):
    """The tracked files of ONE commit, their edges, the hints, and the closure of any suite."""

    def __init__(self, repo, commit, hints_path=None, edges=True):
        """`edges` False reads only the tree and the hints (all `salt` needs): no blob is read and nothing is scanned."""
        self.repo, self.commit = repo, commit
        self.nodes, self.text = {}, {}
        self.by_suffix, self.dir_files, self.dir_suffix = {}, {}, {}
        self.edges, self.leaves, self.arms, self.invokes, self.whole = {}, {}, {}, {}, set()
        self.hints, self.hints_raw = {}, None
        self._memo, self._gmemo, self._sha, self._cmemo = {}, {}, {}, {}
        self.content, self.reads = {}, {}       # path -> id of a shell or Python file hashed without its comments; node -> the paths it reads as text
        self.live = {}                          # path of a shell file -> its text without what it only prints (drop_display_text), the text the edges are read from
        self.arm_reads = {}                     # (dispatcher, word) -> the paths that arm reads as text
        self.functions, self.funcs, self.func_reads = {}, {}, {}      # dispatcher -> its function definitions (name, start, end); dispatcher -> {function: (strong, weak)}; (dispatcher, function) -> reads
        self.mentions, self.arm_mentions, self.func_mentions = {}, {}, {}   # the dispatcher's function names a node, an arm or a function names in its text
        self.fn_names = set()
        self._read_tree()
        if edges:
            self._read_blobs()
        self._index()
        self._load_hints(hints_path)
        if edges:
            self._scan()
            self._condense()

    # -- reading ----------------------------------------------------------------------------------------------------
    def _read_tree(self):
        owned = hook_owned_re()
        out = self.repo.git(["ls-tree", "-r", "-z", "--full-tree", self.commit]).stdout
        for rec in out.split(b"\0"):
            if not rec:
                continue
            meta, _, raw = rec.partition(b"\t")
            fields = meta.decode("ascii", "replace").split(" ")
            if len(fields) != 3:
                raise Fail("cannot parse the tree of %s" % self.commit)
            path = raw.decode("utf-8", "surrogateescape")
            if owned is not None and owned.match(path):
                continue
            self.nodes[path] = Node(path, fields[2], fields[0], classify(path, fields[0]))

    def _read_blobs(self):
        blobs = Blobs(self.repo)
        try:
            for path in sorted(self.nodes):
                node = self.nodes[path]
                if node.kind == "data":
                    continue
                data = blobs.get(node.oid)
                if len(data) > MAX_SCAN or b"\0" in data[:8192]:
                    node.kind = "data"
                    continue
                self.text[path] = data.decode("utf-8", "replace")
                if language(path, data) == "shell":
                    scanned = scan_text(self.text[path])
                    self.live[path] = self.text[path] if scanned is None or not scanned[0] else blank_spans(self.text[path], scanned[0])
                    if path in DISPATCHERS and scanned is not None:
                        self.functions[path] = scanned[1]
                digest = normal_digest(path, data)
                if digest is not None:
                    self.content[path] = "normal:" + digest
        finally:
            blobs.close()

    def _index(self):
        for path, node in self.nodes.items():
            parts = path.split("/")
            for i in range(1, len(parts)):
                self.by_suffix.setdefault("/".join(parts[i:]), []).append(node)
                self.dir_files.setdefault("/".join(parts[:i]), []).append(path)
        for d in self.dir_files:
            parts = d.split("/")
            for i in range(len(parts)):
                self.dir_suffix.setdefault("/".join(parts[i:]), []).append(d)
        self.top_names = set(p.split("/")[0] for p in self.nodes)
        self.last_names = set(part for p in self.nodes for part in p.split("/"))    # a token whose last component is none of these names nothing

    def suites(self):
        return sorted(p for p, n in self.nodes.items() if n.kind == "suite")

    def suite_path(self, name):
        """The repo path a --suite argument or a hints key means: test/x.test.sh, x.test.sh or an absolute path inside the repo."""
        s = name.strip()
        real, top = os.path.realpath(s), os.path.realpath(self.repo.top)
        if os.path.isabs(s) and real.startswith(top + os.sep):
            s = os.path.relpath(real, top)
        if s.startswith("./"):
            s = s[2:]
        return s if "/" in s else "test/" + s

    # -- hints ------------------------------------------------------------------------------------------------------
    def _load_hints(self, hints_path):
        origin = HINTS
        if hints_path is not None:
            origin = hints_path
            try:
                with open(hints_path, "rb") as fh:
                    self.hints_raw = fh.read(MAX_SCAN + 1)
            except OSError as exc:
                raise Fail("cannot read the hints file %s: %s" % (hints_path, exc))
        elif HINTS in self.nodes:
            self.hints_raw = self.repo.git(["cat-file", "blob", self.nodes[HINTS].oid]).stdout
        if self.hints_raw is None:
            return
        try:
            data = json.loads(self.hints_raw.decode("utf-8"))
        except ValueError as exc:
            raise Fail("the hints file %s is not valid JSON (%s)" % (origin, exc))
        if not isinstance(data, dict):
            raise Fail('the hints file %s must be a JSON object keyed by suite: {"test/x.test.sh": {"extra": [...], "always_run": true}}' % origin)
        for key, spec in data.items():
            suite = self.suite_path(key)
            if not isinstance(spec, dict):
                raise Fail("hints for %s must be an object" % key)
            unknown = sorted(set(spec) - set(["extra", "always_run"]))
            if unknown:
                raise Fail("hints for %s: unknown key(s) %s (the keys are extra and always_run)" % (key, ", ".join(unknown)))
            always = spec.get("always_run", False)
            if not isinstance(always, bool):
                raise Fail("hints for %s: always_run must be true or false" % key)
            extra = spec.get("extra", [])
            if not isinstance(extra, list) or not all(isinstance(e, str) and e for e in extra):
                raise Fail("hints for %s: extra must be a list of paths" % key)
            paths = []
            for e in extra:
                e = (e[2:] if e.startswith("./") else e).rstrip("/")
                if e in self.nodes:
                    paths.append(e)
                elif e in self.dir_files:
                    paths.extend(self.dir_files[e])
                else:
                    raise Fail("hints for %s: extra path %s names no tracked file or directory" % (key, e))
            if suite not in self.nodes:
                sys.stderr.write("heimdall-suite-closure: warning: the hints name %s, which is no suite at this commit; ignored\n" % key)
                continue
            self.hints[suite] = {"always_run": always, "extra": sorted(set(paths))}

    # -- edges ------------------------------------------------------------------------------------------------------
    def _resolve(self, raw, mode, glued, cmdpos=False):
        key = (raw, mode, glued, cmdpos)
        hit = self._memo.get(key)
        if hit is None:
            hit = self._memo[key] = self._resolve_uncached(raw, mode, glued, cmdpos)
        return hit

    def _resolve_uncached(self, raw, mode, glued, cmdpos):
        """(files, directory members) the token `raw` names. `glued` is None, or the variable name (possibly '') whose closing quote or brace
        the token follows: `"$REPO"/bin/x`. mode is where it was written: "suite" (directories count), "suite-nodir" (a PATH= line of a suite:
        a search path, not a read), "code" (a tool: a bare data name such as README.md or .gitignore is the TARGET project's, not ours) or
        "comment" (a suite's header: a plain word such as `heimdall` or `corpus` is prose, a compound name such as `heimdall-state` is not).
        A plain word (no - _ .) names a tool only in COMMAND position (`hmd init`, `exec heimdall`, `["hmd", ...]`), cmdpos: the project's own
        name is in every log line and usage text. A file is found wherever a path suffix matches; a DIRECTORY only when it is the real one."""
        dir_ok, bare_data, bare_plain = mode == "suite", mode != "code", mode != "comment" and cmdpos
        tok = raw.rstrip(".")
        pathlike = "/" in tok
        absolute = glued is None and bool(SYSTEM_ABS_RE.match(tok))
        parts = [p for p in tok.split("/") if p and p != "."]
        first, dotdot = (parts[0] if parts else ""), ".." in parts
        if dotdot:
            parts = parts[len(parts) - parts[::-1].index(".."):]
        if glued is not None:
            rooted = glued in DIR_VARS
        else:
            rooted = dotdot or tok.startswith("./") or first in DIR_VARS or first in self.top_names
        files, dirs = set(), set()
        for i in range(len(parts)):
            s = "/".join(parts[i:])
            multi = i < len(parts) - 1
            node = self.nodes.get(s)
            if node is not None:
                if multi or node.kind != "data":
                    files.add(node.path)                    # a nested repo path, or a root-level code file (install.sh)
                elif (rooted if pathlike else bare_data):
                    files.add(node.path)                    # $REPO/VERSION yes, $d/VERSION no; a bare VERSION only in a suite
            plain = not multi and re.search(r"[-_.]", s) is None
            for node in self.by_suffix.get(s, ()):
                if multi or (node.kind != "data" and not absolute and (bare_plain or not plain)):
                    files.add(node.path)
            if dir_ok and rooted and not absolute and (multi or pathlike):
                for d in self.dir_suffix.get(s, ()):
                    dirs.update(self.dir_files[d])
            if files or dirs:
                break
        return frozenset(files), frozenset(dirs)

    def _glob(self, raw, before, glued):
        """What a glob after `raw` enumerates: the directory `raw` names (up to its last `/`), or the whole tree after the repo root variable."""
        key = (raw, before, glued)
        hit = self._gmemo.get(key)
        if hit is None:
            hit = self._gmemo[key] = self._glob_uncached(raw, before, glued)
        return hit

    def _glob_uncached(self, raw, before, glued):
        if raw.endswith("/"):
            d = raw
        elif "/" in raw:
            d = raw.rpartition("/")[0] + "/"
        else:
            return frozenset()
        if not d.strip("/"):
            return frozenset([WHOLE]) if ROOT_BEFORE_RE.search(before) else frozenset()
        files, dirs = self._resolve(d, "suite", glued)
        return files | dirs

    def _imports(self, path, lines):
        found = set()
        ext = os.path.splitext(path)[1].lower()
        python = ext == ".py" or (lines and lines[0].startswith("#!") and "python" in lines[0])
        for line in lines:
            if not python and ext not in JS_STYLE:
                # python embedded in shell (`python3 -c "from hmd_x import y"`, a heredoc): a module name that is a tracked .py file
                for m in SHELL_IMPORT_RE.finditer(line):
                    cand = m.group(1) + ".py"
                    found.update(n.path for n in self.by_suffix.get(cand, ()) if n.kind != "data")
                    if cand in self.nodes:
                        found.add(cand)
            elif python:
                m = PY_IMPORT_RE.match(line)
                if not m:
                    continue
                names = [m.group(1)] if m.group(1) else [n.strip() for n in m.group(2).split(",")]
                for name in names:
                    base = name.replace(".", "/")
                    for cand in (base + ".py", base + "/__init__.py"):
                        node = self.nodes.get(cand)
                        if node is not None:
                            found.add(node.path)
                        found.update(n.path for n in self.by_suffix.get(cand, ()) if n.kind != "data")
            elif ext in JS_STYLE:
                for m in JS_IMPORT_RE.finditer(line):
                    parts = [p for p in m.group(1).split("/") if p and p not in (".", "..")]
                    base = "/".join(parts)
                    for tail in ("", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".json", "/index.js", "/index.mjs", "/index.ts"):
                        node = self.nodes.get(base + tail)
                        if node is not None:
                            found.add(node.path)
                        found.update(n.path for n in self.by_suffix.get(base + tail, ()) if "/" in base or n.kind != "data")
        return found

    def _scan_lines(self, lines, mode="code", python=False):
        """(strong, weak, whole, read) for `lines` written in `mode` ("suite", "code" or "comment", see _resolve_uncached) in a shell file or, with `python`, a Python one. strong = the files they name (and, in a suite, the directories a glob enumerates): the closure
        follows what these reach. weak = the directories a SUITE names: every file in them is part of the closure and is hashed, but what
        THEY reach is not followed. whole = they enumerate the whole tree. Directories and whole-tree enumeration are a SUITE's alone: a
        hub tool that prints "see docs/", copies skills/ or runs `git ls-files` works on whatever it is pointed at (a fixture, in nearly every
        suite), and counting those made 99% of the suites depend on 99% of the tree (measured). A suite that points such a tool at the real
        repo, or whose tool reads a directory the suite never names, belongs in test/closure-hints.json."""
        suite = mode == "suite"
        keys, gkeys, whole = set(), set(), False
        read_keys, read_gkeys = set(), set()      # the keys of tokens a suite hands to a command that reads text: read = what they name, hashed as committed
        for line in lines:
            line_mode = "suite-nodir" if suite and PATH_ASSIGN_RE.search(line) else mode
            if suite and QUICK_WHOLE_RE.search(line) and any(rx.search(line) for rx in WHOLE_RES):
                whole = True
            reads = (PY_LINE_READ_RE if python else READER_RE).search(line) is not None      # any file's line, not a suite's alone: a tool that greps a script reads its comments too
            for m in TOK_RE.finditer(line):
                raw, glob = m.group(1), m.group(2)
                if len(raw) < 2 and not glob:
                    continue
                if not glob and raw.rstrip("./").rsplit("/", 1)[-1] not in self.last_names:
                    continue
                glued = None
                if m.start() > 0 and line[m.start() - 1] in "\"'})":
                    var = VAR_BEFORE_RE.search(line[:m.start()])
                    glued = var.group(1) if var else ""
                reading = reads and (python or reads_operand(line, m.start()))
                if glob and suite:
                    gkey = (raw, line[max(0, m.start() - 40):m.start()], glued)
                    gkeys.add(gkey)
                    if reading:
                        read_gkeys.add(gkey)
                cmdpos = False
                if PLAIN_TAIL_RE.search(raw):
                    start = max(0, m.start() - 40)
                    before = ("\0" if start else "") + line[start:m.start()]
                    if "/" in raw:
                        before = VAR_OPEN_RE.sub("", before)        # "$dir/heimdall": the `$` opens the variable `dir`, it is not part of a word
                    cmdpos = CMD_BEFORE_RE.search(before) is not None
                keys.add((raw, line_mode, glued, cmdpos))
                if reading:
                    read_keys.add((raw, line_mode, glued, cmdpos))
        strong, weak, read = set(), set(), set()
        for key in keys:
            files, dirs = self._resolve(*key)
            strong |= files
            weak |= dirs
            if key in read_keys:
                read |= files | dirs
        for key in gkeys:
            found = self._glob(*key)
            strong.update(found)
            if key in read_gkeys:
                read |= found
        if WHOLE in strong:
            whole = True
            strong.discard(WHOLE)
        read.discard(WHOLE)
        return strong, weak - strong, whole, read

    def _demote_suites(self, from_suite, strong, weak):
        """(strong, weak) with every suite a non-suite names moved from strong to weak: only a suite RUNS another suite. A tool that names a suite in
        its usage text, or run-all.sh's list of live suites, depends on the file, not on what that suite depends on (following it made every
        suite depend on every other through the one suite that globs test/*.test.sh)."""
        if from_suite:
            return strong, weak - strong
        demoted = set(p for p in strong if self.nodes[p].kind == "suite")
        return strong - demoted, (weak | demoted) - (strong - demoted)

    def _dispatcher_vars(self, code):
        """{variable: True when it may hold the dispatcher} for the variables `code` assigns: a value that names heimdall or hmd, is another variable, or is the output of a command may; a path to any other tool may not.
        A variable `code` never assigns (it comes from the environment or a sourced file) is not in the answer, and the caller treats it as a possible dispatcher."""
        assigns = [(m.group(1), next(g for g in m.groups()[1:] if g is not None)) for line in code for m in ASSIGN_VALUE_RE.finditer(line)]
        out = {}
        for _ in range(2):                                  # the second pass sees the variables the first found (`local bin="$1"` then `HMD="$bin"`)
            names = self.dispatcher_names | set(n for n, v in out.items() if v)
            for n, v in assigns:
                out[n] = out.get(n, False) or may_be_dispatcher(v, names)
        return out

    def _invocations(self, code, shell):
        """(the literal words a file hands the dispatcher, whether it hands it a word it cannot read) for the calls in `code`: `heimdall version`, `"$HMD" "$cmd"`. In a shell file a call is a name in COMMAND position
        (a mention in text is not a call) and a variable counts unless the file sets it to some other tool (`FACE_BIN="$PLUGIN_DIR/bin/heimdall-face"` then `"$FACE_BIN" "$mode"` is not the dispatcher)."""
        known = self._dispatcher_vars(code) if shell else {}
        subs, dynamic = set(), False
        for line in code:
            hits = [(m, None) for m in DISP_TOK_RE.finditer(line)] + [(m, m.group(1)) for m in DISP_VAR_RE.finditer(line)]
            for m, var in hits:
                if shell and var is not None and not (known[var] if var in known else var in self.dispatcher_names):
                    continue                    # set here to some other tool, or set nowhere in the repository to anything that can be the dispatcher
                call = CALL_ARGS_RE.match(line, m.end())
                if call is None or (shell and not in_command_position(line[:m.start()])):
                    continue
                if call.group(1):
                    dynamic = True
                else:
                    subs.add(call.group(2))
        return subs, dynamic

    def _dispatcher_names(self):
        """The variables that some shell file in the repository sets to the dispatcher by name (`HMD="$REPO/bin/hmd"`): a file that calls one it never sets itself (it comes from a sourced library or a suite's
        environment) calls the dispatcher. A variable set only to other tools, to text or to an argument (`X="$1"`) is not here. Names are shared by every file, so a chain through another variable is followed only
        inside one file (_dispatcher_vars): a global chain would join every file that happens to call a variable `port`."""
        return set(m.group(1) for text in self.live.values() for m in ASSIGN_VALUE_RE.finditer(text)
                   if may_be_dispatcher(next(g for g in m.groups()[1:] if g is not None), frozenset(), True))

    def _mentions(self, lines):
        """The dispatcher's function names that `lines` name as a word anywhere (a call, a trap, a `$(...)`, a string): the only way a function body runs."""
        return frozenset(FN_WORD_RE.findall("\n".join(lines))) & self.fn_names if self.fn_names else frozenset()

    def _scan(self):
        self.dispatcher_names = self._dispatcher_names()
        self.fn_names = set(name for fns in self.functions.values() for name, _, _ in fns)
        for path in sorted(self.text):
            node, c_style = self.nodes[path], os.path.splitext(path)[1].lower() in C_STYLE
            suite = node.kind == "suite"
            live_text, units = self.live.get(path, self.text[path]), {}
            if path in self.functions:
                live_text, units = cut_functions(live_text, self.functions[path])
            code, comments = [], []
            for line in live_text.split("\n"):
                stripped = line.strip()
                if stripped:
                    (comments if is_comment(stripped, c_style) else code).append(line)
            python = os.path.splitext(path)[1].lower() == ".py" or bool(code and code[0].startswith("#!") and "python" in code[0])
            if python:
                code, prose = strip_docstrings(code)
                comments += prose
            if path in DISPATCHERS:
                eager_lines, arm_lines = split_arms(code)
            else:
                eager_lines, arm_lines = code, {}
            found, weak, whole, read = self._scan_lines(eager_lines, "suite" if suite else "code", python)
            found |= self._imports(path, code)
            if suite:
                # a header comment names what the suite tests (files only, never a directory); it never makes one suite depend on another
                found |= set(p for p in self._scan_lines(comments, "comment")[0] if self.nodes[p].kind != "suite")
                if whole:
                    self.whole.add(path)
            self.reads[path] = frozenset(read)
            self.mentions[path] = self._mentions(eager_lines)
            found.discard(path)
            found, weak = self._demote_suites(suite, found, weak)
            self.edges[path] = found
            self.leaves[path] = weak
            for word, lines in arm_lines.items():
                targets, arm_weak, _, arm_read = self._scan_lines(lines, "code", python)
                targets.discard(path)
                self.arms.setdefault(path, {})[word] = self._demote_suites(suite, targets, arm_weak)
                self.arm_reads[(path, word)] = frozenset(arm_read)
                self.arm_mentions[(path, word)] = self._mentions(lines)
            for name, text in units.items():
                lines = [l for l in text.split("\n") if l.strip() and not is_comment(l.strip(), False)]
                targets, fn_weak, _, fn_read = self._scan_lines(lines, "code")
                targets.discard(path)
                self.funcs.setdefault(path, {})[name] = self._demote_suites(suite, targets, fn_weak)
                self.func_reads[(path, name)] = frozenset(fn_read)
                self.func_mentions[(path, name)] = self._mentions(lines)
            if path not in DISPATCHERS and path not in FORWARDERS:
                subs, dynamic = self._invocations(code, path in self.live)
                if subs or dynamic:
                    self.invokes[path] = (frozenset(subs), dynamic)

    def _condense(self):
        """Reachability for every node at once: strongly connected components, then each component's reach as one big-integer bitmask
        (bit i = self.paths[i]). A closure is then an OR of a few masks instead of a walk of thousands of edges per suite."""
        self.paths = sorted(self.nodes)
        self.idx = dict((p, i) for i, p in enumerate(self.paths))
        self.all_bits = (1 << len(self.paths)) - 1
        adj = [sorted(self.idx[t] for t in self.edges.get(p, ())) for p in self.paths]
        self.comp, self.reach, self.rreach = condense(adj, [self.mask(self.leaves.get(p, ())) for p in self.paths],
                                                      [self.mask(self.reads.get(p, ())) for p in self.paths])
        self.inv_by_idx = dict((self.idx[p], v) for p, v in self.invokes.items())
        self.inv_mask = 0
        for i in self.inv_by_idx:
            self.inv_mask |= 1 << i
        self.fn_bit = dict((n, 1 << i) for i, n in enumerate(sorted(self.fn_names)))

        def fmask(names):
            bits = 0
            for n in names:
                bits |= self.fn_bit[n]
            return bits
        self.node_mentions = [fmask(self.mentions.get(p, ())) for p in self.paths]
        self.mention_nodes = 0
        for i, m in enumerate(self.node_mentions):
            if m:
                self.mention_nodes |= 1 << i
        self.arm_idx = dict((self.idx[d], dict((w, ([self.idx[t] for t in strong], self.mask(weak), self.mask(self.arm_reads.get((d, w), ())),
                                                     fmask(self.arm_mentions.get((d, w), ()))))
                                               for w, (strong, weak) in arms.items()))
                            for d, arms in self.arms.items())
        self.func_idx = dict((self.idx[d], dict((n, ([self.idx[t] for t in strong], self.mask(weak), self.mask(self.func_reads.get((d, n), ())),
                                                      self.fn_bit[n], fmask(self.func_mentions.get((d, n), ()))))
                                                for n, (strong, weak) in fns.items()))
                             for d, fns in self.funcs.items())

    def mask(self, paths):
        bits = 0
        for p in paths:
            bits |= 1 << self.idx[p]
        return bits

    # -- closure ----------------------------------------------------------------------------------------------------
    def _reach(self, i):
        return self.reach[self.comp[i]]

    def closure(self, suite):
        """The closure of `suite` as a bitmask over self.paths."""
        return self._closure(suite)[0]

    def _closure(self, suite):
        """(the closure of `suite` as a bitmask over self.paths, the files that some FOLLOWED member of it reads as text: the hash takes those as committed)."""
        hint = self.hints.get(suite, {})
        if hint.get("always_run") or suite in self.whole:
            return self.all_bits, self.all_bits
        got = self._cmemo.get(suite)
        if got is not None:
            return got
        i = self.idx[suite]
        bits, raw = self._reach(i), self.rreach[self.comp[i]]
        for extra in hint.get("extra", ()):
            j = self.idx[extra]
            bits |= self._reach(j)
            raw |= self.rreach[self.comp[j]] | (1 << j)
        released, called = set(), 0          # called: the function names that the arms and functions released so far mention
        while self.arm_idx or self.func_idx:
            subs, dynamic = set(), False
            for i in bit_indices(bits & self.inv_mask):
                found, dyn = self.inv_by_idx[i]
                subs |= found
                dynamic = dynamic or dyn
            mentioned = called
            for i in bit_indices(bits & self.mention_nodes):
                mentioned |= self.node_mentions[i]
            grew = False
            for disp, arms in self.arm_idx.items():
                if not (bits >> disp) & 1:
                    continue
                for word, (targets, weak_bits, read_bits, mention_bits) in arms.items():
                    if (disp, word) not in released and (dynamic or word in subs):
                        released.add((disp, word))
                        grew = True
                        bits |= weak_bits
                        raw |= read_bits
                        called |= mention_bits
                        for t in targets:
                            bits |= self._reach(t)
                            raw |= self.rreach[self.comp[t]]
            for disp, fns in self.func_idx.items():
                if not (bits >> disp) & 1:
                    continue
                for name, (targets, weak_bits, read_bits, own_bit, mention_bits) in fns.items():
                    if (disp, name) not in released and mentioned & own_bit:
                        released.add((disp, name))
                        grew = True
                        bits |= weak_bits
                        raw |= read_bits
                        called |= mention_bits
                        for t in targets:
                            bits |= self._reach(t)
                            raw |= self.rreach[self.comp[t]]
            if not grew:
                break
        self._cmemo[suite] = got = (bits, raw)
        return got

    def members(self, bits):
        return [self.paths[i] for i in bit_indices(bits)]

    def raw_bits(self, suite):
        """The members of `suite`'s closure that it, or any file it runs, reads as TEXT, which its closure hash takes as committed (comments included): every file when it enumerates the tree, else the files handed to
        a command that reads, the directories enumerated that way and the paths its hint adds."""
        return self._closure(suite)[1]

    def closure_sha(self, bits, raw=0):
        key = (bits, raw)
        got = self._sha.get(key)
        if got is None:
            committed = set(self.members(bits & raw))
            h = hashlib.sha256()
            for p in self.members(bits):
                ident = self.nodes[p].oid if p in committed else self.content.get(p, self.nodes[p].oid)
                h.update(("%s\t%s\n" % (p, ident)).encode("utf-8", "surrogateescape"))
            got = self._sha[key] = h.hexdigest()
        return got

    def hash_all(self):
        return [(s, self.closure_sha(*self._closure(s))) for s in self.suites()]

    def runner_salt_input(self):
        """(key, value) that stands for test/run-all.sh in the salt: the sha256 of its text without full-line comments, or its raw blob id when it cannot be stripped
        safely (see strip_full_line_comments; a link, a submodule, a binary or an oversized file is never stripped either)."""
        node = self.nodes.get(RUN_ALL)
        if node is None:
            return RUN_ALL, "absent"
        raw = (RUN_ALL + ":blob", node.oid)
        if node.mode not in ("100644", "100755"):
            return raw
        data = self.repo.git(["cat-file", "blob", node.oid]).stdout
        if len(data) > MAX_SCAN or b"\0" in data[:8192]:
            return raw
        stripped = strip_full_line_comments(data.decode("utf-8", "surrogateescape"))
        if stripped is None:
            return raw
        return RUN_ALL + ":code", sha256_hex(stripped.encode("utf-8", "surrogateescape"))

    def salt(self):
        h = hashlib.sha256()

        def put(key, value):
            h.update(("%s\t%s\n" % (key, value)).encode("utf-8", "surrogateescape"))

        def oid(path):
            return self.nodes[path].oid if path in self.nodes else "absent"
        here = os.path.dirname(os.path.abspath(__file__))
        put("schema", SCHEMA)
        put(*self.runner_salt_input())
        for p in RUNNER_LIBS:
            put(p, oid(p))
        put(HINTS, sha256_hex(self.hints_raw) if self.hints_raw is not None else "absent")
        put(CACHE_LIB, oid(CACHE_LIB))
        for name, path in (("suite_closure.py", os.path.abspath(__file__)),
                           ("heimdall-suite-closure", os.path.join(os.path.dirname(here), "heimdall-suite-closure")),
                           ("hook-owned-path.sh", os.path.join(here, "hook-owned-path.sh"))):
            put("engine:" + name, file_sha(path))
        put("bash", tool_version(["bash", "--version"]))
        put("jq", tool_version(["jq", "--version"]))
        put("python3", platform.python_version())
        put("git", tool_version(["git", "--version"]))
        put("uname", "%s %s" % (os.uname().sysname, os.uname().machine))
        return h.hexdigest()


# ── verify-receipt ────────────────────────────────────────────────────────────────────────────────────────────────────

def _int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _count(v):
    return _int(v) and v >= 0


def _matching(rx):
    return lambda v: isinstance(v, str) and rx.fullmatch(v) is not None


# name, test, what it must be: the cache block of a sweep receipt, as run-all.sh composes it
CACHE_FIELDS = (
    ("mode", lambda v: v == "closure", 'the string "closure"'),
    ("salt", _matching(SHA256_RE), "a sha256 (64 lowercase hex digits)"),
    ("suites_fresh", _count, "a count (an integer, 0 or more)"),
    ("suites_cached", _count, "a count (an integer, 0 or more)"),
    ("audited", _count, "a count (an integer, 0 or more)"),
    ("cold", lambda v: isinstance(v, bool), "true or false"),
    ("oldest_entry_age_days", lambda v: isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0, "a number of days, 0 or more"),
    ("entries", lambda v: isinstance(v, list), "a list of {suite, closure_sha, finished_at}"),
)
ENTRY_FIELDS = (
    ("suite", lambda v: isinstance(v, str) and v != "", "a non-empty suite name"),
    ("closure_sha", _matching(SHA256_RE), "a sha256 (64 lowercase hex digits)"),
    ("finished_at", _matching(STAMP_RE), "a UTC timestamp like 2026-10-13T12:00:00Z"),
)


def shape_problems(receipt):
    problems = []
    if not isinstance(receipt, dict):
        return ["the receipt is not a JSON object"]
    if not _matching(OID_RE)(receipt.get("head_sha")):
        problems.append("head_sha must be the full commit id the sweep graded (40 lowercase hex digits)")
    if not _int(receipt.get("exit_code")) or receipt.get("exit_code") != 0:
        problems.append("exit_code is %r, not 0: a red sweep proves nothing" % (receipt.get("exit_code"),))
    if receipt.get("kind") != "full":
        problems.append("kind is %r, not \"full\": only a full-equivalent sweep stands in for a full one" % (receipt.get("kind"),))
    if "full_equivalent" in receipt and receipt["full_equivalent"] is not True:
        problems.append("full_equivalent is %r: the receipt itself says it is not full-equivalent" % (receipt["full_equivalent"],))
    cache = receipt.get("cache")
    if not isinstance(cache, dict):
        problems.append("the receipt has no cache block (a receipt without one is not a closure-composed sweep)")
        return problems
    for name, ok, what in CACHE_FIELDS:
        if name not in cache:
            problems.append("cache.%s is missing (it must be %s)" % (name, what))
        elif not ok(cache[name]):
            problems.append("cache.%s must be %s" % (name, what))
    if isinstance(cache.get("entries"), list):
        for i, entry in enumerate(cache["entries"]):
            if not isinstance(entry, dict):
                problems.append("cache.entries[%d] must be an object" % i)
                continue
            for name, ok, what in ENTRY_FIELDS:
                if name not in entry:
                    problems.append("cache.entries[%d].%s is missing (it must be %s)" % (i, name, what))
                elif not ok(entry[name]):
                    problems.append("cache.entries[%d].%s must be %s" % (i, name, what))
    return problems


def live_patterns(runall_text):
    """The basename globs of run-all.sh's own live_reason() (its case labels), or None when that function cannot be read.
    run-all.sh stays the single definition of 'live': nothing here copies the list."""
    body = re.search(r"^live_reason\(\) \{\n(.*?)^\}", runall_text, re.S | re.M)
    if not body:
        return None
    pats = []
    for line in body.group(1).splitlines():
        label = re.match(r"^\s+(\S+)\)\s*$", line)
        if label:
            pats.extend(a for a in label.group(1).split("|") if a != "*")
    return pats


def _env_int(name):
    raw = os.environ.get(name, "")
    return int(raw) if raw.isdigit() else None


def _names(items, limit=5):
    shown = ", ".join(items[:limit])
    return shown + (" and %d more" % (len(items) - limit) if len(items) > limit else "")


def verify_receipt(repo, receipt_path, hints_path):
    """The reasons the receipt cannot stand in for a full sweep (an empty list = it can). Everything is recomputed at ITS commit."""
    try:
        with open(receipt_path, "rb") as fh:
            raw = fh.read(MAX_RECEIPT + 1)
        if len(raw) > MAX_RECEIPT:
            return ["%s is larger than %d bytes" % (receipt_path, MAX_RECEIPT)]
        receipt = json.loads(raw.decode("utf-8"))
    except (OSError, ValueError) as exc:
        return ["cannot read the receipt %s: %s" % (receipt_path, exc)]
    problems = shape_problems(receipt)
    if problems:
        return problems
    head = repo.resolve(receipt["head_sha"])
    if head is None:
        return ["head_sha %s is not a commit in this repository" % receipt["head_sha"][:12]]
    cache = receipt["cache"]
    graph = Graph(repo, head, hints_path)
    live = live_patterns(graph.text.get(RUN_ALL, ""))
    if live is None:
        live = []
        problems.append("test/run-all.sh at %s has no readable live_reason(), so no suite is treated as live" % head[:12])
    suites = graph.suites()
    shas = dict(graph.hash_all())
    if cache["salt"] != graph.salt():
        problems.append("salt changed: the test infrastructure, the hints, the closure engine or the toolchain differ from the sweep that "
                        "wrote this receipt, so none of its cached results can be trusted")
    entries, stale, ghosts, twice, aged, future = {}, [], [], [], [], []
    limit = MAX_AGE_DAYS
    tighter = _env_int("HMD_SUITE_CACHE_MAX_DAYS")
    if tighter is not None and tighter < limit:
        limit = tighter
    now = datetime.datetime.now(datetime.timezone.utc)
    for entry in cache["entries"]:
        suite = graph.suite_path(entry["suite"])
        if suite in entries:
            twice.append(suite)
        entries[suite] = entry
        if suite not in shas:
            ghosts.append(suite)
            continue
        if entry["closure_sha"] != shas[suite]:
            stale.append(suite)
        when = datetime.datetime.strptime(entry["finished_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        age = (now - when).total_seconds() / 86400.0
        if age < -1.0 / 24:
            future.append(suite)
        elif age > limit and not cache["cold"]:
            aged.append("%s (%.1f days)" % (suite, age))
    if twice:
        problems.append("entry for %s is listed twice" % _names(sorted(set(twice))))
    if ghosts:
        problems.append("entry names suite(s) that do not exist at the graded commit: %s" % _names(sorted(ghosts)))
    if stale:
        problems.append("closure of %d suite(s) changed since their result was recorded: %s" % (len(stale), _names(sorted(stale))))
    if future:
        problems.append("entry finished_at is in the future for %s" % _names(sorted(future)))
    if aged:
        problems.append("entry for %s is more than %d days old (limit %d): every suite must run cold at least that often" % (_names(sorted(aged)), limit, limit))
    missing = [s for s in suites if s not in entries and not any(fnmatch.fnmatchcase(s.rsplit("/", 1)[-1], pat) for pat in live)]
    if missing:
        problems.append("no green entry for %d suite(s): %s" % (len(missing), _names(missing)))
    if cache["cold"]:
        if cache["suites_cached"] or cache["audited"]:
            problems.append("cold is true, yet %d suite(s) were served from the cache and %d audited: a cold run ran every suite fresh"
                            % (cache["suites_cached"], cache["audited"]))
    else:
        hits = cache["suites_cached"] + cache["audited"]
        pct = max(AUDIT_PCT, _env_int("HMD_SUITE_CACHE_AUDIT_PCT") or 0)
        need = min(hits, max(AUDIT_FLOOR, int(math.ceil(hits * pct / 100.0))))
        if cache["audited"] < need:
            problems.append("audited %d suite(s), but max(%d, %d%% of the %d cache hits) = %d must be re-run to prove the cache still agrees "
                            "with the suites" % (cache["audited"], AUDIT_FLOOR, pct, hits, need))
    return problems


# ── CLI ───────────────────────────────────────────────────────────────────────────────────────────────────────────────

def emit(lines):
    sys.stdout.buffer.write("".join(l + "\n" for l in lines).encode("utf-8", "surrogateescape"))
    sys.stdout.buffer.flush()


def open_graph(args, edges=True):
    repo = Repo(args.repo)
    if args.rev is None:
        stray = repo.dirty(hook_owned_re())
        if stray:
            raise Fail("refusing: tracked files have uncommitted changes (%s). A closure hash describes the COMMIT, and the suites would run "
                       "against the work tree, so a result cached under it would be wrong. Commit them, or read an exact commit with --rev."
                       % _names(stray))
        rev = "HEAD"
    else:
        rev = args.rev
    commit = repo.resolve(rev)
    if commit is None:
        raise Fail("%s is not a commit in %s" % (rev, repo.top))
    return Graph(repo, commit, args.hints, edges)


def one_suite(graph, name):
    suite = graph.suite_path(name)
    if suite not in graph.nodes or graph.nodes[suite].kind != "suite":
        raise Fail("no such suite at %s: %s (a suite is test/<name>.test.sh)" % (graph.commit[:12], name))
    return suite


def cmd_hash_all(args):
    emit("%s\t%s" % pair for pair in open_graph(args).hash_all())
    return 0


def cmd_hash(args):
    graph = open_graph(args)
    suite = one_suite(graph, args.suite)
    emit([graph.closure_sha(graph.closure(suite), graph.raw_bits(suite))])
    return 0


def cmd_deps(args):
    graph = open_graph(args)
    emit(graph.members(graph.closure(one_suite(graph, args.suite))))
    return 0


def cmd_salt(args):
    emit([open_graph(args, edges=False).salt()])
    return 0


def cmd_verify(args):
    problems = verify_receipt(Repo(args.repo), args.receipt, args.hints)
    for problem in problems:
        sys.stderr.write("verify-receipt: %s\n" % problem)
    return 1 if problems else 0


def build_parser():
    parser = argparse.ArgumentParser(
        prog="heimdall-suite-closure", formatter_class=argparse.RawDescriptionHelpFormatter,
        description="The static dependency closure of a test suite (rules: bin/lib/suite_closure.py, proof: test/suite-closure.test.sh).",
        epilog="exit status: 0 ok; 1 verify-receipt refused the receipt (reasons on stderr); 2 usage error or refusal (a dirty tree, a bad hints file).\n"
               "A suite is test/<name>.test.sh, written as that path, as <name>.test.sh, or as an absolute path inside the repo.\n"
               "hash-all prints one `suite<TAB>closure_sha` line per test/*.test.sh, suite as the repo path.")
    sub = parser.add_subparsers(dest="cmd", metavar="{hash-all,hash,deps,salt,verify-receipt}")
    sub.required = True

    def common(p, rev=True, suite=False):
        p.add_argument("--repo", default=".", help="the repository (default: the cwd)")
        p.add_argument("--hints", help="a hints file (default: test/closure-hints.json as committed)")
        if rev:
            p.add_argument("--rev", help="read this commit's git objects instead of HEAD (no clean-tree requirement)")
        if suite:
            p.add_argument("--suite", required=True, help="the suite")
        return p
    common(sub.add_parser("hash-all", help="suite<TAB>closure_sha for every suite")).set_defaults(run=cmd_hash_all)
    common(sub.add_parser("hash", help="the closure_sha of one suite"), suite=True).set_defaults(run=cmd_hash)
    common(sub.add_parser("deps", help="the closure of one suite, sorted, one path per line (exactly what is hashed)"), suite=True).set_defaults(run=cmd_deps)
    common(sub.add_parser("salt", help="the salt: sha256 of the test infrastructure, hints, engine and toolchain")).set_defaults(run=cmd_salt)
    verify = common(sub.add_parser("verify-receipt", help="exit 0 only if the receipt's cache block re-derives at its own head_sha"), rev=False)
    verify.add_argument("--receipt", required=True, help="the sweep receipt (JSON) to verify")
    verify.set_defaults(run=cmd_verify)
    return parser


def main(argv):
    if hasattr(signal, "SIGPIPE"):
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    args = build_parser().parse_args(argv)
    try:
        return args.run(args)
    except Fail as exc:
        sys.stderr.write("heimdall-suite-closure: %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
