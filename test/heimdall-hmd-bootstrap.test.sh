#!/usr/bin/env bash
#
# heimdall-hmd-bootstrap.test.sh — proves the `hmd` first-run bootstrap completes
# in ONE invocation, non-interactively, is idempotent, and survives the two
# live-VM failure modes.
#
# THE BUGS THIS LOCKS DOWN:
#   ORIGINAL: on a fresh machine the launcher needed TWO `hmd` runs. Run 1 hit
#   `ensure_auth`, dropped into an interactive `claude login`, and `exit 1` aborted
#   the whole bootstrap BEFORE companion setup ran or the first-run marker was
#   written. Run 2 then blocked on the claude-mem `Ok to proceed? (y)` npm confirm.
#
#   LIVE-VM #1 (marker in a root-owned install dir): the repo was `sudo git
#   clone`'d (root-owned) and hmd runs as a normal user, so `touch
#   "$PLUGIN_DIR/.setup-done"` failed `Permission denied` → the marker never
#   landed → first-run setup re-ran forever. FIX: the marker lives in the
#   USER-writable home ($HEIMDALL_HOME | ~/.heimdall), NEVER the install dir; an
#   existing legacy marker is migrated so upgraded installs are not re-run.
#
#   LIVE-VM #2 (claude-mem interactive wizard + bun): `npx claude-mem install`
#   launches a multi-prompt wizard (email/IDE/runtime/provider/model) and needs
#   `bun`. Force-feeding `yes` still ran the wizard and aborted
#   `bun-missing-after-install`. FIX: attempt claude-mem ONLY when a real TTY AND
#   bun are both present; otherwise SKIP cleanly WITHOUT launching the installer.
#
# THE PROOFS HERE (all hermetic — `claude`/`npx`/`bun` are recording PATH fakes;
# claude-mem is absent so its branch runs; the launcher short-circuits at the
# `launch:task` trace marker before any real `claude … -p`; every run is under a
# watchdog so a re-introduced blocking prompt fails as a HANG, not a wedge):
#   1. FRESH first run — READ-ONLY install dir, unauthenticated, non-TTY — ONE
#      invocation installs companions, writes the marker to the USER home (NOT the
#      repo dir), and defers auth without aborting.
#   2. claude-mem is SKIPPED on a non-TTY box — the installer is NEVER invoked.
#   3. IDEMPOTENT re-run (same home) — companion setup does NOT re-run.
#   4. LEGACY-marker MIGRATION — an old repo-dir marker is honored as already-set-up.
#   5. claude-mem SKIPPED even when bun IS present but there is no TTY (the TTY is
#      required, not just bun).
#   6. claude-mem IS attempted when a real TTY (pty) AND bun are both present.
#
# HARNESS HERMETICITY — every scenario that must observe FIRST-RUN behaviour calls
# cold_install_state first, and every "X was NOT invoked" proof is paired with a
# POSITIVE CONTROL proving first-run setup actually ran in that same scenario. See
# cold_install_state below for the cross-scenario leak this defends against; the
# controls exist because a negative assertion is trivially satisfied by a launcher
# that did nothing at all — which is exactly how proof 6 sat red unnoticed.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
note(){ printf '  \033[33mNOTE\033[0m %s\n' "$1"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "FATAL: $1 not found on PATH"; exit 2; }; }
need git; need python3; need yes

[ -x "$REPO/bin/heimdall" ] || { echo "FATAL: bin/heimdall not executable"; exit 2; }

# ── Isolated plugin tree (the install dir; the marker must NOT land here) ──
# The copied launcher resolves its own PLUGIN_DIR from its location, so
# PLUGIN_DIR = $TPLUG. With the fix the first-run marker lands in $HEIMDALL_HOME,
# never $TPLUG — which is exactly what lets a READ-ONLY $TPLUG still complete setup.
TPLUG="$(mktemp -d)"
mkdir -p "$TPLUG/bin" "$TPLUG/.claude-plugin"
cp -R "$REPO/bin/." "$TPLUG/bin/"
[ -f "$REPO/.claude-plugin/plugin.json" ] && cp "$REPO/.claude-plugin/plugin.json" "$TPLUG/.claude-plugin/" 2>/dev/null || true
[ -f "$REPO/skills-registry.json" ] && cp "$REPO/skills-registry.json" "$TPLUG/" 2>/dev/null || true
LAUNCHER="$TPLUG/bin/heimdall"
chmod +x "$LAUNCHER" 2>/dev/null || true

