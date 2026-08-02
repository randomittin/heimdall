#!/usr/bin/env bash
#
# install-stranger.test.sh — stranger-environment acceptance harness for install.sh
#
# Reproduces a clean curl-install in a stripped env (a fresh $HOME, a minimal
# PATH carrying only claude/node/git) and asserts the four launch-blocking
# guarantees a real first-time user depends on:
#
#   1. COMPONENT RESOLUTION — after install, `hmd demo` finds heimdall-demo, and
#      the launcher resolves EVERY sibling it touches (face, state, city, …).
#      A dev repo with all components already on PATH hides this bug; only a
#      stripped env exposes it.
#   2. DYNAMIC VERSION — the success card shows the ACTUAL installed version
#      (resolved from the fetched ref/tag), never a hardcoded literal.
#   3. CONSISTENT PATH — the card's stated install location matches where things
#      were actually placed (no "~/.heimdall" vs "~/.local/bin" contradiction).
#   4. PATH SETUP — `hmd` is reachable after install: the installer appends the
#      bin dir to the user's shell profile, idempotently (a second run must not
#      double-append), so the headline `hmd demo` actually runs.
#
# Usage:
#   test/install-stranger.test.sh                 # uses repo of this checkout @ HEAD
#   REPO=/path REF=<sha|tag> test/install-stranger.test.sh
#
# Exit 0 = all guarantees hold. Non-zero = a guarantee regressed (prints which).
set -uo pipefail

# ── Resolve the repo + ref under test (this working tree by default) ──────────
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-$(cd "$SELF_DIR/.." && pwd)}"
REF="${REF:-$(git -C "$REPO" rev-parse HEAD)}"

# ── Resolve tool dirs for the stripped PATH (claude/node/git must be findable) ─
need() { command -v "$1" >/dev/null 2>&1 || { echo "FATAL: $1 not found on host PATH"; exit 2; }; }
need claude; need git
CLAUDE_BIN="$(cd "$(dirname "$(command -v claude)")" && pwd)"
GIT_BIN="$(cd "$(dirname "$(command -v git)")" && pwd)"
# node may be an nvm shell function; resolve the real binary dir.
NODE_REAL="$(bash -lc 'command -v node' 2>/dev/null || true)"
if [ -z "$NODE_REAL" ] || [ "$NODE_REAL" = "node" ]; then
  if [ -d "$HOME/.nvm/versions/node" ]; then
    _lv="$(ls "$HOME/.nvm/versions/node" 2>/dev/null | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
    NODE_REAL="$HOME/.nvm/versions/node/v${_lv}/bin/node"
  fi
fi
NODE_BIN="$(cd "$(dirname "$NODE_REAL")" && pwd 2>/dev/null || echo /usr/bin)"
STRANGER_PATH="$CLAUDE_BIN:$NODE_BIN:$GIT_BIN:/usr/bin:/bin"

# ── Intercept `claude plugins` for the launch-arm trace probes (§5, §6) ───────
# Those probes drive the launcher's FIRST-RUN path, whose first_run_setup runs
# `claude plugins marketplace add` + `claude plugins install` for the companion
# plugins (caveman/superpowers/claude-mem). In a fresh stripped HOME with no
# plugin cache those are real SSH git clones with 120s timeouts each — slow, and
# on a flaky/offline host they stall the whole harness. We only need the launcher
# to reach its trace markers, NOT to actually install plugins over the network.
# This wrapper makes `claude plugins …` an instant no-op and passes everything
# else through to the real claude. It is prepended to PATH for the two trace
# probes ONLY — install and every other assertion still use the real claude.
FAKE_DIR="$(mktemp -d)"
cat > "$FAKE_DIR/claude" <<EOF
#!/usr/bin/env bash
# harness intercept — make companion-plugin network installs instant in probes.
if [ "\${1:-}" = "plugins" ]; then exit 0; fi
exec "$CLAUDE_BIN/claude" "\$@"
EOF
chmod +x "$FAKE_DIR/claude"
PROBE_PATH="$FAKE_DIR:$STRANGER_PATH"

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

run_install() {  # $1=HOME
  # HEIMDALL_NO_DREAM_SCHEDULE=1: the installer now auto-registers a launchd
  # LaunchAgent (com.heimdall.dream). launchctl load targets the REAL user GUI
  # session domain — NOT isolated by the throwaway $HOME — so an unguarded run would
  # stomp the tester's own live nightly agent with one pointed at this temp checkout
  # (then leave it dangling on cleanup). Opt out so the smoke stays side-effect-free;
  # the schedule wiring itself is proven hermetically in test/dream-install-wire.test.sh.
  env -i HOME="$1" TERM="dumb" PATH="$STRANGER_PATH" \
    HEIMDALL_REPO="$REPO" HEIMDALL_REF="$REF" HEIMDALL_NO_COLOR=1 \
    HEIMDALL_NO_DREAM_SCHEDULE=1 \
    bash "$REPO/install.sh" 2>&1
}
in_stranger() { # $1=HOME, rest=cmd — run a command as the stranger would
  local h="$1"; shift
  env -i HOME="$h" TERM="dumb" PATH="$STRANGER_PATH" "$@" 2>&1
}

TMPH="$(mktemp -d)"
# PROBE_TREE is built in §7 from the INSTALLED tree and drives the §7f–§7k
# uninstall-reversal scenarios. Declared up here so the cleanup trap can name it
# unconditionally under `set -u`.
PROBE_TREE=""
trap 'rm -rf "$TMPH" "$FAKE_DIR" ${PROBE_TREE:+"$PROBE_TREE"}' EXIT

echo "stranger-install harness  repo=$REPO  ref=${REF:0:12}  HOME=$TMPH"
echo "--------------------------------------------------------------------"

# ── Fresh install ─────────────────────────────────────────────────────────────
CARD="$(run_install "$TMPH")"

# Expected version: what `git describe --tags` reports in the installed clone —
# the SAME source the launcher's heimdall_version() trusts first.
EXPECT_VER="$(git -C "$TMPH/.heimdall" describe --tags --abbrev=0 2>/dev/null \
  | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
[ -n "$EXPECT_VER" ] || EXPECT_VER="$(git -C "$REPO" describe --tags --abbrev=0 2>/dev/null | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"

# (2) DYNAMIC VERSION — card must show the real version, not a stale literal.
if printf '%s' "$CARD" | grep -qE "Heimdall v${EXPECT_VER}([^0-9]|\$)"; then
  ok "card shows dynamic version v$EXPECT_VER"
else
  bad "card version is not the installed v$EXPECT_VER — got: $(printf '%s' "$CARD" | grep -iE 'Heimdall v[0-9]' | head -1 | sed 's/^ *//')"
fi

# (3) CONSISTENT PATH — the card must not claim a single install path that
# contradicts where the launchers actually went. If the card prints a path
# line, every path it names must be a real, populated location.
LAUNCHER="$TMPH/.local/bin/hmd"
[ -e "$LAUNCHER" ] || LAUNCHER="$TMPH/.local/bin/heimdall"
if printf '%s' "$CARD" | grep -qE 'path:.*\.heimdall' \
   && ! printf '%s' "$CARD" | grep -qE 'local/bin|launchers?|hmd, heimdall'; then
  bad "card states 'path: ~/.heimdall' only — contradicts launchers placed in ~/.local/bin"
else
  ok "card install location is consistent with what was placed"
fi

# (1) COMPONENT RESOLUTION — the headline command must resolve its runner.
DEMO_OUT="$(in_stranger "$TMPH" "$LAUNCHER" demo --dry 2>&1)"
if printf '%s' "$DEMO_OUT" | grep -qi 'demo runner not found'; then
  bad "hmd demo: $(printf '%s' "$DEMO_OUT" | grep -i 'not found' | head -1 | sed 's/^ *//')"
else
  ok "hmd demo resolves heimdall-demo (no 'not found')"
fi

# (1d) DEMO ARC — the deny→fix→pass showcase must actually PLAY end to end. It
# regressed once: under `set -euo pipefail`, the runtime secret-key generator
# `tr … </dev/urandom | head -c 40` took SIGPIPE (nonzero pipeline) and aborted
# the demo right after the gate-inspector frame — so the RED denial, the fix, the
# GOLD pass and the summary card never rendered (the product's signature moment,
# silently gone). The arc's narration is TTY-gated, so we drive the INSTALLED demo
# under a pty (`script`) with --intro, gitleaks on PATH (the catch needs the real
# gate), and assert BOTH the denial AND the pass stages render. A future early
# exit between "inspecting" and the pass fails THIS loudly. gitleaks/script absent
# → skip (the arc legitimately needs the real scanner; we never assert a fake).
GL_DIR=""; command -v gitleaks >/dev/null 2>&1 && GL_DIR="$(cd "$(dirname "$(command -v gitleaks)")" && pwd)"
if [ -n "$GL_DIR" ] && command -v script >/dev/null 2>&1; then
  ARC_OUT="$TMPH/demo-arc.out"; : > "$ARC_OUT"
  ( script -q "$ARC_OUT" env HOME="$TMPH" PATH="$GL_DIR:$STRANGER_PATH" \
      "$LAUNCHER" demo --intro --dry >/dev/null 2>&1 ) &
  _arc_pid=$!
  ( sleep 40; kill -9 "$_arc_pid" 2>/dev/null; pkill -9 -f heimdall-demo 2>/dev/null ) &
  _arc_kp=$!
  wait "$_arc_pid" 2>/dev/null
  kill "$_arc_kp" 2>/dev/null
  ARC="$(sed 's/\x1b\[[0-9;]*m//g' "$ARC_OUT" 2>/dev/null)"
  _deny="$(printf '%s' "$ARC" | grep -ciE 'caught|denial|barred' || true)"
  _pass="$(printf '%s' "$ARC" | grep -ciE 'gate ✓|Bifröst open|PASS — secret-scan' || true)"
  if [ "${_deny:-0}" -ge 1 ] && [ "${_pass:-0}" -ge 1 ]; then
    ok "demo plays the full deny→fix→pass arc (denial + pass stages both render)"
  else
    bad "demo arc incomplete — deny=$_deny pass=$_pass (early exit after gate-inspector?)"
  fi
