#!/usr/bin/env python3
# cp_boot.py — THE ASSEMBLY POINT of the Heimdall control plane.
#
# DESIGN DOSSIER §10 (the registration seam). cp_server ships ONLY the built-in
# /dispatch entry; every other capability (ingest/dashboard/schedules/jobs/
# approvals/notifications) lives in a sibling cp_* module that plugs ITS routes in
# via cp_server.register_route WITHOUT editing cp_server. That disjointness is the
# point — but a server that imports only cp_server therefore exposes NOTHING beyond
# /dispatch. SOMETHING has to call every piece's registration entrypoint against the
# live server. That something is boot().
#
# boot(server, ...) does three things, in order:
#   1. ASSEMBLE — import every capability piece and call its route-registration
#      function against the live cp_server module, so the running server exposes the
#      full surface: /ingest, /dashboard, /schedules, /jobs (+status/pause/resume/
#      cancel), /approvals/* and /notifications.
#   2. RESUME — call cp_worker.resume_orphans so a job left mid-flight (queued /
#      interrupted) when the process died is re-driven to completion on the next boot
#      (§4 replay-on-boot). Durable jobs are self-healing across a full restart.
#   3. TICK — start a daemon thread that calls cp_scheduler.tick() once a minute so
#      stored cron schedules FIRE autonomously. The scheduler has no privileged
#      dispatch (§6): tick() builds the SAME (identity, action_type, params) call a
#      manual client would and re-validates through cp_server.dispatch — the tick
#      driver only makes the clock turn.
#
# boot() is idempotent at the route level (register_route replaces a key) but starts
# AT MOST ONE tick thread per process (guarded), so a double-boot does not spawn two
# clocks. It returns a BootResult describing what it wired — for status/CLI/tests.
#
# stdlib-only (threading/datetime/json/os) + the sibling cp_* substrate modules.

from __future__ import annotations

import datetime
import json
import os
import sys
import threading

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_approval
import cp_auth
import cp_config
import cp_corpus
import cp_dashboard
import cp_diag
import cp_enroll
import cp_ingest
import cp_issue_ingest
import cp_notify
import cp_presence
import cp_scheduler
import cp_server
import cp_worker

# The fixed tick cadence: one wake per minute. cron resolution is per-minute (§6),
# so a per-minute tick fires every schedule on the minute it becomes due, no finer.
TICK_INTERVAL_SECONDS = 60.0

# ── THE TICK WATCHDOG (bug #17: one blocked sub-step must never silence the clock) ──────────
#
# WHY (live prod hang, revision heimdall-control-plane-00050). run_tick() drains each team's
# queue, which reads Firestore. When a backend read wedged (an unbounded collection scan with no
# timeout — since fixed in cp_state_firestore), the tick thread BLOCKED inside run_tick FOREVER:
# no "drain cycle" line, no "tick error" (an exception would have printed one), just SILENCE for
# 8+ minutes while a queued task sat undrained. The loud-tick contract was defeated because a
# BLOCK is not an exception. THE WATCHDOG closes that gap structurally: run_tick runs in a worker
# thread the loop WAITS ON for a bounded budget. If the step overruns, the loop ABANDONS THE WAIT
# (never the durable work — the worker keeps finishing in the background), emits a LOUD
# "drain step timeout" line, and continues to the next wake — so ONE slow/blocked step can no
# longer silence the loop. An OVERLAP GUARD refuses to start a second run_tick while a prior one
# is still finishing, so schedules/drains are never double-fired.
_TICK_STEP_TIMEOUT_ENV = "HEIMDALL_CP_TICK_STEP_TIMEOUT_SECONDS"
# 55s < the 60s cadence: a normal wake (drain + dispatch) finishes well under this, while a truly
# wedged step is detected within one cadence. Overridable per deploy / injectable per test.
_TICK_STEP_TIMEOUT_DEFAULT = 55.0

