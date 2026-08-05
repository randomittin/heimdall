#!/usr/bin/env bash
# test/dream-install-root.test.sh — acceptance for WHERE the background job's artifacts
# are installed, and with WHAT MODES.
#
# THE BUG THIS SUITE ENCODES (measured, not assumed).
#   A default `curl | bash` install puts the plugin tree at $HOME/.heimdall (install.sh)
#   and then calls `heimdall-dream-schedule install --repo $PLUGIN_DIR`. The schedule
#   helper stages its launchd runner into $HEIMDALL_HOME/bin — which ALSO defaults to
#   $HOME/.heimdall/bin. Source and destination are THE SAME PATH, and `cp X X` exits 1
#   ("are identical (not copied)"), so install_runner died, the helper exited 3, and
#   install.sh's ensure_dream_schedule rendered that as the state word 'skipped'.
#
#   Net effect: EVERY default install silently registered no nightly dream at all. Not a
#   warning, not an error line — the installer printed nothing and moved on. That is the
#   same failure SHAPE as the 10-night TCC silence (commit 245ede5): the thing that was
#   supposed to run never ran, and nothing said so.
#
# WHAT ELSE IS PINNED HERE.
#   · MODES ARE EXPLICIT, NOT INHERITED. `mkdir -p` + `chmod +x` take their bits from the
#     caller's umask. Under `umask 000` that yields a 0777 WORLD-WRITABLE executable which
#     the user's launchd then runs every night at 03:00 — any local process could rewrite
#     it between runs. So this suite drives the whole install under `umask 000` and demands
#     exact modes anyway. A permission test that only passes under the default umask proves
#     nothing about the machine it has to protect.
#   · THE SCHEDULED JOB MUST NOT DEPEND ON A TCC-PROTECTED PATH. Not its program, not its
#     working directory, not its output. The repo it ANALYSES may be protected — that case
#     is 245ede5's loud, structured failure and is deliberately left alone — but the
#     artifacts the job needs in order to REPORT that failure must be reachable, or the
#     reporter dies behind the same locked door as the thing it reports on.
#   · THE INTERPRETER IS RESOLVED, NOT GUESSED. `#!/usr/bin/env python3` resolves through
#     PATH, and this machine has THREE python3s: /usr/bin/python3 (3.9.6, what launchd's
#     PATH finds), ~/.pyenv/shims/python3 (3.11.14, what the terminal finds) and
#     /opt/homebrew/bin/python3 (3.14.4). A nightly job that silently runs a different
#     interpreter than the one the operator tested with is a latent failure.
#
# HERMETIC. Synthetic $HOME, a shimmed launchctl that records verbs into a log, and a
# LaunchAgents dir inside the sandbox. NOTHING here reaches the real launchd domain, the
# real ~/.heimdall, the real ~/Library/LaunchAgents, crontab or keychain.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCHED_SRC="$ROOT/bin/heimdall-dream-schedule"
RUNNER_SRC="$ROOT/bin/heimdall-dream-runner"
DREAM_SRC="$ROOT/bin/heimdall-dream"
LIB_SRC="$ROOT/bin/lib/real-home.sh"
# The register path resolves the TCC-protected-path predicate through this shared lib
# (see the sourcing note in bin/heimdall-dream-schedule). Omitting it from a fixture tree
# does not merely change a message: require_reachable_artifacts fails SAFE on an undefined
# predicate and refuses the install outright, so every section below would fail for a
# reason that has nothing to do with what it is testing.
TCC_LIB_SRC="$ROOT/bin/lib/tcc-paths.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

for f in "$SCHED_SRC" "$RUNNER_SRC" "$DREAM_SRC"; do
  [ -x "$f" ] || { echo "FATAL: $f not executable" >&2; exit 2; }
done
[ -r "$LIB_SRC" ] || { echo "FATAL: $LIB_SRC not readable" >&2; exit 2; }
[ -r "$TCC_LIB_SRC" ] || { echo "FATAL: $TCC_LIB_SRC not readable" >&2; exit 2; }
command -v plutil >/dev/null 2>&1 || { echo "FATAL: plutil required (macOS)" >&2; exit 2; }

WORK="$(mktemp -d -t dream-install-root)"
cleanup() { chmod -R u+rwx "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# macOS stat: %Lp prints the permission bits in octal, without the file type.
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || printf '?'; }

# A launchctl shim. Records every verb so a refusal can be proven to have issued NONE.
LCTL="$WORK/launchctl"
cat > "$LCTL" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$LCLOG"
exit 0
SH
chmod 0755 "$LCTL"

