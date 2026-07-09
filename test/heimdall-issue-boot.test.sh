#!/usr/bin/env bash
# heimdall-issue-boot.test.sh — THE /issues BOOT-WIRING FALSIFIER (Wave 3, wire-boot task).
#
# WHAT THIS GATES. cp_server ships ONLY the built-in /dispatch entry; every other capability plugs
# its routes in via cp_server.register_route, and SOMETHING has to call each piece's register()
# against the live server at boot — that something is cp_boot.boot() (the §10 assembly seam). The
# Wave-2 cp_issue_ingest module EXPOSES register() but does NOT register itself; this wave wires
# routes["issues"] = [cp_issue_ingest.register(home=home)] into boot() so POST /issues is LIVE.
#
# THIS suite proves the boot wiring is LOAD-BEARING — exactly the cp-wired #6(c) discipline
# ("a seam route that pre-boot 404s now 200s post-boot"), specialized to /issues:
#
#   1. BOOT WIRES THE ROUTE — cp_boot.boot() registers ("POST", "/issues"); the BootResult carries
#      an "issues" key. Pre-boot, cp_server exposes only /dispatch, so the route does not exist.
#   2. SIGNED POST /issues -> 200 INGESTED (route LIVE, wired to cp_issue_ingest) — a signed batch
#      of one valid issue_v1 lands in the isolated issues/ partition and reads back. LOAD-BEARING:
#      delete the boot wiring line and a SIGNED POST /issues 404s here -> RED.
#   3. UNSIGNED POST /issues -> 401 FAIL-CLOSED — the route is served signed+gated; an unsigned push
#      is rejected at the cp_auth chokepoint BEFORE the route body runs. The route is live yet
#      never trusts an unauthenticated caller.
#   4. SIGNED GET /nope -> 404 — a signed request to a NON-registered path 404s, proving the 200 in
#      (2) is the ROUTE cp_boot wired, not a blanket accept.
#   5. FIRESTORE-MODE ROUND-TRIP (deployed-shape) — boot + register + a signed POST /issues ingest
#      and read-back hold under the REAL FirestoreBackend (HEIMDALL_STATE_BACKEND=firestore). The
#      presence bug taught us LocalBackend-green != Firestore-green; a boot that wires the route
#      locally but breaks under firestore -> RED. Any boot failure is LOUD (the driver prints the
#      captured traceback), never silent.
#
# Exit 0 iff ALL sections pass. Nonzero otherwise. stdlib + the shipped cp_* / issue_corpus /
# pmr_corpus code ONLY — ZERO real GCP / ZERO spend (section 5 uses the SAME faithful in-process
# firestore fake the cp-*-firestore + corpus-ingest gates use, or a caller-provided emulator).
# Crypto (Ed25519) is required (signed HTTP); absent it the suite SKIPS honestly (exit 0) rather
# than false-green — a green with no crypto would not have exercised the signed-ingest path.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
export LIB REPO

for f in cp_boot cp_server cp_issue_ingest issue_corpus cp_auth cp_state cp_state_firestore pmr_corpus; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# Crypto is required for the SIGNED ingest path (sections 2/3/5). Absent an Ed25519 backend, skip
# the WHOLE suite honestly — a green with no crypto would be a false pass (nothing was signed).
if ! "$PY" -c "import sys;sys.path.insert(0,'$LIB');import cp_auth;sys.exit(0 if cp_auth.crypto_available() else 1)" >/dev/null 2>&1; then
  echo "heimdall-issue-boot: SKIP — no Ed25519 backend (install \`cryptography\` or \`pynacl\`)."
  echo "RESULT: 0 passed, 0 failed (skipped)"
  exit 0
fi

ROOT_T="$(mktemp -d -t "issue-boot.XXXXXX")"
HOME_T="$ROOT_T/home"
mkdir -p "$HOME_T"
cleanup() { rm -rf "$ROOT_T"; }
trap cleanup EXIT

export HEIMDALL_HOME="$HOME_T"
export HEIMDALL_CORPUS_NAMESPACE="heimdall_corpus_boot_gate"

echo "============================================================"
echo "/issues BOOT-WIRING falsifier (Wave 3 wire-boot)"
echo "  home=$HEIMDALL_HOME  corpus_ns=$HEIMDALL_CORPUS_NAMESPACE"
echo "============================================================"
echo

