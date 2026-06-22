#!/usr/bin/env python3
# slack.py — the Slack source adapter (design dossier §1/§2).
#
# fetch_issues returns RAW Slack message objects (the conversations.history native
# shape: {ts, text, thread_ts, user, ...}) for the configured channel. It does NOT
# normalize — normalize() (piece b) maps the native shape to the internal issue
# schema (title = first line of text, source_ref = {channel, ts, thread_ts}).
# post_resolution replies in the message's thread; close_issue reacts to mark the
# message handled (Slack has no "close" — a checkmark reaction is the idempotent
# equivalent).
#
# LAZY / OPTIONAL: the Slack Web API client uses urllib (stdlib). The adapter is
# INACTIVE without a token. configure() reads the token from the resolved config
# block ONLY (key "token"). Absent token -> health().active == False,
# fetch_issues() -> [], post/close -> { ok: False, reason: 'inactive' }. No
# network call is attempted without a token.

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from typing import List, Optional

from . import Connector, ConnectorConfigError, register

_API_ROOT = "https://slack.com/api"
_TIMEOUT = 20
_HANDLED_REACTION = "white_check_mark"


class SlackConnector(Connector):
    name = "slack"
    label = "Slack"
    kind = "chat"

    def __init__(self) -> None:
        self._channel: Optional[str] = None
        self._token: Optional[str] = None
        self._api_root = _API_ROOT

    # ── configure / health / identity ─────────────────────────────────────────
    def configure(self, cfg: dict) -> None:
        if not isinstance(cfg, dict):
            raise ConnectorConfigError("slack config must be an object")
        channel = cfg.get("channel")
        if not channel:
            raise ConnectorConfigError("slack config needs 'channel' (a channel id, e.g. C123)")
        self._channel = str(channel)
        tok = cfg.get("token")
        self._token = str(tok) if tok else None
        self._api_root = str(cfg.get("api_root") or _API_ROOT).rstrip("/")

    def health(self) -> dict:
        if not self._channel:
            return {"name": self.name, "active": False, "reason": "not configured"}
        if not self._token:
            return {
                "name": self.name,
                "active": False,
                "reason": "no token (set the token_env credential to activate)",
            }
        return {"name": self.name, "active": True, "reason": None}

    def identity(self) -> dict:
        return {"name": self.name, "label": self.label, "kind": self.kind}

    # ── fetch (raw native shape) ──────────────────────────────────────────────
    def fetch_issues(self, since: Optional[str] = None) -> List[dict]:
        if not self.health()["active"]:
            return []
        params = {"channel": self._channel, "limit": "100"}
        if since:
            params["oldest"] = str(since)
        data = self._get("conversations.history", params)
        if not isinstance(data, dict) or not data.get("ok"):
            return []
        msgs = [m for m in (data.get("messages") or []) if isinstance(m, dict) and m.get("ts")]
        # tag each message with its channel so normalize has the full source_ref
        # without re-querying. Native field, not normalization.
        for m in msgs:
            m.setdefault("channel", self._channel)
        # deterministic order: oldest first by ts (ts is a sortable string).
        msgs.sort(key=lambda m: float(m.get("ts", "0")))
        return msgs

    # ── writeback ─────────────────────────────────────────────────────────────
    def post_resolution(self, raw_ref: dict, resolution: dict) -> dict:
        if not self.health()["active"]:
            return {"ok": False, "reason": "inactive"}
        ref = raw_ref or {}
        channel = str(ref.get("channel") or self._channel)
        thread_ts = ref.get("thread_ts") or ref.get("ts")
        if not thread_ts:
            return {"ok": False, "reason": "missing ts in source_ref"}
        out = self._post(
            "chat.postMessage",
            {
                "channel": channel,
                "thread_ts": str(thread_ts),
                "text": self._resolution_text(resolution),
            },
        )
        ok = isinstance(out, dict) and out.get("ok")
        return {"ok": bool(ok), "thread_ts": out.get("ts") if isinstance(out, dict) else None}

    def close_issue(self, raw_ref: dict) -> dict:
        if not self.health()["active"]:
            return {"ok": False, "reason": "inactive"}
        ref = raw_ref or {}
        channel = str(ref.get("channel") or self._channel)
        ts = ref.get("ts") or ref.get("thread_ts")
        if not ts:
            return {"ok": False, "reason": "missing ts in source_ref"}
        out = self._post(
            "reactions.add",
            {"channel": channel, "timestamp": str(ts), "name": _HANDLED_REACTION},
        )
        # already_reacted is idempotent success: the message is marked handled.
        ok = isinstance(out, dict) and (out.get("ok") or out.get("error") == "already_reacted")
        return {"ok": bool(ok), "thread_ts": str(ts)}

    # ── internals ─────────────────────────────────────────────────────────────
    @staticmethod
    def _resolution_text(resolution: dict) -> str:
        res = resolution or {}
        pr_url = res.get("pr_url") or res.get("url")
        summary = res.get("summary") or "Resolution merged."
        return summary + ("\nResolved in %s" % pr_url if pr_url else "")

    def _request(self, method: str, endpoint: str, payload):
        url = "%s/%s" % (self._api_root, endpoint)
        body = None
        if method == "GET" and isinstance(payload, dict):
            url += "?" + urllib.parse.urlencode(payload)
        elif payload is not None:
            body = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(url, data=body, method=method)
        req.add_header("Authorization", "Bearer %s" % self._token)
        req.add_header("User-Agent", "heimdall-connector")
        if body is not None:
            req.add_header("Content-Type", "application/json; charset=utf-8")
        try:
            with urllib.request.urlopen(req, timeout=_TIMEOUT) as resp:
                raw = resp.read().decode("utf-8", "replace")
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError):
            return None
        try:
            return json.loads(raw) if raw else None
        except json.JSONDecodeError:
            return None

    def _get(self, endpoint: str, params: dict):
        return self._request("GET", endpoint, params)

    def _post(self, endpoint: str, payload: dict):
        return self._request("POST", endpoint, payload)


register(SlackConnector())
