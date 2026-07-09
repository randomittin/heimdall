#!/usr/bin/env python3
# cp_issue_aggregate.py — THE DAILY ANONYMIZED-ISSUE AGGREGATE JOB (Wave 2).
#
# WHAT THIS IS: the ADDITIVE SIBLING of cp_corpus_aggregate.py, for the issue path
# (issue_v1). Where the corpus aggregate rolls up per-team zero-content PMRs, THIS
# job rolls up the ingested `issue_v1` records — a hashed error-signature plus
# coarse coded fields — into the PUBLISHED aggregate the seeker/fixer feed reads.
#
# THE HARD PRIVACY GATE (INV-B, TESTED — the falsifier): a published/queryable
# SIGNATURE BUCKET — keyed by (error_class, signature_hash, hmd_version, os_class,
# command|phase) — is served ONLY when >= issue_corpus.ISSUE_K_ANONYMITY_MIN (= 10)
# DISTINCT team_id_hash have contributed. A sub-threshold bucket (including a rare
# error-signature seen by fewer than 10 distinct teams) emits ONLY a
# {suppressed:true, reason:"k_anonymity", teams:n} marker — never the metrics. The
# k-anon decision is DELEGATED to issue_corpus.suppress_if_rare (the single source
# of the rule, defined once in the local lib and IMPORTED here) so the emit-side
# and the aggregate can never disagree — distinct-team count, never row count.
#
# THE SECURITY LANE IS ABSOLUTE (INV-F): a security_sensitive record NEVER enters
# the public aggregate — it is EXCLUDED before any fold, regardless of k / team
# count. A signal is treated as security-sensitive when its stamped
# `security_sensitive` flag is true OR its coded error_class falls in the security
# taxonomy (issue_corpus._SECURITY_CLASSES) — fail-closed belt on top of the flag.
#
# STORE ISOLATION (INV-G): the aggregate reads issues/<team_hash>/issues.ndjson
# THROUGH the ISOLATED corpus namespace (cp_corpus._backend — the SAME disjoint
# keyspace seam the corpus uses), per-team partitioned. A control-plane presence/
# ops rel can NEVER be resolved by this backend and vice-versa, so no cross-tenant
# read path exists; the rr-multitenant-isolation keystone stays 1.0. The aggregate
# lands under its own partition (issue_aggregates/) within that namespace.
#
# BYO-INFERENCE (standing invariant): this rollup is PURELY STATISTICAL — counts,
# rates, and distinct-team sets. It makes NO model call, dispatches nothing, runs
# no handler. It reads records and writes a keyed aggregate record.
#
# stdlib-only (json/os/sys/time) + cp_corpus (the isolated backend seam + the path
# slug) + issue_corpus (the k-anon primitive + the security taxonomy + the
# threshold) — the SAME dependency shape cp_corpus_aggregate has. It NEVER edits a
# gated module (cp_corpus*.py / pmr_corpus.py stay byte-for-byte green).

from __future__ import annotations

import json
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_corpus     # the ISOLATED corpus backend seam (_backend) + the path slug (_slug).
import issue_corpus  # the k-anon primitive (suppress_if_rare) + ISSUE_K_ANONYMITY_MIN + taxonomy.

# The issue store partition (INV-G) — issues/<team_hash>/issues.ndjson, WITHIN the
# corpus namespace, disjoint from control-plane. This is the layout the Wave-2/3
# ingest writes; the aggregate is the read side of that same contract.
_ISSUE_PARTITION = "issues"
_ISSUE_FILE = "issues.ndjson"

# The aggregate store partition (its own retention, within the corpus namespace).
_AGG_PARTITION = "issue_aggregates"
_LATEST_KEY = "latest"

_DAY_SECONDS = 86400  # UTC day length (epoch 0 == UTC midnight); parity with cp_corpus_aggregate.


