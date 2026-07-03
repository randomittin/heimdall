#!/usr/bin/env bash
# heimdall-gh-app-token.test.sh — HERMETIC proof of the dedicated GitHub-App PR-bot
# credential path. NO network, NO live GitHub, NO real App: a test RSA key is generated
# in-process (cryptography) and a fake GitHub API is served on 127.0.0.1 so every
# assertion runs offline.
#
# What it proves:
#   • bin/heimdall-gh-app-token mints an INSTALLATION token: it builds a well-formed
#     RS256 App JWT (alg=RS256, iss=<app-id>, exp within 10 min of iat) and POSTs it as
#     the Bearer to /app/installations/<id>/access_tokens.
#   • ONLY the installation token prints to stdout (nothing else).
#   • The App PRIVATE KEY never appears on stdout/stderr (grep) — with a POSITIVE
#     CONTROL that the key really signed the JWT (the fake API verifies the RS256
#     signature with the matching PUBLIC key; a 201 is only returned on a valid sig).
#   • Missing / invalid creds → a clear, NONZERO error (before any network).
#   • An API failure (wrong install id) → a clear, NONZERO error, still no key leak.
#   • The per-cycle wiring (maintain_loop.apply_pr_bot_token) exports
#     HEIMDALL_PR_BOT_TOKEN from the freshly-minted token when App creds are present,
#     and falls back to the static PAT when they are not.
#   • setup-bot.sh --dry-run prints the App-setup plan (permissions/install/verify) and
#     leaks no creds; bash -n both scripts.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/heimdall-gh-app-token"
SETUP="$ROOT/deploy/github-app/setup-bot.sh"
LIB="$ROOT/bin/lib"
PY="$(command -v python3 || command -v python)"

P=0; F=0
ok()  { P=$((P+1)); printf '  PASS %s\n' "$1"; }
bad() { F=$((F+1)); printf '  FAIL %s\n' "$1"; }

[ -x "$BIN" ]   || { echo "FATAL: $BIN not executable"; exit 2; }
[ -f "$SETUP" ] || { echo "FATAL: $SETUP missing"; exit 2; }
[ -n "$PY" ]    || { echo "FATAL: python3 not found"; exit 2; }

TMP="$(mktemp -d)"
SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

# ── 0. syntax gates ───────────────────────────────────────────────────────────
bash -n "$SETUP" && ok "setup-bot.sh bash -n clean" || bad "setup-bot.sh syntax error"
"$PY" -c "import ast,sys; ast.parse(open('$BIN').read())" && ok "heimdall-gh-app-token parses" \
  || bad "heimdall-gh-app-token syntax error"

# ── 1. generate a test RSA keypair (PEM), 0600 ───────────────────────────────
"$PY" - "$TMP" <<'PYEOF'
import sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
tmp = sys.argv[1]
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
priv = key.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption(),
)
pub = key.public_key().public_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PublicFormat.SubjectPublicKeyInfo,
)
open(tmp + "/key.pem", "wb").write(priv)
open(tmp + "/pub.pem", "wb").write(pub)
PYEOF
chmod 600 "$TMP/key.pem"
[ -s "$TMP/key.pem" ] && ok "test RSA private key generated" || bad "keygen failed"
# a stable NEEDLE from the middle of the PEM base64 body — must never leak to logs.
NEEDLE="$(sed -n '3p' "$TMP/key.pem")"
[ -n "$NEEDLE" ] || NEEDLE="$(sed -n '2p' "$TMP/key.pem")"

# ── 2. start the fake GitHub API (verifies the JWT sig; captures the request) ─
cat > "$TMP/fake_gh.py" <<'PYEOF'
import base64, json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

TMP = sys.argv[1]
PUB = serialization.load_pem_public_key(open(TMP + "/pub.pem", "rb").read())

