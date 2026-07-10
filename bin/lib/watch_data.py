#!/usr/bin/env python3
"""
watch_data.py — the LOCAL-ONLY data + render core for `hmd watch` (the TUI dashboard,
spec section C). This module reads Heimdall's own local caches and artifacts and
renders them; it makes NO network calls and reimplements NO verdict/gate/presence
logic. That is the cardinal invariant of the whole feature:

  * ZERO ADDITIONAL SERVER LOAD — every read here is a local file read. The WALL
    reads the roster cache the beat cadence already maintains (<repo>/.heimdall/
    roster-cache.json); the FEED reads the local receipt/verdict trail
    (<repo>/.heimdall/feed.jsonl); the INSPECTOR reads the local report.json a feed
    item points at. There is deliberately no socket/urllib/http import in this file.

  * RENDERER OVER EXISTING PLUMBING — the interactive actions (approve/deny/clip/
    invite/presence) are SHELL-OUTS to the existing CLI (`hmd <cmd> ...`), built by
    build_shell_argv(). This module never signs, never computes a verdict, never
    speaks the presence protocol.

The Textual app (watch_tui.py) and the bin launcher (heimdall-watch-tui) both import
this module. It is intentionally free of the Textual dependency so it degrades to a
static wall+feed dump when Textual is absent.
"""

import os
import re
import sys
import json
import time
import importlib.util


# ── keymap (spec C) — value carries the action name; the app binds Textual keys ──
KEYMAP = {
    "j": "select_next",     # move selection down
    "k": "select_prev",     # move selection up
    "enter": "inspect",     # open the receipt for the selected feed item
    "c": "clip",            # export selected event  -> hmd clip
    "i": "invite",          # print invite            -> hmd invite
    "p": "presence",        # presence toggle         -> hmd presence
    "r": "reports",         # morning/sleep/weekly markdown reports
    "a": "approve",         # owner-gated approve     -> hmd approve
    "d": "deny",            # owner-gated deny        -> hmd deny
    "?": "help",            # keymap help overlay
    "q": "quit",            # leave the dashboard
}

# ── freemium boundary (spec C). FREE features are unlocked at ANY team size, always.
#    Only these four are gated behind the (dark, default-off) entitlement flag.
FREE_FEATURES = frozenset({
    "wall", "feed", "inspector", "reports", "clip", "invite", "presence",
})
DEFAULT_LOCKED = frozenset({"history", "trends", "analytics", "archive"})

# One-line upsells (no nagging modals — a single line under a locked pane).
_UPSELL = {
    "history":   "Team tier — 30-day scrollback · hmd upgrade",
    "trends":    "Team tier — per-dev/per-repo trend panes · hmd upgrade",
    "analytics": "Team tier — team analytics · hmd upgrade",
    "archive":   "Team tier — report archive · hmd upgrade",
}

# Verdict -> (glyph, upper label). Fixed across tiers (statusline v2 semantics).
VERDICT_SYM = {
    "PASS": "✓", "DENY": "✗", "RUNNING": "▶", "IDLE": "·",
}

# Wall STATE -> badge. The server derives a per-dev "active"/"idle" state on every roster view
# (cp_presence.roster); the wall renders them DISTINCTLY so a glance separates "working now"
# (● active) from "here but idle" (○ idle). This is the presence badge — orthogonal to the
# verdict glyph (a teammate can be idle with a PASS verdict, or active while RUNNING).
STATE_SYM = {"active": "●", "idle": "○"}


# ── path resolution (all local) ──────────────────────────────────────────────
def resolve_root(env=None):
    """Repo root: HEIMDALL_WATCH_ROOT override > git toplevel > CWD. Local only."""
    env = os.environ if env is None else env
    r = env.get("HEIMDALL_WATCH_ROOT")
    if r:
        return r
    # git toplevel is a local filesystem query, not a network call.
    try:
        import subprocess
        top = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=3,
        )
        if top.returncode == 0 and top.stdout.strip():
            return top.stdout.strip()
    except Exception:
        return os.getcwd()
    return os.getcwd()


def _heimdall_dir(root):
    return os.path.join(root, ".heimdall")


# ── roster (WALL) — reads the local cache the beat cadence maintains ──────────
def read_roster(root):
    """Return (members, payload). members is a list of roster rows
    {handle, haid, verdict, file, age_seconds}. payload is the raw cache object
    (a dict carries the team + entitlement flag; a bare list is members-only).
    Missing cache => empty roster (never an error, never a network call)."""
    path = os.path.join(_heimdall_dir(root), "roster-cache.json")
    if not os.path.exists(path):
        return [], {}
    try:
        with open(path, "r") as f:
            payload = json.load(f)
    except Exception:
        return [], {}
    if isinstance(payload, list):
        return payload, {"members": payload}
    if isinstance(payload, dict):
        members = payload.get("members")
        if members is None:
            members = payload.get("roster") or []
        return list(members), payload
    return [], {}


