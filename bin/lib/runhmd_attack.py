#!/usr/bin/env python3
"""runhmd_attack -- `hmd attack` (RP1): "can I break this?"

Attacks a target and answers PROVEN or DENIED with a counterexample, as a
runhmd.verdict/1 document (docs/schemas/runhmd.verdict.v1.json).

The verdict is NOT computed here. The `attack` oracle gate (evals/oracles/attack/run.sh) is
the single source of truth for pass/fail: it replays an adversarial battery against the
target and diffs the outcome with an independent reference model, and `bin/falsify attack`
proves that gate can go red. This module consumes the gate's typed report.json (never its
stdout), turns it into the verdict document, validates that document against the schema
before printing it (a document that violates its own contract is an error, never output),
and renders it.

Isolation: each target is attacked inside a private temp dir (TMPDIR and HOME redirected into
it, removed afterwards); the gate copies the target there, scrubs the environment and runs
the engine under a watchdog. Nothing is written outside that dir except what --out asks for.
The engine is deterministic and offline: no model, no network, so the cost is $0.00.

Library use (tests, `hmd prove`): main(argv) -> exit code; enforce_budget(cost, cap).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
PLUGIN_DIR = os.path.dirname(os.path.dirname(HERE))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import runhmd_card  # noqa: E402
import runhmd_schema  # noqa: E402

EXIT_PROVEN, EXIT_DENIED, EXIT_USAGE, EXIT_CONSENT, EXIT_BUDGET, EXIT_INFRA = 0, 1, 2, 3, 4, 5

# gate error kinds that mean "this target cannot be attacked" (the caller's input), as opposed
# to "the engine could not run" (infrastructure).
_USAGE_KINDS = {"no_attack_surface", "bad_manifest", "too_large"}

HELP = """hmd attack -- can I break this? PROVEN or DENIED, with a counterexample.

usage:
  hmd attack [<path>] [options]
  hmd attack --batch <targets.txt> --out <dir> [options]

A target is a directory that declares its attack surface in runhmd.attack.json
({"schema":"runhmd.attack-target/1","profile":"settlement-webhook/1","module":"webhook.mjs"}),
or a single .mjs module. A directory that declares nothing has nothing to attack and exits 2:
a verdict over nothing would be a false green. The target runs in an ephemeral temp dir, in a
scrubbed environment; the engine is deterministic and offline (no model, no network, $0.00).

options:
  --json            print the runhmd.verdict/1 document on stdout (the canonical output)
  --card            print the 40-column verdict card (the default output; with --json it goes to stderr)
  --yes, -y         consent without a prompt (required when stdin is not a terminal)
  --max-usd N       refuse to run when the estimated cost exceeds N dollars (exit 4)
  --no-network      guarantee no network use (the built-in engine never uses the network)
  --receipt         issue a signed receipt (runhmd.receipt/1) for each verdict and set receipt_url to its
                    address; needs a signing key (hmd receipt keygen, RUNHMD_RECEIPT_KEY_FILE)
  --public          mark the receipt public: the only kind `hmd receipt render` publishes (needs --receipt)
  --no-upload       with --receipt, do not publish it: receipt_url stays null (it is still stored locally)
  --out DIR         write verdict.json and attacks/f-NNNN.json evidence into DIR
  --batch FILE      attack every target listed in FILE (one per line, # comments); needs --out
  --diff SPEC       attack a diff: NOT SUPPORTED in this build (arrives with the gitdiff adapter)
  -h, --help        this text

receipts: with --receipt the receipt is stored as <id>.json under $RUNHMD_RECEIPT_DIR (default
$HEIMDALL_HOME/runhmd/receipts) and receipt_url is https://runhmd.dev/r/<id> (RUNHMD_RECEIPT_BASE_URL
moves it). The URL resolves once the receipt is published (hmd receipt render); see hmd receipt --help.

exit codes:
  0  PROVEN: no attack broke the target
  1  DENIED: an attack broke the target (the counterexample is in the output)
  2  usage or config error (bad flag, unsupported target, nothing to attack)
  3  consent required: stdin is not a terminal and --yes was not given, or the prompt was declined
  4  budget cap hit (--max-usd)
  5  infrastructure error: the engine could not run
