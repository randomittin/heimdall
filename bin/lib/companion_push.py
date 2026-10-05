#!/usr/bin/env python3
"""companion_push.py -- the SENDING half of phone push notifications (Expo Push Service).

Spec of record: docs/HANDOFF-TO-HEIMDALL-push-notifications.md and docs/superpowers/specs/
2026-10-03-push-notifications.md in the hmdapp repo (read-only inputs). The relay is not involved: hmd
POSTs a short, scrubbed summary straight to Expo, which forwards it to APNs / FCM. An ExpoPushToken is
the only capability needed -- no publisher credential ever sits on a developer's laptop.

WHAT RUNS WHERE. sentinels/hmd-ui.py's StateCache builds one PushMonitor per process and hands it every
state it collects (the same slot the native panel publishers use). `observe` is a few dict lookups: it
detects TRANSITIONS between consecutive states and queues events; a worker thread -- started on the first
event, gone when idle -- does everything else (store read, policy, message build, HTTPS). The poller never
waits on the network, the store, or a lock, and nothing here raises into it.

THE FIVE TRIGGERS (spec 6), each deduped by its key, the first tick after start being a silent baseline:
    question   attention.state == needs_input and attention.id changed          q:<attention id>
    approval   an approvals[].id that was absent in the previous state          p:<approval id>
    error      attention.kind == error and attention.id changed                 e:<attention id>
    gate_red   quality_gate.clear_to_push went true -> false                    g:<tick second>
    finished   a non-idle run of >= HMD_PUSH_MIN_RUN_S (default 60) ended idle/done|stopped   f:<attention id>
               or a new sweep receipt, when no finished went out in the last 120 s            v:<finished_at>

POLICY, in order, per registered device (spec 7): kind filter -> foreground suppression (the app reported
foreground within 900 s and, when the host can tell, the phone is attached; a stale foreground is
unknown) -> approvals go at once (dropped under 5 s of life) / everything else coalesces for
HMD_PUSH_COALESCE_S (default 5) and sends its highest-priority candidate -> at most one non-approval per
10 s, 20 non-approval + 20 approval per rolling hour. Suppressed events still count as handled: nothing is
ever replayed.

OPERATOR TEST (`hmd app push-test`; spec 6 `test`, key t:<request id>). The CLI cannot be the sender: the sender
role is one process per repo, held for life by whichever process sent first, and a process that does not own the
lock drops every event it detects -- a CLI that took the lock to send a test would make the real sender lose an
approval or a question detected meanwhile, and one that sent without it would break the one-sender rule. So the
CLI posts a REQUEST, <repo>/.heimdall/app/push-test ({"v":1,"id":<16 hex>,"at":<epoch s>}, 0600, atomic), and every
monitor looks at that one file with a single stat() per state it observes -- no thread, no poll of its own. The
monitor that owns the sender lock serves it, through the same message builder, scrub, transport, back-off and
DeviceNotRegistered pruning as any event, and answers in <repo>/.heimdall/app/push-test.result:
    {"v":1,"id":..,"state":"sending"|"done","results":[{"device":<8 hex>,"ok":bool,"detail":null|<code>,
                                                           "suppressed":null|"rate-limited"}]}
"sending" is written the moment it takes the request (so the CLI can tell a sender that is slow from none), "done"
carries one entry per registered device and never a token. A request is served only while it is fresh (written <=
60 s ago, not more than 30 s ahead) and unanswered (no result for its id): a leftover file is inert and a
restarted sender never serves one twice. A request that finds no device registered is answered "done" with no
results by any monitor, lock or not (nothing is sent, so there is no sender to be).
What `test` BYPASSES: the kind filter (a phone cannot subscribe to it), foreground suppression, and the coalescing
window with the 10 s spacing that belongs to it -- it is sent at once and is never merged away by a higher-priority
candidate; a real notification waiting in its window is neither delayed nor dropped by it. What still APPLIES: the
20-per-hour cap (a test counts as one non-approval message; the one past the cap is answered "rate-limited"), the
provider back-off and the InvalidCredentials pause (answered "backoff" / "paused"), the sender lock, HMD_PUSH=0,
the loopback-only HMD_PUSH_EXPO_URL rule, the allowlisted text (the constant body, the registered label) and
DeviceNotRegistered pruning.

TEXT (spec 8). A notification carries ONLY allowlisted fields through fixed templates. The one free-text
field is the question summary (and up to 3 option labels): it goes through
companion_ui_attention.secret_shaped (a hit replaces the whole body with a constant) and then `scrub`, a
port of hmdapp's src/diagnostics/redact.ts rules plus the code-span, email, path-basename and sha rules.
approvals[].summary (the command text), paths, branches, repo names, chat text, panels and receipts' sha are
never read. Titles <= 48 and bodies <= 120 UTF-16 units, an ellipsis counting toward the limit.

ONE SENDER PER REPO. Several processes can watch one repo (`hmd ui`, the relay client): the first one
with something to send takes an exclusive flock on <repo>/.heimdall/app/push-sender.lock and holds it
for life; the others drop what they detect. The kernel frees the lock when its owner dies, so another
process takes over at its next event. Nothing touches the lock until a device is registered.

EGRESS. One HTTPS call class, to exp.host, only after a phone registered a token. HMD_PUSH=0 switches the
whole thing off. HMD_PUSH_EXPO_URL redirects the sender for tests and is honoured ONLY for a loopback
host (127.0.0.1 / localhost); anything else is ignored with one error event, so it can never become an
exfiltration switch. Redirects are never followed.

LOGGING. Callers get one event per planned message through `emit`:
    {"event":"push","kind":..,"device":<8 hex of sha256(token)>,"ok":bool,"detail":null|<code>,
     "suppressed":null|"foreground"|"coalesced"|"rate-limited"|"expired"|"disabled-kind","ms":N}
`detail` is an Expo error code, `network`, `http-<status>`, `backoff`, `paused`, `bad-response` or
`store-write-failed`. Never a token, title, body, ref or any text of the session.

STORE. The registered devices live behind bin/lib/companion_push_store.py (load / remove_tokens); this
module never writes them except to drop a token Expo said is gone (DeviceNotRegistered, from a ticket or a
receipt fetched >= 900 s after the send). The store reports when the app last said foreground / background as
an ISO-8601 UTC timestamp (`app_state_at`); it is read here as epoch seconds.

Stdlib only. Loadable by path, like every companion_* module.
"""
import calendar
import collections
import contextlib
import fcntl
import hashlib
import http.client
import json
import math
import os
import re
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from importlib.util import module_from_spec, spec_from_file_location

HERE = os.path.dirname(os.path.abspath(__file__))

PUSH_CAP = "push-v1"
KINDS = ("question", "approval", "error", "gate_red", "finished", "test")
EXPO_SEND_URL = "https://exp.host/--/api/v2/push/send"
EXPO_RECEIPTS_URL = "https://exp.host/--/api/v2/push/getReceipts"
LOOPBACK_HOSTS = ("127.0.0.1", "localhost")

