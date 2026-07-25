#!/usr/bin/env python3
# chat_classifier.py — chat-ops P2 VERB CLASSIFIER (§1: the bounded verb set).
#
# THE INVARIANT: classify(text) is PURE and TOTAL — it returns EXACTLY ONE of the P2 verbs
#   {status, investigate, report, link, help}
# for ANY input, and NEVER returns raw text. A message is never handed to an agent as an
# instruction; free text maps to a bounded verb, and anything unmapped maps to `help` (which
# lists the verbs). This is the CP allowlist principle applied to natural language: no verb =>
# no action.
#
# P3 verbs (fix / approve / deny) are ABSENT in P2, so they classify as `help` — the bot will
# not pretend to offer a capability it cannot yet run. When P3 lands it adds those verbs here.
#
# stdlib-only, no IO, no state — a pure function so the oracle/tests pin it exactly.

from __future__ import annotations

# The closed set classify() may ever return. Anything outside this set is a bug.
VERBS = ("status", "investigate", "report", "link", "help")

# First-token verb synonyms. The FIRST word of a normalized message (after stripping a
# leading slash-command and an optional "hmd" prefix) is matched here before any phrase
# heuristics — an explicit verb always wins.
_FIRST_TOKEN = {
    "link": "link", "connect": "link", "bind": "link", "pair": "link",
    "status": "status", "wall": "status", "roster": "status",
    "report": "report", "audit": "report",
    "investigate": "investigate", "triage": "investigate",
    "debug": "investigate", "diagnose": "investigate",
    "help": "help", "start": "help", "commands": "help", "verbs": "help", "?": "help",
    # P3 verbs are absent in P2 -> help (never dispatch fix/approve/deny).
    "fix": "help", "approve": "help", "deny": "help",
}

# Free-text intent phrases (substring match on the normalized message) — the "what's
# breaking this" -> investigate mapping (§1). Checked in this order; the first hit wins.
_INVESTIGATE_PHRASES = (
    "breaking", "broken", "failing", "what's wrong", "whats wrong", "what is wrong",
    "why red", "why is it red", "what happened", "what broke", "gate red", "red gate",
    "see what", "look into", "whats failing", "what's failing", "investigate",
)
_STATUS_PHRASES = (
    "status", "how are we", "everything ok", "everything okay", "are we green",
    "any denies", "open denies", "the wall", "who's online", "whos online",
)
_REPORT_PHRASES = (
    "report", "last audit", "sleep report", "audit report", "the report",
)


def _normalize(text):
    """Lower-case, strip, drop a single leading slash and an optional leading `hmd` token.
    Returns (normalized_text, first_token). Pure."""
    t = text.strip().lower()
    if t.startswith("/"):
        t = t[1:]
    words = t.split()
    if words and words[0] == "hmd":
        words = words[1:]
    t = " ".join(words)
    return t, (words[0] if words else "")


def classify(text):
    """Map ANY message to exactly one P2 verb. Total: non-str / empty / unmapped -> "help".
    Never returns raw text."""
    if not isinstance(text, str):
        return "help"
    t, first = _normalize(text)
    if not t:
        return "help"
    # 1) An explicit first-token verb wins (incl. P3 verbs -> help).
    if first in _FIRST_TOKEN:
        return _FIRST_TOKEN[first]
    # 2) Free-text intent: investigate is the wedge ("what's breaking"), then status/report.
    for phrase in _INVESTIGATE_PHRASES:
        if phrase in t:
            return "investigate"
    for phrase in _STATUS_PHRASES:
        if phrase in t:
            return "status"
    for phrase in _REPORT_PHRASES:
        if phrase in t:
            return "report"
    # 3) Unmapped -> help (lists the verbs). NEVER the raw text, NEVER a dispatch.
    return "help"
