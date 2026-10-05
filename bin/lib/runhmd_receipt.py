#!/usr/bin/env python3
"""runhmd_receipt -- issue and verify runhmd.receipt/1, the signed record of one verdict (RP3).

A receipt says "runhmd attacked THIS (a content hash) and concluded THAT (the verdict, each
finding as a digest), with THIS tool version, at THIS time", and carries an Ed25519 signature
over exactly that statement. It holds no file contents, no path, no counterexample text and no
secret, so the exact signed bytes can be published at any visibility. The contract (fields,
canonical form, signature construction) lives in docs/schemas/runhmd.receipt.v1.json, which
bin/lib/runhmd_schema.py enforces; this module is the code that writes and checks those bytes.

SIGNING. Ed25519 through the shipped cp_auth backend (cryptography, else PyNaCl) -- Ed25519 is
never re-implemented here. With neither backend installed signing and verifying FAIL CLOSED
(`crypto_unavailable`); there is no weaker fallback scheme.

KEY SOURCE (all documented in docs/RECEIPTS.md). The secret is a base64 32-byte seed in a file
that only its owner may read:
  1. $RUNHMD_RECEIPT_KEY_FILE
  2. $HEIMDALL_HOME/signing/runhmd-receipt.key   (HEIMDALL_HOME defaults to ~/.heimdall)
`hmd receipt keygen` writes that pair. A key file readable by other users is refused. There is no
environment variable that carries the secret itself (children inherit the environment), and
nothing is ever minted silently: no key means no receipt. This key is deliberately NOT the
minisign release key (release/heimdall-signing.pub): that one signs the auto-update channel and
must stay offline, while the receipt key signs attestations and will live where a receipt service
runs. A receipt key leaking can forge receipts; it cannot ship code.
TRUST. A verifier never takes the public key from the receipt (that would let a forger ship their
own key beside their forgery). It uses a pinned set, in this order: the explicit files it is given
(--pubkey), else $RUNHMD_RECEIPT_PUBKEY_FILE, else release/runhmd-receipt.pub in this plugin plus
$HEIMDALL_HOME/signing/runhmd-receipt.pub, whichever exist. A pub file holds one base64 32-byte
key per line (`#` comments allowed), several keys when rotating. An empty trust set is a
configuration error, never a pass.

CALL SITES.
  hmd attack --receipt   bin/lib/runhmd_attack.py -> receipt_for_verdict(), write_receipt(),
                         receipt_url()
  hmd prove              NOT wired here (RP2 is another workstream); its call site is
                         docs/RECEIPTS.md "Wiring hmd prove": after building its runhmd.prove/1
                         document it calls issue_receipt(...) with the document's own fields and
                         verdict_sha256=verdict_digest(document), then write_receipt() and
                         receipt_url(). Because RC2 requires a DENIED receipt to carry a finding,
                         a prove run denied for an unproven gate states that gate as a finding.

Library API:
  canonical(obj) -> bytes                   the canonical JSON bytes of a value
  Signer(seed_b64), load_signer(path=None), generate_key_files(dir), load_trust(paths=None)
  issue_receipt(**fields) -> bytes          sign + validate + self-verify; the receipt file bytes
  receipt_for_verdict(verdict_doc, ...)     the same, for a runhmd.verdict/1 document
  verify_bytes(raw, trust) -> dict          raises ReceiptError(kind, detail) unless it verifies
  store_dir(), write_receipt(), read_receipt(), receipt_url()
"""
from __future__ import annotations

import base64
import copy
import datetime
import functools
import hashlib
import json
import math
import os
import re
import stat
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
PLUGIN_DIR = os.path.dirname(os.path.dirname(HERE))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import runhmd_schema  # noqa: E402

