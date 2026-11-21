#!/usr/bin/env bash
# test/seamless-restart-e2e.test.sh -- the seamless restart after an update, end to end
# (docs/superpowers/plans/2026-11-13-seamless-update-restart.md section 8 and Task W4-e2e; the feature is documented in docs/seamless-restart.md).
#
# What runs for real: bin/heimdall (a copy per run, in a sandbox plugin dir, started on a pty so it supervises), bin/lib/hmd_supervise.sh, the Stop hook of
# hooks/hooks.json (its command line, extracted with jq) and bin/heimdall-restart-request, bin/heimdall-restart-gate, bin/heimdall-update-pending. What is
# faked, at the boundary only: claude (test/fixtures/fake-claude, the oracle of W1, written from the plan and never from this code), the process table and the
# live-subagent count the gate asks for, the checkpoint writer, and the claude half of "is a newer claude installed" (heimdall-cc-selfheal answers only for a
# native install, which a sandbox is not). Nothing outside the temp tree is read, written or signalled; only the fake claudes this suite started are ever signalled.
#
# The clock is virtual and the steps are counted, not timed. The real gate runs with its DEFAULT quiet window (300 s, the decided Q2); a wrapper hands it
# HMD_RESTART_NOW = the real time + a skew the world driver adds in whole steps, so "the operator was away for five minutes" is ONE step, never 300 s of waiting.
# Every assertion is an ordering or a count (events of the fake's log against the evaluations of the gate): a slow machine stretches a run, it cannot flip a verdict.
# A state only counts against a gate answer when it held through the whole evaluation (plus a margin), so the race windows of a live system are not judged.
#
# Cases (all start at once through a throttle, each in its own sandbox):
#   journey   an operator is working, an update lands, they go idle, the restart comes at the first quiet moment and the SAME conversation is back, one line printed
#   golden    the oracle's restart-happy, restart-deferred and restart-loop-guard traces, run through the real launcher and hook; plus term-ignored (the session is
#             kept) and print-mode (a -p task is never supervised, even with HMD_SUPERVISED=1 inherited from an outer session)
#   seeds     N seeded interleavings of {Stop, keystroke, live child, sweep.lock, live agents, installer, /clear, user /exit, second Stop, time passing} with the
#             invariants of section 8: I1 the TERM is only ever sent after two SAFE answers, and no SAFE answer was given while the status was busy, or live work,
#             a keystroke inside the quiet window was in effect; I2 at most one relaunch per target version; I3 every relaunch is --resume <the session id in effect
#             at TERM time>; I4 the launcher's status is the last child's; I5 only the fake claude gets a TERM and only the launcher a USR1 (kill is wrapped through
#             BASH_ENV); I6 the one line is printed exactly once per relaunch. A vacuity guard asserts the sweep restarts some seeds and defers others.
#   mutants   the ten one-line seds of test/fixtures/fake-claude/mutants.list, each applied to a COPY of the real file and run under the scenario that pins it;
#             all ten must go RED (score 1.0), and each sed must really change its file (else the list and the code have drifted).
#
# Debugging aids (not used by the gate): E2E_SEEDS=N (default 50), E2E_LIMIT=N (concurrent runs, default 12), E2E_ONLY=journey,happy,deferred,loopguard,ignore,print,
# seeds,mutants (comma list, default all), E2E_KEEP=1 (keep the temp tree and print it).
# bash 3.2 compatible.
#
# budget: 150 -- ~100 s solo: about seventy launcher runs on real ptys, all with real sleeps (the oracle's restart-deferred script alone is ~55 s and is run five
# times: golden and four mutants), twelve at a time; no assertion depends on the speed of the machine, a failure that only shows under load gets ONE solo re-run.
#
# Usage:  bash test/seamless-restart-e2e.test.sh
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO/test/lib/net-default-guard.sh"
FAKE="$REPO/test/fixtures/fake-claude/fake-claude.sh"
TRACES="$REPO/test/fixtures/fake-claude/expected"
MUTANTS="$REPO/test/fixtures/fake-claude/mutants.list"
HOOKS_JSON="$REPO/hooks/hooks.json"
DOC="$REPO/docs/seamless-restart.md"
SEEDS="${E2E_SEEDS:-50}"
LIMIT="${E2E_LIMIT:-12}"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
want() { [ -z "${E2E_ONLY:-}" ] && return 0; case ",$E2E_ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

echo "seamless-restart-e2e"
for tool in python3 perl jq; do command -v "$tool" >/dev/null 2>&1 || { bad "0. $tool is required"; exit 1; }; done
for f in "$FAKE" "$MUTANTS" "$HOOKS_JSON" "$TRACES/restart-happy.trace" "$TRACES/restart-deferred.trace" "$TRACES/restart-loop-guard.trace" \
         "$REPO/bin/heimdall" "$REPO/bin/lib/hmd_supervise.sh" "$REPO/bin/lib/hmd_restart_gate.py" "$REPO/bin/heimdall-restart-request"; do
  [ -f "$f" ] || { bad "0. $f must exist"; exit 1; }
done
STOP_CMD="$(jq -r '[.hooks.Stop[].hooks[].command | select(contains("heimdall-restart-request"))] | .[0] // empty' "$HOOKS_JSON")"
[ -n "$STOP_CMD" ] || { bad "0. hooks/hooks.json has no Stop hook that runs heimdall-restart-request"; exit 1; }
if [ "$(wc -l < "$MUTANTS" | tr -d ' ')" = 10 ]; then ok "0. the mutant list has ten rows"; else bad "0. the mutant list does not have ten rows"; fi

T="$(mktemp -d "${TMPDIR:-/tmp}/seamless-restart-e2e.XXXXXX")" || exit 1
T="$(cd "$T" && pwd -P)"
cleanup() {
  local f p
  for f in "$T"/*/claude.log; do
    [ -f "$f" ] || continue
    for p in $(sed -n 's/.*"event":"start".*"pid":\([0-9][0-9]*\),.*/\1/p;s/.*"event":"start","pid":\([0-9][0-9]*\).*/\1/p' "$f"); do
      case "$(ps -o command= -p "$p" 2>/dev/null)" in *fake-claude.sh*) kill -USR2 "$p" 2>/dev/null ;; esac
    done
  done
  for f in "$T"/*/sweeper.pid; do
    [ -f "$f" ] || continue
    p="$(cat "$f")"
    case "$(ps -o command= -p "$p" 2>/dev/null)" in "sleep 3600"*) kill "$p" 2>/dev/null ;; esac
  done
  if [ "${E2E_KEEP:-}" = 1 ]; then echo "kept: $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

# ------------------------------------------------------------------------------------------------------------------------------------------ the helper program
cat > "$T/e2e.py" <<'PY'
import fcntl
import json
import os
import random
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time

EPS = 0.35  # a state must have held this long before, and after, a gate evaluation to count as held through it
NON_IDLE = ("busy", "waiting", "shell")
UPDATED = re.compile(r"^\[heimdall\] updated (.*) - resumed(?: \(parked agents ended: .*\))?$", re.M)
LIVE_REASONS = ("not-idle", "settling", "agents-live", "sweep-running", "task-live", "user-active", "install-running")


def read_jsonl(path):
    rows = []
    try:
        with open(path, errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        return rows
    return rows


def read_text(path):
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


# ----------------------------------------------------------------------------------------------------------------------------------------------------- pty
def pty_main(argv):
    timeout_s, out_path, cmd = float(argv[0]), argv[1], argv[2:]
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

    def own_tty():
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave, close_fds=True, start_new_session=True, preexec_fn=own_tty)
    os.close(slave)
    deadline = time.time() + timeout_s
    rc = None
    with open(out_path, "wb") as out:
        while True:
            if time.time() > deadline:
                proc.kill()
                rc = 124
                break
            ready, _, _ = select.select([master], [], [], 0.2)
            if ready:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    chunk = b""
                if chunk:
                    out.write(chunk)
                    out.flush()
                    continue
            if proc.poll() is not None:
                break
        if rc is None:
            rc = proc.wait()
    return rc if rc >= 0 else 128 - rc


# ------------------------------------------------------------------------------------------------------------------------------------------ world driver
class World(object):
    """The events of a run that are not the fake claude's own: the update landing, time passing, live work the status does not show, the user quitting."""

    def __init__(self, sd):
        self.sd = sd
        self.sweeper = None
        self.exiting = False
        self.last_exit = 0.0
        self.term_wait = None
        self.term_seen = None

    def path(self, *parts):
        return os.path.join(self.sd, *parts)

    def log(self, kind, state):
        row = {"ts": int(time.time() * 1000), "event": "world", "kind": kind, "state": state}
        with open(self.path("world.log"), "a") as f:
            f.write(json.dumps(row) + "\n")

    def apply(self, kind, arg):
        if kind == "skew":
            cur = int(read_text(self.path("vskew")).strip() or "0") + int(arg)
            atomic(self.path("vskew"), str(cur))
            self.log("skew", str(cur))
        elif kind == "agents":
            atomic(self.path("agents.n"), str(arg))
            self.log("agents", str(arg))
        elif kind == "sweep":
            rdir = self.path("home", ".heimdall", "receipts")
            os.makedirs(rdir, exist_ok=True)
            if arg == "on" and self.sweeper is None:
                self.sweeper = subprocess.Popen(["sleep", "3600"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                atomic(self.path("sweeper.pid"), str(self.sweeper.pid))
                atomic(os.path.join(rdir, "sweep.lock"), "pid=%d\n" % self.sweeper.pid)
            elif arg == "off":
                self.stop_sweeper()
                try:
                    os.remove(os.path.join(rdir, "sweep.lock"))
                except OSError:
                    time.sleep(0)
            self.log("sweep", arg)
        elif kind == "installer":
            marker = self.path("installer.on")
            if arg == "on":
                open(marker, "w").close()
            elif os.path.exists(marker):
                os.remove(marker)
            self.log("installer", arg)
        elif kind == "plugin":
            atomic(self.path("plugin", ".claude-plugin", "plugin.json"), '{"name": "heimdall", "version": "%s"}\n' % arg)
            self.log("plugin", arg)
        elif kind == "claude-newest":
            binary = self.path("versions", arg)
            open(binary, "w").close()
            os.utime(binary, (1577836800, 1577836800))
            self.log("claude-newest", arg)
        elif kind == "exit":
            self.exiting = True
            self.log("exit", "typed")
        elif kind == "after-term":
            self.term_wait = float(arg)

    def stop_sweeper(self):
        if self.sweeper is not None:
            self.sweeper.kill()
            self.sweeper.wait()
            self.sweeper = None

    def fifo_exit(self):
        try:
            fd = os.open(self.path("fifo"), os.O_RDWR | os.O_NONBLOCK)
        except OSError:
            return
        try:
            os.write(fd, b"/exit\n")
        finally:
            os.close(fd)


def world_main(sd):
    w = World(sd)
    limit = time.time() + 140
    finished = lambda: os.path.exists(w.path("done"))
    while not finished() and time.time() < limit:
        if any(e.get("event") == "start" for e in read_jsonl(w.path("claude.log"))):
            break
        time.sleep(0.05)
    if finished():
        return 0
    base = time.time()
    events = sorted(json.load(open(w.path("timeline.json"))), key=lambda e: e[0])
    i, last_term_look = 0, 0.0
    while not finished() and time.time() < limit:
        t = time.time() - base
        while i < len(events) and events[i][0] <= t:
            w.apply(events[i][1], events[i][2])
            i += 1
        if w.term_wait is not None and w.term_seen is None and time.time() - last_term_look >= 0.2:
            last_term_look = time.time()
            if any(e.get("event") == "signal" and e.get("signal") == "TERM" for e in read_jsonl(w.path("claude.log"))):
                w.term_seen = time.time()
        if w.term_seen is not None and time.time() - w.term_seen >= w.term_wait:
            w.exiting = True
        if w.exiting and time.time() - w.last_exit >= 0.5:
            w.fifo_exit()
            w.last_exit = time.time()
        time.sleep(0.03)
    w.stop_sweeper()
    return 0


# ------------------------------------------------------------------------------------------------------------------------------------------- generator
def gen_main(seed, sd):
    r = random.Random(seed)

    def u(lo, hi):
        return round(r.uniform(lo, hi), 2)

    sid = "sid-s%d" % seed
    takes = r.random() < 0.65  # does the relaunched claude run the new version? else the target stays pending (the loop guard's case)
    fake, ext = [], []
    tu = u(0.1, 1.2)
    kind = r.choice(("claude", "hmd", "both"))
    if kind != "hmd":
        ext.append([tu, "claude-newest", "2.1.323"])
    if kind != "claude":
        ext.append([round(tu + r.choice((0.0, 0.2, 0.4)), 2), "plugin", "2.4.2"])
    t = u(0.3, 1.2)
    for _ in range(r.choice((1, 2, 2, 3))):
        fake.append([t, "set status=" + r.choice(("busy", "busy", "busy", "waiting", "shell"))])
        t = round(t + u(0.3, 1.0), 2)
        fake.append([t, "stop-hook"])
        t = round(t + (u(3.0, 4.5) if r.random() < 0.3 else u(0.1, 0.9)), 2)
        fake.append([t, "set status=idle"])
        t = round(t + u(0.2, 2.0), 2)
    last = t
    for _ in range(r.choice((0, 0, 0, 1, 1, 2))):
        fake.append([u(0.3, last + 1.0), "key"])
    if r.random() < 0.35:
        tc = u(0.5, 3.0)
        fake += [[tc, "child on"], [round(tc + u(1.5, 3.5), 2), "child off"]]
    if r.random() < 0.2:
        ta = u(0.5, 3.0)
        ext += [[ta, "agents", "1"], [round(ta + u(1.5, 3.0), 2), "agents", "0"]]
    if r.random() < 0.2:
        ts = u(0.5, 3.0)
        ext += [[ts, "sweep", "on"], [round(ts + u(1.5, 3.0), 2), "sweep", "off"]]
    if r.random() < 0.2:
        ti = u(0.5, 3.0)
        ext += [[ti, "installer", "on"], [round(ti + u(1.5, 3.0), 2), "installer", "off"]]
    if r.random() < 0.25:
        fake.append([u(1.0, last + 1.0), "set sessionId=sid-c%d" % seed])
    t_end = min(round(last + u(2.0, 6.0), 2), 11.0)
    if r.random() < 0.5:
        ext.append([u(1.5, max(2.0, t_end - 2.0)), "skew", "400"])
    ext.append([t_end, "exit", ""])
    lines = ["@0 set status=idle sessionId=%s version=2.1.322" % sid]
    prev = 0.0
    for at, step in sorted(fake, key=lambda x: x[0]):
        if at > prev:
            lines.append("@0 sleep %.2f" % (at - prev))
            prev = at
        lines.append("@0 " + step)
    lines.append("@1 set status=idle version=%s" % ("2.1.323" if takes else "2.1.322"))
    if not takes:
        lines += ["@1 sleep 0.5", "@1 set status=busy", "@1 sleep 0.4", "@1 stop-hook", "@1 set status=idle"]
    with open(os.path.join(sd, "script"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(sd, "timeline.json"), "w") as f:
        json.dump(ext, f)
    return 0


# --------------------------------------------------------------------------------------------------------------------------------------------- checker
def normalize_main(sd):
    """The real launcher passes --resume <id> before --agent heimdall, the oracle's traces write it after: put the pair in the trace's order."""
    with open(os.path.join(sd, "claude.norm.log"), "w") as f:
        for e in read_jsonl(os.path.join(sd, "claude.log")):
            if e.get("event") == "start":
                argv = list(e["argv"])
                if "--resume" in argv and "--agent" in argv:
                    i = argv.index("--resume")
                    if i < argv.index("--agent") and i + 1 < len(argv):
                        pair = argv[i:i + 2]
                        del argv[i:i + 2]
                        j = argv.index("--agent")
                        argv[j + 2:j + 2] = pair
                e["argv"] = argv
            f.write(json.dumps(e) + "\n")
    return 0


def check_main(sd, quiet, mode):
    ev = read_jsonl(os.path.join(sd, "claude.log"))
    wl = read_jsonl(os.path.join(sd, "world.log"))
    bad = []
    gates = []
    for line in read_text(os.path.join(sd, "gate.log")).splitlines():
        p = line.split()
        try:
            if len(p) >= 4:
                gates.append((float(p[0]), float(p[1]), float(p[2]), p[3], p[4] if len(p) > 4 else ""))
        except ValueError:
            bad.append("gate.log has a line that is not an evaluation: %r" % line[:60])
    gates.sort(key=lambda g: g[1])
    starts = [e for e in ev if e["event"] == "start"]
    terms = [e for e in ev if e["event"] == "signal" and e.get("signal") == "TERM"]
    exits = [e for e in ev if e["event"] == "exit"]
    keys = [e["ts"] / 1000.0 for e in ev if e["event"] == "key"]
    out = read_text(os.path.join(sd, "out")).replace("\r", "")
    try:
        rc = int(read_text(os.path.join(sd, "rc")).strip())
    except ValueError:
        rc = None

    status = sorted(((e["ts"] / 1000.0, None if e["event"] in ("start", "exit") else e["status"])
                     for e in ev if e["event"] in ("start", "exit") or (e["event"] == "status" and "status" in e)), key=lambda x: x[0])

    def status_at(t):
        cur = None
        for at, value in status:
            if at > t:
                break
            cur = value
        return cur

    iv = {"child": [], "agents": [], "sweep": [], "installer": []}
    opened = None
    for e in ev:
        t = e["ts"] / 1000.0
        if e["event"] == "child" and e.get("state") == "on":
            opened = t
        elif opened is not None and ((e["event"] == "child" and e.get("state") == "off") or e["event"] == "exit"):
            iv["child"].append((opened, t))
            opened = None
    if opened is not None:
        iv["child"].append((opened, float("inf")))
    since = {}
    for e in wl:
        kind, state, t = e["kind"], e["state"], e["ts"] / 1000.0
        if kind not in ("agents", "sweep", "installer"):
            continue
        live = state == "on" or (kind == "agents" and state not in ("0", ""))
        if live and kind not in since:
            since[kind] = t
        elif not live and kind in since:
            iv[kind].append((since.pop(kind), t))
    for kind, t in since.items():
        iv[kind].append((t, float("inf")))

    # I1: a SAFE answer is never given while a state that must stop a restart held through the whole evaluation
    for a, b, skew, verdict, _ in gates:
        if verdict != "SAFE":
            continue
        lo, hi = a - EPS, b + EPS
        why = []
        s = status_at(lo)
        if s in NON_IDLE and not any(lo < at <= hi for at, _v in status):
            why.append("status %s" % s)
        for kind, spans in iv.items():
            if any(x <= lo and y >= hi for x, y in spans):
                why.append("%s live" % kind)
        earlier = [k for k in keys if k <= lo]
        if earlier and (a + skew) - max(earlier) < quiet - EPS:
            why.append("a keystroke %.1f virtual s ago (quiet window %g s)" % ((a + skew) - max(earlier), quiet))
        if why:
            bad.append("I1 SAFE at %.2f while %s" % (a, ", ".join(why)))
    # I1: a TERM follows two SAFE answers, nothing else
    for tm in terms:
        t = tm["ts"] / 1000.0
        prior = [g for g in gates if g[1] <= t + 0.05]
        if len(prior) < 2 or any(g[3] != "SAFE" for g in prior[-2:]):
            bad.append("I1 TERM at %.2f without two SAFE answers right before it" % t)

    # the session id in effect, per fake process
    hist = {}
    for e in ev:
        if e["event"] == "start":
            resume = e.get("resume")
            hist[e["pid"]] = [(e["ts"] / 1000.0, resume if resume not in (None, "none") else "fake-sid-%d" % e["n"])]
        elif e["event"] == "status" and "sessionId" in e and e["pid"] in hist:
            hist[e["pid"]].append((e["ts"] / 1000.0, e["sessionId"]))

    def sid_at(pid, t):
        cur = None
        for at, sid in hist.get(pid, []):
            if at <= t:
                cur = sid
        return cur

    if mode == "strict":
        for tm in terms:
            t = tm["ts"] / 1000.0
            later = [s for s in starts if s["ts"] > tm["ts"]]
            if not later:
                bad.append("I3 TERM at %.2f was never followed by a relaunch" % t)
                continue
            nxt = later[0]
            want = {sid_at(tm["pid"], t), sid_at(tm["pid"], t - 1.2)}
            argv = nxt["argv"]
            given = argv[argv.index("--resume") + 1] if "--resume" in argv and argv.index("--resume") + 1 < len(argv) else None
            if given is None or given not in want or nxt.get("resume") != given:
                bad.append("I3 relaunch after the TERM at %.2f resumes %r, the session in effect was %s" % (t, given, sorted(x for x in want if x)))
        for k, s in enumerate(starts[1:], 1):
            if s["env"].get("HMD_RESTART_COUNT") != str(k):
                bad.append("I3 start %d has HMD_RESTART_COUNT=%r" % (k, s["env"].get("HMD_RESTART_COUNT")))
    lines = UPDATED.findall(out)
    targets = []
    for text in lines:
        names = tuple(sorted(re.findall(r"(claude|hmd) \S+->(\S+)", text)))
        targets.append(names)
    if len(set(targets)) != len(targets):
        bad.append("I2 a second relaunch for the same target version: %r" % (lines,))
    if mode == "strict" and len(lines) != len(starts) - 1:
        bad.append("I6 the line was printed %d times for %d relaunches" % (len(lines), len(starts) - 1))
    if mode == "ignore" and (lines or len(starts) != 1):
        bad.append("I6 a session whose TERM was ignored must not be relaunched (lines=%d starts=%d)" % (len(lines), len(starts)))
    if rc is None or rc == 124:
        bad.append("I4 the launcher did not finish (status %r)" % rc)
    elif exits and exits[-1]["rc"] != rc:
        bad.append("I4 the launcher exited %d, the last child %d" % (rc, exits[-1]["rc"]))
    fakes = set(e["pid"] for e in starts)
    launcher = None
    for s in starts:
        if s["env"].get("HMD_LAUNCHER_PID"):
            launcher = int(s["env"]["HMD_LAUNCHER_PID"])
            break
    for line in read_text(os.path.join(sd, "kill.log")).splitlines():
        parts = line.split("|", 3)
        if len(parts) < 3 or parts[0] not in ("hmd_supervise.sh", "heimdall-restart-request"):
            continue
        args = parts[2].split()
        sig = args[0].lstrip("-") if args and args[0].startswith("-") else "TERM"
        pids = args[1:] if args and args[0].startswith("-") else args
        sig_ok = (sig in ("TERM", "15") and parts[0] == "hmd_supervise.sh" and all(p.isdigit() and int(p) in fakes for p in pids)) or \
                 (sig == "USR1" and parts[0] == "heimdall-restart-request" and all(p.isdigit() and int(p) == launcher for p in pids))
        if not sig_ok:
            bad.append("I5 %s sent `kill %s`" % (parts[0], parts[2]))

    verdicts = {}
    for _a, _b, _s, verdict, reason in gates:
        key = "SAFE" if verdict == "SAFE" else reason
        verdicts[key] = verdicts.get(key, 0) + 1
    with open(os.path.join(sd, "stats.json"), "w") as f:
        json.dump({"terms": len(terms), "starts": len(starts), "verdicts": verdicts}, f)
    for line in bad:
        print(line)
    return 1 if bad else 0


def summary_main(dirs):
    restarted = deferred = both = 0
    reasons = {}
    for sd in dirs:
        try:
            st = json.load(open(os.path.join(sd, "stats.json")))
        except (OSError, ValueError):
            continue
        held = [k for k in st["verdicts"] if k in LIVE_REASONS]
        restarted += 1 if st["terms"] else 0
        deferred += 1 if held else 0
        both += 1 if st["terms"] and held else 0
        for k in held:
            reasons[k] = reasons.get(k, 0) + st["verdicts"][k]
    print("restarted=%d deferred=%d deferred-then-restarted=%d reasons=%s" % (restarted, deferred, both, ",".join(sorted(reasons))))
    return 0


if __name__ == "__main__":
    cmd, rest = sys.argv[1], sys.argv[2:]
    if cmd == "pty":
        sys.exit(pty_main(rest))
    if cmd == "world":
        sys.exit(world_main(rest[0]))
    if cmd == "gen":
        sys.exit(gen_main(int(rest[0]), rest[1]))
    if cmd == "normalize":
        sys.exit(normalize_main(rest[0]))
    if cmd == "check":
        sys.exit(check_main(rest[0], float(rest[1]), rest[2]))
    if cmd == "summary":
        sys.exit(summary_main(rest))
    sys.exit(64)
PY
python3 -I -m py_compile "$T/e2e.py" 2>/dev/null && ok "0. the helper program compiles" || { bad "0. the helper program does not compile"; exit 1; }

# ------------------------------------------------------------------------------------------------------------------------------------------- the stand-ins
mkdir -p "$T/stubs" "$T/fakes"
cat > "$T/stubs/claude" <<'EOF'
#!/bin/sh
# the claude on PATH: the fake for the launcher's own launch (--agent heimdall) and --version, nothing for any other call the launcher makes
case "$1" in --version) exec bash "$FAKE_CLAUDE_SH" "$@" ;; esac
case " $* " in *" --agent heimdall "*) exec bash "$FAKE_CLAUDE_SH" "$@" ;; esac
exit 0
EOF
cat > "$T/fakes/gate.sh" <<'EOF'
#!/bin/sh
# the REAL gate under a virtual clock: HMD_RESTART_NOW is the real time plus the skew the world driver has added so far, and every evaluation is recorded as
# `start end skew verdict [reason]` for the invariant checker
t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
skew=$(cat "$SC_DIR/vskew" 2>/dev/null)
case "$skew" in ''|*[!0-9]*) skew=0 ;; esac
HMD_RESTART_NOW=$(perl -e 'printf "%.3f", $ARGV[0] + $ARGV[1]' "$t0" "$skew")
export HMD_RESTART_NOW
out=$("$SC_PLUGIN/bin/heimdall-restart-gate" "$@")
rc=$?
t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
printf '%s %s %s %s\n' "$t0" "$t1" "$skew" "$out" >> "$SC_DIR/gate.log"
printf '%s\n' "$out"
exit "$rc"
EOF
cat > "$T/fakes/ps.sh" <<'EOF'
#!/bin/sh
# the process table of ONE run: the launcher's descendants only (nothing else on this machine can sway a verdict), without what the fake claude keeps around
# as housekeeping: its `sleep`s and its forked subshells (a row whose command line is its parent's own). The `sleep 3600` a `child on` step started is live
# work the status does not show and stays: its pid is the last child event of the fake's log. An installer is a row of its own while installer.on exists.
keep=$(grep '"event":"child"' "$FAKE_CLAUDE_LOG" 2>/dev/null | tail -n 1 | sed -n 's/.*"state":"on","cpid":\([0-9][0-9]*\).*/\1/p')
ps -axww -o pid=,ppid=,command= | awk -v root="${HMD_LAUNCHER_PID:-0}" -v keep="${keep:-0}" '
  { ppid[$1] = $2; row[$1] = $0; name = $3; sub(/.*\//, "", name); base[$1] = name; c = ""; for (i = 3; i <= NF; i++) c = c (i > 3 ? " " : "") $i; cmd[$1] = c }
  END {
    mark[root] = 1
    do { grew = 0; for (p in ppid) if (!(p in mark) && (ppid[p] in mark)) { mark[p] = 1; grew = 1 } } while (grew)
    for (p in mark) {
      if (p == root || !(p in row)) continue
      if (base[p] == "sleep" && p != keep) continue
      if ((ppid[p] in cmd) && cmd[p] == cmd[ppid[p]]) continue
      print row[p]
    }
  }'
if [ -f "$SC_DIR/installer.on" ]; then echo "999999 1 /bin/bash /opt/heimdall/install.sh --update"; fi
EOF
cat > "$T/fakes/agents.sh" <<'EOF'
#!/bin/sh
n=$(cat "$SC_DIR/agents.n" 2>/dev/null)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
echo "$n"
EOF
cat > "$T/fakes/checkpoint.sh" <<'EOF'
#!/bin/sh
echo "$*" >> "$SC_DIR/checkpoint.log"
EOF
cat > "$T/fakes/ccpending.sh" <<'EOF'
#!/bin/sh
# stands in for `heimdall-cc-selfheal pending --pid P`, which answers only for a NATIVE claude install: the running version is the one in the session file of P,
# the newest is the highest name in the versions directory; `claude <running> <newest>` and exit 0 when running is older, exit 1 and nothing otherwise
pid=""
while [ $# -gt 0 ]; do
  case "$1" in --pid) pid="$2"; shift ;; esac
  shift
done
running=$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$HMD_RESTART_SESSIONS_DIR/$pid.json" 2>/dev/null)
newest=$(ls "$HEIMDALL_CC_VERSIONS" 2>/dev/null | sort -V | tail -n 1)
[ -n "$running" ] && [ -n "$newest" ] && [ "$running" != "$newest" ] || exit 1
[ "$(printf '%s\n%s\n' "$running" "$newest" | sort -V | head -n 1)" = "$running" ] || exit 1
echo "claude $running $newest"
EOF
cat > "$T/fakes/kill-wrap.sh" <<'EOF'
# BASH_ENV of every bash of a run: `kill` is logged as `source|pid|arguments|status` (the existence probe `kill -0` is not), then done by the builtin
kill() {
  local rc=0
  builtin kill "$@" || rc=$?
  case "${1:-}" in -0) return "$rc" ;; esac
  printf '%s|%s|%s|%s\n' "$(basename "${BASH_SOURCE[1]:-}")" "$$" "$*" "$rc" >> "${SC_KILLLOG:-/dev/null}" 2>/dev/null
  return "$rc"
}
EOF
chmod +x "$T/stubs/claude" "$T/fakes/gate.sh" "$T/fakes/ps.sh" "$T/fakes/agents.sh" "$T/fakes/checkpoint.sh" "$T/fakes/ccpending.sh"

# ----------------------------------------------------------------------------------------------------------------------------------------- the sandboxes
mk_install() {   # mk_install DIR: the files of an hmd install a launch reads, in the layout of the repository (the mutants edit these copies, never the repository)
  local d="$1" f
  mkdir -p "$d/bin/lib" "$d/hooks" "$d/.claude-plugin"
  cp "$REPO/bin/heimdall" "$d/bin/heimdall"
  for f in heimdall-restart-gate heimdall-update-pending heimdall-restart-request; do cp "$REPO/bin/$f" "$d/bin/$f"; done
  for f in hmd_supervise.sh hmd_restart_gate.py hmd_update_pending.py hmd_sweep_guard.py hmd_kill_guard.py hook-enabled.sh; do cp "$REPO/bin/lib/$f" "$d/bin/lib/$f"; done
  cp "$REPO/hooks/hooks.json" "$REPO/hooks/hooks.metadata.json" "$d/hooks/"
  chmod +x "$d/bin/heimdall" "$d/bin/heimdall-restart-gate" "$d/bin/heimdall-update-pending" "$d/bin/heimdall-restart-request"
}

prep() {   # prep SD HMD_AT_LAUNCH [NEWEST_CLAUDE_ALREADY_INSTALLED]
  local sd="$1"
  mkdir -p "$sd/cwd" "$sd/home/.heimdall" "$sd/home/.claude/sessions" "$sd/versions" "$sd/tasks"
  touch "$sd/home/.heimdall/setup-done"
  mk_install "$sd/plugin"
  printf '{"name": "heimdall", "version": "%s"}\n' "$2" > "$sd/plugin/.claude-plugin/plugin.json"
  : > "$sd/versions/2.1.322"
  touch -t 202001010000 "$sd/versions/2.1.322"
  if [ -n "${3:-}" ]; then : > "$sd/versions/$3"; touch -t 202001010000 "$sd/versions/$3"; fi
  : > "$sd/tty"
  touch -t 202001010000 "$sd/tty"
  mkfifo "$sd/fifo"
  : > "$sd/claude.log"
  : > "$sd/gate.log"
  : > "$sd/world.log"
  : > "$sd/kill.log"
  echo 0 > "$sd/vskew"
  echo '[]' > "$sd/timeline.json"
}

trace_script() { HMD_FAKE_CLAUDE=1 bash "$FAKE" --extract script "$1" > "$2"; }

# the scenarios: each prepares its sandbox and sets SC_ENV (extra variables of the launcher) and SC_ARGV (the launcher's arguments)
scn_journey() {
  prep "$1" 2.4.1
  cat > "$1/script" <<'EOF'
@0 set status=idle sessionId=sid-J version=2.1.322
@0 sleep 0.6
@0 key
@0 set status=busy
@0 sleep 0.6
@0 key
@0 sleep 0.6
@0 stop-hook
@0 set status=idle
@1 set status=idle version=2.1.323
@1 sleep 4
@1 exit 0
EOF
  printf '[[0.2, "plugin", "2.4.2"], [0.2, "claude-newest", "2.1.323"], [5.0, "skew", "400"], [40, "exit", ""]]\n' > "$1/timeline.json"
  SC_ENV=()
  SC_ARGV=()
}
scn_happy() {
  prep "$1" 2.4.1 2.1.323
  trace_script "$TRACES/restart-happy.trace" "$1/script"
  printf '[[0.2, "plugin", "2.4.2"], [40, "exit", ""]]\n' > "$1/timeline.json"
  SC_ENV=(HMD_RESTART_POLL_S=2 HMD_RESTART_QUIET_S=3 HMD_RESTART_SETTLE_S=3)
  SC_ARGV=()
}
scn_loopguard() {
  prep "$1" 2.4.2 2.1.323
  trace_script "$TRACES/restart-loop-guard.trace" "$1/script"
  printf '[[40, "exit", ""]]\n' > "$1/timeline.json"
  SC_ENV=(HMD_RESTART_POLL_S=2 HMD_RESTART_QUIET_S=3 HMD_RESTART_SETTLE_S=3)
  SC_ARGV=()
}
scn_deferred() {
  prep "$1" 2.4.2 2.1.323
  trace_script "$TRACES/restart-deferred.trace" "$1/script"
  printf '[[90, "exit", ""]]\n' > "$1/timeline.json"
  SC_ENV=(HMD_RESTART_POLL_S=2 HMD_RESTART_QUIET_S=8 HMD_RESTART_SETTLE_S=2)
  SC_ARGV=()
}
scn_ignore() {
  prep "$1" 2.4.1 2.1.323
  trace_script "$TRACES/restart-happy.trace" "$1/script.all"
  { grep '^@0 ' "$1/script.all"; echo '@1 exit 0'; } > "$1/script"
  printf '[[0.2, "plugin", "2.4.2"], [0.0, "after-term", "4"], [40, "exit", ""]]\n' > "$1/timeline.json"
  SC_ENV=(FAKE_CLAUDE_TERM=ignore HMD_RESTART_TERM_WAIT_S=3 HMD_RESTART_POLL_S=2 HMD_RESTART_QUIET_S=3 HMD_RESTART_SETTLE_S=3)
  SC_ARGV=()
}
scn_print() {
  prep "$1" 2.4.1
  : > "$1/script"
  SC_ENV=(HMD_SUPERVISED=1)
  SC_ARGV=(fix the login bug)
}
scn_seed() {
  prep "$1" 2.4.1
  python3 -I "$T/e2e.py" gen "$2" "$1"
  SC_ENV=()
  SC_ARGV=()
}

mut_row() { awk -F'\t' -v n="$1-" 'index($3, n) == 1 { print $1 "\t" $2; exit }' "$MUTANTS"; }
mut_kind() { case "$1" in M1|M2|M3|M5) echo deferred ;; M4|M6|M9) echo happy ;; M7) echo ignore ;; M8) echo print ;; M10) echo loopguard ;; esac; }
apply_mutant() {   # apply_mutant SD Mn: 0 when the one-line sed changed its file, 1 when it matched nothing, 2 when the row or file is missing
  local sd="$1" row file expr
  row="$(mut_row "$2")"
  file="${row%%$'\t'*}"
  expr="${row#*$'\t'}"
  [ -n "$row" ] && [ -f "$sd/plugin/$file" ] || return 2
  sed -e "$expr" "$sd/plugin/$file" > "$sd/plugin/$file.mut" || return 2
  if cmp -s "$sd/plugin/$file" "$sd/plugin/$file.mut"; then rm -f "$sd/plugin/$file.mut"; return 1; fi
  cat "$sd/plugin/$file.mut" > "$sd/plugin/$file"
  rm -f "$sd/plugin/$file.mut"
  return 0
}

