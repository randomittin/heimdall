#!/usr/bin/env bash
# test/heimdall-ui-agents-visible.test.sh
#
# hmdapp docs/HANDOFF-TO-HEIMDALL-agents-visible.md: running agents must reach the phone.
#
# The report: the session's Agents tab and the Status tab's AGENTS tile read "0 running" while hmd
# sessions run background agents. Verified cause (section A, the handoff's section 1): the `agents`
# panel had more than one writer and the native publisher never noticed. `hmd ui panel set agents`
# succeeded (a hook script's last line), and the publisher skipped its next write because its rows equalled
# what it had written LAST (an in-memory copy), not what was on disk -- a foreign overwrite stood until the
# rows next changed (a minute boundary at best, for ever when `started`/`elapsed` were blank).
#
#   A  one owner: a foreign overwrite of agents / chat / hmd-question is repaired on the next tick; a sibling
#      poller's cosmetically different write is believed (no ping-pong between the two pollers every repo has:
#      `hmd ui` and the relay client)
#   B  `model` and `started_at` from `heimdall-agents list --json` fill the model / started / elapsed cells for
#      every agent, including one first seen long after it started (handoff recommendation 4)
#   C  the published panel is exactly what the app's Agents tab parses (hmdapp guards.ts parseTableData,
#      src/session/tabs/agents/parse.ts): six string cells a row, data keys exactly columns+rows, no `source`
#      key, a status in the closed set, running agents counted as running
#   D  `hmd ui panel set` refuses the ids the native publisher owns (recommendation 1); HMD_UI_COMPANION_PANELS=0
#      is the documented way to own them yourself
#   E  the statusline's count gate (recommendation 5): a cached 0 is not believed past a failed refresh
#      (`.agents-count-cache.fail`) nor for longer than IDLE_REPROBE_S
#   F  a running agent keeps the panel fresh (heartbeat); an idle one never churns it
#   G  no hook decides "finished" or writes a panel (recommendation 3)
#   H  the handoff's "Reproduce" section, automated, with the real binaries: `heimdall-agents list --json`,
#      `heimdall-agents count`, `hmd ui --print-state --repo`
#   L  the same against a live `hmd ui`: the poller publishes, the CLI is refused, a raw overwrite is repaired
#
# Hermetic: HOME/TMPDIR/HEIMDALL_HOME/TZ pinned to a temp dir, the harness layout bin/heimdall-agents reads is
# built under it (HMD_AGENT_TASKDIR / HMD_AGENT_PROJECTS_DIR), every server is reaped before the run ends and
# the run asserts nothing of it is left alive.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI="${HEIMDALL_UI_BIN:-$REPO/bin/heimdall-ui}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "heimdall-ui-agents-visible (running agents reach the phone)"

for tool in python3 curl jq git; do
  command -v "$tool" >/dev/null 2>&1 || { bad "required tool missing: $tool"; printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; }
done

TMPROOT="$(mktemp -d)"
export TMPDIR="$TMPROOT"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
export TZ=UTC
unset CLAUDE_CONFIG_DIR HMD_AGENT_PROJECTS_DIR HMD_AGENT_TASKDIR HMD_AGENT_CWD HMD_UI_COMPANION_PANELS
mkdir -p "$HOME/.claude/projects" "$HEIMDALL_HOME"

PIDS=()
stop_servers() {
  local p
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && wait "$p" 2>/dev/null; done
  PIDS=()
}
cleanup() { stop_servers; rm -rf "$TMPROOT"; }
trap cleanup EXIT

# The harness layout bin/heimdall-agents reads (test/heimdall-agents.test.sh): a task-dir `.output` symlinked to the
# subagent transcript, whose first record carries the spawn `timestamp` and whose sibling .meta.json carries
# agentType / description / model.
cat > "$TMPROOT/fx.py" <<'PYEOF'
import json
import os
import time

TOOL_USE = {"type": "assistant", "message": {"role": "assistant", "stop_reason": "tool_use",
                                              "content": [{"type": "tool_use", "name": "Bash", "id": "tu_1"}]}}
END_TURN = {"type": "assistant", "message": {"role": "assistant", "stop_reason": "end_turn",
                                              "content": [{"type": "text", "text": "working"}]}}


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(t))


