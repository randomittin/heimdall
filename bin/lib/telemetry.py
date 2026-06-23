#!/usr/bin/env python3
# telemetry.py — piece (a) of the Heimdall telemetry layer: the ONE general event
# surface. The real engine behind `bin/heimdall-telemetry` and the single write API
# every consumer (issue-loop, installs, runs) calls. Heimdall measures everything
# except itself; this is the substrate that closes that loop.
#
# DESIGN DOSSIER §1/§2/§7/§8 (authoritative). This module pins:
#
#   • The STORE — an append-only NDJSON log under the gitignored runtime home
#     (${HEIMDALL_HOME:-<repo>/.heimdall}/telemetry/events.ndjson). NDJSON (not
#     SQLite) was chosen so `gitleaks detect` scans it natively as plaintext — the
#     secret gate stays fully armed on the store, no path-allowlist needed (§1).
#     One open('a') + one write() of one line + flush() — the cheapest non-blocking
#     write. Rotation at 5 MB to events-<epoch>.ndjson (§1).
#
#   • The SCHEMA — the ONE pinned event shape (§1). Only the keys below are ever
#     written; consumers ignore unknown fields (forward-compatible). `tokens` is
#     copied VERBATIM from `bin/heimdall-tokens` JSON (already secret-free metrics).
#
#   • NO-SECRET-BY-CONSTRUCTION (§7, security-critical) — the schema has NO free
#     payload field. error.detail / extra values pass through _scrub(): bounded to
#     ≤120 chars AND rejected (dropped) if they match any gitleaks high-signal
#     pattern or look like a key=opaque-value. Secrets/tokens/credentials/PII
#     CANNOT enter the store by construction, not by after-the-fact scrubbing.
#
#   • GRACEFUL-DEGRADE (§8) — emit() swallows EVERY exception → returns False → the
#     event is dropped → the run/install continues. Disabled (HEIMDALL_TELEMETRY=off
#     or an opt-out marker) → emit() is a no-op. Absent telemetry world behaves
#     IDENTICALLY. stdlib-only (json/os/uuid/datetime/re) — no third-party dep, so a
#     clean install never breaks for a missing driver.
#
# This is a LIBRARY (pure-ish; mirrors issue_queue.py shape). The bash CLI
# (bin/heimdall-telemetry) is a thin wrapper that owns argv + stdout shape.

from __future__ import annotations

import datetime
import json
import os
import re
import sys
import uuid

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import issue_queue  # piece (b); REUSE its home resolver — never re-derive (§1 L36)

# ── schema constants (the pinned contract — §1) ───────────────────────────────

SCHEMA_VERSION = "1.0.0"

# The event_type ENUM (§1). emit() REJECTS any other value (drops the event).
EVENT_TYPES = (
    "install_step",
    "phase",
    "gate",
    "token",
    "outcome",
    "commit",
    "issue_state",
)

# The bounded-string limit for the only two free-ish fields (error.detail / extra
# scalar values). A value over this is REJECTED, never truncated-and-kept — a
# truncated secret is still a secret leak (§7).
_SCRUB_MAX = 120

# Rotation threshold: rename events.ndjson when it exceeds this (§1).
_ROTATE_BYTES = 5 * 1024 * 1024

# The opt-out marker file under the runtime home; its mere presence disables
# telemetry (alongside HEIMDALL_TELEMETRY=off). Local-first, user-controlled (§7).
_OPTOUT_MARKER = "telemetry.off"

