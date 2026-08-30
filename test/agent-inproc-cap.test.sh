#!/usr/bin/env bash
# agent-inproc-cap harness
#
# Covers the in-process agent concurrency cap (Task 3.1) added to
# bin/heimdall-precheck-agent: an independent, self-expiring lease directory
# that never touches ~/.heimdall/agent-pool.json (the shared ledger a prior,
# reverted attempt at this same task wedged -- pid-null entries never reap,
# see the header comment in the hook itself for the full incident).
#
# Falsifiable both ways: proves under-cap allows, at/over-cap denies, every
# fail-open path (missing jq, missing date, corrupt/occupied state dir,
# hung filesystem via perl-alarm timeout) individually, the anti-ghost
# self-heal property (stale leases don't block forever) contrasted against
# a still-valid case (same age, longer TTL, still denied -- so the heal is
# real TTL comparison, not a vacuous always-allow), and closes with a
# mutation RED-PROOF that the cap's own exit 2 is load-bearing.
#
# Hermetic: everything lives under a mktemp sandbox rooted at $TMPDIR. This
# suite NEVER reads or writes the operator's real ~/.heimdall/agent-pool.json
# or ~/.heimdall/inproc-agent-leases -- every invocation gets its own
# HOME/HEIMDALL_HOME pointed at a throwaway directory.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_HOOK="$REPO/bin/heimdall-precheck-agent"
REALPATH="$PATH"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-inproc-cap.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

payload() {
  local st="${1:-coder}"
  jq -cn --arg st "$st" '{tool_input: {subagent_type: $st, prompt: "hi"}}'
}

# fire HOME MAX TTL PATH_VALUE PAYLOAD_JSON -- sets globals RC, OUT, ERR
fire() {
  local home="$1" max="$2" ttl="$3" pathv="$4" pl="$5"
  OUT="$(mktemp "$SANDBOX/out.XXXXXX")"
  ERR="$(mktemp "$SANDBOX/err.XXXXXX")"
  local extra=()
  [ -n "$max" ] && extra+=("HEIMDALL_INPROC_AGENT_MAX=$max")
  [ -n "$ttl" ] && extra+=("HEIMDALL_INPROC_AGENT_TTL=$ttl")
  # Guard the expansion itself, not just the appends above: under set -u,
  # "${extra[@]}" on a still-empty array is an unbound-variable error in
  # some bash builds even though extra WAS declared -- only ${#extra[@]}
  # (a count) is safe to reference unconditionally. Two call shapes avoids
  # ever writing the bare expansion when nothing was appended.
  if [ "${#extra[@]}" -gt 0 ]; then
    printf '%s' "$pl" | env -i "HOME=$home" "HEIMDALL_HOME=$home/.heimdall" "PATH=$pathv" "${extra[@]}" bash "$REAL_HOOK" >"$OUT" 2>"$ERR"
  else
    printf '%s' "$pl" | env -i "HOME=$home" "HEIMDALL_HOME=$home/.heimdall" "PATH=$pathv" bash "$REAL_HOOK" >"$OUT" 2>"$ERR"
  fi
  RC=$?
}

make_fakebin() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t src
  for t in "$@"; do
    src="$(command -v "$t" 2>/dev/null)" || continue
    ln -sf "$src" "$dir/$t"
  done
}

echo "agent-inproc-cap harness"
echo "--------------------------------------------------------------------"

# -- structural checks -------------------------------------------------
bash -n "$REAL_HOOK" 2>/dev/null && ok "real hook parses (bash -n)" || bad "real hook fails bash -n"

grep -q '^# -- in-process agent concurrency cap' "$REAL_HOOK" \
  && ok "cap section header present" \
  || bad "cap section header missing"

