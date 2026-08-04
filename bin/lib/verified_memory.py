#!/usr/bin/env python3
# verified_memory.py — Verified-Memory lib + CLI core (VM piece B).
#
# THE LOAD-BEARING NOVELTY (dossier §2): a memory entry about code is a checkable
# claim, and its staleness is DECIDED by re-checking the claim against git — not
# estimated by a decay timer or an LLM vote. Piece A (vm_gitcheck) is that check;
# this module is the STORE + lifecycle that binds to it. The single mechanism that
# matters here is READ-TIME RE-VERIFICATION: staleness bites at retrieval, months
# after write, so every read re-runs verify() and a stale entry is returned MARKED
# stale (or filtered) — never served as live (dossier §2 "read-time re-verification
# is the load-bearing novelty").
#
# THREE HONEST LAYERS, faithfully (dossier §1):
#   • git = TRUTH    — status (live|stale|conflicted) is DERIVED by vm_gitcheck,
#                      never a stored opinion. We persist the derived status as a
#                      snapshot, but every read RE-DERIVES it; the stored value is
#                      never trusted as live.
#   • weight = READOUT — recomputed by vm_gitcheck.weight_for at every read, NOT a
#                      stored decaying number. A hand-set stored weight is OVERRIDDEN
#                      by the read-time readout (a deliberately-wrong weight cannot
#                      leak through).
#   • human = ESCALATION — reconcile() routes a genuine multi-live conflict to a
#                      human (the only case git cannot adjudicate intent).
#
# THE STORE (dossier §2): append-only NDJSON at
#   ${HEIMDALL_HOME:-<repo>/.heimdall}/memory/entries.ndjson
# (REUSE issue_queue.heimdall_home — never re-derive the home). NDJSON (not SQLite)
# so `gitleaks detect` scans it natively as plaintext and the secret gate stays
# armed without a path-allowlist — the exact rationale telemetry.py pins. Append +
# rotation mirror the telemetry store. An "update" appends a new revision of the
# same id; the live view folds to the latest revision per id (the log is the
# audit trail; the fold is the current state).
#
# NO-SECRET-BY-CONSTRUCTION (dossier §7, security-critical): every `claim` string
# (and any free scalar) passes the telemetry _scrub shape gate at WRITE — bounded
# length, reject gitleaks high-signal patterns / key=opaque-value. A credential
# CANNOT enter the memory store by construction, not by after-the-fact scrubbing.
# A claim that fails the gate is REJECTED (the write fails honestly) — never stored
# with the secret quietly removed (that would lie about what was remembered).
#
# NEVER RAISES INTO A READER (telemetry/attestation graceful-degrade discipline): a
# corrupt store line is skipped; a verify failure degrades the entry to an honest
# stale. The truth is git; a store fault never asserts live.
#
# This is a LIBRARY with a thin CLI core (write|get|list|verify|reconcile) driven by
# the bash wrapper bin/heimdall-memory (which owns argv + stdout shape).

from __future__ import annotations

import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import issue_queue        # REUSE heimdall_home() — never re-derive the runtime home
import memory_codec as mc  # §8 — the storage-codec seam (plain unless a codec exists)
import telemetry          # REUSE _scrub shape gate — the store stays gitleaks-clean
import vm_gitcheck as vmg  # piece A — the git-check engine (verify | reconcile | weight)

SCHEMA_VERSION = vmg.SCHEMA_VERSION  # "vm-1.0" — one entry shape, pinned by the engine

# Rotation threshold: rename entries.ndjson when it exceeds this (mirror telemetry).
_ROTATE_BYTES = 5 * 1024 * 1024


# ── store location (REUSE issue_queue.heimdall_home — dossier §2) ─────────────


def memory_dir(home=None):
    """The memory store dir: ${HEIMDALL_HOME:-<repo>/.heimdall}/memory/.

    `home` lets a caller (and the tests) pin an explicit runtime home directly;
    otherwise we REUSE issue_queue.heimdall_home() so memory lands in the SAME
    gitignored runtime home as the queue / attestation / telemetry stores (never
    re-derived)."""
    base = home if home else issue_queue.heimdall_home()
    return os.path.join(base, "memory")


