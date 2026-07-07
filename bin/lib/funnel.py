#!/usr/bin/env python3
# funnel.py — the Δ6 LAUNCH FUNNEL event engine (client-side, consent-gated,
# zero-content). The launch gate wants ONE thing: a truthful count of how far a
# user got down the growth loop — install → init → invite_sent → join →
# badge_added — WITHOUT ever shipping a byte of source, a path, or a secret.
#
# WHAT THIS IS. A tiny event recorder that REUSES the merged corpus #4 machinery
# (bin/lib/pmr_corpus.py): the SAME consent gate (off is fully honored), the SAME
# zero-content cardinal guard, the SAME secret-scan-before-send, the SAME alarm
# trail, and the SAME ~/.heimdall/telemetry/ runtime home. There is NO new control
# plane route and NO model call — the funnel events land in a LOCAL ndjson spool
# under <corpus_home>/telemetry/funnel/, a sibling of telemetry/pmr/.
#
# THE PRIVACY LINE IS THE SAME ABSOLUTE ONE (§2 of the PMR spec), enforced by
# construction + falsifier-tested:
#   * OFF FULLY HONORED   — consent off (or HEIMDALL_TELEMETRY=off) => emit is a
#     pure no-op; ZERO events written.
#   * ZERO-CONTENT        — every record is scanned by pmr.assert_zero_content; a
#     planted path / source line (e.g. in --context) => BLOCKED + ALARMED, never
#     written. Only coded stage tokens, coarse env classes, and HASHES leave.
#   * SECRET-SCAN         — every record is scanned before it can be queued; a
#     detected secret shape => BLOCKED + ALARMED.
#   * TEAM KEY IS HASHED  — the team is projected through pmr.team_id_hash, so a
#     funnel count can never be joined back to a team identity in the clear.
#
# This is a LIBRARY + a thin CLI core, driven by bin/heimdall-funnel and the
# `hmd funnel` router case. stdlib-only; mirrors bin/lib/pmr_corpus.py.

from __future__ import annotations

import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

# REUSE the corpus #4 engine wholesale — never re-derive consent/guards/hashing.
import pmr_corpus as pmr  # noqa: E402 — sibling import after sys.path setup

SCHEMA_EVENT = "funnel_v1"
SCHEMA_COUNTS = "funnel_counts_v1"

# Upper bound on any coded string tag in a record (mirrors pmr._TAG_MAX intent).
_MAX_TAG = 64

# The launch funnel stages, in growth-loop order. ONLY these events are accepted —
# an unknown event is refused (a coded vocabulary can never carry free-form
# content). Kept in sync with the emit call sites: install.sh, hmd init, hmd
# invite, hmd join, hmd badge.
STAGES = ["install", "init", "invite_sent", "join", "badge_added"]


# ── namespace (own dir under the shared telemetry home — sibling of pmr/) ──────


def funnel_dir(home=None):
    """<corpus_home>/telemetry/funnel — the funnel-only namespace, a sibling of
    telemetry/pmr. Resolved through pmr.corpus_home so it honors the SAME
    HEIMDALL_CORPUS_HOME / HEIMDALL_HOME / ~/.heimdall precedence."""
    base = home if home else pmr.corpus_home()
    return os.path.join(base, "telemetry", "funnel")


def events_path(home=None):
    return os.path.join(funnel_dir(home), "events.ndjson")


# ── the event record (zero-content by construction) ───────────────────────────


def _hmd_version():
    """A coded version tag for the funnel record. Supplied by the bash wrapper via
    HEIMDALL_HMD_VERSION (resolved from the git tag / manifest), else 'unknown'.
    Always a single token (no path/space), so the zero-content guard is satisfied."""
    v = (os.environ.get("HEIMDALL_HMD_VERSION") or "").strip()
    if not v or len(v.split()) != 1:
        return "unknown"
    return v[:_MAX_TAG]


def build_event(event, team_id=None, context=None):
    """Build a funnel_v1 record. PURE (no IO). team_id is HASHED (never stored raw);
    `context` is copied RAW on purpose so a planted path/source line survives to the
    zero-content guard and is caught — never silently cleaned (the PMR discipline)."""
    if team_id is None:
        # Resolve the current repo's team the same way the corpus does (returns
        # None => 'solo'); hashed regardless, so a solo user is a stable bucket.
        try:
            team_id = pmr._current_team_id()  # noqa: SLF001 — intentional reuse
        except Exception:  # noqa: BLE001 — a git hiccup never fails an emit
            team_id = None
    rec = {
        "schema": SCHEMA_EVENT,
        "consent_version": pmr.CONSENT_VERSION,
        "event": event,
        "when": {
            "ts": pmr._now_iso(),           # noqa: SLF001
            "tz_bucket": pmr._tz_bucket(),  # noqa: SLF001
        },
        "team_id_hash": pmr.team_id_hash(team_id or "solo"),
        "env": {
            "os_class": pmr._default_os_class(),  # noqa: SLF001
            "hmd_version": _hmd_version(),
        },
    }
    if context is not None:
        # RAW copy — guarded downstream. A coded trigger token ('cli', 'hook') is
        # fine; a planted path/source line is caught by assert_zero_content.
        rec["context"] = str(context)
    return rec


# ── emit: gate -> project -> guard -> secret-scan -> append (mirrors emit_pmr) ─


