#!/usr/bin/env bash
# test/heimdall-connect.test.sh — acceptance for `hmd connect` (bin/heimdall-connect),
# Part 2 of the zero-config team UX: the lazy, idempotent, secret-safe capture that
# registers a team's Claude credential via the SIGNED write-only POST /team/cred.
#
# HERMETIC: $HOME is a throwaway dir; the identity is supplied via $HMD_HAID (no
# identity CLI / real key consulted); a per-test signing seed is minted in-memory with
# the SHIPPED cp_auth keygen and written to the 0600 seed path the client expects; the
# CP URL is pinned either to a LOCAL fake /team/cred capture-server (happy paths) or to
# an unreachable loopback port (offline-degrade paths). The Claude token is a SYNTHETIC
# sk-ant-oat… shape — never a real secret.
#
# FALSIFIABLE claims proven:
#   (1) LAZY STATUS  — a pre-registered marker → bare `hmd connect` is a NO-OP status
#                      ("already connected"), NO prompt; `--status` shows the KIND, never a value.
#   (2) ENV AUTODETECT — $CLAUDE_CODE_OAUTH_TOKEN set → captured + forwarded to /team/cred
#                      with NO prompt; a value-free marker is written.
#   (3) INBOX HAPPY  — `--inbox` arms a 0600 file; a token written to it is validated,
#                      forwarded (the fake server captures the SIGNED request), and the
#                      inbox file is SHREDDED (asserted GONE afterwards).
#   (4) NO ECHO      — the prompt uses `read -rs` (hidden); the inbox CONTENT is never printed.
#   (5) NOT IN ARGV  — the secret crosses to python via the CP_CRED_SECRET ENV, never argv.
#   (6) TIMEOUT SAFE — `--inbox` with no paste → nonzero exit, a "shredded" message, inbox GONE.
#   (7) SIGINT SAFE  — SIGINT during the watch → the trap shreds + removes the inbox (no residue).
#   (8) NO CLIPBOARD — pbpaste/xclip/wl-paste and any clipboard poll are ABSENT from the source.
#   (9) HELP         — `hmd connect --help` (the bin) resolves and exits 0.
#
# Fakes in the TEST are fine; production (bin/heimdall-connect) has no fakes.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONNECT="$ROOT/bin/heimdall-connect"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

PY="$(command -v python3 || command -v python)"
[ -x "$CONNECT" ] || { echo "FATAL: $CONNECT missing/not executable" >&2; exit 1; }
[ -n "$PY" ] || { echo "FATAL: python3 required" >&2; exit 1; }

WORK="$(mktemp -d -t heimdall-connect-test.XXXXXX)"
trap 'rm -rf "$WORK"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null || true' EXIT

export HOME="$WORK/home"
mkdir -p "$HOME/.heimdall/pki"
export HMD_HAID="connect-test-haid"                 # supply identity → no CLI / real key.
SEED_FILE="$HOME/.heimdall/pki/connect-test-haid.seed"   # slug: no / or : to map.
unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY 2>/dev/null || true

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# a SYNTHETIC, shape-valid oauth token (sk-ant-oat<NN>-<body>, body 20..180 of [A-Za-z0-9_-]).
TOKEN="sk-ant-oat01-$("$PY" -c 'import secrets,string; a=string.ascii_letters+string.digits+"_-"; print("".join(secrets.choice(a) for _ in range(90)))')"

# ── mint a per-test signing seed with the SHIPPED cp_auth keygen (0600) ────────
LIB="$ROOT/bin/lib" DEST="$SEED_FILE" "$PY" - <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth
priv, _pub = cp_auth.generate_keypair()
with open(os.environ["DEST"], "w") as f:
    f.write(priv)
os.chmod(os.environ["DEST"], 0o600)
PYEOF
[ -s "$SEED_FILE" ] && ok "0.0 minted a 0600 signing seed for the test identity" || bad "0.0 seed not minted"

