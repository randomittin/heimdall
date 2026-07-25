#!/usr/bin/env python3
# chat_core.py — chat-ops P2 DISPATCH SEAM. The ONE place a chat message becomes an action.
#
# handle_message(chat_id, text) is the funnel BOTH the one-shot `hmd chat handle` and the
# long-poll `hmd chat serve` feed. It:
#   1. classifies the text into exactly one bounded verb (chat_classifier — never raw text),
#   2. for `link`  -> redeems the 6-digit code against this chat_id (chat_link.redeem),
#      for a verb  -> runs the team-scoped read verb (chat_verbs), which itself resolves the
#                     binding and refuses when unbound,
#      for `help`  -> returns the verb list.
# No message is ever handed to an agent as an instruction: no verb => help, unbound => the
# link instruction. This is the CP allowlist principle at the chat boundary.
#
# stdlib-only + chat_classifier / chat_link / chat_verbs.

from __future__ import annotations

import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import chat_classifier
import chat_link
import chat_verbs

# A run of exactly 6 digits anywhere in the message — the link code the user DMs the bot.
_CODE_RE = re.compile(r"\b(\d{6})\b")

HELP_TEXT = (
    "Heimdall chat-ops — I understand these verbs:\n"
    "  status              the bound team's wall + recent verdicts + open denies\n"
    "  investigate [hint]  resume from the team's synced context and triage what's breaking\n"
    "  report              the last session/audit report for the bound team\n"
    "  link <code>         bind this chat to your Heimdall identity (get a code with "
    "`hmd link telegram`)\n"
    "Anything else lands here. (fix / approve / deny arrive in a later phase.)"
)


def _extract_code(text):
    """The first 6-digit run in the message, or None. Pure."""
    if not isinstance(text, str):
        return None
    m = _CODE_RE.search(text)
    return m.group(1) if m else None


def _strip_verb(text):
    """The message with a leading slash-command / `hmd` / verb token removed — the hint that
    rides after `investigate`. Returns "" when nothing remains. Pure."""
    if not isinstance(text, str):
        return ""
    t = text.strip()
    if t.startswith("/"):
        t = t[1:]
    words = t.split()
    if words and words[0].lower() == "hmd":
        words = words[1:]
    if words and words[0].lower() in ("investigate", "triage", "debug", "diagnose"):
        words = words[1:]
    return " ".join(words).strip()


def handle_message(chat_id, text, *, channel=chat_link.DEFAULT_CHANNEL, home=None, repo=None):
    """The dispatch seam. Returns a dict {ok, verb, reply, ...} — `reply` is always the text to
    send back to the chat. NEVER raises on ordinary input; a non-str/blank message is `help`."""
    verb = chat_classifier.classify(text)

    if verb == "link":
        code = _extract_code(text)
        if not code:
            return {"ok": False, "verb": "link", "bound": False,
                    "reply": ("To link, DM me `/hmd link <code>` with the 6-digit code from "
                              "`hmd link telegram` on your enrolled machine.")}
        res = chat_link.redeem(code, chat_id, channel=channel, home=home)
        if res.get("ok"):
            reply = ("Linked. This chat is now bound to team %s — try `status` or "
                     "`investigate`." % (res.get("team_id") or "")[:8])
        else:
            reasons = {
                "invalid_code": "That code isn't valid.",
                "already_used": "That code was already used (single-use).",
                "expired": "That code has expired (codes last 5 minutes).",
                "race": "That code was just consumed elsewhere — mint a fresh one.",
                "io_error": "Couldn't record the binding — try again.",
            }
            reply = reasons.get(res.get("reason"), "Couldn't link with that code.") + \
                " Get a new code with `hmd link telegram`."
        return {"ok": bool(res.get("ok")), "verb": "link",
                "bound": bool(res.get("ok")), "reply": reply, "result": res}

    if verb == "status":
        return chat_verbs.status(chat_id, channel=channel, home=home)

    if verb == "investigate":
        return chat_verbs.investigate(chat_id, hint=_strip_verb(text),
                                      channel=channel, home=home, repo=repo)

    if verb == "report":
        return chat_verbs.report(chat_id, channel=channel, home=home, repo=repo)

    # help (and every unmapped message) — list the verbs, dispatch nothing.
    return {"ok": True, "verb": "help", "bound": None, "reply": HELP_TEXT}
