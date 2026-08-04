#!/usr/bin/env bash
# cp-signed-no-rewriting-proxy.test.sh — THE FALSIFIER for the signed-path invariant:
#
#     A LOCAL REWRITING proxy may never carry signed bytes.
#     A legitimate corporate CONNECT proxy must keep working.
#
# THE DEFECT THIS REPLACES. The old `no-signed-traffic-routing` invariant grepped the
# control-plane scripts for proxy-routing variables and printed BYPASS-OK when it found
# NONE. That is inverted: a script that never MENTIONS a proxy is exactly the script that
# silently INHERITS an ambient one. Measured on the shipped client before the fix — a
# `heimdall-presence beat` with `http_proxy` pointed at a loopback rewriter delivered
# `POST /presence` to the REWRITER and ZERO bytes to the real control plane, while the
# invariant printed BYPASS-OK. A check that cannot fail in the state it exists to catch is
# worth less than no check, because it is trusted.
#
# WHY NOT JUST BYPASS EVERY PROXY. A normal corporate HTTPS proxy CONNECT-tunnels TLS end
# to end; it cannot read or rewrite signed bytes, and in a locked-down estate it is the ONLY
# egress. Blanket `--noproxy '*'` would break hmd for those users to defend against a threat
# their proxy does not pose. The thing that must never sit in a signed path is a REWRITING
# proxy — Headroom's own local endpoint, the HEADROOM_* namespace, a loopback proxy var.
# So the scrub is CONDITIONAL, and section 1.6 / 2.7 below is what stops anyone "fixing"
# this back into a blanket bypass.
#
# THE MECHANISM UNDER TEST: hmd_signed_exec (bin/lib/hmd-gate-endpoint.sh), the signed-path
# sibling of hmd_gate_exec. Same file, same canonical _HMD_GATE_ROUTING_VARS enumeration,
# different policy — judgment scrubs every route, the signed path scrubs only the rewriters.
#
# HERMETIC: no network beyond 127.0.0.1 (and one optional local non-loopback interface).
# The "control plane" and the "rewriter" are both real HTTP servers on this machine, and the
# client driven against them is the REAL SHIPPED bin/heimdall-presence and bin/heimdall-connect
# — not a stand-in. Arrival logs are the evidence: WHERE the bytes landed, not whether a
# command exited 0.
#
# It is genuinely falsifiable — it FAILS if:
#   1  the rig cannot detect a hijack it is shown (1.2 / 2.1 are the POSITIVE CONTROLS —
#      without them every green below could be vacuous);
#   2  a loopback rewriter, or the HEADROOM_* namespace, survives into a signed child;
#   3  a signed request from a real shipped client arrives at the rewriter;
#   4  a legitimate NON-loopback (corporate) proxy is stripped or stops carrying traffic;
#   5  any of the three signed surfaces stops routing through hmd_signed_exec — THE
#      MUTATION TARGET;
#   6  the module invariant reverts to something that can pass without the scrub, or stops
#      failing CLOSED when the control plane is unreachable.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/bin/lib/hmd-gate-endpoint.sh"
MANIFEST="$ROOT/modules/headroom/manifest.json"

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "error: python3 is required for the local servers" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

WORK="$(mktemp -d)"
SRV_PIDS=""
cleanup() {
  for p in $SRV_PIDS; do kill "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [expr: $2]"; fi; }

# The suite must control its own baseline: an ambient proxy (or an ambient no_proxy that
# exempts 127.0.0.1) would silently disarm the positive controls below.
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy
unset HEADROOM_BASE_URL HEADROOM_PROXY HEADROOM_PROXY_URL
unset ANTHROPIC_BASE_URL ANTHROPIC_API_URL ANTHROPIC_DEFAULT_BASE_URL CLAUDE_CODE_BASE_URL

# ── the local servers ─────────────────────────────────────────────────────────
# One shape serves both roles. Each logs every arrival and stamps its own name into the
# body, so "which server answered" is decidable from either side. Port 0 -> ephemeral, so
# parallel runs never collide.
cat > "$WORK/srv.py" <<'PYEOF'
import http.server, socketserver, json, os

