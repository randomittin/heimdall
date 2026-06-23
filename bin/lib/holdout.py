#!/usr/bin/env python3
# holdout.py — piece (e) of the Heimdall telemetry layer: A/B-HOLDOUT +
# MEASURED-vs-ESTIMATED reporting. This is the HONESTY-CRITICAL piece — it applies
# Heimdall's own "measured-not-asserted" rule to Heimdall's OWN savings claims.
#
# DESIGN DOSSIER §6 (authoritative; the holdout seam was not located in-repo, so
# §6 is built fresh from spec intent). This module:
#
#   • ASSIGNS a run to an ARM — control (UNSHAPED: companion / output-shaping OFF)
#     or treatment (the variable under test: a companion, a feature, output
#     shaping). The arm is recorded as a telemetry tag (extra={"arm": ...}) so the
#     SAME workload is measured with AND without the variable. HEIMDALL_HOLDOUT=
#     control forces the control arm; otherwise a deterministic per-run fraction
#     (holdout.fraction, default 0.0 = everything treated) decides. The decision is
#     stable per run_id (same run_id → same arm), never random per call.
#
#   • COMPUTES the MEASURED delta — over real token events (telemetry.read_events,
#     piece a — we BIND it, never re-derive the store), it groups runs by arm,
#     sums each run's measured total_tokens / total_cost_usd, and reports the
#     control−treatment delta WITH A CONFIDENCE BAND (n per arm, mean, spread/
#     std-error half-width). Real numbers from real events — never invented.
#
#   • ENFORCES THE HARD HONESTY RULE (§6, the whole point): the "saved vs raw-CC"
#     figure is sourced by EXACTLY one of three provenances, tagged cost_source:
#       1. "measured"  — a holdout delta with ≥ min_n samples per arm exists →
#                        render the measured value + band.
#       2. "estimated" — labeled explicitly (the basis stated) → rendered with an
#                        `est.` label, NEVER a bare number.
#       3. null/blank  — no baseline (no control sample) → render "—". Honest
#                        absence.
#     savings_figure() REFUSES to emit a comparison number it did not measure: a
#     measured number REQUIRES a control sample present (structural, not a
#     convention). A counterfactual with no baseline can ONLY be estimated-or-
#     blank, NEVER a fabricated fact. require_measured() rejects an untagged or
#     un-measured number — an untagged raw-CC number is a build defect.
#
#   • GRACEFUL (§8): every read goes through telemetry.read_events (tolerant; an
#     absent store yields []); a run with too few samples degrades to blank, never
#     to a fabricated number. stdlib-only (hashlib/json/math/os/sys). No 3rd-party.
#
# This is a LIBRARY; the CLI core at the bottom is what bin/heimdall-holdout (bash)
# shells out to (house style: a thin bin/* CLI over a bin/lib/*.py engine, mirrors
# bin/heimdall-redum).

from __future__ import annotations

import hashlib
import json
import math
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import telemetry  # piece (a), on main — the ONE event surface. BIND, never rebuild.

# ── arm constants (the control-group vocabulary — §6) ─────────────────────────

ARM_CONTROL = "control"      # UNSHAPED: the variable under test is OFF (baseline).
ARM_TREATMENT = "treatment"  # SHAPED: the variable under test is ON (default).

# The provenance tags the savings figure may carry (§6 honesty rule). These are the
# ONLY three a comparison number may have — and "measured" is the ONLY one that may
# present a bare number as fact.
COST_MEASURED = "measured"     # a holdout delta from real events ≥ min_n per arm.
COST_ESTIMATED = "estimated"   # a labeled estimate (the `~est.` label, basis stated).
COST_NONE = None               # no baseline → blank ("—"). Honest absence.

# The minimum samples PER ARM before a delta may be presented as MEASURED. Below
# this, the figure degrades to blank — a single run per arm is not a measurement.
_DEFAULT_MIN_N = 2

# The environment override that forces a run into the control arm (§6).
_ENV_HOLDOUT = "HEIMDALL_HOLDOUT"


