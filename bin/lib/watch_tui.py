#!/usr/bin/env python3
"""
watch_tui.py — the Textual dashboard for `hmd watch` (spec section C).

This is the RENDERER. All data comes from watch_data (local caches, zero network);
all owner actions (approve/deny/clip/invite/presence) are SHELL-OUTS to the existing
CLI via subprocess — this module never reimplements verdict/gate/presence logic.

Layout: WALL (roster, live) | FEED (gate events, newest-first) over an INSPECTOR
tab (the selected event's receipt) with a REPORTS view (`r`) and a status bar. It
degrades per capability tier through the shared render core (hmd_termcaps caps.emit).

Importing this module requires Textual. The launcher (heimdall-watch-tui) only imports
it when Textual is present; otherwise it falls back to watch_data.static_dump().
"""

import os
import importlib.util
import subprocess

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.widgets import Static, Footer, Markdown

# ── load the local data core (sibling file) ──────────────────────────────────
_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("watch_data", os.path.join(_HERE, "watch_data.py"))
wd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wd)


def _resolve_hmd_bin():
    """The sibling `hmd` entry point (bin/hmd), used for every shell-out."""
    cand = os.path.normpath(os.path.join(_HERE, "..", "hmd"))
    if os.path.exists(cand):
        return cand
    return "hmd"


# Refresh cadence for the local caches. This is a LOCAL FILE re-read, NOT a network
# poll — the beat/roster cadence that populates the caches runs independently.
_REFRESH_SECONDS = 2.0


class WatchApp(App):
    """The full dashboard. `--pane` slim mode renders the wall only."""

    CSS = """
    Screen { layout: vertical; }
    #top { height: 60%; }
    #wall { width: 34%; border: round $accent; }
    #feed { width: 1fr; border: round $accent; }
    #inspector { height: 1fr; border: round $secondary; }
    #statusbar { height: 1; dock: bottom; }
    .locked { color: $warning; }
    """

    BINDINGS = [
        Binding("j", "select_next", "down", show=False),
        Binding("k", "select_prev", "up", show=False),
        Binding("enter", "inspect", "inspect"),
        Binding("c", "clip", "clip"),
        Binding("i", "invite", "invite"),
        Binding("p", "presence", "presence"),
        Binding("r", "reports", "reports"),
        Binding("a", "approve", "approve"),
        Binding("d", "deny", "deny"),
        Binding("question_mark", "help", "help"),
        Binding("q", "quit", "quit"),
    ]

    def __init__(self, root, caps, sig, slim=False, **kw):
        super().__init__(**kw)
        self._root = root
        self._caps = caps
        self._sig = sig
        self._slim = slim
        self._hmd = _resolve_hmd_bin()
        self._events = []
        self._sel = 0
        self._members = []
        self._ent = wd.resolve_entitlement({}, os.environ)
        self._showing_reports = False

    # ── compose ──────────────────────────────────────────────────────────────
    def compose(self) -> ComposeResult:
        if self._slim:
            yield Static(id="wall")
            yield Static(id="statusbar")
            return
        with Vertical():
            with Horizontal(id="top"):
                yield Static(id="wall")
                yield Static(id="feed")
            yield Static(id="inspector")
            yield Static(id="statusbar")
        yield Footer()

    def on_mount(self):
        self.refresh_data()
        self.set_interval(_REFRESH_SECONDS, self.refresh_data)

    # ── data (local reads only) ──────────────────────────────────────────────
    def refresh_data(self):
        self._members, payload = wd.read_roster(self._root)
        self._ent = wd.resolve_entitlement(payload, os.environ)
        self._events = wd.read_feed(self._root)
        if self._sel >= len(self._events):
            self._sel = max(0, len(self._events) - 1)
        self._paint()

    def _selected_event(self):
        if 0 <= self._sel < len(self._events):
            return self._events[self._sel]
        return None

    # ── paint ────────────────────────────────────────────────────────────────
    def _paint(self):
        wall = self.query_one("#wall", Static)
        wall.update("\n".join(wd.render_wall(self._members, self._caps, self._sig)))
        if self._slim:
            self._paint_status()
            return
        feed = self.query_one("#feed", Static)
        feed_lines = wd.render_feed(self._events, self._caps)
        # mark the selected row (header is line 0)
        marked = []
        for idx, ln in enumerate(feed_lines):
            if idx - 1 == self._sel and idx > 0:
                marked.append("› " + ln)
            elif idx > 0:
                marked.append("  " + ln)
            else:
                marked.append(ln)
        feed.update("\n".join(marked))
        if not self._showing_reports:
            self._paint_inspector()
        self._paint_status()

    def _paint_inspector(self):
        insp = self.query_one("#inspector", Static)
        ev = self._selected_event()
        if ev is None:
            insp.update("INSPECTOR\n  (select a feed item, then Enter)")
            return
        receipt = wd.read_receipt(ev)
        insp.update("\n".join(wd.render_inspector(receipt, self._caps)))

    def _paint_status(self):
        bar = self.query_one("#statusbar", Static)
        bar.update(wd.status_bar(len(self._members), self._ent, self._caps))

    # ── selection ────────────────────────────────────────────────────────────
    def action_select_next(self):
        if self._events:
            self._sel = min(self._sel + 1, len(self._events) - 1)
            self._showing_reports = False
            self._paint()

    def action_select_prev(self):
        if self._events:
            self._sel = max(self._sel - 1, 0)
            self._showing_reports = False
            self._paint()

    def action_inspect(self):
        self._showing_reports = False
        self._paint_inspector()

    # ── owner actions: SHELL the existing CLI (never reimplement) ─────────────
    def _shell(self, action):
        ev = self._selected_event()
        argv = wd.build_shell_argv(action, self._hmd, ev)
        if not argv:
            self.notify("no CLI path for %s" % action, severity="warning")
            return
        try:
            res = subprocess.run(argv, capture_output=True, text=True, timeout=60)
            out = (res.stdout or res.stderr or "").strip().splitlines()
            head = out[0] if out else ("%s ok" % action)
            sev = "information" if res.returncode == 0 else "error"
            self.notify("%s: %s" % (action, head), severity=sev)
        except Exception as exc:
            self.notify("%s failed: %s" % (action, exc), severity="error")

    def action_clip(self):
        self._shell("clip")

    def action_invite(self):
        self._shell("invite")

    def action_presence(self):
        self._shell("presence")
        self.refresh_data()

    def action_approve(self):
        self._shell("approve")
        self.refresh_data()

    def action_deny(self):
        self._shell("deny")
        self.refresh_data()

    # ── reports (markdown) ────────────────────────────────────────────────────
    def action_reports(self):
        if self._slim:
            self.notify("reports unavailable in --pane slim mode", severity="warning")
            return
        self._showing_reports = True
        insp = self.query_one("#inspector", Static)
        md = "\n".join(wd.render_reports(self._root, None))
        # locked-pane rendering for the archive freemium feature
        if self._ent.locked("archive"):
            md += "\n\n> 🔒 %s" % self._ent.upsell("archive")
        try:
            insp.update(Markdown(md))
        except Exception:
            insp.update(md)

    def action_help(self):
        rows = ["KEYS"]
        for key, act in wd.KEYMAP.items():
            rows.append("  %-6s %s" % (key, act))
        self.notify("\n".join(rows), title="hmd watch — keymap", timeout=8)


def run(root, caps, sig, slim=False):
    """Entry point used by the bin launcher when Textual is present."""
    WatchApp(root, caps, sig, slim=slim).run()
