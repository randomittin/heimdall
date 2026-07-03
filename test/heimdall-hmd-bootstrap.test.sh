#!/usr/bin/env bash
#
# heimdall-hmd-bootstrap.test.sh — proves the `hmd` first-run bootstrap completes
# in ONE invocation, non-interactively, and is idempotent.
#
# THE BUG THIS LOCKS DOWN: on a fresh machine the launcher needed TWO `hmd` runs.
# Run 1 hit `ensure_auth`, dropped into an interactive `claude login`, and `exit 1`
# aborted the whole bootstrap BEFORE companion setup ran or the first-run marker
# was written. Run 2 then did companion setup, which BLOCKED on the claude-mem
# `Ok to proceed? (y)` npm confirm. Auth-check and companion-setup were effectively
# mutually exclusive per run, and both blocked on prompts.
#
# THE FIX PROVEN HERE (all in a single invocation):
#   1. companion plugins (caveman, superpowers, claude-mem, heimdall marketplace)
#      install — recorded by PATH fakes — DECOUPLED from auth state,
#   2. the claude-mem confirm is AUTO-answered (`npx --yes … < <(yes)`) → NO block,
#   3. the first-run marker is written,
#   4. an UNAUTHENTICATED state prints the deferred sign-in instruction WITHOUT
#      aborting setup or the marker,
#   5. a SECOND invocation does NOT re-run companion setup (idempotent).
#
# HERMETIC: no real network / npm / claude. `claude`, `npx` are recording fakes on
# PATH; claude-mem is deliberately absent so its install branch runs; the launcher
# short-circuits at the `launch:task` trace marker before any real `claude … -p`.
# Each launcher invocation runs under a watchdog so a regression that re-introduces
# a blocking prompt fails as a HANG rather than wedging the suite.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

need() { command -v "$1" >/dev/null 2>&1 || { echo "FATAL: $1 not found on PATH"; exit 2; }; }
need git; need python3; need yes

[ -x "$REPO/bin/heimdall" ] || { echo "FATAL: bin/heimdall not executable"; exit 2; }

# ── Isolated plugin tree (the first-run marker lands HERE, never the real repo) ──
# The copied launcher resolves its own PLUGIN_DIR from its location, so
# PLUGIN_DIR = $TPLUG and SETUP_MARKER = $TPLUG/.setup-done — freely deletable.
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

# `npx` — records argv, THEN reads one line of stdin to model the claude-mem
# `Ok to proceed? (y)` confirm. With the fix the launcher feeds a \`yes\` stream on
# stdin, so the read returns "y" immediately; we record what we saw so the test can
# PROVE the confirm was auto-answered (npx-stdin:y) rather than left to block. The
# -t guard means the fake itself can never hang the suite.
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
# NOTE: NO `claude-mem` fake on PATH ⇒ `command -v claude-mem` fails ⇒ the launcher
# runs the claude-mem install branch (the step under test).

# PATH: our fakes FIRST, then the real dirs holding python3 + git + coreutils the
# launcher genuinely needs. No real claude/npx/claude-mem is reachable.
SYS="$(dirname "$(command -v python3)"):$(dirname "$(command -v git)"):/usr/bin:/bin"
PROBE_PATH="$FAKE_DIR:$SYS"

WD1="$(mktemp -d)"; WD2="$(mktemp -d)"
HH1="$(mktemp -d)/.heimdall"; HH2="$(mktemp -d)/.heimdall"

trap 'rm -rf "$TPLUG" "$FAKE_DIR" "$WD1" "$WD2" "$HH1" "$HH2" 2>/dev/null || true' EXIT

