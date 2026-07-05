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

import json
import os
import re
import subprocess
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

    def source_env(self):
        """A COPY of the base (pre-scrub) env the context was built from — the env the
        DISPATCHING process (the operator's machine in Arch A, the Cloud Run Job container
        in Arch B) actually carries, including any Secret-Manager-injected credential.

        This is NOT what a job's child process receives (that is scrubbed_env(), which
        DROPS every secret). It is the source a TRUSTED, source-reviewed handler reads to
        SELECTIVELY copy the ONE credential its bounded work legitimately needs into a
        child env — e.g. run_maintainer_cycle picks the single LLM auth var and injects it,
        never the PKI key / audit creds. The §2 isolation guarantee is about the CHILD env
        (scrubbed baseline + only the explicitly-selected var), not the handler's own read
        access; a handler is allowlisted code reviewed in a PR, not code-from-the-wire."""
        return dict(self._base_env)

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


# ── run-maintainer-cycle: drive the durable autopilot loop (both-auth, no-secret-log) ─
#
# THE FIXED-ARGV CONTRACT. This handler NEVER interpolates untyped data into a shell.
# It builds a FIXED argv list — [<loop-bin>, "run", "--repo", <repo>, "--max", <max>,
# ("--budget-tokens", <budget>)?] — from ALREADY-VALIDATED params (the allowlist proved
# `repo` is an owner/name slug with no shell metachars, `max`/`budget_tokens` are bounded
# ints) and runs it with subprocess.run(argv, shell=False). There is no shell, no eval,
# no wire-supplied command. The maintainer PROMPT is built INSIDE heimdall-maintain-loop
# from the queued issue — it is NEVER a control-plane param (the security spine).
#
# BOTH-AUTH, ENV-ONLY, NEVER-LOGGED. The loop's child needs an LLM credential. We select
# it from the base (source) env — preferring CLAUDE_CODE_OAUTH_TOKEN (a `claude setup-token`
# OAuth token that authorizes headless against the operator's Max subscription — cheap),
# else ANTHROPIC_API_KEY (metered, always-works fallback) — and inject EXACTLY the one
# selected var into the child env, on top of the scrubbed baseline. The token travels by
# ENV ONLY: never an argv element, never the returned result, never an audit/telemetry
# field, never a log line. Arch A (SubprocessRunner on the operator's box) and Arch B
# (CloudRunJobRunner with the token from Secret Manager) both land the credential in the
# dispatching process env, from which we selectively copy it.

# The two LLM-auth env vars, in PREFERENCE order (OAuth subscription first, metered second).
AUTH_ENV_OAUTH = "CLAUDE_CODE_OAUTH_TOKEN"
AUTH_ENV_API_KEY = "ANTHROPIC_API_KEY"
AUTH_ENV_ORDER = (AUTH_ENV_OAUTH, AUTH_ENV_API_KEY)

# Beyond the scrubbed baseline (PATH/LANG/LC_ALL/TZ + HEIMDALL_HOME + scoped token) the
# maintainer child ALSO needs a bounded set of NON-secret config roots + the PR bot token
# to do its real work: HOME (git/gh/claude read per-user config), PYTHONPATH (the loop's
# sibling-lib imports), and HEIMDALL_PR_BOT_TOKEN (the scoped B1 token issue_pr.py opens
# heimdall/* PRs with — the maintainer OPENS PRs, never pushes main / merges). It ALSO
# needs the NON-secret HEADLESS-FIX toggles so the loop's fix slot actually drives
# `claude -p` to write edits (bug #20 — without them the child ran but produced an EMPTY
# diff): HEIMDALL_FIX_WITH_CLAUDE (the enable flag the deployed maintainer sets),
# HEIMDALL_CLAUDE_BIN (an optional binary override), and HEIMDALL_FIX_TIMEOUT (the per-fix
# wall-clock cap). None is a secret. This is a DELIBERATE, bounded widening for THIS
# handler's child ONLY; it does NOT touch ISOLATED_ENV_ALLOW, so every other handler stays
# maximally scrubbed. The PKI key / audit creds are NEVER in this set — a breached
# maintainer child cannot read control-plane state.
MAINTAINER_ENV_PASSTHROUGH = (
    "HOME",
    "PYTHONPATH",
    "HEIMDALL_PR_BOT_TOKEN",
    "HEIMDALL_FIX_WITH_CLAUDE",
    "HEIMDALL_CLAUDE_BIN",
    "HEIMDALL_FIX_TIMEOUT",
)

# Env var overriding the maintain-loop binary path (tests point it at a hermetic mock,
# mirroring maintain_loop.py's own HEIMDALL_*_BIN override discipline). Absent -> the
# real bin/heimdall-maintain-loop resolved relative to this lib dir.
MAINTAIN_LOOP_BIN_ENV = "HEIMDALL_MAINTAIN_LOOP_BIN"