def build(base, now, slug="slug"):
    """Two running agents: `aw1` awaits a tool result (state working), started 700s ago, transcript last written 400s
    ago (so a publisher that only guesses a start never has one), model sonnet; `al1` is live, started 90s ago,
    no model in its meta. Returns the env bin/heimdall-agents needs and the spec."""
    task = os.path.join(base, "claude-501", slug, "tsess", "tasks")
    subd = os.path.join(base, "projects", slug, "asess", "subagents")
    os.makedirs(task)
    os.makedirs(subd)
    open(os.path.join(base, "projects", slug, "asess.jsonl"), "w").close()
    spec = (("aw1", 400, 700, TOOL_USE, {"agentType": "hmd:coder", "description": "refactor parser", "model": "sonnet"}),
            ("al1", 20, 90, END_TURN, {"description": "scout"}))
    for aid, age, started_ago, last, meta in spec:
        j = os.path.join(subd, "agent-%s.jsonl" % aid)
        first = {"parentUuid": None, "isSidechain": True, "agentId": aid, "type": "user",
                 "message": {"role": "user", "content": "go"}, "timestamp": iso(now - started_ago)}
        with open(j, "w") as f:
            f.write(json.dumps(first) + "\n" + json.dumps(last) + "\n")
        os.utime(j, (now - age, now - age))
        with open(os.path.join(subd, "agent-%s.meta.json" % aid), "w") as f:
            json.dump(meta, f)
        os.symlink(j, os.path.join(task, aid + ".output"))
    # No HMD_AGENT_PROJECTS_DIR: it also redirects the session resolver (hmd_session_resolve.projects_dir), which would
    # hide the repo's own transcript from `hmd ui` and so stop it publishing at all. The task-dir symlinks are enough.
    env = {"HMD_AGENT_TASKDIR": task, "HMD_AGENT_REAPED_FILE": os.path.join(base, "reaped.json"),
           "HMD_AGENT_LIVE_SLUGS": slug}
    return env, spec
PYEOF

CHECKS="$TMPROOT/checks.py"
cat > "$CHECKS" <<'PYEOF'
import json
import os
import subprocess
import sys
import time

REPO, TMPROOT = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(REPO, "bin", "lib"))
sys.path.insert(0, TMPROOT)
import companion_ui_panels as P
import companion_ui_publish as CP
import fx

UI = os.path.join(REPO, "bin", "heimdall-ui")
AGENTS_BIN = os.path.join(REPO, "bin", "heimdall-agents")
COLS = list(CP.AGENT_COLUMNS)
results = []


def check(name, cond, detail=""):
    results.append((bool(cond), name, detail))


def guarded(label):
    def deco(fn):
        try:
            fn()
        except Exception as e:      # a section that raises is a FAIL with the reason, never a silent skip
            check("%s: the section ran to its end" % label, False, "%s: %s" % (e.__class__.__name__, e))
        return fn
    return deco


T0 = time.time() - 600
HMS = lambda ts: time.strftime("%H:%M:%S", time.localtime(ts))
iso = fx.iso
STRIPE = "sk" + "_li" + "ve_" + "Ab3dE6gH9jK2mN5pQ8sT1vW4"
_n = [0]


def new_repo(reply="ok"):
    _n[0] += 1
    root = os.path.realpath(os.path.join(TMPROOT, "repo%d" % _n[0]))
    os.makedirs(root)
    d = os.path.join(os.environ["HOME"], ".claude", "projects", CP.project_slug(root))
    os.makedirs(d)
    with open(os.path.join(d, "s.jsonl"), "w", encoding="utf-8") as f:
        f.write(json.dumps({"type": "user", "isSidechain": False, "timestamp": iso(T0), "entrypoint": "cli",
                            "message": {"role": "user", "content": "go"}, "origin": {"kind": "human"}}) + "\n")
        f.write(json.dumps({"type": "assistant", "isSidechain": False, "timestamp": iso(T0 + 5), "entrypoint": "cli",
                            "message": {"id": "m1", "role": "assistant", "stop_reason": "end_turn",
                                        "content": [{"type": "text", "text": reply}]}}) + "\n")
    return root


class Lister(object):
    def __init__(self, result):
        self.result, self.calls = result, 0

    def __call__(self):
        self.calls += 1
        return self.result


def AG(aid, state, age, desc=None, typ=None, name="-", **extra):
    d = {"id": aid, "age_secs": age, "state": state, "name": name, "agent_type": typ, "description": desc,
         "worktree_path": None, "worktree_branch": None}
    d.update(extra)
    return d


def fresh(agents, reply="ok"):
    root = new_repo(reply)
    lister = Lister(agents)
    pub = CP.CompanionPublisher(root, list_agents=lister)
    pub.tick(now=T0 + 100)
    return root, pub, lister


def served(root, now):
    return {p["id"]: p for p in P.read_panels(root, now=now, log=lambda m: None)}


def disk(root, pid="agents"):
    with open(P.panel_path(root, pid), encoding="utf-8") as f:
        return json.load(f)


def statuses(root):
    return [r[3] for r in disk(root)["data"]["rows"]]