# ── arm assignment (the control-group flag — §6) ──────────────────────────────


def assign_arm(run_id, *, fraction=0.0, env=None):
    """Decide the arm for `run_id`: ARM_CONTROL or ARM_TREATMENT.

    Precedence (§6):
      1. HEIMDALL_HOLDOUT=control (env override) → ARM_CONTROL, unconditionally.
         Any other HEIMDALL_HOLDOUT value (treatment / unset) defers to the
         fraction.
      2. `fraction` (holdout.fraction, default 0.0) is the share of runs put in
         the control arm. The decision is DETERMINISTIC per run_id (a stable hash
         of the run_id mapped into [0,1)) — the SAME run_id always lands in the
         SAME arm, so a re-run is never silently re-bucketed. fraction<=0 ⇒ always
         treatment; fraction>=1 ⇒ always control.

    Returns ARM_CONTROL or ARM_TREATMENT. Pure; never raises."""
    flag = (env if env is not None else os.environ.get(_ENV_HOLDOUT) or "")
    if str(flag).strip().lower() == ARM_CONTROL:
        return ARM_CONTROL
    try:
        frac = float(fraction)
    except (TypeError, ValueError):
        frac = 0.0
    if frac <= 0.0:
        return ARM_TREATMENT
    if frac >= 1.0:
        return ARM_CONTROL
    return ARM_CONTROL if _run_unit_interval(run_id) < frac else ARM_TREATMENT


def _run_unit_interval(run_id):
    """Map a run_id deterministically into [0,1) via a stable hash. Same run_id →
    same point, so arm assignment is reproducible (never per-call random)."""
    h = hashlib.sha256((run_id or "").encode("utf-8")).hexdigest()
    # take 13 hex digits (52 bits) → a stable fraction in [0,1).
    return int(h[:13], 16) / float(1 << 52)


def tag_arm(run_id, arm, *, home=None):
    """Record which arm a run is in as a telemetry tag — an `outcome` event with
    extra={"arm": arm} keyed to run_id (the substrate scrubs the bounded scalar).
    This is what lets the SAME workload be measured with/without the variable: the
    delta query reads these arm tags back. Returns telemetry.emit's bool (False
    when disabled / dropped); never raises into the caller (§8)."""
    if arm not in (ARM_CONTROL, ARM_TREATMENT):
        return False
    return telemetry.emit(
        "outcome", run_id=run_id, outcome="passed",
        extra={"arm": arm}, home=home,
    )


# ── reading the arms + spend back out of real events (§6 measured delta) ──────


def _run_arm_map(events):
    """Map run_id → arm from the recorded arm tags (extra.arm on any event). The
    LAST arm tag for a run wins (a re-tag overrides). Runs with no arm tag are
    absent from the map (they are neither control nor treatment for the delta)."""
    arms = {}
    for e in events:
        extra = e.get("extra")
        if isinstance(extra, dict):
            arm = extra.get("arm")
            if arm in (ARM_CONTROL, ARM_TREATMENT):
                rid = e.get("run_id")
                if rid:
                    arms[rid] = arm
    return arms


def _run_spend_map(events):
    """Map run_id → {total_tokens, total_cost_usd, cost_source} summed from that
    run's REAL token events (telemetry's token event copies bin/heimdall-tokens
    verbatim). A run with no token event is absent — it contributes no measured
    spend (we never fabricate a number for a run that did not meter)."""
    spend = {}
    for e in events:
        if e.get("event_type") != "token":
            continue
        rid = e.get("run_id")
        if not rid:
            continue
        tk = e.get("tokens")
        if not isinstance(tk, dict):
            continue
        rec = spend.setdefault(
            rid, {"total_tokens": 0, "total_cost_usd": None, "cost_source": None,
                  "saw": False},
        )
        tt = tk.get("total_tokens")
        if isinstance(tt, (int, float)):
            rec["total_tokens"] += int(tt)
            rec["saw"] = True
        c = tk.get("total_cost_usd")
        if isinstance(c, (int, float)):
            rec["total_cost_usd"] = (rec["total_cost_usd"] or 0.0) + float(c)
        cs = tk.get("cost_source")
        if cs is not None:
            rec["cost_source"] = cs
    # drop runs that carried a token event but no usable total (defence in depth).
    return {rid: r for rid, r in spend.items() if r.get("saw")}