def entries_path(home=None):
    """Absolute path to the active append-only NDJSON entry log."""
    return os.path.join(memory_dir(home), "entries.ndjson")


# ── the claim shape gate (REUSE telemetry._scrub — dossier §7) ────────────────


def _claim_ok(claim):
    """A claim string passes iff the telemetry _scrub shape gate accepts it: a
    bounded, secret-free scalar. _scrub returns None for a value that is over the
    length bound OR matches a gitleaks high-signal pattern OR is shaped like an
    assigned credential — exactly the values that must never enter the store. We
    return (ok, reason): ok=False means the write must be REJECTED (not stored with
    the secret removed — a rejected write is honest, a quietly-scrubbed claim lies
    about what was remembered)."""
    if not isinstance(claim, str) or not claim.strip():
        return False, "claim must be a non-empty string"
    cleaned = telemetry._scrub(claim)  # noqa: SLF001 — intentional reuse of the gate
    if cleaned is None:
        return False, (
            "claim rejected by the secret/shape gate (too long, or matches a "
            "gitleaks high-signal pattern / key=opaque-value) — the store stays "
            "gitleaks-clean by construction"
        )
    return True, None


def _refs_ok(refs):
    """refs is a list of {path, symbol?, kind?}. Each ref's path (and symbol/kind
    when present) passes the same shape gate so no credential rides in on a ref
    field. Returns (ok, reason)."""
    if refs is None:
        return True, None
    if not isinstance(refs, list):
        return False, "refs must be a list of {path, symbol, kind} objects"
    for r in refs:
        if not isinstance(r, dict):
            return False, "each ref must be an object"
        for field in ("path", "symbol", "kind"):
            val = r.get(field)
            if val is None or val == "":
                continue
            if telemetry._scrub(val) is None:  # noqa: SLF001 — same gate as claims
                return False, "ref.%s rejected by the secret/shape gate" % field
        if not (r.get("path") or "").strip():
            return False, "each ref needs a path"
    return True, None


# ── append-only NDJSON store (append + rotation mirror telemetry) ─────────────


def _maybe_rotate(path):
    """Rotate entries.ndjson → entries-<epoch>.ndjson when it exceeds the threshold
    (mirror telemetry._maybe_rotate). A rotation failure never blocks the append."""
    try:
        if os.path.getsize(path) > _ROTATE_BYTES:
            import datetime

            epoch = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
            os.replace(path, path.replace(".ndjson", "-%d.ndjson" % epoch))
    except OSError:
        return  # absent file (first write) or rename failure → no rotation, fine


def _append(entry, home):
    """Append ONE JSON line to entries.ndjson, rotating first if oversized. Returns
    True on success, False on any IO failure (graceful-degrade — a disk error drops
    the write rather than raising into the caller). The store is the audit log; the
    live view folds to the latest revision per id.

    THE WRITE HALF OF THE §8 CODEC SEAM. The entry passes through
    memory_codec.encode_entry on its way to disk, so a storage codec shrinks what is
    stored WITHOUT hmd giving up a single truth semantic:
      • the secret/shape gate has ALREADY run (write() rejects a secret-shaped claim
        before we are reached) — a codec can never smuggle a credential past it;
      • encode_entry touches PAYLOAD fields only and never a verifier input, so the
        commit_ref / refs / status / weight written here are bit-identical to the
        verified entry the git-check produced;
      • with no codec installed (the default) encode_entry is the identity and the
        stored bytes are exactly what they were before this seam existed.
    """
    try:
        ldir = memory_dir(home)
        os.makedirs(ldir, exist_ok=True)
        path = os.path.join(ldir, "entries.ndjson")
        _maybe_rotate(path)
        line = json.dumps(mc.encode_entry(entry), sort_keys=True,
                          separators=(",", ":"))
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
            fh.flush()
    except OSError:
        return False
    _codec_hint(path)
    return True


def _codec_hint(store_path):
    """Surface the ONE optional codec hint on stderr, at most once per store, when
    the store has grown heavy and no codec is installed. stderr because stdout is
    the CLI's JSON contract. Best-effort: a hint never affects whether a write
    succeeded, and it never repeats — a hint that repeats gets muted, and then the
    hint that matters gets muted with it."""
    try:
        hint = mc.maybe_hint(store_path)
    except Exception:  # noqa: BLE001 — a hint must never break a write
        return
    if hint:
        sys.stderr.write("hmd: %s\n" % hint)


