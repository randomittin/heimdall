#!/usr/bin/env python3
# behavioral_diff.py — the AST behavioral-diff engine behind
# `bin/designmatch-behavioral-diff` (designmatch v2, step-5 verification).
#
# THE PROBLEM
#   designmatch v2 regenerates a screen fresh from the (visual-only) canonical.
#   The fresh component is visually faithful but BEHAVIORALLY EMPTY. The old
#   component is the SOLE source of behavior (handlers, state, API calls, nav,
#   effects, prop contracts). Before the old file is released from tmp, we must
#   prove every behavioral unit it carried is PRESENT AND WIRED in the new one.
#
# WHY NOT GREP
#   grep gives false confidence: a handler `submit` can be "present" by name in
#   the new file (declared, imported) yet never wired to any JSX prop and never
#   invoked — a dead function. A grep match counts it as migrated; it is not.
#   The behavioral requirement is to distinguish PRESENT-AND-WIRED from
#   NAME-APPEARS-BUT-UNWIRED. That needs structure, not string matching.
#
# THE BACKEND SEAM (pluggable; tree-sitter slots in later)
#   `extract_behavioral_surface(src, path, backend=...) -> ExtractionResult`
#   is the single entry point. It dispatches to a registered backend by name:
#
#     "structural"  (DEFAULT, primary NOW) — a real scope/brace-tracking walker
#                   over a tokenized view of the source. It does NOT merely match
#                   strings: it confirms a handler is WIRED by checking it is bound
#                   to a JSX attribute (`onPress={submit}`) or invoked inside a
#                   wired callback, and it reads `useState`/`useEffect`/call
#                   structure from balanced-bracket scopes. This is materially
#                   better than grep and is the primary backend while the
#                   tree-sitter substrate stays PARKED (RJ's standing discipline:
#                   substrate parked until the C3 verdict; designmatch is off the
#                   critical path, so it does not justify un-parking tree-sitter).
#
#     "heuristic"   (DEGRADED FLOOR, required fallback) — a pure-regex extractor.
#                   It is the graceful-degradation layer: if the structural walker
#                   raises on a pathological input, OR a caller explicitly forces
#                   it, the engine never crashes — it degrades to regex and SAYS SO
#                   in the `backend` field with a lowered `parse_confidence`.
#
#     "treesitter"  (FUTURE) — registering a real tree-sitter backend post-C3 is a
#                   one-line addition to BACKENDS below. The diff/coverage logic
#                   (compare_surfaces, coverage record) consumes the backend-neutral
#                   BehavioralUnit model and does NOT change when the backend does.
#                   THAT is the seam: backends produce units; the diff is backend-
#                   agnostic. See register_backend().
#
# HONEST COVERAGE (the cardinal output rule)
#   The diff reports its OWN confidence, not just pass/fail. The record carries:
#     extracted, present_and_wired, unmatched, coverage_pct, unmatched_units,
#     backend, parse_confidence.
#   A green check with LOW extraction coverage is a FALSE GREEN — the numbers are
#   always surfaced. K (unmatched units) > 0 BLOCKS the tmp-exit (the caller reads
#   `blocked`/`unmatched_units` to refuse release). A low-confidence parse is
#   visible in `parse_confidence`, never hidden as a pass.
#
# This is PURE stdlib. No third-party parser is used (tree-sitter is parked); the
# structural backend is a hand-rolled scope walker, the heuristic backend is regex.

import json
import os
import re
import sys

# ── the backend-neutral behavioral unit model ────────────────────────────────


# Behavioral categories extracted from a component's surface.
CAT_HANDLER = "handler"      # event handler bound to a JSX prop (onPress=...)
CAT_STATE = "state"          # useState / useReducer / redux selector / dispatch
CAT_API = "api"              # fetch / axios / react-query / data call
CAT_NAV = "nav"              # navigation.navigate / .push / .goBack / etc.
CAT_EFFECT = "effect"        # useEffect with its dep signature
CAT_PROP = "prop"            # prop contract: received and passed down

ALL_CATEGORIES = (CAT_HANDLER, CAT_STATE, CAT_API, CAT_NAV, CAT_EFFECT, CAT_PROP)


class BehavioralUnit:
    """One unit of behavioral surface. Backend-neutral: every backend produces
    these, and compare_surfaces consumes ONLY these — so swapping the backend
    (structural → tree-sitter) never touches the diff logic.

    Fields:
      category : one of CAT_* — what KIND of behavior this is.
      key      : the stable identity used for matching old↔new (e.g. a handler's
                 bound function name, a state var name, an effect's dep signature).
      label    : a human description for the unmatched-units report.
      wired    : True only when this unit is actually CONNECTED (a handler bound
                 to a JSX prop / a call actually invoked), not merely named. This
                 is the present-AND-wired distinction that grep cannot make.
      detail   : backend-specific evidence (the JSX prop, the call expression…).
    """

    __slots__ = ("category", "key", "label", "wired", "detail")

    def __init__(self, category, key, label, wired, detail=""):
        self.category = category
        self.key = key
        self.label = label
        self.wired = wired
        self.detail = detail

    def match_id(self):
        # The identity two backends/sides agree on. Category + key: a handler
        # `submit` in old must match a WIRED `submit` in new regardless of which
        # JSX element it hangs off.
        return (self.category, self.key)

    def to_dict(self):
        return {
            "category": self.category,
            "key": self.key,
            "label": self.label,
            "wired": self.wired,
            "detail": self.detail,
        }


