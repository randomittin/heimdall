#!/usr/bin/env python3
"""bin/lib/quota_stop.py — classify an agent-termination message as a QUOTA stop
(retryable once a wall-clock reset time arrives) vs. a genuine failure (needs a
human), and resolve that reset time to an absolute epoch using stdlib zoneinfo.

WHY THIS EXISTS
    Heimdall agents die mid-task when Claude's own usage/session/weekly limit is
    hit. The termination text looks like:

        Agent terminated early due to an API error: You've hit your session
        limit · resets 12:40pm (Asia/Calcutta)

    Getting the classification wrong in the retryable direction means an
    automated resume loop spins forever on a genuine failure (a bug, a broken
    tool call, an auth error) waiting for a reset that will never come. Getting
    it wrong the other way means a real quota stop gets treated as unrecoverable
    and the work is silently abandoned. Both are worse than doing nothing, so
    this module is deliberately conservative: it requires TWO independent
    signals to agree before calling anything a quota stop —
      1. the Claude-specific "hit your ... limit" phrase (ANCHOR_RE), and
      2. a well-formed "resets H[:MM]am/pm (TZ)" wall-clock clause (RESET_RE).
         Minutes are OPTIONAL — production text omits them entirely on the
         hour ("resets 2pm (Asia/Calcutta)"), not just when non-zero
         ("resets 2:30pm (Asia/Calcutta)"). Both are real, observed shapes;
         neither is fabricated to make a test pass.
    Either signal alone classifies as "unknown", and "unknown" is the safe
    default: the caller (bin/heimdall-quota-resume record) refuses to write a
    resume record for "unknown" text. That refusal is the do-nothing default
    this design prefers over a wrong guess in either direction — a generic
    "rate limit exceeded" from some unrelated HTTP API has neither signal and
    so can never be mistaken for a quota stop; a message that merely mentions
    a limit without a parseable reset time is left for a human, not retried
    forever.

TIME MATH
    The reset clause is a WALL-CLOCK LOCAL TIME with a named timezone, not a
    duration. Resolving it to an absolute instant means: interpret "5:40pm" in
    the NAMED timezone (not the machine's local zone), decide whether that
    already happened today (roll to tomorrow if so), and do that decision with
    a small tolerance for clock skew / message-composition lag so a target a
    few seconds in the "past" is still treated as "now", not "wait 24h more".
    zoneinfo (stdlib since Python 3.9) does this correctly across a DST
    transition for free: `datetime + timedelta(days=1)` on an aware
    zoneinfo-backed datetime keeps the wall-clock fields and re-derives the
    UTC offset from the *new* date when `.timestamp()` is read, so a reset
    that rolls over a DST boundary still lands on the right UTC instant. This
    sidesteps BSD-vs-GNU `date` entirely, which is why this piece is Python
    and not shell (see AGENTS.md on macOS bash 3.2 / BSD date portability).

CLI (invoked by bin/heimdall-quota-resume; also directly unit-testable)
    classify    read text from --text/--file/stdin, print JSON classification,
                exit 0=quota 1=unknown 64=usage error
    resolve     resolve an explicit H:MM am/pm + tz to an absolute epoch,
                exit 0=ok 1=failed(unknown tz / out-of-range time) 64=usage
    detect      classify + (if quota) resolve, in one call — what
                bin/heimdall-quota-resume record actually uses.
                exit 0=quota+resolved 1=unknown 2=quota but unresolved
                64=usage error

Nothing here touches git, the filesystem (beyond reading --file), or the
network. Pure text in, JSON out.
"""

import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - this repo targets Python >= 3.9
    ZoneInfo = None

# The Claude-Code-specific "you're out of quota" phrase. Bounded so it can
# never run away across an entire message, and deliberately NOT just "rate
# limit" — that phrase is generic enough to appear in unrelated HTTP/API error
# text this classifier must never fire on by itself (see module docstring).
ANCHOR_RE = re.compile(r"hit your [a-z0-9][a-z0-9\- ]{0,24}limit", re.IGNORECASE)

