#!/usr/bin/env python3
# cp_auth.py — piece (a) of the Heimdall control plane: PKI AUTH (§3).
#
# DESIGN DOSSIER §3 (authoritative). HAID is the identity basis; KEYS are the gap
# this module closes. heimdall-haid derives a deterministic, stable identity NAME
# per checkout but has NO crypto material today. cp_auth BINDS an Ed25519 keypair to
# each HAID: an instance generates a keypair on register, sends the public key, the
# server stores {haid -> pubkey, status} extending agents.json's registry. Every
# instance<->server message is SIGNED with the instance private key; the server
# VERIFIES against the registered pubkey. Unsigned / bad-sig / unknown / revoked
# HAID -> rejected (the server maps to HTTP 401 + an audit auth_fail row).
#
# PKI secures the CHANNEL; it is NECESSARY, NOT SUFFICIENT. The allowlist (§1)
# controls the BLAST RADIUS. Both, independently.
#
# REVOCATION reuses HAID's enforcement primitive VERBATIM (§3): a revoked HAID's
# signed requests are refused. We consult the agents.json registry status (the same
# field `heimdall-haid revoke` sets, the same `check` gates on) — no new revocation
# machinery. A revoked OR absent HAID fails verification.
#
# THE OIDC SEAM (architect, do NOT build — §3): all identity verification sits
# behind ONE chokepoint, verify_identity(request) -> Identity. Internal uses the
# HAID-signature path below; the external path later swaps in an OIDC verifier
# returning the SAME Identity shape. Single seam = no scatter. It is a named
# interface point, not built now.
#
# GRACEFUL-DEGRADE (the dossier's explicit instruction): the crypto dep
# (`cryptography` Ed25519, else PyNaCl) is imported behind a guard. If NEITHER is
# importable, the module still LOADS (no hard crash at import) — crypto_available()
# returns False and sign/verify return a clear, structured degraded result instead
# of raising. A self-hosted box missing the dep gets a clear message, not a stack
# trace.
#
# THE INTERFACE pieces (b)-(f) BIND to (stable; they import, never edit):
#   crypto_available()                    — True iff an Ed25519 backend loaded.
#   generate_keypair()                    — (private_b64, public_b64) for register.
#   register_key(haid, public_b64, ...)   — bind a pubkey to a HAID in the registry.
#   sign(private_b64, message_bytes)      — instance-side signature (base64).
#   verify(haid, message_bytes, sig_b64)  — server-side verify against the registry.
#   verify_identity(request)              — THE chokepoint -> Identity | AuthError.
#   Identity / AuthError                  — the returned identity shape + failure type.
#
# stdlib-only core (base64/json/os/subprocess) + an OPTIONAL crypto backend.

from __future__ import annotations

import base64
import hashlib
import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import cp_state  # the pluggable persistence backend (Wave 1). The HAID->pubkey key
               # registry's atomic keyed JSON read/write runs THROUGH a StateBackend
               # (get_backend) — exactly like cp_approval — so the same tmp+os.replace
               # put / json read becomes durable on Cloud Run (Firestore backend) WITHOUT
               # changing this module. The local backend is byte-identical to the prior
               # keys.json-to-HEIMDALL_HOME path, and it owns heimdall_home() resolution
               # (the registry no longer needs issue_queue / direct json IO here).

# ── crypto backend (Ed25519 via `cryptography`, else PyNaCl, else degrade) ─────
#
# Imported behind a guard so the MODULE LOADS even with neither installed. The
# dossier is explicit: degrade gracefully with a clear message, do NOT hard-crash
# the import. _BACKEND names which path is live; _BACKEND=None ⇒ degraded mode.

_BACKEND = None
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey as _CrPriv,
        Ed25519PublicKey as _CrPub,
    )
    from cryptography.hazmat.primitives import serialization as _cr_ser
    _BACKEND = "cryptography"
except Exception:  # noqa: BLE001 — any import failure -> try the next backend.
    try:
        import nacl.signing as _nacl_signing
        _BACKEND = "pynacl"
    except Exception:  # noqa: BLE001 — neither backend -> degraded mode, NO crash.
        _BACKEND = None


# ── the auth failure type + the Identity shape (the chokepoint contract — §3) ──


