#!/usr/bin/env bash
# test/heimdall-switch-launch-env.test.sh
#
# WHY THIS FILE EXISTS
# --------------------
# bin/heimdall-route's own FALLBACK PRECEDENCE block routes a newly exec'd CHILD
# process -- a child can never setenv its own parent, so that mechanism only ever
# reaches work hmd LAUNCHES, never the operator's own Claude Code session. A
# SESSION-level rate limit blocks that session itself, and Anthropic's
# rate_limits payload never exposes a session window to detect it proactively
# either (bin/heimdall-session-usage: only five_hour/seven_day ever appear).
# bin/heimdall IS the parent of the `claude` process it is about to launch, so
# apply_switch_fallback_env() (bin/heimdall, defined right after resolve_model())
# is the one place that can legitimately set the endpoint for the WHOLE session.
#
# WHAT THIS SUITE PROVES
# -----------------------
#   A. Static shape: the function exists, is wired into all 3 real launch call
#      sites (resume / non-interactive task / interactive), and never
#      re-implements heimdall-fallback's own status/base-url/token-file/model
#      contracts.
#   B. Functional coverage (deterministic stub heimdall-fallback, direct
#      in-process call): switch+ROUTE exports the endpoint+model+token; every
#      other state (auto/off/coop/unknown) and every non-ROUTE verdict
#      (REFUSE/non-loopback) leaves the launching shell's env untouched;
#      fail-open when heimdall-fallback is absent from PATH; an operator-set
#      ANTHROPIC_MODEL always outranks the fallback pin; the warning banner
#      states the routing, the endpoint, the model, the cache/context cost, the
#      undo, AND the adjudication consequence.
#   C. THE LITERAL ACCEPTANCE PROOF: a stub `claude` on PATH dumps its OWN
#      environment -- proving the gateway URL + pinned model genuinely reach the
#      EXEC'D CHILD under switch+ROUTE, and reach neither under auto (existing
#      child-only behaviour preserved).
#   D. Real heimdall-fallback, zero stub: a freshly `set switch`'d sandbox repo
#      with no provider configured REFUSEs by construction (tier1_credential_
#      absent), and apply_switch_fallback_env leaves the env untouched against
#      that REAL refusal -- not a simulated one.
#   E. THE ADJUDICATION CONSEQUENCE (requirement 6), real end-to-end: the exact
#      env shape apply_switch_fallback_env would export under switch+ROUTE
#      really does make the REAL, shipped bin/heimdall-precheck-agent DENY
#      hmd:reviewer/verifier/security-auditor spawns, while still ALLOWING a
#      generation spawn (hmd:coder) in that same routed session, and allowing
#      everything when the session is not routed. bin/heimdall-precheck-agent
#      and bin/lib/hmd-route-claude are a sibling's active files (coop spawn-
#      path work) -- this section only ever INVOKES the real, already-shipped
#      hook read-only; it edits neither file, and this suite touches neither.
#
# Hermetic throughout: every heimdall-fallback in Sections A-C is a deterministic
# PATH-shadowed stub (never the real network/DB/quota probe); Section D uses the
# real binary but only ever against a throwaway sandbox repo (`--repo`) with a
# sandboxed HEIMDALL_HOME, NEVER the operator's own `.heimdall/fallback.json`.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HMD="$REPO/bin/heimdall"
REAL_PATH="$PATH"
[ -f "$HMD" ] || { echo "FATAL: bin/heimdall missing"; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s -- %s\n' "$1" "$2"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "heimdall-switch-launch-env  repo=$REPO"

# ── shared helpers ───────────────────────────────────────────────────────────
extract_key() { grep "^$2=" "$1" 2>/dev/null || true; }   # extract_key <envfile> <KEY>
field()       { printf '%s\n' "$1" | grep "^$2=" | sed "s/^$2=//" || true; }  # field <blob> <KEY>

echo "== Section A: static shape =="

if bash -n "$HMD" 2>/dev/null; then ok "A1 bin/heimdall parses (bash -n)"
else bad "A1 bin/heimdall parses (bash -n)" "syntax error"; fi

if grep -q "^apply_switch_fallback_env() {" "$HMD"; then
  ok "A2 apply_switch_fallback_env defined"
else
  bad "A2 apply_switch_fallback_env defined" "function definition not found"
fi

CALL_COUNT="$(grep -c "^  apply_switch_fallback_env$" "$HMD" || true)"
if [ "${CALL_COUNT:-0}" -eq 3 ]; then
  ok "A3 called from exactly 3 real launch sites (resume/non-interactive/interactive)"
else
  bad "A3 called from exactly 3 real launch sites" "found $CALL_COUNT"
fi

for sub in "status --json" "base-url" "token-file" "model"; do
  if grep -qF "heimdall-fallback --repo \"\$WORK_DIR\" $sub" "$HMD"; then
    ok "A4 reuses heimdall-fallback's own '$sub' (never re-implemented)"
  else
    bad "A4 reuses heimdall-fallback's own '$sub'" "invocation not found"
  fi
done

if grep -qF '[ "$fb_state" = "switch" ] || return 0' "$HMD"; then
  ok "A5 any state other than switch returns before any export (fail closed toward not-routing)"
else
  bad "A5 any state other than switch returns before any export" "guard not found"
fi

if grep -qF 'if [ -z "${ANTHROPIC_MODEL:-}" ]; then' "$HMD"; then
  ok "A6 operator-set ANTHROPIC_MODEL is guarded (never overridden)"
else
  bad "A6 operator-set ANTHROPIC_MODEL is guarded" "guard not found"
fi

if grep -qF 'command -v heimdall-fallback >/dev/null 2>&1 || return 0' "$HMD"; then
  ok "A7 fails open immediately when heimdall-fallback is not on PATH"
else
  bad "A7 fails open immediately when heimdall-fallback is not on PATH" "guard not found"
fi

echo "== Section B: functional coverage (deterministic stub heimdall-fallback, direct in-process call) =="

STUBDIR="$WORK/stubbin"
mkdir -p "$STUBDIR"
cat > "$STUBDIR/heimdall-fallback" <<'STUB'
#!/usr/bin/env bash
# Deterministic double for heimdall-fallback, driven entirely by env vars this
# test controls -- never real network/DB/quota state. That contract (state via
# `status --json`, endpoint via `base-url`, path via `token-file`, id via
# `model`, empty stdout + nonzero exit on any refusal) is proven for real
# elsewhere (test/heimdall-fallback.test.sh, test/heimdall-fallback-command.test.sh);
# this double exists only to drive apply_switch_fallback_env's OWN reaction to
# every branch of that contract, deterministically.
[ -n "${STUB_CALL_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_CALL_LOG"
while [ "${1:-}" = "--repo" ]; do shift 2; done
case "${1:-}" in
  status)
    case "${STUB_FB_STATUS_MODE:-normal}" in
      empty) exit 0 ;;
      malformed) printf 'not json at all {{{\n'; exit 0 ;;
      *) printf '{"state":"%s"}\n' "${STUB_FB_STATE:-off}"; exit 0 ;;
    esac
    ;;
  base-url)
    if [ -n "${STUB_FB_URL:-}" ]; then printf '%s\n' "$STUB_FB_URL"; exit 0; fi
    exit 1
    ;;
  token-file)
    if [ -n "${STUB_FB_TOKENFILE:-}" ]; then printf '%s\n' "$STUB_FB_TOKENFILE"; exit 0; fi
    exit 1
    ;;
  model)
    if [ -n "${STUB_FB_MODEL:-}" ]; then printf '%s\n' "$STUB_FB_MODEL"; exit 0; fi
    exit 1
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$STUBDIR/heimdall-fallback"

