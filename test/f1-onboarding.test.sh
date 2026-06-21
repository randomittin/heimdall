#!/usr/bin/env bash
#
# f1-onboarding.test.sh — deterministic harness for the F1 launch resolution
# order wired into bin/heimdall: orient → resume → persona-check → onboard-if-cold.
#
# This proves the WIRING (F1 Wave 2): bin/heimdall consumes the already-merged
# standalone pieces — the front-door classifier (bin/heimdall-frontdoor), the SI-1
# comprehension capsule (bin/heimdall-comprehend), and the global persona store
# (bin/heimdall-persona) — in the documented order, with the cold-vs-warm contract
# (a cold first run completes ALL setup, including persona, BEFORE the first task;
# a warm run resumes and skips straight to work). It is the launch-path sibling of
# test/f1-frontdoor.test.sh, which proves the standalone units.
#
# HOW IT DRIVES THE LAUNCHER WITHOUT A LIVE MODEL CALL (mirrors the v2.0.3
# first-run-ordering probe in test/install-stranger.sh):
#   - HEIMDALL_TRACE_ORDER=<file>  — the launcher appends one ordered marker per
#     phase (orient, setup:auth, setup:companion, setup:skills, resume,
#     persona-check, onboard, launch:task) and SHORT-CIRCUITS just before the real
#     `claude … -p` exec. We assert the ORDER of markers, never run a task.
#   - ANTHROPIC_API_KEY=<probe>     — makes ensure_auth a no-op no-login.
#   - a fake `claude` on PATH       — makes `claude plugins …` an instant no-op so
#     companion setup never does a real network install.
#   - HEIMDALL_NO_INTRO=1 / non-TTY — no boot animation, no persona prompt hang.
#   - HEIMDALL_NO_REUSE_METRIC=1    — the reuse metric never runs (irrelevant here).
#
# ISOLATION (deterministic + repeatable): the launcher writes its first-run marker
# (.setup-done) into its PLUGIN_DIR, and persists the persona into HEIMDALL_HOME.
# So each run uses (a) a COPIED plugin tree in a temp dir — the marker lands there,
# never in the real checkout — and (b) a temp HEIMDALL_HOME. Flipping the temp
# marker's presence flips cold/warm; flipping the temp persona.json flips
# set/unset. Nothing touches the developer's real state.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

need() { command -v "$1" >/dev/null 2>&1 || { echo "FATAL: $1 not found on PATH"; exit 2; }; }
need git; need python3

[ -x "$REPO/bin/heimdall" ]            || { echo "FATAL: bin/heimdall not executable"; exit 2; }
[ -x "$REPO/bin/heimdall-frontdoor" ] || { echo "FATAL: bin/heimdall-frontdoor missing"; exit 2; }
[ -x "$REPO/bin/heimdall-comprehend" ]|| { echo "FATAL: bin/heimdall-comprehend missing"; exit 2; }
[ -x "$REPO/bin/heimdall-persona" ]   || { echo "FATAL: bin/heimdall-persona missing"; exit 2; }

# ── Build an ISOLATED copy of the plugin tree (marker lands here, not the repo) ──
# Copy bin/ (the launcher + every sibling it resolves) and .claude-plugin/ (so
# heimdall_version() resolves a version). The copied launcher resolves its own
# PLUGIN_DIR from its location, so PLUGIN_DIR = $TPLUG and SETUP_MARKER =
# $TPLUG/.setup-done — fully isolated and freely deletable.
TPLUG="$(mktemp -d)"
mkdir -p "$TPLUG/bin" "$TPLUG/.claude-plugin"
cp -R "$REPO/bin/." "$TPLUG/bin/"
[ -f "$REPO/.claude-plugin/plugin.json" ] && cp "$REPO/.claude-plugin/plugin.json" "$TPLUG/.claude-plugin/" 2>/dev/null || true
LAUNCHER="$TPLUG/bin/heimdall"
chmod +x "$LAUNCHER" 2>/dev/null || true

# ── A fake `claude` that makes companion-plugin installs an instant no-op ────────
FAKE_DIR="$(mktemp -d)"
cat > "$FAKE_DIR/claude" <<'EOF'
#!/usr/bin/env bash
# harness intercept — companion-plugin network installs become instant no-ops.
if [ "${1:-}" = "plugins" ]; then exit 0; fi
exit 0
EOF
chmod +x "$FAKE_DIR/claude"
PROBE_PATH="$FAKE_DIR:/usr/bin:/bin"

