#!/usr/bin/env python3
# cp_dashboard.py — piece (b) of the Heimdall control plane: THE OBSERVE DASHBOARD.
#
# DESIGN DOSSIER §5/§10/§11 (authoritative). A thin CROSS-DEV view over the observe
# store cp_ingest.py writes (partitioned by instance HAID). It REUSES report.py's
# aggregates VERBATIM (gate frequency, failure patterns, token trends, install drop-
# off) and adds the one adapter §5 names: an INSTANCE_ID GROUP-BY, so the same
# answers report.py gives for one local store now span the whole fleet — per dev AND
# fleet-wide.
#
# THE TWO CARDINAL PROPERTIES this module pins:
#
#   1. CROSS-DEV BY instance_id (§5) — the store is partitioned per HAID; the
#      dashboard reads each partition (cp_ingest.read_instance), runs report.aggregate
#      over THAT dev's events (the per-dev view), AND over the union of all partitions
#      (the fleet view). install drop-off / gate frequency / failure patterns / token
#      spend, each grouped by instance_id. This is the reuse §11's ledger names:
#      report.aggregate is the compute; the group-by is the only adapter.
#
#   2. HONEST NUMBERS ONLY (§5/§6, holdout discipline) — every reported FIGURE goes
#      through holdout.render_figure / holdout.savings_figure. A figure with no
#      backing data renders BLANK ("—"), NEVER a fabricated number. A dev who never
#      metered a token event shows tokens as "—"; a step never started shows drop-off
#      as "—". Missing data is shown as missing, never invented — the same refusal
#      report.py and holdout.py already enforce, applied to the cross-dev view.
#
# This module READS ONLY — it never writes the store and (like all of piece b) never
# executes anything. The /dashboard route returns the aggregate as DATA (JSON); the
# render helpers are an honest text view of the same data.
#
# THE INTERFACE the server binds to (stable):
#   register(*, home=None)                  — wire GET /dashboard into cp_server seam.
#   dashboard_route(identity, request, ...) — the route handler (verified Identity in).
#   cross_dev(*, home=None) -> dict          — the fleet aggregate grouped by instance.
#   render_dashboard(view) -> str            — an honest text render (blank, not faked).
#
# stdlib-only (json/os/sys) + the sibling cp_ingest/cp_server and the REUSED report /
# holdout layers — never re-derives an aggregate or an honesty rule.

from __future__ import annotations

import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_auth      # the Identity shape the verified route receives (§3).
import cp_ingest    # REUSE the observe store read path (partitioned by HAID).
import cp_server    # REUSE register_route + Response — the registration seam (§10).
import holdout      # REUSE the honesty rule — a figure with no data renders blank.
import report       # REUSE aggregate/run_detail — the compute, never re-derived.

# The honest-absence glyph (the SAME em-dash report.py / holdout.py render — a
# missing number is shown as missing, never fabricated). Single-sourced from report.
DASH = report.DASH


# ── the cross-dev aggregate: report.aggregate per partition + fleet-wide (§5) ──


def _instance_view(instance_slug, *, home=None):
    """The per-dev view for ONE instance partition: report.aggregate over THAT dev's
    stored events (the EXACT compute report.py gives a local store, now scoped to one
    instance's partition). Returns {instance, events, aggregate}. Read-only; an empty
    partition yields report's honest-empty aggregate (has_data=False)."""
    events = cp_ingest.read_instance(instance_slug, home=home)
    return {
        "instance": instance_slug,
        "event_count": len(events),
        "aggregate": report.aggregate(events=events),
    }


def cross_dev(*, home=None):
    """THE cross-dev aggregate (§5): report.py's gate frequency / failure patterns /
    token trends / install drop-off, GROUPED BY instance_id, plus a fleet-wide roll-
    up over the union of all partitions.

    Returns:
      {
        "has_data": bool,                 # any partition has any event.
        "instances": ["<slug>", ...],     # the devs who pushed (the group-by keys).
        "by_instance": {slug: {instance, event_count, aggregate}, ...},  # per-dev.
        "fleet": <report.aggregate over ALL partitions' events>,         # roll-up.
        "savings": <holdout.savings_figure>,  # the honest fleet token figure (blank
                                               # unless a measured holdout delta exists).
      }

    Read-only; tolerant of an absent/empty store (honest-empty, has_data=False); never
    raises and NEVER executes anything. Every number is report/holdout-sourced — a
    figure with no backing data is blank, never fabricated (§6)."""
    instances = cp_ingest.stored_instances(home=home)
    by_instance = {}
    all_events = []
    for slug in instances:
        view = _instance_view(slug, home=home)
        by_instance[slug] = view
        all_events.extend(cp_ingest.read_instance(slug, home=home))

    fleet = report.aggregate(events=all_events)

    # The fleet token SAVINGS figure goes through the holdout honesty gate: a measured
    # control-vs-treatment delta over the real events, else BLANK. A figure with no
    # control sample can ONLY be blank here — never a fabricated number (§6).
    delta = holdout.measure_delta(all_events, metric="total_tokens")
    savings = holdout.savings_figure(delta)

    return {
        "has_data": bool(all_events),
        "instances": instances,
        "by_instance": by_instance,
        "fleet": fleet,
        "savings": savings,
    }


# ── honest text render (blank for missing data — never a fabricated number) ────


def _dropoff_by_instance(view):
    """Pull each instance's install drop-off out of its aggregate for the cross-dev
    table. Returns {slug: {step: {started, succeeded, failed, dropoff}}}. A dev with
    no install events contributes an empty map — honest absence, never a faked row."""
    out = {}
    for slug, iv in (view.get("by_instance") or {}).items():
        agg = iv.get("aggregate") or {}
        out[slug] = agg.get("install_dropoff") or {}
    return out


