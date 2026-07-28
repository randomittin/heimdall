#!/usr/bin/env python3
# cp_repoteam.py — the server-side repo -> team_id REGISTRY for zero-touch auto-team
# formation (design: docs/analysis/zero-touch-team-formation.md §2/§3; oracle: INV-AUTOTEAM
# rows AT3/AT5 in evals/oracles/rr-multitenant-isolation). A Wave-1 PRIMITIVE — the later
# cp_autoteam handler (POST /team/auto) COMPOSES this; this file builds NO route.
#
# WHY THIS EXISTS (the keystone the auto-team flow turns on). Today a team is a high-entropy
# bearer `team_secret` scoped to a repo; joining means presenting that secret. The zero-touch
# shift (§2) moves the membership proof to "has GitHub access to the repo, server-verified" and
# makes `team_id` a NON-SECRET partition handle bound to a repo. For that to be safe the server
# needs ONE source of truth for "which team covers this repo" — a `repo_slug -> team_id` binding
# authored SERVER-SIDE. That is this registry.
#
# THE NON-SECRET CANONICAL KEY (the whole point — no bearer secret in git). A repo is addressed
# by its `repo_slug`: a deterministic, host-stripped, lowercased `owner/name` derived from a git
# remote URL (repo_slug()). It carries NO secret — a guessable repo_slug is harmless because the
# operative team_id is ALWAYS server-resolved from the binding, never a wire field (INV-1), so a
# caller cannot read a partition the server never bound their HAID to.
#
# THE ISOLATION INVARIANTS this primitive upholds (tested in test/heimdall-cp-repoteam.test.sh):
#   * SERVER-DERIVED TEAM (AT3 / INV-1). mint_team_for_repo derives the team_id SERVER-SIDE from a
#     freshly-minted random secret (cp_auth.derive_team_id), NEVER from a wire value. This module
#     never accepts a caller-supplied team_id as authoritative for a NEW repo — the team a repo (and
#     therefore a joining HAID) belongs to is decided here, on the server, from the repo binding.
#   * FIRST-WRITER-WINS CAS (AT5 race). bind_repo_team writes the repo->team binding through the
#     StateBackend's compare-and-swap (put_record_if). Once a repo is bound, a SECOND concurrent
#     initiate NEVER clobbers the winner — it reads the winner back and converges on it. Two
#     concurrent auto-initiates on the same fresh repo therefore agree on ONE team, and auto-join
#     never invents a second team for an already-bound repo.
#   * KEYED-BY-REPO. Each binding is stored at a flat, Firestore-safe store key derived from the
#     repo_slug (a domain-separated sha256 hex — no "/" and no "__", so it is a valid doc id on the
#     FirestoreBackend which encodes rel "/" -> "__"). A read for repo A addresses EXACTLY repo A's
#     partition; there is no path that returns repo B's team to a repo-A read.
#   * FAIL-CLOSED. A bad/unresolvable repo_slug or a bad team_id on a WRITE raises RepoTeamError
#     (never a silent bad binding); get_team_for_repo returns None for an unbound (or unresolvable)
#     repo. Firestore-safe throughout: get_record + put_record_if only, NEVER backend.path().
#
# MEMBERSHIP BINDING reuses the EXISTING key registry (cp_auth), it does NOT duplicate it:
# bind_haid_to_team re-registers the HAID's binding via cp_auth.register_key preserving its
# pubkey/owner/project/enrolled_at and swapping only the team_id — the SAME accessor cp_enroll's
# own-key team-switch uses. The team_id passed in MUST be server-derived (a get_team_for_repo /
# mint_team_for_repo result), never a wire team_id, so registered_team(haid) stays server-derived.
#
# stdlib-only (hashlib/os/re/secrets) + the repo's own cp_state / cp_auth / cp_allowlist substrate —
# no new dependency, mirrors cp_ghinstall's shape exactly.

from __future__ import annotations