trap 'rm -rf "$TPLUG" "$FAKE_DIR"' EXIT

# set_marker / clear_marker — flip the isolated plugin's first-run marker.
set_marker()   { : > "$TPLUG/.setup-done"; }
clear_marker() { rm -f "$TPLUG/.setup-done"; }

# run_launch WORKDIR TRACE HEIMDALL_HOME [STDERR_OUT] — drive the launcher's main
# path in a stripped, non-TTY env, FROM the work dir (the launcher classifies
# $(pwd)). Stdin is </dev/null so any unguarded read would hang (it must not — we
# assert that). The trace short-circuit means no real `claude -p` is ever reached.
# When STDERR_OUT is given, the run's stderr (which carries the F1 phase
# diagnostics in trace mode, e.g. the orient capsule action) is captured to it.
run_launch() {
  local wd="$1" trace="$2" hh="$3" errf="${4:-/dev/null}"
  env -i HOME="$(dirname "$hh")" TERM="dumb" PATH="$PROBE_PATH" \
    HEIMDALL_HOME="$hh" ANTHROPIC_API_KEY="sk-ant-f1-probe" \
    HEIMDALL_NO_INTRO=1 HEIMDALL_NO_REUSE_METRIC=1 \
    HEIMDALL_TRACE_ORDER="$trace" \
    bash -c "cd '$wd' && exec '$LAUNCHER' 'noop f1 probe'" </dev/null >/dev/null 2>"$errf"
}

# line_of MARKER TRACE — 1-based line number of the first exact-match marker (or empty).
line_of() { grep -n "^$1\$" "$2" 2>/dev/null | head -1 | cut -d: -f1; }
has_marker() { grep -q "^$1\$" "$2" 2>/dev/null; }

echo "f1-onboarding harness  repo=$REPO"
echo "--------------------------------------------------------------------"

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ 1. COLD FIRST RUN — empty dir, no first-run marker, persona unset.        ║
# ║    Contract: orient → (setup:auth/companion/skills) → persona-check →     ║
# ║    onboard, ALL BEFORE launch:task. No setup interleaved past launch.     ║
# ╚══════════════════════════════════════════════════════════════════════════╝
COLD_WD="$(mktemp -d)"                 # empty → front door classifies empty-dir
COLD_HH="$(mktemp -d)/.heimdall"       # fresh home → persona unset
COLD_TRACE="$(mktemp -d)/cold.trace"
clear_marker                           # genuine cold first run

run_launch "$COLD_WD" "$COLD_TRACE" "$COLD_HH"

if [ ! -f "$COLD_TRACE" ]; then
  bad "cold run: launcher emitted no trace (HEIMDALL_TRACE_ORDER ignored)"
else
  COLD_ORDER="$(tr '\n' ' ' < "$COLD_TRACE")"
  L_ORI="$(line_of orient          "$COLD_TRACE")"
  L_AUT="$(line_of setup:auth       "$COLD_TRACE")"
  L_COM="$(line_of setup:companion  "$COLD_TRACE")"
  L_SKI="$(line_of setup:skills     "$COLD_TRACE")"
  L_PER="$(line_of persona-check    "$COLD_TRACE")"
  L_ONB="$(line_of onboard          "$COLD_TRACE")"
  L_LCH="$(line_of launch:task      "$COLD_TRACE")"

  # Every required cold marker present.
  if [ -n "$L_ORI" ] && [ -n "$L_AUT" ] && [ -n "$L_COM" ] && [ -n "$L_SKI" ] \
     && [ -n "$L_PER" ] && [ -n "$L_ONB" ] && [ -n "$L_LCH" ]; then
    ok "cold run: all phase markers present (orient, setup×3, persona-check, onboard, launch)"
  else
    bad "cold run: missing a phase marker (trace: $COLD_ORDER)"
  fi

  # orient is FIRST.
  if [ -n "$L_ORI" ] && [ "$L_ORI" = "1" ]; then
    ok "cold run: orient is the first phase"
  else
    bad "cold run: orient was not first (trace: $COLD_ORDER)"
  fi

  # ALL setup completes BEFORE launch (the stranger-test ordering contract).
  if [ -n "$L_AUT" ] && [ -n "$L_COM" ] && [ -n "$L_SKI" ] && [ -n "$L_LCH" ] \
     && [ "$L_AUT" -lt "$L_LCH" ] && [ "$L_COM" -lt "$L_LCH" ] && [ "$L_SKI" -lt "$L_LCH" ]; then
    ok "cold run: auth+companion+skills setup complete BEFORE launch (no interleaving)"
  else
    bad "cold run: setup interleaved with/deferred past launch (trace: $COLD_ORDER)"
  fi

  # persona-check AND onboard both precede launch (setup-incl-persona before task).
  if [ -n "$L_PER" ] && [ -n "$L_ONB" ] && [ -n "$L_LCH" ] \
     && [ "$L_PER" -lt "$L_LCH" ] && [ "$L_ONB" -lt "$L_LCH" ]; then
    ok "cold run: persona-check + onboard precede the task launch"
  else
    bad "cold run: persona-check/onboard did not precede launch (trace: $COLD_ORDER)"
  fi

  # The full documented order: orient < setup:auth < persona-check < onboard < launch.
  if [ -n "$L_ORI" ] && [ -n "$L_AUT" ] && [ -n "$L_PER" ] && [ -n "$L_ONB" ] && [ -n "$L_LCH" ] \
     && [ "$L_ORI" -lt "$L_AUT" ] && [ "$L_AUT" -lt "$L_PER" ] \
     && [ "$L_PER" -lt "$L_ONB" ] && [ "$L_ONB" -lt "$L_LCH" ]; then
    ok "cold run: order is orient → setup → persona-check → onboard → launch"
  else
    bad "cold run: resolution order wrong (trace: $COLD_ORDER)"
  fi
