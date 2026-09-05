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
# Guarantees 10 onward additionally PATH-shadow a FAKE `heimdall-fallback` ahead of the
# real one to dictate the fallback verdict a test wants; the real `.heimdall/fallback.json`
# and any real OmniRoute gateway are never touched, and no guarantee below makes a
# network call.
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
# Commit 6de9093 added a FALLBACK PRECEDENCE block: `heimdall-fallback base-url` /
# `token-file` now feed ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN, and the fallback gate
# wins over headroom when it says ROUTE. Guarantees 10-21 cover that seam:
#  10. FAIL-OPEN, named: with no .heimdall/fallback.json at all, the launch is
#      unchanged — headroom still routes, the child still launches.
#  11. FAIL-OPEN: with `heimdall-fallback` absent from PATH entirely (not merely
#      unconfigured), the launch still succeeds and still takes the headroom path.
#  12. FAIL-OPEN: a non-loopback or garbage `base-url` stdout (a wrong host, plain
#      text, a traceback line) is never exported as ANTHROPIC_BASE_URL — only a
#      literal loopback URL is trusted.
#  13. PRECEDENCE: when the fallback gate says ROUTE, it wins over a live headroom
#      proxy — the two re-point the same variable and are mutually exclusive.
#  14. The stderr disclosure on that path names the fallback destination and says
#      headroom compression is OFF for the session.
#  15. TOKEN: on the fallback path, ANTHROPIC_AUTH_TOKEN equals the configured
#      token file's own contents.
#  16. TOKEN: that value never appears in the route command's OWN stdout or
#      stderr — only in the child's environment.
#  17. TOKEN: on a launch NOT routed to the fallback, a pre-set ANTHROPIC_AUTH_TOKEN
#      that byte-matches the token file is dropped before the child ever sees it.
#  18. TOKEN: on the same kind of launch, a pre-set ANTHROPIC_AUTH_TOKEN that does
#      NOT match the token file (an operator's real key) passes through untouched
#      — the pair to 17, and the one that catches an over-broad unset.
#  19. --url answers for the fallback destination too, when the gate says ROUTE.
#  20. --status names the fallback route and its URL, when the gate says ROUTE.
#  21. On the fallback path, ANTHROPIC_MODEL is pinned from `heimdall-fallback model`
#      (commit 81e252d) only when the operator left it unset; an operator-set
#      ANTHROPIC_MODEL is never overridden.
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

# Ports are OS-assigned, not PID-derived: a PID-modulo scheme guesses into a fixed,
# narrow, guessable range with zero collision detection or retry, so any unrelated
# process already bound to that one exact port turns every downstream guarantee that
# reuses it red (confirmed: an external occupier on the predicted port alone cascades
# a clean 19/0 run to 10 passed, 5 failed). All four ports needed below are bound
# SIMULTANEOUSLY in one interpreter so the OS cannot hand out the same number twice
# for this run — a collision with something else entirely, after release, is the
# same small residual TOCTOU window every free-port allocator (incl. the OS itself)
# has; it is not eliminable, only narrowed from "guaranteed within a 4000-port range
# on collision" to "requires an unrelated bind in a vanishingly short window."
read -r PORT1 PORT2 PORT_FAILOPEN PORT_UNUSED <<<"$(python3 -c '
import socket
socks = [socket.socket(socket.AF_INET, socket.SOCK_STREAM) for _ in range(4)]
for s in socks:
    s.bind(("127.0.0.1", 0))
ports = [s.getsockname()[1] for s in socks]
for s in socks:
    s.close()
print(" ".join(str(p) for p in ports))
')"

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

# A config-free sandbox for every guarantee below that invokes "$ROUTE" without already
# controlling its own cwd. bin/heimdall-route resolves the fallback gate via
# `heimdall-fallback --repo "$PWD" ...`, so whatever directory this suite happens to be
# INVOKED FROM leaks straight into guarantees 2, 3, 4, 5 and 9 — including a real
# operator's own .heimdall/fallback.json, if one exists at that cwd. Pinning cwd to this
# empty, throwaway directory for those five guarantees makes them pass or fail on
# headroom precedence alone, never on whatever fallback state happens to be ambient on
# the host running the suite. Mirrors the NOFB_REPO pattern guarantee 10 already uses.
FALLBACK_FREE_REPO="$TMP/fallback-free-repo"; mkdir -p "$FALLBACK_FREE_REPO"

