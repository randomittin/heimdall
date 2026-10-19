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
            Comment lines and Python docstrings count for a SUITE only as FILE names (its header names what it tests): never a plain word,
            a directory or another suite. For a tool they count for nothing (the 2026-10-12 comment-chain incident, bin/lib/sweep-chain.sh).
  dispatch  bin/heimdall routes `hmd <word>` to one arm of its top-level `case "${1:-}"`. What an arm names is followed only when the
            suite's closure invokes that word (`heimdall|hmd|$..HMD..|$..BIN.. <word>`); what the dispatcher names OUTSIDE its arms is
            always followed. bin/hmd is a pure forwarder and its own `"$@"` is not an invocation. An invocation with a non-literal
            word (`hmd "$cmd"`, `hmd "$@"`) follows every arm.
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
             The blob id, as committed, stands wherever the file can be read as TEXT: a script that reads its own header (`sed -n '2,40p' "$0"` is
             its --help), a Python file that does not tokenize or reads its own source, the paths a hint adds, everything a SUITE hands to a command
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

SCHEMA = 2                      # part of the salt: bump it whenever the rules above change what a closure is (2: shell and Python files are hashed without their comments)
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
DISP_NAME = r"(?:\bheimdall|\bhmd|\$\{?\w*(?:HMD|HEIMDALL|BIN)\w*\}?)[\"']?"
INV_RE = re.compile(DISP_NAME + r"\s+(?:--?[A-Za-z][\w=-]*\s+)*([A-Za-z][A-Za-z0-9-]*)\b")
DYN_RE = re.compile(DISP_NAME + r"\s+(?:--?[A-Za-z][\w=-]*\s+)*[\"']?\$")
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
DOUBLE_RE = re.compile(r'\\.|"')
ANSI_RE = re.compile(r"\\.|'")
SINGLE_QUOTED_RE = re.compile(r"'[^']*'")
QUOTED_RE = re.compile("'[^']*'|\"[^\"]*\"")
# the script's own path: $0, ${0}, $BASH_SOURCE, ${BASH_SOURCE[0]} (not ${0##*/}, which is a name); dirname or basename of it is a directory or a name, not the text
SELF_REF = r"\$(?:0\b|\{0\}|\{BASH_SOURCE[^}]*\}|BASH_SOURCE\b)"
SELF_REF_RE = re.compile(SELF_REF)
SELF_ASSIGN_RE = re.compile(r"^[ \t]*(?:(?:readonly|local|declare|typeset|export)[ \t]+(?:-\w+[ \t]+)*)?([A-Za-z_]\w*)=[\"']?(?:\$\()?"
                            r"(?:(?:readlink|realpath)(?:[ \t]+-\w+)*[ \t]+)?[\"']?" + SELF_REF, re.M)
SELF_NAME_RE = re.compile(r"\b(?:dirname|basename)\b(?:[ \t]+-\w+)*[ \t]+[\"']?" + SELF_REF + r"[\"']?")
PY_SELF_READ_RE = re.compile(rb"getsource|getcomments|getsourcelines|open\([^)\n]*__file__|__file__[^\n]*\.(?:read_text|read_bytes|read)\(")
# a command that reads the text of the file it is given: a suite that hands one a file, or a directory, sees its comments
READERS = ("grep|egrep|fgrep|rg|ag|sed|awk|gawk|perl|head|tail|cat|tac|nl|cut|tr|wc|diff|cmp|comm|sort|uniq|less|more|od|xxd|hexdump|strings|"
           "shasum|sha1sum|sha256sum|sha512sum|md5sum|md5|cksum|openssl|shellcheck|find|xargs|read|mapfile|readarray")
READER_RE = re.compile(r"\b(?:" + READERS + r")\b")
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


