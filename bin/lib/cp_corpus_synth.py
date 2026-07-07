#!/usr/bin/env python3
# cp_corpus_synth.py — THE RULE-SYNTHESIS SHADOW LOOP (premerge-corpus-spec §4.1 / §5.3).
#
# DESIGN: heimdall-premerge-corpus-spec.md §4.1 (the learned-rules flywheel) + §5.3. The T1
# deny-context corpus (cp_corpus, the heimdall_corpus/ t1 partition) is a stream of failing
# hunks + their coded gate reasons. This job CLUSTERS those deny-contexts and PROPOSES candidate
# learned-rules — but it is SHADOW ONLY: observe-and-propose, it does NOT gate anything. It
# writes proposals to a REVIEW QUEUE a maintainer inspects; nothing here ever enforces a rule.
#
# SHADOW = OBSERVE-AND-PROPOSE, NEVER ENFORCE (the standing rule, spec §4.1 "shadow gates"). The
# module has NO path into any gate, dispatcher, or handler. It reads T1, folds coded clusters,
# and appends proposal records with enforced=false / status="pending_review". A human promotes a
# proposal to a real gate LATER, out of band — this loop never does. THE FALSIFIER: a proposal
# record carrying enforced=true, or any call from here into a gate/dispatch, is a RED test.
#
# BYO-INFERENCE — NO MODEL CALL ON heimdall-cp-prod (a standing invariant). The synthesis is
# PURELY HEURISTIC/STATISTICAL: it counts coded (deny_reason, gate, lang) clusters and their
# distinct-team support. It makes NO LLM call, imports no model client, and sends nothing to an
# inference endpoint. Clustering coded tags is arithmetic, not generation.
#
# NO HUNK CONTENT IN A PROPOSAL (privacy-first). A proposal is SHAPE: the coded pattern + support
# COUNTS + referenced pmr_ids (non-secret handles). It NEVER copies a hunk's diff bytes into the
# review queue — a reviewer pulls the underlying T1 hunks from the corpus if needed. So the
# review queue stays free of source content, and the secret-scan boundary (cp_corpus ingest)
# already guarantees no secret ever reached T1 in the first place.
#
# MIN SUPPORT — a proposal is emitted only for a cluster with >= HEIMDALL_CORPUS_SYNTH_MIN_TEAMS
# DISTINCT teams (default the k-anonymity floor, pmr_corpus.K_ANONYMITY_MIN), so a candidate rule
# never encodes a pattern seen by only a handful of teams (defense-in-depth privacy, matching the
# aggregate k-anonymity discipline). Env-tunable.
#
# STORE: proposals land in the CORPUS namespace (its own retention): proposals/queue.ndjson (an
# append-only review queue). Written THROUGH the isolated corpus backend (cp_corpus._backend),
# firestore-durable, NEVER backend.path() (every op is append_line/read_lines — firestore-safe).
#
# stdlib-only (json/os/sys/time/hashlib) + cp_corpus (the T1 read path + the isolated backend) +
# pmr_corpus (the min-support floor) — the SAME dependency shape every CP job has.

from __future__ import annotations

import hashlib
import json
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_corpus    # the T1 READ path (all_hunks) + the ISOLATED corpus backend (_backend).
import pmr_corpus   # K_ANONYMITY_MIN — the default min-team support floor for a proposal.

# The review-queue partition (WITHIN the corpus namespace) — its own retention policy.
_PROPOSALS_PARTITION = "proposals"
_QUEUE_FILE = "queue.ndjson"

# The proposal record schema tag — a shadow candidate, NEVER an enforced rule.
_PROPOSAL_SCHEMA = "shadow_rule_v1"

# The min DISTINCT-team support for a cluster to become a proposal (defense-in-depth privacy).
_MIN_TEAMS_ENV = "HEIMDALL_CORPUS_SYNTH_MIN_TEAMS"


def _min_teams():
    """The min distinct-team support a deny-context cluster needs before it becomes a candidate
    proposal (HEIMDALL_CORPUS_SYNTH_MIN_TEAMS, default pmr_corpus.K_ANONYMITY_MIN). A malformed /
    non-positive override falls back to the default so a misconfig never disables the floor."""
    raw = os.environ.get(_MIN_TEAMS_ENV)
    try:
        val = int(raw) if raw not in (None, "") else pmr_corpus.K_ANONYMITY_MIN
    except (TypeError, ValueError):
        return pmr_corpus.K_ANONYMITY_MIN
    return val if val > 0 else pmr_corpus.K_ANONYMITY_MIN


def _queue_rel():
    """The store-relative path of the shadow proposal review queue: proposals/queue.ndjson."""
    return os.path.join(_PROPOSALS_PARTITION, _QUEUE_FILE)


def _cluster_key(hunk):
    """The coded cluster key a T1 hunk contributes to: (deny_reason, gate, lang). All three are
    coded tags (scrubbed at ingest), never free text — so the key is SHAPE, never content. A
    missing part is 'unknown' so every hunk clusters somewhere."""
    return (
        hunk.get("deny_reason") or "unknown",
        hunk.get("gate") or "unknown",
        hunk.get("lang") or "unknown",
    )


