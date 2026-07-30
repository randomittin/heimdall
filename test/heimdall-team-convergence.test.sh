#!/usr/bin/env bash
# heimdall-team-convergence.test.sh — REAL-CODE convergence gate for the team-split bug
# (TEAM-FIX-PLAN §5.5). RED on the pre-Wave-2 resolver, GREEN after it.
#
# THE BUG. Two developers on the SAME github repo (the SAME canonical repo_slug) must land on the
# SAME operative team_id, or they can never see each other's presence. They enter via DIFFERENT
# client resolution models:
#
#   * MACHINE A — the COMMITTED-SECRET model. <repo>/.heimdall/team.json carries a bearer
#     `team_secret` (an old `hmd team new` / a pasted `join <secret>` a teammate committed). On the
#     SHIPPED (pre-fix) resolver, _resolve_team_for_wire RETURNS on the non-empty secret BEFORE ever
#     calling /team/auto, so A lifts the secret into the X-Heimdall-Team-Secret header and the server
#     binds A to derive_team_id(secret) == sha256("heimdall-team\0"+secret)[:32].
#
#   * MACHINE B — the /team/auto SERVER model. A fresh checkout, zero-touch: POST /team/auto binds
#     the repo_slug to a server-derived team_id (first teammate INITIATES, everyone else JOINS).
#
# Same repo_slug, two operative team_ids -> SPLIT: A and B are invisible to each other. This test
# drives the ACTUAL bin/heimdall-presence resolver for both machines against a hermetic mock control
# plane (localhost) + a shim `gh`, and asserts they CONVERGE on ONE server team_id and that A no
# longer sends the secret header (which is exactly what re-split the repo).
#
# FALSIFIABLE IN BOTH DIRECTIONS:
#   * PRE-FIX  -> A short-circuits on its committed secret: team.json never gains a team_id, A's beat
#                carries the team-secret header, A's operative id stays derive_team_id(secret) != B's
#                server id. Assertions C1/C2 FAIL (RED).
#   * POST-FIX -> A, being a github repo, PREFERS /team/auto: drops the header, adopts + persists the
#                server team_id (secret preserved for the offline P4 fallback). A_id == B_id. GREEN.
#
# HERMETIC: two throwaway HOME/HEIMDALL_TEAM_DIR "machines" on one throwaway github-remote repo, an
# in-process mock CP (stateful /team/auto so one repo -> one id), a PATH-shim `gh`. NO real network,
# NO prod CP, NO GitHub API, NO spend. Cleaned via trap.
#
# Exit 0 = A and B converged (Wave 2 landed). Nonzero = the split is live (expected pre-fix).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/bin/heimdall-presence"
LIB="$ROOT/bin/lib"
export LIB
# DEFAULT-ON egress guard: pin the baked-in CP default at a dead port so no un-pinned presence call
# can reach the real production CP.
. "$ROOT/test/lib/net-default-guard.sh"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "SKIP: python3 unavailable" >&2; exit 0; }
[ -x "$BIN" ] || { echo "FATAL: $BIN missing/!exec" >&2; exit 2; }
for f in cp_auth cp_repoteam; do
  [ -f "$LIB/$f.py" ] || { echo "FATAL: $LIB/$f.py missing" >&2; exit 2; }
done

CRYPTO="$("$PY" -c "import sys;sys.path.insert(0,'$LIB');import cp_auth;print('1' if cp_auth.crypto_available() else '0')" 2>/dev/null || echo 0)"
if [ "$CRYPTO" != "1" ]; then
  echo "SKIP: no Ed25519 backend (cryptography/pynacl) — cannot exercise the signed enroll/beat resolver" >&2
  exit 0
