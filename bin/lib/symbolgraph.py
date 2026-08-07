#!/usr/bin/env python3
"""symbolgraph — a repo-wide symbol/call graph, built to answer navigation
questions WITHOUT reading whole files.

Why this exists
---------------
The expensive way to answer "what calls pad_or_truncate() and what breaks if I
change it" is: grep, then Read five files in full, then Read their callers in
full. Almost every byte of that is irrelevant. This module answers the same
question from an index: definition site with a line range, the call/reference
sites as file:line, one hop each way, and the transitive caller set.

Honesty contract
----------------
A symbol graph that SILENTLY misses a caller is worse than no graph at all: an
agent would run `impact`, see a short list, and conclude a change is safe when
it is not. So every extractor here declares its own precision, `impact` prints
its blind spots in its own output (see LIMITATIONS), and nothing is ever served
from a stale index — the cache carries a repo-state stamp and is rebuilt the
moment the stamp disagrees with the working tree.

Extractors, by precision
------------------------
  python      — the stdlib `ast` module. Exact for statically-written calls;
                see LIMITATIONS for what no static pass can see.
  shell       — a quote/comment/heredoc state machine plus a command-position
                classifier. Heuristic. Identifiers found inside single-quoted
                literals are recorded as `quoted` edges (marked `~` in output)
                rather than dropped, because a silent miss is the dangerous
                direction and a marked maybe is the safe one.
  javascript  — delegated to bin/lib/treesitter_ast.py when the tree-sitter
                grammars are installed. When they are not, javascript is listed
                in `skipped` with a reason; it is never silently half-indexed.

Everything else in the tree is not indexed and says so in `skipped`.
"""

import ast
import hashlib
import json
import os
import re
import subprocess
import sys
import time

SCHEMA_VERSION = 1
# Bump when an extractor changes shape — it participates in the stamp, so a
# behaviour change invalidates every cached index rather than serving old edges.
ENGINE_VERSION = "2"

DEFAULT_LIMIT = 40
MAX_FILE_BYTES = 1000000

# Directories that are never project source. Mirrors bin/lib/comprehension.py's
# SKIP_DIRS so the two censuses agree on what "the project" means.
SKIP_DIRS = {
    ".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "build",
    "target", ".next", ".idea", ".vscode", "vendor", ".worktrees",
    ".heimdall", ".designmatch", ".pytest_cache", ".mypy_cache", "coverage",
}

EXT_LANG = {
    ".py": "python",
    ".sh": "shell", ".bash": "shell",
    ".js": "javascript", ".mjs": "javascript", ".cjs": "javascript",
}

# Extensionless executables are the norm in bin/ and hooks/, so language has to
# come from the shebang or the whole CLI surface would be invisible.
SHEBANG_LANG = (
    ("python", "python"),
    ("bash", "shell"),
    ("zsh", "shell"),
    ("sh", "shell"),
    ("node", "javascript"),
)

BACKEND_LABEL = {
    "python": "python-ast (exact for static calls)",
    "shell": "quote/heredoc state machine + command-position classifier (heuristic)",
    "javascript": "tree-sitter",
}

# Edge kinds that mean "control actually reaches the target".
CALL_KINDS = ("call", "quoted")

# Printed BY `impact` ITSELF, not just in docs — the agent deciding whether a
# change is safe is the one who has to read this.
LIMITATIONS = (
    "known callers only, NOT exhaustive. A static index cannot see:",
    "dynamic dispatch (getattr/globals()[name]/setattr, method tables)",
    "string-built or eval'd calls (eval, exec, importlib, subprocess of a built cmd)",
    "shell indirection ($cmd, eval, ${fn:-default}, arrays of command names)",
    "runtime plugin/hook loading (entry points, glob-and-source, dynamic imports)",
    "cross-language calls (a shell script invoking a python entry point)",
    "callers living outside this repo",
    "~ marks a low-confidence edge (identifier seen inside a shell literal)",
    "? marks an AMBIGUOUS edge: the name has several definitions and the call "
    "site does not pick one, so this row may belong to a namesake",
)


