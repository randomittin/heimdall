#!/usr/bin/env python3
"""inbox-latency-probe.py -- phone -> model delivery latency, measured on a hermetic harness.

WHAT IT MEASURES. A phone message is "delivered" when a hook pops it out of
<repo>/.heimdall/ui/inbox.jsonl and hands it to Claude Code. The doc
(hmdapp docs/HANDOFF-TO-HEIMDALL-zero-lag-sync.md, ask 2) defines the number as the
receipt's delivered_at minus the message's ts, and this probe reports exactly that
(receipt_s), plus the moment the hook process that popped it exited (seen_s: the
output has been printed by then, so that is when Claude Code can read it).

HOW. Nothing is stubbed: the message is appended through the REAL
bin/lib/companion_ui_inbox.append (the function the relay client and `hmd ui` call),
and what pops it is the REAL command string out of <root>/hooks/hooks.json, run the
way Claude Code runs a hook (bash -c, CLAUDE_PLUGIN_ROOT / CLAUDE_PROJECT_DIR set, the
event payload on stdin). Every trial gets its own scratch repo; nothing outside
$TMPDIR is touched and no process that is not started here is signalled.

  --scenario idle-hold      the session is idle at a Stop hook with a companion
                            connected, so the Stop long-poll is holding; the message
                            lands a fixed offset into the hold.
  --scenario tool-boundary  the session is MID-TURN. A scripted turn fires PreToolUse
                            and PostToolUse every --gap seconds, then ends with a Stop
                            hook that does not hold. The message lands at a fixed
                            offset into the turn. A tree whose hooks.json wires no
                            tool-boundary command (the tree before this feature) gets
                            no events, so the message waits for the Stop: that is the
                            "before" number.

Offsets are evenly spaced across their range rather than random: the result is the
same distribution, and a regression cannot hide behind a lucky draw.

  inbox-latency-probe.py --root DIR --scenario S [--library module|inline]
        [--watch auto|poll] [--trials N] [--json]

Exit 0 when every trial was delivered, 1 otherwise. Stdlib only.
"""
import argparse
import concurrent.futures
import contextlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import types

LIVE_PID = os.getpid()   # connect.json names this process: a live "companion"
MARKER_WAIT_S = 20.0     # how long a hold may take to publish inbox-waiting
HOLD_BUDGET_S = 30       # HMD_INBOX_WAIT_S for the idle hold: only bounds a broken run
KILL_AFTER_S = 45        # a trial still running this long is a hang, not a slow hook


def percentile(values, q):
    s = sorted(values)
    pos = (len(s) - 1) * q
    lo = int(pos)
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (pos - lo)


def summarize(values):
    if not values:
        return {"p50": None, "p95": None, "max": None, "mean": None}
    return {"p50": round(percentile(values, 0.50), 3), "p95": round(percentile(values, 0.95), 3),
            "max": round(max(values), 3), "mean": round(sum(values) / len(values), 3)}


def spread(lo, hi, n):
    if n == 1:
        return [lo]
    return [lo + (hi - lo) * i / (n - 1) for i in range(n)]


def load_inbox_module(root):
    path = os.path.join(root, "bin", "lib", "companion_ui_inbox.py")
    spec = importlib.util.spec_from_file_location("probe_companion_ui_inbox", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def wired_command(hooks, event, needle):
    for group in hooks.get(event, []):
        for hook in group.get("hooks", []):
            if needle in hook.get("command", ""):
                return hook["command"]
    return None


def make_repo(root, library):
    repo = tempfile.mkdtemp(prefix="inbox-probe-")
    os.makedirs(os.path.join(repo, ".heimdall", "ui"))
    os.makedirs(os.path.join(repo, ".heimdall", "app"))
    with open(os.path.join(repo, ".heimdall", "app", "connect.json"), "w", encoding="utf-8") as f:
        json.dump({"mode": "relay", "pid_ui": LIVE_PID, "pid_client": LIVE_PID,
                   "port": 1, "relay": "x", "started_at": "t"}, f)
    if library == "module":
        os.makedirs(os.path.join(repo, "bin", "lib"))
        shutil.copy(os.path.join(root, "bin", "lib", "companion_ui_inbox.py"),
                    os.path.join(repo, "bin", "lib", "companion_ui_inbox.py"))
    return repo


def hook_env(root, repo, home, extra):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("HMD_", "CLAUDE_", "HEIMDALL_"))}
    env.update(CLAUDE_PLUGIN_ROOT=root, CLAUDE_PROJECT_DIR=repo, HEIMDALL_HOME=home,
               CLAUDE_CODE_ENTRYPOINT="cli", HMD_INBOX_TTY="off")
    env.update(extra)
    return env


