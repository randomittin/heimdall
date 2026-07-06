# claude_cred.py — SANITIZE + VALIDATE a Claude BYO credential at the INGESTION
# boundary. The single shape oracle shared by BOTH the client (`rr connect`) and the
# server (POST /team/cred), so the two sides agree on exactly one token grammar.
#
# WHY THIS EXISTS (bug #23). `claude setup-token` prints a DECORATED INTERACTIVE UI —
# spinner frames, "Welcome to Claude Code", "Your OAuth token:", an authorize URL, all
# wrapped in ANSI/terminal control sequences — NOT a clean token on stdout. An operator
# onboarded with `export CLAUDE_CODE_OAUTH_TOKEN="$(claude setup-token)"`, so the captured
# value was the whole ~2199-char decorated dump with the real 108-char sk-ant-oat token
# buried inside. That blob became the per-team Secret Manager cred -> `claude` received
# `Bearer <ansi junk>` -> "Header has invalid value" -> interactive-login fallback ->
# GATE_FAILED, 0 files, every run. Defense at the boundary: the client EXTRACTS the clean
# token before signing/posting; the server REFUSES a secret that is not a clean single
# token regardless. Neither side ever trusts a decorated blob.

from __future__ import annotations

import re

# ── the two Claude BYO credential shapes (design §1) ───────────────────────────
#   oauth : sk-ant-oat<NN>-<body>   (`claude setup-token` — the user's subscription)
#   apikey: sk-ant-api<NN>-<body>   (a metered console key)
# <NN> is a two-digit version; <body> is base64url-ish [A-Za-z0-9_-]. A real oauth token
# is ~108 chars (a 13-char "sk-ant-oat01-" prefix + a ~95-char body). We bound the body
# 20..180 so a too-short fragment never validates and an over-long blob never masquerades
# as one whole token.
_BODY = r"[A-Za-z0-9_-]{20,180}"
_OAUTH_RE = re.compile(r"\Ask-ant-oat[0-9]{2}-%s\Z" % _BODY)
_API_RE = re.compile(r"\Ask-ant-api[0-9]{2}-%s\Z" % _BODY)
_ANY_RE = re.compile(r"\Ask-ant-(?:oat|api)[0-9]{2}-%s\Z" % _BODY)
# The UN-anchored finder that pulls a token candidate OUT of a decorated blob.
_FIND_RE = re.compile(r"sk-ant-(?:oat|api)[0-9]{2}-%s" % _BODY)

# ANSI / terminal control sequences the setup-token UI emits, stripped before matching:
#   CSI  ESC [ ... final byte  — color SGR, cursor moves, line clears, spinner frames.
#   OSC  ESC ] ... BEL|ST      — window-title sets.
#   ESC  ESC <2nd byte>        — other two-byte escapes.
_CSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
_OSC_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
_ESC_RE = re.compile(r"\x1b[@-_]")
# Any remaining C0 control char or DEL (includes newlines/tabs/carriage returns and a
# stray lone ESC) — turned into a space so adjacent tokens split cleanly.
_CTRL_RE = re.compile(r"[\x00-\x1f\x7f]")

# The hard ceiling for a stored Claude secret. A real token is ~108 chars; nothing
# legitimate approaches this. Anything longer is a decorated blob or garbage — refused.
MAX_SECRET_LEN = 200

# The kinds this oracle knows (mirrors cp_team_creds.ENV_FOR_KIND).
KIND_OAUTH_TOKEN = "oauth_token"
KIND_API_KEY = "api_key"


def _sanitize(raw):
    """Strip ANSI/OSC/ESC control sequences from `raw` and turn every remaining control
    character (newlines, tabs, stray ESC) into a space, so token candidates are cleanly
    delimited. Returns "" for a non-str input."""
    if not isinstance(raw, str):
        return ""
    s = _OSC_RE.sub("", raw)   # OSC first (its BEL/ST terminator is itself a control char).
    s = _CSI_RE.sub("", s)
    s = _ESC_RE.sub("", s)
    s = _CTRL_RE.sub(" ", s)
    return s


def extract_claude_token(raw):
    """Return the single clean sk-ant-* token recoverable from `raw`, else None.

    Strips the setup-token UI's ANSI/terminal control sequences + banner, then finds every
    sk-ant-(oat|api)NN-<body> candidate. Returns the token iff EXACTLY ONE distinct valid
    token is present; None when zero (junk / no token) or two-or-more DISTINCT tokens
    (ambiguous) are found. A single token repeated is fine (a banner may echo it once).
    NEVER returns a value that still carries junk — the result is a whole, clean token."""
    found = _FIND_RE.findall(_sanitize(raw))
    if not found:
        return None
    if len(set(found)) != 1:      # zero handled above; >1 distinct == ambiguous.
        return None
    tok = found[0]
    return tok if _ANY_RE.match(tok) else None   # belt-and-braces: whole, clean token only.


def is_valid_claude_secret(secret, kind):
    """Server-side shape gate (defense-in-depth): True iff `secret` is a CLEAN single token
    of the right shape for `kind`. Refuses anything that carries a control char, exceeds
    MAX_SECRET_LEN, or does not match the sk-ant-oat (oauth_token) / sk-ant-api (api_key)
    grammar. The server refuses a decorated/oversized/garbage secret even though the client
    already sanitizes — so a bad value is NEVER stored regardless of how it arrived."""
    if not isinstance(secret, str) or not secret:
        return False
    if len(secret) > MAX_SECRET_LEN:
        return False
    if _CTRL_RE.search(secret):   # any control char (ANSI/newline/tab) -> not a clean token.
        return False
    if kind == KIND_OAUTH_TOKEN:
        return bool(_OAUTH_RE.match(secret))
    if kind == KIND_API_KEY:
        return bool(_API_RE.match(secret))
    return False