fi

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t hmd-team-convergence)"
MOCK_PIDS=""
cleanup() {
  for p in $MOCK_PIDS; do kill "$p" >/dev/null 2>&1 || true; wait "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup INT TERM EXIT

GH_TOKEN="gho_faketoken_TRANSIT_ONLY_do_not_persist_conv"
GH_LOGIN="octocat"

# ── the mock control plane: /enroll, /team/auto (stateful: one repo -> one server team_id, first
#    INITIATES the rest JOIN), /presence (LOGS whether the team-secret header rode). ──
cat > "$WORK/mock_cp.py" <<'PYEOF'
import hashlib, json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit, parse_qs

LOG = os.environ["MOCK_LOG"]
ENROLLED = set()
TEAMS = {}   # repo_slug -> server team_id (first caller INITIATES, the rest JOIN the same id)


def record(line):
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        return

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n > 0 else b""

    def _send(self, code, obj):
        p = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(p)))
        self.end_headers()
        self.wfile.write(p)

    def do_POST(self):
        path = urlsplit(self.path).path
        try:
            d = json.loads(self._body() or b"{}")
        except Exception:
            d = {}
        if path == "/enroll":
            h = d.get("haid") or ""
            if h:
                ENROLLED.add(h)
            record("enroll haid=%s" % h)
            self._send(200, {"ok": True})
            return
        if path == "/team/auto":
            repo = d.get("repo") or ""
            haid = d.get("haid") or ""
            record("teamauto repo=%s haid=%s" % (repo, haid))
            if haid not in ENROLLED:
                self._send(409, {"ok": False, "error": "enroll_required"})
                return
            tid = "srv_" + hashlib.sha1(repo.encode("utf-8")).hexdigest()[:24]
            mode = "joined" if repo in TEAMS else "initiated"
            TEAMS.setdefault(repo, tid)
            self._send(200, {"ok": True, "team_id": TEAMS[repo], "mode": mode,
                             "project": "github.com/" + repo})
            return
        if path == "/presence":
            team = 1 if self.headers.get("X-Heimdall-Team-Secret") else 0
            record("presence team_header=%d haid=%s" % (team, self.headers.get("X-Heimdall-HAID")))
            self._send(200, {"ok": True})
            return
        self._send(404, {"error": "no_route"})

    def do_GET(self):
        s = urlsplit(self.path)
        if s.path == "/roster":
            q = parse_qs(s.query)
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

MOCK_LOG="$WORK/mock.log"; : > "$MOCK_LOG"
PORT_FILE="$WORK/port.txt"; : > "$PORT_FILE"
MOCK_LOG="$MOCK_LOG" MOCK_GUARD_PID="$$" "$PY" "$WORK/mock_cp.py" >"$PORT_FILE" 2>>"$WORK/mock.err" &
MOCK_PIDS="$MOCK_PIDS $!"
PORT=""
for _ in $(seq 1 50); do
  PORT="$(sed -n '1p' "$PORT_FILE" 2>/dev/null || true)"
  [ -n "$PORT" ] && break
  "$PY" -c "import time;time.sleep(0.1)"
done
[ -n "$PORT" ] || { echo "FATAL: mock CP never bound a port" >&2; cat "$WORK/mock.err" >&2; exit 2; }
URL="http://127.0.0.1:$PORT"

# ── PATH-shim gh (authed). ──
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

# ── the SHARED github repo both machines are on (one canonical repo_slug). ──
REPO="$WORK/rally"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "dev@example.com"
git -C "$REPO" config user.name "Dev"
git -C "$REPO" remote add origin "https://github.com/randomittin/rally.git"
SLUG_EXPECT="randomittin/rally"

# The REAL server canonicalizer — a sanity anchor that the slug the mock keys on is the same
# repo_slug the shipped server derives (no hardcode-only assertion).
SLUG_REAL="$(REMOTE="https://github.com/randomittin/rally.git" "$PY" -c 'import os,sys;sys.path.insert(0,os.environ["LIB"]);import cp_repoteam;sys.stdout.write(cp_repoteam.repo_slug(os.environ["REMOTE"]) or "")' 2>/dev/null || true)"

write_endpoint() { mkdir -p "$1/.heimdall"; printf '{"url":"%s"}\n' "$2" > "$1/.heimdall/cp-endpoint.json"; }
read_field() {
  "$PY" - "$1" "$2" 2>/dev/null <<'PYEOF' || true
import json, sys
try:
    sys.stdout.write(str(json.load(open(sys.argv[1])).get(sys.argv[2]) or ""))
except Exception:
    sys.stdout.write("")
PYEOF
}
# clean-env runner (mirrors the presence-autoteam harness): zero manual CP exports; gh on PATH.
run_at() {
  local home="$1" ghbin="$2"; shift 2
  ( cd "$REPO" \
    && env -u HEIMDALL_CP_URL -u BASE_URL -u HEIMDALL_CP_PKI_KEY -u PKI_SEED \
           -u HMD_PROJECT -u HMD_HAID -u HMD_HANDLE -u HMD_AUTO_TEAM_DISABLE \
           PATH="$ghbin:$PATH" HOME="$home" HEIMDALL_TEAM_DIR="$home/.heimdall" \
           HMD_PRESENCE_INTERACTIVE=1 "$BIN" "$@" )
}

echo "============================================================"
echo "TEAM CONVERGENCE — same repo_slug must resolve to ONE team_id"
echo "  remote=https://github.com/randomittin/rally.git  slug=$SLUG_EXPECT"
echo "============================================================"
echo

