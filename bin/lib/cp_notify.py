#!/usr/bin/env python3
# cp_notify.py — piece (f) of the Heimdall control plane: NOTIFY (§8).
#
# DESIGN DOSSIER §8 (authoritative) + §11 risk row "Notify becomes a command channel
# by accretion". Server -> instance/owner messages: alerts, job-complete pings,
# gate-needs-approval notices.
#
# THE ONE INVARIANT — A NOTIFICATION IS DATA, NEVER A COMMAND. This is the INVERSE of
# the refused RCE (§1/§2): the server never opens a reverse channel that makes an
# instance run something. A notification is a message PAYLOAD the recipient RENDERS;
# there is NO field by which it can be made to execute anything. The command channel
# does not exist by construction:
#   • the payload schema is CLOSED — {schema_version, kind, ts, target_haid, job_id?,
#     action_id?, text, extra} and NOTHING else. There is no action_type / cmd /
#     command / exec / dispatch / handler / shell / eval field in the schema, and a
#     caller that tries to smuggle one (via `extra`) has it STRIPPED before the
#     payload is built — _strip_command_keys() drops any command-shaped key.
#   • `notification_executes(n) -> False` ALWAYS. The module exposes this property so
#     the inverse-of-RCE is a falsifiable, asserted fact, not a comment. There is no
#     execute_/dispatch_/run_ symbol, and the module runs no child process or code
#     evaluator of any kind — it only reads + writes data files.
#   • the instance INBOX is a poll-only data file: deliver_inbox() appends a payload,
#     poll() reads payloads back as DATA. An instance pulls notifications; it NEVER
#     receives an inbound command socket. Reading a notification cannot run anything.
#
# EGRESS — REUSE the existing connectors VERBATIM (§0/§11 reuse ledger): notify sends
# OUT via connectors.slack / connectors.email through the Connector.post_resolution
# egress verb. It does NOT rebuild egress. A notification is mapped into the
# connector's resolution shape ({summary, url}) and delivered. LAZY / OPTIONAL: an
# inactive connector (absent creds -> health().active == False) is SKIPPED — that
# channel is inactive, no crash (the MarkItDown graceful-degrade). The inbox channel
# always delivers (it is the in-band instance channel), so notify never hard-fails.
#
# NO-SECRET-BY-CONSTRUCTION — REUSE telemetry._scrub VERBATIM (never re-derive). The
# notification `text` and every `extra` value pass through _scrub: bounded to
# <=120 chars AND rejected (dropped) if they match a gitleaks high-signal pattern or
# look like an assigned credential. A secret CANNOT enter a notification payload (and
# therefore cannot reach the wire or the audit) by construction. Every send is
# AUDITED via cp_audit.write (what kind was sent to whom — no secret VALUES).
#
# THE ROUTE SEAM (§10) — register_notify_routes() plugs GET /notifications into the
# server via cp_server.register_route WITHOUT editing cp_server. The route is a
# POLL: an instance reads ITS notifications back as data (the authenticated HAID
# scopes the inbox). There is no inbound command route — by construction.
#
# stdlib-only (json/os/uuid/datetime) + the sibling cp_audit + telemetry + the
# connectors package — minimal self-host deps.

from __future__ import annotations

import datetime
import os
import sys
import uuid

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_state      # the pluggable persistence backend (Wave 0). The inbox is an
                    # append-only NDJSON log written THROUGH a StateBackend
                    # (get_backend) so the same flush-only append/scan becomes durable
                    # on Cloud Run (Wave-2 FirestoreBackend) WITHOUT changing this store.
                    # The local backend is byte-identical to the prior NDJSON-to-
                    # HEIMDALL_HOME path, and it owns heimdall_home() resolution (notify
                    # no longer needs issue_queue directly — the backend re-derives home).
import telemetry     # REUSE _scrub — the no-secret-by-construction discipline (§8).
import cp_audit      # REUSE the audit writer — every send is audited (§8/§9).
import connectors    # REUSE the egress (slack/email) — notify sends OUT, never rebuilds it.

# ── schema constants (the CLOSED notification contract — §8) ──────────────────

SCHEMA_VERSION = "1.0.0"

# The notification KIND enum (§8). build_notification REJECTS any other kind (returns
# None) — the schema is closed, like telemetry's EVENT_TYPES + cp_audit's AUDIT_EVENTS.
KINDS = ("job_complete", "approval_needed", "alert")

