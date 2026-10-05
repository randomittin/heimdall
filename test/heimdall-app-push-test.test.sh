#!/usr/bin/env bash
# test/heimdall-app-push-test.test.sh -- `hmd app push-test`: the operator's check that a registered phone gets a
# push (hmdapp docs/HANDOFF-TO-HEIMDALL-push-notifications.md PN5; docs/analysis/2026-10-04-heimdall-golive-
# readiness.md item 9). Without it a launch has no way to prove a device receives anything.
#
# The design under test (bin/lib/companion_push.py "OPERATOR TEST", bin/lib/companion_push_cli.py):
#   * The CLI NEVER SENDS. The sender role is one process per repo: an exclusive flock on push-sender.lock, taken
#     by whichever process had something to send first and held for life; a process that does not own the lock
#     throws away every event it detects. A CLI that took that lock to send a test would therefore make the real
#     sender drop whatever it detected meanwhile (an approval, a question), and a CLI that sent without the lock
#     would break the one-sender rule. So the CLI posts a REQUEST (<repo>/.heimdall/app/push-test) and the lock
#     owner -- the process that already sends the real notifications -- answers it through the same message
#     builder, scrub, transport, back-pressure and DeviceNotRegistered pruning, writing push-test.result.
#   * `test` bypasses the kind filter (a phone cannot subscribe to it), foreground suppression and the coalescing
#     window (so also the 10 s spacing). It does NOT bypass the 20/hour cap, the provider back-off / pause, the
#     lock, the kill switch or the loopback-only endpoint override.
#
#   A  the monitor serves a request: one `test` message per token, each bypass and each thing that still applies,
#      DeviceNotRegistered pruning, the lock, the TTL, the kill switch, never a token
#   B  `hmd app push-test` end to end against sender PROCESSES and a loopback fake Expo: per-token results, the exit
#      codes (0 sent, 2 usage, 3 no device, 4 no sender, 5 push off, 6 all failed), the lock, restarts
#   C  the same CLI against the real bin/heimdall-ui: its StateCache poller is what notices the request
#   D  the CLI module's waiting rules and the wording of every outcome, against a stand-in for the sender
#
# Hermetic: HOME / HEIMDALL_HOME / TMPDIR are a temp dir, every sender talks to a loopback fake through
# HMD_PUSH_EXPO_URL (the CLI is given it too, so a CLI that tried to send would hit the fake, never Expo), and
# HTTPS_PROXY points at a closed port so a push that tried to leave this machine would die at the proxy. Token-
# shaped inputs are assembled at runtime. Only processes this suite started are ever signalled. Bounded waits.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "heimdall-app-push-test (hmd app push-test: one test notification per registered token, through the one sender)"

for f in "$REPO/bin/heimdall-app" "$REPO/bin/heimdall" "$REPO/bin/heimdall-ui" "$REPO/bin/lib/companion_push.py" \
         "$REPO/bin/lib/companion_push_store.py" "$REPO/test/lib/push_test_lib.py" "$REPO/sentinels/hmd-ui.py"; do
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

export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$HOME/.heimdall"
export TMPDIR="$TMPROOT"
mkdir -p "$HOME"
unset HMD_PUSH HMD_PUSH_EXPO_URL HMD_PUSH_COALESCE_S HMD_PUSH_MIN_RUN_S HMD_PYTHON
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID SESSION_ID CLAUDE_CONFIG_DIR CLAUDE_PROJECT_DIR HMD_AGENT_PROJECTS_DIR
# a push that tried to leave this machine dies at a closed proxy port; loopback bypasses it
export HTTPS_PROXY="http://127.0.0.1:9" HTTP_PROXY="http://127.0.0.1:9"
export https_proxy="$HTTPS_PROXY" http_proxy="$HTTP_PROXY"
export NO_PROXY="127.0.0.1,localhost" no_proxy="127.0.0.1,localhost"

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

# ── A. the monitor serves a request ──────────────────────────────────────────────────────
cat >"$TMPROOT/part_a.py" <<'PYEOF'
import calendar
import hashlib
import json
import os
import stat
import sys
import time

code, tmp = sys.argv[1], sys.argv[2]
os.makedirs(tmp, exist_ok=True)
sys.path.insert(0, os.path.join(code, "test", "lib"))
import push_test_lib as T

CP = T.load("companion_push", os.path.join(code, "bin", "lib", "companion_push.py"))
STORE = T.load("companion_push_store", os.path.join(code, "bin", "lib", "companion_push_store.py"))
A, S, att = T.a_id, T.state, T.attention
TOK1, TOK2 = T.expo_token("a"), T.expo_token("b")
YESNO = [{"key": "yes", "label": "Yes"}, {"key": "no", "label": "No"}]
IDLE = S(att("idle", A(1)))
TWO = ((TOK1, "ios", "api server", None), (TOK2, "android", "web app", None))
_n = [0]