throttle() { while [ "$(jobs -r | wc -l | tr -d ' ')" -ge "$LIMIT" ]; do sleep 0.3; done; }

# start_run SD: one launcher, under a pty, in the background; the world driver runs beside it; the status of the launcher lands in SD/rc
start_run() {
  local sd="$1"
  (
    cd "$sd/cwd" || exit 1
    python3 -I "$T/e2e.py" world "$sd" > "$sd/world.err" 2>&1 &
    wpid=$!
    rc=0
    env -i PATH="$T/stubs:$PATH" HOME="$sd/home" HEIMDALL_HOME="$sd/home/.heimdall" TERM=dumb ANTHROPIC_API_KEY=sk-ant-seamless-restart-e2e \
      HEIMDALL_NO_INTRO=1 HEIMDALL_NO_UPDATE_CHECK=1 HEIMDALL_NO_REUSE_METRIC=1 HEIMDALL_DEFAULT_CP_URL="${HEIMDALL_DEFAULT_CP_URL:-}" \
      HMD_FAKE_CLAUDE=1 FAKE_CLAUDE_SH="$FAKE" FAKE_CLAUDE_LOG="$sd/claude.log" FAKE_CLAUDE_SCRIPT="$sd/script" FAKE_CLAUDE_FIFO="$sd/fifo" \
      FAKE_CLAUDE_TTY_FILE="$sd/tty" FAKE_CLAUDE_TERM=graceful FAKE_CLAUDE_STOP_HOOK="$STOP_CMD" CLAUDE_PLUGIN_ROOT="$sd/plugin" \
      HMD_RESTART_SESSIONS_DIR="$sd/home/.claude/sessions" HMD_RESTART_GATE_CMD="$T/fakes/gate.sh" HMD_CHECKPOINT_CMD="$T/fakes/checkpoint.sh" \
      HMD_RESTART_AGENTS_CMD="$T/fakes/agents.sh" HMD_RESTART_PS_CMD="$T/fakes/ps.sh" HMD_RESTART_TTY="$sd/tty" HMD_AGENT_TASKDIR="$sd/tasks" \
      HEIMDALL_CC_VERSIONS="$sd/versions" HMD_UPDATE_CC_PENDING_CMD="$T/fakes/ccpending.sh" \
      HMD_RESTART_POLL_S=1 HMD_RESTART_RECHECK_S=1 HMD_RESTART_TERM_WAIT_S=10 HMD_RESTART_SETTLE_S=1 HMD_RESTART_SESSION_MIN_AGE_S=0 HMD_RESTART_GAP_S=0 \
      BASH_ENV="$T/fakes/kill-wrap.sh" SC_KILLLOG="$sd/kill.log" SC_DIR="$sd" SC_PLUGIN="$sd/plugin" \
      ${SC_ENV[@]+"${SC_ENV[@]}"} \
      python3 -I "$T/e2e.py" pty 150 "$sd/out" "$sd/plugin/bin/heimdall" ${SC_ARGV[@]+"${SC_ARGV[@]}"} || rc=$?
    echo "$rc" > "$sd/rc"
    : > "$sd/done"
    wait "$wpid" 2>/dev/null
  ) &
}