echo
echo "2 — --url prints the chain's base URL against a verified-lossless proxy"
PID1="$(start_proxy "$PORT1" --lossless)" && LIVE_PIDS="$LIVE_PIDS $PID1"
if [ -n "${PID1:-}" ]; then
  URL1="$(cd "$FALLBACK_FREE_REPO" && HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
          HEIMDALL_HOME="$TMP/home1" HEADROOM_PORT="$PORT1" "$ROUTE" --url 2>/dev/null)"
  [ "$URL1" = "http://127.0.0.1:$PORT1" ] \
    && ok "--url prints $URL1" \
    || bad "--url printed '$URL1', expected http://127.0.0.1:$PORT1"
else
  bad "guarantee 2 skipped — the fixture proxy never became ready on $PORT1"
fi

echo
echo "3 — --url fails, and prints nothing, when the chain refuses the live proxy"
PID2="$(unset HEADROOM_LOSSLESS; start_proxy "$PORT2")" && LIVE_PIDS="$LIVE_PIDS $PID2"
if [ -n "${PID2:-}" ]; then
  OUT2="$(cd "$FALLBACK_FREE_REPO" && HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
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
  ( cd "$FALLBACK_FREE_REPO" && PATH="$TOOLDIR:$PATH" FAKETOOL_ENV_FILE="$ENV4" \
    HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
    HEIMDALL_HOME="$TMP/home4" HEADROOM_PORT="$PORT1" \
    "$ROUTE" faketool --some-flag value >"$TMP/out4" 2>"$TMP/err4" )
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
( cd "$FALLBACK_FREE_REPO" && PATH="$TOOLDIR:$PATH" FAKETOOL_ENV_FILE="$ENV5" \
  HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$EMPTY_STATE" \
  HEIMDALL_HOME="$TMP/home5" HEADROOM_PORT="$PORT_FAILOPEN" \
  "$ROUTE" faketool >"$TMP/out5" 2>"$TMP/err5" )
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
  ST="$(cd "$FALLBACK_FREE_REPO" && HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
        HEADROOM_PORT="$PORT1" "$ROUTE" --status 2>/dev/null)"
  case "$ST" in
    ROUTED*)     ok "--status reports: $ST" ;;
    "NOT ROUTED"*) bad "--status says NOT ROUTED against a live verified proxy: $ST" ;;
    *)           bad "--status printed something unrecognised: '$ST'" ;;
  esac
  ST2="$(cd "$FALLBACK_FREE_REPO" && HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
         HEADROOM_PORT="$PORT_UNUSED" "$ROUTE" --status 2>/dev/null)"
  case "$ST2" in
    "NOT ROUTED"*) ok "--status reports NOT ROUTED when no proxy is listening" ;;
    *) bad "--status claimed routing with no proxy on the port: '$ST2'" ;;
  esac
else
  bad "guarantee 9 skipped — no live fixture proxy"
fi

# ── fixtures for guarantees 10+ (commit 6de9093's FALLBACK PRECEDENCE block) ─────────
# Guarantees 10-20 prove the seam `hmd route` now has onto `heimdall-fallback
# base-url`/`token-file`: it must fail open, it must never trust garbage on stdout as a
# URL, it must actually win precedence over headroom when the gate says ROUTE, and it
# must move a gateway token without ever leaking it or crossing it into the wrong
# audience. Guarantees 13-20 PATH-shadow a FAKE heimdall-fallback ahead of the real one;
# 10-12 exercise the real one (or its deliberate absence) against a config-free sandbox.
# Nothing here reads the real .heimdall/fallback.json, touches a real OmniRoute gateway,
# or makes a network call.

# A loopback URL string bin/heimdall-route only ever pattern-matches and exports; it is
# never dialed by anything in this suite (faketool just dumps its own env and exits), so
# it needs no real listener behind it.
FB_URL="http://127.0.0.1:65432"

