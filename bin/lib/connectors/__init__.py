#!/usr/bin/env python3
# connectors — the PLUGGABLE SOURCE-ADAPTER SEAM for Heimdall's issue-resolution
# loop (design dossier §1). Mirrors bin/lib/designmatch_targets/__init__.py
# verbatim: an abc.ABC interface + a module-level _REGISTRY + register/get/
# available + a single trailing import line that declares the launch set.
#
# The loop (piece c), normalize (piece b) and writeback (piece d) depend ONLY on
# this interface — never on a concrete adapter. A 4th source (Datadog, Jira, ...)
# is a new module implementing Connector + one register(...) import line; the
# loop is NEVER edited.
#
# LAZY / OPTIONAL (the MarkItDown clean-install contract): an absent connector
# library OR absent credentials -> the source is simply INACTIVE, never a crash.
# `health().active == False` and `fetch_issues()` returns [] — the loop skips it.
# With no connectors configured the loop is inert (base install + stranger-test
# unaffected). Adapters NEVER read creds from anywhere but the `cfg` they are
# configured with (the config layer, piece e).

from __future__ import annotations

import abc
from typing import Dict, List, Optional, Type


class ConnectorConfigError(Exception):
    """Raised by Connector.configure() on malformed config (missing required
    structural keys). NOT raised for absent creds — absent creds degrade to an
    INACTIVE source (health().active == False), never an exception."""


class Connector(abc.ABC):
    """A pluggable issue SOURCE adapter. One concrete subclass per source
    (GitHub Issues, Slack, email, ...). Every method is honest about activity:
    when creds are absent the connector is inactive and IO methods no-op
    (return [] / {ok: False}) rather than raising — the lazy/optional contract."""

    #: short, lowercase registry key (e.g. "github", "slack", "email").
    name: str = ""
    #: human-readable label (e.g. "GitHub Issues").
    label: str = ""
    #: static source kind: "issue" | "chat" | "email".
    kind: str = ""

    @abc.abstractmethod
    def configure(self, cfg: dict) -> None:
        """Bind per-connector config (creds, repo/channel/mailbox). Raises
        ConnectorConfigError on malformed config. NEVER reads creds from anywhere
        but `cfg` (the config layer, piece e). Absent creds are NOT an error here
        — they surface as health().active == False."""
        raise RuntimeError("Connector.configure must be overridden by a subclass")

    @abc.abstractmethod
    def health(self) -> dict:
        """{ name, active: bool, reason: str|None }. active=False (NOT raise) when
        the connector library or creds are absent — the MarkItDown lazy/optional
        contract: an absent connector -> inactive source, no crash."""
        raise RuntimeError("Connector.health must be overridden by a subclass")

    @abc.abstractmethod
    def identity(self) -> dict:
        """{ name, label, kind } — static descriptor, no IO. Used by normalize to
        tag `source`/kind and by writeback to route the resolution back."""
        raise RuntimeError("Connector.identity must be overridden by a subclass")

    @abc.abstractmethod
    def fetch_issues(self, since: Optional[str] = None) -> List[dict]:
        """Return RAW source items (adapter-native shape). `since` = cursor for an
        incremental pull. On an inactive/unconfigured connector -> return []
        (never raise). Deterministic ordering (sorted by native id)."""
        raise RuntimeError("Connector.fetch_issues must be overridden by a subclass")

    @abc.abstractmethod
    def post_resolution(self, raw_ref: dict, resolution: dict) -> dict:
        """Write the resolution BACK to the source (reply in thread / comment on
        issue / reply email). Called by piece (d) ONLY after a human merge.
        `raw_ref` is the adapter-native locator from the normalized issue's
        links.source_ref. Returns { ok, url|thread_ts|message_id }. On an inactive
        connector -> { ok: False, reason: 'inactive' } (no crash)."""
        raise RuntimeError("Connector.post_resolution must be overridden by a subclass")

    @abc.abstractmethod
    def close_issue(self, raw_ref: dict) -> dict:
        """Idempotent source-issue close. Separate from post_resolution so
        writeback can close WITHOUT a message and vice-versa. Inactive ->
        { ok: False, reason: 'inactive' }."""
        raise RuntimeError("Connector.close_issue must be overridden by a subclass")


_REGISTRY: Dict[str, Connector] = {}


def register(connector: Connector) -> Connector:
    """Register a concrete Connector instance under its `.name`. Re-registering
    the same name REPLACES the prior entry (mirrors designmatch_targets)."""
    if not isinstance(connector, Connector):
        raise TypeError("register() expects a Connector instance, got %r" % (connector,))
    if not connector.name:
        raise ValueError("connector %r has no .name" % (connector,))
    _REGISTRY[connector.name] = connector
    return connector


def register_class(cls: Type[Connector]) -> Type[Connector]:
    """Instantiate a Connector subclass and register the instance."""
    register(cls())
    return cls


def get(name: str) -> Connector:
    """Return the registered Connector for `name`, or raise KeyError listing the
    available keys (so a typo'd source fails loudly, never silently defaults)."""
    try:
        return _REGISTRY[name]
    except KeyError:
        raise KeyError(
            "no connector %r — available: %s"
            % (name, ", ".join(sorted(_REGISTRY)) or "(none)")
        )


def available() -> List[str]:
    """Sorted list of registered connector keys."""
    return sorted(_REGISTRY)


def is_registered(name: str) -> bool:
    return name in _REGISTRY


def active(cfg: dict) -> List[Connector]:
    """Return the connectors that are BOTH configured (a per-connector block in
    cfg['connectors']) AND report health().active == True. The single place the
    loop asks "which sources are live right now?". A connector whose creds are
    absent is configured-but-inactive and is silently excluded — the lazy/optional
    degrade. Order: sorted by name for determinism."""
    out: List[Connector] = []
    per = (cfg or {}).get("connectors", {}) or {}
    for name in sorted(_REGISTRY):
        block = per.get(name)
        if not isinstance(block, dict):
            continue  # source not configured at all -> not active
        connector = _REGISTRY[name]
        try:
            connector.configure(block)
        except ConnectorConfigError:
            continue  # malformed config -> treated as not-active, never crash the loop
        if connector.health().get("active"):
            out.append(connector)
    return out


# The launch set is declared in ONE place: the trailing import side-effect. Each
# module calls register(...) at import. A 4th source adds its module here + a
# register() call — zero edits to the logic above, zero edits to pieces (b)/(c)/(d).
from . import github, slack, email  # noqa: E402,F401