def fp(token):
    """The 8 hex of sha256(token): the only trace of a device that may be shown."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:8]


def wait_for(pred, secs):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.05)
    return pred()


class Rig:
    """One monitor over a repo whose registrations the PRODUCTION store wrote, plus a loopback fake Expo. The test
    drives the clock: observe(state, now) is the poller's tick, step(now) the worker's pass."""

    def __init__(self, devices=TWO, cfg=None, env=None, fake=None, root=None):
        _n[0] += 1
        self.root = root or os.path.join(tmp, "repo%d" % _n[0])
        os.makedirs(self.root, exist_ok=True)
        self.fake = fake or T.FakeExpo()
        for token, platform, label, events in devices:
            STORE.register(self.root, token, platform, label=label, events=events)
        self.events = []
        environ = {"HMD_PUSH_EXPO_URL": self.fake.url}
        environ.update(env or {})
        config = {"min_run_s": 0, "timeout_s": 3.0}
        config.update(cfg or {})
        self.m = CP.PushMonitor(self.root, emit=self.events.append, config=config, sleep=lambda seconds: None,
                                environ=environ, start_thread=False)

    def another(self):
        """A second monitor on the same repo (a second process in production), with its own log."""
        events = []
        m = CP.PushMonitor(self.root, emit=events.append, config={"min_run_s": 0, "timeout_s": 3.0},
                           sleep=lambda seconds: None, environ={"HMD_PUSH_EXPO_URL": self.fake.url},
                           start_thread=False)
        return m, events

    def pushes(self):
        return [e for e in self.events if e.get("event") == "push"]

    def path(self, name):
        return os.path.join(self.root, ".heimdall", "app", name)

    def close(self):
        self.m.close()
        self.fake.close()


def ask(rig, now, monitor=None):
    """An operator runs `hmd app push-test` (the request file), the poller's next tick notices it and the worker's
    next pass serves it. Returns the request id."""
    rid = CP.request_test(rig.root)
    mon = monitor or rig.m
    mon.observe(IDLE, now)
    mon.step(now)
    return rid


def answer(rig, rid):
    """What the CLI reads back: (state, [(device, ok, detail, suppressed)]) or None."""
    r = CP.read_test_result(rig.root, rid)
    return None if r is None else (r["state"], [(x["device"], x["ok"], x["detail"], x["suppressed"]) for x in r["results"]])


def sent_kinds(rig):
    return [m["data"]["kind"] for m in rig.fake.messages()]


def put_request(root, rid, at, raw=None):
    directory = os.path.join(root, ".heimdall", "app")
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, "push-test"), "w", encoding="utf-8") as f:
        f.write(raw if raw is not None else json.dumps({"v": 1, "id": rid, "at": at}))


def files_with(root, needles):
    """Every file under `root`, except the registry itself, whose bytes contain any of `needles`."""
    hits = []
    for d, _, names in os.walk(root):
        for name in names:
            if name == "push.json":
                continue
            path = os.path.join(d, name)
            with open(path, "rb") as f:
                data = f.read()
            if any(n.encode("utf-8") in data for n in needles):
                hits.append(os.path.relpath(path, root))
    return hits


# ── A1. one `test` message per registered token, built by the sender's own builder; the bypasses ──
rig = Rig(devices=((TOK1, "ios", "api server", ["question"]), (TOK2, "android", "web app", ["error"])))
STORE.set_app_state(rig.root, "foreground")
stamped = calendar.timegm(time.strptime(STORE.load(rig.root)["app_state_at"], "%Y-%m-%dT%H:%M:%SZ"))
base = stamped + 10.0
# contrast: a REAL question is held back -- by foreground suppression for the device that asked for questions, by
# the kind filter for the one that did not -- so the two bypasses below are bypasses of something that is on
rig.m.observe(S(att("working", A(1))), base)
rig.m.observe(S(att("needs_input", A(2), "question", "Delete the old branch?", YESNO)), base + 2)
rig.m.step(base + 2)
rig.m.step(base + 8)
T.eq([(e["kind"], e["device"], e["suppressed"]) for e in rig.pushes()],
     [("question", fp(TOK1), "foreground"), ("question", fp(TOK2), "disabled-kind")],
     "A1a. contrast: a real question is suppressed (foreground for one device, kind filter for the other), nothing sent")
T.eq(len(rig.fake.messages()), 0, "A1b. contrast: Expo was sent nothing for it")
rid = ask(rig, base + 9)
msgs = rig.fake.messages()
T.eq(sorted(m["to"] for m in msgs), sorted([TOK1, TOK2]),
     "A1c. the test is sent to EVERY registered token, one message each, though the app is in the foreground and neither "
     "device subscribed to the test kind")
by_to = {m["to"]: m for m in msgs}
if len(by_to) == 2:
    T.eq((by_to[TOK1]["title"], by_to[TOK1]["body"], by_to[TOK1]["ttl"], by_to[TOK1]["channelId"]),
         ("api server · test notification", "Notifications from this laptop work.", 600, "hmd-updates"),
         "A1d. the message is the closed per-kind table's test row, titled with the device's own label")
    T.eq(by_to[TOK2]["title"], "web app · test notification", "A1e. the other device carries its own label")
    T.eq(by_to[TOK1]["data"], {"v": 1, "ref": hashlib.sha256(TOK1.encode("utf-8")).hexdigest()[:16], "kind": "test",
                               "ep": None}, "A1f. the notification data is exactly {v, ref, kind, ep}: nothing else rides along")
T.eq(answer(rig, rid), ("done", [(fp(TOK1), True, None, None), (fp(TOK2), True, None, None)]),
     "A1g. the answer lists each device by its 8-hex fingerprint, in registry order, ok, with no detail")
T.eq([(e["kind"], e["device"], e["ok"], e["suppressed"]) for e in rig.pushes()[2:]],
     [("test", fp(TOK1), True, None), ("test", fp(TOK2), True, None)],
     "A1h. one `push` log line per device, kind test, ok")
T.check(all(set(e) == {"event", "kind", "device", "ok", "detail", "suppressed", "ms"} for e in rig.pushes()),
        "A1i. every log line has exactly the documented keys", rig.pushes())
a1_root, a1_events = rig.root, json.dumps(rig.events)
rig.close()

# ── A2. no coalescing window, no spacing; a real notification is neither merged away nor delayed ──
rig = Rig(devices=TWO[:1])
base = 1000.0
rig.m.observe(S(att("working", A(1))), base)
rig.m.observe(S(att("needs_input", A(2), "question", "Delete the old branch?", YESNO)), base + 2)
rig.m.step(base + 2)
T.eq(sent_kinds(rig), [], "A2a. a real question waits in its 5 s coalescing window")
ask(rig, base + 3)
T.eq(sent_kinds(rig), ["test"], "A2b. a test requested meanwhile goes out at once, inside that window")
rig.m.step(base + 7)
T.eq(sent_kinds(rig), ["test", "question"],
     "A2c. the real question still goes at its own time: the test neither merged it away nor delayed it")
ask(rig, base + 8)
T.eq(sent_kinds(rig), ["test", "question", "test"],
     "A2d. a test one second after a real message goes out too: the 10 s spacing does not apply to it")
T.eq([e["suppressed"] for e in rig.pushes()], [None, None, None], "A2e. nothing was logged as coalesced or suppressed")
rig.close()

# ── A3. the 20/hour cap still applies, as a rolling window ──
rig = Rig(devices=TWO[:1], cfg={"hourly_cap": 2})
r1, r2, r3 = ask(rig, 1000.0), ask(rig, 1001.0), ask(rig, 1002.0)
T.eq(len(rig.fake.messages()), 2, "A3a. with a cap of 2 per hour the third test is not sent")
T.eq(answer(rig, r3), ("done", [(fp(TOK1), False, None, "rate-limited")]), "A3b. and it is answered as rate-limited")
T.eq([(e["kind"], e["ok"], e["suppressed"]) for e in rig.pushes()],
     [("test", True, None), ("test", True, None), ("test", False, "rate-limited")], "A3c. and logged as rate-limited")
ask(rig, 1002.0 + 3601)
T.eq(len(rig.fake.messages()), 3, "A3d. the cap is a rolling hour: an hour later a test is sent again")
rig.close()

# ── A4. provider back-pressure still applies: the sender's own retry rule, then its back-off ──
rig = Rig(devices=TWO[:1])
rig.fake.script = [{"status": 500, "body": {}}] * 4
r1 = ask(rig, 1000.0)
T.eq(answer(rig, r1), ("done", [(fp(TOK1), False, "http-500", None)]), "A4a. an Expo outage is answered with its HTTP status")
T.eq(len(rig.fake.sends()), 4, "A4b. through the sender's own retry rule: the request and three retries")
r2 = ask(rig, 1005.0)
T.eq(answer(rig, r2), ("done", [(fp(TOK1), False, "backoff", None)]), "A4c. inside the 60 s back-off the sender set, a test is held back")
T.eq(len(rig.fake.sends()), 4, "A4d. and nothing more is POSTed")
r3 = ask(rig, 1061.0)
T.eq(answer(rig, r3), ("done", [(fp(TOK1), True, None, None)]), "A4e. once the back-off is over the test goes through")
rig.close()

# ── A5. DeviceNotRegistered prunes through the production store ──
rig = Rig()
rig.fake.unregistered.add(TOK1)
rid = ask(rig, 1000.0)
T.eq(answer(rig, rid), ("done", [(fp(TOK1), False, "DeviceNotRegistered", None), (fp(TOK2), True, None, None)]),
     "A5a. the dead device is reported as DeviceNotRegistered, the live one as ok")
T.eq([e["token"] for e in STORE.load(rig.root)["tokens"]], [TOK2], "A5b. the dead registration is removed from push.json, the live one stays")
rig.close()

# ── A6. a token is never written anywhere but the registry, and what is written is private ──
T.eq(files_with(a1_root, [TOK1, TOK2]), [], "A6a. no file under the repo except push.json holds a token (request, result, lock)")
T.check(TOK1 not in a1_events and TOK2 not in a1_events and "test notification" not in a1_events
        and "Notifications from this laptop" not in a1_events and "api server" not in a1_events,
        "A6b. the log carries no token, title, body or label", a1_events)
T.eq((stat.S_IMODE(os.stat(os.path.join(a1_root, ".heimdall", "app", "push-test")).st_mode),
      stat.S_IMODE(os.stat(os.path.join(a1_root, ".heimdall", "app", "push-test.result")).st_mode),
      stat.S_IMODE(os.stat(os.path.join(a1_root, ".heimdall", "app")).st_mode)), (0o600, 0o600, 0o700),
     "A6c. the request and the result are 0600 in a 0700 directory")

# ── A7. which requests are served: fresh, well-formed, unanswered ──
rig = Rig(devices=TWO[:1])
junk = [("two minutes old", dict(rid="1" * 16, at=time.time() - 120)),
        ("just past its 60 s life", dict(rid="4" * 16, at=time.time() - 70)),
        ("dated an hour ahead", dict(rid="2" * 16, at=time.time() + 3600)),
        ("not an id", dict(rid="XYZ", at=time.time())),
        ("not json", dict(rid=None, at=None, raw="{not json")),
        ("oversized", dict(rid=None, at=None, raw=" " * 5000 + json.dumps({"v": 1, "id": "5" * 16, "at": time.time()})))]
for name, kw in junk:
    put_request(rig.root, **kw)
    rig.m.observe(IDLE, 1000.0)
    rig.m.step(1000.0)
    T.check(len(rig.fake.messages()) == 0 and not os.path.exists(rig.path("push-test.result")),
            "A7a. a request that is %s is ignored: nothing sent, nothing answered" % name)
put_request(rig.root, "3" * 16, time.time() - 50)
rig.m.observe(IDLE, 1001.0)
rig.m.step(1001.0)
T.eq((len(rig.fake.messages()), answer(rig, "3" * 16)), (1, ("done", [(fp(TOK1), True, None, None)])),
     "A7b. a request written 50 s ago (inside its 60 s life) is served")
rig.m.observe(IDLE, 1002.0)
rig.m.step(1002.0)
T.eq(len(rig.fake.messages()), 1, "A7c. the same request noticed again is not served twice")
rig.close()

# a request file that is touched again (the same id) before it was served is still served ONCE
rig = Rig(devices=TWO[:1])
rid = CP.request_test(rig.root)
rig.m.observe(IDLE, 1000.0)                                  # noticed and queued
later = time.time() + 5
os.utime(rig.path("push-test"), (later, later))              # the file moves, the request does not
rig.m.observe(IDLE, 1001.0)
rig.m.step(1001.0)
T.eq(sent_kinds(rig), ["test"], "A7c2. a request file touched again (same id) before it is served is served once")
rig.close()

# a request that was answered is not served again, not even by a monitor that never saw it (a restarted sender)
rig = Rig(devices=TWO[:1])
rid = ask(rig, 1000.0)
rig.m.close()                                   # the owner goes away and frees the lock
second, second_events = rig.another()
second.observe(IDLE, 1001.0)
second.step(1001.0)
T.eq((len(rig.fake.messages()), second_events), (1, []),
     "A7d. a request that was already answered is not served again by a sender that starts afterwards")
second.close()
rig.fake.close()

# only the owner of the sender lock serves; a monitor that does not own it stays quiet
rig = Rig(devices=TWO[:1])
rig.m.observe(S(att("working", A(1))), 1000.0)
rig.m.observe(S(att("needs_input", A(2), "question", "Delete the old branch?", YESNO)), 1002.0)
rig.m.step(1002.0)
rig.m.step(1007.0)                              # the real question: this monitor now owns the lock
other, other_events = rig.another()
other.observe(IDLE, 1008.0)
rid = CP.request_test(rig.root)
other.observe(IDLE, 1009.0)
rig.m.observe(IDLE, 1009.0)
other.step(1009.0)
T.eq((sent_kinds(rig), answer(rig, rid)), (["question"], None),
     "A7e. a monitor that does not own the sender lock does not send a test, and does not answer it")
rig.m.step(1009.0)
T.eq((sent_kinds(rig), len(rig.pushes()), len(other_events)), (["question", "test"], 2, 0),
     "A7f. the owner serves it: exactly one test, logged by the owner only")
other.close()
rig.close()

# the kill switch: a monitor with HMD_PUSH=0 never notices a request
rig = Rig(devices=TWO[:1], env={"HMD_PUSH": "0"})
rid = ask(rig, 1000.0)
T.eq((len(rig.fake.requests), rig.events, answer(rig, rid), os.path.exists(rig.path("push-sender.lock"))),
     (0, [], None, False), "A7g. HMD_PUSH=0: no request is served, answered, logged or locked")
rig.close()

# nothing registered: answered "done" with no results, without touching the lock or the network
rig = Rig(devices=())
rid = ask(rig, 1000.0)
T.eq((answer(rig, rid), len(rig.fake.requests), os.path.exists(rig.path("push-sender.lock"))),
     (("done", []), 0, False), "A7h. no device registered: answered as an empty list; no request, no lock file")
rig.close()


class BrokenStore:
    """A registry that cannot be read."""

    def load(self, root):
        raise RuntimeError("registry unreadable")

    def remove_tokens(self, root, tokens):
        return 0


# a registry that cannot be read: nothing is sent, the request is not answered (the CLI then says no sender), one error event
rig = Rig(devices=TWO[:1])
broken = CP.PushMonitor(rig.root, store=BrokenStore(), emit=rig.events.append, config={"min_run_s": 0, "timeout_s": 3.0},
                        sleep=lambda seconds: None, environ={"HMD_PUSH_EXPO_URL": rig.fake.url}, start_thread=False)
rid = CP.request_test(rig.root)
broken.observe(IDLE, 1000.0)
broken.step(1000.0)
T.eq((len(rig.fake.requests), answer(rig, rid), [e["detail"] for e in rig.events if e.get("event") == "error"]),
     (0, None, ["push: store-load failed (RuntimeError)"]),
     "A7i. a registry that cannot be read: nothing sent, no answer, exactly one error event")
broken.close()
rig.close()

# an answer that cannot be written costs the CLI its answer, never the send
rig = Rig(devices=TWO[:1])
os.makedirs(rig.path("push-test.result"))                    # a directory where the answer would go
rid = ask(rig, 1000.0)
errors = [e["detail"] for e in rig.events if e.get("event") == "error"]
T.check(sent_kinds(rig) == ["test"] and len(errors) == 1 and errors[0].startswith("push: test-result failed"),
        "A7j. the answer cannot be written: the test was still sent, and one error event says why", (sent_kinds(rig), errors))
rig.close()

# ── A8. the worker thread serves a request by itself (no step() from the caller) ──
rig = Rig(devices=TWO[:1])
events = []
thread_monitor = CP.PushMonitor(rig.root, emit=events.append, config={"min_run_s": 0, "timeout_s": 3.0},
                                environ={"HMD_PUSH_EXPO_URL": rig.fake.url}, start_thread=True)
rid = CP.request_test(rig.root)
thread_monitor.observe(IDLE)
T.check(wait_for(lambda: (answer(rig, rid) or ("",))[0] == "done", 20), "A8a. the worker thread answers a request noticed by observe()")
T.eq((sent_kinds(rig), [(e["kind"], e["ok"]) for e in events if e.get("event") == "push"]),
     (["test"], [("test", True)]), "A8b. with exactly one message sent and one line logged")
thread_monitor.close()
rig.close()

# while the send is in flight the answer already reads "sending": a slow sender is told apart from no sender
rig = Rig(devices=TWO[:1])
rig.fake.script = [{"hang": 2.0}]
slow_monitor = CP.PushMonitor(rig.root, emit=lambda event: None, config={"min_run_s": 0, "timeout_s": 10.0},
                              environ={"HMD_PUSH_EXPO_URL": rig.fake.url}, start_thread=True)
rid = CP.request_test(rig.root)
slow_monitor.observe(IDLE)
T.check(wait_for(lambda: (answer(rig, rid) or ("",))[0] == "sending", 10),
        "A8c. while Expo is slow to answer, the answer reads 'sending' (no results yet)", answer(rig, rid))
T.check(wait_for(lambda: (answer(rig, rid) or ("",))[0] == "done", 30)
        and answer(rig, rid) == ("done", [(fp(TOK1), True, None, None)]),
        "A8d. and then 'done' with the device's outcome", answer(rig, rid))
slow_monitor.close()
rig.close()

# ── A9. what the CLI uses: the registered devices, the request, its withdrawal, the paths ──
rig = Rig()
listed = CP.registered_devices(rig.root)
T.eq(listed, [{"device": fp(TOK1), "platform": "ios"}, {"device": fp(TOK2), "platform": "android"}],
     "A9a. registered_devices lists each device by fingerprint and platform, in registry order")
T.check(TOK1 not in json.dumps(listed) and TOK2 not in json.dumps(listed), "A9b. and never a token")
T.eq(CP.registered_devices(os.path.join(tmp, "nowhere")), [], "A9c. a repo with no registry has no devices")
rid = CP.request_test(rig.root)
with open(rig.path("push-test"), encoding="utf-8") as f:
    body = json.load(f)
T.check(len(rid) == 16 and all(c in "0123456789abcdef" for c in rid) and set(body) == {"v", "id", "at"}
        and body["v"] == 1 and body["id"] == rid and isinstance(body["at"], int) and abs(body["at"] - time.time()) < 5,
        "A9d. a request is {v: 1, id: 16 hex, at: epoch seconds}", body)
CP.withdraw_test_request(rig.root, "0" * 16)
T.check(os.path.exists(rig.path("push-test")), "A9e. withdrawing some other request id leaves this one alone")
CP.withdraw_test_request(rig.root, rid)
T.check(not os.path.exists(rig.path("push-test")), "A9f. withdrawing its own id removes the request")
T.eq(CP.read_test_result(rig.root, rid), None, "A9g. no result is no answer")
paths = CP.source_paths("/r")
T.check("/r/.heimdall/app/push-test" in paths and "/r/.heimdall/app/push-test.result" in paths
        and "/r/.heimdall/app/push.json" in paths and "/r/.heimdall/app/push-sender.lock" in paths,
        "A9h. source_paths names everything the sender touches, the request and the result included", paths)


def put_result(root, rid, state, results):
    directory = os.path.join(root, ".heimdall", "app")
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, "push-test.result"), "w", encoding="utf-8") as f:
        json.dump({"v": 1, "id": rid, "state": state, "results": results}, f)


# a result file is only read, never trusted: junk entries are dropped, junk fields read as absent
put_result(rig.root, "7" * 16, "done",
           [{"device": "5e0c9a77", "ok": True, "detail": "x y z", "suppressed": "elsewhere"},
            {"device": "NOT-HEX!", "ok": True, "detail": None, "suppressed": None},
            {"device": "5e0c9a78", "ok": "yes", "detail": None, "suppressed": None}, "junk", 7, None])
T.eq(CP.read_test_result(rig.root, "7" * 16),
     {"state": "done", "results": [{"device": "5e0c9a77", "ok": True, "detail": None, "suppressed": None}]},
     "A9i. a result's junk entries are dropped and its junk detail / suppressed read as absent")
T.eq(CP.read_test_result(rig.root, "8" * 16), None, "A9j. a result for another request id is no answer")
put_result(rig.root, "7" * 16, "finished", [])
T.eq(CP.read_test_result(rig.root, "7" * 16), None, "A9k. a result in a state other than sending / done is no answer")
rig.close()
print("done")
PYEOF
run_part A "$TMPROOT/part_a.py"

# ── the sender process Part B starts: a real PushMonitor with its worker thread, fed a state every 0.1 s ──
cat >"$TMPROOT/sender_host.py" <<'PYEOF'
import json
import os
import sys
import time

code, root, name, ctl, url, opts = sys.argv[1:7]
opts = json.loads(opts)
sys.path.insert(0, os.path.join(code, "test", "lib"))
import push_test_lib as T

CP = T.load("companion_push", os.path.join(code, "bin", "lib", "companion_push.py"))
S, att, A = T.state, T.attention, T.a_id
YESNO = [{"key": "yes", "label": "Yes"}, {"key": "no", "label": "No"}]


def flag(*parts):
    return os.path.join(ctl, "-".join(parts))


def emit(obj):
    with open(flag("events", name), "a", encoding="utf-8") as f:
        f.write(json.dumps(obj, sort_keys=True) + "\n")


config = {"min_run_s": 0, "timeout_s": 3.0, "coalesce_s": 1.0}
config.update(opts.get("config", {}))
monitor = CP.PushMonitor(root, emit=emit, config=config, environ={"HMD_PUSH_EXPO_URL": url}, start_thread=True)
idle = S(att("idle", A(1)))
asking = S(att("needs_input", A(2), "question", "Delete the old branch?", YESNO))
monitor.observe(idle)
open(flag("ready", name), "w").close()
# runs until told to stop -- or until nobody is left to tell it: the suite's temp dir is gone, its parent died, or ten
# minutes passed -- so a part that crashed can never leave this process behind
give_up = time.monotonic() + 600
while (not os.path.exists(flag("stop", name)) and os.path.isdir(ctl) and os.getppid() != 1
       and time.monotonic() < give_up):
    if os.path.exists(flag("question", name)):
        os.unlink(flag("question", name))
        monitor.observe(asking)
    else:
        monitor.observe(idle)
    time.sleep(0.1)
monitor.close()
PYEOF

# ── B. `hmd app push-test` against sender processes and a loopback fake Expo ──────────────
cat >"$TMPROOT/part_b.py" <<'PYEOF'
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time

code, tmp = sys.argv[1], sys.argv[2]
os.makedirs(tmp, exist_ok=True)
sys.path.insert(0, os.path.join(code, "test", "lib"))
import push_test_lib as T

STORE = T.load("companion_push_store", os.path.join(code, "bin", "lib", "companion_push_store.py"))
BIN = os.path.join(code, "bin", "heimdall-app")
HEIMDALL = os.path.join(code, "bin", "heimdall")
HOST = os.path.join(os.path.dirname(tmp), "sender_host.py")
TOK1, TOK2 = T.expo_token("a"), T.expo_token("b")
ONE = ((TOK1, "ios", "api server", None),)
TWO = ((TOK1, "ios", "api server", None), (TOK2, "android", "web app", None))
_n = [0]


def fp(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:8]


def wait_for(pred, secs):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.05)
    return pred()


def line_for(out, device, platform, word):
    """The per-token line: the device's fingerprint, its platform and the outcome word, on one line."""
    return re.search(r"^\s*%s\s+%s\s+.*%s" % (device, platform, word), out, re.M) is not None


