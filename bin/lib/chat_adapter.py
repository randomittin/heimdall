#!/usr/bin/env python3
# chat_adapter.py — chat-ops P2 TELEGRAM ADAPTER (§0: one thin skin over chat_core).
#
# A Telegram bot is a stateless HTTP client of api.telegram.org: getUpdates (long-poll) to
# receive, sendMessage to reply. This adapter is that skin and nothing more — parse an inbound
# Update into {chat_id, text}, and send a reply. All verb logic lives in chat_core.
#
# THE INVARIANTS:
#   * The bot token comes from env HEIMDALL_TELEGRAM_BOT_TOKEN ONLY — never a hardcoded literal,
#     never a wire value. No token => the adapter is INACTIVE and send is a clean no-op (the
#     server can boot without Telegram configured).
#   * parse_update is PURE (no IO) so tests pin it exactly; a malformed/non-message update ->
#     None (ignored), never a crash.
#   * The transport is an INJECTABLE seam: send_message(..., transport=fn) routes through fn
#     instead of the network, so tests exercise the full path with zero sockets. The default
#     transport is a real urllib POST to the Telegram Bot API.
#
# stdlib-only (json/os/urllib) — no third-party Telegram SDK, self-hostable.

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

BOT_TOKEN_ENV = "HEIMDALL_TELEGRAM_BOT_TOKEN"
_API_BASE = "https://api.telegram.org"
_HTTP_TIMEOUT = 30  # seconds — also the long-poll ceiling for getUpdates.


def bot_token():
    """The Telegram bot token from env HEIMDALL_TELEGRAM_BOT_TOKEN, or None when unset. This
    is the ONLY source of the token — never a literal, never a wire value."""
    tok = os.environ.get(BOT_TOKEN_ENV)
    return tok.strip() if tok and tok.strip() else None


def is_active():
    """True iff a bot token is configured. When False the adapter is inactive and send is a
    clean no-op — the control plane runs fine without Telegram wired."""
    return bot_token() is not None


def parse_update(update):
    """Parse a Telegram Update (dict) into {chat_id, text}, or None when it is not a text
    message we handle. PURE — no IO. Tolerant: a non-dict, an update with no message, or a
    message with no text/chat all return None (the poller simply skips it)."""
    if not isinstance(update, dict):
        return None
    msg = update.get("message") or update.get("edited_message")
    if not isinstance(msg, dict):
        return None
    chat = msg.get("chat")
    text = msg.get("text")
    if not isinstance(chat, dict) or not isinstance(text, str):
        return None
    chat_id = chat.get("id")
    if chat_id is None:
        return None
    return {"chat_id": str(chat_id), "text": text,
            "update_id": update.get("update_id")}


def _default_transport(method, payload, token):
    """The real transport: a JSON POST to https://api.telegram.org/bot<token>/<method>.
    Returns {ok, status?, result?/error?}. Never raises — a network error is a structured
    failure the caller can log."""
    url = "%s/bot%s/%s" % (_API_BASE, token, method)
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=_HTTP_TIMEOUT) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
        parsed = json.loads(raw)
        return {"ok": bool(parsed.get("ok")), "status": 200, "result": parsed.get("result")}
    except urllib.error.HTTPError as exc:
        return {"ok": False, "status": exc.code, "error": "http_error"}
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return {"ok": False, "error": "transport_error", "detail": str(exc)[:200]}


def send_message(chat_id, text, *, transport=None, token=None):
    """Send `text` to `chat_id`. The token defaults to the env; INACTIVE (no token) is a clean
    no-op {ok: False, reason: 'inactive'}. `transport` is an injectable seam (signature
    fn(method, payload, token) -> dict) — default is a real Telegram API POST."""
    token = token if token is not None else bot_token()
    if not token:
        return {"ok": False, "reason": "inactive"}
    payload = {"chat_id": chat_id, "text": text}
    tx = transport if transport is not None else _default_transport
    return tx("sendMessage", payload, token)


def get_updates(offset=None, *, transport=None, token=None, timeout=25):
    """Long-poll getUpdates from the Telegram API. Returns a list of raw Update dicts (empty on
    inactive/error). `offset` acks all updates < offset. `transport` is the same injectable
    seam as send_message so the serve loop is testable without a socket."""
    token = token if token is not None else bot_token()
    if not token:
        return []
    payload = {"timeout": timeout}
    if offset is not None:
        payload["offset"] = offset
    tx = transport if transport is not None else _default_transport
    resp = tx("getUpdates", payload, token)
    if not isinstance(resp, dict) or not resp.get("ok"):
        return []
    result = resp.get("result")
    return result if isinstance(result, list) else []
