#!/usr/bin/env bash
#
# heimdall-caveman-no-plugin.test.sh — hermetic proof that hmd's output-compression
# feature works end to end with the external caveman plugin NEVER installed, and
# that an operator who already has it is left completely alone.
#
# WHY THIS EXISTS
# caveman moved in-house on 2026-08-30: bin/heimdall-caveman
# ($HEIMDALL_HOME/caveman-level) is now the sole source of truth, and
# bin/heimdall's first_run_setup no longer installs, requires, or checks for the
# external plugin at all (see the comment in first_run_setup and CLAUDE.md
# "Token Efficiency"). This file is the dedicated fresh-install proof that
# removal promise actually holds, end to end, rather than trusting the removal
# by reading the diff.
#
# Non-negotiables this file exists to prove (verbatim from the task that
# authored it):
#   - Fail open: a session must always start; compression is never a
#     correctness gate.
#   - Do not break an existing install that HAS the plugin.
#   - Do not auto-uninstall anything belonging to the operator.
#
# Guarantees proved here:
#   A. PLUGIN ABSENT: a genuine cold first-run makes zero `claude` invocations
#      that mention caveman — nothing is installed, because there is nothing
#      left to install.
#   B. PLUGIN PRESENT: the exact same cold first-run, but with an operator's
#      pre-existing `.caveman-active` flag file already on disk, STILL makes
#      zero caveman-related `claude` invocations (no re-install, and
#      critically no attempted uninstall), and leaves that flag file
#      byte-for-byte untouched.
#   C. bin/heimdall-caveman resolves a sane default level and emits non-empty
#      rules text from a completely fresh, never-configured $HEIMDALL_HOME.
#   D. bin/heimdall-caveman-block — the thing that actually reaches the model's
#      prompt — emits hmd's own real, level-labelled rules text on a fresh
#      install, not the generic "no level set" placeholder (that placeholder
#      is reserved for bin/heimdall-caveman itself being missing/broken; see
#      test/caveman-level-claim.test.sh guarantee 3).
#
# ISOLATION: mirrors test/f1-onboarding.test.sh's harness — a COPIED plugin
# tree in a temp dir (so nothing writes into the real checkout or the
# developer's real ~/.heimdall / ~/.claude), a fake `claude` on PATH so no
# proof ever makes a real network call, and HEIMDALL_TRACE_ORDER to observe
# phase ordering without a live model call.
#
# Usage: test/heimdall-caveman-no-plugin.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$REPO/bin/heimdall" ]               || { echo "FATAL: bin/heimdall not executable"; exit 2; }
[ -x "$REPO/bin/heimdall-caveman" ]       || { echo "FATAL: bin/heimdall-caveman missing"; exit 2; }
[ -x "$REPO/bin/heimdall-caveman-block" ] || { echo "FATAL: bin/heimdall-caveman-block missing"; exit 2; }

# ── Isolated copy of the plugin tree (any first-run artifact lands here) ──────
TPLUG="$(mktemp -d)"
mkdir -p "$TPLUG/bin" "$TPLUG/.claude-plugin"
cp -R "$REPO/bin/." "$TPLUG/bin/"
[ -f "$REPO/.claude-plugin/plugin.json" ] && cp "$REPO/.claude-plugin/plugin.json" "$TPLUG/.claude-plugin/" 2>/dev/null || true
LAUNCHER="$TPLUG/bin/heimdall"
chmod +x "$LAUNCHER" 2>/dev/null || true

