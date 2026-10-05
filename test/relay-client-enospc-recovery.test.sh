#!/usr/bin/env bash
# test/relay-client-enospc-recovery.test.sh -- bin/heimdall-relay-client keeps sending state through a full disk
# (ENOSPC) and goes back to writing its logs, status and panels when space returns.
#
# THE BUG. `hmd app connect --relay --bg` runs the client with stdout and stderr redirected to temp files, and
# the client keeps its event log, status file and the panels it publishes on the same volume. When that volume
# filled up:
#   - emit() wrote stdout with no guard, so the OSError(ENOSPC) came out of whichever thread emitted -- the
#     state loop (whose own `except` handler emits too, so it died there), the stream thread, the connect
#     threads -- and the client stopped sending state for good;
#   - the event log latched itself off for the rest of the process ("never retried");
#   - sentinels/hmd-ui.py's StateCache poller and warmer threads report their failures with a bare
#     sys.stderr.write inside an `except` handler. stderr is a file on the same full disk, so the handler raised,
#     the thread ended, and the cache never refreshed again -- state silently frozen, space or no space.
#
# What is held here, each part a real module / real process, nothing mocked but the relay (test/lib/fake-relay.py)
# and the disk:
#   A. the client module, in-process: emit() never raises on a failing stdout and does not stay broken; the event
#      log is retried, not latched; a failing status write is reported once per outage, not once per frame;
#      every failure is reported at a bounded rate (one notice per outage, one when writes work again).
#   B. sentinels/hmd-ui.py, in-process: nothing a loop thread reports can raise out of it (poller pass, warmer,
#      live-users and companion panel publishers, push observer), and a repeating failure is logged at a bounded rate.
#   C. the REAL bin/heimdall-relay-client against the fake relay, run under a launcher that makes the disk "full"
#      while a flag file exists (every write to a regular file fails with ENOSPC: stdout, stderr, the event log,
#      the status file, panels, the inbox; reads, sockets and child processes are untouched): the client stays
#      alive and keeps sending state and acking commands during the outage, and after the disk "frees up" the
#      panel write that failed is retried and reaches the phone, the log / status / inbox writes resume, and the
#      poller, warmer and stream threads are still alive.
#
# Hermetic: HOME / HEIMDALL_HOME / TMPDIR / the Claude projects dir are redirected into one temp dir, the repo
# under test is a throwaway git repo, the relay is a loopback fake, every process started here is reaped on EXIT.
# Bounded waits only (no `timeout` on macOS). Never touches a running relay client: it starts its own.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "relay-client-enospc-recovery (heimdall-relay-client + hmd-ui.py state producer on a full disk)"

for f in "$REPO/sentinels/hmd-ui.py" "$REPO/bin/heimdall-relay-client" "$REPO/test/lib/fake-relay.py" \
         "$REPO/bin/lib/hmd_relay_e2e.py" "$REPO/bin/lib/companion_ui_panels.py"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
if ! command -v python3 >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  printf 'FATAL: python3 and git are required\n' >&2
  printf '\n0 passed, 1 failed\n'
  exit 1
fi

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# Run one python part; each line it prints is `ok <text>` or `bad <text>` (forwarded to the tally),
# anything else is shown indented. A part that dies before finishing is itself a failure.
run_part() {
  local label="$1" script="$2"; shift 2
  local out="$TMPROOT/$label.out" line saw_done=0
  python3 "$script" "$REPO" "$TMPROOT/$label" "$@" >"$out" 2>"$TMPROOT/$label.err"
  local rc=$?
  while IFS= read -r line; do
    case "$line" in
      "ok "*)   ok "${line#ok }" ;;
      "bad "*)  bad "${line#bad }" ;;
      "done")   saw_done=1 ;;
      *)        printf '       | %s\n' "$line" ;;
    esac
  done <"$out"
  if [ "$rc" -ne 0 ] || [ "$saw_done" -ne 1 ]; then
    bad "$label: part did not finish (rc=$rc): $(tail -n 6 "$TMPROOT/$label.err" | tr '\n' '|')"
  fi
}

