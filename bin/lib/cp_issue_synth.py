#!/usr/bin/env python3
# cp_issue_synth.py — THE ISSUE SHADOW-SYNTHESIS LOOP (anonymized-issue-collection, Wave 2).
#
# WHAT THIS IS: the SHADOW support-floor for the anonymized-issue path — the exact role
# cp_corpus_synth plays for the pre-merge corpus, but over the issue_v1 signal stream.
# The ingested issue store (issues/<team_hash>/issues.ndjson in the ISOLATED corpus
# namespace) is a per-team stream of ZERO-CONTENT issue signals (a coded error_class + a
# HASHED signature + coded gate/phase/command/severity/os_class/hmd_version). This job
# CLUSTERS those signals and PROPOSES candidate issues for a maintainer to triage — but
# it is SHADOW ONLY: observe-and-propose, it NEVER auto-opens a GitHub issue and NEVER
# enforces anything. It appends proposals to a review queue a human promotes out of band.
#
# WHY IT EXISTS (the "shadow-synth support floor"): the synthesis lets the aggregate be
# exercised + validated WITHOUT exposing sub-threshold real data. Because a candidate is
# emitted ONLY for a signature cluster that clears the k-anon distinct-team floor, a rare
# error-signature (seen by fewer than ISSUE_K_ANONYMITY_MIN teams) is NEVER surfaced as a
# served proposal — the k-anon guarantee is upheld THROUGH synth (INV-B), not just at the
# aggregate publish boundary.
#
# THE PRIVACY LINE IS ABSOLUTE — and REUSED, NOT REBUILT (mirrors cp_corpus_synth):
#   * issue_corpus.suppress_if_rare / .ISSUE_K_ANONYMITY_MIN — the ONE k-anon primitive,
#     defined once in the emit lib and IMPORTED here so emit-side + synth can never
#     disagree. Distinct-team count, never row count (100 issues from one team is a cohort
#     of ONE and MUST suppress).
#   * cp_corpus._backend / ._slug — the ISOLATED corpus StateBackend (INV-G). The issue
#     store + the proposal queue live under the corpus namespace (pmr_corpus.corpus_
#     namespace()), a DISJOINT keyspace from the control-plane presence/ops store. We
#     REUSE that isolation seam by import — the #4/#10 gated modules stay byte-for-byte
#     green (we add a file, we do not edit them).
#
# INV-F — SECURITY-SENSITIVE IS NEVER SYNTHESIZED. A record flagged security_sensitive is
# EXCLUDED before it can enter a cluster, at ANY team count. A security signal therefore
# never becomes a synth candidate, never lands in the public review queue — regardless of
# how many teams hit it. (The ingest boundary already drops security records fail-closed;
# this is defense-in-depth at the synth boundary.)
#
# NO ISSUE CONTENT IN A PROPOSAL (privacy-first, mirrors cp_corpus_synth). A proposal is
# SHAPE: the coded pattern + support COUNTS + referenced issue_ids (non-secret handles).
# It NEVER copies the underlying records into the queue — so a re-exposure of sub-threshold
# real data downstream is structurally impossible.
#
# BYO-INFERENCE — NO MODEL CALL. The synthesis is PURELY HEURISTIC/STATISTICAL: it counts
# coded signature clusters + their distinct-team support. No LLM, no model client, nothing
# sent to an inference endpoint. Clustering coded tags is arithmetic, not generation.
#
# stdlib-only (json/os/sys/time/hashlib) + cp_corpus (the ISOLATED backend + slug) +
# issue_corpus (the k-anon primitive + policy constants) — the SAME dependency shape every
# CP job has. This module DOES NOT touch cp_corpus*.py / pmr_corpus.py / issue_corpus.py;
# it imports them.

from __future__ import annotations

import hashlib
import json
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_corpus      # the ISOLATED corpus backend (_backend) + the path slug (_slug).
import issue_corpus   # the k-anon primitive (suppress_if_rare) + ISSUE_K_ANONYMITY_MIN.