def b64url_decode(s):
    s += "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s.encode())

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # keep the test output clean
        return

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(n) if n else b""
        auth = self.headers.get("Authorization", "")
        cap = {
            "path": self.path,
            "authorization": auth,
            "accept": self.headers.get("Accept", ""),
            "api_version": self.headers.get("X-GitHub-Api-Version", ""),
            "body": body.decode("utf-8", "replace"),
            "sig_ok": False,
        }
        # positive control: verify the RS256 signature with the matching PUBLIC key.
        if auth.startswith("Bearer "):
            jwt = auth[len("Bearer "):]
            try:
                h_b64, p_b64, s_b64 = jwt.split(".")
                signing_input = (h_b64 + "." + p_b64).encode()
                PUB.verify(b64url_decode(s_b64), signing_input,
                           padding.PKCS1v15(), hashes.SHA256())
                cap["sig_ok"] = True
                cap["header"] = json.loads(b64url_decode(h_b64))
                cap["payload"] = json.loads(b64url_decode(p_b64))
            except Exception as e:
                cap["error"] = str(e)
        import os
        tmpf = TMP + "/req.json.tmp"
        open(tmpf, "w").write(json.dumps(cap))
        os.replace(tmpf, TMP + "/req.json")
        # only install id 987 with a VALID signature gets a 201 token.
        if self.path == "/app/installations/987/access_tokens" and cap["sig_ok"]:
            out = json.dumps({
                "token": "ghs_FAKEINSTALLTOKEN_deadbeef",
                "expires_at": "2099-01-01T00:00:00Z",
                "permissions": {"contents": "write", "issues": "write", "pull_requests": "write"},
            }).encode()
            self.send_response(201)
        else:
            out = json.dumps({"message": "Bad credentials"}).encode()
            self.send_response(401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

srv = HTTPServer(("127.0.0.1", 0), H)
open(TMP + "/port", "w").write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
"$PY" "$TMP/fake_gh.py" "$TMP" &
SRV_PID=$!
disown "$SRV_PID" 2>/dev/null || true
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PORT="$(cat "$TMP/port" 2>/dev/null)"
[ -n "$PORT" ] && ok "fake GitHub API up on 127.0.0.1:$PORT" || { bad "fake API never bound"; }
BASE="http://127.0.0.1:$PORT"

# ── 3. mint a token — the happy path ─────────────────────────────────────────
OUT="$(HEIMDALL_GH_APP_ID=123456 \
       HEIMDALL_GH_APP_INSTALLATION_ID=987 \
       HEIMDALL_GH_APP_PRIVATE_KEY_FILE="$TMP/key.pem" \
       HEIMDALL_GH_API_BASE="$BASE" \
       "$BIN" 2>"$TMP/err")"; rc=$?
[ "$rc" = 0 ] && ok "mint exit 0" || bad "mint rc=$rc (stderr: $(cat "$TMP/err"))"
[ "$OUT" = "ghs_FAKEINSTALLTOKEN_deadbeef" ] && ok "stdout is ONLY the installation token" \
  || bad "stdout not exactly the token: [$OUT]"
# stdout is a single line — no diagnostics bleed onto it.
[ "$(printf '%s' "$OUT" | wc -l | tr -d ' ')" = "0" ] && ok "stdout is a single bare line" \
  || bad "stdout has extra lines"

# ── 4. the request the API received (path + bearer + JWT shape) ──────────────
REQ="$TMP/req.json"
"$PY" - "$REQ" <<'PYEOF' && ok "JWT: RS256, iss=app-id, exp<=10min, Bearer to /installations/987/access_tokens" || bad "JWT/request shape wrong"
import json, sys
c = json.load(open(sys.argv[1]))
assert c["path"] == "/app/installations/987/access_tokens", c["path"]
assert c["authorization"].startswith("Bearer "), c["authorization"]
assert c["sig_ok"] is True, "signature did NOT verify with the public key"
h = c["header"]; p = c["payload"]
assert h.get("alg") == "RS256", h
assert h.get("typ") == "JWT", h
assert str(p.get("iss")) == "123456", p
iat = int(p["iat"]); exp = int(p["exp"])
assert 0 < (exp - iat) <= 600, (iat, exp, exp - iat)
assert "application/vnd.github" in c["accept"], c["accept"]
PYEOF

# ── 5. SECRET-SAFETY — the private key never surfaces (positive control above) ─
if grep -qF "$NEEDLE" "$TMP/err" 2>/dev/null; then bad "private key leaked to stderr"; else ok "no private-key material on stderr"; fi
printf '%s' "$OUT" | grep -qF "$NEEDLE" && bad "private key leaked to stdout" || ok "no private-key material on stdout"
# the key is passed via env/file only — never on argv. Prove the bin exposes no key flag.
grep -q -- '--private-key' "$BIN" && bad "bin takes a key on argv (leak risk)" || ok "bin reads key via env/file, never argv"

# ── 6. inline-PEM path works too (HEIMDALL_GH_APP_PRIVATE_KEY) ────────────────
OUT6="$(HEIMDALL_GH_APP_ID=123456 \
        HEIMDALL_GH_APP_INSTALLATION_ID=987 \
        HEIMDALL_GH_APP_PRIVATE_KEY="$(cat "$TMP/key.pem")" \
        HEIMDALL_GH_API_BASE="$BASE" \
        "$BIN" 2>/dev/null)"; rc6=$?
[ "$rc6" = 0 ] && [ "$OUT6" = "ghs_FAKEINSTALLTOKEN_deadbeef" ] && ok "inline PEM env also mints" \
  || bad "inline PEM path failed (rc=$rc6)"

# ── 7. missing creds → clear NONZERO error (before any network) ──────────────
HEIMDALL_GH_APP_INSTALLATION_ID=987 HEIMDALL_GH_APP_PRIVATE_KEY_FILE="$TMP/key.pem" \
  HEIMDALL_GH_API_BASE="$BASE" "$BIN" >"$TMP/o7" 2>"$TMP/e7"; rc7=$?
[ "$rc7" != 0 ] && grep -qi 'HEIMDALL_GH_APP_ID' "$TMP/e7" && ok "missing app-id -> clear nonzero error" \
  || bad "missing app-id not rejected clearly (rc=$rc7)"

echo "not a pem" > "$TMP/bad.pem"
HEIMDALL_GH_APP_ID=1 HEIMDALL_GH_APP_INSTALLATION_ID=987 \
  HEIMDALL_GH_APP_PRIVATE_KEY_FILE="$TMP/bad.pem" HEIMDALL_GH_API_BASE="$BASE" \
  "$BIN" >"$TMP/o7b" 2>"$TMP/e7b"; rc7b=$?
[ "$rc7b" != 0 ] && grep -qi 'private key' "$TMP/e7b" && ok "invalid PEM -> clear nonzero error" \
  || bad "invalid PEM not rejected clearly (rc=$rc7b)"

# ── 8. API failure (wrong install id) → nonzero, still no key leak ────────────
HEIMDALL_GH_APP_ID=123456 HEIMDALL_GH_APP_INSTALLATION_ID=000 \
  HEIMDALL_GH_APP_PRIVATE_KEY_FILE="$TMP/key.pem" HEIMDALL_GH_API_BASE="$BASE" \
  "$BIN" >"$TMP/o8" 2>"$TMP/e8"; rc8=$?
[ "$rc8" != 0 ] && ok "API 401 -> nonzero exit" || bad "API failure not surfaced (rc=$rc8)"
grep -qF "$NEEDLE" "$TMP/e8" && bad "key leaked on API-error path" || ok "no key leak on API-error path"

# ── 9. per-cycle wiring — apply_pr_bot_token mints, else falls back to PAT ────
cat > "$TMP/fake-mint" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "ghs_MINTED_percycle_777"
SH
chmod +x "$TMP/fake-mint"

# 9a. App creds present → export the MINTED token as HEIMDALL_PR_BOT_TOKEN
R9A="$(cd "$ROOT" && HEIMDALL_GH_APP_ID=1 HEIMDALL_GH_APP_TOKEN_BIN="$TMP/fake-mint" \
  PYTHONPATH="$LIB" "$PY" - <<'PYEOF'
import os
os.environ.pop("HEIMDALL_PR_BOT_TOKEN", None)
import maintain_loop as M
path = M.apply_pr_bot_token()
print(path, os.environ.get("HEIMDALL_PR_BOT_TOKEN"))
PYEOF
)"
[ "$R9A" = "app ghs_MINTED_percycle_777" ] && ok "wiring: App creds -> minted token exported as HEIMDALL_PR_BOT_TOKEN" \
  || bad "wiring app-path wrong: [$R9A]"

