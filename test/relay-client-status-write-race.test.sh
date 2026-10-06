#!/usr/bin/env bash
# test/relay-client-status-write-race.test.sh -- the relay client's status file (relay.json) survives concurrent writers.
#
# THE BUG. bin/heimdall-relay-client's _atomic_write_json staged every write in ONE temp file per process
# (`relay.json.tmp-<pid>`), and write_status() runs on several threads at once: the state loop on every tick, the
# stream thread on every command, the connect threads. Two overlapping writes shared that one temp file -- the first
# os.replace() renamed it away, and the second writer's chmod / replace / cleanup-unlink then hit ENOENT, an OSError
# that write_status() reports as an `error` event "status write failed: [Errno 2] ...". Measured before the fix: 617
# such events in 4 s with 4 threads. The two writers also shared one inode, so a torn file could be published.
#
# What is held here, in-process against the REAL module (nothing mocked; the only injected fault is the one in A4):
#   A1. _atomic_write_json hammered by 4 threads on ONE path for N seconds: zero exceptions, and a reader polling
#       the file the whole time never sees anything but one whole writer's document.
#   A2. RelayClient.write_status() hammered by 4 threads for N seconds: zero `status write failed` events, the file
#       always whole JSON and never vanishing, and the file never goes BACKWARDS (an older snapshot landing after a
#       newer one -- the status lock orders snapshot + write).
#   A3. nothing is left behind: no stray temp files, relay.json 0600, its directory 0700.
#   A4. a write that fails (os.replace -> ENOSPC) raises that same error to the caller, leaves no temp file, and
#       leaves the previous status intact.
#   B1-B5. the same hazard in the sibling writers the relay client and hmd-ui run on their own threads (one temp name
#       per process: ENOENT, or a torn file, when two threads write one path) --
#       companion_ui_controls._write_stop, companion_cc_login.write_config and LoginSession._write_pid_file,
#       companion_remote_switches._write_json_atomic, cp_state.LocalBackend.put_record -- each hammered by 4 threads on
#       ONE path for N/2 seconds: zero failures, the file always one writer's whole document, no temp file left.
# N is RELAY_STATUS_RACE_SECONDS (default 3).
#
# Hermetic: everything lives in one temp dir removed on EXIT. Never touches a running relay client.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "relay-client-status-write-race (heimdall-relay-client status writes from concurrent threads)"

if [ ! -e "$REPO/bin/heimdall-relay-client" ]; then
  printf 'FATAL: required file missing: %s\n' "$REPO/bin/heimdall-relay-client" >&2
  printf '\n0 passed, 1 failed\n'
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'FATAL: python3 is required\n' >&2
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

# ── shared by every part: thread hammer + whole-file reader ───────────────────────────────────────────
cat >"$TMPROOT/race_lib.py" <<'PYEOF'
import json
import threading
import time


def hammer(work, n_threads, secs):
    """Run work(i) in a loop on n_threads threads for `secs` seconds, all released together.
    Returns (calls per thread, every exception any call raised)."""
    stop_at = time.monotonic() + secs
    calls, errors = [0] * n_threads, []
    start = threading.Barrier(n_threads)

    def run(i):
        start.wait()
        while time.monotonic() < stop_at:
            try:
                work(i)
            except BaseException as e:  # a write that raises is a failure to count, not to abort the run
                errors.append(e)
            calls[i] += 1

    threads = [threading.Thread(target=run, args=(i,), name="hammer-%d" % i) for i in range(n_threads)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return calls, errors


class Reader(threading.Thread):
    """Polls `path` in a tight loop until stop(): every read must be one whole JSON document (`check(doc)` returns
    an error string for a document that is not one writer's whole output, else None), and once the file has
    appeared it must never vanish."""

    def __init__(self, path, check):
        super().__init__(name="reader", daemon=True)
        self.path, self.check = path, check
        self._running = threading.Event()
        self._running.set()
        self.reads, self.vanished, self.bad = 0, 0, []

    def stop(self):
        self._running.clear()
        self.join(10)

    def run(self):
        while self._running.is_set():
            try:
                with open(self.path, "rb") as f:
                    raw = f.read()
            except FileNotFoundError:
                if self.reads:
                    self.vanished += 1
                continue
            try:
                doc = json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError) as e:
                self.bad.append("unparseable (%d bytes): %s" % (len(raw), e))
                self.reads += 1
                continue
            problem = self.check(doc)
            if problem:
                self.bad.append(problem)
            self.reads += 1