def emit_event(event, team_id=None, context=None, home=None):
    """Record ONE funnel event into the LOCAL spool. The full gate, in order:
        1. UNKNOWN EVENT refused — a coded vocabulary carries no free-form content.
        2. OFF honored — disabled => pure no-op, ZERO write.
        3. build_event() — the zero-content-by-construction projection.
        4. assert_zero_content() — CARDINAL guard; a path/source leak => BLOCK+ALARM.
        5. secret_scan_payload() — a secret shape => BLOCK+ALARM (before queueing).
        6. append to the ndjson spool.
    Returns a status dict; NEVER raises into the caller (telemetry must never fail a
    real flow — an install/init/invite must not break because of a funnel event)."""
    try:
        if event not in STAGES:
            return {"emitted": False, "reason": "unknown-event",
                    "event": str(event)[:_MAX_TAG]}

        if not pmr.enabled(home):
            return {"emitted": False, "reason": "disabled"}

        rec = build_event(event, team_id, context)

        ok, violations = pmr.assert_zero_content(rec)
        if not ok:
            pmr._alarm("funnel-zero-content",  # noqa: SLF001
                       {"event": event, "violations": violations}, home)
            return {"emitted": False, "reason": "zero-content-blocked",
                    "violations": violations}

        clean, findings = pmr.secret_scan_payload(rec)
        if not clean:
            pmr._alarm("funnel-secret-scan",  # noqa: SLF001
                       {"event": event, "findings": findings}, home)
            return {"emitted": False, "reason": "secret-detected-blocked",
                    "findings": findings}

        _append(rec, home)
        return {"emitted": True, "event": event,
                "consent_version": rec["consent_version"]}
    except Exception as exc:  # noqa: BLE001 — a funnel emit NEVER fails the caller
        return {"emitted": False, "reason": "error", "detail": str(exc)[:120]}


def _append(rec, home=None):
    d = funnel_dir(home)
    os.makedirs(d, exist_ok=True)
    line = json.dumps(rec, sort_keys=True)
    path = events_path(home)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")
        fh.flush()
    return path


# ── read + count (the local view: `hmd funnel`) ───────────────────────────────


def read_events(home=None):
    """Every recorded funnel event (read-only). Tolerant: a bad line is skipped, an
    absent spool yields []."""
    out = []
    path = events_path(home)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if isinstance(obj, dict):
                    out.append(obj)
    except OSError:
        return out
    return out


def counts(home=None):
    """The local funnel view: per-stage counts + the total. Writes nothing.
    `enabled` reflects the CURRENT consent so a user sees whether new events will be
    recorded."""
    tally = {s: 0 for s in STAGES}
    total = 0
    for rec in read_events(home):
        ev = rec.get("event")
        if ev in tally:
            tally[ev] += 1
            total += 1
    return {
        "schema": SCHEMA_COUNTS,
        "consent_version": pmr.CONSENT_VERSION,
        "enabled": pmr.enabled(home),
        "stages": STAGES,
        "counts": tally,
        "total": total,
        "home": funnel_dir(home),
    }


def purge(home=None):
    """Delete the local funnel spool (the funnel half of the §3 rights layer). The
    PMR purge already keys a corpus deletion request by team; this clears the local
    funnel events. Returns a status dict."""
    path = events_path(home)
    removed = 0
    try:
        if os.path.exists(path):
            os.remove(path)
            removed = 1
    except OSError:
        removed = 0
    return {"purged": True, "removed": removed, "home": funnel_dir(home)}


# ── CLI core (driven by bin/heimdall-funnel + the `hmd funnel` router case) ────


def _render_human(c):
    """A compact human table for the default `hmd funnel` view."""
    lines = ["heimdall launch funnel  (telemetry %s)"
             % ("on" if c["enabled"] else "off")]
    for s in c["stages"]:
        lines.append("  %-12s %d" % (s, c["counts"][s]))
    lines.append("  %-12s %d" % ("total", c["total"]))
    lines.append("  spool: %s" % c["home"])
    return "\n".join(lines)


def _cli(argv):
    """CLI core. Subcommands:
        emit <event> [--team-id ID] [--context TOK]   record one funnel event
        counts | status [--json]                      the local funnel view
        purge                                         clear the local funnel spool
    """
    import argparse

    p = argparse.ArgumentParser(prog="hmd funnel", add_help=True)
    p.add_argument("subcommand")
    p.add_argument("event", nargs="?")
    p.add_argument("--team-id", dest="team_id")
    p.add_argument("--context")
    p.add_argument("--home")
    p.add_argument("--json", action="store_true", help="force JSON output")
    args = p.parse_args(argv)
    home = args.home
    sub = args.subcommand

    if sub == "emit":
        if not args.event:
            print(json.dumps({"emitted": False, "reason": "no-event"}))
            return 2
        res = emit_event(args.event, team_id=args.team_id,
                         context=args.context, home=home)
        print(json.dumps(res, sort_keys=True))
        return 0  # never gate the caller

    if sub in ("counts", "status"):
        c = counts(home)
        if args.json:
            print(json.dumps(c, indent=2, sort_keys=True))
        else:
            print(_render_human(c))
        return 0

    if sub == "purge":
        print(json.dumps(purge(home), sort_keys=True))
        return 0

    print(json.dumps({"error": "unknown subcommand: %s" % sub}))
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
