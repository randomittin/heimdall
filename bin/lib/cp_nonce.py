#!/usr/bin/env python3
# cp_nonce.py — the REPLAY GATE for the PUBLIC control-plane surface (presence beats).
#
# WHY THIS EXISTS (the captured-beat replay blast radius). /presence is about to be served
# on an --allow-unauthenticated Cloud Run service: the GFE/IAM layer no longer rejects
# anonymous callers, so the APP LAYER is the only abuse gate left. A presence beat is PKI-
# signed (cp_auth.canonical_message over METHOD\nPATH\nbody), so an attacker cannot FORGE a
# beat for a HAID they do not hold a key for — but a captured signed beat is byte-for-byte
# REPLAYABLE: nothing in the signature is time- or use-bound, so the same valid bytes can be
# re-POSTed forever to keep a dev falsely "online", or hammered to churn the presence store.
# cp_auth proves WHO signed; this module proves the signed beat is FRESH and used ONCE.
#
# THE CONTRACT (where nonce + ts come from — read this before wiring). The (nonce, ts) pair
# travels INSIDE the signed request body — it is therefore COVERED by the Ed25519 signature
# cp_auth.verify_identity already checked, so it is UNFORGEABLE (an attacker cannot mint a
# fresh (nonce, ts) for a captured beat without the private key — re-signing is exactly what
# they cannot do) and only REPLAYABLE (they can resend the captured bytes verbatim). The
# presence handler therefore extracts nonce + ts from the ALREADY-VERIFIED body and passes
# them here; this module never re-verifies the signature (that already happened at the §3
# chokepoint) — it only decides freshness + first-use. accept() is the single seam the
# presence verify path calls.
#
# TWO INDEPENDENT CHECKS (both must pass):
#
#   • STALE — |ts - now| > window  ⇒  reject (reason "stale"). PURE / in-memory: no store
#     read, ALWAYS enforced (a backend outage cannot weaken it). A beat whose own timestamp
#     is outside ±window of the server clock is too old (a replay of a captured beat) or too
#     far in the future (a forged/clock-skewed ts) to be a live heartbeat. This alone bounds
#     a replay to the ±window — a captured beat is useless once `window` seconds elapse.
#
#   • REPLAY — (scope, key, nonce) already seen within the window  ⇒  reject (reason
#     "replay"). The nonce is unique PER BEAT; the key is the haid (the nonce namespace is
#     per-identity, so two devs may pick the same nonce without colliding — see the test).
#     First sight RECORDS the nonce and returns ok (reason "ok"); a second sight of the same
#     (scope, key, nonce) inside the window is the replay and is refused.
#
# THE SEEN-SET (fixed-window TTL, on the StateBackend seam — DURABLE ACROSS INSTANCES). A
# per-instance in-memory set is near-useless under Cloud Run autoscale: a replay routed to a
# different instance sees an empty set and is accepted. So the seen-set is persisted THROUGH
# the StateBackend (cp_state.get_backend), exactly like cp_ratelimit's counter, and is
# Firestore-durable when HEIMDALL_STATE_BACKEND=firestore — one shared set every instance
# reads+writes, so the replay is caught fleet-wide. Local-backend it is the byte-identical
# keyed-JSON-to-HEIMDALL_HOME path (dev/test).
#
#   • Each seen nonce is ONE keyed JSON record {"ts": <float>} at the rel
#     "nonce/<scope>/<key-hash>/<nonce-hash>.json". accept() does one get_record (has this
#     nonce been seen?) + one put_record (record first sight) — O(1), never read_lines a
#     growing log.
#
#   • TTL-BOUNDED so the set never grows unbounded: a recorded nonce's `ts` is the beat's own
#     timestamp, and a stored record whose ts is older than `window` is treated as ABSENT (a
#     nonce older than the window can no longer be replayed — the STALE check already refuses
#     a beat with that ts — so its seen-record is meaningless and a same-nonce reuse AFTER the
#     window is allowed). Because a nonce can only ever be replayed within ±window, a record
#     older than the window is dead weight; we never read it again and a same-key write simply
#     overwrites it. No sweeper is needed (self-expiring by ts, exactly like cp_ratelimit's
#     by-bucket self-expiry).
#
# NEVER STORE THE RAW NONCE/KEY (no-secret-by-construction). The key may be a haid and the
# nonce is opaque client material; both are sha256-hashed to a hex prefix BEFORE they become
# path segments, so neither raw value is written to the store or logged, and the path is
# uniform + bounded + filesystem-safe for any shape.
#
# FAIL-OPEN on a backend error (documented + bounded). Presence replay is LOW-STAKES (the
# §3 PKI chokepoint is the real security boundary and is unaffected; a replay can at most keep
# a dev falsely "online" within the window). So on ANY backend error during the seen-set
# read/write the REPLAY check FAILS OPEN — accept() returns ok with reason "ok". This is
# bounded by the STALE check, which is PURE and ALWAYS enforced: even with the store fully
# down, a captured beat is useless once `window` seconds elapse. We deliberately do NOT fail
# closed here (unlike cp_enroll, whose token IS the security gate) — locking out a legit beat
# on a transient store hiccup is worse than a bounded replay window.
#
# NEVER backend.path() ON A SERVING PATH (the firestore-only incident class). Every seen-set
# op uses get_record/put_record only — both served by FirestoreBackend; path() RAISES under
# firestore and is never called here. DATA ONLY — a nonce record executes nothing.
#
# stdlib-only (hashlib/os/sys) + cp_state (the persistence seam) — the SAME dependency shape
# every CP store has, no third-party dep, self-hostable.

