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
# mitigation first added during the headroom-ai 0.33.0 -> 0.35.0 upgrade (since rolled
# back — the pinned and installed version is 0.33.0 again):
# HEADROOM_COMPRESSION_TIMEOUT_SECONDS is now set on the proxy's OWN child process at
# launch, scoped to that one process. HEADROOM_BACKGROUND_COMPRESSION is deliberately
# NOT set: it is opt-in and off by default. An earlier version of this header added
# that it is "a no-op under the CACHE mode hmd always launches in —
# proxy/background_compression.py gates its one call site behind `is_token_mode(...)`,
# unchanged between 0.33.0 and 0.35.0". The last clause was wrong: `is_token_mode`
# appears nowhere in 0.33.0's proxy/background_compression.py, which reads the flag as
# a plain env bool at proxy/server.py:1090-1092 and gates it at the call sites. The
# behaviour these sections assert is unaffected — they prove which vars this file's
# chain does and does not put on the child, not upstream's mode semantics — but the
# justification was version-specific and is not restated as 0.33.0's.
#
# EXTENDED (same session, fork-assessment §1a — see
# docs/superpowers/specs/2026-08-19-headroom-fork-assessment.md): the chain now also
# sets HEADROOM_KOMPRESS_MAX_TOKENS=10000 on the same child, the size-gate half of
# #1171. Sections 6-8 below prove the same three properties for this second var that
# sections 2/3/5 already proved for the first: reaches the child by default, a caller
# override is respected unchanged, and it does not leak into the sourcing shell.
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
#   2. HEADROOM_COMPRESSION_TIMEOUT_SECONDS=30 reaches the child when the caller sets
#      nothing. This asserted 130 until the 0.35.0 root-cause pass: on 0.35.0 the
#      budget is not a background-worker budget but a PRE-UPSTREAM stall (upstream
#      #2357 turned cache-mode cold start into a synchronous
#      `anthropic_pipeline.apply(..., timeout=COMPRESSION_TIMEOUT_SECONDS)` that runs
#      before the request is forwarded), so 130s guaranteed the client abandoned the
#      turn first. 30 is upstream's own default, pinned so hmd's stall ceiling cannot
#      move if upstream's default does.
#   3. A caller-exported override reaches the child UNCHANGED — the same
#      ${VAR:-default} pattern hmd_headroom_port already uses, never clobbered.
#   4. HEADROOM_BACKGROUND_COMPRESSION is NOT set on the child — locks in the
#      verified-no-op-under-cache-mode finding so nobody re-adds it believing it
#      fixes the cascade.
#   5. The var is scoped to the ONE child process: it does not leak into the
#      sourcing shell's own environment (and therefore not into whatever hmd launches
#      next in that same shell — the coding tool itself) after the chain returns.
#   6. HEADROOM_KOMPRESS_MAX_TOKENS=10000 reaches the child when the caller sets
#      nothing — chosen because it is ~2x the single largest real kompress block ever
#      logged on the machine this was tuned on (2,464 tokens over 1,181 recovered
#      events; 5,090 words over 775 raw ONNX calls), and the 50,000 upstream default
#      it replaces was measured to have fired zero times, ever, on that same machine.
#   7. A caller-exported override of HEADROOM_KOMPRESS_MAX_TOKENS reaches the child
#      UNCHANGED — same ${VAR:-default} precedent as guarantee 3.
#   8. HEADROOM_KOMPRESS_MAX_TOKENS is scoped to the ONE child process, same as
#      guarantee 5: it does not leak into the sourcing shell's own environment.
#   9. HEADROOM_LOSSLESS=1 reaches the child when the caller sets nothing. This is the
#      var that keeps STREAMING working, not a savings knob: without it Headroom
#      injects its `headroom_retrieve` tool, `buffered_stream_ccr` goes true, and a
#      client `stream:true` request is silently forwarded upstream as `stream:false`
#      and buffered — time-to-first-byte becomes the whole generation, which is the
#      `0 stream events received` half of the live failure, and it routes essentially
#      all traffic through the one return path that copies the upstream content-type
#      verbatim, which is the `non-streaming request was answered with a stream` half.
#      Upstream: #3071 and #3130, neither fixed in any released version.
#  10. A caller-exported HEADROOM_LOSSLESS override reaches the child UNCHANGED — same
#      ${VAR:-default} precedent as guarantees 3 and 7. `0` is a real opt-out (click
#      types the flag as boolean), so an operator can restore upstream's CCR default.
#  11. HEADROOM_LOSSLESS is scoped to the ONE child process, same as guarantees 5/8.
#  12. HEADROOM_NO_CCR is NOT set on the child. It would silence the same downgrade,
#      but upstream documents it as "lossy compression with no recovery path" whereas
#      --lossless leaves would-need-a-marker content uncompacted. Asserting the
#      absence stops a future edit trading fidelity for the same streaming fix.
##  13. The proxy the chain STARTS carries `--lossless` on its command line, not only in
#      its environment. Upstream treats the two as equivalent inputs, so the proxy
#      behaves identically either way; what the flag buys is that a LATER session can
#      verify it, because argv is readable on every platform and environments are not
#      (macOS hides them for SIP-signed binaries — measured: /bin/bash and /bin/sleep
#      expose zero env tokens to `ps eww`, Headroom's uv-installed interpreter exposes
#      its full environment).
#  14. A proxy ALREADY LISTENING that was started WITHOUT lossless mode is NOT reused.
#      This is the half of the streaming fix guarantee 9 could not reach: the var is
#      only ever put on proxies this file launches, a Headroom proxy is long-lived, and
#      one started by `headroom wrap`, by hand, or by an hmd predating the fix keeps
#      injecting `headroom_retrieve` for every session that finds it on the port.
#      Nothing in /health or /settings distinguishes the two (measured against two real
#      0.33.0 proxies: byte-identical apart from pid, timestamp and uptime), so the
#      verdict is read from the running PROCESS via the pid /health does report.
#  15. A live proxy carrying HEADROOM_LOSSLESS=1 in its ENVIRONMENT is still reused —
#      the check must not cost an operator the proxy they correctly configured. Not
#      observable on a host that hides process environments; reported as a NOTE there,
#      never as a silent skip.
#  16. An explicit HEADROOM_LOSSLESS=0 reuses a lossy proxy anyway. That operator asked
#      for upstream's CCR default and accepted the streaming risk; hmd enforces its own
#      default rather than overruling a stated choice. This is also the documented
#      escape hatch, which is why the gate adds no second opt-out variable.
#  17. The `--lossless` FLAG alone counts, with no env var set — upstream reads
#      `args.lossless or _get_env_bool(...)`, so an env-only check would refuse a proxy
#      that is in fact safe.
#  18. hmd_headroom_report says NOT ROUTED, with the reason, whenever the chain would
#      refuse. A refusal the operator cannot see is as bad as a silent proxy: they would
#      see Headroom running on the port and assume it is on the wire.
#  19. The proxy hmd itself started IS reused by the next chain run. The regression that
#      pairs with 14: a gate that refused every proxy it did not start in THIS process
#      would cost every session after the first its compression.
#
# FALSIFIABILITY (run by hand, see the commit message for the transcript): with the
# HEADROOM_COMPRESSION_TIMEOUT_SECONDS line reverted out of hmd-headroom-chain.sh,
# guarantee 2 goes RED (`HEADROOM_COMPRESSION_TIMEOUT_SECONDS=` line absent from the
# recorded child env). Restoring the fix turns it GREEN again with no other guarantee
# ever moving — this file is not vacuously green. Symmetrically, reverting only the
# HEADROOM_KOMPRESS_MAX_TOKENS line reds out guarantee 6 alone (the line is absent
# from the recorded child env) while every other guarantee, 2 included, stays green —
# the two vars are independently wired and independently falsifiable, not a single
# guard that happens to cover both. Reverting only the HEADROOM_LOSSLESS line reds out
# guarantee 9 alone, on the same terms.
#
# FALSIFIABILITY OF THE REUSE GATE (run this session, both directions): neutering
# hmd_headroom_reuse_ok's verdict (making it return 0 unconditionally) turns 14 and 18
# RED together and nothing else — they are the act-on-it and show-it-to-the-operator
# halves of one gate, which is why the gate lives in exactly one function. Separately,
# dropping only the `--lossless` argument from the launch line reds out 13 alone, with
# 19 still green here because this host happens to expose environments; on a host that
# does not, that same revert would additionally cost hmd the ability to verify its own
# proxy. An earlier version of guarantee 14's second assertion matched the bare word
# "lossless" and stayed GREEN under the first revert, because the REUSE message says
# "verified lossless" too; it now matches "WITHOUT lossless". That miss was found by
# running the falsification, not by reading the code.
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
import os, sys, json
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
        # `config` is loopback-only in the real proxy (server.py `_health_payload`,
        # include_config=_request_is_loopback(request)) and carries the serving
        # process's own pid. The chain reads that pid to check whether a proxy it did
        # not start has CCR tool injection off, so the fixture has to carry it too.
        body = json.dumps(
            {
                "service": "headroom-proxy",
                "checks": {"upstream": {"url": "https://api.anthropic.com"}},
                "config": {"pid": os.getpid()},
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
    exec python3 "$HTTP_SERVER_PY" "\$port" "\$@"
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
echo "2 — HEADROOM_COMPRESSION_TIMEOUT_SECONDS=30 reaches the child by default"
if [ -s "$ENV1" ]; then
  grep -q '^HEADROOM_COMPRESSION_TIMEOUT_SECONDS=30$' "$ENV1" \
    && ok "the child process env carries HEADROOM_COMPRESSION_TIMEOUT_SECONDS=30" \
    || bad "no HEADROOM_COMPRESSION_TIMEOUT_SECONDS=30 line in the child's recorded env: $(grep '^HEADROOM_COMPRESSION_TIMEOUT_SECONDS=' "$ENV1" 2>/dev/null || echo '<absent entirely>')"
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
    && ok "a caller override (45) reaches the child instead of the 30 default" \
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
echo "6 — HEADROOM_KOMPRESS_MAX_TOKENS=10000 reaches the child by default"
if [ -s "$ENV1" ]; then
  grep -q '^HEADROOM_KOMPRESS_MAX_TOKENS=10000$' "$ENV1" \
    && ok "the child process env carries HEADROOM_KOMPRESS_MAX_TOKENS=10000" \
    || bad "no HEADROOM_KOMPRESS_MAX_TOKENS=10000 line in the child's recorded env: $(grep '^HEADROOM_KOMPRESS_MAX_TOKENS=' "$ENV1" 2>/dev/null || echo '<absent entirely>')"
else
  bad "guarantee 6 skipped — no env dump from guarantee 1 to check"
fi

echo
echo "7 — an operator-supplied HEADROOM_KOMPRESS_MAX_TOKENS override reaches the child unchanged"
PORT4=$((BASE_PORT + 3))
ENV4="$TMP/env4"
(
  export HEADROOM_KOMPRESS_MAX_TOKENS=7500
  . "$CHAIN"
  export HMD_HEADROOM_BIN="$FAKE_BIN"
  export HMD_MODULES_STATE="$MODSTATE"
  export HEIMDALL_HOME="$TMP/home4"
  export HEADROOM_PORT="$PORT4"
  export HMD_FAKE_HEADROOM_ENV_FILE="$ENV4"
  hmd_headroom_chain "$TMP/plugin"
  printf '%s\n' "$?" > "$TMP/rc4"
)
RC4="$(cat "$TMP/rc4" 2>/dev/null || echo 1)"
[ -s "$TMP/home4/headroom/proxy.pid" ] && LIVE_PIDS="$LIVE_PIDS $(cat "$TMP/home4/headroom/proxy.pid")"
if [ "$RC4" = "0" ] && [ -s "$ENV4" ]; then
  grep -q '^HEADROOM_KOMPRESS_MAX_TOKENS=7500$' "$ENV4" \
    && ok "a caller override (7500) reaches the child instead of the 10000 default" \
    || bad "the override did not reach the child: $(grep '^HEADROOM_KOMPRESS_MAX_TOKENS=' "$ENV4" 2>/dev/null || echo '<absent>')"
else
  bad "guarantee 7 skipped — chain did not start cleanly (rc=$RC4)"
fi

echo
echo "8 — HEADROOM_KOMPRESS_MAX_TOKENS is scoped to the ONE child; it does not leak into the sourcing shell"
PORT5=$((BASE_PORT + 4))
ENV5="$TMP/env5"
(
  unset HEADROOM_KOMPRESS_MAX_TOKENS
  . "$CHAIN"
  export HMD_HEADROOM_BIN="$FAKE_BIN"
  export HMD_MODULES_STATE="$MODSTATE"
  export HEIMDALL_HOME="$TMP/home5"
  export HEADROOM_PORT="$PORT5"
  export HMD_FAKE_HEADROOM_ENV_FILE="$ENV5"
  hmd_headroom_chain "$TMP/plugin" >/dev/null 2>&1
  if [ -z "${HEADROOM_KOMPRESS_MAX_TOKENS:-}" ]; then
    echo "SCOPE-OK" > "$TMP/scope5"
  else
    echo "LEAKED=$HEADROOM_KOMPRESS_MAX_TOKENS" > "$TMP/scope5"
  fi
)
[ -s "$TMP/home5/headroom/proxy.pid" ] && LIVE_PIDS="$LIVE_PIDS $(cat "$TMP/home5/headroom/proxy.pid")"
SCOPE5="$(cat "$TMP/scope5" 2>/dev/null || echo "<no result>")"
[ "$SCOPE5" = "SCOPE-OK" ] \
  && ok "HEADROOM_KOMPRESS_MAX_TOKENS does not leak into the sourcing shell after the chain returns" \
  || bad "HEADROOM_KOMPRESS_MAX_TOKENS leaked into the sourcing shell: $SCOPE5"

echo
echo "9 — HEADROOM_LOSSLESS=1 reaches the child by default (the streaming fix)"
if [ -s "$ENV1" ]; then
  grep -q '^HEADROOM_LOSSLESS=1$' "$ENV1" \
    && ok "the child process env carries HEADROOM_LOSSLESS=1" \
    || bad "no HEADROOM_LOSSLESS=1 line in the child's recorded env — the proxy will inject headroom_retrieve and silently downgrade streaming requests to buffered non-stream (#3071/#3130): $(grep '^HEADROOM_LOSSLESS=' "$ENV1" 2>/dev/null || echo '<absent entirely>')"
else
  bad "guarantee 9 skipped — no env dump from guarantee 1 to check"
fi

echo
echo "10 — an operator-supplied HEADROOM_LOSSLESS override reaches the child unchanged"
PORT6=$((BASE_PORT + 5))
ENV6="$TMP/env6"
(
  export HEADROOM_LOSSLESS=0
  . "$CHAIN"
  export HMD_HEADROOM_BIN="$FAKE_BIN"
  export HMD_MODULES_STATE="$MODSTATE"
  export HEIMDALL_HOME="$TMP/home6"
  export HEADROOM_PORT="$PORT6"
  export HMD_FAKE_HEADROOM_ENV_FILE="$ENV6"
  hmd_headroom_chain "$TMP/plugin"
  printf '%s\n' "$?" > "$TMP/rc6"
)
RC6="$(cat "$TMP/rc6" 2>/dev/null || echo 1)"
[ -s "$TMP/home6/headroom/proxy.pid" ] && LIVE_PIDS="$LIVE_PIDS $(cat "$TMP/home6/headroom/proxy.pid")"
if [ "$RC6" = "0" ] && [ -s "$ENV6" ]; then
  grep -q '^HEADROOM_LOSSLESS=0$' "$ENV6" \
    && ok "a caller opt-out (0) reaches the child instead of the 1 default" \
    || bad "the override did not reach the child: $(grep '^HEADROOM_LOSSLESS=' "$ENV6" 2>/dev/null || echo '<absent>')"
else
  bad "guarantee 10 skipped — chain did not start cleanly (rc=$RC6)"
fi

echo
echo "11 — HEADROOM_LOSSLESS is scoped to the ONE child; it does not leak into the sourcing shell"
PORT7=$((BASE_PORT + 6))
ENV7="$TMP/env7"
(
  unset HEADROOM_LOSSLESS
  . "$CHAIN"
  export HMD_HEADROOM_BIN="$FAKE_BIN"
  export HMD_MODULES_STATE="$MODSTATE"
  export HEIMDALL_HOME="$TMP/home7"
  export HEADROOM_PORT="$PORT7"
  export HMD_FAKE_HEADROOM_ENV_FILE="$ENV7"
  hmd_headroom_chain "$TMP/plugin" >/dev/null 2>&1
  if [ -z "${HEADROOM_LOSSLESS:-}" ]; then
    echo "SCOPE-OK" > "$TMP/scope7"
  else
    echo "LEAKED=$HEADROOM_LOSSLESS" > "$TMP/scope7"
  fi
)
[ -s "$TMP/home7/headroom/proxy.pid" ] && LIVE_PIDS="$LIVE_PIDS $(cat "$TMP/home7/headroom/proxy.pid")"
SCOPE7="$(cat "$TMP/scope7" 2>/dev/null || echo "<no result>")"
[ "$SCOPE7" = "SCOPE-OK" ] \
  && ok "HEADROOM_LOSSLESS does not leak into the sourcing shell after the chain returns" \
  || bad "HEADROOM_LOSSLESS leaked into the sourcing shell: $SCOPE7"

echo
echo "12 — HEADROOM_NO_CCR is NOT the knob this chain reaches for"
# --no-ccr also stops the headroom_retrieve injection, so it would silence the same
# streaming downgrade — but upstream documents it as "lossy compression with no
# recovery path", i.e. it keeps destroying content while removing the way back.
# --lossless leaves such content uncompacted instead. Asserting the ABSENCE keeps a
# future edit from swapping in the cheaper-looking var and quietly trading fidelity
# for the same streaming fix.
if [ -s "$ENV1" ]; then
  if grep -q '^HEADROOM_NO_CCR=' "$ENV1"; then
    bad "HEADROOM_NO_CCR is set on the child — that is the lossy-with-no-recovery variant; HEADROOM_LOSSLESS is the one this chain uses"
  else
    ok "HEADROOM_NO_CCR is absent from the child env, as intended"
  fi
else
  bad "guarantee 12 skipped — no env dump from guarantee 1 to check"
fi

echo
echo "13 — the proxy hmd starts carries --lossless on its COMMAND LINE, not only in its env"
# Upstream treats flag and env var as equivalent inputs, so this changes nothing about
# how the proxy behaves. It changes what a LATER session can PROVE about it: argv is
# readable on every platform, environments are not (macOS hides them for SIP-signed
# binaries — measured: /bin/bash and /bin/sleep expose zero env tokens to `ps eww`).
# Without the flag, hmd's own long-lived proxy would eventually be refused as
# unverifiable by the very chain that started it.
PROXY1_PID="$(cat "$TMP/home1/headroom/proxy.pid" 2>/dev/null || echo "")"
PROXY1_ARGV="$(ps -ww -o command= -p "${PROXY1_PID:-0}" 2>/dev/null || echo "")"
case " $PROXY1_ARGV " in
  *" --lossless "*) ok "the running proxy's argv carries --lossless (${PROXY1_ARGV##*/})" ;;
  "  ") bad "guarantee 13 skipped — no live proxy from guarantee 1 to inspect (pid '$PROXY1_PID')" ;;
  *) bad "the proxy hmd started has no --lossless in its argv, so a later session cannot verify it without reading its environment: '$PROXY1_ARGV'" ;;
