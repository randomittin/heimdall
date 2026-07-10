#!/usr/bin/env python3
# reference.py — the INDEPENDENT reference fold for the symbol-reuse differential oracle.
#
# INDEPENDENCE (differential integrity). This module imports NOTHING from bin/lib/* — every
# rule below is HAND-REPRODUCED from evals/oracles/symbol-reuse/INVARIANTS.md, so it shares no
# code path with the implementation under test (bin/lib/redum.detect_symbol_reuse). The impl
# author and this reference author are disjoint; differential.py (the neutral gate wiring)
# imports BOTH and diffs them, so oracle independence holds by construction. An acceptance grep
# enforces independence over IMPORT lines only (comments describe it, so scan imports, not prose):
#   ! grep -nE '^(import|from)[[:space:]]' reference.py | grep -qE 'redum|dedup|reuse_analyzer|bin/lib'
#
# WHAT IT COMPUTES. The SAME classification partition redum's cross-project symbol-reuse
# detector produces, recomputed from first principles over a stream of symbol declarations:
#   {"blocked": [...], "advised": [...], "ok": [...]}   (SR-A..SR-H in INVARIANTS.md §3)
# per the pipeline:
#   symbol in a test/fixture/vendored/generated path -> DROPPED  (SR-A, in no bucket)
#   symbol carries the opt-out marker                -> ok       (SR-B, allowed)
#   exact function dup (name+sig, diff module)        -> blocked  (SR-C)
#   exact type dup (name+fields, diff module)         -> blocked  (SR-D)
#   structural type (same fields, diff name)          -> advised  (SR-E)
#   same-name function (diff sig) / const re-def      -> advised  (SR-F/SR-G)
#   else                                              -> ok       (SR-H, unique)

from __future__ import annotations

import hashlib
import re

# ── constants hand-copied from INVARIANTS.md (never imported) ─────────────────

# §2 — symbol families. A function never dedups against a type.
_FN_KINDS = frozenset({"function", "shell-function", "method"})
_TYPE_KINDS = frozenset({"type", "class", "interface", "enum", "component"})
_CONST_KINDS = frozenset({"const"})

# §1 — the SHARED ignore set (reproduced from reuse.is_test_path + redum's vendor/generated
# regexes): test / spec / fixture dirs + vendored + generated trees are NOT canonical surface.
_IGNORE_DIR_RX = re.compile(
    r"(^|/)(tests?|__tests__|spec|specs|fixtures?|testdata|conformance|e2e|"
    r"node_modules|bower_components|vendor|vendored|third[_-]?party|external|"
    r"\.venv|venv|site-packages|dist|build|out|target|generated|__generated__|\.gen)(/|$)")
_IGNORE_FILE_RX = re.compile(
    r"^(test[_\-].*|.*[_\-]test|.*\.test|.*\.spec|.*\.fixture|conftest|test-.*)$")
_GENERATED_FILE_RX = re.compile(
    r"(\.generated\.[A-Za-z0-9]+$|_generated\.[A-Za-z0-9]+$|_pb2\.py$|\.pb\.go$|"
    r"\.g\.dart$|\.min\.js$|\.bundle\.js$)")

# §2 — the opt-out marker (a deliberate, justified local copy is allowed).
_OPTOUT_RX = re.compile(
    r"redum[\s:_\-]*allow[\s_\-]*(?:duplicate|local[\s_\-]*copy)", re.I)


# ── the rule reproduction (INVARIANTS.md §3, hand-authored) ───────────────────


def _basename(path):
    return str(path).replace("\\", "/").rsplit("/", 1)[-1]


def _stem(base):
    return base.rsplit(".", 1)[0] if "." in base else base


def is_ignored(path):
    """SR-A — a path whose symbols are not the project's canonical reuse surface."""
    norm = str(path).replace("\\", "/")
    if _IGNORE_DIR_RX.search(norm):
        return True
    base = _basename(norm).lower()
    if _IGNORE_FILE_RX.match(base) or _IGNORE_FILE_RX.match(_stem(base)):
        return True
    return bool(_GENERATED_FILE_RX.search(norm))


