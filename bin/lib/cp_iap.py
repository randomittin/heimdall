#!/usr/bin/env python3
# cp_iap.py — THE BROWSER→GOD AUTH BRIDGE. Google Cloud IAP JWT verification, honored
# as an OWNER-EQUIVALENT identity FOR THE /god/* ROUTES ONLY.
#
# WHY THIS EXISTS (the core problem it solves). /god/* is the owner-only cross-tenant
# aggregate (cp_god). On the wire it is gated by TWO things a BROWSER cannot do: GCP IAM
# (Cloud Run --no-allow-unauthenticated) AND the §3 Ed25519 owner signature
# (_require_owner over verify_identity). RJ wants the god wall on the web behind Google
# IAP (google.runheimdall.dev-style, only he can reach). IAP authenticates his Google
# identity at the edge and forwards a SIGNED assertion header `X-Goog-IAP-JWT-Assertion`
# on every request. This module is the APP-LAYER verifier of that assertion: a VALID IAP
# JWT whose verified `email` == the configured owner email is accepted as an
# owner-equivalent Identity — a NEW owner-auth path ALONGSIDE the existing Ed25519 owner,
# scoped to /god/* only.
#
# HOW THIS DOES NOT WEAKEN INV-GOD (G1-G4 stay intact).
#   * G1/G2 — /god/* is NEVER in cp_publicsurface.PUBLIC_ROUTES, so the internet-facing
#     PUBLIC service 404s it BEFORE auth for every anonymous caller and every team secret.
#     This module changes NOTHING there; the IAP path is honored ONLY on the god-serving
#     surface (god_surface_enabled(), env HEIMDALL_GOD_SURFACE=1) which is a DISTINCT deploy
#     behind IAP, never the public surface.
#   * The IAP owner path is honored ONLY for the /god/* routes (is_god_route) AND ONLY when
#     god_surface_enabled(). On any other route the IAP header is never consulted — a browser
#     that reached /dispatch on the god surface still falls to §3 Ed25519 (which it cannot
#     produce) and gets a 401. So the IAP grant confers NO authority beyond /god/*.
#   * G3 — the owner gate (cp_approval._require_owner) is unchanged. This path mints
#     Identity(owner=True) ONLY after the JWT signature verifies AND `email` == the
#     configured owner email. A missing / malformed / bad-signature / wrong-issuer /
#     wrong-audience / expired / wrong-email / unconfigured JWT → AuthError → 401. FAIL-CLOSED.
#   * G4 — cp_god still enumerates its partition set SERVER-SIDE; the IAP path supplies only
#     an Identity, never a team_id, so INV-1 inside the aggregate is untouched.
#
# THE VERIFICATION IS REAL (not a trust-the-edge shim). We independently verify the
# Google-signed ES256 JWT in the app layer — signature (against Google's published JWK set),
# issuer, audience, expiry, and the email claim — so a misconfigured or bypassed IAP layer
# cannot grant owner. The audience + owner email are operator config (env), never hardcoded.
#
# stdlib (base64/json/os/time/threading/urllib) + the cryptography EC backend cp_auth
# already ships (Ed25519 lives in the same package; ES256 is ECDSA-P256 in the same lib).
# Graceful-degrade: if the EC backend is unavailable the module still LOADS and every verify
# raises AuthError('crypto_unavailable') — fail CLOSED, never silently pass.

from __future__ import annotations

import base64
import json
import os
import sys
import threading
import time
import urllib.request

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_auth  # REUSE the Identity shape + AuthError (the SAME contract verify_identity
               # returns, so cp_server/cp_approval treat an IAP owner exactly like a signed
               # owner: Identity(owner=True) passes _require_owner, AuthError -> 401).

# ── the EC (ES256) crypto backend, behind a guard (mirrors cp_auth's degrade discipline) ──
_EC_OK = False
try:
    from cryptography.hazmat.primitives.asymmetric import ec as _ec
    from cryptography.hazmat.primitives.asymmetric.utils import (
        encode_dss_signature as _encode_dss,
    )
    from cryptography.hazmat.primitives import hashes as _hashes
    from cryptography.exceptions import InvalidSignature as _InvalidSignature
    _EC_OK = True
