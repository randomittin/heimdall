#!/usr/bin/env bash
# heimdall-tenant-onboard.test.sh — THE FALSIFIABLE LAST-MILE TENANT-ONBOARDING gate. It proves the
# two SIGNED, team-scoped registration writes the public control plane serves — POST /team/cred and
# POST /team/install — close the multi-tenant loop WITHOUT breaching the isolation invariants:
#
#   INV-1 (team_id server-derived) — a body `team_id` field is IGNORED; a cred/install lands in the
#         CALLER's registered_team(haid) partition, never the spoofed one.
#   INV-2 (per-team partition)     — team A can never write team B's cred/install; A's read is A's only.
#   INV-4 (secret never logged)    — the Claude token appears in NO server log, NO response body, NO
#         driver summary (grep, with a POSITIVE CONTROL that it DID reach the store — the grep is real).
#   INV-6 (public surface holds no cred) — /team/cred WRITE-FORWARDS the caller's own cred into its own
#         partition and STOPS; the round-trip to the worker (env_for_team + mint_token_for_team) works.
#   INV-8 (signed + replay-resistant) — an UNSIGNED or FORGED request is a 401; a REPLAYED signed
#         registration (same nonce) is a 401.
#   plus: `rr connect --dry-run` prints the signed-POST plan with the secret REDACTED (no leak).
#
# HERMETIC. Zero real GCP, zero real GitHub, zero network beyond 127.0.0.1: the REAL public-surface
# server (heimdall-control-plane serve, HEIMDALL_PUBLIC_SURFACE=1, --no-revocation) runs on a loopback
# port over the LocalBackend under a throwaway HEIMDALL_HOME; the model-cred store is the local 0600
# store (HEIMDALL_TEAM_CRED_STORE=local); bin/heimdall-gh-app-token is REPLACED by a FAKE minter. The
# serve subprocess is REAPED on EXIT. Crypto-gated (the writes are signed): SKIP cleanly with no backend.
#
# Acceptance: `bash test/heimdall-tenant-onboard.test.sh` -> N passed, 0 failed (incl cross-tenant-denial
# + cred-never-logged + round-trip-to-worker + unsigned/forged/replay-401 + rr-connect-dry-run-no-secret).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib"
CLI="$REPO/bin/heimdall-control-plane"
RR="$REPO/bin/rr"
export LIB REPO

