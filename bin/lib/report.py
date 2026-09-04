#!/usr/bin/env python3
# report.py — piece (d) of the Heimdall telemetry layer: the AGGREGATE query/view
# surface. This is the consumer that turns the recorded event store into the two
# answers the spec demands — per-run DETAIL and across-run TRENDS — so Heimdall can
# finally measure ITSELF from real events rather than assert.
#
# DESIGN DOSSIER §5 (authoritative; §1 is the schema we query). This module:
#
#   • READS the event store via the substrate (telemetry.read_events, piece a — we
#     BIND it, never re-derive the store path or re-parse the NDJSON). A streaming
#     line-scan: read events → group → reduce. Read-only — it NEVER writes an event.
#
#   • PER-RUN DETAIL (`run_detail`) — one run's timeline: its phases, the gates that
#     fired (passed/failed/blocked) with the file:line they fired at, the SUMMED
#     token spend (carrying the token event's cost_source provenance — never a
#     fabricated number), the atomic commits it produced, and the task outcome.
#
#   • AGGREGATE TRENDS (`aggregate`) across runs+installs:
#       - gate-firing FREQUENCY  — count by gate × outcome (which gates earn their
#         keep / which never fire).
#       - FAILURE patterns       — count by error.class × the step/gate it occurred
#         at; the top failing surfaces.
#       - TOKEN trends           — per-run total_tokens over time + the cache-read
#         ratio (cache_read / total), rolling — the spend curve.
#       - INSTALL drop-off       — per install step: failed/started ratio — the
#         top failing install surfaces across runs.
#
#   • HONESTY (§6, critical): any savings/cost figure is sourced ONLY from a token
#     event's MEASURED total_cost_usd carrying its cost_source provenance. This
#     module NEVER authors a "vs raw-CC" delta — that measured comparison is piece
#     (e)'s holdout job. A run with no token event shows tokens as None (the honest
#     "—"), NEVER a fabricated number. cost provenance travels with every cost.
#
#   • GRACEFUL (§8): an absent/empty store ⇒ read_events yields [] ⇒ every view
#     renders an honest "no data yet", never a crash. Disabled telemetry writes no
#     events ⇒ the same honest-empty report. Partial events are tolerated (a missing
#     field is simply absent from its bucket). stdlib-only — no third-party dep.
#
# This is a LIBRARY; the CLI core at the bottom is what bin/heimdall-report (bash)
# shells out to (house style: a thin bin/* CLI over a bin/lib/*.py engine, mirrors
# bin/heimdall-redum / bin/heimdall-holdout).

from __future__ import annotations

import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import telemetry  # piece (a), on main — the ONE event surface. BIND, never rebuild.

# The provenance tag a cost figure must carry to print as a measured fact (§6). We
# mirror the holdout vocabulary so the report and the holdout reporter agree on what
# "measured" means — a cost prints as fact only when its source tagged it measured.
COST_MEASURED = "measured"

# The em-dash the honest-empty / no-measurement slots render as (the same degrade
# glyph the summary-card renderer uses — honest absence, never a fabricated number).
DASH = "—"


# ── small reducers (pure; tolerant of partial events) ─────────────────────────


def _inc(counter, key):
    """Increment a count in a nested-or-flat counter dict. Skips a None key (a
    partial event missing the grouping field contributes to no bucket — tolerated,
    never crashes). Pure."""
    if key is None:
        return
    counter[key] = counter.get(key, 0) + 1


def _token_sum(tokens):
    """The total_tokens carried by a token event's `tokens` object, or None when the
    object is absent/partial (the honest "—" — never a fabricated 0). Pure."""
    if not isinstance(tokens, dict):
        return None
    tt = tokens.get("total_tokens")
    if isinstance(tt, (int, float)):
        return int(tt)
    return None


def _cache_ratio(tokens):
    """The cache-hit ratio (cache_read_tokens / total_tokens) for a token event, or
    None when it cannot be computed honestly (no total, or a zero/absent total — a
    ratio over zero is undefined, never faked). Pure."""
    if not isinstance(tokens, dict):
        return None
    total = tokens.get("total_tokens")
    cache = tokens.get("cache_read_tokens")
    if not isinstance(total, (int, float)) or total <= 0:
        return None
    if not isinstance(cache, (int, float)):
        return None
    return float(cache) / float(total)


