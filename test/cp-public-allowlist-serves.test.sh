#!/usr/bin/env bash
# test/cp-public-allowlist-serves.test.sh — THE DEPLOYED-SHAPE GUARD FOR THE PUBLIC ALLOWLIST.
#
# THE FAILURE CLASS THIS EXISTS FOR (deployed-shape: green in review, 404 in the container).
# cp_publicsurface.PUBLIC_ROUTES is the SINGLE SOURCE OF TRUTH for what the internet-facing
# service serves — when public_surface_enabled(), cp_server serves ONLY these and returns a
# FLAT {"error":"no_such_route"} 404 for everything else. That makes the allowlist a PROMISE,
# and nothing checked the promise was KEEPABLE: an entry could name a route that NOTHING on
# the app actually serves, and the surface would answer its own boundary 404 to a caller
# following the documented contract. `test/cp-public-surface.test.sh` spot-checks a HAND-LISTED
# handful of routes, so a NEWLY added allowlist entry with no serving route ships unnoticed.
# THIS test hand-lists nothing: it ITERATES PUBLIC_ROUTES itself, so every present and future
# entry is covered the moment it is added.
#
# WHY A LIVE SERVER AND NOT A REGISTRY READ. A public route reaches its handler through FOUR
# different mechanisms in cp_server._handle, and a registry-only check sees just two of them:
#   1. the pre-auth HEALTH short-circuit      (cp_diag.is_health_path — /healthz, /readyz)
#   2. the pre-auth PUBLIC seam               (cp_server._public_route — /enroll, /config, …)
#   3. the authenticated §10 seam             (cp_server._route — /roster, /presence, …)
#   4. INLINE post-auth special cases         (/rr-task, /team/cred, /team/install — served by
#      dedicated branches in _handle, never registered into the seam at all)
# Plus cp_server.register_late_routes wires cp_session's dashboard routes OUTSIDE cp_boot.boot().
# Only a REAL request against a REAL public-surface server proves "this route serves" across all
# four; anything less encodes an internal mechanism and rots the next time one is added.
#
# THE ORACLE (two independent halves — HTTP alone is NOT sufficient, and here is why).
#   • RESOLUTION (claim 2, the load-bearing half). For each allowlisted (METHOD, PATH), at least
#     one of the four mechanisms above must resolve it; otherwise the request falls through to
#     `Response(404, {"error": "no_such_route"})` at the end of _handle. The inline set is DERIVED
#     from cp_server's own source (the `route_path == "…"` / `route_path in (…)` comparisons), not
#     hand-listed, so an inline route added later is picked up automatically.
#   • LIVE 404 (claim 2b, the confirming half). No allowlisted route may answer the flat
#     {no_such_route} 404 over a real request to a real public-surface server.
# HTTP alone cannot carry this test: the §3 auth chokepoint runs BEFORE the route lookup, so an
# UNREGISTERED but signature-gated path (say /roster) answers 401 exactly like a registered one —
# the defect is invisible from outside. That is precisely the trap this test exists to avoid, so
# resolution is asserted in-process and the live sweep confirms the pre-auth classes end to end.
# We assert reachability rather than a per-route status so the test stays true when a route's
# gate legitimately changes — reachability is the property that breaks in this failure class.
#
# THE LIVE ANOMALY THAT MOTIVATED IT (2026-07-17, .planning/PARTB-ANSWERS.md §2; still live
# 2026-08-03). `GET https://heimdall-cp-public-…run.app/healthz` -> 404, while /readyz -> 200.
# ROOT CAUSE, proven by headers: the 404 is `content-type: text/html` (Google's branded error
# page) and carries NO `x-cloud-trace-context`, while the /readyz 200 carries one — the request
# never reached the container. Google's Cloud Run edge intercepts an EXTERNAL GET /healthz
# before routing. The app-side registration is CORRECT (claim 2 below proves /healthz serves),
# so the allowlist entry MUST stay; the stale artifact was the runbook, which used an endpoint
# the edge eats as its first reachability probe. Claim 5 pins that doc so it cannot regress.
#
# FALSIFIABLE claims proven:
#   (1) the public surface comes up (HEIMDALL_PUBLIC_SURFACE=1).
#   (2) EVERY route in PUBLIC_ROUTES RESOLVES to a handler through one of the four mechanisms.
#  (2b) EVERY route in PUBLIC_ROUTES answers a live request without the flat {no_such_route} 404.
#   (3) MEASURED DELTA (the keep gate) — the SAME probe run over a MUTATED allowlist (one extra
#       entry naming a route nothing serves) reports exactly that entry unserved, while the real
#       allowlist reports zero. delta > 0, so the probe demonstrably CAN go red; a check that
#       cannot fail proves nothing (skills/self-improve keep/discard discipline).
#   (4) DEPLOY PARITY — every route in deploy-public-surface.sh's canonical PUBLIC_SURFACE_ROUTES
#       string is in PUBLIC_ROUTES, so the deploy contract cannot advertise a route the app
#       refuses to serve.
#   (5) EXTERNAL-PROBE DOC GUARD — docs/team-validation-runbook.md's reachability step probes
#       /readyz, never /healthz (which Google's edge 404s before the container — see above).
#
# Hermetic: a throwaway HEIMDALL_HOME under a temp dir, a loopback server on a free port, a
# throwaway PKI seed. No network, no creds, no live bin/lib mutation.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/bin/lib"
CLI="$ROOT/bin/heimdall-control-plane"
DEPLOY_SH="$ROOT/deploy/cloud-run/deploy-public-surface.sh"
RUNBOOK="$ROOT/docs/team-validation-runbook.md"
PY="${PYTHON:-python3}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# ── (4) DEPLOY PARITY — the gcloud-facing contract names only routes the app allowlists ──────
# Runs FIRST: it needs no server, so a parity break is reported even where crypto is absent.
PARITY="$("$PY" - "$LIB" "$DEPLOY_SH" <<'PY'
import re, sys
sys.path.insert(0, sys.argv[1])
import cp_publicsurface
src = open(sys.argv[2], encoding="utf-8").read()
m = re.search(r'^PUBLIC_SURFACE_ROUTES="([^"]+)"', src, re.M)
if not m:
    print("MISSING PUBLIC_SURFACE_ROUTES in the deploy script"); sys.exit(1)
