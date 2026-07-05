#!/usr/bin/env python3
# cp_daily_budget.py — the PER-TEAM DAILY SPEND CEILING for the cloud maintainer.
#
# WHY THIS EXISTS (prod-readiness audit item #2, 2026-07-06). The gated maintainer drain
# dispatches a team's queued cycles through the authz/mint chokepoint. Before this module the
# ONLY throttle on that path was the fixed-window DISPATCH-RATE cap (cp_ratelimit, INV-7: ~30
# dispatches/min/team) plus the per-dispatch token cap (~600k). Neither is a DAILY ceiling, so
# a single team's worst-case burn was ~30 dispatch/min × 600k tokens × a full day ≈ $78k–389k/
# day/team, and the only backstop was the LAGGING $10k GCP billing kill-switch (it trips AFTER
# the spend, fleet-wide, not per-team). This module adds the missing PROACTIVE per-team daily
# ceiling: a durable counter of (dispatches, tokens) consumed per team per UTC day, checked at
# dispatch time — the same chokepoint that mints the token — so a runaway team is capped BEFORE
# the spend, per-team, without waiting for the billing backstop.
#
# THE COUNTER (fixed UTC-day window, on the StateBackend seam — the cp_ratelimit discipline).
# It reuses cp_ratelimit's exact storage discipline verbatim, only the window is a UTC DAY and
# the increment is an ARBITRARY amount (a dispatch reserves `tokens`, not one unit):
#
#   • The window is the UTC calendar day: day = floor(now / 86400). Unix time has NO leap
#     seconds, so epoch 0 == 1970-01-01T00:00:00Z and every multiple of 86400 is EXACTLY UTC
#     midnight — floor(now/86400) therefore rolls over at UTC midnight FOR FREE, and yesterday's
#     bucket is simply never read again (self-expiring by key, no sweeper), exactly like a
#     cp_ratelimit fixed-window bucket. On Firestore the doc additionally carries a top-level
#     `ttl_at` (team_daily is a TTL-eligible root, cp_state_firestore._TTL_ELIGIBLE_ROOTS), so a
#     stale day-bucket is auto-reaped like a ratelimit bucket.
#
#   • Two counters per (team, day): the dispatch COUNT and the token SPEND, each ONE keyed JSON
#     record {"count": N} at "team_daily/<kind>/<team-hash>/<day>.json". One get_record + (on an
#     allowed dispatch) one put_record per kind — O(1), never read_lines a growing log, and
#     NEVER backend.path() (path() RAISES under Firestore; every op is get/put — DATA ONLY).
#
#   • check_and_consume(team, tokens, dispatch_max, token_budget) is the ATOMIC-ish gate: it
#     reads both counters, REFUSES (consuming NOTHING) if this dispatch would push EITHER over
#     its cap, else CONSUMES one dispatch + `tokens` and allows. A refused dispatch does not
#     burn budget — the caller defers it (requeue, no attempt burn) so it retries after the UTC
#     rollover. `tokens` is the dispatch's RESERVATION (its budget_tokens cap, ≤600k), not its
#     eventual actual spend, so the ceiling is enforced up-front (a reservation model — the
#     per-dispatch token cap is the ceiling on any single reservation).
#
# NEVER STORE THE RAW TEAM ID AS-IS (uniform, filesystem-safe path). The team_id is already a
# non-secret 32-hex derived id (never the team secret), but it is sha256-hashed to a hex prefix
# before it becomes a path segment — identical to cp_ratelimit._key_hash — so the layout is
# uniform + bounded + filesystem-safe + Firestore-flat-safe regardless of the id's shape.
#
# FAIL-OPEN (documented + bounded — the cp_ratelimit decision, and WHY it is right HERE too). On
# ANY backend error the check FAILS OPEN (ok=True): blocking a legit team's whole cycle on a
# transient Firestore hiccup is worse than a briefly-unenforced daily ceiling, because (a) this
# is a COST cap, not the security gate (the §3 PKI chokepoint + the per-team mint are the real
# boundaries and are unaffected by a store outage), (b) the per-dispatch 600k token cap still
# bounds any SINGLE dispatch during the outage, and (c) the GCP billing budget — dropped to $1k
# as part of this same audit item — is the HARD backstop that Google enforces server-side and
# that CANNOT itself fail open. A fail-open emits ONE loud stderr line so an unenforced window
# is visible in the logs. A zero/negative cap is NOT a backend error — it is an explicit hard-
# closed gate (a kill switch) and refuses, it does NOT fail open.
#
# stdlib-only (hashlib/os/sys) + cp_state (the persistence seam) — the SAME dependency shape
# cp_ratelimit and every CP store has, no third-party dep, self-hostable.

