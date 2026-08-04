#!/usr/bin/env bash
# gate-judgment-uncompressed.test.sh — THE FALSIFIER for the judgment invariant:
#
#     Generation may run compressed; judgment may not.
#
# THE SETUP. A MOCK PROXY stands in for a context-compressing proxy (e.g. Headroom). It is
# a real HTTP server on 127.0.0.1 that (a) TAGS every response body it serves and (b) LOGS
# every request that reaches it. The environment is then made maximally hostile — exactly
# what a wrapped shell exports: ANTHROPIC_BASE_URL, HTTP(S)_PROXY, ALL_PROXY, … all pointed
# at the mock proxy.
#
# THE RULE THIS ENFORCES: any GATE call that arrives at the mock proxy — or that comes back
# carrying its tag — is RED. A judge reading compressed context produces false greens, which
# is the one failure mode the whole project exists to prevent.
#
# HERMETIC: no real provider call, no network beyond 127.0.0.1. The stub `claude` NEVER
# dials out — when it resolves the real provider endpoint it answers locally, so a correctly
# pinned gate is fast and offline, and only a MIS-routed gate touches a socket at all.
#
# It is genuinely falsifiable — it FAILS if:
#   1  the mock proxy cannot actually be detected (the detector itself is broken — this is
#      the POSITIVE CONTROL, and without it every other case below could be a false green);
#   2  a gate call routed through hmd_gate_exec arrives at the proxy or returns tagged;
#   3  the pinned endpoint is anything other than the real provider;
#   4  any routing/proxy var survives into the gate child;
#   5  the scrub eats CREDENTIALS (a starved judge is not a protected judge);
#   6  a real gate client (bin/falsify, bin/heimdall-drain) stops routing its verdict
#      through hmd_gate_exec — THE MUTATION TARGET;
#   7  pinning breaks the real oracle gate.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/bin/lib/hmd-gate-endpoint.sh"

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "error: python3 is required for the mock proxy" >&2; exit 2; }