# run_case <state> <url> <tokenfile> <model> <preset_model> -- sources the REAL
# bin/heimdall (HEIMDALL_LIB_ONLY=1) under a sandboxed HEIMDALL_HOME with the
# stub above shadowing PATH, calls the REAL apply_switch_fallback_env, and
# prints the three routing vars plus the stub's own call log so a caller can
# also assert which subcommands were (or were not) ever queried.
run_case() {
  local state="$1" url="$2" tokenfile="$3" model="$4" preset_model="${5:-}"
  local sandbox_home; sandbox_home="$(mktemp -d)"
  local calllog; calllog="$(mktemp)"
  local out
  out="$(
    cd "$WORK" || exit 1
    export HEIMDALL_HOME="$sandbox_home"
    export PATH="$STUBDIR:/usr/bin:/bin"
    export STUB_FB_STATE="$state" STUB_FB_URL="$url" STUB_FB_TOKENFILE="$tokenfile" STUB_FB_MODEL="$model"
    export STUB_CALL_LOG="$calllog"
    export ANTHROPIC_MODEL="$preset_model"
    unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN 2>/dev/null
    HEIMDALL_LIB_ONLY=1 bash -c "
      source \"$HMD\"
      apply_switch_fallback_env
      echo \"BASE_URL=[\${ANTHROPIC_BASE_URL:-}]\"
      echo \"MODEL=[\${ANTHROPIC_MODEL:-}]\"
      echo \"AUTH_TOKEN=[\${ANTHROPIC_AUTH_TOKEN:-}]\"
    " 2>"$WORK/last_stderr.log"
  )"
  printf '%s\n' "$out"
  printf 'CALLLOG=[%s]\n' "$(tr '\n' ';' < "$calllog")"
  rm -rf "$sandbox_home"
  rm -f "$calllog"
}

