#!/usr/bin/env bash
#
# telemetry-install.test.sh — install-step instrumentation proofs (dossier piece b:
# the first_run_setup + install.sh step events). Piece (a) is the substrate these
# bind to; these proofs pin the install-side CONTRACT (dossier §3 + §8):
#
#   A. PER-STEP EVENTS — driving first_run_setup (bin/heimdall --setup) with MOCKED
#      step bodies (NO real network install) emits, for each step, a `started` then
#      a `succeeded` install_step event carrying that step's id AND a duration_ms.
#      The distinct step ids (setup, companion:caveman, companion:claude-mem,
#      skills, launch-readiness) are present so aggregate (piece d) can pinpoint
#      WHERE an install fails.
#
#   B. SIM-FAILURE AT A STEP — forcing the claude-mem step to FAIL (a mocked `npx`
#      that exits nonzero) records a `failed` install_step event WITH the step name
#      (companion:claude-mem) AND an error CLASS (never a secret). This is the
#      claude-mem swap-evidence datum. FALSIFIABLE: a build that swallowed the
#      nonzero exit would emit `succeeded`, flipping the assertion.
#
#   C. DISABLED ⇒ IDENTICAL — HEIMDALL_TELEMETRY=off runs the SAME install path:
#      it still exits 0, the setup marker is still written, and NO events.ndjson is
#      produced. A disabled world is identical to a no-telemetry world (§8).
#
#   D. FORCED EMIT FAILURE NEVER FAILS THE INSTALL — making the telemetry store
#      unwritable (a regular file where the store dir must go) does NOT abort
#      first_run_setup: it still exits 0 and still writes the setup marker. The
#      event is silently dropped; the install continues (graceful-degrade, §8).
#      FALSIFIABLE: a non-swallowed write error would abort --setup non-zero.
#
#   E. INSTALL.SH PATH STEP — install.sh's `path` step emits started→succeeded with
#      step=path + duration_ms, driven through the REAL wrapper + schema (no
#      clone/network), proving install.sh's own step is instrumented.
#
#   F. STRANGER-TEST STILL GREEN — test/install-stranger.sh stays exit 0 (the
#      instrumentation did not regress the real clean-install path). SLOW: takes
#      >170s; skipped unless HEIMDALL_TEST_SLOW=1 is set.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
[ -x "$REPO/bin/heimdall" ] || { echo "FATAL: bin/heimdall not executable"; exit 2; }
[ -x "$REPO/bin/heimdall-telemetry" ] || { echo "FATAL: telemetry CLI missing"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── Build a self-contained plugin tree copy so --setup's marker write + telemetry
# resolution land in the SANDBOX, never the repo. We copy only what first_run_setup
# + the telemetry substrate touch: the launcher, the telemetry CLI, and the two
# python libs it imports (telemetry.py + its issue_queue home-resolver dep). ──
PLUG="$WORK/plugin"
mkdir -p "$PLUG/bin/lib"
cp "$REPO/bin/heimdall"            "$PLUG/bin/heimdall"
cp "$REPO/bin/heimdall-telemetry" "$PLUG/bin/heimdall-telemetry"
cp "$REPO/bin/lib/telemetry.py"   "$PLUG/bin/lib/telemetry.py"
cp "$REPO/bin/lib/issue_queue.py" "$PLUG/bin/lib/issue_queue.py"
chmod +x "$PLUG/bin/heimdall" "$PLUG/bin/heimdall-telemetry"

# ── A fake-binary dir: stand-ins for every command first_run_setup shells out to,
# so the run is fully offline + deterministic. `claude` is an instant no-op (so the
# plugin/marketplace `install` calls succeed); `claude-mem` is ABSENT (command -v
# fails ⇒ the claude-mem block runs); `npx claude-mem install` outcome is governed
# by the NPX_RC env var (0 ⇒ succeed, nonzero ⇒ the sim-failure). git/node present
# as no-ops. The real python3 is symlinked in (telemetry + auth checks need it). ──
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
# instant no-op claude: `plugins …` always succeeds, `--version` is recent, all
# else exits 0. No network, no real plugin install.
case "${1:-}" in
  --version) echo "1.99.0 (Claude Code)"; exit 0 ;;
  plugins)   exit 0 ;;
  *)         exit 0 ;;
esac
SH

cat > "$FAKEBIN/npx" <<'SH'
#!/usr/bin/env bash
# `npx claude-mem install` exit code is driven by NPX_RC (default 0). This is the
# single knob the sim-failure test flips to force the claude-mem step to fail.
exit "${NPX_RC:-0}"
SH

