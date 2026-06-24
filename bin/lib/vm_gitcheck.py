#!/usr/bin/env python3
# vm_gitcheck.py — Verified-Memory git-check engine (VM piece A).
#
# THE LOAD-BEARING NOVELTY (dossier §1/§2): code memory is the special case of
# agent memory where ground truth EXISTS — the repository. So a memory entry's
# staleness is not ESTIMATED by a decay timer or an LLM vote; it is DECIDED by a
# mechanical re-check of the entry's claim against git. This module is that check.
#
# THREE HONEST LAYERS, only the first two live here (§1):
#   • git = TRUTH    — does `commit_ref` exist? do the {path,symbol} refs still
#                      match the claim at HEAD?  A mechanical check, never a vote.
#   • weight = READOUT — a function of the git-check, RECOMPUTED at read, never a
#                      stored decaying number. A stale entry's weight is 0 because
#                      git says so, not because time passed.
#   (human = ESCALATION lives in piece B's reconcile UI; here we only DERIVE the
#    `conflicted` status that routes to it.)
#
# CHEAP AT READ TIME (the dossier's biggest flagged risk): the per-entry verify
# result is cached keyed by (commit_ref + current HEAD sha). HEAD moving
# invalidates the cache (mirrors comprehension's fingerprint). On a slow/failed
# check we FAIL SAFE to `stale` — never block, never assert `live` on a timeout. A
# falsely-live entry is the exact failure mode we are eliminating.
#
# NEVER RAISES (telemetry / attestation graceful-degrade discipline): a git
# failure, a parse failure, or a timeout degrades the entry to an honest `stale`
# with a `reason`, not a crash and never a silent `live`.
#
# REUSE (do not rebuild):
#   • the subprocess-git extraction shape from bin/heimdall-attest:252
#     (`subprocess.run(["git","-C",repo,...])`) — proven git-shell pattern.
#   • treesitter_ast.extract_symbols — the SAME AST substrate SI-2 / redum use for
#     symbol presence; a regex cannot tell a real declaration from a comment.
#
# This is a LIBRARY with a thin argparse CLI (verify | reconcile) used by the
# tests and by piece B (verified_memory.py).

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys

# the AST substrate lives alongside this file (mirror attestation.py's sys.path).
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import treesitter_ast as ts  # noqa: E402 — sibling import after sys.path setup

SCHEMA_VERSION = "vm-1.0"

# the three honest statuses (§2). DERIVED from git, never a stored opinion.
LIVE = "live"
STALE = "stale"
CONFLICTED = "conflicted"

# default git-call budget (seconds). Bounded so the read-time check cannot hang;
# on exceed → fail safe to STALE (§Risks: "fall back to stale on timeout").
DEFAULT_TIMEOUT = 5.0


# ── git plumbing (the bin/heimdall-attest:252 extraction shape, reused) ───────


class _GitTimeout(Exception):
    """Raised when a git call exceeds the bounded budget. Caught by verify() and
    turned into an honest STALE (fail-safe), never allowed to escape."""