TITLE_MAX = 48
BODY_MAX = 120
OPTION_MAX = 16
OPTIONS_SHOWN = 3
LABEL_MAX = 24
DEFAULT_LABEL = "hmd"
MIN_APPROVAL_TTL_S = 5            # an approval with less life left than this is not worth a notification
QUESTION_FALLBACK = "hmd has a question. Open to answer."
FINISHED_FALLBACK = "Turn ended."
MAX_BATCH = 100                   # Expo: at most 100 messages per request
MAX_RESPONSE_BYTES = 1 << 20
MAX_INPUT = 4000                  # redact.ts: the longest input a scrub looks at
SEEN_CAP = 256                    # dedupe keys remembered
TICKETS_CAP = 100                 # receipt ids remembered
EVENT_QUEUE_CAP = 32              # events waiting for the worker; the oldest is dropped when full
LOCK_REL = os.path.join(".heimdall", "app", "push-sender.lock")
STORE_REL = os.path.join(".heimdall", "app", "push.json")
TEST_REQUEST_REL = os.path.join(".heimdall", "app", "push-test")          # `hmd app push-test` -> the sender
TEST_RESULT_REL = os.path.join(".heimdall", "app", "push-test.result")    # the sender -> `hmd app push-test`
TEST_REQUEST_TTL_S = 60.0         # a request written longer ago than this is never served
TEST_REQUEST_SKEW_S = 30.0        # ... nor one dated further ahead of this clock than this
TEST_FILE_CAP = 4096              # a request or a result is a few hundred bytes; a bigger file is not ours

DEFAULTS = {
    "coalesce_s": 5.0,            # spec 7.5: a non-approval candidate waits this long for a better one
    "min_run_s": 60.0,            # spec 6: a run shorter than this never reports "finished"
    "verdict_gap_s": 120.0,       # spec 6: a sweep receipt is not announced this soon after a finished
    "min_gap_s": 10.0,            # spec 7.6: at most one non-approval message per device per this long
    "hourly_cap": 20,             # spec 7.6: per device, per rolling hour, per class (approval / other)
    "foreground_ttl_s": 900.0,    # spec 7.3: an app_state report older than this is no longer believed
    "timeout_s": 10.0,            # one HTTPS exchange
    "retry_delays": (1, 2, 4),    # spec 7.7: 429 / 5xx / MessageRateExceeded / network
    "backoff_s": 60.0,            # after the retries ran out, no send is attempted for this long
    "pause_s": 3600.0,            # InvalidCredentials: an operator problem, stop sending for this long
    "receipt_after_s": 900.0,     # spec 7.8: receipts are fetched once, this long after the oldest ticket
}

# kind -> (title phrase, channelId, categoryId, interruptionLevel, ttl s). A key whose value is None is omitted.
_KIND_TABLE = {
    "question": ("hmd asks", "hmd-attention", None, "time-sensitive", 3600),
    "approval": ("approval needed", "hmd-attention", "hmd_approval", "time-sensitive", None),
    "error": ("agent error", "hmd-attention", None, "active", 3600),
    "gate_red": ("push gate red", "hmd-updates", None, "active", 3600),
    "finished": (None, "hmd-updates", None, "active", 3600),
    "test": ("test notification", "hmd-updates", None, "active", 600),
}
_FINISHED_PHRASE = {"done": "done, verified", "stopped": "finished, not verified", "verdict": "sweep finished"}
_APPROVAL_TOOLS = frozenset(("Bash", "Write", "Edit", "MultiEdit", "NotebookEdit"))
PRIORITY = {"question": 5, "error": 4, "gate_red": 3, "finished": 2, "test": 1}   # coalescing: highest wins

_EP_RE = re.compile(r"a-[0-9a-f]{10}")
_PID_RE = re.compile(r"p-[0-9a-f]{8}")
_REF_RE = re.compile(r"[0-9a-f]{16}")
_TOKEN_RE = re.compile(r"(?:ExponentPushToken|ExpoPushToken)\[[A-Za-z0-9_-]{8,64}\]")
_CODE_RE = re.compile(r"[A-Za-z0-9_-]{1,40}")
_ISO_UTC_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
_REQUEST_ID_RE = re.compile(r"[0-9a-f]{16}")
_DEVICE_RE = re.compile(r"[0-9a-f]{8}")
_TEST_SUPPRESSED = ("rate-limited",)      # the only reason a test is answered "not sent" besides an Expo / back-off detail


def enabled(environ=None):
    """The kill switch: push is on unless HMD_PUSH is exactly "0"."""
    return (os.environ if environ is None else environ).get("HMD_PUSH") != "0"


def _env_number(env, name, default, low, high):
    try:
        value = float(env.get(name, default))
    except (TypeError, ValueError):
        return default
    return min(high, max(low, value)) if math.isfinite(value) else default


def config_from_env(environ=None):
    """DEFAULTS with the documented HMD_PUSH_* overrides applied, each clamped to its documented range."""
    env = os.environ if environ is None else environ
    cfg = dict(DEFAULTS)
    cfg["coalesce_s"] = _env_number(env, "HMD_PUSH_COALESCE_S", cfg["coalesce_s"], 1, 60)
    cfg["min_run_s"] = _env_number(env, "HMD_PUSH_MIN_RUN_S", cfg["min_run_s"], 0, 3600)
    return cfg


def _load_sibling(name):
    """A sibling bin/lib module by path, or None. Callers treat None as 'unavailable' and fail closed."""
    try:
        spec = spec_from_file_location(name, os.path.join(HERE, name + ".py"))
        mod = module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


_SECRET = {"tried": False, "fn": None}


def _secret_checker():
    """companion_ui_attention.secret_shaped -- reused, never copied. None when it cannot be loaded, in which
    case every free-text field is withheld (fail closed)."""
    if not _SECRET["tried"]:
        _SECRET["tried"] = True
        fn = getattr(_load_sibling("companion_ui_attention"), "secret_shaped", None)
        _SECRET["fn"] = fn if callable(fn) else None
    return _SECRET["fn"]


# ── text: UTF-16 accounting and the scrub pipeline (spec 8.2) ─────────────────────────────────────
def utf16_len(text):
    """Length in UTF-16 code units -- what a JS string, and so the app's limits, count."""
    return len(text.encode("utf-16-le", "surrogatepass")) // 2


def clip(text, limit):
    """`text` unchanged when it fits `limit` UTF-16 units, else cut at a character boundary (never inside a
    surrogate pair) with a trailing ellipsis that counts toward the limit."""
    if utf16_len(text) <= limit:
        return text
    kept, units = [], 0
    for ch in text:
        width = 2 if ord(ch) > 0xFFFF else 1
        if units + width > limit - 1:
            break
        kept.append(ch)
        units += width
    return "".join(kept).rstrip() + "…"