# The fake heimdall-fallback: one script, entirely driven by env vars set immediately
# before each invocation, so it serves every guarantee below without being rewritten.
#   FBSTUB_URL / FBSTUB_URL_RC               -> base-url's stdout / exit code
#   FBSTUB_TOKEN_FILE / FBSTUB_TOKEN_FILE_RC -> token-file's stdout / exit code
#   FBSTUB_MODEL / FBSTUB_MODEL_RC           -> model's stdout / exit code
# Empty FBSTUB_URL (resp. FBSTUB_TOKEN_FILE, FBSTUB_MODEL) means "print nothing", same
# as the real tool's own fail-closed contract. An unhandled subcommand (e.g. a real
# `heimdall-fallback` that has not grown `model` yet) falls to the catch-all below,
# which is deliberately harmless: stderr only, never a hang or a crash — proving the
# fail-open contract holds even against a heimdall-fallback that predates this seam.
FBSTUB_DIR="$TMP/fbstub"; mkdir -p "$FBSTUB_DIR"
cat > "$FBSTUB_DIR/heimdall-fallback" <<'EOSH'
#!/usr/bin/env bash
set -uo pipefail
case " $* " in
  *" base-url "*)
    [ -n "${FBSTUB_URL:-}" ] && printf '%s\n' "$FBSTUB_URL"
    exit "${FBSTUB_URL_RC:-0}" ;;
  *" token-file "*)
    [ -n "${FBSTUB_TOKEN_FILE:-}" ] && printf '%s\n' "$FBSTUB_TOKEN_FILE"
    exit "${FBSTUB_TOKEN_FILE_RC:-0}" ;;
  *" model "*)
    [ -n "${FBSTUB_MODEL:-}" ] && printf '%s\n' "$FBSTUB_MODEL"
    exit "${FBSTUB_MODEL_RC:-0}" ;;
  *)
    printf 'fake-heimdall-fallback: unhandled args: %s\n' "$*" >&2
    exit 2 ;;
esac
EOSH
chmod +x "$FBSTUB_DIR/heimdall-fallback"

# A 0600 gateway-token file holding a sentinel value. Must reach the child's
# ANTHROPIC_AUTH_TOKEN on the fallback path, must never appear on the route command's
# own stdout/stderr, and must never ride along to a launch it is not the audience for.
TOKEN_SENTINEL="SENTINEL_ROUTE_TOKEN_9922"
TOKFILE="$TMP/gateway-token"
printf '%s' "$TOKEN_SENTINEL" > "$TOKFILE"
chmod 600 "$TOKFILE"

# `heimdall-fallback` genuinely absent from PATH: built by DROPPING every PATH entry
# that resolves it, rather than assuming it lives at some fixed system path — the real
# binary's install location is not this test's business.
NOFB_PATH=""
_old_ifs="$IFS"
IFS=':'
for _d in $PATH; do
  [ -n "$_d" ] || continue
  [ -x "$_d/heimdall-fallback" ] && continue
  NOFB_PATH="${NOFB_PATH:+$NOFB_PATH:}$_d"
done
IFS="$_old_ifs"

# check_garbage_rejected LABEL GARBAGE_STDOUT STUB_EXIT — guarantee 12's body, reused
# for three garbage shapes. HEADROOM_PORT is a dead port, so the only correct outcome
# is that ANTHROPIC_BASE_URL is ABSENT from the child — never the garbage value.
check_garbage_rejected() {
  local label="$1" garbage="$2" rc="$3"
  local envfile="$TMP/env12-$1" outfile="$TMP/out12-$1" errfile="$TMP/err12-$1"
  # HMD_MODULES_STATE is the EMPTY state (module not installed), not MODSTATE: this
  # isolates the garbage-rejection property from headroom's own chain, which would
  # otherwise legitimately fork a fresh proxy onto PORT_UNUSED (a genuinely free port)
  # and set ANTHROPIC_BASE_URL to ITS OWN url, unrelated to the garbage under test here.
  FBSTUB_URL="$garbage" FBSTUB_URL_RC="$rc" PATH="$FBSTUB_DIR:$TOOLDIR:$PATH" \
    FAKETOOL_ENV_FILE="$envfile" HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$EMPTY_STATE" \
    HEIMDALL_HOME="$TMP/home12-$1" HEADROOM_PORT="$PORT_UNUSED" \
    "$ROUTE" faketool >"$outfile" 2>"$errfile"
  if grep -q "^ANTHROPIC_BASE_URL=" "$envfile" 2>/dev/null; then
    bad "garbage base-url ($label: '$garbage') leaked into the child: $(grep '^ANTHROPIC_BASE_URL=' "$envfile")"
  else
    ok "garbage base-url ($label) rejected — no ANTHROPIC_BASE_URL reached the child"
  fi
}