# Env var bounding one maintainer dispatch (seconds); default 1h, matching the Cloud Run
# Job --task-timeout. A runaway child is killed and the job fails (never hangs the worker).
MAINTAINER_TIMEOUT_ENV = "HEIMDALL_MAINTAINER_TIMEOUT"
MAINTAINER_TIMEOUT_DEFAULT = 3600


def select_maintainer_auth(source_env):
    """Select the ONE LLM-auth credential for the maintainer child from `source_env`,
    preferring the OAuth setup-token (the operator's subscription) over the metered API
    key. Returns a {name: value} dict with EXACTLY the first present var, or {} if NEITHER
    is set (the loop then fails fast on the box's own missing auth — we do not fabricate).
    The value is returned ONLY to be injected into a child env by the caller — it is NEVER
    logged. Never returns both (never require both; prefer whichever is configured)."""
    for name in AUTH_ENV_ORDER:
        val = source_env.get(name)
        if val:
            return {name: val}
    return {}


def _maintainer_passthrough(source_env):
    """The bounded, NON-PKI config/bot-token env the maintainer child also needs, taken
    from `source_env` for the keys actually present (an unset key is omitted, never blanked)."""
    return {k: source_env[k] for k in MAINTAINER_ENV_PASSTHROUGH
            if source_env.get(k)}


def _maintain_loop_bin():
    """Resolve the durable maintain-loop binary: the HEIMDALL_MAINTAIN_LOOP_BIN override
    (tests) or bin/heimdall-maintain-loop relative to this lib dir (bin/lib/.. -> bin/),
    the same bin/ layout every cp_* module assumes."""
    override = os.environ.get(MAINTAIN_LOOP_BIN_ENV)
    if override:
        return override
    return os.path.normpath(os.path.join(_HERE, os.pardir, "heimdall-maintain-loop"))


def build_maintainer_argv(params, *, loop_bin=None):
    """Build the FIXED argv for one maintainer dispatch from ALREADY-VALIDATED params.
    Exposed (pure, no side effects) so the test can assert the exact argv shape with zero
    subprocess spend. Order is fixed; every element is either a literal or a validated,
    bounded scalar (repo slug / bounded int) — NO untyped free string, NO shell."""
    argv = [loop_bin or _maintain_loop_bin(), "run",
            "--repo", params["repo"], "--max", str(params["max"])]
    if params.get("budget_tokens") is not None:
        argv += ["--budget-tokens", str(params["budget_tokens"])]
    # explicit=True is the drain's AUTHORIZATION that this cycle came from a signed rr task;
    # the flag makes the loop run WITHOUT a local heimdall-state.json enable flag (absent in
    # the ephemeral job container). A LITERAL flag element — no untyped data enters the argv
    # (the allowlist already proved `explicit` is a strict bool, never a string payload).
    if params.get("explicit"):
        argv += ["--explicit"]
    return argv


# Token-ish patterns scrubbed from any child error text before it is surfaced (result +
# logs). Covers GitHub tokens (ghs_/ghp_/gho_/github_pat_), Anthropic keys (sk-ant-), and
# PEM private-key headers (the whole -----BEGIN ...  line). A failed cycle must NAME its
# cause WITHOUT ever echoing a credential that leaked into the child's stderr.
_SECRET_SCRUB = re.compile(
    r"(?:ghs_|ghp_|gho_|github_pat_|sk-ant-)[A-Za-z0-9_-]+"
    r"|-----BEGIN[^\n]*"
)

# The error tail is bounded so a runaway child cannot flood the durable result / logs.
_ERROR_TAIL_MAX = 400


def _scrub_secrets(text):
    """Redact token-ish substrings (GitHub / Anthropic / PEM) from `text`. Never returns a
    credential — the surfaced cause is safe to persist and log."""
    return _SECRET_SCRUB.sub("[REDACTED]", text)


def _error_tail(proc, summary):
    """Build a bounded, token-scrubbed cause line from a FAILED child: its stderr (the
    proximate error), plus the tail of stdout when that stdout was NOT parseable JSON (the
    live silent-failure shape — a traceback on stdout instead of a summary). Returns None
    when there is genuinely nothing to report. Truncated to the LAST _ERROR_TAIL_MAX chars
    (the proximate cause sits at the end of a traceback), '…'-prefixed when clipped."""
    parts = []
    err = (proc.stderr or "").strip()
    if err:
        parts.append(err)
    if summary is None:
        out = (proc.stdout or "").strip()
        if out:
            parts.append("stdout: " + out)
    tail = "\n".join(parts).strip()
    if not tail:
        return None
    tail = _scrub_secrets(tail)
    if len(tail) > _ERROR_TAIL_MAX:
        tail = "…" + tail[-_ERROR_TAIL_MAX:]
    return tail