except Exception:  # noqa: BLE001 — no EC backend -> degraded mode, NO import crash.
    _EC_OK = False


# ── IAP protocol constants (Google-published; NOT operator-tunable) ─────────────────────
IAP_JWT_HEADER = "X-Goog-IAP-JWT-Assertion"   # the header IAP forwards on every request.
IAP_ISSUER = "https://cloud.google.com/iap"    # the required `iss` claim (exact match).
DEFAULT_JWKS_URL = "https://www.gstatic.com/iap/verify/public_key-jwk"  # IAP's EC JWK set.

# ── operator config env vars (the god-serving surface sets these; NEVER the public one) ──
GOD_SURFACE_ENV = "HEIMDALL_GOD_SURFACE"       # "1" ON the IAP-gated god surface, unset else.
OWNER_EMAIL_ENV = "HEIMDALL_GOD_OWNER_EMAIL"   # the ONE Google identity accepted as owner.
AUDIENCE_ENV = "HEIMDALL_GOD_IAP_AUDIENCE"     # the exact IAP JWT `aud` for this backend.
# The JWKS source. Defaults to Google's gstatic URL. Overridable so a self-host / air-gapped
# god surface can point at a pinned/mirrored key set (file:// is honored by urlopen); it only
# changes WHERE the trusted EC keys come from, never HOW the JWT is verified.
JWKS_URL_ENV = "HEIMDALL_GOD_IAP_JWKS_URL"

_TRUTHY = {"1", "true", "yes", "on"}

# The god routes this bridge is allowed to authenticate. MUST equal cp_god's registered
# routes; kept here (not imported) so cp_server can gate the surface without importing cp_god.
GOD_ROUTES = frozenset({("GET", "/god/roster"), ("GET", "/god/logs")})

# ── JWKS cache (Google rotates the IAP signing keys; refetch on a TTL / on an unknown kid) ──
_JWKS_TTL_SECONDS = 3600
_jwks_lock = threading.Lock()
_jwks_cache = {"fetched_at": 0.0, "keys": {}, "url": None}


def god_surface_enabled(env=None):
    """True iff HEIMDALL_GOD_SURFACE is set truthy — this instance is the IAP-gated
    god-serving surface (serves ONLY /god/* + health, and honors the IAP owner path). Unset
    / "" / "0" / "false" -> False (the gated IAM service + the public surface, both unchanged).
    `env` defaults to os.environ so a test can probe without mutating the process."""
    e = env if env is not None else os.environ
    raw = e.get(GOD_SURFACE_ENV)
    if not raw:
        return False
    return raw.strip().lower() in _TRUTHY


def is_god_route(method, path):
    """True iff (METHOD, path) is a /god/* route this bridge authenticates. `path` MUST be
    the query-STRIPPED route path (cp_server matches on route_path). Exact — nothing else is
    ever eligible for the IAP owner grant."""
    return ((method or "").upper(), path or "") in GOD_ROUTES


def owner_email(env=None):
    """The ONE Google identity accepted as owner on the god surface (HEIMDALL_GOD_OWNER_EMAIL),
    normalized to a stripped lowercase string. None when unset — in which case iap_identity
    fails CLOSED (no email can ever match None), so an unconfigured surface grants nothing."""
    e = env if env is not None else os.environ
    raw = e.get(OWNER_EMAIL_ENV)
    if not raw or not raw.strip():
        return None
    return raw.strip().lower()


def iap_audience(env=None):
    """The exact IAP JWT `aud` this backend must see (HEIMDALL_GOD_IAP_AUDIENCE). None when
    unset — iap_identity then fails CLOSED (an unset audience cannot be matched, so we refuse
    rather than skip the audience check, which is the classic JWT-confusion foot-gun)."""
    e = env if env is not None else os.environ
    raw = e.get(AUDIENCE_ENV)
    if not raw or not raw.strip():
        return None
    return raw.strip()


def crypto_available():
    """True iff the EC (ES256) backend loaded. When False every verify raises
    AuthError('crypto_unavailable') — fail CLOSED, never silently accept an unverifiable JWT."""
    return _EC_OK


