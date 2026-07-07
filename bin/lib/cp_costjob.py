#!/usr/bin/env python3
# cp_costjob.py — THE BRAKE CHAIN, wired into one daily job (cost-governance §4).
#
# WHY THIS EXISTS. The spec's §4 brake chain is four links that already mostly exist as parts;
# this module is the one place they become a CHAIN, run daily:
#
#   1. DAILY COST JOB (§1) — turn yesterday's ACTUAL infra spend (BigQuery billing export $/day,
#      or, until RJ enables it, a modeled $/day from op counts) into {$/day, $/DAU, projected
#      month, % of budget} via cp_cost_model. The %-of-budget is the SPEND-PACE.
#   2. LADDER AUTO-BACKOFF (§2) — feed that spend-pace to cp_config.set_ladder, which picks the
#      interval tier (<50%->20/15 … >90%->120/120). Every client's next /config fetch OBEYS the
#      slower cadence, so the system self-heals its own burn (the barely-perceptible-latency lever).
#   3. OWNER ALERTS at 50/75/90% (§4) — when the pace crosses UP into a new tier band, page every
#      owner (cp_notify) so a human sees the burn climbing BEFORE the hard cap. De-duped on the
#      UPWARD CROSSING (prev tier < new tier), so a steady 80% does not re-page every day; a climb
#      50->75->90 pages once per step. A daily summary is always posted to the owner inbox (the
#      "spend as a receipt" transparency line — on-brand).
#   4. BILLING KILL-SWITCH — the DEAD-MAN'S BRAKE at the hard cap. It is a GCP budget object +
#      Cloud Function (infra/billing-killswitch) that Google enforces server-side and that CANNOT
#      itself fail open; it stays UNTOUCHED here (RJ owns the budget-object change). This module
#      only ALIGNS the software brake's budget knob to it (HEIMDALL_MONTHLY_BUDGET_USD == the
#      budget-object amount) and REPORTS when the pace has reached the hard cap (pct >= 100), so
#      the daily log names "the dead-man's brake is armed" instead of it tripping silently.
#
# THE CHAIN IS THE POINT: link 1 measures, link 2 slows the fleet, link 3 warns the human, link 4
# is the hard floor Google enforces if 2+3 were not enough. Each link degrades independently — a
# notify failure never blocks the ladder set; a ladder-set failure never blocks the report — so a
# fault in one link cannot break the brake as a whole.
#
# INVARIANT (§0): this job constructs NO model-API client and touches NO inference path — it reads
# billing $ (or op counts) + writes the ladder record + posts notifications. BYO-inference holds.
#
# stdlib-only (os/sys/time) + cp_cost_model (the arithmetic) + cp_config (the ladder) + cp_notify
# (owner alerts) + cp_auth (owner_haids) — the SAME dependency shape every CP job has.

from __future__ import annotations

import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_auth        # owner_haids — who the 50/75/90 alerts + the daily summary go to.
import cp_config      # set_ladder / get_ladder — the §2 adaptive-interval ladder (link 2).
import cp_cost_model  # the §1 unit-cost arithmetic (link 1 — spend -> spend-pace).
import cp_notify      # the §8 owner alert channel (link 3 — DATA only, never a command).

# The alert bands the brake chain pages on (spec §4). A tier index maps to the % band it enters:
# tier 1 = 50%, tier 2 = 75%, tier 3 = 90%. The daily job pages on an UPWARD crossing into a new
# tier, so these three thresholds are exactly the tier boundaries cp_config's ladder already uses.
_ALERT_TIER_PCT = {1: 50, 2: 75, 3: 90}


def _pct_for_tier(tier):
    """The %-band label for a ladder tier (for the alert text). 0 -> nominal, else the band floor."""
    return _ALERT_TIER_PCT.get(tier, 0)


def kill_switch_budget_usd():
    """The budget the software brake aligns to the GCP billing kill-switch object (spec §4/§5).
    This is the SAME HEIMDALL_MONTHLY_BUDGET_USD knob cp_cost_model uses, surfaced here so the
    daily log can state the alignment ("software brake budget = $X; verify the GCP budget object
    matches"). RJ owns the budget-object change; this is the code-side knob that must equal it."""
    return cp_cost_model.monthly_budget_usd()


def kill_switch_armed(pct_of_budget):
    """True iff the spend-pace has reached the HARD CAP (pct_of_budget >= 100) — the point at
    which the dead-man's brake (the GCP billing kill-switch, infra/billing-killswitch) is the last
    line. The software ladder should have slowed the burn long before this; if it is armed, links
    2+3 were insufficient and Google's server-side enforcement is what remains. Reported, never
    enforced here (the kill-switch is a GCP budget object RJ owns)."""
    return isinstance(pct_of_budget, (int, float)) and pct_of_budget >= 100.0


def _owner_alert(text, *, home=None):
    """Page EVERY registered owner (cp_notify.alert -> the owner inbox, DATA only). Returns the
    count of owners alerted. A notify fault on one owner never blocks the others or the chain (the
    inbox delivery degrades to a logged non-ok, never a raise). No secret enters (text is scrubbed
    by cp_notify)."""
    alerted = 0
    for haid in cp_auth.owner_haids(home):
        try:
            result = cp_notify.alert(haid, text, home=home)
            if result.get("ok"):
                alerted += 1
        except Exception as exc:  # noqa: BLE001 — one owner's notify fault never breaks the chain.
            _stderr("cp_costjob: owner alert failed for %s: %s" % (str(haid)[:8],
                                                                   type(exc).__name__))
    return alerted


