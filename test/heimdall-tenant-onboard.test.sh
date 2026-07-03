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
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$EXT"; }
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
printf '%s' "$RR_OUT" | grep -q "redacted" && printf '%s' "$RR_OUT" | grep -q "/team/cred" \
  && printf '%s' "$RR_OUT" | grep -q "/team/install" && printf '%s' "$RR_OUT" | grep -q "424242" \
  && ok "7.2 the plan shows the POST /team/cred (redacted) + POST /team/install (id 424242) shape" \
  || bad "7.2 the dry-run plan is missing the redacted-secret / route / install-id markers"

echo
echo "============================================================"
printf "heimdall-tenant-onboard: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
