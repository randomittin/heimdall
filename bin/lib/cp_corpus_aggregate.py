#!/usr/bin/env python3
# cp_corpus_aggregate.py — THE DAILY CORPUS AGGREGATE JOB (premerge-corpus-spec §5.2 / §4).
#
# DESIGN: heimdall-premerge-corpus-spec.md §4 (the value ladder) + §2 (k-anonymity). The corpus
# T0 records (cp_corpus, the heimdall_corpus/ namespace) are a per-team stream of zero-content
# PMRs. This job ROLLS THEM UP into the published aggregates that make the corpus a product:
#   • verdict rates            (pass/deny distribution)                    — §4.3 State-of-AI-Code
#   • deny-class distribution  (which coded gate reasons fire, and how often)
#   • falsify survival rates   (mutants_run vs survived — do tests actually catch bugs)
#   • reuse rates              (dup_candidates / reused — is the agent reusing vs duplicating)
# bucketed OVERALL and per-dimension (by agent tool×model, by language, by deny-class).
#
# THE HARD PRIVACY GATE (spec §2, TESTED — the falsifier): K-ANONYMITY >= 20 DISTINCT teams for
# ANY published/queryable bucket. A bucket backed by fewer than pmr_corpus.K_ANONYMITY_MIN
# DISTINCT team_id_hash is SUPPRESSED — it is NEVER served; the published output carries only a
# {suppressed: true, reason: "k_anonymity", teams: <n>} marker in its place, never the metrics.
# THE FALSIFIER: a bucket with < 20 teams appearing with real numbers in the published aggregate
# is a RED test (test/heimdall-corpus-ingest.test.sh). K-anonymity is applied PER BUCKET, at the
# publish boundary, so no rollup can ever expose a small-team cell.
#
# BYO-INFERENCE (a standing invariant): this rollup is PURELY STATISTICAL — counts, rates, and
# distinct-team sets. It makes NO model call (no LLM on heimdall-cp-prod). It reads the corpus
# and writes a keyed aggregate record; it dispatches nothing and executes nothing.
#
# STORE: the aggregate lands in the CORPUS namespace (its own retention, never mixed with ops):
# aggregates/<utc-day>.json (a keyed record) + aggregates/latest.json (the newest, for a read).
# Written THROUGH the isolated corpus backend (cp_corpus._backend), so it is firestore-durable
# and NEVER calls backend.path() (every op is get/put/read — firestore-safe).
#
# stdlib-only (json/os/sys/time) + cp_corpus (the corpus read path + the isolated backend) +
# pmr_corpus (K_ANONYMITY_MIN + the namespace) — the SAME dependency shape every CP job has.

from __future__ import annotations

import json
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_corpus    # the corpus READ path (all_pmrs) + the ISOLATED corpus backend (_backend).
import pmr_corpus   # K_ANONYMITY_MIN (the hard gate threshold) + the namespace/partition names.

# The aggregate store partition (WITHIN the corpus namespace) — its own retention policy.
_AGG_PARTITION = "aggregates"
_LATEST_KEY = "latest"

# The UTC day length in seconds (parity with cp_daily_budget — epoch 0 == UTC midnight, no leap
# seconds), so the day-keyed aggregate rolls over exactly at UTC midnight.
_DAY_SECONDS = 86400