class Case:
    """One repo with registrations written through the production store, one loopback fake Expo, and the sender
    processes (real PushMonitors) started for it."""

    def __init__(self, devices=ONE):
        _n[0] += 1
        self.root = os.path.join(tmp, "case%d" % _n[0])
        self.ctl = os.path.join(tmp, "ctl%d" % _n[0])
        os.makedirs(self.root)
        os.makedirs(self.ctl)
        self.fake = T.FakeExpo()
        for token, platform, label, events in devices:
            STORE.register(self.root, token, platform, label=label, events=events)
        self.procs = {}

    def flag(self, *parts):
        return os.path.join(self.ctl, "-".join(parts))

    def path(self, name):
        return os.path.join(self.root, ".heimdall", "app", name)

    def start_sender(self, name="a", opts=None):
        self.procs[name] = subprocess.Popen([sys.executable, HOST, code, self.root, name, self.ctl, self.fake.url,
                                             json.dumps(opts or {})])
        return wait_for(lambda: os.path.exists(self.flag("ready", name)), 30)

    def stop_sender(self, name="a"):
        proc = self.procs.pop(name, None)
        if proc is None:
            return
        open(self.flag("stop", name), "w").close()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()                                 # a child this suite started
            proc.wait()

    def sender_events(self, name="a"):
        try:
            with open(self.flag("events", name), encoding="utf-8") as f:
                return [json.loads(line) for line in f if line.strip()]
        except OSError:
            return []

    def test_pushes(self, name="a"):
        return [(e["ok"], e["detail"], e["suppressed"]) for e in self.sender_events(name)
                if e.get("event") == "push" and e.get("kind") == "test"]

    def cli(self, *args, env=None, repo=True):
        full = dict(os.environ, HMD_PUSH_EXPO_URL=self.fake.url)
        full.update(env or {})
        argv = [BIN, "push-test"] + (["--repo", self.root] if repo else []) + list(args)
        began = time.monotonic()
        p = subprocess.run(argv, capture_output=True, text=True, env=full, timeout=120)
        return p.returncode, p.stdout, p.stderr, time.monotonic() - began

    def close(self):
        for name in list(self.procs):
            self.stop_sender(name)
        self.fake.close()