# B1 -- the one true positive: switch + ROUTE exports gateway URL + pinned model.
B1_OUT="$(run_case switch "http://127.0.0.1:9101" "" "oc/fallback-model-x" "")"
B1_URL="$(field "$B1_OUT" BASE_URL)"; B1_MODEL="$(field "$B1_OUT" MODEL)"
if [ "$B1_URL" = "[http://127.0.0.1:9101]" ] && [ "$B1_MODEL" = "[oc/fallback-model-x]" ]; then
  ok "B1 switch+ROUTE exports gateway URL + pinned model"
else
  bad "B1 switch+ROUTE exports gateway URL + pinned model" "url=$B1_URL model=$B1_MODEL"
fi

# The banner from B1's run -- checked NOW, before any later run_case call
# overwrites last_stderr.log.
BANNER="$(cat "$WORK/last_stderr.log" 2>/dev/null || true)"
case "$BANNER" in
  *"ENTIRE session is now routed to a third-party model"*) ok "B1-banner states the whole session is now routed to a third-party model" ;;
  *) bad "B1-banner states the whole session is now routed to a third-party model" "$BANNER" ;;
esac
case "$BANNER" in *"http://127.0.0.1:9101"*) ok "B1-banner names the endpoint" ;; *) bad "B1-banner names the endpoint" "$BANNER" ;; esac
case "$BANNER" in *"oc/fallback-model-x"*) ok "B1-banner names the pinned model" ;; *) bad "B1-banner names the pinned model" "$BANNER" ;; esac
case "$BANNER" in *"heimdall-fallback set off"*) ok "B1-banner gives the exact undo command" ;; *) bad "B1-banner gives the exact undo command" "$BANNER" ;; esac
case "$BANNER" in *"cache"*) ok "B1-banner mentions prompt-cache loss" ;; *) bad "B1-banner mentions prompt-cache loss" "$BANNER" ;; esac
case "$BANNER" in *"91-95"*) ok "B1-banner quantifies the cache-value cost (~91-95%)" ;; *) bad "B1-banner quantifies the cache-value cost" "$BANNER" ;; esac
case "$BANNER" in *"41,000"*) ok "B1-banner quantifies measured session context (~41,000 tokens)" ;; *) bad "B1-banner quantifies measured session context" "$BANNER" ;; esac
case "$BANNER" in *"DENIED"*) ok "B1-banner states judge subagents will be DENIED (adjudication consequence, requirement 6)" ;; *) bad "B1-banner states judge subagents will be DENIED" "$BANNER" ;; esac
case "$BANNER" in *"hmd:reviewer"*"hmd:verifier"*"hmd:security-auditor"*) ok "B1-banner names the affected judge subagent types" ;; *) bad "B1-banner names the affected judge subagent types" "$BANNER" ;; esac