# launch NAME KIND [SEED|MUTANT]: prepare the sandbox of the scenario KIND, apply the mutant when KIND is run for one, start it
launch() {
  local name="$1" kind="$2" extra="${3:-}" sd="$T/$1"
  throttle
  case "$kind" in
    seed) scn_seed "$sd" "$extra" ;;
    *) "scn_$kind" "$sd" ;;
  esac
  case "$extra" in
    M*) apply_mutant "$sd" "$extra" || { echo "bad" > "$sd/mutant-unapplied"; } ;;
  esac
  start_run "$sd"
}

# ---- the mutants must change what they say they change (a sed that matches nothing is a mutant that cannot fail)
if want mutants; then
  for m in M1 M2 M3 M4 M5 M6 M7 M8 M9 M10; do
    prep "$T/chk-$m" 2.4.1
    apply_mutant "$T/chk-$m" "$m"
    case $? in
      0) ok "0. mutant $m changes $(mut_row "$m" | cut -f1)" ;;
      1) bad "0. mutant $m matches nothing in $(mut_row "$m" | cut -f1): the list and the code have drifted" ;;
      *) bad "0. mutant $m has no usable row or its file is not in the sandbox" ;;
    esac
  done
fi

# ---- start everything (the long ones first)
want deferred && launch golden-deferred deferred
want journey && launch journey journey
want happy && launch golden-happy happy
want loopguard && launch golden-loopguard loopguard
want ignore && launch golden-ignore ignore
want print && launch golden-print print
if want mutants; then
  for m in M1 M2 M3 M5; do launch "mut-$m" deferred "$m"; done
  for m in M4 M6 M9; do launch "mut-$m" happy "$m"; done
  launch mut-M7 ignore M7
  launch mut-M8 print M8
  launch mut-M10 loopguard M10