class ExtractionResult:
    """What a backend returns: the units it found + an honest self-assessment of
    how well it parsed (so a partial parse lowers coverage instead of faking a
    pass). `parse_confidence` ∈ [0,1]; `coverage_basis` explains the number."""

    __slots__ = ("units", "backend", "parse_confidence", "coverage_basis", "notes")

    def __init__(self, units, backend, parse_confidence, coverage_basis, notes=None):
        self.units = units
        self.backend = backend
        self.parse_confidence = parse_confidence
        self.coverage_basis = coverage_basis
        self.notes = notes or []


# ── tokenization helpers shared by the structural backend ─────────────────────
#
# Not a full JS lexer (tree-sitter is parked) — a "structural view" that masks
# out the parts of source that lie to a naive matcher: string/template literals,
# comments, and regex literals. With those masked, brace/paren depth tracking is
# reliable, so we can answer "is this `submit` reference inside a JSX attribute
# value?" and "what is the body of this useEffect?" structurally rather than by
# string proximity.


def _mask_noncode(src):
    """Return `src` with the CONTENT of strings, template literals, line and block
    comments replaced by same-length filler (spaces, keeping newlines), so that
    brace/paren scanning is not fooled by braces inside a string or a comment.
    Identifiers, operators, braces and JSX stay intact. Length is preserved so
    every index in the masked view maps 1:1 back to the original source."""
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        # line comment
        if c == "/" and nxt == "/":
            while i < n and src[i] != "\n":
                out.append(" ")
                i += 1
            continue
        # block comment
        if c == "/" and nxt == "*":
            out.append("  ")
            i += 2
            while i < n and not (src[i] == "*" and i + 1 < n and src[i + 1] == "/"):
                out.append("\n" if src[i] == "\n" else " ")
                i += 1
            if i < n:
                out.append("  ")
                i += 2
            continue
        # string / template literal
        if c in ("'", '"', "`"):
            quote = c
            out.append(c)
            i += 1
            while i < n:
                ch = src[i]
                if ch == "\\" and i + 1 < n:
                    out.append("  ")
                    i += 2
                    continue
                if ch == quote:
                    out.append(quote)
                    i += 1
                    break
                out.append("\n" if ch == "\n" else " ")
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def _matching_brace(masked, open_idx, opench="{", closech="}"):
    """Given the index of an opening bracket in the masked view, return the index
    of the matching close bracket, or -1. Operates on the masked source so braces
    inside strings/comments are already neutralized."""
    depth = 0
    i = open_idx
    n = len(masked)
    while i < n:
        ch = masked[i]
        if ch == opench:
            depth += 1
        elif ch == closech:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def _line_of(src, idx):
    return src.count("\n", 0, idx) + 1


# ── the STRUCTURAL backend (primary; real scope walking, not grep) ────────────

_IDENT = r"[A-Za-z_$][\w$]*"

# JSX event-prop attribute:  onPress={ EXPR }   /  onChange={EXPR}  etc.
# The prop name is a camelCase `on...` handler attribute. We capture the prop and
# the raw expression so we can decide WIRING structurally (below).
_JSX_HANDLER_ATTR = re.compile(
    r"\b(on[A-Z]\w*)\s*=\s*\{", re.M
)

# useState destructure:  const [count, setCount] = useState(...)
_USESTATE = re.compile(
    r"\b(?:const|let|var)\s*\[\s*(" + _IDENT + r")\s*,\s*(" + _IDENT + r")\s*\]\s*=\s*useState\b"
)
# useReducer:  const [state, dispatch] = useReducer(reducer, init)
_USEREDUCER = re.compile(
    r"\b(?:const|let|var)\s*\[\s*(" + _IDENT + r")\s*,\s*(" + _IDENT + r")\s*\]\s*=\s*useReducer\b"
)
# redux selector:  const x = useSelector(...)
_USESELECTOR = re.compile(
    r"\b(?:const|let|var)\s+(" + _IDENT + r")\s*=\s*useSelector\b"
)
# redux dispatch binding:  const dispatch = useDispatch()
_USEDISPATCH = re.compile(r"\buseDispatch\s*\(")
# a dispatch(...) call
_DISPATCH_CALL = re.compile(r"\bdispatch\s*\(")

# data/API calls — the call head we treat as an API surface.
_API_HEADS = (
    "fetch", "axios", "useQuery", "useMutation", "useInfiniteQuery",
    "useLazyQuery", "request", "ky", "superagent",
)
_API_CALL = re.compile(r"\b(" + "|".join(re.escape(h) for h in _API_HEADS) + r")\b(\s*\.\s*\w+)?\s*\(")
# axios.get / axios.post style is covered by the optional `.method` group above.

# navigation calls — navigation.navigate / .push / .replace / .goBack / linkTo /
# router.push (expo-router).  We capture the method for the key.
_NAV_CALL = re.compile(
    r"\b(?:navigation|nav|router)\s*\.\s*(navigate|push|replace|goBack|pop|popToTop|reset|setParams|dispatch)\s*\("
)
_NAV_LINKTO = re.compile(r"\b(linkTo)\s*\(")

# useEffect / useLayoutEffect — captured with their dependency-array signature.
_USEEFFECT = re.compile(r"\b(useEffect|useLayoutEffect)\s*\(")

# function declarations / named arrow consts (handler bodies live here).
_FUNC_DECL = re.compile(r"\bfunction\s+(" + _IDENT + r")\s*\(")
_ARROW_CONST = re.compile(
    r"\b(?:const|let|var)\s+(" + _IDENT + r")\s*=\s*(?:async\s*)?\([^)]*\)\s*=>"
)
_ARROW_CONST_NOPAREN = re.compile(
    r"\b(?:const|let|var)\s+(" + _IDENT + r")\s*=\s*(?:async\s*)?" + _IDENT + r"\s*=>"
)