LOG = os.environ["SRV_LOG"]
NAME = os.environ["SRV_NAME"]
BIND = os.environ.get("SRV_BIND", "127.0.0.1")


class Handler(http.server.BaseHTTPRequestHandler):
    def _serve(self):
        with open(LOG, "a") as fh:
            fh.write("%s %s\n" % (self.command, self.path))
            fh.flush()
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        body = json.dumps({"origin": NAME, "ok": True, "haid": "x", "team_id": "t"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = do_PUT = _serve

    def log_message(self, *a):
        return


socketserver.TCPServer.allow_reuse_address = True
httpd = socketserver.TCPServer((BIND, 0), Handler)
with open(os.environ["PORT_FILE"], "w") as fh:
    fh.write(str(httpd.server_address[1]))
httpd.serve_forever()
PYEOF

# start_server <role> <bind-addr> -> sets $SRV_PORT. Deliberately NOT called through a
# command substitution: the child PID has to land in $SRV_PIDS in THIS shell so the EXIT
# trap can reap it, and a backgrounded child inherits (and would hold open) the
# substitution's pipe.
SRV_PORT=""
start_server() {
  local role="$1" bind="$2" logf portf pid
  logf="$WORK/$role.log"; portf="$WORK/$role.port"
  : > "$logf"
  SRV_LOG="$logf" SRV_NAME="$role" SRV_BIND="$bind" PORT_FILE="$portf" \
    "$PY" "$WORK/srv.py" >/dev/null 2>&1 &
  pid=$!
  SRV_PIDS="$SRV_PIDS $pid"
  # detach from job control so reaping at EXIT never prints a "Terminated: 15" job notice
  # into the suite output (pristine output is part of the pass criteria).
  disown "$pid" 2>/dev/null || true
  SRV_PORT=""
  for _ in $(seq 1 60); do
    [ -s "$portf" ] && { SRV_PORT="$(cat "$portf")"; break; }
    sleep 0.1
  done
  [ -n "$SRV_PORT" ] || { echo "error: $role server failed to start" >&2; exit 2; }
}

start_server cp 127.0.0.1;       CP_PORT="$SRV_PORT"
start_server rewriter 127.0.0.1; RW_PORT="$SRV_PORT"
CP_URL="http://127.0.0.1:$CP_PORT"
RW_URL="http://127.0.0.1:$RW_PORT"

# A DEAD loopback port — a rewriter that is exported but not listening. This is the shape
# the module invariant uses: if the scrub fails, the request cannot even complete.
DEAD_PORT="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
DEAD_URL="http://127.0.0.1:$DEAD_PORT"

arrivals() { wc -l < "$WORK/$1.log" | tr -d ' '; }
reset_logs() { : > "$WORK/cp.log"; : > "$WORK/rewriter.log"; [ -f "$WORK/corp.log" ] && : > "$WORK/corp.log"; return 0; }

echo
echo "1 — the POLICY: hmd_signed_exec scrubs rewriters, keeps corporate proxies"
echo "----------------------------------------------------------------------"

# shellcheck source=../bin/lib/hmd-gate-endpoint.sh
. "$LIB"

check "1.1 the shipped lib defines hmd_signed_exec" \
  '[ "$(type -t hmd_signed_exec)" = "function" ]'

# signed_env — the environment AS A SIGNED CHILD SEES IT. Every assertion below is of the
# form "this variable is absent", and an EMPTY capture satisfies all of them: a missing or
# broken hmd_signed_exec would turn the whole section green by saying nothing at all. So a
# canary rides along, and a capture that loses the canary is POISONED with every routing
# var instead — silence becomes red rather than a clean sweep.
POISON='HTTP_PROXY=READBACK-BROKEN
HTTPS_PROXY=READBACK-BROKEN
ALL_PROXY=READBACK-BROKEN
http_proxy=READBACK-BROKEN
https_proxy=READBACK-BROKEN
all_proxy=READBACK-BROKEN
HEADROOM_BASE_URL=READBACK-BROKEN
HEADROOM_PROXY=READBACK-BROKEN
HEADROOM_PROXY_URL=READBACK-BROKEN
ANTHROPIC_BASE_URL=READBACK-BROKEN
ANTHROPIC_API_URL=READBACK-BROKEN
ANTHROPIC_DEFAULT_BASE_URL=READBACK-BROKEN
CLAUDE_CODE_BASE_URL=READBACK-BROKEN'
signed_env() {
  local out
  out="$(HMD_SCRUB_CANARY=alive hmd_signed_exec env 2>/dev/null)"
  case "$out" in
    *HMD_SCRUB_CANARY=alive*) printf '%s\n' "$out" ;;
    *)                        printf '%s\n' "$POISON" ;;
  esac
}