# ── the full disk: a launcher that runs a script in-process with a flag-controlled ENOSPC ─────────────
cat >"$TMPROOT/faulty_launch.py" <<'PYEOF'
#!/usr/bin/env python3
"""Test-only launcher: run a script IN THIS PROCESS on a simulated full disk (ENOSPC).

usage: faulty_launch.py FLAG SCRIPT [script args...]

While the file FLAG exists the disk is "full": every write this process makes to a regular file fails with
OSError(ENOSPC) -- stdout and stderr (regular files, as `hmd app connect --relay` redirects them), open() /
os.fdopen() writes, os.write(), and the creation of a new file by open() / os.open(). Reads, sockets, pipes
and child processes are untouched. Removing FLAG is "space came back". The code under test imports nothing
from here: only the primitives it calls are wrapped. SIGUSR1 writes the live thread names to FLAG.threads."""
import builtins
import errno
import io
import os
import runpy
import signal
import stat
import sys
import threading

FLAG, SCRIPT = sys.argv[1], sys.argv[2]
sys.argv = [SCRIPT] + sys.argv[3:]

_open, _os_open, _fdopen, _os_write, _replace = builtins.open, os.open, os.fdopen, os.write, os.replace


def full():
    return os.path.exists(FLAG)


def enospc():
    return OSError(errno.ENOSPC, os.strerror(errno.ENOSPC))


def writes(mode):
    return any(c in mode for c in "wax+")


def creates(path):
    return isinstance(path, (str, bytes, os.PathLike)) and not os.path.exists(path)


class FullFile:
    """A file object opened for writing: its writes fail while the disk is full."""

    def __init__(self, f):
        self._f = f

    def write(self, data):
        if full():
            raise enospc()
        return self._f.write(data)

    def writelines(self, lines):
        if full():
            raise enospc()
        return self._f.writelines(lines)

    def flush(self):
        if full():
            raise enospc()
        return self._f.flush()

    def truncate(self, *args):
        if full():
            raise enospc()
        return self._f.truncate(*args)

    def __enter__(self):
        self._f.__enter__()
        return self

    def __exit__(self, *exc):
        return self._f.__exit__(*exc)

    def __iter__(self):
        return iter(self._f)

    def __getattr__(self, name):
        return getattr(self._f, name)


def open_(file, mode="r", *args, **kwargs):
    if writes(mode) and full() and creates(file):
        raise enospc()
    f = _open(file, mode, *args, **kwargs)
    return FullFile(f) if writes(mode) else f


def os_open(path, flags, *args, **kwargs):
    if flags & os.O_CREAT and full() and creates(path):
        raise enospc()
    return _os_open(path, flags, *args, **kwargs)


def fdopen(fd, mode="r", *args, **kwargs):
    f = _fdopen(fd, mode, *args, **kwargs)
    return FullFile(f) if writes(mode) else f


def os_write(fd, data):
    if full() and stat.S_ISREG(os.fstat(fd).st_mode):
        raise enospc()
    return _os_write(fd, data)


class FullRaw(io.RawIOBase):
    """The raw end of stdout / stderr: the real fd, failing while the disk is full."""

    def __init__(self, fd):
        self._fd = fd

    def writable(self):
        return True

    def fileno(self):
        return self._fd

    def write(self, data):
        if full():
            raise enospc()
        return _os_write(self._fd, data)


def dump_threads(_signum, _frame):
    path = FLAG + ".threads"
    with _open(path + ".tmp", "w") as f:
        f.write("\n".join(sorted(t.name for t in threading.enumerate())) + "\n")
    _replace(path + ".tmp", path)


builtins.open = open_
os.open = os_open
os.fdopen = fdopen
os.write = os_write
# the buffering CPython gives them: stdout block-buffered, stderr line-buffered and written through
sys.stdout = io.TextIOWrapper(io.BufferedWriter(FullRaw(1)), encoding="utf-8", errors="backslashreplace")
sys.stderr = io.TextIOWrapper(io.BufferedWriter(FullRaw(2)), encoding="utf-8", errors="backslashreplace",
                              line_buffering=True, write_through=True)
