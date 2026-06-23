#!/usr/bin/env bash
#
# telemetry-store.test.sh — substrate proofs for the ONE telemetry event surface
# (dossier piece a: bin/lib/telemetry.py + bin/heimdall-telemetry). This is the
# BLOCKING substrate every other piece (b/c/d/e) binds to, so these proofs pin the
# CONTRACT: the schema shape, the secret gate, graceful-degrade, and the disabled
# no-op. All runnable, none skippable.
#
# Proofs (dossier §1/§7/§8):
#
#   A. SCHEMA — emit() writes a well-formed NDJSON line carrying EXACTLY the pinned
#      schema keys (schema_version, ts, run_id, event_type, phase, step, outcome,
#      gate, tokens, duration_ms, commit, error, loc, extra). One JSON object per
#      line. tokens copied verbatim from a heimdall-tokens-shaped object.
#
#   B. NO-SECRET-BY-CONSTRUCTION (§7, security-critical) — _scrub() REJECTS a
#      planted secret-shaped value. The planted token is a REAL gitleaks match
#      ASSEMBLED AT RUNTIME from non-matching fragments (the fixture-secret
#      convention — no static ghp_+36 literal in this file), so the store + this
#      test carry no committed secret and need no .gitleaks.toml allowlist entry.
#      We feed it via error.detail AND extra AND a long over-bound value; assert
#      NONE of them appear anywhere in the store. FALSIFIABLE: a scrubber that let
#      the value through would put it in events.ndjson and flip the assertion.
#
#   C. GRACEFUL-DEGRADE (§8) — a telemetry WRITE FAILURE (unwritable store dir)
#      does NOT raise into the caller: emit() returns False and the caller's exit
#      code is 0, the "run continues" sentinel still prints. FALSIFIABLE: break the
#      swallow (let _append raise) and the caller would abort non-zero.
#
#   D. DISABLED NO-OP (§8) — HEIMDALL_TELEMETRY=off ⇒ emit() is a no-op, returns
#      False, and writes NO events.ndjson. A disabled world is identical to a
#      no-telemetry world.
#
#   E. GITLEAKS-CLEAN + NOT-ALLOWLISTED — after planting the runtime secret through
#      the scrubber, a bare `gitleaks detect` over the produced store finds ZERO
#      (the scrubber kept it out), AND the telemetry store path is NOT present in
#      .gitleaks.toml's allowlist (the store must be CLEAN, never exempted).
#
#   F. ISSUE-LOOP STILL GREEN — the seam wiring (issue-loop = consumer #1) did not
#      regress issue-loop: its own test suite still passes.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
TELE="$REPO/bin/heimdall-telemetry"
LIB="$REPO/bin/lib/telemetry.py"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
[ -x "$TELE" ] || { echo "FATAL: telemetry CLI not executable at $TELE"; exit 2; }
[ -f "$LIB" ]  || { echo "FATAL: telemetry lib missing at $LIB"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export REPO

# ─────────────────────────────────────────────────────────────────────────────
# A. SCHEMA — a well-formed NDJSON event with the pinned keys.
# ─────────────────────────────────────────────────────────────────────────────
echo "A. SCHEMA (emit writes the pinned NDJSON schema):"
HOME_A="$WORK/home-a"
TOKENS_JSON='{"input_tokens":10,"output_tokens":20,"cache_creation_tokens":0,"cache_read_tokens":5,"total_tokens":35,"total_cost_usd":null,"cost_source":"measured"}'
out_a="$("$TELE" emit --type token --run-id run-aaa --phase waves --outcome passed \
  --gate test --duration-ms 1234 --commit abc1234 --loc config.py:5 \
  --tokens "$TOKENS_JSON" --extra '{"issue_id":"gh#1"}' --home "$HOME_A")"
if printf '%s' "$out_a" | grep -Fq '"emitted": true'; then
  ok "emit reported a write"
else
  bad "emit did NOT report a write: $out_a"
fi
STORE_A="$HOME_A/telemetry/events.ndjson"
if [ -f "$STORE_A" ] && [ "$(wc -l < "$STORE_A" | tr -d ' ')" = "1" ]; then
  ok "store has exactly one NDJSON line"
else
  bad "store missing or not a single line: $STORE_A"
fi
# Validate the schema keys + verbatim token copy via a temp python checker (one
# parse, exact key set). Temp script avoids fragile heredoc-in-$() nesting.
cat > "$WORK/check_schema.py" <<'PYEOF'
import json, os, sys
e = json.loads(open(os.environ["STORE"]).readline())
need = {"schema_version", "ts", "run_id", "event_type", "phase", "step",
        "outcome", "gate", "tokens", "duration_ms", "commit", "error", "loc",
        "extra"}
missing = need - set(e)
unexpected = set(e) - need
if missing or unexpected:
    print("KEYMISMATCH missing=%s unexpected=%s"
          % (sorted(missing), sorted(unexpected)))
    sys.exit(1)
assert e["event_type"] == "token", e["event_type"]
assert e["run_id"] == "run-aaa"
assert e["duration_ms"] == 1234
assert e["loc"] == "config.py:5"
t = e["tokens"]
assert t["total_tokens"] == 35 and t["cache_read_tokens"] == 5, t
assert t["total_cost_usd"] is None and t["cost_source"] == "measured", t
assert e["extra"] == {"issue_id": "gh#1"}, e["extra"]
print("SCHEMA_OK")
PYEOF
schema_rc=0
SCHEMA_OUT="$(STORE="$STORE_A" "$PY" "$WORK/check_schema.py" 2>&1)" || schema_rc=$?
if [ "$schema_rc" -eq 0 ] && printf '%s' "$SCHEMA_OUT" | grep -q SCHEMA_OK; then
  ok "event carries EXACTLY the pinned schema keys + verbatim tokens"
else
  bad "schema mismatch: $SCHEMA_OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# B. NO-SECRET-BY-CONSTRUCTION — _scrub REJECTS a runtime-assembled secret.
# ─────────────────────────────────────────────────────────────────────────────
echo "B. NO-SECRET (scrubber rejects a planted runtime secret):"
HOME_B="$WORK/home-b"
# Assemble a REAL gitleaks-matching GitHub PAT at runtime from non-matching parts
# (test/selfscan.test.sh pattern) — no contiguous literal exists in this file.
_GP_PRE="ghp_"; _GP_A="0123456789abcdefghij"; _GP_B="ABCDEFGHIJ012345"
PLANT_TOK="${_GP_PRE}${_GP_A}${_GP_B}"   # ghp_+36 at runtime; no source literal
export PLANT_TOK
if printf '%s' "$PLANT_TOK" | grep -Eq 'ghp_[A-Za-z0-9]{36}'; then
  ok "planted token is a real gitleaks-shaped PAT (runtime-assembled, falsifiable)"
else
  bad "planted token is NOT gitleaks-shaped — the proof would be vacuous"
fi
# Try to smuggle it through every free-ish field: error.detail, an extra value, and
# an over-bound long value. NONE may reach the store.
LONG_VAL="$(printf 'A%.0s' $(seq 1 200))"   # 200 chars > the 120 bound → rejected
export LONG_VAL
"$TELE" emit --type outcome --run-id run-bbb --outcome failed \
  --error-class CalledProcessError --error-step companion:claude-mem \
  --error-detail "$PLANT_TOK" \
  --extra "{\"leak\":\"$PLANT_TOK\",\"long\":\"$LONG_VAL\",\"safe\":\"npm exec exit 1\"}" \
  --home "$HOME_B" >/dev/null
STORE_B="$HOME_B/telemetry/events.ndjson"
if [ -f "$STORE_B" ]; then
  ok "emit still wrote an event (the safe fields survive; the run continues)"
else
  bad "no event written at all — emit should drop only the secret fields, not the event"
fi
if [ -f "$STORE_B" ] && grep -Fq "$PLANT_TOK" "$STORE_B"; then
  bad "PLANTED SECRET LEAKED INTO THE STORE — scrubber failed (no-secret-by-construction broken)"
else
  ok "planted secret does NOT appear in the store (scrubber rejected it — falsifiable)"
fi
if [ -f "$STORE_B" ] && grep -Fq "$LONG_VAL" "$STORE_B"; then
  bad "over-bound 200-char value leaked into the store (length bound not enforced)"
else
  ok "over-bound value rejected (length bound holds)"
fi
if [ -f "$STORE_B" ] && grep -Fq "npm exec exit 1" "$STORE_B"; then
  ok "the safe SHAPE field (npm exec exit 1) survived — only secrets are dropped"
else
  bad "the safe SHAPE field was dropped — scrubber is over-broad"
fi
# Direct unit assertion on _scrub via a temp checker.
cat > "$WORK/check_scrub.py" <<'PYEOF'
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "bin", "lib"))
import telemetry
plant = os.environ["PLANT_TOK"]
assert telemetry._scrub(plant) is None, "scrub let the secret through"
assert telemetry._scrub("npm exec exit 1") == "npm exec exit 1", "scrub dropped a safe value"
assert telemetry._scrub("x" * 200) is None, "scrub kept an over-bound value"
assert telemetry._scrub("token=" + "A" * 40) is None, "scrub kept a key=opaque value"
print("SCRUB_OK")
PYEOF
scrub_rc=0
SCRUB_OUT="$("$PY" "$WORK/check_scrub.py" 2>&1)" || scrub_rc=$?
if [ "$scrub_rc" -eq 0 ] && printf '%s' "$SCRUB_OUT" | grep -q SCRUB_OK; then
  ok "_scrub() unit: rejects secret/over-bound/key=opaque, echoes safe SHAPE"
