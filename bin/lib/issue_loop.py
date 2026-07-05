#!/usr/bin/env python3
# issue_loop.py — piece (c) of the Heimdall issue-resolution loop: the RESOLUTION
# LOOP STATE MACHINE. The real engine behind `bin/heimdall-issue-loop`.
#
# The loop is a SEQUENCER of EXISTING machinery (dossier §4) — it introduces no
# new orchestration primitive. One issue per `run-once`:
#
#   pick -> orient(SI-1) -> fix -> GATE -> attest(SI-2) -> [PR-ready | flagged]
#
# States (each persisted into the queue's in_flight[id].state — dossier §4):
#
#   PICKED -orient-> ORIENTED -fix-> FIXED -gate-> +-PASS-> ATTESTED -pr-> PR_OPEN
#                                                  +-FAIL-> GATE_FAILED (-> flagged)
#   any state -error-> ERRORED (-> release back to queue OR flagged 'out-of-scope')
#
# REUSE LEDGER (dossier §10 — read/call, NEVER reimplement):
#   • orient  = SI-1: shell out to `bin/heimdall-comprehend load <repo>` (exit 0 =
#               fresh capsule reused; exit 3 = `comprehend <repo>` then re-load).
#               The loop READS the capsule JSON (.heimdall/context.json) to brief
#               the fix. No new orientation code.
#   • attest  = SI-2: shell out to `bin/heimdall-attest emit --evidence "<cmd>"`.
#               The emitted record {claims,contracts,evidence,reuse,risk} is BOTH
#               the PR body's payload AND the gate verdict source. One emission,
#               two readers, zero re-analysis.
#   • queue   = piece (b): bin/lib/issue_queue.py — pick() (claim-before-work
#               idempotency), set_state(), flag(), mark_resolved(). Never re-picks
#               an in_flight / resolved / flagged id.
#
# ── THE CARDINAL RULE (dossier §5, safety-critical) ───────────────────────────
#   An issue is PR-ready ONLY when the deterministic gate PASSES. The verdict is
#   read ONLY from record["evidence"]["all_passed"] — a RECORDED REAL EXIT
#   (attestation.py::build_evidence: ok=(code==0); all_passed=bool(checks) and
#   all_ok) — NEVER from an agent "done" claim. The wiring is STRUCTURAL, not
#   convention: open_pr() is physically reachable only inside the
#   `if all_passed is True:` branch of _gate_and_finish(). A FAIL cannot reach it.
#   An empty evidence list yields all_passed=False -> FAIL -> flagged, never a PR.
#
# This is a LIBRARY (pure-ish orchestration + a thin subprocess seam). The bash
# CLI (bin/heimdall-issue-loop) owns argv + stdout shape.

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import issue_queue  # piece (b); sibling on sys.path

# ── evidence discovery seam (soft-import, like telemetry below) ───────────────
# issue_evidence.resolve_evidence discovers the runnable acceptance commands the SI-2
# gate should run — from the ISSUE BODY's Acceptance section AND repo conventions (an
# executable ./run_tests.sh in the clone) — on top of any explicit --evidence. Before
# this seam the cloud maintainer ran the gate with an EMPTY evidence list (no --evidence
# was ever threaded through the dispatch) -> all_passed False -> GATE_FAILED, so a real
# fix could never be PR'd (bug #20). If the module is ABSENT (a partial checkout) the
# loop degrades to the explicit --evidence commands only — byte-identical to before.
try:
    import issue_evidence  # sibling on sys.path
except Exception:  # noqa: BLE001 — absent/broken discovery must never break the loop
    issue_evidence = None


# ── telemetry seam: the loop is CONSUMER #1 of the ONE event surface (dossier §2) ─
# Soft-import the general telemetry surface, mirroring how the PR layer is soft-
# imported below: if bin/lib/telemetry.py is ABSENT (a partial checkout) the loop
# runs IDENTICALLY — _emit_telemetry becomes a no-op. The loop NEVER keeps a
# parallel recording; it emits at the SAME transition points the queue already
# records (set_state / flag / gate verdict). emit() is itself fire-and-forget and
# never-raises, so a telemetry fault can never fail the loop (dossier §8).
try:
    import telemetry  # piece (a); the ONE general event surface