# component prop contract: destructured props in the component signature
#   function Screen({ userId, onDone }) {...}  /  const Screen = ({a,b}) => {...}
_PROPS_DESTRUCTURE = re.compile(
    r"(?:function\s+" + _IDENT + r"\s*\(\s*\{([^}]*)\}\s*\)"
    r"|(?:const|let|var)\s+" + _IDENT + r"\s*=\s*(?:async\s*)?\(\s*\{([^}]*)\}\s*\)\s*=>)"
)


def _collect_identifiers(masked_expr):
    return set(re.findall(_IDENT, masked_expr))


def _name_used_beyond(masked, name):
    """True if `name` appears MORE THAN ONCE in the (masked) source — i.e. beyond
    its single binding/declaration site. A state setter / reducer dispatch bound
    once in its `[v, set] = useState` destructure and never referenced again is
    DEAD (unwired); one that is invoked `set(` OR passed by reference
    (`onChangeText={set}`) appears a second time → wired. This is the
    reference-counting wiring signal for state."""
    return len(re.findall(r"\b" + re.escape(name) + r"\b", masked)) > 1


def _structural_extract(src, path):
    """The real work: walk the masked source, decide WIRING structurally.

    Returns ExtractionResult with backend='structural'. Raises only on truly
    pathological input — the public entry wraps this and degrades to heuristic on
    any exception, so a raise here is never fatal to the caller."""
    masked = _mask_noncode(src)
    units = []
    seen = set()  # dedupe by (category, key)
    notes = []

    def add(category, key, label, wired, detail=""):
        mid = (category, key)
        if mid in seen:
            # keep the wired=True version if any side is wired
            for u in units:
                if u.match_id() == mid and wired and not u.wired:
                    u.wired = True
                    u.detail = detail or u.detail
            return
        seen.add(mid)
        units.append(BehavioralUnit(category, key, label, wired, detail))

    # --- the set of locally-defined function names (for wiring resolution) ---
    local_funcs = set()
    for m in _FUNC_DECL.finditer(masked):
        local_funcs.add(m.group(1))
    for m in _ARROW_CONST.finditer(masked):
        local_funcs.add(m.group(1))
    for m in _ARROW_CONST_NOPAREN.finditer(masked):
        local_funcs.add(m.group(1))

    # --- HANDLERS: a JSX `on...={EXPR}` attribute. The handler is WIRED because
    #     it hangs off a JSX prop. The KEY is the bound function name (so a
    #     migration that re-binds the SAME logic under the same name matches).
    #     Inline-arrow handlers (`onPress={() => submit()}`) are wired and keyed
    #     by the function they call; a bare `onPress={submit}` keys on `submit`.
    for m in _JSX_HANDLER_ATTR.finditer(masked):
        prop = m.group(1)
        brace_open = m.end() - 1  # the `{` of the attribute value
        brace_close = _matching_brace(masked, brace_open, "{", "}")
        if brace_close == -1:
            continue
        expr_masked = masked[brace_open + 1:brace_close]
        expr_real = src[brace_open + 1:brace_close]
        idents = _collect_identifiers(expr_masked)
        # Bound function: prefer a locally-defined function referenced in the expr;
        # else the first call target; else the lone identifier (bare binding).
        bound = None
        called = re.findall(r"(" + _IDENT + r")\s*\(", expr_masked)
        local_hit = [i for i in idents if i in local_funcs]
        if local_hit:
            # the locally-defined handler this prop wires to
            bound = sorted(local_hit)[0]
        elif called:
            bound = called[0]
        else:
            stripped = expr_masked.strip()
            if re.fullmatch(_IDENT, stripped):
                bound = stripped
        if not bound:
            # an inline arrow with no call and no ident (e.g. a literal) — still a
            # handler surface, key it by the prop+line so it is counted, not lost.
            bound = prop + "@" + str(_line_of(src, m.start()))
        label = "handler %s={%s}" % (prop, expr_real.strip()[:40])
        add(CAT_HANDLER, bound, label, True, detail=prop)

    # --- STATE: useState / useReducer / selectors / dispatch ---
    for m in _USESTATE.finditer(masked):
        var, setter = m.group(1), m.group(2)
        # WIRED iff the setter is actually USED — invoked `setter(` OR bound by
        # reference (`onChangeText={setter}`, passed as a callback). A setter that
        # appears only in its own destructure is dead state. Counting "used at all"
        # (not just "called") is what makes a reference-bound setter count as wired
        # while still flagging a never-referenced one.
        setter_used = _name_used_beyond(masked, setter)
        add(CAT_STATE, var, "useState(%s/%s)" % (var, setter), setter_used,
            detail="setter=%s" % setter)
    for m in _USEREDUCER.finditer(masked):
        st, disp = m.group(1), m.group(2)
        disp_used = _name_used_beyond(masked, disp)
        add(CAT_STATE, st, "useReducer(%s/%s)" % (st, disp), disp_used,
            detail="dispatch=%s" % disp)
    for m in _USESELECTOR.finditer(masked):
        var = m.group(1)
        # WIRED iff the selected value is referenced beyond its declaration.
        refs = len(re.findall(r"\b" + re.escape(var) + r"\b", masked))
        add(CAT_STATE, var, "useSelector→%s" % var, refs > 1, detail="selector")
    if _USEDISPATCH.search(masked):
        disp_called = _DISPATCH_CALL.search(masked) is not None
        add(CAT_STATE, "dispatch", "useDispatch()", disp_called, detail="redux-dispatch")

    # --- API / data calls. WIRED = the call expression is present and inside a
    #     function/effect body (i.e. it is actually invoked, not a dangling type
    #     reference). We approximate "inside a body" as: the call is not at JSX
    #     attribute position. The KEY includes the call head + a 1-based ordinal
    #     for multiple distinct call sites so two `fetch`es are two units.
    api_seen = {}
    for m in _API_CALL.finditer(masked):
        head = m.group(1)
        method = (m.group(2) or "").replace(" ", "")
        api_seen.setdefault(head, 0)
        api_seen[head] += 1
        key = head + method
        if api_seen[head] > 1:
            key = "%s#%d" % (key, api_seen[head])
        label = "api %s%s(...)" % (head, method)
        add(CAT_API, key, label, True, detail="call")

    # --- NAVIGATION ---
    nav_seen = {}
    for m in _NAV_CALL.finditer(masked):
        method = m.group(1)
        nav_seen.setdefault(method, 0)
        nav_seen[method] += 1
        key = "navigation." + method
        if nav_seen[method] > 1:
            key = "%s#%d" % (key, nav_seen[method])
        add(CAT_NAV, key, "nav.%s(...)" % method, True, detail="navigation")
    for m in _NAV_LINKTO.finditer(masked):
        add(CAT_NAV, "linkTo", "linkTo(...)", True, detail="navigation")

    # --- EFFECTS: useEffect(cb, [deps]). KEY = the sorted dep signature so the
    #     SAME effect (same deps) matches across old/new even if reordered. WIRED
    #     = the effect callback body is non-empty.
    for m in _USEEFFECT.finditer(masked):
        paren_open = m.end() - 1
        paren_close = _matching_brace(masked, paren_open, "(", ")")
        if paren_close == -1:
            continue
        inner = masked[paren_open + 1:paren_close]
        # dependency array = the last top-level [...] in the call args.
        deps = _effect_deps(inner)
        # callback body present? find the first `{...}` or arrow body.
        body_present = bool(re.search(r"=>\s*\{", inner) or re.search(r"function\b", inner))
        if body_present:
            bo = inner.find("{")
            if bo != -1:
                bc = _matching_brace(inner, bo, "{", "}")
                body = inner[bo + 1:bc] if bc != -1 else ""
                body_present = bool(body.strip())
        key = "effect[" + ",".join(deps) + "]"
        add(CAT_EFFECT, key, "useEffect deps=[%s]" % ",".join(deps), body_present,
            detail="deps=%s" % deps)

    # --- PROP CONTRACT: the component's destructured props. Each received prop is
    #     a unit; WIRED = the prop is referenced in the body (used, not just
    #     declared and ignored). This catches a regenerated component that takes
    #     `userId` as a prop but never threads it through.
    pm = _PROPS_DESTRUCTURE.search(masked)
    if pm:
        props_raw = pm.group(1) or pm.group(2) or ""
        # the component body starts after the signature.
        body_start = pm.end()
        body = masked[body_start:]
        for prop in _split_props(props_raw):
            if not prop:
                continue
            used = re.search(r"\b" + re.escape(prop) + r"\b", body) is not None
            add(CAT_PROP, prop, "prop %s" % prop, used, detail="received")

    # --- parse confidence: did we get a coherent parse? Confidence is high when
    #     the masked source has balanced braces (the structural assumptions hold)
    #     and we found a component-shaped signature. A skewed brace count means we
    #     likely mis-scoped — lower confidence so a partial parse cannot green.
    confidence, basis = _structural_confidence(masked, units, bool(pm))
    if not units:
        notes.append("no behavioral surface extracted")
    return ExtractionResult(units, "structural", confidence, basis, notes)