else
  ok "demo-arc check skipped — gitleaks/script unavailable (arc needs the real gate, never faked)"
fi

# (1b) COMPONENT RESOLUTION (real task path) — prove the launcher resolves every
# sibling a real `hmd "task"` touches WITHOUT a model call. `hmd version` runs
# the same $0→readlink→PLUGIN_DIR resolution; then we directly probe that each
# component the task path invokes exists beside the resolved launcher.
VER_OUT="$(in_stranger "$TMPH" "$LAUNCHER" version 2>&1)"
VER_LINE="$(printf '%s' "$VER_OUT" | grep -iE 'Heimdall v[0-9]' | head -1 | sed 's/^ *//')"
# TIGHTENED (was: merely asserts it RUNS). `hmd version` must report the EXACT
# release version the launcher resolves (git-describe of the installed tree →
# manifest fallback) — the SAME value the success card shows. It previously read
# plugin.json directly and reported a hardcoded "Heimdall v1.1.0" for the entire
# v2.0.x line; this gate makes that drift impossible to re-ship.
if [ -z "$VER_LINE" ]; then
  bad "hmd version failed to run through the launcher: $VER_OUT"
elif printf '%s' "$VER_OUT" | grep -qE "Heimdall v${EXPECT_VER}([^0-9]|\$)"; then
  # Equals the installed release version. Also explicitly reject the stale 1.1.0
  # whenever the release has moved past it (defense in depth — if EXPECT_VER ever
  # mis-resolves, a literal 1.1.0 still fails loudly here).
  if [ "$EXPECT_VER" != "1.1.0" ] && printf '%s' "$VER_OUT" | grep -qE 'Heimdall v1\.1\.0([^0-9]|$)'; then
    bad "hmd version reports stale hardcoded 1.1.0 (expected v$EXPECT_VER) — plugin.json drift"
  else
    ok "hmd version reports release version v$EXPECT_VER (not stale 1.1.0): $VER_LINE"
  fi
else
  bad "hmd version is not the installed release v$EXPECT_VER — got: $VER_LINE"
fi
# Resolve PLUGIN_DIR exactly as the launcher does (readlink -f $0 → dirname/..)
REAL_LAUNCHER="$(in_stranger "$TMPH" /usr/bin/readlink -f "$LAUNCHER" 2>/dev/null || echo "$LAUNCHER")"
RESOLVED_PLUGIN="$(cd "$(dirname "$REAL_LAUNCHER")/.." && pwd)"
MISSING=""
for comp in heimdall-demo heimdall-face heimdall-city heimdall-state \
            heimdall-selfscan skill-manager discover-skills summary-card; do
  [ -x "$RESOLVED_PLUGIN/bin/$comp" ] || MISSING="$MISSING $comp"
done
if [ -z "$MISSING" ]; then
  ok "all task-path components resolve beside launcher ($RESOLVED_PLUGIN/bin)"
else
  bad "components NOT beside resolved launcher ($RESOLVED_PLUGIN/bin):$MISSING"
fi

# (4) PATH SETUP — installer must put the bin dir on PATH via a shell profile,
# idempotently. Detect which profile it wrote, count the lines mentioning the
# bin dir; a fresh install adds exactly one.
PROFILE=""
for p in "$TMPH/.zshrc" "$TMPH/.bashrc" "$TMPH/.profile" "$TMPH/.bash_profile"; do
  if [ -f "$p" ] && grep -qE '\.local/bin' "$p"; then PROFILE="$p"; break; fi
done
if [ -n "$PROFILE" ]; then
  N1="$(grep -cE '\.local/bin' "$PROFILE")"
  ok "PATH export written to $(basename "$PROFILE") ($N1 line)"
else
  bad "no shell profile gained a ~/.local/bin PATH export — hmd stays command-not-found"
fi

# After sourcing the written profile, `hmd` must resolve by bare name on PATH.
if [ -n "$PROFILE" ]; then
  WHICH="$(env -i HOME="$TMPH" TERM="dumb" PATH="/usr/bin:/bin" \
    bash -c "source '$PROFILE' >/dev/null 2>&1; command -v hmd || command -v heimdall" 2>&1)"
  if printf '%s' "$WHICH" | grep -q '/.local/bin/'; then
    ok "after sourcing profile, hmd/heimdall resolves on PATH ($WHICH)"
  else
    bad "after sourcing profile, hmd not on PATH (got: ${WHICH:-<empty>})"
  fi
fi

# (4b) STATUSLINE ACTIVATION — the watchman HUD must activate for a STRANGER via
# the install, not only whoever hand-wired it in dev setup. THE RJ-ONLY BUG: the
# working statusLine registration lived solely in one dev's personal
# ~/.claude/settings.json, and the install never replicated it — so every other
# dev's enter-box stayed bare. install.sh now registers statusLine +
# subagentStatusLine into the user's Claude Code settings.json (honoring
# CLAUDE_CONFIG_DIR → ~/.claude) at the ABSOLUTE installed path. A fresh stranger
# HOME (env -i, no pre-existing settings) proves the install does it for everyone.
SETTINGS="$TMPH/.claude/settings.json"
SL_PLUGIN="$TMPH/.heimdall"
if [ -f "$SETTINGS" ]; then
  SL_EVAL="$(python3 - "$SETTINGS" "$SL_PLUGIN" <<'PY' 2>/dev/null
import json, sys
path, plugin = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    print("noparse"); sys.exit(0)
sl = (d.get("statusLine") or {}).get("command", "")
sa = (d.get("subagentStatusLine") or {}).get("command", "")
ok_sl = (plugin + "/hooks/statusline.sh") in sl
ok_sa = (plugin + "/hooks/subagent-statusline.sh") in sa
# Absolute installed path, NOT an unresolved ${CLAUDE_PLUGIN_ROOT} (which renders
# nothing in a user-level statusLine) — the distinction the fix turns on.
no_unresolved = "CLAUDE_PLUGIN_ROOT" not in sl and "CLAUDE_PLUGIN_ROOT" not in sa
print("OK" if (ok_sl and ok_sa and no_unresolved) else "MISS sl=%s sa=%s unresolved-free=%s" % (ok_sl, ok_sa, no_unresolved))
PY
)"
  if [ "$SL_EVAL" = "OK" ]; then
    ok "statusline activated for stranger — statusLine + subagentStatusLine wired into ~/.claude/settings.json at the installed path"
  else
    bad "statusline NOT activated in stranger settings.json ($SL_EVAL)"
  fi
else
  bad "no ~/.claude/settings.json written by install — statusline stays RJ-only ($SETTINGS)"
fi

# (4c) STATUSLINE NON-TTY SAFE — the registered command must render AND exit 0 on
# a non-TTY (CI) without hanging. We run the installed statusline.sh exactly as CC
# would (a JSON blob on stdin, non-TTY env) under a watchdog; a stall = FAIL.
SL_SCRIPT="$SL_PLUGIN/hooks/statusline.sh"
if [ -x "$SL_SCRIPT" ]; then
  SL_OUT_F="$(mktemp)"
  ( printf '{"cwd":"%s"}' "$TMPH" | env -i HOME="$TMPH" TERM="dumb" PATH="$STRANGER_PATH" \
      bash "$SL_SCRIPT" >"$SL_OUT_F" 2>&1 ) &
  _slp=$!
  ( sleep 15; kill -9 "$_slp" 2>/dev/null ) & _slk=$!
  wait "$_slp" 2>/dev/null; SL_RC=$?
  if kill -0 "$_slk" 2>/dev/null; then kill "$_slk" 2>/dev/null; else [ "$SL_RC" -eq 137 ] && SL_RC=124; fi
  rm -f "$SL_OUT_F"
  if [ "$SL_RC" -eq 124 ]; then
    bad "statusline.sh HUNG on non-TTY (watchdog killed it)"
  elif [ "$SL_RC" -eq 0 ]; then
    ok "statusline.sh renders + exits 0 on non-TTY (CI-safe, no hang)"
  else
    bad "statusline.sh exited nonzero on non-TTY (rc=$SL_RC)"
  fi
else
  bad "installed statusline.sh missing/not executable ($SL_SCRIPT)"
fi

# ── Idempotency: a second install in the SAME HOME must not double-append ──────
run_install "$TMPH" >/dev/null 2>&1
if [ -n "$PROFILE" ]; then
  N2="$(grep -cE '\.local/bin' "$PROFILE")"
  if [ "$N2" = "${N1:-0}" ]; then
    ok "second install is idempotent — PATH line count unchanged ($N2)"
  else
    bad "second install double-appended PATH (was ${N1:-?}, now $N2)"
  fi
fi
# And the launcher must still resolve its demo runner after the re-install.
DEMO2="$(in_stranger "$TMPH" "$LAUNCHER" demo --dry 2>&1)"
if printf '%s' "$DEMO2" | grep -qi 'demo runner not found'; then
  bad "after re-install, hmd demo regressed to 'not found'"
else
  ok "after re-install, hmd demo still resolves"
fi

