#!/usr/bin/env python3
# reuse_analyzer.py — the real engine behind `bin/heimdall-reuse-metric`.
#
# Computes the S-6 reuse metric for a task:
#
#   reuse_pct = units_reusing / units_total
#
# where a "code unit" is a CHANGED or ADDED named code unit (see GRANULARITY)
# and a unit "reuses" when its body CALLS, IMPORTS, or EXTENDS a symbol that
# already existed in the repo BEFORE the change. A unit "reinvents" when it does
# not reuse AND its name/shape closely matches a pre-existing symbol it does not
# call (that pre-existing symbol is then a `suspected_duplicate`).
#
# GRANULARITY (the precise definition, mirrored in REUSE-METRIC.md):
#   A code unit is a NAMED definition introduced or modified by the diff:
#     - JS/TS : function declarations, arrow/function consts assigned to a name,
#               class declarations, object methods, and React components
#               (a capitalized function/const returning JSX is still just a
#               named function unit — we do not special-case JSX).
#     - Python: `def` and `class` at any nesting depth (real `ast` parse).
#     - Shell : `name()` / `function name` definitions.
#   Anonymous/inline closures are NOT counted as their own units; they fold into
#   the enclosing named unit. A top-level script with no named units but with
#   added executable lines is counted as ONE synthetic "<module>" unit so a diff
#   that only adds top-level glue is still measured (never silently 0/0).
#
# REUSE signal (any one makes the unit "reusing"):
#   - imports a module/symbol that resolves to a pre-existing repo file/symbol,
#   - calls a function/method whose name is a pre-existing repo symbol,
#   - extends/instantiates a class/component that is a pre-existing repo symbol.
#
# REINVENTION signal (makes the unit "reinventing" + emits suspected_duplicate):
#   - the unit does NOT reuse, AND a pre-existing repo symbol has a name that is
#     identical or near-identical (normalized, or an edit-distance match) to the
#     new unit's name, AND the new unit never references that symbol.
#
# PRE-CHANGE SYMBOL TABLE:
#   Built from the repo AS IT WAS before the change. The caller passes the set of
#   pre-change source files (already materialized — typically `git show base:f`
#   into a temp tree, or the working tree minus the diff). This module never
#   shells out to git; it is a pure function of (changed_units, pre_symbols).
#
# This is a HEURISTIC analyzer (no full type resolution) but it is REAL: every
# number is computed from parsed source. Unsupported languages yield a null
# reuse_pct with an honest reason — never a fabricated percentage.

import ast
import json
import os
import re
import sys

# ── tree-sitter substrate (PRIMARY engine) ────────────────────────────────────
#
# The reuse metric's symbol/reference DETECTION can run on either of two engines:
#
#   • "treesitter" — the PRIMARY engine. Resolves each changed/added unit's
#     call/import/extend edges from a REAL AST (bin/lib/treesitter_ast.py), the
#     honest answer to "does this unit reference a pre-existing repo symbol?".
#   • "heuristic"  — the REQUIRED graceful fallback (the original `ast`/regex
#     engine below). Used when tree-sitter or a grammar is unavailable (the
#     stranger-test env ships no tree-sitter) so the analyzer NEVER crashes.
#
# The metric DEFINITION (reuse % = changed units that call/import/extend a
# pre-existing repo symbol ÷ total), the diff-scoping (test/fixture exclusion),
# and the JSON record fields are IDENTICAL across engines — only the symbol/
# reference detection differs. The chosen engine is recorded in the record's
# `"engine"` field so a reader knows which backend produced the numbers.
#
# tree-sitter is LAZY-imported via the substrate module (which itself lazy-imports
# the grammars). A failed import is recorded once and degrades to heuristic.

_TS_STATE = {"checked": False, "mod": None}


def _ts_module():
    """Lazy-load the tree-sitter substrate module (bin/lib/treesitter_ast.py),
    which lives alongside this file. Returns the module or None if it cannot be
    imported (degrade to heuristic, never crash)."""
    if _TS_STATE["checked"]:
        return _TS_STATE["mod"]
    _TS_STATE["checked"] = True
    try:
        here = os.path.dirname(os.path.abspath(__file__))
        if here not in sys.path:
            sys.path.insert(0, here)
        import treesitter_ast as ts  # noqa: WPS433 — lazy by design
        _TS_STATE["mod"] = ts
    except Exception:  # noqa: BLE001 — any import failure → heuristic fallback
        _TS_STATE["mod"] = None
    return _TS_STATE["mod"]