# Gitleaks high-signal patterns the scrubber REJECTS a value for matching (§7).
# These mirror the secret-shaped strings the gate itself catches — a value that
# would trip gitleaks must never reach the store. Kept deliberately narrow +
# high-signal (the same families named in the dossier + fixture-secret-convention).
_SECRET_PATTERNS = (
    re.compile(r"ghp_[A-Za-z0-9]{36}"),            # GitHub PAT
    re.compile(r"gh[oprsu]_[A-Za-z0-9]{36}"),      # other GitHub token families
    re.compile(r"AKIA[0-9A-Z]{16}"),               # AWS access key id
    re.compile(r"sk_live_[A-Za-z0-9]{16,}"),       # Stripe live secret key
    re.compile(r"sk_test_[A-Za-z0-9]{16,}"),       # Stripe test secret key
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),   # Slack token
    re.compile(r"-----BEGIN[ A-Z]*PRIVATE KEY-----"),  # PEM private key header
    re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),  # JWT
)

# A key=long-opaque-value shape (e.g. token=AbCdEf0123456789AbCdEf01) — the generic
# "looks like an assigned credential" reject, even when it matches no named vendor
# pattern. A long unbroken high-entropy run assigned to a key is rejected (§7).
_ASSIGNED_OPAQUE = re.compile(
    r"(?:token|secret|password|passwd|pwd|api[_-]?key|apikey|access[_-]?key|"
    r"auth|bearer|credential|private[_-]?key)"
    r"\s*[=:]\s*\S{16,}",
    re.I,
)


# ── runtime home + store location (REUSE issue_queue.heimdall_home — §1 L36) ───


def telemetry_dir(home=None):
    """The telemetry store dir: ${HEIMDALL_HOME:-<repo>/.heimdall}/telemetry/.

    `home` lets a caller (and the tests) pin an explicit runtime home directly;
    otherwise we REUSE issue_queue.heimdall_home() so telemetry lands in the SAME
    gitignored runtime home as the queue + attestation stores (never re-derived)."""
    base = home if home else issue_queue.heimdall_home()
    return os.path.join(base, "telemetry")


def events_path(home=None):
    """Absolute path to the active NDJSON event log."""
    return os.path.join(telemetry_dir(home), "events.ndjson")


# ── enabled / run-id (the public lifecycle helpers — §1) ──────────────────────


def enabled(home=None):
    """True unless telemetry is turned OFF (§8): HEIMDALL_TELEMETRY=off|0|false|no,
    or an opt-out marker file present under the runtime home. Default ON, but a
    disabled world behaves IDENTICALLY (emit becomes a no-op). Never raises."""
    flag = (os.environ.get("HEIMDALL_TELEMETRY") or "").strip().lower()
    if flag in ("off", "0", "false", "no", "disabled"):
        return False
    try:
        base = home if home else issue_queue.heimdall_home()
        if os.path.exists(os.path.join(base, _OPTOUT_MARKER)):
            return False
    except Exception:  # noqa: BLE001 — a home-resolution failure never enables/raises
        return True
    return True


def new_run_id():
    """A stable run id for one hmd / install invocation: 'run-<uuid4hex>'."""
    return "run-" + uuid.uuid4().hex


def _now_iso():
    """Current UTC time as a second-precision ISO-8601 string (§1 ts field)."""
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
    )


# ── the scrubber: NO-SECRET-BY-CONSTRUCTION (§7, security-critical) ───────────


def _scrub(value):
    """SHAPE-enforce a free-ish scalar (error.detail / an extra value) and REJECT it
    if it could carry a secret. Returns the cleaned string, or None to signal the
    field must be DROPPED (never written). The dossier's hard rule: a value over
    _SCRUB_MAX chars OR matching any gitleaks high-signal pattern OR shaped like an
    assigned credential is rejected — secrets cannot enter the store (§7).

    Non-string scalars (int/float/bool) are safe SHAPE values and pass through
    unchanged. Anything else (dict/list/opaque object) is rejected — the schema
    carries NO nested free payload, only bounded scalar tags."""
    if value is None:
        return None
    if isinstance(value, bool) or isinstance(value, (int, float)):
        return value  # a numeric/bool scalar carries no secret payload
    if not isinstance(value, str):
        return None  # no nested/opaque payload may enter (§7 — no free payload)
    if len(value) > _SCRUB_MAX:
        return None  # over the bound → reject (a truncated secret is still a leak)
    if _ASSIGNED_OPAQUE.search(value):
        return None  # key=opaque-RHS shape → reject
    for rx in _SECRET_PATTERNS:
        if rx.search(value):
            return None  # matches a gitleaks high-signal pattern → reject
    return value


