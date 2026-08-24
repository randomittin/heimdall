#!/usr/bin/env python3
"""pressure_control.py — the AIMD ENGINE behind bin/heimdall-pressure and the
pressure-aware ceiling in bin/agent-pool.

THE ASK this exists for (repo owner, verbatim): "you'd also need to create a
capability to control the 529 overloaded bit." hmd spawns up to 10 parallel
agents by policy (agent-pool DEFAULTS["max_agents"]) and pushes hard toward
maximum parallelism (agents/heimdall.md). When the API is capacity-pressured,
hmd is contributing ten simultaneous request streams to the thing that is
overloaded, then treating the resulting 529 as bad luck. This module is the
feedback loop that closes: observed pressure -> reduced spawn recommendation
-> recovery once pressure clears.

THE HONEST LIMIT (read this before calling anything here a "circuit breaker"):
hmd cannot see the harness's HTTP responses. It learns about a 529/
overloaded_error or a connection reset ONLY from an agent's own death/report
message, relayed by whatever calls record_event() (a caller — e.g.
bin/session-fork noticing a give-up exit, or an orchestrator hook — must
notice the failure and call in; nothing here intercepts a live request). This
module is therefore a FEEDBACK CONTROLLER ON SPAWN DECISIONS, informed by
recent observed failures — never an interceptor of a request in flight. It
cannot stop a request already sent, and it cannot see a 529 no caller reported.

WHY A MULTIPLIER, NOT AN ABSOLUTE CAP. State stores a `factor` in (0, 1]
rather than an absolute agent count, so it is CEILING-AGNOSTIC: recommend()
always computes effective = ceiling * factor at read time, so the answer
stays correct even if the operator's configured max_agents changes (e.g.
`agent-pool init --max N` again) between pressure events. Absolute-count
state would drift out of sync with a policy change between the write and the
read; a dimensionless multiplier never can, and record_event() never needs to
know the caller's ceiling just to log a failure.

AIMD SHAPE (Additive-Increase/Multiplicative-Decrease — the standard,
well-understood congestion-control shape; this is TCP's own algorithm,
retargeted from "how many packets may be in flight" to "how many Claude Code
agents may run at once"):
  * MULTIPLICATIVE DECREASE on a pressure BURST (>= threshold() events within
    window_secs()): factor *= decrease_factor() (0.5 — halving). Fast
    collapse, because congestion is expensive and getting off it quickly
    matters more than optimizing the exact new ceiling.
  * ADDITIVE INCREASE once no NEW pressure has landed: factor +=
    recovery_step() per recovery_secs() elapsed, capped at 1.0. Slow, linear
    climb — cautious re-expansion, so agents don't all leap back to full
    concurrency the instant the API goes quiet for a moment.
  * A fresh breach RESETS the observation window to just the triggering
    event. Without this, the very next unrelated event would immediately
    re-breach (the window was already at/over threshold) and needlessly
    re-halve on top of noise right after a legitimate reaction. Sustained
    pressure still compounds correctly: each additional threshold's worth of
    events after the reset triggers its own multiplicative decrease.

THE THRESHOLD, STATED (not hidden): a single pressure event is noise — one
request can fail for reasons that have nothing to do with sustained capacity
pressure (a mid-flight network blip, one slow route). Real capacity pressure
is CORRELATED: when the API is genuinely overloaded, multiple concurrently
running agents tend to see it within moments of each other, because they are
all hitting the same backend at the same time. threshold()=3 observed
pressure events inside a 3-minute window is the floor before this module
reshapes pool-wide behavior. This is a SMALLER floor than the 20-observation
floor bin/heimdall-dream enforces before trusting a routing pass-rate delta
(bin/lib/holdout.py-adjacent MIN_SAMPLES_FLOOR) — deliberately: a hard
failure report is a much lower-noise signal than a sampled proportion, so it
does not need the same sample size to be trustworthy. Different statistical
problem, different floor, both stated rather than copied blindly.

FAIL OPEN, ALWAYS. load_state() and recommend() degrade to "no pressure
known" on any error — missing state file, corrupt JSON, unwritable home
directory, a negative or non-numeric field. This module must never be the
reason a spawn decision breaks; the worst it may do is under-inform, never
mis-fail closed. record_event() is the one function that DOES raise on a bad
`kind` — by design, so the CLI layer can choose strict/non-strict handling
per bin/heimdall-metric's own --strict convention, rather than this engine
silently deciding for every caller.
"""
import contextlib
import fcntl
import json
import os
import random
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 1

PRESSURE_KINDS = ("overloaded_error", "connection_reset")

MAX_WINDOW_EVENTS = 200  # defensive bound on stored timestamps; not a policy knob.


# ── tunables (env-overridable; see module docstring for the AIMD justification) ─

def _env_float(name, default):
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return float(raw)
    except (TypeError, ValueError):
        return default


def _env_int(name, default):
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return int(float(raw))
    except (TypeError, ValueError):
        return default


