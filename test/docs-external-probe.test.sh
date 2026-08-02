#!/usr/bin/env bash
# docs-external-probe.test.sh — THE EXTERNAL-PROBE DOC GUARD, REPO-WIDE.
#
# WHAT THIS GATES. No operator-facing doc may tell a human to probe a DEPLOYED/PUBLIC URL
# with `GET /healthz`. Google's Cloud Run edge intercepts an EXTERNAL GET /healthz and answers
# its own branded HTML 404 BEFORE the request reaches the container (the 404 carries no
# `x-cloud-trace-context`; a /readyz 200 does). An operator following such a doc sees 404 and
# concludes the service is DOWN when it is healthy. /readyz is served by the SAME pre-auth
# handler (bin/lib/cp_diag.py is_health_path), IS routed by the edge, and is the stronger
# signal (it proves the backend initialised: {"status":"ready","booted":true,…}).
#
# WHY THIS EXISTS SEPARATELY. cp-public-allowlist-serves.test.sh check (5) already guards this
# class — but it is hardcoded to ONE file (docs/team-validation-runbook.md). That scope gap is
# how deploy/cloud-run/GO-LIVE-RUNBOOK.md kept telling operators `curl "${PUBLIC_URL}/healthz"
# # Expect: 200` after the same defect had been fixed next door. This sweeps EVERY *.md.
#
# WHAT IT DOES *NOT* FLAG (deliberate — these are correct and must stay):
#   * Route inventories / allowlist tables that LIST `GET /healthz` (README, runbook tables).
#     /healthz is a real, correctly-registered public route; it is never to be removed.
#   * Prose that explains this very rule (the "probe /readyz, not /healthz" blockquotes).
#   * A LOCAL probe — `http://127.0.0.1:$PORT/healthz` — which reaches our app and returns 200
#     (e.g. the readiness poll in test/cp-roster-team-deployed.test.sh).
#   * deploy/cloud-run/deploy-public-rr.sh — a *.sh executor, not operator prose, and it already
#     tries /healthz then FALLS BACK to /readyz and dies on failure. Correct as written.
# The detector therefore requires all three: a `curl`, a DEPLOYED URL (a public-URL variable or
# a literal https:// host), and `/healthz`.
#
# Hermetic: greps the working tree + one throwaway temp fixture. No network, no creds, no server.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# THE DETECTOR — one implementation, used by BOTH the real sweep (1) and the falsifiability
# mutation (2), so the mutation proves the *shipping* detector fires, not a lookalike.
#   $1 = directory to sweep. Prints `path:line:text` per offender; exit status is grep's.
BAD_PROBE='curl[^|]*(\$\{?(CP_URL|PUB|PUBLIC_URL|GATED_URL|SERVICE_URL|BASE_URL)\}?|https://[A-Za-z0-9._-]+)/healthz'
# NOTE: the skip-list uses --exclude-dir (NAME matching), never a path-substring filter on the
# results. A `grep -v /.claude/worktrees/` filter silently swallowed EVERY hit when the checkout
# itself lives under .claude/worktrees/<agent> (how Heimdall's agents run) — the sweep passed
# vacuously with a real defect in the tree. Name matching is position-independent.
scan_healthz_probes() {
  grep -rnE --include='*.md' \
    --exclude-dir='worktrees' --exclude-dir='node_modules' --exclude-dir='.git' \
    "$BAD_PROBE" "$1" 2>/dev/null
}

echo "============================================================"
echo "EXTERNAL-PROBE DOC GUARD (repo-wide *.md sweep)"
echo "  root=$ROOT"
echo "============================================================"
echo

# ── (1) THE SWEEP — no *.md tells an operator to curl a deployed URL's /healthz ──────────────
echo "#1 no *.md probes a DEPLOYED /healthz"
OFFENDERS="$(scan_healthz_probes "$ROOT")"
if [ -n "$OFFENDERS" ]; then
  bad "(1) a doc probes /healthz against a deployed URL — the edge 404s it before the container:"
  printf '%s\n' "$OFFENDERS" | sed 's/^/        /'
  echo "        FIX: probe /readyz instead (same pre-auth handler, actually routed by the edge)."
