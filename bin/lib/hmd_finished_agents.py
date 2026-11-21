#!/usr/bin/env python3
"""hmd_finished_agents.py -- background agents that finished and were never closed, and the one line that tells the model so.

WHY. A background agent that has delivered its result stays listed by the harness until something calls TaskStop on it, and the
rule meant to close them (agents/heimdall.md 4d: TaskStop on an idle_notification) never fires for an unnamed agent: one session
of 1,510 unnamed spawns received none (docs/analysis/2026-11-20-finished-agents-still-listed.md). Prose rules have a poor record
here, so this is mechanical: a hook records each finish, a hook forgets each close, a hook says what is left.

HOOK EVENTS, AND THE PAYLOAD FIELD EACH ONE READS (checked against real payloads and transcripts, 2026-11-22):
  SubagentStop        subagent-stop  agent_id and session_id. agent_id is the id TaskStop takes: a task-notification's <task-id> is
                                     the same string as agent-<id>.jsonl. The spawn description, requestShape and spawnDepth come
                                     from the sidecar beside agent_transcript_path (agent-<id>.meta.json). Only a BACKGROUND DIRECT
                                     CHILD (requestShape "background", spawnDepth 1) that stopped with no running entry in
                                     background_tasks counts: a foreground agent answered its spawn call, a grandchild belongs to
                                     its parent, and an agent still waiting on its own background work is not finished (the harness
                                     says the same: "fires each time this agent stops with no live background children"). Without
                                     a readable sidecar nothing is recorded: background cannot be shown.
  PostToolUse         tool-done      matcher TaskStop|SendMessage. TaskStop: tool_input.task_id (shell_id is its old name), the
                                     entry is closed. SendMessage: tool_input.to, the agent is live again, the entry is dropped.
  PostToolUseFailure  tool-failed    matcher TaskStop. An error that says "No task found" or "is not running" means the harness
                                     holds nothing to stop, so the entry would ask for the impossible on every prompt (75 of 238
                                     stops failed in the measured session, 62 of them "No task found").
  UserPromptSubmit    prompt         session_id; prints one line of hookSpecificOutput.additionalContext. A <task-notification> turn
                                     fires this event too (measured: every notice in the orchestrator transcript is followed by
                                     hook_additional_context attachments of hookEvent UserPromptSubmit), so the line arrives with
                                     the notice that an agent finished. No Stop hook: its output reaches the model only through
                                     decision:block, which would force a turn.

STATE. $HEIMDALL_HOME/finished-agents/<session id>.jsonl, one event per line, append-only: {"ev":"finished","id","ts","desc","type"}
and {"ev":"closed","id","ts","why"}. An agent is OPEN when its last event is a finish. Every read and write goes through
bin/lib/hmd_private_state.py (0700 directory, 0600 files, no link followed, one flock around every change). Bounded: a log growing
past 32 KiB is rewritten as its newest 100 open entries, an entry older than 7 days is forgotten, a session log untouched for 7 days
is removed by the next recording, and a log with nothing open is removed, so the common state costs a file test and nothing more.

FAIL-OPEN. The hook verbs exit 0 on every path: an unexpected error is one line on stderr. The CLI verbs keep their codes.

    heimdall-finished-agents list [--session ID] [--json]             agents still open, oldest first (the default verb)
    heimdall-finished-agents clear (--all | --session ID | --id ID)   forget entries; stops nothing
    heimdall-finished-agents subagent-stop | tool-done | tool-failed  hook verbs, the payload on stdin
    heimdall-finished-agents prompt [--session ID]                    hook verb, the payload on stdin unless --session is given
Exit: 0 done, 1 the state could not be read or written (list, clear), 2 usage.
"""
import argparse
import json
import os
import re
import stat
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hmd_private_state as ps  # noqa: E402  (the 0700/0600, link-free state every per-user record of hmd uses)

REL = "finished-agents"
LOCK = ".lock"

MAX_PAYLOAD = 8 << 20      # bytes read from a hook's stdin
MAX_SIDECAR = 64 << 10     # bytes read from an agent's .meta.json
MAX_LOG_READ = 1 << 20     # a log past this is not trusted (ps.read) and is rewritten by the next recording
COMPACT_AT = 32 << 10      # a log growing past this is rewritten as its open entries
MAX_OPEN = 100             # open entries kept per session: the newest
MAX_AGE_S = 7 * 24 * 3600  # an entry older than this is forgotten; so is a session log untouched this long
MAX_DESC = 120             # characters of a description kept
LINE_DESC = 60             # characters of it shown to the model
MAX_LISTED = 6             # agents the model-facing line names

