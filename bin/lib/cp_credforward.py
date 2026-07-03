#!/usr/bin/env python3
# cp_credforward.py — forward a SIGNED POST /team/cred WRITE from the least-privilege
# PUBLIC surface to the privileged GATED control-plane service.
#
# WHY THIS EXISTS (the least-privilege split, INV-6). The public surface
# (heimdall-cp-public) runs as heimdall-cp-public-run@ — DELIBERATELY least-privilege:
# datastore + secretAccessor on cp-enroll-token / the public PKI seed, and NOTHING else.
# It holds NO secretmanager.admin / secretmanager.create. But the BYO-credential store
# (HEIMDALL_TEAM_CRED_STORE=secretmanager) must CREATE + version a per-team Secret Manager
# secret on POST /team/cred (cp_team_creds.put_team_cred -> the SM create + add-version
# path), which needs secretmanager.admin. The public SA lacks it, so a DIRECT write RAISES
# -> the handler crashed -> HTTP 503 with an EMPTY body (the exact live break this closes).
#
# THE FIX (do NOT expand the public SA's blast radius). We do NOT grant the internet-facing
# public SA secretmanager.admin — that would let a public surface create arbitrary secrets,
# defeating the whole point of the split. Instead the SIGNED /team/cred request is FORWARDED
# to the GATED service (heimdall-control-plane, runtime SA heimdall-cp-runtime@ which HAS
# secretmanager.admin) over an AUTHENTICATED Cloud Run service-to-service call:
#   * the public SA fetches a Google-signed ID token for the gated service's URL from the
#     instance metadata server and sends it as Authorization: Bearer <id-token>;
#   * the gated service is --no-allow-unauthenticated, so Cloud Run IAM admits the call ONLY
#     because the public SA holds roles/run.invoker ON THE GATED SERVICE (a narrow, specific
#     grant — NOT secret-admin);
#   * the gated /team/cred handler re-runs the §3 signature chokepoint (the SAME Ed25519
#     signature over METHOD\nPATH\nBODY verifies byte-for-byte because the path + body are
#     forwarded unchanged), re-derives team_id SERVER-SIDE (INV-1), and does the privileged
#     Secret Manager write as heimdall-cp-runtime@.
# The cred only TRANSITS this surface (public->gated over TLS): it is never read back, never
# stored at rest here, never logged — INV-6's "no cred beyond transit" property holds.
#
# FAIL LOUD, NEVER LEAK. Every failure (gated URL unset, ID-token fetch failed, gated
# unreachable) returns a STRUCTURED (status, {error, detail}) tuple the handler surfaces as
# JSON — never a bare 503 with an empty body, and never the secret in any field or log line.
#
# stdlib-only (json/os/sys/urllib) + cp_team_creds (the SM-store selector ONLY). No credential
# is ever read back here; this module names NO cred-read / dispatch symbol.

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_team_creds  # the SM-store selector (_use_secret_manager) — the ONLY import; no cred read.

# The env the deploy sets on the PUBLIC service, pointing at the GATED service's base URL
# (e.g. https://heimdall-control-plane-<hash>-uc.a.run.app). Absent -> the forward is
# unconfigured and the handler fails loud (a structured 502), never a silent drop.
GATED_URL_ENV = "HEIMDALL_GATED_SERVICE_URL"

# The public-surface flag (mirrors cp_publicsurface.PUBLIC_SURFACE_ENV — read directly here so
# this module never imports cp_publicsurface, keeping the dependency one-way and cycle-free).
_PUBLIC_SURFACE_ENV = "HEIMDALL_PUBLIC_SURFACE"
_TRUTHY = {"1", "true", "yes", "on"}

# An EXPLICIT ID-token override (self-host / hermetic-test seam). When set, it is used AS the
# service-to-service bearer instead of the GCP metadata server (which only exists on Cloud Run).
# In production this is UNSET and the token comes fresh from the metadata server. It is a bearer
# for the gated call ONLY — it does NOT weaken the Ed25519 signature auth the gated handler
# independently re-verifies (that is the real cred-write authorization).
_ID_TOKEN_OVERRIDE_ENV = "HEIMDALL_FORWARD_ID_TOKEN"

# The GCP metadata endpoint that issues an ID token for a target audience (the gated URL).
_METADATA_IDENTITY_URL = (
    "http://metadata.google.internal/computeMetadata/v1/"
    "instance/service-accounts/default/identity")

# Network timeout (seconds) — bounded so a hung metadata / gated call fails loud, never hangs.
_TIMEOUT_SECONDS = 10

# The path the forward targets on the gated service (the SAME signed route).
_TEAM_CRED_PATH = "/team/cred"


class ForwardError(Exception):
    """A service-to-service forward failure. `detail` is a short, SECRET-FREE machine note (an
    exception type name / a reason code) — never the cred, never the ID token."""

    def __init__(self, detail):
        self.detail = detail
        super().__init__(detail)


def _truthy_env(name, env=None):
    e = env if env is not None else os.environ
    raw = e.get(name)
    if not raw:
        return False
    return raw.strip().lower() in _TRUTHY


def gated_service_url(env=None):
    """The GATED service base URL to forward to (HEIMDALL_GATED_SERVICE_URL), stripped of a
    trailing slash, or None when unset/blank."""
    e = env if env is not None else os.environ
    raw = e.get(GATED_URL_ENV)
    if not raw or not raw.strip():
        return None
    return raw.strip().rstrip("/")