def _arm_samples(events, metric):
    """Collect the per-run `metric` value for each arm from real events. Returns
    {ARM_CONTROL: [v, ...], ARM_TREATMENT: [v, ...]} — only runs that BOTH carry an
    arm tag AND metered the metric contribute a sample. metric is 'total_tokens'
    or 'total_cost_usd'."""
    arms = _run_arm_map(events)
    spend = _run_spend_map(events)
    samples = {ARM_CONTROL: [], ARM_TREATMENT: []}
    for rid, arm in arms.items():
        rec = spend.get(rid)
        if not rec:
            continue
        v = rec.get(metric)
        if isinstance(v, (int, float)):
            samples[arm].append(float(v))
    return samples


# ── the confidence band (n / mean / spread — §6) ──────────────────────────────


def _band(values):
    """Summarize a sample with a CONFIDENCE BAND: n, mean, sample std-dev (spread),
    std-error, and a ±half-width (the band). With n<2 the spread/band are None
    (a single point has no measurable spread — honesty, not a fabricated 0 band).
    Pure; tolerant of an empty list (n=0)."""
    n = len(values)
    if n == 0:
        return {"n": 0, "mean": None, "stdev": None, "stderr": None, "band": None}
    mean = sum(values) / n
    if n < 2:
        return {"n": n, "mean": mean, "stdev": None, "stderr": None, "band": None}
    var = sum((v - mean) ** 2 for v in values) / (n - 1)  # sample variance
    stdev = math.sqrt(var)
    stderr = stdev / math.sqrt(n)
    # ~95% band ≈ 1.96·stderr (normal approx; honest about being an approximation).
    band = 1.96 * stderr
    return {
        "n": n,
        "mean": mean,
        "stdev": stdev,
        "stderr": stderr,
        "band": band,
    }


# ── the measured delta (control vs treatment, with band — §6) ─────────────────


def measure_delta(events, *, metric="total_tokens", min_n=_DEFAULT_MIN_N):
    """Compute the MEASURED control−treatment delta for `metric` over real events,
    WITH a confidence band per arm + a band on the delta itself.

    Returns a dict:
      {
        "metric", "min_n",
        "control":   {n, mean, stdev, stderr, band},
        "treatment": {n, mean, stdev, stderr, band},
        "delta":     control.mean − treatment.mean | None,   # tokens SAVED by
                                                             #   treatment (>0 good)
        "delta_band": half-width on the delta | None,
        "measured":  bool,         # True ⇔ BOTH arms have ≥ min_n samples
        "cost_source": "measured" | None,   # the provenance tag (§6)
      }

    The HONEST core: `measured` is True (and cost_source="measured") ONLY when BOTH
    arms cleared min_n. With NO control sample (or too few), measured is False and
    cost_source is None — the caller MUST then render estimated-or-blank, NEVER the
    raw delta as a fact. Pure; never raises."""
    samples = _arm_samples(events, metric)
    ctrl = _band(samples[ARM_CONTROL])
    treat = _band(samples[ARM_TREATMENT])
    measured = (ctrl["n"] >= min_n and treat["n"] >= min_n)
    delta = None
    delta_band = None
    if measured and ctrl["mean"] is not None and treat["mean"] is not None:
        delta = ctrl["mean"] - treat["mean"]
        cb = ctrl["band"] or 0.0
        tb = treat["band"] or 0.0
        # combine the two arms' band half-widths in quadrature (independent arms).
        delta_band = math.sqrt(cb * cb + tb * tb)
    return {
        "metric": metric,
        "min_n": min_n,
        "control": ctrl,
        "treatment": treat,
        "delta": delta,
        "delta_band": delta_band,
        "measured": bool(measured),
        "cost_source": COST_MEASURED if measured else COST_NONE,
    }


