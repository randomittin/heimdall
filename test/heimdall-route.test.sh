#!/usr/bin/env bash
#
# heimdall-route.test.sh — acceptance for bin/heimdall-route, the launch-time routing
# half of the Headroom chain.
#
# WHY THE FILE UNDER TEST EXISTS. The chain had exactly one caller — `hmd wrap <tool>`,
# which also installs Layer-0 git hooks, writes the AGENTS.md fence and starts presence.
# Those are the right side effects for adopting a repo and the wrong ones for "compress
# my sessions", so anyone launching `claude` directly got no proxy. Measured over
# 2026-08-11..19 on the machine this was written on: 140 distinct Claude Code session
# ids in Headroom's logs against 403 session transcripts in the same window. The proxy
# itself was working — 90.8% of its 15,605 request records carried cache_read > 0 — so
# the gap was coverage, not compression.
#
# HOW THIS RUNS HERMETICALLY. HMD_HEADROOM_BIN points the chain at a recorder instead of
# the real `headroom`, and the tool being "launched" is a script that dumps its own
# environment and exits. No network, no ML model, no real proxy, no real editor.
#
# Guarantees proved:
#   1. The binary exists, is executable, parses, and is REACHABLE from the router
#      (`hmd route`). A tool reachable from nothing enforces nothing — this repo has
#      found three such subsystems already, and this asserts against a fourth.
#   2. --url prints the chain's base URL when a verified-lossless proxy is live.
#   3. --url fails, and prints NOTHING on stdout, when the live proxy is one the chain
#      refuses (started without lossless). The gate is inherited, not re-implemented.
#   4. Launching a tool puts ANTHROPIC_BASE_URL on the CHILD process — asserted from
#      the child's own recorded environment, not from the launching shell.
#   5. FAIL-OPEN: with the module absent the tool is still launched, with no
#      ANTHROPIC_BASE_URL and a reason on stderr. A compression proxy that can stop a
#      session from starting is worse than no compression.
#   6. HTTPS_PROXY / ALL_PROXY / HTTP_PROXY are never set on the child. Those route
#      EVERYTHING — control plane, enrollment, presence — through the rewriter.
#   7. An unknown tool exits 127 with a named reason and launches nothing.
#   8. NO REPO MUTATION. A git worktree is checksummed before and after a routed
#      launch and must be byte-identical, including .git and untracked files. This is
#      the property that makes it safe to put on every launch in any directory, and it
#      is the one that separates `hmd route` from `hmd wrap`.
#   9. --status answers "am I routed right now" without launching anything.
#
# Usage:  bash test/heimdall-route.test.sh   (exit 0 = every guarantee holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
ROUTE="$REPO/bin/heimdall-route"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-route.XXXXXX")"
LIVE_PIDS=""
cleanup() {
  local p
  for p in $LIVE_PIDS; do kill "$p" >/dev/null 2>&1 || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

BASE_PORT=$((26000 + ($$ % 4000)))

echo
echo "1 — the binary exists, parses, and is reachable from the router"
[ -f "$ROUTE" ] && [ -x "$ROUTE" ] && ok "bin/heimdall-route exists and is executable" \
  || { bad "bin/heimdall-route missing or not executable"; echo "FATAL"; exit 1; }
bash -n "$ROUTE" && ok "bin/heimdall-route parses (bash -n)" \
  || bad "bin/heimdall-route has a syntax error"
if "$REPO/bin/hmd" route --help 2>/dev/null | grep -q "hmd route"; then
  ok "\`hmd route\` reaches it through the router"
else
  bad "\`hmd route\` does not reach bin/heimdall-route — the tool is unreachable from the CLI"
fi

# ── fixtures ──────────────────────────────────────────────────────────────────────────
# The /health responder the recorder execs into: a real answer, including the
# loopback-only `config.pid` the chain's reuse gate reads.
HTTP_SERVER_PY="$TMP/fake_http_server.py"
cat > "$HTTP_SERVER_PY" <<'PYEOF'
import os, sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        return None

    def do_GET(self):
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

# The fake `headroom` CLI: understands `proxy --host H --port P [--lossless]`, forwards
# its argv to the responder so the reuse gate can read it, and answers --version.
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
    exec python3 "$HTTP_SERVER_PY" "\$port" "\$@"
    ;;
  --version) echo "headroom, version FAKE-RECORDER" ;;
  *) echo "fake-headroom: unhandled args: \$*" >&2; exit 2 ;;
esac
EOSH
chmod +x "$FAKE_BIN"

# The "tool": dumps its own environment where the assertions can read it.
TOOLDIR="$TMP/toolbin"; mkdir -p "$TOOLDIR"
cat > "$TOOLDIR/faketool" <<'EOSH'
#!/usr/bin/env bash
env > "${FAKETOOL_ENV_FILE:?FAKETOOL_ENV_FILE not set}"
printf 'faketool ran with args: %s\n' "$*"
EOSH
chmod +x "$TOOLDIR/faketool"

