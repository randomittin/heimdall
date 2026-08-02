#!/usr/bin/env bash
# crontab-safe.test.sh — proves bin/lib/crontab-safe.sh can NEVER destroy a user's crontab.
#
# THE DEFECT THIS GUARDS (the reason this file exists):
#   The old form was `crontab -l 2>/dev/null | grep -v MARKER > "$tmp" || true; crontab "$tmp"`.
#   If `crontab -l` failed for ANY reason other than "no crontab exists" — permissions, a cron
#   daemon hiccup, an unreadable spool — then $tmp was EMPTY, `|| true` swallowed the failure,
#   and `crontab "$tmp"` REPLACED the user's entire crontab with only the heimdall lines.
#   Every unrelated cron job, gone, silently, with no backup. Same vacuous-gate shape as an
#   empty intermediate treated as a valid result — but destructive instead of a false pass.
#
# HERMETIC: a fake `crontab` is prepended to PATH and HOME is redirected to a temp dir. The
# REAL crontab binary is NEVER invoked and the real user crontab is NEVER read or written.
#
#   A. SYNTAX: `bash -n` clean on the lib and both deploy scripts; the emitted remote script
#      is valid POSIX sh (`sh -n`).
#   B. NORMAL: unrelated jobs are PRESERVED, stale heimdall-marker lines are REPLACED.
#   C. NO CRONTAB: the documented "no crontab for <user>" non-zero exit is NOT an error —
#      it installs the heimdall lines and correctly preserves nothing.
#   D. READ FAILURE ABORTS (the assertion that matters most): a real `crontab -l` error
#      (authorization denied, and a silent non-zero with empty stderr) must ABORT non-zero
#      and the stub must record that `crontab <file>` was NEVER invoked.
#   E. BACKUP: the pre-existing crontab is written to a timestamped file, the path is
#      REPORTED on stdout, and its bytes match the crontab that was read.
#   F. NO DRIFT: neither deploy script still carries the destructive `|| true` read, and both
#      route through the one shared helper (so one call site can't get fixed and the other left).
#   G. TRAILING NEWLINE: a kept crontab whose last line lacks a newline is not JOINED to the
#      first appended heimdall entry.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/bin/lib/crontab-safe.sh"
GCE="$ROOT/deploy/gce/provision-maintainer-vm.sh"
CRUN="$ROOT/deploy/cloud-run/deploy-maintainer.sh"
MARKER='heimdall-maintainer-'

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -f "$LIB" ] || { echo "FATAL: $LIB not found"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
STUBDIR="$WORK/bin"; mkdir -p "$STUBDIR"
export STUB_CURRENT="$WORK/current.cron"      # what the fake `crontab -l` returns
export STUB_LOG="$WORK/install.log"           # every `crontab <file>` invocation
export STUB_INSTALLED="$WORK/installed.cron"  # bytes the fake `crontab <file>` received

# ── the fake crontab. NEVER touches a real crontab; it only reads/writes files under $WORK.
cat > "$STUBDIR/crontab" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-l" ]; then
  case "${STUB_MODE:-has}" in
    has)  cat "$STUB_CURRENT"; exit 0 ;;
    none) echo "no crontab for tester" >&2; exit 1 ;;                                   # expected: none exists
    denied) echo "crontab: you (tester) are not allowed to use this program" >&2; exit 126 ;;  # REAL failure
    silent) exit 70 ;;                                                                  # REAL failure, no stderr
  esac
fi
echo "INSTALL $1" >> "$STUB_LOG"   # the destructive call — must not happen after a failed read
cp "$1" "$STUB_INSTALLED"
exit 0
STUB
chmod +x "$STUBDIR/crontab"

BEAT="* * * * * . \$HOME/.heimdall.env; loop runner-beat --runner-id \$(hostname) >/dev/null 2>&1 # ${MARKER}beat"
CYCLE="*/30 * * * * . \$HOME/.heimdall.env; loop run --max 3 >/dev/null 2>&1 # ${MARKER}cycle"