# Engine selection. "auto" (default) prefers tree-sitter when its backend +
# grammar are available for the file's language, else heuristic. An explicit
# "heuristic" forces the fallback (used to prove the contract holds on the
# stranger-test path); "treesitter" forces the AST engine (degrades per-file to
# heuristic only when that specific file's grammar is missing — never crashes).
_FORCE_ENGINE_ENV = "HEIMDALL_REUSE_ENGINE"


def resolve_engine(requested=None):
    """Resolve the engine name to use. Precedence: explicit `requested` arg →
    the HEIMDALL_REUSE_ENGINE env var → "auto". Returns one of
    "auto" | "treesitter" | "heuristic"."""
    val = (requested or os.environ.get(_FORCE_ENGINE_ENV) or "auto").strip().lower()
    if val not in ("auto", "treesitter", "heuristic"):
        val = "auto"
    return val


def _ts_lang_for(lang, path):
    """Map this analyzer's coarse language tag (js|py|sh) + path to a tree-sitter
    canonical language, or None if the substrate can't parse it (→ heuristic)."""
    ts = _ts_module()
    if ts is None:
        return None
    if lang == "py":
        return "python"
    if lang == "js":
        # distinguish ts/tsx via extension so the right grammar is used.
        return ts.lang_for_path(path) or "javascript"
    return None  # shell + anything else: no tree-sitter grammar → heuristic


def _ts_extract_units(src, lang, path):
    """Tree-sitter extraction producing the SAME (units, module_refs) shape the
    heuristic `extract_units` returns. Each Unit's `refs` are the call/import/
    extend edges whose AST line falls inside that unit's span; module-level
    imports become `module_refs` (credited to a unit only when its body also
    references the name — the same anti-inflation rule the heuristic applies).

    Returns (units, module_refs) on success, or None when tree-sitter/the grammar
    is unavailable for this file (caller falls back to the heuristic)."""
    ts = _ts_module()
    if ts is None:
        return None
    tslang = _ts_lang_for(lang, path)
    if tslang is None:
        return None
    res = ts.extract(src, tslang)
    if not res.available:
        return None  # backend/grammar missing for this file → heuristic fallback

    # Sort definitions by span start so attribution can pick the INNERMOST
    # enclosing unit for a nested def (smallest containing span wins).
    syms = sorted(res.symbols, key=lambda s: (s.span[0], -s.span[1]))
    spans = [(s.name, s.span[0], s.span[1]) for s in syms]

    def enclosing_unit_index(line):
        # the smallest span that contains `line`; -1 if none (module level).
        best = -1
        best_size = None
        for i, (_n, a, b) in enumerate(spans):
            if a <= line <= b:
                size = b - a
                if best_size is None or size < best_size:
                    best, best_size = i, size
        return best

    src_lines = src.splitlines()

    def _unit_body(a, b):
        # 1-based inclusive line span → the unit's source slice.
        return "\n".join(src_lines[a - 1:b])

    units = [Unit(name, lang, path, src) for (name, _a, _b) in spans]
    module_refs = set()       # names brought into module scope (imports)
    module_body_refs = set()  # call/extend refs at module level (top-level glue)

    # SUPPLEMENT: instantiation (`new X(...)`) and JSX-render (`<X .../>`) are real
    # reuse edges that the substrate's public reference API does not emit as
    # call/import/extend Refs (a `new_expression`/JSX element is neither). Recover
    # them per-unit from the unit's AST-bounded body slice so an endpoint that
    # instantiates a pre-existing model or renders a pre-existing component is
    # credited identically to one that calls a pre-existing function. This is the
    # one place the AST engine borrows the heuristic's `new`/JSX matcher to cover
    # an edge kind the substrate omits — symbol/call/import/extend resolution stays
    # tree-sitter. (Python has no analogue: instantiation there is a `call`, which
    # the substrate already emits.)
    if lang == "js":
        for i, (_n, a, b) in enumerate(spans):
            body = _unit_body(a, b)
            for m in _JS_NEW.finditer(body):
                units[i].refs.add(m.group(1).split(".")[-1])
                units[i].refs.add(m.group(1).split(".")[0])
            for m in _JS_JSX.finditer(body):
                units[i].refs.add(m.group(1).split(".")[0])

    for ref in res.references:
        idx = enclosing_unit_index(ref.line)
        if ref.kind == "import":
            # an import edge: the imported NAME is available module-wide.
            module_refs.add(ref.name)
            module_refs.add(ref.name.split(".")[-1])
            mod = ref.detail.get("module") if ref.detail else None
            if mod:
                base = os.path.basename(mod)
                module_refs.add(base)
                module_refs.add(os.path.splitext(base)[0])
            if idx >= 0:
                # an import physically inside a unit's span credits that unit
                # directly (it is in that unit's body).
                units[idx].refs.add(ref.name)
                units[idx].refs.add(ref.name.split(".")[-1])
            continue
        # call / extend edge: attribute to the enclosing unit, else module glue.
        nm = ref.name.split(".")[-1]
        if idx >= 0:
            units[idx].refs.add(nm)
        else:
            module_body_refs.add(nm)

    # Anti-inflation: a unit gets credit for a module-level import only when its
    # body actually references the imported name (mirrors the heuristic's
    # `_import_credit`). A sibling unit that never touches the import is not
    # crediting it.
    for u in units:
        u.refs |= (module_refs & u.refs)

    # Top-level glue (refs outside any unit). If there are NO named units but the
    # module has executable references, synthesize a module unit so a glue-only
    # diff is still measured (never silently 0/0) — same as the heuristic.
    if not units and (module_body_refs or module_refs):
        mu = Unit("<module:%s>" % os.path.basename(path), lang, path, src)
        mu.refs |= module_body_refs
        mu.refs |= (module_refs & module_body_refs)
        units = [mu]

    return units, module_refs