# ── a LOCAL fake /team/cred + /team/install capture-server ─────────────────────
CAP_DIR="$WORK/cap"; mkdir -p "$CAP_DIR"
SRV_PORT="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
CAP_DIR="$CAP_DIR" SRV_PORT="$SRV_PORT" "$PY" - >"$WORK/srv.out" 2>&1 <<'PYEOF' &
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer
CAP = os.environ["CAP_DIR"]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n)
        name = self.path.strip("/").replace("/", "_") or "root"
        with open(os.path.join(CAP, name + ".body"), "wb") as f:
            f.write(raw)
        # record the signing headers too (proves the request was SIGNED).
        with open(os.path.join(CAP, name + ".hdr"), "w") as f:
            f.write("HAID=%s\nSIG=%s\n" % (self.headers.get("X-Heimdall-HAID") or "",
                                           self.headers.get("X-Heimdall-Signature") or ""))
        try:
            b = json.loads(raw)
        except Exception:
            b = {}
        out = {"team_id": "team-server-derived"}
        if self.path == "/team/cred":
            out["kind"] = b.get("kind") or "oauth_token"
        else:
            out["installation_id"] = b.get("installation_id") or ""
        body = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
HTTPServer(("127.0.0.1", int(os.environ["SRV_PORT"])), H).serve_forever()
PYEOF
SRV_PID=$!
FAKE_URL="http://127.0.0.1:$SRV_PORT"
# wait for the fake server to accept.
for _ in $(seq 1 50); do
  "$PY" -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$SRV_PORT))==0 else 1)" && break
  sleep 0.1
done

echo
echo "════════════════════════════════════════════════════════════════════════════"
echo "hmd connect — lazy, secret-safe Claude-credential capture (Part 2)"
echo "════════════════════════════════════════════════════════════════════════════"

# ── (9) HELP resolves ──────────────────────────────────────────────────────────
if "$CONNECT" --help >/dev/null 2>&1; then ok "9.1 \`hmd connect --help\` resolves (bin exists, exit 0)"; else bad "9.1 --help did not exit 0"; fi

# ── (2) ENV AUTODETECT — no prompt, forwarded to /team/cred ────────────────────
OUT="$(CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" HEIMDALL_CP_URL="$FAKE_URL" "$CONNECT" </dev/null 2>&1)"; RC=$?
OUTP="$(printf '%s' "$OUT" | strip_ansi)"
[ "$RC" = 0 ] && ok "2.1 env-autodetect connect exits 0" || bad "2.1 env-autodetect exit=$RC ($OUTP)"
grep -qi "no prompt needed" <<<"$OUTP" && ok "2.2 CLAUDE_CODE_OAUTH_TOKEN used SILENTLY (no prompt)" || bad "2.2 did not report silent env use"
grep -qi "Paste your" <<<"$OUTP" && bad "2.3 a prompt was shown despite a valid env token" || ok "2.3 NO prompt shown (env token present)"
[ -f "$CAP_DIR/team_cred.body" ] && ok "2.4 the credential was forwarded to POST /team/cred" || bad "2.4 /team/cred was not called"
# the forwarded body carries the CLEAN token + kind (this is the wire body, not argv).
"$PY" - "$CAP_DIR/team_cred.body" "$TOKEN" <<'PYEOF' && ok "2.5 the forwarded body carries the clean token + kind=oauth_token, NO team_id" || bad "2.5 forwarded body wrong"
import json, sys
b = json.load(open(sys.argv[1]))
assert b.get("secret") == sys.argv[2], "secret mismatch"
assert b.get("kind") == "oauth_token", "kind"
assert "team_id" not in b, "team_id must be server-derived (INV-1)"
PYEOF
[ -f "$CAP_DIR/team_cred.hdr" ] && grep -q "SIG=" "$CAP_DIR/team_cred.hdr" && [ -n "$(grep '^SIG=' "$CAP_DIR/team_cred.hdr" | cut -d= -f2)" ] \
  && ok "2.6 the request was SIGNED (X-Heimdall-Signature present)" || bad "2.6 request not signed"