_RE_FLAGS = re.IGNORECASE | re.ASCII          # JS /i and \b \w \d \s semantics: ASCII only
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]+")
_FENCE_RE = re.compile(r"```.*?(?:```|\Z)", re.S)
_SPAN_RE = re.compile(r"`[^`]*`")
_EMAIL_RE = re.compile(r"\S+@\S+\.\w+")
_PATH_RUN_RE = re.compile(r"\S*[/\\]\S*")
_SEPARATORS_RE = re.compile(r"[/\\]+")
_HEX_RUN_RE = re.compile(r"\b[0-9a-fA-F]{7,40}\b", re.ASCII)
_NUMBERS_RE = re.compile(r"(:\d+:\d+)|\b(?:\d{6,}|\d{3}(?: \d{3})+)\b", re.ASCII)
# hmdapp src/diagnostics/redact.ts RULES, in the app's order. The path rule (spec 8.2 step 5) is inserted after
# the first (URL) rule, so the host-path rule below it can no longer match once every run containing a
# separator is down to its basename; it stays so this list remains the app's list, rule for rule.
_URL_RULE = (re.compile(r"\b[a-z][a-z0-9+.-]*:\/\/\S*", _RE_FLAGS), "[url]")
_TAIL_RULES = tuple((re.compile(pattern, _RE_FLAGS), replacement) for pattern, replacement in (
    (r"\?[^\s=&#?]+=[^\s#]*", "?[query]"),
    (r"#[^\s=&#?]+=\S*", "#[fragment]"),
    (r"\b((?:[a-z0-9-]+\.){1,8}[a-z]{2,}(?::\d{1,5})?)\/[^\s?#\"'<>()\[\]{},;]+", r"\1/[path]"),
    (r"\b(bearer)\s+[^\s\"',;]+", r"\1 [redacted]"),
    (r"\b(digest)\s+(?=[\w-]+=)[^\r\n]+", r"\1 [redacted]"),
    (r"\b([\w-]*?(?:pin(?:code)?|passcode|otp)s?)([\"']?\s*[:=]\s*[\"']?)[^\s\"'&,;()\[\]{}]+",
     r"\1\2[redacted]"),
    (r"\b([\w-]*?(?:token|key(?:[_-]?pair)?|secret|passw(?:or)?d|credential|code|sig(?:nature)?|"
     r"auth(?:orization)?|cookie|session(?:[_-]?id)?|sid|nonce)s?)([\"']?\s*[:=]\s*[\"']?)"
     r"(?!\d{1,5}(?!\w))(?:(?:bearer|basic|token|digest)\s+)?[^\s\"'&,;()\[\]{}]+", r"\1\2[redacted]"),
    (r"[A-Za-z0-9+/_-]{20,}={0,2}", "[redacted]"),
))


def _path_tail(match):
    parts = [p for p in _SEPARATORS_RE.split(match.group(0)) if p]
    return parts[-1] if parts else "[path]"


def _sha_or_keep(match):
    run = match.group(0)
    return "[sha]" if any(c.isdigit() for c in run) and any(c.isalpha() for c in run) else run


def scrub(text, limit=BODY_MAX):
    """Spec 8.2 steps 2-7 (step 1, the secret_shaped check, is the caller's): control characters -> space, code
    spans -> [code], emails -> [email], the redact.ts rules with the path rule after the URL rule, hex runs of
    7-40 with a digit and a letter -> [sha], whitespace collapsed, then cut to `limit` UTF-16 units."""
    if not isinstance(text, str):
        return ""
    if len(text) > MAX_INPUT:
        text = re.sub(r"\S+\Z", "", text[:MAX_INPUT])
    out = _CONTROL_RE.sub(" ", text)
    out = _SPAN_RE.sub("[code]", _FENCE_RE.sub("[code]", out))
    out = _EMAIL_RE.sub("[email]", out)
    out = _URL_RULE[0].sub(_URL_RULE[1], out)
    out = _PATH_RUN_RE.sub(_path_tail, out)
    for rx, replacement in _TAIL_RULES:
        out = rx.sub(replacement, out)
    out = _NUMBERS_RE.sub(lambda m: m.group(1) or "[redacted]", out)
    out = _HEX_RUN_RE.sub(_sha_or_keep, out)
    return clip(" ".join(out.split()), limit)


# ── messages (spec 5.5, 8.1) ──────────────────────────────────────────────────────────────────────
def _num(v):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) else None


def _iso_epoch(v):
    """The store's timestamp -- ISO-8601 UTC, whole seconds, trailing Z (`2026-10-03T06:19:00Z`) -- as epoch
    seconds; None for anything that is not exactly that form."""
    if not isinstance(v, str) or _ISO_UTC_RE.fullmatch(v) is None:
        return None
    try:
        return float(calendar.timegm(time.strptime(v, "%Y-%m-%dT%H:%M:%SZ")))
    except (ValueError, OverflowError):
        return None


def _count(v):
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else None


def _duration(seconds):
    minutes, secs = divmod(int(seconds), 60)
    return "%dm%ds" % (minutes, secs) if minutes else "%ds" % secs


def _clean_label(label):
    """The user's own session label, validated as the registration validates it (1..24 UTF-16 units after trim,
    no control characters, no slash); anything else reads as the default."""
    if isinstance(label, str):
        text = label.strip()
        check = _secret_checker()
        if (text and utf16_len(text) <= LABEL_MAX and not _CONTROL_RE.search(text) and "/" not in text
                and "\\" not in text and not (check and check(text))):
            return text
    return DEFAULT_LABEL


def _ref_for(token, ref):
    if isinstance(ref, str) and _REF_RE.fullmatch(ref):
        return ref
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:16]


def _question_body(fields):
    check = _secret_checker()
    summary = fields.get("summary")
    if not isinstance(summary, str) or not summary.strip() or check is None or check(summary):
        return QUESTION_FALLBACK
    body = scrub(summary, BODY_MAX)
    if not body:
        return QUESTION_FALLBACK
    options = fields.get("options")
    labels = []
    for raw in (options if isinstance(options, list) else [])[:OPTIONS_SHOWN]:
        if isinstance(raw, str) and not check(raw):
            shown = scrub(raw, OPTION_MAX)
            if shown:
                labels.append(shown)
    if labels:
        with_options = "%s [%s]" % (body, " / ".join(labels))
        if utf16_len(with_options) <= BODY_MAX:
            body = with_options
    return body


def _gate_body(fields):
    failing, total = _count(fields.get("failing")), _count(fields.get("total"))
    if failing and total and total >= failing:
        return "%d of %d gates failing." % (failing, total)
    return "The push gate turned red."


def _finished_body(fields):
    variant = fields.get("variant")
    passed, total = _count(fields.get("suites_passed")), _count(fields.get("suites_total"))
    if variant == "stopped":
        gate = fields.get("gate")
        return "Turn ended. Push gate %s." % ("clear" if gate is True else "red" if gate is False else "unknown")
    if variant == "verdict":
        return "Suites %d/%d passed." % (passed, total) if passed is not None and total is not None \
            else "The full sweep finished."
    clauses = []
    if fields.get("gate") is True:
        clauses.append("Gates clear.")
    if passed is not None and total is not None:
        clauses.append("Suites %d/%d passed." % (passed, total))
    ran = _num(fields.get("duration_s"))
    if ran is not None and ran >= 0:
        clauses.append("Ran %s." % _duration(ran))
    return " ".join(clauses) or FINISHED_FALLBACK


