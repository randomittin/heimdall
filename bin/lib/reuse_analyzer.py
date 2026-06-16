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


def extract_units(src, lang, path):
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


def build_pre_symbols(pre_files):
    """pre_files: dict {path: source} of repo files BEFORE the change.
    Returns the set of pre-existing symbol names (function/class/component +
    module basenames, so an import of a pre-existing file resolves)."""
    syms = set()
    for path, src in pre_files.items():
        lang = detect_language(path)
        if lang is None:
            continue
        units, _ = extract_units(src, lang, path)
        if units:
            for u in units:
                syms.add(u.name)
        # the file itself is an importable module
        base = os.path.basename(path)
        syms.add(base)
        syms.add(os.path.splitext(base)[0])
    return syms


def analyze(task, changed_files, pre_symbols):
    """changed_files: dict {path: source} of the CHANGED/ADDED side of the diff.
    pre_symbols: set from build_pre_symbols. Returns the record dict."""
    all_units = []
    self_names = set()
    langs_seen = set()
    unsupported = []

    for path, src in changed_files.items():
        lang = detect_language(path)
        if lang is None:
            unsupported.append(path)
            continue
        units, _ = extract_units(src, lang, path)
        if units is None:
            # could not parse a supported language (e.g. py syntax error) — honest
            unsupported.append(path)
            continue
        langs_seen.add("py" if lang == "py" else "js" if lang == "js" else "sh")
        if not units and src.strip():
            # supported language, no named units, but non-empty: one module unit
            u = Unit("<module:%s>" % os.path.basename(path), lang, path, src)
            if lang == "py":
                u.refs |= (extract_units(src, lang, path)[1] or set())
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
        "%d reinventing; %d suspected duplicate%s) — task=%r"
        % (
            pct,
            record["units_reusing"],
            record["units_total"],
            record["units_reinventing"],
            dups,
            "" if dups == 1 else "s",
            record["task"],
        )
    )


# ── CLI: read a JSON job on stdin or argv, emit record JSON on stdout ──────────
#
# Job schema (stdin JSON):
#   { "task": str,
#     "pre_files":     { path: source, ... },   # repo before the change
#     "changed_files": { path: source, ... } }  # added/changed side of the diff
#
# Emits the record JSON to stdout. The one-line human summary goes to stderr so
# callers can capture pure JSON on stdout.


def main(argv):
    raw = sys.stdin.read()
    job = json.loads(raw)
    task = job.get("task", "")
    pre_files = job.get("pre_files", {})
    changed_files = job.get("changed_files", {})
    pre_symbols = build_pre_symbols(pre_files)
    record = analyze(task, changed_files, pre_symbols)
    sys.stdout.write(json.dumps(record, indent=2) + "\n")
    sys.stderr.write(human_summary(record) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