# build_install_tree <dir> — lay out a plugin tree exactly as install.sh clones it.
build_install_tree() {
  local d="$1"
  mkdir -p "$d/bin/lib"
  cp "$SCHED_SRC"  "$d/bin/heimdall-dream-schedule"
  cp "$RUNNER_SRC" "$d/bin/heimdall-dream-runner"
  cp "$DREAM_SRC"  "$d/bin/heimdall-dream"
  cp "$LIB_SRC"     "$d/bin/lib/real-home.sh"
  cp "$TCC_LIB_SRC" "$d/bin/lib/tcc-paths.sh"
  chmod 0755 "$d/bin/heimdall-dream-schedule" "$d/bin/heimdall-dream-runner" \
             "$d/bin/heimdall-dream"
}

echo "dream install-root acceptance"
echo "============================="

# ══ (1) THE STRANGER LAYOUT: plugin tree IS $HEIMDALL_HOME ═══════════════════════
#
# This is the default `curl | bash` shape and the one that was broken. install.sh sets
# PLUGIN_DIR=$HOME/.heimdall; the helper defaults HEIMDALL_HOME to the same path, so the
# runner's source and its staging destination collide. Everything below runs under
# `umask 000` so the mode assertions test the CHMOD, never the umask.

H1="$WORK/h1"
mkdir -p "$H1/Library/LaunchAgents" "$H1/Downloads" "$H1/Documents" "$H1/Desktop"
PLUGIN1="$H1/.heimdall"
build_install_tree "$PLUGIN1"
LC1="$WORK/lc1.log"; : > "$LC1"
PLIST1="$H1/Library/LaunchAgents/com.heimdall.dream.plist"

I1_OUT="$(umask 000; HOME="$H1" HEIMDALL_REAL_HOME="$H1" \
  HEIMDALL_LAUNCH_AGENTS_DIR="$H1/Library/LaunchAgents" \
  LAUNCHCTL="$LCTL" LCLOG="$LC1" \
  "$PLUGIN1/bin/heimdall-dream-schedule" install --repo "$PLUGIN1" 2>&1)"
I1_RC=$?

if [ "$I1_RC" -eq 0 ]; then
  ok "(1) stranger layout (plugin tree == \$HEIMDALL_HOME) installs, exit 0"
else
  bad "(1) stranger layout install failed rc=$I1_RC: $(printf '%s' "$I1_OUT" | head -2)"
fi

if [ -f "$PLIST1" ]; then
  ok "(1) the nightly LaunchAgent plist was written"
else
  bad "(1) NO plist written — the nightly dream was never scheduled"
fi

PA0_1="$(plutil -extract ProgramArguments.0 raw -o - "$PLIST1" 2>/dev/null || true)"
if [ -n "$PA0_1" ] && [ -x "$PA0_1" ]; then
  ok "(1) ProgramArguments[0] ($PA0_1) exists and is executable"
else
  bad "(1) ProgramArguments[0] is '$PA0_1' — missing or not executable"
fi