# ── Recording fakes: every `claude` / `npx` invocation appends its argv to $CALLS ─
FAKE_DIR="$(mktemp -d)"
CALLS="$FAKE_DIR/calls.log"
: > "$CALLS"

# `claude` — records argv, prints NOTHING for `plugins list` / `marketplace list`
# (so the launcher's grep-guards miss → the install/add branches actually run),
# and exits 0 for everything (companion installs become instant recorded no-ops).
cat > "$FAKE_DIR/claude" <<EOF
#!/usr/bin/env bash
echo "claude \$*" >> "$CALLS"
exit 0
EOF

# `npx` — records argv, then reads one line of stdin with a hard timeout so the
# fake itself can NEVER hang the suite, and exits 0. It is only ever reached when
# the launcher's TTY+bun gate has ALREADY decided claude-mem may be attempted.
cat > "$FAKE_DIR/npx" <<EOF
#!/usr/bin/env bash
echo "npx \$*" >> "$CALLS"
reply=""
if IFS= read -r -t 5 reply; then
  echo "npx-stdin:\$reply" >> "$CALLS"
else
  echo "npx-stdin:NONE" >> "$CALLS"
fi
exit 0
EOF
chmod +x "$FAKE_DIR/claude" "$FAKE_DIR/npx"
# NOTE: NO `claude-mem` fake ⇒ `command -v claude-mem` fails ⇒ the claude-mem
# branch (the step under test) runs.

# `bun` fake lives in its OWN dir so PATH can include or EXCLUDE it independently —
# that is how we flip the "bun present / absent" half of the claude-mem gate.
BUN_DIR="$(mktemp -d)"
cat > "$BUN_DIR/bun" <<EOF
#!/usr/bin/env bash
echo "bun \$*" >> "$CALLS"
exit 0
EOF
chmod +x "$BUN_DIR/bun"

# PATH: fakes FIRST, then the real dirs holding python3 + git + coreutils. No real
# claude/npx/claude-mem/bun is reachable. PATH_NOBUN omits bun; PATH_BUN prepends it.
SYS="$(dirname "$(command -v python3)"):$(dirname "$(command -v git)"):/usr/bin:/bin"
PATH_NOBUN="$FAKE_DIR:$SYS"
PATH_BUN="$BUN_DIR:$FAKE_DIR:$SYS"

trap 'chmod -R u+w "$TPLUG" 2>/dev/null || true; rm -rf "$TPLUG" "$FAKE_DIR" "$BUN_DIR" 2>/dev/null || true' EXIT

# cold_install_state — return the INSTALL DIR to a genuine never-set-up state.
#
# WHY THIS EXISTS (the cross-scenario leak that silently red-lined proof 6): a
# fresh $HEIMDALL_HOME is NOT sufficient to get first-run behaviour, because setup
# state is ALSO reachable from the install dir. `_write_setup_marker`
# (bin/heimdall:52) drops a convenience copy of the marker at the LEGACY path
# $PLUGIN_DIR/.setup-done, and startup MIGRATES any existing legacy marker into a
# fresh $HEIMDALL_HOME (bin/heimdall:70-72). So the moment ONE scenario completes
# first-run setup against a WRITABLE $TPLUG, every later scenario is treated as
# already-set-up: first_run_setup returns immediately (bin/heimdall:579) and the
# companion/claude-mem code under test never executes — the run "passes" by doing
# nothing. Scenario 1 dodged this only because $TPLUG was read-only at the time.
# Any scenario asserting FIRST-RUN behaviour must call this first.
cold_install_state() { rm -f "$TPLUG/.setup-done"; }