CAP_SECTION="$(awk '/^# -- in-process agent concurrency cap/{f=1} /^# -- adjudication fallback fence/{f=0} f' "$REAL_HOOK")"
CAP_CODE_ONLY="$(printf '%s\n' "$CAP_SECTION" | grep -v '^[[:space:]]*#')"
# The independence property that actually matters is never touching the
# concrete shared ledger file -- NOT avoiding the substring "agent-pool"
# altogether, which the code's own deny message legitimately contains (in
# a string literal, to explain the independence to a human reader; see the
# at-cap message assertions below). Asserting the bare substring is absent
# would fail against that correct, intentional prose, so this checks the
# concrete file name instead.
if printf '%s\n' "$CAP_CODE_ONLY" | grep -q 'agent-pool\.json'; then
  bad "cap section CODE references agent-pool.json (should never touch the shared ledger file)"
else
  ok "cap section CODE never references the concrete agent-pool.json shared ledger file"
fi

# -- fakebins for fail-open proofs --------------------------------------
FAKEBIN_NOJQ="$SANDBOX/bin-nojq"
make_fakebin "$FAKEBIN_NOJQ" bash date mkdir cat rm perl mktemp grep sed
FAKEBIN_NODATE="$SANDBOX/bin-nodate"
make_fakebin "$FAKEBIN_NODATE" bash jq mkdir cat rm perl mktemp grep sed
FAKEBIN_SLOW="$SANDBOX/bin-slowdate"
make_fakebin "$FAKEBIN_SLOW" bash jq mkdir cat rm perl mktemp grep sed
cat > "$FAKEBIN_SLOW/date" <<'EOF'
#!/bin/sh
sleep 10
echo 9999999999
EOF
chmod +x "$FAKEBIN_SLOW/date"

# -- default (env unset) => disabled, zero behavior change --------------
home="$SANDBOX/home-default"
mkdir -p "$home/.heimdall/inproc-agent-leases"
now="$(date +%s)"
for i in 1 2 3 4 5; do printf '%s' "$now" > "$home/.heimdall/inproc-agent-leases/lease-pre-$i"; done
fire "$home" "" "" "$REALPATH" "$(payload coder)"
[ "$RC" -eq 0 ] \
  && ok "default (HEIMDALL_INPROC_AGENT_MAX unset) -> cap disabled -> allowed despite 5 pre-existing leases" \
  || bad "default -> expected allow(0), got $RC"

# -- garbage MAX value -> treated as disabled ----------------------------
home="$SANDBOX/home-garbagemax"
mkdir -p "$home/.heimdall/inproc-agent-leases"
now="$(date +%s)"
printf '%s' "$now" > "$home/.heimdall/inproc-agent-leases/lease-a"
printf '%s' "$now" > "$home/.heimdall/inproc-agent-leases/lease-b"
fire "$home" "notanumber" 900 "$REALPATH" "$(payload coder)"
[ "$RC" -eq 0 ] \
  && ok "garbage HEIMDALL_INPROC_AGENT_MAX (non-numeric) -> treated as disabled -> allowed" \
  || bad "garbage MAX -> expected allow(0), got $RC"

# -- under cap: allowed, and a real lease gets staked --------------------
home="$SANDBOX/home-undercap"
fire "$home" 5 900 "$REALPATH" "$(payload coder)"
leases_dir="$home/.heimdall/inproc-agent-leases"
count_after=$(ls -1 "$leases_dir" 2>/dev/null | wc -l | tr -d ' ')
[ "$RC" -eq 0 ] && [ "$count_after" -eq 1 ] \
  && ok "under cap (0/5) -> allowed, exactly one real lease staked (not vacuous)" \
  || bad "under cap -> rc=$RC leases=$count_after (expected rc=0, leases=1)"

