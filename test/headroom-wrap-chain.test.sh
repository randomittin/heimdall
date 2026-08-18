#!/usr/bin/env bash
#
# headroom-wrap-chain.test.sh — acceptance for bin/lib/hmd-headroom-chain.sh, the
# wrap-chain wire that starts (or reuses) the Headroom proxy and hands its base URL
# to `hmd wrap`.
#
# WHY THIS FILE EXISTS NOW. The chain file's own header comment has pointed at
# "test/headroom-wrap-chain.test.sh section 5" since it was written, and no such
# file — or any test exercising hmd_headroom_chain / its HMD_HEADROOM_BIN seam —
# ever existed. This is that file, scoped first to the timeout-debt quarantine
# mitigation added during the headroom-ai 0.33.0 -> 0.35.0 upgrade:
# HEADROOM_COMPRESSION_TIMEOUT_SECONDS is now set on the proxy's OWN child process at
# launch, scoped to that one process. HEADROOM_BACKGROUND_COMPRESSION is deliberately
# NOT set: verified against installed 0.35.0 source that it is a no-op under the
# CACHE mode hmd always launches in — proxy/background_compression.py gates its one
# call site (proxy/handlers/anthropic.py) behind `is_token_mode(...)`, unchanged
# between 0.33.0 and 0.35.0. Setting it would be config that looks like a fix for the
# leak/quarantine cascade (upstream #1171) and does nothing.
#
# HOW THIS RUNS HERMETICALLY. HMD_HEADROOM_BIN (an existing test seam in the sourced
# file) points hmd_headroom_chain at a tiny recorder instead of the real `headroom`
# CLI: no network egress, no ML model, no real proxy. The recorder answers /health
# itself (a stdlib http.server) so the chain's own readiness poll succeeds for real,
# and dumps its OWN environment to a file BEFORE serving — so what this file asserts
# on is what the CHILD PROCESS actually received, not what the shell line that built
# the command looks like.
#
# Guarantees proved:
#   1. The chain starts the recorder and returns a base URL pointed at it.
#   2. HEADROOM_COMPRESSION_TIMEOUT_SECONDS=130 reaches the child when the caller sets
#      nothing — the chosen default (~2x the worst synchronous compression run
#      measured on the machine this was tuned on: 64.75s against Headroom's own 30s).
#   3. A caller-exported override reaches the child UNCHANGED — the same
#      ${VAR:-default} pattern hmd_headroom_port already uses, never clobbered.
#   4. HEADROOM_BACKGROUND_COMPRESSION is NOT set on the child — locks in the
#      verified-no-op-under-cache-mode finding so nobody re-adds it believing it
#      fixes the cascade.
#   5. The var is scoped to the ONE child process: it does not leak into the
#      sourcing shell's own environment (and therefore not into whatever hmd launches
#      next in that same shell — the coding tool itself) after the chain returns.
#
# FALSIFIABILITY (run by hand, see the commit message for the transcript): with the
# HEADROOM_COMPRESSION_TIMEOUT_SECONDS line reverted out of hmd-headroom-chain.sh,
# guarantee 2 goes RED (`HEADROOM_COMPRESSION_TIMEOUT_SECONDS=` line absent from the
# recorded child env). Restoring the fix turns it GREEN again with no other guarantee
# ever moving — this file is not vacuously green.
#
# Usage:  bash test/headroom-wrap-chain.test.sh   (exit 0 = every guarantee holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CHAIN="$REPO/bin/lib/hmd-headroom-chain.sh"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/headroom-chain.XXXXXX")"
LIVE_PIDS=""
cleanup() {
  local p
  for p in $LIVE_PIDS; do kill "$p" >/dev/null 2>&1 || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

echo
echo "0 — the file exists and parses"
[ -f "$CHAIN" ] && ok "bin/lib/hmd-headroom-chain.sh exists" \
  || { bad "bin/lib/hmd-headroom-chain.sh missing"; echo "FATAL"; exit 1; }
bash -n "$CHAIN" && ok "bin/lib/hmd-headroom-chain.sh parses (bash -n)" \
  || bad "bin/lib/hmd-headroom-chain.sh has a syntax error"

# ── fixture: the HTTP responder the recorder execs into ────────────────────────────
# A minimal stdlib http.server standing in for the real Headroom proxy's /health.
# Separate file (not a nested heredoc) so quoting stays simple and robust.
HTTP_SERVER_PY="$TMP/fake_http_server.py"
cat > "$HTTP_SERVER_PY" <<'PYEOF'
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    # Silence http.server's default per-request stderr logging — a real,
    # complete override (not a stub): the base class's log_message() writes to
    # stderr on every request, which would otherwise interleave into this
    # suite's own PASS/FAIL output.
    def log_message(self, *args):
        return None

    def do_GET(self):
        body = json.dumps(
            {
                "service": "headroom-proxy",
                "checks": {"upstream": {"url": "https://api.anthropic.com"}},
            }
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PYEOF

# ── fixture: the recorder itself — a fake `headroom` CLI understanding only
# `proxy --host H --port P` (what hmd_headroom_chain invokes) and `--version`.
# Dumps its OWN environment to $HMD_FAKE_HEADROOM_ENV_FILE, THEN execs into the
# HTTP responder — so by the time /health can answer, the env dump already landed.
FAKE_BIN="$TMP/fake-headroom"
cat > "$FAKE_BIN" <<EOSH
#!/usr/bin/env bash
set -uo pipefail
case "\${1:-}" in
  proxy)
    port=8787
    prev=""
    for a in "\$@"; do
      [ "\$prev" = "--port" ] && port="\$a"
      prev="\$a"
    done
    env > "\${HMD_FAKE_HEADROOM_ENV_FILE:?HMD_FAKE_HEADROOM_ENV_FILE not set}"
    exec python3 "$HTTP_SERVER_PY" "\$port"
    ;;
  --version)
    echo "headroom, version FAKE-RECORDER"
    ;;
  *)
    echo "fake-headroom: unhandled args: \$*" >&2
    exit 2
    ;;
