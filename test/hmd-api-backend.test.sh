#!/usr/bin/env bash
# hmd-api-backend.test.sh — falsifiable coverage for bin/lib/hmd_api_backend.py's HTTP
# and retry behavior: the `api` backend for bin/hmd-exec's wave-2 seam. The two
# structural refusal paths (--allowedTools present, no gate ROUTE verdict) already
# have dedicated coverage in test/hmd-exec.test.sh's Case F and are NOT repeated here.
#
# HERMETIC: every case runs against a LOCAL, throwaway HTTP fixture server this file
# starts and stops itself (127.0.0.1, an OS-assigned ephemeral port). It never
# contacts the real OmniRoute endpoint (127.0.0.1:20128) or any network host. The
# .heimdall/fallback.json each case writes is a REAL on-disk config pointed at that
# fixture, and the sqlite DB each case points omniroute_db_path at is a REAL sqlite
# file with an empty (no Tier-1) provider_connections table -- bin/heimdall-fallback's
# OWN preflight genuinely runs and genuinely ROUTEs. Nothing about the gate itself is
# mocked; only the far end of the HTTP call is.
#
# This suite is the entire acceptance-evidence basis for the api backend's HTTP/retry
# behavior, and deliberately so: measured directly against the live OmniRoute gateway
# on 2026-08-26, every keyless provider (duckduckgo-web, felo-web, veoaifree-web)
# rejects real agent-shaped requests -- a bare "system" field alone (not tools, not
# size) causes a 400/malformed response on all three, and `claude -p` itself fails
# identically against the same gateway. A live keyless run can therefore prove, at
# most, that a toy completion works -- never that HTTP-error handling, malformed-body
# handling, or the retry/backoff loop behave correctly. So none of that is asked of a
# live provider here; the fixture is the only sound basis for it.
#
# It is genuinely falsifiable — it FAILS if the api backend:
#   H1: does NOT complete a real gate-ROUTE + real HTTP-200 round trip end to end;
#   H2: reports an HTTP error response as success (required falsifier: "an HTTP error
#       is not reported as success");
#   H3: reports a malformed/non-JSON response body as success (required falsifier: "a
#       malformed response body is not reported as success");
#   H4: fakes success, or fails silently, when overload never clears -- must give up
#       loudly at the configured attempt cap (this closes the one coverage gap
#       test/hmd-exec.test.sh cannot reach: THIS backend's own Python retry loop, as
#       opposed to the claude-code backend's separate bin/lib/hmd-claude-retry.sh);
#   H5: surfaces overload/error text as if it were the real answer once the fixture
#       recovers, or does not retry the correct number of times.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/bin/hmd-exec"
FALLBACK="$ROOT/bin/heimdall-fallback"

WORK="$(mktemp -d)"
FIXTURE_PID=""
trap '[ -n "$FIXTURE_PID" ] && kill "$FIXTURE_PID" 2>/dev/null; wait "$FIXTURE_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [expr: $2]"; fi; }
fcount() { local n; n=$(cat "$FIXTURE_COUNTER" 2>/dev/null); echo "${n:-0}"; }

# fast, hermetic retry env (mirrors test/hmd-exec.test.sh / test/heimdall-overload-heal.test.sh)
export HMD_OVERLOAD_BASE_SECS=0
export HMD_OVERLOAD_CAP_SECS=0
export ANTHROPIC_MODEL="opencode/fixture-model"
unset OMNIROUTE_PREFER_CLAUDE_CODE_FOR_UNPREFIXED_CLAUDE_MODELS

# ── local fixture HTTP server ("Anthropic-shaped" /v1/messages, canned by mode) ──
FIXTURE_SRV="$WORK/fixture_server.py"
cat > "$FIXTURE_SRV" <<'PYEOF'
#!/usr/bin/env python3
"""Hermetic stand-in for an Anthropic-shaped /v1/messages endpoint. Binds an
ephemeral localhost port, prints it on stdout for the caller to read, then serves
canned responses per FIXTURE_MODE. Never talks to anything real."""
import http.server
import json
import os
import sys

MODE = os.environ.get("FIXTURE_MODE", "success")
FAIL_TIMES = int(os.environ.get("FIXTURE_FAIL_TIMES", "0") or "0")
COUNTER_PATH = os.environ.get("FIXTURE_COUNTER", "")