fi

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ 2. WARM RUN — existing codebase + checkpoint + persona already set.       ║
# ║    Contract: orient → resume → (persona skipped) → launch, NO onboard.    ║
# ╚══════════════════════════════════════════════════════════════════════════╝
WARM_WD="$(mktemp -d)"
WARM_HH="$(mktemp -d)/.heimdall"
WARM_TRACE="$(mktemp -d)/warm.trace"

# Real existing codebase: git history + source, plus a checkpoint to resume.
(
  cd "$WARM_WD"
  git init -q
  git config user.email "t@t.t"; git config user.name "t"
  printf 'print("hi")\n' > app.py
  git add app.py
  git commit -qm "init" >/dev/null 2>&1
)
mkdir -p "$WARM_WD/.planning"
printf '# CHECKPOINT\nResume the in-flight work here.\n' > "$WARM_WD/.planning/CHECKPOINT.md"

# Persona ALREADY set → persona-check must skip the prompt (and never re-write).
mkdir -p "$WARM_HH"
printf '{"version":1,"persona":"coder","set_at":"2026-06-22T00:00:00+00:00"}\n' > "$WARM_HH/persona.json"

set_marker   # warm: first-run marker present → onboarding must NOT fire

run_launch "$WARM_WD" "$WARM_TRACE" "$WARM_HH"

if [ ! -f "$WARM_TRACE" ]; then
  bad "warm run: launcher emitted no trace"
else
  WARM_ORDER="$(tr '\n' ' ' < "$WARM_TRACE")"
  W_ORI="$(line_of orient       "$WARM_TRACE")"
  W_RES="$(line_of resume       "$WARM_TRACE")"
  W_PER="$(line_of persona-check "$WARM_TRACE")"
  W_LCH="$(line_of launch:task  "$WARM_TRACE")"

  if [ -n "$W_ORI" ] && [ -n "$W_RES" ] && [ -n "$W_PER" ] && [ -n "$W_LCH" ] \
     && [ "$W_ORI" -lt "$W_RES" ] && [ "$W_RES" -lt "$W_LCH" ] && [ "$W_PER" -lt "$W_LCH" ]; then
    ok "warm run: orient → resume → persona-check → launch (in order)"
  else
    bad "warm run: order wrong / a marker missing (trace: $WARM_ORDER)"
  fi

  # NO onboarding on a warm run — the critical regression guard.
  if has_marker onboard "$WARM_TRACE"; then
    bad "warm run: onboarding fired on a warm run (trace: $WARM_ORDER)"
  else
    ok "warm run: NO onboard marker (warm runs skip onboarding)"
  fi

  # resume fired BECAUSE there is a checkpoint to resume.
  if [ -n "$W_RES" ]; then
    ok "warm run: resume fired (checkpoint present)"
  else
    bad "warm run: resume did not fire despite a checkpoint (trace: $WARM_ORDER)"
  fi
fi

# Persona was NOT re-prompted / NOT re-written: still exactly the value we set.
WARM_PVAL="$(HEIMDALL_HOME="$WARM_HH" "$REPO/bin/heimdall-persona" get 2>/dev/null)"
if [ -f "$WARM_HH/persona.json" ] && [ "$WARM_PVAL" = "coder" ]; then
  ok "warm run: persona remains 'coder' (set-once, not re-prompted)"