# ── entitlement (freemium, DARK by default) ──────────────────────────────────
class Entitlement:
    """The freemium boundary as data. `enforced` is the DARK flag: OFF by default
    means everything is unlocked (free/unlocked now — revenue is parked behind the
    star milestone). There is NO team-size input here: the free wall/feed/inspector
    are unlocked at any team size (the Δ1 invariant)."""

    __slots__ = ("enforced", "tier", "_locked")

    def __init__(self, enforced, tier, locked_features):
        self.enforced = bool(enforced)
        self.tier = tier
        self._locked = frozenset(locked_features)

    def locked(self, feature):
        if feature in FREE_FEATURES:
            return False
        return self.enforced and (feature in self._locked)

    def upsell(self, feature):
        if not self.locked(feature):
            return ""
        return _UPSELL.get(feature, "Team tier — hmd upgrade")

    def banner(self):
        """Status-bar fragment for the trial/tier. Dark flag off => a plain free tag."""
        if not self.enforced:
            return "free"
        return "%s · locked: %s" % (self.tier, ", ".join(sorted(self._locked)))


def resolve_entitlement(payload, env=None):
    """Read the entitlement flag from the roster payload if present; default unlocked.
    The env override HEIMDALL_WATCH_ENTITLEMENT (on/off) forces the dark flag, so the
    behaviour is testable and RJ can flip it without a live billing backend."""
    env = os.environ if env is None else env
    ent = {}
    if isinstance(payload, dict):
        ent = payload.get("entitlement") or {}
    enforced = bool(ent.get("enforced", False))
    override = (env.get("HEIMDALL_WATCH_ENTITLEMENT") or "").strip().lower()
    if override in ("on", "1", "true", "enforced", "locked"):
        enforced = True
    elif override in ("off", "0", "false", "unlocked"):
        enforced = False
    tier = ent.get("tier", "free")
    locked = set(ent.get("locked", DEFAULT_LOCKED)) if enforced else set()
    return Entitlement(enforced, tier, locked)


# ── feed (gate events, newest-first) — local receipt/verdict trail ───────────
def read_feed(root, limit=200):
    """Read the local feed trail (<repo>/.heimdall/feed.jsonl), newest-first.
    Each line is one event {ts, verdict, kind, ref, haid, handle, summary,
    receipt_path?}. Missing/partial lines are skipped, never fatal."""
    path = os.path.join(_heimdall_dir(root), "feed.jsonl")
    events = []
    if os.path.exists(path):
        try:
            with open(path, "r") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        events.append(json.loads(line))
                    except Exception:
                        continue
        except Exception:
            events = []
    events.sort(key=lambda e: e.get("ts", 0), reverse=True)
    return events[:limit]


def _confined_realpath(candidate, base):
    """Return the resolved candidate ONLY if it lies within `base` (an allowlisted
    directory), else None. This is the path-traversal gate for INSPECTOR reads: a
    feed item's receipt_path is UNTRUSTED, so an absolute escape (/etc/passwd), a
    `..` traversal (../../etc/passwd), or a symlink pointing outside the base must
    NOT be opened. We realpath both sides (which collapses `..` AND resolves
    symlinks) and require the candidate to sit strictly under base + os.sep. A
    relative candidate is resolved against base; an absolute candidate that still
    lands inside base (e.g. the beat cadence writes absolute receipt paths under
    .heimdall/) is allowed — containment, not the abs/rel distinction, is the gate."""
    if not candidate or not isinstance(candidate, str):
        return None
    base_real = os.path.realpath(base)
    if os.path.isabs(candidate):
        cand = candidate
    else:
        cand = os.path.join(base_real, candidate)
    cand_real = os.path.realpath(cand)
    if cand_real == base_real:
        return None  # the base dir itself is not a receipt file
    if cand_real.startswith(base_real + os.sep):
        return cand_real
    return None