def build_message(token, event, label, ref, now):
    """One Expo message for `event` (a Planner event) to `token`, or None when there is nothing to send (an
    approval with under MIN_APPROVAL_TTL_S of life left, an unknown kind or finished variant). Every string
    comes from the closed tables above or from an allowlisted field through scrub; see the module docstring."""
    if not isinstance(event, dict) or _KIND_TABLE.get(event.get("kind")) is None:
        return None
    kind, fields = event["kind"], _dict(event.get("fields"))
    phrase, channel, category, level, ttl = _KIND_TABLE[kind]
    ep = event.get("ep")
    data = {"v": 1, "ref": _ref_for(token, ref), "kind": kind, "ep": ep if isinstance(ep, str) and _EP_RE.fullmatch(ep) else None}
    if kind == "approval":
        exp, pid = _num(fields.get("expires_at")), fields.get("pid")
        if exp is None or not (isinstance(pid, str) and _PID_RE.fullmatch(pid)):
            return None
        ttl = int(math.floor(exp - now))
        if ttl < MIN_APPROVAL_TTL_S:
            return None
        tool = fields.get("tool")
        body = "%s is waiting. Deny within %d s." % (tool if tool in _APPROVAL_TOOLS else "A tool", ttl)
        data.update(pid=pid, exp=int(math.floor(exp)))
    elif kind == "question":
        body = _question_body(fields)
    elif kind == "error":
        body = "The session stopped on an error. Open to see it."
    elif kind == "gate_red":
        body = _gate_body(fields)
    elif kind == "finished":
        phrase = _FINISHED_PHRASE.get(fields.get("variant"))
        if phrase is None:
            return None
        body = _finished_body(fields)
    else:
        body = "Notifications from this laptop work."
    ref = data["ref"]
    message = {"to": token, "title": clip("%s · %s" % (_clean_label(label), phrase), TITLE_MAX),
               "body": body, "data": data}
    if category:
        message["categoryId"] = category
    message.update(channelId=channel, priority="high", interruptionLevel=level, sound="default", ttl=ttl,
                   collapseId="%s.%s" % (ref, kind), tag="%s.%s" % (ref, kind), threadId=ref)
    return message


# ── the planner: transitions between consecutive states (spec 6) ──────────────────────────────────
_NON_IDLE = frozenset(("working", "needs_input", "needs_approval"))
_ATT_STATES = frozenset(("working", "needs_input", "needs_approval", "idle", "ended"))


def _dict(v):
    return v if isinstance(v, dict) else {}


def _list(v):
    return v if isinstance(v, list) else []


def _reduce(state):
    """The few fields the triggers read, typed and validated -- everything else in `state` is dropped here, so
    nothing outside this allowlist can reach an event. None for a state that is not a dict."""
    if not isinstance(state, dict):
        return None
    att = _dict(state.get("attention"))
    att_id = att.get("id")
    gate = _dict(state.get("quality_gate")).get("clear_to_push")
    rows = [g for g in _list(_dict(state.get("ledger")).get("gates")) if isinstance(g, dict)]
    receipt = _dict(state.get("sweep_receipt"))
    finished_at = receipt.get("finished_at")
    approvals = []
    for item in _list(state.get("approvals")):
        if isinstance(item, dict) and isinstance(item.get("id"), str) and _PID_RE.fullmatch(item["id"]):
            tool = item.get("tool")
            approvals.append({"id": item["id"], "tool": tool if isinstance(tool, str) else None,
                              "expires_at": _num(item.get("expires_at"))})
    summary, kind = att.get("summary"), att.get("kind")
    return {
        "att_state": att.get("state") if att.get("state") in _ATT_STATES else None,
        "att_id": att_id if isinstance(att_id, str) and _EP_RE.fullmatch(att_id) else None,
        "att_kind": kind if isinstance(kind, str) else None,
        "summary": summary if isinstance(summary, str) else None,
        "options": [o["label"] for o in _list(att.get("options"))
                    if isinstance(o, dict) and isinstance(o.get("label"), str)][:OPTIONS_SHOWN],
        "approvals": approvals,
        "approval_ids": frozenset(a["id"] for a in approvals),
        "gate": gate if isinstance(gate, bool) else None,
        "failing": sum(1 for g in rows if g.get("state") == "deny") if rows else None,
        "total": len(rows) if rows else None,
        "receipt_at": finished_at if (isinstance(finished_at, str) and finished_at) or _num(finished_at) is not None
        else None,
        "suites_passed": _count(receipt.get("suites_passed")),
        "suites_total": _count(receipt.get("suites_total")),
        "duration_s": _num(receipt.get("duration_s")),
    }


class Planner:
    """Turns a stream of states into events. Stateful (the previous state, when the current non-idle run began,
    the keys already handled) and NOT thread-safe: the monitor serialises calls. Each call returns the events
    of that tick, in a fixed order: question, approval, error, gate_red, finished, verdict."""

    def __init__(self, config=None):
        cfg = dict(DEFAULTS)
        cfg.update(config or {})
        self._min_run = cfg["min_run_s"]
        self._verdict_gap = cfg["verdict_gap_s"]
        self._prev = None
        self._run_start = None
        self._last_finished = None
        self._seen = collections.OrderedDict()

    def observe(self, state, now):
        cur = _reduce(state)
        if cur is None:
            return []
        prev, self._prev = self._prev, cur
        events = self._events(prev, cur, now) if prev is not None else []
        if cur["att_state"] in _NON_IDLE:
            if self._run_start is None:
                self._run_start = now
        else:
            self._run_start = None
        return events

    def _events(self, prev, cur, now):
        events = []

        def emit(kind, key, fields):
            if key in self._seen:
                return
            self._seen[key] = now
            while len(self._seen) > SEEN_CAP:
                self._seen.popitem(last=False)
            events.append({"kind": kind, "key": key, "ep": cur["att_id"], "fields": fields})
            if kind == "finished":
                self._last_finished = now

        changed = cur["att_id"] is not None and cur["att_id"] != prev["att_id"]
        if cur["att_state"] == "needs_input" and changed:
            emit("question", "q:" + cur["att_id"], {"summary": cur["summary"], "options": cur["options"]})
        for item in cur["approvals"]:
            if item["id"] not in prev["approval_ids"]:
                emit("approval", "p:" + item["id"],
                     {"tool": item["tool"], "pid": item["id"], "expires_at": item["expires_at"]})
        if cur["att_kind"] == "error" and changed:
            emit("error", "e:" + cur["att_id"], {})
        if prev["gate"] is True and cur["gate"] is False:
            emit("gate_red", "g:%d" % int(now), {"failing": cur["failing"], "total": cur["total"]})
        ran_long_enough = self._run_start is not None and now - self._run_start >= self._min_run
        if (prev["att_state"] in _NON_IDLE and cur["att_state"] == "idle" and cur["att_id"] is not None
                and cur["att_kind"] in ("done", "stopped") and ran_long_enough):
            if cur["att_kind"] == "done":
                emit("finished", "f:" + cur["att_id"],
                     {"variant": "done", "gate": cur["gate"], "suites_passed": cur["suites_passed"],
                      "suites_total": cur["suites_total"], "duration_s": cur["duration_s"]})
            else:
                emit("finished", "f:" + cur["att_id"], {"variant": "stopped", "gate": cur["gate"]})
        quiet = self._last_finished is None or now - self._last_finished >= self._verdict_gap
        if cur["receipt_at"] is not None and cur["receipt_at"] != prev["receipt_at"] and quiet:
            emit("finished", "v:%s" % (cur["receipt_at"],),
                 {"variant": "verdict", "suites_passed": cur["suites_passed"], "suites_total": cur["suites_total"]})
        return events