# 9b. no App creds, static PAT present → keep the static PAT (fallback)
R9B="$(cd "$ROOT" && HEIMDALL_PR_BOT_TOKEN="ghp_STATIC_pat_123" \
  HEIMDALL_GH_APP_TOKEN_BIN="$TMP/fake-mint" PYTHONPATH="$LIB" "$PY" - <<'PYEOF'
import os
os.environ.pop("HEIMDALL_GH_APP_ID", None)
import maintain_loop as M
path = M.apply_pr_bot_token()
print(path, os.environ.get("HEIMDALL_PR_BOT_TOKEN"))
PYEOF
)"
[ "$R9B" = "static ghp_STATIC_pat_123" ] && ok "wiring: no App creds -> static PAT retained (fallback)" \
  || bad "wiring fallback wrong: [$R9B]"

# ── 10. setup-bot.sh --dry-run prints the plan, leaks nothing ────────────────
OUT10="$(bash "$SETUP" --dry-run 2>&1)"; rc10=$?
[ "$rc10" = 0 ] && ok "setup-bot --dry-run exit 0 (no creds)" || bad "setup-bot dry-run rc=$rc10"
printf '%s' "$OUT10" | grep -qi 'Contents' && printf '%s' "$OUT10" | grep -qi 'Pull request' \
  && ok "setup plan documents Contents + Pull requests permissions" || bad "permissions not documented"
printf '%s' "$OUT10" | grep -qi 'Metadata' && ok "setup plan notes Metadata (mandatory) permission" || bad "Metadata not noted"
printf '%s' "$OUT10" | grep -qiE 'no Administration|NEVER|no workflow' && ok "setup plan states the DENIED scopes" || bad "denied scopes not stated"
printf '%s' "$OUT10" | grep -qi 'heimdall-gh-app-token' && ok "setup plan verifies via heimdall-gh-app-token" || bad "verify step missing"
printf '%s' "$OUT10" | grep -qF "$NEEDLE" && bad "setup dry-run leaked key material" || ok "setup dry-run leaks no creds"

echo "──────────"
echo "gh-app-token: $P passed, $F failed"
[ "$F" = 0 ] || exit 1
