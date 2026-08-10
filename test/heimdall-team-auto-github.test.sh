#!/usr/bin/env bash
# heimdall-team-auto-github.test.sh — acceptance for the WAVE-3 AUTO (GitHub) team path
# in bin/heimdall-team: zero-touch team formation via the control plane's POST /team/auto,
# keyed on the dev's GitHub ACCESS (no bearer secret to paste).
#
# Fully HERMETIC. A localhost recording server stands in for the control plane and returns
# a canned /team/auto response; a fake `gh` on PATH supplies an auth token + a login (the
# proof), and a throwaway HOME + git repo isolate all state. NO real network, NO real gh.
#
# Proves:
#   (a) SYNTAX         — bash -n parses clean.
#   (b) INITIATE       — `hmd team auto` (loud) POSTs {repo,gh_user,gh_proof,haid} to
#                        /team/auto, persists the NON-secret team_id (source auto-github),
#                        writes NO team_secret, and prints an honest "Initiated" line.
#   (c) JOIN           — mode:"joined" persists the team_id + prints a "Joined … via GitHub" line.
#   (d) TOKEN TRANSIT  — the gh auth token appears in the POST BODY the server received but in
#                        NO file under HOME/the repo (never persisted, never logged).
#   (e) DENY           — a 403 non-collaborator / initiate_denied / enroll_required prints a
#                        clear actionable message, persists NO team_id, exit-defers to the
#                        fallback (no crash).
#   (f) SEVERED        — a persisted control-plane SEVER makes `auto` do ZERO egress (server
#                        records NOTHING) and fall through to the bearer-secret path.
#   (g) UNAUTH DEFER   — with gh present but UNAUTHENTICATED (no token) `auto` never calls the
#                        CP (server silent) and falls through to a solo secret mint.
#   (h) FALLBACK GREEN — the explicit bearer path still works: `new` mints a 0600 secret team,
#                        `join` stores a teammate secret, `show` prints the team_id — all with
#                        the AUTO path dormant (no gh).
#
# Exit 0 = every assertion passed.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-team"
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }
[ -x "$CLI" ] || { echo "FATAL: $CLI missing/!exec" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

TMP="$(mktemp -d -t hmd-team-auto)"
WIRE_PID=""
cleanup() { if [ -n "$WIRE_PID" ]; then kill "$WIRE_PID" >/dev/null 2>&1; wait "$WIRE_PID" 2>/dev/null; fi; rm -rf "$TMP"; }
trap cleanup EXIT

FAKE_TOKEN="gho_FAKETESTTOKEN_0000000000000000000000"

# ── the mock control plane: records every POST body to $REC/requests.log and returns a
#    canned /team/auto reply driven by $REC/reply.json ({status, body}).
REC="$TMP/rec"; mkdir -p "$REC"
cat > "$TMP/cpsrv.py" <<'PYEOF'
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer
REC = os.environ["REC_DIR"]
def reply():
    try:
        return json.load(open(os.path.join(REC, "reply.json")))
    except Exception:
        return {"status": 200, "body": {"ok": True, "team_id": "deadbeef", "mode": "initiated", "project": "x"}}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): return
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        with open(os.path.join(REC, "requests.log"), "a") as fh:
            fh.write("POST " + self.path.split("?")[0] + "\n")
        with open(os.path.join(REC, "last-body"), "wb") as fh:
            fh.write(raw)
        r = reply(); b = json.dumps(r.get("body") or {}).encode()
        self.send_response(int(r.get("status") or 200))
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        self.send_response(404); self.end_headers()
srv = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(REC, "port"), "w").write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
REC_DIR="$REC" "$PY" "$TMP/cpsrv.py" &
WIRE_PID=$!
for _ in $(seq 1 40); do [ -s "$REC/port" ] && break; "$PY" -c 'import time;time.sleep(0.1)'; done
PORT="$(cat "$REC/port" 2>/dev/null || true)"
[ -n "$PORT" ] || { echo "FATAL: mock CP never bound a port" >&2; exit 2; }
URL="http://127.0.0.1:$PORT"