import hashlib
import os
import re
import secrets
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_state      # the pluggable, CAS-capable persistence backend (Wave 1) — put_record_if.
import cp_auth       # REUSE derive_team_id + the haid->team key registry (register_key etc.).
import cp_allowlist  # REUSE REPO_SLUG_RE (cp_allowlist.py:175) — the single owner/name whitelist.

# The store-relative dir every repo->team binding lives under, RELATIVE to
# ${HEIMDALL_HOME}/control-plane/ (the StateBackend rel namespace). One keyed JSON record per
# repo: "repo-team/<key>.json", where <key> is the flat hashed slug key below. The backend owns
# the home root + the atomic tmp+os.replace / indent=2 byte shape (byte-identical local,
# Firestore-durable in cloud). Mirrors cp_ghinstall's _INSTALL_DIR discipline.
_REPOTEAM_DIR = "repo-team"

# The record schema version (mirrors the key registry's / install map's "1.0.0" stamp).
_SCHEMA_VERSION = "1.0.0"

# The domain-separation prefix + width for the flat store key derived from a repo_slug. The slug
# itself carries a "/" (owner/name) which cannot be a store-path segment, so the key is a
# domain-separated sha256 of the canonical slug, truncated to 32 hex (128 bits — mirrors
# cp_auth's _TEAM_ID_HEX). Hex -> only [0-9a-f], so the key contains NO "/" and NO "__": it is a
# valid FirestoreBackend doc id (that backend encodes rel "/" -> "__"; _SEP="__"), collision-free
# for distinct slugs, and byte-safe as a local filename. The plaintext slug is stored INSIDE the
# record (repo_slug field) so a binding stays human-inspectable — the hash is the KEY only.
_REPO_KEY_PREFIX = b"heimdall-repo\x00"
_REPO_KEY_HEX = 32

# The repo-slug whitelist, reused verbatim from the allowlist spine so a bound repo can ONLY ever
# be an owner/name slug (exactly one slash, no shell metachar, no whitespace, no deep path).
_REPO_SLUG_RX = re.compile(cp_allowlist.REPO_SLUG_RE)

# A conservative team_id shape guard (defensive; the team_id is a stored VALUE, not a path
# segment, so it cannot traverse the store — but a malformed/empty team_id is still refused on a
# write). Mirrors cp_ghinstall._TEAM_ID_RX (cp_ghinstall.py:72): the normal value is the 32-hex
# derive_team_id() handle, but the legacy/default team ids are grandfathered by the wider set.
_TEAM_ID_RX = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")

# The entropy (in bytes) of the fresh server-side secret minted for a NEW repo's team. 32 bytes
# -> a 64-hex secret; it is consumed ONCE to derive the non-secret team_id and DISCARDED (never
# stored, returned, or logged) — the same discard discipline cp_enroll uses on a presented secret.
_MINT_SECRET_BYTES = 32


class RepoTeamError(Exception):
    """Raised for every fail-closed refusal on a WRITE path in this module. `reason` is a short
    machine code (bad_repo | bad_team_id | bind_race_unresolved | write_failed); `detail` is a
    short, secret-free note (a minted secret is NEVER placed in an exception message)."""

    def __init__(self, reason, detail=""):
        self.reason = reason
        self.detail = detail
        super().__init__("%s: %s" % (reason, detail) if detail else reason)


# ── the canonical repo key: a normalized owner/name from any git remote URL ─────