def _fleet_tokens_figure(view):
    """The fleet token figure rendered HONESTLY via holdout.render_figure: a measured
    holdout delta renders its value+band; anything else renders the blank em-dash. A
    cross-dev token figure with no measured baseline is NEVER a fabricated number."""
    return holdout.render_figure(view.get("savings"))


def render_dashboard(view):
    """Render the cross-dev view to an HONEST text dashboard (§5/§6). An empty store
    renders a single honest 'no data yet' line. Every number is report/holdout-
    sourced; a missing figure is the blank em-dash, NEVER fabricated. Read-only; pure.

    Sections: a per-instance roll-up (events, runs, total tokens — blank when a dev
    metered none), then the fleet-wide gate frequency / failure / token / install
    drop-off (report.render_aggregate verbatim), then the honest fleet savings slot."""
    if not view.get("has_data"):
        return ("Heimdall control-plane observe dashboard: no data yet.\n"
                "  (no instance has pushed telemetry — the observe store is empty.)")

    lines = []
    instances = view.get("instances") or []
    lines.append("Heimdall observe dashboard — %d instance(s) reporting" % len(instances))
    lines.append("")
    lines.append("Per-instance roll-up (cross-dev, grouped by instance_id):")
    for slug in instances:
        iv = (view.get("by_instance") or {}).get(slug) or {}
        agg = iv.get("aggregate") or {}
        tt = (agg.get("token_trends") or {})
        # total tokens is shown ONLY when a token event metered it — else blank.
        toks = tt.get("total_tokens") if tt.get("run_count") else None
        toks_s = ("%d" % toks) if isinstance(toks, int) and tt.get("run_count") else DASH
        lines.append(
            "  %-22s events=%d runs=%d tokens=%s" % (
                slug, iv.get("event_count", 0), agg.get("run_count", 0), toks_s))

    lines.append("")
    lines.append("Install drop-off by instance (where each dev's installs fail):")
    drop_by = _dropoff_by_instance(view)
    any_drop = False
    for slug in instances:
        steps = drop_by.get(slug) or {}
        if not steps:
            continue
        for step in sorted(steps):
            rec = steps[step]
            ratio = rec.get("dropoff")
            # an unstarted step has an undefined ratio → blank, never a faked 0%.
            ratio_s = ("%.0f%%" % (ratio * 100)) if ratio is not None else DASH
            lines.append(
                "  %-14s %-20s started=%d failed=%d drop-off=%s" % (
                    slug, step, rec.get("started", 0), rec.get("failed", 0), ratio_s))
            any_drop = True
    if not any_drop:
        lines.append("  %s no install data yet" % DASH)

    lines.append("")
    lines.append("Fleet-wide trends (all instances combined):")
    # REUSE report.render_aggregate VERBATIM for the fleet roll-up — gate frequency,
    # failure patterns, token trends, install drop-off, each honest-empty when absent.
    fleet_text = report.render_aggregate(view.get("fleet") or {})
    for ln in fleet_text.splitlines():
        lines.append("  " + ln)

    lines.append("")
    # the savings slot is the holdout honesty surface: blank unless measured.
    lines.append("Fleet token savings (vs raw-CC): %s" % _fleet_tokens_figure(view))
    return "\n".join(lines)


# ── the route handler (verified Identity in — the server authed it, §3) ─────────


def dashboard_route(identity, request, *, home=None):
    """The GET /dashboard route handler (§5). The server ran the §3 auth chokepoint
    BEFORE this runs, so `identity` is a VERIFIED cp_auth.Identity — an unauthenticated
    request never reaches here. Returns the cross-dev aggregate as DATA (a cp_server
    Response, JSON body) plus an honest text render. READ-ONLY — it writes nothing and
    executes nothing. An honest-empty store yields has_data=False, never a fabricated
    figure."""
    _ = identity  # the verified caller; the dashboard is the same view for any authed dev.
    view = cross_dev(home=home)
    body = dict(view)
    body["rendered"] = render_dashboard(view)
    return cp_server.Response(200, body)


def register(*, home=None):
    """Wire GET /dashboard into cp_server's registration seam (§10) WITHOUT editing
    cp_server. Returns the registered (method, path) key. The handler closes over the
    runtime `home`. Idempotent — re-registering replaces the route."""
    return cp_server.register_route(
        "GET", "/dashboard",
        lambda identity, request: dashboard_route(identity, request, home=home),
    )


# ── CLI core (read-only cross-dev view; mirrors bin/heimdall-report shape) ─────


def _cli(argv):
    """CLI core (read-only). Renders the cross-dev observe dashboard:

      dashboard [--json] [--home H]
          The cross-dev aggregate (grouped by instance_id): per-instance roll-up +
          fleet-wide gate frequency / failure / token / install drop-off, every
          number honest (blank for missing, never fabricated). Human text by default;
          --json for the structured view.

    Read-only — NEVER writes the store, NEVER executes. An absent/empty store renders
    an honest 'no data yet'. Exits 0 on a clean render; 2 on a usage error."""
    import argparse

    p = argparse.ArgumentParser(prog="cp-dashboard", add_help=True)
    p.add_argument("subcommand", nargs="?", default="dashboard")
    p.add_argument("--json", action="store_true", dest="as_json")
    p.add_argument("--home")
    args = p.parse_args(argv)

    if args.subcommand != "dashboard":
        print(json.dumps({"error": "unknown subcommand: %s" % args.subcommand}))
        return 2

    view = cross_dev(home=args.home)
    if args.as_json:
        print(json.dumps(view, sort_keys=True))
    else:
        print(render_dashboard(view))
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
