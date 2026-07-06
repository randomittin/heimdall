#!/usr/bin/env python3
# issue_evidence.py — the EVIDENCE-COMMAND DISCOVERY seam for the issue-resolution
# loop (bin/lib/issue_loop.py). It answers ONE question: "what runnable acceptance
# commands should the SI-2 gate execute to PROVE this fix?" — so the gate has real
# evidence to run instead of the honest-but-useless `no-evidence-commands-supplied`
# FAIL that refused every cloud PR (bug #20).
#
# FOUR SOURCES, in precedence order (highest first):
#
#   1. EXPLICIT --evidence commands. A human / a signed rr dispatch chose these; they
#      are kept VERBATIM (never re-sanitized) — byte-identical to the old --evidence
#      behavior, so every existing test that passes `--evidence "true"` is unchanged.
#   2. A NAMED GATING TEST NODE (bug #25). When the body names a specific, ISOLATED
#      test node (a pytest/unittest node id — `path::Class::method` or `path::method`,
#      typically on a "Gating test:" / "Gating:" / "Failing test:" line) AND that node's
#      file is present in the clone, the node becomes the PRIMARY (and SOLE) gating
#      command — run precisely (`python3 -m pytest <node> -q`, or `-m unittest <dotted>`
#      when pytest is absent). This is the per-issue, falsifiable proof that THIS fix
#      works; the whole-suite ./run_tests.sh (sources 3 + 4) is DEMOTED — SKIPPED from
#      the gating set — so unrelated co-resident failures in the SAME suite CANNOT fail
#      the gate. Rationale (run 12): a single maintainer issue names ONE concern, but a
#      whole-suite gate let sibling planted bugs (average/clamp) fail a genuinely-correct
#      sum_range fix. The node keeps the gate honest: node red -> gate FAILS.
#   3. The ISSUE BODY's ACCEPTANCE section. The conventional "Acceptance:"/"Gating
#      test:" lines + fenced command blocks that appear inside that section. Parsed
#      CONSERVATIVELY (an allow-list of leading tokens + a hard reject of every shell
#      metacharacter) because these strings become `bash -c "<cmd>"` inside the
#      workspace clone (heimdall-attest runs them exactly as a --evidence arg).
#   4. REPO CONVENTIONS. A well-known runnable test entrypoint present in the clone
#      (an executable ./run_tests.sh / ./test.sh / a Makefile `test:` target).
#
# THE GATING-NODE PRECEDENCE RULE (bug #25): a PRECISE named node when present + runnable
# (per-issue isolated proof) ELSE the whole-suite acceptance/conventions (a repo with a
# single concern still gates on its full suite — the pre-#25 behavior, unchanged). The
# node ONLY wins when its file actually exists in the clone: an unrunnable named node is
# not proof, so we fall back honestly to the whole suite rather than fabricate a command.
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


# ── bug #25: the NAMED GATING TEST NODE (per-issue isolated proof) ─────────────
# A GATING-TEST line names the single failing node that isolates THIS issue's fix. We
# harvest the node ONLY from such a line (not from a generic "Acceptance:" line) so a
# whole-suite command is never mistaken for a node.
_GATING_NODE_LINE_RX = re.compile(r"(?i)\b(gating(\s+test)?|failing\s+test)\b")

# A pytest/unittest node id shape (STRICT, injection-safe): a file/path segment, then
# `::`, then a `Class::method` / `method` tail. The ONLY characters allowed are word
# chars, `.`, `/`, `-`, `:` — NONE of the shell metacharacters in _UNSAFE_CHARS. A node
# id is a single shell WORD (no spaces), so `python3 -m pytest <node> -q` is a safe argv
# with no room for chaining / substitution. Validation is FULL-STRING (fullmatch) so a
# token carrying ANY metachar (`x::m$(...)`, `x::m;rm`) fails and is REJECTED.
_NODE_ID_RX = re.compile(r"[\w./-]+::[\w./:-]+")

# characters stripped from the ends of a candidate node token before validation: markdown
# code ticks, quotes, and wrapping brackets/parens. A trailing sentence period/comma is
# stripped separately. NEVER strips a shell metachar into validity — fullmatch is the gate.
_NODE_EDGE_STRIP = "`\"'()[]{}"


def extract_gating_node(body):
    """Extract the single NAMED gating-test node id from `body`, or None.

    A node is harvested ONLY from a GATING-TEST line (`_GATING_NODE_LINE_RX`: a
    "Gating test:" / "Gating:" / "Failing test:" line) — never from a generic
    "Acceptance:" line, so a whole-suite command is never mistaken for a node. On such a
    line the FIRST whitespace token containing `::` is the candidate; it is accepted ONLY
    when it FULL-MATCHES the strict, injection-safe `_NODE_ID_RX` shape. A candidate
    carrying ANY shell metachar (`x::m$(...)`, `x::m;rm`, `x::m&&curl`) fails fullmatch and
    is REJECTED (returns None) — never stripped-and-run. Conservative: the first gating
    line whose first `::`-token validates wins; a poisoned first `::`-token rejects."""
    if not body or not isinstance(body, str):
        return None
    for raw in body.splitlines():
        if not _GATING_NODE_LINE_RX.search(raw):
            continue
        for tok in raw.split():
            if "::" not in tok:
                continue
            cand = tok.strip(_NODE_EDGE_STRIP).strip().rstrip(".,")
            if _NODE_ID_RX.fullmatch(cand):
                return cand
            # the first `::`-bearing token on this gating line is POISONED (a metachar
            # broke the strict shape) -> reject rather than hunt for a "clean" tail.
            return None
    return None