esac

# ── fixture: a STRANGER proxy — one hmd did NOT start, already listening when the
# chain runs. This is the reuse branch, and it is the branch the HEADROOM_LOSSLESS fix
# could not reach: the var is put on proxies this file LAUNCHES, while a long-lived
# proxy started by `headroom wrap`, by hand, or by an hmd predating the fix keeps
# injecting `headroom_retrieve` and keeps downgrading streaming for every session that
# reuses it. Prints the stranger's pid; the caller adds it to LIVE_PIDS.
start_stranger() {  # <port> <envfile> [extra proxy args...]
  local port="$1" envfile="$2"; shift 2
  HMD_FAKE_HEADROOM_ENV_FILE="$envfile" "$FAKE_BIN" proxy --host 127.0.0.1 --port "$port" "$@" \
    >/dev/null 2>&1 &
  local pid=$! i=0
  while [ "$i" -lt 60 ]; do
    if curl -s --max-time 2 "http://127.0.0.1:$port/health" 2>/dev/null | grep -q headroom-proxy; then
      printf '%s' "$pid"; return 0
    fi
    sleep 0.25; i=$((i+1))
  done
  kill "$pid" >/dev/null 2>&1 || true
  return 1
}

# run_chain_against <port> <home> — source the chain and drive it at an already-busy
# port. Writes rc / url / why to $TMP/<home>.{rc,url,why}.
run_chain_against() {
  local port="$1" home="$2"
  (
    . "$CHAIN"
    export HMD_HEADROOM_BIN="$FAKE_BIN"
    export HMD_MODULES_STATE="$MODSTATE"
    export HEIMDALL_HOME="$TMP/$home"
    export HEADROOM_PORT="$port"
    export HMD_FAKE_HEADROOM_ENV_FILE="$TMP/$home.env"
    hmd_headroom_chain "$TMP/plugin"
    printf '%s\n' "$?"                        > "$TMP/$home.rc"
    printf '%s\n' "$HMD_HEADROOM_BASE_URL"    > "$TMP/$home.url"
    printf '%s\n' "$HMD_HEADROOM_WHY"         > "$TMP/$home.why"
  )
}