def foreign(root, pid, ptype, data, title, at):
    """A writer that is not the publisher, bypassing the CLI (a hook script's last line before the CLI refused it)."""
    P.write_panel(root, pid, {"id": pid, "title": title, "type": ptype, "data": data, "refresh_s": 30, "updated_at": at})


def has_key(o, k):
    if isinstance(o, dict):
        return k in o or any(has_key(v, k) for v in o.values())
    if isinstance(o, list):
        return any(has_key(v, k) for v in o)
    return False


RUN2 = [AG("w1", "working", 5, "job one", "hmd:coder"), AG("w2", "working", 5, "job two", "hmd:coder")]


# ── A. one owner: a foreign overwrite is repaired, a sibling poller's write is believed ───────────────
@guarded("A")
def _():
    root, pub, _l = fresh(RUN2)
    check("A1. the native publisher lists both agents running", statuses(root) == ["running", "running"])
    hook = [["job one", "hmd:coder", "", "finished", "12:00:00", "11s"], ["job two", "hmd:coder", "", "finished", "12:00:00", "20s"]]
    foreign(root, "agents", "table", {"columns": COLS, "rows": hook}, "Agents", T0 + 101)
    changed = pub.tick(now=T0 + 105)
    check("A2. the handoff's clobber (a script marks both running agents finished) is repaired on the very next tick, "
          "not left standing until the rows next change", changed is True and statuses(root) == ["running", "running"],
          "changed=%r statuses=%r" % (changed, statuses(root)))
    changed = pub.tick(now=T0 + 140)
    check("A2b. ...and once repaired the panel is quiet again (no rewrite on an unchanged list)", changed is False)

    root, pub, _l = fresh(RUN2)
    path = P.panel_path(root, "agents")
    sib = [[r[0], r[1], "sonnet", r[3], "09:00:00", "7m"] for r in disk(root)["data"]["rows"]]
    foreign(root, "agents", "table", {"columns": COLS, "rows": sib}, "Agents", T0 + 101)
    before = open(path, "rb").read()
    changed = pub.tick(now=T0 + 105)
    check("A3. a write that lists the same agents with the same statuses and different cosmetics (a sibling poller: "
          "`hmd ui` and the relay client each run one) is believed -- no rewrite, no ping-pong",
          changed is False and open(path, "rb").read() == before)

    root, pub, _l = fresh(RUN2)
    path = P.panel_path(root, "agents")
    before = open(path, "rb").read()
    os.utime(path, ns=(time.time_ns() + 5 * 10**9,) * 2)
    changed = pub.tick(now=T0 + 105)
    check("A4. a touched (mtime-only) panel file is not rewritten", changed is False and open(path, "rb").read() == before)

    root = new_repo("Which one?")
    pub = CP.CompanionPublisher(root)
    pub.tick(now=T0 + 100)
    orig_chat, orig_q = disk(root, "chat")["data"], disk(root, "hmd-question")["data"]
    foreign(root, "chat", "log-tail", {"lines": ["12:00 you nope"]}, "Chat", T0 + 101)
    foreign(root, "hmd-question", "markdown", {"text": "bogus?"}, "hmd asks", T0 + 101)
    changed = pub.tick(now=T0 + 105)
    check("A5. chat and hmd-question are repaired the same way (one writer per file)",
          changed is True and disk(root, "chat")["data"] == orig_chat and disk(root, "hmd-question")["data"] == orig_q)

    root = new_repo()
    started = T0 + 100 - 65
    run = [AG("w1", "working", 5, "job one", "hmd:coder", started_at=started)]
    pa, pb = CP.CompanionPublisher(root, list_agents=Lister(run)), CP.CompanionPublisher(root, list_agents=Lister(run))
    writes, real = [], P.write_panel

    def counting(r, pid, obj):
        if pid == "agents":
            writes.append(obj["updated_at"])
        return real(r, pid, obj)

    P.write_panel = counting
    try:
        for pub, dt in ((pa, 100), (pb, 103), (pa, 106), (pb, 109), (pa, 112), (pb, 115), (pa, 118), (pb, 121)):
            pub.tick(now=T0 + dt)
    finally:
        P.write_panel = real
    check("A6. two publishers on one repo settle: at most one write each over eight ticks inside one minute",
          len(writes) <= 2, str(writes))