# PERIODIC RESUME (audit §3a fix (a)). resume_orphans runs at boot, but with min-instances=1
# the gated instance stays warm for days, so a boot-only replay almost never re-runs — a job
# stuck `queued` (a failed cloudrun-job dispatch) or `running` (a dead job-container) sits
# stuck indefinitely. So the tick ALSO runs a resume pass every Nth wake. At the 60s cadence
# every 5th tick is ~5 minutes — frequent enough to reclaim a dead job promptly, rare enough
# not to add load. The pass is idempotent (run_job no-ops non-orphan states).
_RESUME_EVERY_TICKS = 5

# At-most-one tick thread per process. boot() may be called more than once (a test
# re-wiring, a re-import); the route registration is idempotent but a second clock
# would double-fire schedules. This guards the singleton.
_TICK_LOCK = threading.Lock()
_TICK_STARTED = False


class BootResult:
    """What boot() wired — for status/CLI/tests. Carries the registered route keys
    (per piece), the orphan jobs it re-drove, and whether the tick thread started."""

    def __init__(self, routes, resumed, tick_started, server_identity=None):
        self.routes = routes              # {piece -> [(METHOD, path), ...]}
        self.resumed = resumed            # [(job_id, final_state), ...]
        self.tick_started = tick_started  # bool
        # The deterministic server signing identity established at boot (no private seed in
        # it — only the seeded/haid/public_key/registered status). None when not computed.
        self.server_identity = server_identity

    def to_dict(self):
        return {
            "routes": {
                piece: ["%s %s" % (m, p) for (m, p) in keys]
                for piece, keys in self.routes.items()
            },
            "resumed": [
                {"job_id": jid, "state": state} for (jid, state) in self.resumed
            ],
            "tick_started": self.tick_started,
            "server_identity": self.server_identity,
            "registered_routes": [
                "%s %s" % (m, p) for (m, p) in cp_server.registered_routes()
            ],
        }


def _owner_haids(home=None):
    """The registered HAIDs flagged owner:true — the identities the tick driver fires
    schedules AS (§6/§7). Resolved THROUGH cp_auth.owner_haids, which reads the key
    registry via the StateBackend (get_record), NOT via keys_path()/open().

    THE INCIDENT THIS FIXES (live, firestore deploy). This used to enumerate owners by
    cp_auth.keys_path(home) + open()ing that file. keys_path() routes to backend.path(),
    and FirestoreBackend.path() RAISES BackendUnavailable by design (a firestore-backed
    rel has no local file). So under HEIMDALL_STATE_BACKEND=firestore the per-minute tick
    raised every 60s, even though /readyz (which probes via _db()/read_lines, never path())
    reported the backend ready — the tick's data-access path diverged from the probe's.
    The fix is in THIS caller: the owner registry is a keyed JSON record, so we read it
    with the firestore-safe record accessor instead of a filesystem path. An absent/garbled
    registry still yields [] — a server with no owners simply has no autonomous tick
    principal, which is honest.

    A schedule is owned by the owner_haid that created it; tick(identity, ...) fires as
    one identity per call, so the driver loops the owners and ticks once per owner — each
    owner's due schedules fire AS that owner (the create-time gate they passed)."""
    return cp_auth.owner_haids(home)


def _stderr(msg):
    """Write one LOUD diagnostic line to stderr (Cloud Run captures stderr into the service
    logs). Best-effort: a logging failure is swallowed so it can NEVER break the tick."""
    try:
        sys.stderr.write("%s\n" % msg)
        sys.stderr.flush()
    except Exception:  # noqa: BLE001 — diagnostic only; a write error must not break the tick.
        return


def _exc_line(exc):
    """Format a swallowed exception as `Type: <scrubbed message>` — the silent-drain lesson
    says a swallowed fault must say WHY, but a message could carry a secret, so the message is
    run through telemetry's scrub (lazy import; falls back to the bare type name if unavailable).
    Never a bare swallow, never a raw token."""
    try:
        import telemetry
        msg = telemetry._scrub(str(exc))
    except Exception:  # noqa: BLE001 — the log line must survive a scrub/import failure.
        return type(exc).__name__
    return "%s: %s" % (type(exc).__name__, msg)