def _read_raw(home=None):
    """Stream every stored entry line across entries*.ndjson (the active log + any
    rotated siblings), parsing each. Tolerant: a bad line is skipped, an absent
    store yields []. Read-only — never writes. This is the raw audit log, in write
    order (oldest → newest).

    THE READ HALF OF THE §8 CODEC SEAM, AND THE REASON A CODEC CANNOT CORRUPT A
    VERDICT. Every line is decoded here, at the store boundary, BEFORE any consumer
    exists — so vm_gitcheck.verify() and every gate above it read raw text, always.
    The gates-read-raw invariant (bin/lib/hmd-gate-endpoint.sh: "generation may run
    compressed; judgment may not") holds for storage exactly as it holds for the
    model endpoint: compression in a judge's input corrupts the judge.

    A payload that will not decode back to the text its digest names is
    UNRECOVERABLE, and is skipped by the same rule that already governs a corrupt
    JSON line — never repaired, never partially served. A truncated memory served as
    whole would be a lie about what was remembered."""
    out = []
    try:
        ldir = memory_dir(home)
        if not os.path.isdir(ldir):
            return out
        names = sorted(
            n for n in os.listdir(ldir)
            if n.startswith("entries") and n.endswith(".ndjson")
        )
    except OSError:
        return out
    for name in names:
        fp = os.path.join(ldir, name)
        try:
            with open(fp, "r", encoding="utf-8", errors="replace") as fh:
                for raw in fh:
                    line = raw.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except (ValueError, TypeError):
                        continue  # corrupt line → skip, never crash a reader
                    if not (isinstance(obj, dict) and obj.get("id")):
                        continue
                    try:
                        obj = mc.decode_entry(obj)
                    except mc.CodecCorruption:
                        continue  # unrecoverable payload → skip, never serve it
                    out.append(obj)
        except OSError:
            continue
    return out


def _latest_by_id(home=None):
    """Fold the append-only log to the CURRENT state: the latest revision per id
    (last write wins). Returns an id→entry dict. The log is the audit trail; this
    fold is what `get`/`list` operate on."""
    latest = {}
    for obj in _read_raw(home):  # write order → later overwrites earlier
        latest[obj["id"]] = obj
    return latest


# ── WRITE: create/update + verify at write time (dossier §2) ──────────────────


def write(claim, commit_ref, refs, repo, *, entry_id=None, provenance="measured",
          home=None, cache_dir=None, timeout=vmg.DEFAULT_TIMEOUT):
    """Create or update a MemoryEntry and VERIFY it against git at write time, then
    persist with the DERIVED status + weight-as-readout (dossier §2). A hand-set
    weight is never stored as truth — write seeds the entry via vmg.make_entry
    (inert defaults) and OVERWRITES status/weight/verified_at/reason from the
    git-check.

    `entry_id` updates an existing entry's id (append a new revision); omitted → a
    fresh vm-<uuid> id. The claim + refs pass the telemetry secret/shape gate first
    — a secret-shaped claim is REJECTED (returns ok=False), never stored.

    Returns a result dict:
      { ok, entry, reason, persisted }
    ok=False with a reason when the claim/refs fail the gate or the store write
    fails. NEVER raises into the caller."""
    ok, why = _claim_ok(claim)
    if not ok:
        return {"ok": False, "entry": None, "reason": why, "persisted": False}
    ok, why = _refs_ok(refs)
    if not ok:
        return {"ok": False, "entry": None, "reason": why, "persisted": False}

    # seed an inert entry (weight/status are defaults the verify overwrites).
    entry = vmg.make_entry(
        claim, commit_ref, refs or [], entry_id=entry_id, provenance=provenance,
    )

    # WRITE-TIME VERIFY: derive status/weight from git — never store a hand-set
    # weight as truth. The verify result is the source of the persisted fields.
    verified = vmg.verify(entry, repo, timeout=timeout, cache_dir=cache_dir)
    verified.pop("cache", None)  # cache stats are a read concern, not stored state

    persisted = _append(verified, home)
    if not persisted:
        return {
            "ok": False,
            "entry": verified,
            "reason": "store write failed (entry verified but not persisted)",
            "persisted": False,
        }
    return {"ok": True, "entry": verified, "reason": None, "persisted": True}