missing = []
for entry in m.group(1).split(","):
    parts = entry.strip().split(None, 1)
    if len(parts) != 2:
        missing.append(entry.strip()); continue
    method, path = parts[0].upper(), parts[1].strip()
    if (method, path) not in cp_publicsurface.PUBLIC_ROUTES:
        missing.append("%s %s" % (method, path))
if missing:
    print("deploy advertises routes absent from PUBLIC_ROUTES: " + "; ".join(missing)); sys.exit(1)
print("%d deploy-named routes all present in PUBLIC_ROUTES" % len(m.group(1).split(",")))
PY
)"
if [ $? -eq 0 ]; then ok "(4) deploy parity: $PARITY"; else bad "(4) deploy parity broken -> ${PARITY:-unknown}"; fi

# ── (5) EXTERNAL-PROBE DOC GUARD — the runbook must not probe an edge-eaten endpoint ─────────
if [ ! -f "$RUNBOOK" ]; then
  bad "(5) $RUNBOOK not found — the external-probe guard cannot run"
else
  # Any runbook line that curls a $CP_URL/$PUB endpoint for reachability must target /readyz.
  HZ_PROBE="$(grep -nE '^[^#]*curl[^|]*\$\{?(CP_URL|PUB|PUBLIC_URL)\}?/healthz' "$RUNBOOK" || true)"
  if [ -n "$HZ_PROBE" ]; then
    bad "(5) runbook still probes /healthz externally (Google's edge 404s it before the container): $HZ_PROBE"
  else
    ok "(5) runbook uses no external GET /healthz reachability probe"
  fi
  grep -qE 'curl[^|]*\$\{?(CP_URL|PUB|PUBLIC_URL)\}?/readyz' "$RUNBOOK" \
    && ok "(5) runbook probes /readyz for reachability (the endpoint the edge actually routes)" \
    || bad "(5) runbook has no /readyz reachability probe"
fi

# ── the live public surface (claims 1-3) ─────────────────────────────────────────────────────
if ! "$PY" -c "import sys;sys.path.insert(0,'$LIB');import cp_auth;sys.exit(0 if cp_auth.crypto_available() else 1)"; then
  echo "  SKIP no crypto backend (cryptography|pynacl) — serve needs a server identity."
  printf "cp-public-allowlist-serves: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m (server checks SKIPPED)\n" "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