def no_token(*texts):
    blob = "\n".join(texts)
    return TOK1 not in blob and TOK2 not in blob and "PushToken[" not in blob


# ── B1. nothing registered: exit 3, nothing sent, nothing left behind ──
c = Case(devices=())
rc, out, err, _ = c.cli()
T.eq(rc, 3, "B1a. no device registered: exit 3")
T.check("no device registered" in out, "B1b. and it says so", out)
T.eq((len(c.fake.requests), os.path.exists(c.path("push-test"))), (0, False), "B1c. nothing was sent and no request was left")
c.close()

# ── B2. HMD_PUSH=0: exit 5 ──
c = Case()
rc, out, err, _ = c.cli(env={"HMD_PUSH": "0"})
T.eq(rc, 5, "B2a. push switched off (HMD_PUSH=0): exit 5")
T.check("HMD_PUSH=0" in out, "B2b. and it names the switch", out)
T.eq((len(c.fake.requests), os.path.exists(c.path("push-test"))), (0, False), "B2c. nothing was sent and no request was posted")
c.close()

# ── B3. no sender answers: exit 4 within the wait, and the CLI sent nothing itself ──
c = Case()
rc, out, err, took = c.cli("--wait", "2")
T.eq(rc, 4, "B3a. no sender running: exit 4")
T.check(took < 8, "B3b. after the wait it was given, not later (%.1f s)" % took)
T.check("no push sender" in out, "B3c. and it says no sender picked the request up", out)
T.eq((len(c.fake.requests), os.path.exists(c.path("push-test")), os.path.exists(c.path("push-sender.lock"))),
     (0, False, False), "B3d. the CLI never sends and never takes the lock itself, and withdrew its request so a sender "
     "that starts later does not find it")
