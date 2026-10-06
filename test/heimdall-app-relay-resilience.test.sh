#!/usr/bin/env bash
# test/heimdall-app-relay-resilience.test.sh -- part 2/3 of the heimdall-app-relay acceptance suite:
# scenarios O-U, hmdapp's docs/HANDOFF-TO-HEIMDALL-relay-ipv6-stall.md (connect robustly, retry a failed
# ack, log every ack) and the persistent-connection / state-resend rules that followed. Split out of
# test/heimdall-app-relay.test.sh (see its header); the shared prelude is test/lib/app-relay-common.sh.

# shellcheck disable=SC2034  # RELAY_SUITE_TITLE is read by test/lib/app-relay-common.sh (sourced next), never in this file
RELAY_SUITE_TITLE="heimdall-app-relay (bin/heimdall-relay-client + hmd app connect --relay oracle) -- part 2/3: connect, ack/state retry"
# shellcheck source=lib/app-relay-common.sh
# shellcheck disable=SC1091  # sourced lib is not a shellcheck input without -x
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/app-relay-common.sh"

# ═════════════════════════════════════════════════════════════════════════════
# hmdapp docs/HANDOFF-TO-HEIMDALL-relay-ipv6-stall.md -- scenarios O, O2, P, Q, R
#
# Root cause: on the operator's Mac a connect to the relay over IPv6 sometimes
# black-holes (SYN dropped, connect() hangs ~10 s) while the resolver hands
# IPv6 back FIRST, so any hmd->relay POST -- a state frame or an ack -- can sit
# in connect() past the phone's 10 s ack window, and a POST that times out was
# never retried. Three asks, one scenario group each:
#   1. connect robustly      -> O (real client, black-holed first address),
#                               O2 (bad HMD_RELAY_IP_FAMILY), P (the connect
#                               logic itself, case by case)
#   2. retry a failed ack    -> Q (real client + a relay that drops ack
#                               responses), R (the retry's timing rules, on a
#                               clock the harness steps by hand)
#   3. log every ack         -> Q and R (ack_sent for every command)
#
# A true black hole cannot be built from userland on loopback portably (a full
# accept queue stalls Linux but not macOS), so test/lib/fake-relay.py's
# `netfault` mode and install_netfault() emulate one at the stdlib's resolver
# and blocking-connect calls -- below the client, so the pre-fix client stalls
# on exactly the same table the fixed one sails through.
# ═════════════════════════════════════════════════════════════════════════════


# ── Scenario O: the REAL client against a relay whose FIRST resolved address
# black-holes. hmd-relay.test resolves to [::1 black-holed, 127.0.0.1 answering]
# below the client; against the pre-fix client pair/init alone then waits out
# the whole 15 s connect timeout before it ever reaches IPv4 ─────────────────
REPO_O="$(make_repo)"
PORT_O_RELAY="$(free_port)"
PORT_O_UI="$(free_port)"
LOG_O="$TMPROOT/o.log"; CTL_O="$TMPROOT/o.ctl"
mkdir -p "$LOG_O" "$CTL_O"

python3 "$FAKE_RELAY" serve "$PORT_O_RELAY" --log "$LOG_O" --ctl "$CTL_O" >"$TMPROOT/o.srv.out" 2>&1 &
SRV_O=$!
PIDS+=("$SRV_O")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_O_RELAY))==0 else 1)" && break
  sleep 0.1
done

CLIENT_O_OUT="$TMPROOT/o.client.out"
EVENT_LOG_O="$REPO_O/.heimdall/app/relay-events.jsonl"
python3 "$FAKE_RELAY" netfault --host hmd-relay.test --addrs '::1!,127.0.0.1' -- \
  "$RELAY_CLIENT_RUN" --relay "http://hmd-relay.test:$PORT_O_RELAY" --repo "$REPO_O" --ui-port "$PORT_O_UI" \
  >"$CLIENT_O_OUT" 2>"$TMPROOT/o.client.err" &
CLIENT_O=$!
PIDS+=("$CLIENT_O")

if wait_for "$CLIENT_O_OUT" '"event":"device_bound"' 8; then
  ok "scenario O: paired and bound through a relay name whose first address black-holes (pair/init + stream never waited it out)"
else
  bad "scenario O: never bound within 8 s -- a connect waited out the black-holed first address: $(tail -3 "$TMPROOT/o.client.err" 2>/dev/null)"
fi
wait_for_count "$LOG_O/frames.ndjson" 1 '"type":"state"' 10 >/dev/null 2>&1 || true
wait_for "$EVENT_LOG_O" '"event":"state_sent"' 10 || true

O_CHECK="$TMPROOT/o.check.out"
python3 - "$EVENT_LOG_O" >"$O_CHECK" 2>"$TMPROOT/o.check.err" <<'PYEOF'
import calendar
import json
import sys
import time

events = []
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except ValueError:
            continue  # the client is still running -- a half-written last line


def ts(event):
    t = event["ts"]
    return calendar.timegm(time.strptime(t[:19], "%Y-%m-%dT%H:%M:%S")) + int(t[20:23]) / 1000.0


connects = [e for e in events if e.get("event") == "connect"]
labels = {str(e.get("for")) for e in connects}
print("RESULT o_connect_count %d" % len(connects))
print("RESULT o_has_pair_stream_frames %s" % ({"pair", "stream", "frames"} <= labels))
print("RESULT o_families %s" % ",".join(sorted({str(e.get("family")) for e in connects})))
print("RESULT o_attempts %s" % ",".join(sorted({str(e.get("attempts")) for e in connects})))
print("RESULT o_max_connect_ms %d" % max((e["ms"] for e in connects if isinstance(e.get("ms"), int)), default=-1))

# POST /frames end to end: the connect's own ms plus the time from that connect
# event to the state_sent that is only emitted once the response is in
post_ms = -1
for i, e in enumerate(events):
    if e.get("event") == "connect" and e.get("for") == "frames":
        sent = next((s for s in events[i + 1:] if s.get("event") == "state_sent"), None)
        if sent is not None:
            post_ms = int(e["ms"] + (ts(sent) - ts(e)) * 1000)
            break
print("RESULT o_post_frames_ms %d" % post_ms)
PYEOF

check_res "$O_CHECK" o_has_pair_stream_frames True "scenario O: a connect event was logged for each of pair, stream and frames"
check_res "$O_CHECK" o_families ipv4 "scenario O: every connection went out over IPv4 -- the black-holed IPv6 address never won"
check_res "$O_CHECK" o_attempts 1 "scenario O: every connection needed exactly one attempt (IPv4 is tried first, IPv6 never raced in)"
O_MAX_MS="$(res "$O_CHECK" o_max_connect_ms)"
if [ -n "$O_MAX_MS" ] && [ "$O_MAX_MS" -ge 0 ] && [ "$O_MAX_MS" -lt 1000 ]; then
  ok "scenario O: the slowest connect took ${O_MAX_MS} ms (< 1000 ms, the handoff's 'v4 within ~1 s')"
else
  bad "scenario O: slowest connect was '$O_MAX_MS' ms, want 0..999"
fi
check_res_between "$O_CHECK" o_post_frames_ms 0 2000 "scenario O: POST /frames completed in under 2 s with IPv6 black-holed (handoff acceptance)"
if [ ! -s "$TMPROOT/o.client.err" ]; then
  ok "scenario O: the client wrote nothing to stderr (no connect thread died with a traceback)"
else
  bad "scenario O: the client wrote to stderr: $(head -5 "$TMPROOT/o.client.err")"
fi

kill "$CLIENT_O" 2>/dev/null
wait "$CLIENT_O" 2>/dev/null
kill "$SRV_O" 2>/dev/null
wait "$SRV_O" 2>/dev/null

# ── Scenario O2: HMD_RELAY_IP_FAMILY with a value the knob does not know is a
# loud `error` event naming it -- never silently swallowed -- and the client
# falls back to auto and still works ────────────────────────────────────────
REPO_O2="$(make_repo)"
PORT_O2_RELAY="$(free_port)"
PORT_O2_UI="$(free_port)"
LOG_O2="$TMPROOT/o2.log"; CTL_O2="$TMPROOT/o2.ctl"
mkdir -p "$LOG_O2" "$CTL_O2"

python3 "$FAKE_RELAY" serve "$PORT_O2_RELAY" --log "$LOG_O2" --ctl "$CTL_O2" >"$TMPROOT/o2.srv.out" 2>&1 &
SRV_O2=$!
PIDS+=("$SRV_O2")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_O2_RELAY))==0 else 1)" && break
  sleep 0.1
done

CLIENT_O2_OUT="$TMPROOT/o2.client.out"
HMD_RELAY_IP_FAMILY=bogus "$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$PORT_O2_RELAY" --repo "$REPO_O2" --ui-port "$PORT_O2_UI" \
  >"$CLIENT_O2_OUT" 2>"$TMPROOT/o2.client.err" &
CLIENT_O2=$!
PIDS+=("$CLIENT_O2")

if wait_for_event "$CLIENT_O2_OUT" "error" "HMD_RELAY_IP_FAMILY" 10; then
  ok "scenario O2: HMD_RELAY_IP_FAMILY=bogus produced an error event naming the knob"
else
  bad "scenario O2: HMD_RELAY_IP_FAMILY=bogus was swallowed silently -- no error event named it"
fi
if wait_for "$CLIENT_O2_OUT" '"event":"device_bound"' 10; then
  ok "scenario O2: the client fell back to auto and still paired"
else
  bad "scenario O2: the client did not come up after a bad HMD_RELAY_IP_FAMILY"
fi

kill "$CLIENT_O2" 2>/dev/null
wait "$CLIENT_O2" 2>/dev/null
kill "$SRV_O2" 2>/dev/null
wait "$SRV_O2" 2>/dev/null

# ── Scenario P: the connect logic itself, case by case. Imports the client and
# fake-relay.py in one process and drives `_connect(...).connect()` -- the very
# call every request and the stream go through -- with install_netfault()
# standing in for the network. Every case reads the same way against the
# pre-fix client (serial create_connection), which is what makes the failures
# below meaningful ──────────────────────────────────────────────────────────
HE_OUT_P="$TMPROOT/p.he.out"
python3 - "$RELAY_CLIENT_RUN" "$FAKE_RELAY" >"$HE_OUT_P" 2>"$TMPROOT/p.he.err" <<'PYEOF'
import contextlib
import io
import json
import os
import socket
import ssl
import sys
import threading
import time
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

client_path, fake_relay_path = sys.argv[1:3]
HOST = "hmd-relay.test"
V4, V6 = socket.AF_INET, socket.AF_INET6
FAMILY_NAME = {V4: "ipv4", V6: "ipv6"}


def load(path, name, env=None):
    """Import a script by path (bin/heimdall-relay-client has no .py suffix, hence
    the explicit SourceFileLoader) with `env` applied for the duration of the
    import only -- the client reads its HMD_RELAY_* knobs once, at import."""
    env = env or {}
    saved = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    try:
        loader = SourceFileLoader(name, path)
        mod = module_from_spec(spec_from_loader(name, loader))
        loader.exec_module(mod)
        return mod
    finally:
        for k, old in saved.items():
            if old is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = old


fake_relay = load(fake_relay_path, "fake_relay_under_harness")
client = load(client_path, "hmd_relay_client_he_auto")
client_v4 = load(client_path, "hmd_relay_client_he_v4", {"HMD_RELAY_IP_FAMILY": "4"})
client_v6 = load(client_path, "hmd_relay_client_he_v6", {"HMD_RELAY_IP_FAMILY": "6"})


def v6_loopback_usable():
    try:
        probe = socket.socket(V6, socket.SOCK_STREAM)
    except OSError:
        return False
    try:
        probe.bind(("::1", 0))
        return True
    except OSError:
        return False
    finally:
        probe.close()