def payload(repo, event, **fields):
    body = {"session_id": "probe", "transcript_path": "", "cwd": repo, "hook_event_name": event}
    body.update(fields)
    return json.dumps(body).encode("utf-8")


def start_hook(cmd, env, repo, stdin_bytes):
    proc = subprocess.Popen(["bash", "-c", cmd], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, env=env, cwd=repo)
    try:
        proc.stdin.write(stdin_bytes)
        proc.stdin.close()
    except BrokenPipeError:
        # The empty-inbox fast path is finished before it reads stdin. Claude Code's own write
        # tolerates that too (it beats a shell's exec by milliseconds; this harness, running
        # trials on threads, sometimes does not).
        with contextlib.suppress(OSError):
            proc.stdin.close()
    proc.stdin = None   # already closed: communicate() would otherwise try to flush it again
    return proc


def finish_hook(proc):
    try:
        out, _ = proc.communicate(timeout=KILL_AFTER_S)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, _ = proc.communicate()
        return out, False
    return out, True


def delivered_at(repo, msg_id):
    path = os.path.join(repo, ".heimdall", "ui", "inbox-delivered.jsonl")
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("id") == msg_id:
                    return rec.get("delivered_at")
    except OSError:
        return None
    return None


def result(rec, seen_at, repo):
    got = delivered_at(repo, rec["id"])
    if got is None or seen_at is None:
        return None
    return {"receipt_s": got - rec["ts"], "seen_s": seen_at - rec["ts"]}


def trial_idle_hold(ctx, k, offset):
    repo = make_repo(ctx.root, ctx.library)
    try:
        env = hook_env(ctx.root, repo, ctx.home, dict(ctx.watch_env, HMD_INBOX_WAIT_S=str(HOLD_BUDGET_S)))
        proc = start_hook(ctx.stop_cmd, env, repo, payload(
            repo, "Stop", stop_hook_active=False, last_assistant_message="Done."))
        marker = os.path.join(repo, ".heimdall", "ui", "inbox-waiting")
        deadline = time.time() + MARKER_WAIT_S
        while not os.path.exists(marker) and time.time() < deadline and proc.poll() is None:
            time.sleep(0.01)
        time.sleep(offset)
        rec = ctx.inbox.append(repo, "probe idle-hold %d" % k)
        out, finished = finish_hook(proc)
        seen_at = time.time()
        if not finished or b'"decision"' not in out:
            return None
        return result(rec, seen_at, repo)
    finally:
        shutil.rmtree(repo, ignore_errors=True)


def trial_tool_boundary(ctx, k, offset):
    repo = make_repo(ctx.root, ctx.library)
    try:
        env = hook_env(ctx.root, repo, ctx.home, ctx.watch_env)
        stop_env = hook_env(ctx.root, repo, ctx.home, dict(ctx.watch_env, HMD_INBOX_WAIT_S="0"))
        box = {"rec": None, "seen": None}

        def inject():
            time.sleep(offset)
            box["rec"] = ctx.inbox.append(repo, "probe tool-boundary %d" % k)

        injector = threading.Thread(target=inject)
        t0 = time.monotonic()
        injector.start()

        def fire(event, cmd, run_env, **fields):
            if cmd is None:
                return
            out, _ = finish_hook(start_hook(cmd, run_env, repo, payload(repo, event, **fields)))
            if out.strip() and box["seen"] is None and box["rec"] is not None:
                box["seen"] = time.time()

        def sleep_until(t):
            rest = t0 + t - time.monotonic()
            if rest > 0:
                time.sleep(rest)

        t = 0.0
        while t < ctx.turn_s:
            sleep_until(t)
            fire("PreToolUse", ctx.pre_cmd, env, tool_name="Bash", tool_input={"command": "true"})
            t += ctx.tool_s
            sleep_until(t)
            fire("PostToolUse", ctx.post_cmd, env, tool_name="Bash", tool_input={"command": "true"},
                 tool_response={"stdout": "", "stderr": ""})
            t += max(ctx.gap - ctx.tool_s, 0.01)
        sleep_until(ctx.turn_s)
        fire("Stop", ctx.stop_cmd, stop_env, stop_hook_active=False, last_assistant_message="Done.")
        injector.join()
        if box["rec"] is None:
            return None
        return result(box["rec"], box["seen"], repo)
    finally:
        shutil.rmtree(repo, ignore_errors=True)