except Exception:  # noqa: BLE001 — absent/broken telemetry must never break the loop
    telemetry = None


def _emit_telemetry(event_type, **kw):
    """Emit ONE event through the general surface if it is present. A no-op when the
    telemetry lib is absent (soft-import miss) — the loop's behavior is identical
    either way. Never raises: telemetry.emit already swallows everything, and this
    guards the soft-import miss. The loop reads its verdict from the SAME recorded
    real exit the cardinal rule already reads — telemetry only OBSERVES it."""
    if telemetry is None:
        return False
    try:
        return telemetry.emit(event_type, **kw)
    except Exception:  # noqa: BLE001 — defence in depth; the loop never depends on this
        return False

# ── machine states (dossier §4) ───────────────────────────────────────────────

IDLE = "IDLE"              # nothing pickable — the loop is inert this iteration
PICKED = "PICKED"
ORIENTED = "ORIENTED"
FIXED = "FIXED"
ATTESTED = "ATTESTED"
PR_OPEN = "PR_OPEN"        # terminal-for-loop (dossier §6 human gate begins here)
GATE_FAILED = "GATE_FAILED"  # terminal; -> flagged{gate-failed}; NOT resolved
ERRORED = "ERRORED"        # honest failure; -> flagged{out-of-scope} or released


# ── tool locators (the SI-1 / SI-2 binaries we REUSE, never reimplement) ──────


def _bindir():
    """The bin/ directory that holds heimdall-comprehend + heimdall-attest. This
    lib lives at bin/lib/issue_loop.py, so bin/ is one level up."""
    return os.path.dirname(_HERE)


def _comprehend_bin():
    return os.path.join(_bindir(), "heimdall-comprehend")


def _attest_bin():
    return os.path.join(_bindir(), "heimdall-attest")


def _capsule_path(repo):
    """Where SI-1 writes the comprehension capsule: ${HEIMDALL_HOME:-<repo>/
    .heimdall}/context.json — the SAME home the queue + attestations use."""
    home = os.environ.get("HEIMDALL_HOME") or os.path.join(repo, ".heimdall")
    return os.path.join(home, "context.json")


# ── orient: REUSE SI-1 (heimdall-comprehend) — never reimplement comprehension ─


def orient(repo):
    """Orient on the repo by REUSING SI-1 (dossier §4 EXACT reuse point):

      `heimdall-comprehend load <repo>`  (exit 0 = fresh capsule, reuse it;
                                          exit 3 = stale/missing -> comprehend
                                          then re-load).

    Reads the resulting capsule (.heimdall/context.json) and returns an orient
    result the loop attaches to the fix brief:

      { tool: 'heimdall-comprehend', action: 'reused'|'derived',
        capsule_attached: bool, capsule: <dict|None>, capsule_path: str }

    No orientation logic lives here — this is purely the F1 wiring contract."""
    comp = _comprehend_bin()
    cap_path = _capsule_path(repo)
    action = "reused"

    # 1) try a cache load first (orient-once, reuse-many).
    rc = _run([comp, "load", repo]).returncode
    if rc == 3:
        # stale / missing / corrupt -> derive, then the capsule exists to read.
        _run([comp, "comprehend", repo])
        action = "derived"
    # rc 0 -> a fresh capsule already on disk (reused). Any other rc: we still try
    # to read whatever capsule exists; an absent capsule -> capsule_attached False.

    capsule = _read_json(cap_path)
    return {
        "tool": "heimdall-comprehend",
        "action": action,
        "capsule_attached": capsule is not None,
        "capsule": capsule,
        "capsule_path": cap_path,
    }


# ── fix: the real Heimdall task slot (the loop DRIVES it, reads the GATE) ──────