# run the helper with the stub on PATH and a throwaway HOME. Prints output; returns its rc.
run_install() { # $1 = STUB_MODE
  local mode="$1" fh="$WORK/home"
  mkdir -p "$fh"
  STUB_MODE="$mode" PATH="$STUBDIR:$PATH" HOME="$fh" \
    bash -c 'set -uo pipefail; . "$1"; shift; heimdall_crontab_install "$@"' \
      _ "$LIB" "$MARKER" "$BEAT" "$CYCLE" 2>&1
}
reset_stub() { : > "$STUB_LOG"; rm -f "$STUB_INSTALLED"; rm -rf "$WORK/home"; }

echo "== A. syntax =="
bash -n "$LIB" 2>/dev/null && ok "crontab-safe.sh: bash -n clean" || bad "crontab-safe.sh: bash -n FAILED"
bash -n "$GCE" 2>/dev/null && ok "provision-maintainer-vm.sh: bash -n clean" || bad "provision-maintainer-vm.sh: bash -n FAILED"
bash -n "$CRUN" 2>/dev/null && ok "deploy-maintainer.sh: bash -n clean" || bad "deploy-maintainer.sh: bash -n FAILED"
# the GCE call site ships this text over ssh to a POSIX shell — it must parse as plain sh.
( . "$LIB"; heimdall_crontab_script "$MARKER" "$BEAT" "$CYCLE" ) > "$WORK/emitted.sh" 2>/dev/null
sh -n "$WORK/emitted.sh" 2>/dev/null && ok "emitted remote script: sh -n clean (POSIX)" || bad "emitted remote script: sh -n FAILED"

echo "== B. normal: unrelated jobs preserved, heimdall lines replaced =="
reset_stub
cat > "$STUB_CURRENT" <<EOF
0 3 * * * /usr/local/bin/backup-db.sh    # the user's OWN job
@reboot /opt/thing/start.sh
*/5 * * * * loop runner-beat >/dev/null 2>&1 # ${MARKER}beat
EOF
OUT_B="$(run_install has)"; RC_B=$?
[ "$RC_B" = 0 ] && ok "normal: exited 0" || bad "normal: exited $RC_B (expected 0)"
if [ -f "$STUB_INSTALLED" ]; then
  grep -q 'backup-db.sh' "$STUB_INSTALLED" && ok "normal: unrelated job 'backup-db.sh' PRESERVED" \
    || bad "normal: unrelated job 'backup-db.sh' LOST"
  grep -q '@reboot /opt/thing/start.sh' "$STUB_INSTALLED" && ok "normal: unrelated '@reboot' job PRESERVED" \
    || bad "normal: unrelated '@reboot' job LOST"
  [ "$(grep -c "${MARKER}beat" "$STUB_INSTALLED")" = 1 ] && ok "normal: stale heimdall beat line REPLACED (exactly 1)" \
    || bad "normal: heimdall beat line count = $(grep -c "${MARKER}beat" "$STUB_INSTALLED") (expected 1)"
  grep -q "${MARKER}cycle" "$STUB_INSTALLED" && ok "normal: new heimdall cycle line APPENDED" \
    || bad "normal: new heimdall cycle line MISSING"
  grep -q 'hostname' "$STUB_INSTALLED" && ok "normal: '\$(hostname)' kept literal for cron to expand" \
    || bad "normal: '\$(hostname)' was expanded/lost"
else
  bad "normal: crontab was never installed"
fi

echo "== C. no crontab exists: succeeds, installs, preserves nothing =="
reset_stub
OUT_C="$(run_install none)"; RC_C=$?
[ "$RC_C" = 0 ] && ok "no-crontab: exited 0 (a 'no crontab for <user>' exit is NOT a failure)" \
  || bad "no-crontab: exited $RC_C (expected 0)"
if [ -f "$STUB_INSTALLED" ]; then
  grep -q "${MARKER}beat" "$STUB_INSTALLED" && grep -q "${MARKER}cycle" "$STUB_INSTALLED" \
    && ok "no-crontab: both heimdall lines installed" || bad "no-crontab: heimdall lines missing"
  [ "$(grep -cv '^[[:space:]]*$' "$STUB_INSTALLED")" = 2 ] \
    && ok "no-crontab: exactly the 2 heimdall lines, nothing invented" \
    || bad "no-crontab: installed $(grep -cv '^[[:space:]]*$' "$STUB_INSTALLED") lines (expected 2)"