# ── PER-RUN DETAIL (§5: one run's phases/gates/tokens/commits/outcome) ─────────


def run_detail(run_id, *, home=None, events=None):
    """Reduce ONE run's events to its detail view: an ordered timeline plus the
    summarized phases, gates (with the file:line each fired at), the SUMMED token
    spend (carrying cost_source provenance), the atomic commits, and the outcome.

    `events` lets a caller pass a pre-read list (avoids a second store scan); else
    we read this run's events from the substrate. Read-only; tolerant of partial
    events; never raises into the caller — an absent run yields the honest-empty
    detail (found=False), not a crash."""
    if events is None:
        try:
            events = telemetry.read_events(home=home, run_id=run_id)
        except Exception:  # noqa: BLE001 — a read fault degrades to honest-empty (§8)
            events = []
    else:
        events = [e for e in events if e.get("run_id") == run_id]

    # stable timeline order: events.ndjson is append-only, so file order IS time
    # order; we keep it but expose the ts so a reader sees the wall-clock too.
    timeline = []
    phases = []
    gates = []
    commits = []
    token_total = 0
    saw_token = False
    cost_source = None
    cost_usd = None
    outcome = None
    error = None

    for e in events:
        et = e.get("event_type")
        timeline.append({
            "ts": e.get("ts"),
            "event_type": et,
            "phase": e.get("phase"),
            "step": e.get("step"),
            "gate": e.get("gate"),
            "outcome": e.get("outcome"),
            "loc": e.get("loc"),
            "commit": e.get("commit"),
        })
        if et == "phase":
            phases.append({
                "phase": e.get("phase"),
                "outcome": e.get("outcome"),
                "duration_ms": e.get("duration_ms"),
            })
        elif et == "gate":
            gates.append({
                "gate": e.get("gate"),
                "outcome": e.get("outcome"),
                "loc": e.get("loc"),
            })
        elif et == "commit":
            sha = e.get("commit")
            if sha:
                commits.append(sha)
        elif et == "token":
            tk = e.get("tokens") or {}
            tt = _token_sum(tk)
            if tt is not None:
                token_total += tt
                saw_token = True
            if tk.get("cost_source") is not None:
                cost_source = tk.get("cost_source")
            c = tk.get("total_cost_usd")
            if isinstance(c, (int, float)):
                cost_usd = (cost_usd or 0.0) + float(c)
        elif et == "outcome":
            # an arm-tag-only outcome (holdout) still has outcome="passed"; the
            # LAST real outcome wins for the run's verdict.
            if e.get("outcome") is not None:
                outcome = e.get("outcome")
            if isinstance(e.get("error"), dict):
                error = e.get("error")

    return {
        "run_id": run_id,
        "found": bool(events),
        "event_count": len(events),
        "timeline": timeline,
        "phases": phases,
        "gates": gates,
        "commits": commits,
        "commit_count": len(commits),
        "total_tokens": token_total if saw_token else None,  # None ⇒ honest "—"
        "has_tokens": saw_token,
        "cost_source": cost_source,
        "total_cost_usd": cost_usd,
        "outcome": outcome,
        "error": error,
    }


# ── AGGREGATE TRENDS (§5: gate-freq / failure / token / install drop-off) ──────


def _gate_frequency(events):
    """Count gate firings by gate × outcome (§5: which gates earn their keep / never
    fire). Returns {gate: {outcome: count, "_total": n}, ...}. A run that never
    tripped a gate contributes nothing — an empty result honestly says "no gate
    fired yet". Pure."""
    freq = {}
    for e in events:
        if e.get("event_type") != "gate":
            continue
        gate = e.get("gate")
        if gate is None:
            continue
        by_outcome = freq.setdefault(gate, {"_total": 0})
        outcome = e.get("outcome") or "unknown"
        _inc(by_outcome, outcome)
        by_outcome["_total"] += 1
    return freq