# ── (1) LAZY STATUS — after (2) a marker exists → bare connect is a no-op ───────
OUT="$(HEIMDALL_CP_URL="$FAKE_URL" "$CONNECT" </dev/null 2>&1)"; RC=$?
OUTP="$(printf '%s' "$OUT" | strip_ansi)"
[ "$RC" = 0 ] && grep -qi "already connected" <<<"$OUTP" && ok "1.1 re-run while connected → NO-OP status ('already connected')" || bad "1.1 re-run not a no-op ($OUTP)"
grep -qi "Paste your" <<<"$OUTP" && bad "1.2 a prompt was shown on a re-run" || ok "1.2 re-run shows NO prompt"
# --status shows the KIND, never the token value.
OUT="$(HEIMDALL_CP_URL="$FAKE_URL" "$CONNECT" --status </dev/null 2>&1 | strip_ansi)"
grep -qi "oauth_token" <<<"$OUT" && ok "1.3 --status reports the KIND (oauth_token)" || bad "1.3 --status missing kind"
grep -qF "$TOKEN" <<<"$OUT" && bad "1.4 --status LEAKED the token value" || ok "1.4 --status NEVER shows the token value"
# the marker on disk holds NO secret value.
grep -qF "$TOKEN" "$HOME/.heimdall/connect-state.json" 2>/dev/null && bad "1.5 the marker file stored the token value" || ok "1.5 the local marker holds NO token value (kind+ts only)"

# ── (5) NOT IN ARGV / (4) NO ECHO / (8) NO CLIPBOARD — source-level falsifiers ──
grep -q "read -rs" "$CONNECT" && ok "4.1 the prompt uses \`read -rs\` (hidden, no echo)" || bad "4.1 read -rs not used"
grep -Eq 'CP_CRED_SECRET=.*register_py|CP_CRED_SECRET="\$clean"' "$CONNECT" && ok "5.1 the secret crosses via the CP_CRED_SECRET ENV (never argv)" || bad "5.1 secret not passed via env"
# the token value must NEVER appear on any process argv while connect runs (nor on stdout).
grep -qF "$TOKEN" <<<"$OUTP" && bad "5.2 the token value appeared on connect output" || ok "5.2 the token value never appears on connect output"
# scan only EXECUTABLE lines (strip full-line comments — the header DOCUMENTS the ban).
if grep -vE '^[[:space:]]*#' "$CONNECT" | grep -Eq 'pbpaste|xclip|wl-paste|xsel|pbcopy'; then bad "8.1 a CLIPBOARD tool is CALLED (BANNED)"; else ok "8.1 NO clipboard tool called (pbpaste/xclip/wl-paste absent from code)"; fi

# ── (3) INBOX HAPPY PATH — arm, paste, validate, forward, SHRED ────────────────
rm -f "$CAP_DIR/team_cred.body" "$CAP_DIR/team_cred.hdr"
rm -f "$HOME/.heimdall/connect-state.json"      # clear the marker so inbox actually captures.
INBOX_DIR="$WORK/inbox"; mkdir -p "$INBOX_DIR"
INBOX_OUT="$WORK/inbox.out"
( HEIMDALL_CP_URL="$FAKE_URL" HEIMDALL_CONNECT_INBOX_DIR="$INBOX_DIR" \
  HEIMDALL_CONNECT_TIMEOUT=20 HEIMDALL_CONNECT_POLL=0.1 \
  "$CONNECT" --inbox </dev/null >"$INBOX_OUT" 2>&1 ) &
INBOX_PID=$!
# wait for the inbox file to be armed, then paste the token into it from "another tab".
INBOX_PATH=""
for _ in $(seq 1 60); do
  INBOX_PATH="$(ls "$INBOX_DIR"/heimdall-connect.* 2>/dev/null | head -1)"
  [ -n "$INBOX_PATH" ] && break
  sleep 0.1
done
if [ -n "$INBOX_PATH" ]; then
  ok "3.1 --inbox armed a fresh file in the tmpfs-like dir"
  # the instruction printed the PATH but never the content.
  grep -qF "$INBOX_PATH" "$INBOX_OUT" && ok "3.2 the inbox PATH is printed (the instruction)" || bad "3.2 inbox path not printed"
  printf '%s' "$TOKEN" > "$INBOX_PATH"     # paste from "any tab".
  wait "$INBOX_PID"; IRC=$?
  [ "$IRC" = 0 ] && ok "3.3 --inbox captured + forwarded, exit 0" || bad "3.3 --inbox exit=$IRC ($(strip_ansi <"$INBOX_OUT"))"
  [ -f "$CAP_DIR/team_cred.body" ] && ok "3.4 the pasted token was forwarded to POST /team/cred" || bad "3.4 /team/cred not called from inbox"
  [ -e "$INBOX_PATH" ] && bad "3.5 the inbox file still EXISTS (not shredded)" || ok "3.5 the inbox file was SHREDDED (gone) after capture"
  grep -qF "$TOKEN" "$INBOX_OUT" && bad "3.6 the inbox content was ECHOED to output" || ok "3.6 the inbox content was NEVER echoed"