SCHEMA_ID = "runhmd.receipt/1"
SIGN_PREFIX = b"runhmd.receipt/1\n"          # domain separation: this key signs nothing else, and nothing else's signature is a receipt's
DEFAULT_BASE_URL = "https://runhmd.dev"
MAX_RECEIPT_BYTES = 1024 * 1024
MAX_SAFE_INT = 2 ** 53                       # past this a JavaScript verifier cannot read an integer back exactly
KEY_FILE = "runhmd-receipt.key"
PUB_FILE = "runhmd-receipt.pub"
ANCHOR_FILE = os.path.join(PLUGIN_DIR, "release", "runhmd-receipt.pub")
_BASE_URL = re.compile(r"https://[^\s/?#@]+(/[^\s?#]*)?")


class ReceiptError(Exception):
    """A receipt could not be issued, found or verified. `kind` is a short machine code, `detail`
    says why; kinds in CONFIG_KINDS are the caller's setup or input, every other kind means the
    receipt itself is bad."""

    def __init__(self, kind, detail):
        super().__init__("%s: %s" % (kind, detail))
        self.kind = kind
        self.detail = detail


CONFIG_KINDS = frozenset({
    "no_signing_key", "insecure_key_file", "key_unusable", "key_exists", "crypto_unavailable",
    "no_trust", "bad_trust", "bad_schema", "bad_id", "bad_base_url", "not_found", "store_failed",
})


# ── canonical form ───────────────────────────────────────────────────────────────────────────


def _canon_number(value):
    if isinstance(value, int):
        if abs(value) >= MAX_SAFE_INT:
            raise ValueError("integer %d is outside the interoperable range" % value)
        return str(value)
    if not math.isfinite(value):
        raise ValueError("NaN and infinity have no canonical form")
    if value == int(value):
        if abs(value) >= MAX_SAFE_INT:
            raise ValueError("number %r is outside the interoperable range" % value)
        return str(int(value))                # 1.0 -> 1, -0.0 -> 0, 134.0 -> 134
    text = repr(value)
    if "e" in text or "E" in text:
        raise ValueError("number %r needs an exponent; the canonical form never uses one" % value)
    return text


def _canon(value):
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, (int, float)):
        return _canon_number(value)
    if isinstance(value, list):
        return "[" + ",".join(_canon(item) for item in value) + "]"
    if isinstance(value, dict):
        if not all(isinstance(key, str) for key in value):
            raise ValueError("object keys must be strings")
        members = sorted(value, key=lambda key: key.encode("utf-16-be"))
        return "{" + ",".join("%s:%s" % (json.dumps(key, ensure_ascii=False), _canon(value[key])) for key in members) + "}"
    raise ValueError("cannot canonicalise a %s" % type(value).__name__)


def canonical(obj):
    """The canonical bytes of a JSON value (the form is specified in docs/schemas/runhmd.receipt.v1.json):
    UTF-8, no insignificant whitespace, members sorted by UTF-16 code unit, minimal string escapes,
    integral numbers without a fraction, other numbers as the shortest round-trip decimal, never an
    exponent. Raises ValueError for a value with no unambiguous spelling (NaN, an exponent form, an
    unencodable string, an integer a JavaScript verifier would misread)."""
    return _canon(obj).encode("utf-8")


# ── keys ─────────────────────────────────────────────────────────────────────────────────────


@functools.lru_cache(maxsize=1)
def _auth():
    """cp_auth, imported on first use: it pulls in the whole crypto stack (about half a second) and
    nothing else in this module needs it."""
    import cp_auth
    if not cp_auth.crypto_available():
        raise ReceiptError("crypto_unavailable", "no Ed25519 backend for this python3: install `cryptography` or `pynacl`")
    return cp_auth


def key_id_of(public_b64):
    """The first 16 hex digits of the SHA-256 of the raw 32-byte public key."""
    return hashlib.sha256(base64.b64decode(public_b64)).hexdigest()[:16]


def _home():
    return os.environ.get("HEIMDALL_HOME") or os.path.join(os.path.expanduser("~"), ".heimdall")


