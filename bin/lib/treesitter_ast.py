#!/usr/bin/env python3
# treesitter_ast.py — the deterministic AST substrate for Heimdall.
#
# This is the SHARED foundation called for by ★2 of the deterministic-tooling
# spec: real tree-sitter parsing of the C3 stacks (JS / TS / TSX / Python / Go /
# Rust) that extracts the STRUCTURAL SURFACE of a source file:
#
#   • SYMBOLS    — the definitions: functions, methods, classes, structs,
#                  interfaces, enums, React components. (extract_symbols)
#   • REFERENCES — the edges between them: call / import / extend. A changed unit
#                  "calls X", "imports Y", "extends Z". (extract_references)
#
# WHY this exists (and is not regex): Heimdall's reuse metric (SI-2 / S-6), its
# comprehension capsule (SI-1), and designmatch's behavioral diff all need to
# answer structural questions — "does this changed unit call/import/extend a
# pre-existing repo symbol?" — and the honest answer is an AST query, not a
# string match. A regex cannot tell a call from a same-named string literal, a
# real `extends` from the word in a comment, or an imported name from a local
# shadow. tree-sitter can. This module is the one place that knowledge lives so
# the consumers (SI-2 Wave 2, designmatch, F3 Redum) reuse it instead of each
# re-implementing a flaky parser.
#
# GRACEFUL DEGRADATION (the Heimdall pattern, mandatory):
#   tree_sitter + the language grammars are OPTIONAL dependencies. They are
#   LAZY-imported, so this module imports cleanly on a stripped host (the
#   stranger-test env) with no tree-sitter installed. When the backend or a
#   grammar is unavailable, the public API returns an honest "unavailable"
#   result (empty symbols/refs + a reason) instead of crashing. A caller can
#   always call extract_symbols / extract_references and never see a traceback
#   merely because a grammar is missing.
#
# INSTALL (documented for the consumer):
#   python3 -m pip install tree-sitter tree-sitter-languages
#   `tree-sitter-languages` bundles prebuilt grammars for all C3 stacks and is
#   the preferred path (one wheel, no per-language build). If it will not
#   install on a host, the per-language wheels also work and are tried as a
#   fallback automatically:
#     python3 -m pip install tree-sitter \
#         tree-sitter-python tree-sitter-javascript tree-sitter-typescript \
#         tree-sitter-go tree-sitter-rust
#
# This file is a LIBRARY. The thin CLI is bin/heimdall-ast.

from __future__ import annotations

import json
import os

# ── language identity ─────────────────────────────────────────────────────────
#
# The canonical language ids this substrate speaks, plus the file-extension map
# the CLI uses to auto-detect. "tsx" is distinct from "ts" because the TypeScript
# grammar ships two separate parsers (tsx allows JSX, ts does not) and using the
# wrong one mis-parses JSX-bearing files.

LANGS = ("javascript", "typescript", "tsx", "python", "go", "rust")

# Aliases a caller may pass for convenience → canonical id.
_LANG_ALIASES = {
    "js": "javascript",
    "jsx": "javascript",  # the javascript grammar parses JSX natively
    "javascript": "javascript",
    "ts": "typescript",
    "typescript": "typescript",
    "tsx": "tsx",
    "py": "python",
    "python": "python",
    "go": "go",
    "golang": "go",
    "rs": "rust",
    "rust": "rust",
}

# File extension → canonical language id (for the CLI's auto-detect).
_EXT_LANG = {
    ".js": "javascript",
    ".jsx": "javascript",
    ".mjs": "javascript",
    ".cjs": "javascript",
    ".ts": "typescript",
    ".tsx": "tsx",
    ".py": "python",
    ".pyi": "python",
    ".go": "go",
    ".rs": "rust",
}


def normalize_lang(lang):
    """Map a caller-supplied language name/alias to a canonical id, or None if it
    is not one of the supported C3 stacks."""
    if not lang:
        return None
    return _LANG_ALIASES.get(str(lang).strip().lower())


def lang_for_path(path):
    """Infer the canonical language id from a file path's extension, or None."""
    _, ext = os.path.splitext(str(path))
    return _EXT_LANG.get(ext.lower())


# ── lazy backend loader (the degradation seam) ────────────────────────────────
#
# Nothing here imports tree_sitter at module load. The first call that needs a
# parser triggers the import; if it fails, we remember the reason and every
# subsequent call degrades cheaply without re-trying the import.

