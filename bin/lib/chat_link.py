#!/usr/bin/env python3
# chat_link.py — chat-ops P2 IDENTITY BINDING (the crux): a chat handle must NEVER be
# trusted bare. This module mints a one-time link code on an enrolled machine, redeems it
# against a chat_id from the bot, and resolves a chat_id back to its bound team — the
# {chat_id <-> HAID <-> team} contract §2 of the chat-ops spec.
#
# THE SECURITY SHAPE (why every step is server-derived + fail-closed):
#   * mint_code(haid) derives the team SERVER-SIDE from the caller's HAID via
#     cp_auth.registered_team — the team is NEVER a wire value. A caller who is not
#     enrolled in a team cannot mint (fail closed).
#   * Only the sha256 HASH of the 6-digit code is persisted (control-plane store, keyed
#     by the hash). The plaintext code is returned to the LOCAL caller once (to print) and
#     is never stored — a store compromise leaks hashes, never live codes.
#   * redeem(code, chat_id) validates TTL, then CONSUMES the code with a compare-and-set
#     (cp_state.put_record_if) so a code is single-use even under a concurrent race: the
#     losing writer sees False and refuses (fail closed). Only after the consume commits is
#     the {chat_id <-> HAID <-> team} binding written.
#   * resolve(chat_id) returns the bound team_id or None. An UNBOUND / forged chat_id has
#     no binding, so it resolves to None — the caller then refuses with the link
#     instruction and returns NO data. This is INV-CHAT (oracle C1-unbound-chat).
#   * unlink writes a REVOKED tombstone (the backend contract has no delete); resolve
#     treats a revoked binding as None — fail closed, backend-agnostic.
#
# stdlib-only (hashlib/os/secrets/time) + cp_state (the pluggable store) + cp_auth
# (registered_team, the server-derived team) — the same dependency shape as every cp store.

from __future__ import annotations

import hashlib
import os
import secrets
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_state  # the pluggable persistence backend (get_backend / put_record_if / REV_FIELD).
import cp_auth   # registered_team(haid) — the SERVER-DERIVED team; never a wire value.

# The chat-ops store namespace, relative to ${HEIMDALL_HOME}/control-plane/ (the backend rel
# root). Codes and bindings live in disjoint sub-dirs so an enumeration of one never sees
# the other.
_CODES_DIR = os.path.join("chat", "codes")
_BINDINGS_DIR = os.path.join("chat", "bindings")

# The code shape: exactly 6 decimal digits, single-use, short TTL.
_CODE_DIGITS = 6
_CODE_MIN = 10 ** (_CODE_DIGITS - 1)          # 100000 — first 6-digit value.
_CODE_MAX = (10 ** _CODE_DIGITS) - 1          # 999999 — last 6-digit value.
DEFAULT_TTL_SECONDS = 300                      # 5 minutes (§2).

# The default channel. Telegram is P2; the same binding model serves Slack in P3 by passing
# channel="slack" — the channel is part of the binding key so handles never collide across
# channels.
DEFAULT_CHANNEL = "telegram"

# The domain-separation prefixes so these hashes never alias any other sha256 in the system.
_CODE_HASH_PREFIX = b"heimdall-chat-code\x00"
_CHATID_HASH_PREFIX = b"heimdall-chat-id\x00"
_HASH_HEX = 32  # 128-bit truncation — filesystem-/Firestore-safe path segments (hex only).


def _backend(home=None):
    """The StateBackend for the chat-ops store (HEIMDALL_STATE_BACKEND, default local).
    `home` pins the store root exactly as every cp accessor's `home=` arg does."""
    return cp_state.get_backend(home=home)


def _hash_code(code):
    """The sha256 hash (domain-separated, 128-bit hex) of a plaintext code — the ONLY form
    persisted. Pure; the plaintext is never stored or logged."""
    raw = _CODE_HASH_PREFIX + str(code).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:_HASH_HEX]