# ── transport: the Expo Push Service over urllib ──────────────────────────────────────────────────
def resolve_endpoint(environ=None, emit=None):
    """(send_url, receipts_url, loopback). HMD_PUSH_EXPO_URL redirects the sender for tests and is honoured ONLY
    for an http(s) URL whose host is exactly 127.0.0.1 or localhost; anything else is ignored with ONE error event
    that does not echo the value, so the override can never become an exfiltration switch."""
    env = os.environ if environ is None else environ
    raw = env.get("HMD_PUSH_EXPO_URL")
    if not raw:
        return EXPO_SEND_URL, EXPO_RECEIPTS_URL, False
    try:
        parts = urllib.parse.urlsplit(raw)
        host = parts.hostname
    except ValueError:
        parts, host = None, None
    if parts is not None and parts.scheme in ("http", "https") and host in LOOPBACK_HOSTS:
        return raw, urllib.parse.urljoin(raw, "getReceipts"), True
    if emit is not None:
        emit({"event": "error", "detail": "push: HMD_PUSH_EXPO_URL ignored (only a loopback http(s) URL is honoured)"})
    return EXPO_SEND_URL, EXPO_RECEIPTS_URL, False


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect is an error here: a push body is never re-sent anywhere the endpoint did not name."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _failure(detail):
    return {"ok": False, "detail": detail, "id": None}


def _ticket_result(ticket):
    """One Expo ticket (or receipt) -> {"ok", "detail", "id"}. `detail` is Expo's own error code when it is
    code-shaped, else the generic "error": nothing a server says is ever copied further than that."""
    if isinstance(ticket, dict) and ticket.get("status") == "ok":
        ticket_id = ticket.get("id")
        return {"ok": True, "detail": None, "id": ticket_id if isinstance(ticket_id, str) and ticket_id else None}
    code = _dict(_dict(ticket).get("details")).get("error")
    return _failure(code if isinstance(code, str) and _CODE_RE.fullmatch(code) else "error")