_BACKEND_STATE = {
    "checked": False,
    "available": False,
    "reason": "",
    "get_parser": None,   # callable(canonical_lang) -> tree_sitter.Parser
    "source": "",         # which provider satisfied the import
}

# A cache of built parsers per canonical language so we parse-build once.
_PARSER_CACHE = {}


def _try_languages_bundle():
    """Provider A: tree-sitter-languages (one wheel, all grammars). Returns a
    get_parser(canonical_lang)->Parser callable or raises."""
    from tree_sitter_languages import get_parser as _bundle_get_parser

    # The bundle keys tsx/typescript under those exact names.
    _bundle_names = {
        "javascript": "javascript",
        "typescript": "typescript",
        "tsx": "tsx",
        "python": "python",
        "go": "go",
        "rust": "rust",
    }

    def get_parser(canonical):
        name = _bundle_names.get(canonical)
        if name is None:
            raise KeyError("unsupported language %r" % canonical)
        return _bundle_get_parser(name)

    # Probe one grammar so a broken bundle fails here (degrade) not mid-parse.
    get_parser("python")
    return get_parser


def _try_per_language_wheels():
    """Provider B: per-language tree_sitter_{python,javascript,typescript,go,rust}
    wheels + the core tree_sitter.Parser. Returns a get_parser callable or
    raises. Handles both the modern (Language(capsule)) and the legacy
    (Language(capsule, name)) tree_sitter constructor signatures."""
    from tree_sitter import Language, Parser

    def _mk_language(capsule):
        # tree_sitter >= 0.22 takes one arg; older builds took (capsule, name).
        try:
            return Language(capsule)
        except TypeError:
            return Language(capsule, "lang")

    # Map canonical id -> (module name, attribute that yields the grammar capsule).
    # typescript and tsx both live in tree_sitter_typescript under two funcs.
    def _load(canonical):
        if canonical == "javascript":
            import tree_sitter_javascript as m
            return _mk_language(m.language())
        if canonical == "typescript":
            import tree_sitter_typescript as m
            return _mk_language(m.language_typescript())
        if canonical == "tsx":
            import tree_sitter_typescript as m
            return _mk_language(m.language_tsx())
        if canonical == "python":
            import tree_sitter_python as m
            return _mk_language(m.language())
        if canonical == "go":
            import tree_sitter_go as m
            return _mk_language(m.language())
        if canonical == "rust":
            import tree_sitter_rust as m
            return _mk_language(m.language())
        raise KeyError("unsupported language %r" % canonical)

    _lang_objs = {}

    def get_parser(canonical):
        lang = _lang_objs.get(canonical)
        if lang is None:
            lang = _load(canonical)
            _lang_objs[canonical] = lang
        parser = Parser()
        # tree_sitter >= 0.22 exposes .language as a settable property; older
        # builds use .set_language(). Support both.
        try:
            parser.language = lang
        except (AttributeError, TypeError):
            parser.set_language(lang)
        return parser

    get_parser("python")  # probe
    return get_parser


def _ensure_backend():
    """Resolve the tree-sitter backend once. Sets _BACKEND_STATE. Never raises:
    a failed import is recorded as unavailable + a human reason."""
    if _BACKEND_STATE["checked"]:
        return _BACKEND_STATE["available"]
    _BACKEND_STATE["checked"] = True

    # Try the bundle first (cleanest install), then per-language wheels.
    for source, loader in (
        ("tree-sitter-languages", _try_languages_bundle),
        ("per-language-grammars", _try_per_language_wheels),
    ):
        try:
            get_parser = loader()
        except Exception as exc:  # noqa: BLE001 — any failure → try next / degrade
            last_reason = "%s: %s" % (source, exc)
            _BACKEND_STATE["reason"] = last_reason
            continue
        _BACKEND_STATE["available"] = True
        _BACKEND_STATE["get_parser"] = get_parser
        _BACKEND_STATE["source"] = source
        _BACKEND_STATE["reason"] = ""
        return True

    if not _BACKEND_STATE["reason"]:
        _BACKEND_STATE["reason"] = (
            "tree-sitter not installed "
            "(pip install tree-sitter tree-sitter-languages)"
        )
    return False


def backend_available():
    """True iff tree-sitter + at least one grammar provider imported cleanly."""
    return _ensure_backend()