class AuthError(Exception):
    """Raised by verify_identity() when authentication fails. The server maps this to
    HTTP 401 + an audit auth_fail row. `reason` is a short machine code
    (missing_signature | bad_signature | unknown_haid | revoked | malformed |
    crypto_unavailable); `detail` is a short, secret-free note."""

    def __init__(self, reason, detail=""):
        self.reason = reason
        self.detail = detail
        super().__init__("%s: %s" % (reason, detail) if detail else reason)


class Identity:
    """The verified caller identity returned by the auth chokepoint (§3). The SAME
    shape the future OIDC verifier returns, so external auth drops in without
    touching callers. Carries:
      haid   — the verified HAID (a deterministic identity name).
      owner  — True iff this HAID is flagged owner:true in the registry (gate
               override authority, §7).
      org    — the org id seam (None internal-first; the per-org-isolation hook
               §11 sets this later without touching callers)."""

    def __init__(self, haid, *, owner=False, org=None):
        self.haid = haid
        self.owner = bool(owner)
        self.org = org

    def to_dict(self):
        return {"haid": self.haid, "owner": self.owner, "org": self.org}


def crypto_available():
    """True iff an Ed25519 backend loaded. When False, the PKI runs in DEGRADED mode:
    sign/verify return a structured degraded result and verify_identity raises
    AuthError('crypto_unavailable') instead of silently allowing — fail CLOSED."""
    return _BACKEND is not None


def backend_name():
    """The live backend name ('cryptography' | 'pynacl' | None) for status/CLI."""
    return _BACKEND


# ── keypair generation + low-level sign/verify (the crypto primitives — §3) ────


def generate_keypair():
    """Generate an Ed25519 keypair. Returns (private_b64, public_b64) — base64 of the
    raw 32-byte seed and the raw 32-byte public key. The instance keeps private_b64
    locally (never sent); public_b64 is registered with the server on `register`.

    Raises AuthError('crypto_unavailable') in degraded mode — key generation cannot
    be faked, so we fail CLOSED with a clear message rather than emit a bogus key."""
    if not crypto_available():
        raise AuthError("crypto_unavailable",
                        "install `cryptography` or `pynacl` to enable PKI")
    if _BACKEND == "cryptography":
        priv = _CrPriv.generate()
        raw_priv = priv.private_bytes(
            encoding=_cr_ser.Encoding.Raw,
            format=_cr_ser.PrivateFormat.Raw,
            encryption_algorithm=_cr_ser.NoEncryption(),
        )
        raw_pub = priv.public_key().public_bytes(
            encoding=_cr_ser.Encoding.Raw,
            format=_cr_ser.PublicFormat.Raw,
        )
    else:  # pynacl
        sk = _nacl_signing.SigningKey.generate()
        raw_priv = bytes(sk)
        raw_pub = bytes(sk.verify_key)
    return _b64(raw_priv), _b64(raw_pub)


# ── the server's signing identity from the Secret-Manager seed (the GAP fix) ───
#
# THE BUG THIS CLOSES. The control plane must sign/verify with a STABLE identity
# across every Cloud Run instance + cold-start. generate_keypair() mints a FRESH
# random key per call, so each instance ran a DIFFERENT key universe with an EMPTY
# registry → PKI identity was broken on the deploy target. The deploy injects the
# Ed25519 PRIVATE SEED from Secret Manager as env HEIMDALL_CP_PKI_KEY
# (deploy/cloud-run/README.md §2/§3, `--set-secrets="HEIMDALL_CP_PKI_KEY=cp-pki-key:latest"`).
# load_signing_key() reads THAT seed and DETERMINISTICALLY derives the SAME keypair
# every instance/cold-start — a reproducible server identity rooted in the secret.

# The env var the deploy's --set-secrets populates (deploy/cloud-run/README.md §2).
PKI_KEY_ENV = "HEIMDALL_CP_PKI_KEY"


def cloud_profile():
    """True iff we are running in the Cloud Run / durable deploy profile, where a
    missing PKI seed is a HARD failure (never silently mint a fresh key). Detected via
    TWO independent signals, either of which means "deployed, not a laptop":

      * K_SERVICE — Cloud Run sets this automatically on every instance/job (the
        platform's own marker that we are inside a Cloud Run container).
      * HEIMDALL_STATE_BACKEND=firestore — the documented deploy env-var
        (deploy/cloud-run/README.md §3 --set-env-vars): selecting the durable Firestore
        backend is the operator declaring "this is the durable deployment".

    Locally (neither signal set) cloud_profile() is False and the dev mint path
    (generate_keypair via `identity`) is preserved verbatim. The signal is documented
    here so the fail-closed boundary is unambiguous."""
    if os.environ.get("K_SERVICE"):
        return True
    backend = (os.environ.get("HEIMDALL_STATE_BACKEND") or "").strip().lower()
    return backend == "firestore"