def _bump_counter():
    n = 0
    if COUNTER_PATH and os.path.exists(COUNTER_PATH):
        with open(COUNTER_PATH, "r", encoding="utf-8") as fh:
            text = fh.read().strip()
        n = int(text) if text else 0
    n += 1
    if COUNTER_PATH:
        with open(COUNTER_PATH, "w", encoding="utf-8") as fh:
            fh.write(str(n))
    return n


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return  # keep stderr clean; not a test assertion signal

    def _send(self, status, payload_bytes, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload_bytes)))
        self.end_headers()
        self.wfile.write(payload_bytes)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        self.rfile.read(length)
        n = _bump_counter()
        mode = MODE
        if mode == "recover_after" and n > FAIL_TIMES:
            mode = "success"
        if mode == "success":
            body = json.dumps({
                "type": "message",
                "role": "assistant",
                "content": [{"type": "text", "text": "FIXTURE-OK-ANSWER"}],
                "stop_reason": "end_turn",
            }).encode("utf-8")
            self._send(200, body)
        elif mode in ("recover_after", "always_overload"):
            body = json.dumps({
                "type": "error",
                "error": {"type": "overloaded_error", "message": "fixture: 529 Overloaded"},
            }).encode("utf-8")
            self._send(529, body)
        elif mode == "http_error":
            body = json.dumps({
                "type": "error",
                "error": {"type": "invalid_request_error", "message": "fixture: deliberate 400"},
            }).encode("utf-8")
            self._send(400, body)
        elif mode == "malformed":
            self._send(200, b"not-json-at-all {{{", content_type="text/plain")
        else:
            self._send(500, b"{}")


