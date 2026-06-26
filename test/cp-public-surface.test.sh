#!/usr/bin/env bash
# cp-public-surface.test.sh — THE PUBLIC-SURFACE BOUNDARY falsifier (deployed-shape).
#
# The whole trust story of the public --allow-unauthenticated presence surface rests on ONE
# guarantee: a GATED route (dispatch/jobs/approvals/owner/…) MUST NOT exist on the public
# surface. This drives a REAL `heimdall-control-plane serve` subprocess and asserts it over a
# real socket:
#
#   CARDINAL (the falsifier) — with HEIMDALL_PUBLIC_SURFACE=1, an UNSIGNED POST to a gated
#     route returns a FLAT 404 (not 401, not 200): the route does not resolve/parse/authenticate
#     on the public surface. An unsigned request proves it is the BOUNDARY, not auth, doing the
#     refusing — confirmed by the flag-OFF control where the SAME unsigned request returns 401
#     (the route exists, auth is demanded). Remove the boundary and the gated route answers
#     non-404 => RED.
#   PUBLIC reachable — /healthz 200; /enroll is reachable + token-gated (wrong token -> 401, not 404).
#   RATE-LIMIT wired — a per-IP enroll flood trips 429 (limit set low via env for determinism).
#   FLAG-OFF = gated unchanged — the gated service still routes /dispatch to the auth chokepoint (401).
#
# Crypto-gated (serve mints its server identity): SKIP cleanly when no cryptography|pynacl.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
CLI="$REPO/bin/heimdall-control-plane"
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: no python" >&2; exit 2; }
[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

if ! "$PY" -c "import sys;sys.path.insert(0,'$LIB');import cp_auth;sys.exit(0 if cp_auth.crypto_available() else 1)"; then
  echo "  SKIP no crypto backend (cryptography|pynacl) — serve needs a server identity."
  echo "cp-public-surface: 0 passed, 0 failed (SKIPPED — no crypto)"
  exit 0
fi

PKI="$("$PY" -c "import base64,os;print(base64.b64encode(os.urandom(32)).decode())")"
TOKEN="public-surface-fixture-token-$$"   # fake fixture; never a real secret
EXT="$(mktemp -d)"; SRV1=""; SRV2=""
cleanup(){ for p in "$SRV1" "$SRV2"; do [ -n "$p" ] && { kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; }; done; rm -rf "$EXT"; }
trap cleanup EXIT

freeport(){ "$PY" -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()"; }

# httpstat METHOD URL [BODY] [HEADER "K:V"] -> prints the HTTP status code (0 on transport error)
httpstat(){ "$PY" - "$@" <<'PY'
import sys, urllib.request, urllib.error
m, u = sys.argv[1], sys.argv[2]
data = sys.argv[3].encode() if len(sys.argv) > 3 and sys.argv[3] else None
req = urllib.request.Request(u, data=data, method=m)
if len(sys.argv) > 4 and sys.argv[4]:
    k, v = sys.argv[4].split(":", 1); req.add_header(k, v)
try:
    print(urllib.request.urlopen(req, timeout=5).status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print(0)
PY
}
waitup(){ for _ in $(seq 1 60); do [ "$(httpstat GET "$1/healthz")" = "200" ] && return 0; sleep 0.1; done; return 1; }

# ── boot the PUBLIC surface (HEIMDALL_PUBLIC_SURFACE=1, enroll IP limit low for determinism) ──
P1="$(freeport)"; U1="http://127.0.0.1:$P1"
HEIMDALL_PUBLIC_SURFACE=1 HEIMDALL_CP_PKI_KEY="$PKI" HEIMDALL_ENROLL_TOKEN="$TOKEN" \
  HEIMDALL_ENROLL_IP_LIMIT=3 HEIMDALL_HOME="$EXT/pub" \
  "$CLI" serve --host 127.0.0.1 --port "$P1" >/dev/null 2>&1 &
SRV1=$!
waitup "$U1" || { bad "public server did not come up"; echo "cp-public-surface: $PASS passed, $((FAIL+1)) failed"; exit 1; }
ok "public surface up (HEIMDALL_PUBLIC_SURFACE=1)"

# CARDINAL FALSIFIER — gated routes are 404 (not reached) on the public surface, UNSIGNED.
for r in /dispatch /jobs /approvals; do
  c="$(httpstat POST "$U1$r" '{}')"
  if [ "$c" = "404" ]; then ok "gated $r -> 404 on public surface (boundary; never resolves/auths)"
  else bad "gated $r -> $c on public surface (expected 404 — the BOUNDARY is broken)"; fi
done

# PUBLIC routes reachable + token-gated.
[ "$(httpstat GET "$U1/healthz")" = "200" ] && ok "/healthz reachable (200)" || bad "/healthz not 200"
c="$(httpstat POST "$U1/enroll" '{"haid":"x","pubkey":"y"}' 'X-Heimdall-Enroll-Token:WRONGTOKEN')"
if [ "$c" = "401" ]; then ok "/enroll reachable + wrong-token -> 401 (gated by token, not 404)"
else bad "/enroll wrong-token -> $c (expected 401)"; fi

# RATE-LIMIT wired — a per-IP enroll flood trips 429 (limit=3).
hit429=0
for i in $(seq 1 25); do
  c="$(httpstat POST "$U1/enroll" '{"haid":"rl'"$i"'","pubkey":"bad"}' "X-Heimdall-Enroll-Token:$TOKEN")"
  [ "$c" = "429" ] && { hit429=1; break; }
done
[ "$hit429" = "1" ] && ok "enroll per-IP rate-limit trips 429 under flood (gate wired)" \
  || bad "no 429 under 25 rapid enrolls at limit=3 (rate-limit not wired?)"

# ── boot the GATED surface (flag OFF) — the control ──
P2="$(freeport)"; U2="http://127.0.0.1:$P2"
HEIMDALL_CP_PKI_KEY="$PKI" HEIMDALL_ENROLL_TOKEN="$TOKEN" HEIMDALL_HOME="$EXT/gated" \
  "$CLI" serve --host 127.0.0.1 --port "$P2" >/dev/null 2>&1 &
SRV2=$!
waitup "$U2" || { bad "gated server did not come up"; echo "cp-public-surface: $PASS passed, $((FAIL+1)) failed"; exit 1; }
# Flag-off control: the SAME unsigned /dispatch now reaches the auth chokepoint -> 401, NOT 404.
c="$(httpstat POST "$U2/dispatch" '{}')"
if [ "$c" = "401" ]; then ok "flag-off: /dispatch -> 401 (route exists, gated by auth; boundary is flag-gated, gated service unchanged)"
elif [ "$c" = "404" ]; then bad "flag-off: /dispatch -> 404 (the boundary leaked into the GATED service — must be flag-gated)"
else bad "flag-off: /dispatch -> $c (expected 401)"; fi

echo "──────────────────────────────────────────"
echo "cp-public-surface: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] || exit 1