def repo_slug(remote_url):
    """The CANONICAL, NON-SECRET repo key: a deterministic, host-stripped, lowercased `owner/name`
    slug derived from a GitHub git remote URL. ONE function covering every remote form:

      https://github.com/Owner/Repo.git          -> owner/repo
      https://github.com/Owner/Repo               -> owner/repo
      http://github.com/Owner/Repo/               -> owner/repo
      https://x-access-token:TOKEN@github.com/O/R -> o/r          (userinfo stripped)
      ssh://git@github.com/Owner/Repo.git         -> owner/repo
      ssh://git@github.com:22/Owner/Repo.git      -> owner/repo   (port stripped)
      git://github.com/Owner/Repo.git             -> owner/repo
      git@github.com:Owner/Repo.git               -> owner/repo   (scp-like form)
      git@ghe.corp.com:Owner/Repo.git             -> owner/repo   (any host stripped — enterprise)
      Owner/Repo                                  -> owner/repo   (already a bare slug)

    The slug is lowercased (GitHub slugs are case-insensitive) so the key is canonical: the same
    repo via any remote form maps to the SAME binding. Pure — no IO, no store. Returns None (not
    an exception) for a value that does not resolve to a clean owner/name pair (empty, a single
    segment, a shell-metachar/whitespace payload) — a read treats an unresolvable slug as unbound,
    and a write path (bind/mint) turns that None into a fail-closed RepoTeamError."""
    if not isinstance(remote_url, str):
        return None
    s = remote_url.strip()
    if not s:
        return None
    # Extract the PATH portion (everything after [scheme://][userinfo@]host[:port]).
    if "://" in s:
        # scheme://[userinfo@]host[:port]/owner/name — drop the scheme + authority.
        rest = s.split("://", 1)[1]
        path = rest.split("/", 1)[1] if "/" in rest else ""
    elif ":" in s and "/" not in s.split(":", 1)[0]:
        # scp-like remote: [user@]host:owner/name (the authority before ":" carries no slash).
        path = s.split(":", 1)[1]
    else:
        # already a bare path / owner/name (or an unqualified host/owner/name).
        path = s
    path = path.strip().strip("/")
    if path.endswith(".git"):
        path = path[: -len(".git")]
    segs = [p for p in path.split("/") if p]
    if len(segs) < 2:
        return None
    # The LAST TWO non-empty segments are owner/name (a github remote is always host/owner/name;
    # a bare owner/name has exactly those two). One slash, lowercased -> the canonical key.
    slug = ("%s/%s" % (segs[-2], segs[-1])).lower()
    if not _REPO_SLUG_RX.fullmatch(slug):
        return None
    return slug


# ── internal validation + the flat, Firestore-safe store key ────────────────────


def _require_slug(value):
    """Normalize `value` (a URL or an already-canonical slug) to a canonical repo_slug, or raise
    RepoTeamError('bad_repo') — the fail-closed guard on every WRITE path (a garbage key can never
    be bound). repo_slug() is idempotent on an already-canonical slug, so a caller may pass either."""
    slug = repo_slug(value)
    if not slug:
        raise RepoTeamError("bad_repo", "not a resolvable owner/name repo slug")
    return slug


def _validate_team_id(team_id):
    """Return `team_id` iff it is a sane non-empty id, else raise RepoTeamError('bad_team_id').
    Defensive only: team_id is stored as a VALUE (never a path segment), so it cannot traverse the
    store — but a malformed/empty team_id must not be persisted as a binding."""
    if not isinstance(team_id, str) or not _TEAM_ID_RX.fullmatch(team_id):
        raise RepoTeamError("bad_team_id", "team_id must be a safe non-empty id")
    return team_id


def _key(slug):
    """The flat, Firestore-safe store key for a CANONICAL slug: a domain-separated sha256 of the
    slug truncated to 32 hex. Hex -> no "/" and no "__", so it is a valid FirestoreBackend doc id
    and a byte-safe local filename; collision-free for distinct slugs. The slug is assumed already
    canonical (lowercased owner/name) so the hash is deterministic per repo."""
    return hashlib.sha256(_REPO_KEY_PREFIX + slug.encode("utf-8")).hexdigest()[:_REPO_KEY_HEX]


def _rel(slug):
    """The store-relative record key for a canonical slug — "repo-team/<hashed-key>.json"."""
    return os.path.join(_REPOTEAM_DIR, "%s.json" % _key(slug))