else
  bad "3.1 --inbox never armed an inbox file"; kill "$INBOX_PID" 2>/dev/null || true
fi

# ── (6) TIMEOUT SAFE — no paste → nonzero, 'shredded' msg, inbox GONE ──────────
rm -f "$INBOX_DIR"/heimdall-connect.* 2>/dev/null || true
rm -f "$HOME/.heimdall/connect-state.json"
TO_OUT="$WORK/timeout.out"
HEIMDALL_CP_URL="$FAKE_URL" HEIMDALL_CONNECT_INBOX_DIR="$INBOX_DIR" \
  HEIMDALL_CONNECT_TIMEOUT=1 HEIMDALL_CONNECT_POLL=0.1 \
  "$CONNECT" --inbox </dev/null >"$TO_OUT" 2>&1; TRC=$?
[ "$TRC" != 0 ] && ok "6.1 --inbox timeout exits NONZERO ($TRC)" || bad "6.1 timeout did not exit nonzero"
grep -qi "shredded" "$TO_OUT" && ok "6.2 timeout prints a 'shredded / nothing captured' message" || bad "6.2 no shred message on timeout"
[ -z "$(ls "$INBOX_DIR"/heimdall-connect.* 2>/dev/null)" ] && ok "6.3 no inbox file remains after timeout (removed)" || bad "6.3 an inbox file survived the timeout"

# ── (7) SIGINT SAFE — trap shreds + removes the inbox on abort ─────────────────
rm -f "$INBOX_DIR"/heimdall-connect.* 2>/dev/null || true
SIG_OUT="$WORK/sigint.out"
( HEIMDALL_CP_URL="$FAKE_URL" HEIMDALL_CONNECT_INBOX_DIR="$INBOX_DIR" \
  HEIMDALL_CONNECT_TIMEOUT=30 HEIMDALL_CONNECT_POLL=0.1 \
  "$CONNECT" --inbox </dev/null >"$SIG_OUT" 2>&1 ) &
SIG_PID=$!
SIG_PATH=""
for _ in $(seq 1 60); do
  SIG_PATH="$(ls "$INBOX_DIR"/heimdall-connect.* 2>/dev/null | head -1)"
  [ -n "$SIG_PATH" ] && break
  sleep 0.1
done
if [ -n "$SIG_PATH" ]; then
  kill -INT "$SIG_PID" 2>/dev/null || true
  wait "$SIG_PID" 2>/dev/null; SRC=$?
  [ "$SRC" != 0 ] && ok "7.1 SIGINT during the watch → nonzero exit ($SRC)" || bad "7.1 SIGINT did not yield nonzero"
  [ -e "$SIG_PATH" ] && bad "7.2 the inbox survived SIGINT (trap did not shred)" || ok "7.2 SIGINT trap SHREDDED + removed the inbox (no residue)"
else
  bad "7.1 --inbox never armed for the SIGINT test"; kill "$SIG_PID" 2>/dev/null || true
fi

# ── (5b) NOT IN ARGV — runtime: no leftover plaintext anywhere under $HOME ──────
if grep -rqF "$TOKEN" "$HOME" 2>/dev/null; then bad "5.3 the token value is present somewhere under \$HOME at rest"; else ok "5.3 NO token plaintext at rest anywhere under \$HOME"; fi
# and the fake server logs never echoed a shell-argv trace of the token (sanity).
grep -qF "$TOKEN" "$WORK/srv.out" 2>/dev/null && bad "5.4 the token leaked to the server's stderr log" || ok "5.4 no token in the server log"

echo
echo "════════════════════════════════════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  printf "heimdall-connect: \033[32m%d passed\033[0m, 0 failed\n" "$PASS"
  echo "ALL GREEN — lazy status · env-autodetect · inbox happy path · SHRED · no-echo · not-in-argv · timeout · SIGINT · no-clipboard"
  exit 0
else
  printf "heimdall-connect: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
  exit 1
fi
