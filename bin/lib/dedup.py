#!/usr/bin/env python3
# dedup.py — the SHARED dedup-candidate core (F3 Redum builds on it; F2 Checker's
# max-tier (Wave 3b) FUSES onto it — one machinery, not two copies).
#
# THE ONE QUESTION this module answers:
#   "Given a code shape (a name + kind, an RN reuse-unit, or a raw symbol), what
#    EXISTING repo code already provides it?"  → a ranked list of dedup candidates.
#
# It is the matcher under BOTH:
#   • F3 Redum plan-time factoring — "what should this task reuse?" (surface
#     candidates to the planner so the agent reuses by design, not luck).
#   • F3 Redum commit-time gate    — "did this change re-add a shape the repo
#     already had?" (a residual-redundancy backstop).
#   • F2 Checker max-tier          — "did a DIFFERENT author write a semantically-
#     equivalent unit?" (cross-author semantic dedup). F2 calls the SAME
#     `match_candidates` / `index_repo_units` with an author-aware filter — see
#     the FUSION INTERFACE block at the bottom.
#
# IT DOES NOT RE-MEASURE REUSE. The S-6 reuse percentage + suspected_duplicates
# live in the SI-2 attestation `reuse` field (bin/heimdall-attest → reuse_analyzer).
# This module is the *matcher* that finds reusable shapes; Redum READS SI-2's
# reuse field for the residual-redundancy verdict and uses this matcher to NAME
# the existing unit the agent should have reused.
#
# DETECTION SUBSTRATE (priority, all on the tree-sitter foundation):
#   1. tree-sitter symbol map (bin/lib/treesitter_ast.extract) — the PRIMARY,
#      AST-accurate symbol/kind/span surface. Always available as a matcher.
#   2. RN/MMKV reuse-unit detector (rn_units below) — slices, selectors, MMKV
#      keys: the React-Native-specific reuse units a plain symbol map misses.
#   3. ast-grep STRUCTURAL matcher (bin/lib/astgrep_match, DEMAND-DRIVEN) — only
#      consulted when a shape needs *structural* (pattern) matching beyond a name/
#      kind comparison, and only when ast-grep is installed. Graceful-degrades to
#      the tree-sitter symbol matcher when ast-grep is absent (never crashes,
#      never blocks).
#
# This is a LIBRARY (pure functions over source text). No git, no I/O beyond the
# optional ast-grep subprocess in astgrep_match. The callers (bin/heimdall-redum,
# bin/lib/redum.py, F2's max-tier) own the git extraction.

from __future__ import annotations

import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import treesitter_ast as ts  # noqa: E402 — sibling import after sys.path setup
import reuse_analyzer as reuse  # noqa: E402 — reuse its language detect + heuristic


# ── reuse-unit value type ─────────────────────────────────────────────────────


class ReuseUnit:
    """A reusable shape the repo exposes (a symbol the matcher can dedup against).

      name   — the canonical identifier a caller would reuse (a function name, a
               selector name, the MMKV key string, a slice name).
      kind   — the unit kind, stable across languages + RN concepts:
                 function | method | class | component | interface | enum | type |
                 const | rn-slice | rn-selector | mmkv-key
      file   — the file the unit is defined in (so a candidate names WHERE to reuse).
      span   — (start_line, end_line) 1-based inclusive, or None for non-AST units.
      lang   — the canonical language id, or None.
      detail — small structured extras (slice name a selector belongs to, the raw
               MMKV key literal, the author when known for F2's cross-author pass).
    """

    __slots__ = ("name", "kind", "file", "span", "lang", "detail")

    def __init__(self, name, kind, file, span=None, lang=None, detail=None):
        self.name = name
        self.kind = kind
        self.file = file
        self.span = tuple(span) if span else None
        self.lang = lang
        self.detail = detail or {}

    def to_dict(self):
        d = {
            "name": self.name,
            "kind": self.kind,
            "file": self.file,
            "lang": self.lang,
        }
        if self.span:
            d["span"] = list(self.span)
        if self.detail:
            d["detail"] = self.detail
        return d

    def __repr__(self):
        return "ReuseUnit(%s %s @%s)" % (self.kind, self.name, self.file)


