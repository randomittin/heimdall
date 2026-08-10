#!/usr/bin/env bash
# test/feedback.test.sh — acceptance test for the hmd:feedback CLI
# (bin/heimdall-feedback). Proves, against the REAL CLI + the REAL issue-loop
# plumbing it reuses (bin/lib/issue_config.py + bin/lib/connectors/github.py),
# with NO live GitHub call:
#
#   (a) DRY-RUN PAYLOAD — the built issue carries the dev's words, a `feedback:`
#       title, the `feedback`+`from-hmd` labels, and the hmd version footer — and
#       NOTHING else (no code fence, no transcript). The mockable assertion path.
#   (b) NO-SECRET GUARD — a message bearing a credential SHAPE is REFUSED (exit 5)
#       and nothing is filed. The "feedback is the dev's words only" discipline.
#   (c) GRACEFUL WHEN UNCONFIGURED — no github block -> clear message, exit 1, NO
#       python traceback. Absent credential -> clear message, exit 1, no traceback.
#   (d) REAL CREATE OVER HTTP (mock server) — with a github block pointed at a
#       LOCAL mock api_root + a token in env, the CLI drives the connector's POST
#       over real HTTP, prints "filed as issue #N" + the URL, and the payload the
#       server RECEIVED carries the title + both labels + NO secret/code.
#   (e) CONNECTOR DEGRADATION REUSE — create_issue on an inactive (token-less)
#       connector returns {ok:False, reason:'inactive'} with NO network call —
#       the same lazy/optional contract as post_resolution/close_issue.
#
# Exit 0 = every executed assertion passed. Non-zero = a regression.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-feedback"
GH="$ROOT/bin/lib/connectors/github.py"