# -- at cap: denied, with a real, specific message -----------------------
home="$SANDBOX/home-atcap"
mkdir -p "$home/.heimdall/inproc-agent-leases"
now="$(date +%s)"
printf '%s' "$now" > "$home/.heimdall/inproc-agent-leases/lease-a"
printf '%s' "$now" > "$home/.heimdall/inproc-agent-leases/lease-b"
fire "$home" 2 900 "$REALPATH" "$(payload coder)"
[ "$RC" -eq 2 ] && ok "at cap (2/2) -> denied (exit 2)" || bad "at cap -> expected exit 2, got $RC"
grep -q '"error"' "$OUT" && ok "deny emits a JSON object with .error on stdout" || bad "deny stdout not JSON-shaped: $(cat "$OUT")"
jq -e '.error' <"$OUT" >/dev/null 2>&1 && ok "deny stdout parses cleanly as JSON" || bad "deny stdout failed jq -e '.error': $(cat "$OUT")"
grep -q 'in-process agent concurrency cap' "$ERR" && ok "stderr names the cap explicitly" || bad "stderr missing cap name: $(cat "$ERR")"
grep -q '2/2' "$ERR" && ok "stderr reports the exact count/max (2/2)" || bad "stderr missing count/max: $(cat "$ERR")"
if grep -q 'agent-pool' "$ERR"; then
  bad "deny message wrongly mentions agent-pool"
else
  ok "deny message never mentions agent-pool (independence visible to the caller too)"
fi
count_after_deny=$(ls -1 "$home/.heimdall/inproc-agent-leases" 2>/dev/null | wc -l | tr -d ' ')
[ "$count_after_deny" -eq 2 ] \
  && ok "at-cap: a denied spawn does not stake a lease (still exactly 2, not 3)" \
  || bad "at-cap: lease count changed after denial (expected 2, got $count_after_deny)"

# -- anti-ghost self-heal: stale leases get pruned, spawn allowed --------
home="$SANDBOX/home-antighost"
mkdir -p "$home/.heimdall/inproc-agent-leases"
old=$(( $(date +%s) - 100 ))
printf '%s' "$old" > "$home/.heimdall/inproc-agent-leases/lease-stale-a"
printf '%s' "$old" > "$home/.heimdall/inproc-agent-leases/lease-stale-b"
fire "$home" 2 5 "$REALPATH" "$(payload coder)"
[ "$RC" -eq 0 ] \
  && ok "anti-ghost: 2 stale leases (age 100s) vs TTL=5 -> pruned first, spawn allowed" \
  || bad "anti-ghost -> expected allow(0), got $RC"
remaining=$(ls -1 "$home/.heimdall/inproc-agent-leases" 2>/dev/null | wc -l | tr -d ' ')
[ "$remaining" -eq 1 ] \
  && ok "anti-ghost: stale leases actually removed from disk (1 fresh lease remains, not 3)" \
  || bad "anti-ghost: expected exactly 1 remaining lease, found $remaining"

# -- contrast: same age, longer TTL -> NOT stale -> still denied ---------
# Proves the heal above is a real TTL comparison, not an unconditional prune.
home="$SANDBOX/home-notstale"
mkdir -p "$home/.heimdall/inproc-agent-leases"
old=$(( $(date +%s) - 100 ))
printf '%s' "$old" > "$home/.heimdall/inproc-agent-leases/lease-a"
printf '%s' "$old" > "$home/.heimdall/inproc-agent-leases/lease-b"
fire "$home" 2 1000 "$REALPATH" "$(payload coder)"
[ "$RC" -eq 2 ] \
  && ok "contrast: same-age(100s) leases under TTL=1000 (not stale) -> still denied" \
  || bad "contrast -> expected deny(2), got $RC (would mean staleness is not really checked)"

# -- fail-open: missing jq ------------------------------------------------
home="$SANDBOX/home-nojq"
mkdir -p "$home/.heimdall/inproc-agent-leases"
now="$(date +%s)"
printf '%s' "$now" > "$home/.heimdall/inproc-agent-leases/lease-a"
printf '%s' "$now" > "$home/.heimdall/inproc-agent-leases/lease-b"
fire "$home" 2 900 "$FAKEBIN_NOJQ" "$(payload coder)"
[ "$RC" -eq 0 ] \
  && ok "fail-open: jq missing -> allowed even though cap dir is saturated (2/2)" \
  || bad "fail-open jq-missing -> expected allow(0), got $RC"

