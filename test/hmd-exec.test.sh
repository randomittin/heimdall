#!/usr/bin/env bash
# hmd-exec.test.sh — falsifiable coverage for bin/hmd-exec, the single dispatcher for
# "run a headless coding task" (Wave 1 of the harness-independence design:
# docs/analysis/2026-08-25-harness-independence-design.md, Stage 0/1).
#
# HERMETIC: a stub `claude` on PATH (same design as test/heimdall-overload-heal.test.sh)
# stands in for the real CLI. Backoff env is tiny (BASE=0/CAP=0) so the suite is instant.
#
# It is genuinely falsifiable — it FAILS if hmd-exec:
#   A: does NOT dispatch the default (claude-code) backend with byte-identical argv to a
#      direct hmd_claude_retry call (the whole point of Wave 1 — nothing may change);
#   B: accepts an unknown --backend value instead of rejecting it loudly;
#   C: does NOT retry a transient overload THROUGH the dispatcher (i.e. loses the retry
#      loop somewhere between the CLI parse and the library call — this is exactly the
#      class of bug this suite caught during development: calling hmd_claude_retry BARE
#      under `set -e` trips errexit on the first overloaded attempt and never retries);
#   D: does NOT give up loudly (distinct exit code) when overload never clears;
#   E: retries a REAL (non-overload) error instead of failing fast;
#   F: mis-implements the documented wave-2 `api` seam as a silent no-op instead of a
#      loud, explicit "not implemented" rejection;
#   G: silently accepts a missing subcommand or corrupts stdout with its own banners.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/bin/hmd-exec"
LIB="$ROOT/bin/lib/hmd-claude-retry.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── stub claude ───────────────────────────────────────────────────────────────
# honors -p/--model (consumes them), records its full argv, increments a counter each
# call, and behaves per $STUB_MODE. stdout = the "answer"; stderr = progress/error banners.
STUB="$WORK/bin/claude"
mkdir -p "$WORK/bin"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
[ -n "${ARGV_RECORD:-}" ] && printf '%s\n' "$@" >> "$ARGV_RECORD"
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
export HMD_OVERLOAD_BASE_SECS=0          # no real waiting
export HMD_OVERLOAD_CAP_SECS=0

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [expr: $2]"; fi; }

reset_case() {
  export STUB_MODE="$1"
  export STUB_COUNTER="$WORK/counter"
  : > "$STUB_COUNTER"
  export ARGV_RECORD="$WORK/argv.txt"
  : > "$ARGV_RECORD"
  export HEIMDALL_HOME="$WORK/hmdhome-$RANDOM"
  export HMD_OVERLOAD_LOG="$WORK/heal.log"
  : > "$HMD_OVERLOAD_LOG"
}
count() { local n; n=$(cat "$STUB_COUNTER" 2>/dev/null); echo "${n:-0}"; }
backoffs() { local n; n=$(grep -c 'will-retry' "$HMD_OVERLOAD_LOG" 2>/dev/null); echo "${n:-0}"; }

# ── Case A: default backend -> byte-identical argv vs. calling the library directly ──
echo "Case A — default backend dispatches with byte-identical argv:"
reset_case success
export HMD_OVERLOAD_MAX_ATTEMPTS=6
export ARGV_RECORD="$WORK/argv-direct.txt"; : > "$ARGV_RECORD"
# shellcheck source=lib/hmd-claude-retry.sh
. "$LIB"
outDirect="$(hmd_claude_retry -p "identical task" --model sonnet --output-format text)"
rcDirect=$?

export ARGV_RECORD="$WORK/argv-exec.txt"; : > "$ARGV_RECORD"
: > "$STUB_COUNTER"
outExec="$("$EXEC" run -p "identical task" --model sonnet --output-format text 2>"$WORK/a.err")"
rcExec=$?
check "A both exit 0"                                   "[ '$rcDirect' -eq 0 ] && [ '$rcExec' -eq 0 ]"
check "A both return the same stdout"                   "[ \"\$outDirect\" = \"\$outExec\" ]"
check "A recorded argv is byte-identical"               "diff -q '$WORK/argv-direct.txt' '$WORK/argv-exec.txt' >/dev/null"
check "A announces the backend on STDERR, not stdout"   "grep -q 'backend=claude-code' '$WORK/a.err' && ! printf '%s' \"\$outExec\" | grep -q 'backend='"

# ── Case B: unknown backend is rejected, always, loudly ─────────────────────────
echo "Case B — unknown --backend is rejected:"
reset_case success
rcB=0; outB="$("$EXEC" --backend nonesuch run -p "x" 2>"$WORK/b.err")" || rcB=$?
check "B exits non-zero"                                "[ '$rcB' -ne 0 ]"
check "B never invoked claude at all"                   "[ '$(count)' -eq 0 ]"
check "B names the bad backend in the error"            "grep -q \"unknown backend 'nonesuch'\" '$WORK/b.err'"
check "B lists the available backends"                  "grep -q 'claude-code' '$WORK/b.err'"