signal.signal(signal.SIGUSR1, dump_threads)
runpy.run_path(SCRIPT, run_name="__main__")
PYEOF

# ── A. the client's own output paths, in-process ──────────────────────────────────────────────────
cat >"$TMPROOT/part_a.py" <<'PYEOF'
import argparse
import errno
import json
import os
import sys
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

code, tmp = sys.argv[1], sys.argv[2]
os.makedirs(tmp)
real_out = sys.stdout


def verdict(passed, text):
    real_out.write(("ok " if passed else "bad ") + text + "\n")
    real_out.flush()


def enospc():
    return OSError(errno.ENOSPC, os.strerror(errno.ENOSPC))


class Sink:
    """A stdout / stderr stand-in whose disk can be full."""

    def __init__(self):
        self.full = False
        self.text = ""

    def write(self, s):
        if self.full:
            raise enospc()
        self.text += s
        return len(s)

    def flush(self):
        if self.full:
            raise enospc()


def events(sink):
    return [json.loads(line) for line in sink.text.splitlines() if line.startswith("{")]


log_path = os.path.join(tmp, "events.jsonl")
os.environ["HMD_RELAY_EVENT_LOG"] = log_path
loader = SourceFileLoader("hmd_relay_client_enospc", os.path.join(code, "bin", "heimdall-relay-client"))
spec = spec_from_loader(loader.name, loader)
mod = module_from_spec(spec)
loader.exec_module(mod)
mod.configure_event_log(tmp)
out, err = Sink(), Sink()
sys.stdout, sys.stderr = out, err


def logged(name):
    try:
        with open(log_path) as f:
            rows = [json.loads(line) for line in f.read().splitlines()]
    except OSError:
        return []
    return [r["seq"] for r in rows if r.get("event") == name]


# A1 -- stdout on a full disk: emit() must not raise (it runs on the state loop, the stream thread and the
# connect threads, and an exception out of it ended them), must work again the moment space returns, and must
# report the outage once, not once per dropped line.
out.full = True
raised = None
try:
    for i in range(5):
        mod.emit({"event": "state_sent", "seq": i})
except Exception as e:
    raised = e
out.full = False
mod.emit({"event": "state_sent", "seq": 99})
verdict(raised is None, "A1a: emit() does not raise while stdout is full (got %r)" % (raised,))
verdict(any(e.get("seq") == 99 for e in events(out)), "A1b: stdout lines flow again once space returns")
verdict(err.text.count("stdout write failed") == 1 and err.text.count("stdout writes recovered after 5 failed") == 1,
        "A1c: 5 failed stdout writes -> ONE failure notice and ONE recovery notice on stderr: %r" % err.text)

# A2 -- the event log on a full disk: the line is dropped, the client carries on, and the log is NOT latched off
# for the rest of the process -- the next emit after space returns appends again.
real_os_open = os.open
down = {"on": False}


def os_open(path, flags, *args, **kwargs):
    if down["on"] and path == log_path:
        raise enospc()
    return real_os_open(path, flags, *args, **kwargs)


os.open = os_open
err.text = ""
for i in range(2):
    mod.emit({"event": "log-probe", "seq": i})
down["on"] = True
raised = None
try:
    for i in range(10, 14):
        mod.emit({"event": "log-probe", "seq": i})
except Exception as e:
    raised = e
down["on"] = False
mod.emit({"event": "log-probe", "seq": 100})
os.open = real_os_open
verdict(raised is None, "A2a: emit() does not raise while the event log's disk is full (got %r)" % (raised,))
verdict(logged("log-probe") == [0, 1, 100],
        "A2b: the event log holds the lines before the outage and the first one after it (not latched off): %s"
        % logged("log-probe"))
verdict(err.text.count("event log write failed") == 1 and err.text.count("event log writes recovered after 4 failed") == 1,
        "A2c: 4 failed log writes -> ONE failure notice and ONE recovery notice on stderr: %r" % err.text)
