#!/usr/bin/env bash
# heimdall-issue-corpus-emit.test.sh — the Wave-1 falsifier belt for the local
# anonymized-issue emit engine (bin/lib/issue_corpus.py). Mirrors the sections of
# test/heimdall-corpus-ingest.test.sh. Each section is a RED-without-fix falsifier
# mapped to an invariant in evals/oracles/issue-collection/INVARIANTS.md:
#
#   consent-off      INV-D  telemetry OFF => emit is a pure no-op (zero bytes)
#   leaked-content   INV-A  a planted path/source line => BLOCK, never spooled
#   security-routing INV-F  a security signal => private lane, NOT the send outbox
#   rare-signature   INV-B  a bucket seen by < 10 distinct teams => suppressed
#
# stdlib python + bash only. Hermetic: every emit is pinned to a throwaway --home.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/bin/lib/issue_corpus.py"
CLI="$ROOT/bin/heimdall-issue-corpus"
PY="$(command -v python3 || command -v python)"

PASS=0
FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Count regular files under a dir (0 when absent).
nfiles() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }

echo "== issue-corpus emit falsifier belt =="

[ -f "$LIB" ] || { echo "issue_corpus.py missing: $LIB"; }

# ── consent-off (INV-D) ───────────────────────────────────────────────────────
echo "-- consent-off (INV-D) --"
H="$TMP/off"; mkdir -p "$H"
OUT="$(HEIMDALL_TELEMETRY=off "$PY" "$LIB" emit \
        --event '{"error_class":"lint"}' --home "$H" 2>/dev/null)"
if grep -q '"emitted": false' <<<"$OUT"; then
  ok "consent-off: emit returns emitted:false"
else
  bad "consent-off: emit did not return emitted:false (got: $OUT)"
fi
# zero bytes written ANYWHERE under the home (outbox + private lane + spool).
if [ "$(nfiles "$H")" = "0" ]; then
  ok "consent-off: zero files written under home (no cron/hook leak path)"
else
  bad "consent-off: files were written under home while OFF ($(nfiles "$H"))"
fi

# ── leaked-content (INV-A) ────────────────────────────────────────────────────
echo "-- leaked-content (INV-A) --"
H="$TMP/leak"; mkdir -p "$H"
OUT="$("$PY" "$LIB" emit \
        --event '{"error_class":"lint","message":"/etc/passwd:42 boom()"}' \
        --home "$H" 2>/dev/null)"
if grep -qi 'block' <<<"$OUT"; then
  ok "leaked-content: planted path/source line is BLOCKED"
else
  bad "leaked-content: planted content was not blocked (got: $OUT)"
fi
if grep -q '"emitted": true' <<<"$OUT"; then
  bad "leaked-content: a blocked emit still reported emitted:true"
else
  ok "leaked-content: blocked emit did not report emitted:true"
fi

# ── security-routing (INV-F) ──────────────────────────────────────────────────
echo "-- security-routing (INV-F) --"
H="$TMP/sec"; mkdir -p "$H"
OUT="$("$PY" "$LIB" emit \
        --event '{"error_class":"auth","message":"login failed"}' \
        --home "$H" 2>/dev/null)"
# the private lane got the record ...
LANE="$H/security-signals"
if [ "$(nfiles "$LANE")" -ge 1 ]; then
  ok "security-routing: signal written to the PRIVATE lane"
else
  bad "security-routing: private lane empty (got: $OUT)"
fi
# ... and the send outbox did NOT.
if [ "$(nfiles "$H/telemetry/issues/outbox")" = "0" ]; then
  ok "security-routing: send outbox is empty (never public)"
else
  bad "security-routing: a security signal reached the send outbox"
fi
if grep -q '"emitted": true' <<<"$OUT"; then
  bad "security-routing: a private signal reported emitted:true (would be sent)"
else
  ok "security-routing: private signal not reported as emitted (not sent)"
fi

# a benign signal, by contrast, DOES reach the outbox (proves routing is real,
# not a blanket refusal).
H2="$TMP/benign"; mkdir -p "$H2"
"$PY" "$LIB" emit --event '{"error_class":"lint","gate":"lint","phase":"verify"}' \
      --home "$H2" >/dev/null 2>&1
if [ "$(nfiles "$H2/telemetry/issues/outbox")" -ge 1 ]; then
  ok "security-routing: a benign signal DOES reach the outbox (routing discriminates)"
else
  bad "security-routing: a benign signal failed to spool (over-blocking)"
fi

# ── rare-signature k-anon (INV-B) ─────────────────────────────────────────────
echo "-- rare-signature k-anon (INV-B) --"
# A signature bucket seen by < 10 distinct teams MUST suppress; >= 10 MUST clear.
RARE="$("$PY" - "$LIB" <<'PYEOF'
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("issue_corpus", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
rare = [{"team_id_hash": "t%d" % i} for i in range(3)]      # 3 distinct teams
big  = [{"team_id_hash": "t%d" % i} for i in range(12)]     # 12 distinct teams
r = m.suppress_if_rare(rare)
b = m.suppress_if_rare(big)
print("RARE_SUPPRESSED", bool(r.get("suppressed")))
print("BIG_SUPPRESSED", bool(b.get("suppressed")))
print("KMIN", m.ISSUE_K_ANONYMITY_MIN)
PYEOF
)"
if grep -q 'RARE_SUPPRESSED True' <<<"$RARE"; then
  ok "rare-signature: a <10-team bucket is SUPPRESSED"
else
  bad "rare-signature: a rare bucket was NOT suppressed (got: $RARE)"
fi
if grep -q 'BIG_SUPPRESSED False' <<<"$RARE"; then
  ok "rare-signature: a >=10-team bucket is served (not over-suppressed)"
else
  bad "rare-signature: a well-supported bucket was suppressed (got: $RARE)"
fi
if grep -q 'KMIN 10' <<<"$RARE"; then
  ok "rare-signature: ISSUE_K_ANONYMITY_MIN == 10 (RJ decision 3)"
else
  bad "rare-signature: k threshold is not 10 (got: $RARE)"
fi

# ── CLI surface sanity ────────────────────────────────────────────────────────
echo "-- CLI surface --"
if [ -x "$CLI" ]; then
  ok "CLI bin/heimdall-issue-corpus is executable"
else
  bad "CLI bin/heimdall-issue-corpus missing or not executable"
fi
if "$PY" "$LIB" status --home "$TMP/st" >/dev/null 2>&1; then
  ok "status subcommand runs"
else
  bad "status subcommand failed"
fi
if "$PY" "$LIB" flush --dry-run --home "$TMP/st" >/dev/null 2>&1; then
  ok "flush --dry-run runs (and sends nothing — no transport in W1)"
else
  bad "flush --dry-run failed"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