# ── name normalization (shared with reuse_analyzer's semantics) ───────────────


def normalize(name):
    """Canonicalize a symbol name for shape comparison: strip separators, lower.
    `makeOptionMandatory` and `make_option_mandatory` normalize to the same key,
    so a snake_case reinvention of a camelCase repo helper still matches."""
    return re.sub(r"[_\-]", "", str(name)).lower()


def near(a, b):
    """True if two names are identical-or-near (normalized equality, or a small
    Levenshtein distance on names >= 4 chars). Delegates to the reuse_analyzer's
    `_near` so the dedup matcher and the S-6 reinvention detector agree on what
    'near-duplicate name' means (one definition, not two)."""
    return reuse._near(a, b)  # noqa: SLF001 — intentional shared-semantics reuse


# ── RN / MMKV reuse-unit detection ────────────────────────────────────────────
#
# React-Native + MMKV introduce reuse units a plain symbol map does not name:
#
#   • SLICE     — a Redux-Toolkit slice: `createSlice({ name: "cards", ... })`.
#                 The slice NAME is the reuse unit (a second `createSlice` with the
#                 same name duplicates the store domain).
#   • SELECTOR  — a memoized/derived read: `export const selectCards = ...`,
#                 `createSelector(...)`, or any `const selectX = (state) => ...`.
#                 The selector NAME is the reuse unit (a new `selectCards` that
#                 re-derives what an existing `selectCards` already returns is a dup).
#   • MMKV-KEY  — a storage key STRING: `storage.set("cards.cache", v)`,
#                 `MMKV_KEYS.cards = "cards.cache"`, `const CARDS_KEY = "cards.cache"`.
#                 The key STRING is the reuse unit (two writers using two different
#                 constants for the SAME string, OR two constants holding the same
#                 string, both duplicate a single source-of-truth key).
#
# These are detected on the tree-sitter AST when available (precise spans), with a
# regex fallback so detection still works on a host without tree-sitter (the
# Heimdall degradation pattern). The regexes key on the STABLE RN/MMKV API shapes.

# createSlice({ name: "<slice>" ... })  — capture the slice name literal.
_RN_SLICE = re.compile(
    r"createSlice\s*\(\s*\{[^}]*?\bname\s*:\s*['\"]([A-Za-z0-9_\-]+)['\"]",
    re.S,
)
# selector consts: `const selectX = ...` / `export const selectX = ...`. The RN
# convention is a `select`-prefixed const; createSelector(...) on the RHS is a
# strong memoized-selector signal but the name is what we dedup on.
_RN_SELECTOR = re.compile(
    r"\b(?:export\s+)?const\s+(select[A-Z][A-Za-z0-9_]*)\s*=",
)
# MMKV / storage key WRITES + named key constants. Shapes detected:
#   storage.set("<key>", ...) / mmkv.set('<key>', ...)  — a write to a literal key
#   const X_KEY = "<key>"                                — a KEY-named const
#   const ANYNAME = "<dotted.or:namespaced.key>"         — ANY const holding a
#       storage-key-SHAPED string (a dotted/namespaced literal). This is what
#       makes the dedup core catch the canonical card-data reinvention: a second
#       const (e.g. CARD_CACHE = "cards.cache.v1") holding the SAME key string as
#       the existing CARDS_CACHE_KEY, even though its NAME doesn't contain "KEY".
#       The reuse unit is the STRING, so two consts with the same value collide.
#   X: "<key>" inside a *_KEYS map                       — a mapped key entry
_MMKV_SET = re.compile(
    r"\b(?:storage|mmkv|MMKV)\w*\s*\.\s*(?:set|getString|getNumber|getBoolean|delete)\s*"
    r"\(\s*['\"]([A-Za-z0-9_.\-:]+)['\"]",
)
# KEY/KEYS-named const → always a key, value captured verbatim.
_MMKV_KEY_CONST = re.compile(
    r"\b(?:export\s+)?const\s+([A-Z][A-Z0-9_]*(?:KEY|KEYS)[A-Z0-9_]*)\s*=\s*['\"]([A-Za-z0-9_.\-:]+)['\"]",
)
# ANY const whose VALUE is a storage-key-shaped literal: a dotted or colon-
# namespaced string (at least one '.'/':' separator, e.g. "cards.cache.v1",
# "user:token"). The separator requirement keeps this from flagging ordinary
# strings — a bare "hello" is not a key, but "cards.cache.v1" is the storage slot.
_MMKV_KEY_LITERAL_CONST = re.compile(
    r"\b(?:export\s+)?const\s+([A-Za-z_$][\w$]*)\s*=\s*['\"]([A-Za-z0-9_\-]+(?:[.:][A-Za-z0-9_\-]+)+)['\"]",
)
# a key entry inside a `*_KEYS = { ... }` map: `cards: "cards.cache"`.
_MMKV_KEY_MAP_ENTRY = re.compile(
    r"\b([A-Za-z0-9_]+)\s*:\s*['\"]([A-Za-z0-9_.\-:]+)['\"]",
)
_MMKV_KEYS_MAP = re.compile(
    r"\b(?:export\s+)?const\s+([A-Za-z0-9_]*(?:KEYS|Keys)[A-Za-z0-9_]*)\s*=\s*\{",
)