def normalize(name):
    """Canonical symbol-name key (redum/dedup semantics): strip _/- and lowercase."""
    return re.sub(r"[_\-]", "", str(name)).lower()


def family(kind):
    if kind in _FN_KINDS:
        return "function"
    if kind in _TYPE_KINDS:
        return "type"
    if kind in _CONST_KINDS:
        return "const"
    return "other"


def fn_shape(params):
    return "(" + ",".join(params or []) + ")"


def type_shape(fields):
    return "{" + ",".join(sorted(fields or [])) + "}"


def _tag(sym):
    return "%s@%s" % (sym["name"], sym["module"])


def _has_optout(sym):
    if sym.get("optout"):
        return True
    return bool(_OPTOUT_RX.search(str(sym.get("marker") or "")))


def _pick(cands, proposed):
    """Deterministic canonical pick: smallest (module, name) in a DIFFERENT module."""
    xs = sorted((c for c in cands if c["module"] != proposed["module"]),
                key=lambda c: (str(c["module"]), str(c["name"])))
    return xs[0] if xs else None


def _classify(proposed, by_norm, type_by_shape):
    """Return (bucket, klass, canonical) for one proposed symbol, or None when unique.
    bucket in {"block","warn"}. Precedence matches redum: exact-block > structural/near/
    const advise > unique."""
    fam = family(proposed["kind"])
    nn = normalize(proposed["name"])
    same_name = by_norm.get(nn, [])

    if fam == "function":
        exact = _pick([c for c in same_name if family(c["kind"]) == "function"
                       and fn_shape(c.get("params")) == fn_shape(proposed.get("params"))],
                      proposed)
        if exact is not None:
            return "block", "exact-function", exact
        near = _pick([c for c in same_name if family(c["kind"]) == "function"], proposed)
        if near is not None:
            return "warn", "same-name-function", near
        return None

    if fam == "type":
        exact = _pick([c for c in same_name if family(c["kind"]) == "type"
                       and c.get("fields") and proposed.get("fields")
                       and type_shape(c["fields"]) == type_shape(proposed["fields"])],
                      proposed)
        if exact is not None:
            return "block", "exact-type", exact
        if proposed.get("fields"):
            struct = _pick([c for c in type_by_shape.get(type_shape(proposed["fields"]), [])
                            if family(c["kind"]) == "type"], proposed)
            if struct is not None:
                return "warn", "structural-type", struct
        same_type = _pick([c for c in same_name if family(c["kind"]) == "type"], proposed)
        if same_type is not None:
            return "warn", "same-name-type", same_type
        return None

    if fam == "const":
        c = _pick([c for c in same_name if family(c["kind"]) == "const"], proposed)
        if c is not None:
            return "warn", "const-redef", c
        return None

    return None


def fold(stream):
    """Fold a stream {"canonical":[...], "proposed":[...]} into the reference classification
    partition (the truth half of the differential). Returns {"blocked","advised","ok"} of sorted
    rows. A block/advise row is [proposed_tag, class, canonical_tag]; an ok row is proposed_tag."""
    canon = [c for c in (stream.get("canonical") or []) if not is_ignored(c["module"])]
    by_norm = {}
    type_by_shape = {}
    for c in canon:
        by_norm.setdefault(normalize(c["name"]), []).append(c)
        if family(c["kind"]) == "type" and c.get("fields"):
            type_by_shape.setdefault(type_shape(c["fields"]), []).append(c)

    blocked, advised, ok = [], [], []
    for p in (stream.get("proposed") or []):
        if is_ignored(p["module"]):          # SR-A — dropped from every bucket
            continue
        if _has_optout(p):                   # SR-B — deliberate local copy allowed
            ok.append(_tag(p))
            continue
        verdict = _classify(p, by_norm, type_by_shape)
        if verdict is None:                  # SR-H — unique
            ok.append(_tag(p))
            continue
        bucket, klass, canonical = verdict
        row = [_tag(p), klass, _tag(canonical)]
        (blocked if bucket == "block" else advised).append(row)

    return {
        "blocked": sorted(blocked),
        "advised": sorted(advised),
        "ok": sorted(ok),
    }