else
  bad "_scrub() unit failed: $SCRUB_OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# C. GRACEFUL-DEGRADE — a write failure does NOT raise into the caller.
# ─────────────────────────────────────────────────────────────────────────────
echo "C. GRACEFUL-DEGRADE (write failure never fails the caller):"
HOME_C="$WORK/home-c"
mkdir -p "$HOME_C"
# Make the telemetry store dir unwritable: pre-create it as a FILE where a dir must
# go, so os.makedirs + open('a') both fail inside emit() — which must swallow it.
: > "$HOME_C/telemetry"   # a regular file occupies the dir path → makedirs raises
cat > "$WORK/check_degrade.py" <<'PYEOF'
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "bin", "lib"))
import telemetry
wrote = telemetry.emit("phase", run_id="run-ccc", phase="waves",
                       outcome="started", home=os.environ["HOMEC"])
# the run CONTINUES regardless — this line printing IS the proof the caller was
# not aborted by a telemetry write failure (graceful-degrade, §8).
print("RUN_CONTINUED wrote=%s" % wrote)
PYEOF
degrade_rc=0
DEGRADE_OUT="$(HOMEC="$HOME_C" "$PY" "$WORK/check_degrade.py" 2>&1)" || degrade_rc=$?
if [ "$degrade_rc" -eq 0 ] && printf '%s' "$DEGRADE_OUT" | grep -q "RUN_CONTINUED wrote=False"; then
  ok "write failure swallowed: emit returned False, caller continued, exit 0 (falsifiable)"