set_reply() { printf '%s' "$1" > "$REC/reply.json"; }
clear_log() { : > "$REC/requests.log"; rm -f "$REC/last-body"; }

# ── a fake `gh`: `auth token` -> the token (unless FAKE_GH_UNAUTH set); `api user` -> a login.
mkgh() { # $1 = dir ; $2 = authed(1|"")
  local d="$1" authed="$2"; mkdir -p "$d"
  cat > "$d/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = auth ] && [ "\$2" = token ]; then
  [ -n "${authed:+x}" ] || exit 1
  printf '%s\n' "$FAKE_TOKEN"; exit 0
fi
if [ "\$1" = api ] && [ "\$2" = user ]; then
  [ -n "${authed:+x}" ] || exit 1
  printf 'octocat\n'; exit 0
fi
exit 0
EOF
  chmod +x "$d/gh"
}

# a throwaway git repo (github origin) + HOME; $1=name  $2=gh-authed(1|"")
mkrepo() { # -> prints repo path
  local n="$1" authed="$2"; local r="$TMP/$n"
  mkdir -p "$r/.heimdall" "$r/fb" "$r/home/.heimdall"
  git -C "$r" init -q
  git -C "$r" remote add origin "https://github.com/fakeorg/$n.git"
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  mkgh "$r/fb" "$authed"
  printf '%s' "$r"
}

# run heimdall-team in repo $1 with the mock CP wired + a TTY-forced loud mode; extra argv after.
run_auto() { # $1=repo  $2=loud(1|"")  ...args
  local r="$1" loud="$2"; shift 2
  ( cd "$r" && env -u HEIMDALL_CP_URL -u BASE_URL \
      PATH="$r/fb:/usr/bin:/bin" HOME="$r/home" \
      HEIMDALL_TEAM_DIR="$r/.heimdall" HEIMDALL_CP_URL="$URL" \
      HMD_HAID="haid:tester" ${loud:+HMD_TEAM_AUTO_LOUD=1} \
      "$CLI" "$@" )
}
secret_of() { HMD_F="$1" "$PY" -c 'import json,os,sys;sys.stdout.write((json.load(open(os.environ["HMD_F"])).get("team_secret") or "")if os.path.exists(os.environ["HMD_F"])else"")' 2>/dev/null; }
tid_of()    { HMD_F="$1" "$PY" -c 'import json,os,sys;sys.stdout.write((json.load(open(os.environ["HMD_F"])).get("team_id") or "")if os.path.exists(os.environ["HMD_F"])else"")' 2>/dev/null; }
autosrc_of(){ HMD_F="$1" "$PY" -c 'import json,os,sys;d=json.load(open(os.environ["HMD_F"]))if os.path.exists(os.environ["HMD_F"])else{};sys.stdout.write((d.get("auto")or{}).get("source")or"")' 2>/dev/null; }

echo "============================================================"
echo "heimdall-team — AUTO (GitHub) zero-touch team formation"
echo "============================================================"
echo

# ── (a) SYNTAX ───────────────────────────────────────────────────────────────
if bash -n "$CLI" 2>/dev/null; then ok "(a) bash -n parses clean"; else bad "(a) syntax error"; fi

# ── (b) INITIATE ─────────────────────────────────────────────────────────────
set_reply '{"status":200,"body":{"ok":true,"team_id":"aa11bb22cc33","mode":"initiated","project":"fakeorg/init1"}}'
clear_log
R="$(mkrepo init1 1)"; TJ="$R/.heimdall/team.json"
OUT="$(run_auto "$R" 1 auto 2>&1)"; RC=$?
if grep -q "POST /team/auto" "$REC/requests.log" 2>/dev/null; then ok "(b1) auto POSTed /team/auto"; else bad "(b1) no POST recorded"; fi
if [ "$(tid_of "$TJ")" = "aa11bb22cc33" ] && [ "$(autosrc_of "$TJ")" = "auto-github" ]; then
  ok "(b2) persisted the NON-secret team_id (source auto-github)"
