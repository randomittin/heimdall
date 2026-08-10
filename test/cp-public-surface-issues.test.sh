#!/usr/bin/env bash
# cp-public-surface-issues.test.sh — THE PUBLIC-SURFACE EXPOSURE falsifier for the SIGNED
# anonymized-issue intake (POST /issues) + the k-anon issue AGGREGATE it feeds.
#
# WHY THIS EXISTS. Wave-3 wire-public-surface adds ("POST", "/issues") to
# cp_publicsurface.PUBLIC_ROUTES so the signed issue-corpus flush is SERVED signed+gated on the
# --allow-unauthenticated public surface EXACTLY like /corpus. This belt proves the exposure does
# NOT open a privacy hole — the exposed intake still feeds a k-anon-gated, security-excluded,
# tenant-isolated aggregate — under BOTH the LocalBackend and the DEPLOYED Firestore StateBackend.
# Each section is a RED-without-fix falsifier mapped to an invariant in
# evals/oracles/issue-collection/INVARIANTS.md:
#
#   SECTION 1  BOUNDARY (real server)  — with HEIMDALL_PUBLIC_SURFACE=1, an UNSIGNED POST /issues
#              is 401 (SERVED + auth-gated at the §3 chokepoint, INV-E), NOT a flat 404. A gated
#              route (/dispatch) is 404 (the boundary is active + discriminating). FALSIFIER:
#              remove ("POST","/issues") from PUBLIC_ROUTES => /issues flat-404s like a gated
#              route => the "unsigned /issues -> 401" assertion goes RED.
#   SECTION 2  PRIVACY through the exposed intake (LocalBackend) —
#              INV-B  a signature bucket seen by < 10 distinct teams is SUPPRESSED (no metrics);
#                     >= 10 is PUBLISHED. Sub-k rates NEVER appear in the public aggregate.
#              INV-F  a security_sensitive record pushed through /issues is DROPPED at the intake
#                     boundary (blocked_security, nothing stored) and NEVER reaches the aggregate.
#              INV-G  a lone tenant's signature (cohort of one) is SUPPRESSED (tenant A's rates are
#                     never visible to tenant B via the aggregate); the aggregate reads ONLY the
#                     isolated corpus namespace — a control-plane record NEVER surfaces, and the
#                     issue backend can never resolve a control-plane rel (and vice-versa).
#              INV-C  a verified caller with NO registered team -> 403 fail-closed (no write).
#   SECTION 3  FIRESTORE-MODE round-trip (deployed-shape guard) — the SAME signed-ingest ->
#              aggregate path holds under the REAL FirestoreBackend (HEIMDALL_STATE_BACKEND=
#              firestore), no "__" doc-id slug collision, no path()-under-firestore raise.
#              FALSIFIER: LocalBackend-green but Firestore-broken -> RED (the presence bug taught
#              us LocalBackend-green != Firestore-green).
#
# Crypto-gated (the intake is signed): SKIP cleanly when no cryptography|pynacl. stdlib python +
# bash only. Hermetic: every read/write is pinned to a throwaway --home and a UNIQUE corpus
# namespace so the isolation proof is honest. ZERO real GCP / ZERO spend (Section 3 uses the SAME
# faithful in-process firestore fake the cp-*-firestore + corpus-ingest gates use).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
LIB="$ROOT/bin/lib"
CLI="$ROOT/bin/heimdall-control-plane"
export LIB ROOT
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: no python" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# Crypto is required — the intake is a SIGNED write, and serve mints a server identity.
if ! "$PY" -c "import sys;sys.path.insert(0,'$LIB');import cp_auth;sys.exit(0 if cp_auth.crypto_available() else 1)"; then
  echo "  SKIP no crypto backend (cryptography|pynacl) — the signed /issues intake needs it."
  echo "cp-public-surface-issues: 0 passed, 0 failed (SKIPPED — no crypto)"
  exit 0
fi

ROOT_T="$(mktemp -d -t ps-issues.XXXXXX)"
SRV1=""
cleanup(){ [ -n "$SRV1" ] && { kill "$SRV1" 2>/dev/null; wait "$SRV1" 2>/dev/null; }; rm -rf "$ROOT_T"; }
trap cleanup EXIT

# ── SECTION 1 — the PUBLIC-SURFACE BOUNDARY falsifier (real serve subprocess over a socket) ──
echo "== cp-public-surface ISSUES exposure belt =="
echo
echo "── SECTION 1 — boundary: POST /issues is SERVED + auth-gated (401), not a flat 404"

[ -x "$CLI" ] || { bad "S1 $CLI not executable"; }