fi
if want seeds; then
  n=1
  while [ "$n" -le "$SEEDS" ]; do
    launch "seed-$n" seed "$n"
    n=$((n + 1))
  done
fi
wait

# ------------------------------------------------------------------------------------------------------------------------------------------ the verdicts
count_in() { local n; n="$(grep -c "$1" "$2" 2>/dev/null)" || true; echo "${n:-0}"; }

trace_verdict() {   # trace_verdict SD TRACE QUIET: 0 when the run reproduces the oracle's trace and holds every invariant
  local sd="$1" rc=0
  python3 -I "$T/e2e.py" normalize "$sd"
  tr -d '\r' < "$sd/out" 2>/dev/null | grep -E '^\[heimdall\] (updated |resume failed)' > "$sd/out.sup" || true
  HMD_FAKE_CLAUDE=1 bash "$FAKE" --trace-diff "$2" "$sd/claude.norm.log" "$sd/out.sup" > "$sd/diff" 2>&1 || rc=1
  python3 -I "$T/e2e.py" check "$sd" "$3" strict > "$sd/check.out" 2>&1 || rc=1
  return $rc
}
ignore_verdict() {   # the session whose TERM is ignored is kept: one start, one TERM, no KILL, no line, the launcher's 0
  local sd="$1" rc=0
  python3 -I "$T/e2e.py" check "$sd" 3 ignore > "$sd/check.out" 2>&1 || rc=1
  [ "$(count_in '"signal":"TERM"' "$sd/claude.log")" = 1 ] || rc=1
  if grep -qE 'kill -(KILL|9)|kill -s (KILL|9)' "$sd/kill.log" 2>/dev/null; then rc=1; fi
  [ "$(cat "$sd/rc" 2>/dev/null)" = 0 ] || rc=1
  return $rc
}
print_verdict() {   # a -p task under a tty, with HMD_SUPERVISED=1 inherited: one -p start, nothing of the supervisor in claude's environment, no restart directory
  local sd="$1" rc=0 start
  start="$(grep '"event":"start"' "$sd/claude.log" | head -n 1)"
  [ "$(count_in '"event":"start"' "$sd/claude.log")" = 1 ] || rc=1
  printf '%s' "$start" | grep -q '"-p"' || rc=1
  if printf '%s' "$start" | grep -q '"HMD_LAUNCHER_PID"\|"HMD_RESTART_DIR"'; then rc=1; fi
  [ ! -e "$sd/home/.heimdall/restart" ] || rc=1
  [ "$(cat "$sd/rc" 2>/dev/null)" = 0 ] || rc=1
  return $rc
}
snip() { head -c 600 "$1" 2>/dev/null | tr '\n' ' '; }