def quote_state(line, state):
    """The quoting state at the end of `line` ("" none, "'", '"' or "$'") for a line that starts in `state`. A comment ends the scan: what follows a `#` that starts a word is text, so an apostrophe in it opens nothing."""
    pos = 0
    while True:
        if state == "'":
            end = line.find("'", pos)
            if end < 0:
                return state
            pos, state = end + 1, ""
            continue
        rx = DOUBLE_RE if state == '"' else ANSI_RE if state == "$'" else UNQUOTED_RE
        for m in rx.finditer(line, pos):
            tok = m.group()
            if state:
                if tok[0] != "\\":                          # the quote that closes it
                    pos, state = m.end(), ""
                    break
            elif tok == "#":
                return state
            elif tok[0] != "\\":
                pos, state = m.end(), tok
                break
        else:
            return state


def reads_own_text(lines):
    """True when a shell script hands its own path to a command that reads text (`sed -n '2,40p' "$0"` prints the header comment as --help): a comment of such a script IS its behaviour."""
    names = set(SELF_ASSIGN_RE.findall("\n".join(lines)))
    ref = re.compile(SELF_REF + "".join(r"|\$\{?%s\b" % re.escape(n) for n in names)) if names else SELF_REF_RE
    for line in lines:
        if "$" in line:
            bare = SELF_NAME_RE.sub("", SINGLE_QUOTED_RE.sub("''", line))
            if READER_RE.search(bare) and ref.search(bare):
                return True
    return False


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
        end = quote_state(line, quote)
        joined = line.rstrip(" \t\r").endswith("\\")
        out.append(line.rstrip(" \t") if not quote and not end and not joined else line)
        quote = end
    return None if reads_own_text(out) else "\n".join(out)


def python_digest(data):
    """sha256 over the tokens of the Python source `data` without its comments (a `#!` first line stays) and its non-logical newlines, or None when it must be hashed as committed: it does not tokenize, or it reads its
    own source. A docstring and every other string is a token, so it stays, and so do the indentation and the encoding."""
    if PY_SELF_READ_RE.search(data):
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


def bit_indices(bits):
    """The positions of the set bits of `bits`, ascending."""
    return [i for i, c in enumerate(bin(bits)[:1:-1]) if c == "1"]