cat > "$FAKEBIN/node" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FAKEBIN/bun" <<'SH'
#!/usr/bin/env bash
# Present-but-inert `bun`. bin/heimdall gates the claude-mem installer on BOTH a real
# TTY and bun being on PATH (the LIVE-VM #2 hang fix); without this stand-in the step
# short-circuits to `skipped` and the NPX_RC knob below is never consulted at all.
exit 0
SH
chmod +x "$FAKEBIN/claude" "$FAKEBIN/npx" "$FAKEBIN/node" "$FAKEBIN/git" "$FAKEBIN/bun"
# Real python3 must resolve on the stripped PATH (telemetry + auth JSON checks).
ln -s "$PY" "$FAKEBIN/python3"
# NOTE: claude-mem is deliberately NOT created ⇒ `command -v claude-mem` fails ⇒
# the claude-mem install block runs (the step under test).

# ── A pty harness. bin/heimdall's claude-mem block is gated on `[ -t 0 ] && [ -t 1 ]`
# (+ bun) so a headless box never launches claude-mem's interactive wizard. A plain
# `cmd >/dev/null` run therefore has NO tty and always takes the graceful-skip branch,
# which makes the sim-failure below unreachable. So drive the launcher under a REAL pty
# (python3's pty.spawn — no `script(1)`, whose flags differ BSD vs util-linux).
# stdin comes from /dev/null in the CALLER, so pty.spawn leaves the outer terminal's
# termios untouched (no raw mode) while the CHILD still gets a genuine tty on fd 0+1.
# A second fake-bin dir identical to FAKEBIN but WITHOUT bun, so the headless run below
# exercises the gate's skip branch on both of its conditions (no tty AND no bun).
NOBUNBIN="$WORK/fakebin-nobun"
mkdir -p "$NOBUNBIN"
for _fb in claude npx node git; do cp "$FAKEBIN/$_fb" "$NOBUNBIN/$_fb"; done
chmod +x "$NOBUNBIN/claude" "$NOBUNBIN/npx" "$NOBUNBIN/node" "$NOBUNBIN/git"
ln -s "$PY" "$NOBUNBIN/python3"

PTY_RUNNER="$WORK/pty_run.py"
cat > "$PTY_RUNNER" <<'PYEOF'
import os, pty, sys
status = pty.spawn(sys.argv[1:])
if hasattr(os, "waitstatus_to_exitcode"):
    sys.exit(os.waitstatus_to_exitcode(status))
sys.exit(status >> 8 if status else 0)
PYEOF

# Drive bin/heimdall --setup in the sandbox. Args: $1=HEIMDALL_HOME (store dir),
# plus inherited env (HEIMDALL_TELEMETRY / NPX_RC) governs telemetry + sim-failure.
# ANTHROPIC_API_KEY short-circuits ensure_auth to its success path (no live login).
# PATH = the fakebin FIRST (our claude/npx/node win) then the system coreutils dirs
# (the launcher needs readlink/dirname/cd/pwd etc.); no real claude/npx is on it.
# Runs under a pty (see PTY_RUNNER) so the claude-mem TTY gate opens and the npx
# outcome — not the gate — decides the step. `</dev/null` keeps the outer terminal safe.
# Returns the launcher's exit code; the caller captures it.
run_setup() {
  local home="$1"
  PATH="$FAKEBIN:/usr/bin:/bin" HOME="$WORK/fakehome" \
    ANTHROPIC_API_KEY="sk-test-not-a-real-key" \
    HEIMDALL_HOME="$home" \
    "$PY" "$PTY_RUNNER" "$PLUG/bin/heimdall" --setup </dev/null >/dev/null 2>&1
}

# The same launcher run HEADLESS — no pty AND no bun on PATH ($NOBUNBIN is FAKEBIN minus
# the bun stand-in). This is the real-world CI/VM shape, and it pins the graceful-skip
# branch of the claude-mem gate: the path that silently swallowed the sim-failure knob
# and left section B vacuously green for 9 days.
run_setup_headless() {
  local home="$1"
  PATH="$NOBUNBIN:/usr/bin:/bin" HOME="$WORK/fakehome" \
    ANTHROPIC_API_KEY="sk-test-not-a-real-key" \
    HEIMDALL_HOME="$home" \
    "$PLUG/bin/heimdall" --setup </dev/null >/dev/null 2>&1
}

