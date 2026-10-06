# shellcheck shell=bash
# hermetic-cp.sh — a loopback stand-in for the control plane that module `add` probes.
#
# WHY THIS EXISTS. Both real traffic-proxy manifests (modules/headroom and
# modules/omniroute) carry a `no-signed-traffic-routing` invariant that curls
# $HEIMDALL_DEFAULT_CP_URL/readyz and FAILS CLOSED on anything but 200
# ("NON_VERIFIED control-plane unreachable ... an unreachable check fails, never
# passes"). Left at its baked-in default (bin/lib/cp-consent.sh) that URL is the
# LIVE production control plane, so any suite that drives a REAL manifest through
# `add` is, without this, a statement about the internet: green only while
# production answers, and deterministically red when it does not — or when the
# ambient env pins the default at a dead port, which test/lib/net-default-guard.sh
# does on purpose for the presence corpus.
#
# WHAT IS NOT CHANGED: the manifests and the engine. Failing closed on an
# unreachable control plane is the product behaviour that invariant exists for
# (proved for headroom in test/cp-signed-no-rewriting-proxy.test.sh 4.6). A suite
# that adopts this helper proves that behaviour still holds for ITS OWN add path
# with a fail-closed arm built on hermetic_cp_dead_url, so supplying a reachable
# control plane is never mistaken for a weakening: the suite stopped reaching the
# REAL control plane, not stopped caring whether the control plane is reachable.
#
# HOW TO USE. Source it once the suite has a scratch dir, then start it:
#
#   . "$SELF_DIR/lib/hermetic-cp.sh"
#   hermetic_cp_start "$TMP" || exit 2
#   hermetic_cp_selfcheck            # optional; needs the suite's ok() and bad()
#
# hermetic_cp_start
#   * serves GET /readyz -> 200 and every other path -> 404 from a real HTTP
#     server on an ephemeral 127.0.0.1 port (the 404 is what lets the self-check
#     prove the probe is reading /readyz specifically and not a wall of 200s);
#   * ASSIGNS HEIMDALL_DEFAULT_CP_URL — never `:-` — so an ambient pin, dead or
#     live, can never leak in. This is the documented override in
#     bin/lib/cp-consent.sh ("Env-overridable so hermetic tests can point the
#     baked-in default at a localhost server");
#   * drops ambient proxy routing and Headroom's HEADROOM_* namespace, the reason
#     test/cp-signed-no-rewriting-proxy.test.sh drops them: the invariant's clean
#     probe goes through whatever the environment routes, so a proxy exported by a
#     wrapper chain would turn a reachable stand-in into a NON_VERIFIED, and a
#     NO_PROXY covering loopback would defeat its un-scrubbed positive control;
#   * leaves nothing running. The server polls its parent pid and exits when the
#     shell that started it is gone, so no EXIT trap has to be composed with the
#     suite's own, and a suite killed by SIGKILL or by run-all.sh's timeout (which
#     skips traps) leaks no listener. Call it directly, not inside $( ... ), or
#     the "parent" is a subshell that exits at once.

HERMETIC_CP_PORT=""

hermetic_cp_start() { # <existing scratch dir>
  local dir="${1:-}" py
  [ -d "$dir" ] || { echo "error: hermetic_cp_start needs an existing scratch dir" >&2; return 2; }
  py="$(command -v python3 || true)"
  [ -n "$py" ] || { echo "error: python3 is required for the local stand-in control plane" >&2; return 2; }
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy
  unset HEADROOM_BASE_URL HEADROOM_PROXY HEADROOM_PROXY_URL
  cat > "$dir/stub-cp.py" <<'PYEOF'
import http.server, os, sys, threading, time


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ready = self.path.split("?", 1)[0] == "/readyz"
        body = b'{"ok":true}' if ready else b'{"ok":false}'
        self.send_response(200 if ready else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        return


def exit_with_parent(parent):
    while os.getppid() == parent:
        time.sleep(0.5)
    os._exit(0)


httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=exit_with_parent, args=(os.getppid(),), daemon=True).start()
with open(sys.argv[1], "w") as fh:
    fh.write(str(httpd.server_address[1]))
httpd.serve_forever()
PYEOF
  "$py" "$dir/stub-cp.py" "$dir/stub-cp.port" >/dev/null 2>&1 &
  # Detach from job control so the server's end never prints a "Terminated: 15"
  # notice into the suite output (pristine output is part of the pass criteria).
  disown "$!" 2>/dev/null || true
  HERMETIC_CP_PORT=""
  for _ in $(seq 1 60); do
    [ -s "$dir/stub-cp.port" ] && { HERMETIC_CP_PORT="$(cat "$dir/stub-cp.port")"; break; }
    sleep 0.1
  done
  [ -n "$HERMETIC_CP_PORT" ] || { echo "error: the local stand-in control plane failed to start" >&2; return 2; }
  export HEIMDALL_DEFAULT_CP_URL="http://127.0.0.1:$HERMETIC_CP_PORT"
}

# The stand-in must be a real probe target before any add result is read as a
# statement about the add path. Uses the calling suite's ok() / bad().
hermetic_cp_selfcheck() {
  echo
  echo "CP — the stand-in control plane the add path probes (hermetic: loopback only)"
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$HEIMDALL_DEFAULT_CP_URL/readyz" 2>/dev/null)" = "200" ] \
    && ok "the stand-in answers 200 on /readyz — the probe the invariants make can succeed offline" \
    || bad "the stand-in did not answer 200 on /readyz — every add below would fail closed for the wrong reason"
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$HEIMDALL_DEFAULT_CP_URL/not-readyz" 2>/dev/null)" = "404" ] \
    && ok "…and is not a wall of 200s: any other path answers 404, so the probe is reading /readyz specifically" \
    || bad "the stand-in answers 200 on a path that is not /readyz — it cannot distinguish a real probe"
}

# A loopback URL whose port nothing listens on, for a FAIL-CLOSED arm: run the
# SAME add with `env HEIMDALL_DEFAULT_CP_URL="$(hermetic_cp_dead_url)" ...` and
# demand it is refused and unwound. The port is bound and released, so it was free
# a moment ago; only an unrelated process grabbing it in between could answer.
hermetic_cp_dead_url() {
  local port
  port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')" || return 2
  printf 'http://127.0.0.1:%s' "$port"
}
