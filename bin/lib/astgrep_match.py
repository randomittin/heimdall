#!/usr/bin/env python3
# astgrep_match.py — DEMAND-DRIVEN ast-grep structural matcher for the dedup core.
#
# WHY THIS EXISTS (demand-driven, not speculative): the tree-sitter symbol map in
# bin/lib/dedup.py answers name+kind dedup ("is there an existing `selectCards`?").
# That covers the overwhelming majority of Redum's cases. But ONE case genuinely
# needs STRUCTURAL shape-matching beyond a name compare: a reinvention that RENAMES
# the identifier but keeps the BODY shape (the commander.js class — the agent
# rewrote the mandatory-option *logic* under a fresh name instead of calling
# `makeOptionMandatory`). A name match alone gives that a weak "near-name" score;
# a STRUCTURAL match of the body confirms it is the same shape and promotes it to
# a high-confidence dedup candidate.
#
# So this matcher is consulted ONLY to DISAMBIGUATE/CONFIRM a body-shape match for
# an already-named candidate — it never invents candidates from structure alone
# (that would risk the premature-abstraction failure mode F3's spec warns against).
#
# GRACEFUL DEGRADATION (mandatory Heimdall pattern): ast-grep is an OPTIONAL
# external binary. `available()` probes for it once. Every public call returns an
# empty/neutral result when ast-grep is absent so the dedup core falls back to the
# tree-sitter symbol matcher WITHOUT crashing or blocking a commit. No ast-grep =
# name/kind matching only, which is the documented, sufficient default.

from __future__ import annotations

import json
import re
import shutil
import subprocess

_STATE = {"checked": False, "bin": None}


def available():
    """True iff the `ast-grep` (or `sg`) binary is on PATH. Probed once, cached.
    When False the dedup core uses the tree-sitter symbol matcher alone."""
    if _STATE["checked"]:
        return _STATE["bin"] is not None
    _STATE["checked"] = True
    for cand in ("ast-grep", "sg"):
        path = shutil.which(cand)
        if path:
            # `sg` collides with a common util on some hosts; confirm it's ast-grep.
            if cand == "sg":
                try:
                    out = subprocess.run([path, "--version"], capture_output=True,
                                         timeout=5, text=True)
                    if "ast-grep" not in (out.stdout + out.stderr).lower():
                        continue
                except Exception:  # noqa: BLE001
                    continue
            _STATE["bin"] = path
            return True
    _STATE["bin"] = None
    return False


def _binary():
    return _STATE["bin"]


# ast-grep language ids keyed by the dedup core's language tags.
_LANG = {"js": "tsx", "py": "python"}


def _structural_signature(src):
    """Reduce a unit BODY to a structural signature: the ordered sequence of
    syntactic operations, with identifiers/strings/numbers ABSTRACTED away. Two
    bodies with the same signature are the same SHAPE under different names — the
    renamed-reinvention case.

    We keep control-flow + call STRUCTURE and drop the names so `function a(){
    if(x) return f(x); }` and `function b(){ if(y) return g(y); }` share a
    signature (same shape, different identifiers). Literals collapse to S (string)
    / N (number); non-keyword identifiers collapse to I."""
    s = re.sub(r"//[^\n]*", " ", src)
    s = re.sub(r"/\*.*?\*/", " ", s, flags=re.S)
    s = re.sub(r"#[^\n]*", " ", s)
    s = re.sub(r"""(['"]).*?\1""", "S", s, flags=re.S)
    s = re.sub(r"\b\d+(\.\d+)?\b", "N", s)
    # keep structural keywords; abstract every other identifier to "I".
    keywords = {
        "if", "else", "for", "while", "return", "function", "const", "let", "var",
        "class", "new", "throw", "try", "catch", "switch", "case", "break",
        "continue", "def", "elif", "import", "from", "this", "self", "yield",
        "await", "async",
    }
    tokens = re.findall(r"[A-Za-z_$][\w$]*|[(){}\[\];,.=<>+\-*/!&|?:]+|S|N", s)
    out = []
    for t in tokens:
        if re.match(r"^[A-Za-z_$]", t):
            out.append(t if t in keywords else "I")
        else:
            out.append(t)
    return " ".join(out)