# ── B. model + started_at fill the cells ──────────────────────────────────────────────────────────────
@guarded("B")
def _():
    now = T0 + 100
    rows = CP.agent_rows([
        AG("w1", "working", 400, "refactor parser", "hmd:coder", model="sonnet", started_at=now - 700),
        AG("d1", "done", 30, "write docs", "hmd:docs-writer", model="opus", started_at=now - 200),
        AG("h1", "hung", 4000, "stuck build", "hmd:coder", model="haiku", started_at=now - 5000)], now, {})
    want = [["refactor parser", "hmd:coder", "sonnet", "running", HMS(now - 700), "11m"],
            ["stuck build", "hmd:coder", "haiku", "unknown", HMS(now - 5000), "1h23m"],
            ["write docs", "hmd:docs-writer", "opus", "finished", HMS(now - 200), "2m"]]
    check("B1. model comes through and every agent has its real start: a running agent first seen stale (age 400s), "
          "a hung one, a finished one (elapsed = start -> finish)", rows == want, repr(rows))
    rows = CP.agent_rows([AG("w1", "working", 5, "j", "hmd:coder", started_at=now - 600)], now, {})
    check("B2. the recorded spawn time beats the first-sighting guess (fresh at age 5s, started 10 minutes ago)",
          rows[0][4] == HMS(now - 600) and rows[0][5] == "10m", repr(rows))
    for bad in (float("nan"), True, "12345", -5, 0, now + 10000, [1], None):
        rows = CP.agent_rows([AG("w1", "working", 5, "j", "hmd:coder", started_at=bad)], now, {})
        check("B3. an unusable started_at (%r) falls back to the first-sighting estimate" % (bad,),
              len(rows) == 1 and rows[0][4] == HMS(now - 5) and rows[0][5] == "<1m", repr(rows))
    rows = CP.agent_rows([AG("a", "working", 5, "x", None, model={"a": 1}), AG("b", "working", 5, "y", None, model=12),
                          AG("c", "working", 5, "z", None, model=STRIPE)], now, {})
    check("B4. a model that is not a string is no cell; a secret-shaped one is [redacted] (the row stays)",
          [r[2] for r in rows] == ["", "", "[redacted]"], repr(rows))


# ── C. the panel is what the app's Agents tab parses ──────────────────────────────────────────────────
def parse_agents_panel(panel):
    """hmdapp src/session/tabs/agents/parse.ts, line for line."""
    cols = panel["data"]["columns"]
    idx = lambda n: cols.index(n) if n in cols else -1
    out = []
    for row in panel["data"]["rows"]:
        def cell(i, row=row):
            return "" if i == -1 else ("" if row[i] is None else str(row[i]))
        role, status = cell(idx("role")), cell(idx("status"))
        if role == "idle" or not status or (not role and status not in ("running", "pending")):
            continue
        out.append({"agent": cell(idx("agent")), "role": role or "agent", "model": cell(idx("model")),
                    "status": status if status in ("running", "pending", "finished", "unknown") else "unknown",
                    "started": cell(idx("started")), "elapsed": cell(idx("elapsed"))})
    rank = {"running": 0, "pending": 1, "finished": 2, "unknown": 3}
    return sorted(out, key=lambda a: rank[a["status"]])


@guarded("C")
def _():
    root, _p, _l = fresh([AG("w1", "working", 400, "refactor parser", "hmd:coder", model="sonnet", started_at=T0 + 100 - 700),
                          AG("l1", "live", 20, None, None, "scout", started_at=T0 + 100 - 90),
                          AG("d1", "done", 30, "write docs", "hmd:docs-writer", model="opus", started_at=T0 + 100 - 200),
                          AG("h1", "hung", 4000, "stuck", "hmd:coder")])
    panel = served(root, T0 + 100)["agents"]
    rows = panel["data"]["rows"]
    check("C1. envelope: table 'Agents', top-level keys exactly the contract's, data keys exactly [columns, rows], the six "
          "columns", panel["type"] == "table" and panel["title"] == "Agents"
          and set(panel) == {"id", "title", "type", "data", "refresh_s", "updated_at", "stale"}
          and list(panel["data"]) == ["columns", "rows"] and panel["data"]["columns"] == COLS, str(panel)[:300])
    check("C2. the app's guard: every row exactly len(columns) cells, each a string; <= 200 rows; no `source` key anywhere; "
          "every status in the closed set", all(len(r) == len(COLS) and all(isinstance(c, str) for c in r) for r in rows)
          and len(rows) <= 200 and not has_key(panel, "source")
          and all(r[3] in ("running", "pending", "finished", "unknown") for r in rows), repr(rows))
    app = parse_agents_panel(panel)
    check("C3. the app's Agents tab reads 2 running (an implicit agent with no role is shown as `agent`), with model, "
          "start and elapsed on the cards", [a["status"] for a in app] == ["running", "running", "finished", "unknown"]
          and app[0]["role"] == "agent" and app[0]["agent"] == "scout" and app[0]["started"] == HMS(T0 + 10)
          and app[1]["model"] == "sonnet" and app[1]["started"] == HMS(T0 + 100 - 700) and app[1]["elapsed"] == "11m"
          and app[2]["model"] == "opus", repr(app))


