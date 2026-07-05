#!/usr/bin/env python3
# cp_ratelimit.py — the ABUSE GATE for the PUBLIC control-plane surface (enroll + presence).
#
# WHY THIS EXISTS (the leaked-bootstrap-token blast radius). /enroll (cp_enroll §pre-auth)
# and /presence + /roster (cp_presence) are about to be served on an --allow-unauthenticated
# Cloud Run service: the GFE/IAM layer no longer rejects anonymous callers, so the APP LAYER
# is the ONLY abuse gate left. /enroll already fails-closed without a bootstrap token and
# 409s a rebind, and /presence is PKI-gated — but a LEAKED bootstrap token would still let an
# attacker: (a) flood the key registry with unbounded NEW enrollments, and (b) hammer the
# unauthenticated surface to exhaust the instance. cp_auth/cp_enroll bound WHAT one token can
# do (no hijack, no rebind); this module bounds HOW FAST and HOW MANY — the rate + the
# registry-growth ceiling a single leaked credential cannot exceed.
#
# THE COUNTER (fixed-window, on the StateBackend seam — DURABLE ACROSS INSTANCES). A per-
# instance in-memory limiter is near-useless under Cloud Run autoscale: N instances each
# grant the full quota, so the real limit is N×limit and a fresh instance resets it. So the
# counter is persisted THROUGH the StateBackend (cp_state.get_backend), exactly like every CP
# store, and is therefore Firestore-durable when HEIMDALL_STATE_BACKEND=firestore — one shared
# counter every instance reads+writes, so the limit holds across the fleet. Local-backend it is
# the byte-identical keyed-JSON-to-HEIMDALL_HOME path (dev/test).
#
#   • A window is a fixed bucket: bucket = floor(now / window). The counter for
#     (scope, key, bucket) is ONE keyed JSON record {"count": N} at the rel
#     "ratelimit/<scope>/<key-hash>/<bucket>.json". One get_record + one put_record per
#     check (cheap, O(1) — never read_lines a growing log). When the wall clock crosses into
#     the next bucket the count starts at 0 again — the window "rolls over" for free, and a
#     stale bucket's record is simply never read again (self-expiring by key, no sweeper).
#
#   • allow(scope, key, limit, window) -> (ok, retry_after). ok=False once the bucket's count
#     has reached `limit`; retry_after is the integer seconds until the current bucket ends
#     (when the quota refreshes). The CALLER calls allow() TWICE per request — once keyed by
#     client IP, once by the bootstrap-token-hash / haid — and BOTH must pass, so one noisy
#     key (a single hammering IP, or a single leaked token) cannot starve every other.
#
#   • enroll_budget_ok(now, max_new, window) — a DEPLOYMENT-WIDE ceiling on NEW enrollments
#     per window (one global counter, not per-key), so a leaked token cannot grow the key
#     registry unbounded no matter how many IPs/HAIDs it rotates through. It reuses allow()'s
#     mechanics with a single global key.
#
# NEVER STORE THE RAW KEY (no-secret-by-construction). The `key` may be a bootstrap-token
# value; it is sha256-hashed to a hex prefix BEFORE it becomes a path segment, so the raw
# token is never written to the store and never logged. An IP is hashed by the same path so
# the counter layout is uniform and filesystem-safe regardless of the key's shape.
#
# FAIL-OPEN (documented + bounded). A rate limiter is an ABUSE gate, not an auth gate: a
# TRANSIENT backend hiccup must NOT lock out a legitimate dev (the §3 PKI chokepoint and the
# §enroll token are the real security boundaries and are unaffected). So on ANY backend error
# the check FAILS OPEN — it returns ok=True. This is bounded: the store's own methods are
# tolerant (get_record -> None on a miss/error, put_record -> False on a write error), an
# absent counter reads as 0 (allow), and a failed increment still allows. The cost of a fail-
# open is at most "the limit was not enforced during the outage", never "a real dev is
# refused"; the registry-growth ceiling is the backstop that still bounds the worst case. We
# deliberately do NOT fail closed here, unlike cp_enroll (whose secret IS the security gate).
#
# NEVER backend.path() ON A SERVING PATH (the firestore-only incident class). Every counter
# op uses get_record/put_record only — both served by FirestoreBackend; path() RAISES under
# firestore and is never called here. DATA ONLY — a counter executes nothing.
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

import cp_state  # the pluggable persistence backend — the counter is one keyed JSON record
                 # per (scope, key, window-bucket), put/get THROUGH a StateBackend so the same
                 # atomic put / tolerant get becomes Firestore-durable (shared across instances)
                 # on Cloud Run WITHOUT changing this module (byte-identical on local).

# ── store layout (a keyed counter record per (scope, key-hash, window-bucket)) ──
#
# Every rel is RELATIVE to ${HEIMDALL_HOME}/control-plane/ (the StateBackend namespace): the
# limiter root is "ratelimit/", one scope's dir is "ratelimit/<scope>/", one key's dir is
# "ratelimit/<scope>/<key-hash>/", and one window bucket is
# "ratelimit/<scope>/<key-hash>/<bucket>.json". The backend owns the home root + makedirs +
# the byte shape; this module NEVER opens a file directly and NEVER calls backend.path().