def read_receipt(event, root=None):
    """The INSPECTOR target for a feed item: the local report.json it points at.
    Falls back to an inline receipt or the event's own fields. Local read only;
    scoped to a Heimdall artifact (a report) under <root>/.heimdall — NEVER a
    general file browser. The receipt_path comes from an UNTRUSTED feed item, so
    it is confined to the .heimdall base (_confined_realpath): a crafted absolute
    path, `..` traversal, or symlink escape is refused before any open()."""
    if not event:
        return {}
    if root is None:
        root = resolve_root(os.environ)
    base = _heimdall_dir(root)
    rp = event.get("receipt_path")
    safe = _confined_realpath(rp, base) if rp else None
    if safe and os.path.exists(safe):
        try:
            with open(safe, "r") as f:
                return json.load(f)
        except Exception:
            return {"ref": event.get("ref"), "verdict": event.get("verdict"),
                    "reason_text": "receipt unreadable: %s" % safe}
    if isinstance(event.get("receipt"), dict):
        return event["receipt"]
    return {
        "ref": event.get("ref"),
        "verdict": event.get("verdict"),
        "gate": event.get("kind"),
        "reason_text": event.get("summary", ""),
    }


# ── shell-out table (renderer over existing plumbing) ────────────────────────
# A ref/id is a data-derived value (from the feed/roster) that becomes a CLI
# POSITIONAL. It must match the strict charset the system actually issues — hex
# gate refs (a3f1b2), haid handles (haid:rj-a3f9), dotted/slashed paths — so a
# crafted value can never smuggle a shell metachar or whitespace into an argv slot.
_REF_RE = re.compile(r"^[A-Za-z0-9._:/-]+$")


def _safe_ref(ref):
    """Allowlist a data-derived ref before it reaches a CLI. Returns the trimmed
    ref if it matches the issued-id charset, else None (reject). Note a value like
    `--foo` passes the charset (hyphens are legal in refs) but is still rendered as
    a POSITIONAL after a `--` terminator by build_shell_argv, so it can never be
    read as a flag; values with spaces / `;` / `$` / backticks are rejected here."""
    if not isinstance(ref, str):
        return None
    ref = ref.strip()
    if not ref or not _REF_RE.match(ref):
        return None
    return ref


def build_shell_argv(action, hmd_bin, event=None):
    """Build the argv that SHELLS the existing CLI for an owner action. ALWAYS an
    argv LIST (the caller runs it with shell=False — never a shell string). The TUI
    never reimplements the logic — it execs `hmd <cmd> ...`. Returns [] for an
    unknown action, or for a ref-consuming action whose data-derived ref fails the
    allowlist, so the caller can no-op cleanly.

    Ref-consuming actions (clip/approve/deny) place the validated ref as a POSITIONAL
    after a literal `--` option terminator: this guarantees a ref beginning with `-`
    (e.g. `--foo`, `-rf`) is parsed as an operand, never a flag (argument injection)."""
    raw = (event or {}).get("ref", "") if event else ""
    if action in ("clip", "approve", "deny"):
        ref = _safe_ref(raw)
        if ref is None:
            return []
        return [hmd_bin, action, "--", ref]
    if action == "invite":
        return [hmd_bin, "invite"]
    if action == "presence":
        return [hmd_bin, "presence"]
    return []


# ── presence beat (open the wall == you're on the wall) ───────────────────────
# Opening the wall marks you present: watch emits a lightweight heartbeat through the
# EXISTING beat path so simply watching keeps you TTL-live (when watch closes and the
# TTL lapses you go offline naturally). Like the owner actions, watch NEVER speaks the
# presence protocol itself — it BUILDS the argv here (pure) and the action layer
# (watch_entry one-shot / watch_tui interval) RUNS it best-effort. The beat REUSES
# heimdall-presence: its enroll/sign/HAID resolution + X-Heimdall-Team-Secret header,
# so the heartbeat lands in exactly the partition the watcher's own team.json reads
# back (idempotent upsert keyed by HAID — no duplicate roster rows).
def resolve_presence_bin(env=None):
    """The sibling `heimdall-presence` CLI — the ONE beat path watch reuses. Override
    with HEIMDALL_PRESENCE_BIN (testability / a packaged path); else bin/heimdall-presence
    next to this lib dir; else the bare name resolved on PATH."""
    env = os.environ if env is None else env
    override = env.get("HEIMDALL_PRESENCE_BIN")
    if override:
        return override
    here = os.path.dirname(os.path.abspath(__file__))
    cand = os.path.normpath(os.path.join(here, "..", "heimdall-presence"))
    if os.path.exists(cand):
        return cand
    return "heimdall-presence"


def build_beat_argv(presence_bin):
    """The argv that SHELLS the existing presence beat (heimdall-presence beat). ALWAYS a
    LIST (the caller runs it with shell=False). The beat is best-effort: the caller times
    it out and swallows errors so the wall still renders on a network hiccup."""
    return [presence_bin, "beat"]