def _git(repo, args, timeout):
    """Run `git -C <repo> <args...>` with a bounded timeout. Returns
    (stdout_str, returncode). Reuses the proven attest:252 subprocess shape. A
    timeout raises _GitTimeout (caught upstream → STALE). Any other OSError is
    surfaced as a non-zero returncode so callers degrade rather than crash."""
    try:
        p = subprocess.run(
            ["git", "-C", repo, *args],
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise _GitTimeout("git %s exceeded %.3fs budget" % (args[0], timeout))
    except OSError as exc:  # git missing / repo unreadable → degrade, never crash
        return ("", 128 if "No such" not in str(exc) else 127)
    return (p.stdout.decode("utf-8", "replace"), p.returncode)


def head_sha(repo, timeout=DEFAULT_TIMEOUT):
    """The current HEAD commit sha (full), or "" if it cannot be resolved (empty
    repo / not a git dir). Part of the cache key — when this moves, the cache for
    every entry invalidates."""
    out, rc = _git(repo, ["rev-parse", "HEAD"], timeout)
    return out.strip() if rc == 0 else ""


def _commit_exists(repo, commit_ref, timeout):
    """True iff `commit_ref` resolves to a real commit object in the repo.
    `git cat-file -e <ref>^{commit}` — the exact §2 step-1 check."""
    if not commit_ref:
        return False
    _out, rc = _git(repo, ["cat-file", "-e", "%s^{commit}" % commit_ref], timeout)
    return rc == 0


def _file_at_head(repo, path, timeout):
    """The body of `path` at HEAD, or None if the path does not exist at HEAD.
    `git show HEAD:<path>` — reads ground truth from git, not the dirty worktree,
    so the check is deterministic against the committed state."""
    out, rc = _git(repo, ["show", "HEAD:%s" % path], timeout)
    return out if rc == 0 else None


# ── symbol presence (treesitter_ast — the SI-2 AST substrate, reused) ─────────


def _symbol_present(src, path, symbol):
    """True iff `symbol` is declared in `src` at `path`, by the AST substrate.

    Uses treesitter_ast.extract_symbols (the same engine SI-2 / redum use). When
    tree-sitter is unavailable the result degrades to UNKNOWN (None) so the caller
    can fail safe to STALE rather than silently passing a check it never ran — we
    never assert `live` on an un-run check (§2: default-to-stale on uncertainty).

    Returns True / False / None(unknown)."""
    lang = ts.lang_for_path(path)
    if lang is None:
        # not a source language tree-sitter speaks → we cannot prove presence by
        # AST. UNKNOWN, not a silent pass.
        return None
    res = ts.extract(src, lang)
    if not res.available:
        return None  # backend/grammar missing → UNKNOWN → caller fails safe
    return any(s.name == symbol for s in res.symbols)


# ── the mechanical check: verify(entry, repo) -> status (§2) ──────────────────


def _classify(entry, repo, timeout):
    """The pure git-check core. Returns (status, reason) WITHOUT caching or weight.
    Deterministic function of (entry, git state). Never raises — a _GitTimeout is
    converted to STALE here so every path returns an honest status.

    Steps mirror §2 exactly:
      1. commit_ref resolves to a real commit?            no → STALE
      2. for each ref: path exists at HEAD AND symbol declared there?  no → STALE
      3. all refs present + commit live                   → LIVE
    Any uncertainty (unparseable file, missing AST backend, timeout) → STALE."""
    commit_ref = (entry.get("commit_ref") or "").strip()
    refs = entry.get("refs") or []

    try:
        if not _commit_exists(repo, commit_ref, timeout):
            return STALE, "commit_ref %s not found in repo" % (commit_ref or "<empty>")

        for ref in refs:
            path = (ref.get("path") or "").strip()
            symbol = (ref.get("symbol") or "").strip()
            if not path:
                return STALE, "ref missing a path"
            src = _file_at_head(repo, path, timeout)
            if src is None:
                return STALE, "path %s absent at HEAD" % path
            if symbol:
                present = _symbol_present(src, path, symbol)
                if present is None:
                    return STALE, (
                        "could not verify symbol %s in %s (AST unavailable) "
                        "— failing safe to stale" % (symbol, path)
                    )
                if not present:
                    return STALE, "symbol %s no longer declared in %s" % (symbol, path)
    except _GitTimeout as exc:
        return STALE, "git check timed out: %s — failing safe to stale" % exc

    return LIVE, "commit live and all refs present at HEAD"


# ── weight = READOUT recomputed from the git-check (§1, never stored) ─────────


def weight_for(status, entry):
    """The weight is a READOUT of the git-check, recomputed every call — NOT a
    stored decaying number. The rule (§1):

      • status != live  → 0.0   (a stale/conflicted entry is provably worthless
                                  for context; git, not a timer, zeroed it)
      • status == live  → a bounded relevance readout in (0,1]: each surviving ref
                          that still resolves contributes, normalised by ref count,
                          with a floor so any live entry outranks every stale one.

    The stored `entry["weight"]` is IGNORED — this function derives the number from
    liveness, so a deliberately-wrong stored weight cannot leak through."""
    if status != LIVE:
        return 0.0
    refs = entry.get("refs") or []
    n = len(refs)
    if n == 0:
        # a live commit-only claim (no refs) still survives — give it the floor.
        return 0.5
    # all refs are present when LIVE (that is what made it live), so the readout is
    # the full, ref-count-aware relevance: more concrete refs → a stronger anchor,
    # asymptotically approaching 1.0, always strictly above 0.
    return round(0.5 + 0.5 * (n / (n + 1.0)), 6)


# ── read-time cache keyed by (commit_ref + HEAD sha) (§Risks mitigation) ──────


def _cache_key(entry, head):
    """The cache key: (commit_ref + refs-shape + HEAD sha). When HEAD moves the key
    changes → the entry re-derives (no cached hit served for a moved HEAD). refs
    are folded in so two entries sharing a commit_ref but differing refs do not
    collide."""
    refs = entry.get("refs") or []
    refsig = ";".join(
        "%s:%s" % ((r.get("path") or ""), (r.get("symbol") or "")) for r in refs
    )
    raw = "%s|%s|%s" % ((entry.get("commit_ref") or ""), refsig, head)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _cache_path(cache_dir, key):
    return os.path.join(cache_dir, "vmgc-%s.json" % key)


def _cache_get(cache_dir, key):
    """Return the cached (status, reason) for `key`, or None on miss / unreadable
    cache. A corrupt cache entry is a miss (re-derive), never a crash."""
    if not cache_dir:
        return None
    fp = _cache_path(cache_dir, key)
    try:
        with open(fp, "r", encoding="utf-8") as fh:
            rec = json.load(fh)
        return rec.get("status"), rec.get("reason")
    except (OSError, ValueError):
        return None


def _cache_put(cache_dir, key, status, reason):
    """Persist (status, reason) for `key`. Best-effort — a cache write failure
    never affects the returned result (the check already ran). The truth is git,
    not the cache, so a failed write simply forces a re-derive next read."""
    if not cache_dir:
        return
    try:
        os.makedirs(cache_dir, exist_ok=True)
        with open(_cache_path(cache_dir, key), "w", encoding="utf-8") as fh:
            json.dump({"status": status, "reason": reason}, fh)
    except OSError:
        return  # best-effort cache; a write failure is non-fatal


# ── the public verify() — the contract every consumer binds to ────────────────


def verify(entry, repo, timeout=DEFAULT_TIMEOUT, cache_dir=None, force_timeout=False):
    """verify(entry, repo) -> verified-entry dict.

    The contract (consumers bind to THIS):
      input  — `entry`: a MemoryEntry dict (schema vm-1.0; see make_entry).
               `repo`: path to the git repo that is ground truth.
               `timeout`: per-check git budget (s); exceed → fail safe to STALE.
               `cache_dir`: where the read-time cache lives (keyed on HEAD); None
                            disables caching.
               `force_timeout`: test/ops hook — simulate a timed-out check; MUST
                            degrade to STALE, proving the fail-safe (never live).
      output — a COPY of `entry` with the DERIVED fields overwritten from the
               git-check (the stored values are never trusted):
                 status      live | stale  (conflicted is decided by reconcile)
                 weight      the READOUT (0.0 unless live)
                 verified_at when this check ran (UTC, sec-precision)
                 reason      a human one-liner explaining the status
                 cache       {hit: bool, key, head} present when cache-stats asked

    NEVER raises. A timeout / git failure / unparseable file → an honest STALE."""
    out = dict(entry)

    # force-timeout fail-safe hook (§Risks): a timed-out / un-runnable check NEVER
    # asserts live. This branch runs BEFORE any git call so a zero/negative budget
    # cannot even start git — it degrades straight to STALE with a timeout reason.
    if force_timeout or (timeout is not None and timeout <= 0):
        status = STALE
        reason = "git check timeout — budget exhausted, failing safe to stale"
        out["status"] = status
        out["weight"] = weight_for(status, entry)
        out["reason"] = reason
        out["verified_at"] = _now_iso()
        out["cache"] = {"hit": False, "key": None, "head": ""}
        return out

    head = head_sha(repo, timeout)
    key = _cache_key(entry, head)
    cached = _cache_get(cache_dir, key)
    if cached is not None:
        status, reason = cached
        hit = True
    else:
        status, reason = _classify(entry, repo, timeout)
        _cache_put(cache_dir, key, status, reason)
        hit = False

    out["status"] = status
    out["weight"] = weight_for(status, entry)
    out["reason"] = reason
    out["verified_at"] = _now_iso()
    out["cache"] = {"hit": hit, "key": key, "head": head}
    return out


# ── reconcile a conflicting set toward git truth (§3 steps 2–4) ───────────────


def reconcile(entries, repo, timeout=DEFAULT_TIMEOUT, cache_dir=None):
    """Reconcile a set of entries whose refs overlap, toward git truth (§3). git
    wins — entries are claims, git is the referent. Returns a verdict dict:

      { verdict:    auto-resolved | conflicted | empty,
        decided_by: git,
        winner:     the single live survivor (auto-resolved), else None,
        live:       [verified live entries],
        stale:      [verified stale entries, weight 0],
        escalation: present iff conflicted — the git evidence a human needs }

    The two §3 outcomes this engine decides mechanically:
      • all-but-one stale  → AUTO-RESOLVE: the lone live entry wins, the rest are
                             demoted to stale (git decided; no human).
      • >=2 mutually live   → CONFLICTED: git cannot pick; emit the evidence and
                             route to human escalation (piece B). Never auto-pick a
                             wrong survivor."""
    verified = [verify(e, repo, timeout, cache_dir) for e in entries]
    live = [v for v in verified if v["status"] == LIVE]
    stale = [v for v in verified if v["status"] != LIVE]

    if not verified:
        return {"verdict": "empty", "decided_by": "git", "winner": None,
                "live": [], "stale": []}

    if len(live) == 1:
        return {
            "verdict": "auto-resolved",
            "decided_by": "git",
            "winner": live[0],
            "live": live,
            "stale": stale,
        }

    if len(live) == 0:
        # nothing the repo still backs — the whole set is stale. git decided: no
        # survivor. Not a human-judgment conflict; a clean all-stale result.
        return {
            "verdict": "auto-resolved",
            "decided_by": "git",
            "winner": None,
            "live": [],
            "stale": stale,
        }

    # >= 2 mutually-live contradictory claims → git cannot adjudicate intent. This
    # is the ONLY case a human enters (§3 step 4): intentional deprecation vs
    # not-yet-migrated. Attach the git evidence; never auto-pick.
    return {
        "verdict": CONFLICTED,
        "decided_by": "git",
        "winner": None,
        "live": live,
        "stale": stale,
        "escalation": {
            "reason": "multiple entries remain git-live on a shared ref; git "
                      "cannot decide intent — human escalation required (§3)",
            "head": head_sha(repo, timeout),
            "live_claims": [
                {"id": v.get("id"), "claim": v.get("claim"), "refs": v.get("refs")}
                for v in live
            ],
        },
    }


# ── small helpers (mirror telemetry/_now_iso, issue_queue) ────────────────────


def _now_iso():
    """Current UTC time as a second-precision ISO-8601 string (mirrors
    telemetry._now_iso / issue_queue._now_iso — the §2 verified_at field)."""
    import datetime

    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
    )


