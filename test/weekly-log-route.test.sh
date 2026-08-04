#!/usr/bin/env bash
# test/weekly-log-route.test.sh — bin/heimdall must ROUTE `hmd weekly-log`.
#
# THE DEFECT THIS GUARDS: bin/heimdall-weekly-log shipped complete, executable,
# and fully proven (test/weekly-log-consent.test.sh, 38/0) — but bin/heimdall's
# dispatcher had no `weekly-log)` arm. The generator was reachable only by its
# absolute path: a shipped feature no user could find via `hmd`/`heimdall`. This
# is the SAME bug class closed in 4ec87bb for `hmd update`: advertised without
# being dispatched, so a user following the documented command lands on the
# Claude-task fall-through instead of the tool they asked for — and the
# fall-through prints happily and exits 0, so the miss looks like success.
#
#   A. SYNTAX    bash -n clean on bin/heimdall.
#   B. DISPATCH  `hmd weekly-log` execs heimdall-weekly-log, never the Claude
#                fall-through.
#   C. ARGS      every flag forwards byte-for-byte, unmodified, in order.
#   D. MISSING   a missing/non-executable heimdall-weekly-log fails LOUDLY —
#      BINARY    clear stderr message, nonzero exit, no silent success, no
#                fall-through — and never bricks a SIBLING route (the b55c106
#                defect class: an unguarded helper call under
#                `set -euo pipefail` can abort the whole launcher).
#   E. REAL GEN  the genuine bin/heimdall-weekly-log (not a stub) answers
#                --help through the route, sandboxed — proves the wiring is
#                real, not just argv-recording, with zero risk of a live
#                Claude/network/install side effect.
#   F. DRIFT     symmetric check: advertised in --help text <=> has a case arm.
#                A future edit that adds one without the other must go RED
#                here, same shape as test/hmd-update-alias.test.sh.
#
# HOW THE HARNESS WORKS: mirrors test/heimdall-cli-routing.test.sh — copy
# bin/heimdall into a throwaway fake plugin dir so PLUGIN_DIR resolves there,
# stub heimdall-weekly-log to record its argv, and read HEIMDALL_TRACE_ORDER to
# prove (or disprove) the Claude fall-through was reached. Nothing here ever
# invokes a real `claude`, a real network call, or writes into the real repo.
#
# FALSIFIABILITY: every assertion is a direct behavioural read (stub called /
# args recorded / trace marker / real exit code / real output) — none can pass
# vacuously without the route actually existing and actually working. Proof:
# this file was run against bin/heimdall BEFORE the weekly-log case arm existed
# (RED — B, C, D1-D3, E2, F1-F2 fail) and AFTER (GREEN) — see the commit that
# adds this file for the exact counts of both runs.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
REAL_BIN="$REPO/bin/heimdall"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -f "$REAL_BIN" ] || { echo "FATAL: $REAL_BIN not found"; exit 2; }

# ── fake plugin dir (mirrors test/heimdall-cli-routing.test.sh's harness) ──
FAKE_DIR="$(mktemp -d /tmp/test-heimdall-weekly-log-route-XXXXXX)"
FAKE_BIN="$FAKE_DIR/bin"
FAKE_HOME="$FAKE_DIR/home"
mkdir -p "$FAKE_BIN" "$FAKE_HOME" "$FAKE_DIR/.claude-plugin"

# COPY (not symlink) so readlink -f resolves PLUGIN_DIR to $FAKE_DIR.
cp "$REAL_BIN" "$FAKE_BIN/heimdall"
chmod +x "$FAKE_BIN/heimdall"

# Mark setup done -> first_run_setup returns immediately, no network/install.
touch "$FAKE_HOME/setup-done"

# Stub `claude` so ensure_claude passes and any fall-through short-circuits on
# HEIMDALL_TRACE_ORDER rather than launching anything real.
cat > "$FAKE_BIN/claude" <<'EOBIN'
#!/usr/bin/env bash
exit 0
EOBIN
chmod +x "$FAKE_BIN/claude"

STUB_OUT="$(mktemp /tmp/test-hmd-wl-stub-XXXXXX)"
TRACE_FILE="$(mktemp /tmp/test-hmd-wl-trace-XXXXXX)"
HMD_OUT="$(mktemp /tmp/test-hmd-wl-out-XXXXXX)"

cleanup() { rm -rf "$FAKE_DIR" "$STUB_OUT" "$TRACE_FILE" "$HMD_OUT" 2>/dev/null || true; }
trap cleanup EXIT

# make_stub NAME — place a stub in $FAKE_BIN that records its argv to STUB_OUT.
make_stub() {
  local name="$1"
  cat > "$FAKE_BIN/$name" <<EOBIN
#!/usr/bin/env bash
printf '%s ARGS: %s\n' "$name" "\$*" >> "\${HMD_STUB_OUT:-/dev/null}"
exit 0
EOBIN
  chmod +x "$FAKE_BIN/$name"
}

# run_hmd CMD [ARGS…] — discard output, sanitised environment (dispatch proofs).
run_hmd() {
  PATH="$FAKE_BIN:$PATH" \
  HEIMDALL_HOME="$FAKE_HOME" \
  HEIMDALL_NO_INTRO=1 \
  HEIMDALL_NO_UPDATE_CHECK=1 \
  HMD_STUB_OUT="$STUB_OUT" \
  HEIMDALL_TRACE_ORDER="$TRACE_FILE" \
  bash "$FAKE_BIN/heimdall" "$@" >/dev/null 2>&1
}