def _pytest_available():
    """True when pytest can run in THIS interpreter (the maintainer container where the
    gate executes evidence). The env override HEIMDALL_PYTEST_AVAILABLE (0/1) forces the
    branch for hermetic tests; otherwise importlib.util.find_spec — a read-only probe with
    NO import side effects (keeps the module's no-side-effects contract)."""
    override = os.environ.get("HEIMDALL_PYTEST_AVAILABLE")
    if override is not None:
        return override.strip().lower() not in ("", "0", "false", "no")
    try:
        import importlib.util
        return importlib.util.find_spec("pytest") is not None
    except Exception:  # noqa: BLE001 — a probe failure is "not available", never fatal
        return False


def _node_to_dotted(node):
    """Convert a pytest node id to a unittest dotted path:
    `tests/test_x.py::C::m` -> `tests.test_x.C.m`. Strips a trailing `.py` from the file
    segment and swaps `/` and `::` for `.`. Returns None when the shape is unusable."""
    if "::" not in node:
        return None
    path, _, tail = node.partition("::")
    if path.endswith(".py"):
        path = path[:-3]
    mod = path.replace("/", ".").strip(".")
    tail = tail.replace("::", ".")
    dotted = (mod + "." + tail) if mod else tail
    dotted = dotted.strip(".")
    return dotted or None


def build_gating_node_command(node):
    """Build the PRECISE, injection-safe command that runs ONLY the named `node`:
    `python3 -m pytest <node> -q` when pytest is available, else
    `python3 -m unittest <dotted-node>`. Returns None when `node` is not the strict,
    safe shape (defense in depth — the caller already validated via extract_gating_node)."""
    if not node or not _NODE_ID_RX.fullmatch(node):
        return None
    if _pytest_available():
        return "python3 -m pytest " + node + " -q"
    dotted = _node_to_dotted(node)
    if not dotted:
        return None
    return "python3 -m unittest " + dotted


def _node_file_present(node, repo):
    """True when the file segment of `node` (before the first `::`) is a real file in the
    clone `repo`. The node is per-issue PROOF only if we can actually run it here; an
    absent file -> fall back to the whole suite (honest, never fabricate a command). A
    path that escapes the clone (absolute / contains `..`) is rejected."""
    if not node or not repo or not os.path.isdir(repo):
        return False
    rel = node.split("::", 1)[0]
    if not rel or os.path.isabs(rel) or ".." in rel.split("/"):
        return False
    return os.path.isfile(os.path.join(repo, rel))


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
      2. a NAMED, RUNNABLE GATING NODE (bug #25) — when the body names an ISOLATED test
                          node (extract_gating_node) AND its file exists in the clone, that
                          node's precise command (build_gating_node_command) is the PRIMARY
                          and SOLE body-derived gating proof: the whole-suite sources (3+4)
                          are SKIPPED so unrelated co-resident failures in the same suite
                          cannot fail the gate. node red still FAILS the gate.
      3. the ISSUE BODY — extract_acceptance_commands(issue.body) (sanitized).
      4. REPO CONVENTIONS — discover_repo_conventions(repo) (an executable ./run_tests.sh
                          in the clone, a Makefile `test:` target).

    THE PRECEDENCE RULE: a precise named node when present + runnable ELSE the whole-suite
    acceptance/conventions (a one-concern repo still gates on its full suite — unchanged).

    Returns a list. When nothing is discovered the list is exactly `supplied` (so the
    honest empty-list -> gate FAIL is preserved when there is genuinely no proof)."""
    ordered = []
    for cmd in supplied or []:
        if cmd and cmd not in ordered:
            ordered.append(cmd)
    body = (issue or {}).get("body") if isinstance(issue, dict) else None
    body = body or ""

    # ── source 2 (bug #25): a NAMED, RUNNABLE node is the primary + SOLE gating proof ──
    # It becomes the primary body-derived command AND short-circuits the whole-suite
    # sources (3 + 4) so co-resident sibling failures cannot fail a genuinely-correct fix.
    # Gated on the node's FILE existing in the clone: an unrunnable named node is not
    # proof, so we fall through to the whole suite rather than fabricate a command.
    node = extract_gating_node(body)
    if node and _node_file_present(node, repo):
        node_cmd = build_gating_node_command(node)
        if node_cmd:
            if node_cmd not in ordered:
                ordered.append(node_cmd)
            if cap and cap > 0:
                return ordered[:cap]
            return ordered

    # ── sources 3 + 4 (the whole-suite fallback — the pre-#25 behavior) ───────────
    for cmd in extract_acceptance_commands(body):
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