def make_entry(claim, commit_ref, refs, entry_id=None, provenance="measured"):
    """Construct a schema-vm-1.0 MemoryEntry. weight/status/verified_at are seeded
    as inert defaults — they are DERIVED by verify() at read, never trusted as
    stored. Piece B uses this to build entries before persisting."""
    import uuid

    return {
        "id": entry_id or ("vm-" + uuid.uuid4().hex),
        "claim": claim,
        "commit_ref": commit_ref,
        "refs": list(refs or []),
        "weight": 0.0,
        "verified_at": _now_iso(),
        "status": STALE,  # honest default: unverified == stale until a git-check
        "provenance": provenance,
        "schema_version": SCHEMA_VERSION,
    }


# ── thin CLI (verify | reconcile) — used by the tests and piece B ─────────────


def _load_entry(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _cmd_verify(args):
    entry = _load_entry(args.entry)
    result = verify(
        entry,
        args.repo,
        timeout=args.timeout,
        cache_dir=args.cache_dir,
        force_timeout=args.force_timeout,
    )
    if not args.cache_stats:
        result.pop("cache", None)
    sys.stdout.write(json.dumps(result, indent=2) + "\n")
    return 0


def _cmd_reconcile(args):
    entries = [_load_entry(p) for p in args.entries]
    verdict = reconcile(entries, args.repo, timeout=args.timeout, cache_dir=args.cache_dir)
    sys.stdout.write(json.dumps(verdict, indent=2) + "\n")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(
        prog="vm_gitcheck",
        description="Verified-Memory git-check engine: decide a MemoryEntry's "
                    "live/stale/conflicted status against git ground truth.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    pv = sub.add_parser("verify", help="verify one entry against git")
    pv.add_argument("--repo", required=True, help="path to the git repo (truth)")
    pv.add_argument("--entry", required=True, help="path to a MemoryEntry JSON")
    pv.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT,
                    help="per-check git budget in seconds (<=0 forces a timeout)")
    pv.add_argument("--cache-dir", default=None,
                    help="read-time cache dir (keyed on HEAD); omit to disable")
    pv.add_argument("--cache-stats", action="store_true",
                    help="include the cache {hit,key,head} block in output")
    pv.add_argument("--force-timeout", action="store_true",
                    help="simulate a timed-out check (must degrade to stale)")
    pv.set_defaults(func=_cmd_verify)

    pr = sub.add_parser("reconcile", help="reconcile a conflicting entry set to git")
    pr.add_argument("--repo", required=True, help="path to the git repo (truth)")
    pr.add_argument("--entries", required=True, nargs="+",
                    help="paths to the MemoryEntry JSONs to reconcile")
    pr.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    pr.add_argument("--cache-dir", default=None)
    pr.set_defaults(func=_cmd_reconcile)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Exception as exc:  # noqa: BLE001 — the CLI degrades, never tracebacks
        sys.stderr.write("vm_gitcheck: %s\n" % exc)
        # emit an honest stale-shaped error result so a consumer never reads live.
        sys.stdout.write(json.dumps({
            "status": STALE,
            "weight": 0.0,
            "reason": "engine error: %s — failing safe to stale" % exc,
        }, indent=2) + "\n")
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
