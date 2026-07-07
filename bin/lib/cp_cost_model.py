#!/usr/bin/env python3
# cp_cost_model.py — THE UNIT-COST MODEL as executable arithmetic (cost-governance §1).
#
# WHY THIS EXISTS. docs/analysis/launch-cost-model.md is the human unit-cost model: at the
# published GCP us-central1 list rates, Heimdall's $10k/mo budget buys ONLY orchestration
# (Firestore ops + Cloud Run request handling — Heimdall NEVER pays for inference, it is BYO
# everywhere), and the dominant knob is the beat/refresh cadence. A doc drifts from reality;
# a SCRIPT does not. This module turns that doc into configurable arithmetic so:
#   • the WEEKLY job (bin/heimdall-cost-model-refresh) recomputes the projected spend from the
#     current rates + cadence and re-validates the model's constants against reality;
#   • the DAILY job (bin/heimdall-cost-report) turns yesterday's ACTUAL billing (or op counts)
#     into {$/day, $/DAU, projected month, % of budget} — and that %-of-budget is the SPEND-PACE
#     the adaptive-interval ladder (cp_config §2) consumes to self-heal the burn.
#
# THE ARITHMETIC (all rates cited to launch-cost-model.md §0, published GCP list prices,
# labeled [rate] — NOT a secret, NOT read from any credentialed source; a self-host deploy can
# override every one via the env or a rates dict):
#   • Firestore Native regional: reads $0.03/100k, writes $0.09/100k (free tier 50k/20k per day).
#   • Cloud Run request-billed (the public surface): requests $0.40/M, vCPU $0.000024/vCPU-s,
#     mem $0.0000025/GiB-s — a request costs the flat per-request fee + (duration × vCPU+mem).
#   • The always-on FLOOR: the gated instance is min-instances=1 --no-cpu-throttling ->
#     instance-billed 24/7 ≈ $50/mo (launch-cost-model.md §1). It is a fixed monthly floor,
#     independent of load, so it is ADDED to the projected month, not scaled by traffic.
#   • Month = 30 days for the daily->month projection (conservative vs the 30.4 mean; a deploy
#     can override). Budget = $10,000/mo (HEIMDALL_MONTHLY_BUDGET_USD).
#
# THE TWO ENTRY POINTS:
#   • project_from_counts(reads, writes, requests, ...) -> a modeled $/day from op counts (the
#     path when the BigQuery billing export is not yet enabled, or for the weekly what-if model).
#   • report(daily_usd, dau, budget, ...) -> {daily_usd, per_dau_usd, projected_month_usd,
#     pct_of_budget} — the daily job's output; pct_of_budget is the ladder's spend-pace input.
#   • model_from_concurrency(...) -> the launch-cost-model.md §4 virality table as code (a
#     what-if the weekly job prints so the doc's constants can be re-validated against reality).
#
# PURE — no IO, no store, no credential, no model API. Every number is arithmetic over inputs +
# published rates. stdlib-only (os for the env-overridable rates). The §0 invariant holds by
# construction: this module constructs NO model-API client and touches NO inference path.

from __future__ import annotations

import os

# ── the published GCP list rates (launch-cost-model.md §0 — [rate], env-overridable) ──────
#
# Every rate is a published us-central1 list price, NOT a secret and NOT read from a credentialed
# source. A self-host deploy on a different region / negotiated rate overrides any of them via the
# env (HEIMDALL_RATE_*) or by passing a `rates` dict to any function. The defaults reproduce the
# doc's headline figures exactly, so the script and the doc agree until a rate is deliberately
# changed (which is the whole point — the weekly job re-validates the doc against these).
_DEFAULT_RATES = {
    # Firestore Native, regional us-central1.
    "firestore_read_per_op":  0.03 / 100_000,   # $0.03 / 100k reads.
    "firestore_write_per_op": 0.09 / 100_000,   # $0.09 / 100k writes.
    # Cloud Run request-billed (the public surface: --cpu-throttling, scale-to-zero).
    "cloudrun_request_per_op": 0.40 / 1_000_000,  # $0.40 / 1M requests.
    "cloudrun_vcpu_per_s":     0.000024,          # $/vCPU-s (throttled rate).
    "cloudrun_mem_per_gib_s":  0.0000025,         # $/GiB-s (throttled rate).
}

# The always-on operator floor (the gated min-instances=1 --no-cpu-throttling instance, billed
# 24/7) — a FIXED monthly cost independent of traffic (launch-cost-model.md §1 ≈ $50/mo). Added
# to the projected month, never scaled by load. Env-overridable for a different gated shape.
_FLOOR_MONTHLY_ENV = "HEIMDALL_FIXED_FLOOR_USD"
_FLOOR_MONTHLY_DEFAULT = 50.0