def open_listeners():
    """A v4 listener on 127.0.0.1:P and, where this host has IPv6 loopback, a v6
    listener on [::1]:P -- the SAME port, because getaddrinfo(host, port) hands
    every address of a name the one port."""
    want_v6 = v6_loopback_usable()
    for _ in range(50):
        l4 = socket.socket(V4, socket.SOCK_STREAM)
        l4.bind(("127.0.0.1", 0))
        l4.listen(16)
        port = l4.getsockname()[1]
        if not want_v6:
            return l4, None, port
        l6 = socket.socket(V6, socket.SOCK_STREAM)
        try:
            l6.bind(("::1", port))
            l6.listen(16)
            return l4, l6, port
        except OSError:
            l6.close()
            l4.close()
    raise SystemExit("no free v4+v6 loopback port pair")


def closed_port():
    s = socket.socket(V4, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def run_case(mod, table, port, timeout=3.0, scheme="http", conn_hook=None, resolver=None):
    """Resolve HOST through `table` (see fake-relay.py's NetFault) and connect;
    `resolver`, when given, then replaces the patched getaddrinfo (restore()
    puts the real one back either way)."""
    fault = fake_relay.install_netfault(HOST, table)
    if resolver is not None:
        socket.getaddrinfo = resolver
    out = io.StringIO()
    parsed = mod._split_relay("%s://%s:%d" % (scheme, HOST, port))
    result = {"ok": False, "family": None, "error": "", "local_port": None}
    t0 = time.monotonic()
    conn = mod._connect(parsed, timeout=timeout)
    if conn_hook is not None:
        conn_hook(conn)
    try:
        with contextlib.redirect_stdout(out):
            conn.connect()
        result["ok"] = True
        result["family"] = FAMILY_NAME.get(conn.sock.family, "?")
        result["local_port"] = conn.sock.getsockname()[1]
    except OSError as e:
        result["error"] = str(e).replace("\n", " ")
    finally:
        result["ms"] = int((time.monotonic() - t0) * 1000)
        conn.close()
        fault.restore()
    result["attempted"] = list(fault.attempted)
    result["events"] = [json.loads(l) for l in out.getvalue().splitlines() if l.strip()]
    return result


def show(tag, r):
    print("RESULT %s_ok %s" % (tag, r["ok"]))
    print("RESULT %s_ms %d" % (tag, r["ms"]))
    print("RESULT %s_family %s" % (tag, r["family"]))
    print("RESULT %s_attempted %s" % (tag, ",".join(r["attempted"])))
    print("RESULT %s_error %s" % (tag, r["error"]))
    print("RESULT %s_local_port %s" % (tag, r["local_port"]))
    connects = [e for e in r["events"] if e.get("event") == "connect"]
    print("RESULT %s_connect_events %d" % (tag, len(connects)))
    if connects:
        print("RESULT %s_connect_event %s" % (tag, json.dumps(connects[0], sort_keys=True)))


l4, l6, PORT = open_listeners()
print("RESULT have_v6 %s" % (l6 is not None))

# c1: the resolver answers IPv6 first and IPv6 black-holes -- the operator's Mac
show("c1", run_case(client, [(V6, "::1", True), (V4, "127.0.0.1", False)], PORT))
# c2: same family, first address black-holed -- the second is raced in after the stagger
show("c2", run_case(client, [(V4, "127.0.0.2", True), (V4, "127.0.0.1", False)], PORT))
# c3: IPv4 black-holed instead -- IPv6 must rescue it (needs IPv6 loopback)
if l6 is not None:
    show("c3", run_case(client, [(V4, "127.0.0.1", True), (V6, "::1", False)], PORT))
# c4: HMD_RELAY_IP_FAMILY=4 considers IPv4 only -- a black-holed IPv4 is NOT rescued by IPv6
show("c4", run_case(client_v4, [(V4, "127.0.0.1", True), (V6, "::1", False)], PORT, timeout=1.0))
# c5: HMD_RELAY_IP_FAMILY=6 considers IPv6 only -- IPv4 is never tried although it answers
show("c5", run_case(client_v6, [(V4, "127.0.0.1", False), (V6, "::1", False)], PORT))
# c6: nothing answers (every address refuses) -- one error that names each family tried
show("c6", run_case(client, [(V6, "::1", False), (V4, "127.0.0.1", False)], closed_port()))
# c7: every address black-holed -- bounded by the ONE overall timeout, not one timeout per address
show("c7", run_case(client, [(V4, "127.0.0.1", True), (V6, "::1", True)], PORT, timeout=1.0))
# c8: HTTPS -- the TLS handshake is still aimed at the NAME, never at the winning IP.
# ssl.SSLContext.wrap_socket is patched at the CLASS, so this reads the same
# however a client builds its connection
recorded = {}
real_wrap_socket = ssl.SSLContext.wrap_socket


def recording_wrap_socket(self, sock, *args, server_hostname=None, **kwargs):
    recorded["server_hostname"] = server_hostname
    raise ssl.SSLError("recording wrap_socket: handshake intentionally not attempted")


ssl.SSLContext.wrap_socket = recording_wrap_socket
try:
    show("c8", run_case(client, [(V4, "127.0.0.1", False)], PORT, scheme="https"))
finally:
    ssl.SSLContext.wrap_socket = real_wrap_socket
print("RESULT c8_server_hostname %s" % recorded.get("server_hostname"))

# c9: a source address set on the connection is honoured -- bound to a port picked up front
bind_port = closed_port()
show("c9", run_case(client, [(V4, "127.0.0.1", False)], PORT,
                    conn_hook=lambda conn: setattr(conn, "source_address", ("127.0.0.1", bind_port))))
print("RESULT c9_bind_port %d" % bind_port)

# c10: the OS refuses to start a thread for the first address -- that address just counts as failed
real_start = threading.Thread.start
start_failures = []


def failing_start(self):
    if self.name == "relay-connect" and not start_failures:
        start_failures.append(self.name)
        raise RuntimeError("can't start new thread")
    return real_start(self)


threading.Thread.start = failing_start
try:
    show("c10", run_case(client, [(V4, "127.0.0.2", False), (V4, "127.0.0.1", False)], PORT))
finally:
    threading.Thread.start = real_start

# c11: the resolver comes back with nothing at all
show("c11", run_case(client, [(V4, "127.0.0.1", False)], PORT,
                     resolver=lambda host, port, family=0, type=0, proto=0, flags=0: []))

# c12: an address that finally connects AFTER the race was decided closes itself -- the
# listener it reached sees EOF at once, not a connection left dangling (needs IPv6 loopback)
if l6 is not None:
    l4.setblocking(False)
    while True:
        try:
            l4.accept()
        except BlockingIOError:
            break  # backlog drained: only c12's slow loser can be accepted from here on
    l4.settimeout(4.0)
    show("c12", run_case(client, [(V4, "127.0.0.1", False, 0.8), (V6, "::1", False)], PORT))
    try:
        loser, _addr = l4.accept()
        loser.settimeout(4.0)
        print("RESULT c12_loser_closed %s" % (loser.recv(1) == b""))
        loser.close()
    except OSError as e:
        print("RESULT c12_loser_closed %s" % e)

# how the knob's value is read: empty means unset, whitespace is trimmed, anything else is invalid
client_empty = load(client_path, "hmd_relay_client_he_empty", {"HMD_RELAY_IP_FAMILY": ""})
client_spaced = load(client_path, "hmd_relay_client_he_spaced", {"HMD_RELAY_IP_FAMILY": " 6 "})
client_bogus = load(client_path, "hmd_relay_client_he_bogus", {"HMD_RELAY_IP_FAMILY": "ipv6"})
print("RESULT env_empty %s/%s" % (client_empty.IP_FAMILY, client_empty.IP_FAMILY_VALID))
print("RESULT env_spaced %s/%s" % (client_spaced.IP_FAMILY, client_spaced.IP_FAMILY_VALID))
print("RESULT env_bogus %s/%s" % (client_bogus.IP_FAMILY, client_bogus.IP_FAMILY_VALID))

l4.close()
if l6 is not None:
    l6.close()
sys.exit(0)
PYEOF
HE_RC_P=$?

if [ "$HE_RC_P" -eq 0 ]; then
  ok "scenario P: connect-logic harness ran to completion"
else
  bad "scenario P: connect-logic harness exited $HE_RC_P -- $(tail -3 "$TMPROOT/p.he.err")"
fi

check_res "$HE_OUT_P" c1_family ipv4 "P/c1: IPv6 first and black-holed -- the connection went out over IPv4"
check_res_between "$HE_OUT_P" c1_ms 0 1000 "P/c1: ...in under 1 s ms (the pre-fix serial connect waits out the black hole first)"
check_res "$HE_OUT_P" c1_attempted 127.0.0.1 "P/c1: IPv4 is tried first -- no attempt is ever spent on the black-holed IPv6 address"
C1_EVENT="$(res "$HE_OUT_P" c1_connect_event)"
if printf '%s' "$C1_EVENT" | python3 -c '
import json, sys
e = json.load(sys.stdin)
sys.exit(0 if (e.get("event") == "connect" and e.get("family") == "ipv4" and isinstance(e.get("ms"), int)
               and isinstance(e.get("dns_ms"), int) and e.get("attempts") == 1 and isinstance(e.get("for"), str)) else 1)
' 2>/dev/null; then
  ok "P/c1: exactly one connect event naming family=ipv4, ms, dns_ms, attempts=1 and what it was for"
else
  bad "P/c1: connect event missing or malformed (got '$C1_EVENT')"
fi
check_res "$HE_OUT_P" c1_connect_events 1 "P/c1: one connection emitted exactly one connect event"

check_res "$HE_OUT_P" c2_ok True "P/c2: same-family race -- connected although the first address black-holes"
check_res "$HE_OUT_P" c2_attempted "127.0.0.2,127.0.0.1" "P/c2: the second address was started only after the first (in resolver order)"
check_res_between "$HE_OUT_P" c2_ms 200 1500 "P/c2: the second address was raced in after the ~250 ms stagger, not after the 3 s timeout"
C2_EVENT="$(res "$HE_OUT_P" c2_connect_event)"
if printf '%s' "$C2_EVENT" | python3 -c '
import json, sys
e = json.load(sys.stdin)
sys.exit(0 if e.get("event") == "connect" and e.get("attempts") == 2 else 1)
' 2>/dev/null; then
  ok "P/c2: the connect event reports attempts=2 (a fallback happened)"
else
  bad "P/c2: connect event does not report attempts=2 (got '$C2_EVENT')"
fi

if [ "$(res "$HE_OUT_P" have_v6)" = "True" ]; then
  check_res "$HE_OUT_P" c3_family ipv6 "P/c3: IPv4 black-holed -- IPv6 rescued the connection"
  check_res_between "$HE_OUT_P" c3_ms 200 1500 "P/c3: ...after the ~250 ms stagger"
  C3_EVENT="$(res "$HE_OUT_P" c3_connect_event)"
  if printf '%s' "$C3_EVENT" | python3 -c '
import json, sys
e = json.load(sys.stdin)
sys.exit(0 if e.get("family") == "ipv6" and e.get("attempts") == 2 else 1)
' 2>/dev/null; then
    ok "P/c3: the connect event names family=ipv6 and attempts=2"
  else
    bad "P/c3: connect event does not name ipv6/attempts=2 (got '$C3_EVENT')"
  fi
else
  skip "P/c3: IPv4-black-holed -> IPv6 rescue: this host has no IPv6 loopback"
fi

check_res "$HE_OUT_P" c4_attempted 127.0.0.1 "P/c4: HMD_RELAY_IP_FAMILY=4 never attempts an IPv6 address"
check_res "$HE_OUT_P" c4_ok False "P/c4: HMD_RELAY_IP_FAMILY=4 does not fall back to IPv6 when IPv4 black-holes"
check_res "$HE_OUT_P" c5_attempted "::1" "P/c5: HMD_RELAY_IP_FAMILY=6 never attempts an IPv4 address, though one answers"

check_res "$HE_OUT_P" c6_ok False "P/c6: every address refusing is an error, not a hang"
check_res_between "$HE_OUT_P" c6_ms 0 1000 "P/c6: ...reported promptly (ms)"
C6_ERROR="$(res "$HE_OUT_P" c6_error)"
case "$C6_ERROR" in
  *ipv4*ipv6*|*ipv6*ipv4*) ok "P/c6: the error names every family tried ($C6_ERROR)" ;;
  *) bad "P/c6: the error does not name both families (got '$C6_ERROR')" ;;