c.close()

# ── B3e. without --wait a missing sender is reported at the 10 s pickup deadline, not after the whole 60 s ──
c = Case()
rc, out, err, took = c.cli()
T.check(rc == 4 and 9.0 <= took < 30.0,
        "B3e. no --wait and no sender: exit 4 after the 10 s pickup deadline, not the 60 s wait (%.1f s)" % took, (rc, out))
c.close()

# ── B4. one device, a live sender: exit 0, one message of kind test, a per-token line, no token anywhere ──
c = Case()
T.check(c.start_sender("a"), "B4a. the sender process is up")
rc, out, err, _ = c.cli()
T.eq(rc, 0, "B4b. a test notification accepted: exit 0")
T.eq([(m["to"], m["data"]["kind"]) for m in c.fake.messages()], [(TOK1, "test")],
     "B4c. exactly one message reached Expo: addressed to the registered token, kind test")
T.check(line_for(out, fp(TOK1), "ios", "accepted"), "B4d. the output has one line for the device: its fingerprint, platform, accepted", out)
T.check(no_token(out, err) and not re.search(r"Exponent|ExpoPush", out + err), "B4e. the CLI's output never shows a token", out + err)
T.eq(c.test_pushes("a"), [(True, None, None)], "B4f. the sender logged one test push, ok")
leftovers = [n for n in ("push-test", "push-test.result") if os.path.exists(c.path(n))]
T.eq(leftovers, ["push-test", "push-test.result"],
     "B4g. an answered request and its result stay behind, inert (a record of the last test)")
c.close()

