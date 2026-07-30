#!/usr/bin/env bash
# heimdall-overload-heal.test.sh — falsifiable coverage for the claude 529/overload
# self-heal wrapper (bin/lib/hmd-claude-retry.sh).
#
# HERMETIC: a stub `claude` on PATH, driven by an env-selected mode + a file counter,
# stands in for the real CLI. Backoff env is tiny (BASE=0) so the suite runs instantly.
#
# It is genuinely falsifiable — it FAILS if the wrapper:
#   A: does NOT retry a transient overload (or returns the error text as output);
#   B: does NOT give up cleanly (distinct exit + diagnostic) when overload never clears;
#   C: retries a REAL (non-overload) error instead of failing fast;
#   D: adds an extra call / latency to the happy path.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/bin/lib/hmd-claude-retry.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── stub claude ───────────────────────────────────────────────────────────────
# honors -p/--model (consumes them), increments a counter each call, and behaves per
# $STUB_MODE. stdout = the "answer"; stderr = progress/error banners.
STUB="$WORK/bin/claude"
mkdir -p "$WORK/bin"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# fake claude: honor -p/--model, count invocations, behave per $STUB_MODE.
prompt=""; model=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--print) prompt="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --output-format|--permission-mode|--allowedTools) shift 2 ;;
    *) shift ;;
  esac
done
n=$(cat "$STUB_COUNTER" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_COUNTER"
case "$STUB_MODE" in
  success)        echo "STUB-OK-OUTPUT"; exit 0 ;;
  real_error)     echo "Error: invalid prompt — malformed request" >&2; exit 1 ;;
  always_overload) echo "API Error: 529 Overloaded · Retrying ${n}/10" >&2; exit 1 ;;
  recover_after)
    if [ "$n" -le "${STUB_FAIL_TIMES:-2}" ]; then
      echo "Overloaded (overloaded_error, 529) · Retrying in 5s" >&2; exit 1
    fi
    echo "STUB-RECOVERED-OUTPUT"; exit 0 ;;
  *) echo "stub: unknown STUB_MODE=$STUB_MODE" >&2; exit 99 ;;
esac
STUBEOF
chmod +x "$STUB"

# fast, hermetic env
export HMD_CLAUDE_BIN="$STUB"
export HEIMDALL_HOME="$WORK/hmdhome"
export HMD_OVERLOAD_BASE_SECS=0          # no real waiting
export HMD_OVERLOAD_CAP_SECS=0

# shellcheck source=/dev/null
. "$LIB"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [expr: $2]"; fi; }

reset_case() {
  export STUB_MODE="$1"
  export STUB_COUNTER="$WORK/counter"
  : > "$STUB_COUNTER"
  export HMD_OVERLOAD_LOG="$WORK/heal.log"
  : > "$HMD_OVERLOAD_LOG"
}
count() { cat "$STUB_COUNTER" 2>/dev/null || echo 0; }
backoffs() { local n; n=$(grep -c 'will-retry' "$HMD_OVERLOAD_LOG" 2>/dev/null); echo "${n:-0}"; }

# ── Case A: overloaded N times then succeeds -> retries, returns SUCCESS output ──
echo "Case A — transient overload (recovers after 2 failures):"
reset_case recover_after
export STUB_FAIL_TIMES=2
export HMD_OVERLOAD_MAX_ATTEMPTS=6
rcA=0; outA="$(hmd_claude_retry -p "do work" --model m --output-format text 2>"$WORK/a.err")" || rcA=$?
check "A exit 0 (ultimately succeeded)"                 "[ '$rcA' -eq 0 ]"
check "A returns the SUCCESS output"                    "printf '%s' \"\$outA\" | grep -q 'STUB-RECOVERED-OUTPUT'"
check "A did NOT return overload error text as output"  "! printf '%s' \"\$outA\" | grep -qiE '529|overloaded|retrying'"
check "A actually retried (3 calls = 2 fail + 1 ok)"    "[ '$(count)' -eq 3 ]"
check "A logged 2 backoffs"                             "[ '$(backoffs)' -eq 2 ]"
unset STUB_FAIL_TIMES

# ── Case B: always overloaded -> gives up cleanly (distinct exit + diagnostic) ──
echo "Case B — persistent overload (never clears):"
reset_case always_overload
export HMD_OVERLOAD_MAX_ATTEMPTS=4
rcB=0; outB="$(hmd_claude_retry -p "do work" --model m 2>"$WORK/b.err")" || rcB=$?
errB="$(cat "$WORK/b.err")"
check "B exit is the distinct give-up code (75)"        "[ '$rcB' -eq 75 ]"
check "B did NOT fake success output"                   "! printf '%s' \"\$outB\" | grep -q 'STUB-OK\\|RECOVERED'"
check "B emitted 'gave up after N attempts' diagnostic" "printf '%s' \"\$errB\" | grep -qi 'gave up after 4 attempts'"
check "B tried exactly max=4 times"                     "[ '$(count)' -eq 4 ]"
check "B logged GAVE UP"                                "grep -qi 'GAVE UP' '$HMD_OVERLOAD_LOG'"
check "B logged 3 backoffs (between the 4 tries)"       "[ '$(backoffs)' -eq 3 ]"

# ── Case C: real (non-overload) error -> fail fast, NO retry ────────────────────
echo "Case C — real error (must not retry):"
reset_case real_error
export HMD_OVERLOAD_MAX_ATTEMPTS=6
rcC=0; outC="$(hmd_claude_retry -p "do work" --model m 2>"$WORK/c.err")" || rcC=$?
errC="$(cat "$WORK/c.err")"
check "C propagates claude's real exit (1)"             "[ '$rcC' -eq 1 ]"
check "C called claude exactly once (fail fast)"        "[ '$(count)' -eq 1 ]"
check "C logged ZERO backoffs (no retry)"               "[ '$(backoffs)' -eq 0 ]"
check "C surfaced the real error text on stderr"        "printf '%s' \"\$errC\" | grep -qi 'invalid prompt'"

# ── Case D: success first try -> single call, no backoff, exact output ──────────
echo "Case D — happy path (no regression, no added latency):"
reset_case success
export HMD_OVERLOAD_MAX_ATTEMPTS=6
rcD=0; outD="$(hmd_claude_retry -p "do work" --model m 2>"$WORK/d.err")" || rcD=$?
check "D exit 0"                                        "[ '$rcD' -eq 0 ]"
check "D exact output (no banners merged in)"           "[ \"\$outD\" = 'STUB-OK-OUTPUT' ]"
check "D single call (no wasted retries)"               "[ '$(count)' -eq 1 ]"
check "D zero backoffs (no added latency)"              "[ '$(backoffs)' -eq 0 ]"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