def _backend(home=None):
    """The StateBackend for the repo->team registry (HEIMDALL_STATE_BACKEND, default local).
    `home` pins the store root exactly as every cp_* accessor's `home=` arg does."""
    return cp_state.get_backend(home=home)


# ── the read: repo -> the bound team_id (the server-side resolution AT3 keys on) ─


def get_team_for_repo(repo, *, home=None):
    """The team_id bound to `repo` (a repo_slug or a remote URL), or None when the repo is unbound
    (or `repo` does not resolve to a clean slug). This is the SERVER-SIDE `repo -> team_id`
    resolution the auto-join handler uses (INV-1 / AT3): the operative team is resolved HERE from
    the repo binding, never from a caller-supplied wire team_id. Read-only, tolerant — a bad slug
    or an absent/corrupt record reads as None (unbound). Firestore-safe (get_record only)."""
    slug = repo_slug(repo)
    if not slug:
        return None
    rec = _backend(home).get_record(_rel(slug))
    if not isinstance(rec, dict):
        return None
    tid = rec.get("team_id")
    return tid if isinstance(tid, str) and tid else None


# ── the write: CAS-bind repo -> team (first-writer-wins, never clobber) ─────────


def bind_repo_team(repo, team_id, *, home=None):
    """CAS-write the `repo -> team_id` binding and return the AUTHORITATIVE bound team_id.

    FIRST-WRITER-WINS (AT5 race, fail-closed on clobber):
      * ALREADY BOUND to `team_id`  -> idempotent no-op; returns `team_id` (no rewrite).
      * ALREADY BOUND to a DIFFERENT team -> the existing winner is NEVER clobbered; returns the
        EXISTING team_id (a second concurrent initiate converges on the winner, it does not steal
        the repo). This is the fail-closed race behavior: a bound repo has exactly one team.
      * UNBOUND -> a compare-and-swap create (put_record_if with expected_rev=0). On a committed
        write returns `team_id`; if a concurrent writer won the create race (CAS False), re-reads
        the winner and returns IT (again: never clobber). The CAS is the cross-instance guard that
        makes two Cloud Run instances' simultaneous initiates converge on ONE team (on the
        FirestoreBackend put_record_if is a transactional CAS; the LocalBackend rev-check is the
        same guard for single-host durability).

    Raises RepoTeamError('bad_repo' | 'bad_team_id') on an unresolvable slug / malformed team_id
    (fail-closed — a garbage binding is never persisted), or ('bind_race_unresolved') in the
    pathological case where the CAS lost yet no winner is readable. Firestore-safe (get_record +
    put_record_if only, never backend.path())."""
    slug = _require_slug(repo)
    tid = _validate_team_id(team_id)
    rel = _rel(slug)
    backend = _backend(home)

    existing = backend.get_record(rel)
    if isinstance(existing, dict):
        bound = existing.get("team_id")
        if isinstance(bound, str) and bound:
            # Already bound — idempotent for the same team, first-writer-wins for a different one.
            # NEVER clobber: return the incumbent so a second initiate converges on the winner.
            return bound

    # Unbound -> compare-and-swap CREATE. An absent record is rev 0; the new record carries rev 1,
    # so put_record_if commits ONLY IF no writer has since created the binding (expected_rev 0).
    record = {
        "version": _SCHEMA_VERSION,
        "repo_slug": slug,
        "team_id": tid,
        cp_state.REV_FIELD: 1,
    }
    if backend.put_record_if(rel, record, 0):
        return tid

    # Lost the create race (a concurrent writer committed first). Re-read + return the winner —
    # first-writer-wins, we never overwrite the committed binding.
    winner = backend.get_record(rel)
    if isinstance(winner, dict):
        bound = winner.get("team_id")
        if isinstance(bound, str) and bound:
            return bound
    # CAS refused but no readable winner: an IO/backend fault, not a race — fail closed loudly.
    raise RepoTeamError(
        "bind_race_unresolved",
        "the repo->team CAS write did not commit and no bound team is readable")


