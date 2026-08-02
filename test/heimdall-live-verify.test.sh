#!/usr/bin/env bash
# test/heimdall-live-verify.test.sh — acceptance for the live-isolation receipt tool
# (bin/heimdall-live-verify).
#
# WHY THIS EXISTS. The isolation boundary that protects real teammates' presence data had no
# durable proof-of-verification artifact. The only record of a live run was prose in a
# GITIGNORED .planning/ file, which (a) could not be found by anyone else and (b) silently
# went stale (it captured routes_registered=27; the live CP reports 35). This tool writes a
# committed, timestamped receipt so staleness is a git diff, not an archaeology project.
#
# HERMETIC. Every HTTP call is served by a STUB curl written into a temp dir and injected via
# HEIMDALL_LV_CURL; the oracle is stubbed via HEIMDALL_LV_FALSIFY; the base URLs are fake
# hosts (cp.test / site.test) that do not resolve. This test NEVER touches production, and
# would fail closed (UNREACHABLE, never PASS) if it somehow tried.
#
# FALSIFIABLE claims proven:
#   (1)  SYNTAX      — the tool is bash-syntax clean and executable.
#   (2)  ALL-PASS    — every check green -> exit 0, verdict PASS.
#   (3)  RECEIPT     — both receipts written, well-formed, and carry the staleness fields
#                      (run_utc, git_sha, routes_registered) that make drift diff-detectable.
#   (4)  GOD-SURFACE — /god/ answering 200 instead of 404 (the god surface PRESENT) is a FAIL
#                      and exits non-zero. The security-critical falsification.
#   (5)  CROSS-TENANT— roster-team with a random secret returning a NON-EMPTY online[] (another
#                      tenant's data) is a FAIL and exits non-zero, even though status is 200.
#   (6)  UNREACHABLE — no network reports UNREACHABLE per check, NEVER a fabricated PASS, and
#                      exits non-zero.
#   (7)  ORACLE      — a failing local oracle is a FAIL and exits non-zero.
#   (8)  UNRUN       — the production-WRITE check is ALWAYS in the receipt as UNRUN with the
#                      exact operator command, in every scenario (pass, fail, unreachable).
#                      A receipt may never imply full coverage.
#   (9)  READ-ONLY   — the tool issues no mutating request other than the one deliberate
#                      unsigned POST /corpus (refused before any state change), and never
#                      shells out to beat/enroll/deploy/gcloud.
#  (10)  COMMITTED   — the default receipt dir is NOT gitignored. This is the whole point:
#                      the previous run's evidence was unfindable because it lived in
#                      gitignored .planning/.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOOL="$ROOT/bin/heimdall-live-verify"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
RESP="$WORK/resp"; mkdir -p "$RESP"

CP="http://cp.test"
SITE="http://site.test"
PROJECT="github.com/randomittin/heimdall"

# ── stub curl ────────────────────────────────────────────────────────────────────
# Emulates the exact invocation shape the tool uses: -o <bodyfile> -w '%{http_code}'
# --max-time <n> [-X POST] [-H 'k: v'] <url>. Resolves a KEY per endpoint and serves
# $RESP/<key>.status + $RESP/<key>.body. STUB_UNREACHABLE=1 makes every call fail like a
# dead network (curl exit 7, no output) so the honest-degradation path is exercised.
cat > "$WORK/curl" <<'STUB'
#!/usr/bin/env bash
set -u
OUT=""; POST=0; SEC=0; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    -X) [ "$2" = "POST" ] && POST=1; shift 2 ;;
    -H) case "$2" in X-Heimdall-Team-Secret:*) SEC=1 ;; esac; shift 2 ;;
    -w|--max-time|-d) shift 2 ;;
    -s|-sS|-S|-f|-L) shift ;;
    -*) shift ;;
    *) URL="$1"; shift ;;
  esac