def _scrub_extra(extra):
    """Scrub an `extra` dict to bounded scalar tags ONLY (§1/§7). Each key is
    coerced to a short string key; each value passes through _scrub(). A rejected
    value DROPS that key (the rest survive). A non-dict `extra` yields {} — the
    schema's extra is always a flat object of bounded scalar tags, never a payload."""
    if not isinstance(extra, dict):
        return {}
    out = {}
    for k, v in extra.items():
        key = str(k)[:_SCRUB_MAX]
        cleaned = _scrub(v)
        if cleaned is not None:
            out[key] = cleaned
    return out


def _scrub_error(error):
    """Scrub an `error` object to the SHAPE-only schema {class, step, detail} (§1).
    Each component passes through _scrub(); a rejected component is dropped. A
    non-dict error yields None. error.detail is a SHAPE summary, NEVER stdout/stderr/
    a secret/PII — the scrubber enforces that by construction."""
    if not isinstance(error, dict):
        return None
    out = {}
    for field in ("class", "step", "detail"):
        if field in error:
            cleaned = _scrub(error.get(field))
            if cleaned is not None:
                out[field] = cleaned
    return out or None


def _coerce_int_or_skip(out, key, raw):
    """Set out[key] to int(raw); on a bad value leave the key absent (no lone
    no-op body — the conditional set IS the handling). Defensive coercion for the
    verbatim token components (§1)."""
    try:
        out[key] = int(raw)
    except (TypeError, ValueError):
        out.pop(key, None)
    return out


def _scrub_tokens(tokens):
    """The `tokens` object is copied VERBATIM from bin/heimdall-tokens — already
    pure numeric metrics, no values (§1). We keep ONLY the known numeric/provenance
    keys (defence in depth: never carry an unexpected string field through). A
    non-dict yields None."""
    if not isinstance(tokens, dict):
        return None
    out = {}
    int_keys = (
        "input_tokens", "output_tokens", "cache_creation_tokens",
        "cache_read_tokens", "total_tokens", "non_cache_tokens",
    )
    for k in int_keys:
        if k in tokens:
            _coerce_int_or_skip(out, k, tokens[k])
    if "total_cost_usd" in tokens:
        c = tokens["total_cost_usd"]
        if c is None:
            out["total_cost_usd"] = None
        else:
            try:
                out["total_cost_usd"] = float(c)
            except (TypeError, ValueError):
                out["total_cost_usd"] = None
    # cost_source is a small provenance tag (measured|reported|derived|null) — a
    # bounded scalar, scrubbed like any other (§6 honesty: provenance must travel).
    if "cost_source" in tokens:
        out["cost_source"] = _scrub(tokens.get("cost_source"))
    return out


# ── the ONE event builder (the pinned schema — §1) ────────────────────────────


def build_event(event_type, *, run_id=None, phase=None, step=None, outcome=None,
                gate=None, tokens=None, duration_ms=None, commit=None,
                error=None, loc=None, extra=None):
    """Assemble ONE schema-validated, secret-scrubbed event dict from the pinned
    keys (§1). Returns the event dict, or None if event_type is not in the ENUM
    (an invalid type is dropped, never written). Every free-ish field is scrubbed:
    secrets cannot enter by construction. Pure — no IO."""
    if event_type not in EVENT_TYPES:
        return None

    def _opt_str(v):
        """A short bounded string tag (phase/step/outcome/gate/loc/commit), or None.
        These are closed-vocabulary tags, but we still bound + scrub them so no
        caller can smuggle a payload through a 'phase' field (§7)."""
        if v is None:
            return None
        return _scrub(str(v))

    def _opt_int(v):
        if v is None:
            return None
        try:
            return int(v)
        except (TypeError, ValueError):
            return None

    return {
        "schema_version": SCHEMA_VERSION,
        "ts": _now_iso(),
        "run_id": _opt_str(run_id),
        "event_type": event_type,
        "phase": _opt_str(phase),
        "step": _opt_str(step),
        "outcome": _opt_str(outcome),
        "gate": _opt_str(gate),
        "tokens": _scrub_tokens(tokens),
        "duration_ms": _opt_int(duration_ms),
        "commit": _opt_str(commit),
        "error": _scrub_error(error),
        "loc": _opt_str(loc),
        "extra": _scrub_extra(extra),
    }