# ── language detection ────────────────────────────────────────────────────────

JS_TS_EXT = {".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx"}
PY_EXT = {".py"}
SH_EXT = {".sh", ".bash"}


def detect_language(path):
    ext = os.path.splitext(path)[1].lower()
    if ext in JS_TS_EXT:
        return "js"
    if ext in PY_EXT:
        return "py"
    if ext in SH_EXT:
        return "sh"
    # extensionless files: sniff a shebang
    base = os.path.basename(path)
    if "." not in base:
        return "sh_maybe"
    return None


# ── test / fixture scoping ──────────────────────────────────────────────────
#
# Reuse is a measurement over PRODUCTION code units in the task diff: do the new
# production units build on pre-existing PRODUCTION repo code, or reinvent it?
# A repo's own test files and fixtures are NOT "pre-existing repo code" that a
# task's production units should be credited for reusing — a generic fixture name
# (`dataset`, `check_id`, a `Cheese` test class) that happens to collide with a
# call in the changed code is a false reuse signal. So:
#   - test-file symbols are EXCLUDED from the pre-existing symbol table, and
#   - test files are EXCLUDED from the changed-unit set — UNLESS the task is
#     itself a test task (every changed file is a test), in which case the test
#     units ARE the units to measure (a test that calls an existing helper is
#     legitimately reusing it).
# This is purely a SCOPE fix: the heuristic extraction engine is unchanged.

_TEST_DIR_SEG = re.compile(
    r"(^|/)(tests?|__tests__|spec|specs|fixtures?|testdata|conformance|e2e)(/|$)"
)
_TEST_FILE_NAME = re.compile(
    r"^(test[_\-].*|.*[_\-]test|.*\.test|.*\.spec|.*\.fixture|conftest|test-.*)$"
)


def is_test_path(path):
    """True if `path` is a test / spec / fixture source file. Matches on a
    directory segment (a `tests/`, `__tests__/`, `spec/`, `fixtures/`,
    `conformance/`, `e2e/` component) OR the file's stem (`test_*`, `*_test`,
    `*.test.*`, `*.spec.*`, `*.fixture.*`, `test-*`, `conftest`)."""
    norm = path.replace("\\", "/")
    if _TEST_DIR_SEG.search(norm):
        return True
    base = os.path.basename(norm).lower()
    # match against the full basename (catches compound suffixes like
    # foo.test.js / bar.spec.ts / baz.fixture.sh) and the single-extension stem
    # (catches test_records.py -> test_records, conftest.py -> conftest).
    stem = os.path.splitext(base)[0]
    return bool(_TEST_FILE_NAME.match(base) or _TEST_FILE_NAME.match(stem))


