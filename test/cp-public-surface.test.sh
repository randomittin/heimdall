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

# ── MECHANICAL ISOLATION GUARD (no crypto — always runs) ──────────────────────────────────
# THE whole god/session isolation boundary reduces to ONE allowlist fact: the four dashboard-
# login SESSION routes MUST be in PUBLIC_ROUTES (reachable on the internet surface) and the two
# owner-only GOD routes MUST NOT be (they stay gated-only — a flat 404 on the public surface,
# INV-GOD G1/G2). This asserts PUBLIC_ROUTES membership DIRECTLY so a future edit that leaks a
# god route public — or drops/renames a session route — goes RED mechanically, without needing a
# live server or a crypto backend. (The live-server half below re-proves it over a real socket.)
GUARD_OUT="$("$PY" - "$LIB" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import cp_publicsurface as p
must_public = [("POST", "/dashboard/session/init"),
               ("POST", "/dashboard/session/approve"),
               ("GET",  "/dashboard/session/status"),
               ("GET",  "/dashboard/rosters")]
must_not_public = [("GET", "/god/roster"), ("GET", "/god/logs")]
problems = []
for m, path in must_public:
    if not p.is_public_route(m, path):
        problems.append("MISSING_PUBLIC %s %s" % (m, path))
for m, path in must_not_public:
    if p.is_public_route(m, path):
        problems.append("GOD_LEAKED_PUBLIC %s %s" % (m, path))
print("; ".join(problems))
sys.exit(1 if problems else 0)
PY
)"
if [ $? -eq 0 ]; then
  ok "isolation guard: 4 session routes IN PUBLIC_ROUTES, /god/{roster,logs} NOT (boundary pinned)"
else
  bad "isolation guard: PUBLIC_ROUTES boundary broken -> ${GUARD_OUT:-unknown}"
fi

if ! "$PY" -c "import sys;sys.path.insert(0,'$LIB');import cp_auth;sys.exit(0 if cp_auth.crypto_available() else 1)"; then
  echo "  SKIP no crypto backend (cryptography|pynacl) — serve needs a server identity."
  echo "cp-public-surface: $PASS passed, $FAIL failed (server checks SKIPPED — no crypto)"
  [ "$FAIL" = "0" ] || exit 1
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
# httphdr METHOD URL HEADER [REQ-HEADER "K:V"] -> prints the named RESPONSE header value ('' if absent)
httphdr(){ "$PY" - "$@" <<'PY'
import sys, urllib.request, urllib.error
m, u, want = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request(u, method=m)
if len(sys.argv) > 4 and sys.argv[4]:
    k, v = sys.argv[4].split(":", 1); req.add_header(k, v)
try:
    r = urllib.request.urlopen(req, timeout=5); hdrs = r.headers
except urllib.error.HTTPError as e:
    hdrs = e.headers
except Exception:
    print(""); sys.exit(0)
print(hdrs.get(want, "") or "")
PY
}
# flood METHOD URL N MODE [BODY] -> prints "<code> <scope>" of the FIRST 429 (shed) among N requests,
# or "none 0" if none shed. MODE picks the X-Forwarded-For (client-IP) key cp_publicsurface rate-limits
# on: "same" -> every request shares ONE IP bucket (proves a per-IP cap); "rotate" -> each request a
# DISTINCT IP (per-IP never trips, isolates the deployment-wide budget); "none" -> no XFF (peer IP).
flood(){ "$PY" - "$@" <<'PYF'
import sys, json, urllib.request, urllib.error
m, u, n, mode = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
raw = sys.argv[5].encode() if len(sys.argv) > 5 and sys.argv[5] else b"{}"
data = raw if m == "POST" else None
for i in range(1, n + 1):
    req = urllib.request.Request(u, data=data, method=m)
    if mode == "same":
        req.add_header("X-Forwarded-For", "203.0.113.7")
    elif mode == "rotate":
        req.add_header("X-Forwarded-For", "198.51.100.%d" % i)
    try:
        urllib.request.urlopen(req, timeout=5)
    except urllib.error.HTTPError as e:
        if e.code == 429:
            try: scope = json.loads(e.read() or b"{}").get("scope", "")
            except Exception: scope = ""
            print("429 %s" % (scope or "")); sys.exit(0)
    except Exception:
        print("0 transport"); sys.exit(0)
print("none 0")
PYF
}
waitup(){ for _ in $(seq 1 60); do [ "$(httpstat GET "$1/healthz")" = "200" ] && return 0; sleep 0.1; done; return 1; }