check "1.1 the readback canary survives, so absence assertions mean something" \
  'signed_env | grep -q "^HMD_SCRUB_CANARY=alive$"'

# 1.2 POSITIVE CONTROL — without the scrub a child really does inherit the routing vars.
# Everything below asserts a var is ABSENT; if inheritance did not happen in the first
# place those assertions would pass vacuously.
INHERITED="$(HTTPS_PROXY="$RW_URL" HEADROOM_BASE_URL="$RW_URL" env | grep -cE '^(HTTPS_PROXY|HEADROOM_BASE_URL)=')"
check "1.2 POSITIVE CONTROL — an unscrubbed child inherits both routing vars" \
  '[ "$INHERITED" = "2" ]'

# 1.3 every generic proxy var pointed at loopback is scrubbed, upper and lower case.
LOOPBACK_SURVIVORS="$(HTTP_PROXY="$RW_URL" HTTPS_PROXY="$RW_URL" ALL_PROXY="$RW_URL" \
  http_proxy="$RW_URL" https_proxy="$RW_URL" all_proxy="$RW_URL" \
  signed_env | grep -icE '^(http_proxy|https_proxy|all_proxy)=')"
check "1.3 a LOOPBACK proxy var is scrubbed in every spelling (6 -> 0)" \
  '[ "$LOOPBACK_SURVIVORS" = "0" ]'

# 1.4 Headroom's own namespace names the rewriter itself, so it goes UNCONDITIONALLY —
# even pointed off-box, HEADROOM_* is by definition a context-rewriting endpoint.
HEADROOM_SURVIVORS="$(HEADROOM_BASE_URL=https://headroom.corp.example:8443 \
  HEADROOM_PROXY=https://headroom.corp.example:8443 \
  HEADROOM_PROXY_URL=https://headroom.corp.example:8443 \
  signed_env | grep -c '^HEADROOM_')"
check "1.4 the HEADROOM_* namespace is scrubbed even when it points OFF-box" \
  '[ "$HEADROOM_SURVIVORS" = "0" ]'

BASEURL_SURVIVORS="$(ANTHROPIC_BASE_URL="$RW_URL" ANTHROPIC_API_URL="$RW_URL" \
  ANTHROPIC_DEFAULT_BASE_URL="$RW_URL" CLAUDE_CODE_BASE_URL="$RW_URL" \
  signed_env | grep -cE '^(ANTHROPIC_|CLAUDE_CODE_BASE_URL)')"
check "1.5 the model base-URL overrides are scrubbed (4 -> 0)" \
  '[ "$BASEURL_SURVIVORS" = "0" ]'

# 1.6 THE CORPORATE GUARANTEE. This is the arm that forbids a blanket bypass. A proxy on a
# real off-box host CONNECT-tunnels TLS; it cannot rewrite signed bytes, and in a locked-down
# estate it is the only way out. Stripping it would break hmd for those users.
CORP="http://proxy.corp.example:3128"
CORP_SURVIVORS="$(HTTP_PROXY="$CORP" HTTPS_PROXY="$CORP" ALL_PROXY="$CORP" \
  http_proxy="$CORP" https_proxy="$CORP" all_proxy="$CORP" \
  signed_env | grep -icE '^(http_proxy|https_proxy|all_proxy)=')"