# -- fail-open: missing date ----------------------------------------------
home="$SANDBOX/home-nodate"
mkdir -p "$home/.heimdall/inproc-agent-leases"
now="$(date +%s)"
printf '%s' "$now" > "$home/.heimdall/inproc-agent-leases/lease-a"
printf '%s' "$now" > "$home/.heimdall/inproc-agent-leases/lease-b"
fire "$home" 2 900 "$FAKEBIN_NODATE" "$(payload coder)"
[ "$RC" -eq 0 ] \
  && ok "fail-open: date missing -> allowed even though cap dir is saturated (2/2)" \
  || bad "fail-open date-missing -> expected allow(0), got $RC"

# -- fail-open: corrupt/unreadable state (path occupied by a file) ------
home="$SANDBOX/home-corrupt"
mkdir -p "$home/.heimdall"
: > "$home/.heimdall/inproc-agent-leases"
fire "$home" 1 900 "$REALPATH" "$(payload coder)"
[ "$RC" -eq 0 ] \
  && ok "fail-open: lease path occupied by a non-directory (mkdir -p fails) -> allowed" \
  || bad "fail-open corrupt-state -> expected allow(0), got $RC"

# -- fail-open: hung filesystem / slow date, perl-alarm bounded ----------
home="$SANDBOX/home-timeout"
mkdir -p "$home/.heimdall/inproc-agent-leases"
now="$(date +%s)"
printf '%s' "$now" > "$home/.heimdall/inproc-agent-leases/lease-a"
printf '%s' "$now" > "$home/.heimdall/inproc-agent-leases/lease-b"
start_ts=$(date +%s)
fire "$home" 2 900 "$FAKEBIN_SLOW" "$(payload coder)"
end_ts=$(date +%s)
elapsed=$(( end_ts - start_ts ))
[ "$RC" -eq 0 ] \
  && ok "fail-open: hung date (perl-alarm bounded) -> allowed" \
  || bad "fail-open timeout -> expected allow(0), got $RC"
[ "$elapsed" -lt 8 ] \
  && ok "fail-open: alarm bounded wall-clock to ${elapsed}s (fake date sleeps 10s -- an unbounded hang would take >=10s)" \
  || bad "fail-open timeout -> took ${elapsed}s, alarm did not bound it"

# -- RED-PROOF: neutralize the cap's exit 2, confirm it was load-bearing -
MUTANT="$SANDBOX/mutant-noop-cap"
awk '
  /^# -- in-process agent concurrency cap/ { incap=1 }
  /^# -- adjudication fallback fence/       { incap=0 }
  incap && /^[[:space:]]*exit 2[[:space:]]*$/ { print "      : # MUTANT-noop-cap (test red-proof)"; next }
  { print }
' "$REAL_HOOK" > "$MUTANT"
chmod +x "$MUTANT"
grep -q 'MUTANT-noop-cap' "$MUTANT" \
  && ok "mutant: cap section's exit 2 actually neutralized (mutation applied, not a no-op edit)" \
  || bad "mutant construction failed -- red-proof below would be meaningless"

home="$SANDBOX/home-redproof"
mkdir -p "$home/.heimdall/inproc-agent-leases"
now="$(date +%s)"
printf '%s' "$now" > "$home/.heimdall/inproc-agent-leases/lease-a"
printf '%s' "$now" > "$home/.heimdall/inproc-agent-leases/lease-b"
MOUT="$(mktemp "$SANDBOX/out.XXXXXX")"
MERR="$(mktemp "$SANDBOX/err.XXXXXX")"
printf '%s' "$(payload coder)" | env -i "HOME=$home" "HEIMDALL_HOME=$home/.heimdall" "PATH=$REALPATH" "HEIMDALL_INPROC_AGENT_MAX=2" "HEIMDALL_INPROC_AGENT_TTL=900" bash "$MUTANT" >"$MOUT" 2>"$MERR"
MRC=$?
[ "$MRC" -eq 0 ] \
  && ok "RED-PROOF: mutant with cap's exit 2 removed WRONGLY allows a saturated(2/2) spawn -- proves the real exit 2 is load-bearing" \
  || bad "RED-PROOF did not go red: mutant still exited $MRC (expected 0) -- the deny may not be caused by the code we think it is"

echo "--------------------------------------------------------------------"
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