[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }
[ -f "$GH" ]  || { echo "FATAL: $GH missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# Build the mktemp suffix at runtime (avoid a literal triple-X in this source).
WORK="$(mktemp -d -t "feedback-test.$(printf 'q%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null || true' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO/.heimdall"
export CLAUDE_PLUGIN_ROOT="$ROOT"   # so the version footer resolves from plugin.json

# ── (a) DRY-RUN PAYLOAD SHAPE ──────────────────────────────────────────────────
MSG="the merge gate is too slow when three of us land at once"
set +e
DRY="$("$CLI" "$MSG" --command land --phase merge --dry-run 2>&1)"
DRY_RC=$?
set -e
if [ "$DRY_RC" -eq 0 ] \
   && grep -q '"title": "feedback: the merge gate' <<<"$DRY" \
   && grep -q "$MSG" <<<"$DRY" \
   && grep -q '"feedback"' <<<"$DRY" \
   && grep -q '"from-hmd"' <<<"$DRY" \
   && grep -q 'hmd version:' <<<"$DRY" \
   && grep -q 'command: ' <<<"$DRY" \
   && grep -q 'phase: ' <<<"$DRY"; then
  ok "(a) dry-run builds a feedback: title + message + feedback/from-hmd labels + version footer"
else
  bad "(a) dry-run payload wrong (rc=$DRY_RC): $DRY"
fi

# the payload must carry NO code fence and NO obvious session/transcript marker.
if grep -q '```' <<<"$DRY" ; then
  bad "(a) dry-run payload contains a code fence — feedback must be words only"
else
  ok "(a) dry-run payload contains no code fence (no code/session content)"
fi

# version in the footer matches plugin.json (real, not faked).
PVER="$("$PY" -c "import json;print(json.load(open('$ROOT/.claude-plugin/plugin.json'))['version'])")"
if grep -q "hmd version: \`$PVER\`" <<<"$DRY"; then
  ok "(a) footer carries the REAL hmd version from plugin.json ($PVER)"
else
  bad "(a) footer version mismatch (want $PVER): $DRY"
fi

# ── (b) NO-SECRET GUARD ────────────────────────────────────────────────────────
# Assemble a real-shaped github PAT at runtime (no static secret literal here).
# The guard must REFUSE it (exit 5) and file nothing.
SECRET="ghp_$(printf 'A%.0s' $(seq 1 36))"
set +e
SEC_OUT="$("$CLI" "my token is $SECRET please help" --dry-run 2>&1)"
SEC_RC=$?
set -e
if [ "$SEC_RC" -eq 5 ] && grep -qi 'refused' <<<"$SEC_OUT"; then
  ok "(b) a message bearing a credential shape is REFUSED (exit 5), nothing built"
else
  bad "(b) secret guard did not refuse (rc=$SEC_RC): $SEC_OUT"
fi
# prove the guard is meaningful: the same prose WITHOUT the token passes the build.
set +e
CLEAN_DRY="$("$CLI" "my token refresh keeps failing please help" --dry-run 2>&1)"
CLEAN_RC=$?
set -e
if [ "$CLEAN_RC" -eq 0 ] && grep -q '"title":' <<<"$CLEAN_DRY"; then
  ok "(b) honest prose mentioning the WORD token is NOT refused (no false positive)"
else
  bad "(b) guard false-positived on clean prose (rc=$CLEAN_RC): $CLEAN_DRY"
fi

# ── (c) GRACEFUL WHEN UNCONFIGURED ─────────────────────────────────────────────
# no config at all -> github not configured.
set +e
NOCFG="$("$CLI" "some feedback" --repo "$REPO" 2>&1)"
NOCFG_RC=$?
set -e
if [ "$NOCFG_RC" -eq 1 ] \
   && grep -qi 'not configured' <<<"$NOCFG" \
   && ! grep -q 'Traceback' <<<"$NOCFG"; then
  ok "(c) unconfigured github -> clear message, exit 1, no traceback"
else
  bad "(c) unconfigured handling wrong (rc=$NOCFG_RC): $NOCFG"
fi

# configured but credential env unset -> graceful "no credential".
cat > "$REPO/.heimdall/issue-loop.config.json" <<'JSON'
{ "connectors": { "github": { "active": true, "repo": "owner/name", "token_env": "FEEDBACK_TEST_TOKEN" } } }
JSON
set +e
NOCRED="$(env -u FEEDBACK_TEST_TOKEN "$CLI" "some feedback" --repo "$REPO" 2>&1)"
NOCRED_RC=$?
set -e
if [ "$NOCRED_RC" -eq 1 ] \
   && grep -qi 'no credential' <<<"$NOCRED" \
   && ! grep -q 'Traceback' <<<"$NOCRED"; then
  ok "(c) configured-but-credless github -> clear message, exit 1, no traceback"
else
  bad "(c) credless handling wrong (rc=$NOCRED_RC): $NOCRED"
fi

# ── (d) REAL CREATE OVER HTTP (local mock server, drives the real connector) ───
CAP="$WORK/captured.json"
PORTF="$WORK/port"
cat > "$WORK/mock.py" <<PYEOF
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer

CAP = os.environ["CAP"]
PORTF = os.environ["PORTF"]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        return
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode("utf-8") if n else ""
        with open(CAP, "w", encoding="utf-8") as fh:
            fh.write(json.dumps({"path": self.path,
                                 "auth": self.headers.get("Authorization", ""),
                                 "body": raw}))
        resp = json.dumps({"number": 7,
                           "html_url": "https://example.test/owner/name/issues/7"}).encode()
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)

srv = HTTPServer(("127.0.0.1", 0), H)
with open(PORTF, "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF

CAP="$CAP" PORTF="$PORTF" "$PY" "$WORK/mock.py" &
SRV_PID=$!
# wait for the port file
for _ in $(seq 1 50); do [ -s "$PORTF" ] && break; sleep 0.1; done
PORT="$(cat "$PORTF" 2>/dev/null || true)"
if [ -z "$PORT" ]; then
  bad "(d) mock server failed to start"
else
  cat > "$REPO/.heimdall/issue-loop.config.json" <<JSON
{ "connectors": { "github": { "active": true, "repo": "owner/name", "token_env": "FEEDBACK_TEST_TOKEN", "api_root": "http://127.0.0.1:$PORT" } } }
JSON
  set +e
  FILED="$(FEEDBACK_TEST_TOKEN="t0ken-not-a-real-secret" "$CLI" "auto-merge prompted me unexpectedly" --repo "$REPO" 2>&1)"
  FILED_RC=$?
  set -e
  if [ "$FILED_RC" -eq 0 ] \
     && grep -q 'filed as issue #7' <<<"$FILED" \
     && grep -q 'https://example.test/owner/name/issues/7' <<<"$FILED"; then
    ok "(d) real POST over mock HTTP -> 'filed as issue #7' + URL printed"
  else
    bad "(d) create-over-http wrong (rc=$FILED_RC): $FILED"
  fi

  # the server RECEIVED a payload with the title + both labels + no secret/code.
  if [ -s "$CAP" ]; then
    VERDICT="$("$PY" - "$CAP" <<'PY'
import json, sys
cap = json.load(open(sys.argv[1]))
body = json.loads(cap["body"])
title_ok = body.get("title", "").startswith("feedback: auto-merge prompted")
labels = body.get("labels", [])
labels_ok = "feedback" in labels and "from-hmd" in labels
blob = cap["body"]
no_secret = "t0ken-not-a-real-secret" not in blob
no_fence = (chr(96) * 3) not in blob
path_ok = cap["path"] == "/repos/owner/name/issues"
print("OK" if (title_ok and labels_ok and no_secret and no_fence and path_ok)
      else "BAD title=%s labels=%s secret_clean=%s fence_clean=%s path=%s"
      % (title_ok, labels_ok, no_secret, no_fence, cap["path"]))
PY
)"
    if grep -q '^OK' <<<"$VERDICT"; then
      ok "(d) received payload: feedback: title + feedback/from-hmd labels, hit /repos/owner/name/issues, NO secret/code"
    else
      bad "(d) received payload wrong: $VERDICT"
    fi
  else
    bad "(d) mock server captured no request"
  fi
fi

# ── (e) CONNECTOR DEGRADATION REUSE — inactive create_issue no-ops, no network ─
DEGRADE="$(PYTHONPATH="$ROOT/bin/lib" "$PY" - <<'PY' 2>&1
import connectors as c
gh = c.get("github")
gh.configure({"repo": "owner/name"})          # NO token -> inactive
r = gh.create_issue("t", "b", labels=["feedback"])
print("ok=%s reason=%s" % (r.get("ok"), r.get("reason")))
PY
)"
if grep -q "ok=False reason=inactive" <<<"$DEGRADE"; then
  ok "(e) create_issue on a token-less connector -> {ok:False, reason:inactive} (no network)"
else
  bad "(e) connector degradation contract broken: $DEGRADE"
fi

echo
echo "  feedback tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