WORK="$(mktemp -d)"
PROXY_PID=""
cleanup() {
  [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [expr: $2]"; fi; }

# the marker the mock proxy stamps into every response it serves.
TAG="HEADROOM-COMPRESSED-CTX"
PROXY_LOG="$WORK/proxy-arrivals.log"
: > "$PROXY_LOG"

# ── the MOCK PROXY ────────────────────────────────────────────────────────────
# Tags every response and records every arrival. Binds port 0 (ephemeral) so parallel
# runs never collide.
cat > "$WORK/mock_proxy.py" <<'PYEOF'
import http.server, socketserver, os, sys

LOG = os.environ["PROXY_LOG"]
TAG = os.environ["PROXY_TAG"]

class Handler(http.server.BaseHTTPRequestHandler):
    def _serve(self):
        with open(LOG, "a") as fh:
            fh.write("%s %s\n" % (self.command, self.path))
            fh.flush()
        body = ('{"content":"%s verdict: PASS"}' % TAG).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    do_GET = do_POST = do_PUT = _serve
    def log_message(self, *a):
        return

socketserver.TCPServer.allow_reuse_address = True
httpd = socketserver.TCPServer(("127.0.0.1", 0), Handler)
with open(os.environ["PORT_FILE"], "w") as fh:
    fh.write(str(httpd.server_address[1]))
httpd.serve_forever()
PYEOF

PORT_FILE="$WORK/port"
PROXY_LOG="$PROXY_LOG" PROXY_TAG="$TAG" PORT_FILE="$PORT_FILE" "$PY" "$WORK/mock_proxy.py" &
PROXY_PID=$!
# detach from job control so reaping the proxy at EXIT does not print a "Terminated: 15"
# job notice into the suite's output (pristine output is part of the pass criteria).
disown "$PROXY_PID" 2>/dev/null || true

# wait (bounded) for the proxy to publish its port
PORT=""
for _ in $(seq 1 50); do
  [ -s "$PORT_FILE" ] && { PORT="$(cat "$PORT_FILE")"; break; }
  sleep 0.1
done
[ -n "$PORT" ] || { echo "error: mock proxy failed to start" >&2; exit 2; }
PROXY_URL="http://127.0.0.1:$PORT"

arrivals() { wc -l < "$PROXY_LOG" | tr -d ' '; }

# ── the stub `claude` ─────────────────────────────────────────────────────────
# Routes exactly like the real CLI: honors ANTHROPIC_BASE_URL / ANTHROPIC_API_URL, then the
# generic proxy vars. If it resolves anything other than the real provider it ACTUALLY dials
# that target (so the arrival is real evidence). If it resolves the real provider it answers
# locally and never opens a socket — keeping the suite offline.
STUB="$WORK/bin/claude"
mkdir -p "$WORK/bin"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
base="${ANTHROPIC_BASE_URL:-${ANTHROPIC_API_URL:-https://api.anthropic.com}}"
prox="${HTTPS_PROXY:-${https_proxy:-${ALL_PROXY:-${all_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}}}"
target=""
case "$base" in
  https://api.anthropic.com|https://api.anthropic.com/*) ;;
  *) target="$base" ;;
esac
[ -z "$target" ] && [ -n "$prox" ] && target="$prox"
if [ -n "$target" ]; then
  curl -s --max-time 5 "$target/v1/messages" -d '{}' || echo "PROXY-UNREACHABLE"
  exit 0
fi
# real provider endpoint, no proxy in the way -> answer locally, zero network.
echo 'verdict: PASS'
STUBEOF
chmod +x "$STUB"

# ── a model-assisted GATE ─────────────────────────────────────────────────────
# A verdict producer whose PASS/FAIL *is* model output — precisely the shape the invariant
# protects. Today's heimdall gates are deterministic; this stands in for the first one that
# is not, and for any gate that grows a model call tomorrow.
GATE="$WORK/verdict-gate.sh"
cat > "$GATE" <<GATEEOF
#!/usr/bin/env bash
"$STUB" -p "adjudicate: does this diff satisfy the acceptance criteria?"
GATEEOF
chmod +x "$GATE"

# the hostile shell a Headroom-wrapped session exports into every child.
#
# A SUBSHELL + `export`, deliberately NOT `env VAR=… cmd`: `env` can only exec a real
# binary, so an `env … hmd_gate_exec` form silently fails with "No such file or directory"
# and the assertions below would pass VACUOUSLY on empty output — a false green in the very
# suite whose job is to catch false greens. A subshell inherits shell functions, so the
# function under test genuinely runs under the hostile environment.
hostile_run() {
  (
    export ANTHROPIC_BASE_URL="$PROXY_URL"
    export ANTHROPIC_API_URL="$PROXY_URL"
    export HEADROOM_BASE_URL="$PROXY_URL"
    export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" ALL_PROXY="$PROXY_URL"
    export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL" all_proxy="$PROXY_URL"
    export ANTHROPIC_API_KEY="sk-ant-fake-credential-for-test"
    export PATH="$WORK/bin:$PATH"
    "$@"
  )
}

# shellcheck source=/dev/null
. "$LIB"

# ══ Case 1 — POSITIVE CONTROL: an UNPINNED judge is detectably compromised ══════
# If this fails, the detector is broken and every green below is worthless.
echo "Case 1 — positive control (an unpinned gate MUST arrive tagged):"
before1="$(arrivals)"
out1="$(hostile_run bash "$GATE" 2>/dev/null)"
after1="$(arrivals)"
check "1.1 unpinned gate output carries the proxy TAG"      "printf '%s' \"\$out1\" | grep -q '$TAG'"
check "1.2 the call physically ARRIVED at the mock proxy"   "[ '$after1' -gt '$before1' ]"

# ══ Case 2 — THE INVARIANT: a pinned judge never reaches the proxy ═════════════
echo "Case 2 — the invariant (a gate routed through hmd_gate_exec):"
before2="$(arrivals)"
out2="$(hostile_run hmd_gate_exec bash "$GATE" 2>/dev/null)"
after2="$(arrivals)"
check "2.1 gate output is CLEAN (no proxy tag)"             "! printf '%s' \"\$out2\" | grep -q '$TAG'"
check "2.2 gate produced the real verdict"                  "printf '%s' \"\$out2\" | grep -q 'verdict: PASS'"
check "2.3 ZERO arrivals at the proxy (never dialed it)"    "[ '$after2' -eq '$before2' ]"

# ══ Case 3 — the pin is the REAL provider, immune to the ambient env ═══════════
echo "Case 3 — the pinned endpoint:"
pinned="$(hostile_run hmd_gate_exec sh -c 'printf %s "$ANTHROPIC_BASE_URL"')"
check "3.1 pinned to the real provider endpoint"            "[ \"\$pinned\" = 'https://api.anthropic.com' ]"
check "3.2 the hostile ANTHROPIC_BASE_URL did NOT survive"  "[ \"\$pinned\" != '$PROXY_URL' ]"
check "3.3 the pin is a hardcoded constant, not env-derived" \
  "grep -q '^HMD_PROVIDER_BASE_URL=\"https://api.anthropic.com\"' '$LIB'"

# ══ Case 4 — every routing var is scrubbed from the gate child ════════════════
echo "Case 4 — routing vars scrubbed in the gate child:"
# the RAN: sentinel makes a vacuous pass impossible — an empty result now means the child
# never executed (FAIL), not "the var was scrubbed" (PASS).
for v in ANTHROPIC_API_URL HEADROOM_BASE_URL HTTP_PROXY HTTPS_PROXY ALL_PROXY \
         http_proxy https_proxy all_proxy; do
  got="$(hostile_run hmd_gate_exec sh -c "printf 'RAN:%s' \"\${$v:-}\"")"
  check "4.x $v scrubbed (child ran, value empty)"          "[ \"\$got\" = 'RAN:' ]"