# ── LOCAL-BACKEND driver: boot the assembled server in-process over a real socket, drive the
#    signed/unsigned/non-route requests through the LIVE cp_boot-wired handler, print ONE JSON line.
DRIVER="$ROOT_T/boot_driver.py"
cat >"$DRIVER" <<'PYEOF'
import http.server
import json
import os
import socket
import sys
import threading
import traceback
import urllib.error
import urllib.request

sys.path.insert(0, os.environ["LIB"])
import cp_auth
import cp_boot
import cp_issue_ingest
import cp_server
import issue_corpus

HOME = os.environ["HEIMDALL_HOME"]
out = {}


def signed_request(method, path, body, *, haid, priv, sign=True, base=None):
    """Drive a real request to the live socket, signing the cp_auth canonical message
    (METHOD\\nPATH\\nBODY) exactly as a real instance does. sign=False omits the signature
    header (an unsigned push). Returns (status, parsed_body)."""
    if isinstance(body, str):
        body = body.encode("utf-8")
    req = urllib.request.Request(base + path, data=body, method=method)
    req.add_header("X-Heimdall-HAID", haid)
    req.add_header("Content-Type", "application/json")
    if sign:
        req.add_header("X-Heimdall-Signature",
                       cp_auth.sign(priv, cp_auth.canonical_message(method, path, body)))
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return exc.code, (json.loads(raw) if raw else {})
        except (ValueError, TypeError):
            return exc.code, {}


try:
    # PRE-BOOT: register a signing HAID bound to a real team (server-derived attribution).
    secret = "team-secret-BOOTBOOTBOOTBOOTBOOTBOOTBO"
    priv, pub = cp_auth.generate_keypair()
    haid = "haid:issue-boot-dev"
    cp_auth.register_key(haid, pub, team_id=cp_auth.derive_team_id(secret), home=HOME)
    server_team = cp_auth.registered_team(haid, home=HOME)
    out["server_team"] = server_team

    # bind a free port + start the WIRED handler (the SAME class cp_server.serve builds).
    sock = socket.socket(); sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]; sock.close()
    httpd = http.server.HTTPServer(("127.0.0.1", port), cp_server._build_handler_class(HOME, False))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d" % port

    # #1 BOOT the §10 assembly — this is the line under test. routes["issues"] must appear.
    result = cp_boot.boot(home=HOME, start_tick=False, resume=False)
    out["boot_has_issues_key"] = "issues" in result.routes
    out["boot_issues_routes"] = ["%s %s" % (m, p) for (m, p) in result.routes.get("issues", [])]
    out["route_registered"] = ("POST", "/issues") in cp_server.registered_routes()

    # #2 SIGNED POST /issues with one valid issue_v1 -> 200 ingested (route LIVE, wired to
    #    cp_issue_ingest). project() builds a zero-content-by-construction record the server rebuild
    #    accepts. A stored record proves the request reached cp_issue_ingest.issues_route, not a 404.
    rec = issue_corpus.project({
        "error_class": "lint", "gate": "lint", "phase": "verify",
        "command": "test", "severity": "low", "hmd_version": "9.9.9",
    })
    body = json.dumps({"issues": [rec]})
    st, b = signed_request("POST", "/issues", body, haid=haid, priv=priv, base=base)
    out["signed_status"] = st
    out["signed_ingested"] = bool(b.get("ingested"))
    out["signed_stored"] = b.get("stored")
    stored = cp_issue_ingest.all_issues(home=HOME)
    out["stored_count"] = len(stored)
    out["stored_team"] = stored[0]["ids"]["team_id_hash"] if stored else None

    # #3 UNSIGNED POST /issues -> 401 at the auth chokepoint (route live yet fail-closed).
    st_u, b_u = signed_request("POST", "/issues", body, haid=haid, priv=priv, sign=False, base=base)
    out["unsigned_status"] = st_u

    # #4 SIGNED GET /nope -> 404 (the 200 above is the ROUTE cp_boot wired, not a blanket accept).
    st_n, _ = signed_request("GET", "/nope", b"", haid=haid, priv=priv, base=base)
    out["nonroute_status"] = st_n

    httpd.shutdown(); httpd.server_close()
except Exception:  # noqa: BLE001 — LOUD: a boot failure must surface its traceback, never silence.
    out["fatal"] = traceback.format_exc()

print(json.dumps(out))
PYEOF

OUT="$("$PY" "$DRIVER" 2>"$ROOT_T/local.err")"
if [ -z "$OUT" ]; then
  bad "local boot driver produced no output (see stderr)"; cat "$ROOT_T/local.err" >&2
  echo; echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi
