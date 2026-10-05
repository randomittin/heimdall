"""The adapter contract (docs/ADAPTERS.md, runhmd.adapter/1) as checks, one function per rule id.

Every enum and pattern below is written from the contract, not imported from any adapter. A rule
returns a list of problems (empty = pass) or raises Skip when an earlier failure already explains why
it cannot run; the primary rule for each failure reports it, so a skip never hides a red.

The suite observes each variant the driver offers once (start, events twice, claim twice, a second
start, then a claim-before-events run), then every rule judges that recorded behaviour.
"""
from __future__ import annotations

import copy
import datetime
import json
import os
import re

from adapters import AdapterError

from . import fixture as fx_mod

CONTRACT = "runhmd.adapter/1"
AGENTS = ("claude-code", "codex", "gemini", "cursor", "none")
KINDS = ("tool", "message", "test", "status")
CLAIMS = ("done", "failed", "gave_up")
STATES = ("started",) + CLAIMS
ROLES = ("agent", "user", "system")
RUN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{2,63}$")
SHA = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
_TS = re.compile(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?Z$")
UNKNOWN_RUN = "no-such-run-000000"
_MAX_PROBLEMS = 5


class Skip(Exception):
    """A rule that cannot be judged because an earlier failure already explains why."""


def describe(exc):
    return ("%s: %s" % (type(exc).__name__, exc))[:200]


def parse_ts(ts):
    """(y, m, d, H, M, S, fraction) for an RFC 3339 UTC timestamp ending in Z, else None."""
    match = _TS.match(ts) if isinstance(ts, str) else None
    if not match:
        return None
    parts = [int(g) for g in match.groups()[:6]]
    try:
        datetime.datetime(*parts)
    except ValueError:
        return None
    return tuple(parts) + (float("0." + (match.group(7) or "0")),)


# ── observation ───────────────────────────────────────────────────────────────────────────────

class Obs:
    """What one variant's runs did: results or the exception that stopped each step."""

    def __init__(self, name, task):
        self.name, self.task = name, task
        self.run_id = self.start_err = None
        self.events1 = self.events2 = self.events_err = None
        self.claim1 = self.claim2 = self.claim_err = None
        self.run_id2 = self.start2_err = None
        self.claim3 = self.events3 = self.order_err = None
        self.before = self.after = None


def observe(mod, fixture, name, task):
    o = Obs(name, task)
    o.before = fx_mod.fingerprint(fixture.repo)
    try:
        o.run_id = mod.start(copy.deepcopy(task))
    except Exception as exc:  # noqa: BLE001 - the adapter's failure is the observation
        o.start_err = exc
        o.after = fx_mod.fingerprint(fixture.repo)
        return o
    try:
        o.events1, o.events2 = list(mod.events(o.run_id)), list(mod.events(o.run_id))
    except Exception as exc:  # noqa: BLE001
        o.events_err = exc
    try:
        o.claim1, o.claim2 = mod.claim(o.run_id), mod.claim(o.run_id)
    except Exception as exc:  # noqa: BLE001
        o.claim_err = exc
    try:
        o.run_id2 = mod.start(copy.deepcopy(task))
    except Exception as exc:  # noqa: BLE001
        o.start2_err = exc
    try:
        third = mod.start(copy.deepcopy(task))
        o.claim3 = mod.claim(third)
        o.events3 = list(mod.events(third))
    except Exception as exc:  # noqa: BLE001
        o.order_err = exc
    o.after = fx_mod.fingerprint(fixture.repo)
    return o


class Ctx:
    def __init__(self, mod, fixture, variants):
        self.mod, self.fx, self.variants = mod, fixture, variants
        self.obs = [observe(mod, fixture, name, task) for name, task in variants]
        self._candidates = {}

    def candidate(self, o):
        """(applies, error, dir): the base tree with this variant's claimed diff applied, built once."""
        if o.name not in self._candidates:
            diff = o.claim1["diff"] if isinstance(o.claim1, dict) else None
            if not isinstance(diff, str):
                raise Skip("claim() returned no diff text (K1)")
            dest = os.path.join(self.fx.workdir, "candidates", o.name)
            fx_mod.export(self.fx.repo, self.fx.base_sha, dest)
            applied, err = fx_mod.apply_diff(dest, diff) if diff.strip() else (True, "")
            self._candidates[o.name] = (applied, err, dest)
        return self._candidates[o.name]


def each(ctx, judge):
    """Run `judge(obs)` on every variant; a variant that skips is ignored unless all of them do."""
    problems, skipped = [], 0
    for o in ctx.obs:
        try:
            problems += ["[%s] %s" % (o.name, p) for p in judge(o)]
        except Skip:
            skipped += 1
    if skipped == len(ctx.obs):
        raise Skip("every variant stopped earlier: see the rule that reports it")
    return problems


def _started(o):
    if o.start_err is not None:
        raise Skip("start() raised (T1)")


def _events(o):
    _started(o)
    if o.events_err is not None:
        raise Skip("events() raised (E1)")
    return o.events1


def _claim(o):
    _started(o)
    if o.claim_err is not None:
        raise Skip("claim() raised (K1)")
    return o.claim1


def _state(event):
    if isinstance(event, dict) and event.get("kind") == "status" and isinstance(event.get("data"), dict):
        return event["data"].get("state")
    return None


# ── the rules ─────────────────────────────────────────────────────────────────────────────────

def m1(mod):
    problems = []
    if getattr(mod, "CONTRACT", None) != CONTRACT:
        problems.append("CONTRACT is %r, want %r" % (getattr(mod, "CONTRACT", None), CONTRACT))
    if getattr(mod, "AGENT", None) not in AGENTS:
        problems.append("AGENT is %r, want one of %s" % (getattr(mod, "AGENT", None), ", ".join(AGENTS)))
    for name in ("start", "events", "claim"):
        if not callable(getattr(mod, name, None)):
            problems.append("%s is missing or not callable" % name)
    return problems


def t1(ctx):
    problems = []
    for o in ctx.obs:
        if o.start_err is not None:
            problems.append("[%s] start() raised %s" % (o.name, describe(o.start_err)))
        elif not (isinstance(o.run_id, str) and RUN_ID.match(o.run_id)):
            problems.append("[%s] start() returned %r, want a string matching %s" % (o.name, o.run_id, RUN_ID.pattern))
    return problems


def t2(ctx):
    def judge(o):
        _started(o)
        if o.start2_err is not None:
            return ["the second start() of the same task raised %s" % describe(o.start2_err)]
        return ["two start() calls of the same task both returned run id %r" % o.run_id] if o.run_id2 == o.run_id else []
    return each(ctx, judge)


def malformed_tasks(valid, fixture):
    def drop(key):
        t = copy.deepcopy(valid)
        t.pop(key, None)
        return t

    def put(key, value):
        t = copy.deepcopy(valid)
        t[key] = value
        return t

    cases = [("task is a string", "not a task"), ("task is null", None), ("task is a list", [])]
    cases += [("%s is missing" % k, drop(k)) for k in ("id", "prompt", "repo", "base_sha")]
    cases += [("id is an integer", put("id", 7)), ("id has a space", put("id", "has space")), ("id is empty", put("id", "")),
              ("id starts with a dot", put("id", ".hidden")), ("id is 65 characters", put("id", "a" * 65)), ("id is a path", put("id", "../x")),
              ("prompt is an integer", put("prompt", 7)), ("repo is an integer", put("repo", 7)), ("repo is empty", put("repo", "")),
              ("repo does not exist", put("repo", os.path.join(fixture.workdir, "no-such-dir")))]
    if fx_mod.run(fixture.plain_dir, "rev-parse", "--git-dir", check=False, env={"GIT_CEILING_DIRECTORIES": fixture.workdir}).returncode != 0:
        cases.append(("repo is not a git repository", put("repo", fixture.plain_dir)))
    sha = valid["base_sha"]
    cases += [("base_sha is HEAD", put("base_sha", "HEAD")), ("base_sha is a branch name", put("base_sha", "main")),
              ("base_sha is abbreviated", put("base_sha", sha[:12])), ("base_sha is upper case", put("base_sha", sha.upper())),
              ("base_sha has 41 characters", put("base_sha", sha + "0")), ("base_sha is 40 non-hex characters", put("base_sha", "z" * 40)),
              ("base_sha is an integer", put("base_sha", 7)),
              ("an unknown top-level key", put("extra", 1)), ("options is an integer", put("options", 5))]
    return cases


def t3(ctx):
    problems = []
    for label, bad in malformed_tasks(copy.deepcopy(ctx.variants[0][1]), ctx.fx):
        try:
            run_id = ctx.mod.start(copy.deepcopy(bad))
        except AdapterError as exc:
            if exc.kind != "bad_task":
                problems.append("%s: raised AdapterError kind %r, want bad_task" % (label, exc.kind))
        except Exception as exc:  # noqa: BLE001
            problems.append("%s: raised %s instead of AdapterError" % (label, describe(exc)))
        else:
            problems.append("%s: accepted, run %r" % (label, run_id))
    return problems


def t4(ctx):
    task = copy.deepcopy(ctx.variants[0][1])
    task["base_sha"] = "0" * 40
    try:
        run_id = ctx.mod.start(task)
    except AdapterError as exc:
        return [] if exc.kind == "unknown_base" else ["a well-formed base_sha naming no commit raised kind %r, want unknown_base" % exc.kind]
    except Exception as exc:  # noqa: BLE001
        return ["a base_sha naming no commit raised %s instead of AdapterError" % describe(exc)]
    return ["a base_sha naming no commit was accepted, run %r" % run_id]


def t5(ctx):
    def judge(o):
        if o.before is None or o.after is None:
            raise Skip("no fingerprint")
        changed = [k for k in o.before if o.before[k] != o.after[k]]
        return ["the caller's repo changed during start/events/claim: %s" % ", ".join(changed)] if changed else []
    return each(ctx, judge)


def e1(ctx):
    def judge(o):
        _started(o)
        if o.events_err is not None:
            return ["events() raised %s" % describe(o.events_err)]
        problems = []
        for i, e in enumerate(o.events1):
            if not isinstance(e, dict):
                problems.append("event %d is %s, want an object" % (i, type(e).__name__))
                continue
            if set(e) != {"ts", "kind", "data"}:
                problems.append("event %d has keys %s, want exactly ts, kind, data" % (i, sorted(map(str, e))))
            if parse_ts(e.get("ts")) is None:
                problems.append("event %d ts %r is not RFC 3339 UTC (YYYY-MM-DDTHH:MM:SS[.fff]Z)" % (i, e.get("ts")))
            if e.get("kind") not in KINDS:
                problems.append("event %d kind %r is not one of %s" % (i, e.get("kind"), "|".join(KINDS)))
            if not isinstance(e.get("data"), dict):
                problems.append("event %d data is %s, want an object" % (i, type(e.get("data")).__name__))
            try:
                json.dumps(e)
            except (TypeError, ValueError) as exc:
                problems.append("event %d is not JSON-serialisable: %s" % (i, exc))
        return problems[:_MAX_PROBLEMS]
    return each(ctx, judge)


def e2(ctx):
    def judge(o):
        stamps = [parse_ts(e.get("ts")) for e in _events(o) if isinstance(e, dict)]
        stamps = [s for s in stamps if s is not None]
        return ["ts goes backwards between event %d and %d" % (i, i + 1) for i in range(len(stamps) - 1) if stamps[i] > stamps[i + 1]][:_MAX_PROBLEMS]
    return each(ctx, judge)


def _data_problem(e):
    kind, data = e["kind"], e["data"]
    if kind == "status" and data.get("state") not in STATES:
        return "status.state is %r, want one of %s" % (data.get("state"), "|".join(STATES))
    if kind == "message" and not (data.get("role") in ROLES and isinstance(data.get("text"), str)):
        return "message needs role (%s) and text (string)" % "|".join(ROLES)
    if kind == "tool" and not (isinstance(data.get("name"), str) and data.get("name")):
        return "tool needs a non-empty name"
    if kind == "test" and not (isinstance(data.get("cmd"), str) and isinstance(data.get("exit_code"), int) and not isinstance(data.get("exit_code"), bool)):
        return "test needs cmd (string) and exit_code (integer)"
    return None


def e3(ctx):
    def judge(o):
        problems = []
        for i, e in enumerate(_events(o)):
            if isinstance(e, dict) and e.get("kind") in KINDS and isinstance(e.get("data"), dict):
                found = _data_problem(e)
                if found:
                    problems.append("event %d (%s): %s" % (i, e["kind"], found))
        return problems[:_MAX_PROBLEMS]
    return each(ctx, judge)


def e4(ctx):
    def judge(o):
        stream = _events(o)
        if not stream:
            return ["the stream is empty: it must open with status/started and close with a terminal status"]
        states = [s for s in (_state(e) for e in stream) if s is not None]
        problems = []
        if _state(stream[0]) != "started":
            problems.append("the first event is not status/started")
        if _state(stream[-1]) not in CLAIMS:
            problems.append("the last event is not a terminal status (%s)" % "|".join(CLAIMS))
        if states.count("started") != 1:
            problems.append("status/started appears %d times, want exactly once" % states.count("started"))
        if sum(1 for s in states if s in CLAIMS) != 1:
            problems.append("a terminal status appears %d times, want exactly once" % sum(1 for s in states if s in CLAIMS))
        return problems
    return each(ctx, judge)


def e5(ctx):
    def judge(o):
        _events(o)
        return [] if o.events1 == o.events2 else ["events() returned a different stream on a second read of the same finished run"]
    return each(ctx, judge)


def _unknown_run(call):
    try:
        answer = call(UNKNOWN_RUN)
        if hasattr(answer, "__next__"):
            list(answer)  # a lazy stream may only raise once it is read
    except AdapterError as exc:
        return [] if exc.kind == "unknown_run" else ["raised kind %r, want unknown_run" % exc.kind]
    except Exception as exc:  # noqa: BLE001
        return ["raised %s instead of AdapterError" % describe(exc)]
    return ["answered for a run that never existed instead of raising unknown_run"]


def e6(ctx):
    return _unknown_run(ctx.mod.events)


def k1(ctx):
    def judge(o):
        _started(o)
        if o.claim_err is not None:
            return ["claim() raised %s" % describe(o.claim_err)]
        c = o.claim1
        if not isinstance(c, dict):
            return ["claim() returned %s, want an object" % type(c).__name__]
        problems = []
        if set(c) != {"claim", "diff", "head_sha"}:
            problems.append("keys are %s, want exactly claim, diff, head_sha" % sorted(map(str, c)))
        if c.get("claim") not in CLAIMS:
            problems.append("claim is %r, want one of %s" % (c.get("claim"), "|".join(CLAIMS)))
        if not isinstance(c.get("diff"), str):
            problems.append("diff is %s, want a string" % type(c.get("diff")).__name__)
        if c.get("head_sha") is not None and not (isinstance(c["head_sha"], str) and SHA.match(c["head_sha"])):
            problems.append("head_sha is %r, want null or a full lowercase hex commit id" % (c.get("head_sha"),))
        try:
            json.dumps(c)
        except (TypeError, ValueError) as exc:
            problems.append("not JSON-serialisable: %s" % exc)
        return problems
    return each(ctx, judge)


def k2(ctx):
    def judge(o):
        c, stream = _claim(o), _events(o)
        problems = []
        if isinstance(c, dict) and stream and _state(stream[-1]) != c.get("claim"):
            problems.append("claim() says %r but the stream ends %r" % (c.get("claim"), _state(stream[-1])))
        if o.order_err is not None:
            problems.append("a run read claim-first then events raised %s" % describe(o.order_err))
        elif isinstance(o.claim3, dict) and o.events3 and _state(o.events3[-1]) != o.claim3.get("claim"):
            problems.append("read claim-first, claim() says %r but the stream ends %r" % (o.claim3.get("claim"), _state(o.events3[-1])))
        return problems
    return each(ctx, judge)


def k3(ctx):
    def judge(o):
        c = _claim(o)
        if not isinstance(c, dict):
            raise Skip("claim shape (K1)")
        problems = []
        if c.get("claim") != "done":
            problems.append("the scenario is a finished change, so the claim must be done, got %r" % (c.get("claim"),))
        if not (isinstance(c.get("diff"), str) and c["diff"].strip()):
            problems.append("a done claim carries an empty diff: a change nobody can see cannot be attacked")
        return problems
    return each(ctx, judge)


def k4(ctx):
    def judge(o):
        _claim(o)
        applied, err, _ = ctx.candidate(o)
        return [] if applied else ["the claimed diff does not apply cleanly to base_sha: %s" % err]
    return each(ctx, judge)


def k5(ctx):
    def judge(o):
        c = _claim(o)
        applied, _, candidate = ctx.candidate(o)
        if not applied:
            raise Skip("the diff does not apply (K4)")
        sha = c.get("head_sha") if isinstance(c, dict) else None
        if sha is None:
            return []
        if not (isinstance(sha, str) and SHA.match(sha)):
            raise Skip("head_sha is malformed (K1)")
        if fx_mod.run(ctx.fx.repo, "cat-file", "-e", sha + "^{commit}", check=False).returncode != 0:
            return ["head_sha %s is not a commit in the repo" % sha]
        head_dir = os.path.join(ctx.fx.workdir, "heads", o.name)
        fx_mod.export(ctx.fx.repo, sha, head_dir)
        differences = fx_mod.tree_diff(candidate, head_dir)
        return ["base_sha + diff is not the tree of head_sha: %s" % "; ".join(differences)] if differences else []
    return each(ctx, judge)


def k6(ctx):
    def judge(o):
        _claim(o)
        applied, _, candidate = ctx.candidate(o)
        if not applied:
            raise Skip("the diff does not apply (K4)")
        differences = fx_mod.tree_diff(candidate, ctx.fx.expected_dir)
        return ["base_sha + diff is not the change that was made: %s" % "; ".join(differences)] if differences else []
    return each(ctx, judge)


def k7(ctx):
    def judge(o):
        _claim(o)
        return [] if o.claim1 == o.claim2 else ["claim() returned a different result on a second read of the same finished run"]
    return each(ctx, judge)


def k8(ctx):
    return _unknown_run(ctx.mod.claim)


RULES = (
    ("M1", "module surface: CONTRACT, AGENT, start, events, claim", m1),
    ("T1", "start() returns a run id", t1),
    ("T2", "run ids are unique per start()", t2),
    ("T3", "a malformed task is refused with bad_task", t3),
    ("T4", "an unknown base_sha is refused with unknown_base", t4),
    ("T5", "the caller's repo is left as found", t5),
    ("E1", "events have the shape {ts, kind, data}", e1),
    ("E2", "event timestamps never go backwards", e2),
    ("E3", "each event kind carries its required data", e3),
    ("E4", "the stream opens with status/started and closes with one terminal status", e4),
    ("E5", "events() replays the same stream", e5),
    ("E6", "events() of an unknown run raises unknown_run", e6),
    ("K1", "claim() has exactly {claim, diff, head_sha}, correctly typed", k1),
    ("K2", "the claim equals the stream's terminal status, in either read order", k2),
    ("K3", "a done claim carries a diff", k3),
    ("K4", "the claimed diff applies cleanly to base_sha", k4),
    ("K5", "head_sha, when given, is a commit whose tree is base_sha + diff", k5),
    ("K6", "base_sha + diff is exactly the change that was made", k6),
    ("K7", "claim() replays the same claim", k7),
    ("K8", "claim() of an unknown run raises unknown_run", k8),
)


def catalogue():
    return [(rule_id, title) for rule_id, title, _ in RULES]


def _result(rule_id, title, status, detail=None):
    return {"id": rule_id, "title": title, "status": status, "detail": detail}


def run(mod, fixture, variants, load_error=None):
    """Judge `mod` against every rule; returns one {id, title, status: pass|fail|skip, detail} per rule, in order."""
    results = []
    surface = [load_error] if load_error else (m1(mod) if mod is not None else ["no module"])
    if surface:
        results.append(_result("M1", RULES[0][1], "fail", "; ".join(surface)[:700]))
        results += [_result(rid, title, "skip", "skipped: the module surface (M1) failed") for rid, title, _ in RULES[1:]]
        return results
    results.append(_result("M1", RULES[0][1], "pass"))
    ctx = Ctx(mod, fixture, variants)
    for rule_id, title, judge in RULES[1:]:
        try:
            problems = judge(ctx)
        except Skip as why:
            results.append(_result(rule_id, title, "skip", str(why)))
            continue
        except Exception as exc:  # noqa: BLE001 - a rule that crashes must never read as a pass
            results.append(_result(rule_id, title, "fail", "suite error while judging: %s" % describe(exc)))
            continue
        results.append(_result(rule_id, title, "fail", "; ".join(problems[:_MAX_PROBLEMS * 2])[:700]) if problems else _result(rule_id, title, "pass"))
    return results