# ── B5. two devices: one message per token ──
c = Case(devices=TWO)
c.start_sender("a")
rc, out, err, _ = c.cli()
T.eq(rc, 0, "B5a. two devices: exit 0")
T.eq(sorted(m["to"] for m in c.fake.messages()), sorted([TOK1, TOK2]), "B5b. one message per registered token")
T.check(line_for(out, fp(TOK1), "ios", "accepted") and line_for(out, fp(TOK2), "android", "accepted"),
        "B5c. one result line per device, each with its own fingerprint and platform", out)
c.close()

# ── B6. every device gone (DeviceNotRegistered): exit 6, the registration is pruned ──
c = Case()
c.fake.unregistered.add(TOK1)
c.start_sender("a")
rc, out, err, _ = c.cli()
T.eq(rc, 6, "B6a. every device failed: exit 6")
T.check(line_for(out, fp(TOK1), "ios", "DeviceNotRegistered"), "B6b. the line names DeviceNotRegistered", out)
T.eq(STORE.load(c.root)["tokens"], [], "B6c. the dead registration was pruned from push.json")
T.check(no_token(out, err), "B6d. and no token was printed", out + err)
c.close()

# ── B7. some accepted, some gone: exit 0, both reported, only the dead one pruned ──
c = Case(devices=TWO)
c.fake.unregistered.add(TOK2)
c.start_sender("a")
rc, out, err, _ = c.cli()
T.eq(rc, 0, "B7a. one of two accepted: exit 0")
T.check(line_for(out, fp(TOK1), "ios", "accepted") and line_for(out, fp(TOK2), "android", "DeviceNotRegistered"),
        "B7b. each device reports its own outcome", out)
T.eq([e["token"] for e in STORE.load(c.root)["tokens"]], [TOK1], "B7c. only the dead registration was pruned")
c.close()

# ── B8. foreground suppression and the kind filter do not apply to a test (and do to a real question) ──
c = Case(devices=((TOK1, "ios", "api server", ["error"]),))
STORE.set_app_state(c.root, "foreground")
c.start_sender("a")
open(c.flag("question", "a"), "w").close()
T.check(wait_for(lambda: any(e.get("event") == "push" and e.get("kind") == "question" for e in c.sender_events("a")), 20),
        "B8a. contrast: the sender saw a real question")
real = [(e["suppressed"], e["ok"]) for e in c.sender_events("a") if e.get("kind") == "question"]
T.eq(real, [("disabled-kind", False)], "B8b. contrast: it was held back (the device only asked for errors)")
rc, out, err, _ = c.cli()
T.eq((rc, [m["data"]["kind"] for m in c.fake.messages()]), (0, ["test"]),
     "B8c. the test is sent anyway: the device did not ask for test and the app is in the foreground")
c.close()

# ── B9. the hourly cap still applies to a test; the 10 s spacing does not ──
c = Case()
c.start_sender("a", {"config": {"hourly_cap": 2}})
codes = [c.cli()[:3] for _ in range(3)]
T.eq([r[0] for r in codes], [0, 0, 6], "B9a. two tests in quick succession are accepted, the third hits the cap: exit 0, 0, 6")
T.check("rate-limited" in codes[2][1], "B9b. and the third says rate-limited", codes[2][1])
T.eq(len(c.fake.messages()), 2, "B9c. only two messages reached Expo")
c.close()

# ── B10. the lock: a process that owns push-sender.lock and never answers; the CLI sends nothing around it ──
c = Case()
lock_path = c.path("push-sender.lock")
fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
rc, out, err, _ = c.cli("--wait", "2")
T.eq((rc, len(c.fake.requests)), (4, 0), "B10a. another process owns the sender lock and answers nothing: exit 4, and the CLI sent nothing itself")
T.check(os.path.exists(lock_path), "B10b. the lock file is untouched")
os.close(fd)
c.close()

# ── B11. two sender processes on one repo: exactly one message per token, one answers ──
c = Case(devices=TWO)
c.start_sender("a")
c.start_sender("b")
rc, out, err, _ = c.cli()
T.eq(rc, 0, "B11a. two live senders: exit 0")
T.eq(len(c.fake.messages()), 2, "B11b. two registered tokens, two senders, still exactly one message per token")
T.eq(sorted((len(c.test_pushes("a")), len(c.test_pushes("b")))), [0, 2], "B11c. and only the owner of the lock logged it")
c.close()

# ── B12. a stale request is not served by a sender that starts later; an answered one is not served again ──
c = Case()
os.makedirs(os.path.dirname(c.path("push-test")), exist_ok=True)
with open(c.path("push-test"), "w", encoding="utf-8") as f:
    json.dump({"v": 1, "id": "9" * 16, "at": int(time.time()) - 120}, f)
c.start_sender("a")
time.sleep(1.5)
T.eq((len(c.fake.requests), c.test_pushes("a")), (0, []), "B12a. a two-minute-old request is not served by a sender that starts now")
rc, out, err, _ = c.cli()
T.eq((rc, len(c.fake.messages())), (0, 1), "B12b. a fresh request is")
c.stop_sender("a")
c.start_sender("b")
time.sleep(1.5)
T.eq(len(c.fake.messages()), 1, "B12c. and a sender restarted inside that request's life does not serve it a second time")
c.close()

# ── B13. usage ──
c = Case()
rc, out, err, _ = c.cli("--bogus")
T.check(rc == 2 and "unknown flag" in err, "B13a. an unknown flag: exit 2 and a named error", (rc, err))
rc, out, err, _ = c.cli("--wait", "abc")
T.eq(rc, 2, "B13b. a --wait that is not a number: exit 2")
T.eq([c.cli("--wait", w)[0] for w in ("0", "121", "-3")], [2, 2, 2], "B13b2. a --wait outside 1..120 seconds: exit 2")
rc, out, err, _ = c.cli("--repo", os.path.join(tmp, "no-such-repo"), repo=False)
T.check(rc == 2 and "not a directory" in err, "B13c. a --repo that is not a directory: exit 2", (rc, err))
T.eq(len(c.fake.requests), 0, "B13d. none of them sent anything")
c.close()

# ── B14. the umbrella `hmd app push-test` reaches it; the help names it and its exit codes ──
c = Case(devices=())
p = subprocess.run([HEIMDALL, "app", "push-test", "--repo", c.root], capture_output=True, text=True, timeout=120,
                   env=dict(os.environ, HMD_PUSH_EXPO_URL=c.fake.url))
T.eq(p.returncode, 3, "B14a. `hmd app push-test` dispatches to the subcommand")
h = subprocess.run([BIN, "--help"], capture_output=True, text=True, timeout=60)
T.check(h.returncode == 0 and "hmd app push-test" in h.stdout and "Exit codes (push-test)" in h.stdout,
        "B14b. `hmd app --help` documents push-test and its exit codes", h.stdout[-600:])
c.close()

