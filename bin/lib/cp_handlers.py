#!/usr/bin/env python3
# cp_handlers.py — piece (a) of the Heimdall control plane: THE BOUNDED HANDLERS.
#
# DESIGN DOSSIER §1/§2 (authoritative). These are the ONLY targets an allowlisted
# action_type can resolve to (cp_allowlist.ActionSpec.handler names one of these by
# a dotted "cp_handlers.<fn>" ref). The server resolves a handler from a REGISTERED
# map, never from the wire — a handler is named, never code-from-the-request.
#
# THE HANDLER CONTRACT (every handler honors it):
#   handler(params, ctx) -> result-dict
#     params — the VALIDATED, typed, bounded params from cp_allowlist.validate().
#              A handler receives ONLY these — never the raw request body, never a
#              string to interpret as a command. By the time a handler runs, the
#              allowlist has already proven the params are id-shaped / enum / int.
#     ctx    — an IsolatedContext (§2): the control/data-plane line, made concrete.
#              It exposes the job's SCRATCH dir + a SCOPED token, and DENIES any
#              read of the PKI private key / audit log / server secrets. A handler
#              cannot reach control-plane state through ctx.
#
# THE CONTROL/DATA-PLANE LINE (§2), made a concrete contract here: an `isolated`
# action runs against an IsolatedContext whose env is SCRUBBED to an allowlist (only
# the job's validated params + a scoped token + a per-job HEIMDALL_HOME scratch dir)
# and whose accessors REFUSE control-plane paths. The worker (piece d) builds the
# real low-priv process; THIS module pins the contract that worker MUST honor — the
# isolated-context interface d binds to. The server NEVER runs an arbitrary command;
# a handler does bounded, named work against the isolated context only.
#
# These handlers do REAL bounded work (queue reconciliation status, suite selection)
# without executing an arbitrary command. They return a structured result the job
# runner (piece d) records. A handler NEVER shells out to a wire-supplied string.
#
# THE INTERFACE pieces (b)-(f) BIND to (stable; they import, never edit):
#   IsolatedContext              — the §2 isolated-context contract piece d honors.
#   HANDLERS                     — the registered {name: callable} handler map.
#   resolve(handler_ref)         — resolve a dotted "cp_handlers.fn" -> callable.
#   run_task / sync_queue / run_suite — the three bounded handlers.
#
# stdlib-only (os) + cp_allowlist (sibling) — minimal self-host deps.

from __future__ import annotations

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_allowlist  # the allowlist a handler ref resolves against (defence in depth).


# ── the §2 isolated-context contract (the control/data-plane line) ─────────────


# The env keys an isolated job is ALLOWED to see. EVERYTHING else is scrubbed — in
# particular nothing pointing at the control-plane key dir / audit store / DB creds.
# This is the env allowlist the dossier's §2 isolation invariant names. The worker
# (piece d) builds the real low-priv process around this exact allowlist.
ISOLATED_ENV_ALLOW = (
    "PATH",            # a job needs a PATH to find coreutils — but NOT the server env.
    "LANG",
    "LC_ALL",
    "TZ",
)

# Control-plane path FRAGMENTS an isolated context must REFUSE to hand a job. A job
# that asks the context for any path under these is denied — the isolation invariant
# made enforceable, not aspirational (§2). These mirror the cp_* store roots.
_CONTROL_PLANE_DENY = (
    os.path.join("control-plane", "auth"),    # the PKI private/public key registry.
    os.path.join("control-plane", "audit"),   # the audit log.
    "keys.json",
    "audit.ndjson",
)


class IsolationViolation(Exception):
    """Raised when an isolated job asks its context for a control-plane resource it
    must NOT be able to read (the PKI key, the audit log, server secrets). The §2
    isolation invariant, enforced — a control-plane compromise must not equal a fleet
    compromise, so a job that reaches for control-plane state is refused HERE."""