PKI="$("$PY" -c "import base64,os;print(base64.b64encode(os.urandom(32)).decode())")"
EXT="$(mktemp -d)"; SRV=""
cleanup(){ [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; }; rm -rf "$EXT"; }
trap cleanup EXIT

PORT="$("$PY" -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")"
URL="http://127.0.0.1:$PORT"

# Generous per-IP caps: a 429 still counts as SERVED, but keeping the limits loose means the
# sweep reads each route's real gate rather than the limiter, which is the clearer signal.
HMD_CP_GUARD_PID=$$ HEIMDALL_PUBLIC_SURFACE=1 HEIMDALL_CP_PKI_KEY="$PKI" \
  HEIMDALL_ENROLL_TOKEN="allowlist-serves-fixture-token-$$" \
  HEIMDALL_HOME="$EXT/pub" \
  "$CLI" serve --host 127.0.0.1 --port "$PORT" >"$EXT/serve.out" 2>"$EXT/serve.err" &
SRV=$!

UP=""
for _ in $(seq 1 80); do
  if "$PY" -c "import socket,sys;s=socket.socket();s.settimeout(0.2)
try:
    s.connect(('127.0.0.1',$PORT)); s.close()
except Exception:
    sys.exit(1)" 2>/dev/null; then UP=1; break; fi
  sleep 0.1
done
if [ -z "$UP" ]; then
  bad "(1) public surface did not come up on $URL"
  printf "cp-public-allowlist-serves: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
  exit 1
fi
ok "(1) public surface up on $URL (HEIMDALL_PUBLIC_SURFACE=1)"

# The sweep: RESOLVE every allowlisted route in-process (all four mechanisms) AND probe it live,
# then repeat resolution over a MUTATED superset. The mutation ("GET /__allowlist_falsifier__")
# is the in-memory stand-in for the real defect — an allowlist entry naming a route nothing
# serves — so claim 3 measures the probe's own discriminating power on every run.
# NOTE: the probe is written to a FILE rather than piped through a `$(… <<'PY' …)` heredoc.
# bash 3.2 (what macOS ships) mis-scans a command substitution whose heredoc body carries
# unbalanced parens — and this probe's regexes are full of them. A file sidesteps the parser.
cat > "$EXT/sweep.py" <<'PY'
import inspect, json, re, sys, urllib.error, urllib.request
sys.path.insert(0, sys.argv[1])
BASE, HOME = sys.argv[2], sys.argv[3]

import cp_boot, cp_diag, cp_publicsurface, cp_server

# Assemble the SAME surface serve() does: boot() wires the capability pieces, and
# register_extended_routes() wires cp_session/cp_god, which boot() deliberately does not.
cp_boot.boot(home=HOME, start_tick=False, resume=False)
cp_server.register_extended_routes(home=HOME)

# The INLINE post-auth handlers — branches in _handle that answer BEFORE the seam lookup and are
# never registered into it (/rr-task, /team/cred, /team/install, /dispatch). DERIVED from
# cp_server's own source so a future inline route is covered without editing this test; a route
# added by some other shape simply reads as unserved here, which is the safe direction.
SRC = inspect.getsource(cp_server)
INLINE = set()
for m, p in re.findall(r'method == "(\w+)" and route_path == "([^"]+)"', SRC):
    INLINE.add((m, p))
for m, group in re.findall(r'method == "(\w+)" and route_path in \(([^)]+)\)', SRC):
    for p in re.findall(r'"([^"]+)"', group):
        INLINE.add((m, p))

def resolves(method, path):
    """How (method, path) reaches a handler, or None if _handle would fall through to its
    terminal Response(404, {"error": "no_such_route"}). Mirrors _handle's dispatch order."""
    if cp_diag.is_health_path(method, path):
        return "health-shortcircuit"
    if cp_server._public_route(method, path) is not None:
        return "pre-auth-public-seam"
    if (method, path) in INLINE:
        return "inline-post-auth"
    if cp_server._route(method, path) is not None:
        return "authed-seam"
    return None

def live_boundary_404(method, path):
    """True iff a REAL request got the app's own flat boundary 404. None on transport failure.
    Confirms the pre-auth classes end to end; the §3 chokepoint 401s the signed ones before the
    route lookup, which is exactly why resolves() above — not this — is the load-bearing check."""
    data = b"{}" if method in ("POST", "PUT", "PATCH") else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        urllib.request.urlopen(req, timeout=8)
        return False
    except urllib.error.HTTPError as e:
        if e.code != 404:
            return False
        try:
            return "no_such_route" in (e.read() or b"").decode("utf-8", "replace")
        except Exception:
            return False
    except Exception:
        return None