# run_hmd_capture CMD [ARGS…] — like run_hmd but keeps combined output in
# $HMD_OUT and the exit code in $HMD_RC (missing-binary + real-generator proofs).
run_hmd_capture() {
  PATH="$FAKE_BIN:$PATH" \
  HEIMDALL_HOME="$FAKE_HOME" \
  HEIMDALL_NO_INTRO=1 \
  HEIMDALL_NO_UPDATE_CHECK=1 \
  HMD_STUB_OUT="$STUB_OUT" \
  HEIMDALL_TRACE_ORDER="$TRACE_FILE" \
  bash "$FAKE_BIN/heimdall" "$@" >"$HMD_OUT" 2>&1
  HMD_RC=$?
}

stub_called()    { grep -q "$1" "$STUB_OUT" 2>/dev/null; }
args_contain()   { grep -qF -- "$1" "$STUB_OUT" 2>/dev/null; }
claude_reached() { grep -q "launch:task" "$TRACE_FILE" 2>/dev/null; }
reset() { : > "$STUB_OUT"; : > "$TRACE_FILE"; : > "$HMD_OUT"; }

make_stub heimdall-weekly-log

echo
echo "A. SYNTAX"
if bash -n "$REAL_BIN" 2>/dev/null; then ok "A1 bash -n clean on bin/heimdall"
else bad "A1 bin/heimdall has a syntax error"; fi

echo
echo "B. DISPATCH — hmd weekly-log routes to heimdall-weekly-log, never the Claude fall-through"
reset
run_hmd weekly-log --help
if stub_called "heimdall-weekly-log"; then ok "B1 weekly-log routes to heimdall-weekly-log"
else bad "B1 weekly-log did not route to heimdall-weekly-log"; fi
if args_contain "--help"; then ok "B2 --help is forwarded"
else bad "B2 --help was not forwarded"; fi
if ! claude_reached; then ok "B3 weekly-log does NOT fall through to Claude"
else bad "B3 weekly-log MUST NOT reach the Claude fall-through"; fi

echo
echo "C. ARGS PASS THROUGH UNCHANGED — a full flag set, verbatim, in order"
reset
run_hmd weekly-log --since=2020-01-01 --until 2020-01-08 --k 5 --stdout --slice
if args_contain "--since=2020-01-01 --until 2020-01-08 --k 5 --stdout --slice"; then
  ok "C1 a full flag set is forwarded byte-for-byte, in order"
else
  bad "C1 flags were altered, reordered, or dropped in transit"
  cat "$STUB_OUT" >&2
fi

echo
echo "D. MISSING BINARY — fails loudly, never bricks hmd, never a silent exit 0"
reset
rm -f "$FAKE_BIN/heimdall-weekly-log"
run_hmd_capture weekly-log --help
if [ "$HMD_RC" -ne 0 ]; then ok "D1 missing heimdall-weekly-log exits NONZERO (rc=$HMD_RC)"
else bad "D1 missing heimdall-weekly-log exited 0 — looks like success, isn't"; fi
if grep -qi 'heimdall-weekly-log not found' "$HMD_OUT"; then
  ok "D2 a clear error names the missing binary"
else
  bad "D2 no clear error printed for the missing binary"
  cat "$HMD_OUT" >&2
fi
if ! claude_reached; then ok "D3 a missing binary does NOT silently fall through to Claude"
else bad "D3 [CARDINAL] missing binary must not disguise itself as an unrouted task"; fi

# The brick check: an UNRELATED route must still work in the SAME fake dir while
# heimdall-weekly-log stays absent — proves the guard cannot take down a sibling.
reset
make_stub heimdall-team
run_hmd team status
if stub_called "heimdall-team"; then
  ok "D4 an unrelated subcommand (team) still works while heimdall-weekly-log is absent"
else
  bad "D4 [CARDINAL] a missing heimdall-weekly-log bricked an unrelated subcommand"
fi
rm -f "$FAKE_BIN/heimdall-team"
make_stub heimdall-weekly-log   # restore the recording stub for later sections

echo
echo "E. REAL GENERATOR, SANDBOXED — the genuine binary answers --help through the route"
reset
cp "$REPO/bin/heimdall-weekly-log" "$FAKE_BIN/heimdall-weekly-log"
chmod +x "$FAKE_BIN/heimdall-weekly-log"
drafts_before="$(ls "$REPO/launch-docs/drafts" 2>/dev/null | sort)"
run_hmd_capture weekly-log --help
drafts_after="$(ls "$REPO/launch-docs/drafts" 2>/dev/null | sort)"
if [ "$HMD_RC" -eq 0 ]; then ok "E1 the real generator exits 0 on --help through the route"
else bad "E1 the real generator exited $HMD_RC on --help through the route"; fi
if grep -q 'k-ANONYMITY' "$HMD_OUT"; then
  ok "E2 the real generator's own help text came back through the route"
else
  bad "E2 --help output did not come from the real generator"
  head -3 "$HMD_OUT" >&2
fi
if [ "$drafts_before" = "$drafts_after" ]; then
  ok "E3 --help wrote no new file into the real repo's launch-docs/drafts"
else
  bad "E3 [CARDINAL] --help wrote into the real repo's drafts directory"
fi
make_stub heimdall-weekly-log   # restore the recording stub

echo
echo "F. ADVERTISED <=> DISPATCHED — never one without the other (the 4ec87bb bug class)"
if grep -q 'heimdall weekly-log' "$REAL_BIN"; then ok "F1 weekly-log is advertised in --help text"
else bad "F1 weekly-log is not advertised anywhere in bin/heimdall's help text"; fi
if grep -qE '^  weekly-log\)' "$REAL_BIN"; then ok "F2 weekly-log has a case-dispatch arm"
else bad "F2 [CARDINAL] weekly-log is advertised but undispatched — the exact hmd-update bug class"; fi

echo
echo "============================================================"
echo "weekly-log-route: $PASS passed, $FAIL failed"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