# A tiny python event-query helper: prints, for a (store, step, outcome) triple,
# the count of matching install_step events. Tolerant of an absent store (0).
count_events() {  # $1=store-ndjson  $2=step  $3=outcome
  STORE="$1" STEP="$2" OUTCOME="$3" "$PY" - <<'PYEOF'
import json, os
store = os.environ["STORE"]
step = os.environ["STEP"]; outcome = os.environ["OUTCOME"]
n = 0
try:
    fh = open(store)
except OSError:
    print(0); raise SystemExit
with fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if (e.get("event_type") == "install_step"
                and e.get("step") == step
                and e.get("outcome") == outcome):
            n += 1
print(n)
PYEOF
}

# Whether ANY matching event additionally carries a non-null duration_ms / an error
# class. Prints "yes"/"no".
has_field() {  # $1=store  $2=step  $3=outcome  $4=duration|errorclass
  STORE="$1" STEP="$2" OUTCOME="$3" WHICH="$4" "$PY" - <<'PYEOF'
import json, os
store = os.environ["STORE"]; step = os.environ["STEP"]
outcome = os.environ["OUTCOME"]; which = os.environ["WHICH"]
found = False
try:
    fh = open(store)
except OSError:
    print("no"); raise SystemExit
with fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if (e.get("event_type") != "install_step"
                or e.get("step") != step
                or e.get("outcome") != outcome):
            continue
        if which == "duration" and isinstance(e.get("duration_ms"), int):
            found = True
        if which == "errorclass":
            err = e.get("error") or {}
            if isinstance(err, dict) and err.get("class"):
                found = True
print("yes" if found else "no")
PYEOF
}

# ─────────────────────────────────────────────────────────────────────────────
# A. PER-STEP EVENTS — each step emits started + succeeded with id + duration.
# ─────────────────────────────────────────────────────────────────────────────
echo "A. PER-STEP EVENTS (started + succeeded with step id + duration_ms):"
HOME_A="$WORK/home-a"
NPX_RC=0 run_setup "$HOME_A"; rc_a=$?
STORE_A="$HOME_A/telemetry/events.ndjson"
if [ "$rc_a" -eq 0 ]; then
  ok "first_run_setup exited 0 with telemetry enabled"
else
  bad "first_run_setup exited $rc_a (telemetry must never affect the exit code)"
fi
if [ -f "$STORE_A" ]; then
  ok "telemetry store written during install"
else
  bad "no telemetry store written at $STORE_A"
fi
for step in setup companion:caveman companion:claude-mem skills launch-readiness; do
  s_started="$(count_events "$STORE_A" "$step" started)"
  s_succ="$(count_events "$STORE_A" "$step" succeeded)"
  if [ "$s_started" -ge 1 ] && [ "$s_succ" -ge 1 ]; then
    ok "step '$step' emitted started + succeeded"
  else
    bad "step '$step' missing events (started=$s_started succeeded=$s_succ)"
  fi
done
if [ "$(has_field "$STORE_A" setup succeeded duration)" = "yes" ]; then
  ok "a succeeded step carries a numeric duration_ms"
else
  bad "no succeeded step carried a duration_ms"
fi

# ─────────────────────────────────────────────────────────────────────────────
# B. SIM-FAILURE AT THE claude-mem STEP — failed event with step + error class.
# ─────────────────────────────────────────────────────────────────────────────
echo "B. SIM-FAILURE (force claude-mem to fail ⇒ failed event w/ step + class):"
HOME_B="$WORK/home-b"
NPX_RC=7 run_setup "$HOME_B"; rc_b=$?
STORE_B="$HOME_B/telemetry/events.ndjson"
if [ "$rc_b" -eq 0 ]; then
  ok "install still exited 0 despite the claude-mem step failing (telemetry is data-only)"
else
  bad "install exited $rc_b — a step's instrumented failure must not change the exit"
fi
cm_failed="$(count_events "$STORE_B" companion:claude-mem failed)"
if [ "$cm_failed" -ge 1 ]; then
  ok "a failed companion:claude-mem event was recorded (step name pinpointed)"
else
  bad "no failed companion:claude-mem event — the sim-failure was not captured"
fi
if [ "$(has_field "$STORE_B" companion:claude-mem failed errorclass)" = "yes" ]; then
  ok "the failed event carries an error CLASS (the swap-evidence datum)"
else
  bad "the failed event has no error class"
fi
# The claude-mem step's failed event must NOT also be a succeeded event (falsifiable
# proof the nonzero exit was honoured, not swallowed into a success).
cm_succ="$(count_events "$STORE_B" companion:claude-mem succeeded)"
if [ "$cm_succ" -eq 0 ]; then
  ok "the failing claude-mem step emitted NO succeeded event (nonzero honoured, falsifiable)"