def unresolved(routes):
    return ["%s %s" % (m, p) for m, p in sorted(routes) if resolves(m, p) is None]

real = set(cp_publicsurface.PUBLIC_ROUTES)
FALSIFIER = ("GET", "/__allowlist_falsifier__")

live_dead, live_errors = [], []
for m, p in sorted(real):
    verdict = live_boundary_404(m, p)
    if verdict is None:
        live_errors.append("%s %s" % (m, p))
    elif verdict:
        live_dead.append("%s %s" % (m, p))

print(json.dumps({
    "total": len(real),
    "unresolved_real": unresolved(real),
    "unresolved_mutated": unresolved(real | {FALSIFIER}),
    "live_dead": live_dead,
    "live_errors": live_errors,
    "inline": sorted("%s %s" % k for k in INLINE),
    "falsifier": "%s %s" % FALSIFIER,
}))
PY

mkdir -p "$EXT/home"
SWEEP="$("$PY" "$EXT/sweep.py" "$LIB" "$URL" "$EXT/home" 2>"$EXT/sweep.err")"
[ -s "$EXT/sweep.err" ] && printf "  \033[90msweep stderr: %s\033[0m\n" "$(tail -n 3 "$EXT/sweep.err")"

if [ -z "$SWEEP" ]; then
  bad "(2) allowlist sweep produced no output (probe crashed)"
else
  read -r TOTAL UNRES_REAL UNRES_MUT LIVE_DEAD LIVE_ERR FALS <<EOF2
$("$PY" -c "
import json,sys
d=json.loads(sys.argv[1])
print(d['total'], len(d['unresolved_real']), len(d['unresolved_mutated']),
      len(d['live_dead']), len(d['live_errors']), d['falsifier'].replace(' ','_'))
" "$SWEEP")
EOF2

  DETAIL="$("$PY" -c "
import json,sys
d=json.loads(sys.argv[1])
print('unresolved=' + ('; '.join(d['unresolved_real']) or 'none')
      + ' | live_boundary_404=' + ('; '.join(d['live_dead']) or 'none')
      + ' | transport_errors=' + ('; '.join(d['live_errors']) or 'none')
      + ' | inline_derived=' + ('; '.join(d['inline']) or 'none'))
" "$SWEEP")"

  # (2) every allowlisted route RESOLVES to a handler (the load-bearing half).
  if [ "$UNRES_REAL" = "0" ]; then
    ok "(2) all $TOTAL PUBLIC_ROUTES entries RESOLVE to a handler (health / pre-auth seam / inline / authed seam)"
  else
    bad "(2) $UNRES_REAL of $TOTAL allowlisted routes resolve to NOTHING -> $DETAIL"
  fi

  # (2b) and none of them answers the flat boundary 404 against a live server.
  if [ "$LIVE_ERR" != "0" ]; then
    bad "(2b) transport errors during the live sweep — verdict unsafe: $DETAIL"
  elif [ "$LIVE_DEAD" = "0" ]; then
    ok "(2b) no allowlisted route answers the flat {no_such_route} 404 on a live public surface"
  else
    bad "(2b) $LIVE_DEAD of $TOTAL allowlisted routes answer the flat boundary 404 live -> $DETAIL"
  fi

  # (3) MEASURED DELTA — the same probe flags a mutated allowlist. No delta -> the check is inert.
  DELTA=$((UNRES_MUT - UNRES_REAL))
  printf "  \033[90mmeasured: real_unresolved=%s mutated_unresolved=%s delta=%s (mutation: %s)\033[0m\n" \
    "$UNRES_REAL" "$UNRES_MUT" "$DELTA" "$FALS"
  if [ "$UNRES_REAL" != "0" ]; then
    bad "(3) baseline is NOT clean (real=$UNRES_REAL unresolved) — delta is meaningless until claim 2 passes"
  elif [ "$DELTA" -eq 1 ]; then
    ok "(3) measured delta 1 on a clean baseline -> KEEP (the probe detects an allowlist entry that does not serve)"
  else
    bad "(3) NO measured delta (real=$UNRES_REAL mutated=$UNRES_MUT) -> the probe cannot discriminate; it would never catch the real defect"
  fi
fi

echo
printf "cp-public-allowlist-serves: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