def default_fix_runner(issue, orient_result, repo):
    """The production fix slot: a REAL Heimdall task, briefed with the SI-1 capsule +
    the normalized issue body, producing a working-tree diff in the repo. The loop
    NEVER trusts what this returns as the verdict — the verdict comes from the
    deterministic gate (SI-2 evidence), per the cardinal rule.

    Two steps: (1) materialize the fix BRIEF into the repo's runtime home (the audit
    trail — exactly what the fix was asked to do), then (2) DRIVE the headless coder
    (`claude -p`) INSIDE the workspace so real edits actually land on disk. Step (2) was
    the empty-diff hole (bug #20): the old slot wrote only the brief and returned, so
    NOTHING edited the workspace and every cloud cycle produced a 0-file diff. It is
    gated on HEIMDALL_FIX_WITH_CLAUDE (the deployed maintainer sets it; the fixture-
    driven suites leave it unset and keep the brief-only behavior). Returns { briefed,
    brief_path, fix_attempt } — DESCRIPTIVE ONLY, NOT a verdict. Tests substitute a
    fixture runner (or a fake claude binary via HEIMDALL_CLAUDE_BIN) for hermetic runs."""
    home = os.environ.get("HEIMDALL_HOME") or os.path.join(repo, ".heimdall")
    brief_dir = os.path.join(home, "issues", "fix-briefs")
    os.makedirs(brief_dir, exist_ok=True)
    safe = issue["id"].replace(":", "_").replace("/", "_").replace("#", "_")
    brief_path = os.path.join(brief_dir, safe + ".json")
    brief = {
        "issue_id": issue["id"],
        "title": issue.get("title", ""),
        "body": issue.get("body", ""),
        "capsule_attached": orient_result.get("capsule_attached", False),
        "capsule_path": orient_result.get("capsule_path"),
    }
    tmp = brief_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(brief, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, brief_path)

    fix_result = {"briefed": True, "brief_path": brief_path}
    # DRIVE THE ACTUAL FIX: the headless coder writes real edits into the workspace.
    # LOUDLY instrumented (exit/duration/output-tail/files_changed) so a silent claude
    # failure is diagnosable instead of an inscrutable empty diff. Its return is
    # DESCRIPTIVE ONLY — the SI-2 gate still decides the verdict (the cardinal rule).
    fix_result["fix_attempt"] = _run_claude_fix(issue, orient_result, repo)
    return fix_result


# ── the HEADLESS CODER invocation (claude -p) — the real edits land here ──────
#
# THE EMPTY-DIFF ROOT CAUSE (bug #20): default_fix_runner used to ONLY write a fix brief
# to disk and return — NOTHING ever edited the workspace, so every cloud cycle produced
# a 0-file diff and the gate (correctly, with no evidence) refused the PR. _run_claude_fix
# closes that gap: it shells out to the headless coder (`claude -p`) INSIDE the workspace
# clone with the tool permissions a NON-INTERACTIVE container needs to actually write
# files (--permission-mode acceptEdits + --allowedTools Edit,Write,Read,Bash — a bare
# `claude -p` in a headless job cannot edit without them), and LOUDLY records the call's
# exit / duration / scrubbed output-tail / changed-file count into the fix result (like
# cp_handlers' error_tail), so a silent claude failure is diagnosable, not an empty diff.
#
# GATED, not always-on. The invocation runs ONLY when HEIMDALL_FIX_WITH_CLAUDE is truthy:
# the deployed maintainer sets it (deploy env + cp_handlers MAINTAINER_ENV_PASSTHROUGH);
# the unit/integration suites (which drive the loop with FIXTURE --evidence and must never
# spend a real model call) leave it unset, so they keep the brief-only behavior byte-for-
# byte. When disabled, or when no claude binary resolves, the attempt is recorded honestly
# (invoked False + a reason) and the SI-2 gate still decides the verdict on merit.

CLAUDE_BIN_ENV = "HEIMDALL_CLAUDE_BIN"
CLAUDE_FIX_ENABLE_ENV = "HEIMDALL_FIX_WITH_CLAUDE"
CLAUDE_FIX_TIMEOUT_ENV = "HEIMDALL_FIX_TIMEOUT"
CLAUDE_FIX_TIMEOUT_DEFAULT = 1500  # seconds; bounded < the 3600 maintainer dispatch cap
_ENABLE_TRUTHY = {"1", "true", "yes", "on"}

# the tool set a headless fix needs to actually change files in the clone.
_FIX_ALLOWED_TOOLS = "Edit,Write,Read,Bash"