PYEOF

# ── A. the client's status writes, in-process ─────────────────────────────────────────────────────────
cat >"$TMPROOT/part_a.py" <<'PYEOF'
import argparse
import errno
import json
import os
import sys
import threading
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

code, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from race_lib import Reader, hammer  # noqa: E402

os.makedirs(tmp)
real_out = sys.stdout
SECONDS = float(os.environ.get("RELAY_STATUS_RACE_SECONDS", "3"))
WRITERS = 4


def verdict(passed, text):
    real_out.write(("ok " if passed else "bad ") + text + "\n")
    real_out.flush()


class Sink:
    """The client's stdout: every emit() line lands here."""

    def __init__(self):
        self.lines = []

    def write(self, s):
        self.lines.append(s)
        return len(s)

    def flush(self):
        return None


def events(sink):
    return [json.loads(line) for line in list(sink.lines) if line.startswith("{")]


os.environ["HMD_RELAY_EVENT_LOG"] = os.path.join(tmp, "events.jsonl")
loader = SourceFileLoader("hmd_relay_client_status_race", os.path.join(code, "bin", "heimdall-relay-client"))
spec = spec_from_loader(loader.name, loader)
mod = module_from_spec(spec)
loader.exec_module(mod)
mod.configure_event_log(tmp)
out = Sink()
sys.stdout = out

# A1 -- the module-level writer, straight from several threads onto ONE path. Each writer's document is a
# different length, so two writers' bytes mixed into one inode cannot go unnoticed.
direct_dir = os.path.join(tmp, "direct")
direct_path = os.path.join(direct_dir, "relay.json")


def direct_doc_problem(doc):
    if not isinstance(doc, dict) or "writer" not in doc or len(doc.get("pad", "")) != doc["writer"] * 400:
        return "document is not one writer's whole output: %.80r" % (doc,)
    return None


reader = Reader(direct_path, direct_doc_problem)
reader.start()
calls, errors = hammer(lambda i: mod._atomic_write_json(direct_path, {"writer": i, "pad": "x" * (i * 400)}),
                       WRITERS, SECONDS)
reader.stop()
verdict(not errors and sum(calls) >= 20 and all(calls),
        "A1a: %d threads x %.0fs on _atomic_write_json -> %d writes (per thread %s), zero exceptions (got %d, first %r)"
        % (WRITERS, SECONDS, sum(calls), calls, len(errors), errors[:1]))
verdict(reader.reads > 0 and not reader.bad and not reader.vanished,
        "A1b: the polling reader saw %d whole documents, never a torn or missing file (bad %d: %s, vanished %d)"
        % (reader.reads, len(reader.bad), reader.bad[:1], reader.vanished))

# A2 -- the real thing: RelayClient.write_status() from several threads. frames_sent only ever grows (the bump is
# under a lock of the test's own), so a snapshot taken later is never smaller than one taken earlier -- the file
# must therefore never go backwards.
status_path = os.path.join(tmp, "status", "relay.json")
args = argparse.Namespace(relay="http://127.0.0.1:9", repo=tmp, ui_port=0, public_host=None,
                          status_file=status_path, tick_s=2.0)
client = mod.RelayClient(args)
bump = threading.Lock()
seen = {"last": -1, "regressions": 0}


def status_problem(doc):
    if not isinstance(doc, dict) or doc.get("pid") != os.getpid() or not isinstance(doc.get("frames_sent"), int):
        return "not a status snapshot: %.80r" % (doc,)
    if doc["frames_sent"] < seen["last"]:
        seen["regressions"] += 1
        return "status went backwards: frames_sent %d after %d" % (doc["frames_sent"], seen["last"])
    seen["last"] = doc["frames_sent"]
    return None


def status_write(_i):
    with bump:
        client.frames_sent += 1
    client.write_status()