from __future__ import annotations

import hashlib
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_state  # the pluggable persistence backend — one keyed JSON counter record per
                 # (kind, team-hash, UTC-day), put/get THROUGH a StateBackend so the same
                 # atomic put / tolerant get becomes Firestore-durable (shared across instances)
                 # on Cloud Run WITHOUT changing this module (byte-identical on local).

# ── store layout (a keyed counter record per (kind, team-hash, UTC-day)) ──
#
# Every rel is RELATIVE to ${HEIMDALL_HOME}/control-plane/ (the StateBackend namespace): the
# root is "team_daily/", one kind's dir is "team_daily/<kind>/", one team's dir is
# "team_daily/<kind>/<team-hash>/", and one day bucket is
# "team_daily/<kind>/<team-hash>/<day>.json". The backend owns the home root + makedirs + the
# byte shape; this module NEVER opens a file directly and NEVER calls backend.path().
_ROOT_REL = "team_daily"

# The two counter KINDS: the dispatch COUNT and the token SPEND (independent daily ceilings —
# defense in depth: many small dispatches are bounded by the count cap, few large ones by the
# token cap).
_KIND_DISPATCH = "dispatch"
_KIND_TOKENS = "tokens"

# The keyed-record suffix (one .json per day bucket, like a cp_ratelimit bucket record).
_RECORD_SUFFIX = ".json"

# The count field of a bucket record — the CLOSED schema {"count": <int>}. No team/secret
# material is ever stored, only the integer (dispatch count or token spend).
_FIELD_COUNT = "count"

# The UTC day length in seconds. Unix time carries no leap seconds, so a multiple of this is
# EXACTLY UTC midnight and floor(now / _DAY_SECONDS) is the UTC calendar-day ordinal.
_DAY_SECONDS = 86400

# The hex width of the team-id hash used as a path segment (parity with cp_ratelimit._KEY_HASH_HEX).
_TEAM_HASH_HEX = 32


def _utc_day(now):
    """The UTC calendar-day ordinal for `now`: floor(now / 86400). Rolls over at UTC midnight
    (epoch 0 == UTC midnight, no leap seconds). A non-numeric `now` is treated as day 0 (a
    degenerate but stable bucket — the caller always passes epoch seconds)."""
    if not isinstance(now, (int, float)):
        return 0
    return int(now // _DAY_SECONDS)


def _seconds_to_rollover(now):
    """Integer seconds until the current UTC day ends (when the daily budget refreshes). Used as
    the refused decision's `retry_after`. Always >= 1 so a caller never busy-loops on 0."""
    if not isinstance(now, (int, float)):
        return _DAY_SECONDS
    remaining = _DAY_SECONDS - (now - (_utc_day(now) * _DAY_SECONDS))
    return max(1, int(remaining) + (1 if remaining != int(remaining) else 0))


def _team_hash(team_id):
    """sha256-hash a team_id to a hex prefix used as a path segment — identical discipline to
    cp_ratelimit._key_hash. The team_id is a non-secret derived id, but hashing keeps the path
    uniform + bounded + filesystem-safe + Firestore-flat-safe for any id shape. An empty/None id
    hashes the empty string to a stable bucket (an unattributed check still counts, never
    escapes its segment)."""
    raw = str(team_id or "").encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:_TEAM_HASH_HEX]


