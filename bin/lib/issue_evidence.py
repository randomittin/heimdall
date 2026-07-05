#!/usr/bin/env python3
# issue_evidence.py — the EVIDENCE-COMMAND DISCOVERY seam for the issue-resolution
# loop (bin/lib/issue_loop.py). It answers ONE question: "what runnable acceptance
# commands should the SI-2 gate execute to PROVE this fix?" — so the gate has real
# evidence to run instead of the honest-but-useless `no-evidence-commands-supplied`
# FAIL that refused every cloud PR (bug #20).
#
# THREE SOURCES, in precedence order (highest first):
#
#   1. EXPLICIT --evidence commands. A human / a signed rr dispatch chose these; they
#      are kept VERBATIM (never re-sanitized) — byte-identical to the old --evidence
#      behavior, so every existing test that passes `--evidence "true"` is unchanged.
#   2. The ISSUE BODY's ACCEPTANCE section. The conventional "Acceptance:"/"Gating
#      test:" lines + fenced command blocks that appear inside that section. Parsed
#      CONSERVATIVELY (an allow-list of leading tokens + a hard reject of every shell
#      metacharacter) because these strings become `bash -c "<cmd>"` inside the
#      workspace clone (heimdall-attest runs them exactly as a --evidence arg).
#   3. REPO CONVENTIONS. A well-known runnable test entrypoint present in the clone
#      (an executable ./run_tests.sh / ./test.sh / a Makefile `test:` target).
#
# THE SANITIZE DISCIPLINE (safety-critical). A command extracted from an issue body is
# UNTRUSTED text. heimdall-attest executes each evidence command via `bash -c` in the
# repo, so an unsanitized string is arbitrary code. We therefore accept a body-derived
# command ONLY when it (a) starts with a known-safe leader (`./` or a leading token in
# _LEADER_TOKENS — make/pytest/npm/…), and (b) contains NO shell metacharacter that
# enables chaining / redirection / substitution (`; | & ` $ > < ( ) { } \`). A command
# that cannot be proven safe is DROPPED — never rewritten, never partially run. The
# whole set is deduped and CAPPED (a runaway body cannot enqueue 500 commands).
#
# This module has NO side effects beyond reading the repo's convention files. It never
# runs a command — it only DISCOVERS the list the gate (SI-2) will run and record.

from __future__ import annotations

import os
import re

# The default ceiling on how many evidence commands one issue can contribute. A
# conservative cap so a pathological body / a repo with many convention files cannot
# make the gate run an unbounded number of commands.
DEFAULT_EVIDENCE_CAP = 6

# The maximum length of a single body-derived command. A longer line is almost
# certainly prose, not a command — reject it rather than run it.
_MAX_CMD_LEN = 200

# Leading BARE tokens that mark a line as a runnable acceptance command. A line whose
# first whitespace-delimited token is one of these (or that starts with "./") is a
# candidate; anything else in an acceptance region is treated as prose and skipped.
_LEADER_TOKENS = frozenset({
    "make", "pytest", "py.test", "npm", "npx", "yarn", "pnpm", "bash", "sh",
    "python", "python3", "go", "cargo", "tox", "rake", "gradle", "mvn",
    "phpunit", "rspec", "jest", "vitest", "ctest", "cmake", "bats", "deno",
    "dotnet", "swift", "ruby", "node",
})

# Shell metacharacters that turn a single command into chaining / redirection /
# substitution. ANY of these in a body-derived command -> reject (never run untrusted
# shell). Newlines are already removed by the line split; the rest are guarded here.
_UNSAFE_CHARS = frozenset(";|&`$><(){}\\\n\r")

# Markers that open an ACCEPTANCE region in an issue body. Case-insensitive substring
# match on a line. Inside the region, command-shaped lines (and fenced code blocks
# opened inside it) are harvested until a blank line or a markdown heading closes it.
_ACCEPT_MARKER_RX = re.compile(
    r"(?i)\b(acceptance|gating\s+test|to\s+reproduce|repro|verify|run\s+tests?)\b"
)

# Well-known runnable test entrypoints a repo may ship. An executable one in the clone
# root is a strong evidence candidate (the ./run_tests.sh the live issue named).
_CONVENTION_SCRIPTS = ("run_tests.sh", "test.sh", "run-tests.sh", "scripts/test.sh")


def _strip_decoration(line):
    """Strip common markdown/prompt decoration from a candidate command line so a
    fenced or inline command survives: surrounding backticks, a leading list bullet
    (`- ` / `* ` / `+ `), and a leading shell prompt (`$ ` / `> `). Returns the bare
    command text (possibly still non-command — the caller validates)."""
    s = line.strip()
    # inline code span: `./run_tests.sh` -> ./run_tests.sh
    if len(s) >= 2 and s[0] == "`" and s[-1] == "`":
        s = s[1:-1].strip()
    else:
        s = s.strip("`").strip()
    # a leading list bullet
    s = re.sub(r"^[-*+]\s+", "", s)
    # a leading shell prompt ("$ cmd" / "> cmd") — removed BEFORE the unsafe scan so a
    # legitimate prompted command is not rejected for its own prompt char.
    s = re.sub(r"^[$>]\s+", "", s)
    return s.strip()