# ── Case C: transient overload recovers -- retry survives the dispatcher boundary ──
echo "Case C — overload retry through the dispatcher (recovers after 2 failures):"
reset_case recover_after
export STUB_FAIL_TIMES=2
export HMD_OVERLOAD_MAX_ATTEMPTS=6
rcC=0; outC="$("$EXEC" run -p "flaky" --model m --output-format text 2>"$WORK/c.err")" || rcC=$?
check "C exit 0 (ultimately succeeded)"                 "[ '$rcC' -eq 0 ]"
check "C returns the SUCCESS output"                    "printf '%s' \"\$outC\" | grep -q 'STUB-RECOVERED-OUTPUT'"
check "C did NOT return overload error text as output"  "! printf '%s' \"\$outC\" | grep -qiE '529|overloaded|retrying'"
check "C actually retried (3 calls = 2 fail + 1 ok)"    "[ '$(count)' -eq 3 ]"
check "C logged 2 backoffs"                             "[ '$(backoffs)' -eq 2 ]"
unset STUB_FAIL_TIMES

# ── Case D: persistent overload -> loud, distinct give-up (never a silent no-op) ──
echo "Case D — give-up through the dispatcher (overload never clears):"
reset_case always_overload
export HMD_OVERLOAD_MAX_ATTEMPTS=4
rcD=0; outD="$("$EXEC" run -p "stuck" --model m 2>"$WORK/d.err")" || rcD=$?
check "D exit is the distinct give-up code (75)"        "[ '$rcD' -eq 75 ]"
check "D did NOT fake success output"                   "[ -z \"\$outD\" ]"
check "D tried exactly max=4 times"                     "[ '$(count)' -eq 4 ]"
check "D emitted a give-up diagnostic"                  "grep -qi 'gave up after 4 attempts' '$WORK/d.err'"

# ── Case E: real (non-overload) error -> fail fast, no retry, no masking ────────
echo "Case E — real error through the dispatcher (must not retry):"
reset_case real_error
export HMD_OVERLOAD_MAX_ATTEMPTS=6
rcE=0; outE="$("$EXEC" run -p "bad" --model m 2>"$WORK/e.err")" || rcE=$?
check "E propagates claude's real exit (1)"             "[ '$rcE' -eq 1 ]"
check "E called claude exactly once (fail fast)"        "[ '$(count)' -eq 1 ]"
check "E surfaced the real error text on stderr"        "grep -qi 'invalid prompt' '$WORK/e.err'"

# ── Case F: the wave-2 `api` seam is a documented rejection, not a silent no-op ──
echo "Case F — api backend is a loud, documented not-yet-implemented seam:"
reset_case success
rcF=0; outF="$("$EXEC" --backend api run -p "x" 2>"$WORK/f.err")" || rcF=$?
check "F exits non-zero (never a silent success)"       "[ '$rcF' -ne 0 ]"
check "F never invoked claude at all"                   "[ '$(count)' -eq 0 ]"
check "F produced NO stdout (no fake output)"           "[ -z \"\$outF\" ]"
check "F names it a wave-2 seam, not a generic error"   "grep -qi 'wave-2 seam' '$WORK/f.err'"
check "F points at the design doc"                      "grep -q 'harness-independence-design.md' '$WORK/f.err'"
check "F is listed by \`backends\` as a real, named option" "\"$EXEC\" backends | grep -q '^api '"
check "F is distinguished from an unknown-name rejection" "! grep -qi \"unknown backend\" '$WORK/f.err'"

# ── Case G: CLI-shape sanity (missing subcommand, --strict, help) ──────────────
echo "Case G — CLI shape (missing subcommand / --strict / help):"
rcG1=0; "$EXEC" >/dev/null 2>"$WORK/g1.err" || rcG1=$?
check "G1 no subcommand -> non-zero, explains itself"   "[ '$rcG1' -ne 0 ] && grep -qi 'missing subcommand' '$WORK/g1.err'"

rcG2=0; "$EXEC" --strict run >/dev/null 2>"$WORK/g2.err" || rcG2=$?
check "G2 --strict run with zero task args is rejected" "[ '$rcG2' -ne 0 ] && grep -qi 'zero task args' '$WORK/g2.err'"

reset_case success
rcG3=0; "$EXEC" run >/dev/null 2>"$WORK/g3.err" || rcG3=$?
check "G3 non-strict run w/ zero args does NOT hit hmd-exec's own usage error (falls through to the backend)" \
  "! grep -qi 'missing subcommand' '$WORK/g3.err'"

rcG4=0; "$EXEC" --help >/dev/null 2>"$WORK/g4.err" || rcG4=$?
check "G4 --help exits 0"                               "[ '$rcG4' -eq 0 ]"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
