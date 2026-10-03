#!/usr/bin/env python3
"""companion_cc_login.py -- sign the laptop's Claude Code in from the paired phone (capability `login-v1`).

Design of record: hmdapp's docs/HANDOFF-TO-HEIMDALL-remote-cc-login.md and
docs/superpowers/specs/2026-10-03-remote-cc-login.md (read-only inputs from the hmdapp repo). The phone
asks (sealed `login_start`), hmd runs `claude auth login` on a PTY, validates the authorize URL the CLI
prints against an exact allowlist and publishes it in the sealed state (`state.login.request`); the user
signs in in the phone's browser, the page shows `CODE#STATE`, the phone sends it back sealed
(`login_code`) and hmd types it into the waiting CLI, then verifies the outcome with `claude auth status`
and reports it in `state.login.result`. Nothing here talks to the relay: bin/heimdall-relay-client owns
the wire, this module owns the login.

Facts about Claude Code 2.1.288 this code stands on (read from its binary, not guessed):
  * `claude auth login [--console]` prints `Opening browser to sign in...`, then
    `If the browser didn't open, visit: <URL>`, then the prompt `Paste code here if prompted > ` (no
    trailing newline), and never exits on its own. It needs no TTY; the PTY is only there so it behaves
    as it does for a person.
  * The pasted text is read as a LINE from stdin and split on `#`: BOTH `CODE` and `STATE` must be
    non-empty, else the CLI prints `Invalid code. Please make sure the full code was copied.` on stderr
    and keeps waiting. Hence submit_code refuses a code without `#STATE` (bad-code) before it is spent.
  * Success prints `Login successful.` and exits 0; failure prints `Login failed: <reason>` on stderr and
    exits 1. (`OAuth error`, the marker the handoff guessed, does not occur; it is still honoured.)
  * `claude auth status` prints JSON {loggedIn, authMethod, apiProvider, analyticsDisabled,
    projectsDirectory, configDirectory[, apiKeySource][, email, orgId, orgName, subscriptionType]} and
    exits 0 iff loggedIn. A console login is reported as authMethod `api_key` with apiKeySource
    `/login managed key`; an ANTHROPIC_API_KEY from the environment as `api_key` with another source.

What this module guarantees (each is a test in test/companion-cc-login-*.test.sh):
  * validate_url: only an https authorize URL on an allowlisted (host, path) with the pinned manual
    redirect_uri, PKCE-shaped challenge/state, no repeated keys, no userinfo/port/punycode/fragment, at
    most 2048 chars, for the kind that was asked for, ever reaches the phone. The rows, redirect values and
    the code shape are DATA (docs/samples/login/allowlist.json), not code.
  * The login CODE is a secret: it exists only inside the sealed `login_code` command, in one local
    variable between normalize_code and one os.write to the PTY. It is never logged, evented, stored, put
    in state or echoed in an ack; the PTY has ECHO off; the 16 KiB output buffer is process memory only
    and is dropped when the session ends. No exception message here ever contains caller input.
  * One login at a time (a global flock), 3 starts per 600 s, 300 s of life, the whole process group
    killed (SIGTERM, then SIGKILL) on every terminal state, an orphan sweep at relay-client start.
  * After the code is written the outcome is always verified (`claude auth status`) and the identity is
    compared with the pin the operator set at the laptop; a different account is logged out again.

Stdlib only. Loadable by path (the convention of bin/lib/companion_ui_*.py), no import-time side effects.
"""
import hashlib
import json
import os
import re
import urllib.parse

HERE = os.path.dirname(os.path.realpath(__file__))
# The vendored allowlist (hmdapp's docs/samples/login/allowlist.json, checksum-pinned by
# test/companion-cc-login-vectors.test.sh): URL rows, redirect values, PKCE shape, code shape.
ALLOWLIST_PATH = os.path.normpath(os.path.join(HERE, "..", "..", "docs", "samples", "login", "allowlist.json"))

CAP_LOGIN = "login-v1"
ACTIONS = ("login_start", "login_code", "login_cancel")
KINDS = ("claudeai", "console")
MANAGED_KEY_SOURCE = "/login managed key"  # apiKeySource of `claude auth status` after a console login
ASCII_WHITESPACE = " \t\n\r\f\v"

