"""A hermetic sandbox for timing / fork-counting bin/heimdall-statusline.

WHY THIS EXISTS. The perf suites used to render the real captured Cursor fixture from a
temp workspace but with the fixture's OWN `cwd` (/Users/rj/Downloads/heimdall — the real
repo, on the machine it was captured on) and no HMD_AGENT_CWD. Two things followed, both
measured:

  * the wrapper's cached `heimdall-agents count` refresh and the watchman's presence refresh
    (`heimdall-presence roster`, repo_roster.py) fired against the REAL repo's .heimdall —
    73 harness transcripts / 31 MB for the count alone — as detached children that kept
    running through the timed renders, so a render's measured time included CPU burnt by
    its own previous render's background work (and, on the test's own cleanup, the child was
    still writing into the temp HOME while `rm -rf` ran: "Directory not empty");
  * every number depended on what else was alive on the box, which is exactly how a render
    that costs ~750 ms CPU measured 1004 ms at load 34 and 1802 ms + SIGALRM at load 76.

The sandbox makes the timed region closed:

  * private HOME / TMPDIR / HEIMDALL_HOME / HMD_STATUSLINE_TMP / HMD_AGENT_CWD / identity dir,
    and the payload's cwd, workspace.current_dir and workspace.project_dir rewritten to the
    private workspace — nothing the render derives from a path can reach a real directory;
  * every throttle that gates a background refresh is pre-seeded FRESH with an mtime an hour
    in the FUTURE (the gates are `now - mtime < TTL`, so a future mtime reads as "just
    written" for the whole run, however long a loaded box takes): the agents-count cache, the
    roster cache, the beat stamp and the wall lock. The render's stat-only "is it due?" checks
    still run — they are part of its real cost — but no child is ever forked. `refreshed()`
    proves it afterwards instead of assuming it.

Deliberately NOT neutralised: the foreground work a real render does (identity resolution
every 5 s, the interpreter launches, sigil/gauge rendering) — that is what is being measured.
"""
import json
import os
import shutil
import signal
import subprocess
import tempfile
import time

_THROTTLES = (
    (".beat-stamp", ""),
    (".roster-cache.json", "[]"),
    (".wall-cache.json.lock", ""),
    (".agents-count-cache", "0"),
)


class Sandbox:
    def __init__(self, fixture):
        self.base = tempfile.mkdtemp(prefix="statusline-sandbox-")
        self.ws = self.base + "/ws"
        self.home = self.base + "/home"
        self.tmp = self.base + "/tmp"
        os.makedirs(self.ws + "/.heimdall")
        os.makedirs(self.home + "/.heimdall")
        os.makedirs(self.tmp)
        with open(self.ws + "/.heimdall/identity.json", "w") as f:
            f.write('{"handle":"rj","seed":"rj","created":0}\n')
        with open(self.ws + "/.heimdall/statusline.json", "w") as f:
            f.write('{"verdict":"pass","passed":3,"total":3}\n')
        self._future = time.time() + 3600
        self._seed = {}
        for name, body in _THROTTLES:
            p = self.ws + "/.heimdall/" + name
            with open(p, "w") as f:
                f.write(body)
            os.utime(p, (self._future, self._future))
            self._seed[name] = (body, os.stat(p).st_mtime)
        with open(fixture) as f:
            cursor = json.load(f)
        cursor["cwd"] = self.ws
        cursor["workspace"]["current_dir"] = self.ws
        cursor["workspace"]["project_dir"] = self.ws
        self.cursor_blob = json.dumps(cursor).encode()
        # a Claude-Code-shaped payload carrying REAL context numbers: the shape that makes
        # `ctx-meter publish` do all of its field parsing (the Cursor fixture's are all null).
        self.claude_blob = json.dumps({
            "session_id": "perf-claude-1", "cwd": self.ws, "model": {"display_name": "Opus 4.8"},
            "workspace": {"current_dir": self.ws},
            "context_window": {"total_input_tokens": 42000, "used_percentage": 21,
                               "context_window_size": 200000},
            "cost": {"total_cost_usd": 1.5, "total_duration_ms": 120000},
        }).encode()

    def env(self, **extra):
        e = dict(PATH=os.environ["PATH"], HOME=self.home, TMPDIR=self.tmp, LANG="en_US.UTF-8",
                 TERM="xterm-256color", HEIMDALL_HOME=self.home + "/.heimdall",
                 HEIMDALL_IDENTITY_DIR=self.ws + "/.heimdall", HMD_HAID="rj", HMD_NOW="1752410000",
                 HEIMDALL_CP_URL="http://127.0.0.1:1", HMD_STATUSLINE_TMP=self.tmp,
                 HEIMDALL_STATUSLINE_MODE="truecolor", HMD_AGENT_CWD=self.ws)
        e.update(extra)   # COLUMNS is deliberately absent unless a caller adds it
        return e

    def render(self, cli, blob, alarm=None, **extra_env):
        """One render. -> (elapsed_ms, returncode, stdout). With `alarm`, the render runs under
        `perl alarm N; exec` (a hard SIGALRM kill, the stand-in for Cursor's timeoutMs: macOS
        ships no timeout(1)); a killed render has returncode -SIGALRM."""
        cmd = ["bash", cli]
        if alarm:
            cmd = ["perl", "-e", "alarm %d; exec @ARGV" % alarm, "--"] + cmd
        t0 = time.perf_counter()
        p = subprocess.run(cmd, input=blob, capture_output=True, env=self.env(**extra_env), cwd=self.ws)
        return (time.perf_counter() - t0) * 1000, p.returncode, p.stdout

    @staticmethod
    def killed(returncode):
        return returncode == -signal.SIGALRM

    def refreshed(self):
        """Names of the pre-seeded throttles a render touched (content or mtime changed) plus any
        lock / tmp file that appeared beside them — i.e. evidence a background refresh was
        launched inside the sandbox. [] means the timed region really was closed."""
        out = []
        d = self.ws + "/.heimdall"
        for name, (body, mtime) in self._seed.items():
            p = d + "/" + name
            try:
                if open(p).read() != body or os.stat(p).st_mtime != mtime:
                    out.append(name)
            except OSError:
                out.append(name)
        known = {n for n, _ in _THROTTLES} | {"identity.json", "statusline.json"}
        for n in sorted(os.listdir(d)):
            if n not in known:
                out.append(n)
        return out

    def close(self):
        shutil.rmtree(self.base, ignore_errors=True)
