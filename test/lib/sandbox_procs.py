#!/usr/bin/env python3
"""test/lib/sandbox_procs.py -- end what a test sandbox left running, without `hmd app disconnect`.

A scenario of the pair-code suites is over when its own checks are: what is still running -- a detached relay client, a pair window's
supervisor, the ui, a `connect --bg` watcher -- belongs to its sandbox and to nobody else, and every one of those carries the sandbox's private
temp directory (a name no other run has) in its command line, as the repo it serves. `hmd app disconnect` ended them at the price of a bash
script of four thousand lines and a python start per helper: seconds a scenario, on a loaded machine many, and a call into the real tailscale CLI
when the sandbox has no state of its own. The clean-up asserts nothing, so a scenario that does not test disconnect finds them by that name and
kills them.

Only pids whose command line names the sandbox are ever signalled -- never anything by a bare name -- and never this process or the `ps` that looks.
Stdlib only.
"""
import os
import signal
import subprocess


def sandbox_pids(root):
    """The pids of the live processes (zombies are not) whose command line names the directory `root`."""
    token = os.path.basename(os.path.normpath(root))
    out = subprocess.run(["ps", "-axww", "-o", "pid=,stat=,command="], capture_output=True, text=True).stdout
    pids = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and not parts[1].startswith("Z") and token in parts[2] \
                and int(parts[0]) != os.getpid() and not parts[2].startswith("ps "):
            pids.append(int(parts[0]))
    return pids


def kill_sandbox(root):
    """SIGKILL every process that names the sandbox `root`."""
    for pid in sandbox_pids(root):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            continue  # gone already