def window_secs():
    return max(1, _env_int("HMD_PRESSURE_WINDOW_SECS", 180))


def threshold():
    return max(1, _env_int("HMD_PRESSURE_THRESHOLD", 3))


def decrease_factor():
    v = _env_float("HMD_PRESSURE_DECREASE_FACTOR", 0.5)
    return v if 0.0 < v < 1.0 else 0.5


def min_factor():
    v = _env_float("HMD_PRESSURE_MIN_FACTOR", 0.1)
    return v if 0.0 < v <= 1.0 else 0.1


def recovery_step():
    v = _env_float("HMD_PRESSURE_RECOVERY_STEP", 0.2)
    return v if v > 0.0 else 0.2


def recovery_secs():
    return max(1, _env_int("HMD_PRESSURE_RECOVERY_SECS", 120))


def min_cap():
    return max(1, _env_int("HMD_PRESSURE_MIN_CAP", 1))


# ── state file resolution (mirrors bin/agent-pool's _resolve_pool_file) ────────

def resolve_state_file():
    """~/.heimdall/pressure-state.json, adopting a pre-existing ~/.superx
    sibling for back-compat — exactly agent-pool's own POOL_FILE resolution,
    so the two always live side by side regardless of HOME override in
    tests."""
    new = Path.home() / ".heimdall" / "pressure-state.json"
    legacy = Path.home() / ".superx" / "pressure-state.json"
    if not new.exists() and legacy.exists():
        return legacy
    return new


def _now():
    return datetime.now(timezone.utc)


def _parse_ts(raw):
    """Parse an ISO timestamp; None on anything unparseable (fail open)."""
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw)
    except (TypeError, ValueError):
        return None


def _iso(dt):
    return dt.isoformat()


# ── state I/O ────────────────────────────────────────────────────────────────
# Reads are LOCKLESS by design — recommend() sits on bin/agent-pool's hot spawn
# path and "do not add latency to the spawn path" rules out taking a flock on
# every acquire. The atomic tmp-then-rename write below (same pattern as
# bin/agent-pool's save_pool) already guarantees a reader never observes a
# half-written file, so a lockless read is safe. Only the WRITE path
# (record_event/reset_state) takes the lock, exactly mirroring agent-pool's
# own @locked decorator scope (held for the duration of one command).

def load_state():
    """The cached AIMD state, or None on ANY problem (absent, corrupt, wrong
    shape) — the fail-open seam every caller relies on."""
    path = resolve_state_file()
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    return data