esac
EOSH
chmod +x "$FAKE_BIN"

# ── fixture: an installed, opted-in module state (HMD_MODULES_STATE-scoped, so the
# plugin_dir argument passed to hmd_headroom_chain never has to be a real directory).
MODSTATE="$TMP/modstate"
mkdir -p "$MODSTATE/headroom"
printf '{}\n' > "$MODSTATE/headroom/receipt.json"

BASE_PORT=$((20000 + ($$ % 5000)))

echo
echo "1 — the chain starts the recorder and returns its base URL"
PORT1=$BASE_PORT
ENV1="$TMP/env1"
(
  . "$CHAIN"
  export HMD_HEADROOM_BIN="$FAKE_BIN"
  export HMD_MODULES_STATE="$MODSTATE"
  export HEIMDALL_HOME="$TMP/home1"
  export HEADROOM_PORT="$PORT1"
  export HMD_FAKE_HEADROOM_ENV_FILE="$ENV1"
  hmd_headroom_chain "$TMP/plugin"
  rc=$?
  printf '%s\n' "$rc" > "$TMP/rc1"
  printf '%s\n' "$HMD_HEADROOM_BASE_URL" > "$TMP/url1"
  printf '%s\n' "$HMD_HEADROOM_WHY" > "$TMP/why1"
)
RC1="$(cat "$TMP/rc1" 2>/dev/null || echo 1)"
URL1="$(cat "$TMP/url1" 2>/dev/null || echo "")"
WHY1="$(cat "$TMP/why1" 2>/dev/null || echo "")"
[ -s "$TMP/home1/headroom/proxy.pid" ] && LIVE_PIDS="$LIVE_PIDS $(cat "$TMP/home1/headroom/proxy.pid")"

[ "$RC1" = "0" ] \
  && ok "hmd_headroom_chain returns 0 against the recorder" \
  || bad "hmd_headroom_chain returned $RC1 (why: $WHY1)"
[ "$URL1" = "http://127.0.0.1:$PORT1" ] \
  && ok "HMD_HEADROOM_BASE_URL points at the recorder ($URL1)" \
  || bad "HMD_HEADROOM_BASE_URL is '$URL1', expected http://127.0.0.1:$PORT1"
[ -s "$ENV1" ] \
  && ok "the recorder wrote its environment dump before answering /health" \
  || bad "the recorder never wrote its environment dump ($ENV1) — nothing to assert on"