def run_tick(*, home=None, base_env=None, now=None, approved_action_types=None):
    """Fire one scheduler tick for EVERY registered owner identity (§6). Returns the
    flat list of fired-dispatch outcomes across all owners (the run log a caller — the
    tick thread or a test — inspects). Pure of sockets; each owner's due schedules go
    through cp_scheduler.tick -> cp_server.dispatch -> the §1 allowlist + §9 audit, the
    exact path a manual client takes. An owner with no due schedule contributes nothing.

    A build where the scheduler could fire an arbitrary command would have to bypass
    this and exec a raw string — there is no such path: run_tick only relays to tick(),
    and tick() can ONLY fire allowlisted dispatches."""
    when = now if now is not None else datetime.datetime.now(datetime.timezone.utc)
    fired = []
    for haid in _owner_haids(home):
        identity = cp_auth.Identity(haid, owner=True)
        fired.extend(cp_scheduler.tick(
            identity, when, home=home, base_env=base_env,
            approved_action_types=approved_action_types,
        ))
    # DRAIN (§4 multi-tenant intake): on the public multi-tenant deploy the gated tick ALSO
    # sweeps each team's enqueue-only /rr-task queue -> dispatch through the repo<->team authz
    # gate + per-team env (cp_maintainer_runner.drain_all_team_queues). Lazy import (avoid a
    # load-time cycle) + flag-gated (HEIMDALL_RR_TENANT_AUTHZ), so the single-tenant tick is
    # byte-for-byte unchanged when the flag is off.
    import cp_maintainer_runner  # lazy — mirrors cp_scheduler's lazy import of the same module.
    if cp_maintainer_runner.tenant_authz_enabled():
        drains = cp_maintainer_runner.drain_all_team_queues(
            home=home, base_env=base_env, now=when)
        # LOUD per-cycle drain log (the silent-drain lesson: a swallowed drain is why a live
        # task got stuck). One header line naming how many teams were scanned, then the
        # per-team drain_team_queue lines (DISPATCHED / REFUSED / DEAD) already emitted inside
        # the drain. This runs INSIDE the gated image, so the fix only reaches prod on a
        # rebuild+redeploy (deploy-public-rr.sh) — the warm loud tick then drains + dispatches.
        _drain_scanned = len(drains)
        _drain_dispatched = sum(len(d.get("arms") or []) for d in drains)
        _drain_retried = sum(len(d.get("retried") or []) for d in drains)
        _drain_dead = sum(len(d.get("dead") or []) for d in drains)
        _stderr("cp_boot: drain cycle: teams_scanned=%d dispatched=%d retried=%d dead=%d"
                % (_drain_scanned, _drain_dispatched, _drain_retried, _drain_dead))
        for drain in drains:
            _stderr("cp_boot: drain team=%s processed=%d dispatched=%d retried=%d dead=%d%s"
                    % (str(drain.get("team_id"))[:8], drain.get("processed", 0),
                       len(drain.get("arms") or []), len(drain.get("retried") or []),
                       len(drain.get("dead") or []),
                       (" reason=%s" % drain.get("reason")) if drain.get("reason") else ""))
            fired.append({
                "schedule_id": None,
                "action_type": cp_maintainer_runner.MAINTAINER_ACTION_TYPE,
                "status": 200,
                "team_drain": drain.get("team_id"),
                "processed": drain.get("processed", 0),
                "retried": len(drain.get("retried") or []),
                "dead": len(drain.get("dead") or []),
            })
    return fired


def _maybe_resume(tick_count, *, home=None, base_env=None, every=_RESUME_EVERY_TICKS):
    """Every `every`-th tick, run ONE resume pass (re-drive queued orphans + reclaim
    stuck-running jobs, cp_worker.resume_orphans_pass) and emit the LOUD resume line
    `cp_boot: resume pass: requeued=N reclaimed=N`. Returns the pass dict on a resume
    tick, or None on a non-resume tick. Split out of the loop so the cadence is unit-
    testable with a plain counter (no threads, no wall clock) — audit §3a fix (a)."""
    if every <= 0 or tick_count % every != 0:
        return None
    result = cp_worker.resume_orphans_pass(home=home, base_env=base_env)
    _stderr("cp_boot: resume pass: requeued=%d reclaimed=%d"
            % (result.get("requeued", 0), result.get("reclaimed", 0)))
    return result