"""


def enforce_budget(cost_usd, cap_usd):
    """None when `cost_usd` fits under the cap (or there is no cap); else the budget_cap error document."""
    if cap_usd is not None and cost_usd > cap_usd:
        return {"error": "budget_cap", "spent_usd": cost_usd, "cap_usd": cap_usd}
    return None


def estimate_cost_usd(_targets):
    """The built-in engine is deterministic and offline: no model, no tokens, no network."""
    return 0.0


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        sys.stderr.write("hmd attack: %s (see hmd attack --help)\n" % message)
        sys.exit(EXIT_USAGE)


def _parser():
    p = _Parser(prog="hmd attack", add_help=False, allow_abbrev=False)
    p.add_argument("targets", nargs="*")
    p.add_argument("--json", action="store_true")
    p.add_argument("--card", action="store_true")
    p.add_argument("--yes", "-y", action="store_true")
    p.add_argument("--max-usd", dest="max_usd")
    p.add_argument("--no-network", action="store_true")
    p.add_argument("--no-upload", action="store_true")
    p.add_argument("--receipt", action="store_true")
    p.add_argument("--public", action="store_true")
    p.add_argument("--out")
    p.add_argument("--batch")
    p.add_argument("--diff")
    return p


def _emit(obj, as_json, human):
    """A result on stdout (JSON mode) or its human text on stderr; never both."""
    if as_json:
        sys.stdout.write(json.dumps(obj, indent=2) + "\n")
    else:
        sys.stderr.write(human + "\n")


def _consent(args, targets):
    """True when the user may be attacked-on: --yes, or an interactive yes on a real terminal."""
    if args.yes:
        return True
    interactive = bool(getattr(sys.stdin, "isatty", lambda: False)())
    if not interactive:
        _emit({"error": "consent_required",
               "detail": "stdin is not a terminal and --yes was not given: hmd attack runs the target's code and never assumes consent"},
              args.json,
              "hmd attack: consent required. It runs code from the target in an ephemeral sandbox; stdin is not a terminal, "
              "so pass --yes to allow it.")
        return False
    sys.stderr.write(
        "hmd attack will EXECUTE code from the target(s) below, in an ephemeral temp dir with a scrubbed\n"
        "environment. It makes no network calls and calls no model.\n"
        + "".join("  target: %s\n" % t for t in targets)
        + "estimated cost: $%.2f (deterministic engine: no model, no network)\n" % estimate_cost_usd(targets)
        + "Proceed? [y/N] ")
    sys.stderr.flush()
    answer = sys.stdin.readline().strip().lower()
    if answer in ("y", "yes"):
        return True
    _emit({"error": "consent_required", "detail": "consent was not given"}, args.json, "hmd attack: consent not given.")
    return False


def _tree_digest(path):
    """Content hash of the target (the same files the gate copies: no .git, no node_modules, no symlinks)."""
    digest = hashlib.sha256()
    if os.path.isfile(path):
        with open(path, "rb") as fh:
            digest.update(b"file\0" + fh.read())
        return digest.hexdigest()
    for root, dirs, files in os.walk(path, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in (".git", "node_modules"))
        for name in sorted(files):
            full = os.path.join(root, name)
            if os.path.islink(full):
                continue
            digest.update(os.path.relpath(full, path).encode("utf-8", "replace") + b"\0")
            with open(full, "rb") as fh:
                digest.update(fh.read())
            digest.update(b"\0")
    return digest.hexdigest()


def _git_head(path):
    cwd = path if os.path.isdir(path) else (os.path.dirname(os.path.abspath(path)) or ".")
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    try:
        done = subprocess.run(["git", "-C", cwd, "rev-parse", "HEAD"], stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, timeout=10, env=env)
    except (OSError, subprocess.SubprocessError):
        return None
    sha = done.stdout.strip() if done.returncode == 0 else ""
    return sha if re.fullmatch(r"[0-9a-f]{40,64}", sha) else None


def _run_gate(target, work):
    """Run the attack gate on `target`; return (report dict, None) or (None, error dict)."""
    gate = os.path.join(os.environ.get("HEIMDALL_ORACLES_DIR") or os.path.join(PLUGIN_DIR, "evals", "oracles"), "attack", "run.sh")
    report_path = os.path.join(work, "report.json")
    os.makedirs(os.path.join(work, "home"), exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(TMPDIR=work, HOME=os.path.join(work, "home"))
    try:
        wall = int(os.environ.get("RUNHMD_ATTACK_TIMEOUT_S", "60")) + 30
    except ValueError:
        wall = 90
    try:
        done = subprocess.run(["bash", gate, "--input", target, "--report", report_path], stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=wall, env=env)
    except subprocess.TimeoutExpired:
        return None, {"error": "infra", "detail": "the attack gate exceeded its %ds wall clock" % wall}
    except OSError as exc:
        return None, {"error": "infra", "detail": "cannot run the attack gate %s: %s" % (gate, exc)}
    try:
        with open(report_path, "r", encoding="utf-8") as fh:
            report = json.load(fh)
    except (OSError, ValueError):
        tail = (done.stderr or "").strip().splitlines()[-1:] or ["no output"]
        return None, {"error": "infra", "detail": "the attack gate produced no usable report (exit %d): %s" % (done.returncode, tail[0][:300])}
    return report, None


def _verdict(report, ref, started, evidence_prefix, tree):
    metrics = report["metrics"]
    repro = "hmd attack %s --json --yes" % shlex.quote(ref)
    findings = []
    for index, found in enumerate(metrics["findings"], start=1):
        fid = "f-%04d" % index
        findings.append({
            "id": fid, "title": found["title"], "severity": found["severity"], "category": found["category"],
            "counterexample": {"summary": found["counterexample"]["summary"], "repro_cmd": repro,
                               "minimal_input": found["counterexample"]["minimal_input"]},
            "evidence_ref": "%s%s.json" % (evidence_prefix, fid) if evidence_prefix is not None else None,
        })
    return {
        "schema": "runhmd.verdict/1",
        "id": hashlib.sha256(("%s|%s|%s" % (metrics["suite"], metrics["profile"], tree)).encode()).hexdigest()[:12],
        "verdict": "PROVEN" if report["status"] == "pass" else "DENIED",
        "target": {"kind": "path", "ref": ref, "head_sha": _git_head(ref)},
        "attacks": metrics["attacks"],
        "findings": findings,
        "cost_usd": 0.0,
        "duration_s": round(time.monotonic() - started, 2),
        "agent": {"name": "none", "model": None},
        "receipt_url": None,
    }


def _write_json(path, obj):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(obj, indent=2) + "\n")


def _receipt_setup(args):
    """(context, None) for --receipt, (None, None) without it, or (None, (error doc, exit code)) when
    a receipt cannot be issued. Reads the signing key and checks the URL base, so a missing key or a
    bad base fails here, before any target is attacked. Imported lazily: the receipt module pulls in
    the crypto stack, and the default attack path stays light and offline."""
    if not args.receipt:
        return None, None
    import runhmd_receipt as rr
    try:
        signer = rr.load_signer()
        rr.receipt_url("000")          # validates RUNHMD_RECEIPT_BASE_URL before anything runs
    except rr.ReceiptError as exc:
        return None, ({"error": exc.kind, "detail": exc.detail}, EXIT_USAGE if exc.kind in rr.CONFIG_KINDS else EXIT_INFRA)
    return {"rr": rr, "signer": signer, "store": rr.store_dir(), "public": args.public, "publish": not args.no_upload, "paths": []}, None


def _issue_receipt(doc, tree, receipt):
    """Issue and store the receipt for verdict `doc` (the target is attested by its content hash `tree`),
    and set doc["receipt_url"] unless the receipt is to stay local. Returns an error document or None.
    The URL is only set once the receipt is on disk: never a URL that points at nothing."""
    rr = receipt["rr"]
    try:
        raw = rr.receipt_for_verdict(doc, tree_sha256=tree, signer=receipt["signer"], visibility="public" if receipt["public"] else "private")
        path = rr.write_receipt(receipt["store"], doc["id"], raw)
        url = rr.receipt_url(doc["id"]) if receipt["publish"] else None
    except rr.ReceiptError as exc:
        return {"error": "receipt_failed", "detail": "%s: %s" % (exc.kind, exc.detail)}
    doc["receipt_url"] = url
    receipt["paths"].append(path)
    return None


def _attack_one(ref, out_layout, receipt=None):
    """Attack one target. Returns (verdict doc, None, exit code) or (None, error doc, exit code).

    out_layout: None, or (verdict_path, evidence_dir, evidence_ref_prefix) for --out.
    receipt: None, or the context _receipt_setup built: the verdict then gets a signed receipt.
    """
    if not os.path.exists(ref):
        return None, {"error": "target_not_found", "detail": "no such file or directory: %s" % ref, "target": ref}, EXIT_USAGE
    started = time.monotonic()
    work = tempfile.mkdtemp(prefix="runhmd-attack-")
    try:
        report, err = _run_gate(ref, work)
        if err:
            return None, dict(err, target=ref), EXIT_INFRA
        if report.get("status") == "error":
            kind = (report.get("metrics") or {}).get("error_kind", "infra")
            detail = (report.get("first_divergence") or {}).get("actual") or report.get("fix_hint") or kind
            return None, {"error": kind, "detail": detail, "target": ref}, EXIT_USAGE if kind in _USAGE_KINDS else EXIT_INFRA
        if report.get("status") not in ("pass", "fail"):
            return None, {"error": "infra", "detail": "the attack gate reported an unknown status %r" % report.get("status"), "target": ref}, EXIT_INFRA
        tree = _tree_digest(ref)
        doc = _verdict(report, ref, started, out_layout[2] if out_layout else None, tree)
        if receipt:
            failure = _issue_receipt(doc, tree, receipt)
            if failure:
                return None, dict(failure, target=ref), EXIT_INFRA
        problems = runhmd_schema.validate(doc)
        if problems:
            return None, {"error": "infra", "detail": "internal error: the verdict violates runhmd.verdict/1: " + "; ".join(problems[:3]),
                          "target": ref}, EXIT_INFRA
        if out_layout:
            verdict_path, evidence_dir, _ = out_layout
            for found, mine in zip(report["metrics"]["findings"], doc["findings"]):
                _write_json(os.path.join(evidence_dir, "%s.json" % mine["id"]), {
                    "finding_id": mine["id"], "title": mine["title"], "severity": mine["severity"],
                    "category": mine["category"], "evidence": found["evidence"]})
            _write_json(verdict_path, doc)
        return doc, None, EXIT_PROVEN if doc["verdict"] == "PROVEN" else EXIT_DENIED
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _read_batch(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = [line.strip() for line in fh]
    except OSError as exc:
        sys.stderr.write("hmd attack: cannot read the batch file %s: %s\n" % (path, exc))
        sys.exit(EXIT_USAGE)
    targets = [line for line in lines if line and not line.startswith("#")]
    if not targets:
        sys.stderr.write("hmd attack: the batch file %s lists no targets\n" % path)
        sys.exit(EXIT_USAGE)
    return targets


def _slug(index, ref):
    return "%04d-%s" % (index, re.sub(r"[^A-Za-z0-9._-]+", "_", ref).strip("_")[:80] or "target")


def _show_card(doc, as_json):
    (sys.stderr if as_json else sys.stdout).write(runhmd_card.render_card(doc))


def _run_single(args, ref, receipt):
    layout = None
    if args.out:
        layout = (os.path.join(args.out, "verdict.json"), os.path.join(args.out, "attacks"), "attacks/")
    doc, err, code = _attack_one(ref, layout, receipt)
    if err:
        _emit(err, args.json, "hmd attack: %s: %s" % (err["error"], err["detail"]))
        return code
    if args.json:
        sys.stdout.write(json.dumps(doc, indent=2) + "\n")
        if args.card:
            _show_card(doc, True)
    else:
        _show_card(doc, False)
    for path in (receipt or {}).get("paths", []):
        sys.stderr.write("receipt: %s\n" % path)
    return code


def _run_batch(args, refs, receipt):
    worst, lines = EXIT_PROVEN, []
    rank = {EXIT_PROVEN: 0, EXIT_DENIED: 1, EXIT_USAGE: 2, EXIT_INFRA: 3}
    for index, ref in enumerate(refs, start=1):
        slug = _slug(index, ref)
        layout = (os.path.join(args.out, slug + ".json"), os.path.join(args.out, slug + ".attacks"), slug + ".attacks/")
        doc, err, code = _attack_one(ref, layout, receipt)
        if err:
            _write_json(os.path.join(args.out, slug + ".json"), err)
            lines.append("ERROR    %s: %s" % (ref, err["error"]))
        else:
            lines.append("%-8s %s (%d/%d attacks killed it)" % (doc["verdict"], ref, doc["attacks"]["killed"], doc["attacks"]["total"]))
        if args.json:
            sys.stdout.write(json.dumps(err or doc, separators=(",", ":")) + "\n")
        if rank[code] > rank[worst]:
            worst = code
    if not args.json:
        sys.stdout.write("\n".join(lines) + "\n")
    if receipt and receipt["paths"]:
        sys.stderr.write("receipts: %d written to %s\n" % (len(receipt["paths"]), receipt["store"]))
    return worst


def main(argv):
    if any(a in ("-h", "--help") for a in argv):
        sys.stdout.write(HELP)
        return EXIT_PROVEN
    args = _parser().parse_args(argv)

    if args.diff is not None:
        sys.stderr.write("hmd attack: --diff is not supported in this build: attacking a diff needs the gitdiff adapter (RP9). "
                         "Apply the change to a checkout and attack that path.\n")
        return EXIT_USAGE
    cap = None
    if args.max_usd is not None:
        try:
            cap = float(args.max_usd)
        except ValueError:
            cap = None
        if cap is None or not math.isfinite(cap) or cap < 0:
            sys.stderr.write("hmd attack: --max-usd needs a non-negative number of dollars, got %r\n" % args.max_usd)
            return EXIT_USAGE
    if args.batch is not None:
        if args.targets:
            sys.stderr.write("hmd attack: give either a target or --batch FILE, not both\n")
            return EXIT_USAGE
        if not args.out:
            sys.stderr.write("hmd attack: --batch needs --out DIR (one verdict file per target)\n")
            return EXIT_USAGE
    elif len(args.targets) > 1:
        sys.stderr.write("hmd attack: one target at a time; list several in a file and use --batch FILE --out DIR\n")
        return EXIT_USAGE
    targets = [] if args.batch is not None else (args.targets or ["."])
    for ref in targets:
        if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", ref):
            sys.stderr.write("hmd attack: %s is not supported in this build: attacking a PR needs network access and the adapters (RP9). "
                             "Check it out and attack the path.\n" % ref)
            return EXIT_USAGE

    if args.public and not args.receipt:
        sys.stderr.write("hmd attack: --public marks a receipt public, so it needs --receipt (see hmd attack --help)\n")
        return EXIT_USAGE
    receipt, receipt_error = _receipt_setup(args)
    if receipt_error:
        error, code = receipt_error
        _emit(error, args.json, "hmd attack: %s: %s" % (error["error"], error["detail"]))
        return code

    # Everything above is a usage check and touches nothing (--receipt only READS the signing key).
    # From here a target is looked at and its code is run, so consent comes first.
    if not _consent(args, targets or ["(each target listed in %s)" % args.batch]):
        return EXIT_CONSENT
    refs = _read_batch(args.batch) if args.batch is not None else targets
    over = enforce_budget(estimate_cost_usd(refs), cap)
    if over:
        _emit(over, args.json, "hmd attack: budget cap hit: estimated $%.2f exceeds --max-usd %.2f" % (over["spent_usd"], over["cap_usd"]))
        return EXIT_BUDGET
    return _run_batch(args, refs, receipt) if args.batch is not None else _run_single(args, refs[0], receipt)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