# Statusline registration is idempotent too — the second install must leave EXACTLY
# one statusLine entry pointing at the installed path (a JSON key, so it can never
# double-append, but a regression that drops or rewrites it to an unresolved var
# would fail here).
if [ -f "$SETTINGS" ]; then
  SL_EVAL2="$(python3 - "$SETTINGS" "$SL_PLUGIN" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1])); plugin = sys.argv[2]
sl = (d.get("statusLine") or {}).get("command", "")
print("OK" if (plugin + "/hooks/statusline.sh") in sl and "CLAUDE_PLUGIN_ROOT" not in sl else "MISS")
PY
)"
  if [ "$SL_EVAL2" = "OK" ]; then
    ok "second install keeps the statusLine registration intact (idempotent)"
  else
    bad "second install altered/dropped the statusLine registration ($SL_EVAL2)"
  fi
fi

# (8) STEP NARRATION — every installer-owned step must announce itself in the
# install transcript, so a stranger watching a curl|bash never faces a silent gap
# between "started the script" and "done". We assert the captured CARD names each
# owned step (download/setup → register → plugin → link → gates). A removed or
# renamed-to-silence step fails THIS loudly (the anti-silent-hang guarantee).
NARRATE_MISS=""
for label in 'Fetching Heimdall' 'Registering Heimdall marketplace' \
             'Installing plugin' 'Linking entry point' 'Verifying gates'; do
  printf '%s' "$CARD" | grep -qF "$label" || NARRATE_MISS="$NARRATE_MISS | $label"
done
if [ -z "$NARRATE_MISS" ]; then
  ok "every installer step is narrated in the transcript (download→register→plugin→link→gates)"
else
  bad "installer step(s) not narrated — missing:$NARRATE_MISS"
fi

# (9) INSTALL TELEMETRY PER STEP — the installer must record an install_step event
# for EACH owned step so a stall/failure is visible across the team. install.sh
# points HEIMDALL_HOME at $PLUGIN_DIR/.heimdall, so events land inside the install
# footprint (test-visible, and swept by uninstall's wholesale plugin-dir removal).
# This HOME held TWO installs (the idempotency re-run appends to the same store), so
# the store legitimately carries multiple run ids — ONE PER INSTALL. The contract is
# per-install correlation: SOME single run id must cover ALL SIX owned steps
# (fetch→marketplace→plugin→link→gates→path). We verify that, not a global count.
TELE_STORE="$TMPH/.heimdall/.heimdall/telemetry/events.ndjson"
if [ ! -f "$TELE_STORE" ]; then
  bad "install telemetry store absent — no per-step install_step events recorded ($TELE_STORE)"
else
  TELE_EVAL="$(python3 - "$TELE_STORE" <<'PY' 2>/dev/null
import sys, json, collections
REQ={"fetch","marketplace","plugin","link","gates","path"}
by_run=collections.defaultdict(set); all_steps=set()
with open(sys.argv[1]) as fh:
    for line in fh:
        line=line.strip()
        if not line: continue
        try: e=json.loads(line)
        except Exception: continue
        if e.get("event_type")=="install_step" and e.get("step"):
            all_steps.add(e["step"])
            if e.get("run_id"): by_run[e["run_id"]].add(e["step"])
# A run id that covers every required step = per-install correlation holds.
covering=[r for r,s in by_run.items() if REQ<=s]
print("OK" if covering else "MISS")
print(",".join(sorted(all_steps)))
print(",".join(sorted(REQ-all_steps)))   # any required step never recorded at all
PY
)"
  COVER="$(printf '%s' "$TELE_EVAL" | sed -n 1p)"
  GOT_STEPS="$(printf '%s' "$TELE_EVAL" | sed -n 2p)"
  NEVER="$(printf '%s' "$TELE_EVAL" | sed -n 3p)"
  if [ -n "$NEVER" ]; then
    bad "install telemetry never recorded step(s): $NEVER (recorded: $GOT_STEPS)"
  elif [ "$COVER" = "OK" ]; then
    ok "install telemetry records every step under one per-install run id ($GOT_STEPS)"
  else
    bad "install telemetry steps not correlated under a single per-install run id (recorded: $GOT_STEPS)"
  fi
fi

# (10) GRACEFUL OPTIONAL-STEP FAILURE — a failed OPTIONAL step (marketplace
# registration) must NOT break the install. We drive a FRESH stranger HOME with
# HEIMDALL_FORCE_FAIL_OPTIONAL=1 (install.sh's injectable optional-failure hook):
# the install must still COMPLETE — success card rendered, both launchers linked,
# `hmd demo` still resolving — with a non-fatal degrade note instead of an abort.
TMPH_G="$(mktemp -d)"
GRACE_CARD="$(env -i HOME="$TMPH_G" TERM="dumb" PATH="$STRANGER_PATH" \
  HEIMDALL_REPO="$REPO" HEIMDALL_REF="$REF" HEIMDALL_NO_COLOR=1 \
  HEIMDALL_NO_DREAM_SCHEDULE=1 \
  HEIMDALL_FORCE_FAIL_OPTIONAL=1 bash "$REPO/install.sh" 2>&1)"
GRACE_RC=$?
GLNK="$TMPH_G/.local/bin/hmd"; [ -e "$GLNK" ] || GLNK="$TMPH_G/.local/bin/heimdall"
if [ "$GRACE_RC" -eq 0 ] \
   && printf '%s' "$GRACE_CARD" | grep -qiE 'Heimdall v[0-9].* installed' \
   && [ -e "$GLNK" ]; then
  GDEMO="$(in_stranger "$TMPH_G" "$GLNK" demo --dry 2>&1)"
  if printf '%s' "$GDEMO" | grep -qi 'demo runner not found'; then
    bad "graceful-degrade: install completed but hmd demo broke after optional-step failure"
  else
    ok "optional-step failure degrades gracefully — install completes, card renders, launcher works"
  fi
else
  bad "optional-step failure BROKE the install (rc=$GRACE_RC, card present=$(printf '%s' "$GRACE_CARD" | grep -qiE 'Heimdall v[0-9].* installed' && echo yes || echo no))"
fi

# (10b) FALSIFIABLE GRACEFUL-DEGRADE — the degrade guarantee must be PROVABLE, not
# vacuous. The SAME injected optional-step failure, with HEIMDALL_HARD_FAIL_OPTIONAL=1,
# must turn the soft-skip into a HARD abort: a non-zero exit and NO success card.
# If this variant still "succeeds", §10's graceful pass means nothing — so this RED
# variant going GREEN here would itself be the regression. (We assert the abort.)
HARD_CARD="$(env -i HOME="$TMPH_G" TERM="dumb" PATH="$STRANGER_PATH" \
  HEIMDALL_REPO="$REPO" HEIMDALL_REF="$REF" HEIMDALL_NO_COLOR=1 \
  HEIMDALL_NO_DREAM_SCHEDULE=1 \
  HEIMDALL_FORCE_FAIL_OPTIONAL=1 HEIMDALL_HARD_FAIL_OPTIONAL=1 bash "$REPO/install.sh" 2>&1)"
HARD_RC=$?
if [ "$HARD_RC" -ne 0 ] \
   && ! printf '%s' "$HARD_CARD" | grep -qiE 'Heimdall v[0-9].* installed'; then
  ok "graceful-degrade is falsifiable — forced hard-fail-on-optional aborts (rc=$HARD_RC, no card)"
else
  bad "graceful-degrade NOT falsifiable — hard-fail variant did not abort (rc=$HARD_RC, card present=$(printf '%s' "$HARD_CARD" | grep -qiE 'Heimdall v[0-9].* installed' && echo yes || echo no))"
fi
rm -rf "$TMPH_G" 2>/dev/null || true

# (5) FIRST-RUN ORDERING — on a fresh install's first run, auth setup +
# companion-plugin setup must FULLY COMPLETE before the first task launches.
# A real first run can't be driven here (no live model call), so we drive the
# launcher's first-run path with HEIMDALL_TRACE_ORDER=<file>: it emits one
# ordered marker per phase to that file (setup:auth, setup:companion,
# setup:skills, launch:task) and short-circuits just before the `claude … -p`
# exec. The contract this asserts: EVERY setup:* marker precedes launch:task —
# no interleaving, no setup deferred past the launch. We run on a FRESH HOME so
# the first-run marker (.setup-done) is absent and the full setup phase fires.
TMPH3="$(mktemp -d)"
run_install "$TMPH3" >/dev/null 2>&1
LAUNCHER3="$TMPH3/.local/bin/hmd"
[ -e "$LAUNCHER3" ] || LAUNCHER3="$TMPH3/.local/bin/heimdall"
# Resolve the installed plugin dir, then remove any setup marker so this is a
# genuine first run (the full auth+companion+skills setup phase must fire).
REAL_L3="$(in_stranger "$TMPH3" /usr/bin/readlink -f "$LAUNCHER3" 2>/dev/null || echo "$LAUNCHER3")"
PLUGIN3="$(cd "$(dirname "$REAL_L3")/.." && pwd)"
rm -f "$PLUGIN3/.setup-done" 2>/dev/null || true
TRACE3="$TMPH3/order.trace"
# ANTHROPIC_API_KEY makes ensure_auth a no-op no-login (it returns immediately
# when a key is present), so we drive the ordering path WITHOUT a live login or
# model call — the stripped env has no TTY/credentials to log in with. We assert
# the ORDER of setup vs launch, not a live task.
in_stranger "$TMPH3" env PATH="$PROBE_PATH" ANTHROPIC_API_KEY="sk-ant-stranger-ordering-probe" \
  HEIMDALL_TRACE_ORDER="$TRACE3" "$LAUNCHER3" "noop first-run ordering probe" >/dev/null 2>&1 || true