# ── READ: retrieve with READ-TIME re-verification (the core novelty, §2) ──────


def get(entry_id, repo, *, home=None, cache_dir=None, timeout=vmg.DEFAULT_TIMEOUT):
    """Retrieve ONE entry by id and RE-VERIFY it against git AT READ TIME — the
    load-bearing novelty (dossier §2). Staleness bites at retrieval, months after
    write; so the stored status is NEVER trusted: every read re-runs the git-check
    and returns the entry with a freshly-DERIVED status + weight-readout. A stale
    entry is returned MARKED stale (status=stale, weight=0), never served as live.

    Returns the re-verified entry dict, or None if no entry with that id exists.
    NEVER raises — a verify failure degrades the entry to an honest stale."""
    stored = _latest_by_id(home).get(entry_id)
    if stored is None:
        return None
    fresh = vmg.verify(stored, repo, timeout=timeout, cache_dir=cache_dir)
    fresh.pop("cache", None)
    return fresh


def list_entries(repo, *, home=None, cache_dir=None, status=None,
                 include_stale=True, timeout=vmg.DEFAULT_TIMEOUT):
    """List every current entry (latest revision per id), each RE-VERIFIED against
    git at read time (dossier §2). The returned status/weight on every entry are the
    fresh read-time readout, NOT the stored snapshot — a stale entry is marked stale,
    never returned as live.

    `status` filters to one derived status (live|stale|conflicted). `include_stale`
    =False drops every non-live entry (the "served context" view that must never
    leak a stale entry as usable). Returns a list of re-verified entries, sorted by
    descending read-time weight (live survivors first; stale entries weigh 0)."""
    out = []
    for stored in _latest_by_id(home).values():
        fresh = vmg.verify(stored, repo, timeout=timeout, cache_dir=cache_dir)
        fresh.pop("cache", None)
        if status is not None and fresh.get("status") != status:
            continue
        if not include_stale and fresh.get("status") != vmg.LIVE:
            continue
        out.append(fresh)
    out.sort(key=lambda e: (e.get("weight") or 0.0), reverse=True)
    return out


# ── RECONCILE: a conflicting set, decided by git (dossier §3) ─────────────────


def reconcile_ids(entry_ids, repo, *, home=None, cache_dir=None,
                  timeout=vmg.DEFAULT_TIMEOUT):
    """Reconcile a set of stored entries (by id) toward git truth (dossier §3) by
    delegating to the engine's reconcile — git wins. All-but-one stale → auto-resolve
    (the lone git-live entry wins, the rest are demoted to stale). >=2 mutually-live
    contradictory claims → conflicted → escalation (the only case a human enters: an
    intent question git cannot answer).

    Returns the engine verdict dict { verdict, decided_by:"git", winner, live, stale,
    escalation? }, plus a `missing` list of any ids not found in the store. NEVER
    raises."""
    latest = _latest_by_id(home)
    entries = []
    missing = []
    for eid in entry_ids:
        e = latest.get(eid)
        if e is None:
            missing.append(eid)
        else:
            entries.append(e)
    verdict = vmg.reconcile(entries, repo, timeout=timeout, cache_dir=cache_dir)
    if missing:
        verdict["missing"] = missing
    return verdict


def verify_id(entry_id, repo, *, home=None, cache_dir=None,
              timeout=vmg.DEFAULT_TIMEOUT):
    """Re-verify ONE stored entry by id against git and return the engine's full
    verify result INCLUDING the cache stats (the ops/debug view of read-time
    verification). Returns None if the id is absent. NEVER raises."""
    stored = _latest_by_id(home).get(entry_id)
    if stored is None:
        return None
    return vmg.verify(stored, repo, timeout=timeout, cache_dir=cache_dir)


# ── CLI core (driven by bin/heimdall-memory) ──────────────────────────────────


def _print(obj):
    sys.stdout.write(json.dumps(obj, indent=2, sort_keys=True) + "\n")