# ── repo + file census ────────────────────────────────────────────────────────

def repo_root(start=None):
    """Git toplevel of `start`, or `start` itself when it is not a repo."""
    base = os.path.abspath(start or os.getcwd())
    try:
        out = subprocess.run(
            ["git", "-C", base, "rev-parse", "--show-toplevel"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
        )
    except (OSError, ValueError):
        return base
    if out.returncode == 0:
        top = out.stdout.decode("utf-8", "replace").strip()
        if top:
            return top
    return base


def _shebang_lang(path):
    try:
        with open(path, "rb") as fh:
            head = fh.read(128)
    except OSError:
        return None
    if not head.startswith(b"#!"):
        return None
    line = head.split(b"\n", 1)[0].decode("utf-8", "replace").lower()
    for token, lang in SHEBANG_LANG:
        if token in line:
            return lang
    return None


def _git_files(root):
    """Tracked + untracked-but-not-ignored paths. Untracked matters: a file an
    agent just wrote is exactly the one it wants to navigate."""
    try:
        out = subprocess.run(
            ["git", "-C", root, "ls-files", "--cached", "--others",
             "--exclude-standard", "-z"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
        )
    except (OSError, ValueError):
        return None
    if out.returncode != 0:
        return None
    raw = out.stdout.decode("utf-8", "replace")
    return [p for p in raw.split("\0") if p]


def _walk_files(root):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".git")]
        for name in filenames:
            full = os.path.join(dirpath, name)
            found.append(os.path.relpath(full, root))
    return found


def source_files(root):
    """[(relpath, lang)] for every indexable source file under `root`."""
    rels = _git_files(root)
    if rels is None:
        rels = _walk_files(root)
    out = []
    for rel in rels:
        parts = rel.split(os.sep)
        if any(p in SKIP_DIRS for p in parts):
            continue
        full = os.path.join(root, rel)
        if os.path.islink(full) or not os.path.isfile(full):
            continue
        ext = os.path.splitext(rel)[1].lower()
        lang = EXT_LANG.get(ext)
        if lang is None:
            if ext:
                continue
            lang = _shebang_lang(full)
            if lang is None:
                continue
        try:
            if os.path.getsize(full) > MAX_FILE_BYTES:
                continue
        except OSError:
            continue
        out.append((rel, lang))
    out.sort()
    return out


def stamp_for(root, files):
    """A repo-state marker over exactly the files that feed the index: path,
    size and mtime. Any edit, add or delete moves it, so a cached index can
    never be served for a tree it does not describe."""
    h = hashlib.sha256()
    h.update(("engine=%s schema=%d\n" % (ENGINE_VERSION, SCHEMA_VERSION)).encode())
    for rel, lang in files:
        full = os.path.join(root, rel)
        try:
            st = os.stat(full)
        except OSError:
            continue
        h.update(("%s\0%s\0%d\0%d\n" % (rel, lang, st.st_size, st.st_mtime_ns)).encode("utf-8", "replace"))
    return "sha256:" + h.hexdigest()[:32]


# ── python extraction (stdlib ast — exact for static calls) ───────────────────

def _py_callee_name(func):
    if isinstance(func, ast.Name):
        return func.id
    if isinstance(func, ast.Attribute):
        return func.attr
    return None