# ── D. `hmd ui panel set` refuses the ids the native publisher owns ───────────────────────────────────
@guarded("D")
def _():
    root = os.path.realpath(os.path.join(TMPROOT, "cli"))
    os.makedirs(root)
    env = dict(os.environ, HEIMDALL_WATCH_ROOT=root)
    env.pop("HMD_UI_COMPANION_PANELS", None)

    def pset(pid, ptype, data, e):
        return subprocess.run([UI, "panel", "set", pid, "--type", ptype, "--title", "t", "--data-json", "-", "--refresh-s", "30"],
                              input=json.dumps(data), text=True, env=e, capture_output=True, timeout=60)

    for pid, ptype, data in (("agents", "table", {"columns": COLS, "rows": []}), ("chat", "log-tail", {"lines": ["x"]}),
                             ("hmd-question", "markdown", {"text": "x"})):
        p = pset(pid, ptype, data, env)
        check("D1. `hmd ui panel set %s` is refused (exit 2), names the owner and writes nothing" % pid,
              p.returncode == 2 and "published by hmd itself" in p.stderr and not os.path.exists(P.panel_path(root, pid)),
              "rc=%d %s" % (p.returncode, p.stderr.strip()[:160]))
    p = pset("agents", "table", {"columns": COLS, "rows": []}, dict(env, HMD_UI_COMPANION_PANELS="0"))
    check("D2. with the native publishers off (HMD_UI_COMPANION_PANELS=0) nothing owns `agents`: the set goes through",
          p.returncode == 0 and os.path.exists(P.panel_path(root, "agents")), "rc=%d %s" % (p.returncode, p.stderr.strip()[:160]))
    p = pset("my-job", "number", {"value": 1}, env)
    check("D3. every other id is unaffected", p.returncode == 0 and os.path.exists(P.panel_path(root, "my-job")),
          "rc=%d %s" % (p.returncode, p.stderr.strip()[:160]))


# ── E. the statusline's count gate ────────────────────────────────────────────────────────────────────
def cached_repo(count, cache_age, fail_age=None):
    root = new_repo()
    c = os.path.join(root, ".heimdall", ".agents-count-cache")
    os.makedirs(os.path.dirname(c))
    open(c, "w").write("%s\n" % count)
    os.utime(c, (T0 + 100 - cache_age,) * 2)
    if fail_age is not None:
        open(c + ".fail", "w").write("143\n")
        os.utime(c + ".fail", (T0 + 100 - fail_age,) * 2)
    return root, c


@guarded("E")
def _():
    run = [AG("w1", "working", 5, "x", "hmd:coder")]
    root, _c = cached_repo(0, cache_age=1, fail_age=0)
    lister = Lister(run)
    CP.CompanionPublisher(root, list_agents=lister).tick(now=T0 + 100)
    check("E1. a cached 0 that a LATER failed refresh (.agents-count-cache.fail, exit 143) outdates is not believed: the "
          "publisher probes and the running agent is on the panel",
          lister.calls == 1 and statuses(root) == ["running"], "calls=%d" % lister.calls)
    root, _c = cached_repo(0, cache_age=1, fail_age=10)
    lister = Lister(run)
    CP.CompanionPublisher(root, list_agents=lister).tick(now=T0 + 100)
    check("E2. a fresh cached 0 with only an OLDER failure marker still means no probe (the gate saves its cpu)",
          lister.calls == 0 and disk(root)["data"]["rows"] == [["—", "idle", "", "", "", ""]])
    root, c = cached_repo(0, cache_age=1)
    lister = Lister(run)
    pub = CP.CompanionPublisher(root, list_agents=lister)
    pub.tick(now=T0 + 100)
    c0 = lister.calls
    later = T0 + 100 + CP.IDLE_REPROBE_S + 1
    os.utime(c, (later - 1, later - 1))
    pub.tick(now=later)
    check("E3. a cached 0 that stays fresh (a wrong 0 the statusline keeps re-writing) is believed for at most "
          "IDLE_REPROBE_S, then the publisher looks for itself", c0 == 0 and lister.calls == 1
          and statuses(root) == ["running"], "calls %d -> %d" % (c0, lister.calls))