echo
echo "10 — FAIL-OPEN, named: with no .heimdall/fallback.json the launch is unchanged"
NOFB_REPO="$TMP/no-fallback-config-repo"; mkdir -p "$NOFB_REPO"
ENV10="$TMP/env10"
if [ -n "${PID1:-}" ]; then
  ( cd "$NOFB_REPO" && PATH="$TOOLDIR:$PATH" FAKETOOL_ENV_FILE="$ENV10" \
      HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
      HEIMDALL_HOME="$TMP/home10" HEADROOM_PORT="$PORT1" \
      "$ROUTE" faketool >"$TMP/out10" 2>"$TMP/err10" )
  RC10=$?
  [ "$RC10" = "0" ] && ok "no fallback.json: the child still launches (exit 0)" \
    || bad "no fallback.json: launch failed (rc=$RC10): $(cat "$TMP/err10")"
  grep -q "^ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT1$" "$ENV10" 2>/dev/null \
    && ok "no fallback.json: headroom path taken unchanged (pre-6de9093 behavior)" \
    || bad "no fallback.json: headroom path was not taken: $(grep '^ANTHROPIC_BASE_URL=' "$ENV10" 2>/dev/null || echo '<absent>')"
else
  bad "guarantee 10 skipped — no live fixture proxy"
fi

echo
echo "11 — FAIL-OPEN: with heimdall-fallback absent from PATH entirely, the launch still succeeds"
if PATH="$NOFB_PATH" command -v heimdall-fallback >/dev/null 2>&1; then
  bad "guarantee 11 setup is broken — heimdall-fallback is still resolvable on the trimmed PATH"
else
  ok "setup check: heimdall-fallback is genuinely unresolvable on the trimmed PATH"
fi
ENV11="$TMP/env11"
if [ -n "${PID1:-}" ]; then
  PATH="$TOOLDIR:$NOFB_PATH" FAKETOOL_ENV_FILE="$ENV11" \
    HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
    HEIMDALL_HOME="$TMP/home11" HEADROOM_PORT="$PORT1" \
    "$ROUTE" faketool >"$TMP/out11" 2>"$TMP/err11"
  RC11=$?
  [ "$RC11" = "0" ] && ok "heimdall-fallback absent from PATH: the tool still launches (exit 0)" \
    || bad "heimdall-fallback absent from PATH: launch failed (rc=$RC11): $(cat "$TMP/err11")"
  grep -q "^ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT1$" "$ENV11" 2>/dev/null \
    && ok "heimdall-fallback absent from PATH: headroom path is still taken" \
    || bad "heimdall-fallback absent from PATH: headroom path was not taken: $(grep '^ANTHROPIC_BASE_URL=' "$ENV11" 2>/dev/null || echo '<absent>')"
else
  bad "guarantee 11 skipped — no live fixture proxy"
fi

echo
echo "12 — FAIL-OPEN: a non-loopback or garbage base-url is never exported as ANTHROPIC_BASE_URL"
check_garbage_rejected "wrong-host"     "http://evil.example.com"            0
check_garbage_rejected "plain-garbage"  "not a url"                          1
check_garbage_rejected "traceback-line" "Traceback (most recent call last):" 2