def sanitize_command(line):
    """Return a SAFE runnable command parsed from `line`, or None when the line is not
    a provably-safe acceptance command. Conservative by construction (see the module
    header): an allow-listed leader AND no shell metacharacter. Never rewrites — a line
    that is not already safe is dropped."""
    if not line:
        return None
    s = _strip_decoration(line)
    if not s or len(s) > _MAX_CMD_LEN:
        return None
    if any(ch in _UNSAFE_CHARS for ch in s):
        return None
    tokens = s.split()
    if not tokens:
        return None
    first = tokens[0]
    if s.startswith("./") or first in _LEADER_TOKENS:
        return s
    return None


def extract_acceptance_commands(body):
    """Parse `body` (an issue's markdown) for runnable acceptance commands. Harvests
    ONLY inside an ACCEPTANCE region (a line matching _ACCEPT_MARKER_RX opens it; a
    blank line or a markdown heading closes it) — including a fenced ``` block opened
    while the region is active. Every candidate passes sanitize_command; unsafe/prose
    lines are dropped. Returns a deduped list in document order."""
    if not body or not isinstance(body, str):
        return []
    out = []
    in_region = False
    in_fence = False
    fence_in_region = False
    for raw in body.splitlines():
        stripped = raw.strip()
        # fence toggles (```): remember whether the fence opened inside the region so a
        # code block placed right under an "Acceptance:" heading contributes commands.
        if stripped.startswith("```"):
            if not in_fence:
                in_fence = True
                fence_in_region = in_region
            else:
                in_fence = False
                fence_in_region = False
            continue
        if in_fence:
            if fence_in_region:
                cmd = sanitize_command(stripped)
                if cmd:
                    out.append(cmd)
            continue
        # an acceptance/gating marker opens the region AND may carry an inline command
        # after its colon ("Acceptance (must go green): ./run_tests.sh").
        if _ACCEPT_MARKER_RX.search(stripped):
            in_region = True
            if ":" in stripped:
                inline = stripped.split(":", 1)[1]
                cmd = sanitize_command(inline)
                if cmd:
                    out.append(cmd)
            continue
        if in_region:
            if not stripped or stripped.startswith("#"):
                in_region = False
                continue
            cmd = sanitize_command(stripped)
            if cmd:
                out.append(cmd)
    return _dedupe(out)


def discover_repo_conventions(repo):
    """Discover well-known runnable test entrypoints present in the clone `repo`: an
    executable ./run_tests.sh (etc.) in the repo root, or a Makefile with a `test:`
    target. Returns the runnable commands (e.g. "./run_tests.sh", "make test"). A
    missing repo / unreadable file contributes nothing (never raises)."""
    out = []
    if not repo or not os.path.isdir(repo):
        return out
    for rel in _CONVENTION_SCRIPTS:
        path = os.path.join(repo, rel)
        if os.path.isfile(path) and os.access(path, os.X_OK):
            out.append("./" + rel)
    mk = os.path.join(repo, "Makefile")
    if os.path.isfile(mk):
        try:
            with open(mk, "r", encoding="utf-8", errors="replace") as fh:
                mk_text = fh.read()
        except OSError:
            mk_text = ""
        if re.search(r"(?m)^test:", mk_text):
            out.append("make test")
    return _dedupe(out)


def resolve_evidence(supplied, issue, repo, cap=DEFAULT_EVIDENCE_CAP):
    """Resolve the FULL evidence-command list the SI-2 gate should run for one issue.

    Precedence (highest first, deduped, capped at `cap`):
      1. `supplied`     — the explicit --evidence commands (VERBATIM, never re-sanitized:
                          a trusted CLI/dispatch chose them — the old behavior, unchanged).
      2. the ISSUE BODY — extract_acceptance_commands(issue.body) (sanitized).
      3. REPO CONVENTIONS — discover_repo_conventions(repo) (an executable ./run_tests.sh
                          in the clone, a Makefile `test:` target).

    Returns a list. When nothing is discovered the list is exactly `supplied` (so the
    honest empty-list -> gate FAIL is preserved when there is genuinely no proof)."""
    ordered = []
    for cmd in supplied or []:
        if cmd and cmd not in ordered:
            ordered.append(cmd)
    body = (issue or {}).get("body") if isinstance(issue, dict) else None
    for cmd in extract_acceptance_commands(body or ""):
        if cmd not in ordered:
            ordered.append(cmd)
    for cmd in discover_repo_conventions(repo):
        if cmd not in ordered:
            ordered.append(cmd)
    if cap and cap > 0:
        return ordered[:cap]
    return ordered


def _dedupe(seq):
    """Order-preserving dedupe."""
    seen = set()
    out = []
    for x in seq:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out