# An installed, opted-in module state.
MODSTATE="$TMP/modstate"; mkdir -p "$MODSTATE/headroom"
printf '{}\n' > "$MODSTATE/headroom/receipt.json"

# start_proxy <port> [extra args…] — a live proxy the chain will find on the port.
start_proxy() {
  local port="$1"; shift
  "$FAKE_BIN" proxy --host 127.0.0.1 --port "$port" "$@" >/dev/null 2>&1 &
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

echo
echo "2 — --url prints the chain's base URL against a verified-lossless proxy"
PORT1=$BASE_PORT
PID1="$(start_proxy "$PORT1" --lossless)" && LIVE_PIDS="$LIVE_PIDS $PID1"
if [ -n "${PID1:-}" ]; then
  URL1="$(HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
          HEIMDALL_HOME="$TMP/home1" HEADROOM_PORT="$PORT1" "$ROUTE" --url 2>/dev/null)"
  [ "$URL1" = "http://127.0.0.1:$PORT1" ] \
    && ok "--url prints $URL1" \
    || bad "--url printed '$URL1', expected http://127.0.0.1:$PORT1"
else
  bad "guarantee 2 skipped — the fixture proxy never became ready on $PORT1"
fi

echo
echo "3 — --url fails, and prints nothing, when the chain refuses the live proxy"
PORT2=$((BASE_PORT + 1))
PID2="$(unset HEADROOM_LOSSLESS; start_proxy "$PORT2")" && LIVE_PIDS="$LIVE_PIDS $PID2"
if [ -n "${PID2:-}" ]; then
  OUT2="$(HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
          HEIMDALL_HOME="$TMP/home2" HEADROOM_PORT="$PORT2" "$ROUTE" --url 2>"$TMP/err2")"
  RC2=$?
  if [ "$RC2" != "0" ] && [ -z "$OUT2" ]; then
    ok "--url exits $RC2 with empty stdout when the proxy is refused"
  else
    bad "--url returned rc=$RC2 stdout='$OUT2' — a refused proxy must not yield a URL"
  fi
  grep -q "lossless" "$TMP/err2" \
    && ok "the reason reaches stderr, where a shell integration can show it" \
    || bad "no reason on stderr: $(cat "$TMP/err2")"
else
  bad "guarantee 3 skipped — the fixture proxy never became ready on $PORT2"
fi

echo
echo "4 — a launched tool receives ANTHROPIC_BASE_URL in its OWN environment"
ENV4="$TMP/env4"
if [ -n "${PID1:-}" ]; then
  PATH="$TOOLDIR:$PATH" FAKETOOL_ENV_FILE="$ENV4" \
    HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
    HEIMDALL_HOME="$TMP/home4" HEADROOM_PORT="$PORT1" \
    "$ROUTE" faketool --some-flag value >"$TMP/out4" 2>"$TMP/err4"
  RC4=$?
  [ "$RC4" = "0" ] && ok "the tool ran (exit 0)" || bad "the tool did not run cleanly (rc=$RC4): $(cat "$TMP/err4")"
  grep -q "^ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT1$" "$ENV4" 2>/dev/null \
    && ok "the child env carries ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT1" \
    || bad "child env has no ANTHROPIC_BASE_URL for the live proxy: $(grep '^ANTHROPIC_BASE_URL=' "$ENV4" 2>/dev/null || echo '<absent>')"
  grep -q -- "--some-flag value" "$TMP/out4" \
    && ok "the tool's own arguments are forwarded verbatim" \
    || bad "arguments were not forwarded: $(cat "$TMP/out4")"
  grep -q "routed via" "$TMP/err4" \
    && ok "routing is disclosed on stderr, never silent" \
    || bad "the launch did not disclose that it is proxied: $(cat "$TMP/err4")"
else
  bad "guarantee 4 skipped — no live fixture proxy"
fi

echo
echo "5 — FAIL-OPEN: with the module absent, the tool still launches, unproxied"
ENV5="$TMP/env5"
EMPTY_STATE="$TMP/empty-modstate"; mkdir -p "$EMPTY_STATE"
PATH="$TOOLDIR:$PATH" FAKETOOL_ENV_FILE="$ENV5" \
  HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$EMPTY_STATE" \
  HEIMDALL_HOME="$TMP/home5" HEADROOM_PORT=$((BASE_PORT + 9)) \
  "$ROUTE" faketool >"$TMP/out5" 2>"$TMP/err5"
RC5=$?
[ "$RC5" = "0" ] && ok "the tool launched anyway (exit 0)" \
  || bad "an unavailable proxy blocked the launch (rc=$RC5) — fail-open is the contract"