# B2 -- switch + REFUSE (base-url empty) -> nothing exported.
B2_OUT="$(run_case switch "" "" "" "")"
if [ "$(field "$B2_OUT" BASE_URL)" = "[]" ]; then ok "B2 switch+REFUSE leaves ANTHROPIC_BASE_URL untouched"
else bad "B2 switch+REFUSE leaves ANTHROPIC_BASE_URL untouched" "$(field "$B2_OUT" BASE_URL)"; fi

# B3 -- switch + a non-loopback URL (WAIT/verdict corruption) -> re-validated and rejected.
B3_OUT="$(run_case switch "https://evil.example.com" "" "" "")"
if [ "$(field "$B3_OUT" BASE_URL)" = "[]" ]; then ok "B3 switch + non-loopback base-url is rejected, not blindly trusted"
else bad "B3 switch + non-loopback base-url is rejected" "$(field "$B3_OUT" BASE_URL)"; fi

# B4 -- auto keeps existing CHILD-ONLY behaviour: no export, and base-url is
# never even queried (proves the early-return, not just its net effect).
B4_OUT="$(run_case auto "http://127.0.0.1:9101" "" "oc/model" "")"
B4_CALLLOG="$(field "$B4_OUT" CALLLOG)"
if [ "$(field "$B4_OUT" BASE_URL)" = "[]" ]; then ok "B4 auto leaves ANTHROPIC_BASE_URL untouched (child-only behaviour preserved)"
else bad "B4 auto leaves ANTHROPIC_BASE_URL untouched" "$(field "$B4_OUT" BASE_URL)"; fi
case "$B4_CALLLOG" in
  *"base-url"*) bad "B4 auto never queries base-url at all" "call log: $B4_CALLLOG" ;;
  *) ok "B4 auto never queries base-url at all (returns right after reading state)" ;;
esac

# B5 -- off -> no export.
B5_OUT="$(run_case off "http://127.0.0.1:9101" "" "oc/model" "")"
if [ "$(field "$B5_OUT" BASE_URL)" = "[]" ]; then ok "B5 off leaves ANTHROPIC_BASE_URL untouched"
else bad "B5 off leaves ANTHROPIC_BASE_URL untouched" "$(field "$B5_OUT" BASE_URL)"; fi

# B6 -- coop must not be touched by this feature at all: falls into the same
# "anything but switch" bucket, no export.
B6_OUT="$(run_case coop "http://127.0.0.1:9101" "" "oc/model" "")"
if [ "$(field "$B6_OUT" BASE_URL)" = "[]" ]; then ok "B6 coop leaves ANTHROPIC_BASE_URL untouched (untouched by this feature, per requirement 1)"
else bad "B6 coop leaves ANTHROPIC_BASE_URL untouched" "$(field "$B6_OUT" BASE_URL)"; fi

# B7 -- an unrecognized state string defaults to not-routing (fail closed).
B7_OUT="$(run_case yolo "http://127.0.0.1:9101" "" "oc/model" "")"
if [ "$(field "$B7_OUT" BASE_URL)" = "[]" ]; then ok "B7 unrecognized state string leaves ANTHROPIC_BASE_URL untouched (fail closed)"
else bad "B7 unrecognized state string leaves ANTHROPIC_BASE_URL untouched" "$(field "$B7_OUT" BASE_URL)"; fi