echo "  boot driver: $OUT"
echo

j() { printf '%s' "$OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null; }

if [ "$(j "['fatal']")" != "None" ] && [ -n "$(j "['fatal']")" ]; then
  bad "the boot driver hit a FATAL error (LOUD, not silent):"; j "['fatal']" >&2
fi

echo "── SECTION 1 — cp_boot.boot() WIRES POST /issues (the §10 assembly seam)"
[ "$(j "['boot_has_issues_key']")" = "True" ] && [ "$(j "['route_registered']")" = "True" ] \
  && ok "S1a boot() carries an 'issues' route key and registers (POST, /issues): $(j "['boot_issues_routes']")" \
  || bad "S1a boot did not wire the /issues route — out=$OUT"

echo
echo "── SECTION 2 — SIGNED POST /issues -> 200 INGESTED (route LIVE; pre-boot this 404s) [LOAD-BEARING]"
[ "$(j "['signed_status']")" = "200" ] && [ "$(j "['signed_ingested']")" = "True" ] \
  && [ "$(j "['stored_count']")" = "1" ] \
  && ok "S2a a SIGNED POST /issues (200) lands ONE issue via cp_issue_ingest — the boot wiring is load-bearing" \
  || bad "S2a signed ingest did not land through the wired route — out=$OUT"

[ "$(j "['stored_team']")" = "$(j "['server_team']")" ] \
  && ok "S2b the stored issue is keyed by the SERVER-DERIVED team_id_hash (INV-C), reached only via the live route" \
  || bad "S2b the wired route did not server-stamp the team — out=$OUT"

echo
echo "── SECTION 3 — UNSIGNED POST /issues -> 401 FAIL-CLOSED (route served signed+gated)"
[ "$(j "['unsigned_status']")" = "401" ] \
  && ok "S3a an UNSIGNED POST /issues is REFUSED (401) at the cp_auth chokepoint — route live yet fail-closed" \
  || bad "S3a an unsigned push was not refused with 401 — out=$OUT"

echo
echo "── SECTION 4 — SIGNED GET /nope -> 404 (the 200 above is the ROUTE, not a blanket accept)"
[ "$(j "['nonroute_status']")" = "404" ] \
  && ok "S4a a signed NON-route (GET /nope) -> 404 — proves /issues resolves the wired route specifically" \
  || bad "S4a a non-route did not 404 — out=$OUT"

# ── SECTION 5 — FIRESTORE-MODE round-trip (deployed-shape: LocalBackend-green != Firestore-green) ──
echo
echo "── SECTION 5 — firestore-mode boot + signed /issues ingest (the deployed-shape guard)"

FS_EXT="$ROOT_T/fs"
mkdir -p "$FS_EXT"
FS_HOME="$FS_EXT/home"
mkdir -p "$FS_HOME"

MODE=""
# (0) caller-provided emulator (real client) takes precedence.
if [ -n "${FIRESTORE_EMULATOR_HOST:-}" ] \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  MODE="emulator"
  echo "  using caller-provided FIRESTORE_EMULATOR_HOST=$FIRESTORE_EMULATOR_HOST (real client)"
fi
# (1) faithful in-process fake — the SAME double the cp-*-firestore + corpus-ingest gates use. It
# exercises the SHIPPED FirestoreBackend code; only the external service is doubled.
if [ -z "$MODE" ]; then
  MODE="fake"
  FAKEPKG="$FS_EXT/pylib"
  mkdir -p "$FAKEPKG"
  cat >"$FAKEPKG/_fake_firestore_impl.py" <<'PYEOF'
# Faithful in-process FAKE of the slice of google.cloud.firestore FirestoreBackend uses. PERSISTS
# to the JSON file named by HEIMDALL_FAKE_FS_STORE so a read after a write shares one store.
import json
import os

_STORE_ENV = "HEIMDALL_FAKE_FS_STORE"


def _store_path():
    p = os.environ.get(_STORE_ENV)
    if not p:
        raise RuntimeError("fake firestore needs %s set to a path" % _STORE_ENV)
    return p


def _load():
    try:
        with open(_store_path(), "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _save(data):
    tmp = _store_path() + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    os.replace(tmp, _store_path())


class Client:
    def __init__(self, project=None, database=None):
        self.project = project

    def collection(self, name):
        return CollectionRef(name)

    def transaction(self):
        return _Transaction()


class CollectionRef:
    def __init__(self, path):
        self._path = path

    def document(self, doc_id):
        return DocRef(self._path, doc_id)

    def order_by(self, field):
        return _Query(self._path, order_field=field)

    def stream(self):
        return _Query(self._path).stream()


class _Query:
    def __init__(self, coll_path, order_field=None):
        self._coll_path = coll_path
        self._order_field = order_field

    def order_by(self, field):
        return _Query(self._coll_path, order_field=field)

    def stream(self):
        data = _load()
        coll = data.get("collections", {}).get(self._coll_path, {})
        items = []
        for doc_id, doc in coll.items():
            items.append(_Snapshot(self._coll_path, doc_id, doc.get("fields")))
        if self._order_field:
            items.sort(key=lambda s: (s.to_dict() or {}).get(self._order_field))
        else:
            items.sort(key=lambda s: s.id)
        return iter(items)


class DocRef:
    def __init__(self, coll_path, doc_id):
        self._coll_path = coll_path
        self._doc_id = doc_id

    @property
    def id(self):
        return self._doc_id

    def collection(self, name):
        return CollectionRef("%s/%s/%s" % (self._coll_path, self._doc_id, name))

    def get(self, transaction=None):
        data = _load()
        doc = data.get("collections", {}).get(self._coll_path, {}).get(self._doc_id)
        fields = doc.get("fields") if doc else None
        return _Snapshot(self._coll_path, self._doc_id, fields)

    def set(self, fields, merge=False):
        data = _load()
        colls = data.setdefault("collections", {})
        coll = colls.setdefault(self._coll_path, {})
        doc = coll.setdefault(self._doc_id, {"fields": {}})
        if merge:
            cur = dict(doc.get("fields") or {})
            cur.update(fields)
            doc["fields"] = cur
        else:
            doc["fields"] = dict(fields)
        _save(data)


class _Snapshot:
    def __init__(self, coll_path, doc_id, fields):
        self._coll_path = coll_path
        self._doc_id = doc_id
        self._fields = fields

    @property
    def id(self):
        return self._doc_id

    @property
    def exists(self):
        return self._fields is not None

    def to_dict(self):
        return dict(self._fields) if self._fields is not None else None


class _Transaction:
    def set(self, ref, fields, merge=False):
        ref.set(fields, merge=merge)

    def get(self, ref):
        return ref.get()


def transactional(func):
    def _wrapped(transaction, *args, **kwargs):
        return func(transaction, *args, **kwargs)
    return _wrapped
PYEOF
  cat >"$FAKEPKG/sitecustomize.py" <<'PYEOF'
import importlib
import sys

import _fake_firestore_impl as _impl

for _name in ("google", "google.cloud"):
    if _name not in sys.modules:
        try:
            importlib.import_module(_name)
        except Exception:  # noqa: BLE001 — synthesize a bare package when google is absent.
            import types
            _pkg = types.ModuleType(_name)
            _pkg.__path__ = []
            sys.modules[_name] = _pkg

sys.modules["google.cloud.firestore"] = _impl
setattr(sys.modules["google.cloud"], "firestore", _impl)
PYEOF
  export HEIMDALL_FAKE_FS_STORE="$FS_EXT/fake_fs.json"
  : >"$HEIMDALL_FAKE_FS_STORE"
  export PYTHONPATH="$FAKEPKG${PYTHONPATH:+:$PYTHONPATH}"
fi
echo "  firestore MODE=$MODE"

FS_DRIVER="$ROOT_T/fs_boot_driver.py"
cat >"$FS_DRIVER" <<'PYEOF'
import http.server
import json
import os
import socket
import sys
import threading
import traceback
import urllib.error
import urllib.request

sys.path.insert(0, os.environ["LIB"])
import cp_auth
import cp_boot
import cp_issue_ingest
import cp_server
import issue_corpus

HOME = os.environ["HEIMDALL_HOME"]
out = {}


def signed_request(method, path, body, *, haid, priv, base):
    if isinstance(body, str):
        body = body.encode("utf-8")
    req = urllib.request.Request(base + path, data=body, method=method)
    req.add_header("X-Heimdall-HAID", haid)
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Heimdall-Signature",
                   cp_auth.sign(priv, cp_auth.canonical_message(method, path, body)))
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return exc.code, (json.loads(raw) if raw else {})
        except (ValueError, TypeError):
            return exc.code, {}


try:
    secret = "team-secret-FSBOOTFSBOOTFSBOOTFSBOOTFS"
    priv, pub = cp_auth.generate_keypair()
    haid = "haid:issue-boot-fs-dev"
    cp_auth.register_key(haid, pub, team_id=cp_auth.derive_team_id(secret), home=HOME)
    server_team = cp_auth.registered_team(haid, home=HOME)
    out["fs_team"] = server_team
    # no path segment may carry the firestore "__" doc-id separator (the presence-bug class).
    out["fs_team_has_dunder"] = "__" in (server_team or "")

    sock = socket.socket(); sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]; sock.close()
    httpd = http.server.HTTPServer(("127.0.0.1", port), cp_server._build_handler_class(HOME, False))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d" % port

    # BOOT under the firestore backend — the route must wire here too, not just under LocalBackend.
    result = cp_boot.boot(home=HOME, start_tick=False, resume=False)
    out["fs_route_registered"] = ("POST", "/issues") in cp_server.registered_routes()
    out["fs_boot_has_issues_key"] = "issues" in result.routes

    rec = issue_corpus.project({
        "error_class": "gate", "gate": "test", "phase": "verify",
        "command": "run", "severity": "med", "hmd_version": "9.9.9",
    })
    body = json.dumps({"issues": [rec]})
    st, b = signed_request("POST", "/issues", body, haid=haid, priv=priv, base=base)
    out["fs_status"] = st
    out["fs_ingested"] = bool(b.get("ingested"))
    landed = cp_issue_ingest.all_issues(home=HOME)   # the READ path (list_teams + read_lines) under firestore
    out["fs_landed_count"] = len(landed)
    out["fs_landed_team"] = landed[0]["ids"]["team_id_hash"] if landed else None

    httpd.shutdown(); httpd.server_close()