def backend_info():
    """A small dict describing the backend resolution — for diagnostics / CLI."""
    _ensure_backend()
    return {
        "available": _BACKEND_STATE["available"],
        "source": _BACKEND_STATE["source"],
        "reason": _BACKEND_STATE["reason"],
        "languages": list(LANGS),
    }


def _get_parser(canonical):
    """Return a built parser for a canonical language, or raise GrammarUnavailable
    if the backend or that specific grammar is missing."""
    if not _ensure_backend():
        raise GrammarUnavailable(_BACKEND_STATE["reason"])
    cached = _PARSER_CACHE.get(canonical)
    if cached is not None:
        return cached
    try:
        parser = _BACKEND_STATE["get_parser"](canonical)
    except Exception as exc:  # noqa: BLE001 — a missing single grammar → degrade
        raise GrammarUnavailable(
            "grammar for %r unavailable via %s: %s"
            % (canonical, _BACKEND_STATE["source"], exc)
        )
    _PARSER_CACHE[canonical] = parser
    return parser


class GrammarUnavailable(Exception):
    """Raised internally when tree-sitter or a specific grammar is missing. The
    public API catches this and returns an unavailable result rather than letting
    it escape — degradation must never crash the caller."""


# ── result value types ────────────────────────────────────────────────────────


class Symbol:
    """A definition extracted from source.

      name   — the declared identifier (e.g. "CheckoutScreen", "redeemCoupon").
      kind   — one of: function | method | class | struct | interface | enum |
               component | type | const. Stable across languages so a consumer
               keys on `kind` without language branching.
      span   — (start_line, end_line) 1-based inclusive, for slicing the unit.
      lang   — the canonical language id it was parsed as.
      detail — small structured extras (receiver, parent class, params count …).
    """

    __slots__ = ("name", "kind", "span", "lang", "detail")

    def __init__(self, name, kind, span, lang, detail=None):
        self.name = name
        self.kind = kind
        self.span = tuple(span)
        self.lang = lang
        self.detail = detail or {}

    def to_dict(self):
        return {
            "name": self.name,
            "kind": self.kind,
            "span": list(self.span),
            "lang": self.lang,
            "detail": self.detail,
        }

    def __repr__(self):
        return "Symbol(%s %s @%s-%s)" % (
            self.kind, self.name, self.span[0], self.span[1],
        )


class Ref:
    """An edge from the parsed unit out to another symbol.

      name — the referenced identifier (callee, imported name, or base class).
      kind — call | import | extend.
      line — 1-based line the reference appears on.
      lang — the canonical language id.
      detail — extras: for `import` the module specifier; for `call` the receiver
               (e.g. "navigation" in navigation.navigate); for `extend` whether
               it is a class extends vs an interface implements.
    """

    __slots__ = ("name", "kind", "line", "lang", "detail")

    def __init__(self, name, kind, line, lang, detail=None):
        self.name = name
        self.kind = kind
        self.line = line
        self.lang = lang
        self.detail = detail or {}

    def to_dict(self):
        return {
            "name": self.name,
            "kind": self.kind,
            "line": self.line,
            "lang": self.lang,
            "detail": self.detail,
        }

    def __repr__(self):
        return "Ref(%s %s @L%s)" % (self.kind, self.name, self.line)


class ExtractResult:
    """The honest return of an extraction. On success `backend` is "treesitter"
    and `available` is True. On degradation `backend` is "unavailable", the lists
    are empty, and `reason` explains why — the caller checks `.available` and
    falls back (to its own heuristic / regex path) without seeing a crash."""

    __slots__ = ("symbols", "references", "lang", "backend", "available", "reason")

    def __init__(self, symbols, references, lang, backend, available, reason=""):
        self.symbols = symbols
        self.references = references
        self.lang = lang
        self.backend = backend
        self.available = available
        self.reason = reason

    def to_dict(self):
        return {
            "lang": self.lang,
            "backend": self.backend,
            "available": self.available,
            "reason": self.reason,
            "symbols": [s.to_dict() for s in self.symbols],
            "references": [r.to_dict() for r in self.references],
        }


def _unavailable(lang, reason):
    return ExtractResult([], [], lang, "unavailable", False, reason)


# ── tree walking helpers ──────────────────────────────────────────────────────


def _src_bytes(src):
    if isinstance(src, bytes):
        return src
    return src.encode("utf-8")