# B8 -- an operator-set ANTHROPIC_MODEL always outranks the fallback pin, even
# though routing itself still proceeds.
B8_OUT="$(run_case switch "http://127.0.0.1:9102" "" "oc/fallback-model-y" "my-own-preset-model")"
B8_URL="$(field "$B8_OUT" BASE_URL)"; B8_MODEL="$(field "$B8_OUT" MODEL)"
if [ "$B8_URL" = "[http://127.0.0.1:9102]" ] && [ "$B8_MODEL" = "[my-own-preset-model]" ]; then
  ok "B8 operator-set ANTHROPIC_MODEL is never overridden by the fallback pin (routing still proceeds)"
else
  bad "B8 operator-set ANTHROPIC_MODEL is never overridden" "url=$B8_URL model=$B8_MODEL (expected preset to survive)"
fi

# B9 -- heimdall-fallback model/token-file both refusing (empty) under a ROUTE
# verdict must not crash and must not export either -- routing (BASE_URL) still
# proceeds on its own, independent seam.
B9_OUT="$(run_case switch "http://127.0.0.1:9103" "" "" "")"
B9_URL="$(field "$B9_OUT" BASE_URL)"; B9_MODEL="$(field "$B9_OUT" MODEL)"; B9_TOK="$(field "$B9_OUT" AUTH_TOKEN)"
if [ "$B9_URL" = "[http://127.0.0.1:9103]" ] && [ "$B9_MODEL" = "[]" ] && [ "$B9_TOK" = "[]" ]; then
  ok "B9 model/token-file refusal (empty) exports neither, crashes neither, routing still proceeds"
else
  bad "B9 model/token-file refusal (empty) exports neither" "url=$B9_URL model=$B9_MODEL token=$B9_TOK"
fi

# B10 -- token-file: read the PATH, then the FILE'S CONTENTS (heimdall-route's
# own pattern) -- a real temp file with known content proves both hops.
TOKFILE="$WORK/token.txt"
printf 'secret-token-xyz' > "$TOKFILE"
B10_OUT="$(run_case switch "http://127.0.0.1:9104" "$TOKFILE" "" "")"
if [ "$(field "$B10_OUT" AUTH_TOKEN)" = "[secret-token-xyz]" ]; then
  ok "B10 token-file's path is read, then its contents -- ANTHROPIC_AUTH_TOKEN carries the real file content"
else
  bad "B10 token-file path-then-contents" "$(field "$B10_OUT" AUTH_TOKEN)"
fi

# B12 -- heimdall-fallback entirely absent from PATH -> fails open immediately,
# no crash, no export (mirrors bin/heimdall-route's own fail-open discipline).
B12_HOME="$(mktemp -d)"
B12_OUT="$(
  cd "$WORK" || exit 1
  export HEIMDALL_HOME="$B12_HOME"
  export PATH="/usr/bin:/bin"
  unset ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_AUTH_TOKEN 2>/dev/null
  HEIMDALL_LIB_ONLY=1 bash -c "
    source \"$HMD\"
    apply_switch_fallback_env
    echo \"BASE_URL=[\${ANTHROPIC_BASE_URL:-}]\"
    echo \"RC_MARKER=ok\"
  " 2>/dev/null
)"
rm -rf "$B12_HOME"
if [ "$(field "$B12_OUT" BASE_URL)" = "[]" ] && [ "$(field "$B12_OUT" RC_MARKER)" = "ok" ]; then
  ok "B12 heimdall-fallback absent from PATH -> fails open, no export, no crash"
else
  bad "B12 heimdall-fallback absent from PATH -> fails open" "$B12_OUT"
fi