if want journey; then
  D="$T/journey"
  J_EXPECT="[heimdall] updated claude 2.1.322->2.1.323, hmd 2.4.1->2.4.2 - resumed"
  python3 -I "$T/e2e.py" check "$D" 300 strict > "$D/check.out" 2>&1
  J_CHECK=$?
  J_LINES="$(tr -d '\r' < "$D/out" | grep -c '^\[heimdall\] updated ')"
  J_SECOND="$(grep '"event":"start"' "$D/claude.log" | sed -n 2p)"
  J_TERM="$(grep '"signal":"TERM"' "$D/claude.log" | sed -n 1p | sed -n 's/.*"ts":\([0-9]*\).*/\1/p')"
  J_KEY="$(grep '"event":"key"' "$D/claude.log" | tail -n 1 | sed -n 's/.*"ts":\([0-9]*\).*/\1/p')"
  J_SKEW="$(awk '$3 > 0 && $4 == "SAFE" { s = $3 } END { print s + 0 }' "$D/gate.log")"
  why=""
  [ "$J_CHECK" = 0 ] || why="$why invariants: $(tr '\n' ' ' < "$D/check.out");"
  [ "$(count_in '"event":"start"' "$D/claude.log")" = 2 ] || why="$why not exactly two starts;"
  [ "$(count_in '"signal":"TERM"' "$D/claude.log")" = 1 ] || why="$why not exactly one TERM;"
  [ "$J_LINES" = 1 ] && tr -d '\r' < "$D/out" | grep -qxF "$J_EXPECT" || why="$why the one line is not ($J_EXPECT) exactly once;"
  case "$J_SECOND" in *'"--resume","sid-J"'*'"resume":"sid-J"'*) ;; *) why="$why the relaunch does not resume sid-J: $J_SECOND;" ;; esac
  grep -q 'UNSAFE user-active' "$D/gate.log" || why="$why the typing operator was never deferred to;"
  [ -n "$J_TERM" ] && [ -n "$J_KEY" ] && [ "$J_SKEW" -ge 300 ] && [ $(( (J_TERM - J_KEY) / 1000 + J_SKEW )) -ge 300 ] || why="$why the TERM came inside the quiet window (skew $J_SKEW);"
  [ "$(cat "$D/rc" 2>/dev/null)" = 0 ] || why="$why the launcher's status is $(cat "$D/rc" 2>/dev/null);"
  if [ -z "$why" ]; then
    ok "journey: one TERM at the first quiet moment, the relaunch resumes sid-J, the one line printed once, the operator was deferred to first"
    JOURNEY_OK=1
  else
    bad "journey:$why" "out=[$(snip "$D/out")] gate=[$(awk '{ print $4 " " $5 }' "$D/gate.log" | sort | uniq -c | tr '\n' '|')]"
    JOURNEY_OK=0
  fi