class Signer:
    """An Ed25519 signing identity. The seed lives only inside this object: it is never written
    into a receipt, an error message or a repr."""

    def __init__(self, seed_b64):
        auth = _auth()
        try:
            self._seed, self.public_b64 = auth.load_signing_key(seed_b64)
        except auth.AuthError as exc:
            raise ReceiptError("key_unusable", "the signing key is not a base64 32-byte Ed25519 seed (%s)" % exc.reason) from exc
        self.key_id = key_id_of(self.public_b64)

    def sign(self, message):
        return _auth().sign(self._seed, message)

    def __repr__(self):
        return "<Signer key_id=%s>" % self.key_id


def signing_dir():
    """$HEIMDALL_HOME/signing: where `hmd receipt keygen` writes by default (SIGNING.md's directory)."""
    return os.path.join(_home(), "signing")


def default_key_path():
    return os.environ.get("RUNHMD_RECEIPT_KEY_FILE") or os.path.join(signing_dir(), KEY_FILE)


def load_signer(path=None):
    """The Signer for the key file at `path` (default: default_key_path()). Refuses a key file other
    users can read; there is no fallback to minting a key."""
    path = path or default_key_path()
    try:
        info = os.stat(path)
    except OSError as exc:
        raise ReceiptError("no_signing_key", "no receipt signing key at %s (%s): run `hmd receipt keygen`, or point "
                           "RUNHMD_RECEIPT_KEY_FILE at one" % (path, exc.strerror or exc)) from exc
    if not stat.S_ISREG(info.st_mode):
        raise ReceiptError("key_unusable", "%s is not a regular file" % path)
    if info.st_mode & 0o077:
        raise ReceiptError("insecure_key_file", "%s is accessible by other users (mode %o): run chmod 600 on it" % (path, stat.S_IMODE(info.st_mode)))
    try:
        with open(path, "r", encoding="ascii") as fh:
            seed = fh.read(4096).strip()
    except (OSError, UnicodeDecodeError) as exc:
        raise ReceiptError("key_unusable", "cannot read the signing key %s: %s" % (path, exc)) from exc
    return Signer(seed)


def generate_key_files(directory):
    """Write a fresh signing key (0600) and its public key (0644) into `directory`; returns
    (key_path, pub_path, key_id). Never overwrites an existing key."""
    auth = _auth()
    key_path, pub_path = os.path.join(directory, KEY_FILE), os.path.join(directory, PUB_FILE)
    private_b64, public_b64 = auth.generate_keypair()
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
        try:
            fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError as exc:
            raise ReceiptError("key_exists", "%s already exists: refusing to overwrite a signing key (move it away first)" % key_path) from exc
        with os.fdopen(fd, "w", encoding="ascii") as fh:
            fh.write(private_b64 + "\n")
        with open(pub_path, "w", encoding="ascii") as fh:
            fh.write("# runhmd receipt public key %s (pin this file as a trust anchor)\n%s\n" % (key_id_of(public_b64), public_b64))
        os.chmod(pub_path, 0o644)
    except OSError as exc:
        raise ReceiptError("store_failed", "cannot write the key files in %s: %s" % (directory, exc)) from exc
    return key_path, pub_path, key_id_of(public_b64)