# ── boot the PUBLIC surface (HEIMDALL_PUBLIC_SURFACE=1, enroll IP limit low for determinism) ──
P1="$(freeport)"; U1="http://127.0.0.1:$P1"
HEIMDALL_PUBLIC_SURFACE=1 HEIMDALL_CP_PKI_KEY="$PKI" HEIMDALL_ENROLL_TOKEN="$TOKEN" \
  HEIMDALL_ENROLL_IP_LIMIT=3 HEIMDALL_DASH_INIT_IP_LIMIT=3 HEIMDALL_DASH_READ_IP_LIMIT=3 \
  HEIMDALL_DASH_INIT_BUDGET_MAX=20 HEIMDALL_HOME="$EXT/pub" \
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

# GOD ROUTES stay gated-only — a FLAT 404 on the public surface (INV-GOD G1/G2). The live
# re-proof of the mechanical guard above: even the owner's cross-tenant routes must be
# indistinguishable from nonexistent on the internet surface (no 401 that would reveal them).
for r in /god/roster /god/logs; do
  c="$(httpstat GET "$U1$r")"
  if [ "$c" = "404" ]; then ok "god $r -> 404 on public surface (never in PUBLIC_ROUTES — G1/G2)"
  else bad "god $r -> $c on public surface (expected 404 — a GOD route LEAKED public!)"; fi
done

# DASHBOARD-SESSION routes ARE reachable on the public surface (they resolve past the boundary,
# each self-gated). init mints a device_code (200); rosters with no token 401s (route resolves,
# token-gated — NOT a boundary 404); the OPTIONS preflight answers 204.
c="$(httpstat POST "$U1/dashboard/session/init" '{}')"
[ "$c" = "200" ] && ok "/dashboard/session/init reachable -> 200 (mints device_code)" \
  || bad "/dashboard/session/init -> $c on public surface (expected 200 — session route unreachable?)"
c="$(httpstat GET "$U1/dashboard/rosters")"
[ "$c" = "401" ] && ok "/dashboard/rosters reachable + no-token -> 401 (token-gated, not a 404 boundary)" \
  || bad "/dashboard/rosters -> $c (expected 401 missing_token — route unreachable?)"
c="$(httpstat OPTIONS "$U1/dashboard/rosters")"
[ "$c" = "204" ] && ok "OPTIONS /dashboard/rosters preflight -> 204 (CORS preflight resolves)" \
  || bad "OPTIONS /dashboard/rosters -> $c (expected 204 — preflight route missing?)"

# CORS WIRED — the cross-origin runheimdall.dev dashboard must be able to READ these responses.
h="$(httphdr GET "$U1/dashboard/session/status?device_code=dc-nope" "Access-Control-Allow-Origin")"
[ "$h" = "*" ] && ok "/dashboard/session/status carries Access-Control-Allow-Origin:* (browser can read)" \
  || bad "/dashboard/session/status ACAO='$h' (expected * — dashboard cannot read cross-origin)"
h="$(httphdr GET "$U1/dashboard/rosters" "Access-Control-Allow-Origin")"
[ "$h" = "*" ] && ok "/dashboard/rosters (401) carries Access-Control-Allow-Origin:* (error is readable too)" \
  || bad "/dashboard/rosters ACAO='$h' (expected * — error opaque to browser)"
h="$(httphdr OPTIONS "$U1/dashboard/rosters" "Access-Control-Allow-Headers")"
case "$h" in *[Aa]uthorization*) ok "OPTIONS /dashboard/rosters advertises Access-Control-Allow-Headers: Authorization" ;;
  *) bad "OPTIONS /dashboard/rosters allow-headers='$h' (expected Authorization — preflight would fail)" ;; esac