# run_bootstrap WORKDIR HEIMDALL_HOME STDOUT_CAPTURE — drive the launcher's main
# first-run path UNAUTHENTICATED (no ANTHROPIC_API_KEY, a fresh empty HOME so there
# is no ~/.claude.json ⇒ heimdall_is_authed is false), non-TTY, stdin </dev/null so
# an unguarded prompt-read would hang. HEIMDALL_TRACE_ORDER short-circuits before
# the real `claude … -p`. Runs under a 30s watchdog: prints "HANG" and returns 124
# if the launcher does not finish (a re-introduced blocking prompt).
run_bootstrap() {
  local wd="$1" hh="$2" out="$3" trace; trace="$(mktemp)"
  env -i HOME="$(dirname "$hh")" TERM="dumb" PATH="$PROBE_PATH" \
    HEIMDALL_HOME="$hh" HEIMDALL_NO_INTRO=1 HEIMDALL_NO_REUSE_METRIC=1 \
    HEIMDALL_TRACE_ORDER="$trace" \
    bash -c "cd '$wd' && exec '$LAUNCHER' 'noop bootstrap probe'" \
    </dev/null >"$out" 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    waited=$((waited + 1))
    if [ "$waited" -ge 150 ]; then   # 150 * 0.2s = 30s
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
# ║ 1. FRESH FIRST RUN — no marker, UNAUTHENTICATED — ONE invocation does all. ║
# ╚══════════════════════════════════════════════════════════════════════════╝
rm -f "$TPLUG/.setup-done"                 # genuine cold first run
OUT1="$FAKE_DIR/run1.out"
: > "$CALLS"
HANG1="$(run_bootstrap "$WD1" "$HH1" "$OUT1")"; RC1=$?

if [ "$RC1" -eq 124 ] || [ "$HANG1" = "HANG" ]; then
  bad "fresh run BLOCKED/hung (a companion-setup prompt was not auto-answered)"
else
  ok "fresh run completed in ONE invocation without blocking (exit $RC1)"
fi

# 1a. Companion plugins installed — the fakes recorded each install call.
grep -q 'claude plugins install caveman@caveman' "$CALLS" \
  && ok "companion: caveman install recorded" \
  || bad "companion: caveman install NOT recorded (calls: $(tr '\n' ';' < "$CALLS"))"
grep -q 'claude plugins install superpowers' "$CALLS" \
  && ok "companion: superpowers install recorded" \
  || bad "companion: superpowers install NOT recorded"
grep -q 'claude plugins marketplace add randomittin/heimdall-marketplace' "$CALLS" \
  && ok "companion: heimdall marketplace add recorded" \
  || bad "companion: heimdall marketplace add NOT recorded"
grep -q 'npx --yes claude-mem install' "$CALLS" \
  && ok "companion: claude-mem installed NON-INTERACTIVELY (npx --yes)" \
  || bad "companion: claude-mem install missing/interactive (no 'npx --yes')"

# 1b. The claude-mem confirm was AUTO-answered (fed 'y' via the yes-stream), never
#     left to block on a TTY read.
grep -q '^npx-stdin:y' "$CALLS" \
  && ok "claude-mem confirm auto-answered ('y' fed on stdin) — never blocked" \
  || bad "claude-mem confirm NOT auto-answered (stdin: $(grep '^npx-stdin' "$CALLS" || echo none))"

# 1c. The first-run marker was written — even though the user is unauthenticated.
[ -f "$TPLUG/.setup-done" ] \
  && ok "first-run marker written despite deferred auth" \
  || bad "first-run marker NOT written"

# 1d. Deferred-auth: a clear, headless-friendly sign-in instruction printed, and it
#     did NOT abort setup (proven by 1a-1c passing in the same run).
grep -q 'Not signed in to Claude Code' "$OUT1" \
  && ok "deferred-auth: clear 'not signed in' instruction printed" \
  || bad "deferred-auth: sign-in instruction missing (out: $(tr '\n' ' ' < "$OUT1" | tail -c 200))"
grep -q 'setup-token' "$OUT1" \
  && ok "deferred-auth: headless 'claude setup-token' path mentioned" \
  || bad "deferred-auth: headless setup-token path not mentioned"
grep -qi 'Running claude login' "$OUT1" \
  && bad "deferred-auth: still ran interactive 'claude login' (must NOT)" \
  || ok "deferred-auth: did NOT drop into interactive 'claude login'"

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ 2. IDEMPOTENT RE-RUN — marker present ⇒ companion setup does NOT re-run.   ║
# ╚══════════════════════════════════════════════════════════════════════════╝
# Marker from run 1 is still present. A second invocation must skip the companion
# install flow entirely (no re-clone/re-install noise, no npm confirm).
OUT2="$FAKE_DIR/run2.out"
: > "$CALLS"
HANG2="$(run_bootstrap "$WD2" "$HH2" "$OUT2")"; RC2=$?

if [ "$RC2" -eq 124 ] || [ "$HANG2" = "HANG" ]; then
  bad "re-run BLOCKED/hung"
else
  ok "re-run completed without blocking (exit $RC2)"
fi
if grep -q 'plugins install caveman\|npx --yes claude-mem install' "$CALLS"; then
  bad "re-run RE-TRIGGERED companion setup (calls: $(tr '\n' ';' < "$CALLS"))"
else
  ok "re-run did NOT re-run companion setup (idempotent)"
fi
[ -f "$TPLUG/.setup-done" ] \
  && ok "re-run left the first-run marker intact" \
  || bad "re-run lost the first-run marker"

echo "--------------------------------------------------------------------"
printf 'hmd-bootstrap: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