# ── base64url + JWT segment helpers ─────────────────────────────────────────────────────


def _b64url_decode(seg):
    """Decode a base64url JWT segment (no padding). Raises ValueError on undecodable input."""
    if isinstance(seg, bytes):
        seg = seg.decode("ascii")
    pad = "=" * (-len(seg) % 4)
    return base64.urlsafe_b64decode(seg + pad)


def _split_jwt(token):
    """Split a compact JWS into (header_b64, payload_b64, sig_b64, signing_input_bytes).
    Raises cp_auth.AuthError('malformed_jwt') on anything that is not exactly three
    dot-separated non-empty segments."""
    if not token or not isinstance(token, str):
        raise cp_auth.AuthError("malformed_jwt", "assertion is not a compact JWT string")
    parts = token.split(".")
    if len(parts) != 3 or not all(parts):
        raise cp_auth.AuthError("malformed_jwt", "a JWT has exactly three non-empty segments")
    header_b64, payload_b64, sig_b64 = parts
    signing_input = (header_b64 + "." + payload_b64).encode("ascii")
    return header_b64, payload_b64, sig_b64, signing_input


# ── JWKS fetch + EC public-key construction ─────────────────────────────────────────────


def _jwks_url(env=None):
    e = env if env is not None else os.environ
    raw = e.get(JWKS_URL_ENV)
    if raw and raw.strip():
        return raw.strip()
    return DEFAULT_JWKS_URL


def clear_jwks_cache():
    """Drop the cached IAP JWK set (used by tests + after a suspected rotation)."""
    with _jwks_lock:
        _jwks_cache["fetched_at"] = 0.0
        _jwks_cache["keys"] = {}
        _jwks_cache["url"] = None


def _fetch_jwks_raw(url):
    """Fetch + parse the IAP JWK set from `url` into {kid: jwk-dict}. file:// and https:// are
    both honored (urlopen), so a self-host god surface can pin a mirrored key set. Raises
    cp_auth.AuthError('jwks_unavailable') on a network / parse failure (fail CLOSED — an
    unfetchable key set denies, it does not pass)."""
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:  # noqa: S310 — operator-set URL.
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:  # noqa: BLE001 — any fetch/parse failure -> deny.
        raise cp_auth.AuthError("jwks_unavailable",
                                "could not fetch the IAP JWK set") from exc
    keys = {}
    for jwk in (data.get("keys") if isinstance(data, dict) else None) or []:
        if isinstance(jwk, dict) and jwk.get("kid"):
            keys[str(jwk["kid"])] = jwk
    if not keys:
        raise cp_auth.AuthError("jwks_unavailable", "the IAP JWK set carried no usable keys")
    return keys


def _default_jwks_provider(kid, *, env=None):
    """Resolve a JWK by `kid` from the cached IAP key set, refetching when the cache is stale
    (TTL), empty, from a different URL, OR does not know this kid (a rotation just happened).
    Returns the JWK dict or None (unknown kid even after a fresh fetch)."""
    url = _jwks_url(env)
    now = time.time()
    with _jwks_lock:
        fresh = (
            _jwks_cache["url"] == url
            and _jwks_cache["keys"]
            and (now - _jwks_cache["fetched_at"]) < _JWKS_TTL_SECONDS
        )
        if fresh and kid in _jwks_cache["keys"]:
            return _jwks_cache["keys"][kid]
    # Stale / unknown-kid / different-url -> refetch outside the lock, then re-store.
    keys = _fetch_jwks_raw(url)
    with _jwks_lock:
        _jwks_cache["keys"] = keys
        _jwks_cache["fetched_at"] = now
        _jwks_cache["url"] = url
    return keys.get(kid)