out.lines.clear()
reader = Reader(status_path, status_problem)
reader.start()
calls, errors = hammer(status_write, WRITERS, SECONDS)
reader.stop()
failed = [e for e in events(out) if e.get("event") == "error" and "status write failed" in e.get("detail", "")]
verdict(not failed and not errors and sum(calls) >= 20 and all(calls),
        "A2a: %d threads x %.0fs on write_status -> %d calls (per thread %s), zero `status write failed` events "
        "(got %d, first %r) and zero exceptions (%d)"
        % (WRITERS, SECONDS, sum(calls), calls, len(failed), failed[:1], len(errors)))
verdict(reader.reads > 0 and not reader.vanished and not [b for b in reader.bad if "backwards" not in b],
        "A2b: the polling reader saw %d whole snapshots, never a torn or missing file (bad %s, vanished %d)"
        % (reader.reads, [b for b in reader.bad if "backwards" not in b][:1], reader.vanished))
verdict(seen["regressions"] == 0,
        "A2c: the status file never goes backwards -- an older snapshot never lands after a newer one (%d regressions)"
        % seen["regressions"])
with open(status_path) as f:
    final = json.load(f)
verdict(final["frames_sent"] == client.frames_sent,
        "A2d: once the writers stop the file holds the latest snapshot (frames_sent %s of %s)"
        % (final["frames_sent"], client.frames_sent))

# A3 -- nothing left behind, and the permissions the status file has always had.
leftovers = [n for d in (direct_dir, os.path.dirname(status_path)) for n in os.listdir(d) if n != "relay.json"]
verdict(not leftovers, "A3a: no temp file is left behind after %d writes (found %s)" % (sum(calls), leftovers[:3]))
file_mode = os.stat(status_path).st_mode & 0o777
dir_mode = os.stat(os.path.dirname(status_path)).st_mode & 0o777
verdict(file_mode == 0o600 and dir_mode == 0o700,
        "A3b: relay.json is 0600 and its directory 0700 (got %o and %o)" % (file_mode, dir_mode))

# A4 -- a write that fails: the caller gets the real error, no temp file survives, the previous status is intact.
before = open(status_path, "rb").read()
real_replace = os.replace


def replace_fails(src, dst, *a, **kw):
    raise OSError(errno.ENOSPC, os.strerror(errno.ENOSPC))


os.replace = replace_fails
raised = None
try:
    mod._atomic_write_json(status_path, {"would": "overwrite"})
except Exception as e:
    raised = e
finally:
    os.replace = real_replace
verdict(isinstance(raised, OSError) and raised.errno == errno.ENOSPC,
        "A4a: a failed replace raises that very error to the caller (got %r)" % (raised,))
leftovers = [n for n in os.listdir(os.path.dirname(status_path)) if n != "relay.json"]
verdict(not leftovers, "A4b: the failed write leaves no temp file behind (found %s)" % leftovers[:3])
verdict(open(status_path, "rb").read() == before, "A4c: the previous status is untouched by the failed write")

print("done", file=real_out, flush=True)
PYEOF
run_part part_a "$TMPROOT/part_a.py"

# ── B. the sibling writers, in-process ────────────────────────────────────────────────────────────────
cat >"$TMPROOT/part_b.py" <<'PYEOF'
import os
import sys
import types
from importlib.util import module_from_spec, spec_from_file_location

code, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from race_lib import Reader, hammer  # noqa: E402

os.makedirs(tmp)
tmp = os.path.realpath(tmp)
real_out = sys.stdout
SECONDS = max(1.0, float(os.environ.get("RELAY_STATUS_RACE_SECONDS", "3")) / 2)
WRITERS = 4
lib = os.path.join(code, "bin", "lib")
sys.path.insert(0, lib)   # cp_state imports its sibling issue_queue by name


def verdict(passed, text):
    real_out.write(("ok " if passed else "bad ") + text + "\n")
    real_out.flush()