# token-ish shapes scrubbed from the recorded output-tail (never surface a credential a
# fix run may have echoed). Mirrors cp_handlers._SECRET_SCRUB.
_FIX_SECRET_SCRUB = re.compile(
    r"(?:ghs_|ghp_|gho_|github_pat_|sk-ant-)[A-Za-z0-9_-]+"
    r"|-----BEGIN[^\n]*"
)
_FIX_TAIL_MAX = 800


def _claude_bin():
    """The headless coder binary: HEIMDALL_CLAUDE_BIN (tests point it at a fake), else
    the `claude` CLI on PATH."""
    return os.environ.get(CLAUDE_BIN_ENV) or "claude"


def _claude_fix_enabled():
    """True only when HEIMDALL_FIX_WITH_CLAUDE is explicitly truthy. OFF by default so
    the fixture-driven suites never spend a real model call; the deployed maintainer
    turns it ON (deploy env + cp_handlers MAINTAINER_ENV_PASSTHROUGH)."""
    raw = os.environ.get(CLAUDE_FIX_ENABLE_ENV)
    return bool(raw) and raw.strip().lower() in _ENABLE_TRUTHY


def _claude_fix_timeout():
    """The per-fix wall-clock cap (seconds). Bounded default; a bad override falls back."""
    try:
        return int(os.environ.get(CLAUDE_FIX_TIMEOUT_ENV, CLAUDE_FIX_TIMEOUT_DEFAULT))
    except (TypeError, ValueError):
        return CLAUDE_FIX_TIMEOUT_DEFAULT


def _scrub_fix_output(text):
    """Redact token-ish substrings from the recorded fix output-tail (safe to persist)."""
    if not text:
        return ""
    return _FIX_SECRET_SCRUB.sub("[REDACTED]", text)