def _failure_patterns(events):
    """Count failure SHAPES (§5: which gates/steps/task-types fail most + common
    error classes). Three reductions over the real events:
      - by_error_class: error.class → count (the common failure classes).
      - by_error_step:  the step/gate an error occurred at → count (where they fail).
      - by_failed_gate: gate → count of failed|blocked gate events (gates that fail).
      - by_failed_step: install step → count of failed install_step events.
    A store with no failures yields all-empty maps — honest "no failures recorded".
    Pure."""
    by_error_class = {}
    by_error_step = {}
    by_failed_gate = {}
    by_failed_step = {}
    for e in events:
        et = e.get("event_type")
        err = e.get("error")
        if isinstance(err, dict):
            _inc(by_error_class, err.get("class"))
            _inc(by_error_step, err.get("step"))
        outcome = e.get("outcome")
        if et == "gate" and outcome in ("failed", "blocked"):
            _inc(by_failed_gate, e.get("gate"))
        if et == "install_step" and outcome == "failed":
            _inc(by_failed_step, e.get("step"))
    return {
        "by_error_class": by_error_class,
        "by_error_step": by_error_step,
        "by_failed_gate": by_failed_gate,
        "by_failed_step": by_failed_step,
    }


def _token_trends(events):
    """Per-run token spend over time + cache-hit ratio (§5: spend over time, cache
    ratio). Returns:
      {
        "per_run": [{run_id, ts, total_tokens, cache_read_tokens, cache_ratio}, ...],
        "total_tokens": int,         # the rolling sum across all metered runs
        "run_count": int,            # runs that metered a token event
        "mean_tokens": float|None,   # honest mean (None when no metered run)
        "mean_cache_ratio": float|None,
      }
    A store with no token event yields an empty per_run + None means — honest "no
    token data", never a fabricated number. Pure."""
    per_run = []
    total = 0
    ratios = []
    for e in events:
        if e.get("event_type") != "token":
            continue
        tk = e.get("tokens") or {}
        tt = _token_sum(tk)
        if tt is None:
            continue
        ratio = _cache_ratio(tk)
        per_run.append({
            "run_id": e.get("run_id"),
            "ts": e.get("ts"),
            "total_tokens": tt,
            "cache_read_tokens": tk.get("cache_read_tokens"),
            "cache_ratio": ratio,
        })
        total += tt
        if ratio is not None:
            ratios.append(ratio)
    n = len(per_run)
    return {
        "per_run": per_run,
        "total_tokens": total,
        "run_count": n,
        "mean_tokens": (total / n) if n else None,        # None ⇒ honest "—"
        "mean_cache_ratio": (sum(ratios) / len(ratios)) if ratios else None,
    }


def _install_dropoff(events):
    """Per install step: started / succeeded / failed counts + the failed/started
    drop-off ratio (§5: where installs fail across runs — the top failing install
    surfaces). Returns:
      {step: {started, succeeded, failed, dropoff: float|None}, ...}
    `dropoff` is failed/started, or None when a step was never started (a ratio over
    zero is undefined — honest, never faked). A store with no install events yields
    an empty map — honest "no install data". Pure."""
    steps = {}
    for e in events:
        if e.get("event_type") != "install_step":
            continue
        step = e.get("step")
        if step is None:
            continue
        rec = steps.setdefault(step, {"started": 0, "succeeded": 0, "failed": 0})
        outcome = e.get("outcome")
        if outcome in ("started", "succeeded", "failed"):
            rec[outcome] += 1
    for rec in steps.values():
        started = rec["started"]
        rec["dropoff"] = (rec["failed"] / started) if started > 0 else None
    return steps


def aggregate(*, home=None, events=None):
    """The aggregate TRENDS view across all runs+installs (§5). Reduces the whole
    event store to: gate-firing frequency, failure patterns, token trends, and
    install drop-off — plus the run/event inventory. Read-only; tolerant of partial
    events; never raises — an absent/empty store yields the honest-empty aggregate
    (has_data=False), not a crash."""
    if events is None:
        try:
            events = telemetry.read_events(home=home)
        except Exception:  # noqa: BLE001 — a read fault degrades to honest-empty (§8)
            events = []

    run_ids = []
    seen_runs = set()
    by_type = {}
    for e in events:
        _inc(by_type, e.get("event_type"))
        rid = e.get("run_id")
        if rid and rid not in seen_runs:
            seen_runs.add(rid)
            run_ids.append(rid)

    return {
        "has_data": bool(events),
        "event_count": len(events),
        "run_count": len(run_ids),
        "run_ids": run_ids,
        "by_type": by_type,
        "gate_frequency": _gate_frequency(events),
        "failure_patterns": _failure_patterns(events),
        "token_trends": _token_trends(events),
        "install_dropoff": _install_dropoff(events),
    }