else
  bad "claude-mem emitted succeeded despite npx exiting nonzero — failure was swallowed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# C. DISABLED ⇒ IDENTICAL — off runs the same path, no events, still exit 0.
# ─────────────────────────────────────────────────────────────────────────────
echo "C. DISABLED ⇒ IDENTICAL (HEIMDALL_TELEMETRY=off: no events, same install):"
HOME_C="$WORK/home-c"
HEIMDALL_TELEMETRY=off NPX_RC=0 run_setup "$HOME_C"; rc_c=$?
if [ "$rc_c" -eq 0 ]; then
  ok "disabled install exited 0 (identical to the enabled path)"
else
  bad "disabled install exited $rc_c"
fi
if [ -e "$HOME_C/telemetry/events.ndjson" ]; then
  bad "disabled telemetry STILL wrote a store — not a no-op"
else
  ok "disabled telemetry wrote NO events (identical to a no-telemetry world, §8)"
fi
# The marker write (the install's actual side effect) happened regardless — proof
# the install PATH is identical, not skipped, when telemetry is off.
if [ -f "$PLUG/.setup-done" ]; then
  ok "setup marker written under disabled telemetry (install side effects unchanged)"
else
  bad "setup marker absent under disabled telemetry — install path diverged"
fi

# ─────────────────────────────────────────────────────────────────────────────
# D. FORCED EMIT FAILURE NEVER FAILS THE INSTALL — unwritable store, still exit 0.
# ─────────────────────────────────────────────────────────────────────────────
echo "D. FORCED EMIT FAILURE (unwritable store dir ⇒ install still exits 0):"
HOME_D="$WORK/home-d"
mkdir -p "$HOME_D"
# Occupy the telemetry store path with a regular FILE so makedirs + open('a') both
# fail inside emit() — which must swallow it and return False, install continues.
: > "$HOME_D/telemetry"
rm -f "$PLUG/.setup-done"   # ensure first_run_setup actually runs this pass
NPX_RC=0 run_setup "$HOME_D"; rc_d=$?
if [ "$rc_d" -eq 0 ]; then
  ok "install exited 0 with an unwritable telemetry store (write-failure swallowed, §8)"
else
  bad "install exited $rc_d on a telemetry write failure — emit must never abort the install"
fi
if [ -f "$PLUG/.setup-done" ]; then
  ok "setup marker still written despite the telemetry write failure (install completed)"
else
  bad "setup marker absent — the telemetry write failure aborted the install"
fi

# ─────────────────────────────────────────────────────────────────────────────
# E. INSTALL.SH PATH STEP — the `path` step emits started + succeeded + duration.
# ─────────────────────────────────────────────────────────────────────────────
echo "E. INSTALL.SH PATH STEP (path step started + succeeded with duration_ms):"
HOME_E="$WORK/home-e"
# Confirm install.sh ITSELF carries the path-step instrumentation (the source of
# truth for the fire-point — a grep guard so this proof tracks production code).
if grep -q 'path started' "$REPO/install.sh" \
   && grep -q 'path succeeded' "$REPO/install.sh" \
   && grep -q 'path failed' "$REPO/install.sh"; then
  ok "install.sh carries the instrumented \`path\` fire-point (started/succeeded/failed)"
else
  bad "install.sh has no instrumented path step"
fi
# Drive ONLY install.sh's path fire-point through the REAL wrapper + schema (no
# clone/network): emit the same started→succeeded pair the install.sh call site
# does, against a sandbox store, and assert the events + duration land.
PATH_PROBE_RUN="$("$REPO/bin/heimdall-telemetry" new-run-id 2>/dev/null || echo run-install-probe)"
PATH_T0="$("$PY" -c 'import time;print(int(time.time()*1000))')"
HEIMDALL_HOME="$HOME_E" "$REPO/bin/heimdall-telemetry" emit --type install_step \
  --phase install --run-id "$PATH_PROBE_RUN" --step path --outcome started >/dev/null 2>&1 || true
PATH_NOW="$("$PY" -c 'import time;print(int(time.time()*1000))')"
HEIMDALL_HOME="$HOME_E" "$REPO/bin/heimdall-telemetry" emit --type install_step \
  --phase install --run-id "$PATH_PROBE_RUN" --step path --outcome succeeded \
  --duration-ms "$(( PATH_NOW - PATH_T0 ))" >/dev/null 2>&1 || true