def _changed_file_count(repo):
    """Count working-tree changes in `repo` (the diff the fix produced), via
    `git status --porcelain`. Returns None on a git failure (unknown — never a fake 0)."""
    try:
        proc = subprocess.run(
            ["git", "-C", repo, "status", "--porcelain"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    return len([ln for ln in (proc.stdout or "").splitlines() if ln.strip()])


def build_fix_prompt(issue, orient_result):
    """Build the headless coder prompt from the issue + the SI-1 capsule. The maintainer
    context (the rr briefing) is already PREPENDED into issue['body'] upstream, so the
    prompt carries it. Bounded so a huge body cannot blow the argv."""
    title = (issue.get("title") or "").strip()
    body = (issue.get("body") or "").strip()
    if len(body) > 12000:
        body = body[:12000] + "\n\n[...issue body truncated for the fix prompt...]"
    cap = orient_result.get("capsule") if isinstance(orient_result, dict) else None
    cap_line = ""
    if isinstance(cap, dict):
        mods = cap.get("modules") or cap.get("capabilities") or []
        if isinstance(mods, list) and mods:
            cap_line = "\nRepo modules (from comprehension): %s\n" % ", ".join(
                str(m) for m in mods[:20])
    return (
        "You are Heimdall's autonomous maintainer resolving ONE GitHub issue in the "
        "current repository (your working directory IS the checkout). Implement a "
        "COMPLETE, real fix by editing files directly with the Edit/Write tools. Do "
        "NOT ask questions and do NOT stop until the change is on disk. If the issue "
        "names acceptance/test commands, make them pass. Keep the change minimal and "
        "focused on the issue.\n"
        "%s\n"
        "ISSUE TITLE: %s\n\n"
        "ISSUE BODY:\n%s\n" % (cap_line, title, body)
    )


def _run_claude_fix(issue, orient_result, repo):
    """Invoke the headless coder (claude -p) INSIDE `repo` so real edits land, and
    return an instrumentation dict recording the outcome (never the verdict — the SI-2
    gate decides that). See the section header for the empty-diff root cause + the gate.

    Returns one of:
      {invoked:False, enabled:False, reason:'claude-fix-disabled'}          (suite default)
      {invoked:False, enabled:True,  reason:'claude-not-found', bin:...}     (no binary)
      {invoked:True,  enabled:True, exit:int, duration_ms:int,
       output_tail:str, files_changed:int|None}                             (ran)
      {invoked:True,  enabled:True, timed_out:True, duration_ms:int}        (killed)"""
    if not _claude_fix_enabled():
        return {"invoked": False, "enabled": False, "reason": "claude-fix-disabled"}
    prompt = build_fix_prompt(issue, orient_result)
    argv = [
        _claude_bin(), "-p", prompt,
        "--permission-mode", "acceptEdits",
        "--allowedTools", _FIX_ALLOWED_TOOLS,
        "--output-format", "text",
    ]
    t0 = time.time()
    try:
        proc = subprocess.run(
            argv, cwd=repo, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, timeout=_claude_fix_timeout(),
        )
    except FileNotFoundError:
        return {"invoked": False, "enabled": True, "reason": "claude-not-found",
                "bin": _claude_bin()}
    except OSError as exc:
        return {"invoked": False, "enabled": True, "reason": "claude-exec-error",
                "detail": _scrub_fix_output(str(exc))[:200]}
    except subprocess.TimeoutExpired:
        return {"invoked": True, "enabled": True, "timed_out": True,
                "duration_ms": int((time.time() - t0) * 1000)}
    dur = int((time.time() - t0) * 1000)
    combined = proc.stdout or ""
    if proc.stderr:
        combined += "\n[stderr] " + proc.stderr
    tail = _scrub_fix_output(combined.strip())
    if len(tail) > _FIX_TAIL_MAX:
        tail = "…" + tail[-_FIX_TAIL_MAX:]
    return {
        "invoked": True, "enabled": True, "exit": proc.returncode,
        "duration_ms": dur, "output_tail": tail,
        "files_changed": _changed_file_count(repo),
    }


# ── attest + GATE: REUSE SI-2, read the verdict from the RECORDED REAL EXIT ────


def attest(repo, base, evidence_cmds, task=None):
    """REUSE SI-2 (dossier §4 EXACT reuse point): shell out to

      `heimdall-attest emit --repo <repo> --base <base> --evidence "<cmd>" ... --print`

    Each --evidence command is EXECUTED by heimdall-attest and its REAL exit code
    recorded under evidence (attestation.py::build_evidence). The emitted record
    {claims,contracts,evidence,reuse,risk} (schema si-2.1) is returned verbatim:
    it is BOTH the gate-verdict source (record.evidence.all_passed) AND the payload
    the PR body carries. One emission, two readers, zero re-analysis.

    Returns the parsed record dict (never None — a degraded emit still yields an
    honest partial record with all_passed False)."""
    cmd = [_attest_bin(), "emit", "--repo", repo, "--base", base, "--print", "--quiet"]
    if task:
        cmd += ["--task", task]
    for ev in evidence_cmds or []:
        cmd += ["--evidence", ev]
    proc = _run(cmd, capture=True)
    record = _parse_json(proc.stdout)
    if record is None:
        # heimdall-attest is contractually non-crashing; if stdout was unparseable
        # (e.g. python absent) synthesize an honest FAIL record so the gate treats
        # an unverifiable change as a FAIL — never a silent PASS.
        record = {
            "schema": "si-2.1",
            "task": task or "",
            "evidence": {
                "checks": [],
                "ran": 0,
                "all_passed": False,
                "reason": "attest-unavailable",
            },
            "risk": {"overall": "warn", "flags": [
                {"level": "warn", "code": "no-evidence",
                 "detail": "attestation unavailable — change unproven"}]},
            "partial": True,
        }
    return record


def read_verdict(record):
    """THE CARDINAL RULE verdict read (dossier §5): the gate PASS/FAIL is read ONLY
    from record["evidence"]["all_passed"] — a RECORDED REAL EXIT, never an agent
    claim. Returns a strict bool. A missing/non-bool field is treated as FAIL (a
    change with no observed proof is NOT PR-ready)."""
    val = (record.get("evidence") or {}).get("all_passed")
    return val is True


# ── the PR hook: SOFT-IMPORT the pr layer (piece d), like piece b does ────────


def _soft_import_open_pr():
    """Soft-import the PR layer (piece d, built next), mirroring how piece (b)
    soft-imports connectors: if bin/lib/issue_pr.py is ABSENT we return None and
    the loop marks the issue pr_ready then STOPS — it does NOT fabricate a PR.
    Returns the open_pr callable, or None when the layer is not present."""
    try:
        import issue_pr  # piece (d); sibling on sys.path when present
    except Exception:
        return None
    return getattr(issue_pr, "open_pr", None)


# ── the state machine (one issue per run_once) ────────────────────────────────


def run_once(repo, base="HEAD", evidence_cmds=None, cfg=None,
             fix_runner=None, now=None):
    """Drive ONE issue through the full state machine (dossier §4 + §5).

    repo:          the repository the loop resolves issues in.
    base:          the BEFORE ref for the SI-2 attestation (default HEAD).
    evidence_cmds: the runnable acceptance/test/gate commands SI-2 executes; the
                   gate verdict is read from their recorded real exits. An empty
                   list => all_passed False => FAIL (a fix with no proof is never
                   PR'd — the cardinal rule).
    cfg:           the loaded config (prioritization weights for pick()).
    fix_runner:    the fix slot callable(issue, orient_result, repo) -> dict. The
                   default is a real Heimdall task brief; tests inject a fixture.
                   Its return value is NEVER the verdict.
    now:           an aware datetime pinned for deterministic pick timestamps.

    Returns a result dict describing the run (state, issue, orient, gate,
    attestation, pr_ready, pr_opened). Persists every transition into the queue's
    in_flight/flagged/resolved buckets."""
    q = issue_queue.IssueQueue(repo=repo)

    # one run_id per run_once invocation — the key telemetry consumers correlate a
    # loop iteration by (dossier §2). A stable id even when telemetry is disabled.
    loop_run_id = telemetry.new_run_id() if telemetry is not None else None

    # ── pick (REUSE piece b: claim-before-work idempotency) ───────────────────
    issue = q.pick(cfg=cfg, now=now)
    if issue is None:
        return {
            "state": IDLE,
            "issue": None,
            "reason": "nothing pickable (queue empty or all claimed)",
        }
    issue_id = issue["id"]

    try:
        # ── orient (REUSE SI-1) ───────────────────────────────────────────────
        orient_result = orient(repo)
        q.set_state(issue_id, ORIENTED)
        _emit_telemetry("issue_state", run_id=loop_run_id, phase="waves",
                        outcome=ORIENTED, extra={"issue_id": issue_id})

        # ── fix (the real Heimdall task slot; its return is NOT the verdict) ──
        runner = fix_runner or default_fix_runner
        fix_result = runner(issue, orient_result, repo)
        q.set_state(issue_id, FIXED)
        _emit_telemetry("issue_state", run_id=loop_run_id, phase="waves",
                        outcome=FIXED, extra={"issue_id": issue_id})

        # ── evidence discovery: the gate must have REAL proof to run ──────────
        # Augment the explicit --evidence (kept verbatim) with the acceptance
        # commands named in the ISSUE BODY + repo conventions (an executable
        # ./run_tests.sh in the clone). This is bug #20's core: the cloud dispatch
        # never threaded --evidence, so the gate ran an EMPTY list -> all_passed
        # False -> GATE_FAILED, refusing every real fix. A soft-import miss (no
        # issue_evidence module) degrades to the explicit list — unchanged behavior.
        resolved_evidence = list(evidence_cmds or [])
        if issue_evidence is not None:
            try:
                resolved_evidence = issue_evidence.resolve_evidence(
                    evidence_cmds, issue, repo)
            except Exception:  # noqa: BLE001 — discovery never breaks the loop
                resolved_evidence = list(evidence_cmds or [])

        # ── attest (REUSE SI-2) + GATE ────────────────────────────────────────
        record = attest(repo, base, resolved_evidence,
                        task="issue-loop:" + issue_id)

        return _gate_and_finish(
            q, issue, orient_result, fix_result, record, loop_run_id,
            evidence_cmds=resolved_evidence,
        )
    except Exception as exc:  # noqa: BLE001 — no path silently drops an issue
        # honest ERRORED transition: flag out-of-scope, never leave it claimed
        # nor silently resolved (dossier §4 failure transitions).
        q.flag(issue_id, "out-of-scope",
               evidence_ref="error:%s" % type(exc).__name__)
        # observe the honest ERRORED transition (the error CLASS only — a SHAPE
        # summary, never the exception payload; the scrubber bounds it anyway).
        _emit_telemetry(
            "issue_state", run_id=loop_run_id, phase="waves", outcome=ERRORED,
            error={"class": type(exc).__name__, "step": "issue-loop"},
            extra={"issue_id": issue_id},
        )
        return {
            "state": ERRORED,
            "issue": issue,
            "orient": locals().get("orient_result"),
            "error": str(exc),
            "pr_ready": False,
            "pr_opened": False,
        }


def _gate_and_finish(q, issue, orient_result, fix_result, record,
                     loop_run_id=None, evidence_cmds=None):
    """THE CARDINAL RULE wiring, made STRUCTURAL (dossier §5):

      verdict = read_verdict(record)          # record.evidence.all_passed ONLY
      if verdict is True:                      # PASS — and ONLY here:
          -> ATTESTED -> open_pr (soft) -> PR_OPEN / pr_ready
      else:                                    # FAIL:
          -> GATE_FAILED -> flagged{gate-failed}; NO open_pr is reachable.

    open_pr() is called from EXACTLY ONE place — inside the `if all_passed is True`
    branch below. A FAIL physically cannot reach it. There is no other call site."""
    issue_id = issue["id"]
    all_passed = read_verdict(record)  # the recorded real exit, never a claim
    gate = {
        "all_passed": all_passed,
        "evidence_ref": record.get("commit") or record.get("task"),
        "checks": (record.get("evidence") or {}).get("checks", []),
    }

    # observe the gate verdict (dossier §2): emit a `gate` event reading the SAME
    # recorded real exit the cardinal rule reads (record.evidence.all_passed) — NOT
    # a new verdict source. passed→the change is PR-ready; blocked→flagged.
    _emit_telemetry(
        "gate", run_id=loop_run_id, phase="gates", gate="oracle",
        outcome="passed" if all_passed is True else "blocked",
        extra={"issue_id": issue_id},
    )

    if all_passed is True:
        # ── PASS path — the ONLY path that can reach the PR layer ─────────────
        q.set_state(issue_id, ATTESTED)
        _emit_telemetry("issue_state", run_id=loop_run_id, phase="waves",
                        outcome=ATTESTED, gate="oracle",
                        extra={"issue_id": issue_id})
        pr_opened = False
        open_pr = _soft_import_open_pr()
        if open_pr is not None:
            # the pr layer (piece d) is present — hand it the issue + the SAME
            # SI-2 record. The layer asserts all_passed internally too (defence
            # in depth); we only ever call it on a verified PASS.
            open_pr(issue, record)
            pr_opened = True
        # else: SOFT-IMPORT miss — mark pr_ready and STOP. Do NOT fabricate a PR.
        q.set_state(issue_id, PR_OPEN, pr="pr-ready:" + issue_id)
        _emit_telemetry("issue_state", run_id=loop_run_id, phase="waves",
                        outcome=PR_OPEN, extra={"issue_id": issue_id})
        return {
            "state": PR_OPEN,
            "issue": issue,
            "orient": orient_result,
            "fix": fix_result,
            "attestation": record,
            "gate": gate,
            "evidence_cmds": list(evidence_cmds or []),
            "pr_ready": True,
            "pr_opened": pr_opened,
        }

    # ── FAIL path — GATE_FAILED -> flagged honestly; NO PR is ever opened ─────
    q.set_state(issue_id, GATE_FAILED)
    _emit_telemetry("issue_state", run_id=loop_run_id, phase="waves",
                    outcome=GATE_FAILED, gate="oracle",
                    extra={"issue_id": issue_id})
    q.flag(issue_id, "gate-failed", evidence_ref=gate["evidence_ref"])
    return {
        "state": GATE_FAILED,
        "issue": issue,
        "orient": orient_result,
        "fix": fix_result,
        "attestation": record,
        "gate": gate,
        "evidence_cmds": list(evidence_cmds or []),
        "pr_ready": False,
        "pr_opened": False,
    }


# ── subprocess + json helpers (the thin reuse seam) ───────────────────────────


def _run(cmd, capture=False):
    """Run a subprocess. capture=True keeps stdout (for the attest record); else
    stdout/stderr are discarded (we only need the exit code, e.g. comprehend
    load). Never raises on a non-zero exit — the caller branches on returncode."""
    return subprocess.run(
        cmd,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )


def _parse_json(text):
    """Parse JSON text to a dict, or None on any failure."""
    if not text:
        return None
    try:
        data = json.loads(text)
    except (ValueError, TypeError):
        return None
    return data if isinstance(data, dict) else None


def _read_json(path):
    """Read+parse a JSON file to a dict, or None when absent/unparseable."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (FileNotFoundError, ValueError, OSError):
        return None
    return data if isinstance(data, dict) else None


# ── status (a read-only at-a-glance over the queue's buckets) ─────────────────


def status(repo):
    """The loop's at-a-glance status: the queue store counts plus the in_flight
    machine-states. Read-only — picks nothing, touches nothing."""
    q = issue_queue.IssueQueue(repo=repo)
    in_flight = {
        iid: rec.get("state") for iid, rec in q.data["in_flight"].items()
    }
    st = q.status()
    st["in_flight_states"] = in_flight
    return st


# ── CLI core (driven by bin/heimdall-issue-loop) ──────────────────────────────


def _cli(argv):
    """CLI core. Subcommands:
      run-once [--repo R] [--base REF] [--evidence CMD]... [--config C] [--print]
      run      [--repo R] [--base REF] [--evidence CMD]... [--config C] [--max N]
      status   [--repo R]
    Returns an exit code; prints JSON to stdout, human notes to stderr."""
    import argparse

    p = argparse.ArgumentParser(prog="heimdall-issue-loop", add_help=True)
    p.add_argument("subcommand")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--base", default="HEAD")
    p.add_argument("--evidence", action="append", default=[])
    p.add_argument("--config")
    p.add_argument("--max", type=int, default=0)
    p.add_argument("--print", dest="do_print", action="store_true")
    args = p.parse_args(argv)

    repo = os.path.abspath(args.repo)
    cfg = _load_cfg(args.config)

    if args.subcommand == "run-once":
        result = run_once(repo, base=args.base, evidence_cmds=args.evidence, cfg=cfg)
        _emit(result, args.do_print)
        return 0

    if args.subcommand == "run":
        # drain the queue: run-once until IDLE (nothing pickable) or --max reached.
        results = []
        n = 0
        while True:
            result = run_once(repo, base=args.base,
                              evidence_cmds=args.evidence, cfg=cfg)
            if result["state"] == IDLE:
                break
            results.append(result)
            n += 1
            if args.max and n >= args.max:
                break
        out = {"ran": n, "results": results}
        print(json.dumps(out, indent=2, sort_keys=True))
        sys.stderr.write("issue-loop run: processed %d issue(s)\n" % n)
        return 0

    if args.subcommand == "status":
        print(json.dumps(status(repo), indent=2, sort_keys=True))
        return 0

    print("error: unknown subcommand: %s" % args.subcommand, file=sys.stderr)
    return 2


def _emit(result, do_print):
    """Print the run-once result (always to stdout when --print; a one-line human
    summary to stderr regardless)."""
    if do_print:
        print(json.dumps(result, indent=2, sort_keys=True))
    issue = result.get("issue") or {}
    sys.stderr.write(
        "issue-loop run-once: %s — id=%s pr_ready=%s pr_opened=%s\n"
        % (
            result.get("state"),
            issue.get("id", "(none)"),
            result.get("pr_ready", False),
            result.get("pr_opened", False),
        )
    )


def _load_cfg(cfg_arg):
    """Load the config dict from a @file/inline-JSON arg, or {} when absent."""
    if not cfg_arg:
        return {}
    if cfg_arg.startswith("@"):
        with open(cfg_arg[1:], "r", encoding="utf-8") as fh:
            return json.load(fh)
    return json.loads(cfg_arg)


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
