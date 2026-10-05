#!/usr/bin/env python3
"""fg_mutate: enumerate the Study B candidates, the single-site mutants of the frozen base.

The rules are PREREG.md section 5 (the operator table). Every site of every operator is mutated with
every listed replacement; nothing is chosen by hand. Comment lines are never mutated, and neither are
characters inside string literals or template text (only `${...}` expressions are code).

  fg_mutate.py enumerate --base FILE --out cases.json   write the enumerated, classified case set
  fg_mutate.py verify    --base FILE --cases cases.json re-enumerate and compare (exit 1 on any drift)
  fg_mutate.py show      --base FILE --id m-0007        print one candidate's source

Library use (the harness): candidate_sources(base_text) -> {case id: mutant source}.
"""
from __future__ import annotations

import argparse
import bisect
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

SCHEMA = "fg.cases/1"
OPERATORS = ("ROR", "NEG", "AOR", "CRP", "SDL", "AWD", "COND", "RVR", "IDR")

_AOR_SWAP = {"+": "-", "-": "+", "*": "/", "/": "*"}
_IDR_SWAP = {"event.id": "event.account", "event.account": "event.id", "account": "caller",
             "caller": "account", "net": "fee", "fee": "net"}
_STATEMENT_START = ("const ", "await ", "if (", "return ")
_BRACKETS = {"(": 1, "[": 1, "{": 1, ")": -1, "]": -1, "}": -1}


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def code_mask(line):
    """One bool per character: True where the character is code (not a comment, string or template text)."""
    mask = [True] * len(line)
    stack, depth = [], []
    i = 0
    while i < len(line):
        ch, top = line[i], (stack[-1] if stack else None)
        if top in ("'", '"', "`"):
            mask[i] = False
            if ch == "\\":
                if i + 1 < len(line):
                    mask[i + 1] = False
                i += 1
            elif ch == top:
                stack.pop()
            elif top == "`" and line.startswith("${", i):
                mask[i + 1] = False
                stack.append("expr")
                depth.append(0)
                i += 1
        else:
            if line.startswith("//", i):
                for j in range(i, len(line)):
                    mask[j] = False
                break
            if ch in "'\"`":
                mask[i] = False
                stack.append(ch)
            elif top == "expr" and ch == "{":
                depth[-1] += 1
            elif top == "expr" and ch == "}":
                if depth[-1] == 0:
                    mask[i] = False
                    stack.pop()
                    depth.pop()
                else:
                    depth[-1] -= 1
        i += 1
    return mask


class _Source:
    def __init__(self, text):
        self.text = text
        self.lines = text.splitlines(keepends=True)
        self.offsets = []
        total = 0
        for line in self.lines:
            self.offsets.append(total)
            total += len(line)
        self.offsets.append(total)
        self.masks = [code_mask(line.rstrip("\n")) for line in self.lines]

    def position(self, absolute):
        li = bisect.bisect_right(self.offsets, absolute) - 1
        return li + 1, absolute - self.offsets[li] + 1

    def matches(self, pattern):
        """Regex matches lying wholly in code, as (absolute start, end, text), in source order."""
        rx = re.compile(pattern)
        for li, line in enumerate(self.lines):
            for m in rx.finditer(line.rstrip("\n")):
                if all(self.masks[li][m.start():m.end()]):
                    yield self.offsets[li] + m.start(), self.offsets[li] + m.end(), m.group(0)


def _token_edits(src, pattern, alternatives):
    for start, end, token in src.matches(pattern):
        for alt in alternatives(token):
            yield start, end, alt


def _crp_alternatives(token):
    n = int(token)
    out = []
    for value in [n + 1] + ([n - 1] if n >= 1 else []) + [0, 1]:
        if value != n and str(value) not in out:
            out.append(str(value))
    return out


def _condition_edits(src):
    for start, end, _ in src.matches(r"\bif \("):
        depth, i = 1, end
        while i < len(src.text) and depth:
            li = bisect.bisect_right(src.offsets, i) - 1
            col = i - src.offsets[li]
            if col < len(src.masks[li]) and src.masks[li][col]:
                depth += _BRACKETS.get(src.text[i], 0)
            i += 1
        for alt in ("true", "false"):
            yield end, i - 1, alt
    for start, end, _ in src.matches(r"&&"):
        yield start, end, "||"


def _statement_edits(src):
    li = 0
    while li < len(src.lines):
        line = src.lines[li]
        indent = len(line) - len(line.lstrip(" "))
        if indent >= 6 and line.strip().startswith(_STATEMENT_START):
            depth, lj = 0, li
            while lj < len(src.lines):
                depth += sum(_BRACKETS.get(c, 0) for c, ok in zip(src.lines[lj], src.masks[lj]) if ok)
                if depth <= 0 and src.lines[lj].rstrip().endswith(";"):
                    break
                lj += 1
            yield src.offsets[li], src.offsets[lj + 1], ""
            li = lj
        li += 1