fi

if want deferred; then
  if trace_verdict "$T/golden-deferred" "$TRACES/restart-deferred.trace" 8; then ok "golden: restart-deferred trace matches (the real launcher, hook and gate)"
  else bad "golden: restart-deferred trace differs" "$(sed -n '1,25p' "$T/golden-deferred/diff") $(cat "$T/golden-deferred/check.out")"; fi
fi
if want happy; then
  if trace_verdict "$T/golden-happy" "$TRACES/restart-happy.trace" 3; then ok "golden: restart-happy trace matches (the real launcher, hook and gate)"
  else bad "golden: restart-happy trace differs" "$(sed -n '1,25p' "$T/golden-happy/diff") $(cat "$T/golden-happy/check.out") out=[$(snip "$T/golden-happy/out")]"; fi
fi
if want loopguard; then
  if trace_verdict "$T/golden-loopguard" "$TRACES/restart-loop-guard.trace" 3; then ok "golden: restart-loop-guard trace matches (one restart per target version)"
  else bad "golden: restart-loop-guard trace differs" "$(sed -n '1,25p' "$T/golden-loopguard/diff") $(cat "$T/golden-loopguard/check.out")"; fi
fi
if want ignore; then
  if ignore_verdict "$T/golden-ignore"; then ok "term-ignored: session kept, no relaunch"
  else bad "term-ignored" "terms=$(count_in '"signal":"TERM"' "$T/golden-ignore/claude.log") rc=$(cat "$T/golden-ignore/rc" 2>/dev/null) $(cat "$T/golden-ignore/check.out")"; fi