# ── F. heartbeat: a running agent keeps the panel fresh, an idle repo never churns it ─────────────────
@guarded("F")
def _():
    root, pub, _l = fresh([AG("w1", "working", 400, "job", "hmd:coder")])
    c_quiet = pub.tick(now=T0 + 150)
    beat = T0 + 100 + CP.AGENTS_HEARTBEAT_S + 5
    c_beat = pub.tick(now=beat)
    check("F1. a running agent whose row cannot change (no known start) still refreshes the panel once a heartbeat, so "
          "it never greys out as stale while the agent runs", c_quiet is False and c_beat is True
          and disk(root)["updated_at"] == beat and served(root, beat + 60)["agents"]["stale"] is False,
          "quiet=%r beat=%r updated_at=%r" % (c_quiet, c_beat, disk(root)["updated_at"] - T0))
    root, pub, _l = fresh([])
    check("F2. the idle row never heartbeats (no frame per minute for an idle repo)",
          pub.tick(now=T0 + 400) is False and disk(root)["updated_at"] == T0 + 100)


# ── G. no hook decides "finished" or writes a panel ───────────────────────────────────────────────────
@guarded("G")
def _():
    hooks = json.load(open(os.path.join(REPO, "hooks", "hooks.json"), encoding="utf-8"))
    cmds = []

    def walk(o):
        if isinstance(o, dict):
            for k, v in o.items():
                if k == "command" and isinstance(v, str):
                    cmds.append(v)
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    walk(hooks)
    check("G1. no hook in hooks/hooks.json publishes a panel", cmds and not any("panel set" in c or "ui panel" in c or "agents-panel" in c for c in cmds))
    check("G2. no SubagentStart hook: the spawn time is `started_at` from the transcript, not a hook's guess",
          not has_key(hooks, "SubagentStart"))


# ── H. the handoff's "Reproduce", with the real binaries ──────────────────────────────────────────────
@guarded("H")
def _():
    now = time.time()
    envfx, _spec = fx.build(os.path.join(TMPROOT, "fx1"), now)
    env = dict(os.environ, **envfx)
    run = lambda *a: subprocess.run(list(a), env=env, capture_output=True, text=True, timeout=180)
    lst = json.loads(run(AGENTS_BIN, "list", "--json").stdout)
    by = {a["id"]: a for a in lst}
    check("H1. `heimdall-agents list --json` carries model and started_at (the spawn timestamp of the transcript's first "
          "record, epoch seconds), null when the harness recorded none",
          set(by) == {"aw1", "al1"} and by["aw1"]["model"] == "sonnet" and by["al1"]["model"] is None
          and isinstance(by["aw1"]["started_at"], int) and abs(by["aw1"]["started_at"] - (now - 700)) <= 2
          and abs(by["al1"]["started_at"] - (now - 90)) <= 2, json.dumps(lst)[:400])
    cnt = run(AGENTS_BIN, "count").stdout.strip()
    check("H2. `heimdall-agents count` says 2", cnt == "2", cnt)

    # A transcript whose first line is not JSON, and one with no sidecar at all: listed all the same, started_at null.
    base2 = os.path.join(TMPROOT, "fx2")
    task2, subd2 = os.path.join(base2, "claude-501", "slug", "tsess", "tasks"), os.path.join(base2, "projects", "slug", "asess", "subagents")
    os.makedirs(task2)
    os.makedirs(subd2)
    for aid, first, meta in (("ab1", "this is not json", {"agentType": "hmd:coder", "description": "garbled", "model": "haiku"}),
                             ("ab2", json.dumps({"type": "user", "message": {"role": "user", "content": "go"}}), None)):
        j = os.path.join(subd2, "agent-%s.jsonl" % aid)
        with open(j, "w") as f:
            f.write(first + "\n" + json.dumps(fx.END_TURN) + "\n")
        os.utime(j, (now - 20, now - 20))
        if meta is not None:
            json.dump(meta, open(os.path.join(subd2, "agent-%s.meta.json" % aid), "w"))
        os.symlink(j, os.path.join(task2, aid + ".output"))
    env2 = dict(os.environ, HMD_AGENT_TASKDIR=task2, HMD_AGENT_REAPED_FILE=os.path.join(base2, "reaped.json"), HMD_AGENT_LIVE_SLUGS="slug")
    by2 = {a["id"]: a for a in json.loads(subprocess.run([AGENTS_BIN, "list", "--json"], env=env2, capture_output=True, text=True, timeout=180).stdout)}
    check("H1b. an agent whose transcript opens with a non-JSON line keeps its sidecar's fields (started_at null); one with no "
          "sidecar and no timestamp is listed with model and started_at null -- no row is dropped for a missing fact",
          set(by2) == {"ab1", "ab2"} and by2["ab1"]["started_at"] is None and by2["ab1"]["model"] == "haiku"
          and by2["ab1"]["description"] == "garbled" and by2["ab1"]["agent_type"] == "hmd:coder"
          and by2["ab2"]["started_at"] is None and by2["ab2"]["model"] is None, json.dumps(by2)[:400])

    root = new_repo()
    subprocess.run(["git", "init", "-q", root], capture_output=True, timeout=60)
    pub = CP.CompanionPublisher(root, list_agents=lambda: json.loads(run(AGENTS_BIN, "list", "--json").stdout))
    pub.tick(now=time.time())
    p = run(UI, "--print-state", "--repo", root)
    try:
        panels = {x["id"]: x for x in json.loads(p.stdout)["panels"]}
    except ValueError:
        panels = {}
    ag = panels.get("agents")
    rows = ag["data"]["rows"] if ag else []
    check("H3. `hmd ui --print-state` serves the agents panel: 2 rows, both running (scout, then refactor parser with its "
          "model, start and elapsed), fresh", ag is not None and not ag["stale"] and [r[3] for r in rows] == ["running", "running"]
          and rows[0][:3] == ["scout", "", ""] and rows[1][:3] == ["refactor parser", "hmd:coder", "sonnet"]
          and rows[1][4] == HMS(now - 700) and rows[1][5] in ("11m", "12m") and rows[0][4] == HMS(now - 90),
          repr(rows) + " " + p.stderr.strip()[:200])