SESSION_RE = re.compile(r"[A-Za-z0-9_-]{1,128}")
AGENT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}")
GONE_RE = re.compile(r"no task found|is not running", re.I)
FAILED_RE = re.compile(r"\s*(error\b|no task found)", re.I)
CONTROL_RE = re.compile("[\x00-\x1f\x7f-\x9f  ]+")


def state_root():
    home = os.environ.get("HEIMDALL_HOME")
    if home:
        return home
    return os.path.join(os.environ.get("HOME") or "/tmp", ".heimdall")


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    return value


def clean(value, limit):
    """One line without control characters, at most `limit` characters; "" for anything that is not text."""
    if not isinstance(value, str):
        return ""
    return CONTROL_RE.sub(" ", value).strip()[:limit]


def plain(value, pattern):
    return value if isinstance(value, str) and pattern.fullmatch(value) else None


def log_name(session):
    return session + ".jsonl"


# -- state ---------------------------------------------------------------------------------------------------------------------

def read_events(root, session):
    raw = ps.read(root, REL, log_name(session), limit=MAX_LOG_READ)
    if raw is None:
        return []
    events = []
    for line in raw.decode("utf-8", "replace").splitlines():
        try:
            ev = json.loads(line)
        except (ValueError, RecursionError):
            continue
        if (isinstance(ev, dict) and ev.get("ev") in ("finished", "closed")
                and isinstance(ev.get("id"), str) and AGENT_RE.fullmatch(ev["id"])):
            events.append(ev)
    return events


def open_entries(events, at):
    """The agents whose last event is a finish, oldest first. An entry older than MAX_AGE_S is forgotten."""
    last = {}
    for ev in events:
        last[ev["id"]] = ev
    entries = [ev for ev in last.values() if ev["ev"] == "finished" and at - number(ev.get("ts")) <= MAX_AGE_S]
    entries.sort(key=lambda ev: number(ev.get("ts")))
    return entries


def event_line(ev):
    return (json.dumps(ev, separators=(",", ":")) + "\n").encode("ascii")


def update(root, session, decide):
    """Under the lock: let decide(open entries) name one event to record, or None, and record it. A log left with nothing open is
    removed; one grown past COMPACT_AT is rewritten as its newest MAX_OPEN open entries. Returns the event recorded, or None."""
    name = log_name(session)
    ps.ensure_dir(root, REL)
    with ps.lock(root, REL, LOCK):
        at = int(time.time())
        events = read_events(root, session)
        ev = decide(open_entries(events, at))
        if ev is None:
            return None
        events.append(ev)
        still_open = open_entries(events, at)
        if not still_open:
            ps.remove(root, REL, name)
            return ev
        line = event_line(ev)
        st = ps.stat_file(root, REL, name)
        if st is not None and st.st_size + len(line) > COMPACT_AT:
            ps.write(root, REL, name, b"".join(event_line(e) for e in still_open[-MAX_OPEN:]))
        else:
            ps.append(root, REL, name, line)
        return ev


def close_entry(root, session, target, why):
    """Record that `target` is no longer a finished agent waiting to be closed. Nothing is written for an id that is not listed."""
    if not any(e["id"] == target for e in open_entries(read_events(root, session), int(time.time()))):
        return None

    def decide(entries):
        if any(e["id"] == target for e in entries):
            return {"ev": "closed", "id": target, "ts": int(time.time()), "why": why}
        return None

    return update(root, session, decide)


def drop_if_nothing_open(root, session, at):
    if ps.stat_file(root, REL, log_name(session)) is None:
        return
    with ps.lock(root, REL, LOCK):
        if not open_entries(read_events(root, session), at):
            ps.remove(root, REL, log_name(session))


def prune_old(root, keep):
    cutoff = time.time() - MAX_AGE_S
    for name in ps.names(root, REL):
        if not name.endswith(".jsonl") or name == log_name(keep):
            continue
        st = ps.stat_file(root, REL, name)
        if st is not None and st.st_mtime < cutoff:
            ps.remove(root, REL, name)


def all_sessions(root):
    return [n[:-len(".jsonl")] for n in ps.names(root, REL)
            if n.endswith(".jsonl") and SESSION_RE.fullmatch(n[:-len(".jsonl")])]


# -- payloads ------------------------------------------------------------------------------------------------------------------

def read_payload():
    try:
        raw = sys.stdin.buffer.read(MAX_PAYLOAD)
        obj = json.loads(raw.decode("utf-8", "replace"))
    except (OSError, ValueError, RecursionError):
        return {}
    return obj if isinstance(obj, dict) else {}