from __future__ import annotations

import hashlib
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_state  # the pluggable persistence backend — the seen-set is one keyed JSON record
                 # per (scope, key, nonce), put/get THROUGH a StateBackend so the same atomic
                 # put / tolerant get becomes Firestore-durable (shared across instances) on
                 # Cloud Run WITHOUT changing this module (byte-identical on local).

# ── the freshness window (a beat whose ts is outside ±this is STALE — pure check) ──
#
# The presence beat cadence is ~30s; 300s (5min) gives generous clock-skew slack while still
# bounding a captured beat's replay life to 5 minutes. The caller passes `window` explicitly
# (the presence path pins its own value); this is the documented default.
DEFAULT_WINDOW_SECONDS = 300

# ── store layout (a keyed record per (scope, key-hash, nonce-hash)) ────────────
#
# Every rel is RELATIVE to ${HEIMDALL_HOME}/control-plane/ (the StateBackend namespace): the
# seen-set root is "nonce/", one scope's dir is "nonce/<scope>/", one identity's dir is
# "nonce/<scope>/<key-hash>/", and one seen nonce is
# "nonce/<scope>/<key-hash>/<nonce-hash>.json". The backend owns the home root + makedirs +
# the byte shape; this module NEVER opens a file directly and NEVER calls backend.path().

_NONCE_REL = "nonce"

# The keyed-record suffix (one .json per seen nonce, like cp_ratelimit's per-bucket records).
_RECORD_SUFFIX = ".json"

# The ts field of a seen-nonce record. The record is the CLOSED schema {"ts": <float>} — no
# raw nonce/key/haid material is ever stored, only the beat's timestamp (the TTL freshness).
_FIELD_TS = "ts"

# A conservative slug bound for the SCOPE segment (scope is caller-controlled and small, e.g.
# "presence"). Mirrors cp_ratelimit._SCOPE_SLUG_MAX: bounded, filesystem-safe, and free of the
# "__" run the Firestore flat encoding reserves.
_SCOPE_SLUG_MAX = 64

# The hex width of a key/nonce hash used as a path segment. sha256 -> 64 hex chars; 32 is
# ample to avoid collisions for a seen-set (a collision merely shares a record, never leaks
# data) while keeping the path short. The raw key/nonce is NEVER stored — only this hash.
_HASH_HEX = 32


def _scope_slug(scope):
    """A filesystem-safe, bounded slug for the SCOPE path segment. Keeps [A-Za-z0-9._-] and
    maps every other char to "_" (so a single odd char becomes a single "_", never the "__"
    Firestore separator), bounded to _SCOPE_SLUG_MAX. Empty/None -> "unknown" (an unscoped
    record still stores, never escapes its segment). Mirrors cp_ratelimit._scope_slug."""
    raw = str(scope or "").strip()
    if not raw:
        return "unknown"
    out = []
    for ch in raw[:_SCOPE_SLUG_MAX]:
        out.append(ch if (ch.isalnum() or ch in "._-") else "_")
    slug = "".join(out).strip("._-")
    return slug or "unknown"


def _hash(value):
    """sha256-hash a key/nonce to a hex prefix used as a path segment. The value may be a haid
    or opaque client nonce material — hashing it BEFORE it touches the store guarantees the raw
    value is never written or logged (no-secret-by-construction), and makes the path uniform +
    bounded + filesystem-safe for any shape. An empty/None value hashes the empty string to a
    stable segment (an unattributed check still records, never escapes). Mirrors
    cp_ratelimit._key_hash."""
    raw = str(value or "").encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:_HASH_HEX]


def _is_stale(ts, now, window):
    """True iff `ts` is outside ±`window` of `now` (too old to be a live beat, or too far in
    the future to be a sane clock). PURE — no store, no IO. A non-numeric ts is STALE (a beat
    with no usable timestamp cannot be proven fresh). A non-positive window is clamped to a
    minimal 1s so a misconfig never makes EVERY beat fresh (it degrades to a tight window,
    still a valid gate)."""
    if not isinstance(ts, (int, float)):
        return True
    win = window if (isinstance(window, (int, float)) and window > 0) else 1
    return abs(now - ts) > win


def _record_rel(scope, key, nonce):
    """The store-relative path of one seen nonce's record:
    nonce/<scope>/<key-hash>/<nonce-hash>.json. The key AND the nonce are HASHED (never raw)
    into their segments, so neither a haid nor opaque nonce material lands in the store."""
    return os.path.join(
        _NONCE_REL, _scope_slug(scope), _hash(key),
        _hash(nonce) + _RECORD_SUFFIX)