_RATELIMIT_REL = "ratelimit"

# The keyed-record suffix (one .json per window bucket, like cp_presence's per-dev records).
_RECORD_SUFFIX = ".json"

# The count field of a bucket record. A bucket record is the CLOSED schema {"count": <int>} —
# no key/IP/token material is ever stored, only the integer.
_FIELD_COUNT = "count"

# The deployment-wide enroll-budget counter's fixed scope + key. ONE global bucket per window
# (not per-IP/token), so the ceiling bounds TOTAL new enrollments across the fleet regardless
# of how many keys an attacker rotates through.
_ENROLL_BUDGET_SCOPE = "enroll_budget"
_ENROLL_BUDGET_KEY = "global"

# A conservative slug bound for the SCOPE segment (scope is caller-controlled and small, e.g.
# "enroll"/"presence"). Mirrors cp_presence._SLUG_MAX intent: bounded, filesystem-safe, and
# free of the "__" run the Firestore flat encoding reserves.
_SCOPE_SLUG_MAX = 64

# The hex width of a key hash used as a path segment. sha256 -> 64 hex chars; 32 is ample to
# avoid collisions for a counter (a collision merely shares a bucket, never leaks data) while
# keeping the path short. The raw key is NEVER stored — only this hash.
_KEY_HASH_HEX = 32


def _scope_slug(scope):
    """A filesystem-safe, bounded slug for the SCOPE path segment. Keeps [A-Za-z0-9._-] and
    maps every other char to "_" (so a single odd char becomes a single "_", never the "__"
    Firestore separator), bounded to _SCOPE_SLUG_MAX. Empty/None -> "unknown" (an unscoped
    counter still stores, never escapes its segment). Mirrors cp_presence._slug."""
    raw = str(scope or "").strip()
    if not raw:
        return "unknown"
    out = []
    for ch in raw[:_SCOPE_SLUG_MAX]:
        out.append(ch if (ch.isalnum() or ch in "._-") else "_")
    slug = "".join(out).strip("._-")
    return slug or "unknown"


def _key_hash(key):
    """sha256-hash a rate-limit key to a hex prefix used as a path segment. The key may be a
    bootstrap-token VALUE — hashing it BEFORE it touches the store guarantees the raw token is
    never written or logged (no-secret-by-construction), and makes the path uniform + bounded +
    filesystem-safe for any key shape (IP / token-hash / haid). An empty/None key hashes the
    empty string to a stable bucket (an unattributed check still counts, never escapes)."""
    raw = str(key or "").encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:_KEY_HASH_HEX]


