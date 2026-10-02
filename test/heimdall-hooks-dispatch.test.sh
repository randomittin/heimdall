#!/usr/bin/env bash
# heimdall-hooks-dispatch.test.sh -- acceptance for routing `hmd hooks ...`
# through bin/heimdall's CLI dispatch into bin/heimdall-hooks.
#
# Bug this pins: `hmd hooks --help` (and every other `hmd hooks <sub>`) had no
# dispatch arm, so it fell through to the task-prompt path -- printed the
# launch banner and started Claude Code with "hooks --help" as the TASK,
# instead of showing heimdall-hooks' usage. bin/heimdall-hooks itself was fine;
# only the wiring was missing. heimdall-hooks' own behavior is covered by
# hooks-metadata-drift.test.sh and hooks-disable.test.sh -- this suite covers
# only the dispatch arm and its help-listing line.
#
# A fake `claude` is put first on PATH so that, if the arm ever regresses, the
# fallthrough is DETECTED (marker string) instead of launching a real session.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HEIMDALL="$REPO/bin/heimdall"
HMD="$REPO/bin/hmd"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

for f in "$HEIMDALL" "$HMD" "$REPO/bin/heimdall-hooks"; do
  [ -x "$f" ] || { echo "FATAL: $f missing or not executable"; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/fakebin" "$TMP/home"
cat > "$TMP/fakebin/claude" <<'EOF'
#!/bin/sh
echo "FAKE-CLAUDE-LAUNCHED $*"
exit 0
EOF
chmod +x "$TMP/fakebin/claude"

run() {
  # Bounded: a regression that falls through must not hang the suite.
  PATH="$TMP/fakebin:$PATH" HEIMDALL_HOME="$TMP/home" \
    perl -e 'alarm 30; exec @ARGV' "$@" </dev/null 2>&1
}

echo "1. hmd hooks --help / -h / help print heimdall-hooks usage, never launch:"
for flag in --help -h help; do
  OUT="$(run "$HMD" hooks "$flag")"; RC=$?
  [ "$RC" -eq 0 ] && ok "hmd hooks $flag exits 0" || bad "hmd hooks $flag exit $RC: $(printf '%s' "$OUT" | head -3)"
  printf '%s' "$OUT" | grep -q 'usage: heimdall-hooks' \
    && ok "hmd hooks $flag shows heimdall-hooks usage" \
    || bad "hmd hooks $flag missing usage: $(printf '%s' "$OUT" | head -3)"
  printf '%s' "$OUT" | grep -q 'FAKE-CLAUDE-LAUNCHED' \
    && bad "hmd hooks $flag FELL THROUGH and launched claude" \
    || ok "hmd hooks $flag did not launch claude"
done

echo "2. bare hmd hooks prints usage (exit 0), never launches:"
OUT="$(run "$HMD" hooks)"; RC=$?
[ "$RC" -eq 0 ] && ok "bare hmd hooks exits 0" || bad "bare hmd hooks exit $RC"
printf '%s' "$OUT" | grep -q 'usage: heimdall-hooks' && ok "bare hmd hooks shows usage" || bad "bare hmd hooks missing usage"
printf '%s' "$OUT" | grep -q 'FAKE-CLAUDE-LAUNCHED' && bad "bare hmd hooks launched claude" || ok "bare hmd hooks did not launch claude"

echo "3. subcommands pass through with their args and exit codes intact:"
OUT="$(run "$HMD" hooks list)"; RC=$?
[ "$RC" -eq 0 ] && ok "hmd hooks list exits 0" || bad "hmd hooks list exit $RC"
printf '%s' "$OUT" | grep -q 'secret-read-guard\|stub-gate' && ok "hmd hooks list prints hook ids" || bad "hmd hooks list output: $(printf '%s' "$OUT" | head -3)"
OUT="$(run "$HMD" hooks disable --help)"; RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'usage: heimdall-hooks disable' \
  && ok "hmd hooks disable --help reaches the subparser" || bad "hmd hooks disable --help rc=$RC: $(printf '%s' "$OUT" | head -3)"
OUT="$(run "$HMD" hooks disable no-such-hook-id-xyz)"; RC=$?
[ "$RC" -eq 1 ] && ok "unknown id exit code (1) propagates" || bad "unknown id exit $RC (want 1): $OUT"
OUT="$(run "$HMD" hooks bogus-sub)"; RC=$?
[ "$RC" -ne 0 ] && ok "invalid subcommand exits non-zero ($RC)" || bad "invalid subcommand exited 0"
printf '%s' "$OUT" | grep -q 'FAKE-CLAUDE-LAUNCHED' && bad "invalid subcommand launched claude" || ok "invalid subcommand did not launch claude"

echo "4. heimdall and hmd route identically; top-level help lists the arm:"
A="$(run "$HEIMDALL" hooks --help)"; B="$(run "$HMD" hooks --help)"
[ "$A" = "$B" ] && ok "heimdall hooks --help == hmd hooks --help" || bad "heimdall vs hmd output differs"
OUT="$(run "$HEIMDALL" --help)"
printf '%s' "$OUT" | grep -q 'heimdall hooks ' && ok "heimdall --help lists 'heimdall hooks'" || bad "heimdall --help does not list hooks"

echo ""
echo "heimdall-hooks-dispatch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