def _node_text(node, data):
    return data[node.start_byte:node.end_byte].decode("utf-8", "replace")


def _line(node):
    # tree-sitter start_point is (row, col), 0-based row.
    return node.start_point[0] + 1


def _span(node):
    return (node.start_point[0] + 1, node.end_point[0] + 1)


def _child_field(node, field):
    """Return the first child stored under `field`, or None. Uses the public
    child_by_field_name which is stable across tree_sitter versions."""
    return node.child_by_field_name(field)


def _named_children(node):
    return [node.children[i] for i in range(node.child_count) if node.children[i].is_named]


def _walk(node):
    """Depth-first iterator over every node in the tree (named and unnamed)."""
    stack = [node]
    while stack:
        n = stack.pop()
        yield n
        # push children in reverse so iteration is left-to-right
        for i in range(n.child_count - 1, -1, -1):
            stack.append(n.children[i])


def _parse(canonical, src):
    """Parse source → (root_node, data_bytes). Raises GrammarUnavailable if the
    backend/grammar is missing."""
    parser = _get_parser(canonical)
    data = _src_bytes(src)
    tree = parser.parse(data)
    return tree.root_node, data


# ── per-language symbol extractors ────────────────────────────────────────────
#
# Each returns a list[Symbol]. They walk the real AST and key on grammar node
# types (not regex). Node type names are the stable tree-sitter grammar
# identifiers for each language.


def _looks_like_component(name):
    """A JS/TS function whose name is PascalCase is treated as a React component
    (the RN/React convention the reuse + designmatch consumers care about)."""
    return bool(name) and name[0].isupper()


def _js_symbols(root, data, lang):
    out = []

    def emit_func(node, name_node, kind_hint):
        if name_node is None:
            return
        name = _node_text(name_node, data)
        kind = kind_hint
        if kind == "function" and _looks_like_component(name):
            kind = "component"
        out.append(Symbol(name, kind, _span(node), lang))

    for n in _walk(root):
        t = n.type
        if t == "function_declaration":
            emit_func(n, _child_field(n, "name"), "function")
        elif t == "generator_function_declaration":
            emit_func(n, _child_field(n, "name"), "function")
        elif t in ("class_declaration", "abstract_class_declaration"):
            name_node = _child_field(n, "name")
            if name_node is not None:
                out.append(Symbol(_node_text(name_node, data), "class", _span(n), lang))
        elif t == "method_definition":
            name_node = _child_field(n, "name")
            if name_node is not None:
                out.append(Symbol(_node_text(name_node, data), "method", _span(n), lang))
        elif t == "interface_declaration":
            name_node = _child_field(n, "name")
            if name_node is not None:
                out.append(Symbol(_node_text(name_node, data), "interface", _span(n), lang))
        elif t == "enum_declaration":
            name_node = _child_field(n, "name")
            if name_node is not None:
                out.append(Symbol(_node_text(name_node, data), "enum", _span(n), lang))
        elif t == "type_alias_declaration":
            name_node = _child_field(n, "name")
            if name_node is not None:
                out.append(Symbol(_node_text(name_node, data), "type", _span(n), lang))
        elif t in ("lexical_declaration", "variable_declaration"):
            # const X = () => {...}  /  const X = function () {...}
            for decl in _named_children(n):
                if decl.type != "variable_declarator":
                    continue
                name_node = _child_field(decl, "name")
                value = _child_field(decl, "value")
                if name_node is None or value is None:
                    continue
                if value.type in ("arrow_function", "function", "function_expression"):
                    name = _node_text(name_node, data)
                    kind = "component" if _looks_like_component(name) else "function"
                    out.append(Symbol(name, kind, _span(n), lang))
    return out


def _python_symbols(root, data, lang):
    out = []
    # track class membership so a def inside a class is a method.
    class_spans = []
    for n in _walk(root):
        if n.type == "class_definition":
            name_node = _child_field(n, "name")
            if name_node is not None:
                out.append(Symbol(_node_text(name_node, data), "class", _span(n), lang))
                class_spans.append(_span(n))
    for n in _walk(root):
        if n.type == "function_definition":
            name_node = _child_field(n, "name")
            if name_node is None:
                continue
            ln = _line(n)
            inside_class = any(s <= ln <= e for (s, e) in class_spans)
            # the class node itself contains the def; a top-level def has no
            # enclosing class span other than its own (functions aren't classes).
            kind = "method" if inside_class else "function"
            out.append(Symbol(_node_text(name_node, data), kind, _span(n), lang))
    return out