check "1.6 a NON-loopback (corporate CONNECT) proxy SURVIVES the scrub (6 -> 6)" \
  '[ "$CORP_SURVIVORS" = "6" ]'

# 1.7 loopback wears many spellings; the classifier has to parse a host, not match a string.
for spec in "http://localhost:9" "http://127.9.9.9:9" "http://[::1]:9" "http://0.0.0.0:9" \
            "127.0.0.1:9" "http://user:pw@127.0.0.1:9" "https://LOCALHOST:9" "socks5://127.0.0.1:9"; do
  n="$(HTTPS_PROXY="$spec" signed_env | grep -c '^HTTPS_PROXY=')"
  check "1.7 loopback recognised: $spec" '[ "$n" = "0" ]'
done

# 1.8 …and it must not over-match. A corporate proxy whose USERINFO merely contains a
# loopback-looking string is still a corporate proxy: parse the host, never the whole value.
NOT_LOOPBACK="$(HTTPS_PROXY="http://127.0.0.1:pw@proxy.corp.example:3128" \
  signed_env | grep -c '^HTTPS_PROXY=')"
check "1.8 a corporate host with loopback-looking USERINFO is NOT scrubbed" \
  '[ "$NOT_LOOPBACK" = "1" ]'

# 1.9 credentials are ROUTING-neutral. hmd_gate_exec deliberately leaves them alone (a
# starved judge is not a protected judge) and the signed path inherits that reasoning: a
# signed request with no credential is not a safer request, it is a failed one.
CREDS="$(CLAUDE_CODE_OAUTH_TOKEN=tok ANTHROPIC_API_KEY=key \
  signed_env | grep -cE '^(CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY)=')"
check "1.9 credentials are NOT scrubbed — we neutralize ROUTING, never AUTH" \
  '[ "$CREDS" = "2" ]'

# 1.10 NO_PROXY is a bypass ALLOWLIST. It can only ever REMOVE a proxy hop, never add one,
# so it can never route signed bytes into a rewriter — and dropping it would silently push
# an estate's internal hosts back THROUGH the corporate proxy.
NOPROXY="$(NO_PROXY=internal.corp no_proxy=internal.corp \
  signed_env | grep -ic '^no_proxy=')"
check "1.10 NO_PROXY survives — an allowlist can only reduce proxying, never cause it" \
  '[ "$NOPROXY" = "2" ]'

echo
echo "2 — the LIVE differential: the REAL shipped signed clients vs a real rewriter"
echo "----------------------------------------------------------------------------"

# 2.1 POSITIVE CONTROL. urllib — the transport every signed client here uses — really does
# honor an ambient proxy var. Without this, "zero arrivals at the rewriter" below could
# just mean the rig never worked.
cat > "$WORK/client.py" <<'PYEOF'
import os, sys, urllib.request
try:
    with urllib.request.urlopen(os.environ["TARGET"], timeout=8) as r:
        sys.stdout.write(r.read().decode())
except Exception as exc:  # noqa: BLE001 — the origin is what is under test, not the error
    sys.stdout.write("TRANSPORT-ERROR %s" % exc.__class__.__name__)
PYEOF
reset_logs
HIJACKED="$(TARGET="$CP_URL/readyz" http_proxy="$RW_URL" HTTP_PROXY="$RW_URL" "$PY" "$WORK/client.py")"
check "2.1 POSITIVE CONTROL — an unscrubbed urllib request IS hijacked to the rewriter" \
  '[ "$(arrivals rewriter)" = "1" ] && [ "$(arrivals cp)" = "0" ] && printf "%s" "$HIJACKED" | grep -q rewriter'

# The shipped clients get a throwaway HOME so the 0600 Ed25519 seed, the enroll stamp and the
# team file are all created inside $WORK and nothing touches the developer's real state.
export HOME="$WORK/home"; mkdir -p "$HOME"
export HEIMDALL_CP_URL="$CP_URL"

reset_logs
"$ROOT/bin/heimdall-presence" beat >/dev/null 2>&1
check "2.2 a clean presence beat reaches the real control plane" \
  '[ "$(arrivals cp)" -ge 1 ]'