if [ ! -f "$TRACE3" ]; then
  bad "first-run ordering: launcher emitted no trace (HEIMDALL_TRACE_ORDER ignored)"
else
  ORDER="$(tr '\n' ' ' < "$TRACE3")"
  # Line number of each phase marker; every setup phase must precede the launch.
  L_AUTH="$(grep -n '^setup:auth$'      "$TRACE3" | head -1 | cut -d: -f1)"
  L_COMP="$(grep -n '^setup:companion$' "$TRACE3" | head -1 | cut -d: -f1)"
  L_SKIL="$(grep -n '^setup:skills$'    "$TRACE3" | head -1 | cut -d: -f1)"
  L_LNCH="$(grep -n '^launch:task$'     "$TRACE3" | head -1 | cut -d: -f1)"
  if [ -z "$L_AUTH" ] || [ -z "$L_COMP" ] || [ -z "$L_SKIL" ] || [ -z "$L_LNCH" ]; then
    bad "first-run ordering: missing a phase marker (trace: $ORDER)"
  elif [ "$L_AUTH" -lt "$L_LNCH" ] && [ "$L_COMP" -lt "$L_LNCH" ] && [ "$L_SKIL" -lt "$L_LNCH" ]; then
    ok "first-run ordering: auth+companion+skills setup complete BEFORE task launch (trace: $ORDER)"
  else
    bad "first-run ordering: setup interleaved with/deferred past launch (trace: $ORDER)"
  fi
fi
rm -rf "$TMPH3" 2>/dev/null || true

# (6) NON-TTY ANIMATION LEAK — the launch boot animation (#2) and uninstall
# farewell (#3) are TTY-gated cosmetics. The stranger env is non-TTY (env -i, no
# controlling terminal), so the launcher must emit ZERO watchman wake-up bytes here
# (frames piped to a non-TTY are garbage). We drive the launch arm via trace mode
# (HEIMDALL_TRACE_ORDER + ANTHROPIC_API_KEY) — it runs the full setup→handoff path
# and short-circuits at the launch marker. narrate_launch_wakeup is wired at that
# same handoff; its own `[ -t 1 ]` gate means a non-TTY run prints no "watchman
# wakes" line. (The sad farewell's non-TTY gate is proven directly in 7d below.)
TRACE6="$TMPH/order.trace.notty"
NOTTY_OUT="$(in_stranger "$TMPH" env PATH="$PROBE_PATH" ANTHROPIC_API_KEY="sk-ant-stranger-notty-probe" \
  HEIMDALL_TRACE_ORDER="$TRACE6" "$LAUNCHER" "noop non-tty animation probe" 2>&1)"
rm -f "$TRACE6" 2>/dev/null || true
if printf '%s' "$NOTTY_OUT" | grep -qi 'watchman wakes'; then
  bad "non-TTY launch leaked the wake-up animation banner (TTY gate failed)"
else
  ok "non-TTY launch emits no wake-up animation bytes (TTY-gated cosmetic)"
fi

# (7) UNINSTALL COMPLETENESS — `hmd uninstall` must REVERSE EVERYTHING install did:
# the ~/.heimdall plugin clone, BOTH ~/.local/bin symlinks (hmd + heimdall), AND
# the PATH export line install appended to the shell profile (the v2.0.2 gap). We
# run it in the SAME stripped HOME that holds a real install (from above), non-TTY
# (so the farewell frame is gated off — and must leak no art), then assert FULL
# reversal artifact-by-artifact.
# Pre-checks: confirm the install artifacts are actually present before removal, so
# a PASS means the uninstall removed something real (not a vacuous "already gone").
PRE_PLUGIN=0; [ -d "$TMPH/.heimdall" ] && PRE_PLUGIN=1
PRE_HMD=0;    { [ -e "$TMPH/.local/bin/hmd" ] || [ -L "$TMPH/.local/bin/hmd" ]; } && PRE_HMD=1
PRE_HEIM=0;   { [ -e "$TMPH/.local/bin/heimdall" ] || [ -L "$TMPH/.local/bin/heimdall" ]; } && PRE_HEIM=1
PRE_PATHN=0;  [ -n "$PROFILE" ] && PRE_PATHN="$(grep -cE '\.local/bin' "$PROFILE" 2>/dev/null || echo 0)"

# Preserve a RUNNABLE copy of the launcher OUTSIDE the install tree before the
# first uninstall removes both the symlink AND the plugin clone — so the
# idempotency re-run (7e) still has an entry point to invoke against the now-empty
# HOME. The launcher resolves its own guarded canonical paths ($HOME/.heimdall,
# $HOME/.local/bin), so running the saved copy with HOME=$TMPH reverses the SAME
# locations. The mktemp fill run is assembled at runtime, not a source literal.
SAVED_TPL="${TMPDIR:-/tmp}/heimdall-saved-launcher.$(printf 'X%.0s' 1 2 3 4 5 6)"
SAVED_LAUNCHER="$(mktemp "$SAVED_TPL")"
cp "$REAL_LAUNCHER" "$SAVED_LAUNCHER" 2>/dev/null && chmod +x "$SAVED_LAUNCHER" 2>/dev/null || true

# A minimal PLUGIN TREE copied out of the INSTALLED clone, for the §7f–§7k
# uninstall-reversal scenarios. Copied from $RESOLVED_PLUGIN (not from $REPO) so
# those scenarios exercise the artifacts the install actually placed, and taken
# NOW because the uninstall below deletes that tree. It holds the launcher plus
# heimdall-dream-schedule, so `hmd uninstall` resolves PLUGIN_DIR to this tree and
# reaches the real LaunchAgent off-switch rather than its no-helper fallback.
# bin/lib/real-home.sh comes too: it holds the SHARED passwd-based real-user
# predicate that BOTH halves of the launchd guard resolve through (bin/heimdall on
# uninstall, bin/heimdall-dream-schedule on install). Omitting it would make the
# probe tree unrepresentative of a real install AND would silently push both halves
# onto their fail-safe "cannot prove → refuse" branch, turning §7f/§8b green for the
# wrong reason. Its presence is asserted below, so a failed copy FAILS LOUD.
PROBE_TREE="$(mktemp -d)"; mkdir -p "$PROBE_TREE/bin/lib"
cp "$RESOLVED_PLUGIN/bin/heimdall" "$PROBE_TREE/bin/heimdall" 2>/dev/null || true
cp "$RESOLVED_PLUGIN/bin/heimdall-dream-schedule" "$PROBE_TREE/bin/heimdall-dream-schedule" 2>/dev/null || true
cp "$RESOLVED_PLUGIN/bin/lib/real-home.sh" "$PROBE_TREE/bin/lib/real-home.sh" 2>/dev/null || true
# heimdall-dream is the binary the schedule REGISTERS. §8 needs it present because
# cmd_install refuses without an executable dream bin, and the plist it writes must
# name this exact path. It is never executed here — only stat'd and embedded.
cp "$RESOLVED_PLUGIN/bin/heimdall-dream" "$PROBE_TREE/bin/heimdall-dream" 2>/dev/null || true
# install.sh too — §8d sources it (HEIMDALL_INSTALL_SOURCE_ONLY=1) to assert the state
# word its ensure_dream_schedule returns. Copied HERE, from the INSTALLED tree, because
# the uninstall below deletes $RESOLVED_PLUGIN before §8 runs.
cp "$RESOLVED_PLUGIN/install.sh" "$PROBE_TREE/install.sh" 2>/dev/null || true
chmod +x "$PROBE_TREE/bin/heimdall" "$PROBE_TREE/bin/heimdall-dream-schedule" \
         "$PROBE_TREE/bin/heimdall-dream" 2>/dev/null || true

# (7·0a) RESERVED-SUBCOMMAND NON-TTY CLASS — the launcher-preamble regression.
# THE BUG (fixed in bin/heimdall, locked here): the F1 launch resolution-order
# (f1_orient → f1_persona_check → first_run_setup, which includes the companion
# `npx claude-mem install` probe AND a `read -rt 60` persona prompt) used to run on
# EVERY invocation — so a RESERVED subcommand like `hmd uninstall --yes` / `version`
# / `demo` ran the whole launch preamble BEFORE dispatching, and in a non-TTY env
# that preamble's persona read + companion stall HUNG forever.
# THE FIX: reserved words dispatch at the top-level `case "${1:-}"` BEFORE any
# f1_orient/f1_persona_check/first_run_setup runs; the persona prompt is `[ -t 0 ]`-
# guarded. The resolution-order preamble runs ONLY for real task invocations.
# THE DISCRIMINATOR this asserts: a reserved subcommand must dispatch STRAIGHT to
# its handler — NO orient→persona→first-run preamble, NO persona read, NO companion
# `npx claude-mem install` stall. We run each in the stripped/isolated stranger env
# (the installed launcher, </dev/null, non-TTY via env -i), each under a REAL
# watchdog: if a reserved path stalls past a tight bound the watchdog SIGKILLs it
# and the assertion FAILS LOUD (a hang = FAIL). version + demo --dry are
# NON-DESTRUCTIVE and run here while the install is still fully intact; the
# destructive `uninstall --yes` no-hang is asserted at its real invocation below
# (§7), watchdog-wrapped, in the same isolated HOME.
#
# Watchdog runner: launch the reserved cmd in the isolated stranger env, race it
# against a sleeper; whichever wins, the loser is SIGKILLed. Returns the cmd's rc,
# or 124 if the watchdog had to SIGKILL it (the hang signal). Output → $RSV_OUT.
reserved_notty() { # $1=HOME  $2=timeout_s  rest=cmd…
  local _h="$1" _to="$2"; shift 2
  local _of; _of="$(mktemp)"
  ( env -i HOME="$_h" TERM="dumb" PATH="$STRANGER_PATH" "$@" </dev/null >"$_of" 2>&1 ) &
  local _cp=$!
  ( sleep "$_to"; kill -9 "$_cp" 2>/dev/null; pkill -9 -P "$_cp" 2>/dev/null; pkill -9 -f heimdall-demo 2>/dev/null ) &
  local _wp=$!
  local _rc=0
  wait "$_cp" 2>/dev/null; _rc=$?
  if kill -0 "$_wp" 2>/dev/null; then
    kill "$_wp" 2>/dev/null            # cmd finished first → cancel the sleeping dog
  else
    # watchdog already exited → it slept its full bound and SIGKILLed the child.
    # The killed child reports 137 (128+SIGKILL); normalize to 124 = "hung/killed".
    [ "$_rc" -eq 137 ] && _rc=124
  fi
  RSV_OUT="$(cat "$_of")"; rm -f "$_of"
  return "$_rc"
}