def _go_symbols(root, data, lang):
    out = []
    for n in _walk(root):
        t = n.type
        if t == "function_declaration":
            name_node = _child_field(n, "name")
            if name_node is not None:
                out.append(Symbol(_node_text(name_node, data), "function", _span(n), lang))
        elif t == "method_declaration":
            name_node = _child_field(n, "name")
            if name_node is not None:
                detail = {}
                recv = _child_field(n, "receiver")
                if recv is not None:
                    detail["receiver"] = _node_text(recv, data).strip("()")
                out.append(Symbol(_node_text(name_node, data), "method", _span(n), lang, detail))
        elif t == "type_declaration":
            for spec in _named_children(n):
                if spec.type != "type_spec":
                    continue
                name_node = _child_field(spec, "name")
                type_node = _child_field(spec, "type")
                if name_node is None:
                    continue
                kind = "type"
                if type_node is not None:
                    if type_node.type == "struct_type":
                        kind = "struct"
                    elif type_node.type == "interface_type":
                        kind = "interface"
                out.append(Symbol(_node_text(name_node, data), kind, _span(spec), lang))
    return out


def _rust_symbols(root, data, lang):
    out = []
    # spans of impl blocks → a fn inside one is a method.
    impl_spans = []
    for n in _walk(root):
        if n.type == "impl_item":
            impl_spans.append(_span(n))
    for n in _walk(root):
        t = n.type
        if t == "function_item":
            name_node = _child_field(n, "name")
            if name_node is None:
                continue
            ln = _line(n)
            inside_impl = any(s <= ln <= e for (s, e) in impl_spans)
            kind = "method" if inside_impl else "function"
            out.append(Symbol(_node_text(name_node, data), kind, _span(n), lang))
        elif t == "struct_item":
            name_node = _child_field(n, "name")
            if name_node is not None:
                out.append(Symbol(_node_text(name_node, data), "struct", _span(n), lang))
        elif t == "enum_item":
            name_node = _child_field(n, "name")
            if name_node is not None:
                out.append(Symbol(_node_text(name_node, data), "enum", _span(n), lang))
        elif t == "trait_item":
            name_node = _child_field(n, "name")
            if name_node is not None:
                out.append(Symbol(_node_text(name_node, data), "interface", _span(n), lang))
    return out


_SYMBOL_EXTRACTORS = {
    "javascript": _js_symbols,
    "typescript": _js_symbols,
    "tsx": _js_symbols,
    "python": _python_symbols,
    "go": _go_symbols,
    "rust": _rust_symbols,
}


# ── per-language reference extractors ─────────────────────────────────────────
#
# References are the call / import / extend edges. The diff/reuse consumers ask
# "does the changed unit call/import/extend a pre-existing repo symbol?", so we
# emit the referenced NAME plus enough detail to resolve it.


def _callee_name(call_node, data):
    """Return (name, receiver) for a call expression's function part. For
    `foo(...)` → (foo, ""). For `obj.method(...)` → (method, obj). For deeper
    chains we take the rightmost property as the name and its object as receiver."""
    fn = _child_field(call_node, "function")
    if fn is None:
        # some grammars name it differently; fall back to first named child
        named = _named_children(call_node)
        fn = named[0] if named else None
    if fn is None:
        return None, ""
    if fn.type in ("identifier",):
        return _node_text(fn, data), ""
    if fn.type in ("member_expression", "field_expression", "selector_expression",
                   "scoped_identifier", "attribute"):
        prop = (_child_field(fn, "property") or _child_field(fn, "field")
                or _child_field(fn, "name") or _child_field(fn, "attribute"))
        obj = (_child_field(fn, "object") or _child_field(fn, "operand")
               or _child_field(fn, "value") or _child_field(fn, "path"))
        name = _node_text(prop, data) if prop is not None else _node_text(fn, data)
        recv = _node_text(obj, data) if obj is not None else ""
        return name, recv
    # last resort: the raw text of the function part
    return _node_text(fn, data), ""