# The audit event a notify send is recorded under (§8/§9). A notify is NOT a dispatch
# and carries NO action through the allowlist — so it is NEVER recorded under the
# security-loaded events (dispatch/dispatch_refused/override/auth_fail), which must
# stay exclusive to real security acts. cp_audit.AUDIT_EVENTS is a CLOSED enum owned
# by piece (a) (it has no `notify` member); we therefore map each notify KIND to its
# closest VALID, OPERATIONAL audit event, carrying the true kind in `action_type` so a
# search-by-kind still works. NO secret values enter (params-shape + scrubbed detail).
#   • approval_needed -> "approval"  — the EXACT §7 match: the owner is pinged that an
#                                      action entered `pending`. (decision stays None.)
#   • job_complete    -> "job_state" — a job-lifecycle-adjacent operational notice.
#   • alert           -> "job_state" — the generic operational bucket (least security-
#                                      polluting valid event; the kind names the rest).
_KIND_AUDIT_EVENT = {
    "approval_needed": "approval",
    "job_complete": "job_state",
    "alert": "job_state",
}
# The default operational event for any kind not explicitly mapped above.
_DEFAULT_AUDIT_EVENT = "job_state"

# The COMMAND-SHAPED keys a hostile caller might try to smuggle through `extra`. ANY
# of these (case-insensitive) is STRIPPED before the payload is built — the inverse of
# the §1 allowlist's refusal: a notification simply has no place to carry a command.
# This is the §11 "command channel by accretion" guard, enforced not advised.
_COMMAND_KEYS = frozenset({
    "action_type", "cmd", "command", "exec", "dispatch", "handler",
    "shell", "eval", "run", "subprocess", "system", "popen", "script",
})

# The bound for the inbox poll (cap how many pending payloads a poll returns).
_POLL_MAX = 500


# ── store location + backend (the persistence SEAM — Wave 0/§8) ───────────────
#
# The notify inbox addresses its store by paths RELATIVE to
# ${HEIMDALL_HOME}/control-plane/ (the StateBackend rel namespace): the notify dir is
# "notify/", one HAID's inbox is "notify/{inbox_name}.ndjson". The backend owns the
# home root + makedirs + the byte shape; notify_dir/inbox_path remain the public
# absolute-path accessors (now derived from the backend's path(), so they stay
# byte-identical to the prior layout).

# the rel sub-dir all notification inboxes live under, within control-plane/.
_NOTIFY_REL = "notify"


def _backend(home=None):
    """The StateBackend for the notify inbox (HEIMDALL_STATE_BACKEND, default local).
    `home` pins the store root exactly as every notify accessor's `home=` arg always
    has — threaded straight through, no re-derivation of heimdall_home() here."""
    return cp_state.get_backend(home=home)


def _inbox_name(target_haid):
    """A filesystem-safe inbox file name for a HAID. The HAID is a deterministic
    identity name; we replace path separators so it never escapes the notify dir."""
    safe = "".join(c if (c.isalnum() or c in "._-") else "_" for c in str(target_haid))
    return safe or "anon"


def _inbox_rel(target_haid):
    """The store-relative path of one HAID's append-only inbox: notify/{name}.ndjson."""
    return os.path.join(_NOTIFY_REL, _inbox_name(target_haid) + ".ndjson")


def notify_dir(home=None):
    """The notify inbox store dir: ${HEIMDALL_HOME}/control-plane/notify/ (the backend's
    absolute path for the notify rel-dir — unchanged on the local backend)."""
    return _backend(home).path(_NOTIFY_REL)


def inbox_path(target_haid, home=None):
    """Absolute path to a target HAID's append-only notification inbox (NDJSON)."""
    return _backend(home).path(_inbox_rel(target_haid))


def _inbox_path_or_none(target_haid, home=None):
    """The local on-disk path of a HAID's inbox, or None when the selected backend has no
    local file for it. On the LOCAL backend this is the real path; on a non-filesystem
    backend (FirestoreBackend) path() RAISES BackendUnavailable by design (the inbox is an
    external doc, not an on-disk file) — and the notify/deliver path (reached from
    dispatch / job_complete / approval) must NOT raise over a cosmetic path lookup (the
    firestore-only incident class). The notification is already durably appended via
    append_line; this returns None on firestore so deliver_inbox's result carries an
    honest 'no local file' instead of crashing the request path."""
    try:
        return inbox_path(target_haid, home)
    except cp_state.BackendUnavailable:
        return None