def run_maintainer_cycle(params, ctx):
    """Handle the `run-maintainer-cycle` action: drive the durable maintainer autopilot
    loop (bin/heimdall-maintain-loop) for `max` bounded cycles against `repo`, honoring an
    OPTIONAL `budget_tokens` cap. params are the VALIDATED, typed, bounded scalars from the
    allowlist (repo slug, bounded ints) — never a free string, never a prompt/cmd.

    Execution: a FIXED argv (build_maintainer_argv) run with subprocess.run(shell=False) —
    no shell interpolation of untyped data. The child env is the §2 scrubbed baseline PLUS
    the ONE selected LLM-auth var (OAuth preferred, else API key — ENV ONLY) PLUS the bounded
    non-PKI passthrough (HOME/PYTHONPATH/HEIMDALL_PR_BOT_TOKEN). The auth VALUE is NEVER an
    argv element, NEVER in the returned result, NEVER logged. The loop opens PRs via the bot
    token on scoped heimdall/* branches; it never pushes main / merges — a human gates merge.

    Returns the loop's structured result (its JSON summary: cycles, stop, tally incl. PRs
    opened, budget) plus the SAFE dispatch metadata (the argv — token-free — the selected
    auth var NAME, and the exit code). The parsed stdout summary attaches EVEN on a nonzero
    exit. On a FAILED cycle a bounded, token-SCRUBBED `error_tail` (the child's stderr + any
    non-JSON stdout tail) NAMES the cause in the durable result AND is printed to the job's
    stderr for `gcloud logging read`. Token-free by construction: only the auth var NAME
    (not its value) is ever surfaced, and error text is scrubbed of token-ish patterns."""
    argv = build_maintainer_argv(params)
    src = ctx.source_env()

    # child env: scrubbed baseline (no secrets) + bounded non-PKI passthrough + the ONE
    # selected auth var. The selective copy IS the boundary — the PKI key never enters.
    child_env = ctx.scrubbed_env()
    child_env.update(_maintainer_passthrough(src))
    auth = select_maintainer_auth(src)
    child_env.update(auth)
    auth_source = next(iter(auth), None)  # the var NAME only (e.g. CLAUDE_CODE_OAUTH_TOKEN)

    try:
        timeout = int(os.environ.get(MAINTAINER_TIMEOUT_ENV, MAINTAINER_TIMEOUT_DEFAULT))
    except (TypeError, ValueError):
        timeout = MAINTAINER_TIMEOUT_DEFAULT

    try:
        proc = subprocess.run(  # noqa: S603 — FIXED argv (loop bin + literal flags + our
            argv,               # own validated repo/int scalars), shell=False, no wire input.
            env=child_env,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return {
            "action": "run-maintainer-cycle",
            "repo": params["repo"], "max": params["max"],
            "budget_tokens": params.get("budget_tokens"),
            "explicit": bool(params.get("explicit")),
            "argv": argv, "auth_source": auth_source,
            "isolated": True, "status": "timeout",
        }

    # parse the loop's structured JSON summary from stdout (its `run` subcommand prints it).
    # A non-JSON stdout is surfaced as a bounded, token-free note (never the raw stream).
    summary = None
    parse_error = None
    if proc.stdout:
        try:
            summary = json.loads(proc.stdout)
        except (ValueError, TypeError):
            parse_error = "loop stdout was not JSON"

    result = {
        "action": "run-maintainer-cycle",
        "repo": params["repo"], "max": params["max"],
        "budget_tokens": params.get("budget_tokens"),
        "explicit": bool(params.get("explicit")),  # the drain's rr-task authorization (safe metadata).
        "argv": argv,                 # SAFE: the token is env-only, never an argv element.
        "auth_source": auth_source,   # the auth var NAME only — never its value.
        "exit_code": proc.returncode,
        "summary": summary,           # the loop's own result (cycles, tally incl. PRs, budget).
        "isolated": True,
        "status": "done" if proc.returncode == 0 else "failed",
    }
    if parse_error:
        result["parse_error"] = parse_error

    # A FAILED cycle (nonzero exit, or a child that printed no parseable summary) must NAME
    # its cause — the silent-failure pattern (exit_code:1, summary:null, NO error text) is
    # what made a broken cloud cycle undiagnosable. Surface the child's scrubbed stderr (+
    # non-JSON stdout tail) in BOTH the durable result (result.error_tail) AND the job's own
    # stderr, so `gcloud logging read` shows the cause. Token-ish patterns are scrubbed first.
    if proc.returncode != 0 or summary is None:
        tail = _error_tail(proc, summary)
        if tail:
            result["error_tail"] = tail
            sys.stderr.write(
                "run-maintainer-cycle FAILED (repo=%s exit=%s): %s\n"
                % (params["repo"], proc.returncode, tail)
            )
    return result


# ── the registered handler map + resolver (named, never code-from-the-wire) ────
#
# The server resolves an ActionSpec.handler ("cp_handlers.run_task") to a callable
# via THIS map only. A handler ref that does not resolve here is refused — there is
# no eval, no import-from-string, no dynamic load of a wire-named module.

HANDLERS = {
    "cp_handlers.run_task": run_task,
    "cp_handlers.sync_queue": sync_queue,
    "cp_handlers.run_suite": run_suite,
    "cp_handlers.run_maintainer_cycle": run_maintainer_cycle,
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