echo
echo "14 — a live proxy started WITHOUT lossless mode is NOT reused"
PORT8=$((BASE_PORT + 7))
PID8="$(unset HEADROOM_LOSSLESS; start_stranger "$PORT8" "$TMP/env8")" \
  && LIVE_PIDS="$LIVE_PIDS $PID8"
if [ -n "${PID8:-}" ]; then
  run_chain_against "$PORT8" home8
  RC8="$(cat "$TMP/home8.rc" 2>/dev/null || echo 0)"
  WHY8="$(cat "$TMP/home8.why" 2>/dev/null || echo "")"
  URL8="$(cat "$TMP/home8.url" 2>/dev/null || echo "")"
  [ "$RC8" != "0" ] && [ -z "$URL8" ] \
    && ok "the chain refuses to route into a CCR-injecting proxy it did not start (why: $WHY8)" \
    || bad "the chain reused a proxy started without lossless mode (rc=$RC8 url=$URL8) — every streaming request through it is downgraded to buffered (#3071/#3130)"
  # Matched on the phrase a REFUSAL uses, not on the bare word "lossless" — the reuse
  # message says "verified lossless" too, so the loose match passed even with the gate
  # removed (measured while falsifying this suite).
  case "$WHY8" in
    *"WITHOUT lossless"*) ok "the refusal names lossless mode, so the operator can act on it" ;;
    *) bad "the refusal reason does not name lossless mode: '$WHY8'" ;;
  esac
  [ -s "$TMP/home8/headroom/proxy.pid" ] \
    && bad "the chain started a SECOND proxy after refusing the live one" \
    || ok "refusing routes nothing and starts nothing"
