#!/usr/bin/env python3
"""runhmd_prove -- `hmd prove` (RP2): "do all gates pass, and has each gate been shown to fail first?"

Where `hmd attack` attacks a target, `hmd prove` proves the GATES of a repository. A gate is an
oracle domain: a directory evals/oracles/<id>/ that ships fixtures/mutants -- exactly the set
bin/heimdall-gate-run enforces at push time. For every gate this runs bin/falsify (the gate must
accept its golden artifact and reject every committed single-defect mutant) and then the regression
corpus (evals/corpus, bin/corpus). It answers with one runhmd.prove/1 document.

What each field is, and where it comes from (nothing here is asserted, every value is read off a run):

  gates[].status          "pass" iff the gate accepted its own golden artifact (falsify's false-RED
                          check), "fail" iff it rejected it. For a gate whose golden arm drives the
                          repository's own code (team-copilot -> bin/lib/redum.py, ...) that is a live
                          check of that code against its independent reference.
  gates[].falsified       true iff `falsify <gate> --assert-score 1.0` exited 0: golden green AND every
                          mutant red. Judged on falsify's EXIT CODE; its SCORE line is only read for the
                          number and must agree with it.
  gates[].falsify_score   mutants killed / mutants (0 when the golden failed).
  regression_tests        the case corpus: passed = cases still caught, failed = cases missed, read off
                          bin/corpus's `corpus-catch-rate: N/M` contract line (0/0 without a corpus).
  verdict                 derived with runhmd_schema._unproven_reasons -- the very function the
                          validator uses to check rule P2 -- so the verdict and its own validation
                          cannot disagree: PROVEN iff there is a gate, every gate passes AND is
                          falsified, and no regression case failed. A gate that passes but was never
                          shown to fail makes the verdict DENIED.

The document is a runhmd.prove/1: a SIBLING of runhmd.verdict/1 in the same schema file
(docs/schemas/runhmd.verdict.v1.json, `x-documents`), sharing its verdict / gate / regression_tests
definitions. It is NOT an envelope around a runhmd.verdict/1 document. It is validated against that
single schema (bin/lib/runhmd_schema.py) before it is printed: a document that violates its own
contract is an error, never output.

It deliberately does not call bin/heimdall-gate-run, which composes the same two runners but (a) stops
at the first red gate, so the rest would be unreported, (b) overwrites .heimdall/verdict.json and
emits a metric record, and (c) runs `bin/corpus run`, which rewrites evals/corpus/CORPUS-STATUS.md.
prove is read-only: it runs `bin/corpus status` and writes nothing into the repository.

What it does not prove: that the fixtures are good (a gate is only as falsifiable as the mutants its
repository committed), or that the repository's own test suite passes.

Fail closed: if falsify or the corpus gives no verdict this module can read (an unknown output shape, a
usage error, an exit code that contradicts the counts, a runner that outlives its wall clock) there is
NO verdict -- exit 5 and an error document -- and one healthy gate is never allowed to vouch for the rest.

Isolation: the gates run in their own process group (a timeout or Ctrl-C kills the whole tree), with a
private TMPDIR and HOME that are removed afterwards, no GIT_* variables, and bytecode writing off.
The repository is read; prove itself never writes to it. The gates ARE the repository's code, so
consent comes first, as in `hmd attack`.

Library use (tests): main(argv) -> exit code; classify_falsify / classify_corpus / discover_gates /
build_doc.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
PLUGIN_DIR = os.path.dirname(os.path.dirname(HERE))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import runhmd_schema  # noqa: E402
from runhmd_attack import EXIT_CONSENT, EXIT_DENIED, EXIT_INFRA, EXIT_PROVEN, EXIT_USAGE  # noqa: E402

EXIT_INTERRUPTED = 130
DEFAULT_TIMEOUT_S = 300

# A gate id is handed to bin/falsify as an argument and used as a path component: it must be a plain
# name, never something falsify would read as a flag or a path.
_GATE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

# What bin/falsify and bin/corpus print. All anchored at column 0 (or falsify's two-space golden line):
# text a gate controls (first_divergence, case details) can only appear indented or on a line of its own
# choosing, and each pattern must match EXACTLY once, so a forged line makes a run unreadable, never better.
_SCORE = re.compile(r"^SCORE: ([0-9]+)/([0-9]+) = ", re.M)
_SURVIVED = re.compile(r"^SURVIVED: (.+)$", re.M)
_GOLDEN_FAILED = re.compile(r"^GOLDEN FAILED: ", re.M)
_GOLDEN_RED = re.compile(r"^  golden report\.json status='fail' \(expected pass\)", re.M)
_CORPUS_RATE = re.compile(r"^corpus-catch-rate: ([0-9]+)/([0-9]+)$", re.M)

HELP = """hmd prove -- do all gates pass, and has each gate been shown to fail first?