verdict(mod._event_log_path == log_path, "A2d: the event log is still configured after the outage")

# A3 -- the status file: a failed write is bookkeeping (never fatal), reported ONCE per outage rather than once per
# state frame, and written again as soon as it can be.
args = argparse.Namespace(relay="http://127.0.0.1:9", repo=tmp, ui_port=0, public_host=None,
                          status_file=os.path.join(tmp, "relay.json"), tick_s=2.0)
client = mod.RelayClient(args)
real_atomic = mod._atomic_write_json
failing = {"on": True}


def atomic(path, obj):
    if failing["on"]:
        raise enospc()
    return real_atomic(path, obj)


mod._atomic_write_json = atomic
out.text = ""


def status_errors():
    return [e for e in events(out) if e.get("event") == "error" and "status write failed" in e.get("detail", "")]


for _ in range(4):
    client.write_status()
first_outage = len(status_errors())
failing["on"] = False
client.write_status()
written = os.path.exists(args.status_file)
failing["on"] = True
client.write_status()
client.write_status()
verdict(first_outage == 1, "A3a: 4 failed status writes -> ONE error event, not one per write (%d)" % first_outage)
verdict(written, "A3b: the status file is written again once space returns")
verdict(len(status_errors()) == 2, "A3c: a LATER outage is reported again -- once per outage, not once per process (%d)"
        % len(status_errors()))
print("done", file=real_out, flush=True)
PYEOF
run_part part_a "$TMPROOT/part_a.py"

# ── B. the state producer (sentinels/hmd-ui.py), in-process ──────────────────────────────────────────
cat >"$TMPROOT/part_b.py" <<'PYEOF'
import errno
import io
import os
import subprocess
import sys
import threading
import time
from importlib.util import module_from_spec, spec_from_file_location

code, tmp = sys.argv[1], sys.argv[2]
real_out, real_err = sys.stdout, sys.stderr


def verdict(passed, text):
    real_out.write(("ok " if passed else "bad ") + text + "\n")
    real_out.flush()


def enospc():
    return OSError(errno.ENOSPC, os.strerror(errno.ENOSPC))


def load(name, path):
    spec = spec_from_file_location(name, path)
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Full:
    """stderr on a full disk: every write raises."""

    def write(self, s):
        raise enospc()

    def flush(self):
        raise enospc()


def survives(fn):
    try:
        return fn(), None
    except BaseException as e:  # a loop thread must outlive ANY of them
        return None, e


home = os.path.join(tmp, "home")
os.makedirs(os.path.join(home, ".claude", "projects"))
os.environ.update(HOME=home, HEIMDALL_HOME=os.path.join(home, ".heimdall"), TMPDIR=tmp,
                  HMD_AGENT_PROJECTS_DIR=os.path.join(home, ".claude", "projects"))
root = os.path.realpath(os.path.join(tmp, "repo"))
os.makedirs(root)
subprocess.run(["git", "init", "-q", root], check=True)
ui = load("hmd_ui", os.path.join(code, "sentinels", "hmd-ui.py"))
transport = {"bind": "relay", "public_host": "relay", "trust_proxy": False, "port": 0}


def refresh_fails(*args, **kwargs):
    raise enospc()


def reset_limiter():
    """The diagnostics' rate limiter is process-wide state: each case starts from a clean one."""
    getattr(ui, "_warned_at", {}).clear()


# B1 -- a repeating failure is logged at a bounded rate: five failed poller passes, ONE line.
reset_limiter()
cap = io.StringIO()
sys.stderr = cap
cache = ui.StateCache(root, transport)
cache.refresh = refresh_fails
for _ in range(5):
    cache._pass(partial=True)
sys.stderr = real_err
verdict(cap.getvalue().count("refresh failed") == 1,
        "B1: 5 failed poller passes -> ONE stderr line (rate-limited): %r" % cap.getvalue())