# A wall-clock reset clause: "resets 5:40pm (Asia/Calcutta)" OR, just as
# real, "resets 2pm (Asia/Calcutta)" with no minutes at all when the reset
# lands on the hour — the ":MM" group is OPTIONAL (measured 2026-09-06
# against actual Claude Code termination text; a fixed-minutes-required regex
# silently mis-marked every on-the-hour reset as "unknown" in production).
# The timezone token's charset is permissive (IANA names use '/', '_', '+',
# '-') but length-bounded.
RESET_RE = re.compile(
    r"resets?\s+(\d{1,2})(?::(\d{2}))?\s*([ap]m)\s*\(\s*([A-Za-z0-9_+\-/]{2,64})\s*\)",
    re.IGNORECASE,
)

DEFAULT_SKEW_SECONDS = 120


def classify(text):
    """Classify raw termination text. Returns a dict; never raises on bad input.

    Internal keys prefixed with "_" (_hour12, _minute, _ampm) carry the parsed
    reset-clause fields for resolve_reset_epoch() and are stripped before this
    is ever printed as the tool's public JSON output.
    """
    text = text or ""
    anchor_m = ANCHOR_RE.search(text)
    reset_m = RESET_RE.search(text)
    is_quota = bool(anchor_m and reset_m)

    out = {
        "class": "quota" if is_quota else "unknown",
        "anchor_matched": bool(anchor_m),
        "reset_clause_matched": bool(reset_m),
        "reset_local": None,
        "reset_tz": None,
    }
    if reset_m:
        hour, minute, ampm, tz_name = reset_m.groups()
        # minute is None when the source text omitted ":MM" (an on-the-hour
        # reset, e.g. "resets 2pm"). Resolve to 0 for arithmetic, but DISPLAY
        # exactly what appeared in the source — "2pm", never a fabricated
        # "2:00pm" — since reset_local's job is to echo the real text, not
        # manufacture false minute-precision.
        minute_i = int(minute) if minute is not None else 0
        if minute is not None:
            out["reset_local"] = "%d:%02d%s" % (int(hour), minute_i, ampm.lower())
        else:
            out["reset_local"] = "%d%s" % (int(hour), ampm.lower())
        out["reset_tz"] = tz_name
        out["_hour12"] = int(hour)
        out["_minute"] = minute_i
        out["_ampm"] = ampm.lower()
    return out


def to_hour24(hour12, ampm):
    h = int(hour12) % 12
    if str(ampm).lower() == "pm":
        h += 12
    return h


def resolve_reset_epoch(hour12, minute, ampm, tz_name, now_epoch=None,
                         skew_tolerance=DEFAULT_SKEW_SECONDS):
    """Resolve a wall-clock H:MM am/pm in tz_name to an absolute epoch.

    Rolls to tomorrow when the target already passed today, with
    `skew_tolerance` seconds of grace so a target a few seconds in the "past"
    (clock skew, message-composition lag) still counts as today. Fails closed
    — returns {"ok": False, "error": ...} — on an unrecognised timezone or an
    out-of-range time; never raises and never silently guesses.
    """
    if ZoneInfo is None:
        return {"ok": False, "error": "zoneinfo unavailable (Python < 3.9)"}

    try:
        hour12_i = int(hour12)
    except (TypeError, ValueError):
        return {"ok": False, "error": "hour is not an integer: %r" % (hour12,)}
    if not (1 <= hour12_i <= 12):
        # Trust-boundary check: a 12-hour clock hour must be 1-12. Without this,
        # to_hour24's `% 12` would silently reinterpret an out-of-range hour
        # (e.g. 13) as a DIFFERENT, wrong, in-range hour instead of refusing it.
        return {"ok": False, "error": "hour out of range (expected 1-12): %s" % hour12}

    try:
        minute_i = int(minute)
    except (TypeError, ValueError):
        return {"ok": False, "error": "minute is not an integer: %r" % (minute,)}
    if not (0 <= minute_i <= 59):
        return {"ok": False, "error": "minute out of range (expected 0-59): %s" % minute}

    try:
        tz = ZoneInfo(tz_name)
    except Exception as exc:  # unknown/invalid IANA name
        return {"ok": False, "error": "unknown timezone %r: %s" % (tz_name, exc)}

    hour24 = to_hour24(hour12_i, ampm)

    if now_epoch is None:
        now = datetime.now(timezone.utc)
    else:
        try:
            now = datetime.fromtimestamp(float(now_epoch), tz=timezone.utc)
        except (TypeError, ValueError, OSError) as exc:
            return {"ok": False, "error": "invalid now_epoch %r: %s" % (now_epoch, exc)}
    now_local = now.astimezone(tz)

    candidate = now_local.replace(hour=hour24, minute=minute_i, second=0, microsecond=0)
    rolled = False
    if (now_local - candidate).total_seconds() > skew_tolerance:
        # Already passed today (beyond the skew grace window) — same wall-clock
        # time, next calendar day. zoneinfo re-derives the UTC offset from the
        # NEW date when .timestamp() is read below, so this stays correct
        # across a DST transition without any special-casing here.
        candidate = candidate + timedelta(days=1)
        rolled = True

    return {
        "ok": True,
        "reset_epoch": int(candidate.timestamp()),
        "reset_iso": candidate.isoformat(),
        "rolled_to_tomorrow": rolled,
        "now_epoch": int(now.timestamp()),
    }


