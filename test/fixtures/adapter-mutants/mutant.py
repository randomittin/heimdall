"""Mutants of the gitdiff adapter, for test/adapter-conformance.test.sh.

One module, many mutants: HMD_MUTANT selects the single contract rule (a conformance check id, see
docs/ADAPTERS.md) that this copy of the adapter breaks, and every other behaviour is the real
gitdiff adapter's. The conformance suite is falsifiable only if each of these is REJECTED for the
rule it breaks, so the test asserts that, rule by rule. Loaded with:

    python3 -m adapters.conformance --adapter-file test/fixtures/adapter-mutants/mutant.py --driver gitdiff
"""
import itertools
import os
import re

from adapters import AdapterError
from adapters import gitdiff as _real

MUTANT = os.environ["HMD_MUTANT"]

CONTRACT = "runhmd.adapter/0" if MUTANT == "M1" else _real.CONTRACT
AGENT = _real.AGENT

_alias = {}   # run id handed out -> the real run id behind it
_base = {}    # real run id -> the task's base_sha
_calls = itertools.count()
_ID_OK = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")


def _blocks(diff):
    return [b for b in re.split(r"(?m)^(?=diff --git )", diff) if b]


def start(task):
    if MUTANT == "T3" and isinstance(task, dict) and isinstance(task.get("id"), str) and not _ID_OK.match(task["id"]):
        task = dict(task, id="repaired-id")              # a malformed id is quietly repaired, not refused
    if MUTANT == "T3x" and isinstance(task, dict) and "prompt" in task and not isinstance(task["prompt"], str):
        raise ValueError("prompt must be a string")      # a raw exception instead of an AdapterError
    try:
        run_id = _real.start(task)
    except AdapterError as exc:
        if MUTANT == "T4" and exc.kind == "unknown_base":
            raise AdapterError("bad_task", exc.detail)   # the wrong kind for an absent base
        raise
    _base[run_id] = task["base_sha"]
    if MUTANT == "T5":
        with open(os.path.join(task["repo"], "stray.txt"), "w") as fh:
            fh.write("left behind\n")                    # writes into the caller's working tree
    if MUTANT == "T2":
        _alias["gitdiff-000000000000"] = run_id          # every run gets the same id
        return "gitdiff-000000000000"
    if MUTANT == "T1":
        _alias["!" + run_id] = run_id                    # an id outside the run-id alphabet
        return "!" + run_id
    return run_id


def events(run_id):
    real_id = _alias.get(run_id, run_id)
    try:
        stream = list(_real.events(real_id))
    except AdapterError as exc:
        if MUTANT == "E6" and exc.kind == "unknown_run":
            return iter([])                              # an unknown run is an empty stream, not an error
        raise
    if MUTANT == "E1":
        stream = [dict(e, seq=i) for i, e in enumerate(stream)]
    if MUTANT == "E2":
        stream = [dict(e, ts="2026-01-01T00:00:%02d.000Z" % (50 - i)) for i, e in enumerate(stream)]
    if MUTANT == "E3":
        stream = [dict(e, data={k: v for k, v in e["data"].items() if k != "name"}) if e["kind"] == "tool" else e for e in stream]
    if MUTANT == "E4":
        stream = stream[1:]
    if MUTANT == "E5":
        stream = [dict(e, data=dict(e["data"], n=next(_calls))) for e in stream]
    if MUTANT == "K2":
        stream = stream[:-1] + [dict(stream[-1], data=dict(stream[-1]["data"], state="failed"))]
    return iter(stream)


def claim(run_id):
    real_id = _alias.get(run_id, run_id)
    try:
        out = dict(_real.claim(real_id))
    except AdapterError as exc:
        if MUTANT == "K8" and exc.kind == "unknown_run":
            return {"claim": "done", "diff": "", "head_sha": None}
        raise
    if MUTANT == "K1":
        out["note"] = "an extra key"
    if MUTANT == "K3":
        out["diff"], out["head_sha"] = "", None
    if MUTANT == "K4":
        out["diff"] = out["diff"].replace("alpha", "alphX", 1)    # corrupts a context line: the diff no longer applies
    if MUTANT == "K5":
        out["head_sha"] = _base[real_id]                          # a real commit, but not the claimed state
    if MUTANT == "K6":
        out["diff"] = "".join(b for b in _blocks(out["diff"]) if "src/new.txt" not in b.split("\n", 1)[0])
        out["head_sha"] = None                                    # applies fine, but drops part of the change
    if MUTANT == "K7" and next(_calls) % 2:
        out["diff"] = "".join(reversed(_blocks(out["diff"])))     # equivalent diff, different text each time
    return out