h="$(httphdr GET "$U1/config" "Access-Control-Allow-Origin")"
[ "$h" = "*" ] && ok "/config carries Access-Control-Allow-Origin:* (dashboard refresh-interval read works)" \
  || bad "/config ACAO='$h' (expected * — cross-origin /config read blocked)"

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

# ── DASHBOARD-LOGIN abuse caps (deploy-blocker: the 4 /dashboard/session/* routes went public with
#    ZERO rate caps — a write-cost DoS on the $10k budget). Prove each cap is LOAD-BEARING: a flood
#    trips the shed status (429) with the RIGHT scope, while a legitimately-paced login still 200s.
#    IP caps set low via env (INIT/READ=3), budget=20; XFF spoofing keys the per-IP vs budget gate.
c="$(httpstat POST "$U1/dashboard/session/init" '{}' 'X-Forwarded-For:192.0.2.50')"
[ "$c" = "200" ] && ok "dash init legit-paced (single IP) -> 200 (a real login is never shed)" \
  || bad "dash init legit -> $c (expected 200 — a legit login must not be capped)"

r="$(flood POST "$U1/dashboard/session/init" 12 same '{}')"
case "$r" in "429 dash_init_ip") ok "dash init per-IP flood -> 429 dash_init_ip (write-cost DoS shed)" ;;
  *) bad "dash init per-IP flood -> '$r' (expected '429 dash_init_ip' — per-IP cap not wired?)" ;; esac

# IP-rotating flood: each request a fresh IP (per-IP never trips), so ONLY the deployment-wide
# device_code budget can shed it -> an attacker rotating IPs still cannot explode the session store.
r="$(flood POST "$U1/dashboard/session/init" 60 rotate '{}')"
case "$r" in "429 dash_init_budget") ok "dash init IP-rotating flood -> 429 dash_init_budget (budget bounds the fleet)" ;;
  *) bad "dash init rotate flood -> '$r' (expected '429 dash_init_budget' — budget cap not wired?)" ;; esac

# READ caps: approve/status/rosters each shed a same-IP flood past READ_IP_LIMIT=3 with their OWN
# scope (the shed happens BEFORE the handler's verify/enumerate — a real pre-work flood shed).
r="$(flood POST "$U1/dashboard/session/approve" 12 same '{}')"
case "$r" in "429 dash_approve_ip") ok "dash approve per-IP flood -> 429 dash_approve_ip (sig-verify-flood shed)" ;;
  *) bad "dash approve flood -> '$r' (expected '429 dash_approve_ip')" ;; esac
r="$(flood GET "$U1/dashboard/session/status?device_code=dc-nope" 12 same)"
case "$r" in "429 dash_status_ip") ok "dash status per-IP flood -> 429 dash_status_ip (poll-flood shed)" ;;
  *) bad "dash status flood -> '$r' (expected '429 dash_status_ip')" ;; esac
r="$(flood GET "$U1/dashboard/rosters" 12 same)"
case "$r" in "429 dash_rosters_ip") ok "dash rosters per-IP flood -> 429 dash_rosters_ip (enumerate-flood shed)" ;;
  *) bad "dash rosters flood -> '$r' (expected '429 dash_rosters_ip')" ;; esac

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

# DASH caps are FLAG-GATED + LOAD-BEARING: on the gated surface (flag off) the SAME init flood is NOT
# shed (the gates are inert) — remove the public boundary and the flood succeeds, proving the CAP (not
# some other layer) is what sheds on the public surface. A 429 here would mean a cap leaked into gated.
r="$(flood POST "$U2/dashboard/session/init" 12 same '{}')"
case "$r" in "none 0") ok "flag-off: dash init flood NOT shed (gates inert on gated service; cap is load-bearing)" ;;
  *) bad "flag-off: dash init flood -> '$r' (expected 'none 0' — a cap leaked into the GATED service!)" ;; esac

echo "──────────────────────────────────────────"
echo "cp-public-surface: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] || exit 1