def load_signing_key(seed_b64=None):
    """Derive the server's DETERMINISTIC Ed25519 signing identity from the PKI seed
    (HEIMDALL_CP_PKI_KEY, base64 of a 32-byte private seed). Returns
    (private_b64, public_b64) — the SAME pair every call/instance/cold-start for a given
    seed, because the keypair is a pure function of the seed (Ed25519's public key is
    derived from the private seed). This is what makes the server identity stable across
    Cloud Run instances: the registry HAID→pubkey binding rebuilds identically on every
    cold start.

    `seed_b64` overrides the env (for tests / explicit wiring); otherwise the value of
    HEIMDALL_CP_PKI_KEY is used.

    FAIL-CLOSED in the cloud profile (cloud_profile() True): if the seed is ABSENT or
    INVALID we RAISE AuthError — we NEVER fall back to minting a fresh random key (that
    is the exact bug: a per-instance key universe). Locally (not cloud profile) an absent
    seed raises the SAME AuthError too — there is no silent mint here; the dev mint path
    stays in `generate_keypair()`/`identity`, and a caller that explicitly asks to load a
    seed must supply one. Raises AuthError('crypto_unavailable') in degraded mode (a key
    cannot be faked — fail CLOSED with a clear message)."""
    if not crypto_available():
        raise AuthError("crypto_unavailable",
                        "install `cryptography` or `pynacl` to load the PKI signing key")
    raw_seed = seed_b64 if seed_b64 is not None else os.environ.get(PKI_KEY_ENV)
    if not raw_seed:
        # Absent seed. In the cloud profile this is a HARD refusal — the server MUST NOT
        # boot with an unstable identity. The message names the env + the fix.
        if cloud_profile():
            raise AuthError(
                "pki_key_absent",
                "%s is not set in the cloud profile — refusing to mint a fresh per-instance"
                " key (set --set-secrets=%s=cp-pki-key:latest)" % (PKI_KEY_ENV, PKI_KEY_ENV))
        raise AuthError(
            "pki_key_absent",
            "%s is not set — no seed to derive the signing key from" % PKI_KEY_ENV)
    try:
        seed = _unb64(raw_seed)
    except Exception as exc:  # noqa: BLE001 — undecodable base64 is an invalid seed.
        raise AuthError("pki_key_invalid",
                        "%s is not valid base64" % PKI_KEY_ENV) from exc
    if len(seed) != 32:
        # Ed25519 private seeds are exactly 32 bytes; anything else cannot derive a key.
        raise AuthError(
            "pki_key_invalid",
            "%s must decode to a 32-byte Ed25519 seed (got %d bytes)" % (
                PKI_KEY_ENV, len(seed)))
    try:
        if _BACKEND == "cryptography":
            priv = _CrPriv.from_private_bytes(seed)
            raw_pub = priv.public_key().public_bytes(
                encoding=_cr_ser.Encoding.Raw,
                format=_cr_ser.PublicFormat.Raw,
            )
        else:  # pynacl — derive the verify key from the same seed.
            sk = _nacl_signing.SigningKey(seed)
            raw_pub = bytes(sk.verify_key)
    except AuthError:
        raise
    except Exception as exc:  # noqa: BLE001 — a malformed seed that decoded but won't load.
        raise AuthError("pki_key_invalid",
                        "%s did not derive a valid Ed25519 key" % PKI_KEY_ENV) from exc
    # private_b64 is the seed itself (the same shape generate_keypair returns), public_b64
    # the deterministically-derived public key — identical for identical seeds.
    return _b64(seed), _b64(raw_pub)


# The env override for the server's own HAID (the identity the seeded pubkey binds to).
# Cloud Run has no `.planning/ledger` checkout for `heimdall-haid current` to read, so the
# deploy can pin the server HAID explicitly; absent it, we derive via the CLI (local/dev).
SERVER_HAID_ENV = "HEIMDALL_CP_SERVER_HAID"


