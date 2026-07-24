#!/usr/bin/env bash
# cp-iap-god-bridge.test.sh — the REAL cp-level proof of the BROWSER→GOD auth bridge
# (cp_iap + the cp_server god-surface branch). It proves the new IAP owner-auth path is a
# fully-verified ES256 JWT gate that fails CLOSED on every tampered/absent/wrong input, and
# that it is honored ONLY for /god/* on the god-serving surface — never weakening INV-GOD.
#
# Two layers, both against the REAL code (zero real GCP):
#   [A] UNIT — cp_iap.verify_iap_jwt / iap_identity driven with a LOCALLY-generated EC P-256
#       key + self-signed IAP-shaped JWTs (a supplied jwks_provider stands in for Google's
#       gstatic key set). Every failure mode gets its own case: forged signature, alg=none /
#       alg confusion, wrong issuer, wrong audience, expired, future-iat, no email, unknown
#       kid, malformed, missing header, unconfigured surface, wrong email. Plus the positive
#       control (a valid owner JWT mints Identity(owner=True)).
#   [B] END-TO-END — a real cp_server HTTPServer on the god surface (HEIMDALL_GOD_SURFACE=1)
#       with the JWKS pointed at a local file. Over an actual socket: a valid owner IAP JWT
#       GETs /god/roster (200, cross-tenant aggregate), a forged/absent/wrong-email JWT ->
#       401, a NON-god route (/dispatch) -> 404 (surface minimized), health -> 200 pre-auth,
#       and a forged ?team_id is ignored (G4 holds under the IAP identity too).
#
# stdlib python + the cryptography EC backend the CP already ships. Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"

for f in cp_iap cp_auth cp_server cp_god cp_presence cp_state cp_audit cp_diag; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

if ! "$PY" -c "import cryptography.hazmat.primitives.asymmetric.ec" 2>/dev/null; then
  echo "  SKIP: python cryptography EC backend required for the IAP bridge."
  echo "cp-iap-god-bridge: 0 passed, 0 failed (SKIPPED — no EC backend)"
  exit 0
fi

HOME_T="$(mktemp -d -t cp-iap-god.XXXXXX)"
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT

export LIB REPO HOME_T

HEIMDALL_HOME="$HOME_T" "$PY" - <<'PYEOF'
import os, sys, json, time, base64, threading
import http.client

sys.path.insert(0, os.environ["LIB"])
HOME = os.environ["HOME_T"]

import cp_iap, cp_auth, cp_server, cp_god, cp_presence, cp_audit

from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

PASS = 0
FAIL = 0
def ok(m):
    global PASS; PASS += 1; print("  \033[32mPASS\033[0m " + m)
def bad(m):
    global FAIL; FAIL += 1; print("  \033[31mFAIL\033[0m " + m)
def check(cond, m):
    ok(m) if cond else bad(m)

def raises(reason, fn):
    """True iff fn() raises cp_auth.AuthError whose reason == `reason`."""
    try:
        fn()
        return False
    except cp_auth.AuthError as e:
        return e.reason == reason
    except Exception:
        return False

# ── local ES256 signer + IAP JWK, standing in for Google's IAP signer/gstatic keys ──
def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")

KID = "test-kid-1"
PRIV = ec.generate_private_key(ec.SECP256R1())
PUB = PRIV.public_key()
ATTACKER = ec.generate_private_key(ec.SECP256R1())  # a DIFFERENT key -> forged signatures.

def jwk_of(pub, kid):
    n = pub.public_numbers()
    return {"kty": "EC", "crv": "P-256", "kid": kid, "alg": "ES256", "use": "sig",
            "x": b64url(n.x.to_bytes(32, "big")), "y": b64url(n.y.to_bytes(32, "big"))}

JWK = jwk_of(PUB, KID)
JWKS = {"keys": [JWK]}