def _proposal_id(key):
    """A stable proposal id for a cluster key (so re-running does not mint a new id for the same
    pattern — the queue reader can dedupe on it). Derived from the coded key only."""
    raw = ("shadow-rule\x00" + "|".join(key)).encode("utf-8")
    return "shadow-" + hashlib.sha256(raw).hexdigest()[:20]


def synthesize_proposals(hunks, *, min_teams=None, now=None):
    """Cluster T1 deny-context hunks into candidate SHADOW rules (pure — no IO, NO model call).
    Folds each hunk into its coded (deny_reason, gate, lang) cluster, counts occurrences +
    DISTINCT team support + sample pmr_ids, and emits ONE proposal per cluster whose distinct-team
    support meets `min_teams` (default the k-anonymity floor). EVERY proposal is SHADOW: status
    'pending_review', enforced False, no hunk content — only the coded pattern + support counts +
    referenced pmr_ids. Returns the sorted list of proposal dicts. A cluster below the support
    floor contributes NOTHING (it is not proposed — defense-in-depth privacy)."""
    floor = min_teams if isinstance(min_teams, int) and min_teams > 0 else _min_teams()
    when = float(now) if isinstance(now, (int, float)) else time.time()
    clusters = {}
    for hunk in (hunks or []):
        if not isinstance(hunk, dict):
            continue
        key = _cluster_key(hunk)
        c = clusters.setdefault(key, {"hunks": 0, "teams": set(), "pmr_ids": []})
        c["hunks"] += 1
        c["teams"].add(hunk.get("team_id_hash"))
        pid = hunk.get("pmr_id")
        if pid and pid not in c["pmr_ids"] and len(c["pmr_ids"]) < 10:
            c["pmr_ids"].append(pid)
    proposals = []
    for key, c in sorted(clusters.items()):
        teams = len([t for t in c["teams"] if t is not None])
        if teams < floor:
            # BELOW the support floor — never proposed (a rule must not encode a few-team pattern).
            continue
        deny_reason, gate, lang = key
        proposals.append({
            "schema_version": _PROPOSAL_SCHEMA,
            "proposal_id": _proposal_id(key),
            "created_ts": when,
            # SHADOW — this candidate is observe-only. A human promotes it to a real gate later,
            # out of band; this loop NEVER enforces. These two fields are the falsifiable proof.
            "status": "pending_review",
            "enforced": False,
            "pattern": {"deny_reason": deny_reason, "gate": gate, "lang": lang},
            "support": {"hunks": c["hunks"], "teams": teams},
            "sample_pmr_ids": list(c["pmr_ids"]),
            # A human-readable CODED description — no hunk content, just the pattern + a suggested
            # shadow watch. The maintainer decides whether to promote it; the corpus proposes only.
            "candidate_rule": (
                "SHADOW: %d teams hit deny=%s at gate=%s in lang=%s — candidate learned-rule to "
                "watch (shadow only, NOT enforced)." % (teams, deny_reason, gate, lang)),
        })
    return proposals


def run_synthesis(*, home=None, now=None, min_teams=None):
    """THE rule-synthesis SHADOW job (spec §5.3). Read EVERY stored T1 hunk from the isolated
    corpus (cp_corpus.all_hunks), synthesize candidate shadow rules (synthesize_proposals), and
    APPEND each to the review queue (proposals/queue.ndjson in the corpus namespace). Returns a
    summary {generated_ts, hunks_read, proposals, min_teams}. SHADOW — it writes proposals ONLY;
    it enforces nothing, dispatches nothing, and makes no model call (BYO-inference, heuristic
    clustering). Idempotent-ish: proposal ids are stable per pattern, so a queue reader dedupes on
    proposal_id (a re-run appends a fresh snapshot; the id lets the reader collapse duplicates)."""
    when = now if now is not None else time.time()
    hunks = cp_corpus.all_hunks(home=home)
    proposals = synthesize_proposals(hunks, min_teams=min_teams, now=when)
    backend = cp_corpus._backend(home)
    rel = _queue_rel()
    for prop in proposals:
        backend.append_line(rel, prop, fsync=False)
    return {
        "generated_ts": float(when) if isinstance(when, (int, float)) else time.time(),
        "hunks_read": len(hunks),
        "proposals": len(proposals),
        "min_teams": min_teams if isinstance(min_teams, int) and min_teams > 0 else _min_teams(),
    }


def list_proposals(home=None):
    """Read the shadow proposal review queue (proposals/queue.ndjson) from the corpus namespace.
    Tolerant: a bad line is skipped, an absent queue yields []. Read-only. Every record is a
    shadow candidate (enforced=False) — a maintainer reads THIS to decide what to promote."""
    return cp_corpus._backend(home).read_lines(_queue_rel())


# ── CLI (manual / cron run — mirrors cp_corpus_aggregate's __main__) ────────────


def _cli(argv):
    """CLI core: `cp_corpus_synth.py run [--home DIR] [--min-teams N]` reads T1, synthesizes the
    shadow proposals, appends them to the review queue, and prints the summary; `list [--home DIR]`
    prints the current queue. A cron / the scheduler invokes `run` periodically. Prints JSON."""
    import argparse
    p = argparse.ArgumentParser(prog="cp_corpus_synth")
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