# ── the HARD HONESTY RULE — the savings figure (§6) ───────────────────────────


def savings_figure(delta_result, *, estimate=None, estimate_basis=None):
    """Resolve the card's `vs raw-CC est.` slot to EXACTLY one honest provenance
    (§6). This is the structural refusal: a comparison number is emitted as FACT
    ONLY when it was MEASURED via a holdout delta with a control sample. Inputs:

      delta_result   — a measure_delta() result (the measured path).
      estimate       — an OPTIONAL float, a labeled estimate to fall back to when
                       no measurement exists. It is NEVER presented as a bare fact:
                       it is tagged cost_source="estimated" and carries the `est.`
                       label + basis. Pass None to fall through to blank.
      estimate_basis — a short string stating WHAT the estimate is based on
                       (required honesty: an estimate with no stated basis is still
                       blank — we refuse an unlabeled guess).

    Returns a dict the renderer consumes:
      {"value": float|None, "band": float|None, "cost_source": "measured"|
       "estimated"|None, "label": "" | "est.", "basis": str|None, "n": {...}}

    Resolution order (§6): measured → estimated(labeled+basis) → blank. NEVER a
    fabricated number. Pure; never raises."""
    n_info = {
        "control": (delta_result or {}).get("control", {}).get("n", 0),
        "treatment": (delta_result or {}).get("treatment", {}).get("n", 0),
    }
    # 1. MEASURED — a real holdout delta with a control sample.
    if delta_result and delta_result.get("measured") and \
            delta_result.get("delta") is not None:
        return {
            "value": delta_result["delta"],
            "band": delta_result.get("delta_band"),
            "cost_source": COST_MEASURED,
            "label": "",
            "basis": "holdout: control vs treatment, measured from token events",
            "n": n_info,
        }
    # 2. ESTIMATED — a labeled estimate WITH a stated basis (never a bare number).
    if isinstance(estimate, (int, float)) and \
            isinstance(estimate_basis, str) and estimate_basis.strip():
        return {
            "value": float(estimate),
            "band": None,
            "cost_source": COST_ESTIMATED,
            "label": "est.",
            "basis": estimate_basis.strip(),
            "n": n_info,
        }
    # 3. BLANK — no baseline → honest absence. NEVER a fabricated number.
    return {
        "value": None,
        "band": None,
        "cost_source": COST_NONE,
        "label": "",
        "basis": None,
        "n": n_info,
    }


def require_measured(figure):
    """The structural REFUSAL (§6): assert a savings `figure` may be presented as a
    bare FACT. A figure is print-as-fact ONLY when it carries a NUMBER and the
    cost_source provenance tag is exactly "measured". Anything else — an estimate,
    a blank, OR an UNTAGGED number (cost_source missing/None while a value is
    present) — is NOT a fact and MUST NOT be printed as a raw savings number.

    Returns True iff the figure is a measured fact. The writer/renderer call this
    before printing a bare number: an untagged raw-CC number is a build defect, not
    a display choice, so this is the gate that makes fabrication impossible to
    print. Pure; never raises."""
    if not isinstance(figure, dict):
        return False
    cs = figure.get("cost_source")
    val = figure.get("value")
    if val is None:
        return False  # blank is never a bare-number fact.
    return cs == COST_MEASURED  # ONLY a measured-tagged number is a fact.


