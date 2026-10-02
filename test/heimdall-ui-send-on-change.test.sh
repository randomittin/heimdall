#!/usr/bin/env bash
# test/heimdall-ui-send-on-change.test.sh -- the session -> phone leg is event-driven.
#
# docs/HANDOFF-TO-HEIMDALL-zero-lag-sync.md Ask 1 (hmdapp repo, read-only input): detect lag used
# to be the SUM of two uncoordinated 2 s timers -- sentinels/hmd-ui.py's StateCache poller
# (POLL_INTERVAL_S) and bin/heimdall-relay-client's state tick (--tick-s) -- measured 1.0 s p50 /
# 2.7 s p95 / 5.2 s max from a transcript append to the frame landing on a fake relay. The fix under
# test:
#   producer  StateCache.run stats the sources that feed collect_state every WATCH_INTERVAL_S and
#             re-collects the moment one moves (rate-limited to REFRESH_MIN_GAP_S); POLL_INTERVAL_S
#             stays as the BACKSTOP for everything that is not a watched file.
#   consumer  RelayClient.run_state_loop blocks on StateCache.wait_for_change, lets a burst settle
#             for STATE_DEBOUNCE_S (never longer than STATE_DEBOUNCE_MAX_S), then sends ONE frame;
#             --tick-s is only the longest it ever waits.
#
# Three independent parts, each a real process / real module -- nothing about the code under test
# is mocked except the Cloudflare relay (test/lib/fake-relay.py) and, in part C, the cache object
# the debounce loop is handed:
#   A. in-process StateCache: change -> digest <= 500 ms (a panel write, a transcript append); no
#      digest and no hot refresh loop while nothing changes; a burst is rate-limited and still
#      converges; a source nobody watches (git branch) still arrives via the backstop.
#   B. the real bin/heimdall-relay-client against the fake relay: change -> frame <= 500 ms, no frame
#      while nothing changes, a burst is coalesced into a few frames carrying the final state,
#      sustained churn cannot starve the phone, a re-bind re-sends at once, session_ended still
#      ends the process promptly.
#   C. RelayClient._await_new_state with a scripted cache: the debounce contract itself.
#
# Hermetic: HOME / HEIMDALL_HOME / TMPDIR / the Claude projects dir are all redirected into one temp
# dir, the repo under test is a throwaway git repo, the relay is a loopback fake, every process
# started here is reaped on EXIT. Bounded waits only (no `timeout` on macOS).
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "heimdall-ui-send-on-change (StateCache watcher + relay-client send-on-change oracle)"

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

# ── A. StateCache producer ────────────────────────────────────────────────────────────
cat >"$TMPROOT/part_a.py" <<'PYEOF'
import os
import re
import subprocess
import sys
import threading
import time
import uuid
from importlib.util import module_from_spec, spec_from_file_location

code, tmp = sys.argv[1], sys.argv[2]


def verdict(passed, text):
    print(("ok " if passed else "bad ") + text, flush=True)