# 2.3 THE BITE. Same command, same everything, with a LIVE loopback rewriter exported the
# way a wrapped shell exports it. Before the fix this delivered POST /presence to the
# rewriter and nothing to the control plane.
reset_logs
http_proxy="$RW_URL" HTTP_PROXY="$RW_URL" https_proxy="$RW_URL" HTTPS_PROXY="$RW_URL" \
  all_proxy="$RW_URL" ALL_PROXY="$RW_URL" \
  "$ROOT/bin/heimdall-presence" beat >/dev/null 2>&1
check "2.3 a presence beat under a loopback rewriter still reaches the control plane" \
  '[ "$(arrivals cp)" -ge 1 ]'
check "2.3 …and ZERO signed bytes arrived at the rewriter" \
  '[ "$(arrivals rewriter)" = "0" ]'

# 2.4 the same, wired the way Headroom itself wires it.
reset_logs
HEADROOM_BASE_URL="$RW_URL" HEADROOM_PROXY="$RW_URL" HEADROOM_PROXY_URL="$RW_URL" \
  http_proxy="$RW_URL" \
  "$ROOT/bin/heimdall-presence" beat >/dev/null 2>&1
check "2.4 a presence beat under the HEADROOM_* wiring reaches the control plane" \
  '[ "$(arrivals cp)" -ge 1 ]'
check "2.4 …and ZERO signed bytes arrived at the rewriter" \
  '[ "$(arrivals rewriter)" = "0" ]'

# 2.5 ENROLLMENT. The /enroll bootstrap is the one request that is UNSIGNED by design — it
# is what registers the key — so a rewriter sitting there is a compromised install, not a
# broken signature. A fresh HOME forces the bootstrap to run again.
export HOME="$WORK/home2"; mkdir -p "$HOME"
reset_logs
http_proxy="$RW_URL" HTTP_PROXY="$RW_URL" \
  "$ROOT/bin/heimdall-presence" beat >/dev/null 2>&1
check "2.5 the /enroll bootstrap reaches the control plane under a rewriter" \
  'grep -q "/enroll" "$WORK/cp.log"'
check "2.5 …and ZERO enrollment bytes arrived at the rewriter" \
  '[ "$(arrivals rewriter)" = "0" ]'

# 2.6 the second signed surface: heimdall-connect's Ed25519-signed POST /team/cred and
# /team/install. The seed created by the beats above is what signs them. A SYNTHETIC
# shape-valid oauth token (never a real secret, and it travels only to 127.0.0.1) takes the
# env auto-detect branch so the run is non-interactive — same fixture shape as
# test/heimdall-connect.test.sh.
export HOME="$WORK/home"
TOKEN="sk-ant-oat01-$("$PY" -c 'import secrets,string; a=string.ascii_letters+string.digits+"_-"; print("".join(secrets.choice(a) for _ in range(90)))')"
reset_logs
CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" \
  http_proxy="$RW_URL" HTTP_PROXY="$RW_URL" https_proxy="$RW_URL" HTTPS_PROXY="$RW_URL" \
  "$ROOT/bin/heimdall-connect" --endpoint "$CP_URL" \
  --gh-app-installation-id 12345 --repo acme/widgets </dev/null >/dev/null 2>&1
check "2.6 a signed connect POST /team/cred reaches the control plane" \
  'grep -q "/team/cred" "$WORK/cp.log"'
check "2.6 a signed connect POST /team/install reaches the control plane" \
  'grep -q "/team/install" "$WORK/cp.log"'
check "2.6 …and ZERO signed bytes arrived at the rewriter" \
  '[ "$(arrivals rewriter)" = "0" ]'

# 2.7 THE CORPORATE GUARANTEE, LIVE. A proxy on a real non-loopback interface must still
# CARRY the signed request — not merely survive in the environment. When this machine has
# no non-loopback IPv4 (an isolated container), the same guarantee is asserted structurally
# instead; the arm never disappears, it changes evidence.
NONLOOP="$("$PY" - <<'PYEOF'
import socket
addr = ""
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(0.5)
    s.connect(("192.0.2.1", 9))          # TEST-NET-1: routes nowhere, sends nothing
    addr = s.getsockname()[0]
    s.close()