esac

check_res "$HE_OUT_P" c7_ok False "P/c7: every address black-holed is an error"
check_res_between "$HE_OUT_P" c7_ms 0 1600 "P/c7: bounded by the one overall 1 s timeout, not 1 s per address (ms)"
case "$(res "$HE_OUT_P" c7_error)" in
  *"timed out"*) ok "P/c7: the error says the attempts timed out" ;;
  *) bad "P/c7: error does not say timed out (got '$(res "$HE_OUT_P" c7_error)')" ;;
esac

check_res "$HE_OUT_P" c8_server_hostname hmd-relay.test "P/c8: HTTPS verifies the certificate against the relay NAME, not the IP it connected to"

check_res "$HE_OUT_P" c9_ok True "P/c9: a connection with a source address still connects"
C9_PORT="$(res "$HE_OUT_P" c9_local_port)"
C9_BIND="$(res "$HE_OUT_P" c9_bind_port)"
if [ -n "$C9_BIND" ] && [ "$C9_PORT" = "$C9_BIND" ]; then
  ok "P/c9: ...from the source port it asked for ($C9_PORT)"
else
  bad "P/c9: local port was '$C9_PORT', wanted the requested source port '$C9_BIND'"
fi

check_res "$HE_OUT_P" c10_ok True "P/c10: no thread could be started for the first address -> it counts as failed and the next still connects"
check_res "$HE_OUT_P" c10_attempted 127.0.0.1 "P/c10: ...the address whose thread never started was never attempted"
C10_EVENT="$(res "$HE_OUT_P" c10_connect_event)"
if printf '%s' "$C10_EVENT" | python3 -c '
import json, sys
e = json.load(sys.stdin)
sys.exit(0 if e.get("attempts") == 2 else 1)
' 2>/dev/null; then
  ok "P/c10: ...and the connect event counts both addresses as attempts"
else
  bad "P/c10: connect event does not report attempts=2 (got '$C10_EVENT')"
fi

check_res "$HE_OUT_P" c11_ok False "P/c11: a resolver that finds no address at all is an error, not a hang"
case "$(res "$HE_OUT_P" c11_error)" in
  *"no IPv4/IPv6 address"*) ok "P/c11: ...and the error says so" ;;
  *) bad "P/c11: error does not say no address was found (got '$(res "$HE_OUT_P" c11_error)')" ;;
esac
check_res_between "$HE_OUT_P" c11_ms 0 1000 "P/c11: ...reported at once (ms)"

if [ "$(res "$HE_OUT_P" have_v6)" = "True" ]; then
  check_res "$HE_OUT_P" c12_family ipv6 "P/c12: a slow IPv4 connect lost the race to the faster IPv6 one"
  check_res "$HE_OUT_P" c12_loser_closed True "P/c12: ...and when the slow connect finally completed it closed itself (the listener saw EOF)"
else
  skip "P/c12: late-connecting loser closes itself: this host has no IPv6 loopback"
fi

check_res "$HE_OUT_P" env_empty "auto/True" "P: HMD_RELAY_IP_FAMILY= (empty) means unset -- auto, no complaint"
check_res "$HE_OUT_P" env_spaced "6/True" "P: HMD_RELAY_IP_FAMILY=' 6 ' is trimmed to 6"
check_res "$HE_OUT_P" env_bogus "auto/False" "P: HMD_RELAY_IP_FAMILY=ipv6 is not a value of the knob -- auto, flagged invalid"

if [ ! -s "$TMPROOT/p.he.err" ]; then
  ok "P: the harness wrote nothing to stderr (no connect thread died with a traceback)"
else
  bad "P: the harness wrote to stderr: $(head -5 "$TMPROOT/p.he.err")"
fi

# ── Scenario Q: a failed ack POST is retried -- the SAME sealed envelope, a
# bounded number of times -- and every command line is followed by ack_sent
# lines. fail-ack-posts=N makes the fake relay read the next N ack POSTs in
# full and drop the connection with no response (a lost response, the case that
# turns a naive retry into a duplicate). Needs real seal/open ───────────────
send_device_command() {
  # send_device_command CTLDIR FILENUM SESSION_ID KEY_B64 SEQ TEXT -- seals a
  # send-message command as the paired device and queues it for the relay's
  # stream to push to the client
  local ctl="$1" num="$2" sid="$3" key="$4" seq="$5" text="$6" seal nonce ct
  seal="$(python3 "$FAKE_RELAY" device seal --key-b64 "$key" --seq "$seq" --sender device \
    --text "{\"action\":\"send-message\",\"params\":{\"text\":\"$text\"}}")"
  nonce="$(printf '%s' "$seal" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nonce_b64"])')"
  ct="$(printf '%s' "$seal" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ciphertext_b64"])')"
  python3 "$FAKE_RELAY" device envelope --session-id "$sid" --seq "$seq" --sender device \
    --type command --nonce "$nonce" --ciphertext "$ct" > "$ctl/$num.json"
}

if [ "$E2E_PRESENT" = true ]; then
  REPO_Q="$(make_repo)"
  PORT_Q_RELAY="$(free_port)"
  PORT_Q_UI="$(free_port)"
  LOG_Q="$TMPROOT/q.log"; CTL_Q="$TMPROOT/q.ctl"
  mkdir -p "$LOG_Q" "$CTL_Q"

  python3 "$FAKE_RELAY" serve "$PORT_Q_RELAY" --log "$LOG_Q" --ctl "$CTL_Q" >"$TMPROOT/q.srv.out" 2>&1 &
  SRV_Q=$!
  PIDS+=("$SRV_Q")
  for _ in $(seq 1 50); do
    python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_Q_RELAY))==0 else 1)" && break
    sleep 0.1
  done

  DEVQ_KEY_JSON="$(python3 "$FAKE_RELAY" device keygen)"
  DEVQ_PRIV_B64="$(printf '%s' "$DEVQ_KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["priv_b64"])')"
  DEVQ_PUB_B64="$(printf '%s' "$DEVQ_KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pub_b64"])')"
  printf '%s' "$DEVQ_PUB_B64" > "$CTL_Q/bind-device"

  CLIENT_Q_OUT="$TMPROOT/q.client.out"
  EVENT_LOG_Q="$REPO_Q/.heimdall/app/relay-events.jsonl"
  "$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$PORT_Q_RELAY" --repo "$REPO_Q" --ui-port "$PORT_Q_UI" \
    >"$CLIENT_Q_OUT" 2>"$TMPROOT/q.client.err" &
  CLIENT_Q=$!
  PIDS+=("$CLIENT_Q")

  wait_for "$CLIENT_Q_OUT" '"event":"pair_init"' 10 || true
  SID_Q="$(python3 -c "
import json
for line in open('$CLIENT_Q_OUT'):
    o = json.loads(line)
    if o.get('event') == 'pair_init':
        print(o['qr']['session_id']); break
" 2>/dev/null)"
  HMD_PUB_Q="$(python3 -c "
import json
for line in open('$CLIENT_Q_OUT'):
    o = json.loads(line)
    if o.get('event') == 'pair_init':
        print(o['qr']['hmd_pubkey']); break
" 2>/dev/null)"
  if wait_for "$CLIENT_Q_OUT" '"event":"device_bound"' 10 && [ -n "$SID_Q" ] && [ -n "$HMD_PUB_Q" ]; then
    ok "scenario Q: relay-client paired (session key derivable)"
  else
    bad "scenario Q: relay-client never paired -- the rest of Q cannot run: $(tail -3 "$TMPROOT/q.client.err" 2>/dev/null)"
  fi
  SESSION_KEY_Q="$(python3 "$FAKE_RELAY" device derive --dev-priv-b64 "$DEVQ_PRIV_B64" --hmd-pub-b64 "$HMD_PUB_Q" --session-id "$SID_Q" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["key_b64"])')"

  # 1: the first two ack POSTs are dropped, the third gets through
  : > "$CTL_Q/fail-ack-posts=2"
  send_device_command "$CTL_Q" 001 "$SID_Q" "$SESSION_KEY_Q" 1 "ack retry probe"
  ACK_Q1_JSON="$(wait_for_ack_of_seq "$LOG_Q/frames.ndjson" "$SESSION_KEY_Q" 1 15)"
  if [ -n "$ACK_Q1_JSON" ]; then
    ok "scenario Q: the ack for seq=1 reached the relay after two dropped POSTs"
  else
    bad "scenario Q: no ack for seq=1 ever reached the relay -- a failed ack POST was never retried"
  fi
  wait_for_count "$EVENT_LOG_Q" 3 '"event":"ack_sent".*"of_seq":1,' 5 || true

  # 2: more drops than the bounded retry will spend -- it gives up after 3 tries, the client lives on
  : > "$CTL_Q/fail-ack-posts=9"
  send_device_command "$CTL_Q" 002 "$SID_Q" "$SESSION_KEY_Q" 2 "ack gives up"
  wait_for_count "$EVENT_LOG_Q" 3 '"event":"ack_sent".*"of_seq":2,' 15 || true
  sleep 2
  ACK_SENT_Q2="$(count_matching "$EVENT_LOG_Q" '"event":"ack_sent".*"of_seq":2,')"
  if [ "$ACK_SENT_Q2" -eq 3 ]; then
    ok "scenario Q: a permanently failing ack is tried exactly 3 times, then abandoned (no 4th attempt after 2 s)"
  else
    bad "scenario Q: expected exactly 3 ack_sent attempts for seq=2, got $ACK_SENT_Q2"
  fi
  rm -f "$CTL_Q"/fail-ack-posts=*

  # 3: the client is still alive and acks the next command on the first try
  send_device_command "$CTL_Q" 003 "$SID_Q" "$SESSION_KEY_Q" 3 "client survives"
  ACK_Q3_JSON="$(wait_for_ack_of_seq "$LOG_Q/frames.ndjson" "$SESSION_KEY_Q" 3 10)"
  if [ -n "$ACK_Q3_JSON" ]; then
    ok "scenario Q: after an abandoned ack the client kept running and acked the next command"
  else
    bad "scenario Q: the client never acked seq=3 after abandoning seq=2's ack"
  fi

  # 4: a command that fails to decrypt is acked (and the ack logged) like any other
  SEAL_Q4_JSON="$(python3 "$FAKE_RELAY" device seal --key-b64 "$SESSION_KEY_Q" --seq 4 --sender device \
    --text '{"action":"send-message","params":{"text":"forged"}}')"
  NONCE_Q4="$(printf '%s' "$SEAL_Q4_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nonce_b64"])')"
  CT_Q4_GOOD="$(printf '%s' "$SEAL_Q4_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ciphertext_b64"])')"
  CT_Q4="$(python3 -c "
import base64, sys
raw = bytearray(base64.b64decode(sys.argv[1]))
raw[0] ^= 0x01
print(base64.b64encode(bytes(raw)).decode('ascii'))
" "$CT_Q4_GOOD")"
  python3 "$FAKE_RELAY" device envelope --session-id "$SID_Q" --seq 4 --sender device \
    --type command --nonce "$NONCE_Q4" --ciphertext "$CT_Q4" > "$CTL_Q/004.json"
  wait_for_count "$EVENT_LOG_Q" 1 '"event":"ack_sent".*"of_seq":4,' 10 || true

  Q_CHECK="$TMPROOT/q.check.out"
  python3 - "$EVENT_LOG_Q" "$LOG_Q/frames.ndjson" "$LOG_Q/frames-dropped.ndjson" >"$Q_CHECK" 2>"$TMPROOT/q.check.err" <<'PYEOF'
import json
import sys

log_path, frames_path, dropped_path = sys.argv[1:4]


def load_lines(path):
    try:
        with open(path, encoding="utf-8") as f:
            return [l.rstrip("\n") for l in f if l.strip()]
    except OSError:
        return []


def csv(values):
    return ",".join(str(v) for v in values)


events = []
for line in load_lines(log_path):
    try:
        events.append(json.loads(line))
    except ValueError:
        continue


def acks_of(seq):
    return [e for e in events if e.get("event") == "ack_sent" and e.get("of_seq") == seq]