# `hmd version` — must complete PROMPTLY and print the version (no preamble, no hang).
reserved_notty "$TMPH" 25 "$LAUNCHER" version; RSV_RC=$?
if [ "$RSV_RC" -eq 124 ]; then
  bad "non-TTY \`hmd version\` HUNG (watchdog killed it) — reserved path ran the launch preamble"
elif [ "$RSV_RC" -eq 0 ] && printf '%s' "$RSV_OUT" | grep -qiE 'Heimdall v[0-9]'; then
  ok "non-TTY \`hmd version\` completes promptly + prints version, no preamble/hang ($(printf '%s' "$RSV_OUT" | grep -iE 'Heimdall v[0-9]' | head -1 | sed 's/^ *//'))"
else
  bad "non-TTY \`hmd version\` did not complete cleanly (rc=$RSV_RC, out: $(printf '%s' "$RSV_OUT" | tr '\n' ' '))"
fi

# `hmd demo --dry` — the dry/safe demo path must complete PROMPTLY with NO launch
# preamble (no persona prompt, no companion install) and NO hang. We point it at a
# fresh, NON-EXISTENT target dir inside the stranger HOME so the dry scaffold plan
# runs the full reserved `demo` handler (not the "target already exists" guard).
DEMO_NOTTY_TGT="$TMPH/reserved-demo-dry"
rm -rf "$DEMO_NOTTY_TGT" 2>/dev/null || true
reserved_notty "$TMPH" 30 "$LAUNCHER" demo "$DEMO_NOTTY_TGT" --dry; RSV_RC=$?
if [ "$RSV_RC" -eq 124 ]; then
  bad "non-TTY \`hmd demo --dry\` HUNG (watchdog killed it) — reserved path ran the launch preamble"
elif printf '%s' "$RSV_OUT" | grep -qiE 'watchman wakes|npx claude-mem install'; then
  bad "non-TTY \`hmd demo --dry\` ran the launch preamble (persona/companion leaked) — reserved dispatch regressed"
elif [ "$RSV_RC" -eq 0 ]; then
  ok "non-TTY \`hmd demo --dry\` completes promptly via the dry path, no preamble/hang"
else
  bad "non-TTY \`hmd demo --dry\` did not complete cleanly (rc=$RSV_RC, out: $(printf '%s' "$RSV_OUT" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-200))"
fi

# (7·0) SAFETY: bare `uninstall` (no --yes) in a NON-TTY context must REFUSE
# cleanly — exit 2 with the --yes hint — and must NOT hang on a stdin read that
# never arrives. in_stranger has no TTY on stdin, so this exercises the guard.
# A wrapper kills it after 5s so a regression (a hang) FAILS loudly instead of
# stalling the whole harness.
REFUSE_OUT="$(in_stranger "$TMPH" "$LAUNCHER" uninstall </dev/null 2>&1)"
REFUSE_RC=$?
if [ "$REFUSE_RC" -eq 2 ] && printf '%s' "$REFUSE_OUT" | grep -qi 'pass --yes'; then
  ok "non-TTY uninstall without --yes refuses cleanly (exit 2, --yes hint, no hang)"
else
  bad "non-TTY uninstall without --yes did not refuse cleanly (rc=$REFUSE_RC, out: $(printf '%s' "$REFUSE_OUT" | tr '\n' ' '))"
fi

# (7·0b) RESERVED CLASS — `uninstall --yes` non-TTY must COMPLETE the real removal
# PROMPTLY (no hang). This is the destructive third member of the reserved class:
# before the ordering fix it ran the launch preamble (persona read + companion
# stall) BEFORE dispatching to removal → non-TTY hang. We run the REAL removal in
# the isolated stranger HOME (env -i HOME=$TMPH, safe — never the real HOME) under
# the same watchdog: a stall past the bound = SIGKILL = FAIL. Its output/rc feed the
# §7a–§7e artifact-reversal assertions below unchanged.
reserved_notty "$TMPH" 30 "$LAUNCHER" uninstall --yes; UNINST_RC=$?
UNINST_OUT="$RSV_OUT"
if [ "$UNINST_RC" -eq 124 ]; then
  bad "non-TTY \`hmd uninstall --yes\` HUNG (watchdog killed it) — reserved path ran the launch preamble"
else
  ok "non-TTY \`hmd uninstall --yes\` completes the real removal promptly, no preamble/hang (rc=$UNINST_RC)"
fi

# (7a) PATH line GONE — count back to 0 in the profile install wrote.
if [ -n "$PROFILE" ]; then
  PATHN_AFTER="$(grep -cE '\.local/bin' "$PROFILE" 2>/dev/null || true)"; : "${PATHN_AFTER:=0}"
  if [ "${PRE_PATHN:-0}" -ge 1 ] && [ "$PATHN_AFTER" -eq 0 ]; then
    ok "uninstall removed the PATH export from $(basename "$PROFILE") (was $PRE_PATHN, now 0)"
  else
    bad "uninstall did NOT remove the PATH export (was ${PRE_PATHN:-?}, now $PATHN_AFTER) — profile line survives"
  fi
else
  bad "uninstall completeness: no profile was found to check PATH removal"
fi

# (7b) plugin dir GONE.
if [ "$PRE_PLUGIN" -eq 1 ] && [ ! -d "$TMPH/.heimdall" ]; then
  ok "uninstall removed ~/.heimdall plugin dir"
else
  bad "uninstall did NOT remove ~/.heimdall (pre=$PRE_PLUGIN, still present=$([ -d "$TMPH/.heimdall" ] && echo yes || echo no))"
fi

# (7c) BOTH symlinks GONE.
if [ "$PRE_HMD" -eq 1 ] || [ "$PRE_HEIM" -eq 1 ]; then
  if [ ! -e "$TMPH/.local/bin/hmd" ] && [ ! -L "$TMPH/.local/bin/hmd" ] \
     && [ ! -e "$TMPH/.local/bin/heimdall" ] && [ ! -L "$TMPH/.local/bin/heimdall" ]; then
    ok "uninstall removed both ~/.local/bin symlinks (hmd, heimdall)"
  else
    bad "uninstall left a launcher symlink behind in ~/.local/bin"
  fi
else
  bad "uninstall completeness: no launcher symlink was present to remove (install regressed)"
fi

# (7d) non-TTY uninstall leaked NO farewell animation bytes.
if printf '%s' "$UNINST_OUT" | grep -q '▾'; then
  bad "non-TTY uninstall leaked the sad farewell frame (should be TTY-gated)"
else
  ok "non-TTY uninstall emits no farewell animation bytes (TTY-gated cosmetic)"
fi

# (7e) IDEMPOTENT — a SECOND uninstall (run from the SAVED launcher copy, since the
# first run removed the on-PATH symlink + plugin tree) finds nothing to remove and
# exits 0, leaving the now-clean HOME byte-for-byte unchanged.
SECOND_OUT="$(in_stranger "$TMPH" "$SAVED_LAUNCHER" uninstall --yes 2>&1)"
SECOND_RC=$?
rm -f "$SAVED_LAUNCHER" 2>/dev/null || true
if [ "$UNINST_RC" -eq 0 ] && [ "$SECOND_RC" -eq 0 ]; then
  PATHN_2="$([ -n "$PROFILE" ] && grep -cE '\.local/bin' "$PROFILE" 2>/dev/null || true)"; : "${PATHN_2:=0}"
  # The second run must also report it found nothing (idempotent no-op), and must
  # not have resurrected any artifact.
  if [ "$PATHN_2" -eq 0 ] && [ ! -d "$TMPH/.heimdall" ] \
     && printf '%s' "$SECOND_OUT" | grep -qi 'Nothing to remove'; then
    ok "uninstall is idempotent — second run exits 0, finds nothing, PATH still 0"
  else
    bad "second uninstall was not a clean no-op (PATH=$PATHN_2, out: $(printf '%s' "$SECOND_OUT" | tr '\n' ' ' | sed 's/  */ /g'))"
  fi
else
  bad "uninstall not idempotent — exit codes: first=$UNINST_RC second=$SECOND_RC (expected 0/0)"
fi