# B2 -- the poller pass: a refresh that fails while stderr (a file on the same full disk) fails too must not
# raise out of the pass -- an exception here ended the poller thread for good.
reset_limiter()
sys.stderr = Full()
_, raised = survives(lambda: cache._pass(partial=True))
sys.stderr = real_err
verdict(raised is None, "B2: StateCache._pass survives a failed refresh whose diagnostic also hits ENOSPC (got %r)" % (raised,))

# B3 -- the live-users publisher: the panel write fails, so does the diagnostic; the previous value comes back
# (the write is retried on the next pass) and nothing is raised.
reset_limiter()
real_write_panel = ui.PANELS.write_panel
ui.PANELS.write_panel = refresh_fails
sys.stderr = Full()
answer, raised = survives(lambda: ui.publish_live_users(root, 3, None))
sys.stderr = real_err
ui.PANELS.write_panel = real_write_panel
verdict(raised is None and answer is None,
        "B3: publish_live_users on a full disk raises nothing and hands back `previous` for a retry (got %r, %r)"
        % (answer, raised))


class BrokenPublisher:
    def tick(self):
        raise enospc()


class BrokenMonitor:
    def observe(self, state):
        raise enospc()

    def close(self):
        raise enospc()


# B4 -- the companion panel publisher and the push observer, same shape.
reset_limiter()
sys.stderr = Full()
changed, raised_panels = survives(lambda: ui.publish_companion_panels(BrokenPublisher()))
_, raised_observe = survives(lambda: ui.observe_push(BrokenMonitor(), {}))
_, raised_close = survives(lambda: ui.close_push(BrokenMonitor()))
sys.stderr = real_err
verdict(raised_panels is None and changed is False,
        "B4a: publish_companion_panels on a full disk raises nothing and reports no change (got %r, %r)"
        % (changed, raised_panels))
verdict(raised_observe is None and raised_close is None,
        "B4b: observe_push / close_push on a full disk raise nothing (got %r, %r)" % (raised_observe, raised_close))

# B5 -- the warmer thread: failing slow collectors on a full disk must not end it (the poller's partial passes
# reuse what the warmer last refreshed, so a dead warmer freezes identity / ledger / gate for ever).
reset_limiter()
calls = []


def collect_probe(_root):
    calls.append(time.monotonic())
    raise enospc()


ui.SLOW_COLLECTORS = (collect_probe,)
ui.POLL_INTERVAL_S = 0.05
warm_cache = ui.StateCache(root, transport)
sys.stderr = Full()
warmer = threading.Thread(target=warm_cache._warm_loop, name="warm-probe", daemon=True)
warmer.start()
time.sleep(0.6)
alive, passes = warmer.is_alive(), len(calls)
warm_cache._stop.set()
warmer.join(2)
sys.stderr = real_err
verdict(alive and passes >= 3,
        "B5: the warmer thread survives failing collectors on a full disk (alive=%s after %d passes)" % (alive, passes))
print("done", file=real_out, flush=True)
PYEOF
run_part part_b "$TMPROOT/part_b.py"

# ── C. the real client against the fake relay, on a disk that fills up and frees again ───────────────
cat >"$TMPROOT/part_c.py" <<'PYEOF'
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid
from http.server import ThreadingHTTPServer
from importlib.util import module_from_spec, spec_from_file_location

code, tmp, launcher = sys.argv[1], sys.argv[2], sys.argv[3]


def verdict(passed, text):
    print(("ok " if passed else "bad ") + text, flush=True)


def load(name, path):
    spec = spec_from_file_location(name, path)
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def read_lines(path):
    try:
        with open(path) as f:
            return f.read().splitlines()
    except OSError:
        return []


def read_events(path):
    out = []
    for line in read_lines(path):
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


os.makedirs(tmp)
home, repo = os.path.join(tmp, "home"), os.path.join(tmp, "repo")
tmpd, log_dir, ctl_dir = os.path.join(tmp, "tmp"), os.path.join(tmp, "relaylog"), os.path.join(tmp, "relayctl")
for d in (home, repo, tmpd, log_dir, ctl_dir):
    os.makedirs(d)