def ack_frames(path):
    out = []
    for line in load_lines(path):
        try:
            env = json.loads(line)
        except ValueError:
            continue
        if env.get("type") == "ack":
            out.append(line)
    return out


def with_seq(lines, seq):
    return [l for l in lines if json.loads(l).get("seq") == seq]


delivered = ack_frames(frames_path)
dropped = ack_frames(dropped_path)

a1, a2, a3, a4 = acks_of(1), acks_of(2), acks_of(3), acks_of(4)

# command 1: two dropped POSTs, then success -- one delivered ack, same envelope every time
print("RESULT q1_attempts %s" % csv(e["attempt"] for e in a1))
print("RESULT q1_ok %s" % csv(e["ok"] for e in a1))
print("RESULT q1_delivered %s" % csv(e["delivered"] for e in a1))
print("RESULT q1_one_seq %s" % (bool(a1) and len({e["seq"] for e in a1}) == 1))
print("RESULT q1_id %s" % (bool(a1) and all(isinstance(e.get("id"), str) and e["id"] for e in a1)))
print("RESULT q1_ms_int %s" % (bool(a1) and all(isinstance(e.get("ms"), int) and e["ms"] >= 0 for e in a1)))
q1_seq = a1[0]["seq"] if a1 else None
d1, x1 = with_seq(delivered, q1_seq), with_seq(dropped, q1_seq)
print("RESULT q1_delivered_frames %d" % len(d1))
print("RESULT q1_dropped_frames %d" % len(x1))
print("RESULT q1_identical %s" % (bool(d1) and bool(x1) and all(l == d1[0] for l in x1)))

# command 2: every POST dropped -- bounded at three identical copies, none delivered
print("RESULT q2_attempts %s" % csv(e["attempt"] for e in a2))
print("RESULT q2_ok %s" % csv(e["ok"] for e in a2))
q2_seq = a2[0]["seq"] if a2 else None
d2, x2 = with_seq(delivered, q2_seq), with_seq(dropped, q2_seq)
print("RESULT q2_delivered_frames %d" % len(d2))
print("RESULT q2_dropped_frames %d" % len(x2))
print("RESULT q2_identical %s" % (bool(x2) and all(l == x2[0] for l in x2)))

# command 3: healthy relay -- one attempt
print("RESULT q3_attempts %s" % csv(e["attempt"] for e in a3))
print("RESULT q3_ok %s" % csv(e["ok"] for e in a3))
print("RESULT q3_delivered %s" % csv(e["delivered"] for e in a3))

# command 4: decrypt-failed -- still acked and logged; no inbox record, so id is null
print("RESULT q4_attempts %s" % csv(e["attempt"] for e in a4))
print("RESULT q4_id_null %s" % (bool(a4) and all(e.get("id") is None for e in a4)))

# every command line is followed by at least one ack_sent before the next command line
cmd_idx = [i for i, e in enumerate(events) if e.get("event") == "command"]
paired = bool(cmd_idx)
for n, i in enumerate(cmd_idx):
    stop = cmd_idx[n + 1] if n + 1 < len(cmd_idx) else len(events)
    if not any(e.get("event") == "ack_sent" for e in events[i + 1:stop]):
        paired = False
print("RESULT q_commands %d" % len(cmd_idx))
print("RESULT q_every_command_acked %s" % paired)

connects = [e for e in events if e.get("event") == "connect"]
print("RESULT q_connect_shape %s" % (bool(connects) and all(
    e.get("family") in ("ipv4", "ipv6") and isinstance(e.get("ms"), int) for e in connects)))
PYEOF

  check_res "$Q_CHECK" q1_attempts "1,2,3" "Q: two dropped ack POSTs then success -> ack_sent attempts 1,2,3"
  check_res "$Q_CHECK" q1_ok "False,False,True" "Q: ...ok=false,false,true"
  check_res "$Q_CHECK" q1_delivered "False,False,True" "Q: ...delivered=false,false,true"
  check_res "$Q_CHECK" q1_one_seq True "Q: all three attempts carry the SAME ack frame seq (one ack id, never a re-seal)"
  check_res "$Q_CHECK" q1_id True "Q: every ack_sent carries the inbox record id of the command it answers"
  check_res "$Q_CHECK" q1_ms_int True "Q: every ack_sent carries an integer ms"
  check_res "$Q_CHECK" q1_delivered_frames 1 "Q: exactly ONE ack frame was accepted by the relay (one delivered ack)"
  check_res "$Q_CHECK" q1_dropped_frames 2 "Q: the relay received the two dropped attempts in full"
  check_res "$Q_CHECK" q1_identical True "Q: the dropped copies are byte-identical to the delivered ack (duplicate-safe: the phone dedupes on seq)"

  check_res "$Q_CHECK" q2_attempts "1,2,3" "Q: a permanently failing ack is attempted exactly 3 times"
  check_res "$Q_CHECK" q2_ok "False,False,False" "Q: ...every attempt reported ok=false"
  check_res "$Q_CHECK" q2_delivered_frames 0 "Q: ...and none was accepted by the relay"
  # Three attempts, four POSTs: attempt 1 rides the ack connection that carried command 1's
  # delivered ack (frames now travel on a persistent connection), the relay drops it exactly as a
  # dead idle connection would drop it, and the client cannot tell the two apart -- so it re-POSTs
  # the same envelope once on a fresh connection before it calls that attempt failed. Attempts 2
  # and 3 open fresh connections of their own, so a failure there is not retried inside the attempt.
  check_res "$Q_CHECK" q2_dropped_frames 4 "Q: ...the relay received four copies (attempt 1 went out twice: once on the reused connection, once on a fresh one)"
  check_res "$Q_CHECK" q2_identical True "Q: ...and all four copies are the same envelope"

  check_res "$Q_CHECK" q3_attempts 1 "Q: a healthy relay is hit once per ack (no spurious retry)"
  check_res "$Q_CHECK" q3_ok True "Q: ...ok=true"
  check_res "$Q_CHECK" q3_delivered True "Q: ...delivered=true"

  check_res "$Q_CHECK" q4_attempts 1 "Q: a decrypt-failed command is acked and the ack logged"
  check_res "$Q_CHECK" q4_id_null True "Q: ...its ack_sent carries id=null (nothing was written to the inbox)"

  check_res "$Q_CHECK" q_commands 4 "Q: the log holds all four command lines"
  check_res "$Q_CHECK" q_every_command_acked True "Q: relay-events.jsonl shows an ack_sent line for every command line (handoff acceptance)"
  check_res "$Q_CHECK" q_connect_shape True "Q: the durable log carries connect events with family and integer ms"
  if [ ! -s "$TMPROOT/q.client.err" ]; then
    ok "Q: the client wrote nothing to stderr through every retry (no thread died with a traceback)"
  else
    bad "Q: the client wrote to stderr: $(head -5 "$TMPROOT/q.client.err")"
  fi

  kill "$CLIENT_Q" 2>/dev/null
  wait "$CLIENT_Q" 2>/dev/null
  kill "$SRV_Q" 2>/dev/null
  wait "$SRV_Q" 2>/dev/null
else
  skip "scenario Q (ack retry, ack_sent per command): bin/lib/hmd_relay_e2e.py absent -- needs device seal/open/derive"
fi

# ── Scenario R: the ack retry's timing rules, on a clock the harness steps by
# hand. Drives RelayClient._handle_command -- the real path an inbound command
# takes -- with send_frame_envelope replaced by a recorder, `time` by a clock
# that only moves when told to, and stop_event.wait by "advance the clock".
# Deterministic: no real sleeping, no race between a retry and a window ───────
if [ "$E2E_PRESENT" = true ]; then
  ACK_OUT_R="$TMPROOT/r.ack.out"
  python3 - "$RELAY_CLIENT_RUN" >"$ACK_OUT_R" 2>"$TMPROOT/r.ack.err" <<'PYEOF'
import argparse
import base64
import contextlib
import io
import json
import os
import sys
import tempfile
import time
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

client_path = sys.argv[1]


def load(env):
    saved = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    try:
        loader = SourceFileLoader("hmd_relay_client_ackharness", client_path)
        mod = module_from_spec(spec_from_loader(loader.name, loader))
        loader.exec_module(mod)
        return mod
    finally:
        for k, old in saved.items():
            if old is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = old


class Clock:
    def __init__(self):
        self.now = 5000.0

    def advance(self, seconds):
        self.now += seconds


class FakeTime:
    """The client's `time` module with monotonic() replaced by a clock this
    harness steps by hand; everything else (time(), strftime(), ...) is real."""

    def __init__(self, clock):
        self.clock = clock

    def monotonic(self):
        return self.clock.now

    def __getattr__(self, name):
        return getattr(time, name)


class FakeStopEvent:
    """Stands in for RelayClient.stop_event: wait() advances the fake clock by
    the delay instead of sleeping, and reports "stopping" from the Nth wait on
    when stop_on_wait is given."""

    def __init__(self, clock, stop_on_wait=None):
        self.clock = clock
        self.stop_on_wait = stop_on_wait
        self.waits = []

    def is_set(self):
        return self.stop_on_wait is not None and len(self.waits) >= self.stop_on_wait

    def wait(self, timeout=None):
        self.waits.append(timeout)
        if self.stop_on_wait is not None and len(self.waits) >= self.stop_on_wait:
            return True
        self.clock.advance(timeout or 0)
        return False


def run(env, seq, outcomes, cost=0.01, corrupt=False, stop_on_wait=None, inbox_cost=0.0, direct=False):
    """Hand one sealed command to _handle_command and record every POST attempt
    its ack makes. `outcomes` is what each attempt returns (None = the POST
    failed, False = relay answered but no phone is connected, True = delivered);
    each attempt also costs `cost` fake seconds. `inbox_cost` fake seconds are
    spent inside the inbox write, i.e. before the ack -- time the app's window
    keeps running while hmd is still busy. `direct` skips the command and calls
    send_hmd_frame("ack", ...) itself, with no deadline."""
    mod = load(env)
    clock = Clock()
    stop = FakeStopEvent(clock, stop_on_wait)
    calls = []
    plan = list(outcomes)

    def send_frame_envelope(type_, nonce, ciphertext, seq_, **kwargs):
        calls.append({"type": type_, "seq": seq_, "nonce": nonce, "ciphertext": ciphertext,
                      "timeout": kwargs.get("timeout")})
        clock.advance(cost)
        return (plan.pop(0) if plan else None), 321

    with tempfile.TemporaryDirectory() as repo:
        args = argparse.Namespace(relay="http://127.0.0.1:1", repo=repo, ui_port=0, public_host=None,
                                  status_file=os.path.join(repo, "status.json"), tick_s=2.0)
        client = mod.RelayClient(args)
        client.session_id = "sess-ackharness"
        client.token = "token-ackharness"
        client.session_key = os.urandom(32)
        client.stop_event = stop
        client.send_frame_envelope = send_frame_envelope
        mod.time = FakeTime(clock)
        if inbox_cost:
            real_append = mod.INBOX.append

            def slow_append(root, text):
                clock.advance(inbox_cost)
                return real_append(root, text)

            mod.INBOX.append = slow_append
        out = io.StringIO()
        if direct:
            with contextlib.redirect_stdout(out):
                client.send_hmd_frame("ack", {"ok": True, "of_seq": seq})
        else:
            plaintext = json.dumps({"action": "send-message", "params": {"text": "ack harness probe"}})
            nonce, ciphertext = mod.E2E.seal(client.session_key, seq, "device", plaintext.encode("utf-8"))
            if corrupt:
                raw = bytearray(base64.b64decode(ciphertext))
                raw[0] ^= 0x01
                ciphertext = base64.b64encode(bytes(raw)).decode("ascii")
            envelope = {"v": 1, "session_id": client.session_id, "seq": seq, "sender": "device",
                        "type": "command", "nonce": nonce, "ciphertext": ciphertext, "payload": None}
            with contextlib.redirect_stdout(out):
                client._handle_command(envelope)
        inbox_ids = []
        inbox_path = os.path.join(repo, ".heimdall", "ui", "inbox.jsonl")
        if os.path.exists(inbox_path):
            with open(inbox_path, encoding="utf-8") as f:
                inbox_ids = [json.loads(l)["id"] for l in f if l.strip()]
    events = [json.loads(l) for l in out.getvalue().splitlines() if l.strip()]
    return {"calls": calls, "events": events, "waits": stop.waits, "frames_sent": client.frames_sent,
            "last_delivered": client.last_delivered, "inbox_ids": inbox_ids}