def server_haid(home=None):
    """The HAID the server's deterministic signing identity binds to. Resolution order:
      1. HEIMDALL_CP_SERVER_HAID (explicit pin — the deploy sets this since a Cloud Run
         image carries no `.planning/ledger` checkout for the CLI to read).
      2. `heimdall-haid current` — the deterministic per-checkout identity NAME (local/dev).
    Returns the HAID string, or None when neither is available (no CLI + no pin) — the
    caller then skips seeded registration rather than guessing an identity."""
    pinned = os.environ.get(SERVER_HAID_ENV)
    if pinned:
        return pinned.strip() or None
    cli = os.path.join(os.path.dirname(_HERE), "heimdall-haid")
    if not os.path.isfile(cli):
        return None
    try:
        proc = subprocess.run(
            [cli, "current"], capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    haid = (proc.stdout or "").strip()
    return haid or None


def ensure_server_identity(home=None, *, owner=True):
    """ESTABLISH the server's deterministic signing identity at boot (the GAP fix wired).
    When HEIMDALL_CP_PKI_KEY is present, derive the seeded keypair (load_signing_key) and
    register its public key under the server HAID, so the SAME HAID→pubkey binding rebuilds
    on EVERY cold start (no per-instance key universe). `owner=True` flags the server's own
    identity as owner (it drives owner-scoped scheduler ticks / gate decisions, §6/§7).

    Returns a dict the boot path can surface (NO secret in it — never the private seed):
      {"seeded": bool, "haid": <server haid|None>, "public_key": <b64|None>,
       "registered": bool, "reason": <str>}.

    Behavior by profile:
      * Seed present  → derive + register the seeded pubkey deterministically (seeded=True).
        If no server HAID resolves, seeded=True but registered=False (reason names it) —
        the keypair is still deterministic; only the binding could not be written.
      * Cloud profile + seed ABSENT/INVALID → load_signing_key RAISES (fail-closed); this
        function lets that AuthError propagate so the boot refuses an unstable identity.
      * Local profile + seed absent → seeded=False (the dev `identity` mint path stays the
        source of registrations; boot does not mint here). A clear, non-fatal reason."""
    if not crypto_available():
        return {"seeded": False, "haid": None, "public_key": None,
                "registered": False, "reason": "crypto_unavailable"}
    has_seed = bool(os.environ.get(PKI_KEY_ENV))
    if not has_seed and not cloud_profile():
        # Local dev, no seed: do NOT mint here — the `identity` CLI owns dev registration.
        return {"seeded": False, "haid": None, "public_key": None,
                "registered": False, "reason": "no_seed_local_profile"}
    # Seed present, OR cloud profile (where an absent/invalid seed MUST fail-closed):
    # load_signing_key raises AuthError in the cloud profile when the seed is missing —
    # we let it propagate (the boot refuses rather than running an unstable identity).
    _priv, pub = load_signing_key()
    haid = server_haid(home)
    if not haid:
        return {"seeded": True, "haid": None, "public_key": pub,
                "registered": False, "reason": "no_server_haid"}
    stored = register_key(haid, pub, owner=owner, home=home)
    return {"seeded": True, "haid": haid, "public_key": pub,
            "registered": bool(stored),
            "reason": "registered" if stored else "registry_write_failed"}


def sign(private_b64, message):
    """Sign `message` (bytes or str) with the base64 Ed25519 private seed. Returns the
    base64 signature. Raises AuthError('crypto_unavailable') in degraded mode (a
    signature cannot be faked) and AuthError('malformed') on a bad key/message."""
    if not crypto_available():
        raise AuthError("crypto_unavailable", "no Ed25519 backend")
    raw = _as_bytes(message)
    try:
        seed = _unb64(private_b64)
        if _BACKEND == "cryptography":
            priv = _CrPriv.from_private_bytes(seed)
            sig = priv.sign(raw)
        else:  # pynacl
            sk = _nacl_signing.SigningKey(seed)
            sig = sk.sign(raw).signature
    except AuthError:
        raise
    except Exception as exc:  # noqa: BLE001 — a bad key/seed is a malformed input.
        raise AuthError("malformed", "cannot sign with provided key") from exc
    return _b64(sig)


def verify_raw(public_b64, message, sig_b64):
    """Verify `sig_b64` over `message` against the base64 Ed25519 PUBLIC key. Returns
    True on a good signature, False on a bad one. Raises AuthError('crypto_unavailable')
    in degraded mode (we never silently pass a verify we cannot perform — fail CLOSED).

    A malformed key/sig returns False (not an exception) — an attacker-supplied bad
    blob is a failed verify, not a server error."""
    if not crypto_available():
        raise AuthError("crypto_unavailable", "no Ed25519 backend")
    raw = _as_bytes(message)
    try:
        pub = _unb64(public_b64)
        sig = _unb64(sig_b64)
    except Exception:  # noqa: BLE001 — undecodable input -> failed verify.
        return False
    try:
        if _BACKEND == "cryptography":
            _CrPub.from_public_bytes(pub).verify(sig, raw)
            return True
        # pynacl
        vk = _nacl_signing.VerifyKey(pub)
        vk.verify(raw, sig)
        return True
    except Exception:  # noqa: BLE001 — InvalidSignature / bad key length -> False.
        return False


# ── the HAID -> pubkey registry (extends agents.json's model — §3) ─────────────
#
# Stored at ${HEIMDALL_HOME}/control-plane/auth/keys.json:
#   {"version":"1.0.0","keys":{ "<haid>": {"pubkey":"<b64>","owner":bool} } }
# Status/revocation is NOT duplicated here — it is read from heimdall-haid's
# agents.json registry (the single source of truth), so `heimdall-haid revoke`
# governs PKI verification with no extra machinery (§3 revocation reuse).


# The store-relative paths (relative to ${HEIMDALL_HOME}/control-plane/, the StateBackend
# rel namespace): the auth dir is "auth/", the registry is "auth/keys.json". The backend
# owns the home root + makedirs + the atomic tmp+os.replace / indent=2 byte shape; auth_dir
# and keys_path stay the public absolute-path accessors (now sourced from backend.path(),
# so they remain byte-identical to the prior layout on the local backend).
_AUTH_REL = "auth"
_KEYS_REL = os.path.join(_AUTH_REL, "keys.json")


def _backend(home=None):
    """The StateBackend for the key registry (HEIMDALL_STATE_BACKEND, default local).
    `home` pins the store root exactly as every registry accessor's `home=` arg always
    has — exactly like cp_approval._backend."""
    return cp_state.get_backend(home=home)


def auth_dir(home=None):
    """The auth store dir: ${HEIMDALL_HOME}/control-plane/auth/ (the backend's absolute
    path for the auth rel-dir — unchanged on the local backend)."""
    return _backend(home).path(_AUTH_REL)


def keys_path(home=None):
    """The on-disk path of the HAID->pubkey registry: control-plane/auth/keys.json (the
    backend's absolute path — byte-identical to the prior layout on the local backend)."""
    return _backend(home).path(_KEYS_REL)


def _empty_registry():
    return {"version": "1.0.0", "keys": {}}


def _load_keys(home=None):
    """Read the HAID->pubkey registry, or an empty registry when absent/corrupt/off-schema.
    Routed THROUGH the StateBackend (Wave 1): get_record returns the same single keyed JSON
    record (or None when absent/corrupt) the registry has always read — byte-identical on
    the local backend, Firestore-durable when HEIMDALL_STATE_BACKEND=firestore."""
    obj = _backend(home).get_record(_KEYS_REL)
    if isinstance(obj, dict) and isinstance(obj.get("keys"), dict):
        return obj
    return _empty_registry()


def _store_keys(reg, home=None):
    """Atomic write of the key registry, mirroring cp_approval's discipline. Returns True
    on success, False on an IO failure.

    Routed THROUGH the StateBackend (Wave 1): put_record writes the same atomic
    tmp+os.replace, json.dump(sort_keys=True, indent=2) keyed record the registry has always
    written — so keys.json is byte-identical on the local backend, and the SAME atomic put
    becomes Cloud-Run-durable (pubkeys survive scale-to-zero) when the Firestore backend is
    selected."""
    return _backend(home).put_record(_KEYS_REL, reg)


# ── TEAM IDENTITY (multi-tenant team presence — the partition handle) ───────────
#
# A TEAM is a self-generated high-entropy `team_secret` scoped to a repo. Its NON-SECRET
# handle is team_id = a one-way hash of the secret. ALL presence is partitioned by team_id;
# the registry binds each member's HAID to their team_id. The raw secret is NEVER stored —
# it is consumed once to COMPUTE the key and discarded, so a server/DB compromise leaks
# team_ids (partition handles) but never the secrets. There is NO secret comparison anywhere
# on the server (the "verifier" doubles as the partition key) — no stored secret, no oracle.
#
# THE DERIVATION CONTRACT (client + site + server MUST agree byte-for-byte):
#   team_id = sha256(b"heimdall-team\x00" + team_secret.encode("utf-8")).hexdigest()[:32]
# The domain-separation prefix "heimdall-team\0" stops this hash aliasing any other
# sha256(secret) use in the system; the 32-hex (128-bit) truncation matches the codebase's
# _HASH_HEX and is filesystem-/Firestore-safe as a path segment (hex -> no "_", never the
# "__" run FirestoreBackend reserves).

# The domain-separation prefix (a NUL-terminated tag). MUST match the client + team.html.
_TEAM_ID_PREFIX = b"heimdall-team\x00"

# The team_id hex width (128 bits). Mirrors cp_ratelimit/cp_nonce _HASH_HEX = 32.
_TEAM_ID_HEX = 32

# A configured DEFAULT-TEAM secret (back-compat). When set, the single-tenant deploy becomes
# one team whose secret is this value; absent it, the legacy HEIMDALL_ENROLL_TOKEN is used as
# the default-team secret (the live deploy keeps working as one default team — §migration).
DEFAULT_TEAM_SECRET_ENV = "HEIMDALL_DEFAULT_TEAM_SECRET"

# The legacy global bootstrap token (cp_enroll.ENROLL_TOKEN_ENV). Referenced by literal here
# (cp_auth must not import cp_enroll — cp_enroll imports cp_auth) so the default team derives
# from the SAME secret the live single-tenant deploy already configures.
_LEGACY_ENROLL_TOKEN_ENV = "HEIMDALL_ENROLL_TOKEN"


def derive_team_id(team_secret):
    """The NON-SECRET partition handle for a team_secret:
        sha256(b"heimdall-team\\x00" + team_secret).hexdigest()[:32].
    Pure — no IO, no store. Returns None for an empty/None secret (no team). The raw secret
    is hashed here and never returned/stored/logged — the caller discards it after this call.
    The client (bin/heimdall-presence) and the web (team.html) compute the IDENTICAL value,
    so a member writes/reads exactly their own partition."""
    if not team_secret:
        return None
    raw = _TEAM_ID_PREFIX + str(team_secret).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:_TEAM_ID_HEX]