# ── the write API (the ONE interface every consumer calls — §1) ───────────────


def emit(event_type, *, run_id=None, phase=None, step=None, outcome=None,
         gate=None, tokens=None, duration_ms=None, commit=None,
         error=None, loc=None, extra=None, home=None):
    """Append ONE schema-validated, secret-scrubbed event line to events.ndjson.

    Returns True on write, False on ANY drop (disabled / invalid type / write-fail).
    NEVER raises into the caller — a telemetry failure must never fail a run or
    install (§8). Fire-and-forget: one validate + one scrub + one open('a') +
    write + flush. Every failure path swallows the exception and returns False.

    This is the ONLY way to write the store. Consumers never touch the file."""
    try:
        if not enabled(home):
            return False  # disabled world is a no-op (§8) — identical to no-telemetry
        event = build_event(
            event_type, run_id=run_id, phase=phase, step=step, outcome=outcome,
            gate=gate, tokens=tokens, duration_ms=duration_ms, commit=commit,
            error=error, loc=loc, extra=extra,
        )
        if event is None:
            return False  # invalid event_type → dropped, nothing written
        return _append(event, home)
    except Exception:  # noqa: BLE001 — graceful-degrade: a telemetry fault NEVER raises
        return False


def _append(event, home):
    """Write one JSON line to events.ndjson, rotating first if oversized. Returns
    True on success, False on any IO failure (the caller's emit() already guards,
    but this returns False rather than raising so a partial-write disk error drops
    the event cleanly — graceful-degrade, §8)."""
    try:
        ldir = telemetry_dir(home)
        os.makedirs(ldir, exist_ok=True)
        path = os.path.join(ldir, "events.ndjson")
        _maybe_rotate(path)
        line = json.dumps(event, sort_keys=True, separators=(",", ":"))
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
            fh.flush()
        return True
    except OSError:
        return False  # disk full / bad perm / unwritable dir → drop, run continues


def _maybe_rotate(path):
    """Rotate events.ndjson → events-<epoch>.ndjson when it exceeds the threshold
    (§1). Cheap atomic rename. A rotation failure never blocks the append — we just
    keep appending to the current file (graceful-degrade)."""
    try:
        if os.path.getsize(path) > _ROTATE_BYTES:
            epoch = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
            rotated = path.replace(".ndjson", "-%d.ndjson" % epoch)
            os.replace(path, rotated)
    except OSError:
        return  # absent file (first write) or rename failure → no rotation, fine


# ── read helpers (a thin read path for status + the §4 card-fill consumer) ────


def read_events(home=None, run_id=None):
    """Stream every event line across events*.ndjson (the active log + any rotated
    siblings), parsing each. Optionally filter to one run_id. Tolerant: a bad line
    is skipped, an absent store yields []. Read-only — never writes. This is the
    line-scan the aggregate/card-fill consumers (pieces c/d) build on."""
    out = []
    try:
        ldir = telemetry_dir(home)
        if not os.path.isdir(ldir):
            return out
        names = sorted(
            n for n in os.listdir(ldir)
            if n.startswith("events") and n.endswith(".ndjson")
        )
    except OSError:
        return out
    for name in names:
        fp = os.path.join(ldir, name)
        try:
            with open(fp, "r", encoding="utf-8", errors="replace") as fh:
                for raw in fh:
                    line = raw.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except (ValueError, TypeError):
                        continue
                    if not isinstance(obj, dict):
                        continue
                    if run_id is not None and obj.get("run_id") != run_id:
                        continue
                    out.append(obj)
        except OSError:
            continue
    return out