# B13 -- status --json exits 0 but stdout is byte-empty -> the [ -n "$fb_state_json" ]
# guard (line 245) returns before any python3 JSON parse is even attempted.
run_status_mode_case() { # run_status_mode_case <status_mode>
  local mode="$1" home; home="$(mktemp -d)"
  local out
  out="$(
    cd "$WORK" || exit 1
    export HEIMDALL_HOME="$home"
    export PATH="$STUBDIR:/usr/bin:/bin"
    export STUB_FB_STATUS_MODE="$mode" STUB_FB_URL="http://127.0.0.1:9105" STUB_FB_MODEL="oc/m"
    unset ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_AUTH_TOKEN 2>/dev/null
    HEIMDALL_LIB_ONLY=1 bash -c "
      source \"$HMD\"
      apply_switch_fallback_env
      echo \"BASE_URL=[\${ANTHROPIC_BASE_URL:-}]\"
      echo \"RC_MARKER=ok\"
    " 2>/dev/null
  )"
  rm -rf "$home"
  printf '%s\n' "$out"
}
B13_OUT="$(run_status_mode_case empty)"
if [ "$(field "$B13_OUT" BASE_URL)" = "[]" ] && [ "$(field "$B13_OUT" RC_MARKER)" = "ok" ]; then
  ok "B13 status --json exits 0 with byte-empty stdout -> no export, no crash (line 245's own guard)"
else
  bad "B13 status --json byte-empty stdout -> no export, no crash" "$B13_OUT"
fi

# B14 -- status --json exits 0 but stdout is non-empty, non-JSON garbage -> the
# python3 try/except (lines 246-252) prints "" on exception, so fb_state="" and
# the switch-only guard (line 253) still returns before any export.
B14_OUT="$(run_status_mode_case malformed)"
if [ "$(field "$B14_OUT" BASE_URL)" = "[]" ] && [ "$(field "$B14_OUT" RC_MARKER)" = "ok" ]; then
  ok "B14 status --json returns malformed non-JSON garbage -> no export, no crash (JSON-parse exception path)"
else
  bad "B14 status --json malformed garbage -> no export, no crash" "$B14_OUT"
fi

echo "== Section C: literal acceptance proof -- env-dump through a stub claude =="

FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
{ printf 'ARGV:%s\n' "$*"; env; } > "${RECORDER_ENV_FILE:?RECORDER_ENV_FILE not set}"
exit 0
EOF
chmod +x "$FAKEBIN/claude"

# C1 -- switch+ROUTE: the EXEC'D claude's OWN environment (not just the calling
# shell's) carries the gateway URL + pinned model. This is apply_switch_fallback_env
# called, then `claude` invoked immediately after -- exactly what each of the 3
# real call sites in bin/heimdall does, in order, with nothing in between that
# could reset an exported var.
C1_ENV="$WORK/c1.env"
C1_HOME="$(mktemp -d)"
(
  cd "$WORK" || exit 1
  export RECORDER_ENV_FILE="$C1_ENV"
  export PATH="$STUBDIR:$FAKEBIN:/usr/bin:/bin"
  export HEIMDALL_HOME="$C1_HOME"
  export STUB_FB_STATE=switch STUB_FB_URL="http://127.0.0.1:9191" STUB_FB_TOKENFILE="" STUB_FB_MODEL="oc/switch-model-1"
  unset ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_AUTH_TOKEN 2>/dev/null
  HEIMDALL_LIB_ONLY=1 bash -c "
    source \"$HMD\"
    apply_switch_fallback_env
    exec claude -p 'c1 task'
  "
) >/dev/null 2>&1
rm -rf "$C1_HOME"
if [ -f "$C1_ENV" ] \
   && [ "$(extract_key "$C1_ENV" ANTHROPIC_BASE_URL)" = "ANTHROPIC_BASE_URL=http://127.0.0.1:9191" ] \
   && [ "$(extract_key "$C1_ENV" ANTHROPIC_MODEL)" = "ANTHROPIC_MODEL=oc/switch-model-1" ]; then
  ok "C1 switch+ROUTE: the EXEC'D claude's own env carries the gateway URL + pinned model"