failed = [r for r in results if not r[0]]
for okv, name, detail in results:
    print(("OK   " if okv else "FAIL ") + name + ("" if okv else "  [%s]" % detail))
sys.exit(1 if failed else 0)
PYEOF

CHECKS_OUT="$TMPROOT/checks.out"
python3 "$CHECKS" "$REPO" "$TMPROOT" >"$CHECKS_OUT" 2>"$TMPROOT/checks.err"
checks_rc=$?
while IFS= read -r line; do
  case "$line" in
    "OK   "*)   ok "${line#OK   }" ;;
    "FAIL "*)   bad "${line#FAIL }" ;;
  esac
done < "$CHECKS_OUT"
if [ ! -s "$CHECKS_OUT" ]; then
  bad "unit checks produced no output (rc=$checks_rc):"
  sed 's/^/       | /' "$TMPROOT/checks.err" | head -20
fi

# ── L. a live `hmd ui`: the poller publishes, the CLI is refused, a raw overwrite is repaired ──────────
if [ ! -x "$UI" ]; then
  bad "L0. bin/heimdall-ui is not executable ($UI)"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

plant_transcript() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, os, re, sys, time
root, sid, prompt = os.path.realpath(sys.argv[1]), sys.argv[2], sys.argv[3]
d = os.path.join(os.environ["HOME"], ".claude", "projects", re.sub(r"[^A-Za-z0-9]", "-", root))
os.makedirs(d, exist_ok=True)
ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - 60))
with open(os.path.join(d, sid + ".jsonl"), "a", encoding="utf-8") as f:
    f.write(json.dumps({"isSidechain": False, "timestamp": ts, "entrypoint": "cli", "type": "user",
                        "message": {"role": "user", "content": prompt}, "origin": {"kind": "human"}}) + "\n")
PYEOF
}

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