def default_team_id():
    """The reserved DEFAULT team_id for back-compat (§migration): derive_team_id of
    HEIMDALL_DEFAULT_TEAM_SECRET when set, else of the legacy HEIMDALL_ENROLL_TOKEN. None
    when NEITHER is configured (no default team — enroll then fails closed unless an explicit
    team_secret is presented). Read fresh from the env each call so a deploy can flip it
    without a code change. A registry binding with no team_id field reads as THIS id, so the
    existing single-tenant deploy keeps working as one default team."""
    secret = os.environ.get(DEFAULT_TEAM_SECRET_ENV)
    if secret and secret.strip():
        return derive_team_id(secret.strip())
    tok = os.environ.get(_LEGACY_ENROLL_TOKEN_ENV)
    if tok and tok.strip():
        return derive_team_id(tok.strip())
    return None


def register_key(haid, public_b64, *, owner=False, team_id=None, project=None, home=None):
    """Bind an Ed25519 public key to a HAID (the `register` step, §3). Upserts the
    {haid -> {pubkey, owner, team_id?, project?}} entry. Returns True on a stored write. The
    instance generated the keypair and sends ONLY public_b64 — the private seed never leaves
    the instance. `owner=True` flags a distinguished gate-override identity (§7).

    `team_id`/`project` are ADDITIVE (multi-tenant teams): when supplied they are stored as
    the member's team partition handle + active repo; when None they are omitted (a binding
    with no team_id reads as default_team_id() — additive, non-destructive, no migration). The
    raw team_secret is NEVER passed here — only its derived, non-secret team_id."""
    if not haid or not public_b64:
        return False
    reg = _load_keys(home)
    entry = {"pubkey": public_b64, "owner": bool(owner)}
    if team_id is not None:
        entry["team_id"] = team_id
    if project is not None:
        entry["project"] = project
    reg["keys"][haid] = entry
    return _store_keys(reg, home)