usage:
  hmd prove [<dir>] [options]

Proves the gates of a repository (default: the git repository around the current directory). A gate is an
oracle domain: a directory evals/oracles/<id>/ that ships fixtures/mutants -- the set bin/heimdall-gate-run
enforces at push time. For every gate prove runs bin/falsify (the gate must accept its golden artifact and
reject every committed single-defect mutant), then the regression corpus in evals/corpus (bin/corpus). Gates
run in sorted order and every one is reported: prove does not stop at the first red gate.

The verdict is derived from those runs, never asserted:
  PROVEN  there is at least one gate, every gate passes AND is falsified, and no regression case failed
  DENIED  anything else -- including a gate that passes but was never shown to fail (a mutant survives)

per gate:
  status          pass: the gate accepted its own golden artifact (for a gate whose golden arm drives the
                  repository's own code, e.g. team-copilot, that is a live check of that code against its
                  independent reference); fail: it rejected it, so the gate or the code it grades is red
  falsified       true when every committed mutant was rejected (falsify score 1.0)
  falsify_score   mutants killed / mutants (0 when the golden failed)
regression_tests  the case corpus: passed = cases still caught, failed = cases missed (0 and 0 without one)

What this does not prove: that the fixtures are good, or that the repository's own test suite passes.
prove runs code from the repository (each gate's run.sh and the corpus), so it asks first. It writes
nothing into the repository, makes no network call and calls no model.

options:
  --json        print the runhmd.prove/1 document on stdout (docs/schemas/runhmd.verdict.v1.json); the text
                report is a render of it. With --json nothing else is printed on a verdict.
  --yes, -y     consent without a prompt (required when stdin is not a terminal)
  -h, --help    this text

exit codes:
  0  PROVEN: every gate passes and is falsified, no regression case failed
  1  DENIED: a gate failed, a gate was never shown to fail, or a regression case failed
  2  usage or config error (bad flag, no such directory, no gate to prove)
  3  consent required: stdin is not a terminal and --yes was not given, or the prompt was declined
  5  infrastructure error: a gate or the corpus could not be run to a verdict
130  interrupted (Ctrl-C)       143  terminated (SIGTERM)

environment:
  RUNHMD_PROVE_TIMEOUT_S   wall clock for each gate and for the corpus, in seconds (default 300)
"""


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        sys.stderr.write("hmd prove: %s (see hmd prove --help)\n" % message)
        sys.exit(EXIT_USAGE)


def _parser():
    p = _Parser(prog="hmd prove", add_help=False, allow_abbrev=False)
    p.add_argument("repo", nargs="*")
    p.add_argument("--json", action="store_true")
    p.add_argument("--yes", "-y", action="store_true")
    return p


def _emit(obj, as_json, human):
    """A result on stdout (JSON mode) or its human text on stderr; never both."""
    if as_json:
        sys.stdout.write(json.dumps(obj, indent=2) + "\n")
    else:
        sys.stderr.write(human + "\n")


def _error(args, repo, kind, detail, code):
    _emit({"error": kind, "detail": detail, "repo": repo}, args.json, "hmd prove: %s: %s" % (kind, detail))
    return code


def _clean_env():
    """The caller's environment minus GIT_*: a hook exports GIT_DIR / GIT_INDEX_FILE, and a gate that builds
    a throwaway git fixture would otherwise operate on the caller's repository."""
    return {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def _gate_env(work):
    """The environment every runner gets: a private HOME and TMPDIR inside `work`, no bytecode."""
    home, tmp = os.path.join(work, "home"), os.path.join(work, "tmp")
    os.makedirs(home)
    os.makedirs(tmp)
    env = _clean_env()
    env.update(HOME=home, TMPDIR=tmp, PYTHONDONTWRITEBYTECODE="1")
    return env


def _timeout_s():
    """(seconds, None), or (None, why) when RUNHMD_PROVE_TIMEOUT_S is set to something unusable."""
    raw = os.environ.get("RUNHMD_PROVE_TIMEOUT_S")
    if raw is None:
        return DEFAULT_TIMEOUT_S, None
    if re.fullmatch(r"[0-9]+", raw) and int(raw) > 0:
        return int(raw), None
    return None, "RUNHMD_PROVE_TIMEOUT_S must be a positive whole number of seconds, got %r" % raw


def _resolve_repo(arg):
    """Absolute real path of the repository to prove: the argument as given, else the git repository
    around the current directory, else the current directory. Looks at nothing but the path itself."""
    if arg is not None:
        return os.path.realpath(arg)
    cwd = os.getcwd()
    try:
        done = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"], stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=10, env=_clean_env())
    except (OSError, subprocess.SubprocessError):
        return os.path.realpath(cwd)
    top = done.stdout.strip() if done.returncode == 0 else ""
    return os.path.realpath(top or cwd)


def _consent(args, repo):
    """True when the repository's gates may be run: --yes, or an interactive yes on a real terminal."""
    if args.yes:
        return True
    interactive = bool(getattr(sys.stdin, "isatty", lambda: False)())
    if not interactive:
        _emit({"error": "consent_required", "repo": repo,
               "detail": "stdin is not a terminal and --yes was not given: hmd prove runs the repository's gate code and never assumes consent"},
              args.json,
              "hmd prove: consent required. It runs code from the repository (its oracle gates and case corpus); "
              "stdin is not a terminal, so pass --yes to allow it.")
        return False
    sys.stderr.write(
        "hmd prove will EXECUTE code from the repository below: each oracle gate in evals/oracles/ (through bin/falsify)\n"
        "and the case corpus in evals/corpus/ (through bin/corpus), in a private TMPDIR and HOME removed afterwards.\n"
        "It makes no network calls, calls no model, and itself writes nothing to the repository.\n"
        "  repo: %s\n"
        "Proceed? [y/N] " % repo)
    sys.stderr.flush()
    answer = sys.stdin.readline().strip().lower()
    if answer in ("y", "yes"):
        return True
    _emit({"error": "consent_required", "detail": "consent was not given", "repo": repo}, args.json, "hmd prove: consent not given.")
    return False


def _tool(name):
    path = os.path.join(PLUGIN_DIR, "bin", name)
    return path if os.path.isfile(path) and os.access(path, os.X_OK) else None


def discover_gates(oracles):
    """(sorted gate ids, None), or (None, (error kind, detail)). A gate is a directory under `oracles`
    that has fixtures/mutants -- the same set bin/heimdall-gate-run enforces; dot-directories are skipped
    like its glob skips them. No evals/oracles at all is zero gates, not an error."""
    try:
        names = sorted(os.listdir(oracles))
    except FileNotFoundError:
        return [], None
    except OSError as exc:
        return None, ("cannot_read", "cannot read %s: %s" % (oracles, exc))
    gates = []
    for name in names:
        if name.startswith(".") or not os.path.isdir(os.path.join(oracles, name, "fixtures", "mutants")):
            continue
        if not _GATE_ID.match(name):
            return None, ("bad_gate_id", "the gate directory %r under %s is not a plain gate id (letters, digits, '.', '_' and '-', "
                                         "starting with a letter or digit): it could not be handed to bin/falsify as one" % (name, oracles))
        gates.append(name)
    return gates, None


def gate_types(oracles):
    """{gate id: gate_type} from evals/oracles/registry.json. A gate it does not list (or no registry at
    all) is reported as 'unregistered': the type is a label on the document, never an input to the verdict."""
    try:
        with open(os.path.join(oracles, "registry.json"), "r", encoding="utf-8") as fh:
            registry = json.load(fh)
    except (OSError, ValueError):
        return {}
    entries = registry.get("oracles") if isinstance(registry, dict) else None
    if not isinstance(entries, dict):
        return {}
    return {gate: entry["gate_type"] for gate, entry in entries.items()
            if isinstance(entry, dict) and isinstance(entry.get("gate_type"), str) and entry["gate_type"]}


def classify_falsify(code, out):
    """What one `bin/falsify <gate> --assert-score 1.0` run proved: (status, falsified, score, survivors),
    or None when the run says nothing this module can trust.

    The exit code is the authority for `falsified` (0 iff the golden passed AND no mutant survived); the
    SCORE line only supplies the number and must agree with it. Anything unreadable -- an unknown shape,
    a usage error, an exit code that contradicts the score, a forged duplicate line, a golden that gave no
    report (the environment, not the gate) -- is None: no verdict, never a pass.
    """
    if _GOLDEN_FAILED.search(out):
        # The gate rejected its own known-correct fixture. Only an explicit `status='fail'` is the gate's
        # verdict; a golden with no report (status '<none>'), an error or a missing file is not.
        return ("fail", False, 0.0, []) if code != 0 and _GOLDEN_RED.search(out) else None
    scores = _SCORE.findall(out)
    if len(scores) != 1:
        return None
    killed, total = int(scores[0][0]), int(scores[0][1])
    if total == 0 or killed > total:
        return None
    survivors = [name for line in _SURVIVED.findall(out) for name in line.split()]
    if code == 0:
        return ("pass", True, 1.0, []) if killed == total and not survivors else None
    if killed == total:
        return None
    # never let rounding turn "not every mutant was killed" into a 1.0
    return ("pass", False, min(round(killed / total, 4), 0.9999), survivors)


def classify_corpus(code, out):
    """(passed, failed) from one `bin/corpus status` run, or None when it gave no contract line that agrees
    with its exit code (0 iff every case was caught)."""
    rates = _CORPUS_RATE.findall(out)
    if len(rates) != 1:
        return None
    caught, total = int(rates[0][0]), int(rates[0][1])
    if total == 0 or caught > total or (code == 0) != (caught == total):
        return None
    return caught, total - caught


class _WallClock(Exception):
    """A runner outlived its wall clock."""


def _kill_group(proc):
    """SIGKILL the runner's whole process group (it leads its own session)."""
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        return  # ESRCH: the group is already gone, which is what was wanted


def _reap(proc):
    """Collect a killed runner without waiting on a pipe some escaped grandchild may still hold."""
    try:
        proc.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        proc.stdout.close()
        proc.wait()


def _run(argv, env, cwd, timeout):
    """(exit code, combined stdout+stderr text) of argv, run in its own session so a timeout, Ctrl-C or
    SIGTERM kills the whole tree (falsify -> the gate -> whatever the gate spawned), not just its top.
    Raises _WallClock past `timeout`; any other interruption kills the tree and propagates."""
    proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            env=env, cwd=cwd, start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        _reap(proc)
        raise _WallClock()
    except BaseException:
        _kill_group(proc)
        proc.wait()
        raise
    return proc.returncode, out.decode("utf-8", "replace")


def _tail(text, lines=4):
    """The last few non-empty lines of a runner's output, for an error that has to say what it saw."""
    kept = [line.strip() for line in text.splitlines() if line.strip()]
    return " | ".join(kept[-lines:])[:500] or "no output"


def prove_gate(falsify, repo, oracles, gate_id, env, timeout):
    """Run bin/falsify on one gate: ((status, falsified, score, survivors), None) or (None, why there is no verdict)."""
    try:
        code, out = _run([falsify, gate_id, "--assert-score", "1.0"], dict(env, HEIMDALL_ORACLES_DIR=oracles), repo, timeout)
    except _WallClock:
        return None, "gate '%s' exceeded the wall clock of %ds (a gate that never returns has not been shown to do anything)" % (gate_id, timeout)
    except OSError as exc:
        return None, "cannot run bin/falsify for gate '%s': %s" % (gate_id, exc)
    verdict = classify_falsify(code, out)
    if verdict is None:
        return None, "gate '%s': bin/falsify gave no verdict that can be trusted (exit %d): %s" % (gate_id, code, _tail(out))
    return verdict, None


def prove_corpus(corpus, repo, oracles, env, timeout):
    """Run `bin/corpus status` (read-only: `run` would rewrite CORPUS-STATUS.md): ((passed, failed), None) or (None, why)."""
    corpus_env = dict(env, CORPUS_DIR=os.path.join(repo, "evals", "corpus"), ORACLES_DIR=oracles)
    try:
        code, out = _run([corpus, "status"], corpus_env, repo, timeout)
    except _WallClock:
        return None, "the regression corpus exceeded the wall clock of %ds" % timeout
    except OSError as exc:
        return None, "cannot run bin/corpus: %s" % exc
    counts = classify_corpus(code, out)
    if counts is None:
        return None, "the regression corpus (bin/corpus status) gave no verdict that can be trusted (exit %d): %s" % (code, _tail(out))
    return counts, None


def _reasons(doc):
    """Why the document cannot be PROVEN (empty list: it can). Rule P2, via the validator's own function."""
    return runhmd_schema._unproven_reasons(doc["gates"], doc["regression_tests"])


def build_doc(results, types, regression):
    """The runhmd.prove/1 document. results: [(gate id, (status, falsified, score, survivors))] in gate
    order; types: {gate id: gate_type}; regression: (passed, failed). The verdict is derived, not passed in."""
    gates = [{"id": gate_id, "gate_type": types.get(gate_id, "unregistered"), "status": status,
              "falsified": falsified, "falsify_score": score}
             for gate_id, (status, falsified, score, _survivors) in results]
    doc = {
        "schema": "runhmd.prove/1",
        "verdict": "PROVEN",
        "gates": gates,
        "passed": sum(1 for gate in gates if gate["status"] == "pass"),
        "total": len(gates),
        "regression_tests": {"passed": regression[0], "failed": regression[1]},
    }
    if _reasons(doc):
        doc["verdict"] = "DENIED"
    return doc


def render_text(doc, repo, survivors):
    """The human report: a render of the document (plus the surviving mutants' names, which only falsify's
    output carries)."""
    gates, regression = doc["gates"], doc["regression_tests"]
    id_w = max([len(gate["id"]) for gate in gates] + [len("GATE")])
    type_w = max([len(gate["gate_type"]) for gate in gates] + [len("TYPE")])
    lines = ["hmd prove: do all gates pass, and has each gate been shown to fail first?", "repository: %s" % repo, "",
             "  %-*s  %-*s  %-6s  %-9s  %s" % (id_w, "GATE", type_w, "TYPE", "STATUS", "FALSIFIED", "SCORE")]
    for gate in gates:
        lines.append("  %-*s  %-*s  %-6s  %-9s  %.4f" % (id_w, gate["id"], type_w, gate["gate_type"], gate["status"],
                                                       "yes" if gate["falsified"] else "NO", gate["falsify_score"]))
    lines.append("")
    if regression["passed"] + regression["failed"]:
        lines.append("  regression corpus: %d passed, %d failed" % (regression["passed"], regression["failed"]))
    else:
        lines.append("  regression corpus: none (no evals/corpus in this repository)")
    lines.append("")
    reasons = _reasons(doc)
    if not reasons:
        lines.append("PROVEN: %d/%d gates pass and every gate is falsified; %d/%d regression cases still caught."
                     % (doc["passed"], doc["total"], regression["passed"], regression["passed"] + regression["failed"]))
    else:
        lines.append("DENIED:")
        lines.extend("  - %s" % reason for reason in reasons)
        for gate in gates:
            if survivors.get(gate["id"]):
                lines.append("  mutants that survived gate '%s': %s" % (gate["id"], ", ".join(survivors[gate["id"]])))
    return "\n".join(lines) + "\n"


def _prove(args, repo, timeout):
    if not os.path.isdir(repo):
        return _error(args, repo, "repo_not_found", "no such directory: %s" % repo, EXIT_USAGE)
    oracles = os.path.join(repo, "evals", "oracles")
    gates, problem = discover_gates(oracles)
    if problem:
        return _error(args, repo, problem[0], problem[1], EXIT_USAGE)
    if not gates:
        return _error(args, repo, "no_gates",
                      "no oracle gate is declared under %s (a gate is a directory there with fixtures/mutants): "
                      "a verdict over zero gates would be a false green" % oracles, EXIT_USAGE)
    falsify = _tool("falsify")
    if falsify is None:
        return _error(args, repo, "infra", "bin/falsify is missing or not executable under %s: reinstall hmd" % PLUGIN_DIR, EXIT_INFRA)
    has_corpus = os.path.isfile(os.path.join(repo, "evals", "corpus", "INDEX.json"))
    corpus = _tool("corpus") if has_corpus else None
    if has_corpus and corpus is None:
        return _error(args, repo, "infra", "bin/corpus is missing or not executable under %s: reinstall hmd" % PLUGIN_DIR, EXIT_INFRA)
    try:
        work = tempfile.mkdtemp(prefix="runhmd-prove-")
    except OSError as exc:
        return _error(args, repo, "infra", "cannot create a temporary directory: %s" % exc, EXIT_INFRA)
    try:
        env = _gate_env(work)
        results = []
        for gate_id in gates:
            verdict, why = prove_gate(falsify, repo, oracles, gate_id, env, timeout)
            if why:
                return _error(args, repo, "infra", why, EXIT_INFRA)
            results.append((gate_id, verdict))
        regression = (0, 0)
        if has_corpus:
            regression, why = prove_corpus(corpus, repo, oracles, env, timeout)
            if why:
                return _error(args, repo, "infra", why, EXIT_INFRA)
        doc = build_doc(results, gate_types(oracles), regression)
        problems = runhmd_schema.validate(doc)
        if problems:
            return _error(args, repo, "infra", "internal error: the document violates runhmd.prove/1: " + "; ".join(problems[:3]), EXIT_INFRA)
        if args.json:
            sys.stdout.write(json.dumps(doc, indent=2) + "\n")
        else:
            sys.stdout.write(render_text(doc, repo, {gate_id: verdict[3] for gate_id, verdict in results}))
        return EXIT_PROVEN if doc["verdict"] == "PROVEN" else EXIT_DENIED
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv):
    if any(a in ("-h", "--help") for a in argv):
        sys.stdout.write(HELP)
        return EXIT_PROVEN
    args = _parser().parse_args(argv)
    if len(args.repo) > 1:
        sys.stderr.write("hmd prove: one repository at a time (see hmd prove --help)\n")
        return EXIT_USAGE
    timeout, why = _timeout_s()
    if why:
        sys.stderr.write("hmd prove: %s\n" % why)
        return EXIT_USAGE
    try:
        repo = _resolve_repo(args.repo[0] if args.repo else None)
    except OSError as exc:
        sys.stderr.write("hmd prove: cannot determine the repository: %s\n" % exc)
        return EXIT_USAGE
    # Everything above is a usage check and runs nothing of the repository's. From here its code is run,
    # so consent comes first -- before the directory is even looked at.
    try:
        if not _consent(args, repo):
            return EXIT_CONSENT
        return _prove(args, repo, timeout)
    except KeyboardInterrupt:
        sys.stderr.write("hmd prove: interrupted\n")
        return EXIT_INTERRUPTED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