subprocess.run(["git", "init", "-q", repo], check=True)
subprocess.run(["git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q",
                "--allow-empty", "-m", "fixture"], check=True)
repo = os.path.realpath(repo)
projects = os.path.join(home, ".claude", "projects")
os.makedirs(projects)

# the session transcript the chat panel is derived from, and the statusline's "no sub-agent is running" note
# (so the agents publisher makes no `heimdall-agents list` probe of its own)
pdir = os.path.join(projects, re.sub(r"[^A-Za-z0-9]", "-", repo))
os.makedirs(pdir)
transcript = os.path.join(pdir, str(uuid.uuid4()) + ".jsonl")
counts = os.path.join(repo, ".heimdall", ".agents-count-cache")
os.makedirs(os.path.dirname(counts))


def entry_line(text):
    e = {"type": "user", "uuid": str(uuid.uuid4()), "sessionId": "s", "cwd": repo, "entrypoint": "cli",
         "isSidechain": False, "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
         "message": {"role": "user", "content": text}}
    return (json.dumps(e) + "\n").encode("utf-8")


def append_chat(text):
    with open(transcript, "ab") as f:
        f.write(entry_line(text))
    os.utime(counts)


with open(transcript, "wb") as f:
    f.write(entry_line("seed turn one"))
with open(counts, "w") as f:
    f.write("0\n")

e2e = load("hmd_relay_e2e", os.path.join(code, "bin", "lib", "hmd_relay_e2e.py"))
fr = load("fake_relay", os.path.join(code, "test", "lib", "fake-relay.py"))
panels = load("companion_ui_panels", os.path.join(code, "bin", "lib", "companion_ui_panels.py"))
dev_priv, dev_pub = e2e.generate_keypair()
with open(os.path.join(ctl_dir, "bind-device"), "w") as f:
    f.write(e2e.pub_b64(dev_pub))

fr.STATE = fr.RelayState(log_dir, ctl_dir)
frames = []   # (arrival ns, raw body) of every state/ack frame the relay accepted
inner_log_frame = fr.STATE.log_frame


def log_frame(raw_body, name="frames.ndjson"):
    if name == "frames.ndjson":
        frames.append((time.time_ns(), bytes(raw_body)))
    inner_log_frame(raw_body, name)


fr.STATE.log_frame = log_frame
port = free_port()
httpd = ThreadingHTTPServer(("127.0.0.1", port), fr.Handler)
httpd.daemon_threads = True
threading.Thread(target=httpd.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True).start()

env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": home,
       "HEIMDALL_HOME": os.path.join(home, ".heimdall"), "TMPDIR": tmpd,
       "HMD_AGENT_PROJECTS_DIR": projects, "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1",
       "HMD_RELAY_BACKOFF_BASE_MS": "200"}
flag = os.path.join(tmp, "disk-full")
out_path, err_path = os.path.join(tmp, "client.out"), os.path.join(tmp, "client.err")
event_log = os.path.join(repo, ".heimdall", "app", "relay-events.jsonl")
status_path = os.path.join(repo, ".heimdall", "app", "relay.json")
inbox_path = os.path.join(repo, ".heimdall", "ui", "inbox.jsonl")
# stdout and stderr are regular files, exactly as `hmd app connect --relay` redirects them
out_f, err_f = open(out_path, "w"), open(err_path, "w")
client = subprocess.Popen([sys.executable, launcher, flag, os.path.join(code, "bin", "heimdall-relay-client"),
                           "--relay", "http://127.0.0.1:%d" % port, "--repo", repo, "--ui-port", "0"],
                          stdout=out_f, stderr=err_f, env=env, cwd=tmp)

key = None
session_id = None
opened = {}   # frame index -> (type, seq, plaintext object)


def alive():
    return client.poll() is None


def wait_until(pred, secs, step=0.02):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if pred():
            return True
        if not alive():
            return False
        time.sleep(step)
    return bool(pred())