else
  bad "guarantee 14 skipped — the stranger proxy never became ready on $PORT8"
fi

echo
echo "15 — a live proxy started WITH HEADROOM_LOSSLESS=1 IS reused"
PORT9=$((BASE_PORT + 8))
PID9="$(export HEADROOM_LOSSLESS=1; start_stranger "$PORT9" "$TMP/env9")" \
  && LIVE_PIDS="$LIVE_PIDS $PID9"
# Environment visibility is a property of the target binary, not of the host, so it is
# measured on THIS process rather than assumed or probed on some unrelated pid.
PS_ENV_VISIBLE=0
[ -n "${PID9:-}" ] && ps eww -p "$PID9" 2>/dev/null | tr ' ' '\n' | grep -q '^PATH=' \
  && PS_ENV_VISIBLE=1
if [ "$PS_ENV_VISIBLE" = "1" ] && [ -n "${PID9:-}" ]; then
  run_chain_against "$PORT9" home9
  RC9="$(cat "$TMP/home9.rc" 2>/dev/null || echo 1)"
  URL9="$(cat "$TMP/home9.url" 2>/dev/null || echo "")"
  WHY9="$(cat "$TMP/home9.why" 2>/dev/null || echo "")"
  [ "$RC9" = "0" ] && [ "$URL9" = "http://127.0.0.1:$PORT9" ] \
    && ok "a verified-lossless live proxy is still reused (why: $WHY9)" \
    || bad "the chain refused a proxy that IS lossless (rc=$RC9 url=$URL9 why=$WHY9) — the check is over-tight and costs the operator their running proxy"
