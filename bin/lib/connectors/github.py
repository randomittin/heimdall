#!/usr/bin/env python3
# github.py — the GitHub Issues source adapter (design dossier §1/§2).
#
# fetch_issues returns RAW GitHub issue objects (the REST API native shape:
# {number, title, body, labels, html_url, created_at, ...}). It does NOT
# normalize — normalize() (piece b) maps the native shape to the internal issue
# schema. post_resolution comments on the issue; close_issue closes it.
#
# LAZY / OPTIONAL: the GitHub REST client uses urllib (stdlib — always present),
# but the adapter is INACTIVE without a token. configure() reads the token from
# the resolved config block ONLY (key "token"; the config layer resolves the
# env-named secret before handing us the block). Absent token -> health().active
# == False, fetch_issues() -> [], post/close -> { ok: False, reason: 'inactive' }.
# No network call is ever attempted without a token present.

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import List, Optional

from . import Connector, ConnectorConfigError, register

_API_ROOT = "https://api.github.com"
_TIMEOUT = 20


class GithubConnector(Connector):
    name = "github"
    label = "GitHub Issues"
    kind = "issue"

    def __init__(self) -> None:
        self._repo: Optional[str] = None
        self._token: Optional[str] = None
        self._api_root = _API_ROOT

    # ── configure / health / identity ─────────────────────────────────────────
    def configure(self, cfg: dict) -> None:
        if not isinstance(cfg, dict):
            raise ConnectorConfigError("github config must be an object")
        repo = cfg.get("repo")
        if not repo or "/" not in str(repo):
            raise ConnectorConfigError(
                "github config needs 'repo' as 'owner/name' (got %r)" % (repo,)
            )
        self._repo = str(repo)
        # The config layer resolves *_env -> the literal token under "token".
        # An absent token is NOT an error here — it degrades to inactive.
        tok = cfg.get("token")
        self._token = str(tok) if tok else None
        # allow a test/self-host override of the API root (no secret).
        self._api_root = str(cfg.get("api_root") or _API_ROOT).rstrip("/")

    def health(self) -> dict:
        if not self._repo:
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
        path = "/repos/%s/issues?state=open&sort=created&direction=asc&per_page=100" % self._repo
        if since:
            path += "&since=%s" % urllib.parse.quote(str(since))
        data = self._get(path)
        if not isinstance(data, list):
            return []
        # GitHub's /issues endpoint also returns PRs (they carry pull_request);
        # exclude them — they are not issues. Deterministic order by number.
        issues = [it for it in data if isinstance(it, dict) and "pull_request" not in it]
        issues.sort(key=lambda it: it.get("number", 0))
        return issues

    # ── writeback ─────────────────────────────────────────────────────────────
    def post_resolution(self, raw_ref: dict, resolution: dict) -> dict:
        if not self.health()["active"]:
            return {"ok": False, "reason": "inactive"}
        repo, number = self._ref(raw_ref)
        if not number:
            return {"ok": False, "reason": "missing issue number in source_ref"}
        body = self._resolution_body(resolution)
        out = self._post(
            "/repos/%s/issues/%s/comments" % (repo, number),
            {"body": body},
        )
        url = out.get("html_url") if isinstance(out, dict) else None
        return {"ok": bool(url), "url": url}

    def close_issue(self, raw_ref: dict) -> dict:
        if not self.health()["active"]:
            return {"ok": False, "reason": "inactive"}
        repo, number = self._ref(raw_ref)
        if not number:
            return {"ok": False, "reason": "missing issue number in source_ref"}
        out = self._patch(
            "/repos/%s/issues/%s" % (repo, number),
            {"state": "closed", "state_reason": "completed"},
        )
        closed = isinstance(out, dict) and out.get("state") == "closed"
        return {"ok": bool(closed), "url": out.get("html_url") if isinstance(out, dict) else None}

    # ── internals ─────────────────────────────────────────────────────────────
    def _ref(self, raw_ref: dict):
        ref = raw_ref or {}
        return str(ref.get("repo") or self._repo), ref.get("number")

    @staticmethod
    def _resolution_body(resolution: dict) -> str:
        res = resolution or {}
        pr_url = res.get("pr_url") or res.get("url")
        summary = res.get("summary") or "Resolution merged."
        parts = [summary]
        if pr_url:
            parts.append("\nResolved in %s" % pr_url)
        return "".join(parts)

    def _request(self, method: str, path: str, payload: Optional[dict]):
        url = self._api_root + path
        body = json.dumps(payload).encode("utf-8") if payload is not None else None
        req = urllib.request.Request(url, data=body, method=method)
        req.add_header("Authorization", "Bearer %s" % self._token)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        req.add_header("User-Agent", "heimdall-connector")
        if body is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=_TIMEOUT) as resp:
                raw = resp.read().decode("utf-8", "replace")
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError):
            # network failure is NOT a crash — an unreachable source yields no data.
            return None
        try:
            return json.loads(raw) if raw else None
        except json.JSONDecodeError:
            return None

    def _get(self, path: str):
        return self._request("GET", path, None)

    def _post(self, path: str, payload: dict):
        return self._request("POST", path, payload)

    def _patch(self, path: str, payload: dict):
        return self._request("PATCH", path, payload)


# urllib.parse is used in fetch_issues; import after class to keep the network
# surface explicit but ensure the symbol resolves.
import urllib.parse  # noqa: E402

register(GithubConnector())