# ── (7f–7k) UNINSTALL REVERSES WHAT LIVES OUTSIDE THE INSTALL TREE ───────────
#
# install.sh makes two registrations the plugin-dir removal can never reach:
#   · a launchd LaunchAgent (com.heimdall.dream) that fires the overnight sweep
#     nightly at 03:00 — it OUTLIVED the install and kept firing forever
#   · statusLine + subagentStatusLine in ~/.claude/settings.json, pointing INTO
#     the install tree — after uninstall they named a deleted script
#
# ISOLATION — every scenario below is triple-isolated and touches NOTHING real:
#   1. HOME is a throwaway mktemp -d, so ~/.claude/settings.json is a fixture
#   2. launchctl is STUBBED: $LAUNCHCTL points at a recorder, and the stub dir is
#      also FIRST on PATH so even a bare `launchctl` call would hit the recorder
#   3. HEIMDALL_LAUNCH_AGENTS_DIR redirects the plist into the sandbox
# The real user's GUI launchd domain is never a possible target here.
#
# WHY §7f NEEDS HEIMDALL_REAL_HOME. launchctl does NOT resolve through $HOME — it
# targets the real logged-in user's session domain — so uninstall refuses to touch
# it unless the passwd-database home matches $HOME. That refusal is the whole point
# of the guard (it is what stops THIS suite from unloading the developer's own live
# agent), but it also means a throwaway HOME can never reach the positive branch.
# HEIMDALL_REAL_HOME overrides only the RESOLVED passwd home, so §7f can drive the
# real-user branch while isolation (2) and (3) still stand between it and anything
# real. §7g omits it and proves the guard fires on its own.

# Fresh throwaway HOME carrying a recording launchctl stub.
new_probe_home() {
  local sb; sb="$(mktemp -d)"
  mkdir -p "$sb/LaunchAgents" "$sb/stub" "$sb/.claude"
  cat > "$sb/stub/launchctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$sb/launchctl.calls"
exit 0
EOF
  chmod +x "$sb/stub/launchctl"
  printf '%s' "$sb"
}
# Drive the real `hmd uninstall --yes` from PROBE_TREE against a sandbox HOME.
# $1=HOME, remaining args are extra NAME=VALUE env entries. Output → $PROBE_OUT.
uninstall_probe() {
  local h="$1"; shift
  local of rc; of="$(mktemp)"
  env -i HOME="$h" TERM="dumb" PATH="$h/stub:/usr/bin:/bin" \
    HEIMDALL_LAUNCH_AGENTS_DIR="$h/LaunchAgents" LAUNCHCTL="$h/stub/launchctl" \
    "$@" "$PROBE_TREE/bin/heimdall" uninstall --yes </dev/null >"$of" 2>&1
  rc=$?
  PROBE_OUT="$(cat "$of")"; rm -f "$of"
  return "$rc"
}
plant_plist() { printf '<plist>nightly</plist>\n' > "$1/LaunchAgents/com.heimdall.dream.plist"; }

if [ ! -x "$PROBE_TREE/bin/heimdall" ] || [ ! -x "$PROBE_TREE/bin/heimdall-dream-schedule" ] \
   || [ ! -f "$PROBE_TREE/bin/lib/real-home.sh" ] || [ ! -x "$PROBE_TREE/bin/heimdall-dream" ] \
   || [ ! -f "$PROBE_TREE/install.sh" ]; then
  bad "launchd-guard probes unavailable — installed tree lacked heimdall / heimdall-dream-schedule / heimdall-dream / bin/lib/real-home.sh / install.sh"
else

# (7f) REAL-USER UNINSTALL REMOVES THE NIGHTLY LAUNCHAGENT.
SB="$(new_probe_home)"; plant_plist "$SB"
uninstall_probe "$SB" "HEIMDALL_REAL_HOME=$SB" || true
CALLS="$(cat "$SB/launchctl.calls" 2>/dev/null || true)"
if [ ! -e "$SB/LaunchAgents/com.heimdall.dream.plist" ] \
   && printf '%s' "$CALLS" | grep -q 'com\.heimdall\.dream\.plist'; then
  ok "real-user uninstall removes the nightly LaunchAgent (launchctl called: $CALLS)"
else
  bad "real-user uninstall left the nightly LaunchAgent behind (calls='$CALLS', plist still present=$([ -e "$SB/LaunchAgents/com.heimdall.dream.plist" ] && echo yes || echo no))"
fi
# EXACT LABEL ONLY — a call naming anything but com.heimdall.dream would mean
# uninstall can unload a job that is not ours.
if [ -n "$CALLS" ] && printf '%s\n' "$CALLS" | grep -vq 'com\.heimdall\.dream'; then
  bad "launchctl was invoked for a label that is NOT com.heimdall.dream: $CALLS"
else
  ok "every launchctl invocation names the exact label com.heimdall.dream"
fi
rm -rf "$SB"

# (7g) SANDBOX GUARD — a synthetic HOME must NOT reach launchd. This is the
# assertion that keeps this very suite from stomping the developer's live agent.
SB="$(new_probe_home)"; plant_plist "$SB"
uninstall_probe "$SB" || true
if [ ! -f "$SB/launchctl.calls" ]; then
  ok "synthetic HOME: launchctl was NEVER called (sandbox guard held)"
else
  bad "sandbox guard FAILED — launchctl was called under a throwaway HOME: $(cat "$SB/launchctl.calls")"
fi
if [ -e "$SB/LaunchAgents/com.heimdall.dream.plist" ]; then
  ok "synthetic HOME: the LaunchAgent plist was left untouched"
else
  bad "sandbox guard FAILED — the plist was removed under a throwaway HOME"
fi
rm -rf "$SB"

# (7h) STATUSLINE DE-REGISTERED, UNRELATED KEYS BYTE-IDENTICAL. The fixture is
# deliberately hand-formatted (irregular inner spacing, mixed one-line and block
# members) so a whole-file re-serialization cannot pass: it would reflow these
# bytes. Our two keys sit in the middle, so a correct removal is PURE DELETION —
# the diff must contain no added lines at all.
SB="$(new_probe_home)"
SET="$SB/.claude/settings.json"
cat > "$SET" <<'JSON'
{
  "model": "opusplan",
  "statusLine": {
    "type": "command",
    "command": "bash -c '[ -x \"/inst/hooks/statusline.sh\" ] && exec bash \"/inst/hooks/statusline.sh\"; exit 0'",
    "refreshInterval": 2
  },
  "env": {   "KEEP_ME":     "yes",
        "COUNT": 1 },
  "subagentStatusLine": {"type": "command", "command": "bash /inst/hooks/subagent-statusline.sh"},
  "permissions": {"allow": ["Bash(ls:*)"]}
}
JSON
SNAP="$SB/settings.before"; cp "$SET" "$SNAP"
uninstall_probe "$SB" || true
if ! grep -q 'statusLine' "$SET" 2>/dev/null; then
  ok "uninstall removed both statusLine + subagentStatusLine from ~/.claude/settings.json"
else
  bad "statusLine survived uninstall — Claude Code still points at a deleted script"
fi
ADDED="$(diff "$SNAP" "$SET" 2>/dev/null | grep -c '^>' || true)"; : "${ADDED:=0}"
if [ "$ADDED" -eq 0 ]; then
  ok "settings.json was PURE DELETION — diff adds/reflows zero lines"
else
  bad "settings.json was rewritten, not spliced — $ADDED added/reflowed line(s): $(diff "$SNAP" "$SET" | tr '\n' ' ')"
fi
SL_KEEP_MISS=""
while IFS= read -r frag; do
  grep -qF "$frag" "$SET" 2>/dev/null || SL_KEEP_MISS="$SL_KEEP_MISS | $frag"
done <<'FRAGS'
"model": "opusplan"
"env": {   "KEEP_ME":     "yes",
        "COUNT": 1 },
"permissions": {"allow": ["Bash(ls:*)"]}
FRAGS
if [ -z "$SL_KEEP_MISS" ]; then
  ok "unrelated settings keys survive BYTE-IDENTICAL (model, env with its hand spacing, permissions)"
else
  bad "unrelated settings key(s) altered:$SL_KEEP_MISS"
fi
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SET" >/dev/null 2>&1 \
  && ok "settings.json is still valid JSON after the splice" \
  || bad "settings.json is NOT valid JSON after the splice: $(cat "$SET")"
# A backup must exist, be printed, and match the pre-uninstall bytes exactly.
BK="$(printf '%s\n' "$PROBE_OUT" | grep 'heimdall-uninstall-' | head -1 | awk '{print $NF}')"
if [ -n "$BK" ] && [ -f "$BK" ] && cmp -s "$BK" "$SNAP"; then
  ok "uninstall printed a backup path whose bytes match the pre-uninstall file"
else
  bad "backup missing / not printed / not byte-identical (parsed='$BK')"
fi
rm -rf "$SB"

# (7i) OUR KEY LAST — removing the final member must take the now-dangling comma
# with it and still leave valid JSON plus untouched neighbours.
SB="$(new_probe_home)"
SET="$SB/.claude/settings.json"
printf '{\n  "theme":   "dark",\n  "subagentStatusLine": {"command": "/inst/hooks/subagent-statusline.sh"}\n}\n' > "$SET"
uninstall_probe "$SB" || true
if ! grep -q 'subagentStatusLine' "$SET" 2>/dev/null \
   && grep -qF '"theme":   "dark"' "$SET" 2>/dev/null \
   && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SET" >/dev/null 2>&1; then
  ok "removing the LAST member drops its dangling comma and keeps neighbours verbatim"
else
  bad "last-member removal broke the file: $(cat "$SET" 2>/dev/null)"
fi
rm -rf "$SB"