def _public_key_from_jwk(jwk):
    """Build an EC public key from an IAP JWK ({kty:EC, crv:P-256, x, y}). Raises
    cp_auth.AuthError('unknown_kid') on a non-EC / malformed / non-P-256 JWK (we accept only
    the ES256 curve IAP signs with — never a caller-chosen curve)."""
    if not isinstance(jwk, dict) or jwk.get("kty") != "EC" or jwk.get("crv") != "P-256":
        raise cp_auth.AuthError("unknown_kid", "IAP JWK is not an EC P-256 key")
    try:
        x = int.from_bytes(_b64url_decode(jwk["x"]), "big")
        y = int.from_bytes(_b64url_decode(jwk["y"]), "big")
        numbers = _ec.EllipticCurvePublicNumbers(x, y, _ec.SECP256R1())
        return numbers.public_key()
    except cp_auth.AuthError:
        raise
    except Exception as exc:  # noqa: BLE001 — a malformed x/y is an unusable key.
        raise cp_auth.AuthError("unknown_kid", "IAP JWK did not yield an EC key") from exc


def verify_iap_jwt(token, *, audience, now=None, jwks_provider=None, leeway=60, env=None):
    """Verify a Google IAP assertion JWT and return its claims dict, or raise cp_auth.AuthError.
    The FULL verification (each an independent DENY, fail-closed):
      1. crypto_available()          — else 'crypto_unavailable' (never pass an unverifiable JWT).
      2. three-segment compact JWT   — else 'malformed_jwt'.
      3. header alg == 'ES256'       — else 'unsupported_alg' (blocks alg=none + RS/HS confusion;
         we NEVER honor a caller-declared algorithm other than the ES256 IAP signs with).
      4. header carries a kid        — else 'malformed_jwt'; the kid resolves a JWK -> 'unknown_kid'.
      5. ECDSA-P256/SHA-256 verify   — the raw 64-byte (r||s) IAP signature is re-encoded to DER
         and checked over header.payload against the JWK's EC public key -> else 'bad_signature'.
      6. iss == IAP_ISSUER           — else 'bad_issuer'.
      7. aud == `audience`           — else 'bad_audience' (`audience` is required; a None/empty
         expected audience is itself a config error the caller rejects BEFORE calling here).
      8. exp present, now <= exp+leeway   — else 'expired'.
      9. iat present, now >= iat-leeway   — else 'not_yet_valid' (a token from the future is bad).
     10. email present               — else 'no_email' (the identity claim we authorize on).
    `jwks_provider(kid)` overrides the default gstatic-fetch (tests / offline self-host). Pure
    of any owner-email decision — that is iap_identity's job; this returns the verified claims."""
    if not crypto_available():
        raise cp_auth.AuthError("crypto_unavailable",
                                "no EC backend to verify the IAP JWT (install cryptography)")
    if not audience:
        # Defensive: the audience must be a concrete string. iap_identity already refuses an
        # unconfigured audience; guarding here too means verify_iap_jwt can never skip aud.
        raise cp_auth.AuthError("bad_audience", "no expected audience configured")
    now = time.time() if now is None else now

    header_b64, payload_b64, sig_b64, signing_input = _split_jwt(token)
    try:
        header = json.loads(_b64url_decode(header_b64))
        claims = json.loads(_b64url_decode(payload_b64))
    except Exception as exc:  # noqa: BLE001 — undecodable header/payload.
        raise cp_auth.AuthError("malformed_jwt", "JWT header/payload is not valid JSON") from exc
    if not isinstance(header, dict) or not isinstance(claims, dict):
        raise cp_auth.AuthError("malformed_jwt", "JWT header/payload must be objects")

    if header.get("alg") != "ES256":
        raise cp_auth.AuthError("unsupported_alg", "IAP JWTs are ES256; refusing %r"
                                % header.get("alg"))
    kid = header.get("kid")
    if not kid:
        raise cp_auth.AuthError("malformed_jwt", "JWT header carries no kid")

    provider = jwks_provider or (lambda k: _default_jwks_provider(k, env=env))
    jwk = provider(str(kid))
    if not jwk:
        raise cp_auth.AuthError("unknown_kid", "no IAP signing key for kid=%s" % kid)
    pubkey = _public_key_from_jwk(jwk)

    try:
        raw_sig = _b64url_decode(sig_b64)
    except Exception as exc:  # noqa: BLE001 — undecodable signature segment.
        raise cp_auth.AuthError("bad_signature", "signature segment is not base64url") from exc
    if len(raw_sig) != 64:
        # ES256 is a fixed 64-byte (r||s) JOSE signature; any other length is not an ES256 sig.
        raise cp_auth.AuthError("bad_signature", "ES256 signature must be 64 bytes")
    r = int.from_bytes(raw_sig[:32], "big")
    s = int.from_bytes(raw_sig[32:], "big")
    try:
        pubkey.verify(_encode_dss(r, s), signing_input, _ec.ECDSA(_hashes.SHA256()))
    except _InvalidSignature as exc:
        raise cp_auth.AuthError("bad_signature", "IAP JWT signature did not verify") from exc
    except Exception as exc:  # noqa: BLE001 — any verify fault is a failed verify, not a pass.
        raise cp_auth.AuthError("bad_signature", "IAP JWT signature check failed") from exc

    if claims.get("iss") != IAP_ISSUER:
        raise cp_auth.AuthError("bad_issuer", "iss is not the IAP issuer")
    if claims.get("aud") != audience:
        raise cp_auth.AuthError("bad_audience", "aud does not match the configured audience")

    exp = claims.get("exp")
    if not isinstance(exp, (int, float)) or isinstance(exp, bool):
        raise cp_auth.AuthError("expired", "JWT carries no numeric exp")
    if now > float(exp) + leeway:
        raise cp_auth.AuthError("expired", "JWT is past its exp")
    iat = claims.get("iat")
    if not isinstance(iat, (int, float)) or isinstance(iat, bool):
        raise cp_auth.AuthError("not_yet_valid", "JWT carries no numeric iat")
    if now < float(iat) - leeway:
        raise cp_auth.AuthError("not_yet_valid", "JWT iat is in the future")

    email = claims.get("email")
    if not email or not isinstance(email, str):
        raise cp_auth.AuthError("no_email", "JWT carries no email claim")
    return claims