# ── A fake `claude` that LOGS every invocation instead of no-op'ing silently ──
# f1-onboarding.test.sh's fake claude discards its args; this one records them,
# because guarantees A/B are specifically about WHICH calls hmd makes, not just
# that setup completes.
FAKE_DIR="$(mktemp -d)"
cat > "$FAKE_DIR/claude" <<'FAKECLAUDE'
#!/usr/bin/env bash
[ -n "${FAKE_CLAUDE_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_CLAUDE_LOG"
exit 0
FAKECLAUDE
chmod +x "$FAKE_DIR/claude"
PROBE_PATH="$FAKE_DIR:/usr/bin:/bin"

trap 'rm -rf "$TPLUG" "$FAKE_DIR"' EXIT

# run_launch WORKDIR TRACE HEIMDALL_HOME LOG — drive the launcher's cold path
# from an empty work dir. HOME is the parent of HEIMDALL_HOME, so a flag file
# seeded at "$(dirname "$hh")/.claude/.caveman-active" is exactly what the
# launcher/companion-install code would see as "$HOME/.claude/.caveman-active".
# Stdin is </dev/null so any unguarded read would hang (it must not).
# HEIMDALL_TRACE_ORDER short-circuits before the real `claude … -p` exec.
run_launch() {
  local wd="$1" trace="$2" hh="$3" log="$4"
  env -i HOME="$(dirname "$hh")" TERM="dumb" PATH="$PROBE_PATH" \
    HEIMDALL_HOME="$hh" ANTHROPIC_API_KEY="sk-ant-noplugin-probe" \
    HEIMDALL_NO_INTRO=1 HEIMDALL_NO_REUSE_METRIC=1 \
    HEIMDALL_TRACE_ORDER="$trace" FAKE_CLAUDE_LOG="$log" \
    bash -c "cd '$wd' && exec '$LAUNCHER' 'noop no-plugin probe'" </dev/null >/dev/null 2>/dev/null
}

echo "heimdall-caveman-no-plugin harness  repo=$REPO"
echo "--------------------------------------------------------------------"

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ A. PLUGIN ABSENT — cold first-run makes zero caveman-related calls.       ║
# ╚══════════════════════════════════════════════════════════════════════════╝
A_WD="$(mktemp -d)"
A_HH="$(mktemp -d)/.heimdall"
A_TRACE="$(mktemp -d)/a.trace"
A_LOG="$(mktemp -d)/a.claude.log"
: > "$A_LOG"

run_launch "$A_WD" "$A_TRACE" "$A_HH" "$A_LOG"

if [ -f "$A_TRACE" ] && grep -qx 'setup:companion' "$A_TRACE"; then
  ok "plugin-absent: cold run actually reached setup:companion (proof is not vacuous)"
else
  bad "plugin-absent: setup:companion never fired -- proof would be vacuous"
fi
if grep -qi 'caveman' "$A_LOG" 2>/dev/null; then
  bad "plugin-absent: hmd invoked \`claude\` with a caveman-related arg: $(tr '\n' ';' < "$A_LOG")"
else
  ok "plugin-absent: zero claude invocations mention caveman (nothing left to install)"
fi

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ B. PLUGIN PRESENT — same cold run, operator's flag file untouched.        ║
# ║    No re-install, and critically: no auto-uninstall.                      ║
# ╚══════════════════════════════════════════════════════════════════════════╝
B_WD="$(mktemp -d)"
B_HH="$(mktemp -d)/.heimdall"
B_TRACE="$(mktemp -d)/b.trace"
B_LOG="$(mktemp -d)/b.claude.log"
: > "$B_LOG"
B_HOME_DIR="$(dirname "$B_HH")"
mkdir -p "$B_HOME_DIR/.claude"
printf 'full\n' > "$B_HOME_DIR/.claude/.caveman-active"
B_FLAG_BEFORE="$(cat "$B_HOME_DIR/.claude/.caveman-active")"

run_launch "$B_WD" "$B_TRACE" "$B_HH" "$B_LOG"

if [ -f "$B_TRACE" ] && grep -qx 'setup:companion' "$B_TRACE"; then
  ok "plugin-present: cold run actually reached setup:companion (proof is not vacuous)"
else
  bad "plugin-present: setup:companion never fired -- proof would be vacuous"
fi
if grep -qi 'caveman' "$B_LOG" 2>/dev/null; then
  bad "plugin-present: hmd invoked \`claude\` with a caveman-related arg (install or uninstall attempted): $(tr '\n' ';' < "$B_LOG")"
else
  ok "plugin-present: zero claude invocations mention caveman (no-op, not a re-install)"
fi
if [ -f "$B_HOME_DIR/.claude/.caveman-active" ]; then
  B_FLAG_AFTER="$(cat "$B_HOME_DIR/.claude/.caveman-active")"
  if [ "$B_FLAG_AFTER" = "$B_FLAG_BEFORE" ]; then
    ok "plugin-present: operator's .caveman-active is byte-identical after setup (no auto-uninstall/mutation)"
  else
    bad "plugin-present: operator's .caveman-active changed ('$B_FLAG_BEFORE' -> '$B_FLAG_AFTER')"
  fi
else
  bad "plugin-present: operator's .caveman-active was DELETED by setup (auto-uninstall regression)"
fi

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ C. bin/heimdall-caveman resolves a sane default from a fresh $HEIMDALL_HOME║
# ╚══════════════════════════════════════════════════════════════════════════╝
C_HH="$(mktemp -d)/.heimdall"
C_GET="$(HEIMDALL_HOME="$C_HH" "$REPO/bin/heimdall-caveman" get 2>/dev/null)"
case "$C_GET" in
  ultra) ok "fresh heimdall-caveman get resolves the documented default ('$C_GET')" ;;
  *) bad "fresh heimdall-caveman get did not resolve to 'ultra': '$C_GET'" ;;
esac

C_RULES="$(HEIMDALL_HOME="$C_HH" "$REPO/bin/heimdall-caveman" rules 2>/dev/null)"
if [ -n "$C_RULES" ]; then
  ok "fresh heimdall-caveman rules emits non-empty text"
else
  bad "fresh heimdall-caveman rules emitted nothing"