# ── render core bridge (consume hmd_sigil + hmd_termcaps; never re-implement) ─
def _sentinels_dir(explicit=None):
    if explicit:
        return explicit
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", "..", "sentinels"))


def _load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_caps(sentinels_dir=None):
    """The shared capability tier (truecolor/256/16/mono) from hmd_termcaps."""
    d = _sentinels_dir(sentinels_dir)
    tc = _load_module("hmd_termcaps", os.path.join(d, "hmd_termcaps.py"))
    return tc.detect()


def load_sigil(sentinels_dir=None):
    """The shared sigil renderer (glyph/compact/large). Consumed, not rebuilt."""
    d = _sentinels_dir(sentinels_dir)
    return _load_module("hmd_sigil", os.path.join(d, "hmd_sigil.py"))


def _emit(caps, line):
    return caps.emit(line) if caps is not None else line


def _seed_of(member):
    return member.get("haid") or member.get("handle") or "?"


def member_state(member):
    """The wall state ("active"/"idle") for a roster row. The server-derived `state` field
    wins; a LEGACY row without it (an old roster cache / an old server) falls back to a
    verdict-based guess — the idle/watching sentinels read idle, everything else active — so
    the wall still renders distinctly against an old cache (backward-compatible)."""
    s = str(member.get("state") or "").strip().lower()
    if s in STATE_SYM:
        return s
    v = str(member.get("verdict") or "").strip().lower()
    return "idle" if v in ("watching", "idle") else "active"


# ── panes ─────────────────────────────────────────────────────────────────────
def render_wall(members, caps=None, sig=None):
    """WALL pane: one line per teammate — presence badge + sigil glyph + handle + verdict.
    The presence badge (● active / ○ idle) renders the server-derived wall state distinctly so
    a glance separates who is working now from who is here but idle (offline devs are already
    absent from the roster)."""
    lines = ["WALL"]
    if not members:
        lines.append("  (no teammates online)")
        return lines
    for m in members:
        handle = m.get("handle") or m.get("haid") or "?"
        verdict = (m.get("verdict") or "-")
        sym = VERDICT_SYM.get(verdict.upper(), "·")
        badge = STATE_SYM.get(member_state(m), "●")
        try:
            glyph = sig.glyph(_seed_of(m)) if sig is not None else "◉"
        except Exception:
            glyph = "◉"
        line = "%s %s %-8s %s %s" % (badge, glyph, handle[:8], sym, verdict)
        lines.append(_emit(caps, line))
    return lines


def render_feed(events, caps=None):
    """FEED pane: gate events newest-first (caller passes a newest-first list)."""
    lines = ["FEED"]
    if not events:
        lines.append("  (no gate events yet)")
        return lines
    for e in events:
        ts = e.get("ts")
        hhmm = time.strftime("%H:%M", time.localtime(ts)) if ts else "--:--"
        verdict = (e.get("verdict") or "-")
        sym = VERDICT_SYM.get(verdict.upper(), "•")
        summary = e.get("summary", "")
        handle = e.get("handle", "")
        ref = e.get("ref", "")
        line = "%s %s %s %s (%s) %s" % (hhmm, sym, verdict, summary, ref, handle)
        lines.append(_emit(caps, line))
    return lines


def render_inspector(receipt, caps=None):
    """INSPECTOR pane: the receipt for a selected DENY/PASS event — deny reason
    (coded + human), the failing hunk, falsify/reuse/bloat numbers, retry history."""
    r = receipt or {}
    ref = r.get("ref", "?")
    gate = r.get("gate", "?")
    code = r.get("reason_code") or "-"
    text = r.get("reason_text") or ""
    lines = ["INSPECTOR"]
    lines.append("deny %s · %s gate · reason: %s" % (ref, gate, code))
    if text:
        lines.append("  %s" % text)
    diff = r.get("diff") or ""
    if diff:
        lines.append("  ┌ diff (failing hunk) ┐")
        for dl in diff.split("\n"):
            lines.append("  %s" % dl)
        lines.append("  └─────────────────────┘")
    fal = r.get("falsify") or {}
    surv, tot = fal.get("survived"), fal.get("total")
    reuse = (r.get("reuse") or {}).get("score")
    bloat = r.get("bloat") or {}
    added, budget = bloat.get("added_lines"), bloat.get("budget")
    lines.append("  falsify %s/%s · reuse %s · bloat %s/%s"
                 % (surv, tot, reuse, added, budget))
    retries = r.get("retries") or []
    lines.append("  retries: %d attempt(s)" % len(retries))
    for rt in retries:
        lines.append("    #%s %s %s"
                     % (rt.get("attempt"), rt.get("verdict"), rt.get("reason", "")))
    ttg = r.get("time_to_green")
    if ttg is not None:
        lines.append("  time-to-green: %s" % ttg)
    return [_emit(caps, l) for l in lines]