except Exception:  # noqa: BLE001 — LOUD: surface the traceback, never a silent firestore-boot break.
    out["fatal"] = traceback.format_exc()

print(json.dumps(out))
PYEOF

# The firestore backend selects the CLOUD profile, so boot()'s ensure_server_identity refuses to
# mint a per-instance key — it requires a deterministic PKI seed (HEIMDALL_CP_PKI_KEY). Supply a
# TEST seed (in memory only, never a tracked file, never printed) exactly as the cp-*-firestore
# boot gates do, so the SAME production boot path runs under firestore.
SEED_B64="$("$PY" -c "import base64;print(base64.b64encode(bytes((i*7+3)%256 for i in range(32))).decode())")"
FSOUT="$(env HEIMDALL_STATE_BACKEND=firestore HEIMDALL_HOME="$FS_HOME" \
  HEIMDALL_FIRESTORE_ROOT="issue_boot_gate_cp" HEIMDALL_FIRESTORE_PROJECT="issue-boot-fs-test" \
  HEIMDALL_CP_PKI_KEY="$SEED_B64" HEIMDALL_CP_SERVER_HAID="haid:cp-server" \
  "$PY" "$FS_DRIVER" 2>"$ROOT_T/fs.err")"
if [ -z "$FSOUT" ]; then
  bad "S5 firestore boot driver produced no output (see stderr)"; cat "$ROOT_T/fs.err" >&2