# run_launcher MODE WORKDIR HEIMDALL_HOME STDOUT_CAPTURE PATH — drive the launcher's
# first-run path UNAUTHENTICATED (no ANTHROPIC_API_KEY, a fresh empty HOME so
# heimdall_is_authed is false). HEIMDALL_TRACE_ORDER short-circuits before the real
# `claude … -p`. MODE=notty runs backgrounded with stdin </dev/null (an unguarded
# prompt would hang); MODE=tty runs under `script`, which allocates a pty so the
# launcher sees [ -t 0 ] && [ -t 1 ] TRUE. Both run under a watchdog: prints
# "HANG" and returns 124 if the launcher does not finish.
#
# WATCHDOG BUDGET: the hazard being guarded is an UNBOUNDED interactive read (a
# re-introduced `Ok to proceed? (y)`-style prompt), which never returns at all —
# so the bound only has to be comfortably above a slow-but-progressing run, and
# generous is strictly safer than tight. 30s was too tight: a full first-run pass
# measured 40s (non-TTY) / 31s (pty) on a dev box running other suites in
# parallel, which surfaced as spurious "BLOCKED/hung" failures on scenarios that
# had in fact completed. 120s is ~3x the measured worst case and still fails fast
# and decisively on a genuine blocking prompt.
run_launcher() {
  local mode="$1" wd="$2" hh="$3" out="$4" path="$5" trace; trace="$(mktemp)"
  local pid
  if [ "$mode" = "tty" ]; then
    local runner="$FAKE_DIR/pty-runner.sh"
    cat > "$runner" <<RUN
#!/usr/bin/env bash
exec env -i HOME="$(dirname "$hh")" TERM="dumb" PATH="$path" \
  HEIMDALL_HOME="$hh" HEIMDALL_NO_INTRO=1 HEIMDALL_NO_REUSE_METRIC=1 \
  HEIMDALL_TRACE_ORDER="$trace" \
  bash -c "cd '$wd' && exec '$LAUNCHER' 'noop bootstrap probe'"
RUN
    chmod +x "$runner"
    script -q /dev/null "$runner" </dev/null >"$out" 2>&1 &
    pid=$!
  else
    env -i HOME="$(dirname "$hh")" TERM="dumb" PATH="$path" \
      HEIMDALL_HOME="$hh" HEIMDALL_NO_INTRO=1 HEIMDALL_NO_REUSE_METRIC=1 \
      HEIMDALL_TRACE_ORDER="$trace" \
      bash -c "cd '$wd' && exec '$LAUNCHER' 'noop bootstrap probe'" \
      </dev/null >"$out" 2>&1 &
    pid=$!
  fi
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    waited=$((waited + 1))
    if [ "$waited" -ge 600 ]; then   # 600 * 0.2s = 120s (see WATCHDOG BUDGET above)
      kill -9 "$pid" 2>/dev/null || true
      rm -f "$trace" 2>/dev/null || true
      echo "HANG"
      return 124
    fi
  done
  wait "$pid"; local rc=$?
  rm -f "$trace" 2>/dev/null || true
  return $rc
}

echo "hmd-bootstrap harness  repo=$REPO"
echo "--------------------------------------------------------------------"

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ 1. FRESH FIRST RUN — READ-ONLY install dir, UNAUTHENTICATED, non-TTY.      ║
# ║    ONE invocation completes setup and writes the marker to the USER home.  ║
# ╚══════════════════════════════════════════════════════════════════════════╝
WD1="$(mktemp -d)"; HOME1="$(mktemp -d)"; HH1="$HOME1/.heimdall"
cold_install_state                          # genuine cold first run (no legacy marker)
chmod -R a-w "$TPLUG"                       # SIMULATE a root-owned / read-only install dir
OUT1="$FAKE_DIR/run1.out"
: > "$CALLS"
HANG1="$(run_launcher notty "$WD1" "$HH1" "$OUT1" "$PATH_NOBUN")"; RC1=$?

if [ "$RC1" -eq 124 ] || [ "$HANG1" = "HANG" ]; then
  bad "fresh run BLOCKED/hung on a READ-ONLY install dir"
else
  ok "fresh run completed in ONE invocation on a READ-ONLY install dir (exit $RC1)"
fi

# 1a. The marker was written to the USER home — NOT the (read-only) install dir.
[ -f "$HH1/setup-done" ] \
  && ok "marker written to the USER home (\$HEIMDALL_HOME/setup-done)" \
  || bad "marker NOT written to \$HEIMDALL_HOME (out: $(tr '\n' ' ' < "$OUT1" | tail -c 200))"
[ ! -f "$TPLUG/.setup-done" ] \
  && ok "marker NOT written into the install/repo dir (never touches PLUGIN_DIR)" \
  || bad "marker leaked into the install dir (\$PLUGIN_DIR/.setup-done)"

chmod -R u+w "$TPLUG"                        # restore write for the remaining scenarios