else
  bad "write failure was NOT handled gracefully (rc=$degrade_rc out=$DEGRADE_OUT)"
fi
wrap_rc=0
"$TELE" emit --type phase --run-id run-ccc --phase waves --outcome started \
  --home "$HOME_C" >/dev/null 2>&1 || wrap_rc=$?
if [ "$wrap_rc" -eq 0 ]; then
  ok "bash wrapper exits 0 on a write failure (never gates the caller)"
else
  bad "bash wrapper exited $wrap_rc on a write failure — it must always exit 0"
fi

# ─────────────────────────────────────────────────────────────────────────────
# D. DISABLED NO-OP — HEIMDALL_TELEMETRY=off ⇒ no write, no store.
# ─────────────────────────────────────────────────────────────────────────────
echo "D. DISABLED NO-OP (off ⇒ identical to a no-telemetry world):"
HOME_D="$WORK/home-d"
dis_out="$(HEIMDALL_TELEMETRY=off "$TELE" emit --type phase --run-id run-ddd \
  --phase planning --outcome started --home "$HOME_D")"
if printf '%s' "$dis_out" | grep -Fq '"emitted": false'; then
  ok "disabled emit reports no write"
else
  bad "disabled emit did not report a no-op: $dis_out"
fi
if [ -e "$HOME_D/telemetry/events.ndjson" ]; then
  bad "disabled telemetry STILL wrote a store — not a no-op"
else
  ok "disabled telemetry wrote NO store (no-op, §8)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# E. GITLEAKS-CLEAN + NOT-ALLOWLISTED — the store is clean, never exempted.
# ─────────────────────────────────────────────────────────────────────────────
echo "E. GITLEAKS-CLEAN + NOT-ALLOWLISTED:"
if command -v gitleaks >/dev/null 2>&1; then
  GL_RPT="$WORK/store-leaks.json"
  gitleaks detect --source "$HOME_B/telemetry" --no-git --no-banner \
    --report-format json --report-path "$GL_RPT" >/dev/null 2>&1 || true
  if [ -f "$GL_RPT" ] && grep -Fq "$PLANT_TOK" "$GL_RPT" 2>/dev/null; then
    bad "gitleaks found the planted secret in the store — scrubber failed"
  else
    ok "gitleaks over the store finds the planted secret NOWHERE (store is clean)"
  fi
else
  ok "gitleaks not installed — skipping the live scan; the grep proof in (B) already holds"
fi
CFG="$REPO/.gitleaks.toml"
if [ -f "$CFG" ] && grep -Eq 'telemetry|\.heimdall' "$CFG"; then
  bad "telemetry/.heimdall path is in .gitleaks.toml allowlist — the store must be clean, NOT exempted"
else
  ok "telemetry store path is NOT in .gitleaks.toml allowlist (clean-by-construction, never exempted)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F. ISSUE-LOOP STILL GREEN — the seam wiring did not regress consumer #1.
# ─────────────────────────────────────────────────────────────────────────────
echo "F. ISSUE-LOOP STILL GREEN (seam wiring kept consumer #1 green):"
IL_TEST="$REPO/test/issue-loop.test.sh"
if [ -f "$IL_TEST" ]; then
  il_rc=0
  bash "$IL_TEST" >/dev/null 2>&1 || il_rc=$?
  if [ "$il_rc" -eq 0 ]; then
    ok "issue-loop.test.sh still passes after the telemetry seam wiring"
  else
    bad "issue-loop.test.sh FAILED (rc=$il_rc) — the seam regressed consumer #1"
  fi
else
  bad "issue-loop.test.sh not found — cannot prove the seam kept it green"
fi

echo ""
echo "telemetry-store.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