def _py_extract(rel, src):
    """(symbols, edges) for one python file.

    symbols: [(name, kind, start, end)]
    edges:   [(line, enclosing_symbol_local_index_or_-1, target_name, kind)]
    """
    try:
        tree = ast.parse(src, filename=rel)
    except (SyntaxError, ValueError):
        # A file that does not parse contributes nothing rather than a guess.
        return [], []

    symbols = []
    edges = []
    consumed = set()

    def add_symbol(node, name, kind):
        start = getattr(node, "lineno", 1)
        end = getattr(node, "end_lineno", None) or start
        symbols.append((name, kind, start, end))
        return len(symbols) - 1

    def record(line, scope, name, kind):
        if name:
            edges.append((line, scope, name, kind))

    def visit_expr(node, scope):
        """Walk an expression/statement subtree, recording reference edges and
        descending into any nested definition with the right scope."""
        stack = [node]
        while stack:
            cur = stack.pop()
            if isinstance(cur, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                visit_def(cur, scope, False)
                continue
            if isinstance(cur, (ast.Import, ast.ImportFrom)):
                for alias in cur.names:
                    record(cur.lineno, scope, alias.name.rsplit(".", 1)[-1], "import")
                continue
            if isinstance(cur, ast.Call):
                record(getattr(cur, "lineno", 1), scope, _py_callee_name(cur.func), "call")
                consumed.add(id(cur.func))
            elif isinstance(cur, ast.Name) and id(cur) not in consumed:
                if isinstance(cur.ctx, ast.Load):
                    record(cur.lineno, scope, cur.id, "ref")
            elif isinstance(cur, ast.Attribute) and id(cur) not in consumed:
                if isinstance(cur.ctx, ast.Load):
                    record(cur.lineno, scope, cur.attr, "ref")
            stack.extend(ast.iter_child_nodes(cur))

    def visit_def(node, scope, in_class):
        """Register `node` as a symbol, then walk its body under that scope."""
        if isinstance(node, ast.ClassDef):
            idx = add_symbol(node, node.name, "class")
            for base in node.bases:
                record(getattr(base, "lineno", node.lineno), idx,
                       _py_callee_name(base) or getattr(base, "id", None), "extend")
                consumed.add(id(base))
            body_in_class = True
        else:
            idx = add_symbol(node, node.name, "method" if in_class else "function")
            body_in_class = False
        for dec in node.decorator_list:
            visit_expr(dec, scope)
        for child in node.body:
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                visit_def(child, idx, body_in_class)
            else:
                visit_expr(child, idx)

    for top in tree.body:
        if isinstance(top, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            visit_def(top, -1, False)
        else:
            visit_expr(top, -1)

    return symbols, edges


# ── shell extraction (state machine + command-position classifier) ────────────

_SH_NAME = r"[A-Za-z_][A-Za-z0-9_:.\-]*"
_SH_DEF_PAREN = re.compile(r"^[ \t]*(?:function[ \t]+)?(" + _SH_NAME + r")[ \t]*\(\)[ \t]*")
_SH_DEF_KEYWORD = re.compile(r"^[ \t]*function[ \t]+(" + _SH_NAME + r")[ \t]*\{")
_SH_HEREDOC = re.compile(r"<<(-?)[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
# One tokenizer pass per line beats one scan per known name: this repo has 1618
# distinct shell function names over 158k shell lines, so the per-name scan was
# 256M string searches. Never ends on a separator, so `foo` inside `foo-bar`
# stays a non-match (it is one shell word, not a call to foo).
_SH_TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:[:.\-][A-Za-z0-9_]+)*")
_SH_CMD_OPENERS = set(";|&({`!")
_SH_CMD_WORDS = {"then", "else", "elif", "do", "if", "while", "until", "time", "&&", "||", "!"}


def _cmdsubst_spans(line):
    """Keep only `$( … )` and backtick spans, blank the rest. Used for the body
    of an UNQUOTED heredoc, where expansions really do run."""
    out = [" "] * len(line)
    i = 0
    n = len(line)
    while i < n:
        if line[i] == "$" and i + 1 < n and line[i + 1] == "(":
            depth = 0
            j = i + 1
            while j < n:
                if line[j] == "(":
                    depth += 1
                elif line[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                out[j] = line[j]
                j += 1
            i = j + 1
            continue
        if line[i] == "`":
            j = i + 1
            while j < n and line[j] != "`":
                out[j] = line[j]
                j += 1
            i = j + 1
            continue
        i += 1
    return "".join(out)


def _shell_texts(lines):
    """Two parallel views of each line, positions preserved:

      code — comments, single-quoted literals and quoted-heredoc bodies blanked.
             This is command text: safe for brace depth and command position.
      scan — comments and quoted-heredoc bodies blanked, single-quoted literals
             KEPT. `trap 'cleanup' EXIT` really does reach cleanup, so the
             identifier survives here and becomes a marked `quoted` edge.
    """
    code_out = []
    scan_out = []
    in_sq = False
    in_dq = False
    pending = []
    active = None

    for raw in lines:
        line = raw.rstrip("\n")
        width = len(line)

        if active is not None:
            delim, expand, dashed = active
            probe = line.strip() if dashed else line.rstrip()
            if probe == delim:
                active = pending.pop(0) if pending else None
                code_out.append(" " * width)
                scan_out.append(" " * width)
                continue
            if expand:
                keep = _cmdsubst_spans(line)
                code_out.append(keep)
                scan_out.append(keep)
            else:
                code_out.append(" " * width)
                scan_out.append(" " * width)
            continue

        code = []
        scan = []
        i = 0
        while i < width:
            ch = line[i]
            if in_sq:
                if ch == "'":
                    in_sq = False
                    code.append(" ")
                    scan.append(" ")
                else:
                    code.append(" ")
                    scan.append(ch)
                i += 1
                continue
            if ch == "\\" and i + 1 < width:
                code.append("  ")
                scan.append("  ")
                i += 2
                continue
            if ch == '"':
                in_dq = not in_dq
                code.append(" ")
                scan.append(" ")
                i += 1
                continue
            if ch == "'" and not in_dq:
                in_sq = True
                code.append(" ")
                scan.append(" ")
                i += 1
                continue
            if ch == "#" and not in_dq:
                prev = line[i - 1] if i > 0 else ""
                if prev == "" or prev in " \t;&|(":
                    pad = " " * (width - i)
                    code.append(pad)
                    scan.append(pad)
                    break
            code.append(ch)
            scan.append(ch)
            i += 1

        code_line = "".join(code)
        code_out.append(code_line)
        scan_out.append("".join(scan))

        for dash, quote, delim in _SH_HEREDOC.findall(code_line):
            pending.append((delim, quote == "", dash == "-"))
        if pending and active is None:
            active = pending.pop(0)

    return code_out, scan_out


def _sh_span_end(code, start_idx, name_end_col):
    """End line (1-based) of the function whose body opens at/after
    `name_end_col` on line index `start_idx`, by brace depth over code text."""
    depth = 0
    seen_open = False
    col = name_end_col
    for idx in range(start_idx, len(code)):
        line = code[idx]
        j = col if idx == start_idx else 0
        while j < len(line):
            if line[j] == "{":
                depth += 1
                seen_open = True
            elif line[j] == "}":
                depth -= 1
                if seen_open and depth <= 0:
                    return idx + 1
            j += 1
        col = 0
    return None


def _sh_command_position(text, col):
    """Is the identifier starting at `col` in command position?"""
    head = text[:col].rstrip()
    if not head:
        return True
    if head[-1] in _SH_CMD_OPENERS:
        return True
    if head.endswith("$("):
        return True
    words = head.split()
    return bool(words) and words[-1] in _SH_CMD_WORDS


def _sh_defs(code):
    """[(name, kind, start, end)] from the code view of one shell file."""
    raw_defs = []
    for idx, line in enumerate(code):
        m = _SH_DEF_PAREN.match(line)
        if m:
            raw_defs.append((m.group(1), idx, m.end()))
            continue
        m = _SH_DEF_KEYWORD.match(line)
        if m:
            raw_defs.append((m.group(1), idx, m.end() - 1))
    symbols = []
    for pos, (name, idx, col) in enumerate(raw_defs):
        end = _sh_span_end(code, idx, col)
        if end is None:
            # Unbalanced braces (a construct the state machine could not see).
            # Fall back to "up to the next definition" rather than claiming a
            # span running to EOF that would swallow every later function.
            end = raw_defs[pos + 1][1] if pos + 1 < len(raw_defs) else len(code)
        symbols.append((name, "function", idx + 1, max(end, idx + 1)))
    return symbols


def _enclosing_finder(symbols):
    """Innermost symbol containing a line — shared by the shell and JS passes."""
    ranges = [(s[2], s[3], i) for i, s in enumerate(symbols)]

    def enclosing(lineno):
        best = -1
        best_width = None
        for start, end, idx in ranges:
            if start <= lineno <= end:
                width = end - start
                if best_width is None or width < best_width:
                    best_width = width
                    best = idx
        return best

    return enclosing


def _sh_edges(code, scan, symbols, known_names):
    """[(line, enclosing_local_index_or_-1, target, kind)] for one shell file."""
    def_lines = {s[2] for s in symbols}
    enclosing = _enclosing_finder(symbols)
    edges = []

    for idx, scan_line in enumerate(scan):
        lineno = idx + 1
        code_line = code[idx]
        own_def = _SH_DEF_PAREN.match(code_line) if lineno in def_lines else None
        for m in _SH_TOKEN.finditer(scan_line):
            name = m.group(0)
            if name not in known_names:
                continue
            at, end_at = m.start(), m.end()
            before = scan_line[at - 1] if at > 0 else ""
            after = scan_line[end_at] if end_at < len(scan_line) else ""
            if before == "$":
                continue
            if after == "=" and scan_line[end_at:end_at + 2] != "==":
                continue
            if own_def is not None and own_def.group(1) == name and own_def.start(1) == at:
                continue
            if code_line[at:end_at] == name:
                kind = "call" if _sh_command_position(code_line, at) else "ref"
            else:
                kind = "quoted"
            edges.append((lineno, enclosing(lineno), name, kind))
    return edges


# ── javascript extraction (delegated to the tree-sitter substrate) ────────────

def _load_treesitter():
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "treesitter_ast.py")
    if not os.path.isfile(path):
        return None, "bin/lib/treesitter_ast.py not found next to symbolgraph.py"
    if here not in sys.path:
        sys.path.insert(0, here)
    try:
        import treesitter_ast
    except Exception as exc:  # noqa: BLE001 — an optional substrate degrades, never aborts
        return None, "import failed: %s" % exc
    try:
        info = treesitter_ast.backend_info()
    except Exception as exc:  # noqa: BLE001
        return None, "backend probe failed: %s" % exc
    if not info.get("available"):
        return None, info.get("reason") or "tree-sitter grammars not installed"
    if "javascript" not in (info.get("languages") or []):
        return None, "tree-sitter is present but the javascript grammar is not"
    return treesitter_ast, ""


def _js_extract(mod, full):
    res = mod.extract_from_path(full, "javascript")
    if not getattr(res, "available", False):
        return None, getattr(res, "reason", "extraction unavailable")
    symbols = [(s.name, s.kind, s.span[0], s.span[1]) for s in res.symbols]
    enclosing = _enclosing_finder(symbols)
    edges = [(r.line, enclosing(r.line), r.name, r.kind) for r in res.references]
    return (symbols, edges), ""


# ── index build ───────────────────────────────────────────────────────────────

def build_index(root):
    files = source_files(root)
    langs_present = sorted({lang for _rel, lang in files})

    ts_mod = None
    ts_reason = ""
    if "javascript" in langs_present:
        ts_mod, ts_reason = _load_treesitter()

    symbols = []
    edges = []
    skipped = []
    by_lang = {}
    read_failures = 0

    # Pass 1: definitions. Shell reference scanning needs the repo-wide set of
    # shell function names, so it cannot run until every shell file is parsed.
    per_file = []
    for rel, lang in files:
        full = os.path.join(root, rel)
        try:
            with open(full, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            read_failures += 1
            continue
        if lang == "python":
            syms, file_edges = _py_extract(rel, text)
            per_file.append((rel, lang, syms, file_edges, None))
        elif lang == "shell":
            code, scan = _shell_texts(text.splitlines())
            syms = _sh_defs(code)
            per_file.append((rel, lang, syms, None, (code, scan)))
        elif lang == "javascript":
            if ts_mod is None:
                continue
            got, reason = _js_extract(ts_mod, full)
            if got is None:
                skipped.append({"file": rel, "lang": lang, "reason": reason})
                continue
            syms, file_edges = got
            per_file.append((rel, lang, syms, file_edges, None))

    shell_names = {
        sym[0]
        for _rel, lang, syms, _e, _t in per_file
        if lang == "shell"
        for sym in syms
    }
    defined_names = {sym[0] for _rel, _lang, syms, _e, _t in per_file for sym in syms}

    # Pass 2: flatten, resolving shell edges now that the name set is known.
    for rel, lang, syms, file_edges, texts in per_file:
        base = len(symbols)
        for name, kind, start, end in syms:
            symbols.append({"n": name, "k": kind, "f": rel, "a": start, "b": end, "l": lang})
        by_lang[lang] = by_lang.get(lang, 0) + 1
        if lang == "shell":
            file_edges = _sh_edges(texts[0], texts[1], syms, shell_names)
        for line, local, target, kind in file_edges:
            # Call edges are kept whole (an external callee like subprocess.run
            # is real information for `callees`). Non-call reference edges are
            # kept only when they point at something this repo defines —
            # otherwise every local variable load would enter the index.
            if kind != "call" and target not in defined_names:
                continue
            edges.append({
                "f": rel, "l": line,
                "s": base + local if local >= 0 else -1,
                "t": target, "k": kind,
            })

    languages = {lang: BACKEND_LABEL[lang] for lang in langs_present if lang in BACKEND_LABEL}
    if "javascript" in langs_present and ts_mod is None:
        languages.pop("javascript", None)
        skipped.append({
            "lang": "javascript",
            "reason": "tree-sitter unavailable — %s. Install: python3 -m pip install "
                      "tree-sitter tree-sitter-javascript" % (ts_reason or "no grammar"),
        })
    if read_failures:
        skipped.append({"lang": "*", "reason": "%d file(s) unreadable and left out" % read_failures})

    return {
        "schema_version": SCHEMA_VERSION,
        "engine": ENGINE_VERSION,
        "repo": root,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "stamp": stamp_for(root, files),
        "languages": languages,
        "skipped": skipped,
        "limitations": list(LIMITATIONS),
        "stats": {
            "files": len(per_file),
            "symbols": len(symbols),
            "edges": len(edges),
            "by_lang": by_lang,
        },
        # rel -> lang, for the call-site resolver: a python call site can never
        # mean a shell function of the same name.
        "files": {rel: lang for rel, lang, _s, _e, _t in per_file},
        "symbols": symbols,
        "edges": edges,
    }


# ── cache with a repo-state stamp (never serve stale) ─────────────────────────

def cache_path(root):
    home = os.environ.get("HEIMDALL_HOME") or os.path.join(root, ".heimdall")
    return os.path.join(home, "symbolgraph.json")


def _read_cache(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("schema_version") != SCHEMA_VERSION:
        return None
    if data.get("engine") != ENGINE_VERSION:
        return None
    return data


def _write_cache(path, index):
    directory = os.path.dirname(path)
    try:
        os.makedirs(directory, exist_ok=True)
        tmp = "%s.tmp.%d" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(index, fh, separators=(",", ":"))
        os.replace(tmp, path)
        return True
    except OSError:
        # A read-only home is not a reason to fail a query; the index simply
        # stays in memory for this invocation.
        return False


def load_index(root, force=False):
    """(index, freshness) where freshness is 'cached' | 'rebuilt' | 'built'.

    Never returns an index whose stamp disagrees with the working tree.
    """
    path = cache_path(root)
    if not force:
        cached = _read_cache(path)
        if cached is not None and cached.get("stamp") == stamp_for(root, source_files(root)):
            return cached, "cached"
        if cached is not None:
            index = build_index(root)
            _write_cache(path, index)
            return index, "rebuilt"
    index = build_index(root)
    _write_cache(path, index)
    return index, "built"


# ── queries ───────────────────────────────────────────────────────────────────

def _symbol_indices(index, name):
    return [i for i, s in enumerate(index["symbols"]) if s["n"] == name]


def _resolver(index):
    """Resolve a call site (file, target-name) to the definition(s) it plausibly
    means, narrowest scope first:

      1. a definition of that name in the SAME FILE — takes it, alone;
      2. otherwise definitions in the SAME LANGUAGE;
      3. otherwise every definition of the name.

    Without this, a generic name poisons the graph: `main` in a python file
    would link to all 300 shell `main`s, and `impact` would report a change to a
    statusline helper as reaching every CLI in bin/. Over-reporting on that scale
    is not "safely conservative" — it is noise an agent learns to ignore.
    """
    symbols = index["symbols"]
    files = index.get("files", {})
    by_name = {}
    for i, s in enumerate(symbols):
        by_name.setdefault(s["n"], []).append(i)
    cache = {}

    def resolve(edge_file, target):
        key = (edge_file, target)
        hit = cache.get(key)
        if hit is not None:
            return hit
        cands = by_name.get(target)
        if not cands:
            cache[key] = ()
            return ()
        same_file = tuple(i for i in cands if symbols[i]["f"] == edge_file)
        if same_file:
            cache[key] = same_file
            return same_file
        lang = files.get(edge_file)
        if lang:
            same_lang = tuple(i for i in cands if symbols[i]["l"] == lang)
            if same_lang:
                cache[key] = same_lang
                return same_lang
        cache[key] = tuple(cands)
        return cache[key]

    return resolve


def _scope_label(index, edge):
    if edge["s"] >= 0:
        return index["symbols"][edge["s"]]["n"]
    return "(module)"


def cap(rows, limit):
    """(shown, hidden) — the whole point of this tool is a small answer."""
    if limit <= 0 or len(rows) <= limit:
        return rows, 0
    return rows[:limit], len(rows) - limit


def q_def(index, name):
    return [index["symbols"][i] for i in _symbol_indices(index, name)]


def q_refs(index, name):
    rows = []
    for s in q_def(index, name):
        rows.append({"file": s["f"], "line": s["a"], "end": s["b"], "kind": "def", "scope": s["n"]})
    for e in index["edges"]:
        if e["t"] == name:
            rows.append({"file": e["f"], "line": e["l"], "kind": e["k"], "scope": _scope_label(index, e)})
    rows.sort(key=lambda r: (r["file"], r["line"]))
    return rows


def _caller_row(index, e, ambiguous):
    if e["s"] >= 0:
        caller = index["symbols"][e["s"]]
        return {
            "file": e["f"], "line": e["l"], "edge": e["k"], "ambiguous": ambiguous,
            "caller": caller["n"], "caller_kind": caller["k"],
            "caller_file": caller["f"], "caller_span": [caller["a"], caller["b"]],
        }
    return {
        "file": e["f"], "line": e["l"], "edge": e["k"], "ambiguous": ambiguous,
        "caller": "(module)", "caller_kind": "module",
        "caller_file": e["f"], "caller_span": [e["l"], e["l"]],
    }


def q_callers(index, name):
    """Call sites that resolve to a DEFINITION of `name` (see _resolver). When
    the name has no definition in this repo, falls back to name matching so a
    sourced-from-elsewhere function still reports its known call sites."""
    resolve = _resolver(index)
    targets = set(_symbol_indices(index, name))
    rows = []
    for e in index["edges"]:
        if e["k"] not in CALL_KINDS:
            continue
        if targets:
            hit = resolve(e["f"], e["t"])
            if not targets.intersection(hit):
                continue
            ambiguous = len(hit) > 1
        else:
            if e["t"] != name:
                continue
            ambiguous = False
        rows.append(_caller_row(index, e, ambiguous))
    rows.sort(key=lambda r: (r["file"], r["line"]))
    return rows


def q_callees(index, name):
    idxs = set(_symbol_indices(index, name))
    if not idxs:
        return []
    resolve = _resolver(index)
    rows = []
    for e in index["edges"]:
        if e["s"] in idxs and e["k"] in CALL_KINDS:
            hit = resolve(e["f"], e["t"])
            rows.append({
                "file": e["f"], "line": e["l"], "edge": e["k"],
                "callee": e["t"], "resolved": bool(hit), "ambiguous": len(hit) > 1,
            })
    rows.sort(key=lambda r: (r["file"], r["line"]))
    return rows


def q_impact(index, name):
    """Transitive KNOWN callers, breadth-first, with the depth each was reached
    at.

    Traversal is over symbol IDENTITY (a definition), never over a bare name —
    otherwise reaching a caller called `main` would drag in every other `main`
    in the repo. Each definition is expanded once. See LIMITATIONS.
    """
    symbols = index["symbols"]
    resolve = _resolver(index)

    # reverse adjacency: definition index -> call edges arriving at it
    rev = {}
    for e in index["edges"]:
        if e["k"] not in CALL_KINDS:
            continue
        hit = resolve(e["f"], e["t"])
        ambiguous = len(hit) > 1
        for target in hit:
            rev.setdefault(target, []).append((e, ambiguous))

    def row(depth, e, via, ambiguous):
        if e["s"] >= 0:
            caller = symbols[e["s"]]
            return {
                "depth": depth, "name": caller["n"], "kind": caller["k"],
                "file": caller["f"], "span": [caller["a"], caller["b"]],
                "via": via, "at": "%s:%d" % (e["f"], e["l"]), "edge": e["k"],
                "ambiguous": ambiguous,
            }
        return {
            "depth": depth, "name": "(module)", "kind": "module",
            "file": e["f"], "span": [e["l"], e["l"]],
            "via": via, "at": "%s:%d" % (e["f"], e["l"]), "edge": e["k"],
            "ambiguous": ambiguous,
        }

    seed = _symbol_indices(index, name)
    if not seed:
        # Not defined in this repo (sourced elsewhere, or a name we only ever
        # see called). Report the direct known call sites and stop — there is
        # no definition to expand from, and guessing would be the false green
        # this tool exists to avoid.
        rows = [row(1, e, name, False) for e in index["edges"]
                if e["t"] == name and e["k"] in CALL_KINDS]
        rows.sort(key=lambda r: (r["depth"], r["file"], r["span"][0]))
        return rows

    seen = set(seed)
    frontier = list(seed)
    depth = 0
    rows = []
    while frontier:
        depth += 1
        nxt = []
        for target in frontier:
            via = symbols[target]["n"]
            for e, ambiguous in rev.get(target, []):
                rows.append(row(depth, e, via, ambiguous))
                if e["s"] >= 0 and e["s"] not in seen:
                    seen.add(e["s"])
                    nxt.append(e["s"])
        frontier = nxt
    rows.sort(key=lambda r: (r["depth"], r["file"], r["span"][0]))
    return rows


def q_outline(index, rel):
    rows = [s for s in index["symbols"] if s["f"] == rel]
    rows.sort(key=lambda s: (s["a"], s["b"]))
    return rows


def known_file(index, rel):
    return any(s["f"] == rel for s in index["symbols"])