def _save_state_unlocked(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    tmp.rename(path)


def _with_lock(fn):
    path = resolve_state_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_suffix(".lock")
    with open(lock_path, "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            return fn(path)
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def reset_state():
    """Idempotent: removing an already-absent state file is not an error."""
    def _do(path):
        with contextlib.suppress(FileNotFoundError):
            path.unlink()
        return True
    return _with_lock(_do)


# ── the controller ───────────────────────────────────────────────────────────

def _prune_window(events, now):
    cutoff = now.timestamp() - window_secs()
    kept = []
    for ts in events:
        dt = _parse_ts(ts)
        if dt is not None and dt.timestamp() >= cutoff:
            kept.append(ts)
    return kept[-MAX_WINDOW_EVENTS:]


def _recovered_factor(state, now):
    """The CURRENT factor after applying elapsed-time additive recovery to
    the last STORED factor — pure, no I/O. Shared by the read path
    (recommend) and the write path (record_event, so a new breach compounds
    on top of whatever has already recovered rather than an over-stale
    number)."""
    if not state:
        return 1.0
    factor = state.get("factor")
    if factor is None:
        return 1.0
    try:
        factor = float(factor)
    except (TypeError, ValueError):
        return 1.0
    if factor <= 0.0 or factor >= 1.0:
        return 1.0
    changed = _parse_ts(state.get("last_change_ts"))
    if changed is None:
        return factor
    elapsed = (now - changed).total_seconds()
    if elapsed <= 0:
        return factor
    steps = int(elapsed // recovery_secs())
    if steps <= 0:
        return factor
    return min(1.0, factor + steps * recovery_step())


def record_event(kind):
    """Record ONE observed pressure signal (a 529/overloaded_error or a
    connection reset, reported by a caller who noticed an agent die). Raises
    ValueError on an unrecognized kind — the CLI layer decides whether that
    is fatal (--strict) or swallowed, this function does not decide for it.

    Returns a small result dict: {kind, window_count, threshold, breached,
    factor}. Never scans the durable .planning/metrics.jsonl audit ledger —
    that ledger is write-only from this function's perspective (see
    bin/heimdall-pressure's own ledger append), which is what keeps this
    O(1) regardless of how much history has ever been recorded."""
    if kind not in PRESSURE_KINDS:
        raise ValueError(
            "kind must be one of %s, got %r" % ("|".join(PRESSURE_KINDS), kind)
        )

    now = _now()

    def _do(path):
        try:
            with open(path) as f:
                state = json.load(f)
            if not isinstance(state, dict):
                state = {}
        except (OSError, ValueError):
            state = {}

        events = _prune_window(state.get("window_events") or [], now)
        events.append(_iso(now))
        events = events[-MAX_WINDOW_EVENTS:]

        state["schema"] = SCHEMA_VERSION
        state["window_events"] = events
        state["last_kind"] = kind
        state["last_event_ts"] = _iso(now)
        state.setdefault("backoff_events_total", 0)

        breached = len(events) >= threshold()
        if breached:
            current = _recovered_factor(state, now)
            state["factor"] = max(min_factor(), current * decrease_factor())
            state["last_change_ts"] = _iso(now)
            state["backoff_events_total"] = int(state.get("backoff_events_total", 0)) + 1
            # A fresh backoff supersedes the events that caused it. See
            # module docstring "A fresh breach RESETS the observation
            # window" for why: otherwise the very next unrelated event
            # would immediately re-breach and needlessly re-halve on noise.
            state["window_events"] = [_iso(now)]

        _save_state_unlocked(path, state)
        return {
            "kind": kind,
            "window_count": len(events),
            "threshold": threshold(),
            "breached": breached,
            "factor": state.get("factor", 1.0),
        }

    return _with_lock(_do)


def recommend(ceiling, ceiling_default=10):
    """The read path. Pure: one lockless state-file read (or none), O(1)
    arithmetic, NO ledger scan, no write. Fails open to `ceiling` unchanged
    on absent/corrupt state — exactly what an operator who never turned this
    on would see.

    Returns (effective, reason_or_None, detail_dict). `effective` is always
    in [min_cap(), ceiling] whenever ceiling >= min_cap() and pressure is
    known and reducing; it is exactly `ceiling` whenever no pressure is
    known or full recovery has occurred — this function NEVER recommends
    more than the operator configured."""
    try:
        ceiling = int(ceiling)
    except (TypeError, ValueError):
        ceiling = int(ceiling_default)
    if ceiling <= 0:
        return ceiling, None, {"pressure_known": False}

    try:
        state = load_state()
        if not state:
            return ceiling, None, {"pressure_known": False}

        now = _now()
        factor = _recovered_factor(state, now)

        if factor >= 1.0:
            return ceiling, None, {"pressure_known": True, "factor": 1.0}

        detail = {
            "pressure_known": True,
            "factor": round(factor, 3),
            "window_count": len(state.get("window_events") or []),
            "threshold": threshold(),
            "last_kind": state.get("last_kind"),
            "last_event_ts": state.get("last_event_ts"),
            "backoff_events_total": state.get("backoff_events_total", 0),
        }
        effective = max(min_cap(), min(ceiling, int(ceiling * factor)))
        if effective >= ceiling:
            return ceiling, None, detail
        reason = (
            "pressure backoff active: factor=%.2f after %s event(s) observed "
            "(last: %s); recovers +%.2f every %ds"
            % (factor, detail["window_count"], detail["last_kind"] or "?",
               recovery_step(), recovery_secs())
        )
        return effective, reason, detail
    except Exception:
        # Belt-and-suspenders: ANY unexpected error here degrades to the
        # operator's configured ceiling, never to a crash or a refusal.
        return ceiling, None, {"pressure_known": False}


def retry_delay(attempt, base=1.0, cap=60.0, rng=None):
    """Exponential backoff with FULL JITTER for attempt N (1-based). Pure —
    never sleeps, just returns the number of seconds the caller should wait.

    Full jitter (delay = uniform(0, min(cap, base * 2**(attempt-1)))) rather
    than no jitter or "equal jitter": with N callers retrying on the same
    tick — exactly hmd's own situation, up to 10 agents can all hit a 529
    within the same second — an un-jittered or half-jittered backoff still
    leaves them correlated; full jitter decorrelates completely, at the cost
    of some retries firing sooner than the "ideal" exponential curve, which
    is the right trade when the failure mode being defended against IS
    correlation (a thundering herd retrying in lockstep makes overload
    worse, not better).

    This is intentionally decoupled from the AIMD state above: it is a
    general-purpose backoff primitive for the "transient case" (item 4 of
    the ask), usable on its own. A caller that wants pressure-SCALED backoff
    can compose it with recommend()'s factor itself (e.g. divide base by the
    current factor) — that composition is left to the caller rather than
    hidden in here, so this function's contract stays simple and reusable."""
    try:
        attempt = max(1, int(attempt))
    except (TypeError, ValueError):
        attempt = 1
    try:
        base = float(base)
    except (TypeError, ValueError):
        base = 1.0
    try:
        cap = float(cap)
    except (TypeError, ValueError):
        cap = 60.0
    base = max(0.0, base)
    cap = max(base, cap)
    shift = min(attempt - 1, 20)  # avoid absurd overflow at high attempt counts
    ideal = min(cap, base * (2 ** shift))
    draw = rng if rng is not None else random.random
    return round(draw() * ideal, 3)