def sign_jwt(claims, *, kid=KID, priv=PRIV, alg="ES256", force_sig=None):
    header = {"alg": alg, "kid": kid, "typ": "JWT"}
    h = b64url(json.dumps(header).encode("utf-8"))
    p = b64url(json.dumps(claims).encode("utf-8"))
    if force_sig is not None:
        return h + "." + p + "." + force_sig
    der = priv.sign((h + "." + p).encode("ascii"), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return h + "." + p + "." + b64url(raw)

OWNER_EMAIL = "rj@heimdall.example"
AUD = "/projects/123456/global/backendServices/7890"
ISS = cp_iap.IAP_ISSUER

def base_claims(**over):
    now = int(time.time())
    c = {"iss": ISS, "aud": AUD, "email": OWNER_EMAIL,
         "sub": "accounts.google.com:12345",
         "iat": now - 5, "exp": now + 600}
    c.update(over)
    return c

# a jwks_provider that returns our local JWK for KID, nothing else (Google's gstatic stand-in)
def provider(kid):
    return JWK if kid == KID else None

ENV = {cp_iap.OWNER_EMAIL_ENV: OWNER_EMAIL, cp_iap.AUDIENCE_ENV: AUD}

print("== [A] UNIT — cp_iap.verify_iap_jwt / iap_identity (every failure mode) ==")

# positive control: a valid owner JWT verifies + mints Identity(owner=True)
good = sign_jwt(base_claims())
claims = cp_iap.verify_iap_jwt(good, audience=AUD, jwks_provider=provider)
check(claims.get("email") == OWNER_EMAIL, "valid owner JWT verifies, returns email claim")
ident = cp_iap.iap_identity({"iap_assertion": good}, env=ENV, jwks_provider=provider)
check(getattr(ident, "owner", False) is True and ident.haid == "iap:" + OWNER_EMAIL,
      "valid owner JWT -> Identity(owner=True, haid=iap:<email>)")

# forged signature (signed by a DIFFERENT key, same kid) -> bad_signature
forged = sign_jwt(base_claims(), priv=ATTACKER)
check(raises("bad_signature", lambda: cp_iap.verify_iap_jwt(forged, audience=AUD, jwks_provider=provider)),
      "forged signature (wrong key) -> bad_signature")

# alg confusion / alg=none -> unsupported_alg (we NEVER honor a caller-chosen alg)
noalg = sign_jwt(base_claims(), alg="none", force_sig="deadbeef")
check(raises("unsupported_alg", lambda: cp_iap.verify_iap_jwt(noalg, audience=AUD, jwks_provider=provider)),
      "alg=none -> unsupported_alg")
hs = sign_jwt(base_claims(), alg="HS256", force_sig=b64url(b"x" * 64))
check(raises("unsupported_alg", lambda: cp_iap.verify_iap_jwt(hs, audience=AUD, jwks_provider=provider)),
      "alg=HS256 confusion -> unsupported_alg")

# wrong issuer -> bad_issuer
wiss = sign_jwt(base_claims(iss="https://evil.example/iap"))
check(raises("bad_issuer", lambda: cp_iap.verify_iap_jwt(wiss, audience=AUD, jwks_provider=provider)),
      "wrong issuer -> bad_issuer")

# wrong audience (token aud != configured expected aud) -> bad_audience
waud = sign_jwt(base_claims(aud="/projects/999/global/backendServices/000"))
check(raises("bad_audience", lambda: cp_iap.verify_iap_jwt(waud, audience=AUD, jwks_provider=provider)),
      "wrong audience -> bad_audience")

# expired -> expired
exp = sign_jwt(base_claims(exp=int(time.time()) - 3600, iat=int(time.time()) - 7200))
check(raises("expired", lambda: cp_iap.verify_iap_jwt(exp, audience=AUD, jwks_provider=provider)),
      "expired token -> expired")

# future iat -> not_yet_valid
fut = sign_jwt(base_claims(iat=int(time.time()) + 3600, exp=int(time.time()) + 7200))
check(raises("not_yet_valid", lambda: cp_iap.verify_iap_jwt(fut, audience=AUD, jwks_provider=provider)),
      "future iat -> not_yet_valid")

# no email claim -> no_email
noemail = sign_jwt({k: v for k, v in base_claims().items() if k != "email"})
check(raises("no_email", lambda: cp_iap.verify_iap_jwt(noemail, audience=AUD, jwks_provider=provider)),
      "missing email claim -> no_email")

# unknown kid (provider returns None) -> unknown_kid
unk = sign_jwt(base_claims(), kid="rotated-away")
check(raises("unknown_kid", lambda: cp_iap.verify_iap_jwt(unk, audience=AUD, jwks_provider=provider)),
      "unknown kid -> unknown_kid")

# malformed (not three segments) -> malformed_jwt
check(raises("malformed_jwt", lambda: cp_iap.verify_iap_jwt("a.b", audience=AUD, jwks_provider=provider)),
      "two-segment token -> malformed_jwt")

# iap_identity: missing header -> missing_iap_jwt
check(raises("missing_iap_jwt", lambda: cp_iap.iap_identity({}, env=ENV, jwks_provider=provider)),
      "no IAP header -> missing_iap_jwt")

# iap_identity: valid JWT but a DIFFERENT (non-owner) email -> wrong_email
other = sign_jwt(base_claims(email="intruder@evil.example"))
check(raises("wrong_email", lambda: cp_iap.iap_identity({"iap_assertion": other}, env=ENV, jwks_provider=provider)),
      "valid JWT for a non-owner email -> wrong_email")

# iap_identity: unconfigured surface (no owner email / no audience) -> iap_not_configured
check(raises("iap_not_configured",
             lambda: cp_iap.iap_identity({"iap_assertion": good}, env={}, jwks_provider=provider)),
      "unconfigured god surface -> iap_not_configured (fail closed)")

# surface predicates
check(cp_iap.god_surface_enabled(env={cp_iap.GOD_SURFACE_ENV: "1"}) is True,
      "god_surface_enabled('1') is True")
check(cp_iap.god_surface_enabled(env={}) is False,
      "god_surface_enabled(unset) is False")
check(cp_iap.is_god_route("GET", "/god/roster") and cp_iap.is_god_route("GET", "/god/logs"),
      "is_god_route matches /god/roster + /god/logs")
check(not cp_iap.is_god_route("POST", "/dispatch") and not cp_iap.is_god_route("GET", "/roster"),
      "is_god_route rejects non-god routes")

# ════════════════════════════════════════════════════════════════════════════════════════
# [B] END-TO-END — a real cp_server HTTPServer on the GOD SURFACE, over a socket.
# ════════════════════════════════════════════════════════════════════════════════════════
print()
print("== [B] END-TO-END — real cp_server god surface (socket) ==")

# seed two tenants' presence + registry so the god aggregate has cross-tenant data
TID_A = "aaaa0000aaaa0000aaaa0000aaaa0000"
TID_B = "bbbb1111bbbb1111bbbb1111bbbb1111"
FORGED = "cccc2222cccc2222cccc2222cccc2222"
priv_a, pub_a = cp_auth.generate_keypair()
priv_b, pub_b = cp_auth.generate_keypair()
cp_auth.register_key("haid:alice", pub_a, owner=False, team_id=TID_A, project="alice/webapp", home=HOME)
cp_auth.register_key("haid:bob", pub_b, owner=False, team_id=TID_B, project="bob/service", home=HOME)
now = time.time()
cp_presence.record_presence("haid:alice", project="alice/webapp", team_id=TID_A, handle="alice",
                            verdict="PROVEN", file="app.py", home=HOME, ts=now)
cp_presence.record_presence("haid:bob", project="bob/service", team_id=TID_B, handle="bob",
                            verdict="PROVEN", file="svc.go", home=HOME, ts=now)

# write the local IAP JWK set to a file and point the god surface at it (file:// urlopen)
jwks_path = os.path.join(HOME, "iap-jwks.json")
with open(jwks_path, "w") as fh:
    json.dump(JWKS, fh)
cp_iap.clear_jwks_cache()

os.environ[cp_iap.GOD_SURFACE_ENV] = "1"
os.environ[cp_iap.OWNER_EMAIL_ENV] = OWNER_EMAIL
os.environ[cp_iap.AUDIENCE_ENV] = AUD
os.environ[cp_iap.JWKS_URL_ENV] = "file://" + jwks_path

# wire the god routes into the seam (exactly as serve() does) + build the real handler class
cp_server.register_extended_routes(home=HOME)
handler_cls = cp_server._build_handler_class(HOME, True)
from http.server import HTTPServer
httpd = HTTPServer(("127.0.0.1", 0), handler_cls)
port = httpd.server_address[1]
srv = threading.Thread(target=httpd.serve_forever, daemon=True)
srv.start()

def get(path, headers=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    conn.request("GET", path, headers=headers or {})
    resp = conn.getresponse()
    body = resp.read().decode("utf-8")
    conn.close()
    try:
        parsed = json.loads(body) if body else {}
    except ValueError:
        parsed = {}
    return resp.status, parsed

try:
    HDR = cp_iap.IAP_JWT_HEADER
    valid = sign_jwt(base_claims())

    # valid owner IAP JWT -> 200 + the cross-tenant aggregate (both tenants online)
    st, body = get("/god/roster", {HDR: valid})
    team_ids = sorted({t["team_id"] for t in body.get("teams", [])})
    check(st == 200 and team_ids == sorted([TID_A, TID_B]),
          "E2E: valid owner IAP JWT -> 200 GET /god/roster, cross-tenant {A,B} (%s/%s)" % (st, team_ids))

    # /god/logs too
    st, body = get("/god/logs", {HDR: valid})
    check(st == 200 and "enrollments" in body, "E2E: valid owner IAP JWT -> 200 GET /god/logs")

    # forged signature -> 401 (never reaches the aggregate)
    st, body = get("/god/roster", {HDR: sign_jwt(base_claims(), priv=ATTACKER)})
    check(st == 401 and body.get("error") == "bad_signature",
          "E2E: forged IAP JWT -> 401 bad_signature (%s/%s)" % (st, body.get("error")))

    # ABSENT IAP header -> 401 missing_iap_jwt
    st, body = get("/god/roster")
    check(st == 401 and body.get("error") == "missing_iap_jwt",
          "E2E: absent IAP JWT -> 401 missing_iap_jwt (%s/%s)" % (st, body.get("error")))

    # valid JWT for a NON-owner email -> 401 wrong_email
    st, body = get("/god/roster", {HDR: sign_jwt(base_claims(email="intruder@evil.example"))})
    check(st == 401 and body.get("error") == "wrong_email",
          "E2E: non-owner email IAP JWT -> 401 wrong_email (%s/%s)" % (st, body.get("error")))

    # a NON-god route is a FLAT 404 on the god surface (surface minimized; owner grant is /god/* only)
    st, body = get("/dispatch", {HDR: valid})
    check(st == 404, "E2E: /dispatch on the god surface -> 404 (only /god/* + health served)")
    st, body = get("/roster", {HDR: valid})
    check(st == 404, "E2E: /roster on the god surface -> 404 (surface minimized)")

    # health probes answer pre-auth (no IAP JWT needed)
    st, _ = get("/healthz")
    check(st == 200, "E2E: /healthz answered pre-auth on the god surface (200)")

    # G4 under the IAP identity: a forged ?team_id is IGNORED — server-side enumeration only
    st, body = get("/god/roster?team_id=" + FORGED, {HDR: valid})
    ids = {t["team_id"] for t in body.get("teams", [])}
    check(st == 200 and FORGED not in ids and ids == {TID_A, TID_B},
          "E2E(G4): IAP owner + forged ?team_id -> aggregate ignores it, enumerates {A,B}")
finally:
    httpd.shutdown()
    httpd.server_close()

print()
print("cp-iap-god-bridge: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PYEOF
rc=$?
if [ "$rc" -eq 0 ]; then
  printf "\n\033[32mALL PROOFS HELD\033[0m — cp_iap verifies the IAP owner bridge + the god surface is minimized\n"
else
  printf "\n\033[31mFAILURES\033[0m — see above\n"
fi
exit $rc