# ── data model ────────────────────────────────────────────────────────────────


class Unit:
    """A named code unit introduced/modified by the diff."""

    __slots__ = ("name", "lang", "file", "body", "refs")

    def __init__(self, name, lang, file, body):
        self.name = name
        self.lang = lang
        self.file = file
        self.body = body
        self.refs = set()  # symbol names this unit references (calls/imports/extends)


# ── Python extraction (real AST) ──────────────────────────────────────────────


def _py_collect_refs(node):
    refs = set()
    for child in ast.walk(node):
        if isinstance(child, ast.Call):
            f = child.func
            if isinstance(f, ast.Name):
                refs.add(f.id)
            elif isinstance(f, ast.Attribute):
                refs.add(f.attr)
        elif isinstance(child, ast.Attribute):
            refs.add(child.attr)
        elif isinstance(child, ast.Name):
            refs.add(child.id)
        elif isinstance(child, ast.Import):
            for n in child.names:
                refs.add((n.asname or n.name).split(".")[0])
                refs.add(n.name.split(".")[-1])
        elif isinstance(child, ast.ImportFrom):
            if child.module:
                refs.add(child.module.split(".")[-1])
            for n in child.names:
                refs.add(n.asname or n.name)
    return refs


def extract_py_units(src, path):
    """Return (units, module_imports). Real ast parse; on SyntaxError, [] + falls
    back to regex via the caller, signalled by returning None."""
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return None, None
    units = []

    # base-class names for extends detection are captured into the unit refs.
    def visit(node):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                u = Unit(child.name, "py", path, src)
                u.refs |= _py_collect_refs(child)
                units.append(u)
                visit(child)  # nested defs are their own units too
            elif isinstance(child, ast.ClassDef):
                u = Unit(child.name, "py", path, src)
                u.refs |= _py_collect_refs(child)
                # base classes => extends
                for b in child.bases:
                    if isinstance(b, ast.Name):
                        u.refs.add(b.id)
                    elif isinstance(b, ast.Attribute):
                        u.refs.add(b.attr)
                units.append(u)
                visit(child)
            else:
                visit(child)

    visit(tree)
    module_refs = _py_collect_refs(tree)
    return units, module_refs


# ── JS/TS extraction (regex heuristic) ────────────────────────────────────────

# named function decl, named const arrow/function, class decl, object method.
_JS_FUNC_DECL = re.compile(
    r"\b(?:export\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)\s*\(", re.M
)
_JS_CONST_FN = re.compile(
    r"\b(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?"
    r"(?:function\b|\([^)]*\)\s*=>|[A-Za-z_$][\w$]*\s*=>)",
    re.M,
)
_JS_CLASS = re.compile(
    r"\b(?:export\s+(?:default\s+)?)?class\s+([A-Za-z_$][\w$]*)"
    r"(?:\s+extends\s+([A-Za-z_$][\w$.]*))?",
    re.M,
)
_JS_CALL = re.compile(r"\b([A-Za-z_$][\w$]*)\s*\(")
_JS_NEW = re.compile(r"\bnew\s+([A-Za-z_$][\w$.]*)")
_JS_IMPORT_FROM = re.compile(r"""\bfrom\s+['"]([^'"]+)['"]""")
_JS_IMPORT_NAMES = re.compile(r"\bimport\s+(?:\*\s+as\s+([\w$]+)|([\w$]+)|\{([^}]*)\})")
_JS_REQUIRE = re.compile(r"""\brequire\s*\(\s*['"]([^'"]+)['"]\s*\)""")
_JS_JSX = re.compile(r"<\s*([A-Z][\w$.]*)")