# 1b. Companion plugins installed — the fakes recorded each install call.
# caveman is IN-HOUSE (bin/heimdall-caveman) since 2026-08-30 — hmd must NOT
# call out to the external plugin for it any more (CLAUDE.md "Token
# Efficiency"); this is the negative/red-proof half of that removal. See
# heimdall-caveman-no-plugin.test.sh for the dedicated present-vs-absent proof.
if grep -q 'plugins install caveman@caveman\|marketplace add JuliusBrussee/caveman' "$CALLS"; then
  bad "companion: caveman plugin install/marketplace-add call still present (calls: $(tr '\n' ';' < "$CALLS"))"
else
  ok "companion: caveman plugin NOT installed (ownership is in-house)"
fi
grep -q 'claude plugins install superpowers' "$CALLS" \
  && ok "companion: superpowers install recorded" \
  || bad "companion: superpowers install NOT recorded"
grep -q 'claude plugins marketplace add randomittin/heimdall-marketplace' "$CALLS" \
  && ok "companion: heimdall marketplace add recorded" \
  || bad "companion: heimdall marketplace add NOT recorded"

# 1c. Deferred-auth: a clear, headless-friendly sign-in instruction printed, and it
#     did NOT abort setup (proven by the marker + companions above in the same run).
grep -q 'Not signed in to Claude Code' "$OUT1" \
  && ok "deferred-auth: clear 'not signed in' instruction printed" \
  || bad "deferred-auth: sign-in instruction missing"
grep -qi 'Running claude login' "$OUT1" \
  && bad "deferred-auth: still ran interactive 'claude login' (must NOT)" \
  || ok "deferred-auth: did NOT drop into interactive 'claude login'"

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ 2. claude-mem SKIPPED on a non-TTY box — the installer is NEVER invoked.   ║
# ╚══════════════════════════════════════════════════════════════════════════╝
if grep -q 'claude-mem' "$CALLS"; then
  bad "claude-mem installer was INVOKED on a non-TTY box (calls: $(grep -i 'npx\|claude-mem' "$CALLS" | tr '\n' ';'))"
else
  ok "claude-mem installer NOT invoked on a non-TTY box (zero claude-mem calls)"
fi
grep -q "optional companion — skipped" "$OUT1" \
  && ok "claude-mem: graceful one-line skip note printed (never fatal)" \
  || bad "claude-mem: skip note missing (out: $(tr '\n' ' ' < "$OUT1" | tail -c 200))"

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ 3. IDEMPOTENT RE-RUN — SAME home ⇒ companion setup does NOT re-run.        ║
# ╚══════════════════════════════════════════════════════════════════════════╝
WD2="$(mktemp -d)"
OUT2="$FAKE_DIR/run2.out"
: > "$CALLS"
HANG2="$(run_launcher notty "$WD2" "$HH1" "$OUT2" "$PATH_NOBUN")"; RC2=$?  # SAME HH1

if [ "$RC2" -eq 124 ] || [ "$HANG2" = "HANG" ]; then
  bad "re-run BLOCKED/hung"
else
  ok "re-run completed without blocking (exit $RC2)"
fi
if grep -q 'plugins install caveman\|claude-mem' "$CALLS"; then
  bad "re-run RE-TRIGGERED companion setup (calls: $(tr '\n' ';' < "$CALLS"))"
else
  ok "re-run did NOT re-run companion setup (idempotent, marker-gated on the user home)"
fi
[ -f "$HH1/setup-done" ] \
  && ok "re-run left the user-home marker intact" \
  || bad "re-run lost the user-home marker"

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ 4. LEGACY-marker MIGRATION — old repo-dir marker ⇒ treated as set-up.      ║
# ╚══════════════════════════════════════════════════════════════════════════╝
WD3="$(mktemp -d)"; HOME3="$(mktemp -d)"; HH3="$HOME3/.heimdall"
: > "$TPLUG/.setup-done"                     # OLD marker present in the install dir
[ ! -f "$HH3/setup-done" ] || rm -f "$HH3/setup-done"   # fresh user home (no new marker)
OUT3="$FAKE_DIR/run3.out"
: > "$CALLS"
HANG3="$(run_launcher notty "$WD3" "$HH3" "$OUT3" "$PATH_NOBUN")"; RC3=$?