_PRINTABLE_ASCII = re.compile(r"[\x21-\x7e]+")


class LoginError(Exception):
    """A login request was refused or ended. `code` is the machine-readable string that becomes the ack's
    `detail` (start/code/cancel) or `result.detail` (spec 4.3 / 4.5). The message names the rule and never
    echoes anything the phone or the CLI sent."""

    def __init__(self, code, message=None):
        super().__init__(message or code)
        self.code = code


# -- the allowlist ------------------------------------------------------------------------------------
class _AllowlistError(Exception):
    """allowlist.json is missing or malformed: nothing can be validated, so everything is refused."""


_allowlist_cache = {}  # path -> ((mtime_ns, size), parsed)


def _text(value):
    if not isinstance(value, str):
        raise TypeError("expected a string")
    return value


def _parse_allowlist(doc):
    rows = []
    for row in doc["rows"]:
        kind = _text(row["kind"])
        if kind not in KINDS:
            raise ValueError("unknown kind")
        rows.append({"kind": kind, "host": _text(row["host"]), "path": _text(row["path"]),
                     "redirect_uri": _text(row["redirect_uri"])})
    if not rows:
        raise ValueError("no rows")
    required = {_text(k): _text(v) for k, v in doc["required_query"].items()}
    cap = doc["max_url_length"]
    code_cap = doc["code_max_length"]
    if not all(isinstance(n, int) and not isinstance(n, bool) and n > 0 for n in (cap, code_cap)):
        raise ValueError("lengths must be positive integers")
    return {
        "rows": rows,
        "required": required,
        "pkce_keys": [_text(k) for k in doc["pkce_keys"]],
        "pkce_re": re.compile(_text(doc["pkce_regex"]), re.ASCII),
        "nonempty_keys": [_text(k) for k in doc["nonempty_keys"]],
        "max_url_length": cap,
        "code_re": re.compile(_text(doc["code_regex"]), re.ASCII),
        "code_max_length": code_cap,
    }


def _allowlist(path=None):
    path = path or ALLOWLIST_PATH
    try:
        st = os.stat(path)
        stamp = (st.st_mtime_ns, st.st_size)
        cached = _allowlist_cache.get(path)
        if cached is not None and cached[0] == stamp:
            return cached[1]
        with open(path, "rb") as f:
            raw = f.read(65537)
        if len(raw) > 65536:
            raise ValueError("allowlist.json is implausibly large")
        parsed = _parse_allowlist(json.loads(raw.decode("utf-8")))
    except (OSError, ValueError, KeyError, TypeError, AttributeError, re.error) as e:
        raise _AllowlistError(type(e).__name__) from None
    _allowlist_cache[path] = (stamp, parsed)
    return parsed


def _parse_query(query):
    """The query's pairs as a dict of decoded key -> decoded value. Every pair must be `key=value` with a
    key, no key may repeat once decoded, and the percent-escapes must be valid UTF-8: whatever is
    ambiguous about the query is refused rather than interpreted."""
    params = {}
    for pair in query.split("&"):
        key, equals, value = pair.partition("=")
        if not equals or not key:
            raise LoginError("bad-url", "the query is malformed")
        try:
            key = urllib.parse.unquote_plus(key, errors="strict")
            value = urllib.parse.unquote_plus(value, errors="strict")
        except UnicodeDecodeError:
            raise LoginError("bad-url", "the query has an invalid percent-escape") from None
        if key in params:
            raise LoginError("bad-url", "a query key is repeated")
        params[key] = value
    return params