def _line_of(src, idx):
    """1-based line number of character offset `idx` in `src`."""
    return src.count("\n", 0, idx) + 1


def rn_units(src, path):
    """Detect RN/MMKV reuse units (slices, selectors, MMKV keys) in `src`.
    Returns list[ReuseUnit]. Only meaningful for JS/TS files; returns [] otherwise.

    This is the RN/MMKV-AWARE layer the spec calls for: it lets the dedup core
    know a new `selectCards` duplicates an existing one, or that two constants
    hold the SAME MMKV key string (one source of truth, duplicated)."""
    lang = reuse.detect_language(path)
    if lang != "js":
        return []
    out = []
    seen = set()

    def add(name, kind, idx, detail=None):
        key = (kind, name, detail.get("key") if detail else None)
        if key in seen:
            return
        seen.add(key)
        out.append(ReuseUnit(name, kind, path, span=(_line_of(src, idx), _line_of(src, idx)),
                             lang="js", detail=detail or {}))

    for m in _RN_SLICE.finditer(src):
        add(m.group(1), "rn-slice", m.start(), {"slice": m.group(1)})
    for m in _RN_SELECTOR.finditer(src):
        add(m.group(1), "rn-selector", m.start(), {})
    # MMKV key writes: the reuse unit is the KEY STRING (so two different writers
    # of the same string collapse to one unit the dedup core can flag).
    for m in _MMKV_SET.finditer(src):
        add(m.group(1), "mmkv-key", m.start(), {"key": m.group(1), "source": "write"})
    for m in _MMKV_KEY_CONST.finditer(src):
        # both the CONST NAME and the KEY STRING matter: dedup on the string so a
        # second const holding the same string is caught.
        add(m.group(2), "mmkv-key", m.start(),
            {"key": m.group(2), "const": m.group(1), "source": "const"})
    # any const holding a storage-key-shaped (dotted/namespaced) string — catches
    # a duplicate key under a const whose NAME doesn't contain "KEY".
    for m in _MMKV_KEY_LITERAL_CONST.finditer(src):
        add(m.group(2), "mmkv-key", m.start(),
            {"key": m.group(2), "const": m.group(1), "source": "const-literal"})
    # entries inside a *_KEYS = { ... } map.
    for mm in _MMKV_KEYS_MAP.finditer(src):
        brace = src.find("{", mm.end() - 1)
        if brace == -1:
            continue
        depth = 0
        i = brace
        end = len(src)
        while i < len(src):
            c = src[i]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    end = i
                    break
            i += 1
        block = src[brace:end]
        for em in _MMKV_KEY_MAP_ENTRY.finditer(block):
            add(em.group(2), "mmkv-key", brace + em.start(),
                {"key": em.group(2), "map": mm.group(1), "entry": em.group(1),
                 "source": "map"})
    return out


# ── repo unit index (tree-sitter symbols + RN/MMKV units) ─────────────────────