def _parse_refs(ref_args):
    """Parse repeated --ref path:symbol[:kind] CLI args into ref objects. A ref with
    no symbol is a path-only ref (a commit-and-file claim). Returns the refs list."""
    refs = []
    for raw in ref_args or []:
        parts = raw.split(":")
        path = parts[0].strip()
        symbol = parts[1].strip() if len(parts) > 1 else ""
        kind = parts[2].strip() if len(parts) > 2 else ""
        ref = {"path": path}
        if symbol:
            ref["symbol"] = symbol
        if kind:
            ref["kind"] = kind
        refs.append(ref)
    return refs


def _cli(argv):
    """CLI core. Subcommands:
      write    --repo DIR --claim STR --commit REF [--ref P:S[:K] ...]
               [--id ID] [--provenance measured|estimated|null]
               [--home DIR] [--cache-dir DIR] [--timeout SEC]
      get      --repo DIR --id ID [--home DIR] [--cache-dir DIR] [--timeout SEC]
      list     --repo DIR [--status live|stale|conflicted] [--live-only]
               [--home DIR] [--cache-dir DIR] [--timeout SEC]
      verify   --repo DIR --id ID  (full verify incl. cache stats)
      reconcile --repo DIR --id ID [--id ID ...]
    Honest output: every status is the read-time git-check readout, never a stored
    or fabricated value. Exit 0 on success; 2 on a usage/store error; 3 on a write
    REJECTED by the secret/shape gate (an honest refusal, not a crash)."""
    import argparse

    p = argparse.ArgumentParser(prog="heimdall-memory", add_help=True)
    p.add_argument("subcommand")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--claim")
    p.add_argument("--commit", dest="commit_ref")
    p.add_argument("--ref", action="append", dest="refs")
    p.add_argument("--id", action="append", dest="ids")
    p.add_argument("--provenance", default="measured")
    p.add_argument("--status")
    p.add_argument("--live-only", action="store_true", dest="live_only")
    p.add_argument("--home")
    p.add_argument("--cache-dir", dest="cache_dir")
    p.add_argument("--timeout", type=float, default=vmg.DEFAULT_TIMEOUT)
    args = p.parse_args(argv)

    sub = args.subcommand
    first_id = args.ids[0] if args.ids else None

    if sub == "write":
        if not args.claim or not args.commit_ref:
            _print({"ok": False, "reason": "write needs --claim and --commit"})
            return 2
        res = write(
            args.claim, args.commit_ref, _parse_refs(args.refs), args.repo,
            entry_id=first_id, provenance=args.provenance, home=args.home,
            cache_dir=args.cache_dir, timeout=args.timeout,
        )
        _print(res)
        if res["ok"]:
            return 0
        # a gate rejection is an HONEST refusal (exit 3), distinct from a store
        # failure (exit 2) — the caller can tell "secret blocked" from "disk error".
        return 3 if "gate" in (res.get("reason") or "") else 2

    if sub == "get":
        if not first_id:
            _print({"ok": False, "reason": "get needs --id"})
            return 2
        entry = get(first_id, args.repo, home=args.home,
                    cache_dir=args.cache_dir, timeout=args.timeout)
        if entry is None:
            _print({"ok": False, "reason": "no entry with id %s" % first_id})
            return 2
        _print(entry)
        return 0

    if sub == "list":
        entries = list_entries(
            args.repo, home=args.home, cache_dir=args.cache_dir,
            status=args.status, include_stale=not args.live_only,
            timeout=args.timeout,
        )
        _print({"count": len(entries), "entries": entries})
        return 0

    if sub == "verify":
        if not first_id:
            _print({"ok": False, "reason": "verify needs --id"})
            return 2
        res = verify_id(first_id, args.repo, home=args.home,
                        cache_dir=args.cache_dir, timeout=args.timeout)
        if res is None:
            _print({"ok": False, "reason": "no entry with id %s" % first_id})
            return 2
        _print(res)
        return 0

    if sub == "reconcile":
        if not args.ids:
            _print({"ok": False, "reason": "reconcile needs >=1 --id"})
            return 2
        verdict = reconcile_ids(
            args.ids, args.repo, home=args.home, cache_dir=args.cache_dir,
            timeout=args.timeout,
        )
        _print(verdict)
        return 0

    _print({"ok": False, "reason": "unknown subcommand: %s" % sub})
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