elif [ -n "${PID9:-}" ]; then
  printf '  \033[33mNOTE\033[0m %s\n' "guarantee 15 not observable — this host hides this process's environment from ps, so an env-only-lossless stranger is refused as unverifiable (which is the safe direction, and what guarantee 14 proves)"
else
  bad "guarantee 15 skipped — the stranger proxy never became ready on $PORT9"
fi

echo
echo "16 — an explicit HEADROOM_LOSSLESS=0 opt-out reuses a lossy proxy anyway"
# The operator who exports 0 has ASKED for upstream's CCR default and accepted the
# streaming risk with it. hmd enforces its own default; it does not overrule a choice
# the operator stated. This is also the documented escape hatch for anyone who wants a
# reused lossy proxy back, which is why no second opt-out variable exists.
PORT10=$((BASE_PORT + 9))
PID10="$(unset HEADROOM_LOSSLESS; start_stranger "$PORT10" "$TMP/env10")" \
  && LIVE_PIDS="$LIVE_PIDS $PID10"
if [ -n "${PID10:-}" ]; then
  ( export HEADROOM_LOSSLESS=0; run_chain_against "$PORT10" home10 )
  RC10="$(cat "$TMP/home10.rc" 2>/dev/null || echo 1)"
  URL10="$(cat "$TMP/home10.url" 2>/dev/null || echo "")"
  [ "$RC10" = "0" ] && [ "$URL10" = "http://127.0.0.1:$PORT10" ] \
    && ok "HEADROOM_LOSSLESS=0 disables the reuse gate, as the operator asked" \
    || bad "the reuse gate fired despite an explicit opt-out (rc=$RC10 url=$URL10 why=$(cat "$TMP/home10.why" 2>/dev/null))"