def _js_body_refs(body):
    refs = set()
    for m in _JS_CALL.finditer(body):
        refs.add(m.group(1))
    for m in _JS_NEW.finditer(body):
        refs.add(m.group(1).split(".")[-1])
        refs.add(m.group(1).split(".")[0])
    for m in _JS_JSX.finditer(body):
        refs.add(m.group(1).split(".")[0])
    return refs


def _js_slice_body(src, start):
    """From an opening position, return source up to the matching close brace,
    or to end-of-statement for arrow one-liners."""
    brace = src.find("{", start)
    semi = src.find(";", start)
    nl = src.find("\n", start)
    # arrow one-liner with no brace before the newline/semicolon
    if brace == -1 or (semi != -1 and semi < brace) or (nl != -1 and nl < brace and brace > nl + 200):
        end = semi if semi != -1 else (nl if nl != -1 else len(src))
        return src[start:end]
    depth = 0
    i = brace
    while i < len(src):
        c = src[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[start : i + 1]
        i += 1
    return src[start:]


def extract_js_units(src, path):
    units = []
    seen = set()
    # module-level imports become refs available to all units in this file
    module_import_refs = set()
    for m in _JS_IMPORT_FROM.finditer(src):
        module_import_refs.add(os.path.basename(m.group(1)))
        module_import_refs.add(os.path.splitext(os.path.basename(m.group(1)))[0])
    for m in _JS_IMPORT_NAMES.finditer(src):
        star, dflt, named = m.group(1), m.group(2), m.group(3)
        if star:
            module_import_refs.add(star)
        if dflt:
            module_import_refs.add(dflt)
        if named:
            for part in named.split(","):
                nm = part.strip().split(" as ")[-1].strip()
                if nm:
                    module_import_refs.add(nm)
    for m in _JS_REQUIRE.finditer(src):
        module_import_refs.add(os.path.basename(m.group(1)))
        module_import_refs.add(os.path.splitext(os.path.basename(m.group(1)))[0])

    def _import_credit(body_refs):
        # A unit only gets reuse credit for an import if its BODY actually
        # references the imported name (calls it, JSX-renders it, instantiates
        # it). Blanket-crediting every unit in the file for a top-of-file import
        # would inflate reuse (a sibling function that never touches the import
        # is not reusing it). The module basenames are not credited at unit level.
        return module_import_refs & body_refs

    def add(name, start):
        if name in seen:
            return
        seen.add(name)
        body = _js_slice_body(src, start)
        u = Unit(name, "js", path, body)
        brefs = _js_body_refs(body)
        u.refs |= brefs
        u.refs |= _import_credit(brefs)
        units.append(u)

    for m in _JS_FUNC_DECL.finditer(src):
        add(m.group(1), m.end())
    for m in _JS_CONST_FN.finditer(src):
        add(m.group(1), m.end())
    for m in _JS_CLASS.finditer(src):
        u_start = m.end()
        name = m.group(1)
        if name not in seen:
            seen.add(name)
            body = _js_slice_body(src, u_start)
            u = Unit(name, "js", path, body)
            brefs = _js_body_refs(body)
            u.refs |= brefs
            u.refs |= _import_credit(brefs)
            if m.group(2):  # extends Parent
                u.refs.add(m.group(2).split(".")[-1])
                u.refs.add(m.group(2).split(".")[0])
            units.append(u)
    return units, module_import_refs


# ── Shell extraction ──────────────────────────────────────────────────────────

_SH_FUNC = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\s*\)\s*\{?", re.M)
_SH_FUNC2 = re.compile(r"^\s*function\s+([A-Za-z_][\w-]*)\s*\{?", re.M)
_SH_CALL = re.compile(r"[\s;&|(]([A-Za-z_][\w-]*)\b")
_SH_SOURCE = re.compile(r"^\s*(?:\.|source)\s+(\S+)", re.M)


def _sh_slice_body(src, start):
    brace = src.find("{", start)
    if brace == -1:
        nl = src.find("\n", start)
        return src[start : nl if nl != -1 else len(src)]
    depth = 0
    i = brace
    while i < len(src):
        c = src[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[start : i + 1]
        i += 1
    return src[start:]


def extract_sh_units(src, path):
    units = []
    seen = set()
    source_refs = set()
    for m in _SH_SOURCE.finditer(src):
        source_refs.add(os.path.basename(m.group(1)))
        source_refs.add(os.path.splitext(os.path.basename(m.group(1)))[0])

    def add(name, start):
        if name in seen:
            return
        seen.add(name)
        body = _sh_slice_body(src, start)
        u = Unit(name, "sh", path, body)
        brefs = set()
        for cm in _SH_CALL.finditer(body):
            brefs.add(cm.group(1))
        u.refs |= brefs
        # sourcing a pre-existing file only credits a unit whose body actually
        # invokes a name that the source makes available (same anti-inflation
        # rule as JS imports).
        u.refs |= (source_refs & brefs)
        units.append(u)

    for m in _SH_FUNC.finditer(src):
        add(m.group(1), m.start())
    for m in _SH_FUNC2.finditer(src):
        add(m.group(1), m.start())
    return units, source_refs


# ── JS/TS regex fallback for Python parse failures is not applicable; instead a
#    generic line-token extractor backs unsupported-but-textual content so a file
#    is never silently dropped — but it is only used for the synthetic module
#    unit when no named units are found in a SUPPORTED language. ────────────────


def extract_units_heuristic(src, lang, path):
    """The HEURISTIC engine (stdlib `ast` for Python, regex for JS/shell). This is
    the REQUIRED graceful fallback that always works with zero extra deps."""
    if lang == "py":
        units, module_refs = extract_py_units(src, path)
        if units is None:  # SyntaxError -> cannot AST-parse
            return None, None
        return units, module_refs
    if lang == "js":
        return extract_js_units(src, path)
    if lang in ("sh", "sh_maybe"):
        return extract_sh_units(src, path)
    return None, None


def extract_units(src, lang, path, engine="auto"):
    """Engine-aware unit extraction. Returns (units, module_refs, engine_used).

    `engine` is one of "auto" | "treesitter" | "heuristic":
      - "treesitter" / "auto": try the tree-sitter substrate first; if it cannot
        parse this file's language (no backend, missing grammar, or a non-AST
        language like shell), fall back to the heuristic — never crash.
      - "heuristic": force the original stdlib-ast/regex engine.

    The returned `engine_used` is the engine that actually produced the units
    ("treesitter" or "heuristic"), so the record reports it honestly even when a
    per-file fallback happened under "auto"/"treesitter"."""
    if engine in ("auto", "treesitter"):
        ts_result = _ts_extract_units(src, lang, path)
        if ts_result is not None:
            units, module_refs = ts_result
            return units, module_refs, "treesitter"
        # forced/auto tree-sitter but this file isn't AST-parseable (e.g. shell,
        # or grammar missing): fall back to the heuristic for THIS file. The
        # overall run still reports treesitter if another file used it.
    units, module_refs = extract_units_heuristic(src, lang, path)
    return units, module_refs, "heuristic"


# ── reuse / reinvention classification ────────────────────────────────────────


def _normalize(name):
    return re.sub(r"[_\-]", "", name).lower()


def _near(a, b):
    """True if two symbol names are identical-or-near (normalized equality, or a
    small Levenshtein distance on names ≥4 chars). Used for duplicate detection."""
    na, nb = _normalize(a), _normalize(b)
    if na == nb:
        return True
    if len(na) < 4 or len(nb) < 4:
        return False
    # bounded Levenshtein (distance ≤ 2 and ≤ 25% of the longer name)
    if abs(len(na) - len(nb)) > 2:
        return False
    prev = list(range(len(nb) + 1))
    for i, ca in enumerate(na, 1):
        cur = [i]
        for j, cb in enumerate(nb, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    dist = prev[-1]
    return dist <= 2 and dist <= max(len(na), len(nb)) * 0.25


def classify(units, pre_symbols, self_names):
    """units: changed/added Unit list. pre_symbols: set of symbol names that
    existed BEFORE the change. self_names: names defined in the changeset itself
    (so a unit calling a sibling-new unit is not miscounted as reuse).

    Returns (units_reusing, units_reinventing, reused_symbols, suspected_dups)."""
    reused_symbols = {}
    suspected = []
    reusing = 0
    reinventing = 0

    for u in units:
        # which pre-existing symbols does this unit reference? (exclude refs that
        # resolve to a sibling new unit — those are intra-changeset, not reuse of
        # pre-existing repo code, EXCEPT the unit's own name.)
        hits = sorted(
            s
            for s in u.refs
            if s in pre_symbols and s != u.name
        )
        if hits:
            reusing += 1
            for s in hits:
                reused_symbols.setdefault(s, 0)
                reused_symbols[s] += 1
            continue
        # no reuse: is this a reinvention of a pre-existing capability?
        dup = None
        for pre in pre_symbols:
            if pre == u.name and pre not in self_names_minus(self_names, u.name):
                # exact name match of a pre-existing symbol that this unit does
                # NOT call => re-defining/duplicating it.
                dup = pre
                break
        if dup is None:
            for pre in pre_symbols:
                if _near(pre, u.name) and pre not in u.refs:
                    dup = pre
                    break
        if dup is not None:
            reinventing += 1
            suspected.append({"new_unit": u.name, "duplicates": dup, "file": u.file})
        # else: neither reuse nor reinvention (genuinely novel code) — counts in
        # the denominator but in neither reusing nor reinventing.

    reused_list = [
        {"symbol": s, "call_sites": c}
        for s, c in sorted(reused_symbols.items(), key=lambda kv: (-kv[1], kv[0]))
    ]
    return reusing, reinventing, reused_list, suspected


def self_names_minus(self_names, keep):
    # helper so a unit's own redefinition still registers as a duplicate even
    # though the name is in self_names.
    return self_names - {keep}


# ── public entry: compute the record from changed files + a pre-symbol table ──


def build_pre_symbols(pre_files, engine="auto"):
    """pre_files: dict {path: source} of repo files BEFORE the change.
    Returns the set of pre-existing symbol names (function/class/component +
    module basenames, so an import of a pre-existing file resolves).

    The same `engine` (tree-sitter primary / heuristic fallback) extracts the
    pre-existing symbol table so BOTH sides of the comparison are detected by the
    same backend.

    Test / fixture files are EXCLUDED: their symbols (test classes, fixture
    helpers like `dataset` / `check_id`) are not pre-existing PRODUCTION repo
    code, so crediting a changed unit for "reusing" a fixture name it merely
    collides with is a false signal (S-6 C3 Defect 3)."""
    syms = set()
    for path, src in pre_files.items():
        if is_test_path(path):
            continue
        lang = detect_language(path)
        if lang is None:
            continue
        units, _, _used = extract_units(src, lang, path, engine)
        if units:
            for u in units:
                syms.add(u.name)
        # the file itself is an importable module
        base = os.path.basename(path)
        syms.add(base)
        syms.add(os.path.splitext(base)[0])
    return syms


def analyze(task, changed_files, pre_symbols, engine="auto"):
    """changed_files: dict {path: source} of the CHANGED/ADDED side of the diff.
    pre_symbols: set from build_pre_symbols. `engine` selects the symbol/reference
    detection backend ("auto" | "treesitter" | "heuristic"). Returns the record
    dict, including an `"engine"` field naming the backend that produced it."""
    all_units = []
    self_names = set()
    langs_seen = set()
    unsupported = []
    engines_used = set()

    # Scope the changed-unit set to PRODUCTION units in the diff. Test/fixture
    # files in the diff are excluded so a production task is not measured over the
    # repo's existing tests (S-6 C3 Defect 3) — EXCEPT when the task is ITSELF a
    # test task: if every changed source file is a test, the test units ARE the
    # units to measure (a test that calls an existing helper legitimately reuses
    # it). We decide that over the changed SOURCE files only (non-source files like
    # data/config never carry units and must not flip the all-tests verdict).
    src_changed = [
        p for p in changed_files if detect_language(p) is not None
    ]
    task_is_all_tests = bool(src_changed) and all(
        is_test_path(p) for p in src_changed
    )

    for path, src in changed_files.items():
        if not task_is_all_tests and is_test_path(path):
            # a test file changed alongside production code — not a production
            # unit to measure for reuse. Skip it (do not flag as unsupported).
            continue
        lang = detect_language(path)
        if lang is None:
            unsupported.append(path)
            continue
        units, mod_refs, used = extract_units(src, lang, path, engine)
        if units is None:
            # could not parse a supported language (e.g. py syntax error) — honest
            unsupported.append(path)
            continue
        engines_used.add(used)
        langs_seen.add("py" if lang == "py" else "js" if lang == "js" else "sh")
        if not units and src.strip():
            # supported language, no named units, but non-empty: one module unit
            u = Unit("<module:%s>" % os.path.basename(path), lang, path, src)
            if lang == "py":
                u.refs |= (mod_refs or set())
            elif lang == "js":
                u.refs |= _js_body_refs(src)
            else:
                for cm in _SH_CALL.finditer(src):
                    u.refs.add(cm.group(1))
            units = [u]
        for u in units:
            self_names.add(u.name)
        all_units.extend(units)

    units_total = len(all_units)

    # The engine that produced the analyzed units. If any unit came from
    # tree-sitter, report "treesitter" (the run used the AST substrate); only if
    # every file fell back do we report "heuristic". When nothing was analyzable,
    # report the requested engine resolution honestly.
    if engines_used == {"treesitter"} or "treesitter" in engines_used:
        engine_used = "treesitter"
    elif engines_used:
        engine_used = "heuristic"
    else:
        req = resolve_engine(engine)
        engine_used = "heuristic" if req == "heuristic" else (
            "treesitter" if _ts_module() is not None
            and getattr(_ts_module(), "backend_available", lambda: False)()
            else "heuristic"
        )

    if units_total == 0:
        # nothing analyzable. If we saw only unsupported files, be honest.
        record = {
            "task": task,
            "units_total": 0,
            "units_reusing": 0,
            "units_reinventing": 0,
            "reuse_pct": None,
            "reused_symbols": [],
            "suspected_duplicates": [],
            "engine": engine_used,
        }
        if unsupported:
            record["reason"] = "unsupported-language"
            record["unsupported_files"] = unsupported
        else:
            record["reason"] = "no-code-units-in-diff"
        return record

    reusing, reinventing, reused_list, suspected = classify(
        all_units, pre_symbols, self_names
    )
    record = {
        "task": task,
        "units_total": units_total,
        "units_reusing": reusing,
        "units_reinventing": reinventing,
        "reuse_pct": round(reusing / units_total, 4),
        "reused_symbols": reused_list,
        "suspected_duplicates": suspected,
        "languages": sorted(langs_seen),
        "engine": engine_used,
    }
    if unsupported:
        record["unsupported_files"] = unsupported
    return record


def human_summary(record):
    if record.get("reuse_pct") is None:
        return "reuse: n/a (%s) — task=%r, %d unit(s)" % (
            record.get("reason", "unknown"),
            record["task"],
            record["units_total"],
        )
    pct = record["reuse_pct"] * 100
    dups = len(record["suspected_duplicates"])
    return (
        "reuse: %.0f%% (%d/%d units reuse pre-existing repo code; "
        "%d reinventing; %d suspected duplicate%s) [engine=%s] — task=%r"
        % (
            pct,
            record["units_reusing"],
            record["units_total"],
            record["units_reinventing"],
            dups,
            "" if dups == 1 else "s",
            record.get("engine", "?"),
            record["task"],
        )
    )


# ── CLI: read a JSON job on stdin or argv, emit record JSON on stdout ──────────
#
# Job schema (stdin JSON):
#   { "task": str,
#     "engine": "auto"|"treesitter"|"heuristic",  # optional; default auto/env
#     "pre_files":     { path: source, ... },   # repo before the change
#     "changed_files": { path: source, ... } }  # added/changed side of the diff
#
# Emits the record JSON to stdout. The one-line human summary goes to stderr so
# callers can capture pure JSON on stdout. The engine may also be forced via the
# HEIMDALL_REUSE_ENGINE env var (the job field takes precedence when present).


def main(argv):
    raw = sys.stdin.read()
    job = json.loads(raw)
    task = job.get("task", "")
    pre_files = job.get("pre_files", {})
    changed_files = job.get("changed_files", {})
    engine = resolve_engine(job.get("engine"))
    pre_symbols = build_pre_symbols(pre_files, engine)
    record = analyze(task, changed_files, pre_symbols, engine)
    sys.stdout.write(json.dumps(record, indent=2) + "\n")
    sys.stderr.write(human_summary(record) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