else
  bad "no-crontab: crontab was never installed (expected a fresh install)"
fi

echo "== D. READ FAILURE ABORTS — and NEVER installs (the assertion that matters most) =="
for mode in denied silent; do
  reset_stub
  printf '0 3 * * * /usr/local/bin/backup-db.sh\n' > "$STUB_CURRENT"
  OUT_D="$(run_install "$mode")"; RC_D=$?
  [ "$RC_D" != 0 ] && ok "read-fail[$mode]: ABORTED non-zero (rc=$RC_D)" \
    || bad "read-fail[$mode]: exited 0 — a failed read was treated as success"
  [ ! -s "$STUB_LOG" ] && ok "read-fail[$mode]: 'crontab <file>' was NEVER invoked (crontab untouched)" \
    || bad "read-fail[$mode]: DESTRUCTIVE — crontab was installed anyway: $(cat "$STUB_LOG")"
  [ ! -f "$STUB_INSTALLED" ] && ok "read-fail[$mode]: nothing was written to the crontab" \
    || bad "read-fail[$mode]: crontab content was replaced"
  printf '%s' "$OUT_D" | grep -qi 'not modified\|NOT modified' \
    && ok "read-fail[$mode]: told the user their crontab was NOT modified" \
    || bad "read-fail[$mode]: no clear 'crontab was NOT modified' message"
done

echo "== E. backup written + path reported =="
reset_stub
cat > "$STUB_CURRENT" <<EOF
0 3 * * * /usr/local/bin/backup-db.sh
*/5 * * * * loop runner-beat # ${MARKER}beat
EOF
OUT_E="$(run_install has)"; RC_E=$?
BPATH="$(printf '%s\n' "$OUT_E" | sed -n 's/.*backed up[^/]*\(\/[^ ]*\).*/\1/p' | head -1)"
if [ -n "$BPATH" ]; then
  ok "backup: path REPORTED on stdout ($BPATH)"
  if [ -f "$BPATH" ]; then
    ok "backup: file exists at the reported path"
    cmp -s "$BPATH" "$STUB_CURRENT" && ok "backup: bytes match the crontab that was read (fully recoverable)" \
      || bad "backup: contents differ from the crontab that was read"
  else
    bad "backup: reported path does not exist"
  fi
else
  bad "backup: no backup path reported in output"
fi
[ "$RC_E" = 0 ] && ok "backup: install still succeeded" || bad "backup: install exited $RC_E"

echo "== F. no drift: both call sites use the shared helper, destructive form is gone =="
for f in "$GCE" "$CRUN"; do
  n="$(basename "$f")"
  grep -qE "crontab -l 2>/dev/null \| grep -v .*\|\| true" "$f" \
    && bad "$n: STILL carries the destructive 'crontab -l ... || true' read" \
    || ok "$n: destructive 'crontab -l ... || true' read is GONE"
  grep -q 'crontab-safe.sh' "$f" && ok "$n: sources the shared crontab-safe helper" \
    || bad "$n: does not source bin/lib/crontab-safe.sh (fix would drift between call sites)"
  grep -qE 'heimdall_crontab_(install|script)' "$f" && ok "$n: calls the shared helper API" \
    || bad "$n: never calls heimdall_crontab_install/script"
done

echo "== G. crontab with no trailing newline is not joined to the appended entry =="
reset_stub
printf '0 3 * * * /usr/local/bin/backup-db.sh' > "$STUB_CURRENT"   # deliberately NO trailing newline
OUT_G="$(run_install has)"; RC_G=$?
[ "$RC_G" = 0 ] && ok "no-trailing-newline: exited 0" || bad "no-trailing-newline: exited $RC_G"
if [ -f "$STUB_INSTALLED" ]; then
  grep -qE '^0 3 \* \* \* /usr/local/bin/backup-db\.sh[[:space:]]*$' "$STUB_INSTALLED" \
    && ok "no-trailing-newline: user's last job stayed on its OWN line" \
    || bad "no-trailing-newline: user's job was JOINED to a heimdall entry: $(head -1 "$STUB_INSTALLED")"
else
  bad "no-trailing-newline: crontab was never installed"
fi

echo
printf 'crontab-safe: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