else
  bad "guarantee 16 skipped — the stranger proxy never became ready on $PORT10"
fi

echo
echo "17 — a proxy started with the --lossless FLAG (no env var) is reused"
# `lossless = getattr(args, "lossless", False) or _get_env_bool("HEADROOM_LOSSLESS",
# False)` — the flag alone is enough upstream, so a check that only read the
# environment would refuse a proxy that is in fact safe.
PORT11=$((BASE_PORT + 10))
PID11="$(unset HEADROOM_LOSSLESS; start_stranger "$PORT11" "$TMP/env11" --lossless)" \
  && LIVE_PIDS="$LIVE_PIDS $PID11"
if [ -n "${PID11:-}" ]; then
  run_chain_against "$PORT11" home11
  RC11="$(cat "$TMP/home11.rc" 2>/dev/null || echo 1)"
  URL11="$(cat "$TMP/home11.url" 2>/dev/null || echo "")"
  [ "$RC11" = "0" ] && [ "$URL11" = "http://127.0.0.1:$PORT11" ] \
    && ok "the --lossless command-line flag counts as lossless, not just the env var" \
    || bad "a --lossless proxy was refused (rc=$RC11 url=$URL11 why=$(cat "$TMP/home11.why" 2>/dev/null))"
else
  bad "guarantee 17 skipped — the stranger proxy never became ready on $PORT11"