# ── mint: derive + bind a SERVER-DERIVED team for a NEW repo (no double-mint) ────


def mint_team_for_repo(repo, *, home=None):
    """Return the team_id for `repo`, MINTING a fresh server-derived team when the repo is unbound.

    SERVER-DERIVED TEAM (AT3 / INV-1): a NEW repo's team_id is derived HERE, on the server, from a
    freshly-minted high-entropy secret — cp_auth.derive_team_id(secrets.token_hex(...)) — and the
    raw secret is DISCARDED immediately (never stored, returned, or logged). The team_id is NEVER
    taken from a wire value: this module decides a new repo's team, so a joining HAID's team stays
    server-derived from the repo binding.

    NO DOUBLE-MINT (AT5): if `repo` is ALREADY bound, the existing team_id is returned WITHOUT
    minting. And the mint routes its binding through bind_repo_team's CAS, so two concurrent
    initiates on the same fresh repo converge on ONE team (the loser's freshly-minted team is
    discarded when bind returns the winner) — an unbound repo never ends up with two teams.

    Raises RepoTeamError('bad_repo') on an unresolvable slug (fail-closed). Firestore-safe."""
    slug = _require_slug(repo)

    existing = get_team_for_repo(slug, home=home)
    if existing:
        return existing  # already bound — never double-mint.

    # Mint a fresh server-side secret, derive the NON-SECRET team_id, discard the secret.
    secret = secrets.token_hex(_MINT_SECRET_BYTES)
    team_id = cp_auth.derive_team_id(secret)
    del secret  # the raw secret is consumed once and dropped — it never leaves this frame.
    if not team_id:
        # derive_team_id only returns falsy for an empty secret; token_hex never is. Defensive.
        raise RepoTeamError("bad_team_id", "failed to derive a team_id from the minted secret")

    # Bind through the CAS. If a concurrent initiate won, bind returns THAT winner and this
    # frame's freshly-derived team_id is simply discarded — the repo keeps exactly one team.
    return bind_repo_team(slug, team_id, home=home)


# ── membership: bind haid -> team_id via the EXISTING key registry (no dup) ──────


def bind_haid_to_team(haid, team_id, *, home=None):
    """Bind a HAID's membership to `team_id` by RE-REGISTERING its existing key-registry binding
    through cp_auth.register_key — the SAME accessor cp_enroll's own-key team-switch uses. This
    does NOT duplicate the key registry: it reads the HAID's current binding, preserves its
    pubkey + owner + project (register_key preserves enrolled_at itself), and swaps ONLY the
    team_id. Returns True on a stored write.

    SERVER-DERIVED TEAM (INV-1): `team_id` MUST be a server-derived handle — a get_team_for_repo /
    mint_team_for_repo result — NEVER a caller-supplied wire team_id. This helper does not derive
    the team; it persists the server-resolved one, so registered_team(haid) stays server-authored.

    FAIL-CLOSED: returns False for a missing haid/team_id, or when the HAID has no registered
    pubkey (an unregistered HAID cannot be given a membership — it has no key to sign with; it must
    enroll first). Firestore-safe (routes through cp_auth's get_record/put_record registry, never
    backend.path())."""
    if not haid or not team_id:
        return False
    tid = _validate_team_id(team_id)
    pubkey = cp_auth.registered_pubkey(haid, home=home)
    if not pubkey:
        # No registered key -> no identity to bind a membership to. Fail closed (never fabricate).
        return False
    # Preserve the existing owner/project so a membership swap is non-destructive (enrolled_at is
    # preserved by register_key itself). Read via the SAME tolerant registry accessor cp_enroll uses.
    entry = cp_auth._load_keys(home)["keys"].get(haid)
    entry = entry if isinstance(entry, dict) else {}
    return cp_auth.register_key(
        haid, pubkey,
        owner=bool(entry.get("owner")),
        team_id=tid,
        project=entry.get("project"),
        home=home,
    )