if [ "$RC3" -eq 124 ] || [ "$HANG3" = "HANG" ]; then
  bad "migration run BLOCKED/hung"
else
  ok "migration run completed without blocking (exit $RC3)"
fi
if grep -q 'plugins install caveman\|claude-mem' "$CALLS"; then
  bad "migration: companion setup RE-RAN (legacy marker not honored) (calls: $(tr '\n' ';' < "$CALLS"))"
else
  ok "migration: legacy repo-dir marker honored — companion setup did NOT re-run"
fi
[ -f "$HH3/setup-done" ] \
  && ok "migration: user-home marker written from the legacy marker" \
  || bad "migration: user-home marker NOT written"
cold_install_state

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ 5. claude-mem SKIPPED with bun PRESENT but NO TTY (the TTY is required).   ║
# ╚══════════════════════════════════════════════════════════════════════════╝
WD4="$(mktemp -d)"; HOME4="$(mktemp -d)"; HH4="$HOME4/.heimdall"
cold_install_state                           # scenario 4 set up an install — start cold again
OUT4="$FAKE_DIR/run4.out"
: > "$CALLS"
HANG4="$(run_launcher notty "$WD4" "$HH4" "$OUT4" "$PATH_BUN")"; RC4=$?  # bun ON path, non-TTY

if [ "$RC4" -eq 124 ] || [ "$HANG4" = "HANG" ]; then
  bad "bun-present non-TTY run BLOCKED/hung"
else
  ok "bun-present non-TTY run completed (exit $RC4)"
fi
# POSITIVE CONTROL — the skip proof below is a NEGATIVE assertion, so it is
# satisfied just as well by a launcher that short-circuited and did nothing. Prove
# this run genuinely entered first-run setup before trusting the absence.
grep -q 'claude plugins install superpowers' "$CALLS" \
  && ok "bun-present non-TTY run genuinely entered first-run setup (skip proof is not vacuous)" \
  || bad "bun-present non-TTY run never entered first-run setup — skip proof would be VACUOUS (calls: $(tr '\n' ';' < "$CALLS"))"
if grep -q 'claude-mem' "$CALLS"; then
  bad "claude-mem invoked with bun present but NO TTY (TTY must be required too)"
else
  ok "claude-mem SKIPPED with bun present but no TTY — TTY is required, not just bun"
fi

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ 6. claude-mem ATTEMPTED when a real TTY (pty) AND bun are both present.    ║
# ╚══════════════════════════════════════════════════════════════════════════╝
if ! command -v script >/dev/null 2>&1; then
  note "TTY case skipped — 'script' (pty allocator) not on PATH"
else
  WD5="$(mktemp -d)"; HOME5="$(mktemp -d)"; HH5="$HOME5/.heimdall"
  cold_install_state                         # scenario 5 set up an install — start cold again
  OUT5="$FAKE_DIR/run5.out"
  : > "$CALLS"
  HANG5="$(run_launcher tty "$WD5" "$HH5" "$OUT5" "$PATH_BUN")"; RC5=$?  # bun + pty

  if [ "$HANG5" = "HANG" ] || [ "$RC5" -eq 124 ]; then
    bad "TTY+bun run BLOCKED/hung"
  else
    ok "TTY+bun run completed without blocking (exit $RC5)"
  fi
  # POSITIVE CONTROL — same reasoning as scenario 5, and this is the exact assertion
  # that was silently red: a short-circuited launcher records NOTHING, so "no npx
  # call" looked like a claude-mem regression when the run had simply never reached
  # first-run setup at all. Fail loudly on that distinction instead of conflating it.
  grep -q 'claude plugins install superpowers' "$CALLS" \
    && ok "TTY+bun run genuinely entered first-run setup (claude-mem proof is not vacuous)" \
    || bad "TTY+bun run never entered first-run setup — claude-mem proof would be VACUOUS (calls: $(tr '\n' ';' < "$CALLS"))"
  if grep -q 'npx --yes claude-mem install' "$CALLS"; then
    ok "claude-mem ATTEMPTED (npx --yes claude-mem install) when TTY + bun both present"
  else
    bad "claude-mem NOT attempted despite TTY + bun (calls: $(grep -i 'npx\|bun\|claude-mem' "$CALLS" | tr '\n' ';'))"
  fi
fi

echo "--------------------------------------------------------------------"
printf 'hmd-bootstrap: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