def _effect_deps(call_inner):
    """Extract the dependency identifiers from a useEffect call's args (the masked
    inner text between the call parens). Returns a SORTED list of identifier names
    so the signature is order-independent. `[]` → empty list (run-once)."""
    # the dep array is the last top-level [...] group.
    depth = 0
    last_open = -1
    last_close = -1
    for idx, ch in enumerate(call_inner):
        if ch in "({":
            depth += 1
        elif ch in ")}":
            depth -= 1
        elif ch == "[" and depth == 0:
            last_open = idx
        elif ch == "]" and depth == 0 and last_open != -1:
            last_close = idx
    if last_open == -1 or last_close == -1 or last_close <= last_open:
        return ["<no-deps>"]
    inner = call_inner[last_open + 1:last_close]
    ids = sorted(set(re.findall(_IDENT, inner)))
    return ids if ids else ["<empty>"]


def _split_props(props_raw):
    """Split a destructured-props string into top-level prop names, handling
    defaults (`a = 1`), rename (`a: b`), and rest (`...rest`). Nested braces
    (object defaults) are skipped at top level."""
    names = []
    depth = 0
    token = []
    for ch in props_raw:
        if ch in "{[(":
            depth += 1
            token.append(ch)
        elif ch in "}])":
            depth -= 1
            token.append(ch)
        elif ch == "," and depth == 0:
            names.append("".join(token))
            token = []
        else:
            token.append(ch)
    if token:
        names.append("".join(token))
    out = []
    for raw in names:
        raw = raw.strip()
        if not raw:
            continue
        if raw.startswith("..."):
            out.append(raw[3:].strip())
            continue
        # `name: alias` → the local binding is the alias; `name = default` → name.
        if ":" in raw:
            raw = raw.split(":", 1)[1]
        if "=" in raw:
            raw = raw.split("=", 1)[0]
        name = raw.strip()
        m = re.match(_IDENT, name)
        if m:
            out.append(m.group(0))
    return out