def _bucket(now, window):
    """The fixed-window bucket ordinal for `now`: floor(now / window). Two checks in the same
    window share a bucket (and thus a counter); the next window is a new bucket that starts at
    0 — the window "rolls over" for free. A non-positive window is clamped to 1s so a misconfig
    never divides by zero (it degrades to a 1-second window, still a valid limiter)."""
    win = window if (isinstance(window, (int, float)) and window > 0) else 1
    return int(now // win)


def _retry_after(now, window):
    """Integer seconds until the current window bucket ends (when the quota refreshes). Used as
    the refused `retry_after`. Always >= 1 so a caller never busy-loops on retry_after=0."""
    win = window if (isinstance(window, (int, float)) and window > 0) else 1
    elapsed = now - (_bucket(now, win) * win)
    remaining = win - elapsed
    return max(1, int(remaining) + (1 if remaining != int(remaining) else 0))


class RateLimiter:
    """The abuse gate for the public control-plane surface. Construct with a `home` (pinning
    the store root, exactly as every CP accessor threads `home=` through) or an explicit
    `backend` (a StateBackend); by default it resolves the backend from HEIMDALL_STATE_BACKEND
    via cp_state.get_backend, so the same limiter is Firestore-durable on Cloud Run (one shared
    counter across instances) and byte-identical local in dev/test.

    The counter is a fixed window: a keyed JSON record {"count": N} per (scope, key-hash,
    window-bucket). One get_record + one put_record per check. FAIL-OPEN on any backend error
    (an abuse gate must never lock out a legit dev on a transient store hiccup — the PKI/token
    gates are the real security boundary). NEVER backend.path() — every op is get/put."""

    def __init__(self, home=None, *, backend=None):
        # Reuse the StateBackend seam exactly as cp_presence._backend does: an injected
        # `backend` (a test double / a pre-built handle) wins; otherwise resolve from the env.
        # `home` is threaded straight through, no re-derivation of heimdall_home() here.
        self._backend = backend if backend is not None else cp_state.get_backend(home=home)

    def _bucket_rel(self, scope, key, bucket):
        """The store-relative path of one window bucket's counter record:
        ratelimit/<scope>/<key-hash>/<bucket>.json. The key is HASHED (never raw) into its
        segment, so a bootstrap-token value never lands in the store."""
        return os.path.join(
            _RATELIMIT_REL, _scope_slug(scope), _key_hash(key),
            "%d%s" % (bucket, _RECORD_SUFFIX))

    def allow(self, scope, key, *, now=None, limit, window):
        """Consume one unit of the (scope, key) quota for the CURRENT fixed window and report
        whether it was within `limit`. Returns (ok, retry_after):

          • ok=True, retry_after=0   — the bucket's count was below `limit`; the count is
            incremented (this call consumed one unit) and the request may proceed.
          • ok=False, retry_after=N  — the bucket already holds `limit` units; the request is
            refused and N is the integer seconds until the window rolls over (>= 1).

        `now` is injectable epoch seconds (defaults to time.time()) for deterministic tests.
        `limit` is the max units per `window` seconds. The caller invokes allow() TWICE per
        request (per-IP and per-token/haid) and proceeds only if BOTH are ok, so one noisy key
        cannot starve another (the keys address INDEPENDENT counters by construction).

        FAIL-OPEN: on ANY backend error the check returns (True, 0) — an abuse gate must not
        lock out a legit dev on a transient store hiccup. This is bounded (an absent counter
        reads as 0 = allow; a failed increment still allows); the registry-growth ceiling
        (enroll_budget_ok) is the backstop on the worst case. A non-positive `limit` refuses
        immediately (a zero quota is a hard closed gate, by intent)."""
        when = now if now is not None else _now()
        if not isinstance(limit, (int, float)) or limit <= 0:
            # A zero/negative quota is an explicit hard-closed gate (e.g. a kill switch). It is
            # NOT a backend error, so it does NOT fail open — refuse with a full-window retry.
            return (False, _retry_after(when, window))
        try:
            bucket = _bucket(when, window)
            rel = self._bucket_rel(scope, key, bucket)
            record = self._backend.get_record(rel)
            count = 0
            if isinstance(record, dict):
                raw = record.get(_FIELD_COUNT)
                if isinstance(raw, int) and raw >= 0:
                    count = raw
            if count >= limit:
                # Quota exhausted for this window — refuse WITHOUT incrementing (a refused
                # request does not consume more budget) and report when the window refreshes.
                return (False, _retry_after(when, window))
            # Within quota: consume one unit. A failed write fails OPEN (still allow) — the
            # store is tolerant (put_record -> False on error) and we never lock out a dev.
            self._backend.put_record(rel, {_FIELD_COUNT: count + 1})
            return (True, 0)
        except Exception as exc:  # noqa: BLE001 — FAIL-OPEN: a backend error never refuses.
            # DECISION (F6, 2026-07-06 audit): we deliberately fail OPEN, not closed. The tradeoff
            # is availability > abuse-cap: locking out a legit dev on a transient store hiccup is
            # worse than a temporarily-unenforced cap, because the abuse gate is NOT the auth gate
            # (the PKI chokepoint + the enroll token are the real security boundaries, unaffected by
            # a store outage) and the deployment-wide enroll-budget ceiling is the backstop that
            # still bounds registry growth in the worst case. But the fail-open must be OBSERVABLE:
            # emit ONE loud stderr line so an outage window in which the caps are NOT enforced is
            # visible in the logs. Token-free by construction — we log only the caller-controlled
            # `scope` + the exception TYPE, never the raw key (which may be an IP / bootstrap-token
            # value / haid). Guarded so a logging error can NEVER defeat the fail-open return.
            try:
                sys.stderr.write(
                    "cp_ratelimit: FAIL-OPEN abuse-cap on backend error (scope=%s type=%s) — "
                    "rate cap not enforced this call; enroll-budget ceiling is the backstop\n"
                    % (_scope_slug(scope), type(exc).__name__))
                sys.stderr.flush()
            except Exception:  # noqa: BLE001 — diagnostic only; must not defeat the fail-open return.
                return (True, 0)
            return (True, 0)

    def enroll_budget_ok(self, now=None, *, max_new, window):
        """The DEPLOYMENT-WIDE ceiling on NEW enrollments per window. Returns True iff a NEW
        enrollment is within budget (and consumes one unit of it), False once `max_new` new
        enrollments have happened in the current window across the WHOLE fleet — so a leaked
        bootstrap token cannot grow the key registry unbounded no matter how many IPs/HAIDs it
        rotates through (allow()'s per-key gate bounds one key; this bounds the TOTAL).

        It is a single GLOBAL counter (fixed scope + key), reusing allow()'s exact mechanics —
        same fixed-window bucket, same one get+put, same FAIL-OPEN on a backend error (a budget
        check must not block a legit first-run enroll on a transient hiccup). The CALLER invokes
        this only on the path that is about to register a NEW haid->pubkey binding, so an
        idempotent re-enroll of an already-registered key does not consume budget."""
        ok, _ = self.allow(
            _ENROLL_BUDGET_SCOPE, _ENROLL_BUDGET_KEY,
            now=now, limit=max_new, window=window)
        return ok


def _now():
    """Wall-clock epoch seconds. Wrapped so a test can monkeypatch one symbol; the public API
    also accepts an explicit `now` for fully deterministic checks (the preferred test path)."""
    import time
    return time.time()
