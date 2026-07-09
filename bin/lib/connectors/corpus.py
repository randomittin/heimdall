#!/usr/bin/env python3
# corpus.py — the ANONYMIZED-ISSUE-CORPUS source adapter (Wave-3 wiring of the
# anonymized-issue-collection plan). It feeds cp_issue_synth's SHADOW proposals
# into the EXISTING seeker/fixer issue_queue as a NEW source (`source=corpus`),
# reusing the queue machinery + the synth output — it NEVER re-derives proposals.
#
# ⚠ SHADOW-FIRST (RJ decision 2): a synth proposal is a `pending_review` CANDIDATE
# a maintainer PROMOTES out of band. This connector NEVER auto-opens a GitHub
# issue and NEVER enforces anything. That guarantee is STRUCTURAL, not a policy
# flag:
#   * fetch_issues READS shadow proposals from cp_issue_synth.list_proposals only;
#     there is NO code path from this module to github.create_issue / any auto-file
#     channel. It does not import the github connector.
#   * post_resolution + close_issue are inert NO-OPS ({ok: False}) — a shadow
#     proposal has no external source to write back to; promotion is a human act.
#
# INV-F (defense-in-depth): cp_issue_synth already EXCLUDES a security_sensitive
# signal before it can become a proposal, at any team count. This source boundary
# drops any proposal whose coded error_class is in issue_corpus._SECURITY_CLASSES
# (or that carries a security_sensitive flag) a SECOND time — a security signal can
# never enter the public queue even if the synth guarantee ever regressed.
#
# pending-only (RJ#2): only status == "pending_review" proposals are served; an
# already-promoted / enforced proposal is excluded from the feed.
#
# LAZY / OPTIONAL (the MarkItDown clean-install contract): with NO connector config
# block the source is simply inactive (connectors.active() skips it) — the base
# install + stranger-test are unaffected. An absent issue-corpus lib OR an absent
# proposal store degrades to health().active == False / fetch_issues() -> [], never
# a crash. This adapter reads NOTHING but the local isolated corpus namespace; it
# has NO credential (there is no remote source to authenticate to).

from __future__ import annotations

import os
import sys
from typing import List, Optional

from . import Connector, ConnectorConfigError, register

# The issue-corpus libs live in bin/lib (the parent of this connectors package).
# Import them the way every CP job does (bin/lib on sys.path) so we REUSE the synth
# output + the security taxonomy rather than re-deriving either.
_LIB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)

try:
    import cp_issue_synth as _synth  # the SHADOW proposal store reader (list_proposals)
    import issue_corpus as _ic       # the security taxonomy (_SECURITY_CLASSES) — reuse
    _IMPORT_ERR: Optional[str] = None
except Exception as exc:  # pragma: no cover - exercised only on a broken install
    _synth = None
    _ic = None
    _IMPORT_ERR = "issue-corpus lib unavailable: %s" % (exc,)

# The disposition the connector will serve — SHADOW only. A maintainer promotes a
# candidate out of band; this connector never advances a proposal past this state.
_SERVED_STATUS = "pending_review"


class CorpusConnector(Connector):
    """The anonymized-issue-corpus SOURCE adapter. fetch_issues returns RAW
    cp_issue_synth SHADOW proposals (the native `shadow_issue_v1` shape) filtered to
    pending_review, security-excluded, and deduped by proposal_id. normalize() (piece
    b) maps that native shape to the ONE internal issue schema as source=corpus.

    Writeback is intentionally inert: a shadow proposal is promoted by a human, so
    post_resolution / close_issue are no-ops — this connector CANNOT auto-open,
    comment on, or close any external issue."""

    name = "corpus"
    label = "Anonymized Issue Corpus (shadow proposals)"
    kind = "proposal"

    def __init__(self) -> None:
        self._configured = False
        self._home: Optional[str] = None

    # ── configure / health / identity ─────────────────────────────────────────
    def configure(self, cfg: dict) -> None:
        if not isinstance(cfg, dict):
            raise ConnectorConfigError("corpus config must be an object")
        # `active: false` (or an absent block) keeps the source inactive — operator
        # intent, mirrors the other connectors. `home` optionally pins the store
        # root for a hermetic run (defaults to the corpus home). No credential:
        # there is no remote source, so nothing to authenticate.
        self._configured = bool(cfg.get("active", True))
        home = cfg.get("home")
        self._home = str(home) if home else None

    def health(self) -> dict:
        if not self._configured:
            return {"name": self.name, "active": False, "reason": "not configured"}
        if _synth is None:
            return {"name": self.name, "active": False, "reason": _IMPORT_ERR}
        return {"name": self.name, "active": True, "reason": None}

    def identity(self) -> dict:
        return {"name": self.name, "label": self.label, "kind": self.kind}

    # ── fetch (raw native shadow-proposal shape) ──────────────────────────────
    def fetch_issues(self, since: Optional[str] = None) -> List[dict]:
        """Return the pending_review SHADOW proposals from the local isolated corpus
        store (cp_issue_synth.list_proposals) as RAW native items — never a network
        read, never an auto-file. Security-sensitive proposals are dropped (INV-F),
        non-pending proposals are dropped (pending-only), and re-run duplicates are
        collapsed by proposal_id (last snapshot wins). Deterministic order by id."""
        if not self.health()["active"]:
            return []
        try:
            proposals = _synth.list_proposals(self._home)
        except Exception:
            # An unreadable store degrades to no data (lazy/optional), never a crash.
            return []
        deduped: dict = {}
        for prop in proposals:
            if not isinstance(prop, dict):
                continue
            if prop.get("status") != _SERVED_STATUS:
                continue  # pending-only: a promoted/enforced proposal is not re-served
            if self._is_security_sensitive(prop):
                continue  # INV-F: a security proposal NEVER enters the public queue
            pid = prop.get("proposal_id")
            if not pid:
                continue
            deduped[pid] = prop  # last snapshot for a proposal_id wins
        return [deduped[pid] for pid in sorted(deduped)]

    @staticmethod
    def _is_security_sensitive(prop: dict) -> bool:
        """Defense-in-depth INV-F drop at the source boundary: a proposal is
        security-sensitive if it carries a security_sensitive flag OR its coded
        error_class is in the issue_corpus security taxonomy. Reuses the ONE taxonomy
        (issue_corpus._SECURITY_CLASSES) so emit / synth / this boundary can never
        disagree about what counts as sensitive."""
        if prop.get("security_sensitive"):
            return True
        pattern = prop.get("pattern") if isinstance(prop.get("pattern"), dict) else {}
        ec = str(pattern.get("error_class") or "").strip().lower()
        classes = getattr(_ic, "_SECURITY_CLASSES", frozenset()) if _ic is not None else frozenset()
        return ec in classes

    # ── writeback: INERT (SHADOW-first — never auto-files) ────────────────────
    def post_resolution(self, raw_ref: dict, resolution: dict) -> dict:
        """No-op. A shadow proposal has NO external source to comment on — promotion
        is a maintainer act, out of band. This connector NEVER opens or comments on a
        GitHub issue, so a resolved corpus-sourced issue writes nothing back."""
        return {"ok": False, "reason": "shadow-proposal: promoted by a maintainer, never auto-filed"}

    def close_issue(self, raw_ref: dict) -> dict:
        """No-op. There is no external issue to close — a shadow proposal is a local
        candidate, not a filed issue. The connector never auto-files, so it never
        auto-closes."""
        return {"ok": False, "reason": "shadow-proposal: no external issue to close"}


register(CorpusConnector())