# ── human renderers (honest "no data yet"; cost provenance travels — §5/§6/§8) ─


def _fmt_num(v):
    """Compact numeric format: ints bare, floats to a small precision, None → the
    honest em-dash. Pure."""
    if v is None:
        return DASH
    if isinstance(v, float):
        if v.is_integer():
            return "%d" % int(v)
        return "%.4g" % v
    return "%d" % int(v) if isinstance(v, int) else str(v)


def _fmt_cost(cost_usd, cost_source):
    """Render a cost figure HONESTLY (§6): a number ONLY when its source tagged it
    measured — otherwise the value travels with an explicit non-measured provenance
    label so it never reads as an asserted fact. None ⇒ the honest em-dash. Pure."""
    if cost_usd is None:
        return DASH
    if cost_source == COST_MEASURED:
        return "$%.4g (measured)" % float(cost_usd)
    # a cost with a non-measured / absent provenance is shown WITH its provenance,
    # never as a bare asserted number (the honesty rule: provenance travels).
    tag = cost_source if cost_source else "unverified"
    return "$%.4g (%s)" % (float(cost_usd), tag)


def render_run(detail):
    """Render a per-run detail dict to an honest human report. An absent run (found
    False) renders a clear "no data" line — never a crash. Pure."""
    lines = []
    rid = detail.get("run_id")
    if not detail.get("found"):
        lines.append("Run %s: no data yet (no events recorded for this run)." % rid)
        return "\n".join(lines)
    lines.append("Run %s  (%d events)" % (rid, detail.get("event_count", 0)))
    lines.append("  outcome:      %s" % (detail.get("outcome") or DASH))
    toks = detail.get("total_tokens")
    lines.append("  tokens spent: %s" % (_fmt_num(toks) if toks is not None else DASH))
    lines.append("  cost:         %s" % _fmt_cost(
        detail.get("total_cost_usd"), detail.get("cost_source")))
    lines.append("  commits:      %d" % detail.get("commit_count", 0))
    phases = detail.get("phases") or []
    if phases:
        lines.append("  phases:")
        for ph in phases:
            lines.append("    - %s: %s" % (ph.get("phase") or DASH,
                                           ph.get("outcome") or DASH))
    gates = detail.get("gates") or []
    if gates:
        lines.append("  gates fired:")
        for g in gates:
            loc = g.get("loc")
            loc_s = (" @ %s" % loc) if loc else ""
            lines.append("    - %s: %s%s" % (g.get("gate") or DASH,
                                             g.get("outcome") or DASH, loc_s))
    return "\n".join(lines)