def main():
    port = int(sys.argv[1])
    server = http.server.HTTPServer(("127.0.0.1", port), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
PYEOF

start_fixture() {
  # args: mode [fail_times]
  local mode="$1" fail_times="${2:-0}"
  FIXTURE_PORT_FILE="$WORK/fixture-port"
  FIXTURE_COUNTER="$WORK/fixture-counter"
  : > "$FIXTURE_PORT_FILE"
  : > "$FIXTURE_COUNTER"
  FIXTURE_MODE="$mode" FIXTURE_FAIL_TIMES="$fail_times" FIXTURE_COUNTER="$FIXTURE_COUNTER" \
    python3 "$FIXTURE_SRV" 0 >"$FIXTURE_PORT_FILE" 2>"$WORK/fixture-server.log" &
  FIXTURE_PID=$!
  local tries=0
  FIXTURE_PORT=""
  while [ "$tries" -lt 100 ]; do
    FIXTURE_PORT="$(cat "$FIXTURE_PORT_FILE" 2>/dev/null)"
    [ -n "$FIXTURE_PORT" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  if [ -z "$FIXTURE_PORT" ]; then
    echo "FATAL: fixture server never printed a port (mode=$mode)" >&2
    cat "$WORK/fixture-server.log" >&2
    exit 90
  fi
}

stop_fixture() {
  if [ -n "$FIXTURE_PID" ]; then
    kill "$FIXTURE_PID" 2>/dev/null
    wait "$FIXTURE_PID" 2>/dev/null
  fi
  FIXTURE_PID=""
}

make_omniroute_db() {
  # A real sqlite DB with a provider_connections table and no Tier-1 (claude/
  # claude-web) rows -- satisfies heimdall-fallback's tier1_credential_absent check
  # honestly, by construction, rather than by mocking the check itself.
  local dbfile="$1"
  python3 - "$dbfile" <<'PYEOF'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
conn.execute("CREATE TABLE provider_connections (id INTEGER PRIMARY KEY, provider TEXT)")
conn.execute("INSERT INTO provider_connections (provider) VALUES ('opencode')")
conn.commit()
conn.close()
PYEOF
}

write_gate_config() {
  # args: repo_dir endpoint db_path
  # A real .heimdall/fallback.json -- bin/heimdall-fallback's own preflight runs for
  # real against this; nothing about the gate itself is stubbed. target_provider
  # "opencode" is a genuine no-auth provider, so operator_key_env can stay empty.
  local repo="$1" endpoint="$2" db="$3"
  mkdir -p "$repo/.heimdall"
  cat > "$repo/.heimdall/fallback.json" <<CFGEOF
{
  "schema": 1,
  "state": "switch",
  "operator_key_env": "",
  "endpoint": "$endpoint",
  "omniroute_db_path": "$db",
  "cliproxyapi_dir": "$WORK/no-such-cliproxyapi-dir",
  "target_provider": "opencode",
  "tos_flagged_providers": [],
  "noauth_providers": []
}
CFGEOF
}

DB="$WORK/omniroute.sqlite"
make_omniroute_db "$DB"

# ── Case H1: real gate ROUTE + real HTTP success, end to end ───────────────────
echo "Case H1 — real gate ROUTE + real HTTP success, end to end:"
REPO_H1="$WORK/repo-h1"; mkdir -p "$REPO_H1"
start_fixture success
write_gate_config "$REPO_H1" "http://127.0.0.1:$FIXTURE_PORT" "$DB"
check "H1 the gate genuinely ROUTEs (sanity: real preflight passes)" \
  "'$FALLBACK' --repo '$REPO_H1' check"
rcH1=0
outH1="$(HMD_API_BACKEND_REPO="$REPO_H1" "$EXEC" --backend api run -p "hello fixture" 2>"$WORK/h1.err")" || rcH1=$?
check "H1 end-to-end exit 0 (real ROUTE + real HTTP success)" "[ '$rcH1' -eq 0 ]"
check "H1 stdout carries the fixture's real answer"           "printf '%s' \"\$outH1\" | grep -q 'FIXTURE-OK-ANSWER'"
stop_fixture

# ── Case H2: HTTP error is never reported as success (required falsifier) ──────
echo "Case H2 — HTTP error is never reported as success:"
REPO_H2="$WORK/repo-h2"; mkdir -p "$REPO_H2"
start_fixture http_error
write_gate_config "$REPO_H2" "http://127.0.0.1:$FIXTURE_PORT" "$DB"
rcH2=0
outH2="$(HMD_API_BACKEND_REPO="$REPO_H2" "$EXEC" --backend api run -p "x" 2>"$WORK/h2.err")" || rcH2=$?
check "H2 HTTP error -> the real-error exit (1), never 0"     "[ '$rcH2' -eq 1 ]"
check "H2 produced NO stdout (HTTP error is not success)"     "[ -z \"\$outH2\" ]"
check "H2 surfaced the real HTTP error on stderr"             "grep -qi 'deliberate 400' '$WORK/h2.err'"
stop_fixture

# ── Case H3: malformed response body is never reported as success (required falsifier) ──
echo "Case H3 — malformed response body is never reported as success:"
REPO_H3="$WORK/repo-h3"; mkdir -p "$REPO_H3"
start_fixture malformed
write_gate_config "$REPO_H3" "http://127.0.0.1:$FIXTURE_PORT" "$DB"
rcH3=0
outH3="$(HMD_API_BACKEND_REPO="$REPO_H3" "$EXEC" --backend api run -p "x" 2>"$WORK/h3.err")" || rcH3=$?
check "H3 malformed body -> the real-error exit (1), never 0" "[ '$rcH3' -eq 1 ]"
check "H3 produced NO stdout (malformed body is not success)" "[ -z \"\$outH3\" ]"
check "H3 names it malformed on stderr"                       "grep -qi 'malformed' '$WORK/h3.err'"
stop_fixture

# ── Case H4: overload that never clears -> loud give-up, never a fake success ───
echo "Case H4 — overload that never clears: loud give-up, never a fake success:"
REPO_H4="$WORK/repo-h4"; mkdir -p "$REPO_H4"
start_fixture always_overload
write_gate_config "$REPO_H4" "http://127.0.0.1:$FIXTURE_PORT" "$DB"
rcH4=0
outH4="$(HMD_API_BACKEND_REPO="$REPO_H4" HEIMDALL_HOME="$WORK/hmdhome-h4" HMD_OVERLOAD_MAX_ATTEMPTS=3 \
  "$EXEC" --backend api run -p "x" 2>"$WORK/h4.err")" || rcH4=$?
check "H4 overload never clears -> the give-up exit (75)"     "[ '$rcH4' -eq 75 ]"
check "H4 produced NO stdout (no fake success)"               "[ -z \"\$outH4\" ]"
check "H4 retried exactly max=3 times"                        "[ '$(fcount)' -eq 3 ]"
check "H4 logged a give-up diagnostic"                        "grep -qi 'gave up after 3 attempts' '$WORK/h4.err'"
stop_fixture

# ── Case H5: overload that clears -> recovers, never surfaces overload text ─────
echo "Case H5 — overload that clears: recovers, never surfaces overload text as the answer:"
REPO_H5="$WORK/repo-h5"; mkdir -p "$REPO_H5"
start_fixture recover_after 2
write_gate_config "$REPO_H5" "http://127.0.0.1:$FIXTURE_PORT" "$DB"
rcH5=0
outH5="$(HMD_API_BACKEND_REPO="$REPO_H5" HEIMDALL_HOME="$WORK/hmdhome-h5" HMD_OVERLOAD_MAX_ATTEMPTS=6 \
  "$EXEC" --backend api run -p "x" 2>"$WORK/h5.err")" || rcH5=$?
check "H5 recovers -> exit 0"                                 "[ '$rcH5' -eq 0 ]"
check "H5 stdout is the real recovered answer"                "printf '%s' \"\$outH5\" | grep -q 'FIXTURE-OK-ANSWER'"
check "H5 did NOT return overload text as the answer"         "! printf '%s' \"\$outH5\" | grep -qiE '529|overloaded'"
check "H5 retried exactly 3 times (2 fail + 1 ok)"            "[ '$(fcount)' -eq 3 ]"
stop_fixture

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