done

# ══ Case 5 — credentials SURVIVE (we neutralize routing, never auth) ══════════
echo "Case 5 — credentials preserved (a starved judge is not a protected judge):"
cred="$(hostile_run hmd_gate_exec sh -c 'printf %s "${ANTHROPIC_API_KEY:-}"')"
check "5.1 ANTHROPIC_API_KEY passes through untouched"      "[ \"\$cred\" = 'sk-ant-fake-credential-for-test' ]"

# ══ Case 6 — THE MUTATION TARGET: real gate clients route through the pin ═════
echo "Case 6 — real gate clients are wired to the invariant:"
check "6.1 bin/falsify sources the gate-endpoint lib" \
  "grep -q 'hmd-gate-endpoint.sh' '$ROOT/bin/falsify'"
check "6.2 falsify run_gate executes the oracle via hmd_gate_exec" \
  "grep -q 'hmd_gate_exec bash \"\$RUN_SH\"' '$ROOT/bin/falsify'"
check "6.3 no UNPINNED 'bash \$RUN_SH' gate invocation remains in falsify" \
  "! grep -E '^[[:space:]]*bash \"\\\$RUN_SH\"' '$ROOT/bin/falsify'"
check "6.4 bin/heimdall-drain sources the gate-endpoint lib" \
  "grep -q 'hmd-gate-endpoint.sh' '$ROOT/bin/heimdall-drain'"
check "6.5 drain resolves its verdict via hmd_gate_exec" \
  "[ \"\$(grep -c 'hmd_gate_exec' '$ROOT/bin/heimdall-drain')\" -ge 2 ]"

# ══ Case 7 — the real oracle gate still works under a hostile env ═════════════
# Regression, not pinning evidence: rr-multitenant-isolation is deterministic and makes no
# model call, so this proves the pin did not BREAK the shipped gate.
echo "Case 7 — real falsify oracle under the hostile env (regression):"
before7="$(arrivals)"
rc7=0
hostile_run perl -e 'alarm 240; exec @ARGV' -- \
  "$ROOT/bin/falsify" rr-multitenant-isolation --assert-score 1.0 >"$WORK/f7.out" 2>&1 || rc7=$?
after7="$(arrivals)"
check "7.1 falsify still scores 1.0 under the hostile env"  "[ '$rc7' -eq 0 ]"
check "7.2 falsify reported the perfect score"              "grep -q 'ASSERT PASS' '$WORK/f7.out'"
check "7.3 ZERO gate arrivals at the proxy during falsify"  "[ '$after7' -eq '$before7' ]"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