fi

echo
echo "18 — hmd_headroom_report tells the operator the live proxy is not being used"
# A silent refusal is as bad as a silent proxy: `hmd modules status headroom` has to
# say NOT ROUTED, and say why, or the operator sees a running proxy and assumes it is
# on the wire.
if [ -n "${PID8:-}" ]; then
  REPORT8="$(
    . "$CHAIN"
    export HMD_MODULES_STATE="$MODSTATE"
    export HMD_HEADROOM_BIN="$FAKE_BIN"
    export HEADROOM_PORT="$PORT8"
    hmd_headroom_report "$TMP/plugin"
  )"
  case "$REPORT8" in
    "NOT ROUTED"*) ok "the report reads: $REPORT8" ;;
    *) bad "the report claims traffic is routed through a proxy the chain refuses: '$REPORT8'" ;;
  esac
else
  bad "guarantee 18 skipped — no refused stranger proxy from guarantee 14 to report on"
fi

echo
echo "19 — the proxy hmd started IS reused by the next chain run (no self-refusal)"
# The regression this pairs with guarantee 14: a gate that refuses every proxy it did
# not start in THIS process would cost every session after the first its compression.
# The chain re-enters the reuse branch against the proxy guarantee 1 launched.
if [ -n "${PROXY1_PID:-}" ]; then
  run_chain_against "$PORT1" home12
  RC12="$(cat "$TMP/home12.rc" 2>/dev/null || echo 1)"
  URL12="$(cat "$TMP/home12.url" 2>/dev/null || echo "")"
  WHY12="$(cat "$TMP/home12.why" 2>/dev/null || echo "")"
  [ "$RC12" = "0" ] && [ "$URL12" = "http://127.0.0.1:$PORT1" ] \
    && ok "hmd reuses its own still-running proxy (why: $WHY12)" \
    || bad "hmd refused the proxy it started itself (rc=$RC12 url=$URL12 why=$WHY12)"
  case "$WHY12" in
    *"verified lossless"*) ok "the reuse reason records that the verdict was measured, not assumed" ;;
    *) bad "the reuse reason does not record the lossless verdict: '$WHY12'" ;;
  esac
else
  bad "guarantee 19 skipped — no live proxy from guarantee 1 to reuse"
fi

echo
echo "--------------------------------------------------------------------"
printf 'headroom-wrap-chain: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
