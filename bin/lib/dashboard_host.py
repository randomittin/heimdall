#!/usr/bin/env python3
"""dashboard_host.py -- keeps the custom-dashboards producer loop alive for ONE repo inside a long-running process.

The loop is `hmd dash run` (bin/lib/dashboard_producers.py): it serves the generation queue, expires unconfirmed proposals and
refreshes every confirmed tile. It should run exactly while `hmd app remote-dashboards` is on, and it should never be able to take the
process that hosts it down. So the host does not import it: it starts it as a CHILD PROCESS (argv list, no shell, the interpreter that
runs the host) and watches the host's own state for the one word that matters, `state.dashboards.enabled`.

    observe(state)   called by sentinels/hmd-ui.py's StateCache on every state it collects (the relay client builds one with
                     dash_host=True): enabled and no live child -> start one; not enabled and a live child -> SIGTERM it. Cheap,
                     never blocks, never raises.
    close()          the host is stopping: terminate the child (kill after a grace period) and reap it.

WHY A PROCESS AND NOT A THREAD. A producer run can sit in a database driver or a model call for up to two minutes, hold an engine's
credentials in its environment and spawn children of its own; a crash, a hang or a leak there must cost a restart of THIS child, never
a state frame of the phone's session. The relay client's process also never imports the module that can confirm a producer: nothing a
sealed command can reach has a path to `confirm_tile` (test/lib/dashboard_producers_battery.py pins that by text).

ONE LOOP PER REPO is the child's own flock (dash-pending/host.lock): a second relay client, or a `hmd dash run` typed by hand while the
client already runs one, starts a child that exits at once with status 3 and is retried 30 s later. The child is started with
`--parent <host pid>`, so it also ends when remote dashboards go off (the host starts it again when they come back) and when the host
dies without closing it -- an orphaned loop that nobody supervises is exactly what this repo does not want.

A child that exits is restarted with a doubling delay (5 s, 10 s, ... 5 min); a child that lived a minute resets the delay. Nothing it
writes (stderr: event names and ids, never a statement, a row or a setting) reaches the host's stdout, which is the relay client's
JSON event stream.

Stdlib only.
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
LOOP = os.path.join(HERE, "dashboard_producers.py")

RESTART_MIN_S = 5.0                # first restart delay after a child exits; doubles per quick exit
RESTART_MAX_S = 300.0
ALREADY_RUNNING_RETRY_S = 30.0     # another process owns this repo's loop (exit status 3): look again later
STABLE_S = 60.0                    # a child that lived this long resets the restart delay
STOP_GRACE_S = 5.0                 # SIGTERM, then SIGKILL when it is still there this long after
CLOSE_GRACE_S = 3.0                # the host's own shutdown waits at most this long for the child
EXIT_ALREADY_RUNNING = 3           # bin/lib/dashboard_producers.py: the loop of this repo is held by another process


def _default_emit(event):
    try:
        sys.stderr.write("dashboard_host: %s\n" % " ".join("%s=%s" % (k, str(v)[:80]) for k, v in sorted(event.items())))
    except Exception:
        return                      # a diagnostic is best effort: stderr is a file on the volume that may be the problem


class ProducerHost:
    """One per process and repo. `python`, `popen` and `clock` are injectable for tests; `environ` is what the child inherits
    (default: this process's own -- the connector passwords' environment-variable NAMES are looked up there, by the child)."""

    def __init__(self, root, python=None, popen=subprocess.Popen, clock=time.monotonic, emit=None, environ=None, loop=LOOP):
        self.root = root
        self._python = python or sys.executable
        self._popen = popen
        self._clock = clock
        self._emit = emit or _default_emit
        self._env = environ
        self._loop = loop
        self._proc = None
        self._started = 0.0
        self._term_at = None
        self._retry_at = 0.0
        self._failures = 0
        self._closed = False

    # -- the caller's side: cheap, never raises ----------------------------------------------------------------
    def observe(self, state):
        try:
            slice_ = state.get("dashboards") if isinstance(state, dict) else None
            wanted = isinstance(slice_, dict) and slice_.get("enabled") is True
            self._reap()
            if wanted:
                self._ensure()
            else:
                self._stop()
        except Exception as exc:
            self._emit({"event": "observe-failed", "error": type(exc).__name__})

    def running(self):
        return self._proc is not None and self._proc.poll() is None

    def close(self):
        """The host is stopping. Safe to call twice."""
        self._closed = True
        proc, self._proc = self._proc, None
        if proc is None or proc.poll() is not None:
            return
        try:
            proc.terminate()
            deadline = self._clock() + CLOSE_GRACE_S
            while proc.poll() is None and self._clock() < deadline:
                time.sleep(0.05)
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=2.0)
        except Exception as exc:
            self._emit({"event": "close-failed", "error": type(exc).__name__})

    # -- the machinery -----------------------------------------------------------------------------------------
    def _reap(self):
        """Notice a child that exited (and collect it): schedule its restart."""
        proc = self._proc
        if proc is None:
            return
        rc = proc.poll()
        now = self._clock()
        if rc is None:
            if self._term_at is not None and now - self._term_at > STOP_GRACE_S:
                proc.kill()
                self._term_at = now
            return
        stopped = self._term_at is not None
        self._proc, self._term_at = None, None
        if stopped:
            self._retry_at = 0.0                         # a stop we asked for is not a failure: start at the next `enabled`
            return
        lived = now - self._started
        self._failures = 0 if lived >= STABLE_S else self._failures + 1
        delay = ALREADY_RUNNING_RETRY_S if rc == EXIT_ALREADY_RUNNING else min(RESTART_MIN_S * 2 ** max(self._failures - 1, 0), RESTART_MAX_S)
        self._retry_at = now + delay
        self._emit({"event": "loop-exited", "status": rc, "retry_in_s": int(delay)})

    def _ensure(self):
        if self._closed or self._proc is not None or self._clock() < self._retry_at:
            return
        argv = [self._python, self._loop, "--repo", self.root, "run", "--parent", str(os.getpid())]
        self._proc = self._popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, env=self._env, close_fds=True)
        self._started = self._clock()
        self._term_at = None
        self._emit({"event": "loop-started", "pid": self._proc.pid})

    def _stop(self):
        proc = self._proc
        if proc is None or self._term_at is not None:
            return
        proc.terminate()
        self._term_at = self._clock()
        self._emit({"event": "loop-stopping", "pid": proc.pid})