# ── store layout (WITHIN the isolated corpus namespace — INV-G) ─────────────────

# The ingested issue store partition the aggregate + synth read (cp_issue_ingest writes
# it, INV-G): issues/<team_hash>/issues.ndjson — per-team-partitioned, keyspace-disjoint
# from the control-plane store.
_ISSUES_PARTITION = "issues"
_ISSUES_FILE = "issues.ndjson"

# The shadow-proposal review queue partition (its own retention). Append-only; a human
# reads it to decide what to triage/promote — this loop only proposes.
_PROPOSALS_PARTITION = "issue_proposals"
_QUEUE_FILE = "queue.ndjson"

# The proposal record schema tag — a SHADOW candidate, never an enforced/auto-opened issue.
_PROPOSAL_SCHEMA = "shadow_issue_v1"

# The min DISTINCT-team support override (default issue_corpus.ISSUE_K_ANONYMITY_MIN = 10).
_MIN_TEAMS_ENV = "HEIMDALL_ISSUE_SYNTH_MIN_TEAMS"


def min_teams():
    """The min distinct-team support a signature cluster needs before it becomes a
    candidate proposal (HEIMDALL_ISSUE_SYNTH_MIN_TEAMS, default the imported k-anon floor
    issue_corpus.ISSUE_K_ANONYMITY_MIN). A malformed / non-positive override falls back to
    the default so a misconfig never disables the floor (fail-safe toward MORE privacy)."""
    raw = os.environ.get(_MIN_TEAMS_ENV)
    try:
        val = int(raw) if raw not in (None, "") else issue_corpus.ISSUE_K_ANONYMITY_MIN
    except (TypeError, ValueError):
        return issue_corpus.ISSUE_K_ANONYMITY_MIN
    return val if val > 0 else issue_corpus.ISSUE_K_ANONYMITY_MIN


# ── the ISOLATED read path (mirrors cp_corpus.list_teams / all_pmrs) ────────────


def _backend(home=None):
    """The ISOLATED corpus StateBackend (the corpus namespace — INV-G). REUSED from
    cp_corpus so the issue store + proposal queue share the corpus's disjoint keyspace and
    can never resolve a control-plane rel. `home` pins the store root for a hermetic run."""
    return cp_corpus._backend(home)


def _issues_rel(team_hash):
    """The store-relative issue log path for a team: issues/<team_hash>/issues.ndjson.
    Slugged with cp_corpus._slug (the canonical corpus-namespace slug) so the partition
    matches the one cp_issue_ingest writes."""
    return os.path.join(_ISSUES_PARTITION, cp_corpus._slug(team_hash), _ISSUES_FILE)


def _queue_rel():
    """The store-relative path of the shadow proposal review queue."""
    return os.path.join(_PROPOSALS_PARTITION, _QUEUE_FILE)


def list_issue_teams(home=None):
    """The SORTED team_id_hash partition slugs present in the issue store (the teams that
    have pushed a signal). Read-only; an absent store yields [] (honest empty). Backend-safe
    (list_names + exists — never backend.path(), so it is firestore-safe)."""
    backend = _backend(home)
    names = []
    for name in backend.list_names(_ISSUES_PARTITION):
        if backend.exists(os.path.join(_ISSUES_PARTITION, name, _ISSUES_FILE)):
            names.append(name)
    return names


def read_team_issues(team_hash, home=None):
    """Stream one team's stored issue signals (the synth per-team scan). Tolerant: a bad
    line is skipped, an absent partition yields []. Read-only — never writes, never runs."""
    return _backend(home).read_lines(_issues_rel(team_hash))


def all_issues(home=None):
    """Every stored issue signal across every team partition (the synth's corpus-wide
    fold). Each record carries its server-stamped team_id_hash, so a reader can cluster +
    count distinct teams for the k-anon floor. Read-only."""
    out = []
    for team in list_issue_teams(home=home):
        out.extend(read_team_issues(team, home=home))
    return out


