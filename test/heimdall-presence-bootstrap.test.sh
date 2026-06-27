#!/usr/bin/env bash
# heimdall-presence-bootstrap.test.sh — the ZERO-CONFIG client bootstrap.
#
# WHAT THIS GATES. A dev's FIRST beat/roster must auto-resolve EVERYTHING with the dev
# exporting NOTHING: the CP url from the shipped local config, an auto-generated +
# auto-enrolled + persisted 0600 signing seed, a STABLE project id from the git remote, and
# the handle from heimdall-identity. And the graceful degrade must hold absolutely — with no
# config the statusline's roster/beat print clean + exit 0 with NO traceback.
#
# MOCKABLE — does NOT touch the live control plane. A tiny in-process HTTP responder on
# localhost mocks /enroll, /presence and /roster and LOGS what the client sent, so we assert
# the client's behavior (keygen -> enroll once -> persist 0600 -> reuse) over real HTTP
# against a fake endpoint. ZERO network egress, ZERO spend.
#
#   A. FIRST beat auto-bootstraps: a 0600 seed is generated + persisted, /enroll is called
#      EXACTLY once carrying the config's token + the public key.
#   B. SECOND beat REUSES the persisted seed: no re-enroll (still one /enroll), the seed
#      bytes are unchanged (no re-keygen).
#   C. STABLE project id: the roster read carries the NORMALIZED git remote
#      (github.com/acme/widget), not the dir name — so clones share one project.
#   D. The beat is SIGNED with the bootstrapped seed (the mock sees a signature header).
#   E. SEED PERMS are 0600 (never world/group-readable).
#   F. NO CONFIG -> clean empty roster ([]) + no-op beat + exit 0 + NO traceback (stderr
#      empty) — the virgin-checkout degrade the statusline depends on.
#
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin/heimdall-presence"
LIB="$REPO/bin/lib"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }
[ -x "$BIN" ] || { echo "FATAL: $BIN missing/!exec" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

CRYPTO="$("$PY" -c "import sys;sys.path.insert(0,'$LIB');import cp_auth;print('1' if cp_auth.crypto_available() else '0')" 2>/dev/null || echo 0)"

WORK="$(mktemp -d -t "presence-bootstrap.$(printf 'X%.0s' 1 2 3 4 5 6)")"
MOCK_PIDS=""   # every mock instance we launch (primary + the open-mode / fail-mode helpers)
cleanup() {
  for p in $MOCK_PIDS; do
    kill "$p" >/dev/null 2>&1 || true
    wait "$p" 2>/dev/null || true   # reap quietly so no "Terminated" notice prints
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

HOME_T="$WORK/home"; mkdir -p "$HOME_T"
MOCK_LOG="$WORK/mock.log"; : > "$MOCK_LOG"
TOKEN="enroll-secret-abc123"

# ── the mock control plane (records what the client sent; real HTTP, localhost only) ──
cat > "$WORK/mock_cp.py" <<'PYEOF'
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit, parse_qs

LOG = os.environ["MOCK_LOG"]
TOKEN = os.environ.get("MOCK_TOKEN", "")
# OPEN mode == empty TOKEN (HEIMDALL_ENROLL_OPEN on the real server): a tokenless enroll is
# accepted. ENROLL_FAIL makes /enroll return 500 so the client's enroll-throttle is exercised.
ENROLL_FAIL = os.environ.get("MOCK_ENROLL_FAIL", "") == "1"


def record(line):
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        return

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n > 0 else b""

    def _send(self, code, obj):
        payload = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        path = urlsplit(self.path).path
        body = self._body()
        if path == "/enroll":
            tok = self.headers.get("X-Heimdall-Enroll-Token") or ""
            team = self.headers.get("X-Heimdall-Team-Secret") or ""
            try:
                d = json.loads(body or b"{}")
            except Exception:
                d = {}
            record("enroll token=%s team=%s haid=%s pubkey=%s"
                   % (tok, team, d.get("haid"), bool(d.get("pubkey"))))
            if ENROLL_FAIL:
                self._send(500, {"error": "boom"})   # exercise the client enroll-throttle
                return
            if TOKEN and tok != TOKEN:   # TOKEN empty == OPEN mode: tokenless enroll accepted
                self._send(401, {"error": "bad_token"})
                return
            self._send(200, {"ok": True})
            return
        if path == "/presence":
            sig = 1 if self.headers.get("X-Heimdall-Signature") else 0
            record("presence sig=%d haid=%s" % (sig, self.headers.get("X-Heimdall-HAID")))
            self._send(200, {"ok": True})
            return
        self._send(404, {"error": "no_route"})

    def do_GET(self):
        split = urlsplit(self.path)
        if split.path == "/roster":
            q = parse_qs(split.query)
            proj = (q.get("project") or [""])[0]
            record("roster project=%s" % proj)
            self._send(200, {"roster": []})
            return
        self._send(404, {"error": "no_route"})


srv = HTTPServer(("127.0.0.1", 0), Handler)
sys.stdout.write("%d\n" % srv.server_address[1])
sys.stdout.flush()
srv.serve_forever()
PYEOF

# launch_mock <logfile> <token> <fail> -> echoes the bound base URL, tracks the pid for
# cleanup. token="" == OPEN mode (tokenless enroll accepted); fail="1" == /enroll returns 500.
PORT_SEQ=0
launch_mock() {
  PORT_SEQ=$((PORT_SEQ+1)); local pf="$WORK/port.$PORT_SEQ.txt"; : >"$pf"
  MOCK_LOG="$1" MOCK_TOKEN="$2" MOCK_ENROLL_FAIL="${3:-}" \
    "$PY" "$WORK/mock_cp.py" >"$pf" 2>>"$WORK/mock.err" &
  local pid=$!; MOCK_PIDS="$MOCK_PIDS $pid"; local p=""
  for _ in $(seq 1 50); do
    p="$(sed -n '1p' "$pf" 2>/dev/null || true)"
    [ -n "$p" ] && break
    kill -0 "$pid" >/dev/null 2>&1 || break
    "$PY" -c "import time;time.sleep(0.1)"
  done
  [ -n "$p" ] || { echo "FATAL: mock CP never bound a port" >&2; cat "$WORK/mock.err" >&2; exit 2; }
  printf 'http://127.0.0.1:%s\n' "$p"
}

URL="$(launch_mock "$MOCK_LOG" "$TOKEN" "")"

# the shipped local config — the ONLY thing a zero-config dev has (no env exports).
mkdir -p "$HOME_T/.heimdall"
cat > "$HOME_T/.heimdall/cp-endpoint.json" <<EOF
{"url":"$URL","enroll_token":"$TOKEN"}
EOF

# a project repo with an UPPERCASE .git remote (proves normalization to host/path lower).
PROJ_REPO="$WORK/clone"; mkdir -p "$PROJ_REPO"
git -C "$PROJ_REPO" init -q
git -C "$PROJ_REPO" config user.email "dev@example.com"
git -C "$PROJ_REPO" config user.name "Dev"
git -C "$PROJ_REPO" remote add origin "https://github.com/Acme/Widget.git"

# run the client from INSIDE the project repo with a CLEAN env (no manual exports) so the
# only configuration is the shipped config + the git remote — true zero-config.
run_presence() {
  ( cd "$PROJ_REPO" \
    && env -u HEIMDALL_CP_URL -u BASE_URL -u HEIMDALL_CP_PKI_KEY -u PKI_SEED \
           -u HMD_PROJECT -u HMD_HAID -u HMD_HANDLE \
           HOME="$HOME_T" HEIMDALL_TEAM_DIR="$HOME_T/.heimdall" "$BIN" "$@" )
}

# same clean-env runner but with a CALLER-CHOSEN HOME (so a fresh HOME == a virgin checkout
# that re-bootstraps against its own config) and a pass-through enroll throttle.
run_in() {
  local h="$1"; shift
  ( cd "$PROJ_REPO" \
    && env -u HEIMDALL_CP_URL -u BASE_URL -u HEIMDALL_CP_PKI_KEY -u PKI_SEED \
           -u HMD_PROJECT -u HMD_HAID -u HMD_HANDLE \
           HOME="$h" HEIMDALL_TEAM_DIR="$h/.heimdall" \
           HMD_ENROLL_THROTTLE="${HMD_ENROLL_THROTTLE:-}" "$BIN" "$@" )
}

echo "============================================================"
echo "ZERO-CONFIG presence bootstrap (mock CP @ $URL, crypto=$CRYPTO)"
echo "============================================================"
echo

if [ "$CRYPTO" = "1" ]; then
  # ── A. first beat auto-bootstraps (keygen -> enroll once -> persist 0600) ──
  echo "A. first beat auto-generates + persists a 0600 seed and enrolls once"
  run_presence beat 2>"$WORK/beat1.err"; B1="$?"
  SEED_FILE="$(ls "$HOME_T/.heimdall/pki/"*.seed 2>/dev/null | head -1 || true)"
  if [ "$B1" = "0" ] && [ -n "$SEED_FILE" ] && [ -s "$SEED_FILE" ]; then
    ok "A1 first beat exited 0 and PERSISTED a non-empty seed ($SEED_FILE)"
  else
    bad "A1 first beat did not persist a seed (exit=$B1, file='$SEED_FILE')"; cat "$WORK/beat1.err" >&2
  fi
  ENROLL_N="$(grep -c '^enroll ' "$MOCK_LOG" 2>/dev/null || echo 0)"
  if [ "$ENROLL_N" = "1" ] && grep -q "enroll token=$TOKEN .* pubkey=True" "$MOCK_LOG"; then
    ok "A2 /enroll called EXACTLY once, carrying the config token + the public key"
  else
    bad "A2 enroll call wrong (count=$ENROLL_N); log:"; sed 's/^/    /' "$MOCK_LOG" >&2
  fi

  # ── E. seed perms are 0600 ──
  echo
  echo "E. the persisted seed is mode 0600"
  PERM="$(stat -f '%Lp' "$SEED_FILE" 2>/dev/null || stat -c '%a' "$SEED_FILE" 2>/dev/null || echo '?')"
  if [ "$PERM" = "600" ]; then
    ok "E seed file perms are 0600 (never world/group-readable)"
  else
    bad "E seed file perms are $PERM, expected 600"
  fi

  # ── B. second beat reuses the persisted seed (no re-enroll, no re-keygen) ──
  echo
  echo "B. second beat REUSES the persisted seed (no re-enroll, no re-keygen)"
  SEED1="$(cat "$SEED_FILE" 2>/dev/null || true)"
  run_presence beat 2>"$WORK/beat2.err"
  ENROLL_N2="$(grep -c '^enroll ' "$MOCK_LOG" 2>/dev/null || echo 0)"
  SEED2="$(cat "$SEED_FILE" 2>/dev/null || true)"
  if [ "$ENROLL_N2" = "1" ]; then
    ok "B1 second beat did NOT re-enroll (/enroll still called exactly once)"
  else
    bad "B1 second beat re-enrolled (count now $ENROLL_N2) — bootstrap not one-shot"
  fi
  if [ -n "$SEED1" ] && [ "$SEED1" = "$SEED2" ]; then
    ok "B2 the seed bytes are UNCHANGED — the persisted key was reused, not regenerated"
  else
    bad "B2 the seed changed between beats — re-keygen happened (RED)"
  fi

  # ── D. the beat was signed with the bootstrapped seed ──
  echo
  echo "D. the heartbeat is signed with the bootstrapped seed"
  if grep -q "^presence sig=1 " "$MOCK_LOG"; then
    ok "D the /presence beat carried an X-Heimdall-Signature (signed with the bootstrapped seed)"
  else
    bad "D the beat carried no signature header; log:"; sed 's/^/    /' "$MOCK_LOG" >&2
  fi

  # ── C. stable project id from the git remote ──
  echo
  echo "C. the roster read carries a STABLE project id derived from the git remote"
  run_presence roster --json >"$WORK/roster.out" 2>"$WORK/roster.err"
  if grep -q "^roster project=github.com/acme/widget$" "$MOCK_LOG"; then
    ok "C the roster carried project=github.com/acme/widget (normalized remote — clones share one id)"
  else
    bad "C the roster project id was not the normalized remote; log:"; sed 's/^/    /' "$MOCK_LOG" >&2
  fi

  # ── H. a CONFIGURED token is still SENT (token-mode servers keep working) ──
  echo
  echo "H. a configured enroll_token is still sent on the POST (token-mode unaffected)"
  if grep -q "^enroll token=$TOKEN " "$MOCK_LOG"; then
    ok "H the token-mode enroll carried X-Heimdall-Enroll-Token=$TOKEN (token still sent when present)"
  else
    bad "H the configured token was not sent; log:"; sed 's/^/    /' "$MOCK_LOG" >&2
  fi

  # ── TM. RULING 1b AUTO-SOLO: no team.json -> mint one 0600 + send it in the enroll header ──
  # The first beat above (A) ran with NO team.json under $HOME_T/.heimdall (a virgin
  # checkout). The client must have AUTO-MINTED a solo team (0600 team.json, 43-char
  # secret) and sent that secret in the X-Heimdall-Team-Secret header at /enroll —
  # the secret travels ONCE at enroll and lives in NO file but team.json.
  echo
  echo "TM. auto-solo: a virgin checkout mints a 0600 team.json + sends it in the enroll header"
  TEAM_JSON="$HOME_T/.heimdall/team.json"
  TEAM_SECRET="$("$PY" - "$TEAM_JSON" 2>/dev/null <<'PYEOF' || true
import json, sys
try:
    sys.stdout.write(json.load(open(sys.argv[1])).get("team_secret") or "")
except Exception:
    sys.stdout.write("")
PYEOF
)"
  TEAM_PERM="$(stat -f '%Lp' "$TEAM_JSON" 2>/dev/null || stat -c '%a' "$TEAM_JSON" 2>/dev/null || echo '?')"
  if [ -f "$TEAM_JSON" ] && [ "$TEAM_PERM" = "600" ] && [ "${#TEAM_SECRET}" -eq 43 ]; then
    ok "TM1 auto-solo minted a 0600 team.json carrying a 43-char secret (${#TEAM_SECRET} chars)"
  else
    bad "TM1 auto-solo did not mint a 0600 43-char team.json (perm=$TEAM_PERM len=${#TEAM_SECRET})"
  fi
  if [ -n "$TEAM_SECRET" ] && grep -qF "team=$TEAM_SECRET " "$MOCK_LOG"; then
    ok "TM2 /enroll carried the X-Heimdall-Team-Secret header = the minted team secret"
  else
    bad "TM2 the enroll did not carry the minted team secret; log:"; sed 's/^/    /' "$MOCK_LOG" >&2
  fi
  if [ -n "$TEAM_SECRET" ]; then
    LEAK="$(grep -rlF "$TEAM_SECRET" "$HOME_T" 2>/dev/null | grep -vF "$TEAM_JSON" || true)"
    if [ -z "$LEAK" ]; then
      ok "TM3 the team secret appears in NO file under HOME but team.json (seed/config/stamp carry none)"
    else
      bad "TM3 the team secret LEAKED to file(s):
$LEAK"
    fi
  else
    bad "TM3 skipped — no team secret resolved"
  fi

  # ── G. ZERO-CONFIG OPEN ENROLL: no token in config + an OPEN server -> auto-enroll, token OMITTED ──
  echo
  echo "G. TOKENLESS open-enroll: a dev with NO token + an OPEN server auto-enrolls (token omitted)"
  OPEN_LOG="$WORK/open.log"; : > "$OPEN_LOG"
  URL_OPEN="$(launch_mock "$OPEN_LOG" "" "")"   # token="" -> OPEN server (tokenless enroll OK)
  HOME_OPEN="$WORK/home_open"; mkdir -p "$HOME_OPEN/.heimdall"
  cat > "$HOME_OPEN/.heimdall/cp-endpoint.json" <<EOF
{"url":"$URL_OPEN"}
EOF
  run_in "$HOME_OPEN" beat 2>"$WORK/open_beat.err"; GBX="$?"
  OSEED="$(ls "$HOME_OPEN/.heimdall/pki/"*.seed 2>/dev/null | head -1 || true)"
  if [ "$GBX" = "0" ] && [ -n "$OSEED" ] && [ -s "$OSEED" ]; then
    ok "G1 tokenless beat exited 0 and PERSISTED a seed with ZERO config ($OSEED)"
  else
    bad "G1 tokenless beat did not bootstrap (exit=$GBX, seed='$OSEED')"; cat "$WORK/open_beat.err" >&2
  fi
  OPEN_N="$(grep -c '^enroll ' "$OPEN_LOG" 2>/dev/null || echo 0)"
  if [ "$OPEN_N" = "1" ] && grep -q "^enroll token= .* pubkey=True" "$OPEN_LOG"; then
    ok "G2 /enroll called once with an EMPTY token (the token was OMITTED from the POST) + a public key"
  else
    bad "G2 open enroll wrong (count=$OPEN_N, expected empty token); log:"; sed 's/^/    /' "$OPEN_LOG" >&2
  fi

  # ── T. ENROLL THROTTLE: a FAILED enroll backs off — a 2nd beat within the window does NOT re-POST ──
  echo
  echo "T. enroll throttle: a failed enroll stamps an attempt; a 2nd beat within the window does NOT retry"
  FAIL_LOG="$WORK/fail.log"; : > "$FAIL_LOG"
  URL_FAIL="$(launch_mock "$FAIL_LOG" "$TOKEN" "1")"   # /enroll always 500 -> enroll fails
  HOME_THR="$WORK/home_thr"; mkdir -p "$HOME_THR/.heimdall"
  cat > "$HOME_THR/.heimdall/cp-endpoint.json" <<EOF
{"url":"$URL_FAIL","enroll_token":"$TOKEN"}
EOF
  HMD_ENROLL_THROTTLE=9999 run_in "$HOME_THR" beat 2>/dev/null   # 1st: enroll attempted, fails
  STAMP_FILE="$(ls "$HOME_THR/.heimdall/pki/"*.enroll-attempt 2>/dev/null | head -1 || true)"
  FAIL_N1="$(grep -c '^enroll ' "$FAIL_LOG" 2>/dev/null || echo 0)"
  MT1="$(stat -f '%m' "$STAMP_FILE" 2>/dev/null || stat -c '%Y' "$STAMP_FILE" 2>/dev/null || echo '?')"
  HMD_ENROLL_THROTTLE=9999 run_in "$HOME_THR" beat 2>/dev/null   # 2nd: must be throttled (no re-POST)
  FAIL_N2="$(grep -c '^enroll ' "$FAIL_LOG" 2>/dev/null || echo 0)"
  MT2="$(stat -f '%m' "$STAMP_FILE" 2>/dev/null || stat -c '%Y' "$STAMP_FILE" 2>/dev/null || echo '?')"
  if [ -n "$STAMP_FILE" ] && [ "$FAIL_N1" = "1" ]; then
    ok "T1 a failed enroll attempted /enroll ONCE and wrote the throttle stamp ($STAMP_FILE)"
  else
    bad "T1 first failed enroll wrong (stamp='$STAMP_FILE', count=$FAIL_N1); log:"; sed 's/^/    /' "$FAIL_LOG" >&2
  fi
  if [ "$FAIL_N2" = "1" ] && [ "$MT1" = "$MT2" ] && [ "$MT1" != "?" ]; then
    ok "T2 the 2nd beat within the window did NOT re-POST /enroll (count still 1) and left the stamp UNCHANGED"
  else
    bad "T2 the throttle did not hold (count $FAIL_N1->$FAIL_N2, stamp mtime $MT1->$MT2)"
  fi
else
  echo "A-E SKIPPED: no Ed25519 backend (cryptography/pynacl) — bootstrap keygen unavailable here."
fi

# ── F. NO CONFIG -> clean empty roster + no-op beat + exit 0 + NO traceback ──
echo
echo "F. NO config -> clean empty roster + no-op beat + exit 0 (no traceback)"
HOME_BARE="$WORK/home_bare"; mkdir -p "$HOME_BARE"   # no cp-endpoint.json, no seed
R_OUT="$( cd "$PROJ_REPO" \
  && env -u HEIMDALL_CP_URL -u BASE_URL -u HEIMDALL_CP_PKI_KEY -u PKI_SEED \
       HOME="$HOME_BARE" HEIMDALL_TEAM_DIR="$HOME_BARE/.heimdall" \
       "$BIN" roster --json 2>"$WORK/bare_roster.err" )"; R_EX="$?"
if [ "$R_OUT" = "[]" ] && [ "$R_EX" = "0" ] && [ ! -s "$WORK/bare_roster.err" ]; then
  ok "F1 no-config roster --json -> [] , exit 0, EMPTY stderr (no traceback)"
else
  bad "F1 no-config roster degraded badly (out='$R_OUT' exit=$R_EX)"; cat "$WORK/bare_roster.err" >&2
fi
( cd "$PROJ_REPO" \
  && env -u HEIMDALL_CP_URL -u BASE_URL -u HEIMDALL_CP_PKI_KEY -u PKI_SEED \
       HOME="$HOME_BARE" HEIMDALL_TEAM_DIR="$HOME_BARE/.heimdall" \
       "$BIN" beat 2>"$WORK/bare_beat.err" ); BARE_BEAT_EX="$?"
if [ "$BARE_BEAT_EX" = "0" ] && [ ! -s "$WORK/bare_beat.err" ]; then
  ok "F2 no-config beat -> silent no-op, exit 0, EMPTY stderr"
else
  bad "F2 no-config beat degraded badly (exit=$BARE_BEAT_EX)"; cat "$WORK/bare_beat.err" >&2
fi

echo
echo "============================================================"
printf "heimdall-presence-bootstrap: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