else
  bad "warm run: persona changed unexpectedly (got: $WARM_PVAL)"
fi

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ 3. ORIENT REUSES SI-1 — a warm run LOADS the comprehension capsule        ║
# ║    (does NOT re-derive it). Proven via the derivation counter: a pre-warm  ║
# ║    derive sets count=1; the launcher's orient must leave it at 1.          ║
# ╚══════════════════════════════════════════════════════════════════════════╝
SI1_WD="$(mktemp -d)"
SI1_HH="$(mktemp -d)/.heimdall"
SI1_TRACE="$(mktemp -d)/si1.trace"
(
  cd "$SI1_WD"
  git init -q; git config user.email "t@t.t"; git config user.name "t"
  printf 'def f():\n    return 1\n' > lib.py
  git add lib.py; git commit -qm "init" >/dev/null 2>&1
)
set_marker  # warm so orient is the only thing touching the capsule

# Pre-warm the capsule (derivation #1). Capsule lives at $SI1_HH/context.json.
HEIMDALL_HOME="$SI1_HH" "$REPO/bin/heimdall-comprehend" comprehend "$SI1_WD" >/dev/null 2>&1
CAPSULE="$SI1_HH/context.json"
COUNT_BEFORE="$(python3 -c "import json;print(json.load(open('$CAPSULE'))['derivation']['count'])" 2>/dev/null)"

# Capture the launcher's stderr so we can read orient's own capsule-action verdict.
SI1_ERR="$(mktemp -d)/si1.err"
run_launch "$SI1_WD" "$SI1_TRACE" "$SI1_HH" "$SI1_ERR"

COUNT_AFTER="$(python3 -c "import json;print(json.load(open('$CAPSULE'))['derivation']['count'])" 2>/dev/null)"

# The reuse proof is the derivation counter: orient LOADED the fresh capsule, so
# the derivation count did NOT advance (a re-derive would bump it to 2). Note: we
# do NOT assert the capsule is still 'fresh' AFTER the run — a normal launch
# legitimately writes CLAUDE.md into the work dir (ensure_project_claude_md),
# which drifts the structural fingerprint; that post-launch drift is expected and
# is NOT evidence orient re-derived. The counter is the load-not-rederive signal.
if [ "$COUNT_BEFORE" = "1" ] && [ "$COUNT_AFTER" = "1" ]; then
  ok "orient reuses SI-1: capsule LOADED not re-derived (derivation count stayed $COUNT_AFTER)"
else
  bad "orient reuses SI-1: derivation count moved $COUNT_BEFORE → $COUNT_AFTER (expected 1 → 1)"
fi

# Orient's own diagnostic (emitted on stderr in trace mode) reports reuse.
if grep -q 'reused-cached' "$SI1_ERR" 2>/dev/null; then
  ok "orient reuses SI-1: orient reported 'reused-cached' (loaded the fresh capsule)"
else
  bad "orient reuses SI-1: orient did not report a cached reuse (stderr: $(tr '\n' ' ' < "$SI1_ERR" 2>/dev/null))"
fi
rm -rf "$(dirname "$SI1_ERR")" 2>/dev/null || true

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ 4. PERSONA persists set-once + non-TTY does NOT hang.                     ║
# ║    The cold run above had stdin </dev/null and persona unset — if the     ║
# ║    prompt read an unguarded stdin it would HANG; the harness completing   ║
# ║    proves it did not. Here we also assert: a non-TTY cold run DEFERS the   ║
# ║    persona (leaves it unset, never invents one), and an explicit `set`     ║
# ║    persists globally across processes.                                     ║
# ╚══════════════════════════════════════════════════════════════════════════╝
# 4a. The cold run (1) ran with persona unset and stdin closed; it returned, so it
#     did not hang. Confirm it DEFERRED rather than inventing a persona.
COLD_PVAL="$(HEIMDALL_HOME="$COLD_HH" "$REPO/bin/heimdall-persona" get 2>/dev/null)"
if [ "$COLD_PVAL" = "unset" ]; then
  ok "persona non-TTY: cold run deferred the prompt (persona left unset, never invented)"
else
  bad "persona non-TTY: cold run wrote a persona without a TTY (got: $COLD_PVAL)"
fi