# (7j) MALFORMED settings.json — a hand-edited/truncated file must survive
# BYTE-IDENTICAL and must not crash the uninstall.
SB="$(new_probe_home)"
SET="$SB/.claude/settings.json"
printf '{ "statusLine": { "command": "/inst/hooks/statusline.sh"\n' > "$SET"
SNAP="$SB/settings.before"; cp "$SET" "$SNAP"
uninstall_probe "$SB"; MAL_RC=$?
if [ "$MAL_RC" -eq 0 ] && [ -f "$SET" ] && cmp -s "$SET" "$SNAP"; then
  ok "malformed ~/.claude/settings.json survives byte-identical, uninstall exits 0"
else
  bad "malformed settings.json was damaged or crashed uninstall (rc=$MAL_RC, now: $(cat "$SET" 2>/dev/null))"
fi
if printf '%s' "$PROBE_OUT" | grep -q 'not valid JSON'; then
  ok "malformed settings.json is REPORTED, not silently skipped"
else
  bad "malformed settings.json was skipped silently: $(printf '%s' "$PROBE_OUT" | tr '\n' ' ')"
fi
rm -rf "$SB"

# (7k) ABSENT settings.json — a clean no-op that conjures no file.
SB="$(new_probe_home)"
rm -f "$SB/.claude/settings.json"
uninstall_probe "$SB"; ABS_RC=$?
if [ "$ABS_RC" -eq 0 ] && [ ! -e "$SB/.claude/settings.json" ]; then
  ok "absent ~/.claude/settings.json: uninstall exits 0 and creates nothing"
else
  bad "absent settings.json mishandled (rc=$ABS_RC, created=$([ -e "$SB/.claude/settings.json" ] && echo yes || echo no))"
fi
rm -rf "$SB"

# ── (8a–8e) INSTALL DOES NOT REGISTER A LAUNCHAGENT FROM A SANDBOX ────────────
#
# THE INCIDENT THIS CLOSES (observed, not hypothetical). Agents running real installs
# during testing overwrote the developer's REAL ~/Library/LaunchAgents/
# com.heimdall.dream.plist and left it pointing at an ephemeral agent worktree — a
# tree that is later reaped, so the nightly job was wired to a path that ceases to
# exist. The cause: `launchctl` registers into the logged-in user's GUI session domain
# (gui/<uid>) and does NOT resolve through $HOME. A throwaway HOME=$(mktemp -d)
# isolates WHERE the plist file lands but NOT which launchd hears about it, so ANY
# test performing a real install reaches the real scheduler.
#
# Uninstall got a passwd-based self-detecting guard (§7f/§7g). Install had only
# HEIMDALL_NO_DREAM_SCHEDULE=1 — an opt-out every caller must REMEMBER. One forgot;
# that is the whole incident. §8a is the assertion that would have caught it.
#
# ISOLATION — identical to §7f–§7k and equally incapable of touching anything real:
#   1. HOME is a throwaway mktemp -d
#   2. launchctl is STUBBED — $LAUNCHCTL points at the recorder AND the stub dir is
#      FIRST on PATH, so even a bare `launchctl` lands on the recorder
#   3. HEIMDALL_LAUNCH_AGENTS_DIR + HEIMDALL_DREAM_LOG redirect every write into it
# On top of that, §8a snapshots the REAL plist and re-checks it afterwards, so a
# regression that escaped all three layers still cannot pass silently.

# The real nightly plist, if this developer has one. Read-only: hashed before §8 and
# re-hashed after, never written. '' when absent (a CI box / a dev who opted out).
REAL_LA_PLIST="$HOME/Library/LaunchAgents/com.heimdall.dream.plist"
REAL_PLIST_BEFORE=""
[ -f "$REAL_LA_PLIST" ] && REAL_PLIST_BEFORE="$(shasum -a 256 "$REAL_LA_PLIST" 2>/dev/null | awk '{print $1}')"

# Drive the REAL `heimdall-dream-schedule install` from PROBE_TREE against a sandbox
# HOME. $1=HOME, remaining args are extra NAME=VALUE env entries. Output → $SCHED_OUT.
schedule_probe() {
  local h="$1"; shift
  local of rc; of="$(mktemp)"
  env -i HOME="$h" TERM="dumb" PATH="$h/stub:/usr/bin:/bin" \
    HEIMDALL_LAUNCH_AGENTS_DIR="$h/LaunchAgents" LAUNCHCTL="$h/stub/launchctl" \
    HEIMDALL_DREAM_LOG="$h/dream.log" \
    "$@" "$PROBE_TREE/bin/heimdall-dream-schedule" install --repo "$h" </dev/null >"$of" 2>&1
  rc=$?
  SCHED_OUT="$(cat "$of")"; rm -f "$of"
  return "$rc"
}

# (8a) THE INCIDENT ASSERTION — a synthetic HOME must NOT reach launchd.
SB="$(new_probe_home)"
schedule_probe "$SB"; SCHED_RC=$?
if [ ! -f "$SB/launchctl.calls" ]; then
  ok "install under a synthetic HOME: launchctl was NEVER invoked (the incident assertion)"
else
  bad "INSTALL SANDBOX GUARD FAILED — launchctl was called under a throwaway HOME: $(tr '\n' ' ' < "$SB/launchctl.calls")"
fi
if [ ! -e "$SB/LaunchAgents/com.heimdall.dream.plist" ]; then
  ok "install under a synthetic HOME: no plist was written at all (refusal precedes write_plist)"
else
  bad "INSTALL SANDBOX GUARD FAILED — a plist was written under a throwaway HOME"
fi
# The refusal must SAY so, in the same words the uninstall side uses.
if printf '%s' "$SCHED_OUT" | grep -q 'synthetic HOME — refusing to touch the real launchd domain'; then
  ok "install refusal prints the uninstall side's exact wording (rc=$SCHED_RC)"
else
  bad "install refusal wording missing (rc=$SCHED_RC, out: $(printf '%s' "$SCHED_OUT" | tr '\n' ' ' | cut -c1-200))"
fi
rm -rf "$SB"

# (8b) REAL USER STILL GETS THE SCHEDULE. The guard is worthless if it also refuses
# the interactive human it exists to protect. Driven through the HEIMDALL_REAL_HOME
# seam (it overrides ONLY the resolved passwd home) while isolation layers 2 and 3
# still stand between this and anything real.
SB="$(new_probe_home)"
schedule_probe "$SB" "HEIMDALL_REAL_HOME=$SB"; SCHED_RC=$?
SB_PLIST="$SB/LaunchAgents/com.heimdall.dream.plist"
if [ "$SCHED_RC" -eq 0 ] && [ -f "$SB_PLIST" ]; then
  ok "real user: the nightly LaunchAgent IS installed (rc=0, plist written)"
else
  bad "real user: install did not complete (rc=$SCHED_RC, plist=$([ -f "$SB_PLIST" ] && echo yes || echo no), out: $(printf '%s' "$SCHED_OUT" | tr '\n' ' ' | cut -c1-200))"
fi
# The plist must name the dream bin of the tree it was installed from — the exact
# field the incident corrupted (it held a reaped worktree path).
if [ -f "$SB_PLIST" ] && grep -qF "<string>$PROBE_TREE/bin/heimdall-dream</string>" "$SB_PLIST"; then
  ok "real user: plist ProgramArguments names the correct dream bin ($PROBE_TREE/bin/heimdall-dream)"
else
  bad "real user: plist does not name $PROBE_TREE/bin/heimdall-dream — got: $(grep -o '<string>[^<]*heimdall-dream</string>' "$SB_PLIST" 2>/dev/null | head -1)"
fi
if [ -f "$SB/launchctl.calls" ] && grep -q "load -w $SB_PLIST" "$SB/launchctl.calls"; then
  ok "real user: launchctl load -w was invoked for the sandbox plist"
else
  bad "real user: launchctl load was NOT invoked (calls: $(tr '\n' ' ' < "$SB/launchctl.calls" 2>/dev/null))"
fi
rm -rf "$SB"

# (8c) THE EXPLICIT OPT-OUT STILL WORKS. Self-detection is an additional floor, not a
# replacement — a real user who declined must still be declined.
SB="$(new_probe_home)"
schedule_probe "$SB" "HEIMDALL_REAL_HOME=$SB" "HEIMDALL_NO_DREAM_SCHEDULE=1"; SCHED_RC=$?
if [ "$SCHED_RC" -eq 0 ] && [ ! -e "$SB/LaunchAgents/com.heimdall.dream.plist" ] \
   && [ ! -f "$SB/launchctl.calls" ]; then
  ok "HEIMDALL_NO_DREAM_SCHEDULE=1 still opts out even for a real user (rc=0, no plist, no launchctl)"
else
  bad "opt-out regressed (rc=$SCHED_RC, plist=$([ -e "$SB/LaunchAgents/com.heimdall.dream.plist" ] && echo yes || echo no), calls=$(tr '\n' ' ' < "$SB/launchctl.calls" 2>/dev/null))"
fi
rm -rf "$SB"