def _now_iso():
    """Current UTC time as a second-precision ISO-8601 string (§8 ts field)."""
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
    )


# ── the command-key stripper (the §11 inverse-of-RCE guard) ───────────────────


def _strip_command_keys(extra):
    """Reduce a caller-supplied `extra` to bounded scalar tags with EVERY command-
    shaped key DROPPED (§8/§11). A notification carries no command by construction:
    a key in _COMMAND_KEYS (case-insensitive) is removed, and every surviving value
    passes through telemetry._scrub (bounded + secret-rejected). Returns a flat dict
    of safe scalar tags. A non-dict yields {}.

    This is the falsifiable guard: a hostile caller jamming {"cmd": "rm -rf /"} into
    a notification gets it STRIPPED here — the command never enters the payload."""
    if not isinstance(extra, dict):
        return {}
    out = {}
    for k, v in extra.items():
        key = str(k)
        if key.strip().lower() in _COMMAND_KEYS:
            continue  # command-shaped key -> DROPPED (no command channel by accretion)
        bounded_key = key[:telemetry._SCRUB_MAX]
        cleaned = telemetry._scrub(v)
        if cleaned is not None:
            out[bounded_key] = cleaned
    return out


# ── the ONE notification builder (the CLOSED, DATA-ONLY schema — §8) ──────────


def build_notification(kind, *, text=None, target_haid=None, job_id=None,
                       action_id=None, extra=None):
    """Assemble ONE schema-validated, secret-scrubbed, DATA-ONLY notification (§8).
    Returns the payload dict, or None when `kind` is not in KINDS (an invalid kind is
    dropped, never built). Pure — no IO.

    The payload schema is CLOSED — only these keys exist:
      {schema_version, kind, ts, target_haid, job_id, action_id, text, extra}
    There is NO action_type/cmd/command/exec/dispatch/handler field, and `extra` has
    every command-shaped key STRIPPED (_strip_command_keys). `text` is scrubbed (no
    secret enters by construction). A notification is a message the recipient RENDERS
    — it cannot be made to run anything (the inverse of the refused RCE, §2)."""
    if kind not in KINDS:
        return None
    return {
        "schema_version": SCHEMA_VERSION,
        "kind": kind,  # one of KINDS — a data tag, NEVER a command/action_type.
        "ts": _now_iso(),
        "target_haid": telemetry._scrub(str(target_haid)) if target_haid else None,
        "job_id": telemetry._scrub(str(job_id)) if job_id else None,
        "action_id": telemetry._scrub(str(action_id)) if action_id else None,
        "text": telemetry._scrub(text) if text is not None else None,
        "extra": _strip_command_keys(extra),
    }


def notification_executes(notification):  # noqa: ARG001 — the arg is intentional.
    """THE inverse-of-RCE property, exposed as a falsifiable fact (§8/§11): a
    notification NEVER causes the recipient to execute anything. This ALWAYS returns
    False — there is no code path in this module (or anywhere it reaches) that takes a
    notification and runs it. The recipient renders text; it cannot be commanded.

    Asserting this in a test pins the property: were notify ever to grow a command
    channel, this contract is the thing that must change — and the test would catch
    it. The notification is DATA; data does not execute."""
    return False


# ── the instance INBOX (poll-only DATA channel — instances pull, never receive) ─


def deliver_inbox(target_haid, notification, home=None):
    """Append a notification to a target HAID's inbox (the in-band instance channel,
    §8). The instance POLLS this with poll(); it NEVER receives an inbound command
    socket. Returns {ok, path} on a write, {ok: False, reason} on a drop (a None
    payload, or an IO failure — the inbox degrades, never crashes a send).

    The payload is written as-is (already built + scrubbed by build_notification) — a
    pure data line, no execution semantics."""
    if not isinstance(notification, dict) or not notification.get("kind"):
        return {"ok": False, "reason": "not_a_notification"}
    # Routed THROUGH the StateBackend (Wave 0): append_line writes the SAME compact JSON
    # line (json.dumps(sort_keys=True, separators=(",",":")) + "\n") and flush-ONLY
    # discipline (fsync=False — notify flushes, never fsyncs, like §9 audit) the inbox
    # has always used, after owning makedirs itself. False on any IO failure -> the
    # inbox degrades to a dropped line, never crashes a send (byte-identical behavior).
    backend = _backend(home)
    if not backend.append_line(_inbox_rel(target_haid), notification, fsync=False):
        return {"ok": False, "reason": "io_error"}
    # The inbox local path is informational only (poll() reads via the backend, never this
    # field). Resolve it firestore-safe: None when the backend has no local file
    # (FirestoreBackend refuses path() by design), never a raise on the deliver/notify
    # request path (the firestore-only incident class — the line is already durably
    # appended above). On the local backend this stays the real on-disk path, unchanged.
    return {"ok": True, "path": _inbox_path_or_none(target_haid, home)}