def accept(scope, key, nonce, ts, *, now=None, window=DEFAULT_WINDOW_SECONDS, backend=None):
    """Decide whether a signed presence beat's (nonce, ts) is FRESH and FIRST-USE. Returns
    (ok: bool, reason: str):

      • (False, "stale")  — |ts - now| > window. The beat's own timestamp is outside the
        freshness window (a replay of a captured beat, or a forged/skewed future ts). PURE /
        in-memory: ALWAYS enforced, even when the seen-set store is down.
      • (False, "replay") — (scope, key, nonce) has already been seen within the window. The
        captured signed bytes are being resent; the first use recorded the nonce, this is the
        second.
      • (True, "ok")      — first sight of a fresh (nonce, ts). The nonce is RECORDED (one
        put_record) so a later resend within the window is caught as a replay.

    `key` is the haid: the nonce namespace is PER-IDENTITY, so two devs may independently pick
    the same nonce without colliding. `now` is injectable epoch seconds (defaults to
    time.time()) for deterministic tests. `window` bounds BOTH the staleness check and the
    seen-set TTL (a stored nonce whose ts is older than `window` is treated as absent, so the
    set self-expires and a same-nonce reuse AFTER the window is allowed).

    The contract: (nonce, ts) ride in the SIGNED request body, so cp_auth.verify_identity has
    ALREADY proven them unforgeable; the handler extracts them from the verified body and calls
    here. This module never re-verifies the signature — it decides freshness + first-use only.

    FAIL-OPEN on a backend error: the STALE check is pure and runs FIRST (always enforced); if
    it passes, a backend error during the seen-set read/write returns (True, "ok") rather than
    locking out a legit beat — presence replay is low-stakes and the stale window still bounds
    abuse. Never calls backend.path() (firestore-safe)."""
    when = now if now is not None else _now()

    # 1) STALE — pure, in-memory, ALWAYS enforced (a backend outage cannot weaken it). A beat
    #    outside ±window is too old (a replay) or too far future (a skewed/forged ts) to be live.
    if _is_stale(ts, when, window):
        return (False, "stale")

    # 2) REPLAY — consult the durable seen-set. FAIL-OPEN on any backend error: the stale check
    #    above already bounds a replay to ±window, so a transient store hiccup at most lets one
    #    in-window replay through rather than refusing a legit dev's beat.
    try:
        be = backend if backend is not None else cp_state.get_backend()
        rel = _record_rel(scope, key, nonce)
        record = be.get_record(rel)
        if isinstance(record, dict):
            prior = record.get(_FIELD_TS)
            # A recorded nonce whose ts is still within the window is a genuine replay. A record
            # older than the window is self-expired dead weight (the stale check would already
            # have refused a beat with that ts) — treat it as absent and let first-use proceed.
            if isinstance(prior, (int, float)) and not _is_stale(prior, when, window):
                return (False, "replay")
        # First sight (or a self-expired prior): RECORD this nonce's ts, then accept. A failed
        # write fails OPEN (still accept) — the store is tolerant (put_record -> False on error)
        # and we never lock out a dev.
        be.put_record(rel, {_FIELD_TS: float(ts)})
        return (True, "ok")
    except Exception as exc:  # noqa: BLE001 — FAIL-OPEN: a backend error never refuses a beat.
        # DECISION (F6, 2026-07-06 audit): we deliberately fail OPEN, not closed. The tradeoff is
        # availability > replay-window: locking out a legit signed beat on a transient store hiccup
        # is worse than a bounded replay, because the STALE check above is PURE and ALWAYS enforced
        # — even with the seen-set store fully down, a captured beat is useless once +/-window (300s)
        # freshness elapses. So a replay during a store outage is bounded to that +/-300s window, not
        # unbounded. But the fail-open must be OBSERVABLE: emit ONE loud stderr line so an outage-
        # window replay attempt is at least visible in the logs. Token-free by construction — we log
        # only the caller-controlled `scope` + the exception TYPE, never the raw key/nonce (a haid /
        # opaque secret material). Guarded so a logging error can NEVER break the fail-open return.
        try:
            sys.stderr.write(
                "cp_nonce: FAIL-OPEN replay-check on backend error (scope=%s type=%s) — "
                "replay bounded to +/-%ss freshness; abuse visible but not blocked\n"
                % (_scope_slug(scope), type(exc).__name__, window))
            sys.stderr.flush()
        except Exception:  # noqa: BLE001 — diagnostic only; must not defeat the fail-open return.
            return (True, "ok")
        return (True, "ok")


def _now():
    """Wall-clock epoch seconds. Wrapped so a test can monkeypatch one symbol; the public API
    also accepts an explicit `now` for fully deterministic checks (the preferred test path).
    Mirrors cp_ratelimit._now."""
    import time
    return time.time()