def should_forward_cred_write(env=None):
    """True iff a POST /team/cred WRITE must be FORWARDED to the gated service instead of written
    in-process: this is the internet-facing PUBLIC surface (HEIMDALL_PUBLIC_SURFACE truthy) AND
    the cred store is Secret Manager (HEIMDALL_TEAM_CRED_STORE=secretmanager) — the exact case in
    which the least-privilege public SA lacks secretmanager.admin/create.

    False on the GATED service (the public flag is unset there), so it writes directly with its
    privileged runtime SA; False for a local/self-host store (no Secret Manager), so the running
    SA writes locally. Read fresh each call so a deploy can flip either signal without a restart."""
    if not _truthy_env(_PUBLIC_SURFACE_ENV, env):
        return False
    return bool(cp_team_creds._use_secret_manager())


def _fetch_id_token(audience):
    """A Google-signed ID token for `audience` (the gated service URL), the bearer for the Cloud
    Run service-to-service call. Uses the explicit override env when set (self-host / hermetic
    test), else the GCP instance metadata server. Raises ForwardError (secret-free detail) on any
    failure — the caller turns that into a structured 502, never a bare crash."""
    override = os.environ.get(_ID_TOKEN_OVERRIDE_ENV)
    if override and override.strip():
        return override.strip()
    url = _METADATA_IDENTITY_URL + "?" + urllib.parse.urlencode({"audience": audience})
    req = urllib.request.Request(url, headers={"Metadata-Flavor": "Google"})
    try:
        with urllib.request.urlopen(req, timeout=_TIMEOUT_SECONDS) as resp:
            token = resp.read().decode("utf-8").strip()
    except Exception as exc:  # noqa: BLE001 — metadata unreachable / non-200 -> fail loud.
        raise ForwardError("id_token_fetch_failed:" + type(exc).__name__) from exc
    if not token:
        raise ForwardError("id_token_empty")
    return token


def _post_to_gated(target, body_bytes, haid, signature, id_token):
    """POST the SIGNED cred body to the gated service's /team/cred with the caller's ORIGINAL HAID
    + signature (so the gated §3 chokepoint re-verifies) plus the Cloud Run ID token as the
    service-to-service bearer. Returns (status, body_dict): a gated HTTP error (401/422/...) is a
    REAL response passed through; only a transport failure raises ForwardError. The cred rides the
    body over TLS and is never logged here."""
    req = urllib.request.Request(target, data=body_bytes, method="POST")
    req.add_header("Content-Type", "application/json")
    if haid:
        req.add_header("X-Heimdall-HAID", str(haid))
    if signature:
        req.add_header("X-Heimdall-Signature", str(signature))
    req.add_header("Authorization", "Bearer " + id_token)
    try:
        with urllib.request.urlopen(req, timeout=_TIMEOUT_SECONDS) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return exc.code, (json.loads(raw) if raw else {})
        except (ValueError, TypeError):
            return exc.code, {}
    except Exception as exc:  # noqa: BLE001 — connection refused / DNS / timeout -> fail loud.
        raise ForwardError("gated_unreachable:" + type(exc).__name__) from exc


def forward_cred_write(request):
    """Forward a SIGNED POST /team/cred to the privileged gated service. `request` is the parsed
    request dict (haid + signature + raw body). Returns a (status, body) tuple the caller wraps in
    a Response:
      * the gated service's own (status, body) on a completed round-trip (200 stored / a 4xx from
        its re-verify + validation) — passed through verbatim (it never carries the secret);
      * a STRUCTURED (502, {error, detail}) when the forward ITSELF fails (unconfigured / auth /
        unreachable) — FAIL LOUD, never a bare 503, never the secret in any field.
    The cred TRANSITS only (public->gated over TLS): it is never stored here, read back, or logged."""
    url = gated_service_url()
    if not url:
        _log("cred forward UNCONFIGURED: %s is not set" % GATED_URL_ENV)
        return (502, {"error": "cred_forward_unconfigured",
                      "detail": "%s is not set on the public surface" % GATED_URL_ENV})
    haid = request.get("haid") if isinstance(request, dict) else None
    signature = request.get("signature") if isinstance(request, dict) else None
    body = request.get("body") if isinstance(request, dict) else None
    body_bytes = _as_bytes(body)
    try:
        id_token = _fetch_id_token(url)
    except ForwardError as exc:
        _log("cred forward AUTH failed: %s" % exc.detail)
        return (502, {"error": "cred_forward_auth_failed", "detail": exc.detail})
    try:
        status, resp_body = _post_to_gated(
            url + _TEAM_CRED_PATH, body_bytes, haid, signature, id_token)
    except ForwardError as exc:
        _log("cred forward UNREACHABLE: %s" % exc.detail)
        return (502, {"error": "cred_forward_unreachable", "detail": exc.detail})
    _log("cred forward ok: gated /team/cred -> %s" % status)
    return (status, resp_body if isinstance(resp_body, dict) else {})


def _as_bytes(body):
    """Coerce a request body to bytes for the forward — byte-identical to what the client signed
    (so the gated §3 chokepoint re-verifies the same canonical_message)."""
    if body is None:
        return b""
    if isinstance(body, (bytes, bytearray)):
        return bytes(body)
    return str(body).encode("utf-8")


def _log(msg):
    """One LOUD, SECRET-FREE diagnostic line to stderr (Cloud Run captures it). Never the cred,
    never the ID token — only the decision + a status/reason. Best-effort: a log fault never
    breaks the forward path."""
    try:
        sys.stderr.write("cp_credforward: %s\n" % msg)
        sys.stderr.flush()
    except Exception:  # noqa: BLE001 — diagnostic only; a write error must not break the forward.
        return