else
  bad "C1 switch+ROUTE: the EXEC'D claude's own env carries the gateway URL + pinned model" \
    "$(grep '^ANTHROPIC_' "$C1_ENV" 2>/dev/null)"
fi

# C2 -- auto: the SAME stub heimdall-fallback would say ROUTE if asked, but
# auto never asks -- the exec'd claude's env carries NEITHER var. This is the
# direct falsifying counterpart to C1: a shim that always routes would pass C1
# but fail this.
C2_ENV="$WORK/c2.env"
C2_HOME="$(mktemp -d)"
(
  cd "$WORK" || exit 1
  export RECORDER_ENV_FILE="$C2_ENV"
  export PATH="$STUBDIR:$FAKEBIN:/usr/bin:/bin"
  export HEIMDALL_HOME="$C2_HOME"
  export STUB_FB_STATE=auto STUB_FB_URL="http://127.0.0.1:9191" STUB_FB_TOKENFILE="" STUB_FB_MODEL="oc/switch-model-1"
  unset ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_AUTH_TOKEN 2>/dev/null
  HEIMDALL_LIB_ONLY=1 bash -c "
    source \"$HMD\"
    apply_switch_fallback_env
    exec claude -p 'c2 task'
  "
) >/dev/null 2>&1
rm -rf "$C2_HOME"
if [ -f "$C2_ENV" ] \
   && [ -z "$(extract_key "$C2_ENV" ANTHROPIC_BASE_URL)" ] \
   && [ -z "$(extract_key "$C2_ENV" ANTHROPIC_MODEL)" ]; then
  ok "C2 auto: the EXEC'D claude's env carries NEITHER gateway URL nor pinned model (child-only behaviour preserved)"
else
  bad "C2 auto: the EXEC'D claude's env carries NEITHER var" "$(grep '^ANTHROPIC_' "$C2_ENV" 2>/dev/null)"
fi

echo "== Section D: real heimdall-fallback, zero stub (REFUSE-by-construction sanity) =="

D_REPO="$(mktemp -d)"
D_HOME="$(mktemp -d)"
mkdir -p "$D_REPO/.heimdall"
(
  cd "$D_REPO" || exit 1
  export HEIMDALL_HOME="$D_HOME"
  "$REPO/bin/heimdall-fallback" --repo "$D_REPO" set switch >/dev/null 2>&1
)

D_STATE_JSON="$("$REPO/bin/heimdall-fallback" --repo "$D_REPO" status --json 2>/dev/null)"
D_STATE_VAL="$(printf '%s' "$D_STATE_JSON" | jq -r '.state' 2>/dev/null || true)"
if [ "$D_STATE_VAL" = "switch" ]; then
  ok "D0 real heimdall-fallback persisted state=switch in the sandboxed repo"
else
  bad "D0 real heimdall-fallback persisted state=switch in the sandboxed repo" "$D_STATE_JSON"
fi

D_URL="$("$REPO/bin/heimdall-fallback" --repo "$D_REPO" base-url 2>/dev/null || true)"
if [ -z "$D_URL" ]; then
  ok "D1 real heimdall-fallback base-url REFUSEs by default (no provider configured) -- empty stdout"
else
  bad "D1 real heimdall-fallback base-url REFUSEs by default" "got [$D_URL]"
fi

D2_OUT="$(
  cd "$D_REPO" || exit 1
  export HEIMDALL_HOME="$D_HOME"
  export PATH="$REPO/bin:/usr/bin:/bin"
  unset ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_AUTH_TOKEN 2>/dev/null
  HEIMDALL_LIB_ONLY=1 bash -c "
    source \"$HMD\"
    apply_switch_fallback_env
    echo \"BASE_URL=[\${ANTHROPIC_BASE_URL:-}]\"
  " 2>/dev/null
)"
if [ "$(field "$D2_OUT" BASE_URL)" = "[]" ]; then
  ok "D2 real REFUSE-by-construction repo + REAL heimdall-fallback (no stub) -> switch-launch leaves ANTHROPIC_BASE_URL untouched"
