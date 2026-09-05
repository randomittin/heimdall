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
#   F: the (now-implemented) wave-2 `api` backend fails to refuse loudly and
#      distinctly for either structural refusal case -- tool-use requested via
#      --allowedTools, or no gate ROUTE verdict -- or `backends` fails to list it
#      as implemented rather than as an unimplemented seam;
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
  real_429)       echo "error type rate_limit, HTTP 429" >&2; exit 1 ;;
  real_quota)     echo "Agent terminated early due to an API error: You've hit your session limit · resets 11:30pm (Asia/Calcutta)" >&2; exit 1 ;;
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
check "B exits exactly 2 (unconditional, never soft-exits)" "[ '$rcB' -eq 2 ]"
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

# ── Case F: the (now-implemented) wave-2 `api` backend refuses loudly, per reason ──
echo "Case F — api backend refuses loudly and distinctly, per structural reason:"
reset_case success
F_NOGATE_REPO="$WORK/no-gate-repo"
mkdir -p "$F_NOGATE_REPO"

# F1: --allowedTools non-empty -> the capability-refusal exit (3), before any gate
# or network call at all -- claude is never invoked, neither is the fallback gate.
rcF1=0
outF1="$(HMD_API_BACKEND_REPO="$F_NOGATE_REPO" "$EXEC" --backend api run -p "x" --allowedTools "Edit,Write,Read" 2>"$WORK/f1.err")" || rcF1=$?
check "F1 --allowedTools -> the capability-refusal exit (3)" "[ '$rcF1' -eq 3 ]"
check "F1 produced NO stdout (no fake output)"            "[ -z \"\$outF1\" ]"
check "F1 names tool-use as the reason"                   "grep -qi 'tool-use' '$WORK/f1.err'"
check "F1 never invoked claude at all"                    "[ '$(count)' -eq 0 ]"

# F2: no gate ROUTE verdict (no .heimdall/fallback.json -> fail-closed state=off
# default) -> the routing-refusal exit (4), distinct from F1's exit 3.
rcF2=0
outF2="$(HMD_API_BACKEND_REPO="$F_NOGATE_REPO" "$EXEC" --backend api run -p "x" 2>"$WORK/f2.err")" || rcF2=$?
check "F2 no ROUTE verdict -> the routing-refusal exit (4)" "[ '$rcF2' -eq 4 ]"
check "F2 produced NO stdout (no fake output)"            "[ -z \"\$outF2\" ]"
check "F2 names heimdall-fallback and ROUTE as the reason" "grep -q 'heimdall-fallback' '$WORK/f2.err' && grep -q 'ROUTE' '$WORK/f2.err'"
check "F2 never invoked claude at all"                    "[ '$(count)' -eq 0 ]"
check "F2's exit is distinct from F1's (4 != 3)"          "[ '$rcF2' -ne '$rcF1' ]"

# F3: `backends` lists api as implemented/completion-only, never as a seam.
outBackends="$("$EXEC" backends)"
check "F3 backends lists api as implemented"              "printf '%s\n' \"\$outBackends\" | grep -q '^api — implemented, completion-only'"
check "F3 backends does NOT call it a seam"               "! printf '%s\n' \"\$outBackends\" | grep -qi 'seam'"

# F4: neither structural refusal is misreported as an unknown-backend rejection.
check "F4 F1 is distinguished from an unknown-backend rejection" "! grep -qi 'unknown backend' '$WORK/f1.err'"
check "F4 F2 is distinguished from an unknown-backend rejection" "! grep -qi 'unknown backend' '$WORK/f2.err'"

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

# ── Case H: 429/quota-shaped failures mark the reactive exhaustion gate
# (bin/heimdall-429-mark, fed by bin/lib/hmd-claude-retry.sh's
# _hmd_is_429_text / _hmd_is_quota_text); an unrelated real error, a clean
# success, and a pure server-overload give-up must NOT (red-proofs).
# HEIMDALL_HOME is already per-case-sandboxed by reset_case() above (a fresh
# "$WORK/hmdhome-$RANDOM" every call), so marker_fresh() below never touches
# a real ~/.heimdall/429-marker.json.
echo "Case H — 429/quota detection marks the exhaustion gate (unrelated failure/success/pure-529 do not):"
marker_fresh() { "$ROOT/bin/heimdall-429-mark" check --ttl-secs 900 >/dev/null 2>&1; }

# H1: raw "429 / rate_limit" text (Anthropic API-shaped) also satisfies
# _hmd_is_overload_text (it literally contains "429"), so this is genuinely
# indistinguishable from a transient overload by that gate and retries to
# exhaustion like Case D -- proving the (pre-existing) 429 mark fires even
# on the give-up path, not only on an immediate fail-fast.
reset_case real_429
export HMD_OVERLOAD_MAX_ATTEMPTS=3
rcH1=0; "$EXEC" run -p "x" --model m >/dev/null 2>"$WORK/h1.err" || rcH1=$?
check "H1 exhausts retries and gives up loudly (75)"     "[ '$rcH1' -eq 75 ] && [ '$(count)' -eq 3 ]"
check "H1 (raw 429/rate_limit text) marks the gate"      "marker_fresh"

# H2: Claude-Code session-limit shape ("hit your … limit … resets H:MMam/pm
# (TZ)") -> marker written even though it contains NONE of H1's markers and
# fails _hmd_is_overload_text entirely (fails fast, exit 1, no retry -- see
# hmd-claude-retry.sh's _hmd_is_quota_text comment).
reset_case real_quota
export HMD_OVERLOAD_MAX_ATTEMPTS=6
rcH2=0; "$EXEC" run -p "x" --model m >/dev/null 2>"$WORK/h2.err" || rcH2=$?
check "H2 propagates claude's real exit (1), no retry"   "[ '$rcH2' -eq 1 ] && [ '$(count)' -eq 1 ]"
check "H2 (session-limit text) marks the gate"           "marker_fresh"

# H3 (red-proof #1): unrelated non-zero failure -> NO marker.
reset_case real_error
export HMD_OVERLOAD_MAX_ATTEMPTS=6
rcH3=0; "$EXEC" run -p "x" --model m >/dev/null 2>"$WORK/h3.err" || rcH3=$?
check "H3 unrelated failure propagates exit 1"           "[ '$rcH3' -eq 1 ]"
check "H3 (unrelated failure) does NOT mark the gate"    "! marker_fresh"

# H4 (red-proof #2): clean success -> NO marker.
reset_case success
rcH4=0; "$EXEC" run -p "x" --model m >/dev/null 2>"$WORK/h4.err" || rcH4=$?
check "H4 clean run exits 0"                             "[ '$rcH4' -eq 0 ]"
check "H4 (clean success) does NOT mark the gate"        "! marker_fresh"

# H5 (red-proof #3): pure server-overload (529, no 429/rate-limit/session-
# limit wording at all) gives up loudly -- must NOT be mistaken for an
# account-quota signal. Proves both the old and new text checks stay silent
# on generic capacity-overload text, not just on ordinary real errors.
reset_case always_overload
export HMD_OVERLOAD_MAX_ATTEMPTS=2
rcH5=0; "$EXEC" run -p "x" --model m >/dev/null 2>"$WORK/h5.err" || rcH5=$?
check "H5 pure-529 give-up exits the distinct overload code (75)" "[ '$rcH5' -eq 75 ]"
check "H5 (529 overload, no 429/quota wording) does NOT mark"     "! marker_fresh"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