echo
echo "13 — PRECEDENCE: the fallback gate wins over a live headroom proxy"
ENV13="$TMP/env13"
if [ -n "${PID1:-}" ]; then
  FBSTUB_URL="$FB_URL" FBSTUB_URL_RC=0 PATH="$FBSTUB_DIR:$TOOLDIR:$PATH" \
    FAKETOOL_ENV_FILE="$ENV13" HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
    HEIMDALL_HOME="$TMP/home13" HEADROOM_PORT="$PORT1" \
    "$ROUTE" faketool >"$TMP/out13" 2>"$TMP/err13"
  RC13=$?
  [ "$RC13" = "0" ] && ok "fallback beats a live headroom proxy: the tool still ran (exit 0)" \
    || bad "fallback+live-headroom launch failed (rc=$RC13): $(cat "$TMP/err13")"
  grep -q "^ANTHROPIC_BASE_URL=$FB_URL$" "$ENV13" 2>/dev/null \
    && ok "the child got the FALLBACK url ($FB_URL), not headroom's" \
    || bad "expected ANTHROPIC_BASE_URL=$FB_URL, got: $(grep '^ANTHROPIC_BASE_URL=' "$ENV13" 2>/dev/null || echo '<absent>')"
  if grep -q "^ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT1$" "$ENV13" 2>/dev/null; then
    bad "the child got headroom's URL even though the fallback gate said ROUTE"
  else
    ok "headroom's own URL (http://127.0.0.1:$PORT1) was NOT used"
  fi
else
  bad "guarantee 13 skipped — no live fixture proxy"
fi

echo
echo "14 — PRECEDENCE: the stderr disclosure names the fallback destination and says compression is OFF"
if [ -n "${PID1:-}" ]; then
  grep -q "$FB_URL" "$TMP/err13" 2>/dev/null \
    && ok "stderr names the fallback destination ($FB_URL)" \
    || bad "stderr never named the fallback destination: $(cat "$TMP/err13" 2>/dev/null)"
  grep -qi "compression is off" "$TMP/err13" 2>/dev/null \
    && ok "stderr says headroom compression is OFF for this session" \
    || bad "stderr did not disclose compression is off: $(cat "$TMP/err13" 2>/dev/null)"
else
  bad "guarantee 14 skipped — no live fixture proxy"
fi

echo
echo "15 — TOKEN: the fallback path passes the token file's own contents as ANTHROPIC_AUTH_TOKEN"
ENV15="$TMP/env15"
if [ -n "${PID1:-}" ]; then
  FBSTUB_URL="$FB_URL" FBSTUB_URL_RC=0 FBSTUB_TOKEN_FILE="$TOKFILE" FBSTUB_TOKEN_FILE_RC=0 \
    PATH="$FBSTUB_DIR:$TOOLDIR:$PATH" FAKETOOL_ENV_FILE="$ENV15" \
    HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
    HEIMDALL_HOME="$TMP/home15" HEADROOM_PORT="$PORT1" \
    "$ROUTE" faketool >"$TMP/out15" 2>"$TMP/err15"
  RC15=$?
  [ "$RC15" = "0" ] && ok "fallback+token launch succeeded (exit 0)" \
    || bad "fallback+token launch failed (rc=$RC15): $(cat "$TMP/err15")"
  grep -q "^ANTHROPIC_AUTH_TOKEN=$TOKEN_SENTINEL$" "$ENV15" 2>/dev/null \
    && ok "the child's ANTHROPIC_AUTH_TOKEN equals the token file's contents" \
    || bad "child ANTHROPIC_AUTH_TOKEN missing or wrong: $(grep '^ANTHROPIC_AUTH_TOKEN=' "$ENV15" 2>/dev/null || echo '<absent>')"
else
  bad "guarantee 15 skipped — no live fixture proxy"
fi

echo
echo "16 — TOKEN: the token value never appears in the route command's own stdout or stderr"
if [ -n "${PID1:-}" ]; then
  if grep -q "$TOKEN_SENTINEL" "$TMP/out15" 2>/dev/null; then
    bad "the token sentinel leaked onto stdout: $(cat "$TMP/out15")"
  else
    ok "the token sentinel never appears on stdout"
  fi
  if grep -q "$TOKEN_SENTINEL" "$TMP/err15" 2>/dev/null; then
    bad "the token sentinel leaked onto stderr: $(cat "$TMP/err15")"
  else
    ok "the token sentinel never appears on stderr"
  fi