def _utc_day(now):
    """The UTC calendar-day ordinal for `now` (floor(now/86400))."""
    if not isinstance(now, (int, float)):
        return 0
    return int(now // _DAY_SECONDS)


def _agg_rel(day_key):
    """The store-relative path of one day's aggregate record: issue_aggregates/<day>.json."""
    return os.path.join(_AGG_PARTITION, "%s.json" % day_key)


def _latest_rel():
    """The store-relative path of the newest published aggregate: issue_aggregates/latest.json."""
    return os.path.join(_AGG_PARTITION, "%s.json" % _LATEST_KEY)


# ── the store READ path (INV-G — the isolated corpus namespace, per-team) ───────


def _backend(home=None):
    """The ISOLATED corpus StateBackend — REUSE cp_corpus._backend so the issue
    store lives in the SAME disjoint keyspace as the corpus (never the control-plane
    store). This is the store-isolation seam (INV-G): the backend can never resolve
    a control-plane rel. `home` pins the store root exactly as every CP accessor's
    `home=` threads through."""
    return cp_corpus._backend(home)


def _issue_rel(team_hash):
    """The store-relative issue log path for a team: issues/<team_hash>/issues.ndjson.
    The team_hash is slugged with the SAME cp_corpus._slug so a path segment is
    filesystem-/firestore-safe (no '__' doc-id collision)."""
    return os.path.join(_ISSUE_PARTITION, cp_corpus._slug(team_hash), _ISSUE_FILE)


def list_issue_teams(home=None):
    """The SORTED team_id_hash partition slugs present in the issue store (the teams
    that have pushed issues). Read-only; an absent store yields [] (honest empty).
    Backend-safe: list_names + exists (never backend.path() — firestore-safe)."""
    backend = _backend(home)
    names = []
    for name in backend.list_names(_ISSUE_PARTITION):
        if backend.exists(os.path.join(_ISSUE_PARTITION, name, _ISSUE_FILE)):
            names.append(name)
    return names


def read_team_issues(team_hash, home=None):
    """Stream one team's stored issue_v1 records (the aggregate's per-team scan).
    Tolerant: a bad line is skipped, an absent partition yields []. Read-only."""
    return _backend(home).read_lines(_issue_rel(team_hash))


def all_issues(home=None):
    """Every stored issue_v1 across every team partition (the aggregate's store-wide
    fold). Each record carries its server-stamped team_id_hash, so a reader can
    bucket + count distinct teams for the k-anon gate. Read-only — never writes,
    never executes, never crosses the namespace."""
    out = []
    for team in list_issue_teams(home=home):
        out.extend(read_team_issues(team, home=home))
    return out


# ── security exclusion (INV-F — never in the public aggregate, at any k) ────────


def _is_security_sensitive(rec):
    """True iff a record must be EXCLUDED from the public aggregate (INV-F). The
    stamped `security_sensitive` flag is authoritative; a coded error_class in the
    security taxonomy is a fail-closed belt on top of it (so a record whose flag was
    dropped on the wire still cannot smuggle a security signature into the feed)."""
    if not isinstance(rec, dict):
        return False
    if rec.get("security_sensitive") is True:
        return True
    signal = rec.get("signal") if isinstance(rec.get("signal"), dict) else {}
    ec = str(signal.get("error_class") or rec.get("error_class") or "").strip().lower()
    return ec in issue_corpus._SECURITY_CLASSES


# ── the signature-bucket key + dimension keys ──────────────────────────────────


def _signature_key(rec):
    """The published SIGNATURE-BUCKET key (INV-B): (error_class, signature_hash,
    hmd_version, os_class, command|phase) joined with '|'. command is preferred;
    when it is absent/'unknown' the phase stands in (the 'command|phase' seam)."""
    signal = rec.get("signal") if isinstance(rec.get("signal"), dict) else {}
    env = rec.get("env") if isinstance(rec.get("env"), dict) else {}
    error_class = signal.get("error_class") or "unknown"
    sig = signal.get("signature_hash") or "unknown"
    hmd_version = env.get("hmd_version") or "unknown"
    os_class = env.get("os_class") or "unknown"
    command = signal.get("command") or "unknown"
    phase = signal.get("phase") or "unknown"
    cmd_or_phase = command if command != "unknown" else phase
    return "|".join([str(error_class), str(sig), str(hmd_version), str(os_class),
                     str(cmd_or_phase)])


def _error_class_key(rec):
    signal = rec.get("signal") if isinstance(rec.get("signal"), dict) else {}
    ec = signal.get("error_class") or rec.get("error_class")
    return ec if ec else None


def _gate_key(rec):
    signal = rec.get("signal") if isinstance(rec.get("signal"), dict) else {}
    gate = signal.get("gate")
    return gate if gate else None


# ── the per-bucket publish (k-anon gate DELEGATED to issue_corpus, then metrics) ─


def _publish_bucket(records, k_min):
    """Project a bucket's records to their PUBLISHED shape — OR the SUPPRESSION
    marker when the distinct-team count is below `k_min`. The k-anon decision is
    DELEGATED to issue_corpus.suppress_if_rare (the single source of the rule): a
    suppressed bucket carries NO metrics, only {suppressed, reason, k_min, teams};
    a published bucket carries its coded-field distributions + its (>= k_min)
    distinct-team count. Distinct-team count, never row count."""
    gate = issue_corpus.suppress_if_rare(records, k=k_min)
    if gate.get("suppressed"):
        # THE HARD GATE — metrics are NEVER emitted for a sub-threshold bucket.
        return {"suppressed": True, "reason": gate.get("reason", "k_anonymity"),
                "k_min": k_min, "teams": gate.get("teams", 0)}
    teams = gate.get("teams", 0)
    n = 0
    severity = {}
    error_classes = {}
    gates = {}
    ci_true = 0
    for r in records:
        if not isinstance(r, dict):
            continue
        n += 1
        signal = r.get("signal") if isinstance(r.get("signal"), dict) else {}
        env = r.get("env") if isinstance(r.get("env"), dict) else {}
        sev = signal.get("severity")
        if sev:
            severity[sev] = severity.get(sev, 0) + 1
        ec = signal.get("error_class") or r.get("error_class")
        if ec:
            error_classes[ec] = error_classes.get(ec, 0) + 1
        g = signal.get("gate")
        if g:
            gates[g] = gates.get(g, 0) + 1
        if env.get("ci") is True:
            ci_true += 1
    return {
        "suppressed": False,
        "teams": teams,
        "n": n,
        "severity_distribution": severity,
        "error_class_distribution": error_classes,
        "gate_distribution": gates,
        "ci_rate": round(ci_true / n, 4) if n else None,
    }


# ── compute_issue_aggregates — the pure rollup with the per-bucket k-anon gate ──


def compute_issue_aggregates(issues, *, k_min=None, now=None):
    """Roll UP a list of issue_v1 records into the published aggregate (pure — no IO,
    no model call). Security_sensitive records are EXCLUDED first (INV-F) — counted,
    never folded. Buckets:
      • overall               — one bucket over every non-security record ('all').
      • by_signature[key]     — the (error_class, signature_hash, hmd_version,
                                os_class, command|phase) SIGNATURE bucket (INV-B).
      • by_error_class[class] — the per-error-class breakdown.
      • by_gate[gate]         — the per-failing-gate breakdown.
    EVERY bucket passes through the HARD k-anon gate (_publish_bucket -> issue_corpus.
    suppress_if_rare): a bucket with fewer than `k_min` (default
    issue_corpus.ISSUE_K_ANONYMITY_MIN = 10) DISTINCT team_id_hash is SUPPRESSED — no
    metrics, only a marker. Returns the published aggregate dict."""
    km = k_min if isinstance(k_min, int) and k_min > 0 else issue_corpus.ISSUE_K_ANONYMITY_MIN
    overall = []
    by_signature = {}
    by_error_class = {}
    by_gate = {}
    all_teams = set()
    total = 0
    excluded_security = 0
    for rec in (issues or []):
        if not isinstance(rec, dict):
            continue
        if _is_security_sensitive(rec):
            # INV-F — a security_sensitive signal NEVER enters the public aggregate,
            # regardless of k / team count. Counted (shape only), never folded.
            excluded_security += 1
            continue
        total += 1
        all_teams.add(_team_of(rec))
        overall.append(rec)
        by_signature.setdefault(_signature_key(rec), []).append(rec)
        ec = _error_class_key(rec)
        if ec:
            by_error_class.setdefault(ec, []).append(rec)
        g = _gate_key(rec)
        if g:
            by_gate.setdefault(g, []).append(rec)

    def _publish_dim(buckets):
        return {key: _publish_bucket(recs, km) for key, recs in sorted(buckets.items())}

    dimensions = {
        "overall": {"all": _publish_bucket(overall, km)},
        "by_signature": _publish_dim(by_signature),
        "by_error_class": _publish_dim(by_error_class),
        "by_gate": _publish_dim(by_gate),
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
        "schema": "issue_aggregate_v1",
        "generated_ts": float(now) if isinstance(now, (int, float)) else time.time(),
        "k_min": km,
        "total_issues": total,
        "total_teams": len([t for t in all_teams if t is not None]),
        "excluded_security": excluded_security,
        "published_buckets": published,
        "suppressed_buckets": suppressed,
        "dimensions": dimensions,
    }


def _team_of(rec):
    """The team_id_hash of ONE record — flat (post-ingest stamp) or nested
    (ids.team_id_hash), mirroring issue_corpus.bucket_distinct_teams so the aggregate
    counts the same distinct-team set the k-anon primitive does."""
    tih = rec.get("team_id_hash")
    if not tih and isinstance(rec.get("ids"), dict):
        tih = rec["ids"].get("team_id_hash")
    return tih


# ── run_daily_aggregate — read the store, roll up, STORE the day's aggregate ────


def run_daily_aggregate(*, home=None, now=None, k_min=None):
    """THE daily issue-aggregate job. Read EVERY stored issue_v1 from the isolated
    corpus namespace (all_issues), roll it up (compute_issue_aggregates — with the
    per-bucket k-anon gate + the INV-F security exclusion), and STORE the result as
    the UTC-day aggregate record + refresh issue_aggregates/latest.json, both in the
    CORPUS namespace (its own retention, never the control-plane store). Returns the
    published aggregate (also stored). DATA only — reads + writes records, dispatches
    nothing, makes no model call. Idempotent per UTC day (re-running overwrites)."""
    when = now if now is not None else time.time()
    issues = all_issues(home=home)
    agg = compute_issue_aggregates(issues, k_min=k_min, now=when)
    agg["utc_day"] = _utc_day(when)
    backend = _backend(home)
    # Store the day-keyed record + refresh latest (both in the corpus namespace,
    # firestore-safe put_record — never backend.path()).
    backend.put_record(_agg_rel(_utc_day(when)), agg)
    backend.put_record(_latest_rel(), agg)
    return agg


def latest_aggregate(home=None):
    """Read the most-recently published aggregate (issue_aggregates/latest.json) from
    the corpus namespace, or None when none has been computed yet. Every bucket in it
    has ALREADY passed the k-anon gate at compute time, so a reader can never see a
    sub-threshold cell's metrics."""
    return _backend(home).get_record(_latest_rel())


def read_aggregate(day_key, home=None):
    """Read one UTC-day's published aggregate record, or None when absent. Read-only."""
    return _backend(home).get_record(_agg_rel(day_key))


# ── CLI (manual / cron run — mirrors cp_corpus_aggregate's __main__) ────────────


def _cli(argv):
    """CLI core: `cp_issue_aggregate.py run [--home DIR] [--k-min N]` computes +
    stores today's issue aggregate and prints it; `latest [--home DIR]` prints the
    newest stored aggregate. A cron / the scheduler invokes `run` once a day. Prints
    JSON; returns an exit code."""
    import argparse
    p = argparse.ArgumentParser(prog="cp_issue_aggregate")
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