def detect(text, now_epoch=None, skew_tolerance=DEFAULT_SKEW_SECONDS):
    """classify() + (if quota) resolve_reset_epoch(), merged into one answer."""
    c = classify(text)
    hour12 = c.pop("_hour12", None)
    minute = c.pop("_minute", None)
    ampm = c.pop("_ampm", None)

    out = dict(c)
    out["resolved"] = False
    out["reset_epoch"] = None
    out["reset_iso"] = None
    out["rolled_to_tomorrow"] = None
    out["error"] = None
    if now_epoch is None:
        out["now_epoch"] = int(datetime.now(timezone.utc).timestamp())
    else:
        out["now_epoch"] = int(float(now_epoch))

    if c["class"] == "quota":
        r = resolve_reset_epoch(hour12, minute, ampm, c["reset_tz"],
                                 now_epoch=now_epoch, skew_tolerance=skew_tolerance)
        if r.get("ok"):
            out["resolved"] = True
            out["reset_epoch"] = r["reset_epoch"]
            out["reset_iso"] = r["reset_iso"]
            out["rolled_to_tomorrow"] = r["rolled_to_tomorrow"]
            out["now_epoch"] = r["now_epoch"]
        else:
            out["error"] = r.get("error")
    return out


def _read_text(args):
    if args.text is not None:
        return args.text
    if args.file:
        with open(args.file, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    return sys.stdin.read()


def _cli(argv):
    p = argparse.ArgumentParser(prog="quota_stop.py", add_help=True)
    sub = p.add_subparsers(dest="cmd")

    pc = sub.add_parser("classify")
    pc.add_argument("--text", default=None)
    pc.add_argument("--file", default=None)

    pr = sub.add_parser("resolve")
    pr.add_argument("--hour", required=True)
    pr.add_argument("--minute", required=True)
    pr.add_argument("--ampm", required=True, choices=["am", "pm", "AM", "PM"])
    pr.add_argument("--tz", required=True)
    pr.add_argument("--now", dest="now_epoch", default=None)
    pr.add_argument("--skew", dest="skew", type=int, default=DEFAULT_SKEW_SECONDS)

    pd = sub.add_parser("detect")
    pd.add_argument("--text", default=None)
    pd.add_argument("--file", default=None)
    pd.add_argument("--now", dest="now_epoch", default=None)
    pd.add_argument("--skew", dest="skew", type=int, default=DEFAULT_SKEW_SECONDS)

    args = p.parse_args(argv)
    if not args.cmd:
        p.print_usage(sys.stderr)
        return 64

    if args.cmd == "classify":
        text = _read_text(args)
        out = classify(text)
        out.pop("_hour12", None)
        out.pop("_minute", None)
        out.pop("_ampm", None)
        print(json.dumps(out, sort_keys=True))
        return 0 if out["class"] == "quota" else 1

    if args.cmd == "resolve":
        r = resolve_reset_epoch(args.hour, args.minute, args.ampm, args.tz,
                                 now_epoch=args.now_epoch, skew_tolerance=args.skew)
        print(json.dumps(r, sort_keys=True))
        return 0 if r.get("ok") else 1

    if args.cmd == "detect":
        text = _read_text(args)
        out = detect(text, now_epoch=args.now_epoch, skew_tolerance=args.skew)
        print(json.dumps(out, sort_keys=True))
        if out["class"] != "quota":
            return 1
        return 0 if out["resolved"] else 2

    p.print_usage(sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