else
  ok "(1) no *.md probes a deployed /healthz (operators are never sent at an edge-eaten endpoint)"
fi

# ── (2) FALSIFIABILITY — plant the exact defect in a fixture; the SAME detector must fire ────
# Without this, a detector that silently matches nothing would "pass" forever.
echo
echo "#2 FALSIFIABLE: the detector fires on a planted bad probe (measured delta)"
FIX="$(mktemp -d -t "docsprobe.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$FIX"' EXIT

# a) a fixture carrying ONLY the safe shapes must stay clean (no false positives).
cat >"$FIX/safe.md" <<'MD'
| Routes | `POST /enroll, GET /roster, GET /healthz, GET /readyz` |
Probe `/readyz`, not `/healthz` — the Cloud Run edge 404s an external `GET /healthz`.
```bash
curl -s -o /dev/null -w '%{http_code}\n' "${PUBLIC_URL}/readyz"   # Expect: 200
curl -s "http://127.0.0.1:${CP_PORT}/healthz"   # local: reaches the app, 200
```
MD
SAFE_HITS="$(scan_healthz_probes "$FIX" | wc -l | tr -d ' ')"
[ "$SAFE_HITS" = "0" ] \
  && ok "(2a) route tables + rule prose + a LOCAL /healthz probe are NOT flagged (0 false positives)" \
  || { bad "(2a) the detector false-positived on safe shapes ($SAFE_HITS hits):"; scan_healthz_probes "$FIX" | sed 's/^/        /'; }

# b) plant the real regression (the exact line GO-LIVE-RUNBOOK.md shipped) -> must be caught.
cat >"$FIX/planted.md" <<'MD'
Confirm the public surface itself is alive:
```bash
curl -s -o /dev/null -w '%{http_code}\n' "${PUBLIC_URL}/healthz"   # Expect: 200
```
MD
PLANTED_HITS="$(scan_healthz_probes "$FIX" | wc -l | tr -d ' ')"
printf "  \033[90mmeasured: safe_hits=%s planted_hits=%s delta=%s\033[0m\n" \
  "$SAFE_HITS" "$PLANTED_HITS" "$((PLANTED_HITS - SAFE_HITS))"
if [ "$PLANTED_HITS" -gt "$SAFE_HITS" ]; then
  ok "(2b) the planted deployed-/healthz probe IS caught -> delta $((PLANTED_HITS - SAFE_HITS)) (the guard can fail)"
else
  bad "(2b) the planted bad probe was NOT caught — this guard is vacuous and proves nothing"
fi

# c) a literal deployed host (not just a ${VAR}) is caught too.
cat >"$FIX/planted2.md" <<'MD'
curl -s https://heimdall-cp-public-eqfrs7sfuq-uc.a.run.app/healthz
MD
LIT_HITS="$(scan_healthz_probes "$FIX" | wc -l | tr -d ' ')"
[ "$LIT_HITS" -gt "$PLANTED_HITS" ] \
  && ok "(2c) a LITERAL https://…run.app/healthz probe is caught too (not just \${PUBLIC_URL})" \
  || bad "(2c) a literal deployed-host /healthz probe slipped past the detector"
rm -f "$FIX/planted.md" "$FIX/planted2.md"

# ── (3) POSITIVE CONTROL — the operator runbooks still HAVE a reachability probe ─────────────
# Guards the lazy "fix": deleting the probe instead of correcting it would satisfy (1) while
# leaving operators with no way to confirm the surface is alive.
echo
echo "#3 the operator runbooks still carry a /readyz reachability probe"
READYZ_RE='curl[^|]*\$\{?(CP_URL|PUB|PUBLIC_URL)\}?/readyz'
for rb in "docs/team-validation-runbook.md" "deploy/cloud-run/GO-LIVE-RUNBOOK.md"; do
  if [ ! -f "$ROOT/$rb" ]; then
    bad "(3) $rb not found — the positive control cannot run"
  elif grep -qE "$READYZ_RE" "$ROOT/$rb"; then
    ok "(3) $rb probes /readyz for reachability"
  else
    bad "(3) $rb has NO /readyz reachability probe (was the probe deleted instead of fixed?)"
  fi
done

echo
echo "============================================================"
printf "docs-external-probe: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