fi
case "$C_RULES" in
  *"HMD OUTPUT COMPRESSION"*) ok "fresh rules text carries hmd's own header (not a plugin placeholder)" ;;
  *) bad "fresh rules text missing hmd's own header: $C_RULES" ;;
esac

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ D. bin/heimdall-caveman-block emits REAL rules on a fresh install --       ║
# ║    no .caveman-active anywhere, not even an unrecognized value.           ║
# ╚══════════════════════════════════════════════════════════════════════════╝
D_HOME="$(mktemp -d)"
D_HH="$D_HOME/.heimdall"
D_OUT="$(HOME="$D_HOME" HEIMDALL_HOME="$D_HH" "$REPO/bin/heimdall-caveman-block" 2>/dev/null)"
D_RC=$?
if [ "$D_RC" -eq 0 ] && [ -n "$D_OUT" ]; then
  ok "fresh heimdall-caveman-block runs clean and emits non-empty text (rc=0)"
else
  bad "fresh heimdall-caveman-block failed or emitted nothing (rc=$D_RC)"
fi
case "$D_OUT" in
  *'HMD OUTPUT COMPRESSION — level:'*) ok "fresh block emits hmd's real rules text (a real level header)" ;;
  *) bad "fresh block did not emit a real level header: $D_OUT" ;;
esac
case "$D_OUT" in
  *'no caveman level set'*) bad "fresh block fell back to the generic no-level placeholder on a plain fresh install: $D_OUT" ;;
  *) ok "fresh block did not fall back to the generic placeholder (real config, not a guess)" ;;
esac

# ── Cleanup the per-case temp dirs (the trap removes TPLUG + FAKE_DIR) ────────
rm -rf "$A_WD" "$(dirname "$A_HH")" "$(dirname "$A_TRACE")" "$(dirname "$A_LOG")" \
       "$B_WD" "$(dirname "$B_HH")" "$(dirname "$B_TRACE")" "$(dirname "$B_LOG")" \
       "$(dirname "$C_HH")" "$D_HOME" 2>/dev/null || true

echo "--------------------------------------------------------------------"


# ══════════════════════════════════════════════════════════════════════════
# E — divergence warning is gated on the plugin being genuinely INSTALLED,
#     not merely on files it left behind.
#
# THE BUG THIS PINS: the operator uninstalled the caveman plugin (marketplace
# removed) and BOTH ~/.claude/.caveman-active (still reading "full") and the
# plugin's cache dir survived. hmd then warned "level diverged" on every
# `get`, forever, about a dead file. Noise is how real warnings get ignored;
# this repo has measured that failure mode more than once.
# ══════════════════════════════════════════════════════════════════════════
E_HOME="$(mktemp -d)"; E_FLAG="$(mktemp -d)"
printf 'ultra' > "$E_HOME/caveman-level"
printf 'full'  > "$E_FLAG/.caveman-active"

E_REG_ON="$(mktemp)";  printf '{"plugins":[{"name":"caveman"}]}' > "$E_REG_ON"
E_REG_OFF="$(mktemp)"; printf '{"plugins":[]}'                   > "$E_REG_OFF"

_e_stderr() {
  HEIMDALL_HOME="$E_HOME" CLAUDE_CONFIG_DIR="$E_FLAG" \
    HMD_CAVEMAN_PLUGIN_REGISTRY="$1" "$REPO/bin/heimdall-caveman" get 2>&1 >/dev/null
}

if printf '%s' "$(_e_stderr "$E_REG_ON")" | grep -q 'diverged'; then
  ok "E1 plugin INSTALLED + level mismatch still WARNS (real divergence preserved)"
else
  bad "E1 installed plugin with a mismatched flag failed to warn — the check is now blind"
fi

if [ -z "$(_e_stderr "$E_REG_OFF")" ]; then
  ok "E2 plugin UNINSTALLED + stale flag is SILENT (no noise about a dead file)"
else
  bad "E2 warned about an orphaned flag from an uninstalled plugin"
fi

if printf '%s' "$(_e_stderr /nonexistent/registry.json)" | grep -q 'diverged'; then
  ok "E3 unreadable registry FAILS OPEN toward warning (absence is not evidence)"
else
  bad "E3 unreadable registry suppressed the warning — silently blind"
fi

E_LVL="$(HEIMDALL_HOME="$E_HOME" CLAUDE_CONFIG_DIR="$E_FLAG" \
  HMD_CAVEMAN_PLUGIN_REGISTRY="$E_REG_OFF" "$REPO/bin/heimdall-caveman" get 2>/dev/null)"
if [ "$E_LVL" = "ultra" ]; then
  ok "E4 hmd's own level stays authoritative regardless of the stale flag"
else
  bad "E4 expected ultra, got '$E_LVL' — a stale plugin flag changed hmd's level"
fi

rm -rf "$E_HOME" "$E_FLAG" "$E_REG_ON" "$E_REG_OFF"


echo "heimdall-caveman-no-plugin.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