def _js_references(root, data, lang):
    out = []
    for n in _walk(root):
        t = n.type
        if t == "call_expression":
            name, recv = _callee_name(n, data)
            if name:
                detail = {"receiver": recv} if recv else {}
                out.append(Ref(name, "call", _line(n), lang, detail))
        elif t == "import_statement":
            # import X from "mod" / import { a, b } from "mod" / import * as ns
            source = _child_field(n, "source")
            mod = _node_text(source, data).strip("'\"") if source is not None else ""
            names = []
            for sub in _walk(n):
                if sub.type == "import_specifier":
                    nm = _child_field(sub, "name")
                    if nm is not None:
                        names.append(_node_text(nm, data))
                elif sub.type in ("identifier",) and sub.parent is not None and \
                        sub.parent.type in ("import_clause", "namespace_import"):
                    names.append(_node_text(sub, data))
            if not names and mod:
                names = [mod]
            for nm in names:
                out.append(Ref(nm, "import", _line(n), lang, {"module": mod}))
        elif t in ("class_declaration", "abstract_class_declaration"):
            heritage = None
            for c in _named_children(n):
                if c.type == "class_heritage":
                    heritage = c
                    break
            if heritage is not None:
                for sub in _walk(heritage):
                    if sub.type == "identifier" or sub.type == "type_identifier":
                        out.append(Ref(_node_text(sub, data), "extend", _line(n), lang,
                                       {"relation": "extends"}))
                        break
    return out


def _python_references(root, data, lang):
    out = []
    for n in _walk(root):
        t = n.type
        if t == "call":
            fn = _child_field(n, "function")
            if fn is None:
                continue
            if fn.type == "identifier":
                out.append(Ref(_node_text(fn, data), "call", _line(n), lang))
            elif fn.type == "attribute":
                attr = _child_field(fn, "attribute")
                obj = _child_field(fn, "object")
                if attr is not None:
                    recv = _node_text(obj, data) if obj is not None else ""
                    detail = {"receiver": recv} if recv else {}
                    out.append(Ref(_node_text(attr, data), "call", _line(n), lang, detail))
        elif t == "import_statement":
            for sub in _named_children(n):
                if sub.type == "dotted_name":
                    out.append(Ref(_node_text(sub, data), "import", _line(n), lang,
                                   {"module": _node_text(sub, data)}))
                elif sub.type == "aliased_import":
                    nm = _child_field(sub, "name")
                    if nm is not None:
                        out.append(Ref(_node_text(nm, data), "import", _line(n), lang,
                                       {"module": _node_text(nm, data)}))
        elif t == "import_from_statement":
            mod_node = _child_field(n, "module_name")
            mod = _node_text(mod_node, data) if mod_node is not None else ""
            for sub in _named_children(n):
                if sub is mod_node:
                    continue
                if sub.type == "dotted_name":
                    out.append(Ref(_node_text(sub, data), "import", _line(n), lang,
                                   {"module": mod}))
                elif sub.type == "aliased_import":
                    nm = _child_field(sub, "name")
                    if nm is not None:
                        out.append(Ref(_node_text(nm, data), "import", _line(n), lang,
                                       {"module": mod}))
        elif t == "class_definition":
            supers = _child_field(n, "superclasses")
            if supers is not None:
                for sub in _named_children(supers):
                    if sub.type in ("identifier", "attribute"):
                        out.append(Ref(_node_text(sub, data), "extend", _line(n), lang,
                                       {"relation": "extends"}))
    return out


def _go_references(root, data, lang):
    out = []
    for n in _walk(root):
        t = n.type
        if t == "call_expression":
            name, recv = _callee_name(n, data)
            if name:
                detail = {"receiver": recv} if recv else {}
                out.append(Ref(name, "call", _line(n), lang, detail))
        elif t == "import_spec":
            path = _child_field(n, "path")
            if path is not None:
                mod = _node_text(path, data).strip("'\"`")
                out.append(Ref(mod, "import", _line(n), lang, {"module": mod}))
        elif t == "type_spec":
            # struct embedding: `type X struct { Base }` → Base is an extend edge.
            type_node = _child_field(n, "type")
            if type_node is not None and type_node.type == "struct_type":
                for fld in _walk(type_node):
                    if fld.type == "field_declaration":
                        # an embedded field has a type but no field name.
                        if _child_field(fld, "name") is None:
                            tn = _child_field(fld, "type")
                            if tn is not None:
                                out.append(Ref(_node_text(tn, data), "extend", _line(fld),
                                                lang, {"relation": "embeds"}))
    return out