def _hash_chat_id(channel, chat_id):
    """The sha256 hash (domain-separated, 128-bit hex) of a (channel, chat_id) pair — the
    binding record's filename key. The real chat_id is stored INSIDE the record for display;
    the hash keeps the path segment safe regardless of the channel's id format."""
    raw = _CHATID_HASH_PREFIX + ("%s\x00%s" % (channel, chat_id)).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:_HASH_HEX]


def _code_rel(code):
    return os.path.join(_CODES_DIR, "%s.json" % _hash_code(code))


def _binding_rel(channel, chat_id):
    # The filename carries the channel prefix so list_names over _BINDINGS_DIR can group by
    # channel, and the chat_id hash so the same chat_id always resolves to the same record.
    return os.path.join(_BINDINGS_DIR, "%s__%s.json" % (channel, _hash_chat_id(channel, chat_id)))


def mint_code(haid, *, channel=DEFAULT_CHANNEL, ttl=DEFAULT_TTL_SECONDS, home=None, now=None):
    """Mint a one-time link code for an enrolled HAID (the LOCAL `hmd link` step, §2).

    The team is derived SERVER-SIDE from the HAID via cp_auth.registered_team — never a wire
    value. Returns {ok, code, team_id, channel, expires_ts, ttl} on success (the plaintext
    `code` is for the caller to print ONCE; only its hash is persisted), or
    {ok: False, reason} when the HAID resolves to no team (fail closed — an un-teamed identity
    cannot mint a binding code).

    reasons: no_haid | no_team | io_error."""
    if not haid:
        return {"ok": False, "reason": "no_haid"}
    team_id = cp_auth.registered_team(haid, home=home)
    if not team_id:
        return {"ok": False, "reason": "no_team"}
    now = int(now if now is not None else time.time())
    # secrets.randbelow gives a cryptographically-strong, uniformly-distributed code.
    code = str(secrets.randbelow(_CODE_MAX - _CODE_MIN + 1) + _CODE_MIN)
    record = {
        "schema": "hmd-chat/link-code@1",
        "code_hash": _hash_code(code),
        "haid": haid,
        "team_id": team_id,
        "channel": channel,
        "created_ts": now,
        "ttl": int(ttl),
        "consumed": False,
    }
    if not _backend(home).put_record(_code_rel(code), record):
        return {"ok": False, "reason": "io_error"}
    return {"ok": True, "code": code, "team_id": team_id, "channel": channel,
            "created_ts": now, "expires_ts": now + int(ttl), "ttl": int(ttl)}


def redeem(code, chat_id, *, channel=DEFAULT_CHANNEL, home=None, now=None):
    """Redeem a link code against a chat_id from the bot (the `/hmd link <code>` DM, §2).

    Validates the code exists, is not already consumed, and is within TTL; then CONSUMES it
    with a compare-and-set (single-use, race-safe — a concurrent redeem loses the CAS and is
    refused); then writes the {chat_id <-> HAID <-> team} binding. The team is taken from the
    CODE record (which was server-derived at mint), never from the wire.

    Returns {ok: True, team_id, haid, chat_id, channel} on success, else
    {ok: False, reason} where reason is one of:
      invalid_code | already_used | expired | race | io_error."""
    if not code or chat_id is None:
        return {"ok": False, "reason": "invalid_code"}
    rel = _code_rel(code)
    backend = _backend(home)
    rec = backend.get_record(rel)
    if not isinstance(rec, dict) or rec.get("code_hash") != _hash_code(code):
        return {"ok": False, "reason": "invalid_code"}
    if rec.get("consumed"):
        return {"ok": False, "reason": "already_used"}
    now = int(now if now is not None else time.time())
    created = int(rec.get("created_ts", 0) or 0)
    ttl = int(rec.get("ttl", DEFAULT_TTL_SECONDS) or DEFAULT_TTL_SECONDS)
    if now > created + ttl:
        return {"ok": False, "reason": "expired"}

    # CONSUME with a compare-and-set so the code is single-use even under a concurrent race:
    # the losing writer sees False and refuses (fail closed) — no double redemption.
    expected_rev = cp_state._rev_of(rec)
    consumed = dict(rec)
    consumed["consumed"] = True
    consumed["consumed_ts"] = now
    consumed[cp_state.REV_FIELD] = expected_rev + 1
    if not backend.put_record_if(rel, consumed, expected_rev):
        return {"ok": False, "reason": "race"}

    binding = {
        "schema": "hmd-chat/binding@1",
        "channel": channel,
        "chat_id": str(chat_id),
        "haid": rec.get("haid"),
        "team_id": rec.get("team_id"),
        "bound_ts": now,
        "revoked": False,
    }
    if not backend.put_record(_binding_rel(channel, chat_id), binding):
        return {"ok": False, "reason": "io_error"}
    return {"ok": True, "team_id": rec.get("team_id"), "haid": rec.get("haid"),
            "chat_id": str(chat_id), "channel": channel}