# ── the coded cluster key (the INV-B signature bucket — SHAPE, never content) ───


def _cluster_key(issue):
    """The coded signature-bucket key an issue contributes to (INV-B):
    (error_class, signature_hash, hmd_version, os_class, command|phase). Every part is a
    coded token or a non-reversible hash already on the zero-content record — so the key
    is SHAPE, never content. A missing part is 'unknown' so every issue clusters somewhere;
    command falls back to phase (a coarser locator) before 'unknown'."""
    signal = issue.get("signal") if isinstance(issue.get("signal"), dict) else {}
    env = issue.get("env") if isinstance(issue.get("env"), dict) else {}
    return (
        signal.get("error_class") or "unknown",
        signal.get("signature_hash") or "unknown",
        env.get("hmd_version") or "unknown",
        env.get("os_class") or "unknown",
        signal.get("command") or signal.get("phase") or "unknown",
    )


def _issue_id(issue):
    """The non-secret issue handle (ids.issue_id, or a flat issue_id fallback)."""
    ids = issue.get("ids") if isinstance(issue.get("ids"), dict) else {}
    return ids.get("issue_id") or issue.get("issue_id")


def _proposal_id(key):
    """A stable proposal id for a cluster key (so a re-run does not mint a new id for the
    same signature — a queue reader dedupes on it). Derived from the coded key only."""
    raw = ("shadow-issue\x00" + "|".join(key)).encode("utf-8")
    return "shadow-iss-" + hashlib.sha256(raw).hexdigest()[:20]


# ── synthesize_proposals — the PURE fold (no IO, no model call) ─────────────────


def synthesize_proposals(issues, *, min_teams=None, now=None):
    """Cluster ingested issue signals into candidate SHADOW proposals (pure — no IO, NO
    model call). Folds each NON-security issue into its coded signature cluster, and emits
    ONE proposal per cluster whose DISTINCT-team support clears the k-anon floor (via the
    imported issue_corpus.suppress_if_rare — the SINGLE k-anon source). EVERY proposal is
    SHADOW: status 'pending_review', enforced False, and carries ONLY the coded pattern +
    support counts + sample issue_ids — never the underlying records.

    THE THREE PRIVACY GUARANTEES upheld here:
      INV-F  a security_sensitive record is EXCLUDED before clustering — never a candidate,
             at ANY team count.
      INV-B  a cluster below the floor contributes NOTHING (suppress_if_rare marks it
             suppressed) — a rare/sub-k signature is never surfaced as a served proposal.
      RJ#2   pending_review + enforced=False — SHADOW-first, never auto-opened.

    Returns the sorted list of proposal dicts."""
    floor = min_teams if isinstance(min_teams, int) and min_teams > 0 else globals()["min_teams"]()
    when = float(now) if isinstance(now, (int, float)) else time.time()
    clusters = {}
    for issue in (issues or []):
        if not isinstance(issue, dict):
            continue
        # INV-F — a security-sensitive signal is NEVER a synth candidate (excluded before
        # it can enter a cluster), regardless of team count.
        if issue.get("security_sensitive"):
            continue
        key = _cluster_key(issue)
        c = clusters.setdefault(key, {"records": [], "issue_ids": [], "count": 0})
        c["records"].append(issue)
        c["count"] += 1
        iid = _issue_id(issue)
        if iid and iid not in c["issue_ids"] and len(c["issue_ids"]) < 10:
            c["issue_ids"].append(iid)

    proposals = []
    for key, c in sorted(clusters.items()):
        # INV-B — the k-anon gate, via the IMPORTED single-source primitive. A cluster below
        # the floor is SUPPRESSED and contributes NOTHING (never a proposal). Only the team
        # COUNT is read from the cleared result — the records themselves are never emitted.
        gate = issue_corpus.suppress_if_rare(c["records"], floor)
        if gate.get("suppressed"):
            continue
        teams = gate.get("teams", 0)
        error_class, signature_hash, hmd_version, os_class, command = key
        proposals.append({
            "schema_version": _PROPOSAL_SCHEMA,
            "proposal_id": _proposal_id(key),
            "created_ts": when,
            # SHADOW — observe-only. A maintainer promotes it out of band; this loop NEVER
            # auto-opens a GitHub issue and NEVER enforces. These two fields are the proof.
            "status": "pending_review",
            "enforced": False,
            "pattern": {
                "error_class": error_class,
                "signature_hash": signature_hash,
                "hmd_version": hmd_version,
                "os_class": os_class,
                "command": command,
            },
            "support": {"issues": c["count"], "teams": teams},
            "sample_issue_ids": list(c["issue_ids"]),
            "candidate": (
                "SHADOW: %d teams hit error_class=%s signature=%s at command=%s "
                "(hmd_version=%s, os_class=%s) — candidate issue to TRIAGE (shadow only, "
                "NOT auto-opened, NOT enforced)."
                % (teams, error_class, signature_hash, command, hmd_version, os_class)),
        })
    return proposals