freeport(){ "$PY" -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()"; }
httpstat(){ "$PY" - "$@" <<'PY'
import sys, urllib.request, urllib.error
m, u = sys.argv[1], sys.argv[2]
data = sys.argv[3].encode() if len(sys.argv) > 3 and sys.argv[3] else None
req = urllib.request.Request(u, data=data, method=m)
try:
    print(urllib.request.urlopen(req, timeout=5).status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print(0)
PY
}
waitup(){ for _ in $(seq 1 60); do [ "$(httpstat GET "$1/healthz")" = "200" ] && return 0; sleep 0.1; done; return 1; }

if [ -x "$CLI" ]; then
  PKI="$("$PY" -c "import base64,os;print(base64.b64encode(os.urandom(32)).decode())")"
  P1="$(freeport)"; U1="http://127.0.0.1:$P1"
  HMD_CP_GUARD_PID=$$ HEIMDALL_PUBLIC_SURFACE=1 HEIMDALL_CP_PKI_KEY="$PKI" HEIMDALL_ENROLL_TOKEN="ps-issues-fixture-$$" \
    HEIMDALL_HOME="$ROOT_T/serve" \
    "$CLI" serve --host 127.0.0.1 --port "$P1" >/dev/null 2>&1 &
  SRV1=$!
  if waitup "$U1"; then
    ok "public surface up (HEIMDALL_PUBLIC_SURFACE=1)"

    # CONTROL — a gated route is a flat 404 on the public surface (boundary active + discriminating).
    c_disp="$(httpstat POST "$U1/dispatch" '{}')"
    [ "$c_disp" = "404" ] \
      && ok "control: gated /dispatch -> 404 (boundary active; never resolves/auths)" \
      || bad "control: gated /dispatch -> $c_disp (expected 404 — boundary broken)"

    # THE FALSIFIER — an UNSIGNED POST /issues is 401 (allowlisted => SERVED => reaches the §3
    # auth chokepoint, which refuses the unsigned push), NOT the 404 a non-allowlisted route gets.
    c_iss="$(httpstat POST "$U1/issues" '{"issues":[]}')"
    if [ "$c_iss" = "401" ]; then
      ok "INV-E: unsigned POST /issues -> 401 (SERVED + auth-gated on the public surface, not a flat 404)"
    elif [ "$c_iss" = "404" ]; then
      bad "INV-E: unsigned POST /issues -> 404 (NOT allowlisted — the /issues exposure is missing)"
    else
      bad "INV-E: unsigned POST /issues -> $c_iss (expected 401)"
    fi

    # The discriminator must be REAL: an allowlisted-but-unsigned route (401) differs from a gated
    # one (404). If they were equal, the allowlist entry would be meaningless.
    [ "$c_iss" != "$c_disp" ] \
      && ok "boundary discriminates: /issues ($c_iss) != gated /dispatch ($c_disp)" \
      || bad "boundary does NOT discriminate: /issues and /dispatch both -> $c_iss"

    kill "$SRV1" 2>/dev/null; wait "$SRV1" 2>/dev/null; SRV1=""
  else
    bad "S1 public server did not come up"
  fi
fi

# ── SECTION 2 — PRIVACY invariants through the EXPOSED signed intake (LocalBackend) ──
echo
echo "── SECTION 2 — privacy through the exposed intake (INV-B / INV-F / INV-G / INV-C)"

export HEIMDALL_HOME="$ROOT_T/home"
mkdir -p "$HEIMDALL_HOME"
export HEIMDALL_CORPUS_NAMESPACE="heimdall_corpus_ps_issue_exposure"

DRIVER="$ROOT_T/driver.py"
cat >"$DRIVER" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["LIB"])
import cp_auth
import cp_issue_aggregate as AGG
import cp_issue_ingest as ING
import cp_state
import issue_corpus

HOME = os.environ["HEIMDALL_HOME"]
K = issue_corpus.ISSUE_K_ANONYMITY_MIN  # 10
out = {}


def rec(sig, ec="lint", sec=False):
    """An issue_v1 as a client spools it (nested schema); the server REBUILDS + re-stamps it."""
    return {"schema": "issue_v1", "consent_version": "c1",
            "ids": {"issue_id": "i-" + sig, "team_id_hash": "CLAIM_OTHER_TEAM",
                    "repo_class_hash": "rc"},
            "when": {"ts": "t", "tz_bucket": "u"},
            "signal": {"error_class": ec, "signature_hash": sig, "gate": "lint",
                       "phase": "verify", "command": "verify", "severity": "error"},
            "env": {"os_class": "mac", "ci": False, "hmd_version": "v2"},
            "security_sensitive": sec}


def ingest(secret, haid, records):
    """Drive the REAL exposed path: register a team key, SIGN a POST /issues, verify the identity
    exactly as the §3 chokepoint does, then hand it to the registered handler. Returns the response
    (status, body)."""
    priv, pub = cp_auth.generate_keypair()
    cp_auth.register_key(haid, pub, team_id=cp_auth.derive_team_id(secret), home=HOME)
    body = json.dumps({"issues": records})
    sig = cp_auth.sign(priv, cp_auth.canonical_message("POST", "/issues", body))
    ident = cp_auth.verify_identity(
        {"method": "POST", "path": "/issues", "body": body, "haid": haid, "signature": sig},
        home=HOME)
    resp = ING.issues_route(ident, {"body": body}, home=HOME)
    return resp.status, resp.body


# ── INV-B — >= K distinct teams PUBLISH a signature; < K teams SUPPRESS (sub-k never surfaces) ──
for i in range(K):
    st, _ = ingest("pub-secret-%02d-xxxxxxxxxxxxxxxxxxxx" % i, "haid:pub%02d" % i, [rec("S_pub")])
out["pub_last_status"] = st
for i in range(K - 1):
    ingest("sub-secret-%02d-xxxxxxxxxxxxxxxxxxxx" % i, "haid:sub%02d" % i, [rec("S_sub")])

# ── INV-F — a security_sensitive record pushed through the intake is DROPPED (never stored) ──
sec_st, sec_body = ingest("sec-secret-01-xxxxxxxxxxxxxxxxxxxx", "haid:sec01",
                          [rec("S_secret", ec="auth", sec=True)])
out["sec_status"] = sec_st
out["sec_blocked_security"] = sec_body.get("blocked_security")
out["sec_ingested"] = sec_body.get("ingested")

# ── INV-G — a LONE tenant's signature (cohort of one) must SUPPRESS (A not visible to B) ──
# One team pushes K identical records under S_solo: many rows, still ONE distinct team.
ingest("solo-secret-01-xxxxxxxxxxxxxxxxxxxx", "haid:solo01", [rec("S_solo") for _ in range(K)])

# ── INV-C — a verified caller with NO registered team -> 403 fail-closed (no write) ──
# Enroll a key with NO team binding, sign, and drive the handler: it must refuse before any store.
priv_nt, pub_nt = cp_auth.generate_keypair()
cp_auth.register_key("haid:noteam", pub_nt, team_id=None, home=HOME)
body_nt = json.dumps({"issues": [rec("S_noteam")]})
sig_nt = cp_auth.sign(priv_nt, cp_auth.canonical_message("POST", "/issues", body_nt))
ident_nt = cp_auth.verify_identity(
    {"method": "POST", "path": "/issues", "body": body_nt, "haid": "haid:noteam",
     "signature": sig_nt}, home=HOME)
resp_nt = ING.issues_route(ident_nt, {"body": body_nt}, home=HOME)
out["noteam_status"] = resp_nt.status

# Plant an OPS/presence record in the CONTROL-PLANE namespace (namespace=None) for the INV-G proof.
cp_backend = cp_state.get_backend(home=HOME)
cp_backend.append_line("presence/acme/dev.ndjson", {"online": True, "marker": "OPSDATA_ctrlplane"})

# Roll up the WHOLE exposed store and inspect the published aggregate.
agg = AGG.run_daily_aggregate(home=HOME)
blob = json.dumps(agg)
sig_dim = agg["dimensions"]["by_signature"]


def bucket(sig):
    keys = [k for k in sig_dim if sig in k]
    return sig_dim[keys[0]] if keys else None


b_pub = bucket("S_pub") or {}
b_sub = bucket("S_sub") or {}
b_solo = bucket("S_solo") or {}
out["b_pub_suppressed"] = bool(b_pub.get("suppressed"))
out["b_pub_teams"] = b_pub.get("teams")
out["b_pub_has_metrics"] = ("n" in b_pub) and not b_pub.get("suppressed")
out["b_sub_suppressed"] = bool(b_sub.get("suppressed"))
out["b_sub_has_metrics"] = "n" in b_sub
out["b_sub_reason"] = b_sub.get("reason")
out["b_solo_suppressed"] = bool(b_solo.get("suppressed"))
out["secret_sig_in_output"] = "S_secret" in blob
out["secret_bucket_present"] = bucket("S_secret") is not None
out["ops_marker_in_aggregate"] = "OPSDATA_ctrlplane" in blob
out["total_teams"] = agg.get("total_teams")

# The issue backend must NOT resolve a control-plane rel, and vice-versa (cross-namespace wall).
corp_backend = AGG._backend(HOME)
out["corpus_reads_ctrlplane"] = corp_backend.read_lines("presence/acme/dev.ndjson")
out["ctrlplane_reads_issues"] = cp_backend.read_lines(AGG._issue_rel(
    cp_auth.registered_team("haid:pub00", home=HOME)))
out["corpus_root"] = corp_backend.path("").rstrip("/").split("/")[-1]
out["ctrlplane_root"] = cp_backend.path("").rstrip("/").split("/")[-1]

print(json.dumps(out))
PYEOF

OUT="$("$PY" "$DRIVER" 2>"$ROOT_T/err")"
if [ -z "$OUT" ]; then
  bad "S2 driver produced no output (see stderr)"; cat "$ROOT_T/err" >&2
else
  echo "  driver: $OUT"
  j() { printf '%s' "$OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null; }

  [ "$(j "['pub_last_status']")" = "200" ] \
    && ok "exposed intake: a signed /issues batch LANDS (200) per team" \
    || bad "exposed intake: signed ingest did not land 200 — out=$OUT"

  [ "$(j "['b_pub_suppressed']")" = "False" ] && [ "$(j "['b_pub_has_metrics']")" = "True" ] \
    && [ "$(j "['b_pub_teams']")" = "10" ] \
    && ok "INV-B: a signature seen by >= 10 distinct teams is PUBLISHED (metrics served)" \
    || bad "INV-B: a >= 10-team signature was not published — out=$OUT"

  [ "$(j "['b_sub_suppressed']")" = "True" ] && [ "$(j "['b_sub_has_metrics']")" = "False" ] \
    && [ "$(j "['b_sub_reason']")" = "k_anonymity" ] \
    && ok "INV-B: a signature seen by < 10 distinct teams is SUPPRESSED — NO metrics in the public aggregate (FALSIFIER)" \
    || bad "INV-B: a sub-10-team bucket surfaced metrics in the public aggregate — out=$OUT"

  [ "$(j "['sec_status']")" = "422" ] && [ "$(j "['sec_blocked_security']")" = "1" ] \
    && [ "$(j "['sec_ingested']")" = "False" ] \
    && ok "INV-F: a security_sensitive record pushed to /issues is DROPPED at the intake (422, nothing stored)" \
    || bad "INV-F: a security_sensitive record was not dropped at the intake — out=$OUT"

  [ "$(j "['secret_sig_in_output']")" = "False" ] && [ "$(j "['secret_bucket_present']")" = "False" ] \
    && ok "INV-F: the security signature NEVER appears in the published aggregate (FALSIFIER)" \
    || bad "INV-F: a security signal reached the public aggregate — out=$OUT"

  [ "$(j "['b_solo_suppressed']")" = "True" ] \
    && ok "INV-G: a LONE tenant's signature (cohort of one) is SUPPRESSED — tenant A's rates are never visible to tenant B" \
    || bad "INV-G: a single-tenant signature surfaced its rates (cross-tenant leak) — out=$OUT"

  [ "$(j "['noteam_status']")" = "403" ] \
    && ok "INV-C: a verified caller with NO registered team -> 403 fail-closed (no write)" \
    || bad "INV-C: a no-team caller was not refused 403 — out=$OUT"

  [ "$(j "['ops_marker_in_aggregate']")" = "False" ] \
    && ok "INV-G: the published aggregate NEVER carries a control-plane record" \
    || bad "INV-G: a control-plane marker leaked into the aggregate — out=$OUT"

  [ "$(j "['corpus_reads_ctrlplane']")" = "[]" ] && [ "$(j "['ctrlplane_reads_issues']")" = "[]" ] \
    && ok "INV-G: the issue backend can NEVER resolve a control-plane rel, and vice-versa (FALSIFIER)" \
    || bad "INV-G: a namespace leaked (cross-namespace read path) — out=$OUT"

  CROOT="$(j "['corpus_root']")"; CPROOT="$(j "['ctrlplane_root']")"
  [ -n "$CROOT" ] && [ -n "$CPROOT" ] && [ "$CROOT" != "$CPROOT" ] \
    && ok "INV-G: disjoint on-disk roots: issue-store=$CROOT vs control-plane=$CPROOT" \
    || bad "INV-G: the issue store + control-plane share a root — issue=$CROOT cp=$CPROOT"
fi

# ── SECTION 2b — ABUSE-GATE PARITY with /corpus (F-1/F-2/F-3: replay + per-team + per-IP) ──
#
# WHY THIS EXISTS. /issues was allowlisted + auth-gated (Section 1) but had NO abuse half: no
# pre-auth per-IP flood shed (F-3 crypto-DoS), no post-auth per-team cap (F-2 aggregate/storage
# skew), no replay-nonce (F-1 — a captured signed batch replays indefinitely, re-appends every
# record, inflates one tenant's per-signature counts and CORRUPTS the INV-B k-anon aggregate).
# This section drives the SAME gate seam the server wires (cp_publicsurface.check_issues_*),
# mirroring the /corpus + /rr-task gate proofs (heimdall-cp-authz-gate.test.sh:213-316). Each
# assertion is RED-without-fix (the gate functions do not exist) and GREEN-with.
echo
echo "── SECTION 2b — abuse gates: /issues at parity with /corpus (429 flood shed + 401 replay)"

GATE_DRIVER="$ROOT_T/gate_driver.py"
cat >"$GATE_DRIVER" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["LIB"])
import cp_auth
import cp_publicsurface as PS
import cp_server as CS

HOME = os.environ["HEIMDALL_HOME"]
os.environ["HEIMDALL_PUBLIC_SURFACE"] = "1"
now = 1_000_000
out = {}

# RED-WITHOUT-FIX: if the /issues abuse gates were never added, the accessors below are absent —
# print an all-False result so each assertion below goes RED (rather than crashing opaquely).
if not (hasattr(PS, "check_issues_pre_auth") and hasattr(PS, "check_issues_post_auth")):
    print(json.dumps({"gates_missing": True}))
    sys.exit(0)


def team(secret, haid):
    """Register a team key so the per-team cap keys on a REAL server-derived team_id_hash."""
    priv, pub = cp_auth.generate_keypair()
    cp_auth.register_key(haid, pub, team_id=cp_auth.derive_team_id(secret), home=HOME)
    return cp_auth.Identity(haid)


id_team = team("issues-team-secret-xxxxxxxxxxxxxxxxxxxx", "haid:iss-team")
id_rep = team("issues-rep-secret-xxxxxxxxxxxxxxxxxxxx", "haid:iss-rep")
id_sib = team("issues-sib-secret-xxxxxxxxxxxxxxxxxxxx", "haid:iss-sib")

# ── F-3 per-IP crypto-DoS shed: the pre-auth per-IP flood trips 429 BEFORE any crypto is spent.
os.environ["HEIMDALL_ISSUES_IP_LIMIT"] = "3"
os.environ["HEIMDALL_ISSUES_IP_WINDOW"] = "60"
ip_req = {"peer_ip": "9.9.9.9", "body": json.dumps({"issues": []})}
out["ip_flood_429"] = 0
for _ in range(12):
    r = PS.check_issues_pre_auth(ip_req, home=HOME, now=now)
    if isinstance(r, tuple) and r[0] == 429:
        out["ip_flood_429"] = 1
        out["ip_scope"] = r[1].get("scope")
        break

# ── F-2 per-team cap: the post-auth per-team flood trips 429. Fresh nonce each call so the RATE
#    check (which runs first) is what trips — never the replay check.
os.environ["HEIMDALL_ISSUES_TEAM_LIMIT"] = "3"
os.environ["HEIMDALL_ISSUES_TEAM_WINDOW"] = "60"
out["team_flood_429"] = 0
for i in range(12):
    body = json.dumps({"issues": [], "nonce": "n-team-%02d" % i, "ts": now})
    r = PS.check_issues_post_auth(id_team, {"body": body, "peer_ip": "8.8.8.8"}, home=HOME, now=now)
    if isinstance(r, tuple) and r[0] == 429:
        out["team_flood_429"] = 1
        out["team_scope"] = r[1].get("scope")
        break

# ── F-1 replay-nonce: the SAME signed (nonce, ts) twice -> first ok, second 401 replay_. Team cap
#    raised high so the RATE check cannot trip first (this proves the REPLAY gate, not the cap).
os.environ["HEIMDALL_ISSUES_TEAM_LIMIT"] = "30"
rep_body = json.dumps({"issues": [], "nonce": "issues-replayZ", "ts": now})
g1 = PS.check_issues_post_auth(id_rep, {"body": rep_body, "peer_ip": "7.7.7.7"}, home=HOME, now=now)
g2 = PS.check_issues_post_auth(id_rep, {"body": rep_body, "peer_ip": "7.7.7.7"}, home=HOME, now=now)
out["nonce_first_ok"] = (g1 is None)
out["nonce_replay_401"] = (isinstance(g2, tuple) and g2[0] == 401
                           and str(g2[1].get("error", "")).startswith("replay_"))

# structural: /issues is in the allowlist AND SIGNED-ONLY (goes through §3, not a pre-auth route),
# exactly like /corpus.
out["issues_public"] = (PS.is_public_route("POST", "/issues") is True
                        and ("POST", "/issues") in PS.PUBLIC_ROUTES)
out["issues_signed_only"] = (CS._public_route("POST", "/issues") is None)

# sibling intact: the /corpus post-auth gate still passes (we did not break /corpus).
cg = PS.check_corpus_post_auth(
    id_sib, {"body": json.dumps({"nonce": "corpus-z", "ts": now}), "peer_ip": "4.4.4.4"},
    home=HOME, now=now)
out["corpus_sibling_ok"] = (cg is None)

print(json.dumps(out))
PYEOF

GOUT="$("$PY" "$GATE_DRIVER" 2>"$ROOT_T/gate.err")"
if [ -z "$GOUT" ]; then
  bad "S2b gate driver produced no output (see stderr)"; cat "$ROOT_T/gate.err" >&2
else
  echo "  gate driver: $GOUT"
  gj() { printf '%s' "$GOUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null; }

  [ "$(gj "['ip_flood_429']")" = "1" ] && [ "$(gj "['ip_scope']")" = "issues_ip" ] \
    && ok "F-3: pre-auth per-IP flood sheds 429 (issues_ip) BEFORE crypto — at parity with /corpus" \
    || bad "F-3: no per-IP 429 flood shed on /issues (crypto-DoS surface open) — out=$GOUT"

  [ "$(gj "['team_flood_429']")" = "1" ] && [ "$(gj "['team_scope']")" = "issues_team" ] \
    && ok "F-2: post-auth per-team cap trips 429 (issues_team) — bounds one tenant's flush + aggregate skew" \
    || bad "F-2: no per-team 429 cap on /issues (storage/aggregate skew open) — out=$GOUT"

  [ "$(gj "['nonce_first_ok']")" = "True" ] && [ "$(gj "['nonce_replay_401']")" = "True" ] \
    && ok "F-1: a replayed signed /issues batch (same nonce) -> 401 replay_ — defeats k-anon aggregate corruption" \
    || bad "F-1: the replay-nonce gate did not refuse a replayed /issues batch — out=$GOUT"

  [ "$(gj "['issues_public']")" = "True" ] && [ "$(gj "['issues_signed_only']")" = "True" ] \
    && ok "/issues is in the public allowlist AND SIGNED-ONLY (rides §3 like /corpus)" \
    || bad "/issues route wiring is wrong — out=$GOUT"

  [ "$(gj "['corpus_sibling_ok']")" = "True" ] \
    && ok "sibling intact: the /corpus post-auth gate still passes (the sibling is not broken)" \
    || bad "the /corpus sibling gate regressed — out=$GOUT"
fi

# ── SECTION 3 — FIRESTORE-MODE round-trip (deployed-shape: LocalBackend-green != Firestore-green) ──
echo
echo "── SECTION 3 — firestore-mode ingest -> aggregate + isolation (the deployed-shape guard)"

FS_EXT="$ROOT_T/fs"
mkdir -p "$FS_EXT"
FS_HOME="$FS_EXT/home"
mkdir -p "$FS_HOME"

MODE=""
if [ -n "${FIRESTORE_EMULATOR_HOST:-}" ] \
   && "$PY" -c "import google.cloud.firestore" >/dev/null 2>&1; then
  MODE="emulator"
  echo "  using caller-provided FIRESTORE_EMULATOR_HOST=$FIRESTORE_EMULATOR_HOST (real client)"
fi
# Faithful in-process fake (the SAME double the cp-*-firestore + corpus-ingest gates use). It is
# deterministic + zero-dep and it exercises the SHIPPED FirestoreBackend code (only the external
# service is a double), which is exactly what this deployed-shape guard needs.
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

FS_DRIVER="$ROOT_T/fs_driver.py"
cat >"$FS_DRIVER" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["LIB"])
import cp_auth
import cp_issue_aggregate as AGG
import cp_issue_ingest as ING
import cp_state
import issue_corpus

HOME = os.environ["HEIMDALL_HOME"]
K = issue_corpus.ISSUE_K_ANONYMITY_MIN  # 10
out = {}


def rec(sig, ec="lint", sec=False):
    return {"schema": "issue_v1", "consent_version": "c1",
            "ids": {"issue_id": "i-" + sig, "team_id_hash": "CLAIM", "repo_class_hash": "rc"},
            "when": {"ts": "t", "tz_bucket": "u"},
            "signal": {"error_class": ec, "signature_hash": sig, "gate": "lint",
                       "phase": "verify", "command": "verify", "severity": "error"},
            "env": {"os_class": "mac", "ci": False, "hmd_version": "v2"},
            "security_sensitive": sec}


def ingest(secret, haid, records):
    priv, pub = cp_auth.generate_keypair()
    cp_auth.register_key(haid, pub, team_id=cp_auth.derive_team_id(secret), home=HOME)
    body = json.dumps({"issues": records})
    sig = cp_auth.sign(priv, cp_auth.canonical_message("POST", "/issues", body))
    ident = cp_auth.verify_identity(
        {"method": "POST", "path": "/issues", "body": body, "haid": haid, "signature": sig},
        home=HOME)
    resp = ING.issues_route(ident, {"body": body}, home=HOME)
    team = cp_auth.registered_team(haid, home=HOME)
    return resp.status, team


# Drive the SIGNED intake UNDER THE FIRESTORE BACKEND: K teams publish S_pub, K-1 suppress S_sub,
# one security_sensitive push is dropped.
last_status = None
first_team = None
for i in range(K):
    last_status, team = ingest("fs-pub-%02d-xxxxxxxxxxxxxxxxxxxx" % i, "haid:fspub%02d" % i, [rec("S_pub")])
    if first_team is None:
        first_team = team
for i in range(K - 1):
    ingest("fs-sub-%02d-xxxxxxxxxxxxxxxxxxxx" % i, "haid:fssub%02d" % i, [rec("S_sub")])
sec_status, _ = ingest("fs-sec-01-xxxxxxxxxxxxxxxxxxxx", "haid:fssec01",
                       [rec("S_secret", ec="auth", sec=True)])
out["fs_last_status"] = last_status
out["fs_sec_status"] = sec_status

# No path SEGMENT may contain the firestore "__" doc-id separator (the presence-bug class).
rel = AGG._issue_rel(first_team)
out["fs_first_team"] = first_team
out["fs_rel_segment_dunder"] = any("__" in seg for seg in rel.split("/"))

# The READ path under firestore: list partitions + fold.
landed = AGG.all_issues(home=HOME)
out["fs_landed_count"] = len(landed)

agg = AGG.run_daily_aggregate(home=HOME)
blob = json.dumps(agg)
sig_dim = agg["dimensions"]["by_signature"]


def bucket(sig):
    keys = [k for k in sig_dim if sig in k]
    return sig_dim[keys[0]] if keys else None


b_pub = bucket("S_pub") or {}
b_sub = bucket("S_sub") or {}
out["fs_pub_suppressed"] = bool(b_pub.get("suppressed"))
out["fs_pub_teams"] = b_pub.get("teams")
out["fs_sub_suppressed"] = bool(b_sub.get("suppressed"))
out["fs_secret_in_output"] = "S_secret" in blob
out["fs_total_teams"] = agg.get("total_teams")

# Cross-namespace isolation UNDER FIRESTORE: control-plane root collection vs corpus root
# collection are disjoint, so neither backend resolves the other's rel.
cp_backend = cp_state.get_backend(home=HOME)
corp_backend = AGG._backend(HOME)
cp_backend.append_line("presence/acme/dev.ndjson", {"marker": "OPSDATA_fs"})
out["fs_corpus_reads_ctrlplane"] = corp_backend.read_lines("presence/acme/dev.ndjson")
out["fs_ctrlplane_reads_issues"] = cp_backend.read_lines(rel)
out["fs_ops_marker_in_aggregate"] = "OPSDATA_fs" in blob

# path() MUST raise under firestore — and the issue code proves it NEVER calls it, because every
# ingest/read/fold above succeeded (a single path() call would have raised BackendUnavailable).
out["fs_path_raises"] = False
try:
    corp_backend.path("issues")
except cp_state.BackendUnavailable:
    out["fs_path_raises"] = True

# ── ABUSE-GATE PARITY UNDER FIRESTORE (the audit noted S3 never asserted 429/replay). The 429 +
#    replay gates must hold under the REAL FirestoreBackend too: the rate counters + the nonce
#    seen-set are durable THROUGH cp_state, so they catch a flood/replay fleet-wide. Drive the
#    SAME gate seam the server wires. Guarded so a missing gate reads False (RED-without-fix)
#    rather than crashing the whole firestore section.
import cp_publicsurface as PS
os.environ["HEIMDALL_PUBLIC_SURFACE"] = "1"
NOWG = 2_000_000
out["fs_ip_flood_429"] = 0
out["fs_nonce_first_ok"] = False
out["fs_nonce_replay_401"] = False
if hasattr(PS, "check_issues_pre_auth") and hasattr(PS, "check_issues_post_auth"):
    # F-3 per-IP flood shed under firestore.
    os.environ["HEIMDALL_ISSUES_IP_LIMIT"] = "3"
    os.environ["HEIMDALL_ISSUES_IP_WINDOW"] = "60"
    for _ in range(12):
        r = PS.check_issues_pre_auth(
            {"peer_ip": "5.5.5.5", "body": json.dumps({"issues": []})}, home=HOME, now=NOWG)
        if isinstance(r, tuple) and r[0] == 429:
            out["fs_ip_flood_429"] = 1
            break
    # F-1 replay-nonce under firestore (durable seen-set). Team cap high so the RATE check does
    # not trip first — this proves the replay gate holds under the firestore-backed seen-set.
    priv, pub = cp_auth.generate_keypair()
    cp_auth.register_key("haid:fsrep", pub,
                         team_id=cp_auth.derive_team_id("fs-rep-secret-xxxxxxxxxxxxxxxxxxxx"),
                         home=HOME)
    id_rep = cp_auth.Identity("haid:fsrep")
    os.environ["HEIMDALL_ISSUES_TEAM_LIMIT"] = "30"
    rb = json.dumps({"issues": [], "nonce": "fs-issues-replay", "ts": NOWG})
    fg1 = PS.check_issues_post_auth(id_rep, {"body": rb, "peer_ip": "6.6.6.6"}, home=HOME, now=NOWG)
    fg2 = PS.check_issues_post_auth(id_rep, {"body": rb, "peer_ip": "6.6.6.6"}, home=HOME, now=NOWG)
    out["fs_nonce_first_ok"] = (fg1 is None)
    out["fs_nonce_replay_401"] = (isinstance(fg2, tuple) and fg2[0] == 401)

print(json.dumps(out))
PYEOF

FSOUT="$(env HEIMDALL_STATE_BACKEND=firestore HEIMDALL_HOME="$FS_HOME" \
  HEIMDALL_CORPUS_NAMESPACE="ps_issue_fs_ns" \
  HEIMDALL_FIRESTORE_ROOT="ps_issue_fs_cp" HEIMDALL_FIRESTORE_PROJECT="ps-issue-fs-test" \
  "$PY" "$FS_DRIVER" 2>"$ROOT_T/fs.err")"
if [ -z "$FSOUT" ]; then
  bad "S3 firestore driver produced no output (see stderr)"; cat "$ROOT_T/fs.err" >&2
else
  echo "  fs driver: $FSOUT"
  fj() { printf '%s' "$FSOUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null; }

  [ "$(fj "['fs_last_status']")" = "200" ] && [ "$(fj "['fs_landed_count']")" = "$(( 10 + 9 ))" ] \
    && ok "S3a signed /issues LANDS + reads back under the FIRESTORE backend (server-derived team)" \
    || bad "S3a ingest+read under firestore failed — fs=$FSOUT"

  [ "$(fj "['fs_rel_segment_dunder']")" = "False" ] \
    && ok "S3b no '__' in any issue path segment (no firestore doc-id slug collision)" \
    || bad "S3b a firestore '__' doc-id slug collision in an issue path segment — fs=$FSOUT"

  [ "$(fj "['fs_pub_suppressed']")" = "False" ] && [ "$(fj "['fs_pub_teams']")" = "10" ] \
    && [ "$(fj "['fs_sub_suppressed']")" = "True" ] \
    && ok "S3c k-anon holds under firestore: >= 10 teams PUBLISH, < 10 SUPPRESS" \
    || bad "S3c the k-anon gate did not hold under firestore — fs=$FSOUT"

  [ "$(fj "['fs_sec_status']")" = "422" ] && [ "$(fj "['fs_secret_in_output']")" = "False" ] \
    && ok "S3d a security_sensitive push is dropped + never in the aggregate under firestore (INV-F)" \
    || bad "S3d a security signal survived under firestore — fs=$FSOUT"

  [ "$(fj "['fs_corpus_reads_ctrlplane']")" = "[]" ] && [ "$(fj "['fs_ctrlplane_reads_issues']")" = "[]" ] \
    && [ "$(fj "['fs_ops_marker_in_aggregate']")" = "False" ] \
    && ok "S3e cross-namespace isolation HOLDS under firestore (disjoint root collections, no ops leak)" \
    || bad "S3e a namespace leaked under firestore — fs=$FSOUT"

  [ "$(fj "['fs_path_raises']")" = "True" ] \
    && ok "S3f path() raises under firestore, yet ingest+aggregate succeeded => the issue code never calls path()" \
    || bad "S3f path() did not raise under firestore (the deployed-shape guard is inert) — fs=$FSOUT"

  [ "$(fj "['fs_ip_flood_429']")" = "1" ] \
    && ok "S3g the /issues per-IP flood gate sheds 429 UNDER FIRESTORE (the abuse gate holds in the deployed shape)" \
    || bad "S3g the /issues per-IP flood gate did not trip under firestore — fs=$FSOUT"

  [ "$(fj "['fs_nonce_first_ok']")" = "True" ] && [ "$(fj "['fs_nonce_replay_401']")" = "True" ] \
    && ok "S3h a replayed signed /issues batch -> 401 UNDER FIRESTORE (replay caught fleet-wide via the durable seen-set)" \
    || bad "S3h the /issues replay-nonce gate did not hold under firestore — fs=$FSOUT"
fi

echo
echo "──────────────────────────────────────────"
echo "cp-public-surface-issues: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] || exit 1
