#!/usr/bin/env python3
"""runhmd_card -- render a runhmd.verdict/1 document as the 40-column verdict card (plan 5.3).

The JSON verdict is canonical; the card is only a render of it, built from nothing but the
document's own fields. Nothing here is invented: no receipt line without a receipt_url, no
finding that is not in `findings`.

Layout (exact, byte for byte, as in plan 5.3): every line is 40 terminal columns. A row is
`│ ` + text padded to 37 columns + `│`. The shield counts as 2 columns (it renders as an
emoji), every other glyph as 1. A finding is `✗ ` + its title, word-wrapped; continuation
lines are indented under the title.
"""
from __future__ import annotations

import textwrap
import unicodedata

WIDTH = 40
TEXT_WIDTH = WIDTH - 3          # "│ " on the left, "│" on the right
MARK = "✗ "
MAX_FINDINGS = 5
_WIDE = {"\U0001F6E1"}          # SHIELD: emoji presentation, two columns


def display_width(text):
    """Terminal columns `text` occupies."""
    return sum(2 if ch in _WIDE or unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in text)


def _fit(text):
    """Truncate with an ellipsis so a long value can never push the right border out."""
    if display_width(text) <= TEXT_WIDTH:
        return text
    while text and display_width(text) > TEXT_WIDTH - 1:
        text = text[:-1]
    return text + "…"


def _row(text=""):
    text = _fit(text)
    return "│ " + text + " " * (TEXT_WIDTH - display_width(text)) + "│"


def _blank():
    return "│" + " " * (WIDTH - 2) + "│"


def _duration(seconds):
    if seconds < 60:
        return "%.1fs" % seconds
    minutes, rest = divmod(int(round(seconds)), 60)
    return "%dm %ds" % (minutes, rest)


def _finding_rows(findings):
    rows = []
    for finding in findings[:MAX_FINDINGS]:
        lines = textwrap.wrap(finding["title"], width=TEXT_WIDTH - len(MARK), break_long_words=True, break_on_hyphens=False)
        for index, line in enumerate(lines or [""]):
            rows.append(_row((MARK if index == 0 else " " * len(MARK)) + line))
    if len(findings) > MAX_FINDINGS:
        rows.append(_row("+%d more finding(s) in the JSON" % (len(findings) - MAX_FINDINGS)))
    return rows


def render_card(doc):
    """The card for one verdict document, newline-terminated."""
    attacks = doc["attacks"]
    lines = [
        "╭" + "─" * (WIDTH - 2) + "╮",
        _row("\U0001F6E1 runhmd attack"),
        _blank(),
        _row("VERDICT: %s" % doc["verdict"]),
        _blank(),
        _row("%d attacks · %d survived · %d killed" % (attacks["total"], attacks["survived"], attacks["killed"])),
        _blank(),
    ]
    if doc["findings"]:
        lines += _finding_rows(doc["findings"])
        lines.append(_blank())
    lines.append(_row("Cost: $%.2f · Time: %s" % (doc["cost_usd"], _duration(doc["duration_s"]))))
    if doc.get("receipt_url"):
        lines.append(_row("Evidence → " + doc["receipt_url"].split("://", 1)[-1]))
    lines.append("╰" + "─" * (WIDTH - 2) + "╯")
    return "\n".join(lines) + "\n"