def _step_timeout(explicit=None):
    """The tick-step watchdog budget in seconds: an explicit positive `explicit` wins (tests),
    else HEIMDALL_CP_TICK_STEP_TIMEOUT_SECONDS, else _TICK_STEP_TIMEOUT_DEFAULT (55s). A malformed
    / non-positive override falls back to the default so a misconfig never DISABLES the watchdog."""
    if isinstance(explicit, (int, float)) and explicit > 0:
        return float(explicit)
    raw = os.environ.get(_TICK_STEP_TIMEOUT_ENV)
    try:
        val = float(raw) if raw not in (None, "") else _TICK_STEP_TIMEOUT_DEFAULT
    except (TypeError, ValueError):
        return _TICK_STEP_TIMEOUT_DEFAULT
    return val if val > 0 else _TICK_STEP_TIMEOUT_DEFAULT


class _StepWorker:
    """Runs one tick sub-step (run_tick) in a daemon thread so the loop can BOUND how long it
    waits on it (bug #17 watchdog). A step that overruns the budget is ABANDONED by the WAITER,
    not killed — the worker keeps finishing in the background (its durable side effects still
    land), and the loop refuses to start a NEW run of the step until this one finishes (the
    overlap guard, so schedules/drains are never double-fired). Captures the result AND any
    exception so the loop can log a `tick error` exactly as the synchronous path did."""

    __slots__ = ("label", "_fn", "result", "exc", "done", "_thread")

    def __init__(self, label, fn):
        self.label = label
        self._fn = fn
        self.result = None
        self.exc = None
        self.done = threading.Event()
        self._thread = threading.Thread(target=self._run, name="cp-tick-step", daemon=True)

    def _run(self):
        try:
            self.result = self._fn()
        except BaseException as exc:  # noqa: BLE001 — capture EVERYTHING so the loop reports it.
            self.exc = exc
        finally:
            self.done.set()

    def start(self):
        self._thread.start()

    def wait(self, timeout):
        """True iff the step finished within `timeout` seconds; False if it overran (abandon)."""
        return self.done.wait(timeout)

    @property
    def alive(self):
        return self._thread.is_alive()


def _tick_loop(stop_event, *, home, base_env, interval, on_tick, step_timeout=None):
    """The tick thread body: wake every `interval` seconds and run_tick() for the registered
    owners, plus a periodic resume pass every _RESUME_EVERY_TICKS wakes (audit §3a). Stops
    promptly when `stop_event` is set.

    WATCHDOG (bug #17): each wake emits a LOUD "tick wake #N" line FIRST (liveness is now visible
    every cadence, so a wedged step can never produce total silence), then runs run_tick in a
    worker thread the loop waits on for `step_timeout` (default 55s). If run_tick overruns, the
    loop emits "drain step timeout" and continues — it does NOT start a second run_tick until the
    prior worker finishes (overlap guard), so one blocked/slow step neither silences the clock nor
    double-fires work. A run_tick that RAISES is reported as "tick error" exactly as before. The
    periodic resume runs on cadence regardless of run_tick's fate (its backend calls are timed)."""
    tick_count = 0
    budget = _step_timeout(step_timeout)
    inflight = None  # a _StepWorker whose run_tick has not finished yet (the overlap guard).
    while not stop_event.wait(interval):
        tick_count += 1
        _stderr("cp_boot: tick wake #%d" % tick_count)  # LOUD liveness — silence now impossible.
        # OVERLAP GUARD: never start a second run_tick while a prior one is still finishing.
        if inflight is not None and inflight.alive:
            _stderr("cp_boot: drain step still running: %s (prior wake not finished — skipping "
                    "this wake's run_tick, loop continues)" % inflight.label)
        else:
            inflight = _StepWorker(
                "run_tick", lambda: run_tick(home=home, base_env=base_env))
            inflight.start()
            if inflight.wait(budget):
                # Settled within budget: report an exception as `tick error`, else fan out on_tick.
                if inflight.exc is not None:
                    _stderr("cp_boot: tick error: %s" % _exc_line(inflight.exc))
                elif on_tick is not None and inflight.result:
                    try:
                        on_tick(inflight.result)
                    except Exception as exc:  # noqa: BLE001 — observer fault never stops clock.
                        _stderr("cp_boot: on_tick error: %s" % _exc_line(exc))
                inflight = None  # settled — the next wake may start a fresh run_tick.
            else:
                # WATCHDOG FIRES: abandon the WAIT (not the worker); stay loud, keep the loop
                # turning. The worker finishes in the background; the overlap guard blocks a
                # duplicate run_tick until it does.
                _stderr("cp_boot: drain step timeout: %s exceeded %.0fs — abandoning wait, loop "
                        "continues (worker finishing in background)" % (inflight.label, budget))
        # PERIODIC RESUME — re-drive orphaned /jobs work off the warm tick, not only at boot.
        # Runs on cadence regardless of run_tick's fate; a resume fault must not kill the clock.
        try:
            _maybe_resume(tick_count, home=home, base_env=base_env)
        except Exception as exc:  # noqa: BLE001 — a resume fault must not kill the clock.
            _stderr("cp_boot: resume pass error: %s" % _exc_line(exc))