echo
echo "2 — HEADROOM_COMPRESSION_TIMEOUT_SECONDS=130 reaches the child by default"
if [ -s "$ENV1" ]; then
  grep -q '^HEADROOM_COMPRESSION_TIMEOUT_SECONDS=130$' "$ENV1" \
    && ok "the child process env carries HEADROOM_COMPRESSION_TIMEOUT_SECONDS=130" \
    || bad "no HEADROOM_COMPRESSION_TIMEOUT_SECONDS=130 line in the child's recorded env: $(grep '^HEADROOM_COMPRESSION_TIMEOUT_SECONDS=' "$ENV1" 2>/dev/null || echo '<absent entirely>')"
else
  bad "guarantee 2 skipped — no env dump from guarantee 1 to check"
fi

echo
echo "3 — a caller-exported override reaches the child unchanged"
PORT2=$((BASE_PORT + 1))
ENV2="$TMP/env2"
(
  export HEADROOM_COMPRESSION_TIMEOUT_SECONDS=45
  . "$CHAIN"
  export HMD_HEADROOM_BIN="$FAKE_BIN"
  export HMD_MODULES_STATE="$MODSTATE"
  export HEIMDALL_HOME="$TMP/home2"
  export HEADROOM_PORT="$PORT2"
  export HMD_FAKE_HEADROOM_ENV_FILE="$ENV2"
  hmd_headroom_chain "$TMP/plugin"
  printf '%s\n' "$?" > "$TMP/rc2"
)
RC2="$(cat "$TMP/rc2" 2>/dev/null || echo 1)"
[ -s "$TMP/home2/headroom/proxy.pid" ] && LIVE_PIDS="$LIVE_PIDS $(cat "$TMP/home2/headroom/proxy.pid")"
if [ "$RC2" = "0" ] && [ -s "$ENV2" ]; then
  grep -q '^HEADROOM_COMPRESSION_TIMEOUT_SECONDS=45$' "$ENV2" \
    && ok "a caller override (45) reaches the child instead of the 130 default" \
    || bad "the override did not reach the child: $(grep '^HEADROOM_COMPRESSION_TIMEOUT_SECONDS=' "$ENV2" 2>/dev/null || echo '<absent>')"
else
  bad "guarantee 3 skipped — chain did not start cleanly (rc=$RC2)"
fi

echo
echo "4 — HEADROOM_BACKGROUND_COMPRESSION is deliberately NOT set on the child"
if [ -s "$ENV1" ]; then
  if grep -q '^HEADROOM_BACKGROUND_COMPRESSION=' "$ENV1"; then
    bad "HEADROOM_BACKGROUND_COMPRESSION is set on the child — verified no-op under hmd's cache-mode default; it should not be there"
  else
    ok "HEADROOM_BACKGROUND_COMPRESSION is absent from the child env, as intended"
  fi
else
  bad "guarantee 4 skipped — no env dump from guarantee 1 to check"
fi

echo
echo "5 — the var is scoped to the ONE child; it does not leak into the sourcing shell"
PORT3=$((BASE_PORT + 2))
ENV3="$TMP/env3"
(
  unset HEADROOM_COMPRESSION_TIMEOUT_SECONDS
  . "$CHAIN"
  export HMD_HEADROOM_BIN="$FAKE_BIN"
  export HMD_MODULES_STATE="$MODSTATE"
  export HEIMDALL_HOME="$TMP/home3"
  export HEADROOM_PORT="$PORT3"
  export HMD_FAKE_HEADROOM_ENV_FILE="$ENV3"
  hmd_headroom_chain "$TMP/plugin" >/dev/null 2>&1
  if [ -z "${HEADROOM_COMPRESSION_TIMEOUT_SECONDS:-}" ]; then
    echo "SCOPE-OK" > "$TMP/scope3"
  else
    echo "LEAKED=$HEADROOM_COMPRESSION_TIMEOUT_SECONDS" > "$TMP/scope3"
  fi
)
[ -s "$TMP/home3/headroom/proxy.pid" ] && LIVE_PIDS="$LIVE_PIDS $(cat "$TMP/home3/headroom/proxy.pid")"
SCOPE3="$(cat "$TMP/scope3" 2>/dev/null || echo "<no result>")"
[ "$SCOPE3" = "SCOPE-OK" ] \
  && ok "HEADROOM_COMPRESSION_TIMEOUT_SECONDS does not leak into the sourcing shell after the chain returns" \
  || bad "HEADROOM_COMPRESSION_TIMEOUT_SECONDS leaked into the sourcing shell: $SCOPE3"

echo
echo "--------------------------------------------------------------------"
printf 'headroom-wrap-chain: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