else
  bad "(b2) team_id/source not persisted (tid='$(tid_of "$TJ")' src='$(autosrc_of "$TJ")')"
fi
if [ -z "$(secret_of "$TJ")" ]; then ok "(b3) NO bearer secret written by the auto path"; else bad "(b3) auto path leaked a secret into team.json"; fi
if grep -qi "Initiated the team for fakeorg/init1" <<<"$OUT"; then ok "(b4) printed an honest 'Initiated' line"; else bad "(b4) missing initiate line: $OUT"; fi
[ "$RC" -eq 0 ] && ok "(b5) auto exited 0 on success" || bad "(b5) auto exit=$RC on success"

# ── (c) JOIN ─────────────────────────────────────────────────────────────────
set_reply '{"status":200,"body":{"ok":true,"team_id":"99ff88ee77dd","mode":"joined","project":"fakeorg/join1"}}'
clear_log
R="$(mkrepo join1 1)"; TJ="$R/.heimdall/team.json"
OUT="$(run_auto "$R" 1 auto 2>&1)"
if [ "$(tid_of "$TJ")" = "99ff88ee77dd" ] && grep -qi "Joined fakeorg/join1's team via GitHub" <<<"$OUT"; then
  ok "(c) join persisted team_id + printed 'Joined … via GitHub'"
else
  bad "(c) join wrong (tid='$(tid_of "$TJ")' out='$OUT')"
fi

# ── (d) TOKEN TRANSIT-ONLY ───────────────────────────────────────────────────
# The token MUST be in the POST body the CP received, but in NO file under HOME or the repo.
if [ -f "$REC/last-body" ] && grep -qF "$FAKE_TOKEN" "$REC/last-body"; then
  ok "(d1) gh token rode the POST body (server received it over the wire)"
else
  bad "(d1) token not in the POST body the CP received"
fi
LEAK="$(grep -rlF "$FAKE_TOKEN" "$R/.heimdall" "$R/home" 2>/dev/null | head -1 || true)"
if [ -z "$LEAK" ]; then ok "(d2) gh token persisted to NO file (transit-only)"; else bad "(d2) token LEAKED to $LEAK"; fi

# ── (e) DENY paths ───────────────────────────────────────────────────────────
for spec in \
  '403|{"status":403,"body":{"ok":false,"reason":"non-collaborator"}}|write (collaborator) access' \
  'initiate_denied|{"status":200,"body":{"ok":false,"reason":"initiate_denied"}}|initiate_denied' \
  'enroll_required|{"status":200,"body":{"ok":false,"reason":"enroll_required"}}|enroll_required'
do
  name="${spec%%|*}"; rest="${spec#*|}"; reply="${rest%%|*}"; needle="${rest#*|}"
  set_reply "$reply"; clear_log
  R="$(mkrepo "deny-$name" 1)"; TJ="$R/.heimdall/team.json"
  OUT="$(run_auto "$R" 1 auto 2>&1)"
  # deny -> falls through to the secret ensure, so a solo team.json may exist, but with NO team_id.
  if grep -qiF "$needle" <<<"$OUT" && [ -z "$(tid_of "$TJ")" ]; then
    ok "(e/$name) printed an actionable deny message + persisted NO team_id"
  else
    bad "(e/$name) deny wrong (tid='$(tid_of "$TJ")' out='$OUT')"
  fi
done

# ── (f) SEVERED = ZERO egress ────────────────────────────────────────────────
set_reply '{"status":200,"body":{"ok":true,"team_id":"should_not_happen","mode":"initiated","project":"x"}}'
clear_log
R="$(mkrepo severed 1)"; TJ="$R/.heimdall/team.json"
printf '{"decision":"severed"}\n' > "$R/home/.heimdall/cp-consent.json"
run_auto "$R" 1 auto >/dev/null 2>&1
if [ ! -s "$REC/requests.log" ] && [ -z "$(tid_of "$TJ")" ]; then
  ok "(f) severed -> ZERO egress (no POST) + no team_id; fell through to the local path"