def poll(target_haid, home=None, limit=_POLL_MAX):
    """Read a target HAID's notifications back as DATA (the instance poll, §8). Returns
    a list of notification dicts (most-recent-last, store order). Read-only — never
    writes, never executes. An absent inbox yields []; a bad line is skipped.

    This is the entire instance-receive path: an instance PULLS its notifications and
    RENDERS them. There is no command in the data, and nothing here runs the data —
    the inverse-of-RCE holds at the read side too."""
    # Routed THROUGH the StateBackend (Wave 0): read_lines returns the SAME tolerant,
    # store-ordered scan of dict lines (bad line skipped, absent inbox -> []). The
    # kind-filter (only KINDS payloads count as notifications) and the poll limit stay
    # at the call site — unchanged behavior, the backend just owns the byte read.
    out = [obj for obj in _backend(home).read_lines(_inbox_rel(target_haid))
           if obj.get("kind") in KINDS]
    return out[-limit:] if limit and len(out) > limit else out


# ── the connector egress (REUSE slack/email post_resolution — never rebuild) ──


def _to_resolution(notification):
    """Map a DATA notification into the connector's resolution shape ({summary, url})
    — the existing Connector.post_resolution egress verb (§0 reuse). The notification
    text becomes the summary; a job/action id (if present) is a reference URL-ish tag.
    This carries DATA only — no command crosses into the connector (the connector has
    no execute verb anyway; it posts a message)."""
    summary = notification.get("text") or "(%s)" % notification.get("kind")
    extra = notification.get("extra") or {}
    return {"summary": summary, "url": extra.get("url")}


def _send_via_connector(connector, notification):
    """Send ONE notification OUT via a single connector's egress (post_resolution).
    LAZY / OPTIONAL: an inactive connector (absent creds) is SKIPPED -> a {channel,
    ok: False, reason: inactive} result, NO crash (the graceful-degrade contract).
    Returns a per-channel result dict. Any connector exception degrades to a non-ok
    result (a notify must never crash on a flaky channel)."""
    name = getattr(connector, "name", None) or "connector"
    try:
        health = connector.health()
    except Exception as exc:  # noqa: BLE001 — a flaky health() is a skipped channel.
        return {"channel": name, "ok": False, "reason": "health_error: %s"
                % type(exc).__name__}
    if not (isinstance(health, dict) and health.get("active")):
        # absent creds / not configured -> inactive channel, no crash (§8 lazy).
        return {"channel": name, "ok": False, "reason": "inactive"}
    # the target raw_ref: a connector routes its own way (slack thread / email addr);
    # notify passes the target HAID + scrubbed ids as the locator. DATA only.
    raw_ref = {
        "target_haid": notification.get("target_haid"),
        "job_id": notification.get("job_id"),
        "action_id": notification.get("action_id"),
    }
    try:
        result = connector.post_resolution(raw_ref, _to_resolution(notification))
    except Exception as exc:  # noqa: BLE001 — a send fault is a non-ok channel, not a crash.
        return {"channel": name, "ok": False, "reason": "send_error: %s"
                % type(exc).__name__}
    ok = bool(isinstance(result, dict) and result.get("ok"))
    return {"channel": name, "ok": ok,
            "reason": None if ok else (result or {}).get("reason", "send_failed")}


# ── the ONE send API (build -> egress -> inbox -> audit — §8) ─────────────────