wait_for() {
  local file="$1" re="$2" secs="${3:-10}" i=0 max
  max=$(( secs * 5 ))
  while [ "$i" -lt "$max" ]; do
    grep -Eq "$re" "$file" 2>/dev/null && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

start_server() {
  local fix="$1" prefix="$2"; shift 2
  S_PORT="$(free_port)"
  ( cd "$fix" && HEIMDALL_WATCH_ROOT="$fix" exec "$UI" --repo "$fix" --port "$S_PORT" --no-open "$@" ) \
    >"$prefix.out" 2>"$prefix.err" &
  PIDS+=("$!")
  wait_for "$prefix.out" "^http://127\.0\.0\.1:$S_PORT/\?(t|token)=[A-Za-z0-9_-]+\$" 15 || return 1
  local url q
  url="$(grep -E "^http://127\.0\.0\.1:$S_PORT/" "$prefix.out" | head -1)"
  q="${url#*\?}"
  S_TOKEN="${q#*=}"
  return 0
}

state_until() {
  local port="$1" token="$2" expr="$3" secs="${4:-10}" i=0 max
  max=$(( secs * 5 ))
  LIVE_STATE="$TMPROOT/live-state.$port.json"
  while [ "$i" -lt "$max" ]; do
    curl -s -o "$LIVE_STATE" "http://127.0.0.1:$port/api/state?token=$token" 2>/dev/null
    jq -e "$expr" "$LIVE_STATE" >/dev/null 2>&1 && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

AGLIVE="$TMPROOT/ag-live-repo"
mkdir -p "$AGLIVE/.heimdall"
( cd "$AGLIVE" && git init -q . ) >/dev/null 2>&1
plant_transcript "$AGLIVE" ag-sess "spawn agents"
FXJSON="$(python3 - "$TMPROOT" "$TMPROOT/livefx" <<'PYEOF'
import json, sys, time
sys.path.insert(0, sys.argv[1])
import fx
env, _spec = fx.build(sys.argv[2], time.time())
print(json.dumps(env))
PYEOF
)"
export HMD_AGENT_TASKDIR="$(jq -r .HMD_AGENT_TASKDIR <<<"$FXJSON")" HMD_AGENT_REAPED_FILE="$(jq -r .HMD_AGENT_REAPED_FILE <<<"$FXJSON")"
export HMD_AGENT_LIVE_SLUGS="$(jq -r .HMD_AGENT_LIVE_SLUGS <<<"$FXJSON")"

RUNNING_EXPR='.panels[] | select(.id=="agents") | ((.data.rows|length)==2) and ([.data.rows[][3]]==["running","running"])
  and (.data.rows[1][2]=="sonnet") and (.data.rows[1][4]|test("^[0-9]{2}:[0-9]{2}:[0-9]{2}$")) and (.data.rows[1][5]|test("^[0-9]+m$"))'
if start_server "$AGLIVE" "$TMPROOT/aglive"; then
  if state_until "$S_PORT" "$S_TOKEN" "$RUNNING_EXPR" 25; then
    ok "L1. the poller publishes both running agents to /api/state (model, start and elapsed filled)"
  else
    bad "L1. agents panel in /api/state: $(jq -c '[.panels[]|select(.id=="agents")]' "$LIVE_STATE" 2>/dev/null) err: $(head -c 300 "$TMPROOT/aglive.err")"
  fi
  APATH="$AGLIVE/.heimdall/ui/panels/agents.json"
  before="$(cksum < "$APATH" 2>/dev/null)"
  out="$(cd "$AGLIVE" && HEIMDALL_WATCH_ROOT="$AGLIVE" "$UI" panel set agents --type table --title Agents --refresh-s 30 --data-json - 2>&1 \
         <<<'{"columns":["agent","role","model","status","started","elapsed"],"rows":[["scout","","","finished","","1m"]]}')"
  rc=$?
  after="$(cksum < "$APATH" 2>/dev/null)"
  if [ "$rc" -eq 2 ] && [ -n "$before" ] && [ "$before" = "$after" ] && printf '%s' "$out" | grep -q 'published by hmd itself'; then
    ok "L2. a second writer through the CLI is refused and the published panel is untouched"
  else
    bad "L2. panel set agents: rc=$rc before=[$before] after=[$after] out: $out"
  fi
  OV_AT="$(python3 - "$REPO" "$AGLIVE" <<'PYEOF'
import sys, time
sys.path.insert(0, sys.argv[1] + "/bin/lib")
import companion_ui_panels as P
cols = ["agent", "role", "model", "status", "started", "elapsed"]
rows = [["scout", "", "", "finished", "", "11s"], ["refactor parser", "hmd:coder", "", "finished", "", "20s"]]
at = time.time()
P.write_panel(sys.argv[2], "agents", {"id": "agents", "title": "Agents", "type": "table", "data": {"columns": cols, "rows": rows},
                                       "refresh_s": 30, "updated_at": at})
print(at)
PYEOF
)"
  # The FILE must be rewritten (updated_at past the overwrite's own) and say running again: /api/state alone could still be
  # serving the frame from before the overwrite, which would pass without any repair.
  i=0; repaired=""
  while [ "$i" -lt 125 ]; do
    if jq -e --argjson t "$OV_AT" '.updated_at > $t and ([.data.rows[][3]]==["running","running"])' "$APATH" >/dev/null 2>&1; then repaired=1; break; fi
    sleep 0.2; i=$((i + 1))
  done
  if [ -n "$repaired" ] && state_until "$S_PORT" "$S_TOKEN" "$RUNNING_EXPR" 10; then
    ok "L3. a raw overwrite that marks the running agents finished (a writer that bypasses the CLI) is repaired by the poller"
  else
    bad "L3. overwrite stood (repaired=[$repaired]): $(jq -c '.data.rows' "$APATH" 2>/dev/null) err: $(head -c 300 "$TMPROOT/aglive.err")"
  fi
else
  bad "L1. hmd ui did not come up: $(head -c 400 "$TMPROOT/aglive.err")"
fi

stop_servers
left="$(pgrep -f "$TMPROOT" 2>/dev/null | tr '\n' ' ')"
if [ -z "$left" ]; then
  ok "L4. the run leaves no hmd-ui / relay-client process behind"
else
  bad "L4. processes still alive after the run: $left"
  # shellcheck disable=SC2086
  kill $left 2>/dev/null
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