# The monthly budget the spend-pace is a percentage OF (the $10k cap; env-overridable so RJ can
# align the knob to the real budget object without a code change — spec §4/§5).
_BUDGET_ENV = "HEIMDALL_MONTHLY_BUDGET_USD"
_BUDGET_DEFAULT = 10_000.0

# Days/month for the daily->month projection (conservative 30 vs the 30.4 mean). Env-overridable.
_DAYS_PER_MONTH_ENV = "HEIMDALL_DAYS_PER_MONTH"
_DAYS_PER_MONTH_DEFAULT = 30.0

# The default per-request Cloud Run duration (seconds) + the public surface's memory (GiB) — the
# launch-cost-model.md §4 assumptions (50 ms/request, 512Mi). Used when a caller models from op
# counts without measuring the per-request duration. Env-overridable.
_DEFAULT_REQUEST_SECONDS = 0.05
_DEFAULT_MEM_GIB = 0.5


def _env_float(name):
    """A float from env var `name`, or None when unset/malformed (a bad override never raises —
    the caller falls back to its published default)."""
    raw = os.environ.get(name)
    if raw is None:
        return None
    try:
        return float(raw)
    except (TypeError, ValueError):
        return None


def _rate(rates, name):
    """One rate: an explicit `rates` dict entry wins, else HEIMDALL_RATE_<NAME> from the env,
    else the published default. Lets a self-host deploy override any single rate without a code
    change while the defaults reproduce the doc. A malformed env value falls back to the default."""
    if isinstance(rates, dict) and name in rates:
        return float(rates[name])
    env_val = _env_float("HEIMDALL_RATE_" + name.upper())
    if env_val is not None:
        return env_val
    return _DEFAULT_RATES[name]


def monthly_budget_usd():
    """The monthly budget the spend-pace is a percentage of (HEIMDALL_MONTHLY_BUDGET_USD, default
    $10,000). A malformed/non-positive value falls back to the default (a zero budget would make
    every pace infinite — a misconfig must not do that)."""
    val = _env_float(_BUDGET_ENV)
    if val is None or val <= 0:
        return _BUDGET_DEFAULT
    return val


def fixed_floor_usd():
    """The always-on monthly floor (HEIMDALL_FIXED_FLOOR_USD, default $50 — the gated instance).
    A malformed/negative value falls back to the default."""
    val = _env_float(_FLOOR_MONTHLY_ENV)
    if val is None or val < 0:
        return _FLOOR_MONTHLY_DEFAULT
    return val


def days_per_month():
    """Days/month for the daily->month projection (HEIMDALL_DAYS_PER_MONTH, default 30)."""
    val = _env_float(_DAYS_PER_MONTH_ENV)
    if val is None or val <= 0:
        return _DAYS_PER_MONTH_DEFAULT
    return val