for f in cp_auth cp_publicsurface cp_server cp_team_creds cp_ghinstall cp_state cp_nonce cp_ratelimit; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done
[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }
[ -f "$RR" ]  || { echo "FATAL: $RR missing" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

if ! "$PY" -c "import sys; sys.path.insert(0,'$LIB'); import cp_auth; sys.exit(0 if cp_auth.crypto_available() else 1)"; then
  echo "  SKIP no crypto backend (cryptography|pynacl) — the registration writes are signed."
  printf "heimdall-tenant-onboard: %d passed, %d failed (SKIPPED — no crypto)\n" "$PASS" "$FAIL"
  exit 0
fi

EXT="$(mktemp -d -t "cp-onboard.$(printf 'X%.0s' 1 2 3 4 5 6)")"
HOME_T="$EXT/home"
CALL_LOG="$EXT/minter-calls.log"
FAKE_MINTER="$EXT/heimdall-gh-app-token"
mkdir -p "$HOME_T"
: >"$CALL_LOG"
export EXT
SERVER_PID=""
GATED_PID=""       # section 8: the FAKE privileged GATED service (writes the cred with admin).
PUBSM_PID=""       # section 8: the least-priv PUBLIC surface in SECRET-MANAGER mode (forwards).
cleanup() {
  for p in "$SERVER_PID" "$GATED_PID" "$PUBSM_PID"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
  done
  rm -rf "$EXT"
}
trap cleanup EXIT

# ── the FAKE minter (mirrors heimdall-cp-ghinstall.test.sh): echoes ONLY a deterministic token to
#    stdout embedding the installation id it received via ENV (never argv), so the round-trip can
#    prove the caller-team's OWN installation was used. No real GitHub creds. ──
cat >"$FAKE_MINTER" <<'FAKEEOF'
#!/usr/bin/env python3
import os, sys
inst = os.environ.get("HEIMDALL_GH_APP_INSTALLATION_ID", "")
repos = os.environ.get("HEIMDALL_GH_APP_REPOSITORIES", "")
log = os.environ.get("MINTER_CALL_LOG")
if log:
    with open(log, "a", encoding="utf-8") as fh:
        fh.write("CALL inst=%s repos=%s\n" % (inst, repos))
if not inst:
    sys.stderr.write("fake-minter: no HEIMDALL_GH_APP_INSTALLATION_ID\n"); sys.exit(2)
sys.stdout.write("ghs_faketok_inst_%s_repos_%s\n" % (inst, repos))
FAKEEOF
chmod +x "$FAKE_MINTER"

# ── hermetic env: throwaway home, LOCAL backend, local cred store, no cloud signal, fake minter ──
export HEIMDALL_HOME="$HOME_T"
export HEIMDALL_STATE_BACKEND="local"
export HEIMDALL_TEAM_CRED_STORE="local"
unset K_SERVICE 2>/dev/null || true
export HEIMDALL_GH_APP_TOKEN_BIN="$FAKE_MINTER"
export MINTER_CALL_LOG="$CALL_LOG"
# a TEST PKI seed (in memory only) so the server boots a stable identity; never a tracked file.
export HEIMDALL_CP_PKI_KEY="$("$PY" -c "import base64;print(base64.b64encode(bytes((i*5+1)%256 for i in range(32))).decode())")"
export HEIMDALL_CP_SERVER_HAID="haid:cp-server"

echo "============================================================"
echo "LAST-MILE TENANT ONBOARDING — signed POST /team/cred + /team/install (hermetic, real HTTP)"
echo "  home=$HEIMDALL_HOME"
echo "============================================================"
echo

# ── bring up the REAL public-surface server on a loopback port ──
CP_PORT="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
CP_URL="http://127.0.0.1:$CP_PORT"
export CP_URL
HEIMDALL_PUBLIC_SURFACE=1 "$CLI" serve --host 127.0.0.1 --port "$CP_PORT" --home "$HEIMDALL_HOME" --no-revocation \
  >"$EXT/serve.out" 2>"$EXT/serve.err" &
SERVER_PID=$!

# wait for /healthz to answer 200 (or fail loudly).
UP=0
for _ in $(seq 1 60); do
  code="$("$PY" - <<'PY' 2>/dev/null || true
import os, urllib.request, urllib.error
try:
    print(urllib.request.urlopen(os.environ["CP_URL"] + "/healthz", timeout=2).status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print(0)
PY
)"
  [ "$code" = "200" ] && { UP=1; break; }
  kill -0 "$SERVER_PID" 2>/dev/null || break
  "$PY" -c "import time;time.sleep(0.25)"
done
if [ "$UP" = 1 ]; then
  ok "0.1 the REAL public-surface server is live on $CP_URL (pid $SERVER_PID)"
else
  bad "0.1 the public-surface server did not come up"; cat "$EXT/serve.err" >&2
  echo "heimdall-tenant-onboard: $PASS passed, $FAIL failed"; exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# DRIVER — enroll two teams (A, B) directly in the shared registry, then sign + POST over the
# socket and verify the round-trip to the worker. Prints a booleans/ids-only JSON summary (the
# raw Claude token NEVER appears in it — checked below).
# ══════════════════════════════════════════════════════════════════════════════
D_OUT="$EXT/driver.out"
D_ERR="$EXT/driver.err"
"$PY" - >"$D_OUT" 2>"$D_ERR" <<'PYEOF'
import json, os, secrets, sys, time
import urllib.error, urllib.request
sys.path.insert(0, os.environ["LIB"])
import cp_auth as A
import cp_team_creds as TC
import cp_ghinstall as G

BASE = os.environ["CP_URL"].rstrip("/")

# ── two teams, DISTINCT secrets; bind each haid -> its team_id in the shared registry ──
SA = secrets.token_urlsafe(24); SB = secrets.token_urlsafe(24)
tidA = A.derive_team_id(SA); tidB = A.derive_team_id(SB)
HA = "haid:tenant.alice"; HB = "haid:tenant.bob"
privA, pubA = A.generate_keypair(); privB, pubB = A.generate_keypair()
A.register_key(HA, pubA, team_id=tidA)
A.register_key(HB, pubB, team_id=tidB)

# the SECRETS UNDER TEST — the tenants' BYO Claude creds (must never leak to any log/body/summary).
CRED_A = "sk-ant-oat01-" + secrets.token_urlsafe(40)
CRED_B = "sk-ant-api03-" + secrets.token_urlsafe(40)
REPO_A = "randomittin/heimdall-maintainer-test"

out = {}


def _fresh(extra):
    b = {"nonce": secrets.token_hex(16), "ts": int(time.time())}
    b.update(extra)
    return b


def post(path, body_obj, haid, seed, *, omit_sig=False, forge=False, raw_body=None):
    body = raw_body if raw_body is not None else json.dumps(body_obj).encode("utf-8")
    req = urllib.request.Request(BASE + path, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Heimdall-HAID", haid)
    if not omit_sig:
        to_sign = body + b"X" if forge else body   # forge: sign a DIFFERENT byte string than sent.
        req.add_header("X-Heimdall-Signature", A.sign(seed, A.canonical_message("POST", path, to_sign)))
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, (json.loads(raw) if raw else {})
        except Exception:
            return e.code, {}


# ── 1) A registers its cred WITH A SPOOFED team_id=tidB in the body -> must store under tidA (INV-1) ──
st, resp = post("/team/cred", _fresh({"kind": "oauth_token", "secret": CRED_A, "team_id": tidB}), HA, privA)
out["credA_status"] = st
out["credA_resp_team"] = resp.get("team_id")               # must be tidA, NOT the spoofed tidB.
out["credA_resp_is_tidA"] = (resp.get("team_id") == tidA)
out["credA_resp_no_secret"] = (CRED_A not in json.dumps(resp))
out["stored_under_A"] = TC.has_cred(tidA)                  # landed in A's partition...
out["spoof_ignored_not_B"] = (TC.has_cred(tidB) is False)  # ...never the spoofed B partition.
out["envA_roundtrip"] = (TC.env_for_team(tidA).get("CLAUDE_CODE_OAUTH_TOKEN") == CRED_A)  # worker round-trip.
out["envB_empty"] = (TC.env_for_team(tidB) == {})

# ── 2) B registers its OWN cred (api_key) -> stored under tidB; cross-tenant stays isolated ──
st, resp = post("/team/cred", _fresh({"kind": "api_key", "secret": CRED_B}), HB, privB)
out["credB_status"] = st
out["envB_roundtrip"] = (TC.env_for_team(tidB).get("ANTHROPIC_API_KEY") == CRED_B)
out["A_still_credA"] = (TC.env_for_team(tidA).get("CLAUDE_CODE_OAUTH_TOKEN") == CRED_A)
out["A_never_credB"] = (CRED_B not in json.dumps(TC.env_for_team(tidA)))
out["B_never_credA"] = (CRED_A not in json.dumps(TC.env_for_team(tidB)))

# ── 3) A registers its GitHub App installation (SPOOFED team_id=tidB again) -> stored under tidA ──
st, resp = post("/team/install", _fresh({"installation_id": 55501, "repo": REPO_A, "team_id": tidB}), HA, privA)
out["installA_status"] = st
out["installA_resp_is_tidA"] = (resp.get("team_id") == tidA)
out["A_covers_repo"] = G.team_covers_repo(tidA, REPO_A)
out["B_not_covers_repo"] = (G.team_covers_repo(tidB, REPO_A) is False)
# the round-trip the worker performs: mint a token for A's repo -> the fake minter rides A's install.
try:
    tok = G.mint_token_for_team(tidA, REPO_A)
    out["mintA_uses_55501"] = ("inst_55501_" in tok)
except Exception as exc:  # noqa: BLE001
    out["mintA_uses_55501"] = False
    out["mintA_err"] = "%s" % exc
# B cannot mint A's repo (fail-closed — no install / not covered).
try:
    G.mint_token_for_team(tidB, REPO_A)
    out["mintB_refused"] = False
except G.GhInstallError as exc:
    out["mintB_refused"] = exc.reason in ("no_installation", "repo_not_covered")

# ── 4) UNSIGNED -> 401 (INV-8) ──
st, _ = post("/team/cred", _fresh({"kind": "oauth_token", "secret": "unused"}), HA, privA, omit_sig=True)
out["unsigned_401"] = (st == 401)

# ── 5) FORGED (signature over a different body than sent) -> 401 (INV-8) ──
st, _ = post("/team/cred", _fresh({"kind": "oauth_token", "secret": "unused"}), HA, privA, forge=True)
out["forged_401"] = (st == 401)

# ── 6) REPLAY (resend the SAME signed bytes / nonce) -> first 200, replay 401 (INV-8) ──
replay_body = json.dumps(_fresh({"kind": "oauth_token", "secret": CRED_A})).encode("utf-8")
st1, _ = post("/team/cred", None, HA, privA, raw_body=replay_body)
st2, r2 = post("/team/cred", None, HA, privA, raw_body=replay_body)
out["replay_first_200"] = (st1 == 200)
out["replay_second_401"] = (st2 == 401)

# ── selfcheck: no raw Claude token in the summary we are about to print (booleans/ids only) ──
blob = json.dumps(out)
out["_no_secret_in_summary"] = (CRED_A not in blob and CRED_B not in blob)

# expose the secrets + partition paths to the bash harness via a SEPARATE fd-safe channel: write
# them to files under HOME (0600) so the log-grep can use them WITHOUT printing them to stdout.
home = os.environ["HEIMDALL_HOME"]
with open(os.path.join(os.environ["EXT"], "cred_a.secret"), "w") as fh:
    fh.write(CRED_A)
with open(os.path.join(os.environ["EXT"], "cred_b.secret"), "w") as fh:
    fh.write(CRED_B)
with open(os.path.join(os.environ["EXT"], "tids.txt"), "w") as fh:
    fh.write("%s\n%s\n" % (tidA, tidB))

sys.stdout.write(json.dumps(out))
PYEOF

if [ ! -s "$D_OUT" ]; then
  bad "driver produced no output"; cat "$D_ERR" >&2
  echo "heimdall-tenant-onboard: $PASS passed, $FAIL failed"; exit 1
fi
[ -s "$D_ERR" ] && { bad "driver wrote to stderr"; cat "$D_ERR" >&2; }
j() { "$PY" -c "import json,sys;print(json.load(open('$D_OUT')).get('$1'))"; }

echo "1. INV-1 — team_id is SERVER-DERIVED (a spoofed body team_id is IGNORED)"
[ "$(j credA_status)" = "200" ] && [ "$(j credA_resp_is_tidA)" = "True" ] && [ "$(j stored_under_A)" = "True" ] && [ "$(j spoof_ignored_not_B)" = "True" ] \
  && ok "1.1 POST /team/cred as A with a spoofed team_id=B -> stored under A (registered_team), NOT B" \
  || bad "1.1 the spoofed team_id was honored / not stored under A (see $D_OUT)"
[ "$(j installA_status)" = "200" ] && [ "$(j installA_resp_is_tidA)" = "True" ] && [ "$(j A_covers_repo)" = "True" ] \
  && ok "1.2 POST /team/install as A with a spoofed team_id=B -> stored under A; A covers its repo" \
  || bad "1.2 install stored under the wrong team / A does not cover its repo"

echo "2. INV-2 — per-team partition (cross-tenant write/read DENIED)"
[ "$(j envA_roundtrip)" = "True" ] && [ "$(j A_never_credB)" = "True" ] && [ "$(j B_never_credA)" = "True" ] && [ "$(j envB_roundtrip)" = "True" ] \
  && ok "2.1 A's env carries ONLY A's cred, B's ONLY B's — neither team can reach the other's partition" \
  || bad "2.1 a cred crossed teams (see $D_OUT)"
[ "$(j B_not_covers_repo)" = "True" ] && [ "$(j mintB_refused)" = "True" ] \
  && ok "2.2 B does NOT cover A's repo; mint_token_for_team(B, A's repo) is fail-closed refused" \
  || bad "2.2 B reached A's installation / minted A's repo"

echo "3. INV-6 — round-trip to the worker (env_for_team + mint both resolve the registered material)"
[ "$(j envA_roundtrip)" = "True" ] && [ "$(j mintA_uses_55501)" = "True" ] \
  && ok "3.1 the registered cred + install round-trip: env_for_team(A) returns A's token; mint rides A's install (55501)" \
  || bad "3.1 the worker round-trip failed (env_for_team or mint) (mintA_err=$(j mintA_err))"

echo "4. INV-8 — signed + replay-resistant (unsigned / forged / replayed -> 401)"
[ "$(j unsigned_401)" = "True" ] && ok "4.1 an UNSIGNED POST /team/cred -> 401 (a public write MUST be signed)" || bad "4.1 unsigned was not 401"
[ "$(j forged_401)" = "True" ] && ok "4.2 a FORGED POST /team/cred (sig over a different body) -> 401 bad_signature" || bad "4.2 forged was not 401"
[ "$(j replay_first_200)" = "True" ] && [ "$(j replay_second_401)" = "True" ] \
  && ok "4.3 a REPLAYED signed registration (same nonce) -> first 200, replay 401" || bad "4.3 replay was not caught"

echo "5. INV-4 — the cred is NEVER in any log / response / driver summary [with a POSITIVE CONTROL]"
CRED_A_VAL="$(cat "$EXT/cred_a.secret")"
CRED_B_VAL="$(cat "$EXT/cred_b.secret")"
LEAK=0
for S in "$CRED_A_VAL" "$CRED_B_VAL"; do
  grep -qF -- "$S" "$EXT/serve.out" "$EXT/serve.err" "$D_OUT" "$D_ERR" 2>/dev/null && LEAK=1
done
[ "$LEAK" -eq 0 ] && [ "$(j credA_resp_no_secret)" = "True" ] && [ "$(j _no_secret_in_summary)" = "True" ] \
  && ok "5.1 no Claude token appears in the server logs, any response body, or the driver summary" \
  || bad "5.1 a cred LEAKED into a log/response/summary"
# POSITIVE CONTROL: the token DID reach the store (the write-forward is real) — prove the grep works.
TID_A="$(sed -n '1p' "$EXT/tids.txt")"
STORE_FILE="$HEIMDALL_HOME/control-plane/team-creds/$TID_A/oauth_token.json"
if grep -qF -- "$CRED_A_VAL" "$STORE_FILE" 2>/dev/null; then
  ok "5.2 POSITIVE CONTROL: A's token IS in its own 0600 store partition (write-forward reached the store; the leak-grep is real)"
else
  bad "5.2 positive control failed — the token did not reach A's store partition ($STORE_FILE)"
fi
# the store file is 0600 (a co-tenant process cannot read another team's secret).
if [ -f "$STORE_FILE" ]; then
  MODE="$("$PY" -c "import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$STORE_FILE")"
  [ "$MODE" = "0o600" ] && ok "5.3 the local cred partition file is mode 0600 ($MODE)" || bad "5.3 cred file mode is $MODE (expected 0o600)"
else
  bad "5.3 the cred partition file was not written at the expected path"
fi

echo "6. boundary — the two registration routes are PUBLIC (reachable by a public tenant), gated routes are NOT"
"$PY" - <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import cp_publicsurface as P
assert P.is_public_route("POST", "/team/cred"), "team/cred not public"
assert P.is_public_route("POST", "/team/install"), "team/install not public"
assert not P.is_public_route("POST", "/dispatch"), "dispatch leaked into public"
assert not P.is_public_route("POST", "/jobs"), "jobs leaked into public"
PYEOF
[ "$?" -eq 0 ] \
  && ok "6.1 POST /team/cred + /team/install are in the public allowlist; /dispatch + /jobs are NOT" \
  || bad "6.1 the public boundary is wrong for the registration routes"

# ══════════════════════════════════════════════════════════════════════════════
# 7. rr connect --dry-run — prints the signed-POST plan with the secret REDACTED (no leak, no network).
# ══════════════════════════════════════════════════════════════════════════════
echo "7. rr connect --dry-run prints the plan with the secret REDACTED"
SENTINEL="sk-ant-oat01-DRYRUNsentinel_$("$PY" -c "import secrets;print(secrets.token_urlsafe(20))")"
RR_OUT="$(CLAUDE_CODE_OAUTH_TOKEN="$SENTINEL" HOME="$EXT/fakehome" \
          "$RR" connect --dry-run --gh-app-installation-id 424242 --repo randomittin/heimdall-maintainer-test 2>&1 || true)"
if printf '%s' "$RR_OUT" | grep -qF -- "$SENTINEL"; then
  bad "7.1 rr connect --dry-run LEAKED the token into its output"
else
  ok "7.1 rr connect --dry-run did NOT print the token (the secret is redacted)"
fi
grep -q "redacted" <<<"$RR_OUT" && grep -q "/team/cred" <<<"$RR_OUT" \
  && grep -q "/team/install" <<<"$RR_OUT" && grep -q "424242" <<<"$RR_OUT" \
  && ok "7.2 the plan shows the POST /team/cred (redacted) + POST /team/install (id 424242) shape" \
  || bad "7.2 the dry-run plan is missing the redacted-secret / route / install-id markers"

# ══════════════════════════════════════════════════════════════════════════════
# 8. LEAST-PRIVILEGE WRITE-FORWARD (the /team/cred 503 fix). On the internet-facing PUBLIC surface
#    with the SECRET-MANAGER cred store, the public SA (heimdall-cp-public-run@) lacks
#    secretmanager.admin/create — a DIRECT put_team_cred would raise PermissionDenied and crash into
#    a bare 503. The fix: the public surface FORWARDS the SIGNED /team/cred to the privileged GATED
#    service, which does the SM write with its admin-holding runtime SA. Here we prove the WRITE is
#    ROUTED to the privileged path (never attempted on the least-priv public SA), the cred lands in
#    the CALLER's server-derived partition (a spoofed body team_id is ignored), and it never leaks.
#    Hermetic: a SECOND cp serve (LOCAL store, NO public surface) stands in for the gated service;
#    HEIMDALL_FORWARD_ID_TOKEN stands in for the Cloud Run metadata ID token (off-Cloud-Run). The
#    Cloud Run run.invoker bearer is a PLATFORM IAM concern, not an app check — the fake gated
#    ignores it and re-verifies the SAME Ed25519 signature + re-derives team_id (INV-1).
# ══════════════════════════════════════════════════════════════════════════════
echo "8. LEAST-PRIVILEGE WRITE-FORWARD — public-SM /team/cred routes the WRITE to the privileged gated service"

wait_up() {  # $1 = base url; polls /healthz for a 200
  for _ in $(seq 1 60); do
    c="$("$PY" - "$1" <<'PY' 2>/dev/null || true
import sys, urllib.request, urllib.error
try:
    print(urllib.request.urlopen(sys.argv[1] + "/healthz", timeout=2).status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print(0)
PY
)"
    [ "$c" = "200" ] && return 0
    "$PY" -c "import time;time.sleep(0.25)"
  done
  return 1
}

GATED_PORT="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
GATED_URL="http://127.0.0.1:$GATED_PORT"
# the FAKE privileged GATED service: NO public surface, LOCAL cred store (stands in for the SM-admin
# runtime SA that CAN write). It re-verifies the signature, re-derives team_id, WRITES the cred.
HEIMDALL_TEAM_CRED_STORE=local "$CLI" serve --host 127.0.0.1 --port "$GATED_PORT" --home "$HEIMDALL_HOME" --no-revocation \
  >"$EXT/gated.out" 2>"$EXT/gated.err" &
GATED_PID=$!

PUBSM_PORT="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
PUBSM_URL="http://127.0.0.1:$PUBSM_PORT"
export PUBSM_URL
# the least-privilege PUBLIC surface in SECRET-MANAGER mode: it CANNOT create SM secrets, so /team/cred
# MUST forward. HEIMDALL_FORWARD_ID_TOKEN stands in for the metadata ID token (no metadata server off
# Cloud Run); HEIMDALL_GATED_SERVICE_URL points the forward at the fake gated service.
HEIMDALL_PUBLIC_SURFACE=1 HEIMDALL_TEAM_CRED_STORE=secretmanager \
  HEIMDALL_GATED_SERVICE_URL="$GATED_URL" HEIMDALL_FORWARD_ID_TOKEN="test-id-token" \
  "$CLI" serve --host 127.0.0.1 --port "$PUBSM_PORT" --home "$HEIMDALL_HOME" --no-revocation \
  >"$EXT/pubsm.out" 2>"$EXT/pubsm.err" &
PUBSM_PID=$!

if wait_up "$GATED_URL" && wait_up "$PUBSM_URL"; then
  ok "8.0 fake GATED (local store, admin stand-in) + PUBLIC-SM (secretmanager, forwarding) surfaces are live"
else
  bad "8.0 the gated / public-SM surfaces did not come up"; cat "$EXT/gated.err" "$EXT/pubsm.err" >&2
fi

D8_OUT="$EXT/driver8.out"; D8_ERR="$EXT/driver8.err"
"$PY" - >"$D8_OUT" 2>"$D8_ERR" <<'PYEOF'
import json, os, secrets, sys, time
import urllib.error, urllib.request
sys.path.insert(0, os.environ["LIB"])
import cp_auth as A
import cp_team_creds as TC

PUBSM = os.environ["PUBSM_URL"].rstrip("/")
H = os.environ["HEIMDALL_HOME"]
# team C bound in the SHARED registry; a DIFFERENT team the body will try to spoof.
SC = secrets.token_urlsafe(24); tidC = A.derive_team_id(SC)
SPOOF = A.derive_team_id(secrets.token_urlsafe(24))
HC = "haid:tenant.carol"
privC, pubC = A.generate_keypair()
A.register_key(HC, pubC, team_id=tidC)
CRED_C = "sk-ant-oat01-" + secrets.token_urlsafe(40)

body = json.dumps({"nonce": secrets.token_hex(16), "ts": int(time.time()),
                   "kind": "oauth_token", "secret": CRED_C, "team_id": SPOOF}).encode("utf-8")
req = urllib.request.Request(PUBSM + "/team/cred", data=body, method="POST")
req.add_header("Content-Type", "application/json")
req.add_header("X-Heimdall-HAID", HC)
req.add_header("X-Heimdall-Signature", A.sign(privC, A.canonical_message("POST", "/team/cred", body)))
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        st = r.status; resp = json.loads(r.read() or b"{}")
except urllib.error.HTTPError as e:
    st = e.code
    try:
        resp = json.loads(e.read() or b"{}")
    except Exception:
        resp = {}

out = {}
out["status"] = st
out["resp_is_tidC"] = (resp.get("team_id") == tidC)      # server-derived, NOT the spoofed body team.
out["spoof_not_used"] = (resp.get("team_id") != SPOOF)
out["resp_no_secret"] = (CRED_C not in json.dumps(resp))
# the cred landed in C's OWN partition — WRITTEN BY THE GATED process (local store), read back here.
out["stored_under_C"] = TC.has_cred(tidC, home=H)
out["not_stored_spoof"] = (TC.has_cred(SPOOF, home=H) is False)
out["roundtrip_env"] = (TC.env_for_team(tidC, home=H).get("CLAUDE_CODE_OAUTH_TOKEN") == CRED_C)

with open(os.path.join(os.environ["EXT"], "cred_c.secret"), "w") as fh:
    fh.write(CRED_C)
with open(os.path.join(os.environ["EXT"], "tid_c.txt"), "w") as fh:
    fh.write(tidC)
sys.stdout.write(json.dumps(out))
PYEOF

if [ ! -s "$D8_OUT" ]; then bad "8.x forward driver produced no output"; cat "$D8_ERR" >&2; fi
j8() { "$PY" -c "import json;print(json.load(open('$D8_OUT')).get('$1'))" 2>/dev/null; }

[ "$(j8 status)" = "200" ] && [ "$(j8 resp_is_tidC)" = "True" ] && [ "$(j8 spoof_not_used)" = "True" ] \
  && [ "$(j8 stored_under_C)" = "True" ] && [ "$(j8 not_stored_spoof)" = "True" ] && [ "$(j8 roundtrip_env)" = "True" ] \
  && ok "8.1 public-SM POST /team/cred FORWARDED the write to the gated service -> stored under the caller's server-derived team (spoofed body team_id IGNORED); env_for_team round-trips" \
  || bad "8.1 the forward did not land the cred under the caller's own team (see $D8_OUT)"

# the forwarded cred must NEVER appear in EITHER server's log, the response, or the driver summary.
CRED_C_VAL="$(cat "$EXT/cred_c.secret" 2>/dev/null)"
LEAK8=0
grep -qF -- "$CRED_C_VAL" "$EXT/pubsm.out" "$EXT/pubsm.err" "$EXT/gated.out" "$EXT/gated.err" "$D8_OUT" "$D8_ERR" 2>/dev/null && LEAK8=1
[ "$LEAK8" -eq 0 ] && [ "$(j8 resp_no_secret)" = "True" ] \
  && ok "8.2 the forwarded cred NEVER appears in the public-SM log, the gated log, the response, or the driver summary (transit-only, INV-6)" \
  || bad "8.2 the forwarded cred LEAKED into a log/response/summary"

# POSITIVE CONTROL: the cred IS in C's store partition — written by the GATED (privileged) process,
# proving the WRITE really executed on the privileged path (not the least-priv public SA).
TID_C="$(cat "$EXT/tid_c.txt" 2>/dev/null)"
STORE_C="$HEIMDALL_HOME/control-plane/team-creds/$TID_C/oauth_token.json"
if grep -qF -- "$CRED_C_VAL" "$STORE_C" 2>/dev/null; then
  ok "8.3 POSITIVE CONTROL: C's cred IS in its own 0600 partition (the GATED privileged write landed via the forward; the leak-grep is real)"
else
  bad "8.3 positive control failed — the forwarded write did not reach C's partition ($STORE_C)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 9. FAIL LOUD, NEVER LEAK — the forward decision logic + a STRUCTURED error (never a bare 503) on any
#    forward/write failure. In-process (hermetic, no servers): proves should_forward_cred_write routes
#    correctly, a forward failure is a structured secret-free 502, and a DIRECT store fault in
#    register_team_cred is surfaced (not raised as the bare-503 crash the live break was).
# ══════════════════════════════════════════════════════════════════════════════
echo "9. FAIL LOUD — forward decision routing + STRUCTURED error on failure (never a bare 503, never the secret)"
D9_OUT="$EXT/driver9.out"; D9_ERR="$EXT/driver9.err"
"$PY" - >"$D9_OUT" 2>"$D9_ERR" <<'PYEOF'
import json, os, secrets, socket, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth as A
import cp_credforward as CF
import cp_publicsurface as PS
import cp_team_creds as TC

out = {}

# routing: PUBLIC + SecretManager -> forward; GATED (flag off) -> write in place; local store -> in place.
os.environ["HEIMDALL_PUBLIC_SURFACE"] = "1"; os.environ["HEIMDALL_TEAM_CRED_STORE"] = "secretmanager"
out["forward_when_public_sm"] = (CF.should_forward_cred_write() is True)
os.environ["HEIMDALL_PUBLIC_SURFACE"] = "0"
out["no_forward_when_gated"] = (CF.should_forward_cred_write() is False)
os.environ["HEIMDALL_PUBLIC_SURFACE"] = "1"; os.environ["HEIMDALL_TEAM_CRED_STORE"] = "local"
out["no_forward_when_local"] = (CF.should_forward_cred_write() is False)

req = {"haid": "haid:x", "signature": "sig", "body": b'{"kind":"oauth_token","secret":"unused_secret_x"}'}

# forward UNCONFIGURED (no gated URL) -> structured 502, no crash, no secret.
os.environ.pop("HEIMDALL_GATED_SERVICE_URL", None)
st, body = CF.forward_cred_write(req)
out["unconfigured_502"] = (st == 502 and body.get("error") == "cred_forward_unconfigured")

# forward UNREACHABLE (a closed port) -> structured 502, no crash.
s = socket.socket(); s.bind(("127.0.0.1", 0)); dead = s.getsockname()[1]; s.close()
os.environ["HEIMDALL_GATED_SERVICE_URL"] = "http://127.0.0.1:%d" % dead
os.environ["HEIMDALL_FORWARD_ID_TOKEN"] = "tok"
st, body = CF.forward_cred_write(req)
out["unreachable_502"] = (st == 502 and body.get("error") == "cred_forward_unreachable")
out["no_secret_in_errors"] = ("unused_secret_x" not in json.dumps(body))

# a DIRECT store fault in register_team_cred -> STRUCTURED 502 (not a raised crash / bare 503, no secret).
os.environ["HEIMDALL_PUBLIC_SURFACE"] = "0"; os.environ["HEIMDALL_TEAM_CRED_STORE"] = "local"
H = os.environ["HEIMDALL_HOME"]
Hd = "haid:store.fault"; _priv, pub = A.generate_keypair()
tid = A.derive_team_id(secrets.token_urlsafe(16))
A.register_key(Hd, pub, team_id=tid)
_orig = TC.put_team_cred
def _boom(*a, **k):
    raise RuntimeError("simulated SM failure")
TC.put_team_cred = _boom
# A SHAPE-VALID secret (bug #23 gate passes) so the flow REACHES the boomed store — the point of
# this test is the store-fault -> structured 502 path, not the shape gate (covered by test 10).
STORE_SECRET = "sk-ant-oat01-" + secrets.token_urlsafe(40)
try:
    st, body = PS.register_team_cred(A.Identity(Hd),
        {"body": json.dumps({"kind": "oauth_token", "secret": STORE_SECRET}).encode("utf-8")}, home=H)
    out["store_fault_structured"] = (st == 502 and body.get("error") == "store_error"
                                     and STORE_SECRET not in json.dumps(body))
except Exception as exc:  # noqa: BLE001 — a RAISED exception here IS the bare-503 bug.
    out["store_fault_structured"] = False
    out["store_fault_exc"] = type(exc).__name__
finally:
    TC.put_team_cred = _orig

sys.stdout.write(json.dumps(out))
PYEOF

j9() { "$PY" -c "import json;print(json.load(open('$D9_OUT')).get('$1'))" 2>/dev/null; }
[ "$(j9 forward_when_public_sm)" = "True" ] && [ "$(j9 no_forward_when_gated)" = "True" ] && [ "$(j9 no_forward_when_local)" = "True" ] \
  && ok "9.1 forward routing: PUBLIC+SecretManager -> forward to the privileged gated service; GATED or local store -> write in place (never the public SA attempting SM-admin)" \
  || bad "9.1 should_forward_cred_write routing is wrong (see $D9_OUT)"
[ "$(j9 unconfigured_502)" = "True" ] && [ "$(j9 unreachable_502)" = "True" ] && [ "$(j9 no_secret_in_errors)" = "True" ] \
  && ok "9.2 a forward failure (unconfigured / unreachable) returns a STRUCTURED 502 {error,detail} — never a bare 503, never the secret" \
  || bad "9.2 a forward failure was not a structured, secret-free 502 (see $D9_OUT)"
[ "$(j9 store_fault_structured)" = "True" ] \
  && ok "9.3 a DIRECT store fault in register_team_cred returns a STRUCTURED 502 {store_error} (not a raised crash / bare 503, no secret)" \
  || bad "9.3 a store fault was not surfaced as a structured error (exc=$(j9 store_fault_exc), see $D9_OUT)"

# ── (10) BUG #23 — the SERVER SHAPE GATE: register_team_cred REFUSES a decorated/oversized/control-char
#    secret at the boundary (structured 422 bad_secret_shape, NOT stored), yet passes a CLEAN token.
#    FALSIFIABLE: with the shape gate disabled (is_valid_claude_secret -> always True) the SAME junk
#    secret sails through to the store and IS stored -> the gate is what does the work. ──────────────
echo "(10) BUG #23 server shape gate — the corrupt-cred (2199-char setup-token dump) is REFUSED, not stored [FALSIFIABLE]"
D10_OUT="$EXT/d10.out"; D10_ERR="$EXT/d10.err"
"$PY" - >"$D10_OUT" 2>"$D10_ERR" <<'PYEOF'
import json, os, secrets, sys
sys.path.insert(0, os.environ["LIB"])
import cp_auth as A
import cp_publicsurface as PS
import cp_team_creds as TC
import claude_cred

os.environ["HEIMDALL_PUBLIC_SURFACE"] = "0"; os.environ["HEIMDALL_TEAM_CRED_STORE"] = "local"
H = os.environ["HEIMDALL_HOME"]
out = {}

def _fresh_team():
    hd = "haid:shape." + secrets.token_hex(4); _priv, pub = A.generate_keypair()
    tid = A.derive_team_id(secrets.token_urlsafe(16)); A.register_key(hd, pub, team_id=tid)
    return hd, tid

def _post(hd, secret, kind="oauth_token"):
    return PS.register_team_cred(A.Identity(hd),
        {"body": json.dumps({"kind": kind, "secret": secret}).encode("utf-8")}, home=H)

# reconstruct the corrupt 2199-char `claude setup-token` dump: ANSI + banner + the token buried.
ESC = "\x1b"; real = "sk-ant-oat01-" + secrets.token_urlsafe(70)
spinner = "".join(ESC + "[2K" + ESC + "[1G" + f for f in ["⠋","⠙","⠹","⠸"] * 40)
banner = (ESC + "]0;claude\x07" + ESC + "[1mWelcome to Claude Code" + ESC + "[0m\r\n"
          "Your OAuth token:\r\n" + ESC + "[32m" + real + ESC + "[0m\r\n"
          "Visit https://console.anthropic.com/oauth/authorize?x=1 to continue\r\n")
blob = spinner + banner + (ESC + "[2K") * 200
out["blob_is_big"] = (len(blob) >= 2199)

# (a) the decorated blob -> 422 bad_secret_shape, NOT stored.
hd, tid = _fresh_team()
st, body = _post(hd, blob)
out["blob_422"] = (st == 422 and body.get("error") == "bad_secret_shape")
out["blob_not_stored"] = (TC.get_team_cred(tid, home=H) is None)
out["blob_no_secret_in_body"] = (real not in json.dumps(body) and "\x1b" not in json.dumps(body))

# (b) a control-char secret (valid token with an embedded ESC) -> 422, NOT stored.
hd2, tid2 = _fresh_team()
ctrl = "sk-ant-oat01-" + ESC + "[31m" + secrets.token_urlsafe(40)
st2, body2 = _post(hd2, ctrl)
out["ctrl_422"] = (st2 == 422 and body2.get("error") == "bad_secret_shape")
out["ctrl_not_stored"] = (TC.get_team_cred(tid2, home=H) is None)

# (c) an OVERSIZED secret (>200 chars) -> 422, NOT stored.
hd3, tid3 = _fresh_team()
st3, _ = _post(hd3, "sk-ant-oat01-" + "A" * 300)
out["big_422"] = (st3 == 422)
out["big_not_stored"] = (TC.get_team_cred(tid3, home=H) is None)

# (d) a CLEAN token STILL passes -> 200 stored, env carries EXACTLY it (the gate is not a blanket deny).
hd4, tid4 = _fresh_team()
clean = "sk-ant-oat01-" + secrets.token_urlsafe(40)
st4, body4 = _post(hd4, clean)
out["clean_200"] = (st4 == 200 and body4.get("stored") is True)
out["clean_stored"] = (TC.env_for_team(tid4, home=H).get("CLAUDE_CODE_OAUTH_TOKEN") == clean)

# (e) FALSIFIER — disable the shape gate (is_valid -> always True) and the SAME control-char secret
#     now sails through and IS STORED. Proves the gate (not some other check) blocks the junk.
hd5, tid5 = _fresh_team()
_orig = claude_cred.is_valid_claude_secret
claude_cred.is_valid_claude_secret = lambda secret, kind: True
try:
    st5, _ = _post(hd5, ctrl)
    out["falsifier_stores_without_gate"] = (st5 == 200 and TC.get_team_cred(tid5, home=H) is not None)
finally:
    claude_cred.is_valid_claude_secret = _orig

sys.stdout.write(json.dumps(out))
PYEOF
j10() { "$PY" -c "import json;print(json.load(open('$D10_OUT')).get('$1'))" 2>/dev/null; }
[ "$(j10 blob_is_big)" = "True" ] || bad "10.0 fixture broken: the reconstructed setup-token dump is < 2199 chars"
[ "$(j10 blob_422)" = "True" ] && [ "$(j10 blob_not_stored)" = "True" ] && [ "$(j10 blob_no_secret_in_body)" = "True" ] \
  && ok "10.1 the 2199-char decorated \`claude setup-token\` dump -> 422 bad_secret_shape, NOT stored, no secret/ANSI echoed" \
  || bad "10.1 the corrupt decorated blob was not refused/kept-out-of-store (see $D10_OUT)"
[ "$(j10 ctrl_422)" = "True" ] && [ "$(j10 ctrl_not_stored)" = "True" ] \
  && ok "10.2 a control-char secret -> 422, NOT stored" || bad "10.2 control-char secret not refused (see $D10_OUT)"
[ "$(j10 big_422)" = "True" ] && [ "$(j10 big_not_stored)" = "True" ] \
  && ok "10.3 an oversized (>200-char) secret -> 422, NOT stored" || bad "10.3 oversized secret not refused (see $D10_OUT)"
[ "$(j10 clean_200)" = "True" ] && [ "$(j10 clean_stored)" = "True" ] \
  && ok "10.4 a CLEAN sk-ant-oat token STILL passes -> 200 stored, env carries exactly it (not a blanket deny)" \
  || bad "10.4 a clean token was wrongly refused (see $D10_OUT)"
[ "$(j10 falsifier_stores_without_gate)" = "True" ] \
  && ok "10.5 FALSIFIER: with the shape gate disabled the SAME control-char secret IS stored -> the gate does the work" \
  || bad "10.5 the falsifier did not demonstrate the gate is load-bearing (see $D10_OUT)"

echo
echo "============================================================"
printf "heimdall-tenant-onboard: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