def iap_identity(request, *, home=None, now=None, env=None, jwks_provider=None):
    """THE bridge entry point: turn a request's X-Goog-IAP-JWT-Assertion into an OWNER Identity
    for /god/* — or raise cp_auth.AuthError (cp_server maps it to 401). Steps:
      1. the request carries an IAP assertion header (cp_server lifts it to
         request['iap_assertion']) — else 'missing_iap_jwt'.
      2. the surface is CONFIGURED: HEIMDALL_GOD_IAP_AUDIENCE + HEIMDALL_GOD_OWNER_EMAIL are
         both set — else 'iap_not_configured' (fail CLOSED: an unconfigured god surface grants
         nothing rather than skipping a check).
      3. verify_iap_jwt(...) — full signature + iss + aud + exp verification (above).
      4. the verified email == the configured owner email (case-insensitive) — else
         'wrong_email' (a valid IAP JWT for ANY other Google identity is refused).
    On success returns cp_auth.Identity('iap:<email>', owner=True) — the SAME shape a signed
    owner yields, so _require_owner passes it exactly like the Ed25519 owner. `home` is accepted
    for handler-signature symmetry (this path consults no store). The minted haid is a synthetic
    'iap:<email>' used only for audit attribution; god routes are READ-ONLY and derive team
    scope server-side, so the haid value gates nothing."""
    if not isinstance(request, dict):
        raise cp_auth.AuthError("malformed", "request must be an object")
    assertion = request.get("iap_assertion")
    if not assertion:
        raise cp_auth.AuthError("missing_iap_jwt", "no X-Goog-IAP-JWT-Assertion header")
    audience = iap_audience(env)
    expected_owner = owner_email(env)
    if not audience or not expected_owner:
        raise cp_auth.AuthError(
            "iap_not_configured",
            "set %s and %s on the god surface" % (AUDIENCE_ENV, OWNER_EMAIL_ENV))
    claims = verify_iap_jwt(
        assertion, audience=audience, now=now, jwks_provider=jwks_provider, env=env)
    email = claims.get("email", "").strip().lower()
    if email != expected_owner:
        # A valid IAP JWT — but not the owner's Google identity. Refuse (owner is a single email).
        raise cp_auth.AuthError("wrong_email", "IAP identity is not the configured owner")
    return cp_auth.Identity("iap:" + email, owner=True)