def structural_matches(shape_src, candidate_names, index):
    """Return the subset of `candidate_names` whose INDEXED unit body is a
    structural match for `shape_src`. Each candidate unit's body is sliced from
    its source by span, then compared by structural signature.

    `index` is the list[ReuseUnit] (carries file + span for each candidate). This
    function reads each candidate's file to slice its body — it only runs when
    ast-grep confirmed-available, so it never adds a dependency to the default path.

    Returns a set of names. Empty on any failure (caller degrades to name match)."""
    if not available():
        return set()
    want = set(candidate_names)
    by_name = {}
    for u in index:
        if u.name in want and u.span and u.file:
            by_name.setdefault(u.name, u)
    if not by_name:
        return set()

    shape_sig = _structural_signature(shape_src)
    if not shape_sig.strip():
        return set()

    confirmed = set()
    file_cache = {}
    for name, u in by_name.items():
        body = _slice_body(u, file_cache)
        if body is None:
            continue
        cand_sig = _structural_signature(body)
        if _sig_similar(shape_sig, cand_sig):
            confirmed.add(name)
    return confirmed


def _slice_body(unit, file_cache):
    """Read the unit's file (cached) and return its body source by span, or None."""
    path = unit.file
    if path not in file_cache:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                file_cache[path] = fh.read().splitlines()
        except OSError:
            file_cache[path] = None
    lines = file_cache[path]
    if not lines:
        return None
    a, b = unit.span
    if a < 1 or b > len(lines) or a > b:
        return None
    return "\n".join(lines[a - 1:b])


def run_pattern(pattern, lang, src):
    """Run a raw ast-grep structural pattern against `src`, returning the list of
    match dicts ast-grep emits (JSON). Empty list on any failure / absence. This
    is the thin, reusable ast-grep entrypoint (F2's max-tier may call it directly
    for a custom cross-author structural query)."""
    if not available():
        return []
    aglang = _LANG.get(lang, lang)
    try:
        proc = subprocess.run(
            [_binary(), "run", "--pattern", pattern, "--lang", aglang,
             "--json=stream", "--stdin"],
            input=src, capture_output=True, text=True, timeout=20,
        )
    except Exception:  # noqa: BLE001 — any subprocess failure → degrade
        return []
    matches = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            matches.append(json.loads(line))
        except Exception:  # noqa: BLE001
            continue
    return matches


def _sig_similar(a, b):
    """Two structural signatures are 'similar' when their token skeletons match
    closely: exact equality, OR a high token-overlap ratio (>= 0.85) over equal-
    ish lengths. Conservative by design — a false structural match would over-
    flag; we only confirm clear same-shape bodies."""
    if a == b:
        return True
    ta, tb = a.split(), b.split()
    if not ta or not tb:
        return False
    if abs(len(ta) - len(tb)) > max(2, 0.2 * max(len(ta), len(tb))):
        return False
    common = _lcs_len(ta, tb)
    ratio = common / max(len(ta), len(tb))
    return ratio >= 0.85


def _lcs_len(a, b):
    """Length of the longest common subsequence of two token lists (DP, O(n*m));
    token lists here are unit-body-sized so this is cheap."""
    prev = [0] * (len(b) + 1)
    for x in a:
        cur = [0]
        for j, y in enumerate(b, 1):
            if x == y:
                cur.append(prev[j - 1] + 1)
            else:
                cur.append(max(prev[j], cur[j - 1]))
        prev = cur
    return prev[-1]


if __name__ == "__main__":
    print(json.dumps({
        "available": available(),
        "binary": _binary(),
    }, indent=2))
    raise SystemExit(0)