else
  bad "guarantee 16 skipped — no live fixture proxy"
fi

echo
echo "17 — TOKEN: a NON-fallback launch drops a pre-set token that byte-matches the token file"
ENV17="$TMP/env17"
# HMD_MODULES_STATE is the EMPTY state here too, for the same reason as guarantee 12:
# PORT_UNUSED is a genuinely free port, and an "installed" module would let headroom's
# own chain fork a fresh proxy onto it and set ANTHROPIC_BASE_URL — noise this group has
# no interest in. What guarantee 17 asserts is ANTHROPIC_AUTH_TOKEN, unaffected either way.
FBSTUB_URL="" FBSTUB_URL_RC=1 FBSTUB_TOKEN_FILE="$TOKFILE" FBSTUB_TOKEN_FILE_RC=0 \
  ANTHROPIC_AUTH_TOKEN="$TOKEN_SENTINEL" \
  PATH="$FBSTUB_DIR:$TOOLDIR:$PATH" FAKETOOL_ENV_FILE="$ENV17" \
  HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$EMPTY_STATE" \
  HEIMDALL_HOME="$TMP/home17" HEADROOM_PORT="$PORT_UNUSED" \
  "$ROUTE" faketool >"$TMP/out17" 2>"$TMP/err17"
RC17=$?
[ "$RC17" = "0" ] && ok "non-fallback launch with a matching token still runs (exit 0)" \
  || bad "non-fallback launch failed (rc=$RC17): $(cat "$TMP/err17")"
if grep -q "^ANTHROPIC_AUTH_TOKEN=" "$ENV17" 2>/dev/null; then
  bad "the matching gateway token rode along to a non-fallback launch: $(grep '^ANTHROPIC_AUTH_TOKEN=' "$ENV17")"
else
  ok "the matching gateway token was dropped — the child has no ANTHROPIC_AUTH_TOKEN"
fi

echo
echo "18 — TOKEN: a NON-fallback launch passes through a pre-set token that does NOT match"
ENV18="$TMP/env18"
REAL_TOKEN="sk-ant-operator-real-token-ABCDEF"
# Same EMPTY_STATE reasoning as guarantees 12 and 17.
FBSTUB_URL="" FBSTUB_URL_RC=1 FBSTUB_TOKEN_FILE="$TOKFILE" FBSTUB_TOKEN_FILE_RC=0 \
  ANTHROPIC_AUTH_TOKEN="$REAL_TOKEN" \
  PATH="$FBSTUB_DIR:$TOOLDIR:$PATH" FAKETOOL_ENV_FILE="$ENV18" \
  HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$EMPTY_STATE" \
  HEIMDALL_HOME="$TMP/home18" HEADROOM_PORT="$PORT_UNUSED" \
  "$ROUTE" faketool >"$TMP/out18" 2>"$TMP/err18"
RC18=$?
[ "$RC18" = "0" ] && ok "non-fallback launch with an operator's own token still runs (exit 0)" \
  || bad "non-fallback launch failed (rc=$RC18): $(cat "$TMP/err18")"
grep -q "^ANTHROPIC_AUTH_TOKEN=$REAL_TOKEN$" "$ENV18" 2>/dev/null \
  && ok "the operator's own (non-matching) token passed through untouched" \
  || bad "the operator's own token was altered or dropped: $(grep '^ANTHROPIC_AUTH_TOKEN=' "$ENV18" 2>/dev/null || echo '<absent>')"

echo
echo "19 — --url prints the fallback URL, not headroom's, when the gate says ROUTE"
if [ -n "${PID1:-}" ]; then
  OUT19="$(FBSTUB_URL="$FB_URL" FBSTUB_URL_RC=0 PATH="$FBSTUB_DIR:$TOOLDIR:$PATH" \
           HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
           HEIMDALL_HOME="$TMP/home19" HEADROOM_PORT="$PORT1" "$ROUTE" --url 2>"$TMP/err19")"
  RC19=$?
  [ "$RC19" = "0" ] && [ "$OUT19" = "$FB_URL" ] \
    && ok "--url printed the fallback URL ($OUT19) and exited 0" \
    || bad "--url printed '$OUT19' (rc=$RC19), expected $FB_URL with rc=0"