class Sender:
    """HTTPS to Expo. `send` posts a batch with the spec's retry rule and returns one result per message;
    `get_receipts` fetches receipts once. Never raises: every failure is a result with a `detail` code, and
    nothing it returns or logs contains a token."""

    def __init__(self, send_url, receipts_url, loopback, timeout, retry_delays, wait):
        self.send_url = send_url
        self.receipts_url = receipts_url
        self.timeout = timeout
        self.retry_delays = tuple(retry_delays)
        self.wait = wait            # wait(seconds) -> True when the process is stopping and retrying should stop
        handlers = [_NoRedirect()]
        if loopback:                # a loopback endpoint is never routed through an environment proxy
            handlers.insert(0, urllib.request.ProxyHandler({}))
        self._opener = urllib.request.build_opener(*handlers)

    def _post(self, url, payload):
        """(status, parsed JSON | None, detail | None): detail is None only for a 200 with a JSON body."""
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(
            url, data=body, method="POST",
            headers={"accept": "application/json", "content-type": "application/json", "user-agent": "hmd-push/1"})
        try:
            with self._opener.open(request, timeout=self.timeout) as response:
                status = response.status
                raw = response.read(MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as err:
            err.close()
            return err.code, None, "http-%d" % err.code
        except (urllib.error.URLError, OSError, ValueError, http.client.HTTPException):
            return None, None, "network"
        if status != 200:
            return status, None, "http-%d" % status
        try:
            data = json.loads(raw.decode("utf-8")) if len(raw) <= MAX_RESPONSE_BYTES else None
        except ValueError:
            data = None
        return (status, data, None) if isinstance(data, dict) else (status, None, "bad-response")

    def send(self, messages):
        """-> (results, gave_up). results[i] answers messages[i]. A 429, a 5xx, a network failure or a
        MessageRateExceeded ticket is retried after each of retry_delays; gave_up is True when they ran out."""
        results = [_failure("network") for _ in messages]
        pending = list(range(len(messages)))
        attempt = 0
        while True:
            status, data, detail = self._post(self.send_url, [messages[i] for i in pending])
            retry = []
            if detail is None:
                tickets = data.get("data")
                if isinstance(tickets, list) and len(tickets) == len(pending):
                    for i, ticket in zip(pending, tickets):
                        results[i] = _ticket_result(ticket)
                        if results[i]["detail"] == "MessageRateExceeded":
                            retry.append(i)
                else:
                    for i in pending:
                        results[i] = _failure("bad-response")
            else:
                for i in pending:
                    results[i] = _failure(detail)
                if detail == "network" or status == 429 or (status is not None and status >= 500):
                    retry = list(pending)
            pending = retry
            if not pending:
                return results, False
            if attempt >= len(self.retry_delays):
                return results, True
            if self.wait(self.retry_delays[attempt]):
                return results, False
            attempt += 1

    def get_receipts(self, ids):
        """{ticket id: "ok" | <error code>} for the receipts Expo has, or None when the fetch failed."""
        _, data, detail = self._post(self.receipts_url, {"ids": list(ids)})
        body = data.get("data") if detail is None else None
        if not isinstance(body, dict):
            return None
        codes = {}
        for ticket_id, receipt in body.items():
            result = _ticket_result(receipt)
            codes[ticket_id] = "ok" if result["ok"] else result["detail"]
        return codes


# ── the monitor: observe -> policy -> send, one sender per repo ───────────────────────────────────
_PUSH_KINDS = frozenset(("question", "approval", "error", "gate_red", "finished"))


def _fingerprint(token):
    """8 hex of sha256(token): the only trace of a device that ever reaches a log."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:8]


def _devices_from(raw):
    """The store's answer -> {"devices": {fingerprint: record}, "app_state", "app_state_at" (epoch seconds, from the
    store's ISO timestamp)}, or None when it is not the documented shape. A token that is not ExpoPushToken-shaped
    is skipped: only a valid token ever leaves."""
    if not isinstance(raw, dict):
        return None
    devices = {}
    for item in _list(raw.get("tokens")):
        token = item.get("token") if isinstance(item, dict) else None
        if not (isinstance(token, str) and _TOKEN_RE.fullmatch(token)) or _fingerprint(token) in devices:
            continue
        wanted = [k for k in _list(item.get("events")) if k in _PUSH_KINDS]
        platform = item.get("platform")
        devices[_fingerprint(token)] = {"token": token, "ref": item.get("ref"), "label": item.get("label"),
                                        "platform": platform if platform in ("ios", "android") else None,
                                        "events": frozenset(wanted) if wanted else _PUSH_KINDS}
    state = raw.get("app_state")
    return {"devices": devices, "app_state": state if state in ("foreground", "background", "unknown") else "unknown",
            "app_state_at": _iso_epoch(raw.get("app_state_at"))}


# ── operator test: `hmd app push-test` asks the sender for one `test` message per device ──────────
# The module docstring says why it is a request and not a send. These are the two files and the five functions
# both sides use; PushMonitor._serve_test is the sender's half.
def _read_small_json(path):
    """The JSON object in `path`, or None: a missing, oversized, unparsable or non-object file is simply no record."""
    try:
        with open(path, "rb") as f:
            raw = f.read(TEST_FILE_CAP + 1)
    except OSError:
        return None
    if len(raw) > TEST_FILE_CAP:
        return None
    try:
        obj = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return obj if isinstance(obj, dict) else None


def _write_private_json(path, obj):
    """Replace `path` with `obj`, atomically and privately: a fully written, fsynced 0600 temp file renamed into
    place, so a reader sees the old file or the new one and never half of either. Raises OSError."""
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = "%s.tmp-%d-%s" % (path, os.getpid(), secrets.token_hex(4))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(obj, sort_keys=True, separators=(",", ":")))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def registered_devices(root, store=None):
    """[{"device": <8 hex of sha256(token)>, "platform": "ios" | "android" | None}] for every registered token the
    sender would send to, in registry order -- what `hmd app push-test` counts and lists. Never a token. `store`
    reads the registry (default bin/lib/companion_push_store.py, whose load() never raises: no registry is no
    devices); raises RuntimeError when that module cannot be loaded."""
    store = store if store is not None else _load_sibling("companion_push_store")
    if store is None:
        raise RuntimeError("bin/lib/companion_push_store.py could not be loaded")
    data = _devices_from(store.load(root))
    return [{"device": fp, "platform": rec["platform"]} for fp, rec in (data["devices"] if data else {}).items()]


def request_test(root, now=None):
    """Ask the sender of this repo for a test notification: write the request it watches, return its id (16 hex).
    Raises OSError when the request cannot be written."""
    request_id = secrets.token_hex(8)
    _write_private_json(os.path.join(root, TEST_REQUEST_REL),
                        {"v": 1, "id": request_id, "at": int(time.time() if now is None else now)})
    return request_id


def withdraw_test_request(root, request_id):
    """Remove the request when it is still `request_id`'s -- nobody picked it up, so a sender that starts later
    must not find it. Another request's file is left alone."""
    path = os.path.join(root, TEST_REQUEST_REL)
    held = _read_small_json(path)
    if held is not None and held.get("id") == request_id:
        with contextlib.suppress(OSError):
            os.unlink(path)


def read_test_request(root, now):
    """The request a sender should serve, {"id", "at"}, or None: well-formed, written no more than
    TEST_REQUEST_TTL_S before `now` (or TEST_REQUEST_SKEW_S after it), and not yet answered -- a result for its id,
    "sending" included, means some sender has it."""
    held = _dict(_read_small_json(os.path.join(root, TEST_REQUEST_REL)))
    request_id, at = held.get("id"), _num(held.get("at"))
    if not (isinstance(request_id, str) and _REQUEST_ID_RE.fullmatch(request_id)) or at is None:
        return None
    if not -TEST_REQUEST_SKEW_S <= now - at <= TEST_REQUEST_TTL_S:
        return None
    if read_test_result(root, request_id) is not None:
        return None
    return {"id": request_id, "at": at}


def read_test_result(root, request_id):
    """The sender's answer to `request_id` -- {"state": "sending" | "done", "results": [{"device", "ok", "detail",
    "suppressed"}]} -- or None when there is none yet. Every field is re-validated on the way in: a result file is
    only ever read, never trusted."""
    held = _read_small_json(os.path.join(root, TEST_RESULT_REL))
    if held is None or held.get("id") != request_id or held.get("state") not in ("sending", "done"):
        return None
    results = []
    for item in _list(held.get("results")):
        item = _dict(item)
        device, ok, detail, suppressed = item.get("device"), item.get("ok"), item.get("detail"), item.get("suppressed")
        if not (isinstance(device, str) and _DEVICE_RE.fullmatch(device) and isinstance(ok, bool)):
            continue
        results.append({"device": device, "ok": ok,
                        "detail": detail if isinstance(detail, str) and _CODE_RE.fullmatch(detail) else None,
                        "suppressed": suppressed if suppressed in _TEST_SUPPRESSED else None})
    return {"state": held["state"], "results": results}


class PushMonitor:
    """One per process and repo. `observe(state)` is what the host's poller calls on every collected state: it only
    plans (cheap, never blocks, never raises) and queues events for a worker thread that starts on the first event
    and ends when idle. `step(now)` is that worker's whole body, public so a test can drive it with a clock.

    store     object with load(root) / remove_tokens(root, tokens); default bin/lib/companion_push_store.py
    emit      callable receiving the log dicts of the module docstring; settable after construction
    attached  callable -> truthy when the phone is attached (the relay client's `last_delivered`); None = unknown
    config    overrides over DEFAULTS and the HMD_PUSH_* environment; sleep / clock exist for tests"""

    def __init__(self, root, store=None, emit=None, config=None, clock=None, sleep=None, attached=None,
                 environ=None, start_thread=True):
        self.root = root
        self.store = store
        self.emit = emit
        self.attached = attached
        self._env = os.environ if environ is None else environ
        self._cfg = config_from_env(self._env)
        self._cfg.update(config or {})
        self._clock = clock or time.time
        self._sleep = sleep
        self.enabled = enabled(self._env)
        self._start_thread = start_thread
        self._planner = Planner(self._cfg)
        self._cv = threading.Condition()
        self._step_lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = None
        self._pending = collections.deque(maxlen=EVENT_QUEUE_CAP)   # (detected_at, event); the oldest falls off when full
        self._tests = collections.deque(maxlen=EVENT_QUEUE_CAP)     # request ids of `hmd app push-test`, waiting for the worker
        self._test_stamp = None         # (mtime, size, inode) of the request file as last looked at
        self._test_last = None          # id of the last request queued: a touched file is not served twice
        self._last_ts = None
        self._devices = {}              # fingerprint -> runtime record (window, last_sent, hourly counters)
        self._ready = []                # approvals to send in this step: (fingerprint, event)
        self._tickets = collections.deque(maxlen=TICKETS_CAP)       # (ticket id, token, sent_at), for receipts
        self._receipt_retry_at = 0.0
        self._backoff_until = 0.0
        self._paused_until = 0.0
        self._sender = None
        self._lock_fd = None
        self._reported = set()

    # -- the caller's side: cheap, never raises ------------------------------------------------------
    def observe(self, state, now=None):
        if not self.enabled or self._stop.is_set():
            return
        try:
            now = self._clock() if now is None else now
            self._watch_test_request()
            ts = state.get("ts") if isinstance(state, dict) else None
            with self._cv:
                if _num(ts) is not None:
                    if self._last_ts is not None and ts < self._last_ts:
                        return          # an older collection that finished late: never a transition
                    self._last_ts = ts
                events = self._planner.observe(state, now)
                if not events:
                    return
                self._pending.extend((now, event) for event in events)
                self._wake_locked()
        except Exception as exc:
            self._error_once("observe", exc)

    def _watch_test_request(self):
        """One stat() of the operator's request file per observed state. A request that is new -- a different stamp,
        then a fresh, well-formed, unanswered id -- is queued for the worker, which decides the rest."""
        try:
            st = os.stat(os.path.join(self.root, TEST_REQUEST_REL))
        except OSError:
            return
        stamp = (st.st_mtime_ns, st.st_size, st.st_ino)
        with self._cv:
            if stamp == self._test_stamp:
                return
            self._test_stamp = stamp
        request = read_test_request(self.root, self._clock())
        if request is None:
            return
        with self._cv:
            if request["id"] == self._test_last:
                return
            self._test_last = request["id"]
            self._tests.append(request["id"])
            self._wake_locked()

    def _wake_locked(self):
        """Make sure the worker thread is running and tell it there is work. The caller holds self._cv."""
        if self._start_thread and (self._thread is None or not self._thread.is_alive()):
            self._thread = threading.Thread(target=self._run, name="hmd-push", daemon=True)
            self._thread.start()
        self._cv.notify()

    def close(self):
        """Stop the worker and give up the sender role. Safe to call twice."""
        self._stop.set()
        with self._cv:
            self._cv.notify_all()
        worker = self._thread
        if worker is not None and worker is not threading.current_thread():
            worker.join(2.0)
        fd, self._lock_fd = self._lock_fd, None
        if fd is not None:
            with contextlib.suppress(OSError):
                fcntl.flock(fd, fcntl.LOCK_UN)
            with contextlib.suppress(OSError):
                os.close(fd)

    # -- the worker ----------------------------------------------------------------------------------
    def _run(self):
        while not self._stop.is_set():
            try:
                self.step()
            except Exception as exc:
                self._error_once("worker", exc)
            with self._cv:
                if self._stop.is_set():
                    return
                if not (self._pending or self._tests or self._tickets
                        or any(d["window"] for d in self._devices.values())):
                    self._thread = None
                    return
                if not (self._pending or self._tests):
                    self._cv.wait(self._next_wait(self._clock()))

    def _next_wait(self, now):
        due = [30.0]
        for dev in self._devices.values():
            window = dev["window"]
            if window:
                at = window["opened"] + self._cfg["coalesce_s"]
                if dev["last_sent"] is not None:
                    at = max(at, dev["last_sent"] + self._cfg["min_gap_s"])
                due.append(at - now)
        if self._tickets:
            due.append(max(self._tickets[0][2] + self._cfg["receipt_after_s"], self._receipt_retry_at) - now)
        return max(0.05, min(due))

    def step(self, now=None):
        """One worker pass: take queued events through the policy, send what is due, serve operator test requests,
        fetch receipts that are due."""
        with self._step_lock:
            now = self._clock() if now is None else now
            with self._cv:
                batch = list(self._pending)
                self._pending.clear()
                tests = list(self._tests)
                self._tests.clear()
            if batch:
                self._accept(batch, now)
            self._flush(now)
            for request_id in tests:
                self._serve_test(request_id, now)
            self._poll_receipts(now)

    # -- policy --------------------------------------------------------------------------------------
    def _accept(self, batch, now):
        data = self._load()
        if data is None or not data["devices"] or not self._own_lock():
            return
        foreground = self._foreground(data, now)
        for fp in [fp for fp in self._devices if fp not in data["devices"]]:
            del self._devices[fp]
        for detected_at, event in batch:
            for fp, record in data["devices"].items():
                dev = self._runtime(fp, record)
                if event["kind"] not in record["events"]:
                    self._log(event["kind"], fp, False, None, "disabled-kind", 0)
                elif foreground:
                    self._log(event["kind"], fp, False, None, "foreground", 0)
                elif event["kind"] == "approval":
                    self._ready.append((fp, event))
                elif dev["window"] is None:
                    dev["window"] = {"opened": detected_at, "cands": [event]}
                else:
                    dev["window"]["cands"].append(event)

    def _runtime(self, fp, record):
        """The in-memory state of one device (coalescing window, last send, hourly counters), created on first
        sight, with its latest registry record."""
        dev = self._devices.setdefault(fp, {"window": None, "last_sent": None,
                                            "sent_other": collections.deque(), "sent_approval": collections.deque()})
        dev["rec"] = record
        return dev

    def _foreground(self, data, now):
        """Spec 7.3: the app said foreground, recently, and (when the host can tell) the phone is attached. A report
        older than foreground_ttl_s is no longer believed: it reads as unknown."""
        at = data["app_state_at"]
        if data["app_state"] != "foreground" or at is None or now - at > self._cfg["foreground_ttl_s"]:
            return False
        if self.attached is None:
            return True
        try:
            return bool(self.attached())
        except Exception:
            return False            # cannot tell -> push: a redundant banner beats a missed notification

    def _capped(self, sent, now):
        while sent and now - sent[0] > 3600.0:
            sent.popleft()
        return len(sent) >= self._cfg["hourly_cap"]

    def _flush(self, now):
        out = []
        ready, self._ready = self._ready, []
        for fp, event in ready:
            dev = self._devices[fp]
            if self._capped(dev["sent_approval"], now):
                self._log("approval", fp, False, None, "rate-limited", 0)
                continue
            message = self._message(dev, event, now)
            if message is None:
                self._log("approval", fp, False, None, "expired", 0)
                continue
            dev["sent_approval"].append(now)
            out.append((fp, event, message))
        for fp, dev in self._devices.items():
            window = dev["window"]
            if not window:
                continue
            due = window["opened"] + self._cfg["coalesce_s"]
            if dev["last_sent"] is not None:
                due = max(due, dev["last_sent"] + self._cfg["min_gap_s"])
            if now < due:
                continue
            dev["window"] = None
            best = max(window["cands"], key=lambda e: PRIORITY[e["kind"]])
            for event in window["cands"]:
                if event is not best:
                    self._log(event["kind"], fp, False, None, "coalesced", 0)
            if self._capped(dev["sent_other"], now):
                self._log(best["kind"], fp, False, None, "rate-limited", 0)
                continue
            message = self._message(dev, best, now)
            if message is None:
                self._log(best["kind"], fp, False, "unbuildable", None, 0)
                continue
            dev["last_sent"] = now
            dev["sent_other"].append(now)
            out.append((fp, best, message))
        if out:
            self._send(out, now)

    def _message(self, dev, event, now):
        record = dev["rec"]
        return build_message(record["token"], event, record["label"], record["ref"], now)

    def _serve_test(self, request_id, now):
        """`hmd app push-test`: ONE `test` message to every registered device, answered through push-test.result.

        Only the owner of the sender lock serves it -- a monitor that does not own it stays quiet and the owner answers
        -- so a test goes through the one process that sends the real notifications, with its back-off and its
        counters. It skips the kind filter, foreground suppression and the coalescing window (so the 10 s spacing);
        it still obeys the hourly cap, the back-off / pause, the lock and the kill switch (see the module docstring)."""
        data = self._load()
        if data is None:
            return                                       # the registry could not be read: _load reported it
        devices = data["devices"]
        if not devices:
            self._test_result(request_id, "done", [])    # nothing to send to, so there is no sender to be: any monitor may say so
            return
        if not self._own_lock():
            return
        self._test_result(request_id, "sending", [])
        event = {"kind": "test", "key": "t:" + request_id, "ep": None, "fields": {}}
        answers, out = {}, []
        for fp, record in devices.items():
            dev = self._runtime(fp, record)
            if self._capped(dev["sent_other"], now):
                self._log("test", fp, False, None, "rate-limited", 0)
                answers[fp] = {"device": fp, "ok": False, "detail": None, "suppressed": "rate-limited"}
                continue
            dev["sent_other"].append(now)
            out.append((fp, event, self._message(dev, event, now)))
        for fp, ok, detail in self._send(out, now) if out else []:
            answers[fp] = {"device": fp, "ok": ok, "detail": detail, "suppressed": None}
        self._test_result(request_id, "done", [answers[fp] for fp in devices])

    def _test_result(self, request_id, state, results):
        """Write the answer the CLI is waiting for. A write that fails costs the CLI its answer, never the send."""
        try:
            _write_private_json(os.path.join(self.root, TEST_RESULT_REL),
                                {"v": 1, "id": request_id, "state": state, "results": results})
        except OSError as exc:
            self._error_once("test-result", exc)

    # -- sending -------------------------------------------------------------------------------------
    def _send(self, out, now):
        """POST `out` -- [(fingerprint, event, message)] -- in batches of MAX_BATCH, log every message and act on what
        Expo says about each. Returns [(fingerprint, ok, detail)] for every message, in order."""
        sender = self._get_sender()
        outcomes = []
        for start in range(0, len(out), MAX_BATCH):
            chunk = out[start:start + MAX_BATCH]
            if now < self._paused_until or now < self._backoff_until:
                why = "paused" if now < self._paused_until else "backoff"
                for fp, event, _ in chunk:
                    self._log(event["kind"], fp, False, why, None, 0)
                    outcomes.append((fp, False, why))
                continue
            began = time.monotonic()
            results, gave_up = sender.send([message for _, _, message in chunk])
            took = int((time.monotonic() - began) * 1000)
            for (fp, event, message), res in zip(chunk, results):
                self._log(event["kind"], fp, res["ok"], res["detail"], None, took)
                outcomes.append((fp, res["ok"], res["detail"]))
                if res["ok"] and res["id"]:
                    self._tickets.append((res["id"], message["to"], now))
                elif res["detail"] == "DeviceNotRegistered":
                    self._forget(message["to"])
                elif res["detail"] == "InvalidCredentials":
                    self._paused_until = now + self._cfg["pause_s"]
            if gave_up:
                self._backoff_until = now + self._cfg["backoff_s"]
        return outcomes

    def _poll_receipts(self, now):
        """Spec 7.8: once, >= receipt_after_s after the oldest ticket; only DeviceNotRegistered changes anything."""
        if not self._tickets or now < self._receipt_retry_at \
                or now - self._tickets[0][2] < self._cfg["receipt_after_s"]:
            return
        owners = {ticket_id: token for ticket_id, token, _ in self._tickets}
        got = self._get_sender().get_receipts(list(owners))
        if got is None:
            self._receipt_retry_at = now + self._cfg["backoff_s"]
            return
        self._tickets.clear()
        for ticket_id, code in got.items():
            if code == "DeviceNotRegistered" and ticket_id in owners:
                self._forget(owners[ticket_id])

    def _forget(self, token):
        """Expo says this device is gone: drop it from the store and from memory."""
        self._devices.pop(_fingerprint(token), None)
        try:
            self._store().remove_tokens(self.root, [token])
        except Exception as exc:
            self._error_once("store-remove", exc)

    def _wait(self, seconds):
        if self._sleep is not None:
            self._sleep(seconds)
            return self._stop.is_set()
        return self._stop.wait(seconds)

    def _get_sender(self):
        if self._sender is None:
            send_url, receipts_url, loopback = resolve_endpoint(self._env, self._emit)
            self._sender = Sender(send_url, receipts_url, loopback, self._cfg["timeout_s"],
                                  self._cfg["retry_delays"], self._wait)
        return self._sender

    # -- the store, the lock, the log ----------------------------------------------------------------
    def _store(self):
        if self.store is None:
            self.store = _load_sibling("companion_push_store")
        return self.store

    def _load(self):
        store = self._store()
        if store is None:
            self._error_once("store-import")
            return None
        try:
            data = _devices_from(store.load(self.root))
        except Exception as exc:
            self._error_once("store-load", exc)
            return None
        if data is None:
            self._error_once("store-load")
        return data

    def _own_lock(self):
        """True when THIS monitor is the one sender of the repo: it holds an exclusive flock on the lock file, taken
        at the first event that has a registered device to tell and never released before close() / process exit."""
        if self._lock_fd is not None:
            return True
        path = os.path.join(self.root, LOCK_REL)
        try:
            os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
            fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        except OSError as exc:
            self._error_once("lock", exc)
            return False
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)                # another process (or monitor) is the sender: it reports, this one stays quiet
            return False
        except OSError as exc:
            os.close(fd)
            self._error_once("lock", exc)
            return False
        self._lock_fd = fd
        return True

    def _emit(self, obj):
        if self.emit is None:
            return
        try:
            self.emit(obj)
        except Exception:
            return None                 # a logging fault must never cost a push

    def _log(self, kind, fp, ok, detail, suppressed, ms):
        self._emit({"event": "push", "kind": kind, "device": fp, "ok": ok, "detail": detail,
                    "suppressed": suppressed, "ms": ms})

    def _error_once(self, key, exc=None):
        if key in self._reported:
            return
        self._reported.add(key)
        self._emit({"event": "error",
                    "detail": "push: %s failed%s" % (key, " (%s)" % exc.__class__.__name__ if exc is not None else "")})


def source_paths(root):
    """What the sender touches under the repo, for `hmd ui --print-sources`."""
    return [os.path.join(root, STORE_REL), os.path.join(root, LOCK_REL)]