def condense(adj, leaf):
    """(component of each node, reach bitmask of each component) of the directed graph `adj` (node -> successors), iteratively (Tarjan):
    a component is finished after every component it reaches, so its reach is its own members OR the reach of its successors.
    leaf[v] is a bitmask of nodes that belong to v's closure without being followed (weak edges)."""
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
    reach = [0] * len(comps)
    for c, members in enumerate(comps):
        bits = 0
        for v in members:
            bits |= (1 << v) | leaf[v]
        for v in members:
            for w in adj[v]:
                if comp[w] != c:
                    bits |= reach[comp[w]]
        reach[c] = bits
    return comp, reach


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
        self._memo, self._gmemo, self._sha = {}, {}, {}
        self.content, self.reads = {}, {}       # path -> id of a shell or Python file hashed without its comments; suite -> the paths it reads as text
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

    def _scan_lines(self, lines, mode="code"):
        """(strong, weak, whole, read) for `lines` written in `mode` ("suite", "code" or "comment", see _resolve_uncached). strong = the files they name (and, in a suite, the directories a glob enumerates): the closure
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
            reads = suite and READER_RE.search(line) is not None
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
                reading = reads and reads_operand(line, m.start())
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

    def _scan(self):
        for path in sorted(self.text):
            node, c_style = self.nodes[path], os.path.splitext(path)[1].lower() in C_STYLE
            suite = node.kind == "suite"
            code, comments = [], []
            for line in self.text[path].split("\n"):
                stripped = line.strip()
                if stripped:
                    (comments if is_comment(stripped, c_style) else code).append(line)
            if os.path.splitext(path)[1].lower() == ".py" or (code and code[0].startswith("#!") and "python" in code[0]):
                code, prose = strip_docstrings(code)
                comments += prose
            if path in DISPATCHERS:
                eager_lines, arm_lines = split_arms(code)
            else:
                eager_lines, arm_lines = code, {}
            found, weak, whole, read = self._scan_lines(eager_lines, "suite" if suite else "code")
            found |= self._imports(path, code)
            if suite:
                # a header comment names what the suite tests (files only, never a directory); it never makes one suite depend on another
                found |= set(p for p in self._scan_lines(comments, "comment")[0] if self.nodes[p].kind != "suite")
                if whole:
                    self.whole.add(path)
                self.reads[path] = frozenset(read)
            found.discard(path)
            found, weak = self._demote_suites(suite, found, weak)
            self.edges[path] = found
            self.leaves[path] = weak
            for word, lines in arm_lines.items():
                targets, arm_weak, _, _ = self._scan_lines(lines)
                targets.discard(path)
                self.arms.setdefault(path, {})[word] = self._demote_suites(suite, targets, arm_weak)
            if path not in DISPATCHERS and path not in FORWARDERS:
                subs = set(m.group(1) for line in code for m in INV_RE.finditer(line))
                dynamic = any(DYN_RE.search(line) for line in code)
                if subs or dynamic:
                    self.invokes[path] = (frozenset(subs), dynamic)

    def _condense(self):
        """Reachability for every node at once: strongly connected components, then each component's reach as one big-integer bitmask
        (bit i = self.paths[i]). A closure is then an OR of a few masks instead of a walk of thousands of edges per suite."""
        self.paths = sorted(self.nodes)
        self.idx = dict((p, i) for i, p in enumerate(self.paths))
        self.all_bits = (1 << len(self.paths)) - 1
        adj = [sorted(self.idx[t] for t in self.edges.get(p, ())) for p in self.paths]
        self.comp, self.reach = condense(adj, [self.mask(self.leaves.get(p, ())) for p in self.paths])
        self.inv_by_idx = dict((self.idx[p], v) for p, v in self.invokes.items())
        self.inv_mask = 0
        for i in self.inv_by_idx:
            self.inv_mask |= 1 << i
        self.arm_idx = dict((self.idx[d], dict((w, ([self.idx[t] for t in strong], self.mask(weak))) for w, (strong, weak) in arms.items()))
                            for d, arms in self.arms.items())

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
        hint = self.hints.get(suite, {})
        if hint.get("always_run") or suite in self.whole:
            return self.all_bits
        bits = self._reach(self.idx[suite])
        for extra in hint.get("extra", ()):
            bits |= self._reach(self.idx[extra])
        released = set()
        while self.arm_idx:
            subs, dynamic = set(), False
            for i in bit_indices(bits & self.inv_mask):
                found, dyn = self.inv_by_idx[i]
                subs |= found
                dynamic = dynamic or dyn
            grew = False
            for disp, arms in self.arm_idx.items():
                if not (bits >> disp) & 1:
                    continue
                for word, (targets, weak_bits) in arms.items():
                    if (disp, word) not in released and (dynamic or word in subs):
                        released.add((disp, word))
                        grew = True
                        bits |= weak_bits
                        for t in targets:
                            bits |= self._reach(t)
            if not grew:
                break
        return bits

    def members(self, bits):
        return [self.paths[i] for i in bit_indices(bits)]

    def raw_bits(self, suite):
        """The members of `suite`'s closure that it reads as TEXT, which its closure hash takes as committed (comments included): every file when it enumerates the tree, else the files it hands to a command that
        reads, the directories it enumerates that way and the paths its hint adds."""
        hint = self.hints.get(suite, {})
        if hint.get("always_run") or suite in self.whole:
            return self.all_bits
        return self.mask(set(self.reads.get(suite, ())) | set(hint.get("extra", ())))

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
        return [(s, self.closure_sha(self.closure(s), self.raw_bits(s))) for s in self.suites()]

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
