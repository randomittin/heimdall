#!/usr/bin/env bash
#
# cp-serve-guard-wiring.test.sh — the CALLER gate for the control-plane orphan guard.
#
# THE DEFECT THIS PINS. `bin/heimdall-control-plane serve` runs cp_server.serve() ->
# httpd.serve_forever() out of a bare-stdin heredoc, so in ps the process is exactly
# `python3 -` — no script path, no marker, nothing that attributes it. Commit 3f1a2f2 gave
# that emitter an opt-in watchdog: export HMD_CP_GUARD_PID=<pid> and a daemon thread
# os._exit(0)s the server the moment that pid dies. The watchdog was correct, tested, and had
# ZERO CALLERS. Seventeen launchers across thirteen test files backgrounded the real server
# without exporting it, so any test that died before its explicit `kill $SERVER_PID` — failed
# assertion, set -e, timeout, ctrl-C — left a server reparented to PID 1 and blocked in
# select() for days. That is the orphan pile measured on 2026-08-08.
#
# A guard that exists but is never invoked is not a fix, it is a fix-shaped object. So the
# thing this suite gates is the WIRING, not the guard: test/orphan-python-detection.test.sh
# already owns the emitter's behaviour.
#
#   bash test/cp-serve-guard-wiring.test.sh     (exit 0 = all cases pass)
#
# FALSIFIABLE claims proven:
#   (1) the scan DISCOVERS launchers at all, and at least as many as were wired (17). An
#       empty scan is a hard FAIL — "found nothing, therefore clean" is the exact shape of
#       the blindness this repo keeps getting bitten by.
#   (2) every discovered launcher carries HMD_CP_GUARD_PID in the scope of its own command.
#   (3) PROVE-DETECTS: an unguarded launcher synthesised in a temp dir is FLAGGED, in both
#       the one-line and the backslash-continued shape; its guarded twin is NOT. A verdict
#       that cannot go red proves nothing.
#   (4) NO FALSE POSITIVES: a foreground serve, a backgrounded NON-serve subcommand, and a
#       different binary's `serve` (bin/heimdall-queue) are all left alone. Over-matching
#       would make (2) unmaintainable and push people to weaken the gate.
#   (5) the env var the launchers export is the one the SHIPPED emitter still reads — wiring
#       that points at a consumer which no longer exists is decoration.
#
# HERMETIC. Reads repo files, writes only inside its own mktemp -d, executes no server,
# opens no socket, and never touches the real ~/.heimdall or ~/.claude.
#
# NOTE ON SELF-SCANNING. The scan covers every test/*.test.sh INCLUDING this file: an
# exclusion list is exactly where a real launcher would eventually hide. That is possible
# because the fixture bodies below are ASSEMBLED from argument lists rather than pasted as
# literal launcher lines, so this file contains no line that backgrounds a control-plane
# serve. mkfix is the only writer, and it writes into $WORK.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CP="$ROOT/bin/heimdall-control-plane"

# The number of backgrounded control-plane serve launchers wired with HMD_CP_GUARD_PID=$$.
# The scan must never find FEWER than this: a launcher that disappears from the scan while
# still living in the tree means the detector went blind, not that the tree got cleaner.
WIRED=17