def index_repo_units(files, include_rn=True, author=None):
    """Build the dedup index over a set of repo files.

    files: dict {path: source} — the files to index (e.g. the PRE-change repo for
    plan-time factoring, or the OTHER side's units for F2 cross-author dedup).
    include_rn: also index RN/MMKV reuse units (slices/selectors/MMKV keys).
    author: if given, stamp every unit's detail with this author (F2 fusion: index
            each author's units separately so a later match can require a
            DIFFERENT author — cross-author semantic dedup).

    Returns list[ReuseUnit]. Test/fixture files are EXCLUDED (mirrors the reuse
    analyzer's scoping: a fixture symbol is not pre-existing PRODUCTION code to
    reuse). Uses tree-sitter symbols when available, the heuristic unit extractor
    otherwise — never crashes on a missing grammar."""
    units = []
    for path, src in files.items():
        if reuse.is_test_path(path):
            continue
        lang = reuse.detect_language(path)
        if lang is None:
            continue
        units.extend(_symbols_for(src, path, lang, author))
        if include_rn:
            for ru in rn_units(src, path):
                if author is not None:
                    ru.detail["author"] = author
                units.append(ru)
    return units


def _symbols_for(src, path, lang, author):
    """Extract named symbol reuse units from one file. Prefers tree-sitter symbols
    (AST kinds + spans); falls back to the reuse analyzer's heuristic units when a
    grammar is unavailable."""
    out = []
    tslang = None
    if ts.backend_available():
        tslang = ts.lang_for_path(path) if lang == "js" else (
            "python" if lang == "py" else None
        )
    if tslang is not None:
        res = ts.extract(src, tslang)
        if res.available:
            for s in res.symbols:
                d = {"author": author} if author is not None else {}
                out.append(ReuseUnit(s.name, s.kind, path, span=s.span,
                                     lang=lang, detail=d))
            return out
    # heuristic fallback (shell, or grammar missing): the reuse analyzer's units.
    try:
        hunits, _mod, _used = reuse.extract_units(src, lang, path, "heuristic")
    except Exception:  # noqa: BLE001 — never let one bad file abort the index
        hunits = None
    if hunits:
        for u in hunits:
            d = {"author": author} if author is not None else {}
            out.append(ReuseUnit(u.name, "unit", path, span=None, lang=lang, detail=d))
    return out


# ── the matcher: find existing units matching a shape ─────────────────────────


def match_candidates(shape, index, structural_src=None, max_results=5,
                     different_author_than=None):
    """THE CORE: given a `shape` (a name string OR a ReuseUnit), return the ranked
    existing units in `index` that the shape DUPLICATES / SHOULD REUSE.

    shape: a str name, or a ReuseUnit (name+kind, used for kind-aware ranking and
           RN/MMKV exact-key matching).
    index: list[ReuseUnit] from index_repo_units (the existing repo surface).
    structural_src: optional source text of the shape's unit. When provided AND
           ast-grep is available, a STRUCTURAL match is attempted (demand-driven —
           only consulted to disambiguate a same-shape body). Absent ast-grep,
           this argument is ignored (graceful degrade to the name/kind matcher).
    max_results: cap the returned candidates.
    different_author_than: F2 fusion hook — when set, only candidates whose
           detail.author differs are returned (cross-author semantic dedup). For
           F3's own use this is None (any author).

    Returns list[{unit: dict, score: float, reason: str, match: str}] sorted by
    score desc. score in (0,1]; 1.0 = exact-key / exact-name same-kind match."""
    name = shape.name if isinstance(shape, ReuseUnit) else str(shape)
    kind = shape.kind if isinstance(shape, ReuseUnit) else None
    shape_key = shape.detail.get("key") if isinstance(shape, ReuseUnit) else None
    nn = normalize(name)

    results = []
    for u in index:
        if different_author_than is not None:
            if u.detail.get("author") == different_author_than:
                continue
        score, reason, match = _score_pair(nn, name, kind, shape_key, u)
        if score <= 0:
            continue
        results.append({"unit": u.to_dict(), "score": round(score, 4),
                        "reason": reason, "match": match})

    # optional structural disambiguation: only when a body was supplied AND
    # ast-grep is present. It BOOSTS a name/kind candidate whose body structurally
    # matches the shape's body, turning a "near-name" into a "confirmed shape".
    if structural_src and results:
        results = _structural_boost(structural_src, results, index)

    results.sort(key=lambda r: (-r["score"], r["unit"]["name"]))
    return results[:max_results]