def _edits(src, operator):
    if operator == "ROR":
        edits = _token_edits(src, r"!==|===", lambda t: ["===" if t == "!==" else "!=="])
    elif operator == "NEG":
        edits = _token_edits(src, r"!(?=[A-Za-z_])", lambda t: [""])
    elif operator == "AOR":
        edits = _token_edits(src, r"(?<= )[-+*/](?= )", lambda t: [_AOR_SWAP[t]])
    elif operator == "CRP":
        edits = _token_edits(src, r"(?<![\w.])\d+(?![\w.])", _crp_alternatives)
    elif operator == "AWD":
        edits = _token_edits(src, r"(?<![\w.])await ", lambda t: [""])
    elif operator == "IDR":
        edits = _token_edits(src, r"(?<![\w.])(?:event\.id|event\.account|account|caller|net|fee)(?!\w)", lambda t: [_IDR_SWAP[t]])
    elif operator == "COND":
        edits = _condition_edits(src)
    elif operator == "SDL":
        edits = _statement_edits(src)
    else:
        edits = _rvr_edits(src)
    return sorted(edits, key=lambda e: e[0])


def _rvr_edits(src):
    swap = {"'applied'": "'duplicate'", "'duplicate'": "'applied'"}
    for li, line in enumerate(src.lines):
        if line.lstrip().startswith("//"):
            continue
        for m in re.finditer(r"'applied'|'duplicate'", line):
            yield src.offsets[li] + m.start(), src.offsets[li] + m.end(), swap[m.group(0)]


def enumerate_candidates(base_text):
    """Every mutant in the frozen order: operator, then source position, then replacement."""
    src = _Source(base_text)
    found = []
    for operator in OPERATORS:
        for start, end, replacement in _edits(src, operator):
            line, col = src.position(start)
            original = " ".join(part.strip() for part in src.text[start:end].splitlines())
            found.append({
                "id": "m-%04d" % (len(found) + 1), "operator": operator, "line": line, "col": col,
                "from": original, "to": replacement, "source": src.text[:start] + replacement + src.text[end:],
            })
    return found


def candidate_sources(base_text):
    return {c["id"]: c["source"] for c in enumerate_candidates(base_text)}


def _is_valid_js(source):
    with tempfile.TemporaryDirectory(prefix="fg-mutate-") as tmp:
        path = os.path.join(tmp, "candidate.mjs")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(source)
        return subprocess.run(["node", "--check", path], stdin=subprocess.DEVNULL, capture_output=True).returncode == 0


def build_cases(base_rel, base_text):
    base_hash = sha256_text(base_text)
    seen, cases = {base_hash: "base"}, []
    for cand in enumerate_candidates(base_text):
        digest = sha256_text(cand["source"])
        if digest in seen:
            status, reason = "excluded", ("identical-to-base" if seen[digest] == "base" else "duplicate-of:%s" % seen[digest])
        elif not _is_valid_js(cand["source"]):
            status, reason = "excluded", "invalid-syntax"
        else:
            status, reason = "included", None
            seen[digest] = cand["id"]
        cases.append({"id": cand["id"], "operator": cand["operator"], "line": cand["line"], "col": cand["col"],
                      "from": cand["from"], "to": cand["to"], "candidate_sha256": digest, "status": status, "reason": reason})
    excluded = {}
    for c in cases:
        if c["status"] == "excluded":
            key = c["reason"].split(":")[0]
            excluded[key] = excluded.get(key, 0) + 1
    return {"schema": SCHEMA, "base": {"path": base_rel, "sha256": base_hash}, "operators": list(OPERATORS),
            "counts": {"enumerated": len(cases), "included": sum(c["status"] == "included" for c in cases),
                       "excluded": dict(sorted(excluded.items()))},
            "cases": cases}


def drift(doc, base_rel, base_text):
    """Problems found when the committed case set is re-derived from the base; empty when identical."""
    fresh = build_cases(base_rel, base_text)
    if fresh == doc:
        return []
    problems = []
    old = {c["id"]: c for c in doc.get("cases", [])}
    for case in fresh["cases"]:
        if old.get(case["id"]) != case:
            problems.append("case %s differs from the committed case set" % case["id"])
    for cid in old:
        if cid not in {c["id"] for c in fresh["cases"]}:
            problems.append("committed case %s is no longer enumerated" % cid)
    return problems or ["the case-set header differs (base hash, operators or counts)"]


def _read(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def main(argv):
    parser = argparse.ArgumentParser(prog="fg_mutate", description=__doc__.split("\n\n")[0])
    parser.add_argument("command", choices=("enumerate", "verify", "show"))
    parser.add_argument("--base", required=True)
    parser.add_argument("--out")
    parser.add_argument("--cases")
    parser.add_argument("--id")
    args = parser.parse_args(argv)
    base_text = _read(args.base)
    if args.command == "show":
        sys.stdout.write(candidate_sources(base_text)[args.id])
        return 0
    base_rel = os.path.relpath(args.base, os.path.dirname(os.path.abspath(args.out or args.cases)))
    if args.command == "enumerate":
        doc = build_cases(base_rel, base_text)
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(doc, indent=2) + "\n")
        sys.stdout.write("%d enumerated, %d included, excluded %s\n" % (doc["counts"]["enumerated"], doc["counts"]["included"], doc["counts"]["excluded"]))
        return 0
    problems = drift(json.loads(_read(args.cases)), base_rel, base_text)
    for problem in problems:
        sys.stderr.write("fg_mutate: %s\n" % problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