def csv(values):
    return ",".join(str(v) for v in values)


def show(tag, r):
    acks = [e for e in r["events"] if e.get("event") == "ack_sent"]
    calls = r["calls"]
    first = (calls[0]["nonce"], calls[0]["ciphertext"], calls[0]["seq"]) if calls else None
    print("RESULT %s_calls %d" % (tag, len(calls)))
    print("RESULT %s_same_envelope %s" % (tag, bool(calls) and all(
        (c["nonce"], c["ciphertext"], c["seq"]) == first for c in calls)))
    print("RESULT %s_timeouts %s" % (tag, csv("None" if c["timeout"] is None else "%.2f" % c["timeout"]
                                              for c in calls)))
    print("RESULT %s_waits %s" % (tag, csv("%.2f" % w for w in r["waits"])))
    print("RESULT %s_attempts %s" % (tag, csv(e["attempt"] for e in acks)))
    print("RESULT %s_ok %s" % (tag, csv(e["ok"] for e in acks)))
    print("RESULT %s_delivered %s" % (tag, csv(e["delivered"] for e in acks)))
    print("RESULT %s_frames_sent %d" % (tag, r["frames_sent"]))
    print("RESULT %s_last_delivered %s" % (tag, r["last_delivered"]))


DEFAULT = {}
# r1: two failures then success -> 3 attempts of the same envelope, backoff 0.25 s then 0.5 s
show("r1", run(DEFAULT, 1, [None, None, True]))
# r2: never succeeds -> still exactly 3 attempts
show("r2", run(DEFAULT, 2, [None] * 5))
# r3: a 1 s window and attempts that each burn 0.6 s -> the 3rd never starts, the 2nd is capped to what is left
show("r3", run({"HMD_RELAY_ACK_WINDOW_S": "1.0"}, 3, [None] * 5, cost=0.6))
# r4: the window was already spent (9 s inside the inbox write) -> the late first attempt is still made, no retries
show("r4", run(DEFAULT, 4, [None, True], inbox_cost=9.0))
# r5: the relay ANSWERED (200) but no phone is connected right now (delivered=false) -> an ack
# is never stored, so the phone would never see it: retried like a failed POST, same envelope,
# inside the window (zero-lag sync Ask 4c)
show("r5", run(DEFAULT, 5, [False, True]))
# r6: a command that fails to decrypt is acked, retried and logged too
r6 = run(DEFAULT, 6, [None, True], corrupt=True)
show("r6", r6)
print("RESULT r6_command_detail %s" % csv(e.get("detail") for e in r6["events"] if e.get("event") == "command"))
print("RESULT r6_ack_id %s" % csv(e.get("id") for e in r6["events"] if e.get("event") == "ack_sent"))
print("RESULT r6_of_seq %s" % csv(e.get("of_seq") for e in r6["events"] if e.get("event") == "ack_sent"))
# r7: the ack_sent event's exact shape
r7 = run(DEFAULT, 7, [True])
show("r7", r7)
first = next((e for e in r7["events"] if e.get("event") == "ack_sent"), {})
print("RESULT r7_keys %s" % csv(sorted(first)))
print("RESULT r7_types %s" % (isinstance(first.get("ms"), int) and isinstance(first.get("seq"), int)
                              and first.get("of_seq") == 7))
print("RESULT r7_id_is_inbox_id %s" % (bool(r7["inbox_ids"]) and first.get("id") == r7["inbox_ids"][-1]))
# r8: the client is told to stop while waiting out a backoff -> no further attempt
show("r8", run(DEFAULT, 8, [None, True], stop_on_wait=1))
# r9: an ack sent with no deadline of its own gets the default window from the moment it is sent
r9 = run(DEFAULT, 9, [None, True], direct=True)
show("r9", r9)
print("RESULT r9_of_seq %s" % csv(e.get("of_seq") for e in r9["events"] if e.get("event") == "ack_sent"))
# r10: a window of 0 means "never retry" -- the one attempt is still made
show("r10", run({"HMD_RELAY_ACK_WINDOW_S": "0"}, 10, [None, True]))
# r11: delivered=false every time -> still bounded at 3 attempts, every answer visible in ack_sent
show("r11", run(DEFAULT, 11, [False] * 5))
# r12: delivered=false and the window is a 1 s one burnt by 0.6 s attempts -> the same window rule
# as a failed POST: the 3rd attempt never starts
show("r12", run({"HMD_RELAY_ACK_WINDOW_S": "1.0"}, 12, [False] * 5, cost=0.6))
# HMD_RELAY_ACK_WINDOW_S that is not a sane number of seconds falls back to the 8 s default
for tag, value in (("nan", "nan"), ("negative", "-3"), ("junk", "abc"), ("huge", "1e9"),
                   ("zero", "0"), ("fractional", "2.5")):
    print("RESULT window_%s %s" % (tag, load({"HMD_RELAY_ACK_WINDOW_S": value}).ACK_WINDOW_S))
sys.exit(0)
PYEOF
  ACK_RC_R=$?

  if [ "$ACK_RC_R" -eq 0 ]; then
    ok "scenario R: ack-retry harness ran to completion"
  else
    bad "scenario R: ack-retry harness exited $ACK_RC_R -- $(tail -3 "$TMPROOT/r.ack.err")"
  fi

  check_res "$ACK_OUT_R" r1_calls 3 "R/r1: two failures then success -> 3 POST attempts"
  check_res "$ACK_OUT_R" r1_same_envelope True "R/r1: every attempt re-POSTs the identical sealed envelope (same nonce, ciphertext, seq)"
  check_res "$ACK_OUT_R" r1_timeouts "3.00,3.00,3.00" "R/r1: each attempt is bounded to 3 s, not the 15 s a state frame gets"
  check_res "$ACK_OUT_R" r1_waits "0.25,0.50" "R/r1: backoff is 0.25 s then 0.5 s"
  check_res "$ACK_OUT_R" r1_attempts "1,2,3" "R/r1: ack_sent logs attempts 1,2,3"
  check_res "$ACK_OUT_R" r1_ok "False,False,True" "R/r1: ack_sent ok=false,false,true"
  check_res "$ACK_OUT_R" r1_delivered "False,False,True" "R/r1: ack_sent delivered=false,false,true"
  check_res "$ACK_OUT_R" r1_frames_sent 1 "R/r1: the frame counts once in relay.json's frames_sent, not once per attempt"
  check_res "$ACK_OUT_R" r1_last_delivered True "R/r1: relay.json's last_delivered reflects the attempt that got through"

  check_res "$ACK_OUT_R" r2_calls 3 "R/r2: a never-succeeding ack is attempted exactly 3 times"
  check_res "$ACK_OUT_R" r2_ok "False,False,False" "R/r2: ack_sent ok=false on every attempt"
  check_res "$ACK_OUT_R" r2_frames_sent 0 "R/r2: an ack that never got through is not counted as sent"

  check_res "$ACK_OUT_R" r3_calls 2 "R/r3: inside a 1 s window with 0.6 s attempts the 3rd attempt never starts"
  check_res "$ACK_OUT_R" r3_timeouts "3.00,0.50" "R/r3: the retry's timeout is capped to the window that is left (floor 0.5 s)"
  check_res "$ACK_OUT_R" r3_attempts "1,2" "R/r3: ack_sent logs attempts 1,2 only"

  check_res "$ACK_OUT_R" r4_calls 1 "R/r4: a window already spent -> the (late) first attempt is still made, with no retries"
  check_res "$ACK_OUT_R" r4_timeouts "3.00" "R/r4: ...and gets the full per-attempt timeout"

  check_res "$ACK_OUT_R" r5_calls 2 "R/r5: a 200 with delivered=false (no phone attached right now) is retried inside the window"
  check_res "$ACK_OUT_R" r5_same_envelope True "R/r5: ...the identical sealed envelope again (same nonce, ciphertext, seq)"
  check_res "$ACK_OUT_R" r5_waits "0.25" "R/r5: ...after the same 0.25 s backoff a failed POST gets"
  check_res "$ACK_OUT_R" r5_attempts "1,2" "R/r5: ...ack_sent logs attempts 1,2"
  check_res "$ACK_OUT_R" r5_ok "True,True" "R/r5: ...ok=true on both (the relay answered each time)"
  check_res "$ACK_OUT_R" r5_delivered "False,True" "R/r5: ...delivered=false then true, so a phone-less relay stays diagnosable"
  check_res "$ACK_OUT_R" r5_frames_sent 1 "R/r5: ...and the ack still counts once in frames_sent"

  check_res "$ACK_OUT_R" r11_calls 3 "R/r11: a relay that keeps answering delivered=false is attempted exactly 3 times"
  check_res "$ACK_OUT_R" r11_ok "True,True,True" "R/r11: ...every attempt ok=true (answered)"
  check_res "$ACK_OUT_R" r11_delivered "False,False,False" "R/r11: ...every attempt delivered=false, none hidden"
  check_res "$ACK_OUT_R" r11_last_delivered False "R/r11: ...relay.json's last_delivered ends false"

  check_res "$ACK_OUT_R" r12_calls 2 "R/r12: delivered=false obeys the same window as a failed POST -- the 3rd attempt never starts"
  check_res "$ACK_OUT_R" r12_timeouts "3.00,0.50" "R/r12: ...and the retry's timeout is capped to what is left of the window"

  check_res "$ACK_OUT_R" r6_command_detail "decrypt-failed" "R/r6: the command line reports decrypt-failed"
  check_res "$ACK_OUT_R" r6_attempts "1,2" "R/r6: its ack is retried and logged like any other"
  check_res "$ACK_OUT_R" r6_ack_id "None,None" "R/r6: ...with id=null (nothing was written to the inbox)"
  check_res "$ACK_OUT_R" r6_of_seq "6,6" "R/r6: ...naming the command seq it answers"

  check_res "$ACK_OUT_R" r7_keys "attempt,delivered,event,id,ms,of_seq,ok,seq" "R/r7: ack_sent carries exactly attempt, delivered, event, id, ms, of_seq, ok, seq"
  check_res "$ACK_OUT_R" r7_types True "R/r7: ms and seq are integers and of_seq is the command's seq"
  check_res "$ACK_OUT_R" r7_id_is_inbox_id True "R/r7: id is the inbox record id the ack's sealed payload carries"

  check_res "$ACK_OUT_R" r8_calls 1 "R/r8: told to stop mid-backoff -> no further attempt (shutdown is never delayed by a retry)"
  check_res "$ACK_OUT_R" r8_waits "0.25" "R/r8: ...the backoff wait goes through stop_event, so a stop interrupts it"

  check_res "$ACK_OUT_R" r9_calls 2 "R/r9: an ack sent with no deadline of its own is still retried (default window)"
  check_res "$ACK_OUT_R" r9_attempts "1,2" "R/r9: ...ack_sent logs attempts 1,2"
  check_res "$ACK_OUT_R" r9_of_seq "9,9" "R/r9: ...naming the seq the ack answers"

  check_res "$ACK_OUT_R" r10_calls 1 "R/r10: HMD_RELAY_ACK_WINDOW_S=0 means never retry -- the one attempt is still made"
  check_res "$ACK_OUT_R" r10_timeouts "3.00" "R/r10: ...with the full per-attempt timeout"

  check_res "$ACK_OUT_R" window_fractional "2.5" "R: HMD_RELAY_ACK_WINDOW_S=2.5 is read as 2.5 s"
  check_res "$ACK_OUT_R" window_zero "0.0" "R: HMD_RELAY_ACK_WINDOW_S=0 is read as 0 s (retries off), not rejected"
  check_res "$ACK_OUT_R" window_nan "8.0" "R: HMD_RELAY_ACK_WINDOW_S=nan falls back to the 8 s default"
  check_res "$ACK_OUT_R" window_negative "8.0" "R: HMD_RELAY_ACK_WINDOW_S=-3 falls back to the 8 s default"
  check_res "$ACK_OUT_R" window_junk "8.0" "R: HMD_RELAY_ACK_WINDOW_S=abc falls back to the 8 s default"
  check_res "$ACK_OUT_R" window_huge "8.0" "R: HMD_RELAY_ACK_WINDOW_S=1e9 (absurd) falls back to the 8 s default"