def load(name, filename):
    spec = spec_from_file_location(name, os.path.join(lib, filename))
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def padded(doc):
    """Each writer's document is a different length (`pad` is writer * 400 bytes), so two writers' bytes mixed
    into one inode cannot pass for a whole document."""
    if isinstance(doc, dict) and len(doc.get("pad", "")) == doc.get("writer", -1) * 400:
        return None
    return "document is not one writer's whole output: %.80r" % (doc,)


def run_case(label, path, write, check):
    """WRITERS threads call write(i) on ONE path for SECONDS while a reader polls it."""
    reader = Reader(path, check)
    reader.start()
    calls, errors = hammer(write, WRITERS, SECONDS)
    reader.stop()
    leftovers = [n for n in os.listdir(os.path.dirname(path)) if n != os.path.basename(path)]
    verdict(not errors and sum(calls) >= 20 and all(calls) and reader.reads > 0 and not reader.bad
            and not reader.vanished and not leftovers,
            "%s: %d threads x %.1fs -> %d writes, zero failures (got %d, first %r); the reader saw %d whole "
            "documents (bad %s, vanished %d); temp files left: %s"
            % (label, WRITERS, SECONDS, sum(calls), len(errors), errors[:1], reader.reads, reader.bad[:1],
               reader.vanished, leftovers[:3]))


# B1 -- a stop request: two UI clicks, or the laptop and a phone, handled on two threads of one process.
controls = load("companion_ui_controls_race", "companion_ui_controls.py")
ctl_root = os.path.join(tmp, "ctl")
os.makedirs(ctl_root)
run_case("B1 companion_ui_controls._write_stop", controls._stop_path(ctl_root),
         lambda i: controls._write_stop(ctl_root, {"id": "s-%08x" % i, "requested_at": 1.0, "writer": i,
                                                    "pad": "x" * (i * 400)}),
         padded)

# B2, B3 -- the remote-login config (written by the verifying session's thread) and the live login's pid file.
login = load("companion_cc_login_race", "companion_cc_login.py")
login_home = os.path.join(tmp, "login-home")


def config_problem(doc):
    whole = isinstance(doc, dict) and doc.get("enabled") == (doc.get("pin") is not None) == doc.get("pin_next")
    return None if whole else "not one writer's whole config: %.80r" % (doc,)


run_case("B2 companion_cc_login.write_config", os.path.join(login_home, login.CONFIG_FILE),
         lambda i: login.write_config(login_home, bool(i % 2), pin=("ab" * 32) if i % 2 else None,
                                      pin_next=bool(i % 2)),
         config_problem)

pid_home = os.path.join(tmp, "login-pid-home")
os.makedirs(pid_home)


def write_pid_file(i):
    session = types.SimpleNamespace(mgr=types.SimpleNamespace(home=pid_home),
                                    proc=types.SimpleNamespace(pid=10 ** i), created=1.0)
    login.LoginSession._write_pid_file(session)


run_case("B3 companion_cc_login.LoginSession._write_pid_file", os.path.join(pid_home, login.PID_FILE), write_pid_file,
         lambda doc: None if isinstance(doc, dict) and doc.get("pid") in (1, 10, 100, 1000) and doc.get("started_at") == 1
         else "not one writer's whole pid record: %.80r" % (doc,))

# B4 -- a remote switch / allowlist, set from a controls command on whichever thread dispatches it.
switches = load("companion_remote_switches_race", "companion_remote_switches.py")
switch_path = os.path.join(tmp, "switches", "switch.json")
run_case("B4 companion_remote_switches._write_json_atomic", switch_path,
         lambda i: switches._write_json_atomic(switch_path, {"writer": i, "pad": "x" * (i * 400)}), padded)

# B5 -- the control plane's file backend: put_record answers False on an OSError, which is a lost write.
cp_state = load("cp_state_race", "cp_state.py")
backend = cp_state.LocalBackend(home=os.path.join(tmp, "cp-home"))


def put_record(i):
    if not backend.put_record("race/record.json", {"writer": i, "pad": "x" * (i * 400)}):
        raise OSError("put_record answered False: the write was lost")


run_case("B5 cp_state.LocalBackend.put_record", backend.path("race/record.json"), put_record, padded)

print("done", file=real_out, flush=True)
PYEOF
run_part part_b "$TMPROOT/part_b.py"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