def render_reports(root, caps=None):
    """REPORTS view: morning/sleep reports + the weekly 'watchman learned' changelog,
    read from local .planning artifacts. Returned as markdown text (Textual renders it;
    the static path prints it raw). Local reads only."""
    out = []
    candidates = [
        os.path.join(root, ".planning", "reports"),
        os.path.join(root, ".planning"),
    ]
    found = []
    for base in candidates:
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            low = name.lower()
            if low.endswith(".md") and any(
                k in low for k in ("morning", "sleep", "report", "learned", "weekly", "changelog")
            ):
                found.append(os.path.join(base, name))
    if not found:
        return ["# Reports", "", "_No reports yet — they appear after a morning/sleep run._"]
    for path in found:
        out.append("# %s" % os.path.basename(path))
        out.append("")
        try:
            with open(path, "r") as f:
                out.extend(f.read().splitlines())
        except Exception:
            out.append("_(unreadable: %s)_" % path)
        out.append("")
    return out


def status_bar(team_n, ent, caps=None):
    line = "status: team %d · %s · ? help" % (team_n, ent.banner())
    return _emit(caps, line)


# ── textual install hint (interpreter-aware + PEP-668-aware) ─────────────────
# The rich Textual TUI is an OPTIONAL enhancement, never a hard dependency. When it is
# absent we must tell the user how to install it INTO THE EXACT interpreter hmd's watch
# runs under (the one that does `import textual`) — NOT into an isolated pipx/brew venv
# hmd can't import from (the live footgun: `pipx install textual` succeeds but hmd's
# python3 still can't `import textual`). sys.executable IS that interpreter. On a PEP-668
# externally-managed python (modern macOS / Homebrew / Debian) a plain `pip install`
# errors, so we surface the `--break-system-packages` escape. Pure string-building; the
# only I/O is a stat() for the EXTERNALLY-MANAGED marker.
def _externally_managed():
    """True if THIS interpreter is PEP-668 externally-managed (an EXTERNALLY-MANAGED
    marker in its stdlib dir). Best-effort: any error => assume not managed."""
    import sysconfig
    try:
        stdlib = sysconfig.get_path("stdlib")
    except Exception:
        stdlib = None
    return bool(stdlib and os.path.exists(os.path.join(stdlib, "EXTERNALLY-MANAGED")))


def textual_install_hint(env=None):
    """The EXACT command to install textual into hmd-watch's OWN interpreter. Targets
    sys.executable (the python that does `import textual` here), PEP-668-aware. Returns a
    single shell-ready string. NEVER suggests `pipx install textual` (isolated venv →
    hmd's python can't import it)."""
    import shlex
    py = shlex.quote(sys.executable or "python3")
    if _externally_managed():
        return "%s -m pip install --user --break-system-packages textual" % py
    return "%s -m pip install --user textual" % py


# ── wall+feed+status BODY (shared by the static dump and the live auto-refresh loop) ──
def render_dump(root, caps=None, sig=None, env=None):
    """The wall+feed+status body as a list of lines. Shared by the one-shot static dump
    (static_dump) and the no-textual auto-refresh live loop (watch_entry). Local reads
    only — NO network, NO textual dependency."""
    env = os.environ if env is None else env
    members, payload = read_roster(root)
    ent = resolve_entitlement(payload, env)
    events = read_feed(root)
    out = []
    out.extend(render_wall(members, caps, sig))
    out.append("")
    out.extend(render_feed(events, caps))
    out.append("")
    out.append(status_bar(len(members), ent, caps))
    return out


# ── the Textual-absent one-shot dump (wall + feed + status) ──────────────────
def static_dump(root, caps=None, sig=None, textual_present=True, env=None):
    env = os.environ if env is None else env
    out = render_dump(root, caps, sig, env)
    if not textual_present:
        out.append("")
        out.append("textual not installed — showing a static one-shot wall+feed.")
        out.append("For the rich interactive dashboard, install textual into hmd's own python:")
        out.append("  " + textual_install_hint(env))
    return "\n".join(out)


if __name__ == "__main__":
    # A tiny local self-render for smoke use: `python3 watch_data.py [--once]`.
    root = resolve_root()
    try:
        caps = load_caps()
    except Exception:
        caps = None
    try:
        sig = load_sigil()
    except Exception:
        sig = None
    textual_present = importlib.util.find_spec("textual") is not None
    sys.stdout.write(static_dump(root, caps, sig, textual_present) + "\n")