else
  skip "scenario R (ack retry timing rules): bin/lib/hmd_relay_e2e.py absent -- needs real seal/open"
fi

# ═════════════════════════════════════════════════════════════════════════════
# docs/HANDOFF-TO-HEIMDALL-zero-lag-sync.md (hmdapp repo, read-only), Asks 3 and
# 4 -- the hmd -> relay leg:
#   3. one persistent connection for POST /frames, not one per frame
#                              -> S (the transport, against fake-relay.py's
#                                 connection counter), U (the real client)
#   4a. a failed state POST is re-sent, not forgotten
#                              -> T (real client, a relay that drops the first
#                                 state POST), W (the digest/backoff rules)
#   4b. an ack never waits behind a slow state POST
#                              -> U (real client, a state POST held 3 s at the
#                                 relay while a command is acked), W (the lock
#                                 and ordering rules, stub transport)
#   4c. an ack answered delivered=false is retried inside the ack window
#                              -> U (real client), R above (the timing rules)
# Every case reads the same way against the pre-fix client, which is what makes
# the failures there meaningful: a connection per POST, a digest recorded before
# its POST, one lock across seal + POST + ack retries.
# ═════════════════════════════════════════════════════════════════════════════

# ── Scenario S: POST /frames rides ONE persistent connection per sender. Drives
# RelayClient.send_frame_envelope -- the one function every state frame and every
# ack POST goes through -- against fake-relay.py, which numbers every TCP
# connection it accepts (frame-posts.log), so "one connection" is the relay's own
# count and not the client's claim ───────────────────────────────────────────
PORT_S_RELAY="$(free_port)"
LOG_S="$TMPROOT/s.log"; CTL_S="$TMPROOT/s.ctl"
mkdir -p "$LOG_S" "$CTL_S"
python3 "$FAKE_RELAY" serve "$PORT_S_RELAY" --log "$LOG_S" --ctl "$CTL_S" >"$TMPROOT/s.srv.out" 2>&1 &
SRV_S=$!
PIDS+=("$SRV_S")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_S_RELAY))==0 else 1)" && break
  sleep 0.1
done

FRAMES_OUT_S="$TMPROOT/s.frames.out"
python3 - "$RELAY_CLIENT_RUN" "$PORT_S_RELAY" "$LOG_S" "$CTL_S" >"$FRAMES_OUT_S" 2>"$TMPROOT/s.frames.err" <<'PYEOF'
import argparse
import contextlib
import io
import json
import os
import socket
import sys
import tempfile
import time
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

client_path, port, log_dir, ctl_dir = sys.argv[1:5]
loader = SourceFileLoader("hmd_relay_client_frames_harness", client_path)
mod = module_from_spec(spec_from_loader(loader.name, loader))
loader.exec_module(mod)

NONCE, CIPHERTEXT = "bm9uY2U", "Y2lwaGVydGV4dA"  # opaque to the relay: it never opens a frame


def csv(values):
    return ",".join(str(v) for v in values)


def new_client(repo):
    """A RelayClient paired for real with the fake relay (a fresh session each time)."""
    args = argparse.Namespace(relay="http://127.0.0.1:%s" % port, repo=repo, ui_port=0, public_host=None,
                              status_file=os.path.join(repo, "status.json"), tick_s=2.0)
    client = mod.RelayClient(args)
    client.priv, client.pub = mod.E2E.generate_keypair()
    with contextlib.redirect_stdout(io.StringIO()):
        if client.pair_init() != 0:
            raise SystemExit("pair_init against the fake relay failed")
    return client


def post(client, type_, seq, timeout=15):
    """One send_frame_envelope call -> (answer, events it emitted, seconds it took)."""
    out = io.StringIO()
    began = time.monotonic()
    with contextlib.redirect_stdout(out):
        answer, _nbytes = client.send_frame_envelope(type_, NONCE, CIPHERTEXT, seq, timeout=timeout)
    events = [json.loads(l) for l in out.getvalue().splitlines() if l.strip()]
    return answer, events, time.monotonic() - began


def connects(events):
    return [e for e in events if e.get("event") == "connect" and e.get("for") == "frames"]


def posts(events):
    return [e for e in events if e.get("event") == "post"]


def relay_rows(seqs):
    """The relay's own frame-posts.log lines for these seqs, oldest first."""
    rows = []
    with open(os.path.join(log_dir, "frame-posts.log"), encoding="utf-8") as f:
        for line in f:
            kv = dict(part.split("=", 1) for part in line.split())
            if kv["seq"].isdigit() and int(kv["seq"]) in seqs:
                rows.append(kv)
    return rows


def relay_bodies(name, seq):
    path = os.path.join(log_dir, name)
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [l.rstrip("\n") for l in f if l.strip() and json.loads(l).get("seq") == seq]


def socket_of(client, sender):
    """The pooled socket of one sender's connection, or None when the client keeps no pool."""
    try:
        return client._frame_channels[sender].conn.sock
    except (AttributeError, KeyError):
        return None


def keepalive_set(sock):
    if sock is None:
        return "no-pooled-socket"
    return bool(sock.getsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE))


def put_token(name):
    open(os.path.join(ctl_dir, name), "w").close()


def remove_token(name):
    os.remove(os.path.join(ctl_dir, name))


# s1: six state POSTs in a row -- one connection, opened by the first and reused by the rest
with tempfile.TemporaryDirectory() as repo:
    client = new_client(repo)
    events, answers = [], []
    for seq in range(101, 107):
        answer, evs, _secs = post(client, "state", seq)
        answers.append(answer)
        events += evs
    print("RESULT s1_answers %s" % csv(answers))
    print("RESULT s1_connects %d" % len(connects(events)))
    print("RESULT s1_reused %s" % csv(e.get("reused") for e in posts(events)))
    print("RESULT s1_post_keys %s" % csv(sorted(posts(events)[0])) if posts(events) else "RESULT s1_post_keys none")
    print("RESULT s1_ms_ints %s" % (bool(posts(events)) and all(isinstance(e.get("ms"), int) and e["ms"] >= 0
                                                                for e in posts(events))))
    print("RESULT s1_relay_conns %d" % len({r["conn"] for r in relay_rows(set(range(101, 107)))}))
    print("RESULT s1_keepalive %s" % keepalive_set(socket_of(client, "state")))

    # s2: an ack has a connection of its own -- the state connection is untouched by it
    ack1, ev_ack1, _ = post(client, "ack", 201)
    state7, ev_state7, _ = post(client, "state", 107)
    ack2, ev_ack2, _ = post(client, "ack", 202)
    print("RESULT s2_answers %s" % csv([ack1, state7, ack2]))
    print("RESULT s2_connects %s" % csv([len(connects(ev_ack1)), len(connects(ev_state7)), len(connects(ev_ack2))]))
    print("RESULT s2_reused %s" % csv(e.get("reused") for e in posts(ev_ack1 + ev_state7 + ev_ack2)))
    ack_conns = {r["conn"] for r in relay_rows({201, 202})}
    state_conns = {r["conn"] for r in relay_rows({107})} | {r["conn"] for r in relay_rows(set(range(101, 107)))}
    print("RESULT s2_relay_ack_conns %d" % len(ack_conns))
    print("RESULT s2_relay_state_conns %d" % len(state_conns))
    print("RESULT s2_relay_disjoint %s" % (not (ack_conns & state_conns)))
    print("RESULT s2_keepalive %s" % keepalive_set(socket_of(client, "ack")))

# s3: the connection died while idle (the relay closes it as it reads the next request) -- the
# SAME sealed envelope goes out once more, at once, on a fresh connection
with tempfile.TemporaryDirectory() as repo:
    client = new_client(repo)
    post(client, "state", 301)
    put_token("fail-state-posts=1")
    answer, evs, _secs = post(client, "state", 302)
    rows = relay_rows({302})
    dropped, delivered = relay_bodies("frames-dropped.ndjson", 302), relay_bodies("frames.ndjson", 302)
    print("RESULT s3_answer %s" % answer)
    print("RESULT s3_relay_results %s" % csv(r["result"] for r in rows))
    print("RESULT s3_relay_conns %d" % len({r["conn"] for r in rows}))
    print("RESULT s3_same_envelope %s" % (len(dropped) == 1 and len(delivered) == 1 and dropped[0] == delivered[0]))
    print("RESULT s3_connects %d" % len(connects(evs)))
    print("RESULT s3_reused %s" % csv(e.get("reused") for e in posts(evs)))
    print("RESULT s3_errors %d" % sum(1 for e in evs if e.get("event") == "error"))

# s4: a failure on a connection opened for THAT POST is not retried here -- nothing about a
# fresh connection is stale, and the caller (ack retry, the state loop) owns the next try
with tempfile.TemporaryDirectory() as repo:
    client = new_client(repo)
    put_token("fail-state-posts=1")
    answer, evs, _secs = post(client, "state", 401)
    print("RESULT s4_answer %s" % answer)
    print("RESULT s4_relay_posts %d" % len(relay_rows({401})))
    print("RESULT s4_error_events %d" % sum(1 for e in evs if e.get("event") == "error" and "post failed" in e.get("detail", "")))

# s5: a POST that times out drops its connection -- the late answer must never be read as the
# answer to the NEXT frame -- and is not retried (it already spent the whole budget)
with tempfile.TemporaryDirectory() as repo:
    client = new_client(repo)
    post(client, "state", 501)
    put_token("delay-state-posts=2")
    answer, _evs, secs = post(client, "state", 502, timeout=0.5)
    remove_token("delay-state-posts=2")
    answer2, evs2, _secs2 = post(client, "state", 503)
    print("RESULT s5_timeout_answer %s" % answer)
    print("RESULT s5_timeout_ms %d" % round(secs * 1000))
    print("RESULT s5_next_answer %s" % answer2)
    print("RESULT s5_next_reused %s" % csv(e.get("reused") for e in posts(evs2)))
    print("RESULT s5_next_connects %d" % len(connects(evs2)))

# s6: anything that interrupts a POST half way -- not only a network error -- must not leave a
# half-used connection behind to be reused: the next POST opens a fresh one
with tempfile.TemporaryDirectory() as repo:
    client = new_client(repo)
    post(client, "state", 601)
    real_request = mod.http.client.HTTPConnection.request

    def interrupted_request(self, *args, **kwargs):
        raise RuntimeError("simulated non-network fault mid-request")

    mod.http.client.HTTPConnection.request = interrupted_request
    try:
        try:
            post(client, "state", 602)
            raised = "nothing"
        except RuntimeError as e:
            raised = type(e).__name__
    finally:
        mod.http.client.HTTPConnection.request = real_request
    pooled = getattr(client, "_frame_channels", {}).get("state")
    pool_emptied = pooled is not None and pooled.conn is None
    answer, evs, _secs = post(client, "state", 603)
    print("RESULT s6_raised %s" % raised)
    print("RESULT s6_pool_emptied %s" % pool_emptied)
    print("RESULT s6_next_answer %s" % answer)
    print("RESULT s6_next_reused %s" % csv(e.get("reused") for e in posts(evs)))
    print("RESULT s6_next_connects %d" % len(connects(evs)))