fi
if want print; then
  if print_verdict "$T/golden-print"; then ok "print-mode: unsupervised (a -p task is never supervised, even with HMD_SUPERVISED=1 inherited)"
  else bad "print-mode" "start=[$(grep '"event":"start"' "$T/golden-print/claude.log" | head -n 1 | head -c 400)] out=[$(snip "$T/golden-print/out")]"; fi
fi

# ---- the seeds
if want seeds; then
  held=0
  seed_dirs=""
  n=1
  while [ "$n" -le "$SEEDS" ]; do
    D="$T/seed-$n"
    seed_dirs="$seed_dirs $D"
    if python3 -I "$T/e2e.py" check "$D" 300 strict > "$D/check.out" 2>&1; then
      held=$((held + 1))
    else
      bad "seed $n: an invariant does not hold" "$(head -c 500 "$D/check.out" | tr '\n' ' ') (script: $D/script, timeline: $D/timeline.json)"
    fi
    n=$((n + 1))
  done
  SUM="$(python3 -I "$T/e2e.py" summary $seed_dirs)"
  restarted="$(printf '%s' "$SUM" | sed -n 's/.*restarted=\([0-9]*\).*/\1/p')"
  deferred="$(printf '%s' "$SUM" | sed -n 's/.* deferred=\([0-9]*\).*/\1/p')"
  if [ "$SEEDS" -lt 20 ] || { [ "${restarted:-0}" -ge 5 ] && [ "${deferred:-0}" -ge 10 ]; }; then
    ok "seeds: the sweep is not vacuous ($SUM)"
  else
    bad "seeds: the sweep restarted ${restarted:-0} and deferred ${deferred:-0} of $SEEDS seeds, so its invariants prove too little" "$SUM"
  fi
  if [ "$held" = "$SEEDS" ]; then echo "seeds: $held/$SEEDS invariants hold"; ok "seeds: every seed held I1-I6"; else bad "seeds: only $held/$SEEDS hold their invariants"; fi