def build_ctx(args):
    root = os.path.abspath(args.root)
    with open(os.path.join(root, "hooks", "hooks.json"), "r", encoding="utf-8") as f:
        hooks = json.load(f)["hooks"]
    return types.SimpleNamespace(
        root=root, library=args.library,
        turn_s=args.turn_s, tool_s=args.tool_s, gap=args.gap,
        watch_env={"HMD_INBOX_WATCH": "poll"} if args.watch == "poll" else {},
        stop_cmd=wired_command(hooks, "Stop", "inbox-deliver-stop"),
        pre_cmd=wired_command(hooks, "PreToolUse", "heimdall-inbox-deliver"),
        post_cmd=wired_command(hooks, "PostToolUse", "heimdall-inbox-deliver"),
        inbox=load_inbox_module(root),
        home=tempfile.mkdtemp(prefix="inbox-probe-home-"))


def main(argv):
    ap = argparse.ArgumentParser(description="phone -> model delivery latency on a hermetic harness")
    ap.add_argument("--root", required=True, help="plugin tree under test (has bin/ and hooks/)")
    ap.add_argument("--scenario", required=True, choices=("idle-hold", "tool-boundary"))
    ap.add_argument("--library", choices=("module", "inline"), default="module",
                    help="module: the scratch repo ships bin/lib/companion_ui_inbox.py; inline: it does not")
    ap.add_argument("--watch", choices=("auto", "poll"), default="auto",
                    help="HMD_INBOX_WATCH for the hook under test (ignored by a tree that predates it)")
    ap.add_argument("--trials", type=int, default=6)
    ap.add_argument("--parallel", type=int, default=6, help="trials run side by side, each in its own repo")
    ap.add_argument("--phase-min", type=float, default=0.3, help="idle-hold: earliest landing, s into the hold")
    ap.add_argument("--phase-max", type=float, default=1.2, help="idle-hold: latest landing, s into the hold")
    ap.add_argument("--turn-s", type=float, default=4.0, help="tool-boundary: length of the scripted turn")
    ap.add_argument("--tool-s", type=float, default=0.2, help="tool-boundary: how long each tool runs")
    ap.add_argument("--gap", type=float, default=0.5, help="tool-boundary: seconds from one tool call to the next")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    ctx = build_ctx(args)
    try:
        if ctx.stop_cmd is None:
            sys.stderr.write("inbox-latency-probe: no inbox-deliver-stop command in %s/hooks/hooks.json\n" % ctx.root)
            return 2
        if args.scenario == "idle-hold":
            offsets = spread(args.phase_min, args.phase_max, args.trials)
            trial = trial_idle_hold
        else:
            offsets = spread(0.3, max(args.turn_s - 1.0, 0.3), args.trials)
            trial = trial_tool_boundary
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.parallel)) as pool:
            rows = list(pool.map(lambda pair: trial(ctx, pair[0], pair[1]), enumerate(offsets)))
    finally:
        shutil.rmtree(ctx.home, ignore_errors=True)

    good = [r for r in rows if r is not None]
    report = {"scenario": args.scenario, "library": args.library, "watch": args.watch,
              "trials": len(rows), "failed": len(rows) - len(good),
              "tool_boundary_wired": ctx.pre_cmd is not None or ctx.post_cmd is not None,
              "receipt_s": summarize([r["receipt_s"] for r in good]),
              "seen_s": summarize([r["seen_s"] for r in good])}
    if args.json:
        print(json.dumps(report))
    else:
        print("%s library=%s watch=%s: %d/%d delivered; receipt p50=%s p95=%s max=%s s; seen p50=%s p95=%s max=%s s"
              % (args.scenario, args.library, args.watch, len(good), len(rows),
                 report["receipt_s"]["p50"], report["receipt_s"]["p95"], report["receipt_s"]["max"],
                 report["seen_s"]["p50"], report["seen_s"]["p95"], report["seen_s"]["max"]))
    return 0 if not report["failed"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
