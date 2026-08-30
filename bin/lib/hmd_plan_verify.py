#!/usr/bin/env python3
"""hmd_plan_verify.py -- the engine behind bin/heimdall-plan-verify.

WHY THIS EXISTS. bin/decompose emits dependency-ordered waves, agents/planner.md and
agents/architect.md write PLAN files with acceptance criteria, and bin/heimdall-state's
sweep-receipt gate (grep 'receipts/last-sweep.json') makes a green TEST claim
mechanically undeniable. But nothing ever checked a plan's own acceptance criteria
against what actually happened in the tree. "Wave done" was an assertion, never a
verified fact -- the same defect class as a session reporting "it's running" or "it
landed" from last-known state instead of a fresh check.

WHAT THIS DOES. Given a PLAN markdown file, extracts every acceptance criterion and
classifies each one:

  MET           the criterion is a real shell command; running it now produced the
                stated result.
  UNMET         the criterion is a real shell command; running it now did NOT produce
                the stated result.
  NOT_RUNNABLE  no shell command could be extracted from the criterion text (it is
                prose). Never coerced into MET or UNMET -- an unrunnable criterion is
                reported unrunnable, honestly, every time.

MARKDOWN SCHEMA THIS PARSES (matches docs/superpowers/plans/*.md as written by
agents/planner.md and agents/architect.md):

    ## 2. Waves
    ### Wave 0 -- <title>
    #### Task 0.1 -- <title>
    - **Acceptance criteria:**
      - [ ] `<shell command>`
      - [ ] `<shell command>` outputs `<expected stdout, exact match>`
      - [ ] `<shell command>` exits <N>
      - [ ] <prose with no backtick-wrapped command>          <- NOT_RUNNABLE

A criterion bullet's pass condition is read off the text itself: "outputs `X`" means
exact stdout match; "exits N" means an explicit exit code; a bare backticked command
(the overwhelming common case measured in this repo's own plans -- see COVERAGE note
below) means the house convention that a boolean shell predicate must exit 0.

JSON SIDECAR SCHEMA (when bin/decompose's auto-emit threshold produces one --
see a plan's own "waves.json" section, and docs/superpowers/plans/2026-07-09-
anonymized-issue-collection.waves.json for a real example): a `<plan-without-.md>
.waves.json` file next to the plan, of the shape
    {"waves": [{"id": 0, "tasks": [{"id": "...", "acceptance": ["<cmd>", ...]}]}]}
is preferred over markdown when present, because each `acceptance` entry is already a
clean, unambiguous shell command string (no prose-parsing needed at all). Every entry
is evaluated as a boolean predicate (exit 0 = MET), matching the `test -f` / `grep -q`
idiom the sidecar's own emitter uses.

MEASURED, NOT ASSUMED: the honest fraction of runnable-vs-prose criteria varies plan
to plan -- see test/heimdall-plan-verify.test.sh's header comment for the measured
numbers against this repo's real plans as of the day this was written, and run this
tool against any plan directly for a live number.

CADENCE, NOT MERGES. --require-sweep additionally ties a *wave's* completeness to
bin/heimdall-state's own sweep receipt (.heimdall/receipts/last-sweep.json, or
$HEIMDALL_HOME/receipts/last-sweep.json): a wave counts complete only when its own
criteria are met AND a sweep receipt exists that is fresh (HEAD matches), clean (tree
was clean while it ran), and green (exit 0). This file is the fourth call site for
that receipt path -- grep 'receipts/last-sweep.json' across bin/heimdall-state,
test/run-all.sh, bin/heimdall-delivery-audit, and here -- deliberately reusing the
exact same freshness rules rather than inventing a second notion of "fresh."

WHAT THIS CANNOT DO. This tool measures and reports; like heimdall-deadcode, it does
not delete, does not fix, and cannot force a wave to be treated as verified. A prose
criterion is not a defect this tool can repair -- flagging it honestly (NOT_RUNNABLE)
is the entire contract. Wiring this tool's exit code into an actual push/merge gate is
a separate, deliberate decision belonging to whoever owns that gate, not something
this file does on its own.

EXIT CODES (of bin/heimdall-plan-verify, which execs this file):
  0  the scan ran; zero UNMET criteria in scope (and, with --require-sweep, the
     sweep receipt corroborates completeness too).
  1  the scan ran; at least one UNMET criterion in scope, or --require-sweep's
     receipt check failed.
  2  the scan could not run at all: missing/unreadable plan file, bad arguments, or
     a requested --wave not found in the plan. Fail-open on plumbing: reported,
     never a crash, never rendered as a pass.
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_TIMEOUT = 120  # seconds, per criterion command

MET = "MET"
UNMET = "UNMET"
NOT_RUNNABLE = "NOT_RUNNABLE"


# ─────────────────────────── data model ─────────────────────────────────────

class Criterion:
    def __init__(self, text, cmd, expect_kind, expect_value, source):
        self.text = text                # raw criterion text, for reporting
        self.cmd = cmd                  # shell command string, or None if NOT_RUNNABLE
        self.expect_kind = expect_kind  # "exit" | "stdout" | None
        self.expect_value = expect_value
        self.source = source            # "markdown" | "json"


class Task:
    def __init__(self, task_id, title):
        self.id = task_id
        self.title = title
        self.criteria = []  # list[Criterion]


class Wave:
    def __init__(self, wave_id, title=""):
        self.id = wave_id
        self.title = title
        self.tasks = []  # list[Task]


# ─────────────────────────── markdown parsing ───────────────────────────────

_WAVE_RE = re.compile(r'^###\s+Wave\s+(\d+)\b\s*(?:—|-|:)?\s*(.*)$')
_TASK_RE = re.compile(r'^####\s+Task\s+([0-9]+(?:\.[0-9]+)?)\b\s*(?:—|-|:)?\s*(.*)$')
_ACCEPTANCE_HEADER_RE = re.compile(r'^\s*-\s*\*\*Acceptance criteria:\*\*\s*$')
_CRITERION_LINE_RE = re.compile(r'^\s+-\s*\[[ xX]\]\s*(.*\S)\s*$')
_BACKTICK_RE = re.compile(r'`([^`]*)`')
_OUTPUTS_RE = re.compile(r'^outputs\s+`([^`]*)`')
_EXITS_RE = re.compile(r'^exits\s+(-?\d+)\b')


def _parse_criterion_text(raw_text):
    """One `- [ ] ...` line's text -> a Criterion. cmd=None means NOT_RUNNABLE.

    Known limitation, stated rather than hidden: a command containing a literal
    backtick character (not `$(...)`) cannot be extracted by this single-pair regex.
    Not observed in this repo's plans as of writing (they use `$(...)` throughout).
    """
    m = _BACKTICK_RE.search(raw_text)
    if not m:
        return Criterion(raw_text, None, None, None, "markdown")
    cmd = m.group(1)
    remainder = raw_text[m.end():].strip()

    m_out = _OUTPUTS_RE.match(remainder)
    if m_out:
        return Criterion(raw_text, cmd, "stdout", m_out.group(1), "markdown")

    m_exit = _EXITS_RE.match(remainder)
    if m_exit:
        return Criterion(raw_text, cmd, "exit", int(m_exit.group(1)), "markdown")

    # Bare command, or command followed only by descriptive prose (e.g. an em-dash
    # explanation) -- the house convention, confirmed against every criterion in
    # docs/superpowers/plans/2026-08-29-agent-fallback-coverage.md's Wave 0 and
    # Wave 1: a bare backticked shell command is a boolean predicate that must
    # succeed.
    return Criterion(raw_text, cmd, "exit", 0, "markdown")


def parse_markdown(text):
    waves = {}
    order = []
    cur_wave = None
    cur_task = None
    in_acceptance = False

    for line in text.splitlines():
        m_wave = _WAVE_RE.match(line)
        if m_wave:
            wid = int(m_wave.group(1))
            cur_wave = waves.get(wid)
            if cur_wave is None:
                cur_wave = Wave(wid, m_wave.group(2).strip())
                waves[wid] = cur_wave
                order.append(wid)
            cur_task = None
            in_acceptance = False
            continue

        m_task = _TASK_RE.match(line)
        if m_task:
            if cur_wave is None:
                # A Task header outside any Wave section should not happen in a
                # conforming plan; open an implicit wave 0 rather than dropping data.
                cur_wave = waves.get(0)
                if cur_wave is None:
                    cur_wave = Wave(0, "")
                    waves[0] = cur_wave
                    order.append(0)
            cur_task = Task(m_task.group(1), m_task.group(2).strip())
            cur_wave.tasks.append(cur_task)
            in_acceptance = False
            continue

        if _ACCEPTANCE_HEADER_RE.match(line):
            in_acceptance = cur_task is not None
            continue

        if in_acceptance:
            m_crit = _CRITERION_LINE_RE.match(line)
            if m_crit:
                cur_task.criteria.append(_parse_criterion_text(m_crit.group(1)))
                continue
            # Any other non-blank line ends the acceptance-criteria block (the next
            # "- **Verify:**" bullet, a heading already handled above, ...). Blank
            # lines do not end it, in case a list has incidental spacing.
            if line.strip() != "":
                in_acceptance = False

    return [waves[w] for w in order]


# ─────────────────────────── json sidecar parsing ───────────────────────────

def parse_json_sidecar(obj):
    waves = []
    for w in obj.get("waves", []):
        wave = Wave(int(w.get("id", len(waves))), "")
        for t in w.get("tasks", []):
            task = Task(str(t.get("id", "?")), t.get("agent", "") or "")
            for raw_cmd in t.get("acceptance", []):
                cmd = raw_cmd if isinstance(raw_cmd, str) else json.dumps(raw_cmd)
                task.criteria.append(Criterion(cmd, cmd, "exit", 0, "json"))
            wave.tasks.append(task)
        waves.append(wave)
    return waves


# ─────────────────────────── execution ──────────────────────────────────────

def run_criterion(criterion, cwd, timeout):
    """Never raises. A broken command is UNMET with a reason attached, not an
    uncaught exception -- fail-open on plumbing, never a wedge."""
    if criterion.cmd is None:
        return NOT_RUNNABLE, {"reason": "prose criterion, no shell command found"}

    try:
        proc = subprocess.run(
            ["bash", "-c", criterion.cmd],
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return UNMET, {"reason": "timeout after %ss" % timeout, "cmd": criterion.cmd}
    except OSError as exc:
        return UNMET, {"reason": "could not execute: %s" % exc, "cmd": criterion.cmd}

    stdout = proc.stdout.decode("utf-8", "replace")
    stderr = proc.stderr.decode("utf-8", "replace")

    if criterion.expect_kind == "stdout":
        actual = stdout.strip()
        expected = (criterion.expect_value or "").strip()
        status = MET if actual == expected else UNMET
        return status, {
            "cmd": criterion.cmd,
            "expected_stdout": expected,
            "actual_stdout": actual,
            "returncode": proc.returncode,
            "stderr": stderr[-2000:],
        }

    expected_rc = criterion.expect_value if criterion.expect_value is not None else 0
    status = MET if proc.returncode == expected_rc else UNMET
    return status, {
        "cmd": criterion.cmd,
        "expected_exit": expected_rc,
        "actual_exit": proc.returncode,
        "stdout": stdout[-2000:],
        "stderr": stderr[-2000:],
    }


# ─────────────────────────── sweep-receipt tie-in ───────────────────────────

def repo_root(start):
    """git toplevel for `start`, canonicalized the same way sweep receipts are
    (see test/sweep-receipt-gate.test.sh's own note on macOS /var vs /private/var
    symlink forms) -- falls back to `start` itself if git is unavailable or the
    directory is not inside a repo, rather than raising."""
    with contextlib.suppress(OSError):
        proc = subprocess.run(
            ["git", "-C", str(start), "rev-parse", "--show-toplevel"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
        )
        if proc.returncode == 0:
            return proc.stdout.decode("utf-8", "replace").strip()
    return str(start)


def _current_head(repo):
    with contextlib.suppress(OSError):
        proc = subprocess.run(
            ["git", "-C", repo, "rev-parse", "HEAD"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
        )
        if proc.returncode == 0:
            return proc.stdout.decode("utf-8", "replace").strip()
    return None


def sweep_receipt_status(repo, heimdall_home=None):
    """Mirrors bin/heimdall-state's check-quality-gates sweep-receipt block exactly
    (same path convention, same freshness rules) so this tool and that gate can never
    quietly disagree about what "fresh" means."""
    home = heimdall_home or os.environ.get("HEIMDALL_HOME") or os.path.join(repo, ".heimdall")
    receipt_path = os.path.join(home, "receipts", "last-sweep.json")

    if not os.path.isfile(receipt_path):
        return {"ok": False, "reason": "no sweep receipt at %s" % receipt_path, "path": receipt_path}

    try:
        with open(receipt_path, "r", encoding="utf-8") as fh:
            receipt = json.load(fh)
    except (OSError, ValueError) as exc:
        return {"ok": False, "reason": "sweep receipt is not valid JSON: %s" % exc, "path": receipt_path}

    cur_sha = _current_head(repo)
    r_repo = receipt.get("repo")
    r_sha = receipt.get("head_sha")
    r_clean = receipt.get("tree_clean")
    r_rc = receipt.get("exit_code")

    if r_repo and r_repo != repo:
        return {"ok": False, "reason": "receipt recorded for a different repo (%s, this checkout is %s)" % (r_repo, repo), "path": receipt_path}
    if not r_sha or r_sha != cur_sha:
        return {"ok": False, "reason": "receipt is STALE (receipt HEAD %s != current HEAD %s)" % (r_sha or "<none>", cur_sha or "<none>"), "path": receipt_path}
    if r_clean is not True:
        return {"ok": False, "reason": "receipt recorded a DIRTY tree", "path": receipt_path}
    if r_rc != 0:
        return {"ok": False, "reason": "receipt recorded a FAILING run (exit %s)" % r_rc, "path": receipt_path}
    return {"ok": True, "reason": "fresh, clean, green receipt matches current HEAD", "path": receipt_path}


# ─────────────────────────── report building ────────────────────────────────

def build_report(plan_path, waves, source_kind, root, timeout):
    out_waves = []
    tot_met = tot_unmet = tot_nr = 0
    for wave in waves:
        w_met = w_unmet = w_nr = 0
        out_tasks = []
        for task in wave.tasks:
            t_met = t_unmet = t_nr = 0
            out_criteria = []
            for c in task.criteria:
                status, detail = run_criterion(c, root, timeout)
                if status == MET:
                    t_met += 1
                elif status == UNMET:
                    t_unmet += 1
                else:
                    t_nr += 1
                out_criteria.append({
                    "text": c.text, "cmd": c.cmd, "status": status,
                    "detail": detail, "source": c.source,
                })
            out_tasks.append({
                "id": task.id, "title": task.title, "criteria": out_criteria,
                "met": t_met, "unmet": t_unmet, "not_runnable": t_nr,
            })
            w_met += t_met
            w_unmet += t_unmet
            w_nr += t_nr
        out_waves.append({
            "id": wave.id, "title": wave.title, "tasks": out_tasks,
            "met": w_met, "unmet": w_unmet, "not_runnable": w_nr,
        })
        tot_met += w_met
        tot_unmet += w_unmet
        tot_nr += w_nr

    return {
        "plan": str(plan_path),
        "source": source_kind,
        "waves": out_waves,
        "totals": {"met": tot_met, "unmet": tot_unmet, "not_runnable": tot_nr},
    }


def _truncate(s, n=100):
    s = s.replace("\n", " ")
    return s if len(s) <= n else s[: n - 1] + "…"


def render_text(report):
    lines = []
    lines.append("heimdall-plan-verify -- %s (source: %s)" % (report["plan"], report["source"]))
    lines.append("")
    for wave in report["waves"]:
        title = (" -- " + wave["title"]) if wave.get("title") else ""
        lines.append("Wave %d%s" % (wave["id"], title))
        for task in wave["tasks"]:
            ttitle = (" -- " + task["title"]) if task.get("title") else ""
            lines.append("  Task %s%s: %d MET, %d UNMET, %d NOT-RUNNABLE" % (
                task["id"], ttitle, task["met"], task["unmet"], task["not_runnable"]))
            for c in task["criteria"]:
                display = c["cmd"] if c["cmd"] is not None else c["text"]
                lines.append("    %-12s %s" % (c["status"], _truncate(display)))
                if c["status"] == "UNMET":
                    d = c["detail"]
                    if "expected_stdout" in d:
                        lines.append("                 expected stdout %r, got %r" % (
                            d["expected_stdout"], d["actual_stdout"]))
                    elif "expected_exit" in d:
                        lines.append("                 expected exit %s, got %s" % (
                            d["expected_exit"], d["actual_exit"]))
                    else:
                        lines.append("                 %s" % d.get("reason", ""))
        lines.append("")
    t = report["totals"]
    lines.append("TOTALS: %d MET, %d UNMET, %d NOT-RUNNABLE (across %d criteria)" % (
        t["met"], t["unmet"], t["not_runnable"], t["met"] + t["unmet"] + t["not_runnable"]))
    if report.get("sweep") is not None:
        s = report["sweep"]
        lines.append("sweep receipt: %s -- %s" % ("OK" if s["ok"] else "FAIL", s["reason"]))
    lines.append("")
    lines.append("verdict: %s" % report["verdict"])
    return "\n".join(lines)


def _emit_error(as_json, message):
    if as_json:
        print(json.dumps({"error": message}))
    else:
        print("heimdall-plan-verify: %s" % message, file=sys.stderr)


# ─────────────────────────── CLI ─────────────────────────────────────────────

def build_argparser():
    ap = argparse.ArgumentParser(
        prog="heimdall-plan-verify",
        description="Extract a PLAN file's acceptance criteria, run the runnable ones, "
                    "and report MET / UNMET / NOT_RUNNABLE per wave and task.",
    )
    ap.add_argument("plan", help="path to a PLAN markdown file")
    ap.add_argument("--wave", type=int, default=None, metavar="N",
                    help="only evaluate criteria for wave N")
    ap.add_argument("--json", action="store_true", help="emit structured JSON instead of text")
    ap.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT,
                    help="per-criterion command timeout in seconds (default %(default)s)")
    ap.add_argument("--require-sweep", action="store_true",
                    help="also require a fresh sweep receipt matching current HEAD for "
                         "wave completeness; requires --wave N")
    ap.add_argument("--heimdall-home", default=None, metavar="DIR",
                    help="override HEIMDALL_HOME for the sweep-receipt lookup (testing only)")
    return ap


def main(argv):
    ap = build_argparser()
    args = ap.parse_args(argv)

    if args.require_sweep and args.wave is None:
        _emit_error(args.json, "--require-sweep requires --wave N (wave completeness is "
                                "evaluated per wave, not for a whole plan)")
        return 2

    plan_path = Path(args.plan)
    if not plan_path.is_file():
        _emit_error(args.json, "PLAN NOT FOUND: %s" % plan_path)
        return 2

    root = repo_root(plan_path.parent)

    waves = []
    source_kind = "markdown"
    sidecar_name = plan_path.name[:-3] + ".waves.json" if plan_path.name.endswith(".md") \
        else plan_path.name + ".waves.json"
    sidecar = plan_path.parent / sidecar_name
    if sidecar.is_file():
        try:
            obj = json.loads(sidecar.read_text(encoding="utf-8"))
            waves = parse_json_sidecar(obj)
            source_kind = "json"
        except (OSError, ValueError) as exc:
            _emit_error(args.json, "sidecar %s exists but is not valid JSON (%s) -- "
                                    "falling back to markdown" % (sidecar, exc))
            waves = []

    if not waves:
        try:
            text = plan_path.read_text(encoding="utf-8")
        except OSError as exc:
            _emit_error(args.json, "cannot read plan file %s: %s" % (plan_path, exc))
            return 2
        waves = parse_markdown(text)
        source_kind = "markdown"

    if not waves:
        _emit_error(args.json, "no waves found in %s -- nothing to verify "
                                "(expected '### Wave N' headings under '## 2. Waves', "
                                "or a <plan>.waves.json sidecar)" % plan_path)
        return 2

    if args.wave is not None:
        waves = [w for w in waves if w.id == args.wave]
        if not waves:
            _emit_error(args.json, "wave %d not found in %s" % (args.wave, plan_path))
            return 2

    report = build_report(plan_path, waves, source_kind, root, args.timeout)

    if args.require_sweep:
        sweep = sweep_receipt_status(root, args.heimdall_home)
        wave_complete = report["totals"]["unmet"] == 0 and sweep["ok"]
        if wave_complete:
            verdict = "WAVE %d COMPLETE" % args.wave
        else:
            reasons = []
            if report["totals"]["unmet"] > 0:
                reasons.append("%d UNMET criteria" % report["totals"]["unmet"])
            if not sweep["ok"]:
                reasons.append("sweep receipt: %s" % sweep["reason"])
            verdict = "WAVE %d INCOMPLETE -- %s" % (args.wave, "; ".join(reasons))
        report["sweep"] = sweep
        rc = 0 if wave_complete else 1
    else:
        report["sweep"] = None
        if report["totals"]["unmet"] == 0:
            verdict = "CLEAN -- 0 UNMET"
        else:
            verdict = "%d UNMET criteria -- not verified" % report["totals"]["unmet"]
        rc = 0 if report["totals"]["unmet"] == 0 else 1

    if report["totals"]["not_runnable"] > 0:
        verdict += " (%d criteria are NOT_RUNNABLE prose -- never guessed, never counted " \
                   "as a pass)" % report["totals"]["not_runnable"]
    report["verdict"] = verdict

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(render_text(report))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