def registered_pubkey(haid, home=None):
    """The base64 pubkey bound to a HAID, or None if unregistered."""
    entry = _load_keys(home)["keys"].get(haid)
    if isinstance(entry, dict):
        return entry.get("pubkey")
    return None


def registered_team_field(haid, home=None):
    """The RAW team_id field on a HAID's binding, or None when the binding lacks it (or the
    haid is unregistered). Unlike registered_team(), this does NOT fall back to the default
    team — it is the literal stored value, used to detect an idempotent vs a team-switch
    re-enroll (cp_enroll)."""
    entry = _load_keys(home)["keys"].get(haid)
    if isinstance(entry, dict):
        return entry.get("team_id")
    return None


def registered_team(haid, home=None):
    """The team_id a HAID belongs to — the load-bearing isolation key for presence (§4/§5).
    Resolution: the binding's team_id field when present, else default_team_id() (a binding
    lacking team_id, OR an unregistered haid, reads as the default team — back-compat). NEVER
    taken from a request body; a beat/read scopes to THIS value, so a member can only ever
    write/read their own team."""
    tid = registered_team_field(haid, home=home)
    if tid:
        return tid
    return default_team_id()


def team_member_count(team_id, home=None):
    """The number of registry bindings belonging to `team_id` (the per-team member cap input,
    cp_enroll). Counts a binding's resolved team (its team_id field, else default_team_id), so
    legacy no-team_id bindings count toward the default team exactly as they are read. Firestore-
    safe (tolerant get_record-based registry read, never backend.path()). 0 for a never-seen
    team (no members yet) — the net-new-team signal the team-create caps key on."""
    keys = _load_keys(home).get("keys")
    if not isinstance(keys, dict) or not team_id:
        return 0
    default = default_team_id()
    n = 0
    for entry in keys.values():
        if not isinstance(entry, dict):
            continue
        tid = entry.get("team_id") or default
        if tid == team_id:
            n += 1
    return n