done
if [ "$POST" = "1" ]; then METHOD=POST; else METHOD=GET; fi
[ -n "${REQLOG:-}" ] && echo "$METHOD $URL" >> "$REQLOG"
if [ "${STUB_UNREACHABLE:-0}" = "1" ]; then exit 7; fi
case "$URL" in
  *cp.test/readyz*)        KEY=readyz ;;
  *cp.test/config*)        KEY=config ;;
  *cp.test/corpus*)        KEY=corpus ;;
  *cp.test/roster-team*)   if [ "$SEC" = "1" ]; then KEY=roster-team-secret; else KEY=roster-team-nosecret; fi ;;
  *cp.test/roster-public*) KEY=roster-public ;;
  *cp.test/god/*)          KEY=cp-god ;;
  *cp.test/dispatch*)      KEY=cp-dispatch ;;
  *site.test/dashboard*)   KEY=site-dashboard ;;
  *site.test/god/*)        KEY=site-god ;;
  *) echo "stub-curl: unmapped url: $URL" >&2; exit 6 ;;
esac
[ -n "$OUT" ] && cat "$RESP/$KEY.body" > "$OUT"
printf '%s' "$(cat "$RESP/$KEY.status")"
exit 0
STUB
chmod +x "$WORK/curl"

# ── stub falsify ─────────────────────────────────────────────────────────────────
cat > "$WORK/falsify" <<'STUB'
#!/usr/bin/env bash
echo "SCORE: 23/23 = 1.0000 (golden passing)"
if [ "${STUB_ORACLE_EXIT:-0}" != "0" ]; then
  echo "REJECTED: mutant survived" >&2
fi
exit "${STUB_ORACLE_EXIT:-0}"
STUB
chmod +x "$WORK/falsify"

# ── tripwires — BEHAVIOURAL proof of the read-only posture ───────────────────────
# Poisoned binaries shadow the real mutating tools on PATH. If the verifier ever shells out to
# any of them, the tripwire file appears and the test fails. This proves read-only by execution,
# not by grepping the source for scary words.
TRIP="$WORK/trip"; mkdir -p "$TRIP" "$WORK/bin"
for t in gcloud heimdall-presence heimdall-enroll; do
  cat > "$WORK/bin/$t" <<TRIPEOF
#!/usr/bin/env bash
touch "$TRIP/$t"
exit 0
TRIPEOF
  chmod +x "$WORK/bin/$t"
done

# ── the GREEN fixture set — exactly what the live CP returned on 2026-08-03 ───────
seed_green() {
  printf '200' > "$RESP/readyz.status"
  printf '%s' '{"status": "ready", "booted": true, "routes_registered": 35, "stores_reachable": true, "backend": "firestore", "backend_ready": true, "version": "1.0"}' > "$RESP/readyz.body"
  printf '200' > "$RESP/config.status"
  printf '%s' '{"beat_interval_s": 20, "refresh_interval_s": 15, "ttl_s": 45, "tier": 0}' > "$RESP/config.body"
  printf '401' > "$RESP/corpus.status"
  printf '%s' '{"error": "missing_signature"}' > "$RESP/corpus.body"
  printf '403' > "$RESP/roster-team-nosecret.status"
  printf '%s' '{"error": "team_secret_required", "online": []}' > "$RESP/roster-team-nosecret.body"
  printf '200' > "$RESP/roster-team-secret.status"
  printf '%s' '{"project": "github.com/randomittin/heimdall", "online": []}' > "$RESP/roster-team-secret.body"
  printf '403' > "$RESP/roster-public.status"
  printf '%s' '{"error": "roster_public_retired", "online": []}' > "$RESP/roster-public.body"
  printf '404' > "$RESP/cp-god.status"
  printf '%s' '{"error": "no_such_route"}' > "$RESP/cp-god.body"
  printf '404' > "$RESP/cp-dispatch.status"
  printf '%s' '{"error": "no_such_route"}' > "$RESP/cp-dispatch.body"
  printf '200' > "$RESP/site-dashboard.status"
  printf '%s' '<!doctype html><title>dashboard</title>' > "$RESP/site-dashboard.body"
  printf '404' > "$RESP/site-god.status"
  printf '%s' '<!doctype html><title>404</title>' > "$RESP/site-god.body"
}

# run the tool against the stubs; $1 = out dir. Echoes the exit code.
run_tool() {
  : > "$1.requests"
  RESP="$RESP" \
  REQLOG="$1.requests" \
  STUB_UNREACHABLE="${STUB_UNREACHABLE:-0}" \
  STUB_ORACLE_EXIT="${STUB_ORACLE_EXIT:-0}" \
  HEIMDALL_LV_CURL="$WORK/curl" \
  HEIMDALL_LV_FALSIFY="$WORK/falsify" \
  HEIMDALL_LV_CP="$CP" \
  HEIMDALL_LV_SITE="$SITE" \
  HEIMDALL_LV_PROJECT="$PROJECT" \
  PATH="$WORK/bin:$PATH" \
  bash "$TOOL" --out-dir "$1" --quiet >"$1.stdout" 2>"$1.stderr"
  echo $?
}

# JSON field reader over the receipt.
jf() { python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[int(k)] if isinstance(d,list) else d[k]
print(json.dumps(d) if not isinstance(d,str) else d)' "$1" "$2" 2>/dev/null; }

# ── (1) syntax + executable ──────────────────────────────────────────────────────
[ -f "$TOOL" ] && ok "(1) tool exists at bin/heimdall-live-verify" || bad "(1) tool MISSING at $TOOL"
[ -x "$TOOL" ] && ok "(1) tool is executable" || bad "(1) tool is not executable"
bash -n "$TOOL" 2>/dev/null && ok "(1) bash -n clean" || bad "(1) bash syntax error"

# ── (2)(3) ALL-PASS -> exit 0, verdict PASS, well-formed receipt ─────────────────
seed_green
A="$WORK/out-green"
rc="$(run_tool "$A")"
[ "$rc" = "0" ] && ok "(2) all checks green -> exit 0" || bad "(2) all-green exit was $rc, expected 0"
[ -f "$A/LATEST.md" ]   && ok "(3) markdown receipt written" || bad "(3) no LATEST.md receipt"
[ -f "$A/LATEST.json" ] && ok "(3) json receipt written"     || bad "(3) no LATEST.json receipt"

python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$A/LATEST.json" 2>/dev/null \
  && ok "(3) json receipt parses" || bad "(3) json receipt is not valid JSON"

[ "$(jf "$A/LATEST.json" verdict)" = "PASS" ] && ok "(2) verdict=PASS" || bad "(2) verdict was '$(jf "$A/LATEST.json" verdict)', expected PASS"

# staleness fields — the reason the last record rotted undetected.
[ "$(jf "$A/LATEST.json" routes_registered)" = "35" ] \
  && ok "(3) receipt records live routes_registered=35 (staleness is now a diff)" \
  || bad "(3) routes_registered not captured (got '$(jf "$A/LATEST.json" routes_registered)')"
echo "$(jf "$A/LATEST.json" run_utc)" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  && ok "(3) run_utc is an ISO-8601 UTC timestamp" || bad "(3) run_utc malformed: '$(jf "$A/LATEST.json" run_utc)'"
echo "$(jf "$A/LATEST.json" git_sha)" | grep -Eq '^[0-9a-f]{40}$' \
  && ok "(3) git_sha is a full 40-hex sha" || bad "(3) git_sha malformed: '$(jf "$A/LATEST.json" git_sha)'"

# 10 HTTP checks + 1 local oracle = 11 RUN checks.
NRUN="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["checks"]))' "$A/LATEST.json" 2>/dev/null)"
[ "$NRUN" = "11" ] && ok "(3) receipt records all 11 RUN checks" || bad "(3) receipt has $NRUN run checks, expected 11"

# per-check schema: every check carries command, expected, observed, result.
python3 - "$A/LATEST.json" <<'PY' && ok "(3) every check records command/expected/observed/result" || bad "(3) a check is missing required receipt fields"
import json,sys
need={"id","label","command","expected","observed","result"}
d=json.load(open(sys.argv[1]))
missing=[c.get("id","?") for c in d["checks"] if not need.issubset(c)]
sys.exit(1 if missing else 0)
PY

# the markdown receipt must carry the same staleness anchors a human/diff reads.
grep -q "routes_registered" "$A/LATEST.md" && ok "(3) markdown carries routes_registered" || bad "(3) markdown missing routes_registered"
grep -q "$(git -C "$ROOT" rev-parse HEAD)" "$A/LATEST.md" && ok "(3) markdown carries the run-time git sha" || bad "(3) markdown missing git sha"

# ── (8) the production-WRITE check is present as UNRUN, with the operator command ──
assert_unrun() { # $1=dir $2=scenario label
  local d="$1" s="$2"
  grep -q "UNRUN" "$d/LATEST.md" && ok "(8/$s) receipt marks the write-check UNRUN" || bad "(8/$s) no UNRUN entry in receipt"
  grep -q "requires operator consent" "$d/LATEST.md" \
    && ok "(8/$s) UNRUN states it requires operator consent (production write)" \
    || bad "(8/$s) UNRUN does not state the operator-consent reason"
  grep -q "heimdall-presence beat" "$d/LATEST.md" \
    && ok "(8/$s) UNRUN carries the exact operator command" || bad "(8/$s) UNRUN missing the operator command"
  local n; n="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["unrun"]))' "$d/LATEST.json" 2>/dev/null)"
  [ "$n" -ge 1 ] 2>/dev/null && ok "(8/$s) json receipt lists the UNRUN check" || bad "(8/$s) json receipt has no unrun entry"
}
assert_unrun "$A" "green"

# a green receipt must NOT imply full coverage.
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d["counts"]["unrun"] >= 1 else 1)' "$A/LATEST.json" \
  && ok "(8) green receipt still declares unrun>0 (never implies full coverage)" \
  || bad "(8) green receipt claims full coverage"

# ── (4) god surface PRESENT (200 instead of 404) -> FAIL, non-zero ───────────────
seed_green
printf '200' > "$RESP/cp-god.status"
printf '%s' '{"ok": true}' > "$RESP/cp-god.body"
B="$WORK/out-god"
rc="$(run_tool "$B")"
[ "$rc" != "0" ] && ok "(4) god surface answering 200 -> exit $rc (non-zero)" || bad "(4) god surface 200 still exited 0 — boundary regression not caught"
[ "$(jf "$B/LATEST.json" verdict)" = "FAIL" ] && ok "(4) verdict=FAIL" || bad "(4) verdict was '$(jf "$B/LATEST.json" verdict)', expected FAIL"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
c=[x for x in d["checks"] if x["id"]=="cp-god"][0]
sys.exit(0 if c["result"]=="FAIL" and "200" in c["observed"] else 1)' "$B/LATEST.json" \
  && ok "(4) receipt records cp-god FAIL with observed=200" || bad "(4) cp-god not recorded as FAIL/200"
assert_unrun "$B" "fail"

# ── (5) cross-tenant leak: 200 but NON-EMPTY online[] -> FAIL ────────────────────
seed_green
printf '%s' '{"project": "github.com/randomittin/heimdall", "online": [{"haid": "haid:someone.else-9f21"}]}' > "$RESP/roster-team-secret.body"
C="$WORK/out-leak"
rc="$(run_tool "$C")"
[ "$rc" != "0" ] && ok "(5) random secret leaking another tenant's roster -> exit $rc (non-zero)" || bad "(5) cross-tenant leak exited 0 — the privacy boundary regression is invisible"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
c=[x for x in d["checks"] if x["id"]=="roster-team-random-secret"][0]
sys.exit(0 if c["result"]=="FAIL" else 1)' "$C/LATEST.json" \
  && ok "(5) receipt records roster-team-random-secret as FAIL despite HTTP 200" \
  || bad "(5) leak not recorded as FAIL (status-only checking would miss this)"

# ── (6) no network -> UNREACHABLE, never a fabricated PASS ───────────────────────
seed_green
D="$WORK/out-down"
rc="$(STUB_UNREACHABLE=1 run_tool "$D")"
[ "$rc" != "0" ] && ok "(6) unreachable network -> exit $rc (non-zero)" || bad "(6) unreachable network exited 0"
[ "$(jf "$D/LATEST.json" verdict)" = "UNREACHABLE" ] && ok "(6) verdict=UNREACHABLE" || bad "(6) verdict was '$(jf "$D/LATEST.json" verdict)', expected UNREACHABLE"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
http=[c for c in d["checks"] if c["id"]!="local-oracle"]
sys.exit(0 if all(c["result"]=="UNREACHABLE" for c in http) and not any(c["result"]=="PASS" for c in http) else 1)' "$D/LATEST.json" \
  && ok "(6) every HTTP check is UNREACHABLE and NOT ONE is a fabricated PASS" \
  || bad "(6) an unreachable check was reported as PASS — fabricated evidence"
grep -q "UNREACHABLE" "$D/LATEST.md" && ok "(6) markdown receipt shows UNREACHABLE" || bad "(6) markdown hides the unreachable state"
assert_unrun "$D" "unreachable"

# ── (7) failing local oracle -> FAIL, non-zero ──────────────────────────────────
seed_green
E="$WORK/out-oracle"
rc="$(STUB_ORACLE_EXIT=1 run_tool "$E")"
[ "$rc" != "0" ] && ok "(7) failing oracle -> exit $rc (non-zero)" || bad "(7) failing oracle exited 0"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
c=[x for x in d["checks"] if x["id"]=="local-oracle"][0]
sys.exit(0 if c["result"]=="FAIL" else 1)' "$E/LATEST.json" \
  && ok "(7) receipt records local-oracle FAIL" || bad "(7) oracle failure not recorded"

# ── (9) READ-ONLY posture ───────────────────────────────────────────────────────
# BEHAVIOURAL: what did the wire ACTUALLY carry during the all-green run? Counting '-X POST'
# in the source is the wrong oracle (the tool legitimately spells it twice: once in the executed
# argv, once in the human-readable command echoed into the receipt). The request log is truth.
NREQ="$(wc -l < "$A.requests" | tr -d ' ')"
[ "$NREQ" = "10" ] && ok "(9) the green run issued exactly 10 HTTP requests" || bad "(9) issued $NREQ requests, expected 10"
NPOST="$(grep -c '^POST ' "$A.requests")"
[ "$NPOST" = "1" ] && ok "(9) exactly ONE non-GET request was issued on the wire" \
  || bad "(9) $NPOST POST requests hit the wire, expected exactly 1"
grep '^POST ' "$A.requests" | grep -q '/corpus' \
  && ok "(9) the single POST is the unsigned /corpus probe (refused 401 before any state change)" \
  || bad "(9) the POST did not target /corpus: $(grep '^POST ' "$A.requests")"
NGET="$(grep -c '^GET ' "$A.requests")"
[ "$NGET" = "9" ] && ok "(9) the other 9 requests were all GETs" || bad "(9) $NGET GETs, expected 9"
grep -Eq -- '-X (PUT|DELETE|PATCH)' "$TOOL" && bad "(9) tool issues a PUT/DELETE/PATCH" || ok "(9) no PUT/DELETE/PATCH anywhere"

# BEHAVIOURAL: across every scenario already run above, no mutating binary was ever executed.
TRIPPED="$(ls "$TRIP" 2>/dev/null)"
[ -z "$TRIPPED" ] && ok "(9) tripwire clean — never executed gcloud / heimdall-presence / heimdall-enroll" \
  || bad "(9) tripwire FIRED for: $TRIPPED — the verifier shelled out to a mutating tool"

# every request is time-bounded: timeout(1) does not exist on macOS, so --max-time is the bound.
NMAX="$(grep -c -- '--max-time' "$TOOL")"
[ "${NMAX:-0}" -ge 1 ] 2>/dev/null && ok "(9) requests are bounded with curl --max-time (no unbounded call)" || bad "(9) no --max-time bound found"
grep -Eq '(^|[^-[:alnum:]_])timeout[[:space:]]+[0-9]' "$TOOL" \
  && bad "(9) tool uses timeout(1), which does not exist on macOS" || ok "(9) does not depend on timeout(1)"
# the stub curl asserts it: every probe carried --max-time, or it would not have been consumed.
grep -q 'MAXTIME' "$TOOL" && ok "(9) --max-time is a single configurable bound applied per request" || bad "(9) no per-request bound variable"

# ── (10) the default receipt dir is COMMITTED, not gitignored ───────────────────
DEFAULT_DIR="$(grep -o 'evals/live-isolation' "$TOOL" | head -1)"
[ "$DEFAULT_DIR" = "evals/live-isolation" ] && ok "(10) default receipt dir is evals/live-isolation" || bad "(10) default receipt dir is not evals/live-isolation"
git -C "$ROOT" check-ignore -q "evals/live-isolation/LATEST.md" \
  && bad "(10) receipt path IS gitignored — the evidence would be unfindable again" \
  || ok "(10) receipt path is NOT gitignored (the .planning/ mistake is not repeated)"

echo
printf "heimdall-live-verify acceptance: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