def _utc_day(now):
    """The UTC calendar-day ordinal for `now` (floor(now/86400))."""
    if not isinstance(now, (int, float)):
        return 0
    return int(now // _DAY_SECONDS)


def _agg_rel(day_key):
    """The store-relative path of one day's aggregate record: aggregates/<day>.json."""
    return os.path.join(_AGG_PARTITION, "%s.json" % day_key)


def _latest_rel():
    """The store-relative path of the newest published aggregate: aggregates/latest.json."""
    return os.path.join(_AGG_PARTITION, "%s.json" % _LATEST_KEY)


# ── the per-bucket metric fold (pure, statistical — no model call) ──────────────


def _new_bucket():
    """A fresh accumulator for one bucket. Tracks the DISTINCT team set (the k-anonymity input)
    plus the value-ladder counters — verdicts, deny classes, falsify totals, reuse totals."""
    return {
        "teams": set(),           # DISTINCT team_id_hash — the k-anonymity denominator.
        "n": 0,                   # PMR count in this bucket.
        "verdicts": {},           # verdict -> count.
        "deny_classes": {},       # deny_reason coded -> count.
        "mutants_run": 0,
        "mutants_survived": 0,
        "reused": 0,              # PMRs where reuse.reused is True.
        "reuse_seen": 0,          # PMRs that carried a reuse.reused bool (the denominator).
        "merged": 0,
        "merged_seen": 0,
    }


def _fold_pmr(bucket, pmr):
    """Fold ONE PMR into a bucket accumulator. Pure — reads only the closed pmr_v1 shape."""
    bucket["teams"].add(pmr.get("team_id_hash"))
    bucket["n"] += 1
    verify = pmr.get("verify") if isinstance(pmr.get("verify"), dict) else {}
    verdict = verify.get("verdict")
    if verdict:
        bucket["verdicts"][verdict] = bucket["verdicts"].get(verdict, 0) + 1
    for reason in (verify.get("deny_reasons") or []):
        if reason:
            bucket["deny_classes"][reason] = bucket["deny_classes"].get(reason, 0) + 1
    falsify = verify.get("falsify") if isinstance(verify.get("falsify"), dict) else {}
    if isinstance(falsify.get("mutants_run"), int):
        bucket["mutants_run"] += falsify["mutants_run"]
    if isinstance(falsify.get("survived"), int):
        bucket["mutants_survived"] += falsify["survived"]
    reuse = verify.get("reuse") if isinstance(verify.get("reuse"), dict) else {}
    if isinstance(reuse.get("reused"), bool):
        bucket["reuse_seen"] += 1
        if reuse["reused"]:
            bucket["reused"] += 1
    human = pmr.get("human") if isinstance(pmr.get("human"), dict) else {}
    if isinstance(human.get("merged"), bool):
        bucket["merged_seen"] += 1
        if human["merged"]:
            bucket["merged"] += 1


def _publish_bucket(bucket, *, k_min):
    """Project a bucket accumulator to its PUBLISHED shape — OR the SUPPRESSION marker when the
    distinct-team count is below `k_min` (the HARD k-anonymity gate). A suppressed bucket carries
    NO metrics, only {suppressed, reason, teams}: a reader can see a small cell EXISTS (the count
    of distinct teams) but never any of its rates — exactly the k-anonymity contract. A published
    bucket carries the value-ladder rates + its (>= k_min) distinct-team count."""
    teams = len([t for t in bucket["teams"] if t is not None])
    if teams < k_min:
        # THE HARD GATE — the metrics are NEVER emitted for a small-team bucket.
        return {"suppressed": True, "reason": "k_anonymity",
                "k_min": k_min, "teams": teams}
    n = bucket["n"]
    survival_rate = (round(bucket["mutants_survived"] / bucket["mutants_run"], 4)
                     if bucket["mutants_run"] > 0 else None)
    reuse_rate = (round(bucket["reused"] / bucket["reuse_seen"], 4)
                  if bucket["reuse_seen"] > 0 else None)
    merged_rate = (round(bucket["merged"] / bucket["merged_seen"], 4)
                   if bucket["merged_seen"] > 0 else None)
    verdict_rates = {v: round(c / n, 4) for v, c in bucket["verdicts"].items()} if n else {}
    return {
        "suppressed": False,
        "teams": teams,
        "n": n,
        "verdict_rates": verdict_rates,
        "verdict_counts": dict(bucket["verdicts"]),
        "deny_class_distribution": dict(bucket["deny_classes"]),
        "falsify": {
            "mutants_run": bucket["mutants_run"],
            "survived": bucket["mutants_survived"],
            "survival_rate": survival_rate,
        },
        "reuse_rate": reuse_rate,
        "merged_rate": merged_rate,
    }


# ── the dimension keys (how a PMR is bucketed for the value-ladder rollups) ──────


def _agent_key(pmr):
    """The by-agent bucket key: '<tool>/<model_family>' from the PMR's agent shape ('unknown'
    for a missing part). §4.3's agent×… breakdown."""
    agent = pmr.get("agent") if isinstance(pmr.get("agent"), dict) else {}
    return "%s/%s" % (agent.get("tool") or "unknown", agent.get("model_family") or "unknown")


def _lang_keys(pmr):
    """The by-language bucket keys a PMR contributes to (each of its coded langs). A PMR touching
    no lang contributes to none (never a phantom 'unknown' lang bucket)."""
    change = pmr.get("change") if isinstance(pmr.get("change"), dict) else {}
    return [l for l in (change.get("langs") or []) if l]


def _deny_class_keys(pmr):
    """The by-deny-class bucket keys a PMR contributes to (each of its coded deny reasons)."""
    verify = pmr.get("verify") if isinstance(pmr.get("verify"), dict) else {}
    return [r for r in (verify.get("deny_reasons") or []) if r]


# ── compute_aggregates — the pure rollup with the per-bucket k-anonymity gate ───


def compute_aggregates(pmrs, *, k_min=None, now=None):
    """Roll UP a list of PMRs into the published aggregate (pure — no IO, no model call). Buckets:
      • overall               — one bucket over every PMR ('all').
      • by_agent[tool/model]  — the agent×model breakdown (§4.3).
      • by_lang[lang]         — the per-language breakdown.
      • by_deny_class[reason] — the per-deny-class breakdown.
    EVERY bucket passes through the HARD k-anonymity gate (_publish_bucket): a bucket with fewer
    than `k_min` (default pmr_corpus.K_ANONYMITY_MIN) DISTINCT team_id_hash is SUPPRESSED — its
    metrics are never in the output, only a suppression marker. Returns the published aggregate
    dict {generated_ts, k_min, total_pmrs, total_teams, published_buckets, suppressed_buckets,
    dimensions:{overall, by_agent, by_lang, by_deny_class}}."""
    km = k_min if isinstance(k_min, int) and k_min > 0 else pmr_corpus.K_ANONYMITY_MIN
    overall = _new_bucket()
    by_agent = {}
    by_lang = {}
    by_deny = {}
    all_teams = set()
    total = 0
    for pmr in (pmrs or []):
        if not isinstance(pmr, dict):
            continue
        total += 1
        all_teams.add(pmr.get("team_id_hash"))
        _fold_pmr(overall, pmr)
        _fold_pmr(by_agent.setdefault(_agent_key(pmr), _new_bucket()), pmr)
        for lang in _lang_keys(pmr):
            _fold_pmr(by_lang.setdefault(lang, _new_bucket()), pmr)
        for reason in _deny_class_keys(pmr):
            _fold_pmr(by_deny.setdefault(reason, _new_bucket()), pmr)

    def _publish_dim(buckets):
        return {key: _publish_bucket(b, k_min=km) for key, b in sorted(buckets.items())}

    dimensions = {
        "overall": {"all": _publish_bucket(overall, k_min=km)},
        "by_agent": _publish_dim(by_agent),
        "by_lang": _publish_dim(by_lang),
        "by_deny_class": _publish_dim(by_deny),
    }
    published = 0
    suppressed = 0
    for dim in dimensions.values():
        for b in dim.values():
            if b.get("suppressed"):
                suppressed += 1
            else:
                published += 1
    return {
        "generated_ts": float(now) if isinstance(now, (int, float)) else time.time(),
        "k_min": km,
        "total_pmrs": total,
        "total_teams": len([t for t in all_teams if t is not None]),
        "published_buckets": published,
        "suppressed_buckets": suppressed,
        "dimensions": dimensions,
    }


# ── run_daily_aggregate — read the corpus, roll up, STORE the day's aggregate ───


def run_daily_aggregate(*, home=None, now=None, k_min=None):
    """THE daily aggregate job (spec §5.2). Read EVERY stored T0 PMR from the isolated corpus
    (cp_corpus.all_pmrs), roll it up (compute_aggregates — with the per-bucket k-anonymity gate),
    and STORE the result as the UTC-day aggregate record + refresh aggregates/latest.json, both in
    the CORPUS namespace (its own retention, never the control-plane store). Returns the published
    aggregate dict (also stored). DATA only — reads + writes records, dispatches nothing, makes no
    model call (BYO-inference, statistical rollup only). Idempotent per UTC day (re-running
    overwrites the day's record with the freshest fold)."""
    when = now if now is not None else time.time()
    pmrs = cp_corpus.all_pmrs(home=home)
    agg = compute_aggregates(pmrs, k_min=k_min, now=when)
    agg["utc_day"] = _utc_day(when)
    backend = cp_corpus._backend(home)
    # Store the day-keyed record + refresh latest (both in the corpus namespace, firestore-safe
    # put_record — never backend.path()).
    backend.put_record(_agg_rel(_utc_day(when)), agg)
    backend.put_record(_latest_rel(), agg)
    return agg


def latest_aggregate(home=None):
    """Read the most-recently published aggregate (aggregates/latest.json) from the corpus
    namespace, or None when none has been computed yet. The transparency page / a query reads
    THIS — and every bucket in it has ALREADY passed the k-anonymity gate at compute time, so a
    reader can never see a small-team cell's metrics."""
    return cp_corpus._backend(home).get_record(_latest_rel())


def read_aggregate(day_key, home=None):
    """Read one UTC-day's published aggregate record, or None when absent. Read-only."""
    return cp_corpus._backend(home).get_record(_agg_rel(day_key))


# ── CLI (manual / cron run — mirrors cp_boot's __main__ introspection) ──────────


def _cli(argv):
    """CLI core: `cp_corpus_aggregate.py run [--home DIR]` computes + stores today's aggregate and
    prints it; `latest [--home DIR]` prints the newest stored aggregate. A cron / the scheduler
    invokes `run` once a day. Prints JSON; returns an exit code."""
    import argparse
    p = argparse.ArgumentParser(prog="cp_corpus_aggregate")
    p.add_argument("subcommand", choices=("run", "latest"))
    p.add_argument("--home")
    p.add_argument("--k-min", dest="k_min", type=int)
    args = p.parse_args(argv)
    if args.subcommand == "run":
        agg = run_daily_aggregate(home=args.home, k_min=args.k_min)
        print(json.dumps(agg, indent=2, sort_keys=True))
        return 0
    agg = latest_aggregate(args.home)
    print(json.dumps(agg, indent=2, sort_keys=True) if agg is not None else "null")
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