def render_figure(figure):
    """Render a savings `figure` to an HONEST human string (the card's `vs raw-CC`
    slot). The structural guarantee: this NEVER prints a bare number unless
    require_measured(figure) holds. A measured fact → "<value> (±band)". A labeled
    estimate → "~<value> est. (<basis>)" — always with the est. label, never bare.
    A blank → "—". Pure; never raises."""
    if require_measured(figure):
        val = figure["value"]
        band = figure.get("band")
        if isinstance(band, (int, float)):
            return "%s (±%s)" % (_fmt(val), _fmt(band))
        return _fmt(val)
    cs = figure.get("cost_source") if isinstance(figure, dict) else None
    if cs == COST_ESTIMATED and isinstance(figure.get("value"), (int, float)):
        basis = figure.get("basis") or "estimate"
        return "~%s est. (%s)" % (_fmt(figure["value"]), basis)
    return "—"  # blank — honest absence.


def _fmt(v):
    """Format a numeric value compactly: ints without a decimal, floats to a small
    precision. Pure; tolerant of None (renders the blank em-dash)."""
    if v is None:
        return "—"
    if isinstance(v, float) and not v.is_integer():
        return "%.4g" % v
    return "%d" % int(v)


# ── CLI core (driven by bin/heimdall-holdout — bash) ──────────────────────────


def _cli(argv):
    """CLI core. Subcommands mirror the assign + measure surface so the bash caller
    (bin/heimdall-holdout) drives holdout without re-implementing it.

      assign  --run-id R [--fraction F] [--home H]
              → decide + RECORD the arm (control|treatment); prints {"run_id","arm",
                "tagged"}. HEIMDALL_HOLDOUT=control forces control.
      arm     --run-id R [--fraction F]
              → decide the arm WITHOUT recording (a dry-run); prints {"run_id","arm"}.
      delta   [--metric total_tokens|total_cost_usd] [--min-n N] [--home H]
              → the MEASURED control−treatment delta with confidence bands (JSON).
      figure  [--metric M] [--min-n N] [--estimate F --estimate-basis S] [--home H]
              → the HONEST savings figure (measured | estimated | blank), JSON +
                a rendered one-line `vs raw-CC` string. NEVER a fabricated number.

    Every subcommand exits 0 on a clean parse — telemetry/holdout NEVER gates the
    caller (§8). A read fault degrades to the honest-empty shape, not an error."""
    import argparse

    p = argparse.ArgumentParser(prog="heimdall-holdout", add_help=True)
    p.add_argument("subcommand")
    p.add_argument("--run-id", dest="run_id")
    p.add_argument("--fraction", type=float, default=0.0)
    p.add_argument("--metric", default="total_tokens")
    p.add_argument("--min-n", dest="min_n", type=int, default=_DEFAULT_MIN_N)
    p.add_argument("--estimate", type=float)
    p.add_argument("--estimate-basis", dest="estimate_basis")
    p.add_argument("--home")
    args = p.parse_args(argv)
    sub = args.subcommand

    if sub == "arm":
        if not args.run_id:
            print(json.dumps({"error": "arm needs --run-id"}))
            return 2
        arm = assign_arm(args.run_id, fraction=args.fraction)
        print(json.dumps({"run_id": args.run_id, "arm": arm}))
        return 0

    if sub == "assign":
        if not args.run_id:
            print(json.dumps({"error": "assign needs --run-id"}))
            return 2
        arm = assign_arm(args.run_id, fraction=args.fraction)
        tagged = tag_arm(args.run_id, arm, home=args.home)
        print(json.dumps({"run_id": args.run_id, "arm": arm,
                          "tagged": bool(tagged)}))
        return 0

    if sub == "delta":
        events = telemetry.read_events(home=args.home)
        result = measure_delta(events, metric=args.metric, min_n=args.min_n)
        print(json.dumps(result, sort_keys=True))
        return 0

    if sub == "figure":
        events = telemetry.read_events(home=args.home)
        result = measure_delta(events, metric=args.metric, min_n=args.min_n)
        figure = savings_figure(
            result, estimate=args.estimate,
            estimate_basis=args.estimate_basis,
        )
        out = dict(figure)
        out["rendered"] = render_figure(figure)
        out["is_measured_fact"] = require_measured(figure)
        print(json.dumps(out, sort_keys=True))
        return 0

    print(json.dumps({"error": "unknown subcommand: %s" % sub}))
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