def _rust_references(root, data, lang):
    out = []
    for n in _walk(root):
        t = n.type
        if t == "call_expression":
            name, recv = _callee_name(n, data)
            if name:
                detail = {"receiver": recv} if recv else {}
                out.append(Ref(name, "call", _line(n), lang, detail))
        elif t == "macro_invocation":
            mac = _child_field(n, "macro")
            if mac is not None:
                out.append(Ref(_node_text(mac, data), "call", _line(n), lang,
                               {"macro": True}))
        elif t == "use_declaration":
            arg = _child_field(n, "argument")
            target = arg if arg is not None else n
            # collect the leaf identifiers brought into scope.
            names = []
            for sub in _walk(target):
                if sub.type == "identifier":
                    names.append(_node_text(sub, data))
            mod = _node_text(target, data)
            seen = set()
            for nm in names:
                if nm in seen:
                    continue
                seen.add(nm)
                out.append(Ref(nm, "import", _line(n), lang, {"module": mod}))
        elif t == "impl_item":
            # `impl Trait for Type` → Type implements Trait (an extend edge).
            trait = _child_field(n, "trait")
            if trait is not None:
                out.append(Ref(_node_text(trait, data), "extend", _line(n), lang,
                               {"relation": "implements"}))
    return out


_REF_EXTRACTORS = {
    "javascript": _js_references,
    "typescript": _js_references,
    "tsx": _js_references,
    "python": _python_references,
    "go": _go_references,
    "rust": _rust_references,
}


# ── PUBLIC API ────────────────────────────────────────────────────────────────


def extract_symbols(src, lang):
    """Extract the definitions (functions/methods/classes/components/…) from
    `src` parsed as `lang`. Returns list[Symbol]. Degrades to [] when tree-sitter
    or the grammar is unavailable (call extract() for the reason)."""
    return extract(src, lang).symbols


def extract_references(src, lang):
    """Extract the call/import/extend edges from `src` parsed as `lang`. Returns
    list[Ref]. Degrades to [] when the backend/grammar is unavailable."""
    return extract(src, lang).references


def extract(src, lang):
    """The full extraction: symbols + references in one parse, returned as an
    ExtractResult. THIS is the degradation-honest entry — `.available` is False
    and `.reason` is set when tree-sitter or the grammar is missing, the lists
    empty, and NO exception escapes. Consumers (SI-2, designmatch, F3) check
    `.available` and fall back to their own path when it is False."""
    canonical = normalize_lang(lang)
    if canonical is None:
        return _unavailable(
            str(lang),
            "unsupported language %r (supported: %s)" % (lang, ", ".join(LANGS)),
        )
    if not _ensure_backend():
        return _unavailable(canonical, _BACKEND_STATE["reason"])
    try:
        root, data = _parse(canonical, src)
    except GrammarUnavailable as exc:
        return _unavailable(canonical, str(exc))
    except Exception as exc:  # noqa: BLE001 — a parser crash must degrade, not abort
        return _unavailable(canonical, "parse error: %s" % exc)

    sym_fn = _SYMBOL_EXTRACTORS[canonical]
    ref_fn = _REF_EXTRACTORS[canonical]
    try:
        symbols = sym_fn(root, data, canonical)
        references = ref_fn(root, data, canonical)
    except Exception as exc:  # noqa: BLE001 — extraction bug must degrade honestly
        return _unavailable(canonical, "extraction error: %s" % exc)
    return ExtractResult(symbols, references, canonical, "treesitter", True, "")


def extract_from_path(path, lang=None):
    """Convenience for the CLI: read a file, infer its language from the
    extension (unless `lang` is given), and extract. Returns an ExtractResult."""
    use_lang = normalize_lang(lang) if lang else lang_for_path(path)
    if use_lang is None:
        return _unavailable(
            lang or "?",
            "could not determine language for %r (pass --lang)" % path,
        )
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        src = fh.read()
    return extract(src, use_lang)


if __name__ == "__main__":
    # Tiny self-test usable as `python3 treesitter_ast.py <file>` for ad-hoc
    # inspection; the real CLI is bin/heimdall-ast. Prints the JSON extraction.
    import sys

    if len(sys.argv) < 2:
        sys.stdout.write(json.dumps(backend_info(), indent=2) + "\n")
        raise SystemExit(0)
    res = extract_from_path(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
    sys.stdout.write(json.dumps(res.to_dict(), indent=2) + "\n")
    raise SystemExit(0 if res.available else 0)