def start_tick_thread(*, home=None, base_env=None,
                      interval=TICK_INTERVAL_SECONDS, on_tick=None, step_timeout=None):
    """Start the per-minute scheduler tick daemon (at most one per process). Returns
    (thread, stop_event) on a fresh start, or (None, None) if a tick thread already
    runs in this process (the singleton guard — a double-boot does not spawn two
    clocks). The thread is a daemon so it never blocks interpreter shutdown; pass the
    returned stop_event to stop it cleanly. `step_timeout` overrides the watchdog budget
    (default env/_TICK_STEP_TIMEOUT_DEFAULT) — injectable for deterministic tests."""
    global _TICK_STARTED
    with _TICK_LOCK:
        if _TICK_STARTED:
            return None, None
        stop_event = threading.Event()
        thread = threading.Thread(
            target=_tick_loop,
            kwargs={"stop_event": stop_event, "home": home, "base_env": base_env,
                    "interval": interval, "on_tick": on_tick, "step_timeout": step_timeout},
            name="cp-scheduler-tick",
            daemon=True,
        )
        thread.start()
        _TICK_STARTED = True
        return thread, stop_event


def boot(server=cp_server, *, home=None, base_env=None, start_tick=True,
         resume=True):
    """ASSEMBLE the control plane against the live server (§10) and return a BootResult.

    `server` is the cp_server module (the route seam lives there; passed explicitly so
    a test can hand in the same module the running server uses). For each capability
    piece, call ITS registration entrypoint so the running server exposes the full
    surface — then resume orphaned jobs (§4) and start the per-minute tick clock (§6).

    Steps:
      1. register every piece's routes (ingest/dashboard/schedules/jobs/approvals/
         notifications) — closing the runtime `home` into the home-aware ones so the
         routes write to the SAME home the server serves.
      2. resume_orphans — re-drive jobs left queued/interrupted across a restart.
      3. start_tick_thread — the autonomous per-minute scheduler driver.

    `start_tick=False` / `resume=False` let a test wire routes WITHOUT a clock or a
    replay (deterministic). Idempotent: routes replace, the tick thread is singleton."""
    # 0. SERVER IDENTITY — establish the deterministic signing identity from the PKI seed
    #    BEFORE anything else (the GAP fix wired). When HEIMDALL_CP_PKI_KEY is present the
    #    server derives the SAME keypair every cold-start and re-binds its HAID→pubkey in
    #    the registry, so PKI identity is stable across Cloud Run instances. In the cloud
    #    profile an absent/invalid seed makes ensure_server_identity RAISE (fail-closed) —
    #    we let it propagate so the boot refuses to serve with an unstable identity rather
    #    than silently minting a per-instance key. Locally (no seed, no cloud signal) it is
    #    a no-op and the dev `identity` mint path still owns registration.
    server_identity = cp_auth.ensure_server_identity(home=home)

    routes = {}

    # 1. ASSEMBLE — every piece plugs its routes into the live seam. The home-aware
    #    pieces (ingest/dashboard/jobs/approvals) close the runtime home in so they
    #    write to the home the server serves; the home-free pieces (schedules/notify)
    #    resolve home per-call from the runtime environment.
    routes["ingest"] = [cp_ingest.register(home=home)]
    # Pre-merge corpus ingest (§5.2): the SIGNED POST /corpus lands a client's spooled PMR T0
    # batch (+ opt-in T1 hunks) in the ISOLATED heimdall_corpus/ namespace (never the control-
    # plane store), keyed by the SERVER-DERIVED team_id_hash (INV-1). DATA only — no dispatch,
    # no cred, no model call (BYO-inference). The route is in cp_publicsurface.PUBLIC_ROUTES.
    routes["corpus"] = [cp_corpus.register(home=home)]
    # Anonymized issue ingest (issue-collection, Wave 3 wire-boot): the SIGNED POST /issues lands
    # a client's spooled zero-content issue_v1 batch in the SAME ISOLATED heimdall_corpus/ namespace
    # as /corpus but a DISJOINT issues/ partition (never the control-plane store), keyed by the
    # SERVER-DERIVED team_id_hash (INV-C). DATA only — no dispatch, no handler, no model call. An
    # unsigned push 401s at the auth chokepoint; no team resolves -> 403 fail-closed. Sibling of the
    # corpus route above; the wire-public-surface task adds POST /issues to cp_publicsurface.
    routes["issues"] = [cp_issue_ingest.register(home=home)]
    routes["dashboard"] = [cp_dashboard.register(home=home)]
    routes["schedules"] = list(cp_scheduler.register_routes())
    routes["jobs"] = list(cp_worker.register_job_routes(home=home, base_env=base_env))
    routes["approvals"] = list(cp_approval.register(home=home))
    routes["notifications"] = [cp_notify.register_notify_routes(server.register_route)]
    # Team presence (§presence): POST /presence heartbeat + GET /roster?project=<p>.
    # External-keyed on the StateBackend seam, so the online team survives scale-to-zero
    # (Firestore-durable) — a dev on a fresh instance reads heartbeats another dev wrote.
    routes["presence"] = list(cp_presence.register(home=home))
    # Token-gated self-enroll (§pki-bootstrap): POST /enroll binds a dev's first-run pubkey to
    # its HAID with ZERO manual steps, after which its signed presence beats verify. Wired into
    # the PRE-AUTH public seam (the caller has no key to sign with yet) and gated by the
    # server-side HEIMDALL_ENROLL_TOKEN secret — fail-closed when that secret is unset.
    routes["enroll"] = list(cp_enroll.register(home=home))
    # Server-driven adaptive intervals (cost-governance §2): GET /config serves the current
    # spend-pace interval ladder to every client (statusline/watch/ext/hooks), UNSIGNED because
    # a browser cannot PKI-sign. Pre-auth public seam; the client clamps every interval to
    # [15s,300s] so a spoofed/broken config can never DoS it. (GET,/config) is also in
    # cp_publicsurface.PUBLIC_ROUTES so the public surface serves it, not a flat 404.
    routes["config"] = list(cp_config.register(home=home))
    # The unauthenticated Cloud Run health probes (§A). Registered into the seam for
    # status/CLI visibility (registered_routes() reflects /healthz + /readyz); the LIVE
    # serving of these two bypasses the seam and runs pre-auth in cp_server. Idempotent.
    routes["diagnostics"] = list(cp_diag.register(server, home=home))

    # 2. RESUME — re-drive jobs left mid-flight when the process died (§4 replay-on-boot).
    resumed = []
    if resume:
        resumed = cp_worker.resume_orphans(home=home, base_env=base_env)

    # 3. TICK — the autonomous per-minute scheduler clock (§6). At-most-one per process.
    tick_started = False
    if start_tick:
        thread, _ = start_tick_thread(home=home, base_env=base_env)
        tick_started = thread is not None

    return BootResult(routes, resumed, tick_started, server_identity=server_identity)


# Allow a quick local introspection: `python3 cp_boot.py` wires against the default
# home (no clock, no replay) and prints the resulting route table as JSON.
if __name__ == "__main__":
    result = boot(start_tick=False, resume=False)
    print(json.dumps(result.to_dict(), indent=2, sort_keys=True))