# ── B15. an Expo outage is reported as its code; the sender's back-off is explained ──
c = Case()
c.fake.script = [{"status": 500, "body": {}}] * 4
c.start_sender("a", {"config": {"retry_delays": [0.05, 0.05, 0.05]}})
rc, out, err, _ = c.cli()
T.eq(rc, 6, "B15a. Expo answering 500: every device failed, exit 6")
T.check(line_for(out, fp(TOK1), "ios", "error: http-500"), "B15b. the line carries Expo's failure as a code", out)
rc, out, err, _ = c.cli()
T.eq(rc, 6, "B15c. the next test, inside the sender's back-off, is held back: exit 6")
T.check(line_for(out, fp(TOK1), "ios", "error: backoff") and "holding back" in out,
        "B15d. and its line says the sender is holding back", out)
T.eq(len(c.fake.sends()), 4, "B15e. with nothing more POSTed")
c.close()
print("done")
PYEOF
run_part B "$TMPROOT/part_b.py"

# ── C. the same CLI against the real bin/heimdall-ui ──────────────────────────────────────
cat >"$TMPROOT/part_c.py" <<'PYEOF'
import contextlib
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.request

code, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(code, "test", "lib"))
import push_test_lib as T

STORE = T.load("companion_push_store", os.path.join(code, "bin", "lib", "companion_push_store.py"))
home = os.path.join(tmp, "home")
projects = os.path.join(home, ".claude", "projects")
os.makedirs(projects)
fake = T.FakeExpo()
env = dict(os.environ, HOME=home, HEIMDALL_HOME=os.path.join(home, ".heimdall"), TMPDIR=tmp, HMD_AGENT_PROJECTS_DIR=projects,
           HMD_PUSH_EXPO_URL=fake.url, HMD_UI_COMPANION_PANELS="0", HEIMDALL_FALLBACK_ASSUME_REACHABLE="0")
for name in ("CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID", "SESSION_ID", "HMD_PUSH"):
    env.pop(name, None)
root = os.path.realpath(os.path.join(tmp, "repo"))
os.makedirs(root)
subprocess.run(["git", "init", "-q", root], check=True)
subprocess.run(["git", "-C", root, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "fixture"],
               check=True)
TOK = T.expo_token("t")
STORE.register(root, TOK, "ios", label="api server")
env["HEIMDALL_WATCH_ROOT"] = root


def wait_for(pred, secs):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.05)
    return pred()


def cli(*args):
    p = subprocess.run([os.path.join(code, "bin", "heimdall-app"), "push-test", "--repo", root] + list(args),
                       capture_output=True, text=True, env=env, timeout=150)
    return p.returncode, p.stdout, p.stderr


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


out_path, err_path = os.path.join(tmp, "ui.out"), os.path.join(tmp, "ui.err")
with open(out_path, "w") as out_f, open(err_path, "w") as err_f:
    ui = subprocess.Popen([os.path.join(code, "bin", "heimdall-ui"), "--repo", root, "--no-open"], cwd=root, env=env,
                          stdout=out_f, stderr=err_f, start_new_session=True)


def stop_ui():
    """Stop the hmd ui this part started (its own process group, nothing else). Safe to call twice."""
    if ui.poll() is not None:
        return
    with contextlib.suppress(OSError):
        os.killpg(ui.pid, signal.SIGTERM)
    try:
        ui.wait(timeout=20)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(OSError):
            os.killpg(ui.pid, signal.SIGKILL)
        ui.wait()


try:
    url = None
    if wait_for(lambda: re.search(r"^http://127\.0\.0\.1:\d+/\?token=\S+$", read(out_path), re.M) is not None, 60):
        url = re.search(r"^(http://127\.0\.0\.1:\d+)/\?token=(\S+)$", read(out_path), re.M).groups()
    T.check(url is not None, "C1. the real hmd ui is up", read(err_path)[-300:])
    if url is not None:
        # wait for its first collection pass: a GET /api/state returns only once there is a state
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        opener.open("%s/api/state?token=%s" % url, timeout=90).read()
        rc, out, err = cli("--wait", "40")
        T.eq(rc, 0, "C2. the real hmd ui's poller notices the request and serves it: exit 0")
        T.eq([(m["to"], m["data"]["kind"]) for m in fake.messages()], [(TOK, "test")],
             "C3. exactly one message reached Expo: the registered token, kind test")
        ui_err = read(err_path)
        pushed = [json.loads(m.group(1)) for m in re.finditer(r"^hmd-ui: push (\{.*\})$", ui_err, re.M)]
        T.eq([(e["kind"], e["ok"], e["suppressed"]) for e in pushed], [("test", True, None)],
             "C4. hmd ui logged one test push line, ok")
        T.check(TOK not in out + err + ui_err + read(out_path), "C5. no token in the CLI's output or in hmd ui's output")
        T.check(os.path.exists(os.path.join(root, ".heimdall", "app", "push-sender.lock")),
                "C6. hmd ui took the sender lock to serve it")
        rc2, out2, err2 = cli("--wait", "40")
        T.eq((rc2, len(fake.messages())), (0, 2), "C7. the same process, now the standing lock owner, serves the next request too")
        stop_ui()
        rc3, out3, err3 = cli("--wait", "2")
        T.eq((rc3, len(fake.messages())), (4, 2), "C8. with hmd ui gone nothing answers: exit 4, nothing more sent")
finally:
    stop_ui()
    fake.close()
print("done")
PYEOF
run_part C "$TMPROOT/part_c.py"

# ── D. the CLI module's waiting rules and wording, with a stand-in for the sender ─────────
cat >"$TMPROOT/part_d.py" <<'PYEOF'
import contextlib
import hashlib
import io
import json
import os
import re
import sys
import threading
import time

code, tmp = sys.argv[1], sys.argv[2]
os.makedirs(tmp, exist_ok=True)
sys.path.insert(0, os.path.join(code, "test", "lib"))
import push_test_lib as T

CP = T.load("companion_push", os.path.join(code, "bin", "lib", "companion_push.py"))
STORE = T.load("companion_push_store", os.path.join(code, "bin", "lib", "companion_push_store.py"))
CLI = T.load("companion_push_cli", os.path.join(code, "bin", "lib", "companion_push_cli.py"))
TOKENS = [T.expo_token(c) for c in "abcd"]
_n = [0]


def fp(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:8]


def repo(tokens=()):
    _n[0] += 1
    root = os.path.join(tmp, "repo%d" % _n[0])
    os.makedirs(root)
    for token, platform in zip(tokens, ("ios", "android", "ios", "android")):
        STORE.register(root, token, platform)
    return root


def write_result(root, rid, state, results):
    directory = os.path.join(root, ".heimdall", "app")
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, "push-test.result"), "w", encoding="utf-8") as f:
        json.dump({"v": 1, "id": rid, "state": state, "results": results}, f)


def stand_in(root, answers):
    """Plays the sender for ONE request: waits for the request file, then writes `answers` -- [(state, results)] -- in order."""
    def run():
        path = os.path.join(root, ".heimdall", "app", "push-test")
        end = time.monotonic() + 15
        while time.monotonic() < end:
            try:
                with open(path, encoding="utf-8") as f:
                    held = json.load(f)
            except (OSError, ValueError):
                time.sleep(0.02)
                continue
            for state, results in answers:
                write_result(root, held["id"], state, results)
            return
    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread


def cli_main(root, *args, env=None):
    out = io.StringIO()
    rc = CLI.main(["push-test", "--repo", root] + list(args), out=out, env={} if env is None else env)
    return rc, out.getvalue()


# ── D1. await_answer: the pickup deadline, the finish deadline, an answer that is already there ──
CLI.PICKUP_S = 0.5
root = repo()
began = time.monotonic()
got = CLI.await_answer(CP, root, "a" * 16, 5.0)
took = time.monotonic() - began
T.check(got is None and 0.4 <= took < 2.0, "D1a. nothing answers: it gives up at the pickup deadline, not after the whole wait (%.1f s)" % took)
write_result(root, "b" * 16, "sending", [])
began = time.monotonic()
got = CLI.await_answer(CP, root, "b" * 16, 1.5)
took = time.monotonic() - began
T.check(got is not None and got["state"] == "sending" and 1.3 <= took < 3.0,
        "D1b. a sender that took the request but is slow is waited for up to --wait, past the pickup deadline (%.1f s)" % took)
write_result(root, "c" * 16, "done", [{"device": "5e0c9a77", "ok": True, "detail": None, "suppressed": None}])
began = time.monotonic()
got = CLI.await_answer(CP, root, "c" * 16, 5.0)
T.check(got is not None and got["state"] == "done" and time.monotonic() - began < 0.5,
        "D1c. an answer that is done is returned at once")

# ── D2. --wait is a number of seconds in 1..120 ──
good = [CLI.wait_seconds(t) for t in ("1", "120", "2.5")]
bad = []
for text in ("nan", "inf", "0.9", "120.1", "x", "", "-1"):
    try:
        CLI.wait_seconds(text)
        bad.append(text)
    except Exception:
        continue
T.check(good == [1.0, 120.0, 2.5] and bad == [], "D2. wait_seconds takes 1..120 and refuses everything else", (good, bad))

# ── D3. a sender that took the request and never finished: exit 4, the request withdrawn ──
root = repo(TOKENS[:1])
stand_in(root, [("sending", [])])
rc, out = cli_main(root, "--wait", "2")
T.check(rc == 4 and "took the request but had not finished" in out, "D3a. a sender that never finishes: exit 4 and it says so", (rc, out))
T.check(not os.path.exists(os.path.join(root, ".heimdall", "app", "push-test")), "D3b. and the request was withdrawn")

# ── D4. the wording of every outcome, one line per device ──
root = repo(TOKENS)
unknown = "deadbeef"
stand_in(root, [("done", [
    {"device": fp(TOKENS[0]), "ok": True, "detail": None, "suppressed": None},
    {"device": fp(TOKENS[1]), "ok": False, "detail": "paused", "suppressed": None},
    {"device": fp(TOKENS[2]), "ok": False, "detail": "MessageTooBig", "suppressed": None},
    {"device": fp(TOKENS[3]), "ok": False, "detail": None, "suppressed": "rate-limited"},
    {"device": unknown, "ok": False, "detail": None, "suppressed": None}])])
rc, out = cli_main(root, "--wait", "5")
lines = {m.group(1): m.group(3) for m in re.finditer(r"^  ([0-9a-f]{8})  (\S+)\s+(.*)$", out, re.M)}
T.eq(rc, 0, "D4a. one device accepted: exit 0")
T.eq(lines, {fp(TOKENS[0]): "accepted",
             fp(TOKENS[1]): "error: paused (the sender is paused after Expo refused its credentials)",
             fp(TOKENS[2]): "error: MessageTooBig",
             fp(TOKENS[3]): "not sent (rate-limited: 20 notifications per device per hour)",
             unknown: "error: unknown"}, "D4b. each outcome in its own words: accepted, a hinted code, a bare code, rate-limited, unknown")
T.check(re.search(r"^  %s  android  error: paused" % fp(TOKENS[1]), out, re.M) and re.search(r"^  %s  \?  " % unknown, out, re.M),
        "D4c. the platform column comes from the registry; a device it does not know reads ?", out)
T.check("1 of 5 accepted" in out, "D4d. the summary counts them", out)
T.check(not any(t in out for t in TOKENS), "D4e. and no token is printed")

# ── D5. nothing accepted: exit 6; an empty answer: exit 3; the switch: exit 5; usage: exit 2 ──
root = repo(TOKENS[:1])
stand_in(root, [("done", [{"device": fp(TOKENS[0]), "ok": False, "detail": "network", "suppressed": None}])])
rc, out = cli_main(root, "--wait", "5")
T.check(rc == 6 and "0 of 1 accepted" in out and "error: network (Expo could not be reached)" in out,
        "D5a. nothing accepted: exit 6", (rc, out))
root = repo(TOKENS[:1])
stand_in(root, [("done", [])])
rc, out = cli_main(root, "--wait", "5")
T.check(rc == 3 and "no device registered" in out, "D5b. the sender found no device left: exit 3", (rc, out))
rc, out = cli_main(repo(TOKENS[:1]), env={"HMD_PUSH": "0"})
T.check(rc == 5 and "HMD_PUSH=0" in out, "D5c. HMD_PUSH=0: exit 5", (rc, out))
rc, out = cli_main(repo())
T.check(rc == 3 and "no device registered" in out and not os.path.exists(os.path.join(tmp, "repo%d" % _n[0], ".heimdall", "app", "push-test")),
        "D5c2. nothing registered: exit 3, and no request is posted", (rc, out))
T.check(CLI.main([], out=io.StringIO()) == 2 and CLI.main(["bogus"], out=io.StringIO()) == 2,
        "D5d. no subcommand, or another one: exit 2")

# ── D6. a request that cannot be posted: exit 1 and a reason, no traceback ──
if os.geteuid() != 0:
    root = repo(TOKENS[:1])
    app_dir = os.path.join(root, ".heimdall", "app")
    os.chmod(app_dir, 0o500)
    seen = io.StringIO()
    try:
        with contextlib.redirect_stderr(seen):
            rc, out = cli_main(root, "--wait", "2")
    finally:
        os.chmod(app_dir, 0o700)
    T.check(rc == 1 and "Permission denied" in seen.getvalue() and out == "",
            "D6. the app directory is read-only: exit 1 with the reason on stderr", (rc, out, seen.getvalue()))

# ── D7. Ctrl-C while waiting: exit 130, the request withdrawn ──
root = repo(TOKENS[:1])
real_await = CLI.await_answer


def interrupted(push, repo_root, request_id, wait_s):
    raise KeyboardInterrupt()


CLI.await_answer = interrupted
try:
    rc, out = cli_main(root, "--wait", "5")
finally:
    CLI.await_answer = real_await
T.check(rc == 130 and "interrupted" in out and not os.path.exists(os.path.join(root, ".heimdall", "app", "push-test")),
        "D7. Ctrl-C while waiting: exit 130, and the request is withdrawn", (rc, out))
print("done")
PYEOF
run_part D "$TMPROOT/part_d.py"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