def load_trust(paths=None):
    """{key_id: public_b64}: the pinned set a verifier trusts. Explicit `paths` replace
    $RUNHMD_RECEIPT_PUBKEY_FILE, which replaces the defaults (see the module docstring). A line
    that is not a canonical base64 32-byte key is a hard error, never skipped."""
    if paths is None:
        explicit = os.environ.get("RUNHMD_RECEIPT_PUBKEY_FILE")
        paths = [explicit] if explicit else [p for p in (ANCHOR_FILE, os.path.join(signing_dir(), PUB_FILE)) if os.path.isfile(p)]
    trust = {}
    for path in paths:
        try:
            with open(path, "r", encoding="ascii") as fh:
                lines = fh.read(65536).splitlines()
        except (OSError, UnicodeDecodeError) as exc:
            raise ReceiptError("bad_trust", "cannot read the public key file %s: %s" % (path, exc)) from exc
        for number, line in enumerate(lines, start=1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                raw = base64.b64decode(line, validate=True)
            except ValueError as exc:
                raise ReceiptError("bad_trust", "%s line %d is not base64" % (path, number)) from exc
            if len(raw) != 32 or base64.b64encode(raw).decode("ascii") != line:
                raise ReceiptError("bad_trust", "%s line %d is not a canonical base64 32-byte Ed25519 public key" % (path, number))
            trust[key_id_of(line)] = line
    return trust


# ── digests and the tool version ─────────────────────────────────────────────────────────────


def finding_digest(finding):
    """`sha256:<hex>` of a finding's canonical JSON, counterexample included: the receipt commits to
    text it does not carry."""
    return "sha256:" + hashlib.sha256(canonical(finding)).hexdigest()


def verdict_digest(doc):
    """sha256 hex of the canonical JSON of a verdict document with its receipt_url (if any) set to
    null: a receipt cannot hash the URL that points at it."""
    committed = dict(doc)
    if "receipt_url" in committed:
        committed["receipt_url"] = None
    return hashlib.sha256(canonical(committed)).hexdigest()


def tool_info():
    """{"name": "hmd", "version": <the version in .claude-plugin/plugin.json>}."""
    manifest = os.path.join(PLUGIN_DIR, ".claude-plugin", "plugin.json")
    try:
        with open(manifest, "r", encoding="utf-8") as fh:
            version = json.load(fh)["version"]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise ReceiptError("invalid", "cannot read the hmd version from %s: %s" % (manifest, exc)) from exc
    return {"name": "hmd", "version": str(version)}


# ── issue ────────────────────────────────────────────────────────────────────────────────────


def _utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def issue_receipt(*, signer, id, verdict, subject, attacks, findings, agent, cost_usd, duration_s, verdict_sha256,
                  gates=None, regression_tests=None, visibility="private", created_at=None, tool=None):
    """Sign and return the bytes of a receipt file: canonical JSON of the whole document plus one LF.

    `findings` are receipt findings (id, title, severity, category, digest); `verdict_sha256` is
    verdict_digest() of the attested document. The result is validated against runhmd.receipt/1 and
    verified with the signer's own public key before it is returned: a receipt that violates its
    contract, or that this code could not verify, is an error (ReceiptError "invalid"), never output."""
    body = copy.deepcopy({
        "schema": SCHEMA_ID, "id": id, "created_at": created_at or _utc_now(), "visibility": visibility,
        "verdict": verdict, "subject": subject, "attacks": attacks, "findings": findings, "agent": agent,
        "cost_usd": round(cost_usd, 4), "duration_s": round(duration_s, 2), "tool": tool or tool_info(),
        "verdict_sha256": verdict_sha256, "key_id": signer.key_id,
    })
    if gates is not None:
        body["gates"] = copy.deepcopy(gates)
    if regression_tests is not None:
        body["regression_tests"] = copy.deepcopy(regression_tests)
    try:
        doc = dict(body, signature=signer.sign(SIGN_PREFIX + canonical(body)))
        raw = canonical(doc) + b"\n"
    except ValueError as exc:
        raise ReceiptError("invalid", "the receipt cannot be written in canonical form: %s" % exc) from exc
    try:
        problems = runhmd_schema.validate(doc)
    except runhmd_schema.SchemaError as exc:
        raise ReceiptError("bad_schema", "the receipt schema is unusable: %s" % exc) from exc
    if problems:
        raise ReceiptError("invalid", "refusing to issue a receipt that violates runhmd.receipt/1: " + "; ".join(problems[:3]))
    try:
        verify_bytes(raw, {signer.key_id: signer.public_b64})
    except ReceiptError as exc:
        raise ReceiptError("invalid", "the receipt just issued does not verify (%s): refusing to hand it out" % exc) from exc
    return raw


def receipt_for_verdict(doc, *, tree_sha256, signer, visibility="private", created_at=None):
    """The receipt bytes for a runhmd.verdict/1 document: its id, verdict, attacks, agent, cost and
    duration, each finding reduced to id/title/severity/category plus a digest of the whole finding,
    the target as hashes (kind, git head, `tree_sha256`), and verdict_sha256 over the document."""
    try:
        problems = runhmd_schema.validate(doc)
    except runhmd_schema.SchemaError as exc:
        raise ReceiptError("bad_schema", "the verdict schema is unusable: %s" % exc) from exc
    if problems:
        raise ReceiptError("invalid", "refusing to attest a verdict document that violates its schema: " + "; ".join(problems[:3]))
    if doc.get("schema") != "runhmd.verdict/1":
        raise ReceiptError("invalid", "receipt_for_verdict attests runhmd.verdict/1 documents, not %r" % doc.get("schema"))
    fields = dict(
        signer=signer, id=doc["id"], verdict=doc["verdict"],
        subject={"kind": doc["target"]["kind"], "head_sha": doc["target"]["head_sha"], "tree_sha256": tree_sha256},
        attacks=doc["attacks"],
        findings=[{"id": f["id"], "title": f["title"], "severity": f["severity"], "category": f["category"],
                   "digest": finding_digest(f)} for f in doc["findings"]],
        agent=doc["agent"], cost_usd=doc["cost_usd"], duration_s=doc["duration_s"],
        verdict_sha256=verdict_digest(doc), visibility=visibility, created_at=created_at)
    for optional in ("gates", "regression_tests"):
        if optional in doc:
            fields[optional] = doc[optional]
    return issue_receipt(**fields)


# ── verify ───────────────────────────────────────────────────────────────────────────────────


def _no_constant(name):
    raise ValueError("%s is not allowed in a receipt" % name)


def _parse(raw):
    if not isinstance(raw, (bytes, bytearray)):
        raise ReceiptError("not_json", "receipt bytes expected")
    if len(raw) > MAX_RECEIPT_BYTES:
        raise ReceiptError("not_json", "larger than %d bytes" % MAX_RECEIPT_BYTES)
    try:
        return json.loads(bytes(raw).decode("utf-8"), parse_constant=_no_constant)
    except (UnicodeDecodeError, ValueError, RecursionError) as exc:
        raise ReceiptError("not_json", "not valid JSON: %s" % exc) from exc


def verify_bytes(raw, trust):
    """The receipt document in `raw`, once EVERYTHING holds: it is JSON, it is a runhmd.receipt/1
    document that satisfies its schema and invariants, `raw` is exactly its canonical form (plus an
    optional final LF), it names a key in the pinned `trust` set, and the signature over
    SIGN_PREFIX + canonical(document without signature) is that key's, in canonical base64.
    Raises ReceiptError for anything else, and for nothing but ReceiptError."""
    if not trust:
        raise ReceiptError("no_trust", "no trusted receipt public key is configured: pass --pubkey FILE, set "
                           "RUNHMD_RECEIPT_PUBKEY_FILE, or run `hmd receipt keygen`")
    doc = _parse(raw)
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA_ID:
        raise ReceiptError("schema", "not a %s document" % SCHEMA_ID)
    try:
        problems = runhmd_schema.validate(doc)
    except runhmd_schema.SchemaError as exc:
        raise ReceiptError("bad_schema", "the receipt schema is unusable: %s" % exc) from exc
    if problems:
        raise ReceiptError("schema", "; ".join(problems[:5]))
    try:
        expected = canonical(doc)
    except ValueError as exc:
        raise ReceiptError("not_canonical", "the document has no canonical form: %s" % exc) from exc
    if bytes(raw) not in (expected, expected + b"\n"):
        raise ReceiptError("not_canonical", "the bytes are not the canonical form of the document they spell; the signature covers "
                           "only that form")
    public = trust.get(doc["key_id"])
    if public is None:
        raise ReceiptError("unknown_key", "signed by key %s, which is not in the pinned trust set (%s)" % (doc["key_id"], ", ".join(sorted(trust))))
    signature = doc["signature"]
    try:
        spelled_canonically = base64.b64encode(base64.b64decode(signature, validate=True)).decode("ascii") == signature
    except ValueError:
        spelled_canonically = False
    if not spelled_canonically:
        raise ReceiptError("bad_signature", "the signature is not canonical base64")
    body = {key: value for key, value in doc.items() if key != "signature"}
    if not _auth().verify_raw(public, SIGN_PREFIX + canonical(body), signature):
        raise ReceiptError("bad_signature", "the signature does not match the receipt for key %s: it was changed after it was signed, "
                           "or signed by another key" % doc["key_id"])
    return doc


# ── store and URL ────────────────────────────────────────────────────────────────────────────


@functools.lru_cache(maxsize=1)
def _id_re():
    """The receipt id grammar, read from the verdict schema: one definition shared by verdict ids,
    receipt ids, file names and URLs."""
    try:
        return re.compile(runhmd_schema.load_schema()["$defs"]["id"]["pattern"])
    except (OSError, ValueError, KeyError, runhmd_schema.SchemaError) as exc:
        raise ReceiptError("bad_schema", "cannot read the id pattern from the verdict schema: %s" % exc) from exc


def check_id(receipt_id):
    """`receipt_id` itself when it is a safe token (it becomes a file name and a URL path segment)."""
    if not isinstance(receipt_id, str) or not _id_re().fullmatch(receipt_id):
        raise ReceiptError("bad_id", "%r is not a receipt id" % (receipt_id,))
    return receipt_id


def store_dir():
    """Where receipts are kept: $RUNHMD_RECEIPT_DIR, else $HEIMDALL_HOME/runhmd/receipts."""
    return os.environ.get("RUNHMD_RECEIPT_DIR") or os.path.join(_home(), "runhmd", "receipts")


def write_receipt(store, receipt_id, raw):
    """Atomically store `raw` as <store>/<id>.json (owner-only); returns the path."""
    check_id(receipt_id)
    path = os.path.join(store, receipt_id + ".json")
    try:
        os.makedirs(store, mode=0o700, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".%s." % receipt_id, suffix=".tmp", dir=store)
        try:
            with os.fdopen(fd, "wb") as fh:
                fh.write(raw)
            os.replace(tmp, path)
        except OSError:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
    except OSError as exc:
        raise ReceiptError("store_failed", "cannot store the receipt in %s: %s" % (store, exc)) from exc
    return path


def read_receipt(store, receipt_id):
    """The stored bytes of receipt `receipt_id` (at most MAX_RECEIPT_BYTES + 1: verify rejects an oversize one)."""
    check_id(receipt_id)
    path = os.path.join(store, receipt_id + ".json")
    try:
        with open(path, "rb") as fh:
            return fh.read(MAX_RECEIPT_BYTES + 1)
    except FileNotFoundError as exc:
        raise ReceiptError("not_found", "no receipt %s in %s" % (receipt_id, store)) from exc
    except OSError as exc:
        raise ReceiptError("store_failed", "cannot read %s: %s" % (path, exc)) from exc


def load_verified(store, receipt_id, trust):
    """(document, exact stored bytes) of stored receipt `receipt_id`, verified. The receipt's own id
    must be the id it is filed under: otherwise one valid receipt copied to another receipt's file
    name would be served, and look genuine, at the wrong URL."""
    raw = read_receipt(store, receipt_id)
    doc = verify_bytes(raw, trust)
    if doc["id"] != receipt_id:
        raise ReceiptError("id_mismatch", "filed as %s but it is receipt %s" % (receipt_id, doc["id"]))
    return doc, raw


def receipt_url(receipt_id, base=None):
    """https://<base>/r/<id>; <base> is `base`, else $RUNHMD_RECEIPT_BASE_URL, else https://runhmd.dev.
    A base that is not an https URL without query or fragment is refused."""
    check_id(receipt_id)
    chosen = base or os.environ.get("RUNHMD_RECEIPT_BASE_URL") or DEFAULT_BASE_URL
    chosen = chosen[:-1] if chosen.endswith("/") else chosen
    if not _BASE_URL.fullmatch(chosen):
        raise ReceiptError("bad_base_url", "%r is not an https URL base (no query, no fragment, no credentials)" % chosen)
    return "%s/r/%s" % (chosen, receipt_id)