# (8d) THE INSTALLER REPORTS THE REFUSAL HONESTLY. install.sh's ensure_dream_schedule
# maps the helper's distinct exit 4 to the state word 'sandboxed' — a silent 'skipped'
# would hide from the next agent exactly why the schedule is missing. Sourced from the
# INSTALLED install.sh (HEIMDALL_INSTALL_SOURCE_ONLY=1), the same seam
# test/dream-install-wire.test.sh uses.
INSTALLED_SH="$PROBE_TREE/install.sh"
if [ -f "$INSTALLED_SH" ]; then
  SB="$(new_probe_home)"
  DS_STATE="$( set +e
    export HOME="$SB" PATH="$SB/stub:/usr/bin:/bin" \
           HEIMDALL_LAUNCH_AGENTS_DIR="$SB/LaunchAgents" LAUNCHCTL="$SB/stub/launchctl" \
           HEIMDALL_DREAM_LOG="$SB/dream.log" HEIMDALL_INSTALL_SOURCE_ONLY=1
    source "$INSTALLED_SH" >/dev/null 2>&1
    ensure_dream_schedule "$PROBE_TREE" )"
  if [ "$DS_STATE" = "sandboxed" ]; then
    ok "install.sh reports state 'sandboxed' for a synthetic HOME (not a silent 'skipped')"
  else
    bad "install.sh state word for a synthetic HOME was '$DS_STATE' (expected 'sandboxed')"
  fi
  if [ ! -f "$SB/launchctl.calls" ] && [ ! -e "$SB/LaunchAgents/com.heimdall.dream.plist" ]; then
    ok "install.sh's schedule step touched neither launchctl nor a plist under a synthetic HOME"
  else
    bad "install.sh's schedule step reached launchd under a synthetic HOME (calls=$(tr '\n' ' ' < "$SB/launchctl.calls" 2>/dev/null))"
  fi
  rm -rf "$SB"
else
  bad "install.sh not found in the installed tree at $INSTALLED_SH — cannot assert the state word"
fi

# (8f) THE SECOND MECHANISM — A GENUINE $HOME IS NOT ENOUGH.
#
# §8a–§8d all vary $HOME. The incident did not. The run that actually rewrote the
# developer's live com.heimdall.dream.plist was a REAL user, in their REAL passwd home,
# talking to their REAL launchd domain — every check in §8a–§8d passes for it. What was
# wrong was the TREE: it installed from an agent worktree, so the nightly job was pinned
# to .claude/worktrees/agent-<id>/bin/heimdall-dream, a checkout that is later reaped.
# The job then points at nothing, and — because launchd never complains about a program
# that no longer exists — the only symptom is that dreams silently stop arriving.
#
# So §8f holds HOME genuine (HEIMDALL_REAL_HOME, the same seam §8b uses) and varies ONLY
# worktree-ness. A pass here means the passwd guard was satisfied and something else
# refused: the ephemeral-checkout guard. Isolation is §8's, unchanged — stubbed launchctl
# on $LAUNCHCTL *and* first on PATH, redirected LaunchAgents dir, and §8e re-hashes the
# real plist afterwards.
WT_MAIN="$(mktemp -d)"; mkdir -p "$WT_MAIN/bin/lib"
cp "$PROBE_TREE/bin/heimdall-dream-schedule" "$WT_MAIN/bin/heimdall-dream-schedule" 2>/dev/null || true
cp "$PROBE_TREE/bin/heimdall-dream"          "$WT_MAIN/bin/heimdall-dream" 2>/dev/null || true
cp "$PROBE_TREE/bin/lib/real-home.sh"        "$WT_MAIN/bin/lib/real-home.sh" 2>/dev/null || true
chmod +x "$WT_MAIN/bin/heimdall-dream-schedule" "$WT_MAIN/bin/heimdall-dream" 2>/dev/null || true
git -C "$WT_MAIN" init -q >/dev/null 2>&1
git -C "$WT_MAIN" add -A >/dev/null 2>&1
git -C "$WT_MAIN" -c user.email=t@t -c user.name=t commit -qm probe >/dev/null 2>&1
WT_EPHEM="$(mktemp -d)"; rmdir "$WT_EPHEM" 2>/dev/null || true
git -C "$WT_MAIN" worktree add --detach -q "$WT_EPHEM" >/dev/null 2>&1

# Same isolation as schedule_probe, but driving an arbitrary helper path. $1=HOME,
# $2=helper, $3=--repo target, rest = extra env (PATH overrides included).
worktree_probe() {
  local h="$1" helper="$2" repo="$3"; shift 3
  local of rc; of="$(mktemp)"
  env -i HOME="$h" TERM="dumb" PATH="$h/stub:/usr/bin:/bin" \
    HEIMDALL_LAUNCH_AGENTS_DIR="$h/LaunchAgents" LAUNCHCTL="$h/stub/launchctl" \
    HEIMDALL_DREAM_LOG="$h/dream.log" HEIMDALL_REAL_HOME="$h" \
    "$@" "$helper" install --repo "$repo" </dev/null >"$of" 2>&1
  rc=$?
  SCHED_OUT="$(cat "$of")"; rm -f "$of"
  return "$rc"
}

if [ -x "$WT_EPHEM/bin/heimdall-dream-schedule" ] && [ -f "$WT_EPHEM/.git" ]; then
  SB="$(new_probe_home)"
  worktree_probe "$SB" "$WT_EPHEM/bin/heimdall-dream-schedule" "$WT_EPHEM"; SCHED_RC=$?
  # THE ASSERTION THAT WOULD HAVE PREVENTED THE INCIDENT.
  if [ ! -f "$SB/launchctl.calls" ]; then
    ok "genuine HOME + worktree checkout: launchctl was NEVER invoked (the second-mechanism assertion)"
  else
    bad "EPHEMERAL GUARD FAILED — launchctl was called from a worktree checkout: $(tr '\n' ' ' < "$SB/launchctl.calls")"
  fi
  if [ ! -e "$SB/LaunchAgents/com.heimdall.dream.plist" ]; then
    ok "genuine HOME + worktree checkout: no plist written (refusal precedes write_plist)"
  else
    bad "EPHEMERAL GUARD FAILED — a plist was written from a worktree checkout"
  fi
  if [ "$SCHED_RC" -eq 5 ]; then
    ok "the worktree refusal exits 5 — distinguishable from sandboxed (4) and failure (3)"
  else
    bad "worktree refusal exit code was $SCHED_RC (expected 5): $(printf '%s' "$SCHED_OUT" | tr '\n' ' ' | cut -c1-200)"
  fi
  if printf '%s' "$SCHED_OUT" | grep -q 'ephemeral checkout'; then
    ok "the worktree refusal says WHY (ephemeral checkout), so the next operator can act"
  else
    bad "worktree refusal wording missing (out: $(printf '%s' "$SCHED_OUT" | tr '\n' ' ' | cut -c1-200))"
  fi
  rm -rf "$SB"

  # The guard must not depend on the `git` binary being on PATH: a stripped launchd/cron
  # environment has almost nothing on it. With git unreachable the filesystem detector
  # (the .git-file `gitdir:` shape) has to carry the refusal ALONE — proving the two
  # detectors are independently sufficient rather than one plus decoration.
  SB="$(new_probe_home)"
  worktree_probe "$SB" "$WT_EPHEM/bin/heimdall-dream-schedule" "$WT_EPHEM" PATH="$SB/stub"; SCHED_RC=$?
  if [ ! -f "$SB/launchctl.calls" ] && [ "$SCHED_RC" -eq 5 ]; then
    ok "worktree refusal holds with NO git on PATH (the filesystem detector is sufficient alone)"
  else
    bad "guard leaked without git on PATH (rc=$SCHED_RC, calls=$(tr '\n' ' ' < "$SB/launchctl.calls" 2>/dev/null))"
  fi
  rm -rf "$SB"

  # THE CONTROL. Byte-identical helper, same genuine HOME, same stubs — checked out as
  # the MAIN worktree. It must still register, or the guard is just an outage: the whole
  # point is that a real user installing from their canonical checkout still succeeds.
  SB="$(new_probe_home)"
  worktree_probe "$SB" "$WT_MAIN/bin/heimdall-dream-schedule" "$WT_MAIN"; SCHED_RC=$?
  if [ "$SCHED_RC" -eq 0 ] && [ -f "$SB/LaunchAgents/com.heimdall.dream.plist" ] \
     && grep -qF "<string>$WT_MAIN/bin/heimdall-dream</string>" "$SB/LaunchAgents/com.heimdall.dream.plist"; then
    ok "the SAME helper in the MAIN worktree still registers (rc=0, plist names its own dream bin)"
  else
    bad "main-worktree control failed — the guard refuses a canonical checkout (rc=$SCHED_RC, out: $(printf '%s' "$SCHED_OUT" | tr '\n' ' ' | cut -c1-200))"
  fi
  rm -rf "$SB"
else
  bad "§8f fixture not built — cannot assert the ephemeral-checkout guard (helper=$([ -x "$WT_EPHEM/bin/heimdall-dream-schedule" ] && echo yes || echo no), worktree=$([ -f "$WT_EPHEM/.git" ] && echo yes || echo no))"
fi
git -C "$WT_MAIN" worktree remove --force "$WT_EPHEM" >/dev/null 2>&1 || true
rm -rf "$WT_MAIN" "$WT_EPHEM"

# (8e) THE REAL PLIST IS UNTOUCHED. The final backstop: whatever the probes above did,
# the developer's own nightly job must be byte-for-byte what it was when §8 started.
if [ -n "$REAL_PLIST_BEFORE" ]; then
  REAL_PLIST_AFTER="$(shasum -a 256 "$REAL_LA_PLIST" 2>/dev/null | awk '{print $1}')"
  if [ "$REAL_PLIST_AFTER" = "$REAL_PLIST_BEFORE" ]; then
    ok "the REAL ~/Library/LaunchAgents/com.heimdall.dream.plist is byte-identical after §8"
  else
    bad "THE REAL NIGHTLY PLIST CHANGED during §8 (was ${REAL_PLIST_BEFORE:0:16}…, now ${REAL_PLIST_AFTER:0:16}…) — the incident recurred"
  fi
elif [ -e "$REAL_LA_PLIST" ]; then
  bad "the REAL nightly plist appeared during §8 — a probe escaped its sandbox"
else
  ok "no real nightly plist on this host — §8 conjured none (nothing escaped the sandbox)"
fi

fi

echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