def frame(index):
    if index not in opened:
        env_ = json.loads(frames[index][1])
        text = e2e.open_(key, env_["seq"], "hmd", env_["nonce"], env_["ciphertext"]).decode("utf-8")
        opened[index] = (env_["type"], env_["seq"], json.loads(text))
    return opened[index]


def state_panel(index, pid):
    kind, _, body = frame(index)
    if kind != "state":
        return None
    for p in body["state"].get("panels") or []:
        if p.get("id") == pid:
            return p
    return None


def probe_is(value):
    return lambda i: (state_panel(i, "probe") or {}).get("data", {}).get("value") == value


def chat_has(marker):
    return lambda i: any(marker in ln for ln in (state_panel(i, "chat") or {}).get("data", {}).get("lines", []))


def first_frame(pred, start):
    for i in range(start, len(frames)):
        if pred(i):
            return i
    return None


def wait_frame(pred, start, secs):
    hit = []

    def found():
        hit[:] = [first_frame(pred, start)]
        return hit[0] is not None

    return hit[0] if wait_until(found, secs) else None


def put(value):
    panels.write_panel(repo, "probe", {"id": "probe", "title": "probe", "type": "number",
                                       "data": {"value": value, "format": "count"},
                                       "refresh_s": 30, "updated_at": time.time()})
    os.utime(counts)


cmd_seq = [0]


def send_command(text):
    """The paired phone's sealed `send-message` command, pushed down the stream by the fake relay."""
    cmd_seq[0] += 1
    n = cmd_seq[0]
    plain = json.dumps({"action": "send-message", "params": {"text": text}}).encode("utf-8")
    nonce, ciphertext = e2e.seal(key, n, "device", plain)
    envelope = {"v": 1, "session_id": session_id, "seq": n, "sender": "device", "type": "command",
                "nonce": nonce, "ciphertext": ciphertext, "payload": None}
    staging = os.path.join(ctl_dir, ".cmd-%d.tmp" % n)
    with open(staging, "w") as f:
        json.dump(envelope, f)
    os.replace(staging, os.path.join(ctl_dir, "%03d.json" % (100 + n)))
    return n


def ack_for(of_seq):
    return lambda i: frame(i)[0] == "ack" and frame(i)[2].get("of_seq") == of_seq


def settle(quiet=1.5, limit=60.0):
    end = time.monotonic() + limit
    seen, since = len(frames), time.monotonic()
    while time.monotonic() < end:
        time.sleep(0.05)
        if len(frames) != seen:
            seen, since = len(frames), time.monotonic()
        elif time.monotonic() - since >= quiet:
            return


def thread_names():
    path = flag + ".threads"
    if os.path.exists(path):
        os.remove(path)
    os.kill(client.pid, signal.SIGUSR1)
    if not wait_until(lambda: os.path.exists(path), 5):
        return []
    with open(path) as f:
        return f.read().split()


def why():
    return "client %s; stderr tail: %s" % ("alive" if alive() else "EXITED rc=%s" % client.returncode,
                                           " | ".join(read_lines(err_path)[-3:]))