if grep -q '^ANTHROPIC_BASE_URL=' "$ENV5" 2>/dev/null; then
  bad "ANTHROPIC_BASE_URL was set with no usable proxy: $(grep '^ANTHROPIC_BASE_URL=' "$ENV5")"
else
  ok "no ANTHROPIC_BASE_URL on the child when nothing is routed"
fi
# The reason must be the CHAIN's, not the placeholder. Matching only "not routing" let
# the subshell defect (a lost HMD_HEADROOM_WHY, printed as "no reason reported") pass.
if grep -q "not routing" "$TMP/err5" && ! grep -q "no reason reported" "$TMP/err5"; then
  ok "the un-routed launch says so, with the chain's own reason"
else
  bad "silent or reasonless un-routed launch: $(cat "$TMP/err5")"
fi

echo
echo "6 — the generic proxy variables are NEVER set on the child"
if [ -s "$ENV4" ]; then
  LEAKED=""
  for v in HTTPS_PROXY ALL_PROXY HTTP_PROXY https_proxy all_proxy http_proxy; do
    grep -q "^$v=" "$ENV4" && LEAKED="$LEAKED $v"
  done
  [ -z "$LEAKED" ] \
    && ok "no HTTPS_PROXY/ALL_PROXY/HTTP_PROXY on the child — only ANTHROPIC_BASE_URL is set" \
    || bad "the child inherited generic proxy vars ($LEAKED) — that routes signed traffic too"
else
  bad "guarantee 6 skipped — no child env recorded in guarantee 4"
fi

echo
echo "7 — an unknown tool exits 127 with a named reason and launches nothing"
OUT7="$( "$ROUTE" definitely-not-a-real-tool-xyz 2>&1 )"; RC7=$?
[ "$RC7" = "127" ] && ok "exit 127 for a tool that is not on PATH" \
  || bad "expected exit 127, got $RC7"
case "$OUT7" in
  *"not installed"*) ok "the failure names the missing tool" ;;
  *) bad "unhelpful failure text: '$OUT7'" ;;
esac

echo
echo "8 — NO REPO MUTATION: a routed launch leaves the working tree byte-identical"
# This is what separates `hmd route` from `hmd wrap`, and it is why this is safe to put
# on every launch in every directory. The sum covers tracked files, untracked files and
# .git itself, so a stray hook, fence line or config key would move it.
SANDBOX="$TMP/sandbox"; mkdir -p "$SANDBOX"
(
  cd "$SANDBOX" || exit 1
  git init -q . 2>/dev/null
  printf 'hello\n' > file.txt
  git add file.txt 2>/dev/null
  git -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
) >/dev/null 2>&1
treesum() { ( cd "$1" && find . -type f -exec shasum {} \; 2>/dev/null | sort | shasum | awk '{print $1}' ); }
SUM_BEFORE="$(treesum "$SANDBOX")"
if [ -n "${PID1:-}" ]; then
  ( cd "$SANDBOX" && PATH="$TOOLDIR:$PATH" FAKETOOL_ENV_FILE="$TMP/env8" \
      HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
      HEIMDALL_HOME="$TMP/home8" HEADROOM_PORT="$PORT1" \
      "$ROUTE" faketool >/dev/null 2>&1 )
  SUM_AFTER="$(treesum "$SANDBOX")"
  [ "$SUM_BEFORE" = "$SUM_AFTER" ] \
    && ok "the repo is byte-identical after a routed launch ($SUM_BEFORE)" \
    || bad "the routed launch mutated the repo ($SUM_BEFORE -> $SUM_AFTER) — route must never wrap"
else
  bad "guarantee 8 skipped — no live fixture proxy"
fi

echo
echo "9 — --status answers 'am I routed' without launching anything"
if [ -n "${PID1:-}" ]; then
  ST="$(HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
        HEADROOM_PORT="$PORT1" "$ROUTE" --status 2>/dev/null)"
  case "$ST" in
    ROUTED*)     ok "--status reports: $ST" ;;
    "NOT ROUTED"*) bad "--status says NOT ROUTED against a live verified proxy: $ST" ;;
    *)           bad "--status printed something unrecognised: '$ST'" ;;
  esac
  ST2="$(HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
         HEADROOM_PORT=$((BASE_PORT + 19)) "$ROUTE" --status 2>/dev/null)"
  case "$ST2" in
    "NOT ROUTED"*) ok "--status reports NOT ROUTED when no proxy is listening" ;;
    *) bad "--status claimed routing with no proxy on the port: '$ST2'" ;;
  esac
else
  bad "guarantee 9 skipped — no live fixture proxy"
fi

echo
echo "--------------------------------------------------------------------"
printf 'heimdall-route: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