def resolve_binding(chat_id, *, channel=DEFAULT_CHANNEL, home=None):
    """The full binding record for a chat_id, or None when unbound OR revoked. Fail-closed:
    a missing record, a record missing team_id, or a revoked tombstone all read as None."""
    if chat_id is None:
        return None
    rec = _backend(home).get_record(_binding_rel(channel, chat_id))
    if not isinstance(rec, dict):
        return None
    if rec.get("revoked"):
        return None
    if not rec.get("team_id"):
        return None
    return rec


def resolve(chat_id, *, channel=DEFAULT_CHANNEL, home=None):
    """The team_id bound to a chat_id, or None when unbound/forged/revoked (INV-CHAT).

    A bare chat_id is NEVER trusted: only a persisted, non-revoked binding resolves a team.
    An unbound chat_id -> None -> the caller refuses with the link instruction and returns
    NO team data. This is the load-bearing isolation check the C1-unbound-chat oracle guards."""
    rec = resolve_binding(chat_id, channel=channel, home=home)
    return rec.get("team_id") if rec else None


def unlink(chat_id, *, channel=DEFAULT_CHANNEL, home=None):
    """Revoke a chat binding (the `hmd chat unlink` path / owner revoke, §2). Writes a
    REVOKED tombstone (the backend contract has no delete, so we fail closed by writing a
    record resolve() treats as None) — backend-agnostic and durable. Returns True on a
    stored write, False when there was no binding to revoke or the write failed."""
    if chat_id is None:
        return False
    backend = _backend(home)
    rel = _binding_rel(channel, chat_id)
    rec = backend.get_record(rel)
    if not isinstance(rec, dict):
        return False
    rec["revoked"] = True
    rec["revoked_ts"] = int(time.time())
    return backend.put_record(rel, rec)


def list_bindings(*, home=None):
    """Every non-revoked chat binding, as a SORTED list of
    {channel, chat_id, haid, team_id, bound_ts} (the `hmd chat bindings` audit surface, §2).
    Read-only. A revoked tombstone is omitted. Firestore-safe (list_names + get_record only)."""
    backend = _backend(home)
    out = []
    for name in backend.list_names(_BINDINGS_DIR, suffix=".json"):
        rec = backend.get_record(os.path.join(_BINDINGS_DIR, name))
        if not isinstance(rec, dict) or rec.get("revoked") or not rec.get("team_id"):
            continue
        out.append({
            "channel": rec.get("channel"),
            "chat_id": rec.get("chat_id"),
            "haid": rec.get("haid"),
            "team_id": rec.get("team_id"),
            "bound_ts": rec.get("bound_ts"),
        })
    out.sort(key=lambda r: (r.get("channel") or "", r.get("chat_id") or ""))
    return out