try:
    if not wait_until(lambda: any(o.get("event") == "pair_init" for o in read_events(out_path)), 30):
        raise SystemExit("client never emitted pair_init: %s" % why())
    pair = next(o for o in read_events(out_path) if o.get("event") == "pair_init")
    session_id = pair["qr"]["session_id"]
    key = e2e.derive_session_key(dev_priv, e2e.pub_from_b64(pair["qr"]["hmd_pubkey"]), session_id)
    if not wait_until(lambda: frames, 60, 0.05):
        raise SystemExit("no first state frame within 60 s: %s" % why())
    settle()

    # C1 -- a change reaches the phone, and so does a transcript line (the chat panel is published)
    mark = len(frames)
    put(1)
    base_chat = "CHAT-BASE-" + uuid.uuid4().hex[:6]
    append_chat("hello " + base_chat)
    verdict(wait_frame(probe_is(1), mark, 10) is not None and wait_frame(chat_has(base_chat), mark, 10) is not None,
            "C1: on a healthy disk a panel change and a transcript line both reach the phone (%s)" % why())
    settle()

    # ── the disk fills up ──
    open(flag, "w").close()
    outage_chat = "CHAT-OUTAGE-" + uuid.uuid4().hex[:6]
    append_chat("hello " + outage_chat)   # the poller tries to publish the chat panel: ENOSPC
    time.sleep(0.5)
    mark = len(frames)
    put(2)
    verdict(wait_frame(probe_is(2), mark, 10) is not None,
            "C2: DURING the outage a state change still reaches the phone (sending does not depend on the disk): %s" % why())
    first = send_command("during-outage")
    hit = wait_frame(ack_for(first), 0, 10)
    ack = frame(hit)[2] if hit is not None else None
    verdict(ack is not None and ack.get("ok") is False and ack.get("detail") == "write-failed",
            "C3: DURING the outage a phone command is still acked (stream thread alive), as write-failed: %s (%s)"
            % (ack, why()))
    time.sleep(2.5)   # at least one backstop pass of the poller, failing again
    verdict(alive(), "C4: the client is still running after the outage: %s" % why())

    # ── space returns ──
    os.remove(flag)
    mark = len(frames)
    verdict(wait_frame(chat_has(outage_chat), mark, 12) is not None,
            "C5: the chat panel write that failed is RETRIED and the line written during the outage reaches the phone")
    mark = len(frames)
    put(3)
    sent = wait_frame(probe_is(3), mark, 10)
    verdict(sent is not None, "C6: a state change after the outage reaches the phone: %s" % why())
    sent_seq = frame(sent)[1] if sent is not None else None
    second = send_command("after-recovery")
    hit = wait_frame(ack_for(second), 0, 10)
    ack = frame(hit)[2] if hit is not None else None
    verdict(ack is not None and ack.get("ok") is True, "C7: a phone command after the outage is acked ok: %s" % (ack,))
    verdict(wait_until(lambda: "after-recovery" in "\n".join(read_lines(inbox_path)), 5),
            "C8: ...and its message landed in the inbox (writes resumed)")
    if sent_seq is not None:
        verdict(wait_until(lambda: any(e.get("event") == "state_sent" and e.get("seq", -1) >= sent_seq
                                       for e in read_events(event_log)), 6),
                "C9: the event log is appending again (state_sent seq >= %s) -- not latched off" % sent_seq)
        verdict(wait_until(lambda: any(e.get("event") == "state_sent" and e.get("seq", -1) >= sent_seq
                                       for e in read_events(out_path)), 6),
                "C10: stdout is flowing again (state_sent seq >= %s)" % sent_seq)

        def status_current():
            try:
                with open(status_path) as f:
                    return json.load(f).get("last_seq", 0) >= sent_seq
            except (OSError, ValueError):
                return False

        verdict(wait_until(status_current, 6),
                "C11: the status file (relay.json) is written again, last_seq >= %s" % sent_seq)
    else:
        for n in (9, 10, 11):
            verdict(False, "C%d: skipped, no post-outage frame was ever sent" % n)
    names = thread_names()
    missing = [t for t in ("hmd-ui-poller", "hmd-ui-warm", "relay-stream") if t not in names]
    verdict(not missing,
            "C12: the poller, warmer and stream threads are all still alive (missing %s of %s)" % (missing, names))
    err_text = "\n".join(read_lines(err_path))
    verdict(err_text.count("stdout writes recovered after") == 1 and err_text.count("event log writes recovered after") == 1,
            "C13: the outage is reported once per sink, when writes work again -- not once per dropped line: %r"
            % err_text[-400:])
finally:
    if os.path.exists(flag):
        os.remove(flag)
    if client.poll() is None:
        client.terminate()
        try:
            client.wait(timeout=20)
        except subprocess.TimeoutExpired:
            client.kill()
    out_f.close()
    err_f.close()
    httpd.shutdown()
print("done", flush=True)
PYEOF
run_part part_c "$TMPROOT/part_c.py" "$TMPROOT/faulty_launch.py"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