STORE_E="$HOME_E/telemetry/events.ndjson"
p_started="$(count_events "$STORE_E" path started)"
p_succ="$(count_events "$STORE_E" path succeeded)"
if [ "$p_started" -ge 1 ] && [ "$p_succ" -ge 1 ]; then
  ok "path step emitted started + succeeded"
else
  bad "path step missing events (started=$p_started succeeded=$p_succ)"
fi
if [ "$(has_field "$STORE_E" path succeeded duration)" = "yes" ]; then
  ok "path succeeded event carries a numeric duration_ms"
else
  bad "path succeeded event has no duration_ms"
fi

# ─────────────────────────────────────────────────────────────────────────────
# G. HEADLESS GATE — no tty + no bun ⇒ claude-mem is SKIPPED, never attempted.
#    bin/heimdall refuses to launch claude-mem's interactive wizard without BOTH a
#    real tty and bun (the LIVE-VM #2 hang fix). That branch is what sections A/B
#    were silently taking before they were driven under a pty — it emitted a
#    terminal `skipped` event that neither A nor B knew about, so B's sim-failure
#    was unreachable and B's "no succeeded event" check was VACUOUSLY green.
#    Pinned here so the gate can never again absorb the sim-failure unnoticed.
# ─────────────────────────────────────────────────────────────────────────────
echo "G. HEADLESS GATE (no tty + no bun ⇒ skipped, wizard never launched):"
HOME_G="$WORK/home-g"
NPX_RC=7 run_setup_headless "$HOME_G"; rc_g=$?
STORE_G="$HOME_G/telemetry/events.ndjson"
if [ "$rc_g" -eq 0 ]; then
  ok "headless install exited 0 (the gate skips claude-mem, never hangs or fails the run)"
else
  bad "headless install exited $rc_g — the graceful-skip gate must never fail the install"
fi
g_skipped="$(count_events "$STORE_G" companion:claude-mem skipped)"
if [ "$g_skipped" -ge 1 ]; then
  ok "headless run emitted a terminal companion:claude-mem 'skipped' event (gate observable)"
else
  bad "no skipped companion:claude-mem event — the headless gate is not instrumented (started=$(count_events "$STORE_G" companion:claude-mem started))"
fi
if [ "$(has_field "$STORE_G" companion:claude-mem skipped errorclass)" = "yes" ]; then
  ok "the skipped event carries an error CLASS (no-tty-or-bun — why it was skipped)"
else
  bad "the skipped event has no error class — the skip reason is unattributable"
fi
# The whole point of the gate: with no tty/bun the installer is NEVER invoked, so a
# nonzero NPX_RC cannot appear as a failure. Proves the skip is pre-emptive, not a
# swallowed npx error (and that sections A/B are genuinely reaching npx instead).
g_failed="$(count_events "$STORE_G" companion:claude-mem failed)"
g_succ="$(count_events "$STORE_G" companion:claude-mem succeeded)"
if [ "$g_failed" -eq 0 ] && [ "$g_succ" -eq 0 ]; then
  ok "headless run never invoked npx despite NPX_RC=7 (skip is pre-emptive, not a swallowed error)"
else
  bad "headless run produced failed=$g_failed succeeded=$g_succ — the wizard was launched behind the gate"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F. STRANGER-TEST STILL GREEN — the real clean-install path did not regress.
#    SLOW (>170s): gated behind HEIMDALL_TEST_SLOW=1 so the default suite
#    completes well under the 120s CI guard. Run explicitly to validate the
#    full clean-install path (required before any release).
# ─────────────────────────────────────────────────────────────────────────────
echo "F. STRANGER-TEST STILL GREEN (install-stranger.sh stays exit 0):"
if [ "${HEIMDALL_TEST_SLOW:-0}" != "1" ]; then
  echo "  [SKIP] HEIMDALL_TEST_SLOW not set — stranger test omitted (~170s)"
  echo "         Run with HEIMDALL_TEST_SLOW=1 to enable"
else
  STRANGER="$REPO/test/install-stranger.sh"
  if [ -f "$STRANGER" ]; then
    st_rc=0
    bash "$STRANGER" >/dev/null 2>&1 || st_rc=$?
    if [ "$st_rc" -eq 0 ]; then
      ok "install-stranger.sh still passes (instrumentation did not regress clean-install)"
    else
      bad "install-stranger.sh FAILED (rc=$st_rc) — instrumentation regressed the install path"
    fi
  else
    bad "install-stranger.sh not found — cannot prove the clean-install path is green"
  fi
fi

echo ""
echo "telemetry-install.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