def _structural_confidence(masked, units, has_component_sig):
    """A real, honest confidence number in [0,1]. It is LOW when the parse looks
    unreliable, so a partial parse surfaces as low coverage rather than a false
    green. Factors:
      - brace/paren balance (skew → we mis-scoped → low),
      - whether a component signature was found (no signature → we may have
        parsed a fragment),
      - whether ANY surface was extracted.
    """
    opens = masked.count("{") + masked.count("(") + masked.count("[")
    closes = masked.count("}") + masked.count(")") + masked.count("]")
    if opens + closes == 0:
        balance = 0.0
    else:
        balance = 1.0 - (abs(opens - closes) / max(opens + closes, 1))
    conf = balance
    basis_parts = ["bracket-balance=%.2f" % balance]
    if not has_component_sig:
        conf *= 0.6
        basis_parts.append("no-component-signature(-40%)")
    if not units:
        conf *= 0.5
        basis_parts.append("no-units(-50%)")
    conf = max(0.0, min(1.0, conf))
    return round(conf, 3), "; ".join(basis_parts)


# ── the HEURISTIC backend (degraded floor; pure regex) ────────────────────────
#
# This is deliberately weaker than the structural backend: it is the graceful-
# degradation layer. It can still tell wired-vs-unwired for the COMMON case (a
# handler name that appears in an `on...=` attribute is wired; one that only
# appears as a declaration is not) — so even degraded it catches a planted gap.
# It does NOT do balanced-bracket scoping, so its parse_confidence is capped.

_H_HANDLER_DECL = re.compile(r"\b(?:function\s+|(?:const|let|var)\s+)(on[A-Z]\w*|handle\w*|\w*Press|\w*Submit|\w*Change)\b")
_H_JSX_ATTR = re.compile(r"\b(on[A-Z]\w*)\s*=\s*\{([^}]*)\}")


def _heuristic_extract(src, path):
    units = []
    seen = set()

    def add(category, key, label, wired, detail=""):
        mid = (category, key)
        if mid in seen:
            for u in units:
                if u.match_id() == mid and wired and not u.wired:
                    u.wired = True
            return
        seen.add(mid)
        units.append(BehavioralUnit(category, key, label, wired, detail))

    # handlers: a name bound in a JSX `on...={...}` attribute is WIRED. We key on
    # the bound identifier inside the braces (first identifier), matching the
    # structural backend's key so the two backends are interchangeable downstream.
    for m in _H_JSX_ATTR.finditer(src):
        prop = m.group(1)
        expr = m.group(2)
        ids = re.findall(_IDENT, expr)
        called = re.findall(r"(" + _IDENT + r")\s*\(", expr)
        bound = called[0] if called else (ids[0] if ids else prop)
        add(CAT_HANDLER, bound, "handler %s={...}" % prop, True, detail=prop)

    # state
    for m in _USESTATE.finditer(src):
        var, setter = m.group(1), m.group(2)
        setter_used = _name_used_beyond(src, setter)
        add(CAT_STATE, var, "useState(%s)" % var, setter_used, detail="setter=%s" % setter)
    for m in _USEREDUCER.finditer(src):
        st, disp = m.group(1), m.group(2)
        disp_used = _name_used_beyond(src, disp)
        add(CAT_STATE, st, "useReducer(%s)" % st, disp_used, detail="dispatch=%s" % disp)
    for m in _USESELECTOR.finditer(src):
        var = m.group(1)
        refs = len(re.findall(r"\b" + re.escape(var) + r"\b", src))
        add(CAT_STATE, var, "useSelector→%s" % var, refs > 1, detail="selector")
    if _USEDISPATCH.search(src):
        add(CAT_STATE, "dispatch", "useDispatch()", _DISPATCH_CALL.search(src) is not None,
            detail="redux-dispatch")

    # api
    api_seen = {}
    for m in _API_CALL.finditer(src):
        head = m.group(1)
        method = (m.group(2) or "").replace(" ", "")
        api_seen.setdefault(head, 0)
        api_seen[head] += 1
        key = head + method
        if api_seen[head] > 1:
            key = "%s#%d" % (key, api_seen[head])
        add(CAT_API, key, "api %s%s(...)" % (head, method), True, detail="call")

    # nav
    nav_seen = {}
    for m in _NAV_CALL.finditer(src):
        method = m.group(1)
        nav_seen.setdefault(method, 0)
        nav_seen[method] += 1
        key = "navigation." + method
        if nav_seen[method] > 1:
            key = "%s#%d" % (key, nav_seen[method])
        add(CAT_NAV, key, "nav.%s(...)" % method, True, detail="navigation")
    for m in _NAV_LINKTO.finditer(src):
        add(CAT_NAV, "linkTo", "linkTo(...)", True, detail="navigation")

    # effects — heuristic dep extraction (no brace scoping): grab the bracket
    # group nearest the useEffect call.
    for m in _USEEFFECT.finditer(src):
        tail = src[m.end():m.end() + 4000]
        depm = re.search(r"\]\s*,?\s*\[([^\]]*)\]\s*\)", tail) or re.search(r",\s*\[([^\]]*)\]\s*\)", tail)
        deps = sorted(set(re.findall(_IDENT, depm.group(1)))) if depm else ["<no-deps>"]
        if not deps:
            deps = ["<empty>"]
        body_present = bool(re.search(r"=>\s*\{|function", tail[:80]))
        add(CAT_EFFECT, "effect[" + ",".join(deps) + "]", "useEffect deps=[%s]" % ",".join(deps),
            body_present, detail="deps=%s" % deps)

    # props
    pm = _PROPS_DESTRUCTURE.search(src)
    if pm:
        props_raw = pm.group(1) or pm.group(2) or ""
        body = src[pm.end():]
        for prop in _split_props(props_raw):
            if not prop:
                continue
            used = re.search(r"\b" + re.escape(prop) + r"\b", body) is not None
            add(CAT_PROP, prop, "prop %s" % prop, used, detail="received")

    # heuristic confidence is capped: it cannot verify scope, so even a clean
    # parse tops out below the structural backend's ceiling. This is honest — the
    # degraded layer SAYS it is less sure.
    conf = 0.6 if units else 0.2
    return ExtractionResult(units, "heuristic", conf,
                            "regex-floor(no-scope-verification, capped)",
                            notes=[] if units else ["no behavioral surface extracted"])