P=0; F=0
ok()  { P=$((P+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { F=$((F+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

[ -f "$CP" ] || { echo "FATAL: $CP missing" >&2; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "FATAL: awk not found" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cp-serve-guard.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

echo "cp-serve-guard-wiring.test.sh"

# ══════════════════════════════════════════════════════════════════════════════════
# THE DETECTOR
# ══════════════════════════════════════════════════════════════════════════════════
# Verdicts are per LOGICAL command, not per physical line: 15 of the 17 real launchers spread
# one command over two or three physical lines with backslash continuations, and the env
# prefix sits on the FIRST while the `&` sits on the LAST. A physical-line scanner reads
# every one of them wrong, in both directions.
#
# "The control-plane CLI" is resolved per file rather than assumed: a launcher writes
# `"$CLI" serve`, and $CLI is whatever that file bound to bin/heimdall-control-plane. Matching
# on the bare word `serve` would sweep in bin/heimdall-queue's own serve subcommand, which
# has nothing to do with this guard.
cat > "$WORK/scan.awk" <<'AWKEOF'
function verdict(cmd, ln,    name, v, re, hit) {
  if (cmd ~ /^[ \t]*#/) return
  # (a) remember every variable this file bound to the control-plane CLI path.
  if (cmd ~ /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/ && cmd ~ /bin\/heimdall-control-plane/) {
    name = cmd
    sub(/^[ \t]*(export[ \t]+)?/, "", name)
    sub(/=.*$/, "", name)
    if (name != "") cpvar[name] = 1
  }
  # (b) a file-level export puts the guard in scope for every launcher below it.
  if (cmd ~ /^[ \t]*export[ \t]+HMD_CP_GUARD_PID=/) fileguard = 1
  # (c) only a BACKGROUNDED command can outlive its shell, so only that shape is in scope.
  if (cmd !~ /&[ \t]*$/) return
  if (cmd ~ /&&[ \t]*$/) return
  # (d) …and it must invoke `serve` on the control-plane CLI specifically.
  hit = 0
  for (v in cpvar) {
    re = "[$][{]?" v "[}]?[\"']?[ \t]+serve([ \t]|$)"
    if (cmd ~ re) { hit = 1; break }
  }
  if (hit == 0 && cmd ~ /heimdall-control-plane["']?[ \t]+serve([ \t]|$)/) hit = 1
  if (hit == 0) return
  if (fileguard == 1 || cmd ~ /HMD_CP_GUARD_PID/)
    printf "%s:%d:GUARDED\n", FILENAME, ln
  else
    printf "%s:%d:UNGUARDED\n", FILENAME, ln
}
FNR == 1 { split("", cpvar); fileguard = 0; buf = ""; start = 0 }
{
  if (buf == "") start = FNR
  line = $0
  if (line ~ /\\$/) { sub(/\\$/, "", line); buf = buf line " "; next }
  verdict(buf line, start)
  buf = ""
}
END { if (buf != "") verdict(buf, start) }
AWKEOF

scan() { awk -f "$WORK/scan.awk" "$@" 2>/dev/null; }

# mkfix <path> <line>… — assemble a fixture file one literal line at a time. Fixture bodies
# never appear as pasted launcher lines in this file, which is what lets the repo scan below
# include this file with no exclusion list.
mkfix() {
  local out="$1"; shift
  : > "$out"
  local l
  for l in "$@"; do printf '%s\n' "$l" >> "$out"; done
}

CPBIN='bin/heimdall-control-plane'

# ══════════════════════════════════════════════════════════════════════════════════
# (1) THE SCAN FINDS LAUNCHERS — an empty scan is a FAILURE, never a pass
# ══════════════════════════════════════════════════════════════════════════════════
ALL="$WORK/all"
scan "$ROOT"/test/*.test.sh > "$ALL"
N="$(grep -c '' <"$ALL" || true)"
NFILES="$(cut -d: -f1 <"$ALL" | sort -u | grep -c '' || true)"

if [ "$N" -eq 0 ]; then
  bad "(1) the scan found ZERO backgrounded control-plane serve launchers — the detector is blind, not the tree clean (expected at least $WIRED)"
elif [ "$N" -ge "$WIRED" ]; then
  ok "(1) scan discovered $N backgrounded control-plane serve launchers across $NFILES files (floor: the $WIRED that were wired)"
else
  bad "(1) scan discovered only $N launchers, fewer than the $WIRED wired — a launcher stopped being visible to the detector"
fi

# ══════════════════════════════════════════════════════════════════════════════════
# (2) EVERY LAUNCHER CARRIES THE GUARD
# ══════════════════════════════════════════════════════════════════════════════════
UNGUARDED="$(grep ':UNGUARDED$' <"$ALL" || true)"
if [ -z "$UNGUARDED" ]; then
  ok "(2) all $N launchers export HMD_CP_GUARD_PID in the scope of their own command"
else
  bad "(2) these launchers background the control plane with NO HMD_CP_GUARD_PID in scope — each one leaks a python3 - orphan when its test dies early:"
  while IFS= read -r row; do
    printf '       %s\n' "${row%:UNGUARDED}"
  done <<<"$UNGUARDED"
fi

# ══════════════════════════════════════════════════════════════════════════════════
# (3) PROVE-DETECTS — the clean verdict above must be able to go red
# ══════════════════════════════════════════════════════════════════════════════════
# 3a. the one-line shape, unguarded.
mkfix "$WORK/mutant-oneline.test.sh" \
  '#!/usr/bin/env bash' \
  "CLI=\"\$ROOT/$CPBIN\"" \
  '"$CLI" serve --host 127.0.0.1 --port "$P1" >/dev/null 2>&1 &' \
  'SERVER_PID=$!'
v="$(scan "$WORK/mutant-oneline.test.sh")"
grep -q ':UNGUARDED$' <<<"$v" \
  && ok "(3a) PROVE-DETECTS: a one-line unguarded launcher is FLAGGED → case (2) is falsifiable" \
  || bad "(3a) PROVE-DETECTS: the detector missed a planted one-line unguarded launcher (got: '$v') — case (2) cannot fail"

# 3b. the CONTINUED shape — the one 15 of the 17 real launchers actually use. The `&` lands
#     three physical lines after the command starts, so a physical-line scanner sees a
#     redirection fragment and shrugs.
mkfix "$WORK/mutant-continued.test.sh" \
  '#!/usr/bin/env bash' \
  "CLI=\"\$REPO/$CPBIN\"" \
  'HEIMDALL_PUBLIC_SURFACE=1 "$CLI" serve --host 127.0.0.1 --port "$CP_PORT" --home "$HEIMDALL_HOME" \' \
  '  --no-revocation \' \
  '  >"$EXT/serve.out" 2>"$EXT/serve.err" &' \
  'SERVER_PID=$!'
v="$(scan "$WORK/mutant-continued.test.sh")"
grep -q ':UNGUARDED$' <<<"$v" \
  && ok "(3b) PROVE-DETECTS: a backslash-continued unguarded launcher is FLAGGED (the shape 15 of 17 use)" \
  || bad "(3b) PROVE-DETECTS: a continued launcher escaped the scan (got: '$v') — the real wiring is unpoliced"

# 3c. the guarded twin of 3b must come back clean, with the guard on the FIRST physical line
#     and the `&` on the LAST. If this reads UNGUARDED the gate is unsatisfiable and someone
#     will delete it rather than fix it.
mkfix "$WORK/clean-continued.test.sh" \
  '#!/usr/bin/env bash' \
  "CLI=\"\$REPO/$CPBIN\"" \
  'HMD_CP_GUARD_PID=$$ HEIMDALL_PUBLIC_SURFACE=1 "$CLI" serve --host 127.0.0.1 --port "$CP_PORT" \' \
  '  >"$EXT/serve.out" 2>"$EXT/serve.err" &' \
  'SERVER_PID=$!'
v="$(scan "$WORK/clean-continued.test.sh")"
if grep -q ':GUARDED$' <<<"$v"; then
  ok "(3c) a guarded continued launcher reads GUARDED — the guard is in scope for the whole logical command"
else
  bad "(3c) a correctly guarded launcher was flagged (got: '$v') — the gate is unsatisfiable as written"
fi

# 3d. a file-level export covers every launcher below it. Same claim, the other legal scope.
mkfix "$WORK/clean-fileexport.test.sh" \
  '#!/usr/bin/env bash' \
  "CLI=\"\$REPO/$CPBIN\"" \
  'export HMD_CP_GUARD_PID=$$' \
  '"$CLI" serve --host 127.0.0.1 --port "$A" >/dev/null 2>&1 &' \
  'A_PID=$!' \
  '"$CLI" serve --host 127.0.0.1 --port "$B" >/dev/null 2>&1 &' \
  'B_PID=$!'
v="$(scan "$WORK/clean-fileexport.test.sh")"
ng="$(grep -c ':GUARDED$' <<<"$v" || true)"
nu="$(grep -c ':UNGUARDED$' <<<"$v" || true)"
if [ "$nu" -eq 0 ] && [ "$ng" -eq 2 ]; then
  ok "(3d) a file-level export HMD_CP_GUARD_PID covers both launchers below it (2 GUARDED, 0 UNGUARDED)"
else
  bad "(3d) file-level export scope wrong — want 2 GUARDED / 0 UNGUARDED, got $ng / $nu (raw: '$v')"
fi

# ══════════════════════════════════════════════════════════════════════════════════
# (4) NO FALSE POSITIVES — the scan must stay narrow enough to be worth obeying
# ══════════════════════════════════════════════════════════════════════════════════
mkfix "$WORK/controls.test.sh" \
  '#!/usr/bin/env bash' \
  "QUEUE=\"\$ROOT/bin/heimdall-queue\"" \
  "CLI=\"\$ROOT/$CPBIN\"" \
  '"$QUEUE" serve --port 0 --portfile "$PORTFILE" >/dev/null 2>&1 &' \
  'SRV=$!' \
  '"$CLI" serve --host 127.0.0.1 --port "$P" --home "$H" >/dev/null 2>&1' \
  '"$CLI" identity --haid haid:cp-server >/dev/null 2>&1 &' \
  'ID_PID=$!' \
  'echo "bin/heimdall-control-plane serve is MISSING the watchdog"' \
  'ok "the REAL wired server (heimdall-control-plane serve) is live"'
v="$(scan "$WORK/controls.test.sh")"
if [ -z "$v" ]; then
  ok "(4) no false positives: another binary's serve, a FOREGROUND serve, a backgrounded non-serve subcommand and prose all ignored"
else
  bad "(4) FALSE POSITIVE — the scan flagged something that cannot orphan a control plane: '$v'"
fi

# a control on the control: the same file with ONE real unguarded launcher appended must flip
# to exactly one finding, so (4)'s silence is discrimination and not a dead scanner.
cp "$WORK/controls.test.sh" "$WORK/controls-plus.test.sh"
printf '%s\n' '"$CLI" serve --host 127.0.0.1 --port "$P2" >/dev/null 2>&1 &' >> "$WORK/controls-plus.test.sh"
v="$(scan "$WORK/controls-plus.test.sh")"
if [ "$(grep -c ':UNGUARDED$' <<<"$v" || true)" -eq 1 ]; then
  ok "(4) the same file plus ONE real unguarded launcher yields exactly one finding — (4) is discrimination, not a dead scanner"
else
  bad "(4) adding a real unguarded launcher did not yield exactly one finding (got: '$v') — (4)'s silence is vacuous"
fi

# ══════════════════════════════════════════════════════════════════════════════════
# (5) THE WIRING POINTS AT A LIVE CONSUMER
# ══════════════════════════════════════════════════════════════════════════════════
# Exporting HMD_CP_GUARD_PID is decoration unless the shipped emitter still reads it. This is
# the contract between the two halves; test/orphan-python-detection.test.sh owns proving the
# watchdog's behaviour once it is read.
if grep -q 'HMD_CP_GUARD_PID' "$CP"; then
  ok "(5) bin/heimdall-control-plane still reads HMD_CP_GUARD_PID — the launchers export something live"
else
  bad "(5) bin/heimdall-control-plane no longer reads HMD_CP_GUARD_PID — every launcher's export is now a no-op"
fi

echo
printf 'cp-serve-guard-wiring: %d passed, %d failed\n' "$P" "$F"
[ "$F" -eq 0 ]