class BudgetDecision:
    """The outcome of a daily-budget check. `ok` is whether the dispatch is within BOTH daily
    ceilings (and, when ok, was consumed); `limit_dim` names which ceiling was hit on a refusal
    ("dispatch" | "tokens", None when ok); `dispatches` / `tokens` are the team's day-to-date
    totals AFTER this decision (post-consume on ok, unchanged on a refusal); `dispatch_max` /
    `token_budget` echo the active caps; `retry_after` is seconds to UTC rollover (0 when ok);
    `failed_open` records that a backend error forced a fail-open allow (so the caller can log
    the unenforced window). Token-free by construction — carries only integers + the dimension."""

    __slots__ = ("ok", "limit_dim", "dispatches", "tokens",
                 "dispatch_max", "token_budget", "retry_after", "failed_open")

    def __init__(self, ok, *, limit_dim=None, dispatches=0, tokens=0,
                 dispatch_max=0, token_budget=0, retry_after=0, failed_open=False):
        self.ok = bool(ok)
        self.limit_dim = limit_dim
        self.dispatches = int(dispatches)
        self.tokens = int(tokens)
        self.dispatch_max = int(dispatch_max)
        self.token_budget = int(token_budget)
        self.retry_after = int(retry_after)
        self.failed_open = bool(failed_open)

    def as_dict(self):
        return {"ok": self.ok, "limit_dim": self.limit_dim,
                "dispatches": self.dispatches, "tokens": self.tokens,
                "dispatch_max": self.dispatch_max, "token_budget": self.token_budget,
                "retry_after": self.retry_after, "failed_open": self.failed_open}