# s7: a reused connection that fails AFTER the POST's whole budget is spent is not retried -- the
# retry would have nothing left to run in, and would hide the real error behind its own timeout
with tempfile.TemporaryDirectory() as repo:
    client = new_client(repo)
    post(client, "state", 701)
    real_getresponse, real_connect = mod.http.client.HTTPConnection.getresponse, mod._connect
    opened = []

    def late_reset(self, *args, **kwargs):
        time.sleep(0.4)  # past the 0.3 s budget below
        raise ConnectionResetError("simulated reset after the budget is gone")

    def counting_connect(*args, **kwargs):
        opened.append(1)
        return real_connect(*args, **kwargs)

    mod.http.client.HTTPConnection.getresponse = late_reset
    mod._connect = counting_connect
    try:
        answer, evs, secs = post(client, "state", 702, timeout=0.3)
    finally:
        mod.http.client.HTTPConnection.getresponse = real_getresponse
        mod._connect = real_connect
    print("RESULT s7_answer %s" % answer)
    print("RESULT s7_new_connections %d" % len(opened))
    print("RESULT s7_error_events %d" % sum(1 for e in evs if e.get("event") == "error" and "simulated reset" in e.get("detail", "")))
sys.exit(0)
PYEOF
FRAMES_RC_S=$?

if [ "$FRAMES_RC_S" -eq 0 ]; then
  ok "scenario S: frame-connection harness ran to completion"
else
  bad "scenario S: frame-connection harness exited $FRAMES_RC_S -- $(tail -3 "$TMPROOT/s.frames.err")"
fi

check_res "$FRAMES_OUT_S" s1_answers "True,True,True,True,True,True" "S/s1: six state POSTs, six delivered answers"
check_res "$FRAMES_OUT_S" s1_connects 1 "S/s1: six state POSTs opened exactly ONE connection (connect events)"
check_res "$FRAMES_OUT_S" s1_reused "False,True,True,True,True,True" "S/s1: ...the first POST opened it, the other five reused it (post events)"
check_res "$FRAMES_OUT_S" s1_post_keys "event,ms,reused" "S/s1: a post event carries exactly event, ms and reused"
check_res "$FRAMES_OUT_S" s1_ms_ints True "S/s1: ...ms is a non-negative integer"
check_res "$FRAMES_OUT_S" s1_relay_conns 1 "S/s1: the relay itself counted ONE connection for the six frames"
check_res "$FRAMES_OUT_S" s1_keepalive True "S/s1: the pooled socket has TCP keepalive on (an idle NAT mapping does not silently kill it)"

check_res "$FRAMES_OUT_S" s2_answers "True,True,True" "S/s2: an ack, a state frame and an ack, all delivered"
check_res "$FRAMES_OUT_S" s2_connects "1,0,0" "S/s2: the first ack opened a connection of its own; the next state frame and ack opened none"
check_res "$FRAMES_OUT_S" s2_reused "False,True,True" "S/s2: ...the state frame reused the state connection, the second ack the ack connection"
check_res "$FRAMES_OUT_S" s2_relay_ack_conns 1 "S/s2: the relay saw every ack on ONE connection"
check_res "$FRAMES_OUT_S" s2_relay_state_conns 1 "S/s2: ...and every state frame on ONE connection"
check_res "$FRAMES_OUT_S" s2_relay_disjoint True "S/s2: ...never the same one (a slow state POST cannot hold up an ack)"
check_res "$FRAMES_OUT_S" s2_keepalive True "S/s2: the ack connection has TCP keepalive on too"

check_res "$FRAMES_OUT_S" s3_answer True "S/s3: a reused connection that dies mid-request still ends in a delivered answer"
check_res "$FRAMES_OUT_S" s3_relay_results "dropped,ok" "S/s3: the relay saw the POST twice: dropped, then answered"
check_res "$FRAMES_OUT_S" s3_relay_conns 2 "S/s3: ...on two different connections"
check_res "$FRAMES_OUT_S" s3_same_envelope True "S/s3: ...the very same sealed envelope both times (same seq, nonce, ciphertext)"
check_res "$FRAMES_OUT_S" s3_connects 1 "S/s3: exactly one reconnect"
check_res "$FRAMES_OUT_S" s3_reused False "S/s3: the answered exchange is reported as not reused"
check_res "$FRAMES_OUT_S" s3_errors 0 "S/s3: a stale connection that was transparently replaced is not an error"

check_res "$FRAMES_OUT_S" s4_answer None "S/s4: a failure on a brand-new connection is reported to the caller as no usable answer"
check_res "$FRAMES_OUT_S" s4_relay_posts 1 "S/s4: ...after exactly one POST (no blind retry)"
check_res "$FRAMES_OUT_S" s4_error_events 1 "S/s4: ...and one loud error event"

check_res "$FRAMES_OUT_S" s5_timeout_answer None "S/s5: a timed-out POST is reported as no usable answer"
check_res_between "$FRAMES_OUT_S" s5_timeout_ms 400 1500 "S/s5: ...after its own 0.5 s budget, not retried into a second wait (ms)"
check_res "$FRAMES_OUT_S" s5_next_answer True "S/s5: the next POST is answered normally (the late answer was never read as its own)"
check_res "$FRAMES_OUT_S" s5_next_reused False "S/s5: ...on a fresh connection: the timed-out one was dropped, not reused"
check_res "$FRAMES_OUT_S" s5_next_connects 1 "S/s5: ...one connect event"

check_res "$FRAMES_OUT_S" s6_raised RuntimeError "S/s6: a non-network fault mid-POST propagates (it is not mistaken for a stale connection)"
check_res "$FRAMES_OUT_S" s6_pool_emptied True "S/s6: ...and the interrupted connection is dropped from the pool"
check_res "$FRAMES_OUT_S" s6_next_answer True "S/s6: the next POST is answered normally"
check_res "$FRAMES_OUT_S" s6_next_reused False "S/s6: ...on a fresh connection, not the half-used one"
check_res "$FRAMES_OUT_S" s6_next_connects 1 "S/s6: ...one connect event"

check_res "$FRAMES_OUT_S" s7_answer None "S/s7: a reused connection that fails once the budget is gone is reported as no usable answer"
check_res "$FRAMES_OUT_S" s7_new_connections 0 "S/s7: ...with no retry attempted (a retry has nothing left to run in)"
check_res "$FRAMES_OUT_S" s7_error_events 1 "S/s7: ...and the error event names the real failure, not a retry's timeout"
if [ ! -s "$TMPROOT/s.frames.err" ]; then
  ok "S: the harness wrote nothing to stderr"
else
  bad "S: the harness wrote to stderr: $(head -5 "$TMPROOT/s.frames.err")"
fi

kill "$SRV_S" 2>/dev/null
wait "$SRV_S" 2>/dev/null

# ── Scenario T: a failed state POST is re-sent. The relay receives the very first
# state POST in full and never answers it (fail-state-posts=1). Nothing in the repo
# changes afterwards, so the ONLY thing that can put that state on the wire again is
# the client treating the failure as "not sent". The pre-fix client recorded the
# digest BEFORE posting: the frame was simply gone, until the next state change ─
if [ "$E2E_PRESENT" = true ]; then
  REPO_T="$(make_repo)"
  PORT_T_RELAY="$(free_port)"
  PORT_T_UI="$(free_port)"
  LOG_T="$TMPROOT/t.log"; CTL_T="$TMPROOT/t.ctl"
  mkdir -p "$LOG_T" "$CTL_T"
  : > "$CTL_T/fail-state-posts=1"

  python3 "$FAKE_RELAY" serve "$PORT_T_RELAY" --log "$LOG_T" --ctl "$CTL_T" >"$TMPROOT/t.srv.out" 2>&1 &
  SRV_T=$!
  PIDS+=("$SRV_T")
  for _ in $(seq 1 50); do
    python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_T_RELAY))==0 else 1)" && break
    sleep 0.1
  done

  CLIENT_T_OUT="$TMPROOT/t.client.out"
  "$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$PORT_T_RELAY" --repo "$REPO_T" --ui-port "$PORT_T_UI" \
    >"$CLIENT_T_OUT" 2>"$TMPROOT/t.client.err" &
  CLIENT_T=$!
  PIDS+=("$CLIENT_T")

  if wait_for_count "$LOG_T/frames-dropped.ndjson" 1 '"type":"state"' 15; then
    ok "scenario T: the relay received the first state POST and dropped it unanswered"
  else
    bad "scenario T: the relay never saw a state POST to drop"
  fi
  if wait_for_count "$LOG_T/frames.ndjson" 1 '"type":"state"' 15; then
    ok "scenario T: the state whose POST failed was re-sent, with no state change in between"
  else
    bad "scenario T: the state whose POST failed was never re-sent (its digest was recorded before the POST)"
  fi
  [ -e "$LOG_T/frames.ndjson" ] && { wait_for_quiescent_count "$LOG_T/frames.ndjson" 4 14 || true; }
  T_DROPPED="$(count_matching "$LOG_T/frames-dropped.ndjson" '"type":"state"')"
  T_DELIVERED="$(count_matching "$LOG_T/frames.ndjson" '"type":"state"')"
  if [ "$T_DROPPED" -eq 1 ] && [ "$T_DELIVERED" -eq 1 ]; then
    ok "scenario T: exactly one dropped and one delivered state frame (a retry, not a resend loop; INV-22 intact)"
  else
    bad "scenario T: want 1 dropped + 1 delivered state frame, got $T_DROPPED dropped + $T_DELIVERED delivered"
  fi
  if wait_for_event "$CLIENT_T_OUT" "error" "post failed" 2; then
    ok "scenario T: the failed POST was reported (error event naming it), not swallowed"
  else
    bad "scenario T: the failed state POST left no error event"
  fi
  T_GAP_MS="$(python3 - "$LOG_T/frame-posts.log" <<'PYEOF'
import sys

rows = []
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        rows.append(dict(part.split("=", 1) for part in line.split()))
dropped = [r for r in rows if r["type"] == "state" and r["result"] == "dropped"]
sent = [r for r in rows if r["type"] == "state" and r["result"] == "ok"]
if dropped and sent:
    print(int((float(sent[0]["done"]) - float(dropped[0]["recv"])) * 1000))
PYEOF
)"
  if [ -n "$T_GAP_MS" ] && [ "$T_GAP_MS" -lt 8000 ]; then
    ok "scenario T: the re-send reached the relay ${T_GAP_MS} ms after the dropped POST (< 8000 ms: next tick plus a bounded backoff)"
  else
    bad "scenario T: re-send gap was '$T_GAP_MS' ms, want < 8000"
  fi
  if [ ! -s "$TMPROOT/t.client.err" ]; then
    ok "scenario T: the client wrote nothing to stderr"
  else
    bad "scenario T: the client wrote to stderr: $(head -5 "$TMPROOT/t.client.err")"
  fi

  kill "$CLIENT_T" 2>/dev/null
  wait "$CLIENT_T" 2>/dev/null
  kill "$SRV_T" 2>/dev/null
  wait "$SRV_T" 2>/dev/null
else
  skip "scenario T (failed state POST is re-sent): bin/lib/hmd_relay_e2e.py absent"
fi

# ── Scenario U: the REAL client, a state POST held 3 s at the relay (delay-state-
# posts) while the phone's command arrives. The ack must land at once (it has a
# connection and a lock of its own), the state frame it overtook must be re-sent
# (the phone drops a frame whose seq a newer one has passed), every state POST
# rides one connection and every ack another, and an ack answered delivered=false
# is retried. The no-op command writes nothing to the inbox, so no state change
# can explain a later state frame ─────────────────────────────────────────────
if [ "$E2E_PRESENT" = true ]; then
  REPO_U="$(make_repo)"
  PORT_U_RELAY="$(free_port)"
  PORT_U_UI="$(free_port)"
  LOG_U="$TMPROOT/u.log"; CTL_U="$TMPROOT/u.ctl"
  mkdir -p "$LOG_U" "$CTL_U"

  python3 "$FAKE_RELAY" serve "$PORT_U_RELAY" --log "$LOG_U" --ctl "$CTL_U" >"$TMPROOT/u.srv.out" 2>&1 &
  SRV_U=$!
  PIDS+=("$SRV_U")
  for _ in $(seq 1 50); do
    python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_U_RELAY))==0 else 1)" && break
    sleep 0.1
  done

  DEVU_KEY_JSON="$(python3 "$FAKE_RELAY" device keygen)"
  DEVU_PRIV_B64="$(printf '%s' "$DEVU_KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["priv_b64"])')"
  DEVU_PUB_B64="$(printf '%s' "$DEVU_KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pub_b64"])')"
  printf '%s' "$DEVU_PUB_B64" > "$CTL_U/bind-device"

  CLIENT_U_OUT="$TMPROOT/u.client.out"
  EVENT_LOG_U="$REPO_U/.heimdall/app/relay-events.jsonl"
  "$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$PORT_U_RELAY" --repo "$REPO_U" --ui-port "$PORT_U_UI" \
    >"$CLIENT_U_OUT" 2>"$TMPROOT/u.client.err" &
  CLIENT_U=$!
  PIDS+=("$CLIENT_U")

  wait_for "$CLIENT_U_OUT" '"event":"pair_init"' 10 || true
  SID_U="$(python3 -c "