def load(name, path):
    spec = spec_from_file_location(name, path)
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def median(vals):
    s = sorted(vals)
    return s[len(s) // 2]


home = os.path.join(tmp, "home")
projects = os.path.join(home, ".claude", "projects")
os.makedirs(projects)
os.environ.update(HOME=home, HEIMDALL_HOME=os.path.join(home, ".heimdall"), TMPDIR=tmp,
                  HMD_AGENT_PROJECTS_DIR=projects)
for name in ("CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID", "SESSION_ID"):
    os.environ.pop(name, None)
root = os.path.realpath(os.path.join(tmp, "repo"))
os.makedirs(root)
subprocess.run(["git", "init", "-q", root], check=True)
subprocess.run(["git", "-C", root, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q",
                "--allow-empty", "-m", "fixture"], check=True)

sid = str(uuid.uuid4())
pdir = os.path.join(projects, re.sub(r"[^A-Za-z0-9]", "-", root))
os.makedirs(pdir)
transcript = os.path.join(pdir, sid + ".jsonl")


def entry_line(text):
    import json
    e = {"type": "user", "uuid": str(uuid.uuid4()), "sessionId": sid, "cwd": root, "entrypoint": "cli",
         "isSidechain": False, "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
         "message": {"role": "user", "content": text}}
    return (json.dumps(e) + "\n").encode("utf-8")


with open(transcript, "wb") as f:
    f.write(entry_line("seed turn one"))
    f.write(entry_line("seed turn two"))
# what a live session's statusline keeps writing: "no sub-agent is running", so the agents publisher
# makes no `heimdall-agents list` probe of its own (that probe is a spawn on the poller thread)
counts = os.path.join(root, ".heimdall", ".agents-count-cache")
os.makedirs(os.path.dirname(counts))
with open(counts, "w") as f:
    f.write("0\n")

ui = load("hmd_ui", os.path.join(code, "sentinels", "hmd-ui.py"))
relay_transport = {"bind": "relay", "public_host": "relay", "trust_proxy": False, "port": 0}
cache = ui.StateCache(root, relay_transport)
cache.start()


def panel(state, pid):
    for p in state.get("panels") or []:
        if p.get("id") == pid:
            return p
    return None


def settle(digest, quiet=1.0, limit=60.0):
    """Wait until the digest has been still for `quiet` s; returns (state, digest)."""
    end = time.monotonic() + limit
    state = None
    while time.monotonic() < end:
        state, nd = cache.wait_for_change(digest, quiet)
        if nd == digest:
            return state, digest
        digest = nd
    raise SystemExit("StateCache never settled")


def put(value):
    ui.PANELS.write_panel(root, "probe", {"id": "probe", "title": "probe", "type": "number",
                                          "data": {"value": value, "format": "count"},
                                          "refresh_s": 30, "updated_at": time.time()})


def wait_until(digest, pred, secs):
    """(seconds until pred(state) held, digest) or (None, digest) -- following every digest change."""
    t0 = time.monotonic()
    end = t0 + secs
    while time.monotonic() < end:
        state, nd = cache.wait_for_change(digest, max(0.01, end - time.monotonic()))
        if nd != digest:
            digest = nd
            if state is not None and pred(state):
                return time.monotonic() - t0, digest
    return None, digest


_, digest = cache.wait_for_change(None, 90)
if digest is None:
    raise SystemExit("StateCache produced no first state within 90 s")
_, digest = settle(digest)

# A1 -- a panel write reaches the digest well inside the old 2 s poll. Median of 5 de-phased samples
# (the old poller's wait is uniform over 2 s, so its median is ~1 s); each sample bounded too.
lat, lost = [], 0
for i in range(5):
    time.sleep(0.37 + 0.11 * i)
    put(i + 1)
    took, digest = wait_until(digest, lambda s, v=i + 1: (panel(s, "probe") or {}).get("data", {}).get("value") == v, 3.0)
    if took is None:
        lost += 1
    else:
        lat.append(took)
verdict(lost == 0 and lat and median(lat) <= 0.5 and max(lat) <= 1.5,
        "A1: a panel write reaches StateCache's digest: median %.0f ms (<= 500), max %.0f ms (<= 1500), lost %d"
        % (median(lat) * 1000 if lat else -1, max(lat) * 1000 if lat else -1, lost))

# A2 -- a transcript append reaches the chat panel (the handoff doc's measured scenario).
_, digest = settle(digest, 0.8)
lat, lost = [], 0
fd = os.open(transcript, os.O_WRONLY | os.O_APPEND)
for i in range(4):
    time.sleep(0.43 + 0.09 * i)
    marker = "CHAT-%d-%s" % (i, uuid.uuid4().hex[:6])
    os.write(fd, entry_line("hello " + marker))
    took, digest = wait_until(digest, lambda s, m=marker: any(m in ln for ln in (panel(s, "chat") or {}).get("data", {}).get("lines", [])), 3.0)
    if took is None:
        lost += 1
    else:
        lat.append(took)
os.close(fd)
verdict(lost == 0 and lat and median(lat) <= 0.5 and max(lat) <= 1.5,
        "A2: a transcript append reaches the chat panel: median %.0f ms (<= 500), max %.0f ms (<= 1500), lost %d"
        % (median(lat) * 1000 if lat else -1, max(lat) * 1000 if lat else -1, lost))

# A3 -- nothing changes -> no new digest, and no hot refresh loop (the backstop is POLL_INTERVAL_S).
_, digest = settle(digest, 1.2)
calls = []
inner_refresh = cache.refresh


def counting_refresh(*args, **kwargs):
    calls.append(time.monotonic())
    return inner_refresh(*args, **kwargs)


cache.refresh = counting_refresh
quiet_s = 3.3
_, after = cache.wait_for_change(digest, quiet_s)
verdict(after == digest, "A3a: no change -> no new digest over %.1f s" % quiet_s)
verdict(len(calls) <= 3, "A3b: idle refreshes over %.1f s: %d (<= 3: the %.0f s backstop, no hot loop)"
        % (quiet_s, len(calls), ui.POLL_INTERVAL_S))

# A4 -- a burst of 100 writes (10 ms apart) is rate-limited to one refresh per REFRESH_MIN_GAP_S and
# still converges on the final value.
del calls[:]
began = time.monotonic()
for j in range(100):
    put(1000 + j)
    time.sleep(0.01)
took, digest = wait_until(digest, lambda s: (panel(s, "probe") or {}).get("data", {}).get("value") == 1099, 3.0)
span = time.monotonic() - began
bound = int(span / ui.REFRESH_MIN_GAP_S) + 3
verdict(took is not None, "A4a: after a 100-write burst the digest converges on the LAST value")
verdict(len(calls) <= bound,
        "A4b: 100 writes in %.2f s caused %d refreshes (<= %d = one per %.2f s + 3)"
        % (span, len(calls), bound, ui.REFRESH_MIN_GAP_S))
cache.refresh = inner_refresh

# A5 -- a source nobody watches (the git branch comes from a subprocess) still arrives: the backstop.
_, digest = settle(digest, 1.2)
subprocess.run(["git", "-C", root, "checkout", "-q", "-b", "backstop-branch"], check=True)
took, digest = wait_until(digest, lambda s: (s.get("identity") or {}).get("branch") == "backstop-branch", 6.0)
verdict(took is not None and took <= 4.5,
        "A5: an unwatched source (git branch) still lands via the backstop in %s (<= 4.5 s)"
        % ("%.2f s" % took if took is not None else "never"))

# A6 -- a poller pass never waits on a spawn. With every cached subprocess answer made an hour old,
# the poller thread runs none of the collectors' commands (a partial pass serves the last answer);
# the warmer thread is the one that re-runs them.
_, digest = settle(digest, 1.2)
os.utime(counts)
spawns = []
inner_run = ui._run


def recording_run(argv, cwd, *args, **kwargs):
    spawns.append((threading.current_thread().name, argv[0]))
    return inner_run(argv, cwd, *args, **kwargs)


ui._run = recording_run
for cache_key, (stamped, answer) in list(ui._subprocess_cache.items()):
    ui._subprocess_cache[cache_key] = (stamped - 3600.0, answer)
landed = 0
for i in range(3):
    time.sleep(0.4)
    put(2000 + i)
    took, digest = wait_until(digest, lambda s, v=2000 + i: (panel(s, "probe") or {}).get("data", {}).get("value") == v, 3.0)
    landed += took is not None
time.sleep(ui.POLL_INTERVAL_S + 1.5)
ui._run = inner_run
on_poller = sorted(set(a for t, a in spawns if t == "hmd-ui-poller"))
on_warmer = [a for t, a in spawns if t == "hmd-ui-warm"]
verdict(landed == 3 and not on_poller,
        "A6a: %d/3 changes landed and the poller thread spawned %s (none expected: it reuses the last answers)"
        % (landed, on_poller or "nothing"))
verdict(len(on_warmer) >= 3, "A6b: the warmer thread re-ran the stale answers (%d spawns: %s)"
        % (len(on_warmer), sorted(set(on_warmer))))

cache.stop()
print("done", flush=True)
PYEOF
run_part part_a "$TMPROOT/part_a.py"

# ── B. real relay client vs the fake relay ────────────────────────────────────────────
cat >"$TMPROOT/part_b.py" <<'PYEOF'
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import uuid
from http.server import ThreadingHTTPServer
from importlib.util import module_from_spec, spec_from_file_location

code, tmp = sys.argv[1], sys.argv[2]


def verdict(passed, text):
    print(("ok " if passed else "bad ") + text, flush=True)


def load(name, path):
    spec = spec_from_file_location(name, path)
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def median(vals):
    s = sorted(vals)
    return s[len(s) // 2]


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def read_events(path):
    out = []
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError:
        return out
    for line in lines:
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
out_path = os.path.join(tmp, "client.out")
out_f = open(out_path, "w")
client = subprocess.Popen([sys.executable, os.path.join(code, "bin", "heimdall-relay-client"),
                           "--relay", "http://127.0.0.1:%d" % port, "--repo", repo, "--ui-port", "0"],
                          stdout=out_f, stderr=subprocess.PIPE, env=env, cwd=tmp)


def wait_until(pred, secs, step=0.005):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(step)
    return False


key = None
opened = {}   # frame index -> the `probe` panel's value in that frame's state (None: not a state frame / no probe)


def probe_value(index):
    """The `probe` panel's value inside frame `index` (decrypted once, then remembered)."""
    if index not in opened:
        env_ = json.loads(frames[index][1])
        value = None
        if env_.get("type") == "state":
            text = e2e.open_(key, env_["seq"], "hmd", env_["nonce"], env_["ciphertext"]).decode("utf-8")
            for p in json.loads(text)["state"].get("panels") or []:
                if p.get("id") == "probe":
                    value = p["data"].get("value")
        opened[index] = value
    return opened[index]


def carrying(value, start):
    """Index of the first frame at/after `start` whose `probe` panel holds `value`, else None."""
    for i in range(start, len(frames)):
        if probe_value(i) == value:
            return i
    return None


def put(value):
    panels.write_panel(repo, "probe", {"id": "probe", "title": "probe", "type": "number",
                                       "data": {"value": value, "format": "count"},
                                       "refresh_s": 30, "updated_at": time.time()})


def settle(quiet=3.0, limit=60.0):
    end = time.monotonic() + limit
    seen, since = len(frames), time.monotonic()
    while time.monotonic() < end:
        time.sleep(0.05)
        if len(frames) != seen:
            seen, since = len(frames), time.monotonic()
        elif time.monotonic() - since >= quiet:
            return
    raise SystemExit("frames never went quiet")


try:
    if not wait_until(lambda: any(o.get("event") == "pair_init" for o in read_events(out_path)), 30):
        raise SystemExit("client never emitted pair_init: %s" % client.stderr.read().decode()[-600:])
    pair = next(o for o in read_events(out_path) if o.get("event") == "pair_init")
    key = e2e.derive_session_key(dev_priv, e2e.pub_from_b64(pair["qr"]["hmd_pubkey"]), pair["qr"]["session_id"])
    if not wait_until(lambda: frames, 60, 0.05):
        raise SystemExit("no first state frame within 60 s; events=%s" % read_events(out_path)[-5:])
    settle()

    # B1 -- nothing changes -> no frame
    before = len(frames)
    time.sleep(4.5)
    verdict(len(frames) == before, "B1: no change -> no frame over 4.5 s (%d new)" % (len(frames) - before))

    # B2 -- a change reaches the relay well inside the old 2 s tick
    lat, lost = [], 0
    for i in range(6):
        time.sleep(0.9 + 0.17 * i)
        start = len(frames)
        t0 = time.time_ns()
        put(i + 1)
        wait_until(lambda: carrying(i + 1, start) is not None, 4.0, 0.01)
        hit = carrying(i + 1, start)
        if hit is None:
            lost += 1
        else:
            lat.append((frames[hit][0] - t0) / 1e6)
    verdict(lost == 0 and lat and median(lat) <= 500 and max(lat) <= 1500,
            "B2: change -> frame on the relay: median %.0f ms (<= 500), max %.0f ms (<= 1500), lost %d"
            % (median(lat) if lat else -1, max(lat) if lat else -1, lost))

    # B3 -- a burst of 20 writes (10 ms apart) is coalesced; the last frame carries the final state
    settle(1.5)
    start = len(frames)
    for j in range(20):
        put(100 + j)
        time.sleep(0.01)
    wait_until(lambda: carrying(119, start) is not None, 4.0, 0.01)
    time.sleep(1.2)
    got = len(frames) - start
    seqs = [json.loads(frames[i][1])["seq"] for i in range(start, len(frames))]
    verdict(carrying(119, start) is not None, "B3a: the burst's final value (119) reaches the relay")
    verdict(1 <= got <= 4, "B3b: 20 writes in ~0.3 s were coalesced into %d frame(s) (1..4)" % got)
    verdict(seqs == sorted(set(seqs)), "B3c: frame seq strictly increasing across the burst %s" % seqs)
    verdict(probe_value(len(frames) - 1) == 119,
            "B3d: the LAST frame holds the final state (no stale frame lands after it)")

    # B4 -- sustained churn: the debounce is capped, so the phone is fed DURING the churn
    settle(1.5)
    start = len(frames)
    churn_s, step_s = 2.0, 0.02
    began = time.monotonic()
    value = 200
    while time.monotonic() - began < churn_s:
        put(value)
        value += 1
        time.sleep(step_s)
    mid = len(frames) - start
    wait_until(lambda: carrying(value - 1, start) is not None, 4.0, 0.01)
    time.sleep(1.2)
    total = len(frames) - start
    verdict(mid >= 2, "B4a: %d frames arrived while the churn was still running (>= 2: debounce is capped)" % mid)
    verdict(total <= 14, "B4b: %.0f s of churn (%d writes) cost %d frames (<= 14)" % (churn_s, value - 200, total))
    verdict(probe_value(len(frames) - 1) == value - 1, "B4c: the last frame holds the last write")

    # B5 -- a re-bind (device_bound again, same pubkey) re-sends the state at once, not at the next tick
    settle(1.5)
    resync = []
    for i in range(2):
        bound_before = sum(1 for o in read_events(out_path) if o.get("event") == "device_bound")
        start = len(frames)
        open(os.path.join(ctl_dir, "lifetime-close"), "w").close()
        if not wait_until(lambda: sum(1 for o in read_events(out_path) if o.get("event") == "device_bound") > bound_before, 10, 0.005):
            resync.append(None)
            continue
        seen_at = time.time_ns()
        if not wait_until(lambda: len(frames) > start, 5, 0.005):
            resync.append(None)
            continue
        resync.append((frames[start][0] - seen_at) / 1e6)
        settle(1.5)
    verdict(all(r is not None and r <= 700 for r in resync),
            "B5: a repeated device_bound re-sends the state within 700 ms: %s ms"
            % [("%.0f" % r) if r is not None else "never" for r in resync])

    # B6 -- session_ended still stops the process promptly (the wait is sliced, not a 2 s sleep)
    open(os.path.join(ctl_dir, "end-session"), "w").close()
    t_end = time.monotonic()
    try:
        client.wait(timeout=6)
        exited = time.monotonic() - t_end
    except subprocess.TimeoutExpired:
        exited = None
    verdict(exited is not None and exited <= 2.0 and client.returncode == 0,
            "B6: session_ended -> client exits 0 in %s (<= 2 s)" % ("%.2f s" % exited if exited is not None else "never"))
finally:
    if client.poll() is None:
        client.terminate()
        try:
            client.wait(timeout=20)
        except subprocess.TimeoutExpired:
            client.kill()
    out_f.close()
    httpd.shutdown()
print("done", flush=True)
PYEOF
run_part part_b "$TMPROOT/part_b.py"

# ── C. the debounce contract, against a scripted cache ────────────────────────────────
cat >"$TMPROOT/part_c.py" <<'PYEOF'
import argparse
import os
import sys
import threading
import time
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

code, tmp = sys.argv[1], sys.argv[2]
os.makedirs(tmp)


def verdict(passed, text):
    print(("ok " if passed else "bad ") + text, flush=True)


loader = SourceFileLoader("hmd_relay_client_unit", os.path.join(code, "bin", "heimdall-relay-client"))
spec = spec_from_loader(loader.name, loader)
mod = module_from_spec(spec)
loader.exec_module(mod)
args = argparse.Namespace(relay="http://127.0.0.1:9", repo=tmp, ui_port=0, public_host=None,
                          status_file=None, tick_s=2.0)
Client = mod.RelayClient


class ScriptedCache:
    """The slice of StateCache the state loop uses: a digest and wait_for_change()."""

    def __init__(self, digest):
        self.cond = threading.Condition()
        self.digest = digest

    def set(self, digest):
        with self.cond:
            self.digest = digest
            self.cond.notify_all()

    def wait_for_change(self, seen, timeout):
        with self.cond:
            if self.digest != seen:
                return None, self.digest
            self.cond.wait(timeout)
            return None, self.digest


def feed(cache, schedule):
    t0 = time.monotonic()

    def run():
        for offset, digest in schedule:
            time.sleep(max(0.0, t0 + offset - time.monotonic()))
            cache.set(digest)

    threading.Thread(target=run, daemon=True).start()
    return t0


def case(name, fn):
    try:
        fn()
    except Exception as e:
        verdict(False, "%s: raised %s: %s" % (name, e.__class__.__name__, e))


def fresh(last_sent, digest):
    client = mod.RelayClient(args)
    client.cache = ScriptedCache(digest)
    client.last_sent_digest = last_sent
    return client


def c1():
    client = fresh("A", "A")
    t = time.monotonic()
    result = client._await_new_state()
    el = time.monotonic() - t
    verdict(result is False and el <= 0.5, "C1: nothing new -> False within one wait slice (%.0f ms, <= 500)" % (el * 1000))


def c2():
    client = fresh("A", "A")
    t0 = feed(client.cache, [(0.05, "B")])
    result = client._await_new_state()
    el = time.monotonic() - t0
    floor = 0.05 + Client.STATE_DEBOUNCE_S - 0.01
    verdict(result is True and floor <= el < 0.5,
            "C2: one change -> True, but only after the %.0f ms debounce (%.0f ms; window [%.0f, 500))"
            % (Client.STATE_DEBOUNCE_S * 1000, el * 1000, floor * 1000))


def c3():
    client = fresh("A", "A")
    t0 = feed(client.cache, [(0.05, "B"), (0.09, "C"), (0.13, "D")])
    result = client._await_new_state()
    el = time.monotonic() - t0
    floor = 0.13 + Client.STATE_DEBOUNCE_S - 0.01
    verdict(result is True and floor <= el < 0.6,
            "C3: a 3-change burst is ONE True, after the burst went quiet (%.0f ms; window [%.0f, 600))"
            % (el * 1000, floor * 1000))


def c4():
    client = fresh("A", "A")
    schedule = [(0.02 + 0.03 * i, "X%d" % i) for i in range(50)]
    t0 = feed(client.cache, schedule)
    result = client._await_new_state()
    el = time.monotonic() - t0
    ceiling = Client.STATE_DEBOUNCE_MAX_S + 0.02 + 0.2
    verdict(result is True and el <= ceiling,
            "C4: churn every 30 ms for 1.5 s cannot starve the send: True after %.0f ms (<= %.0f = max hold + slack)"
            % (el * 1000, ceiling * 1000))


def c5():
    client = fresh(None, "A")
    t = time.monotonic()
    result = client._await_new_state()
    el = time.monotonic() - t
    verdict(result is True and el <= 0.3,
            "C5: last_sent_digest reset to None (re-bind resync) -> True at once (%.0f ms, <= 300)" % (el * 1000))


def c6():
    client = fresh("A", "A")
    client.stop_event.set()
    t = time.monotonic()
    result = client._await_new_state()
    el = time.monotonic() - t
    verdict(result is False and el <= 0.5, "C6: stop_event set -> False within one slice (%.0f ms, <= 500)" % (el * 1000))


def c7():
    client = fresh(None, None)
    t = time.monotonic()
    result = client._await_new_state()
    el = time.monotonic() - t
    verdict(result is False and el <= 0.5, "C7: an empty cache (no digest yet) is never 'new' (%.0f ms)" % (el * 1000))


for name, fn in (("C1", c1), ("C2", c2), ("C3", c3), ("C4", c4), ("C5", c5), ("C6", c6), ("C7", c7)):
    case(name, fn)
print("done", flush=True)
PYEOF
run_part part_c "$TMPROOT/part_c.py"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