# The staged runner must live under $HEIMDALL_HOME, which `hmd uninstall` sweeps
# wholesale. An artifact outside it would outlive the uninstall.
case "$PA0_1" in
  "$PLUGIN1"/*) ok "(1) the scheduled program lives under \$HEIMDALL_HOME (uninstall sweeps it)" ;;
  *) bad "(1) the scheduled program '$PA0_1' is outside \$HEIMDALL_HOME — uninstall would orphan it" ;;
esac

if grep -q 'load' "$LC1" 2>/dev/null; then
  ok "(1) launchctl load was issued"
else
  bad "(1) launchctl load never issued (log: $(cat "$LC1" 2>/dev/null | tr '\n' ';'))"
fi

# ══ (2) PERMISSIONS — exact, minimal, and umask-independent ══════════════════════
#
# Everything in (1) was created under `umask 000`. Inherited bits would therefore be
# 0777/0666. Exact modes here prove the code chmods explicitly.

M_HOME="$(mode_of "$PLUGIN1")"
if [ "$M_HOME" = "700" ]; then
  ok "(2) \$HEIMDALL_HOME is 0700 (holds pki/signing/team.json — never group/other)"
else
  bad "(2) \$HEIMDALL_HOME is 0$M_HOME, expected 0700"
fi

M_RUNNER="$(mode_of "$PA0_1")"
if [ "$M_RUNNER" = "755" ]; then
  ok "(2) the staged runner is 0755"
else
  bad "(2) the staged runner is 0$M_RUNNER, expected 0755"
fi

case "$M_RUNNER" in
  *[2367]) bad "(2) the staged runner is WORLD-WRITABLE (0$M_RUNNER) — launchd runs it nightly" ;;
  *) ok "(2) the staged runner is not world-writable" ;;
esac

M_LOGDIR="$(mode_of "$PLUGIN1/logs")"
if [ "$M_LOGDIR" = "700" ]; then
  ok "(2) the log directory is 0700"
else
  bad "(2) the log directory is 0$M_LOGDIR, expected 0700"
fi

M_LOG="$(mode_of "$PLUGIN1/logs/dream.log")"
if [ "$M_LOG" = "600" ]; then
  ok "(2) the dream log is 0600 (it records repo paths and OS errors)"
else
  bad "(2) the dream log is 0$M_LOG, expected 0600"
fi

M_PLIST="$(mode_of "$PLIST1")"
if [ "$M_PLIST" = "644" ]; then
  ok "(2) the plist is 0644 (launchd's own convention, never world-writable)"
else
  bad "(2) the plist is 0$M_PLIST, expected 0644"
fi

# Sweep: nothing the install created anywhere under $HEIMDALL_HOME may be world-writable.
WW="$(find "$PLUGIN1" -perm -0002 2>/dev/null | head -5)"
if [ -z "$WW" ]; then
  ok "(2) no world-writable artifact anywhere under \$HEIMDALL_HOME"
else
  bad "(2) world-writable artifacts exist: $(printf '%s' "$WW" | tr '\n' ' ')"
fi

# ══ (3) THE LAUNCHD-REACHABILITY GUARD (falsifiable) ═════════════════════════════
#
# The runner exists to survive a TCC denial and REPORT it. Staging it inside a
# TCC-protected folder would put the reporter behind the same locked door as the thing
# it reports on — the exact shape of the 10-night silence. Refuse at install time,
# loudly, rather than register a job that is dead on arrival.

run_guard_case() { # <label> <heimdall_home> ; echoes "<rc>|<plist?>|<launchctl verbs>"
  local home="$1" hh="$2" lc="$WORK/lc-guard.log" rc=0 out
  : > "$lc"
  out="$(HOME="$home" HEIMDALL_REAL_HOME="$home" HEIMDALL_HOME="$hh" \
    HEIMDALL_LAUNCH_AGENTS_DIR="$home/Library/LaunchAgents" \
    LAUNCHCTL="$LCTL" LCLOG="$lc" \
    "$PLUGIN1/bin/heimdall-dream-schedule" install --repo "$PLUGIN1" 2>&1)" || rc=$?
  GUARD_OUT="$out"
  GUARD_RC="$rc"
  GUARD_VERBS="$(tr '\n' ';' < "$lc" 2>/dev/null)"
}

for prot in Downloads Documents Desktop; do
  H2="$WORK/h2-$prot"
  mkdir -p "$H2/Library/LaunchAgents" "$H2/$prot"
  rm -f "$H2/Library/LaunchAgents/com.heimdall.dream.plist"
  run_guard_case "$H2" "$H2/$prot/heimdall-state"
  if [ "$GUARD_RC" -eq 6 ] \
     && [ ! -f "$H2/Library/LaunchAgents/com.heimdall.dream.plist" ] \
     && [ -z "$GUARD_VERBS" ]; then
    ok "(3) staging under ~/$prot is REFUSED (exit 6, no plist, no launchctl verb)"
  else
    bad "(3) staging under ~/$prot not refused (rc=$GUARD_RC verbs='$GUARD_VERBS')"
  fi
done

if printf '%s' "$GUARD_OUT" | grep -qi 'protected'; then
  ok "(3) the refusal NAMES the protected folder as the cause"
else
  bad "(3) the refusal does not explain itself: $(printf '%s' "$GUARD_OUT" | head -2)"
fi

# The output path is pinned into the plist too (StandardOutPath) — a job whose LOG it
# cannot write is a job whose failure has nowhere to land.
H3="$WORK/h3"
mkdir -p "$H3/Library/LaunchAgents" "$H3/Documents"
LC3="$WORK/lc3.log"; : > "$LC3"
G3_RC=0
HOME="$H3" HEIMDALL_REAL_HOME="$H3" \
  HEIMDALL_DREAM_LOG="$H3/Documents/dream.log" \
  HEIMDALL_LAUNCH_AGENTS_DIR="$H3/Library/LaunchAgents" \
  LAUNCHCTL="$LCTL" LCLOG="$LC3" \
  "$PLUGIN1/bin/heimdall-dream-schedule" install --repo "$PLUGIN1" >/dev/null 2>&1 || G3_RC=$?
if [ "$G3_RC" -eq 6 ] && [ ! -f "$H3/Library/LaunchAgents/com.heimdall.dream.plist" ]; then
  ok "(3) a TCC-protected LOG path is refused too (the job's output must land somewhere)"
else
  bad "(3) a protected log path was accepted (rc=$G3_RC)"
fi

# FALSIFIABILITY: the guard must not refuse an ordinary home. (1) already installed
# cleanly under $H1 with ~/Downloads present alongside — assert that explicitly so a
# guard that refused everything could not pass this suite by refusing everything.
if [ "$I1_RC" -eq 0 ] && [ -f "$PLIST1" ]; then
  ok "(3) FALSIFIABLE: an ordinary \$HEIMDALL_HOME is NOT refused (guard is not a blanket no)"
else
  bad "(3) the guard refuses ordinary installs too — it is a blanket refusal, not a guard"
fi

# ══ (4) THE INTERPRETER IS PINNED, NOT RESOLVED THROUGH $PATH ════════════════════

PY_PIN="$(plutil -extract ProgramArguments.6 raw -o - "$PLIST1" 2>/dev/null || true)"
PY_FLAG="$(plutil -extract ProgramArguments.5 raw -o - "$PLIST1" 2>/dev/null || true)"
if [ "$PY_FLAG" = "--python" ] && [ -n "$PY_PIN" ]; then
  ok "(4) the plist pins an interpreter (--python)"
else
  bad "(4) no --python pin in the plist (arg5='$PY_FLAG' arg6='$PY_PIN')"
fi

case "$PY_PIN" in
  /*) ok "(4) the pinned interpreter is an ABSOLUTE path ($PY_PIN)" ;;
  *)  bad "(4) the pinned interpreter '$PY_PIN' is not absolute — it would resolve through \$PATH" ;;
esac

if [ -x "$PY_PIN" ]; then
  ok "(4) the pinned interpreter exists and is executable"
else
  bad "(4) the pinned interpreter '$PY_PIN' is not executable"
fi

# The pin must work under the LAUNCHD environment, not merely the installing shell —
# that difference is the entire bug. Validate it the way 03:00 will see it.
if env -i HOME="$H1" PATH=/usr/bin:/bin:/usr/sbin:/sbin "$PY_PIN" -c 'import sys' 2>/dev/null; then
  ok "(4) the pinned interpreter runs under the launchd PATH/env"
else
  bad "(4) the pinned interpreter does not run under a launchd-like env"
fi

# BACK-COMPAT: status' silent-death detector reads ProgramArguments.0 (runner) and .2
# (dream). Inserting the pin must not shift those, or a stale-path job stops being
# detected — narrowing a guard while adding a feature is how the last outage survived.
PA2_1="$(plutil -extract ProgramArguments.2 raw -o - "$PLIST1" 2>/dev/null || true)"
if [ "$PA2_1" = "$PLUGIN1/bin/heimdall-dream" ]; then
  ok "(4) ProgramArguments[2] is still the dream bin (status' stale detector unbroken)"
else
  bad "(4) ProgramArguments[2] is '$PA2_1' — the pin shifted the argv indices"
fi

# ══ (5) THE RUNNER HONORS THE PIN, AND NEVER EXITS 0 WITHOUT ONE ═════════════════

STAGED="$PA0_1"

# 5a. A pinned interpreter that does not exist must be a LOUD, recorded failure.
S5="$WORK/s5.json"
B5_RC=0
"$STAGED" --dream "$PLUGIN1/bin/heimdall-dream" --repo "$PLUGIN1" \
  --python "$WORK/no-such-python" --status "$S5" run --overnight \
  >"$WORK/s5.log" 2>&1 || B5_RC=$?
if [ "$B5_RC" -eq 75 ]; then
  ok "(5) a missing pinned interpreter exits 75 (EX_TEMPFAIL), never a silent 0"
else
  bad "(5) missing interpreter exited $B5_RC, expected 75"
fi
if grep -q '"result": *"blocked"' "$S5" 2>/dev/null \
   && grep -q 'python' "$S5" 2>/dev/null; then
  ok "(5) the failure is RECORDED as blocked with a python reason"
else
  bad "(5) no structured python failure recorded: $(cat "$S5" 2>/dev/null | tr '\n' ' ' | head -c 200)"
fi

# 5b. The pin is actually USED — a recording interpreter proves the runner execs
# through it rather than falling back to the script's own #!/usr/bin/env shebang.
FAKEPY="$WORK/fakepy"
cat > "$FAKEPY" <<'SH'
#!/bin/bash
printf '%s\n' "$*" > "$FAKEPY_LOG"
exit 0
SH
chmod 0755 "$FAKEPY"
S6="$WORK/s6.json"
FAKEPY_LOG="$WORK/fakepy.log" \
  "$STAGED" --dream "$PLUGIN1/bin/heimdall-dream" --repo "$PLUGIN1" \
  --python "$FAKEPY" --status "$S6" run --overnight >/dev/null 2>&1
if grep -q 'heimdall-dream' "$WORK/fakepy.log" 2>/dev/null; then
  ok "(5) the runner execs the dream THROUGH the pinned interpreter"
else
  bad "(5) the pinned interpreter was never invoked: $(cat "$WORK/fakepy.log" 2>/dev/null | head -1)"
fi

# 5c. WITHOUT a pin the runner keeps its original behaviour (shebang exec). This is the
# back-compat contract the existing 21 dream-tcc assertions rely on.
#
# The dream here is the REPO's, not the minimal fixture tree's: heimdall-dream resolves
# siblings (heimdall-self-improve and friends) beside itself, so the stripped-down tree
# built above cannot complete a real run. Every other case in this suite exercises the
# INSTALL path, which needs only the four files; this one exercises the RUN path and
# therefore needs a dream that can actually finish.
S7="$WORK/s7.json"
R7="$WORK/repo7"; mkdir -p "$R7/.planning"
"$STAGED" --dream "$DREAM_SRC" --repo "$R7" --status "$S7" \
  run --overnight >/dev/null 2>&1
if grep -q '"result": *"ok"' "$S7" 2>/dev/null; then
  ok "(5) with no --python the runner still execs the dream directly (back-compat)"
else
  bad "(5) unpinned runner broke: $(cat "$S7" 2>/dev/null | tr '\n' ' ' | head -c 200)"
fi

# ══ (6) IDEMPOTENCE — a re-install upgrades cleanly, with zero drift ═════════════

SUM_A="$(shasum -a 256 < "$PLIST1")"
MODE_A="$(mode_of "$STAGED")"
LC1B="$WORK/lc1b.log"; : > "$LC1B"
I2_RC=0
(umask 000; HOME="$H1" HEIMDALL_REAL_HOME="$H1" \
  HEIMDALL_LAUNCH_AGENTS_DIR="$H1/Library/LaunchAgents" \
  LAUNCHCTL="$LCTL" LCLOG="$LC1B" \
  "$PLUGIN1/bin/heimdall-dream-schedule" install --repo "$PLUGIN1" >/dev/null 2>&1) || I2_RC=$?
SUM_B="$(shasum -a 256 < "$PLIST1")"
MODE_B="$(mode_of "$STAGED")"

if [ "$I2_RC" -eq 0 ] && [ "$SUM_A" = "$SUM_B" ]; then
  ok "(6) re-install is byte-identical — no plist drift"
else
  bad "(6) plist drifted on re-install (rc=$I2_RC)"
fi
if [ "$MODE_A" = "$MODE_B" ] && [ "$MODE_B" = "755" ]; then
  ok "(6) the staged runner's mode is stable across re-install (0755)"
else
  bad "(6) runner mode drifted: 0$MODE_A -> 0$MODE_B"
fi
# unload-before-load, exactly once each: never two loaded copies of the job.
N_LOAD="$(grep -c 'load -w' "$LC1B" 2>/dev/null | head -1)"
[ -n "$N_LOAD" ] || N_LOAD=0
if [ "$N_LOAD" -eq 2 ]; then
  ok "(6) re-install issues exactly one unload + one load (never two live jobs)"
else
  bad "(6) expected 2 launchctl load-family verbs, saw $N_LOAD: $(tr '\n' ';' < "$LC1B")"
fi

# ══ (7) UNINSTALL REVERSES THE INSTALL ══════════════════════════════════════════

LC1U="$WORK/lc1u.log"; : > "$LC1U"
HOME="$H1" HEIMDALL_REAL_HOME="$H1" \
  HEIMDALL_LAUNCH_AGENTS_DIR="$H1/Library/LaunchAgents" \
  LAUNCHCTL="$LCTL" LCLOG="$LC1U" \
  "$PLUGIN1/bin/heimdall-dream-schedule" uninstall --repo "$PLUGIN1" >/dev/null 2>&1
if [ ! -f "$PLIST1" ]; then
  ok "(7) uninstall removes the plist"
else
  bad "(7) uninstall left the plist behind"
fi
if grep -q 'unload' "$LC1U" 2>/dev/null; then
  ok "(7) uninstall unloads the job from launchd"
else
  bad "(7) uninstall never issued unload"
fi
# The stranger layout's staged runner IS the plugin tree's own file. Uninstall must NOT
# delete it — `heimdall-dream-schedule uninstall` is the documented OFF SWITCH and must
# leave the installation itself intact.
if [ -x "$PLUGIN1/bin/heimdall-dream-runner" ]; then
  ok "(7) the OFF switch does not delete the checkout's own runner"
else
  bad "(7) uninstall deleted a file belonging to the installed tree"
fi
U2_RC=0
HOME="$H1" HEIMDALL_REAL_HOME="$H1" \
  HEIMDALL_LAUNCH_AGENTS_DIR="$H1/Library/LaunchAgents" \
  LAUNCHCTL="$LCTL" LCLOG="$WORK/lc1u2.log" \
  "$PLUGIN1/bin/heimdall-dream-schedule" uninstall --repo "$PLUGIN1" >/dev/null 2>&1 || U2_RC=$?
if [ "$U2_RC" -eq 0 ]; then
  ok "(7) a second uninstall is a clean no-op"
else
  bad "(7) second uninstall errored rc=$U2_RC"
fi

# ══ (8) THE SEPARATE-CHECKOUT LAYOUT still stages a real COPY ════════════════════
#
# The owner's shape: a dev checkout somewhere else, state at ~/.heimdall. Here src and
# dst genuinely differ, so a copy must happen — and the copy must be independent of the
# source (never a symlink, which would resolve back into a protected tree at 03:00).

H4="$WORK/h4"
mkdir -p "$H4/Library/LaunchAgents"
CHECKOUT="$WORK/checkout"
build_install_tree "$CHECKOUT"
LC4="$WORK/lc4.log"; : > "$LC4"
I4_RC=0
(umask 000; HOME="$H4" HEIMDALL_REAL_HOME="$H4" \
  HEIMDALL_LAUNCH_AGENTS_DIR="$H4/Library/LaunchAgents" \
  LAUNCHCTL="$LCTL" LCLOG="$LC4" \
  "$CHECKOUT/bin/heimdall-dream-schedule" install --repo "$CHECKOUT" >/dev/null 2>&1) || I4_RC=$?
STAGED4="$H4/.heimdall/bin/heimdall-dream-runner"
if [ "$I4_RC" -eq 0 ] && [ -f "$STAGED4" ]; then
  ok "(8) separate-checkout layout stages the runner into \$HEIMDALL_HOME"
else
  bad "(8) separate-checkout staging failed (rc=$I4_RC)"
fi
if [ -L "$STAGED4" ]; then
  bad "(8) the staged runner is a SYMLINK — it would resolve into the source tree at 03:00"
else
  ok "(8) the staged runner is a real copy, not a symlink"
fi
if [ "$(mode_of "$STAGED4")" = "755" ]; then
  ok "(8) the copied runner is 0755 even under umask 000"
else
  bad "(8) the copied runner is 0$(mode_of "$STAGED4"), expected 0755"
fi
# Here the staged copy is NOT the source, so the OFF switch may reclaim it.
HOME="$H4" HEIMDALL_REAL_HOME="$H4" \
  HEIMDALL_LAUNCH_AGENTS_DIR="$H4/Library/LaunchAgents" \
  LAUNCHCTL="$LCTL" LCLOG="$WORK/lc4u.log" \
  "$CHECKOUT/bin/heimdall-dream-schedule" uninstall --repo "$CHECKOUT" >/dev/null 2>&1
if [ ! -e "$STAGED4" ] && [ -x "$CHECKOUT/bin/heimdall-dream-runner" ]; then
  ok "(8) uninstall reclaims the staged COPY and leaves the source untouched"
else
  bad "(8) uninstall did not reverse the staging cleanly"
fi

echo "------------------------------"
if [ "$FAIL" -eq 0 ]; then
  printf "dream-install-root: \033[32m%d passed\033[0m, 0 failed\n" "$PASS"
  exit 0
else
  printf "dream-install-root: %d passed, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
  exit 1
fi