# ── run_synthesis — read the isolated store, synthesize, APPEND the queue ────────


def run_synthesis(*, home=None, now=None, min_teams=None):
    """THE issue shadow-synthesis job. Read EVERY stored issue signal from the ISOLATED
    corpus (all_issues), synthesize candidate shadow proposals (synthesize_proposals — with
    the k-anon floor + the security exclusion), and APPEND each to the review queue
    (issue_proposals/queue.ndjson in the corpus namespace). Returns a summary
    {generated_ts, issues_read, proposals, min_teams}. SHADOW — it writes proposals ONLY;
    it enforces nothing, auto-opens nothing, dispatches nothing, and makes no model call.
    Idempotent-ish: proposal ids are stable per signature, so a queue reader dedupes on
    proposal_id (a re-run appends a fresh snapshot; the id lets the reader collapse dupes)."""
    when = now if now is not None else time.time()
    floor = min_teams if isinstance(min_teams, int) and min_teams > 0 else globals()["min_teams"]()
    issues = all_issues(home=home)
    proposals = synthesize_proposals(issues, min_teams=floor, now=when)
    backend = _backend(home)
    rel = _queue_rel()
    for prop in proposals:
        backend.append_line(rel, prop, fsync=False)
    return {
        "generated_ts": float(when) if isinstance(when, (int, float)) else time.time(),
        "issues_read": len(issues),
        "proposals": len(proposals),
        "min_teams": floor,
    }


def list_proposals(home=None):
    """Read the shadow proposal review queue from the corpus namespace. Tolerant: a bad
    line is skipped, an absent queue yields []. Read-only. Every record is a shadow
    candidate (enforced=False) — a maintainer reads THIS to decide what to promote."""
    return _backend(home).read_lines(_queue_rel())


# ── CLI (manual / cron run — mirrors cp_corpus_synth's __main__) ────────────────


def _cli(argv):
    """CLI core: `cp_issue_synth.py run [--home DIR] [--min-teams N]` reads the isolated
    issue store, synthesizes the shadow proposals, appends them to the review queue, and
    prints the summary; `list [--home DIR]` prints the current queue. Prints JSON."""
    import argparse
    p = argparse.ArgumentParser(prog="cp_issue_synth")
    p.add_argument("subcommand", choices=("run", "list"))
    p.add_argument("--home")
    p.add_argument("--min-teams", dest="min_teams", type=int)
    args = p.parse_args(argv)
    if args.subcommand == "run":
        print(json.dumps(run_synthesis(home=args.home, min_teams=args.min_teams),
                         indent=2, sort_keys=True))
        return 0
    print(json.dumps(list_proposals(args.home), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