# sanity: the real server canonicalizer agrees on the slug the mock keys on.
if [ "$SLUG_REAL" = "$SLUG_EXPECT" ]; then
  ok "slug: cp_repoteam.repo_slug canonicalized the git remote -> $SLUG_REAL"
else
  bad "slug: repo_slug() gave '$SLUG_REAL' (expected $SLUG_EXPECT)"
fi

# ── MACHINE B — the /team/auto server model: a FRESH checkout INITIATES the repo's team. ──
HOME_B="$WORK/home_b"; write_endpoint "$HOME_B" "$URL"
run_at "$HOME_B" "$GHBIN" beat 2>"$WORK/b.err"; B_EX="$?"
TJ_B="$HOME_B/.heimdall/team.json"
B_TID="$(read_field "$TJ_B" team_id)"
B_SRC="$(read_field "$TJ_B" source)"
if [ "$B_EX" = "0" ] && [ -n "$B_TID" ] && [ "$B_SRC" = "auto-github" ]; then
  ok "B: /team/auto model bound the server team_id ($B_TID, source auto-github, no secret)"
else
  bad "B: auto-github did not bind (exit=$B_EX tid='$B_TID' src='$B_SRC')"; cat "$WORK/b.err" >&2
fi

# ── MACHINE A — the COMMITTED-SECRET model: team.json pre-seeded with a bearer secret (as a
#    teammate would commit it). The FIX makes A, being a github repo, prefer /team/auto. ──
SECRET_A="S-rally-committed-team-secret-000000000000000"
HOME_A="$WORK/home_a"; write_endpoint "$HOME_A" "$URL"
mkdir -p "$HOME_A/.heimdall"
printf '{"team_secret":"%s","created":7,"source":"new"}\n' "$SECRET_A" > "$HOME_A/.heimdall/team.json"
: > "$MOCK_LOG"   # isolate A's beat so we can read A's own /presence header state
run_at "$HOME_A" "$GHBIN" beat 2>"$WORK/a.err"; A_EX="$?"
TJ_A="$HOME_A/.heimdall/team.json"
A_TID="$(read_field "$TJ_A" team_id)"
A_SEC="$(read_field "$TJ_A" team_secret)"
# did A send the team-secret header on its /presence beat? (pre-fix: yes -> the re-split)
A_TEAM_HEADER="$(grep -c '^presence team_header=1 ' "$MOCK_LOG" 2>/dev/null || true)"
[ -n "$A_TEAM_HEADER" ] || A_TEAM_HEADER=0

echo
# ── C1: THE CONVERGENCE ASSERTION — A and B share ONE server team_id. ──
if [ "$A_EX" = "0" ] && [ -n "$A_TID" ] && [ "$A_TID" = "$B_TID" ]; then
  ok "C1 CONVERGED: the committed-secret machine adopted the SAME server team_id as /team/auto ($A_TID)"
else
  bad "C1 SPLIT: same repo_slug '$SLUG_EXPECT' -> A='$A_TID' B='$B_TID' (A must adopt the server id)"
  printf "  \033[31mSPLIT: A_team_id=%s  B_team_id=%s\033[0m\n" "${A_TID:-<none>}" "$B_TID"
  echo   "  A (committed-secret) short-circuited on its bearer secret instead of preferring /team/auto,"
  echo   "  so it never adopted the server repo->team id and stays invisible to B. Wave-2 fix: A drops"
  echo   "  the secret header for a github repo and persists get_team_for_repo('$SLUG_EXPECT') == B."
  cat "$WORK/a.err" >&2
fi

# ── C2: A DROPPED the secret header — membership is the server binding, not sha256(secret). ──
if [ "$A_TEAM_HEADER" -eq 0 ]; then
  ok "C2 A's beat carried NO X-Heimdall-Team-Secret header (no re-bind to sha256(secret) -> no re-split)"
else
  bad "C2 A still sent the team-secret header ($A_TEAM_HEADER beat[s]) -> server re-binds to sha256(secret), the split"
  sed 's/^/    /' "$MOCK_LOG" >&2
fi

# ── C3: the committed secret is PRESERVED (the P4 offline fallback survives the migration). ──
if [ "$A_SEC" = "$SECRET_A" ]; then
  ok "C3 A's committed team_secret is PRESERVED in team.json (offline P4 fallback intact after migration)"
else
  bad "C3 A's committed secret was lost (got '$A_SEC', expected the seeded bearer secret)"
fi

echo
echo "============================================================"
printf "heimdall-team-convergence: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