else
  echo "  fs boot driver: $FSOUT"
  fj() { printf '%s' "$FSOUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null; }

  if [ "$(fj "['fatal']")" != "None" ] && [ -n "$(fj "['fatal']")" ]; then
    bad "the firestore boot driver hit a FATAL error (LOUD, not silent):"; fj "['fatal']" >&2
  fi

  [ "$(fj "['fs_boot_has_issues_key']")" = "True" ] && [ "$(fj "['fs_route_registered']")" = "True" ] \
    && ok "S5a cp_boot.boot() wires POST /issues under the FIRESTORE backend too (deployed-shape)" \
    || bad "S5a boot did not wire /issues under firestore — out=$FSOUT"

  [ "$(fj "['fs_status']")" = "200" ] && [ "$(fj "['fs_ingested']")" = "True" ] \
    && [ "$(fj "['fs_landed_count']")" = "1" ] \
    && [ "$(fj "['fs_landed_team']")" = "$(fj "['fs_team']")" ] \
    && ok "S5b a signed POST /issues LANDS + reads back under firestore via the wired route (server-derived team)" \
    || bad "S5b firestore-mode ingest/read-back through the wired route failed — out=$FSOUT"

  [ "$(fj "['fs_team_has_dunder']")" = "False" ] \
    && ok "S5c no '__' in the corpus team path segment (no firestore doc-id slug collision)" \
    || bad "S5c a corpus path segment contains the '__' firestore separator — out=$FSOUT"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