else
  bad "(f) severed LEAKED egress (log='$(cat "$REC/requests.log" 2>/dev/null)' tid='$(tid_of "$TJ")')"
fi

# ── (g) UNAUTH gh -> DEFER (no CP call) ──────────────────────────────────────
clear_log
R="$(mkrepo unauth "")"; TJ="$R/.heimdall/team.json"   # gh present but NOT authenticated
run_auto "$R" 1 auto >/dev/null 2>&1
if [ ! -s "$REC/requests.log" ] && [ -z "$(tid_of "$TJ")" ] && [ -n "$(secret_of "$TJ")" ]; then
  ok "(g) unauthenticated gh -> no CP call, fell through to a solo secret mint"
else
  bad "(g) unauth wrong (log='$(cat "$REC/requests.log" 2>/dev/null)' tid='$(tid_of "$TJ")' secret_len=${#TJ})"
fi

# ── (h) BEARER FALLBACK still green (no gh at all) ───────────────────────────
FB="$TMP/fb-empty"; mkdir -p "$FB"   # an EMPTY PATH dir: no gh binary resolvable
fb_run() { local r="$1"; shift; ( cd "$r" && env PATH="$FB:/usr/bin:/bin" HOME="$r/home" \
    HEIMDALL_TEAM_DIR="$r/.heimdall" HMD_HAID="haid:fb" "$CLI" "$@" ); }
R="$(mkrepo fallback "")"; rm -f "$R/fb/gh"; TJ="$R/.heimdall/team.json"
fb_run "$R" new >/dev/null 2>&1; RCN=$?
S="$(secret_of "$TJ")"
[ "$RCN" -eq 0 ] && [ "${#S}" -eq 43 ] && ok "(h1) fallback: new minted a 43-char secret team" || bad "(h1) new failed (rc=$RCN len=${#S})"
FAKE="FAKE-TEAM-SECRET-0000000000-not-a-real-token"
R2="$(mkrepo fallback2 "")"; rm -f "$R2/fb/gh"; TJ2="$R2/.heimdall/team.json"
fb_run "$R2" join "$FAKE" >/dev/null 2>&1
[ "$(secret_of "$TJ2")" = "$FAKE" ] && ok "(h2) fallback: join stored the teammate secret" || bad "(h2) join did not store the secret"
SHOW="$(fb_run "$R" show 2>/dev/null)"
EXP_TID="$(HMD_S="$S" "$PY" -c 'import hashlib,os;print(hashlib.sha256(b"heimdall-team\x00"+os.environ["HMD_S"].encode()).hexdigest()[:32])')"
grep -qF "$EXP_TID" <<<"$SHOW" && ok "(h3) fallback: show prints the secret-derived team_id" || bad "(h3) show missing team_id ($EXP_TID)"

# ── (i) COEXISTENCE — a pre-existing bearer secret survives an AUTO formation ─
set_reply '{"status":200,"body":{"ok":true,"team_id":"coex55coex66","mode":"initiated","project":"fakeorg/coexist"}}'
clear_log
R="$(mkrepo coexist 1)"; TJ="$R/.heimdall/team.json"
printf '{"team_secret":"PREEXISTING-SECRET-do-not-clobber-000","created":7,"source":"new"}\n' > "$TJ"
run_auto "$R" 1 auto >/dev/null 2>&1
if [ "$(secret_of "$TJ")" = "PREEXISTING-SECRET-do-not-clobber-000" ] && [ "$(tid_of "$TJ")" = "coex55coex66" ]; then
  ok "(i) AUTO merged the team_id WITHOUT clobbering the existing bearer secret (they coexist)"
else
  bad "(i) coexistence broke (secret='$(secret_of "$TJ")' tid='$(tid_of "$TJ")')"
fi

echo
echo "============================================================"
printf "heimdall-team-auto-github: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