def _nonneg(value):
    """A non-negative float from a number, else 0.0 (a count/duration is never negative; a bad
    value degrades to 0 rather than poisoning the arithmetic). A bool is treated as 0."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        try:
            value = float(value)
        except (TypeError, ValueError):
            return 0.0
    return float(value) if value > 0 else 0.0


def firestore_cost(reads, writes, *, rates=None):
    """The Firestore op cost for `reads` + `writes` at the regional list rates. Conservative:
    the per-day free tier (50k reads / 20k writes) is NOT netted out (headline figures are
    stated without free-tier credit, launch-cost-model.md §0), so this is an upper bound. Pure."""
    r = _nonneg(reads) * _rate(rates, "firestore_read_per_op")
    w = _nonneg(writes) * _rate(rates, "firestore_write_per_op")
    return r + w


def cloudrun_cost(requests, *, request_seconds=_DEFAULT_REQUEST_SECONDS,
                  mem_gib=_DEFAULT_MEM_GIB, rates=None):
    """The Cloud Run request-billed cost for `requests` calls: the flat per-request fee plus the
    per-request compute (duration × (vCPU rate + mem rate × mem_gib)). Models the public surface
    (throttled, scale-to-zero). `request_seconds` is the mean handler duration (default 50 ms,
    the doc's assumption); `mem_gib` the instance memory (default 0.5 GiB). Pure."""
    n = _nonneg(requests)
    per_req_fee = _rate(rates, "cloudrun_request_per_op")
    secs = _nonneg(request_seconds)
    compute = secs * (_rate(rates, "cloudrun_vcpu_per_s")
                      + _rate(rates, "cloudrun_mem_per_gib_s") * _nonneg(mem_gib))
    return n * (per_req_fee + compute)


def project_from_counts(reads, writes, requests, *,
                        request_seconds=_DEFAULT_REQUEST_SECONDS,
                        mem_gib=_DEFAULT_MEM_GIB, rates=None):
    """A modeled infra $/day from YESTERDAY'S op counts (Firestore reads+writes + Cloud Run
    requests). This is the daily-variable spend; the fixed monthly floor is added separately in
    project_month_usd. Pure — the path when the BigQuery billing export is not (yet) enabled, and
    the what-if the weekly job runs. Returns a float ($/day)."""
    return (firestore_cost(reads, writes, rates=rates)
            + cloudrun_cost(requests, request_seconds=request_seconds,
                            mem_gib=mem_gib, rates=rates))


def project_month_usd(daily_usd, *, floor_usd=None, days=None):
    """Project a $/day into a $/month: daily × days/month + the fixed always-on floor. `floor_usd`
    defaults to fixed_floor_usd() (the gated instance); `days` to days_per_month(). The floor is
    ADDED once (it is a fixed monthly cost, not scaled by traffic). Pure."""
    floor = fixed_floor_usd() if floor_usd is None else _nonneg(floor_usd)
    d = days_per_month() if days is None else _nonneg(days)
    return _nonneg(daily_usd) * d + floor


def spend_pace_pct(projected_month_usd, *, budget_usd=None):
    """The SPEND-PACE: projected month as a PERCENTAGE of the monthly budget — the number the
    adaptive-interval ladder (cp_config) consumes to pick its tier. `budget_usd` defaults to
    monthly_budget_usd() ($10k). Rounded to 2dp. A zero/absent budget is guarded upstream
    (monthly_budget_usd never returns 0), so this never divides by zero. Pure."""
    budget = monthly_budget_usd() if budget_usd is None else budget_usd
    if not isinstance(budget, (int, float)) or budget <= 0:
        budget = _BUDGET_DEFAULT
    return round(_nonneg(projected_month_usd) / budget * 100.0, 2)


def report(daily_usd, *, dau=None, budget_usd=None, floor_usd=None, days=None):
    """THE daily cost-report output (spec §1): from yesterday's ACTUAL infra $/day (BigQuery
    billing export) produce {daily_usd, per_dau_usd, projected_month_usd, pct_of_budget}. The
    pct_of_budget is the spend-pace the ladder consumes. `dau` (yesterday's active devs) gives the
    $/DAU line (None -> None, no divide). Pure — the caller (bin/heimdall-cost-report) does the IO
    (read the billing $, set the ladder, alert the owner). Rounds money to 4dp."""
    daily = _nonneg(daily_usd)
    projected = project_month_usd(daily, floor_usd=floor_usd, days=days)
    pct = spend_pace_pct(projected, budget_usd=budget_usd)
    per_dau = None
    if isinstance(dau, (int, float)) and not isinstance(dau, bool) and dau > 0:
        per_dau = round(daily / float(dau), 6)
    return {
        "daily_usd": round(daily, 4),
        "per_dau_usd": per_dau,
        "projected_month_usd": round(projected, 2),
        "pct_of_budget": pct,
        "budget_usd": monthly_budget_usd() if budget_usd is None else float(budget_usd),
    }


def model_from_concurrency(concurrent, *, active_hours=8.0, beat_interval_s=20.0,
                           refresh_interval_s=15.0, roster_size=5, request_seconds=0.05,
                           rates=None):
    """The launch-cost-model.md §4 virality table AS CODE: for `concurrent` sessions each active
    `active_hours`/day, at a given beat/refresh cadence + roster size, model the infra $/day +
    projected month + spend-pace. This is the WHAT-IF the weekly job prints to re-validate the
    doc's constants against reality — and it makes the ladder's premise auditable (doubling the
    beat interval ~halves the burn). Per active session-hour: 3600/beat writes + 3600/refresh
    requests, each request reading `roster_size` roster docs. Pure; returns the full breakdown."""
    conc = _nonneg(concurrent)
    hours = _nonneg(active_hours)
    beat = beat_interval_s if beat_interval_s and beat_interval_s > 0 else 20.0
    refresh = refresh_interval_s if refresh_interval_s and refresh_interval_s > 0 else 15.0
    session_hours = conc * hours
    writes = session_hours * (3600.0 / beat)                 # 1 beat write / beat interval.
    requests = session_hours * (3600.0 / refresh)            # 1 roster read request / refresh.
    reads = requests * _nonneg(roster_size)                  # each roster request reads R docs.
    daily = project_from_counts(reads, writes, requests,
                                request_seconds=request_seconds, rates=rates)
    projected = project_month_usd(daily)
    return {
        "concurrent": int(conc),
        "active_hours": hours,
        "beat_interval_s": beat,
        "refresh_interval_s": refresh,
        "roster_size": int(_nonneg(roster_size)),
        "writes_per_day": int(writes),
        "reads_per_day": int(reads),
        "requests_per_day": int(requests),
        "daily_usd": round(daily, 4),
        "projected_month_usd": round(projected, 2),
        "pct_of_budget": spend_pace_pct(projected),
    }
