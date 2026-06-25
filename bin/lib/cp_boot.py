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
import cp_dashboard
import cp_diag
import cp_ingest
import cp_notify
import cp_scheduler
import cp_server
import cp_worker

# The fixed tick cadence: one wake per minute. cron resolution is per-minute (§6),
# so a per-minute tick fires every schedule on the minute it becomes due, no finer.
TICK_INTERVAL_SECONDS = 60.0

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
    return fired


def _tick_loop(stop_event, *, home, base_env, interval, on_tick):
    """The tick thread body: wake every `interval` seconds and run_tick() for the
    registered owners. A tick that raises is reported to stderr and swallowed (a single
    bad schedule must not kill the clock); the loop continues. Stops promptly when
    `stop_event` is set — stop_event.wait(interval) returns True the instant a shutdown
    is signalled, so the thread does not block a clean process exit for up to a minute."""
    while not stop_event.wait(interval):
        try:
            fired = run_tick(home=home, base_env=base_env)
        except Exception as exc:  # noqa: BLE001 — the clock must survive a bad tick.
            sys.stderr.write("cp_boot: tick error: %s\n" % type(exc).__name__)
            continue
        if on_tick is not None and fired:
            try:
                on_tick(fired)
            except Exception as exc:  # noqa: BLE001 — observer fault never stops clock.
                sys.stderr.write("cp_boot: on_tick error: %s\n" % type(exc).__name__)


def start_tick_thread(*, home=None, base_env=None,
                      interval=TICK_INTERVAL_SECONDS, on_tick=None):
    """Start the per-minute scheduler tick daemon (at most one per process). Returns
    (thread, stop_event) on a fresh start, or (None, None) if a tick thread already
    runs in this process (the singleton guard — a double-boot does not spawn two
    clocks). The thread is a daemon so it never blocks interpreter shutdown; pass the
    returned stop_event to stop it cleanly."""
    global _TICK_STARTED
    with _TICK_LOCK:
        if _TICK_STARTED:
            return None, None
        stop_event = threading.Event()
        thread = threading.Thread(
            target=_tick_loop,
            kwargs={"stop_event": stop_event, "home": home, "base_env": base_env,
                    "interval": interval, "on_tick": on_tick},
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
    routes["dashboard"] = [cp_dashboard.register(home=home)]
    routes["schedules"] = list(cp_scheduler.register_routes())
    routes["jobs"] = list(cp_worker.register_job_routes(home=home, base_env=base_env))
    routes["approvals"] = list(cp_approval.register(home=home))
    routes["notifications"] = [cp_notify.register_notify_routes(server.register_route)]
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