def notify(kind, *, text=None, target_haid=None, job_id=None, action_id=None,
           channels=None, extra=None, home=None):
    """Send ONE notification (§8): build the DATA-ONLY payload, deliver it OUT via the
    given connector `channels` (REUSED egress) AND the instance inbox, then AUDIT the
    send. Returns a structured result:
      {ok, notification, channels: [{channel, ok, reason}...], inbox: {ok, ...},
       audit_id}.

    A notification is DATA — there is no command field, and a smuggled command in
    `extra` is stripped (build_notification). LAZY / OPTIONAL: an inactive connector
    channel is skipped (no crash); the inbox channel always delivers, so notify never
    hard-fails on absent connector creds. NO-SECRET: text/extra are scrubbed, so no
    secret reaches the wire or the audit. Every send is AUDITED (kind + target, no
    secret values)."""
    notification = build_notification(
        kind, text=text, target_haid=target_haid, job_id=job_id,
        action_id=action_id, extra=extra,
    )
    if notification is None:
        return {"ok": False, "reason": "invalid_kind", "channels": [],
                "inbox": {"ok": False, "reason": "invalid_kind"}, "audit_id": None}

    # egress: send OUT via each connector (REUSED slack/email post_resolution).
    channel_results = []
    for connector in (channels or []):
        channel_results.append(_send_via_connector(connector, notification))

    # the in-band instance inbox always delivers (instances poll it) — this is the
    # channel that makes notify never hard-fail on absent connector creds.
    inbox_result = deliver_inbox(target_haid, notification, home=home)

    # AUDIT the send (§8/§9): kind (as action_type, a data tag) + target, params-shape
    # of the delivered channels, scrubbed detail. NO secret VALUES — cp_audit reduces
    # params to shape and scrubs detail via telemetry._scrub.
    audit_id = cp_audit.write(
        _KIND_AUDIT_EVENT.get(kind, _DEFAULT_AUDIT_EVENT),
        actor_haid=target_haid,
        action_type=kind,
        action_id=action_id,
        job_id=job_id,
        outcome="ok" if (inbox_result.get("ok")
                         or any(c.get("ok") for c in channel_results)) else "error",
        params={"channels": len(channel_results), "kind": kind},
        detail="notify %s" % kind,
        home=home,
    )

    delivered = inbox_result.get("ok") or any(c.get("ok") for c in channel_results)
    return {
        "ok": bool(delivered),
        "notification": notification,
        "channels": channel_results,
        "inbox": inbox_result,
        "audit_id": audit_id,
    }


# ── the §8 convenience senders (the three kinds) ──────────────────────────────


def job_complete(target_haid, job_id, *, text=None, channels=None, extra=None,
                 home=None):
    """A job-complete ping to an instance/owner (§8). DATA only."""
    return notify("job_complete", text=text or "job %s complete" % job_id,
                  target_haid=target_haid, job_id=job_id, channels=channels,
                  extra=extra, home=home)


def approval_needed(target_haid, action_id, *, text=None, channels=None, extra=None,
                    home=None):
    """A gate-needs-approval notice to the owner (§7 -> §8). DATA only — it tells the
    owner an action is PENDING; it does NOT carry the action (the approval queue does
    that through the allowlist, never through a notification)."""
    return notify("approval_needed",
                  text=text or "action %s needs approval" % action_id,
                  target_haid=target_haid, action_id=action_id, channels=channels,
                  extra=extra, home=home)


def alert(target_haid, text, *, channels=None, extra=None, home=None):
    """A free alert to an instance/owner (§8). The `text` is scrubbed — DATA only."""
    return notify("alert", text=text, target_haid=target_haid, channels=channels,
                  extra=extra, home=home)


# ── the route seam (POLL only — register GET /notifications, never inbound cmd) ─


def register_notify_routes(register_route=None):
    """Plug the notify surface into the server via the §10 registration seam WITHOUT
    editing cp_server. Registers GET /notifications — a POLL: the authenticated HAID
    reads ITS notifications back as DATA. There is NO inbound command route — the only
    route is a read. Pass `register_route` to inject the seam (defaults to
    cp_server.register_route). Returns the registered route key(s).

    The handler scopes the inbox to the verified Identity's HAID (an instance can only
    poll its own notifications) and returns the payloads as data — it runs nothing."""
    if register_route is None:
        import cp_server
        register_route = cp_server.register_route

    def _notifications_handler(identity, request):
        import cp_server
        haid = getattr(identity, "haid", None)
        payloads = poll(haid) if haid else []
        return cp_server.Response(200, {"notifications": payloads})

    return register_route("GET", "/notifications", _notifications_handler)