class DailyTeamBudget:
    """The per-team DAILY spend ceiling. Construct with a `home` (pinning the store root, exactly
    as every CP accessor threads `home=` through) or an explicit `backend` (a StateBackend); by
    default it resolves the backend from HEIMDALL_STATE_BACKEND via cp_state.get_backend, so the
    SAME counter is Firestore-durable on Cloud Run (one shared counter across instances) and
    byte-identical local in dev/test.

    Two fixed UTC-day counters per team ({"count": N} per (kind, team-hash, day)). One get_record
    per kind on a check + one put_record per kind on an allowed consume. FAIL-OPEN on any backend
    error (a COST cap must not lock out a legit team on a transient store hiccup — the billing
    budget is the hard backstop). NEVER backend.path() — every op is get/put (DATA only)."""

    def __init__(self, home=None, *, backend=None):
        # Reuse the StateBackend seam exactly as cp_ratelimit does: an injected `backend` (a test
        # double / pre-built handle) wins; otherwise resolve from the env. `home` threads straight
        # through, no re-derivation.
        self._backend = backend if backend is not None else cp_state.get_backend(home=home)

    def _rel(self, kind, team_id, day):
        """The store-relative path of one (kind, team, day) counter record:
        team_daily/<kind>/<team-hash>/<day>.json. The team_id is HASHED into its segment."""
        return os.path.join(
            _ROOT_REL, kind, _team_hash(team_id), "%d%s" % (day, _RECORD_SUFFIX))

    def _read_count(self, rel):
        """Read one counter record's integer count (0 for an absent/corrupt/negative record).
        Tolerant — the get_record contract returns None on a miss/error, an absent counter reads
        as 0 (the day started fresh)."""
        record = self._backend.get_record(rel)
        if isinstance(record, dict):
            raw = record.get(_FIELD_COUNT)
            if isinstance(raw, int) and raw >= 0:
                return raw
        return 0

    def usage(self, team_id, *, now=None):
        """READ-ONLY: (dispatches, tokens) the team has consumed in the CURRENT UTC day. For a
        status/dashboard read. On a backend error each dimension reads as 0 (tolerant)."""
        when = now if now is not None else _now()
        day = _utc_day(when)
        try:
            return (self._read_count(self._rel(_KIND_DISPATCH, team_id, day)),
                    self._read_count(self._rel(_KIND_TOKENS, team_id, day)))
        except Exception:  # noqa: BLE001 — a read must never raise; report an honest zero.
            return (0, 0)

    def _log_fail_open(self, exc):
        """Emit ONE loud, token-free stderr line naming a fail-open window (a backend error left
        the daily ceiling unenforced for this call). Guarded so a logging error can NEVER defeat
        the caller's fail-open return; logs only the exception TYPE, never the team_id."""
        try:
            sys.stderr.write(
                "cp_daily_budget: FAIL-OPEN daily spend cap on backend error (type=%s) — "
                "daily ceiling not enforced this call; $1k billing budget is the backstop\n"
                % type(exc).__name__)
            sys.stderr.flush()
        except Exception:  # noqa: BLE001 — diagnostic only; must not raise into the fail-open.
            return

    def check_and_consume(self, team_id, *, tokens, dispatch_max, token_budget, now=None):
        """The daily-ceiling gate. Reads the team's day-to-date (dispatches, tokens) and:

          • REFUSES (BudgetDecision.ok=False) — consuming NOTHING — if this dispatch would push
            EITHER ceiling over its cap: the dispatch count is already at `dispatch_max`, OR the
            token spend + this dispatch's `tokens` reservation would exceed `token_budget`. The
            dispatch count is checked first, so `limit_dim` names the FIRST ceiling hit.
          • else CONSUMES one dispatch + `tokens` (one put_record per kind) and ALLOWS
            (ok=True), returning the post-consume totals.

        `tokens` is this dispatch's token RESERVATION (its budget_tokens cap); it is clamped to
        >= 0. `now` is injectable epoch seconds (defaults to time.time()) for deterministic tests
        — it selects the UTC-day bucket, so a fake clock past midnight sees a fresh (0,0) day.

        FAIL-OPEN: on ANY backend error the gate returns ok=True (failed_open=True) — a cost cap
        must not lock out a legit team on a transient store hiccup; the billing budget is the hard
        backstop. A zero/negative cap is NOT a backend error: it is an explicit hard-closed gate
        and REFUSES (it does not fail open)."""
        when = now if now is not None else _now()
        day = _utc_day(when)
        reserve = int(tokens) if isinstance(tokens, (int, float)) and tokens > 0 else 0
        dmax = int(dispatch_max) if isinstance(dispatch_max, (int, float)) else 0
        tbudget = int(token_budget) if isinstance(token_budget, (int, float)) else 0
        try:
            disp_rel = self._rel(_KIND_DISPATCH, team_id, day)
            tok_rel = self._rel(_KIND_TOKENS, team_id, day)
            dispatches = self._read_count(disp_rel)
            spent = self._read_count(tok_rel)

            # Ceiling checks — REFUSE WITHOUT consuming if either would be exceeded. A zero/
            # negative cap makes the corresponding check always refuse (an explicit kill switch).
            if dispatches >= dmax:
                return BudgetDecision(
                    False, limit_dim=_KIND_DISPATCH, dispatches=dispatches, tokens=spent,
                    dispatch_max=dmax, token_budget=tbudget,
                    retry_after=_seconds_to_rollover(when))
            if spent + reserve > tbudget:
                return BudgetDecision(
                    False, limit_dim=_KIND_TOKENS, dispatches=dispatches, tokens=spent,
                    dispatch_max=dmax, token_budget=tbudget,
                    retry_after=_seconds_to_rollover(when))

            # Within BOTH ceilings: consume one dispatch + this dispatch's token reservation.
            self._backend.put_record(disp_rel, {_FIELD_COUNT: dispatches + 1})
            self._backend.put_record(tok_rel, {_FIELD_COUNT: spent + reserve})
            return BudgetDecision(
                True, dispatches=dispatches + 1, tokens=spent + reserve,
                dispatch_max=dmax, token_budget=tbudget)
        except Exception as exc:  # noqa: BLE001 — FAIL-OPEN: a backend error never refuses.
            self._log_fail_open(exc)
            return BudgetDecision(True, dispatch_max=dmax, token_budget=tbudget,
                                  failed_open=True)


def _now():
    """Wall-clock epoch seconds. Wrapped so a test can monkeypatch one symbol; the public API
    also accepts an explicit `now` for fully deterministic checks (the preferred test path)."""
    import time
    return time.time()
