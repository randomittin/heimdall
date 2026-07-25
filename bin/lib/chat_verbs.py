#!/usr/bin/env python3
# chat_verbs.py — chat-ops P2 READ VERBS: status / investigate / report (§1, read-only).
#
# Every verb is TEAM-SCOPED through chat_link.resolve(chat_id): an UNBOUND / forged chat_id
# resolves to NO team, so the verb REFUSES with the link instruction and returns NO data
# (INV-CHAT — the C1-unbound-chat oracle). A bound chat only ever sees ITS OWN team's data —
# every read is keyed by the server-derived team_id, so a verb can never cross a partition.
#
# investigate (§3 the payoff): reads P1's hmd/context worklog FIRST (chat_worklog, via
# `git show hmd/context:worklog.json` — plumbing, no checkout), CITES what it resumed from,
# then applies the BYO-INFERENCE invariant (§4): a team with NO registered model credential
# gets the one-line connect instruction and NOTHING is dispatched (never run on RJ's wallet);
# a team WITH a credential has its triage task ENQUEUED into its own partition via the
# EXISTING team-queue enqueue-only sink (cp_team_queue) — the same signed-dispatch path the
# public surface uses. No fix/branch/PR here (that is P3) — investigate is a read-only job.
#
# stdlib-only + the cp stores (chat_link, chat_worklog, cp_team_creds, cp_team_queue).

from __future__ import annotations

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import chat_link
import chat_worklog
import cp_team_creds   # has_cred(team_id) — the BYO-inference gate (§4).
import cp_team_queue   # enqueue(team_id, task) — the enqueue-only, team-partitioned dispatch.

# The refusal a verb returns for an unbound/forged chat_id — the ONLY thing an unbound handle
# ever gets. No team data, ever.
_LINK_INSTRUCTION = (
    "You're not linked yet. On an enrolled machine run `hmd link telegram` to get a 6-digit "
    "code, then DM me `/hmd link <code>`. Until then I can't act on your behalf."
)

# The BYO-inference connect instruction (§4) — shown when the team has no model credential.
# Heimdall never runs inference on its own wallet for a team that hasn't connected one.
_CONNECT_INSTRUCTION = (
    "Your team has no model credential connected, so I won't run inference on your behalf. "
    "Connect one with `rr connect` (BYO-inference), then re-run investigate."
)


def _short(team_id):
    """A short, non-secret team handle for display (the first 8 hex of the partition id)."""
    return (team_id or "")[:8]


def _unbound(channel="telegram"):
    """The uniform refusal for an unbound chat_id — no team, no data, just the link path."""
    return {"ok": False, "verb": None, "bound": False, "team": None,
            "reply": _LINK_INSTRUCTION, "reason": "unbound"}


def status(chat_id, *, channel=chat_link.DEFAULT_CHANNEL, home=None):
    """The `status` verb (§1): the bound team's wall + recent verdicts + open denies. Every
    figure is team-scoped (keyed by the server-derived team_id). Unbound -> refusal, no data."""
    team = chat_link.resolve(chat_id, channel=channel, home=home)
    if not team:
        return _unbound(channel)

    # All reads below are scoped to THIS team_id partition — never another team's rows.
    rows = cp_team_queue.list(team, home=home)
    queued = [r for r in rows if r.get("state") == "queued"]
    in_flight = [r for r in rows if r.get("state") == "in_flight"]
    done = [r for r in rows if r.get("state") == "done"]
    dead = [r for r in rows if r.get("state") == "dead"]

    lines = ["status for team %s" % _short(team)]
    lines.append("  queue: %d queued, %d in-flight, %d done, %d dead (open denies)"
                 % (len(queued), len(in_flight), len(done), len(dead)))
    if done:
        recent = done[-3:]
        verdicts = ", ".join("%s=%s" % (r.get("id", "?")[:8], r.get("verdict") or "?")
                             for r in recent)
        lines.append("  last verdicts: %s" % verdicts)
    if dead:
        deads = ", ".join("%s (%s)" % (r.get("id", "?")[:8], r.get("reason") or "?")
                          for r in dead[:3])
        lines.append("  open denies: %s" % deads)
    if not rows:
        lines.append("  no tasks in this team's queue yet.")

    return {"ok": True, "verb": "status", "bound": True, "team": team,
            "reply": "\n".join(lines),
            "data": {"queued": len(queued), "in_flight": len(in_flight),
                     "done": len(done), "dead": len(dead)}}