def load_sidecar(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        raw = os.read(fd, MAX_SIDECAR)
    except OSError:
        return None
    finally:
        os.close(fd)
    try:
        obj = json.loads(raw.decode("utf-8", "replace"))
    except (ValueError, RecursionError):
        return None
    return obj if isinstance(obj, dict) else None


def sidecar_for(payload, agent):
    """The harness's agent-<id>.meta.json: beside agent_transcript_path, else under the main transcript's subagents directory."""
    paths = []
    atp = payload.get("agent_transcript_path")
    if isinstance(atp, str) and atp.endswith(".jsonl"):
        paths.append(atp[:-len(".jsonl")] + ".meta.json")
    tp = payload.get("transcript_path")
    if isinstance(tp, str) and tp.endswith(".jsonl"):
        paths.append(os.path.join(tp[:-len(".jsonl")], "subagents", "agent-%s.meta.json" % agent))
    for path in paths:
        meta = load_sidecar(path)
        if meta is not None:
            return meta
    return None


def waiting_on_children(payload):
    tasks = payload.get("background_tasks")
    if not isinstance(tasks, list):
        return False
    return any(isinstance(t, dict) and t.get("status") == "running" for t in tasks)


def failed_response(response):
    if isinstance(response, dict):
        return response.get("is_error") is True or "error" in response
    if isinstance(response, str):
        return bool(FAILED_RE.match(response) or GONE_RE.search(response))
    return False


# -- hook verbs ----------------------------------------------------------------------------------------------------------------

def hook_subagent_stop():
    payload = read_payload()
    session = plain(payload.get("session_id"), SESSION_RE)
    agent = plain(payload.get("agent_id"), AGENT_RE)
    if not session or not agent or waiting_on_children(payload):
        return
    meta = sidecar_for(payload, agent)
    if meta is None or meta.get("requestShape") != "background":
        return
    depth = meta.get("spawnDepth")
    if type(depth) is int and depth > 1:
        return
    ev = {"ev": "finished", "id": agent, "ts": int(time.time()), "desc": clean(meta.get("description"), MAX_DESC),
          "type": clean(payload.get("agent_type") or meta.get("agentType"), 60)}
    root = state_root()
    os.makedirs(root, 0o700, exist_ok=True)
    update(root, session, lambda entries: ev)
    prune_old(root, session)


def hook_tool_done():
    payload = read_payload()
    session = plain(payload.get("session_id"), SESSION_RE)
    tool_input = payload.get("tool_input")
    if not session or not isinstance(tool_input, dict) or failed_response(payload.get("tool_response")):
        return
    tool = payload.get("tool_name")
    if tool == "TaskStop":
        target, why = tool_input.get("task_id") or tool_input.get("shell_id"), "stopped"
    elif tool == "SendMessage":
        target, why = tool_input.get("to"), "resumed"
    else:
        return
    target = plain(target, AGENT_RE)
    if target:
        close_entry(state_root(), session, target, why)


def hook_tool_failed():
    payload = read_payload()
    session = plain(payload.get("session_id"), SESSION_RE)
    tool_input = payload.get("tool_input")
    if payload.get("tool_name") != "TaskStop" or not session or not isinstance(tool_input, dict):
        return
    text = payload.get("error")
    if not isinstance(text, str):
        text = payload.get("tool_response")
    if not isinstance(text, str) or not GONE_RE.search(text):
        return
    target = plain(tool_input.get("task_id") or tool_input.get("shell_id"), AGENT_RE)
    if target:
        close_entry(state_root(), session, target, "gone")


def age(secs):
    minutes = int(max(secs, 0) // 60)
    if minutes < 1:
        return "<1m"
    if minutes < 60:
        return "%dm" % minutes
    hours, minutes = divmod(minutes, 60)
    if hours < 24:
        return "%dh%02dm" % (hours, minutes)
    return "%dd%02dh" % divmod(hours, 24)


def nag_line(entries, at):
    shown = entries[:MAX_LISTED]
    named = []
    for e in shown:
        desc = clean(e.get("desc"), LINE_DESC)
        when = "finished %s ago" % age(at - number(e.get("ts")))
        named.append("%s (%s)" % (e["id"], "%s, %s" % (desc, when) if desc else when))
    total = len(entries)
    text = "%d finished agent%s still open: %s" % (total, "" if total == 1 else "s", ", ".join(named))
    if total > len(shown):
        text += " (+%d more: hmd agents finished list)" % (total - len(shown))
    if total == 1:
        return text + " — TaskStop it unless keeping it for follow-up."
    return text + " — TaskStop them unless keeping one for follow-up."


def hook_prompt(session_arg):
    session = plain(session_arg, SESSION_RE)
    if session is None:
        session = plain(read_payload().get("session_id"), SESSION_RE)
    if session is None:
        return
    root = state_root()
    at = int(time.time())
    entries = open_entries(read_events(root, session), at)
    if not entries:
        drop_if_nothing_open(root, session, at)
        return
    out = {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": nag_line(entries, at)}}
    sys.stdout.write(json.dumps(out) + "\n")


HOOKS = {"subagent-stop": hook_subagent_stop, "tool-done": hook_tool_done, "tool-failed": hook_tool_failed}


# -- CLI verbs -----------------------------------------------------------------------------------------------------------------

def rows(root, sessions, at):
    found = []
    for sid in sessions:
        for e in open_entries(read_events(root, sid), at):
            ts = int(number(e.get("ts")))
            found.append({"session": sid, "id": e["id"], "description": clean(e.get("desc"), MAX_DESC),
                          "agent_type": clean(e.get("type"), 60), "finished_at": ts, "age_secs": max(at - ts, 0)})
    found.sort(key=lambda r: r["finished_at"])
    return found


def cmd_list(args):
    root = state_root()
    at = int(time.time())
    sessions = [args.session] if args.session else all_sessions(root)
    found = rows(root, sessions, at)
    if args.json:
        print(json.dumps(found, indent=2))
        return 0
    if not found:
        print("no finished agents are waiting to be closed")
        return 0
    print("finished agents not yet closed (oldest first); TaskStop reaches only the session that spawned them:")
    for r in found:
        print("  %-20s %7s ago  session %s  %s" % (r["id"], age(r["age_secs"]), r["session"].split("-")[0], r["description"]))
    return 0


def forget_session(root, sid, at):
    if ps.stat_file(root, REL, log_name(sid)) is None:
        return 0
    with ps.lock(root, REL, LOCK):
        count = len(open_entries(read_events(root, sid), at))
        ps.remove(root, REL, log_name(sid))
    return count


def cmd_clear(args):
    root = state_root()
    at = int(time.time())
    cleared = 0
    if args.id:
        target = plain(args.id, AGENT_RE)
        if target is None:
            sys.stderr.write("heimdall-finished-agents: not a plain agent id: %r\n" % args.id)
            return 2
        for sid in all_sessions(root):
            if close_entry(root, sid, target, "cleared") is not None:
                cleared += 1
    elif args.session:
        sid = plain(args.session, SESSION_RE)
        if sid is None:
            sys.stderr.write("heimdall-finished-agents: not a plain session id: %r\n" % args.session)
            return 2
        cleared = forget_session(root, sid, at)
    else:
        for sid in all_sessions(root):
            cleared += forget_session(root, sid, at)
    print("cleared %d %s" % (cleared, "entry" if cleared == 1 else "entries"))
    return 0


def build_parser():
    parser = argparse.ArgumentParser(prog="heimdall-finished-agents",
                                     description="Finished background agents that were never closed (TaskStop).")
    sub = parser.add_subparsers(dest="cmd")
    for verb in HOOKS:
        sub.add_parser(verb, help="hook verb: the payload on stdin")
    hook = sub.add_parser("prompt", help="hook verb (UserPromptSubmit): the payload on stdin unless --session is given")
    hook.add_argument("--session")
    lst = sub.add_parser("list", help="the agents still open, oldest first")
    lst.add_argument("--session")
    lst.add_argument("--json", action="store_true")
    clr = sub.add_parser("clear", help="forget entries (stops nothing)")
    scope = clr.add_mutually_exclusive_group(required=True)
    scope.add_argument("--all", action="store_true")
    scope.add_argument("--session")
    scope.add_argument("--id")
    return parser


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv) or ["list"]
    args = build_parser().parse_args(argv)
    if args.cmd == "prompt" or args.cmd in HOOKS:
        try:
            if args.cmd == "prompt":
                hook_prompt(args.session)
            else:
                HOOKS[args.cmd]()
        except Exception as exc:  # noqa: BLE001 - a hook must never break the session; the reason goes to stderr
            sys.stderr.write("heimdall-finished-agents: %s: %s\n" % (args.cmd, exc))
        return 0
    try:
        return cmd_list(args) if args.cmd == "list" else cmd_clear(args)
    except OSError as exc:
        sys.stderr.write("heimdall-finished-agents: %s: %s\n" % (args.cmd, exc))
        return 1


if __name__ == "__main__":
    sys.exit(main())