def render_aggregate(agg):
    """Render the aggregate trends dict to an honest human report (§5). An empty
    store renders a single honest "no data yet" line — never a crash. Pure."""
    if not agg.get("has_data"):
        return ("Heimdall telemetry report: no data yet.\n"
                "  (the event store is empty or telemetry is disabled — "
                "run some tasks/installs to populate it.)")
    lines = []
    lines.append("Heimdall telemetry report  (%d events across %d runs)" % (
        agg.get("event_count", 0), agg.get("run_count", 0)))

    lines.append("")
    lines.append("Gate-firing frequency (which gates earn their keep):")
    freq = agg.get("gate_frequency") or {}
    if not freq:
        lines.append("  %s no gate fired yet" % DASH)
    else:
        for gate in sorted(freq):
            by = freq[gate]
            parts = ["%s=%d" % (o, c) for o, c in sorted(by.items())
                     if o != "_total"]
            lines.append("  %-14s total=%d  (%s)" % (
                gate, by.get("_total", 0), ", ".join(parts)))

    lines.append("")
    lines.append("Failure patterns (which gates/steps/classes fail most):")
    fp = agg.get("failure_patterns") or {}
    _render_counter(lines, "error classes", fp.get("by_error_class"))
    _render_counter(lines, "error at step", fp.get("by_error_step"))
    _render_counter(lines, "failed gates", fp.get("by_failed_gate"))
    _render_counter(lines, "failed install steps", fp.get("by_failed_step"))

    lines.append("")
    lines.append("Token trends (spend over time + cache-hit ratio):")
    tt = agg.get("token_trends") or {}
    if not tt.get("run_count"):
        lines.append("  %s no token data yet" % DASH)
    else:
        lines.append("  metered runs:    %d" % tt.get("run_count", 0))
        lines.append("  total tokens:    %s" % _fmt_num(tt.get("total_tokens")))
        lines.append("  mean tokens/run: %s" % _fmt_num(tt.get("mean_tokens")))
        mcr = tt.get("mean_cache_ratio")
        lines.append("  mean cache hit:  %s" % (
            ("%.1f%%" % (mcr * 100)) if mcr is not None else DASH))

    lines.append("")
    lines.append("Install drop-off (where installs fail across runs):")
    drop = agg.get("install_dropoff") or {}
    if not drop:
        lines.append("  %s no install data yet" % DASH)
    else:
        for step in sorted(drop):
            rec = drop[step]
            ratio = rec.get("dropoff")
            ratio_s = ("%.0f%%" % (ratio * 100)) if ratio is not None else DASH
            lines.append("  %-22s started=%d succeeded=%d failed=%d  drop-off=%s" % (
                step, rec.get("started", 0), rec.get("succeeded", 0),
                rec.get("failed", 0), ratio_s))
    return "\n".join(lines)


def _render_counter(lines, label, counter):
    """Render one named counter map sorted by descending count. An empty map prints
    an honest "none". Pure — appends to `lines`."""
    counter = counter or {}
    if not counter:
        lines.append("  %-22s %s none" % (label + ":", DASH))
        return
    ranked = sorted(counter.items(), key=lambda kv: (-kv[1], str(kv[0])))
    parts = ["%s=%d" % (k, v) for k, v in ranked]
    lines.append("  %-22s %s" % (label + ":", ", ".join(parts)))


# ── CLI core (driven by bin/heimdall-report — bash) ───────────────────────────


def _cli(argv):
    """CLI core. Subcommands mirror the two views so the bash caller
    (bin/heimdall-report) drives the report without re-implementing the scan:

      report run <run_id> [--json] [--home H]
          PER-RUN DETAIL: one run's phases, gates (passed/failed/blocked), tokens,
          commits, outcome. Human table by default; --json for structured output.

      report [aggregate] [--json] [--home H]
          AGGREGATE TRENDS across runs+installs: gate-firing frequency, failure
          patterns, token trends, install drop-off. Human report by default;
          --json for structured output. (`aggregate` is the default subcommand.)

    Read-only — NEVER writes an event. An absent/empty store renders an honest "no
    data yet", never a crash. Exits 0 on a clean render; 2 on a usage error. Never
    raises into the caller."""
    import argparse

    p = argparse.ArgumentParser(prog="heimdall-report", add_help=True)
    p.add_argument("subcommand", nargs="?", default="aggregate")
    p.add_argument("run_id", nargs="?")
    p.add_argument("--json", action="store_true", dest="as_json")
    p.add_argument("--home")
    args = p.parse_args(argv)
    sub = args.subcommand

    if sub == "run":
        if not args.run_id:
            print(json.dumps({"error": "run needs a <run_id>"}))
            return 2
        detail = run_detail(args.run_id, home=args.home)
        if args.as_json:
            print(json.dumps(detail, sort_keys=True))
        else:
            print(render_run(detail))
        return 0

    if sub == "aggregate":
        agg = aggregate(home=args.home)
        if args.as_json:
            print(json.dumps(agg, sort_keys=True))
        else:
            print(render_aggregate(agg))
        return 0

    print(json.dumps({"error": "unknown subcommand: %s" % sub}))
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