# ── deterministic seeded stream generator (the seeded-differential arm) ───────


def _seeded_int(seed, *parts):
    h = hashlib.sha256(("|".join([str(seed)] + [str(p) for p in parts])).encode()).hexdigest()
    return int(h[:8], 16)


# the eight class templates the stream cycles through (one per proposed symbol). Fixed structure
# so EVERY seed exercises blocked + advised + ok + dropped; the seed only varies identifiers.
_CLASSES = (
    "exact-function", "exact-type", "structural-type", "same-name-function",
    "const-redef", "unique", "optout-dup", "ignored-dup",
)
_IGNORED_DIRS = ("tests/test_%02d.py", "vendor/lib_%02d.py", "gen_%02d.generated.py")


def generate_stream(seed, records=24):
    """Produce a deterministic symbol-declaration stream for `seed`: `records` cases cycling the
    eight class templates. Same seed => byte-identical stream. Each case emits a proposed symbol
    (and, for the non-unique classes, the canonical it should route to). The distribution is fixed
    so the impl fold and this reference fold MUST agree on blocked/advised/ok every seed."""
    canonical, proposed = [], []
    for i in range(records):
        cls = _CLASSES[i % len(_CLASSES)]
        tok = "%02x%02d" % (_seeded_int(seed, "tok", i) % 256, i)  # unique per case, seed-varied
        cmod = "src/canon/c_%s.py" % tok
        pmod = "src/feat/p_%s.py" % tok

        if cls == "exact-function":
            canonical.append({"module": cmod, "name": "fn_%s" % tok, "kind": "function",
                              "params": ["a", "b"]})
            proposed.append({"module": pmod, "name": "fn_%s" % tok, "kind": "function",
                             "params": ["a", "b"]})
        elif cls == "exact-type":
            canonical.append({"module": cmod, "name": "T_%s" % tok, "kind": "type",
                              "fields": ["id", "name"]})
            proposed.append({"module": pmod, "name": "T_%s" % tok, "kind": "type",
                             "fields": ["id", "name"]})
        elif cls == "structural-type":
            fields = ["fa_%s" % tok, "fb_%s" % tok]   # unique shape per case
            canonical.append({"module": cmod, "name": "Src_%s" % tok, "kind": "type",
                              "fields": fields})
            proposed.append({"module": pmod, "name": "Dup_%s" % tok, "kind": "type",
                             "fields": list(fields)})
        elif cls == "same-name-function":
            canonical.append({"module": cmod, "name": "g_%s" % tok, "kind": "function",
                              "params": ["a"]})
            proposed.append({"module": pmod, "name": "g_%s" % tok, "kind": "function",
                             "params": ["a", "b", "c"]})   # same name, DIFFERENT signature
        elif cls == "const-redef":
            canonical.append({"module": cmod, "name": "K_%s" % tok, "kind": "const",
                              "value": str(_seeded_int(seed, "kv", i) % 1000)})
            proposed.append({"module": pmod, "name": "K_%s" % tok, "kind": "const",
                             "value": str(_seeded_int(seed, "kv2", i) % 1000)})
        elif cls == "unique":
            proposed.append({"module": pmod, "name": "uniq_%s" % tok, "kind": "function",
                             "params": ["z"]})
        elif cls == "optout-dup":
            canonical.append({"module": cmod, "name": "o_%s" % tok, "kind": "function",
                              "params": ["a", "b"]})
            proposed.append({"module": pmod, "name": "o_%s" % tok, "kind": "function",
                             "params": ["a", "b"], "optout": True})
        elif cls == "ignored-dup":
            canonical.append({"module": cmod, "name": "ig_%s" % tok, "kind": "function",
                              "params": ["a", "b"]})
            imod = _IGNORED_DIRS[i % len(_IGNORED_DIRS)] % i
            proposed.append({"module": imod, "name": "ig_%s" % tok, "kind": "function",
                             "params": ["a", "b"]})
    return {"canonical": canonical, "proposed": proposed}
