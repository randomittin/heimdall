#!/usr/bin/env bash
# heimdall-presence-doctor.test.sh — FALSIFIER: self-healing autoenroll heals itself.
#
# THE PROBLEM. Getting a teammate onto the wall took HOURS of manual diagnosis across
# heterogeneous machines: a missing crypto backend, the wrong python interpreter, a closed
# enroll gate, a STALE enroll-throttle stamp, a PATH shadow. THE FIX: a background
# diagnose->remediate->verify doctor that fixes what it safely can, surfaces what it can't,
# retries with backoff until HEALTHY, then QUIESCES — never blocking a session, never hot-looping.
#
# RED-WITHOUT-FIX: every proof drives the NEW `heimdall-presence doctor …` (and the helper
# bin/heimdall-presence-doctor). On the pre-fix bin `doctor` is an unknown subcommand (exit 2,
# no chain, no diagnosis) -> every proof FAILS. With the fix each remediation is exercised:
#
#   a. CRYPTO MISSING  -> the doctor DETECTS it (same interpreter), ATTEMPTS the install, and
#      REPORTS a loud, actionable line naming the ACTUAL interpreter + the pip fix (simulated
#      via a PYTHONPATH shadow like heimdall-presence-crypto-missing.test.sh; the pip call is a
#      harmless injected no-op so the test is hermetic).
#   b. STALE THROTTLE  -> a pre-existing <haid>.enroll-attempt stamp does NOT block the doctor:
#      it CLEARS the stamp and enrolls anyway (its own backoff governs cadence).
#   c. ENROLL 4xx      -> a server-side refusal (401 bad_enroll_token) is mapped to an actionable
#      diagnostic AND the bg loop does NOT loop hot (exactly ONE enroll attempt, then it STOPS).
#   d. HEALTHY PATH    -> keygen->enroll(2xx)->persist seed->beat->roster shows the caller ->
#      HEALTHY; a SECOND run is an idempotent no-op (no re-enroll); the bg loop QUIESCES on
#      HEALTHY (terminates, does not keep beating).
#   e. CONSENT OFF     -> the doctor does NOTHING (no enroll, no beat) — the existing gate is honored.
#   f. OFFLINE BACKOFF -> against a dead endpoint the bg loop backs off and TERMINATES on its
#      wallclock backstop with a loud "could not self-heal" message (must NOT hang, never hot-loop).
#
# HERMETIC: a tiny in-process HTTP mock (localhost) stands in for the control plane and LOGS
# what the client/doctor sent — ZERO real network, ZERO spend. Deterministic bg termination via
# the HMD_DOCTOR_MAX_CYCLES / HMD_DOCTOR_MAX_SECONDS / HMD_DOCTOR_BACKOFF seams (like the keeper test).
#
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin/heimdall-presence"
# DEFAULT-ON egress guard: pin the baked-in CP default at a dead port so no un-pinned presence
# call in this suite resolves the REAL production control plane. Explicit per-invocation pins win.
. "$REPO/test/lib/net-default-guard.sh"
DOCTOR="$REPO/bin/heimdall-presence-doctor"
LIB="$REPO/bin/lib"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }
[ -x "$BIN" ] || { echo "FATAL: $BIN missing/!exec" >&2; exit 2; }
[ -x "$DOCTOR" ] || { echo "FATAL: $DOCTOR missing/!exec" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

CRYPTO="$("$PY" -c "import sys;sys.path.insert(0,'$LIB');import cp_auth;print('1' if cp_auth.crypto_available() else '0')" 2>/dev/null || echo 0)"

WORK="$(mktemp -d -t "presence-doctor.$(printf 'X%.0s' 1 2 3 4 5 6)")"
MOCK_PIDS=""
cleanup() {
  for p in $MOCK_PIDS; do kill "$p" >/dev/null 2>&1 || true; wait "$p" 2>/dev/null || true; done
  # reap any doctor bg loop this test may have left (pidfiles live under each HOME's doctor dir)
  for pf in "$WORK"/*/.heimdall/doctor/*.pid; do
    [ -f "$pf" ] || continue
    q="$(cat "$pf" 2>/dev/null || true)"; case "$q" in ''|*[!0-9]*) : ;; *) kill "$q" 2>/dev/null || true ;; esac
  done
  rm -rf "$WORK"
}
trap cleanup INT TERM EXIT

# ── the mock control plane (stateful roster; records what was sent; localhost only) ──
cat > "$WORK/mock_cp.py" <<'PYEOF'
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit, parse_qs

LOG = os.environ["MOCK_LOG"]
MODE = os.environ.get("MOCK_MODE", "ok")   # ok | badtoken


def record(line):
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


class Handler(BaseHTTPRequestHandler):
    PRES = {}   # project -> set(haid): a beat records presence; roster reads it back.

    def log_message(self, *a):
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
        haid = self.headers.get("X-Heimdall-HAID") or ""
        if path == "/enroll":
            tok = self.headers.get("X-Heimdall-Enroll-Token") or ""
            team = 1 if self.headers.get("X-Heimdall-Team-Secret") else 0
            try:
                d = json.loads(body or b"{}")
            except Exception:
                d = {}
            record("enroll haid=%s token=%s team=%d pubkey=%s"
                   % (d.get("haid"), tok, team, bool(d.get("pubkey"))))
            if MODE == "badtoken":
                self._send(401, {"ok": False, "reason": "bad_enroll_token"})
                return
            self._send(200, {"ok": True, "haid": d.get("haid"), "team_id": "t"})
            return
        if path == "/presence":
            try:
                d = json.loads(body or b"{}")
            except Exception:
                d = {}
            proj = d.get("project") or ""
            self.PRES.setdefault(proj, set()).add(haid)
            record("presence haid=%s proj=%s sig=%d"
                   % (haid, proj, 1 if self.headers.get("X-Heimdall-Signature") else 0))
            self._send(200, {"ok": True})
            return
        self._send(404, {"error": "no_route"})

    def do_GET(self):
        split = urlsplit(self.path)
        if split.path == "/roster":
            q = parse_qs(split.query)
            proj = (q.get("project") or [""])[0]
            rows = [{"haid": h, "handle": "dev", "verdict": "working", "file": "-",
                     "age_seconds": 1} for h in sorted(self.PRES.get(proj, set()))]
            record("roster proj=%s n=%d" % (proj, len(rows)))
            self._send(200, {"roster": rows})
            return
        self._send(404, {"error": "no_route"})


# self-terminating watchdog — a leaked mock CP must NEVER outlive its test. A bash EXIT trap
# does NOT run on SIGKILL (the agent/API hard-kills that orphaned ~692 of these to launchd), so
# guard IN-PROCESS on the TEST SCRIPT's liveness: the launcher exports MOCK_GUARD_PID=$$ (the
# test script's pid, stable across the command-substitution subshell that backgrounds us), and
# we exit hard once that process is gone — or a 120s backstop elapses. NOTE: we deliberately do
# NOT key off getppid()/ppid==1. `URL="$(launch_mock)"` backgrounds us INSIDE a command-
# substitution subshell, so the kernel reparents us to launchd (ppid 1) the instant that subshell
# exits — WHILE the test is still running. A ppid-based guard would kill the mock ~1s after launch
# and break every later step (the doctor's enroll/beat/roster chain). Watching the real
# test-script pid kills a LEAKED mock (script gone) without killing a LIVE one (merely reparented).
import threading as _th, time as _t
_GUARD = int(os.environ.get("MOCK_GUARD_PID") or "0")
def _watchdog():
    start = _t.time()
    while True:
        _t.sleep(1.0)
        guard_dead = False
        if _GUARD:
            try:
                os.kill(_GUARD, 0)          # probe liveness only (no signal delivered)
            except ProcessLookupError:
                guard_dead = True            # the test script is gone -> we are a leak
            except PermissionError:
                guard_dead = False           # pid exists but not ours -> alive
        if guard_dead or (_t.time() - start) > 120:
            os._exit(0)
_th.Thread(target=_watchdog, daemon=True).start()

srv = HTTPServer(("127.0.0.1", 0), Handler)
sys.stdout.write("%d\n" % srv.server_address[1])
sys.stdout.flush()
srv.serve_forever()
PYEOF

PORT_SEQ=0
launch_mock() {  # launch_mock <logfile> <mode> -> echoes base URL, tracks pid
  PORT_SEQ=$((PORT_SEQ+1)); local pf="$WORK/port.$PORT_SEQ.txt"; : >"$pf"
  MOCK_LOG="$1" MOCK_MODE="$2" MOCK_GUARD_PID="$$" "$PY" "$WORK/mock_cp.py" >"$pf" 2>>"$WORK/mock.err" &
  local pid=$!; MOCK_PIDS="$MOCK_PIDS $pid"; local p=""
  for _ in $(seq 1 50); do
    p="$(sed -n '1p' "$pf" 2>/dev/null || true)"; [ -n "$p" ] && break
    kill -0 "$pid" >/dev/null 2>&1 || break
    "$PY" -c "import time;time.sleep(0.1)"
  done
  [ -n "$p" ] || { echo "FATAL: mock CP never bound a port" >&2; cat "$WORK/mock.err" >&2; exit 2; }
  printf 'http://127.0.0.1:%s\n' "$p"
}

# A project repo with a git remote so PROJECT/HAID/URL resolve (the exact code path).
PROJ="$WORK/proj"; mkdir -p "$PROJ"
git -C "$PROJ" init -q
git -C "$PROJ" config user.email "dev@example.com"
git -C "$PROJ" config user.name "Dev"
git -C "$PROJ" remote add origin "https://github.com/acme/widget.git"

# make_home <homedir> <url>: a virgin HOME whose ONLY config is the shipped cp-endpoint.json.
make_home() {
  local h="$1" url="$2"; mkdir -p "$h/.heimdall"
  cat > "$h/.heimdall/cp-endpoint.json" <<EOF
{"url":"$url"}
EOF
}

# run: run the doctor (or the client) from inside the project with a clean, hermetic env.
# usage: run <HOME> <HAID> <extra VAR=VAL ...> -- <args...>
run() {
  local h="$1" hd="$2"; shift 2
  local envs=(); while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift || true
  ( cd "$PROJ" && env -u HEIMDALL_CP_URL -u BASE_URL -u HEIMDALL_CP_PKI_KEY -u HMD_PROJECT -u HMD_HANDLE \
      HOME="$h" HEIMDALL_TEAM_DIR="$h/.heimdall" HEIMDALL_DOCTOR_DIR="$h/.heimdall/doctor" \
      HMD_HAID="$hd" ${envs[@]+"${envs[@]}"} "$BIN" "$@" )
}

# bound SECS -- runs a command with a hard kill-timeout (proves the bg loop cannot hang).
bound() {
  local secs="$1"; shift; [ "$1" = "--" ] && shift
  "$@" & local p=$!
  ( "$PY" -c "import time;time.sleep($secs)"; kill -9 "$p" 2>/dev/null ) & local w=$!
  wait "$p" 2>/dev/null; local rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null || true
  return $rc
}

# grep -c always prints the count (0 on no match) but exits 1 when zero — swallow the exit
# with `|| true` (a `|| echo 0` would DOUBLE-print "0\n0" and break numeric compares).
enroll_count() { grep -c '^enroll ' "$1" 2>/dev/null || true; }

echo "============================================================"
echo "PRESENCE-DOCTOR falsifier — self-healing autoenroll (host crypto=$CRYPTO)"
echo "============================================================"
echo

# ══════════════════════════════════════════════════════════════════════════════
# a. CRYPTO MISSING -> detect + attempt install + LOUD actionable report (shadowed backend).
# ══════════════════════════════════════════════════════════════════════════════
echo "a. crypto-missing: the doctor detects it, attempts the install, and reports loudly"
FAKE="$WORK/fakelib"; mkdir -p "$FAKE"; : > "$FAKE/cryptography.py"; : > "$FAKE/nacl.py"
HCRYPT="$WORK/home_crypto"; make_home "$HCRYPT" "http://127.0.0.1:1"
run "$HCRYPT" "haid:cryptodoc" PYTHONPATH="$FAKE" HMD_DOCTOR_PIP_CMD="touch $WORK/pip.attempted" \
    -- doctor >"$WORK/cd.out" 2>"$WORK/cd.err"; CDX="$?"
if [ "$CDX" = "0" ] && grep -q "Ed25519 backend missing" "$WORK/cd.err" \
   && grep -qE "run: /[^ ]*python[^ ]* -m pip install --user cryptography" "$WORK/cd.err"; then
  ok "a1 the doctor emitted ONE loud line naming the missing backend + the ACTUAL interpreter's pip fix"
else
  bad "a1 the crypto-missing report was not loud/actionable (exit=$CDX); stderr:"; sed 's/^/    /' "$WORK/cd.err" >&2
fi
if [ -f "$WORK/pip.attempted" ]; then
  ok "a2 the doctor ATTEMPTED to install cryptography into that interpreter (remediation fired)"
else
  bad "a2 the doctor did not attempt the crypto install"
fi
CD_STATE="$(run "$HCRYPT" "haid:cryptodoc" PYTHONPATH="$FAKE" -- doctor --status 2>/dev/null | grep -c 'state:       crypto_missing' || true)"
[ "$CD_STATE" -ge 1 ] && ok "a3 the persisted diagnosis records state=crypto_missing" \
  || bad "a3 the diagnosis did not record crypto_missing"

# ══════════════════════════════════════════════════════════════════════════════
# e. CONSENT OFF -> the doctor does NOTHING (no enroll, no beat).
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "e. consent OFF -> the doctor no-ops (no enroll POST, honors the existing gate)"
OFF_LOG="$WORK/off.log"; : > "$OFF_LOG"; URL_OFF="$(launch_mock "$OFF_LOG" "ok")"
HOFF="$WORK/home_off"; make_home "$HOFF" "$URL_OFF"; : > "$HOFF/.heimdall/presence-off"   # global kill switch
run "$HOFF" "haid:offdoc" HMD_DOCTOR_MAX_CYCLES=3 HMD_DOCTOR_BACKOFF="0 0 0" -- doctor --bg >/dev/null 2>&1; OFFX="$?"
run "$HOFF" "haid:offdoc" -- doctor >"$WORK/off.once" 2>/dev/null
OFF_ENROLL="$(enroll_count "$OFF_LOG")"
if [ "$OFFX" = "0" ] && [ "$OFF_ENROLL" = "0" ] && grep -q "presence is OFF" "$WORK/off.once"; then
  ok "e1 consent OFF: the doctor did NOTHING (zero enroll POSTs) and reported presence OFF"
else
  bad "e1 consent OFF was not honored (bg exit=$OFFX, enrolls=$OFF_ENROLL); once:"; sed 's/^/    /' "$WORK/off.once" >&2
fi

if [ "$CRYPTO" = "1" ]; then
  # ════════════════════════════════════════════════════════════════════════════
  # d. HEALTHY PATH -> enroll(2xx) + persist seed + beat + roster shows caller -> HEALTHY;
  #    second run idempotent; bg loop QUIESCES on HEALTHY.
  # ════════════════════════════════════════════════════════════════════════════
  echo
  echo "d. healthy path: keygen->enroll->persist->beat->roster == HEALTHY, idempotent, bg quiesces"
  OK_LOG="$WORK/ok.log"; : > "$OK_LOG"; URL_OK="$(launch_mock "$OK_LOG" "ok")"
  HOK="$WORK/home_ok"; make_home "$HOK" "$URL_OK"
  run "$HOK" "haid:okdoc" -- doctor >"$WORK/ok.out" 2>"$WORK/ok.err"; OKX="$?"
  OK_SEED="$(ls "$HOK/.heimdall/pki/"*.seed 2>/dev/null | head -1 || true)"
  if [ "$OKX" = "0" ] && grep -q "result: HEALTHY" "$WORK/ok.out" && [ -n "$OK_SEED" ] && [ -s "$OK_SEED" ]; then
    ok "d1 the doctor reached HEALTHY (exit 0), persisted a seed, and reported it"
  else
    bad "d1 the doctor did not reach HEALTHY (exit=$OKX, seed='$OK_SEED'); out:"; sed 's/^/    /' "$WORK/ok.out" >&2; sed 's/^/    /' "$WORK/ok.err" >&2
  fi
  OK_PERM="$(stat -f '%Lp' "$OK_SEED" 2>/dev/null || stat -c '%a' "$OK_SEED" 2>/dev/null || echo '?')"
  [ "$OK_PERM" = "600" ] && ok "d2 the enrolled seed is mode 0600" || bad "d2 seed perms are $OK_PERM, expected 600"
  if grep -q "^enroll .* team=1 pubkey=True" "$OK_LOG" && grep -q "^presence .* sig=1" "$OK_LOG"; then
    ok "d3 enroll carried a team secret + public key, and the verify beat was SIGNED (real enroll+beat)"
  else
    bad "d3 the enroll/beat wire was wrong; log:"; sed 's/^/    /' "$OK_LOG" >&2
  fi
  N1="$(enroll_count "$OK_LOG")"
  run "$HOK" "haid:okdoc" -- doctor >"$WORK/ok2.out" 2>/dev/null
  N2="$(enroll_count "$OK_LOG")"
  if grep -q "result: HEALTHY" "$WORK/ok2.out" && [ "$N1" = "$N2" ]; then
    ok "d4 a SECOND run is an idempotent HEALTHY no-op (no re-enroll: count stayed $N1)"
  else
    bad "d4 the second run re-enrolled or was not healthy (count $N1->$N2)"
  fi
  run "$HOK" "haid:okdoc" -- status 2>/dev/null | grep -q "doctor:    healthy" \
    && ok "d5 heimdall-presence status surfaces the doctor's healthy diagnosis" \
    || { bad "d5 status did not surface the healthy doctor diagnosis"; run "$HOK" "haid:okdoc" -- status 2>/dev/null | sed 's/^/    /' >&2; }

  # bg loop QUIESCES on HEALTHY (fresh home): terminates fast, enrolls exactly once, then stops.
  echo
  echo "   bg loop quiesces on HEALTHY (fresh home): one full heal then STOP (no hang)"
  BG_LOG="$WORK/bgok.log"; : > "$BG_LOG"; URL_BGOK="$(launch_mock "$BG_LOG" "ok")"
  HBGOK="$WORK/home_bgok"; make_home "$HBGOK" "$URL_BGOK"
  bound 20 -- run "$HBGOK" "haid:bgokdoc" HMD_DOCTOR_MAX_CYCLES=5 HMD_DOCTOR_BACKOFF="1 1 1 1 1" -- doctor --bg >/dev/null 2>&1; BGX="$?"
  BG_SEED="$(ls "$HBGOK/.heimdall/pki/"*.seed 2>/dev/null | head -1 || true)"
  BG_N="$(enroll_count "$BG_LOG")"
  if [ "$BGX" != "124" ] && [ "$BGX" = "0" ] && [ -n "$BG_SEED" ] && [ "$BG_N" = "1" ]; then
    ok "d6 the bg loop healed then QUIESCED on HEALTHY (terminated, single enroll) — did NOT run all 5 cycles"
  else
    bad "d6 the bg loop did not quiesce cleanly on HEALTHY (rc=$BGX seed='$BG_SEED' enrolls=$BG_N)"
  fi
  BGOK_STATE="$(run "$HBGOK" "haid:bgokdoc" -- doctor --status 2>/dev/null | grep -c 'state:       healthy' || true)"
  [ "$BGOK_STATE" -ge 1 ] && ok "d7 the bg loop persisted state=healthy on quiesce" || bad "d7 bg loop did not persist healthy"

  # ════════════════════════════════════════════════════════════════════════════
  # b. STALE THROTTLE -> a pre-existing enroll-attempt stamp does NOT block the doctor.
  # ════════════════════════════════════════════════════════════════════════════
  echo
  echo "b. stale throttle: a pre-existing <haid>.enroll-attempt stamp does NOT block the self-heal"
  THR_LOG="$WORK/thr.log"; : > "$THR_LOG"; URL_THR="$(launch_mock "$THR_LOG" "ok")"
  HTHR="$WORK/home_thr"; make_home "$HTHR" "$URL_THR"
  mkdir -p "$HTHR/.heimdall/pki"
  STAMP="$HTHR/.heimdall/pki/haid_thrdoc.enroll-attempt"; date +%s > "$STAMP"   # a FRESH stale stamp
  run "$HTHR" "haid:thrdoc" -- doctor >"$WORK/thr.out" 2>/dev/null
  THR_N="$(enroll_count "$THR_LOG")"
  if [ "$THR_N" -ge 1 ] && grep -q "result: HEALTHY" "$WORK/thr.out"; then
    ok "b1 the doctor enrolled despite the fresh throttle stamp (NOT blocked by the ~180s backoff)"
  else
    bad "b1 the stale throttle blocked the doctor (enrolls=$THR_N); out:"; sed 's/^/    /' "$WORK/thr.out" >&2
  fi
  [ ! -f "$STAMP" ] && ok "b2 the doctor CLEARED the stale enroll-attempt stamp" \
    || bad "b2 the stale enroll-attempt stamp was not cleared"

  # ════════════════════════════════════════════════════════════════════════════
  # c. ENROLL 4xx -> mapped diagnostic + the bg loop does NOT loop hot (exactly one attempt).
  # ════════════════════════════════════════════════════════════════════════════
  echo
  echo "c. enroll 4xx: a server-side refusal is surfaced + the bg loop does NOT loop hot"
  REF_LOG="$WORK/ref.log"; : > "$REF_LOG"; URL_REF="$(launch_mock "$REF_LOG" "badtoken")"
  HREF="$WORK/home_ref"; make_home "$HREF" "$URL_REF"
  run "$HREF" "haid:refdoc" -- doctor >"$WORK/ref.out" 2>"$WORK/ref.err"; REFX="$?"
  if [ "$REFX" = "0" ] && grep -q "enroll refused (401)" "$WORK/ref.err" && grep -qi "enroll token" "$WORK/ref.err"; then
    ok "c1 a 401 refusal was mapped to an actionable 'enroll refused (401) … enroll token' diagnostic (exit 0)"
  else
    bad "c1 the 4xx refusal was not surfaced actionably (exit=$REFX); stderr:"; sed 's/^/    /' "$WORK/ref.err" >&2
  fi
  [ ! -s "$(ls "$HREF/.heimdall/pki/"*.seed 2>/dev/null | head -1 || echo /nonexistent)" ] 2>/dev/null \
    && ok "c2 a refused enroll persisted NO seed (a wrong token does not look like success)" \
    || bad "c2 a refused enroll wrongly persisted a seed"
  # the bg loop must STOP after ONE attempt on an unfixable 4xx (never a hot retry loop).
  REF2_LOG="$WORK/ref2.log"; : > "$REF2_LOG"; URL_REF2="$(launch_mock "$REF2_LOG" "badtoken")"
  HREF2="$WORK/home_ref2"; make_home "$HREF2" "$URL_REF2"
  bound 20 -- run "$HREF2" "haid:ref2doc" HMD_DOCTOR_MAX_CYCLES=5 HMD_DOCTOR_BACKOFF="0 0 0 0 0" -- doctor --bg >/dev/null 2>&1; REF2X="$?"
  REF2_N="$(enroll_count "$REF2_LOG")"
  if [ "$REF2X" = "0" ] && [ "$REF2_N" = "1" ]; then
    ok "c3 the bg loop made EXACTLY ONE enroll attempt on the 4xx then STOPPED (no hot loop across 5 allowed cycles)"
  else
    bad "c3 the bg loop hot-looped or hung on the 4xx (rc=$REF2X, enroll attempts=$REF2_N, expected 1)"
  fi
  REF2_STATE="$(run "$HREF2" "haid:ref2doc" -- doctor --status 2>/dev/null | grep -c 'state:       enroll_refused' || true)"
  [ "$REF2_STATE" -ge 1 ] && ok "c4 the persisted diagnosis records state=enroll_refused" || bad "c4 diagnosis did not record enroll_refused"

  # ════════════════════════════════════════════════════════════════════════════
  # f. OFFLINE BACKOFF -> the bg loop backs off + TERMINATES on the wallclock backstop (no hang).
  # ════════════════════════════════════════════════════════════════════════════
  echo
  echo "f. offline: the bg loop backs off and TERMINATES on its wallclock backstop (loud, no hang)"
  HDEAD="$WORK/home_dead"; make_home "$HDEAD" "http://127.0.0.1:1"   # nothing listening on port 1
  START="$(date +%s)"
  bound 20 -- run "$HDEAD" "haid:deaddoc" HMD_DOCTOR_MAX_SECONDS=1 HMD_DOCTOR_BACKOFF="1 1 1" \
      -- doctor --bg >/dev/null 2>"$WORK/dead.err"; DEADX="$?"
  ELAPSED=$(( $(date +%s) - START ))
  if [ "$DEADX" = "0" ] && [ "$ELAPSED" -ge 1 ] && [ "$ELAPSED" -lt 15 ]; then
    ok "f1 the offline bg loop BACKED OFF (~${ELAPSED}s) and TERMINATED on the backstop (did not hang)"
  else
    bad "f1 the offline bg loop did not back off + terminate cleanly (rc=$DEADX elapsed=${ELAPSED}s)"
  fi
  if grep -q "could NOT self-heal presence" "$WORK/dead.err"; then
    ok "f2 on exhaustion it emitted ONE loud, actionable 'could not self-heal' message"
  else
    bad "f2 no loud message on self-heal exhaustion; stderr:"; sed 's/^/    /' "$WORK/dead.err" >&2
  fi
  DEAD_STATE="$(run "$HDEAD" "haid:deaddoc" -- doctor --status 2>/dev/null | grep -c 'state:       exhausted' || true)"
  [ "$DEAD_STATE" -ge 1 ] && ok "f3 the persisted diagnosis records state=exhausted" || bad "f3 diagnosis did not record exhausted"
else
  echo
  echo "b-d,f SKIPPED: no Ed25519 backend on this host — the enroll keygen path needs a real backend."
fi

echo
echo "============================================================"
printf "heimdall-presence-doctor: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