def report(chat_id, *, channel=chat_link.DEFAULT_CHANNEL, home=None, repo=None):
    """The `report` verb (§1): the last session/audit report rendered to the thread. Sourced
    from P1's hmd/context worklog (summary + open cases + recent commits). Unbound -> refusal."""
    team = chat_link.resolve(chat_id, channel=channel, home=home)
    if not team:
        return _unbound(channel)

    wl_result = chat_worklog.read_worklog(repo)
    lines = ["report for team %s" % _short(team)]
    if wl_result.get("available"):
        wl = wl_result.get("worklog") or {}
        lines.append("  %s" % chat_worklog.resume_citation(wl_result))
        if wl.get("goal"):
            lines.append("  goal: %s" % str(wl["goal"]).strip())
        open_cases = wl.get("open_cases") or []
        if open_cases:
            lines.append("  open cases: %s" % ", ".join(str(c) for c in open_cases[:5]))
        commits = wl.get("recent_commits") or []
        if commits:
            lines.append("  recent commits:")
            for c in commits[:5]:
                lines.append("    %s" % str(c).strip())
    else:
        lines.append("  %s" % chat_worklog.resume_citation(wl_result))

    return {"ok": True, "verb": "report", "bound": True, "team": team,
            "reply": "\n".join(lines), "worklog_available": bool(wl_result.get("available"))}


def investigate(chat_id, *, hint=None, channel=chat_link.DEFAULT_CHANNEL, home=None,
                repo=None, enqueue=None):
    """The `investigate` verb (§3/§4): resume from the P1 worklog, cite it, then (BYO-gated)
    enqueue a read-only triage task into the team's OWN partition.

    Flow:
      1. resolve the team (unbound -> refusal, no data).
      2. read P1's hmd/context worklog FIRST and CITE what it resumed from.
      3. BYO-inference gate (§4): no team model credential -> reply the connect instruction,
         enqueue NOTHING (never run on RJ's wallet). With a credential -> enqueue the triage
         task into the team's partition via the existing enqueue-only sink.

    `enqueue` is an injectable seam (default cp_team_queue.enqueue) so tests exercise the
    dispatch path without a live drain. Returns a dict with the citation, the BYO decision,
    and the enqueued task id (when dispatched)."""
    team = chat_link.resolve(chat_id, channel=channel, home=home)
    if not team:
        return _unbound(channel)

    # STEP 2 — resume from the P1 worklog FIRST (it resumes, it does not rediscover, §3).
    wl_result = chat_worklog.read_worklog(repo)
    citation = chat_worklog.resume_citation(wl_result)
    lines = ["investigate for team %s" % _short(team), "  %s" % citation]

    # STEP 3 — BYO-inference gate (§4). No credential => connect instruction, NO dispatch.
    if not cp_team_creds.has_cred(team, home=home):
        lines.append("  %s" % _CONNECT_INSTRUCTION)
        return {"ok": True, "verb": "investigate", "bound": True, "team": team,
                "dispatched": False, "byo_ready": False,
                "worklog_available": bool(wl_result.get("available")),
                "citation": citation, "reply": "\n".join(lines)}

    # With a team credential: enqueue the read-only triage task into the team's OWN partition
    # (the existing enqueue-only, team-partitioned dispatch — the same sink the public surface
    # writes to; a task can NEVER be enqueued into another team's partition here).
    task_text = "investigate: %s" % (hint.strip() if isinstance(hint, str) and hint.strip()
                                     else "see what's breaking (resume from hmd/context)")
    enqueue_fn = enqueue if enqueue is not None else cp_team_queue.enqueue
    result = enqueue_fn(team, task_text, home=home)
    dispatched = bool(isinstance(result, dict) and result.get("ok"))
    task_id = result.get("id") if isinstance(result, dict) else None
    if dispatched:
        lines.append("  enqueued triage task %s into your team's queue." % (task_id or "?"))
    else:
        reason = result.get("reason") if isinstance(result, dict) else "unknown"
        lines.append("  could not enqueue the triage task (%s)." % reason)

    return {"ok": dispatched, "verb": "investigate", "bound": True, "team": team,
            "dispatched": dispatched, "byo_ready": True, "task_id": task_id,
            "worklog_available": bool(wl_result.get("available")),
            "citation": citation, "reply": "\n".join(lines)}