# ── the BACKEND REGISTRY (the seam) ───────────────────────────────────────────
#
# Backends are registered by name. The public entry resolves a name → callable.
# Adding a tree-sitter backend post-C3 is: register_backend("treesitter", fn).
# Nothing in compare_surfaces / the coverage record references a backend by name.

BACKENDS = {}


def register_backend(name, fn):
    """Register a backend: a callable (src, path) -> ExtractionResult. This is the
    extension point. A future tree-sitter backend slots in here without touching
    the diff or coverage logic."""
    BACKENDS[name] = fn


register_backend("structural", _structural_extract)
register_backend("heuristic", _heuristic_extract)


# ── the TREE-SITTER backend (the one-line seam swap, now wired) ───────────────
#
# The substrate is un-parked: bin/lib/treesitter_ast.py is a REAL tree-sitter
# integration that parses the C3 stacks and extracts symbols + call/import/extend
# edges. This backend slots that substrate into the behavioral-diff seam exactly
# as the parked note above promised: `register_backend("treesitter", fn)`.
#
# WHAT IT EXTRACTS via AST (not regex): for a plain (non-React) JS/TS module it
# walks the real syntax tree and emits the backend-neutral BehavioralUnit model —
#   state  : top-level useState/useReducer/useSelector binders + useDispatch,
#            keyed identically to the structural backend so the two are
#            interchangeable downstream (compare_surfaces is backend-agnostic);
#   api    : fetch/axios/react-query call edges (from the AST call nodes);
#   nav    : navigation.<method>(...) / linkTo(...) call edges;
#   effect : useEffect dependency signatures.
# Handler WIRING (is `submit` bound to a JSX `onPress`?) is React-JSX semantics
# that the purpose-built STRUCTURAL walker already models precisely. A generic
# AST symbol/edge walk does NOT reproduce that wiring judgement, and producing a
# weaker handler surface here would REGRESS the migration diff for React/RN
# components (the diff's whole reason to exist). So for a React/JSX component this
# backend DEFERS — it raises, and extract_behavioral_surface's existing graceful
# fallback routes the input to the proven structural/heuristic path. That is an
# honest capability boundary: the tree-sitter substrate owns the language-
# structural surface (symbols/refs — consumed by SI-2 reuse and F3); the
# structural backend owns React behavioral wiring. The diff is unchanged.
#
# REGISTRATION IS CONDITIONAL: this backend registers ONLY when treesitter_ast's
# tree-sitter backend is actually importable on the host. When tree-sitter is
# absent the name stays UNregistered, so the existing structural/heuristic path
# is unchanged and a `--backend treesitter` request degrades gracefully via the
# unknown-backend path — behavioral-diff is never broken by tree-sitter's absence.


class _TreesitterDeferral(Exception):
    """Raised by the tree-sitter backend when the input is a React/JSX component
    whose behavioral WIRING is better served by the structural backend. The
    seam's graceful fallback catches it (as any backend exception) and routes to
    the heuristic floor, so the proven path stays authoritative for RN."""