else
  bad "D2 real REFUSE-by-construction repo -> switch-launch leaves ANTHROPIC_BASE_URL untouched" "$D2_OUT"
fi
rm -rf "$D_REPO" "$D_HOME"

echo "== Section E: adjudication consequence, real end-to-end (requirement 6) =="

REAL_PRECHECK="$REPO/bin/heimdall-precheck-agent"
BASH_ABS="$(command -v bash)"

if [ -x "$REAL_PRECHECK" ]; then ok "E0 bin/heimdall-precheck-agent present + executable in this worktree"
else bad "E0 bin/heimdall-precheck-agent present + executable" "missing or not executable"; fi

payload() { printf '{"tool_input":{"subagent_type":"%s","prompt":"hi"}}' "$1"; }

fire_precheck() { # fire_precheck <subagent_type> <anthropic_base_url>
  local satype="$1" abu="$2" pf errf
  pf="$(mktemp)"; errf="$(mktemp)"
  payload "$satype" > "$pf"
  E_OUT="$(env -i PATH="$REAL_PATH" HOME="${HOME:-/tmp}" ANTHROPIC_BASE_URL="$abu" \
      "$BASH_ABS" "$REAL_PRECHECK" <"$pf" 2>"$errf")"
  E_RC=$?
  E_ERR="$(cat "$errf" 2>/dev/null)"
  rm -f "$pf" "$errf"
}

# E1-E3: the EXACT env shape apply_switch_fallback_env exports under switch+ROUTE
# (a loopback URL) really does deny each judge subagent type, against the REAL,
# shipped hook -- proving requirement 6 end-to-end, not by assertion.
fire_precheck "hmd:reviewer" "http://127.0.0.1:9191"
[ "$E_RC" -eq 2 ] && ok "E1 routed session -> hmd:reviewer spawn DENIED (exit 2) by the real precheck-agent" \
                  || bad "E1 routed session -> hmd:reviewer spawn DENIED" "exit $E_RC (expected 2); stderr=$E_ERR"

fire_precheck "hmd:verifier" "http://127.0.0.1:9191"
[ "$E_RC" -eq 2 ] && ok "E2 routed session -> hmd:verifier spawn DENIED (exit 2)" \
                  || bad "E2 routed session -> hmd:verifier spawn DENIED" "exit $E_RC (expected 2)"

fire_precheck "hmd:security-auditor" "http://127.0.0.1:9191"
[ "$E_RC" -eq 2 ] && ok "E3 routed session -> hmd:security-auditor spawn DENIED (exit 2)" \
                  || bad "E3 routed session -> hmd:security-auditor spawn DENIED" "exit $E_RC (expected 2)"

# E4: the SAME routed session must still allow a GENERATION spawn -- proves the
# consequence is specific to judges, not a blanket deny of the whole session.
fire_precheck "hmd:coder" "http://127.0.0.1:9191"
[ "$E_RC" -eq 0 ] && ok "E4 routed session -> hmd:coder (generation) spawn still ALLOWED (exit 0)" \
                  || bad "E4 routed session -> hmd:coder still ALLOWED" "exit $E_RC (expected 0)"

# E5: an UNROUTED session must never trigger this fence -- proves E1-E3 are
# caused by the routed env var, not an unconditional deny.
fire_precheck "hmd:reviewer" ""
[ "$E_RC" -eq 0 ] && ok "E5 unrouted session (no ANTHROPIC_BASE_URL) -> hmd:reviewer spawn still ALLOWED (exit 0)" \
                  || bad "E5 unrouted session -> hmd:reviewer still ALLOWED" "exit $E_RC (expected 0)"

echo
echo "heimdall-switch-launch-env: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