def validate_url(url, kind):
    """The authorize URL's host when `url` passes spec 3.2 for `kind`, else LoginError("host-not-allowed")
    when its (host, path) is not an allowlist row, else LoginError("bad-url"). Nothing is normalised or
    decoded before it is judged (no lower-casing, no dot-segment or percent-decoding of the path), so the
    string checked is the string a browser would be handed."""
    try:
        allow = _allowlist()
    except _AllowlistError:
        raise LoginError("host-not-allowed", "the allowlist is unavailable") from None
    # rule 1: the form of the URL
    if not isinstance(url, str) or _PRINTABLE_ASCII.fullmatch(url) is None or "\\" in url:
        raise LoginError("bad-url", "the URL is not a plain printable-ASCII string")
    scheme, separator, rest = url.partition("://")
    if not separator or scheme != "https":
        raise LoginError("bad-url", "the scheme is not https")
    authority = re.split(r"[/?#]", rest, maxsplit=1)[0]
    if not authority or "@" in authority or ":" in authority:
        raise LoginError("bad-url", "the URL has userinfo, a port or no host")
    if authority != authority.lower() or "xn--" in authority:
        raise LoginError("bad-url", "the host is not lower-case ASCII or is punycode")
    before_fragment, hash_sep, _fragment = rest[len(authority):].partition("#")
    path, _question, query = before_fragment.partition("?")
    # rule 2: the (host, path) pair is a row
    row = next((r for r in allow["rows"] if r["host"] == authority and r["path"] == path), None)
    if row is None:
        raise LoginError("host-not-allowed", "the host and path are not on the allowlist")
    # rule 3: the query
    if hash_sep:
        raise LoginError("bad-url", "the URL carries a fragment")
    params = _parse_query(query)
    for key, want in allow["required"].items():
        if params.get(key) != want:
            raise LoginError("bad-url", "a required query parameter is missing or wrong")
    if params.get("redirect_uri") != row["redirect_uri"]:
        raise LoginError("bad-url", "redirect_uri is not the pinned manual callback")
    for key in allow["pkce_keys"]:
        if allow["pkce_re"].fullmatch(params.get(key, "")) is None:
            raise LoginError("bad-url", "code_challenge or state is not a base64url value of the allowed length")
    for key in allow["nonempty_keys"]:
        if not params.get(key):
            raise LoginError("bad-url", "a required query parameter is empty")
    # rule 4: the length
    if len(url) > allow["max_url_length"]:
        raise LoginError("bad-url", "the URL is longer than the allowed maximum")
    # rule 5: the kind the caller asked for
    if row["kind"] != kind:
        raise LoginError("bad-url", "the URL is for the other login kind")
    return authority


def normalize_code(raw):
    """`raw` with ASCII whitespace trimmed, when it is a code of the shape of spec 4.4 (`CODE` or
    `CODE#STATE`); else LoginError("bad-code"). Only ASCII whitespace is trimmed (a no-break space or an
    ideographic space is part of the value, so it is refused), and the shape is a full match: no control
    byte, no second `#`, nothing outside [A-Za-z0-9._~-] can reach the PTY."""
    if not isinstance(raw, str):
        raise LoginError("bad-code", "the code is not a string")
    try:
        allow = _allowlist()
    except _AllowlistError:
        raise LoginError("bad-code", "the code shape is unavailable") from None
    code = raw.strip(ASCII_WHITESPACE)
    if len(code) > allow["code_max_length"] or allow["code_re"].fullmatch(code) is None:
        raise LoginError("bad-code", "the code is not CODE or CODE#STATE of the allowed shape")
    return code


def mask_account(email):
    """`r...@example.com` for r@example.com: the first character of the local part, an ellipsis, `@` and the
    domain. None for anything that is not one plain address. The phone only ever sees this, never the
    address (the state frame is sealed to the operator's own phone; the mask keeps screenshots low-value)."""
    if not isinstance(email, str) or email.count("@") != 1:
        return None
    local, domain = email.split("@")
    if not local or not domain or any(ch.isspace() or ord(ch) < 0x20 for ch in email):
        return None
    return local[0] + "…@" + domain


def identity_fingerprint(status):
    """sha256 hex of the account `claude auth status` JSON names -- its e-mail (case-folded) and organisation
    id -- or None when nobody is signed in or the account cannot be told. Method, organisation name and
    plan are deliberately left out: the same person signing in again through the console must stay the same
    identity, and a renamed organisation must not lock the operator out."""
    if not isinstance(status, dict) or status.get("loggedIn") is not True:
        return None
    email = status.get("email")
    if not isinstance(email, str) or not email.strip():
        return None
    org = status.get("orgId")
    canonical = json.dumps([email.strip().lower(), org.strip().lower() if isinstance(org, str) else ""],
                           separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()