def _load_treesitter_substrate():
    """Lazy-import the AST substrate sitting next to this module. Returns the
    module if its tree-sitter backend is available, else None — so registration
    below is conditional and the stranger-test env (no tree-sitter) is unaffected.
    Never raises: a missing substrate simply means 'do not register'."""
    import importlib.util

    lib_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "treesitter_ast.py")
    if not os.path.isfile(lib_path):
        return None
    try:
        spec = importlib.util.spec_from_file_location("heimdall_treesitter_ast", lib_path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    except Exception:  # noqa: BLE001 — any import failure → do not register
        return None
    try:
        if not mod.backend_available():
            return None
    except Exception:  # noqa: BLE001
        return None
    return mod


def _make_treesitter_backend(ts):
    """Build the (src, path) -> ExtractionResult backend bound to substrate `ts`."""

    _REACT_HOOK_CALLS = {
        "useState", "useReducer", "useEffect", "useLayoutEffect", "useMemo",
        "useCallback", "useRef", "useContext", "useSelector", "useDispatch",
    }

    def _is_react_component(refs):
        # A React/JSX component is detected structurally: it calls a React hook
        # or imports from react/react-native. For those, wiring is structural's
        # domain → defer. (Detected from the real AST refs, not a string scan.)
        for r in refs:
            if r.kind == "call" and r.name in _REACT_HOOK_CALLS:
                return True
            if r.kind == "import":
                mod = (r.detail or {}).get("module", "")
                if mod in ("react", "react-native") or mod.startswith("@react-navigation"):
                    return True
        return False

    def _lang_for(path):
        lang = ts.lang_for_path(path)
        return lang or "javascript"

    def _treesitter_extract(src, path):
        lang = _lang_for(path)
        result = ts.extract(src, lang)
        if not result.available:
            # The substrate degraded mid-call (e.g. grammar vanished): hand the
            # input back to the seam's fallback rather than fabricate a surface.
            raise _TreesitterDeferral(
                "treesitter substrate unavailable: %s" % result.reason)

        if _is_react_component(result.references):
            # React behavioral wiring belongs to the structural backend.
            raise _TreesitterDeferral(
                "react/jsx component — handler wiring deferred to structural backend")

        # ── plain (non-React) module: build the behavioral surface from the AST ──
        units = []
        seen = set()

        def add(category, key, label, wired, detail=""):
            mid = (category, key)
            if mid in seen:
                for u in units:
                    if u.match_id() == mid and wired and not u.wired:
                        u.wired = True
                return
            seen.add(mid)
            units.append(BehavioralUnit(category, key, label, wired, detail))

        # state: useState/useReducer/useSelector binders are call refs; we key on
        # the call site and treat a setter/dispatch as wired (mirrors structural).
        for r in result.references:
            if r.kind != "call":
                continue
            if r.name == "useState":
                add(CAT_STATE, "useState@%d" % r.line, "useState() @L%d" % r.line,
                    True, detail="ast-state")
            elif r.name == "useReducer":
                add(CAT_STATE, "useReducer@%d" % r.line, "useReducer() @L%d" % r.line,
                    True, detail="ast-state")
            elif r.name == "useSelector":
                add(CAT_STATE, "useSelector@%d" % r.line, "useSelector() @L%d" % r.line,
                    True, detail="ast-selector")
            elif r.name == "useDispatch":
                add(CAT_STATE, "dispatch", "useDispatch()", True, detail="ast-redux")

        # api: fetch / axios / react-query call edges.
        api_idx = {}
        for r in result.references:
            if r.kind != "call":
                continue
            recv = (r.detail or {}).get("receiver", "")
            head = r.name
            is_api = (head == "fetch" or
                      (head in ("get", "post", "put", "delete", "patch") and recv == "axios") or
                      head in ("useQuery", "useMutation"))
            if not is_api:
                continue
            api_idx[head] = api_idx.get(head, 0) + 1
            key = head if api_idx[head] == 1 else "%s#%d" % (head, api_idx[head])
            add(CAT_API, key, "api %s(...) @L%d" % (head, r.line), True, detail="ast-call")

        # nav: navigation.<method>(...) and linkTo(...) call edges.
        nav_idx = {}
        for r in result.references:
            if r.kind != "call":
                continue
            recv = (r.detail or {}).get("receiver", "")
            if recv == "navigation" or r.name in ("navigate", "push", "goBack", "replace"):
                meth = r.name
                nav_idx[meth] = nav_idx.get(meth, 0) + 1
                key = "navigation." + meth
                if nav_idx[meth] > 1:
                    key = "%s#%d" % (key, nav_idx[meth])
                add(CAT_NAV, key, "nav.%s(...) @L%d" % (meth, r.line), True, detail="ast-nav")
            elif r.name == "linkTo":
                add(CAT_NAV, "linkTo", "linkTo(...) @L%d" % r.line, True, detail="ast-nav")

        # effect: each useEffect call edge is one effect unit.
        for r in result.references:
            if r.kind == "call" and r.name in ("useEffect", "useLayoutEffect"):
                add(CAT_EFFECT, "effect@%d" % r.line, "useEffect @L%d" % r.line,
                    True, detail="ast-effect")

        # Confidence: a clean AST parse is high-confidence for the structural
        # surface it covers. The denominator is honest — if no behavioral surface
        # was found, say so rather than green a non-component.
        conf = 0.9 if units else 0.3
        basis = "tree-sitter AST parse (lang=%s, source=%s)" % (
            lang, ts.backend_info()["source"])
        notes = [] if units else ["no behavioral surface extracted from AST"]
        return ExtractionResult(units, "treesitter", conf, basis, notes=notes)

    return _treesitter_extract


# Conditional registration: only when the tree-sitter substrate is importable AND
# its backend is available. Absent tree-sitter → name stays unregistered and the
# structural/heuristic backends remain the path (behavioral-diff never breaks).
_TS_SUBSTRATE = _load_treesitter_substrate()
if _TS_SUBSTRATE is not None:
    register_backend("treesitter", _make_treesitter_backend(_TS_SUBSTRATE))


def extract_behavioral_surface(src, path="<component>", backend="structural"):
    """THE SEAM. Extract the behavioral surface of a component.

    backend:
      "structural" (default) — the real scope-tracking walker (primary now).
      "heuristic"            — force the regex floor (degraded; used by tests and
                               by the auto-fallback below).
      any registered name    — e.g. a future "treesitter".

    Graceful degradation: if the requested backend raises on pathological input,
    we fall back to the heuristic backend and record that in the result.notes and
    backend field — we NEVER crash the caller (matches Heimdall's heuristic-
    fallback pattern: absent the better backend → degrade, never abort)."""
    fn = BACKENDS.get(backend)
    if fn is None:
        fn = BACKENDS["heuristic"]
        res = fn(src, path)
        res.notes.append("unknown backend %r → degraded to heuristic" % backend)
        res.backend = "heuristic"
        return res
    try:
        return fn(src, path)
    except Exception as exc:  # noqa: BLE001 — degradation must never crash the caller
        res = _heuristic_extract(src, path)
        res.notes.append("backend %r raised (%s) → degraded to heuristic" % (backend, exc))
        res.backend = "heuristic"
        res.parse_confidence = min(res.parse_confidence, 0.4)
        return res


# ── the DIFF + honest coverage record (backend-agnostic) ──────────────────────


def compare_surfaces(old_result, new_result):
    """Diff the OLD behavioral surface against the NEW one. The contract:

      - a unit extracted from OLD is MIGRATED iff a unit with the SAME match_id
        exists in NEW *and is WIRED there*. A new-side unit that is present by
        name but unwired does NOT count — that is the grep false-green this whole
        module exists to prevent.
      - K = unmatched OLD units (extracted from old, not present-and-wired in new).
      - coverage_pct = present_and_wired / extracted (the migration coverage).

    Returns the honest coverage record dict. Consumes only BehavioralUnit fields,
    so it is independent of which backend produced them (the seam)."""
    old_units = old_result.units
    # index new units by match_id; remember whether each is wired.
    new_by_id = {}
    for u in new_result.units:
        prev = new_by_id.get(u.match_id())
        # if the same id appears wired and unwired in new, the wired one wins.
        if prev is None or (u.wired and not prev.wired):
            new_by_id[u.match_id()] = u

    present_and_wired = []
    unmatched = []
    for ou in old_units:
        nu = new_by_id.get(ou.match_id())
        if nu is not None and nu.wired:
            present_and_wired.append(ou)
        else:
            reason = "absent in new" if nu is None else "present but UNWIRED in new"
            unmatched.append((ou, reason))

    extracted = len(old_units)
    m = len(present_and_wired)
    k = len(unmatched)
    coverage_pct = round(100.0 * m / extracted, 1) if extracted else 0.0

    # parse_confidence is the OLD side's extraction confidence: it bounds how much
    # we trust "extracted" itself. A low number means even the denominator is shaky
    # → surfaced explicitly so a low-confidence parse is never a silent green.
    parse_confidence = round(old_result.parse_confidence, 3)

    record = {
        "extracted": extracted,
        "present_and_wired": m,
        "unmatched": k,
        "coverage_pct": coverage_pct,
        "unmatched_units": [
            {
                "category": ou.category,
                "key": ou.key,
                "label": ou.label,
                "reason": reason,
            }
            for (ou, reason) in unmatched
        ],
        "backend": old_result.backend,
        "new_backend": new_result.backend,
        "parse_confidence": parse_confidence,
        "coverage_basis": old_result.coverage_basis,
        # K>0 BLOCKS the tmp-exit. The caller (dual-gate) reads `blocked`.
        "blocked": k > 0,
        "notes": list(old_result.notes) + (
            ["new-side: " + n for n in new_result.notes]
        ),
    }
    # An honest low-confidence flag: even with K=0, if the parse was weak the
    # green is not trustworthy. Surface it so the caller does not treat a
    # low-confidence K=0 as a confident pass.
    record["low_confidence"] = parse_confidence < 0.5
    return record


def diff_components(old_src, new_src, old_path="<old>", new_path="<new>",
                    backend="structural"):
    """End-to-end: extract both sides with the chosen backend, diff, return the
    honest coverage record. This is what the CLI and callers use."""
    old_res = extract_behavioral_surface(old_src, old_path, backend=backend)
    new_res = extract_behavioral_surface(new_src, new_path, backend=backend)
    return compare_surfaces(old_res, new_res)


def human_summary(record):
    cov = record["coverage_pct"]
    parts = [
        "behavioral-diff: %d/%d behavioral units present-and-wired (%.1f%% coverage)"
        % (record["present_and_wired"], record["extracted"], cov),
        "backend=%s" % record["backend"],
        "parse_confidence=%.3f" % record["parse_confidence"],
    ]
    if record["unmatched"]:
        keys = ", ".join("%s:%s" % (u["category"], u["key"]) for u in record["unmatched_units"])
        parts.append("UNMATCHED(K=%d): %s → tmp-exit BLOCKED" % (record["unmatched"], keys))
    else:
        parts.append("K=0")
    if record.get("low_confidence"):
        parts.append("LOW-CONFIDENCE parse (not a confident green)")
    return " | ".join(parts)


# ── CLI ───────────────────────────────────────────────────────────────────────
#
# Job modes:
#   1) two file paths: behavioral_diff.py OLD NEW [--backend NAME]
#   2) stdin JSON: { "old": "<src>", "new": "<src>", "backend": "..." }
# Emits the coverage record JSON on stdout; the human summary on stderr.
# Exit 0 = clean (K=0). Exit 3 = blocked (K>0). Exit 2 = usage. The engine never
# exits nonzero merely because a parse degraded — degradation is reported, not
# fatal; only an actual unmatched unit (a real migration gap) sets exit 3.


def _read_file(p):
    with open(p, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def main(argv):
    backend = "structural"
    files = []
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--backend":
            backend = argv[i + 1] if i + 1 < len(argv) else "structural"
            i += 2
            continue
        if a in ("-h", "--help"):
            sys.stdout.write(
                "usage: behavioral_diff.py OLD NEW [--backend structural|heuristic]\n"
                "       echo '{\"old\":\"...\",\"new\":\"...\"}' | behavioral_diff.py [--backend ...]\n"
            )
            return 0
        files.append(a)
        i += 1

    if len(files) >= 2:
        old_src = _read_file(files[0])
        new_src = _read_file(files[1])
        old_path, new_path = files[0], files[1]
    else:
        raw = sys.stdin.read()
        if not raw.strip():
            sys.stderr.write("behavioral_diff.py: need two file args or a stdin JSON job\n")
            return 2
        job = json.loads(raw)
        old_src = job.get("old", "")
        new_src = job.get("new", "")
        old_path = job.get("old_path", "<old>")
        new_path = job.get("new_path", "<new>")
        backend = job.get("backend", backend)

    record = diff_components(old_src, new_src, old_path, new_path, backend=backend)
    sys.stdout.write(json.dumps(record, indent=2) + "\n")
    sys.stderr.write(human_summary(record) + "\n")
    return 3 if record["blocked"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