def _score_pair(nn, name, kind, shape_key, u):
    """Score one (shape, candidate-unit) pair. Returns (score, reason, match-type).
    Higher is a stronger dedup signal."""
    # RN/MMKV exact-key match is the strongest signal: two units carrying the SAME
    # MMKV key string are the same storage slot regardless of const name.
    if shape_key and u.detail.get("key") == shape_key:
        return 1.0, "same MMKV key string %r" % shape_key, "mmkv-key-exact"
    un = normalize(u.name)
    # exact normalized name + compatible kind.
    if un == nn:
        if kind and u.kind and kind == u.kind:
            return 1.0, "exact name + kind %r" % kind, "name-kind-exact"
        return 0.92, "exact normalized name %r" % name, "name-exact"
    # near name (edit-distance) — a likely reinvention with a renamed identifier.
    if near(name, u.name):
        return 0.7, "near-duplicate name (%s ~ %s)" % (name, u.name), "name-near"
    return 0.0, "", ""


# ── ast-grep structural matcher (DEMAND-DRIVEN, graceful-degrade) ─────────────


def _structural_boost(structural_src, results, index):
    """When ast-grep is available, confirm/boost name candidates whose BODY
    structurally matches. Demand-driven: imported lazily; if ast-grep is absent
    the function returns `results` unchanged (the name/kind matcher stands alone).

    The boost is conservative: it only RAISES the score of an already-named
    candidate when a structural body match is found — it never invents a new
    candidate from structure alone (avoids the premature-abstraction failure mode
    the spec warns about)."""
    try:
        import astgrep_match as asg  # noqa: WPS433 — lazy by design
    except Exception:  # noqa: BLE001
        return results
    if not asg.available():
        return results
    by_name = {r["unit"]["name"]: r for r in results}
    try:
        confirmed = asg.structural_matches(structural_src, by_name.keys(), index)
    except Exception:  # noqa: BLE001 — any ast-grep error → degrade to name match
        return results
    for nm in confirmed:
        r = by_name.get(nm)
        if r is not None and r["score"] < 1.0:
            r["score"] = min(1.0, r["score"] + 0.15)
            r["reason"] += " + structural-body-match"
            r["match"] = "structural"
    return results


# ── FUSION INTERFACE (F2 Checker max-tier, Wave 3b) ───────────────────────────
#
# F2's max-tier (cross-author semantic dedup) FUSES onto THIS module — one
# machinery, not two copies. The contract F2 consumes:
#
#   1. index_repo_units(files, include_rn=, author=AUTHOR)
#        F2 indexes each author's contributed units with their author tag. Call
#        once per author (e.g. group the diff's units by `git blame` author),
#        accumulating one combined index list.
#
#   2. match_candidates(shape, index, different_author_than=AUTHOR)
#        For each unit a given author added, F2 asks: does an existing unit by a
#        DIFFERENT author already provide this shape? A non-empty result IS a
#        cross-author semantic duplicate. F3 leaves different_author_than=None
#        (author-agnostic residual-redundancy); F2 sets it to the adding author.
#
#   3. ReuseUnit.detail["author"]
#        The author stamp index_repo_units writes and match_candidates filters on.
#        Both features share the SAME ReuseUnit type + the SAME scoring — F2 adds
#        ONLY the author filter, no second matcher.
#
#   4. rn_units(src, path)
#        F2 reuses the identical RN/MMKV reuse-unit detector so a cross-author
#        duplicate SELECTOR / MMKV key is caught with the same precision as F3's
#        residual-redundancy gate.
#
# Neither feature re-measures reuse: both read SI-2's reuse field for the S-6
# percentage + suspected_duplicates, and use THIS matcher only to NAME the
# existing unit that should have been reused. See F3.md › "Fusion interface".