except Exception:
    addr = ""
print("" if addr.startswith("127.") else addr)
PYEOF
)"
if [ -n "$NONLOOP" ]; then
  start_server corp 0.0.0.0
  CORP_URL="http://$NONLOOP:$SRV_PORT"
  reset_logs
  http_proxy="$CORP_URL" HTTP_PROXY="$CORP_URL" \
    "$ROOT/bin/heimdall-presence" beat >/dev/null 2>&1
  check "2.7 LIVE — a corporate proxy on $NONLOOP still CARRIES the signed request" \
    '[ "$(arrivals corp)" -ge 1 ]'
else
  CORP_KEPT="$(HTTP_PROXY=http://proxy.corp.example:3128 signed_env | grep -c '^HTTP_PROXY=')"
  check "2.7 STRUCTURAL (no non-loopback interface) — a corporate proxy var is preserved" \
    '[ "$CORP_KEPT" = "1" ]'
fi

unset HEIMDALL_CP_URL

echo
echo "3 — the MUTATION TARGETS: every signed surface routes through the scrub"
echo "-----------------------------------------------------------------------"

for surface in heimdall-presence heimdall-connect heimdall-team; do
  check "3.x $surface sources the signed-path scrub" \
    "grep -q 'hmd-gate-endpoint.sh' '$ROOT/bin/$surface'"
  check "3.x $surface routes its signed client through hmd_signed_exec" \
    "grep -q 'hmd_signed_exec' '$ROOT/bin/$surface'"
done

echo
echo "4 — the MODULE INVARIANT is a real differential and fails CLOSED"
echo "---------------------------------------------------------------"

INV_CMD="$(jq -r '.invariants["no-signed-traffic-routing"].command' "$MANIFEST")"
INV_EXPECT="$(jq -r '.invariants["no-signed-traffic-routing"].expect' "$MANIFEST")"
INV_WHY="$(jq -r '.invariants["no-signed-traffic-routing"].why' "$MANIFEST")"

check "4.1 the invariant declares a non-empty expect marker" '[ -n "$INV_EXPECT" ] && [ "$INV_EXPECT" != "null" ]'
check "4.2 the invariant is no longer the inverted grep that passed on ZERO hits" \
  '! printf "%s" "$INV_CMD" | grep -q "grep -lE"'
check "4.3 the invariant actually drives the signed scrub" \
  'printf "%s" "$INV_CMD" | grep -q "hmd_signed_exec"'
check "4.4 the why text describes the differential, not a grep" \
  'printf "%s" "$INV_WHY" | grep -qi "differential"'

# 4.5 THE DIFFERENTIAL PASSES when the scrub is in place — run hermetically by pointing the
# invariant's control-plane default at the local stand-in.
INV_OUT="$(cd "$ROOT" && HEIMDALL_DEFAULT_CP_URL="$CP_URL" bash -c "$INV_CMD" 2>&1)"
check "4.5 the invariant emits its marker against a live control plane" \
  'printf "%s" "$INV_OUT" | grep -qF "$INV_EXPECT"'

# 4.6 FAIL CLOSED. An unreachable control plane is NON_VERIFIED — never a silent pass. The
# module runner compares stdout against `expect`, so a NON_VERIFIED run fails the invariant
# and the module is rolled back, which is the required behaviour.
NV_OUT="$(cd "$ROOT" && HEIMDALL_DEFAULT_CP_URL="$DEAD_URL" bash -c "$INV_CMD" 2>&1)"
NV_RC=$?
check "4.6 an unreachable control plane reports NON_VERIFIED" \
  'printf "%s" "$NV_OUT" | grep -q "NON_VERIFIED"'
check "4.6 …and does NOT emit the pass marker" \
  '! printf "%s" "$NV_OUT" | grep -qF "$INV_EXPECT"'
check "4.6 …and exits non-zero so the invariant fails closed" '[ "$NV_RC" -ne 0 ]'

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