def is_owner(haid, home=None):
    """True iff the HAID is flagged owner:true in the key registry (§7 override)."""
    entry = _load_keys(home)["keys"].get(haid)
    return bool(entry.get("owner")) if isinstance(entry, dict) else False


def owner_haids(home=None):
    """The SORTED HAIDs flagged owner:true in the key registry — the identities the §6
    scheduler tick fires schedules AS. Read THROUGH the StateBackend (_load_keys ->
    get_record), NEVER through keys_path()/open(): the registry is a keyed JSON record,
    and a non-filesystem backend (FirestoreBackend) REFUSES path() by design, so any
    caller that enumerated owners by opening keys.json on disk crashed under
    HEIMDALL_STATE_BACKEND=firestore (the live per-minute tick incident). This accessor is
    firestore-safe — it uses the SAME tolerant registry read every other reader here uses,
    so an absent/garbled registry yields [] (a server with no owners simply has no
    autonomous tick principal, which is honest), and it returns the identical sorted set on
    the local and firestore backends. cp_boot.run_tick enumerates owners through HERE."""
    keys = _load_keys(home).get("keys")
    if not isinstance(keys, dict):
        return []
    return sorted(
        haid for haid, entry in keys.items()
        if isinstance(entry, dict) and entry.get("owner")
    )


# ── revocation: REUSE heimdall-haid's agents.json status (§3, no new machinery) ─