fi

# ---- the mutants
if want mutants; then
  red=0
  for m in M1 M2 M3 M4 M5 M6 M7 M8 M9 M10; do
    D="$T/mut-$m"
    if [ -e "$D/mutant-unapplied" ]; then bad "mutant $m was not applied, its run proves nothing"; continue; fi
    case "$(mut_kind "$m")" in
      deferred) if trace_verdict "$D" "$TRACES/restart-deferred.trace" 8; then v=green; else v=red; fi ;;
      happy) if trace_verdict "$D" "$TRACES/restart-happy.trace" 3; then v=green; else v=red; fi ;;
      loopguard) if trace_verdict "$D" "$TRACES/restart-loop-guard.trace" 3; then v=green; else v=red; fi ;;
      ignore) if ignore_verdict "$D"; then v=green; else v=red; fi ;;
      print) if print_verdict "$D"; then v=green; else v=red; fi ;;
    esac
    if [ "$v" = red ]; then red=$((red + 1)); ok "mutant $m ($(mut_row "$m" | cut -f1)): the $(mut_kind "$m") scenario goes RED"
    else bad "mutant $m SURVIVED the $(mut_kind "$m") scenario: nothing in this suite notices it"; fi
  done
  if [ "$red" = 10 ]; then echo "mutants: $red/10 red"; ok "mutants: score 1.0"; else bad "mutants: only $red/10 red"; fi
fi

# ---- the journey line the plan asks for, and the doc
if want journey && [ "${JOURNEY_OK:-0}" = 1 ]; then echo "journey: resumed same session id"; fi
if want doc || [ -z "${E2E_ONLY:-}" ]; then
  if grep -q 'HMD_AUTO_RESTART' "$DOC" 2>/dev/null && grep -q 'seamless' "$DOC" 2>/dev/null; then ok "doc: docs/seamless-restart.md names seamless and HMD_AUTO_RESTART"
  else bad "doc: docs/seamless-restart.md is missing or does not name seamless and HMD_AUTO_RESTART"; fi
  if grep -q '300' "$DOC" 2>/dev/null && grep -qi 'parked' "$DOC" 2>/dev/null && grep -q -- '--bg' "$DOC" 2>/dev/null && grep -qi 'on by default' "$DOC" 2>/dev/null; then
    ok "doc: the decided defaults are stated (on by default, 300 s, parked agents do not block, --bg out of scope)"
  else bad "doc: the decided defaults (on by default, 300 s, parked, --bg) are not all stated"; fi
fi

echo
echo "seamless-restart-e2e: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