import json
for line in open('$CLIENT_U_OUT'):
    o = json.loads(line)
    if o.get('event') == 'pair_init':
        print(o['qr']['session_id']); break
" 2>/dev/null)"
  HMD_PUB_U="$(python3 -c "
import json
for line in open('$CLIENT_U_OUT'):
    o = json.loads(line)
    if o.get('event') == 'pair_init':
        print(o['qr']['hmd_pubkey']); break
" 2>/dev/null)"
  if wait_for "$CLIENT_U_OUT" '"event":"device_bound"' 10 && [ -n "$SID_U" ] && [ -n "$HMD_PUB_U" ]; then
    ok "scenario U: relay-client paired (session key derivable)"
  else
    bad "scenario U: relay-client never paired -- the rest of U cannot run: $(tail -3 "$TMPROOT/u.client.err" 2>/dev/null)"
  fi
  SESSION_KEY_U="$(python3 "$FAKE_RELAY" device derive --dev-priv-b64 "$DEVU_PRIV_B64" --hmd-pub-b64 "$HMD_PUB_U" --session-id "$SID_U" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["key_b64"])')"

  # a no-op action writes nothing to the inbox, so no state change can explain a later state frame;
  # both commands are sealed now and moved into the ctl dir only when each is wanted
  prepare_device_action "$TMPROOT/u.cmd1.json" "$SID_U" "$SESSION_KEY_U" 1 '{"action":"noop","params":{}}'
  prepare_device_action "$TMPROOT/u.cmd2.json" "$SID_U" "$SESSION_KEY_U" 2 '{"action":"noop","params":{}}'

  # the first state frame, so both directions of the exchange start from a warm state connection
  if wait_for_count "$LOG_U/frames.ndjson" 1 '"type":"state"' 10; then
    ok "scenario U: first state frame delivered"
  else
    bad "scenario U: no first state frame"
  fi

  # a state change whose POST the relay then holds 3 s
  : > "$CTL_U/delay-state-posts=3"
  ( cd "$REPO_U" && HEIMDALL_WATCH_ROOT="$REPO_U" "$UI" panel set slow-state --type number \
      --title "slow state probe" --data-json - <<<'{"value":1}' ) >/dev/null 2>&1
  for _ in $(seq 1 120); do
    [ -e "$LOG_U/state-inflight" ] && break
    sleep 0.1
  done
  if [ -e "$LOG_U/state-inflight" ]; then
    ok "scenario U: a state POST is in flight at the relay, held 3 s"
  else
    bad "scenario U: the changed state was never POSTed -- U cannot show an ack passing it"
  fi

  # the command goes in while that POST is still held
  mv "$TMPROOT/u.cmd1.json" "$CTL_U/001.json"
  ACK_U1_JSON="$(wait_for_ack_of_seq "$LOG_U/frames.ndjson" "$SESSION_KEY_U" 1 10)"
  rm -f "$CTL_U/delay-state-posts=3"
  if [ -n "$ACK_U1_JSON" ]; then
    ok "scenario U: the ack for seq=1 reached the relay"
  else
    bad "scenario U: no ack for seq=1 ever reached the relay"
  fi

  # the state frame the ack overtook is re-sent (a frame with a seq above the ack's)
  U_RESEND="$(python3 - "$LOG_U/frames.ndjson" 20 <<'PYEOF'
import json
import sys
import time

path, secs = sys.argv[1], float(sys.argv[2])
deadline = time.time() + secs
while True:
    ack_seq, state_seqs = None, []
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        lines = []
    for line in lines:
        try:
            env = json.loads(line)
        except ValueError:
            continue
        if env.get("type") == "ack" and ack_seq is None:
            ack_seq = env["seq"]
        if env.get("type") == "state":
            state_seqs.append(env["seq"])
    if ack_seq is not None and any(s > ack_seq for s in state_seqs):
        print("yes")
        sys.exit(0)
    if time.time() >= deadline:
        print("no")
        sys.exit(0)
    time.sleep(0.1)
PYEOF
)"
  if [ "$U_RESEND" = "yes" ]; then
    ok "scenario U: the state frame the ack overtook was re-sent under a seq above the ack's"
  else
    bad "scenario U: no state frame with a seq above the ack's ever followed -- the phone would keep the older state it dropped"
  fi

  # the delivered=false ack: the relay says no phone is attached for the next two tries
  : > "$CTL_U/undelivered-ack-posts=2"
  mv "$TMPROOT/u.cmd2.json" "$CTL_U/002.json"
  wait_for_count "$EVENT_LOG_U" 3 '"event":"ack_sent".*"of_seq":2,' 15 || true
  ACK_U2_JSON="$(wait_for_ack_of_seq "$LOG_U/frames.ndjson" "$SESSION_KEY_U" 2 5)"
  if [ -n "$ACK_U2_JSON" ]; then
    ok "scenario U: the ack for seq=2 reached the phone after two delivered=false answers"
  else
    bad "scenario U: the ack for seq=2 never reached the phone -- a delivered=false answer was not retried"
  fi

  U_CHECK="$TMPROOT/u.check.out"
  python3 - "$EVENT_LOG_U" "$LOG_U/frame-posts.log" "$LOG_U/frames.ndjson" "$LOG_U/frames-undelivered.ndjson" \
    >"$U_CHECK" 2>"$TMPROOT/u.check.err" <<'PYEOF'
import calendar
import json
import sys
import time

events_path, posts_path, frames_path, undelivered_path = sys.argv[1:5]


def lines_of(path):
    try:
        with open(path, encoding="utf-8") as f:
            return [l.rstrip("\n") for l in f if l.strip()]
    except OSError:
        return []


def csv(values):
    return ",".join(str(v) for v in values)


def ts(event):
    t = event["ts"]
    return calendar.timegm(time.strptime(t[:19], "%Y-%m-%dT%H:%M:%S")) + int(t[20:23]) / 1000.0


events = []
for line in lines_of(events_path):
    try:
        events.append(json.loads(line))
    except ValueError:
        continue  # the client is still running -- a half-written last line

rows = []
for line in lines_of(posts_path):
    kv = dict(part.split("=", 1) for part in line.split())
    kv["recv"], kv["done"] = float(kv["recv"]), float(kv["done"])
    kv["seq"] = int(kv["seq"]) if kv["seq"].isdigit() else None
    rows.append(kv)

# u1: the command is acked while the state POST is still held at the relay
cmd1 = next((e for e in events if e.get("event") == "command"), None)
ack1 = next((e for e in events if e.get("event") == "ack_sent" and e.get("of_seq") == 1), None)
print("RESULT u1_ack_ms %d" % (round((ts(ack1) - ts(cmd1)) * 1000) if cmd1 and ack1 else -1))
ack_row = next((r for r in rows if ack1 and r["type"] == "ack" and r["seq"] == ack1["seq"] and r["result"] == "ok"), None)
held = [r for r in rows if ack_row and r["type"] == "state" and r["recv"] < ack_row["done"] < r["done"]
        and r["done"] - r["recv"] >= 2.5]
print("RESULT u1_state_in_flight %s" % bool(held))
overtaken = [r for r in rows if ack1 and ack_row and r["type"] == "state" and r["result"] == "ok"
             and r["seq"] < ack1["seq"] and r["done"] > ack_row["done"]]
print("RESULT u1_state_overtaken %s" % bool(overtaken))

# u2: connections, counted by the relay and by the client's own events
state_conns = {r["conn"] for r in rows if r["type"] == "state"}
ack_conns = {r["conn"] for r in rows if r["type"] == "ack"}
print("RESULT u2_state_conns %d" % len(state_conns))
print("RESULT u2_ack_conns %d" % len(ack_conns))
print("RESULT u2_disjoint %s" % (not (state_conns & ack_conns)))
print("RESULT u2_frames_connects %d" % sum(1 for e in events if e.get("event") == "connect" and e.get("for") == "frames"))
print("RESULT u2_unreused_posts %d" % sum(1 for e in events if e.get("event") == "post" and e.get("reused") is False))

# u3: delivered=false is retried
a2 = [e for e in events if e.get("event") == "ack_sent" and e.get("of_seq") == 2]
print("RESULT u3_attempts %s" % csv(e["attempt"] for e in a2))
print("RESULT u3_ok %s" % csv(e["ok"] for e in a2))
print("RESULT u3_delivered %s" % csv(e["delivered"] for e in a2))
print("RESULT u3_one_seq %s" % (bool(a2) and len({e["seq"] for e in a2}) == 1))
seq2 = a2[0]["seq"] if a2 else None
undelivered = [l for l in lines_of(undelivered_path) if json.loads(l).get("seq") == seq2]
delivered = [l for l in lines_of(frames_path) if json.loads(l).get("type") == "ack" and json.loads(l).get("seq") == seq2]
print("RESULT u3_undelivered_frames %d" % len(undelivered))
print("RESULT u3_delivered_frames %d" % len(delivered))
print("RESULT u3_identical %s" % (bool(delivered) and bool(undelivered) and all(l == delivered[0] for l in undelivered)))
PYEOF

  check_res_between "$U_CHECK" u1_ack_ms 0 500 "scenario U: the ack landed within 500 ms of its command while a state POST was held 3 s (ms)"
  check_res "$U_CHECK" u1_state_in_flight True "scenario U: ...and the relay's own log shows that state POST still in flight when the ack landed"
  check_res "$U_CHECK" u1_state_overtaken True "scenario U: ...so the ack really did pass the older state frame (the phone will drop the state as a replay)"
  check_res "$U_CHECK" u2_state_conns 1 "scenario U: every state POST of the session rode ONE connection (the relay's count)"
  check_res "$U_CHECK" u2_ack_conns 1 "scenario U: every ack POST rode ONE connection"
  check_res "$U_CHECK" u2_disjoint True "scenario U: ...never the same one"
  check_res "$U_CHECK" u2_frames_connects 2 "scenario U: exactly two connect events for frames (one per sender) across the whole session"
  check_res "$U_CHECK" u2_unreused_posts 2 "scenario U: only those two POSTs opened a connection; every other post event is reused=true"
  check_res "$U_CHECK" u3_attempts "1,2,3" "scenario U: two delivered=false answers then delivered -> ack_sent attempts 1,2,3"
  check_res "$U_CHECK" u3_ok "True,True,True" "scenario U: ...every attempt got an answer (ok=true)"
  check_res "$U_CHECK" u3_delivered "False,False,True" "scenario U: ...delivered=false,false,true"
  check_res "$U_CHECK" u3_one_seq True "scenario U: ...all three attempts carry the same ack seq"
  check_res "$U_CHECK" u3_undelivered_frames 2 "scenario U: the relay received the two undelivered copies"
  check_res "$U_CHECK" u3_delivered_frames 1 "scenario U: ...and ONE delivered ack"
  check_res "$U_CHECK" u3_identical True "scenario U: ...all byte-identical (never a re-seal)"
  if [ ! -s "$TMPROOT/u.client.err" ]; then
    ok "scenario U: the client wrote nothing to stderr"
  else
    bad "scenario U: the client wrote to stderr: $(head -5 "$TMPROOT/u.client.err")"
  fi

  kill "$CLIENT_U" 2>/dev/null
  wait "$CLIENT_U" 2>/dev/null
  kill "$SRV_U" 2>/dev/null
  wait "$SRV_U" 2>/dev/null
else
  skip "scenario U (ack priority, persistent connections, delivered=false retry): bin/lib/hmd_relay_e2e.py absent"
fi


suite_summary
