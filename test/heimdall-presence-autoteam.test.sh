#!/usr/bin/env bash
# heimdall-presence-autoteam.test.sh — ZERO-TOUCH GITHUB TEAM FORMATION (first-run team resolution).
#
# WHAT THIS GATES. On a dev's FIRST beat with NO team.json, heimdall-presence forms the repo's
# SHARED team automatically instead of minting a separate solo team that never converges:
#   • a GitHub repo + `gh` authed -> POST /team/auto: the FIRST teammate INITIATES the repo's team,
#     EVERYONE else on the same repo AUTO-JOINS the SAME team_id — no invite, no paste. The returned
#     team_id is persisted with NO bearer secret (source:"auto-github"; membership is server-side).
#   • no usable gh / no GitHub remote / air-gapped -> FALL BACK to the original solo-mint (unchanged).
#   • SEVERED (zero-egress opt-out) -> NO /team/auto call at all (nothing leaves the machine).
#   • an auto-team CALL FAILURE (5xx / no route / drop) -> degrade gracefully to solo-mint, never crash.
#
# HERMETIC. A tiny in-process HTTP mock (localhost) stands in for the control plane and a PATH-shim
# `gh` stands in for the GitHub CLI — ZERO real network, ZERO GitHub API, ZERO spend. The mock LOGS
# what the client sent so we assert enroll-before-/team/auto, the persisted team.json shape, and the
# single-use gh token's transit-only discipline (it must appear in NO file under HOME).
#
#   A. AUTO-INITIATE : first run writes team.json {team_id, source:"auto-github", NO team_secret},
#      /enroll precedes /team/auto, the beat is delivered, and the gh token leaks to NO HOME file.
#   B. AUTO-JOIN     : a second teammate (fresh HOME) on the SAME repo converges to the SAME team_id
#      with mode "joined" — zero-touch convergence, the whole point.
#   C. NO-GH FALLBACK: gh present but NOT authed -> solo-mint (source:"auto-solo", 43-char secret),
#      /team/auto NEVER called.
#   D. SEVERED       : a severed dev's beat is a no-op -> team.json is NOT created and the CP receives
#      ZERO requests (no /team/auto, no /enroll, no /presence) — the zero-egress guarantee.
#   E. CALL FAILURE  : /team/auto returns 500 -> degrade to solo-mint, exit 0 (never a crash).
#
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin/heimdall-presence"
LIB="$REPO/bin/lib"
# DEFAULT-ON egress guard: pin the baked-in CP default at a dead port so no un-pinned presence
# call (e.g. the SEVERED probe, which resolves no cp-endpoint.json) can reach the real production CP.
. "$REPO/test/lib/net-default-guard.sh"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }
[ -x "$BIN" ] || { echo "FATAL: $BIN missing/!exec" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

CRYPTO="$("$PY" -c "import sys;sys.path.insert(0,'$LIB');import cp_auth;print('1' if cp_auth.crypto_available() else '0')" 2>/dev/null || echo 0)"

WORK="$(mktemp -d -t "presence-autoteam.$(printf 'X%.0s' 1 2 3 4 5 6)")"
MOCK_PIDS=""
cleanup() {
  for p in $MOCK_PIDS; do
    kill "$p" >/dev/null 2>&1 || true
    wait "$p" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup INT TERM EXIT

GH_TOKEN="gho_faketoken_TRANSIT_ONLY_do_not_persist_xyz"   # the single-use gh proof (transit only)
GH_LOGIN="octocat"

# ── the mock control plane: /enroll (records enrolled haids), /team/auto (stateful initiate/join,
#    fail-closes enroll_required until the haid enrolled), /presence, /roster. ──
cat > "$WORK/mock_cp.py" <<'PYEOF'
import hashlib
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit, parse_qs

LOG = os.environ["MOCK_LOG"]
TEAM_FAIL = os.environ.get("MOCK_TEAM_FAIL", "") == "1"   # /team/auto -> 500 (degrade path)

ENROLLED = set()   # haids that have POSTed /enroll (module-global: persists across requests)
TEAMS = {}         # repo -> team_id (first caller INITIATES, the rest JOIN the same id)


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
        try:
            d = json.loads(body or b"{}")
        except Exception:
            d = {}
        if path == "/enroll":
            haid = d.get("haid") or ""
            if haid:
                ENROLLED.add(haid)
            record("enroll haid=%s pubkey=%s" % (haid, bool(d.get("pubkey"))))
            self._send(200, {"ok": True})
            return
        if path == "/team/auto":
            repo = d.get("repo") or ""
            ghu = d.get("gh_user") or ""
            haid = d.get("haid") or ""
            proof = d.get("gh_proof") or ""
            # Log the PRESENCE of the proof, never its value (server-side hygiene).
            record("teamauto repo=%s gh_user=%s haid=%s proof_present=%d"
                   % (repo, ghu, haid, 1 if proof else 0))
            if TEAM_FAIL:
                self._send(500, {"error": "boom"})
                return
            if haid not in ENROLLED:   # fail-closed: the HAID must enroll BEFORE /team/auto
                self._send(409, {"ok": False, "error": "enroll_required"})
                return
            tid = "team_" + hashlib.sha1(repo.encode("utf-8")).hexdigest()[:12]
            if repo in TEAMS:
                mode = "joined"
            else:
                TEAMS[repo] = tid
                mode = "initiated"
            self._send(200, {"ok": True, "team_id": tid, "mode": mode,
                             "project": "github.com/" + repo})
            return
        if path == "/presence":
            sig = 1 if self.headers.get("X-Heimdall-Signature") else 0
            team = 1 if self.headers.get("X-Heimdall-Team-Secret") else 0
            record("presence sig=%d team=%d haid=%s"
                   % (sig, team, self.headers.get("X-Heimdall-HAID")))
            self._send(200, {"ok": True})
            return
        self._send(404, {"error": "no_route"})

    def do_GET(self):
        split = urlsplit(self.path)
        if split.path == "/roster":
            q = parse_qs(split.query)
            record("roster project=%s" % (q.get("project") or [""])[0])
            self._send(200, {"roster": []})
            return
        self._send(404, {"error": "no_route"})


import threading as _th, time as _t
_GUARD = int(os.environ.get("MOCK_GUARD_PID") or "0")
def _watchdog():
    start = _t.time()
    while True:
        _t.sleep(1.0)
        dead = False
        if _GUARD:
            try:
                os.kill(_GUARD, 0)
            except ProcessLookupError:
                dead = True
            except PermissionError:
                dead = False
        if dead or (_t.time() - start) > 120:
            os._exit(0)
_th.Thread(target=_watchdog, daemon=True).start()

srv = HTTPServer(("127.0.0.1", 0), Handler)
sys.stdout.write("%d\n" % srv.server_address[1])
sys.stdout.flush()
srv.serve_forever()
PYEOF

# launch_mock <logfile> <team_fail> -> echoes the bound base URL, tracks the pid for cleanup.
PORT_SEQ=0
launch_mock() {
  PORT_SEQ=$((PORT_SEQ+1)); local pf="$WORK/port.$PORT_SEQ.txt"; : >"$pf"
  MOCK_LOG="$1" MOCK_TEAM_FAIL="${2:-}" MOCK_GUARD_PID="$$" \
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

# ── the PATH-shim gh (authed): answers `gh api user --jq .login` and `gh auth token`. ──
GHBIN="$WORK/ghbin"; mkdir -p "$GHBIN"
cat > "$GHBIN/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "api user"*)   printf '%s\n' "$GH_LOGIN" ;;
  "auth token"*) printf '%s\n' "$GH_TOKEN" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$GHBIN/gh"

# ── a PATH-shim gh that is present but NOT authed (every call fails) — the "no usable gh" case. ──
GHBIN_NOAUTH="$WORK/ghbin_noauth"; mkdir -p "$GHBIN_NOAUTH"
cat > "$GHBIN_NOAUTH/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh: not logged into any GitHub hosts" >&2
exit 1
EOF
chmod +x "$GHBIN_NOAUTH/gh"

# a project repo with a github.com remote (UPPERCASE proves normalization -> github.com/acme/widget).
PROJ_REPO="$WORK/clone"; mkdir -p "$PROJ_REPO"
git -C "$PROJ_REPO" init -q
git -C "$PROJ_REPO" config user.email "dev@example.com"
git -C "$PROJ_REPO" config user.name "Dev"
git -C "$PROJ_REPO" remote add origin "https://github.com/Acme/Widget.git"

# a NON-github repo (a gitlab remote) — auto-github is INELIGIBLE, so it must solo-mint.
NONGH_REPO="$WORK/gitlab"; mkdir -p "$NONGH_REPO"
git -C "$NONGH_REPO" init -q
git -C "$NONGH_REPO" config user.email "dev@example.com"
git -C "$NONGH_REPO" config user.name "Dev"
git -C "$NONGH_REPO" remote add origin "https://gitlab.com/acme/widget.git"

# team.json reader helpers.
read_field() {  # read_field <team.json> <field>
  "$PY" - "$1" "$2" 2>/dev/null <<'PYEOF' || true
import json, sys
try:
    sys.stdout.write(str(json.load(open(sys.argv[1])).get(sys.argv[2]) or ""))
except Exception:
    sys.stdout.write("")
PYEOF
}
perm_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null || echo '?'; }

# clean-env runner: <home> <repo-dir> <ghbin-or-empty> [extra env KEY=VAL ...] -- <args...>
# no manual CP exports (zero-config resolves the mock via cp-endpoint.json); gh comes from a shim
# on PATH; HMD_PRESENCE_INTERACTIVE=1 so the honest one-liner is emitted (stderr is not a tty here).
run_at() {
  local home="$1" repo_dir="$2" ghbin="$3"; shift 3
  local path="$PATH"; [ -n "$ghbin" ] && path="$ghbin:$PATH"
  ( cd "$repo_dir" \
    && env -u HEIMDALL_CP_URL -u BASE_URL -u HEIMDALL_CP_PKI_KEY -u PKI_SEED \
           -u HMD_PROJECT -u HMD_HAID -u HMD_HANDLE -u HMD_AUTO_TEAM_DISABLE \
           PATH="$path" HOME="$home" HEIMDALL_TEAM_DIR="$home/.heimdall" \
           HMD_PRESENCE_INTERACTIVE=1 "$BIN" "$@" )
}

write_endpoint() {  # write_endpoint <home> <url>   (zero-config: url in cp-endpoint.json, OPEN enroll)
  mkdir -p "$1/.heimdall"
  printf '{"url":"%s"}\n' "$2" > "$1/.heimdall/cp-endpoint.json"
}

echo "============================================================"
echo "ZERO-TOUCH auto-team formation (mock CP + shim gh, crypto=$CRYPTO)"
echo "============================================================"
echo

if [ "$CRYPTO" = "1" ]; then
  MOCK_LOG="$WORK/mock.log"; : > "$MOCK_LOG"
  URL="$(launch_mock "$MOCK_LOG" "")"

  # ── A. AUTO-INITIATE ───────────────────────────────────────────────────────────────
  echo "A. first run on a GitHub repo AUTO-INITIATES the team (POST /team/auto, no secret persisted)"
  HOME_A="$WORK/home_a"; write_endpoint "$HOME_A" "$URL"
  run_at "$HOME_A" "$PROJ_REPO" "$GHBIN" beat 2>"$WORK/a.err"; A_EX="$?"
  TJ_A="$HOME_A/.heimdall/team.json"
  A_SRC="$(read_field "$TJ_A" source)"
  A_TID="$(read_field "$TJ_A" team_id)"
  A_SEC="$(read_field "$TJ_A" team_secret)"
  A_PERM="$(perm_of "$TJ_A")"
  if [ "$A_EX" = "0" ] && [ -f "$TJ_A" ] && [ "$A_SRC" = "auto-github" ] && [ -n "$A_TID" ] && [ -z "$A_SEC" ]; then
    ok "A1 team.json persisted {source:auto-github, team_id:$A_TID} with NO team_secret (exit 0)"
  else
    bad "A1 auto-github team.json wrong (exit=$A_EX src='$A_SRC' tid='$A_TID' sec_present=$([ -n "$A_SEC" ] && echo 1 || echo 0))"
    cat "$WORK/a.err" >&2
  fi
  [ "$A_PERM" = "600" ] \
    && ok "A2 team.json is mode 0600 (never world/group-readable)" \
    || bad "A2 team.json perms are $A_PERM, expected 600"
  # enroll must PRECEDE /team/auto (the CP fail-closes enroll_required otherwise).
  EN_LINE="$(grep -n '^enroll ' "$MOCK_LOG" | head -1 | cut -d: -f1)"
  TA_LINE="$(grep -n '^teamauto ' "$MOCK_LOG" | head -1 | cut -d: -f1)"
  if [ -n "$EN_LINE" ] && [ -n "$TA_LINE" ] && [ "$EN_LINE" -lt "$TA_LINE" ]; then
    ok "A3 /enroll ($EN_LINE) preceded /team/auto ($TA_LINE) — the HAID enrolled before auto-team"
  else
    bad "A3 enroll did not precede /team/auto (enroll@$EN_LINE teamauto@$TA_LINE); log:"; sed 's/^/    /' "$MOCK_LOG" >&2
  fi
  if grep -q "^teamauto repo=acme/widget gh_user=$GH_LOGIN .* proof_present=1$" "$MOCK_LOG"; then
    ok "A4 /team/auto carried repo=acme/widget, the gh_user, and the gh proof (present)"
  else
    bad "A4 /team/auto body wrong; log:"; sed 's/^/    /' "$MOCK_LOG" >&2
  fi
  grep -q "^presence sig=1 " "$MOCK_LOG" \
    && ok "A5 the beat was delivered (signed /presence) after the team bound" \
    || { bad "A5 no signed beat after auto-team; log:"; sed 's/^/    /' "$MOCK_LOG" >&2; }
  # the honest one-liner (stderr only).
  grep -qF "initiated the team for github.com/acme/widget (via GitHub)" "$WORK/a.err" \
    && ok "A6 printed the honest one-liner: 'initiated the team for github.com/acme/widget (via GitHub)'" \
    || { bad "A6 missing the initiate notice; stderr:"; sed 's/^/    /' "$WORK/a.err" >&2; }
  # TRANSIT-ONLY gh proof: it must appear in NO file under HOME (never persisted, never logged locally).
  LEAK="$(grep -rlF "$GH_TOKEN" "$HOME_A" 2>/dev/null || true)"
  [ -z "$LEAK" ] \
    && ok "A7 the single-use gh token leaked to NO file under HOME (transit-only discipline holds)" \
    || bad "A7 the gh token LEAKED to file(s): $LEAK"

  # ── B. AUTO-JOIN convergence ─────────────────────────────────────────────────────────
  echo
  echo "B. a SECOND teammate on the SAME repo AUTO-JOINS the SAME team_id (zero-touch convergence)"
  HOME_B="$WORK/home_b"; write_endpoint "$HOME_B" "$URL"
  run_at "$HOME_B" "$PROJ_REPO" "$GHBIN" beat 2>"$WORK/b.err"; B_EX="$?"
  TJ_B="$HOME_B/.heimdall/team.json"
  B_SRC="$(read_field "$TJ_B" source)"
  B_TID="$(read_field "$TJ_B" team_id)"
  if [ "$B_EX" = "0" ] && [ "$B_SRC" = "auto-github" ] && [ -n "$B_TID" ] && [ "$B_TID" = "$A_TID" ]; then
    ok "B1 teammate B converged to the SAME team_id ($B_TID == $A_TID) — auto-join, no invite"
  else
    bad "B1 B did not converge (exit=$B_EX src='$B_SRC' B_tid='$B_TID' A_tid='$A_TID')"; cat "$WORK/b.err" >&2
  fi
  grep -qF "joined your team for github.com/acme/widget (via GitHub)" "$WORK/b.err" \
    && ok "B2 printed the honest one-liner: 'joined your team for github.com/acme/widget (via GitHub)'" \
    || { bad "B2 missing the join notice; stderr:"; sed 's/^/    /' "$WORK/b.err" >&2; }

  # ── E. auto-team CALL FAILURE degrades to solo-mint ──────────────────────────────────
  echo
  echo "E. a /team/auto CALL FAILURE (500) degrades gracefully to solo-mint (exit 0, never a crash)"
  FAIL_LOG="$WORK/fail.log"; : > "$FAIL_LOG"
  URL_FAIL="$(launch_mock "$FAIL_LOG" "1")"   # /team/auto -> 500
  HOME_E="$WORK/home_e"; write_endpoint "$HOME_E" "$URL_FAIL"
  run_at "$HOME_E" "$PROJ_REPO" "$GHBIN" beat 2>"$WORK/e.err"; E_EX="$?"
  TJ_E="$HOME_E/.heimdall/team.json"
  E_SRC="$(read_field "$TJ_E" source)"
  E_SEC="$(read_field "$TJ_E" team_secret)"
  if [ "$E_EX" = "0" ] && [ "$E_SRC" = "auto-solo" ] && [ "${#E_SEC}" -eq 43 ]; then
    ok "E1 a failed /team/auto fell back to a 0600 auto-solo team.json (43-char secret), exit 0"
  else
    bad "E1 failure did not degrade to solo-mint (exit=$E_EX src='$E_SRC' seclen=${#E_SEC})"; cat "$WORK/e.err" >&2
  fi
  grep -q "^teamauto " "$FAIL_LOG" \
    && ok "E2 /team/auto WAS attempted (then failed) before the solo fallback" \
    || { bad "E2 /team/auto was not attempted; log:"; sed 's/^/    /' "$FAIL_LOG" >&2; }
else
  echo "A/B/E SKIPPED: no Ed25519 backend (cryptography/pynacl) — signing/enroll unavailable here."
fi

# ── C. NO usable gh -> solo-mint (needs no crypto for the local mint) ────────────────
echo
echo "C. gh present but NOT authed -> FALL BACK to solo-mint; /team/auto is NEVER called"
CLOG="$WORK/nogh.log"; : > "$CLOG"
URL_C="$(launch_mock "$CLOG" "")"
HOME_C="$WORK/home_c"; write_endpoint "$HOME_C" "$URL_C"
run_at "$HOME_C" "$PROJ_REPO" "$GHBIN_NOAUTH" beat 2>"$WORK/c.err"; C_EX="$?"
TJ_C="$HOME_C/.heimdall/team.json"
C_SRC="$(read_field "$TJ_C" source)"
C_SEC="$(read_field "$TJ_C" team_secret)"
if [ "$C_EX" = "0" ] && [ "$C_SRC" = "auto-solo" ] && [ "${#C_SEC}" -eq 43 ]; then
  ok "C1 no-usable-gh minted a 0600 auto-solo team.json (43-char secret), exit 0"
else
  bad "C1 no-gh did not solo-mint (exit=$C_EX src='$C_SRC' seclen=${#C_SEC})"; cat "$WORK/c.err" >&2
fi
if grep -q "^teamauto " "$CLOG"; then
  bad "C2 /team/auto WAS called despite no usable gh; log:"; sed 's/^/    /' "$CLOG" >&2
else
  ok "C2 /team/auto was NEVER called (no gh proof -> no auto-team attempt)"
fi

# ── C'. a NON-github remote is also auto-github-INELIGIBLE -> solo-mint, /team/auto never called ──
echo
echo "C'. a NON-GitHub remote (gitlab) is ineligible -> solo-mint; /team/auto NEVER called"
CLOG2="$WORK/nongh.log"; : > "$CLOG2"
URL_C2="$(launch_mock "$CLOG2" "")"
HOME_C2="$WORK/home_c2"; write_endpoint "$HOME_C2" "$URL_C2"
run_at "$HOME_C2" "$NONGH_REPO" "$GHBIN" beat 2>"$WORK/c2.err"; C2_EX="$?"
C2_SRC="$(read_field "$HOME_C2/.heimdall/team.json" source)"
if [ "$C2_EX" = "0" ] && [ "$C2_SRC" = "auto-solo" ] && ! grep -q "^teamauto " "$CLOG2"; then
  ok "C'1 a gitlab remote solo-minted and NEVER called /team/auto (github.com-only gate holds)"
else
  bad "C'1 non-github repo mishandled (exit=$C2_EX src='$C2_SRC' teamauto=$(grep -c '^teamauto ' "$CLOG2"))"; cat "$WORK/c2.err" >&2
fi

# ── D. SEVERED -> ZERO egress: no /team/auto, no enroll, no presence, no team.json ──────
echo
echo "D. a SEVERED dev's beat is a no-op -> team.json NOT created and the CP receives ZERO requests"
DLOG="$WORK/sever.log"; : > "$DLOG"
URL_D="$(launch_mock "$DLOG" "")"   # a reachable mock, to PROVE nothing is sent to it
HOME_D="$WORK/home_d"; mkdir -p "$HOME_D/.heimdall"
# SEVERED opt-out persisted; NO cp-endpoint.json (so no CFG_URL override resolves a URL).
printf '{"decision":"severed"}\n' > "$HOME_D/.heimdall/cp-consent.json"
# Pin the baked-in default at THIS mock so that IF the sever gate leaked a URL, the request would
# hit our recorder (and fail the assertion) instead of silently doing nothing — a strict proof.
D_OUT="$( cd "$PROJ_REPO" \
  && env -u HEIMDALL_CP_URL -u BASE_URL -u HEIMDALL_CP_PKI_KEY -u PKI_SEED \
         -u HMD_PROJECT -u HMD_HAID -u HMD_HANDLE -u HMD_AUTO_TEAM_DISABLE \
         PATH="$GHBIN:$PATH" HOME="$HOME_D" HEIMDALL_TEAM_DIR="$HOME_D/.heimdall" \
         HEIMDALL_DEFAULT_CP_URL="$URL_D" HMD_PRESENCE_INTERACTIVE=1 \
         "$BIN" beat 2>"$WORK/d.err" )"; D_EX="$?"
if [ "$D_EX" = "0" ] && [ ! -f "$HOME_D/.heimdall/team.json" ]; then
  ok "D1 a severed beat exited 0 and created NO team.json (no first-run mint when severed)"
else
  bad "D1 severed beat mishandled (exit=$D_EX, team.json exists=$([ -f "$HOME_D/.heimdall/team.json" ] && echo yes || echo no))"; cat "$WORK/d.err" >&2
fi
if [ -s "$DLOG" ]; then
  bad "D2 the CP received request(s) while severed (expected ZERO egress); log:"; sed 's/^/    /' "$DLOG" >&2
else
  ok "D2 the CP received ZERO requests (no /team/auto, no /enroll, no /presence) — zero egress holds"
fi

echo
echo "============================================================"
printf "heimdall-presence-autoteam: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