# 4b. Explicit set-once persists GLOBALLY: write in one process, read in another.
SETONCE_HH="$(mktemp -d)/.heimdall"
HEIMDALL_HOME="$SETONCE_HH" "$REPO/bin/heimdall-persona" set non-coder >/dev/null 2>&1
SETONCE_READBACK="$(HEIMDALL_HOME="$SETONCE_HH" "$REPO/bin/heimdall-persona" get 2>/dev/null)"
if [ "$SETONCE_READBACK" = "non-coder" ]; then
  ok "persona set-once: persisted globally, read back in a fresh process (non-coder)"
else
  bad "persona set-once: read back '$SETONCE_READBACK' (expected non-coder)"
fi

# 4c. A SECOND launcher run with the persona now set must SKIP the prompt and leave
#     the value untouched (never re-prompt), and complete (no hang).
SKIP_WD="$(mktemp -d)"; SKIP_TRACE="$(mktemp -d)/skip.trace"
set_marker
run_launch "$SKIP_WD" "$SKIP_TRACE" "$SETONCE_HH"
SKIP_AFTER="$(HEIMDALL_HOME="$SETONCE_HH" "$REPO/bin/heimdall-persona" get 2>/dev/null)"
if [ "$SKIP_AFTER" = "non-coder" ] && has_marker persona-check "$SKIP_TRACE"; then
  ok "persona set: second run skipped the prompt, persona unchanged (non-coder), no hang"
else
  bad "persona set: second run altered persona ('$SKIP_AFTER') or emitted no persona-check"
fi

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ 5. DIRECTORY ROUTING — empty / fresh / existing classify + route right.   ║
# ║    Through the SAME front-door the launcher's orient consumes.            ║
# ╚══════════════════════════════════════════════════════════════════════════╝
FD="$REPO/bin/heimdall-frontdoor"

# empty-dir → onboard-new
RT_EMPTY="$(mktemp -d)"
R="$("$FD" classify "$RT_EMPTY" 2>/dev/null)"
[ "$R" = "empty-dir -> onboard-new" ] \
  && ok "routing: empty dir → empty-dir -> onboard-new" \
  || bad "routing: empty dir misclassified ($R)"

# fresh-project → orient-fresh  (manifest/source, NO git history)
RT_FRESH="$(mktemp -d)"
printf '{"name":"x"}\n' > "$RT_FRESH/package.json"
printf 'console.log(1)\n'  > "$RT_FRESH/index.js"
R="$("$FD" classify "$RT_FRESH" 2>/dev/null)"
[ "$R" = "fresh-project -> orient-fresh" ] \
  && ok "routing: fresh project → fresh-project -> orient-fresh" \
  || bad "routing: fresh project misclassified ($R)"

# existing-codebase → orient-existing  (git history + source, no checkpoint)
RT_EXIST="$(mktemp -d)"
(
  cd "$RT_EXIST"
  git init -q; git config user.email "t@t.t"; git config user.name "t"
  printf 'def g():\n    return 2\n' > main.py
  git add main.py; git commit -qm "init" >/dev/null 2>&1
)
R="$("$FD" classify "$RT_EXIST" 2>/dev/null)"
[ "$R" = "existing-codebase -> orient-existing" ] \
  && ok "routing: existing codebase → existing-codebase -> orient-existing" \
  || bad "routing: existing codebase misclassified ($R)"

# mid-task-resume → resume  (checkpoint wins over everything)
RT_RESUME="$(mktemp -d)"
mkdir -p "$RT_RESUME/.planning"
printf '# CHECKPOINT\nx\n' > "$RT_RESUME/.planning/CHECKPOINT.md"
R="$("$FD" classify "$RT_RESUME" 2>/dev/null)"
[ "$R" = "mid-task-resume -> resume" ] \
  && ok "routing: checkpoint present → mid-task-resume -> resume" \
  || bad "routing: mid-task-resume misclassified ($R)"

# ── Cleanup the per-case temp dirs (the trap removes TPLUG + FAKE_DIR) ──────────
rm -rf "$COLD_WD" "$(dirname "$COLD_HH")" "$(dirname "$COLD_TRACE")" \
       "$WARM_WD" "$(dirname "$WARM_HH")" "$(dirname "$WARM_TRACE")" \
       "$SI1_WD" "$(dirname "$SI1_HH")" "$(dirname "$SI1_TRACE")" \
       "$(dirname "$SETONCE_HH")" "$SKIP_WD" "$(dirname "$SKIP_TRACE")" \
       "$RT_EMPTY" "$RT_FRESH" "$RT_EXIST" "$RT_RESUME" 2>/dev/null || true

echo "--------------------------------------------------------------------"
echo "f1-onboarding.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]