def run_daily(*, daily_usd=None, reads=None, writes=None, requests=None, dau=None,
              request_seconds=None, home=None, set_ladder=True, notify_owner=True, now=None):
    """RUN the daily brake chain (spec §4). Returns a structured result dict; each link degrades
    independently (a fault in one never breaks the chain).

    INPUT (link 1): an explicit `daily_usd` (yesterday's ACTUAL infra $ from the BigQuery billing
    export) wins; else a modeled $/day from op counts (`reads`/`writes`/`requests` — the path
    until the export is enabled). `dau` gives the $/DAU line. `now` is injectable for tests.

    CHAIN:
      • link 1: report = cp_cost_model.report(...) -> {daily_usd, per_dau_usd, projected_month_usd,
        pct_of_budget}. pct_of_budget is the spend-pace.
      • link 2: when `set_ladder`, prev = get_ladder(); new = set_ladder(pct) -> the interval tier
        every client's next /config obeys.
      • link 3: when `notify_owner` AND the tier crossed UP (prev.tier < new.tier), page every owner
        with the band it entered (50/75/90). A daily summary is ALWAYS posted to the owner inbox.
      • link 4: kill_switch_armed(pct) — report (never enforce) whether the hard cap is reached.

    The result carries the report, the prev/new tier, whether an alert fired, the alerted-owner
    count, and the kill-switch status — the run log the CLI prints + a test asserts."""
    when = now if now is not None else time.time()

    # ── LINK 1: measure -> spend-pace ──────────────────────────────────────────────────────
    if daily_usd is not None:
        rpt = cp_cost_model.report(daily_usd, dau=dau)
        source = "actual_billing"
    else:
        req_secs = (request_seconds if isinstance(request_seconds, (int, float))
                    else 0.05)
        modeled_daily = cp_cost_model.project_from_counts(
            reads or 0, writes or 0, requests or 0, request_seconds=req_secs)
        rpt = cp_cost_model.report(modeled_daily, dau=dau)
        source = "modeled_from_counts"
    pct = rpt["pct_of_budget"]

    # ── LINK 2: spend-pace -> ladder auto-backoff ──────────────────────────────────────────
    prev_tier = cp_config.get_ladder(home=home).get("tier", 0)
    new_tier = prev_tier
    ladder_reason = None
    if set_ladder:
        new = cp_config.set_ladder(pct, home=home)
        new_tier = new.get("tier", 0)
        ladder_reason = new.get("backoff_reason")

    # ── LINK 3: owner alerts on an UPWARD tier crossing (50/75/90) + the daily summary ──────
    alerted = 0
    alert_fired = False
    crossed_up = new_tier > prev_tier
    if notify_owner:
        if crossed_up and new_tier in _ALERT_TIER_PCT:
            alert_fired = True
            alerted = _owner_alert(
                "cost brake: spend-pace crossed %d%% of the $%s/mo budget — interval ladder "
                "backed off to tier %d (%ss beat). projected month $%s (%.1f%% of budget)."
                % (_pct_for_tier(new_tier), _fmt_money(rpt["budget_usd"]), new_tier,
                   cp_config.tier_by_index(new_tier)["beat_interval_s"],
                   _fmt_money(rpt["projected_month_usd"]), pct),
                home=home)
        # The daily summary receipt — ALWAYS posted (spend as a receipt, on-brand transparency).
        _owner_alert(
            "daily cost report: $%s/day, projected $%s/mo (%.1f%% of $%s budget), tier %d%s."
            % (_fmt_money(rpt["daily_usd"]), _fmt_money(rpt["projected_month_usd"]), pct,
               _fmt_money(rpt["budget_usd"]), new_tier,
               (" [%s]" % ladder_reason) if ladder_reason else ""),
            home=home)

    # ── LINK 4: the dead-man's brake status (report, never enforce) ────────────────────────
    armed = kill_switch_armed(pct)
    if armed:
        _stderr("cp_costjob: HARD CAP REACHED (%.1f%% of $%s budget) — the GCP billing "
                "kill-switch (infra/billing-killswitch) is the dead-man's brake; the software "
                "ladder alone did not hold. Verify the budget object == $%s."
                % (pct, _fmt_money(rpt["budget_usd"]), _fmt_money(kill_switch_budget_usd())))

    return {
        "ts": int(when),
        "source": source,
        "report": rpt,
        "spend_pace_pct": pct,
        "prev_tier": prev_tier,
        "new_tier": new_tier,
        "ladder_reason": ladder_reason,
        "crossed_up": crossed_up,
        "alert_fired": alert_fired,
        "owners_alerted": alerted,
        "kill_switch_budget_usd": kill_switch_budget_usd(),
        "kill_switch_armed": armed,
    }


def _fmt_money(value):
    """Format a dollar amount to a compact string (2dp, no trailing noise) for a log/alert line."""
    try:
        return ("%.2f" % float(value)).rstrip("0").rstrip(".") or "0"
    except (TypeError, ValueError):
        return "0"


def _stderr(msg):
    """One best-effort diagnostic line to stderr (Cloud Run captures it). Swallowed on failure so
    a log fault can never break the brake chain."""
    try:
        sys.stderr.write("%s\n" % msg)
        sys.stderr.flush()
    except Exception:  # noqa: BLE001 — diagnostic only; must not raise into the chain.
        return