class IsolatedContext:
    """The §2 control/data-plane line, made a concrete object a handler runs against.

    It pins the contract the worker (piece d) MUST honor for an `isolated` action:
      * scratch_dir — a per-job scratch HEIMDALL_HOME the job may freely read/write.
                      It is NOT the server's runtime home; a job writing here cannot
                      touch the control-plane stores.
      * scoped_token — a short, per-job opaque token (the only credential a job
                      gets); it is NOT the PKI private key and grants nothing beyond
                      the job's own progress channel.
      * scrubbed_env() — the env an isolated process gets: ONLY ISOLATED_ENV_ALLOW
                      keys, NEVER the server's secret-bearing env.
      * resolve_path(rel) — resolve a path UNDER the scratch dir, REFUSING any
                      control-plane path (raises IsolationViolation). A job cannot
                      escape the scratch dir to read the key dir / audit store.

    The server constructs one of these per isolated dispatch; the worker (d) is the
    process that actually runs the handler inside it. THIS class is the seam d binds
    to — d builds the low-priv uid + process; the interface is fixed here so d never
    edits this file."""

    def __init__(self, scratch_dir, scoped_token, *, base_env=None):
        self.scratch_dir = os.path.abspath(scratch_dir)
        self.scoped_token = scoped_token
        self._base_env = dict(base_env if base_env is not None else os.environ)

    def scrubbed_env(self):
        """The env an isolated job is handed: ONLY the ISOLATED_ENV_ALLOW keys from
        the base env, plus the per-job scratch HEIMDALL_HOME + the scoped token. The
        server's secret-bearing vars (anything else) are DROPPED — a job's process
        env carries no control-plane credential (§2 env allowlist)."""
        env = {}
        for k in ISOLATED_ENV_ALLOW:
            if k in self._base_env:
                env[k] = self._base_env[k]
        env["HEIMDALL_HOME"] = self.scratch_dir
        env["HEIMDALL_JOB_TOKEN"] = self.scoped_token
        return env

    def resolve_path(self, rel):
        """Resolve `rel` UNDER the job scratch dir, REFUSING any control-plane path.
        Raises IsolationViolation if the request names a control-plane store fragment
        OR escapes the scratch dir (`..` traversal). A handler reads/writes ONLY its
        own scratch space through this — the §2 invariant made enforceable."""
        low = str(rel).replace("\\", "/").lower()
        for frag in _CONTROL_PLANE_DENY:
            if frag.replace("\\", "/").lower() in low:
                raise IsolationViolation(
                    "isolated job may not access control-plane resource")
        full = os.path.abspath(os.path.join(self.scratch_dir, rel))
        if full != self.scratch_dir and not full.startswith(self.scratch_dir + os.sep):
            raise IsolationViolation("path escapes the job scratch dir")
        return full


# ── the three bounded handlers (the only allowlist targets — §1/§2) ────────────
#
# Each does REAL, bounded, named work against its validated params + the isolated
# context. NONE shells out to a wire-supplied string. The result dict is what the
# job runner (piece d) records as the job's outcome.


def run_task(params, ctx):
    """Handle the `run-task-X` action: prepare a single named task for execution in
    the isolated context. params carries the validated, id-shaped `task_id` (the
    allowlist already proved it is slug-shaped — no shell metacharacters). Returns a
    structured plan the worker (d) executes inside ctx. Does NOT itself spawn an
    arbitrary process — it names the bounded work + the scratch location."""
    task_id = params["task_id"]
    workdir = ctx.resolve_path(os.path.join("tasks", task_id))
    os.makedirs(workdir, exist_ok=True)
    return {
        "action": "run-task-X",
        "task_id": task_id,
        "workdir": workdir,
        "isolated": True,
        "status": "prepared",
    }


def sync_queue(params, ctx):
    """Handle the `sync-queue` action: reconcile one of the two named queues. `queue`
    is a validated Enum ('issue'|'gate') — no free string. Returns a structured sync
    descriptor (the queue + the scratch location the worker reconciles into). Bounded,
    named work; no arbitrary command."""
    queue = params["queue"]
    workdir = ctx.resolve_path(os.path.join("sync", queue))
    os.makedirs(workdir, exist_ok=True)
    return {
        "action": "sync-queue",
        "queue": queue,
        "workdir": workdir,
        "isolated": True,
        "status": "prepared",
    }


def run_suite(params, ctx):
    """Handle the `run-suite` action: run a named test suite. `suite` is a validated
    Enum ('unit'|'integration'|'oracle') — no free string. This action requires_gate
    (§7), so the server only reaches this handler AFTER an owner approval landed.
    Returns a structured run descriptor for the worker. Bounded; no arbitrary cmd."""
    suite = params["suite"]
    workdir = ctx.resolve_path(os.path.join("suites", suite))
    os.makedirs(workdir, exist_ok=True)
    return {
        "action": "run-suite",
        "suite": suite,
        "workdir": workdir,
        "isolated": True,
        "status": "prepared",
    }


# ── the registered handler map + resolver (named, never code-from-the-wire) ────
#
# The server resolves an ActionSpec.handler ("cp_handlers.run_task") to a callable
# via THIS map only. A handler ref that does not resolve here is refused — there is
# no eval, no import-from-string, no dynamic load of a wire-named module.

HANDLERS = {
    "cp_handlers.run_task": run_task,
    "cp_handlers.sync_queue": sync_queue,
    "cp_handlers.run_suite": run_suite,
}


def resolve(handler_ref):
    """Resolve a dotted handler ref ("cp_handlers.run_task") to its callable from the
    registered HANDLERS map ONLY. Returns the callable, or raises KeyError for an
    unregistered ref. Defence in depth: even if a malformed ActionSpec named an
    unregistered handler, the server refuses the dispatch here rather than importing
    or eval-ing a wire-influenced name. Confirms the ref's spec is allowlisted."""
    # belt-and-braces: the ref must belong to a real allowlist entry's handler.
    if handler_ref not in {spec.handler for spec in cp_allowlist.ALLOWLIST.values()}:
        raise KeyError("handler ref is not named by any allowlist entry")
    if handler_ref not in HANDLERS:
        raise KeyError("handler ref is not registered")
    return HANDLERS[handler_ref]