else
  bad "guarantee 19 skipped — no live fixture proxy"
fi

echo
echo "20 — --status names the fallback route and its URL, when the gate says ROUTE"
if [ -n "${PID1:-}" ]; then
  ST20="$(FBSTUB_URL="$FB_URL" FBSTUB_URL_RC=0 PATH="$FBSTUB_DIR:$TOOLDIR:$PATH" \
          HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
          HEIMDALL_HOME="$TMP/home20" HEADROOM_PORT="$PORT1" "$ROUTE" --status 2>/dev/null)"
  case "$ST20" in
    *"ROUTED TO FALLBACK"*"$FB_URL"*) ok "--status reports: $ST20" ;;
    *) bad "--status did not name the fallback route: '$ST20'" ;;
  esac
else
  bad "guarantee 20 skipped — no live fixture proxy"
fi

echo
echo "21 — MODEL: the fallback path pins ANTHROPIC_MODEL when unset, never when set"
if [ -n "${PID1:-}" ]; then
  ENV21A="$TMP/env21a"
  ( unset ANTHROPIC_MODEL
    FBSTUB_URL="$FB_URL" FBSTUB_URL_RC=0 FBSTUB_MODEL="oc/test-model" FBSTUB_MODEL_RC=0 \
      PATH="$FBSTUB_DIR:$TOOLDIR:$PATH" FAKETOOL_ENV_FILE="$ENV21A" \
      HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
      HEIMDALL_HOME="$TMP/home21a" HEADROOM_PORT="$PORT1" \
      "$ROUTE" faketool >"$TMP/out21a" 2>"$TMP/err21a" )
  RC21A=$?
  [ "$RC21A" = "0" ] && ok "fallback+unset-model launch succeeded (exit 0)" \
    || bad "fallback+unset-model launch failed (rc=$RC21A): $(cat "$TMP/err21a")"
  grep -q '^ANTHROPIC_MODEL=oc/test-model$' "$ENV21A" 2>/dev/null \
    && ok "an unset ANTHROPIC_MODEL is pinned from heimdall-fallback model" \
    || bad "ANTHROPIC_MODEL was not pinned: $(grep '^ANTHROPIC_MODEL=' "$ENV21A" 2>/dev/null || echo '<absent>')"

  ENV21B="$TMP/env21b"
  PRESET_MODEL="claude-operator-pinned-model"
  ANTHROPIC_MODEL="$PRESET_MODEL" \
    FBSTUB_URL="$FB_URL" FBSTUB_URL_RC=0 FBSTUB_MODEL="oc/test-model" FBSTUB_MODEL_RC=0 \
    PATH="$FBSTUB_DIR:$TOOLDIR:$PATH" FAKETOOL_ENV_FILE="$ENV21B" \
    HMD_HEADROOM_BIN="$FAKE_BIN" HMD_MODULES_STATE="$MODSTATE" \
    HEIMDALL_HOME="$TMP/home21b" HEADROOM_PORT="$PORT1" \
    "$ROUTE" faketool >"$TMP/out21b" 2>"$TMP/err21b"
  RC21B=$?
  [ "$RC21B" = "0" ] && ok "fallback+preset-model launch succeeded (exit 0)" \
    || bad "fallback+preset-model launch failed (rc=$RC21B): $(cat "$TMP/err21b")"
  grep -q "^ANTHROPIC_MODEL=$PRESET_MODEL$" "$ENV21B" 2>/dev/null \
    && ok "an operator-set ANTHROPIC_MODEL was NOT overridden by heimdall-fallback model" \
    || bad "the operator's ANTHROPIC_MODEL was overridden: $(grep '^ANTHROPIC_MODEL=' "$ENV21B" 2>/dev/null || echo '<absent>')"
else
  bad "guarantee 21 skipped — no live fixture proxy"
fi

echo
echo "--------------------------------------------------------------------"
printf 'heimdall-route: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