def status(home=None):
    """A read-only at-a-glance over the store: enabled flag, path, event count, and
    per-event_type counts. Picks nothing, writes nothing — safe to call anytime."""
    events = read_events(home)
    by_type = {}
    for e in events:
        t = e.get("event_type")
        by_type[t] = by_type.get(t, 0) + 1
    return {
        "schema_version": SCHEMA_VERSION,
        "enabled": enabled(home),
        "path": events_path(home),
        "events": len(events),
        "by_type": by_type,
    }


# ── CLI core (driven by bin/heimdall-telemetry) ───────────────────────────────


def _cli(argv):
    """CLI core. Subcommands:
      emit  --type T [--run-id R] [--phase P] [--step S] [--outcome O]
            [--gate G] [--duration-ms N] [--commit SHA] [--loc F:L]
            [--error-class C] [--error-step S] [--error-detail D]
            [--tokens @file|JSON] [--extra @file|JSON] [--home DIR]
      status [--home DIR]
      new-run-id
    Returns an exit code. NEVER fails the caller on a telemetry problem: emit prints
    {"emitted": bool} and ALWAYS exits 0 (graceful-degrade, §8)."""
    import argparse

    p = argparse.ArgumentParser(prog="heimdall-telemetry", add_help=True)
    p.add_argument("subcommand")
    p.add_argument("--type")
    p.add_argument("--run-id", dest="run_id")
    p.add_argument("--phase")
    p.add_argument("--step")
    p.add_argument("--outcome")
    p.add_argument("--gate")
    p.add_argument("--duration-ms", dest="duration_ms", type=int)
    p.add_argument("--commit")
    p.add_argument("--loc")
    p.add_argument("--error-class", dest="error_class")
    p.add_argument("--error-step", dest="error_step")
    p.add_argument("--error-detail", dest="error_detail")
    p.add_argument("--tokens")
    p.add_argument("--extra")
    p.add_argument("--home")
    args = p.parse_args(argv)

    if args.subcommand == "new-run-id":
        print(new_run_id())
        return 0

    if args.subcommand == "status":
        print(json.dumps(status(args.home), indent=2, sort_keys=True))
        return 0

    if args.subcommand == "emit":
        if not args.type:
            print(json.dumps({"emitted": False, "reason": "missing --type"}))
            return 0  # never fail the caller (§8) — a bad emit is a no-op, exit 0
        error = None
        if args.error_class or args.error_step or args.error_detail:
            error = {
                "class": args.error_class,
                "step": args.error_step,
                "detail": args.error_detail,
            }
        tokens = _read_json_arg(args.tokens) if args.tokens else None
        extra = _read_json_arg(args.extra) if args.extra else None
        wrote = emit(
            args.type, run_id=args.run_id, phase=args.phase, step=args.step,
            outcome=args.outcome, gate=args.gate, tokens=tokens,
            duration_ms=args.duration_ms, commit=args.commit, error=error,
            loc=args.loc, extra=extra, home=args.home,
        )
        print(json.dumps({"emitted": bool(wrote)}))
        return 0  # ALWAYS 0 — telemetry never gates the caller

    print(json.dumps({"error": "unknown subcommand: %s" % args.subcommand}))
    return 2


def _read_json_arg(value):
    """A JSON CLI arg is either inline JSON or @path-to-file. On any parse failure
    returns None (the field is simply omitted — telemetry never fails the caller)."""
    try:
        if value.startswith("@"):
            with open(value[1:], "r", encoding="utf-8") as fh:
                return json.load(fh)
        return json.loads(value)
    except (OSError, ValueError, TypeError):
        return None


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