def _haid_status(haid):
    """Read a HAID's registry status via `heimdall-haid check` — the SAME enforcement
    primitive the local ledger uses. Returns 'active' (check exit 0), 'revoked'/
    'absent' (check exit 3), or 'unknown' when the CLI is unavailable. We shell to
    the existing CLI rather than re-parse agents.json so revocation semantics stay
    single-sourced (§3): `heimdall-haid revoke` governs PKI directly."""
    cli = os.path.join(os.path.dirname(_HERE), "heimdall-haid")
    if not os.path.isfile(cli):
        return "unknown"
    try:
        proc = subprocess.run(
            [cli, "check", haid],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    if proc.returncode == 0:
        return "active"
    # check exits 3 for revoked OR absent; the stderr distinguishes them.
    if "revoked" in (proc.stderr or "").lower():
        return "revoked"
    return "absent"


def verify(haid, message, sig_b64, *, home=None, enforce_revocation=True):
    """SERVER-SIDE verify of a signed instance message (§3). Raises AuthError on:
      * unknown_haid     — the HAID has no registered pubkey,
      * revoked          — the HAID is revoked in agents.json (reused primitive),
      * bad_signature    — the signature does not verify against the registered key,
      * crypto_unavailable — degraded mode (fail CLOSED, never silently pass).
    Returns True on a good, non-revoked, registered, signed message.

    enforce_revocation=False skips the agents.json status check (used when the HAID
    registry CLI is intentionally out of scope, e.g. a pure-crypto unit test)."""
    if not crypto_available():
        raise AuthError("crypto_unavailable", "no Ed25519 backend")
    pub = registered_pubkey(haid, home)
    if not pub:
        raise AuthError("unknown_haid", "no registered key for HAID")
    if enforce_revocation:
        status = _haid_status(haid)
        if status == "revoked":
            raise AuthError("revoked", "HAID is revoked")
        # 'absent'/'unknown' do NOT hard-fail here: the key registry is the PKI
        # source of membership; agents.json governs revocation. A HAID with a
        # registered key but no agents.json row is still a registered instance.
    if not verify_raw(pub, message, sig_b64):
        raise AuthError("bad_signature", "signature did not verify")
    return True


# ── THE auth chokepoint (verify_identity — the single seam, §3/§11) ────────────


def canonical_message(method, path, body):
    """The canonical bytes an instance SIGNS and the server VERIFIES for a request:
    METHOD\\nPATH\\n<body-bytes>. Deterministic + unambiguous so the signed payload
    is exactly the request (no field can be swapped post-signature). Pure.

    `path` is the FULL request path AS TRANSMITTED — INCLUDING any ?query string
    (e.g. "/jobs?job_id=job-abc"). The query is therefore part of the signed bytes
    and is tamper-evident: a request whose query was altered after signing will not
    verify. For a query-LESS path (POST /dispatch, POST /jobs, approvals) the bytes
    are byte-identical to the historical form (the path simply has no "?query"), so
    those signatures are UNAFFECTED — the change is regression-safe.

    WHY the query lives here (the GFE/Cloud-Run fix): a signed read used to carry its
    job_id in the GET request BODY, but Google's GFE / Cloud Run ingress REJECTS a
    GET-with-a-body as malformed (HTTP 400, never reaching the container). Moving the
    job_id to a query param (GET /jobs?job_id=<id> with an EMPTY body) is GFE-safe, and
    signing the full path-with-query keeps the read authenticated + tamper-evident. The
    client and the server MUST canonicalize the SAME full path-with-query or every
    signed request 401s — this is the single source of truth for both sides. The server
    verifies over self.path (the full path incl. query) while ROUTING on the
    query-stripped path; the client signs the identical full path-with-query it sends."""
    head = ("%s\n%s\n" % ((method or "").upper(), path or "")).encode("utf-8")
    return head + _as_bytes(body)


def verify_identity(request, *, home=None, enforce_revocation=True):
    """THE single auth chokepoint (§3/§11). `request` is a dict the server assembles:
        {"method","path","body","haid","signature"}
    where `body` is the raw request body (bytes/str), `haid` the claimed identity,
    `signature` the base64 Ed25519 sig over canonical_message(method,path,body).

    Returns an Identity on success. Raises AuthError (-> server 401 + audit
    auth_fail) on missing_signature / unknown_haid / revoked / bad_signature /
    crypto_unavailable. This is the ONE place identity is decided — the future OIDC
    verifier swaps in HERE, returning the same Identity, without touching callers."""
    if not isinstance(request, dict):
        raise AuthError("malformed", "request must be an object")
    haid = request.get("haid")
    sig = request.get("signature")
    if not haid:
        raise AuthError("missing_signature", "no HAID on request")
    if not sig:
        raise AuthError("missing_signature", "no signature on request")
    msg = canonical_message(
        request.get("method"), request.get("path"), request.get("body"),
    )
    verify(haid, msg, sig, home=home, enforce_revocation=enforce_revocation)
    return Identity(haid, owner=is_owner(haid, home=home))


# ── small encoding helpers ─────────────────────────────────────────────────────


def _as_bytes(message):
    if message is None:
        return b""
    if isinstance(message, bytes):
        return message
    return str(message).encode("utf-8")


def _b64(raw):
    return base64.b64encode(raw).decode("ascii")


def _unb64(s):
    return base64.b64decode(s.encode("ascii") if isinstance(s, str) else s)
