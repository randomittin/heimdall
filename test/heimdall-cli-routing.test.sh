#!/usr/bin/env bash
# test/heimdall-cli-routing.test.sh — CLI routing contract for bin/heimdall
#
# WHAT THIS GATES. The top-level dispatcher (bin/heimdall) must route named
# subcommands to their real bins and forward all args verbatim, while unknown
# commands fall through to the Claude task-prompt path. The three routing gaps
# fixed: `hmd team`, `hmd invite`, `hmd presence` (including `off`, `on`,
# `on --global`, `on --no-files`, `status`, `roster`, etc.).
#
# HOW THE HARNESS WORKS.
#   Routed cases  — we COPY bin/heimdall into a temp fake plugin dir so
#     PLUGIN_DIR resolves to the fake dir (readlink -f on a plain copy, not a
#     symlink, returns the copy's own path). Stub bins placed there intercept
#     exec calls and record their argv to STUB_OUT. We assert the stub was
#     called and the args were forwarded.
#
#   Fall-through — HEIMDALL_TRACE_ORDER=$TRACE_FILE causes bin/heimdall to
#     append "launch:task" to the file and exit 0 just before the real `claude`
#     exec (line 2641-2644). This short-circuits without a live model call.
#     HEIMDALL_HOME points to a dir with a pre-written setup-done marker so
#     first_run_setup is a no-op. A stub `claude` on PATH satisfies ensure_claude.
#
# EXIT: 0 = all assertions pass; 1 = any FAIL.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
REAL_BIN="$REPO/bin/heimdall"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# ── build fake plugin dir ─────────────────────────────────────────────────────
FAKE_DIR="$(mktemp -d /tmp/test-heimdall-routing-XXXXXX)"
FAKE_BIN="$FAKE_DIR/bin"
FAKE_HOME="$FAKE_DIR/home"
mkdir -p "$FAKE_BIN" "$FAKE_HOME" "$FAKE_DIR/.claude-plugin"

# COPY (not symlink) the real script so readlink -f resolves to the copy;
# PLUGIN_DIR inside the copy therefore equals $FAKE_DIR.
cp "$REAL_BIN" "$FAKE_BIN/heimdall"
chmod +x "$FAKE_BIN/heimdall"

# Mark setup done → first_run_setup returns immediately without network calls.
touch "$FAKE_HOME/setup-done"

# Stub `claude` so ensure_claude passes and the trace-order exit works.
cat > "$FAKE_BIN/claude" <<'EOBIN'
#!/usr/bin/env bash
exit 0
EOBIN
chmod +x "$FAKE_BIN/claude"

# Files shared across tests: reset per-run.
STUB_OUT="$(mktemp /tmp/test-hmd-stub-XXXXXX)"
TRACE_FILE="$(mktemp /tmp/test-hmd-trace-XXXXXX)"

cleanup() {
  rm -rf "$FAKE_DIR" "$STUB_OUT" "$TRACE_FILE" 2>/dev/null || true
}
trap cleanup EXIT

# make_stub NAME — place a stub in $FAKE_BIN that records its argv to STUB_OUT.
make_stub() {
  local name="$1"
  # The stub appends "NAME ARGS: <args>" to $HMD_STUB_OUT (exported at run time).
  cat > "$FAKE_BIN/$name" <<EOBIN
#!/usr/bin/env bash
printf '%s ARGS: %s\n' "$name" "\$*" >> "\${HMD_STUB_OUT:-/dev/null}"
exit 0
EOBIN
  chmod +x "$FAKE_BIN/$name"
}

# run_hmd CMD [ARGS…] — run the fake heimdall with a sanitised environment.
# stdout/stderr both suppressed so banner/animation noise stays out of test output.
run_hmd() {
  PATH="$FAKE_BIN:$PATH" \
  HEIMDALL_HOME="$FAKE_HOME" \
  HEIMDALL_NO_INTRO=1 \
  HEIMDALL_NO_UPDATE_CHECK=1 \
  HMD_STUB_OUT="$STUB_OUT" \
  HEIMDALL_TRACE_ORDER="$TRACE_FILE" \
  bash "$FAKE_BIN/heimdall" "$@" >/dev/null 2>&1 || true
}

# Predicates used in assertions.
stub_called()     { grep -q "$1" "$STUB_OUT" 2>/dev/null; }       # $1 = stub name
args_contain()    { grep -qF -- "$1" "$STUB_OUT" 2>/dev/null; }   # $1 = expected substring
claude_reached()  { grep -q "launch:task" "$TRACE_FILE" 2>/dev/null; }

reset() { : > "$STUB_OUT"; : > "$TRACE_FILE"; }

# Ensure stubs are in place for all bins under test.
make_stub heimdall-team
make_stub heimdall-invite
make_stub heimdall-presence
make_stub heimdall-connect

# ══════════════════════════════════════════════════════════════════════════════
# 1. `hmd team new --force` → execs heimdall-team, args forwarded, no fall-through
# ══════════════════════════════════════════════════════════════════════════════
reset
run_hmd team new --force

if stub_called "heimdall-team"; then
  ok "team routes to heimdall-team"
else
  bad "team routes to heimdall-team"
fi

if args_contain "new --force"; then
  ok "team forwards args verbatim (new --force)"
else
  bad "team forwards args verbatim (new --force)"
  cat "$STUB_OUT" >&2
fi

if ! claude_reached; then
  ok "team does NOT fall through to Claude"
else
  bad "team MUST NOT reach the Claude fall-through"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 2. `hmd team show --json` — second team subcommand variant
# ══════════════════════════════════════════════════════════════════════════════
reset
run_hmd team show --json

if stub_called "heimdall-team" && args_contain "show --json"; then
  ok "team show --json forwarded verbatim"
else
  bad "team show --json forwarded verbatim"
  cat "$STUB_OUT" >&2
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. `hmd invite` → execs heimdall-invite, args forwarded, no fall-through
# ══════════════════════════════════════════════════════════════════════════════
reset
run_hmd invite --qr

if stub_called "heimdall-invite"; then
  ok "invite routes to heimdall-invite"
else
  bad "invite routes to heimdall-invite"
fi

if args_contain "--qr"; then
  ok "invite forwards --qr verbatim"
else
  bad "invite forwards --qr verbatim"
  cat "$STUB_OUT" >&2
fi

if ! claude_reached; then
  ok "invite does NOT fall through to Claude"
else
  bad "invite MUST NOT reach the Claude fall-through"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 4. `hmd presence off` → execs heimdall-presence, no fall-through
# ══════════════════════════════════════════════════════════════════════════════
reset
run_hmd presence off

if stub_called "heimdall-presence"; then
  ok "presence routes to heimdall-presence"
else
  bad "presence routes to heimdall-presence"
fi

if args_contain "off"; then
  ok "presence off forwarded verbatim"
else
  bad "presence off forwarded verbatim"
  cat "$STUB_OUT" >&2
fi

if ! claude_reached; then
  ok "presence does NOT fall through to Claude"
else
  bad "presence MUST NOT reach the Claude fall-through"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 5. `hmd presence on --global` — global kill-switch variant
# ══════════════════════════════════════════════════════════════════════════════
reset
run_hmd presence on --global

if stub_called "heimdall-presence" && args_contain "on --global"; then
  ok "presence on --global forwarded verbatim"
else
  bad "presence on --global forwarded verbatim"
  cat "$STUB_OUT" >&2
fi

# ══════════════════════════════════════════════════════════════════════════════
# 6. `hmd presence on --no-files` — per-repo no-files variant
# ══════════════════════════════════════════════════════════════════════════════
reset
run_hmd presence on --no-files

if stub_called "heimdall-presence" && args_contain "on --no-files"; then
  ok "presence on --no-files forwarded verbatim"
else
  bad "presence on --no-files forwarded verbatim"
  cat "$STUB_OUT" >&2
fi

# ══════════════════════════════════════════════════════════════════════════════
# 7. `hmd presence status` — status subcommand
# ══════════════════════════════════════════════════════════════════════════════
reset
run_hmd presence status

if stub_called "heimdall-presence" && args_contain "status"; then
  ok "presence status forwarded verbatim"
else
  bad "presence status forwarded verbatim"
  cat "$STUB_OUT" >&2
fi

# ══════════════════════════════════════════════════════════════════════════════
# 7b. `hmd join <secret>` → execs heimdall-team with `join` PREPENDED, no fall-through
#     (the third user-facing command; the secret rides argv as the documented entry).
# ══════════════════════════════════════════════════════════════════════════════
reset
run_hmd join "abc123secretsecretsecretsecretsecret"

if stub_called "heimdall-team" && args_contain "join abc123secretsecretsecretsecretsecret"; then
  ok "join routes to heimdall-team with 'join' prepended + secret forwarded"
else
  bad "join routes to heimdall-team with 'join' prepended + secret forwarded"
  cat "$STUB_OUT" >&2
fi

if ! claude_reached; then
  ok "join does NOT fall through to Claude"
else
  bad "join MUST NOT reach the Claude fall-through"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 7c. `hmd connect --status` → execs heimdall-connect, args forwarded, no fall-through
# ══════════════════════════════════════════════════════════════════════════════
reset
run_hmd connect --status

if stub_called "heimdall-connect" && args_contain "--status"; then
  ok "connect routes to heimdall-connect (--status forwarded)"
else
  bad "connect routes to heimdall-connect (--status forwarded)"
  cat "$STUB_OUT" >&2
fi

if ! claude_reached; then
  ok "connect does NOT fall through to Claude"
else
  bad "connect MUST NOT reach the Claude fall-through"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 7d. `hmd beat` → execs heimdall-presence with `beat` PREPENDED, no fall-through.
#     Shortcut so a teammate never types the raw ~/.heimdall/bin/heimdall-presence path.
# ══════════════════════════════════════════════════════════════════════════════
reset
run_hmd beat

if stub_called "heimdall-presence" && args_contain "beat"; then
  ok "beat routes to heimdall-presence with 'beat' prepended"
else
  bad "beat routes to heimdall-presence with 'beat' prepended"
  cat "$STUB_OUT" >&2
fi

if ! claude_reached; then
  ok "beat does NOT fall through to Claude"
else
  bad "beat MUST NOT reach the Claude fall-through"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 7e. `hmd beat --strict` — flags forwarded verbatim after the prepended verb.
# ══════════════════════════════════════════════════════════════════════════════
reset
run_hmd beat --strict

if stub_called "heimdall-presence" && args_contain "beat --strict"; then
  ok "beat forwards flags verbatim (beat --strict)"
else
  bad "beat forwards flags verbatim (beat --strict)"
  cat "$STUB_OUT" >&2
fi

# ══════════════════════════════════════════════════════════════════════════════
# 7f. `hmd roster` → execs heimdall-presence with `roster` PREPENDED, no fall-through.
# ══════════════════════════════════════════════════════════════════════════════
reset
run_hmd roster

if stub_called "heimdall-presence" && args_contain "roster"; then
  ok "roster routes to heimdall-presence with 'roster' prepended"
else
  bad "roster routes to heimdall-presence with 'roster' prepended"
  cat "$STUB_OUT" >&2
fi

if ! claude_reached; then
  ok "roster does NOT fall through to Claude"
else
  bad "roster MUST NOT reach the Claude fall-through"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 8. FALSIFIER — unknown command falls through to Claude launch path
#    A routed name must NOT reach fall-through; an unknown one MUST.
# ══════════════════════════════════════════════════════════════════════════════
reset
run_hmd "build-something-xyz-unknown-task-abcdef"

if claude_reached; then
  ok "unknown command falls through to Claude launch path"
else
  bad "unknown command must reach the Claude launch path (launch:task trace missing)"
  cat "$TRACE_FILE" >&2
fi

if ! stub_called "heimdall-team" && ! stub_called "heimdall-invite" && ! stub_called "heimdall-presence" && ! stub_called "heimdall-connect"; then
  ok "unknown command does NOT route to team/invite/presence/connect stubs (falsifier)"
else
  bad "unknown command must NOT be intercepted by any routing stub"
  cat "$STUB_OUT" >&2
fi

# ══════════════════════════════════════════════════════════════════════════════
# 8b. LAUNCH-PATH HELPER DEGRADATION — a missing bin/heimdall-model-resolve must
#     NOT brick the launcher, and its presence must still be honoured.
#
#     bin/heimdall runs under `set -euo pipefail`. Every other launch-path helper
#     is guarded (`[ -x "$SKILL_MGR" ]`, `[ -x "$face" ] || return 0`), but the
#     model-tier resolver was called bare inside a command substitution:
#         MODEL_FLAG="--model $("$PLUGIN_DIR/bin/heimdall-model-resolve" opus)"
#     With the helper absent (partial install, lost +x bit, older layout) the
#     substitution exits 127 and `set -e` aborted the WHOLE launcher — the user's
#     task never ran. That is the defect this section pins, from both sides:
#       A. resolver ABSENT  → launcher still reaches launch:task (degrades to the
#          bare tier alias, which is byte-identical to what the helper prints
#          when no HEIMDALL_MODEL_<TIER> pin is set).
#       B. resolver PRESENT → launcher still CALLS it (a fallback that silently
#          replaced the resolver would defeat float-to-latest / pin overrides).
# ══════════════════════════════════════════════════════════════════════════════

# A. resolver absent — this is the state every other case in this file runs in.
reset
rm -f "$FAKE_BIN/heimdall-model-resolve"
run_hmd "some-unknown-task-resolver-absent"

if claude_reached; then
  ok "launch survives a MISSING heimdall-model-resolve (no 127 abort)"
else
  bad "missing heimdall-model-resolve aborted the launcher before launch:task"
  cat "$TRACE_FILE" >&2
fi

# B. resolver present, NO project override — assert launch still reaches the
#    task AND that the main agent is left UNPINNED (CLAUDE.md "Model routing":
#    "hmd does not hardcode opus — or anything else — for the main agent").
#    select_model() must not call the resolver at all here: there is no tier to
#    resolve when the launch is meant to inherit the operator's own default.
#    Hermetic: cd into an isolated empty dir before launching. WORK_DIR is
#    literally $(pwd) (bin/heimdall:24), so without this a bare `run_hmd` here
#    inherits THIS test's own cwd — which is $REPO when run via run-all.sh or
#    directly from the repo root. A prior version of this assertion read
#    $REPO/.planning/settings.json by accident: it passed in a worktree that
#    happens to lack that file and failed for real on a checkout that has one
#    committed. cd is required; mktemp alone does not change $(pwd).
reset
make_stub heimdall-model-resolve
NO_OVERRIDE_DIR="$(mktemp -d /tmp/test-heimdall-no-override-XXXXXX)"
( cd "$NO_OVERRIDE_DIR" && run_hmd "some-unknown-task-resolver-present" )
rm -rf "$NO_OVERRIDE_DIR"

if claude_reached; then
  ok "launch reaches launch:task with heimdall-model-resolve present"
else
  bad "launch failed to reach launch:task with the resolver present"
  cat "$TRACE_FILE" >&2
fi

if stub_called "heimdall-model-resolve"; then
  bad "heimdall-model-resolve was invoked with no project override present — the main agent must stay unpinned"
  cat "$STUB_OUT" >&2
else
  ok "present resolver is NOT invoked absent an override — main agent inherits the operator's default, unpinned"
fi

# B2. resolver present AND a .planning/settings.json project override — the
#     main agent must STILL stay unpinned. default_code used to be read here
#     and applied to THIS launch (a second, subtler instance of the exact bug
#     CLAUDE.md's directive forbids, merely gated behind an opt-in file
#     instead of being unconditional): no code path anywhere in this repo
#     ever applied default_code to a DELEGATED coding subagent spawn, so
#     pinning the main agent was its entire real mechanical effect. Removed
#     from select_model() (bin/heimdall) and re-documented in
#     commands/save.md — the file is still injected verbatim into the
#     preamble by load_checkpoint_context(), so default_code remains visible
#     to the orchestrator as advisory text for ITS OWN subagent spawns,
#     exactly like parallelism/governance/avoid_dirs. It must never again
#     reach this launch's own MODEL_FLAG. Hermetic for the same reason as B:
#     cd into the dir that owns the constructed settings.json.
reset
OVERRIDE_DIR="$(mktemp -d /tmp/test-heimdall-override-XXXXXX)"
mkdir -p "$OVERRIDE_DIR/.planning"
cat > "$OVERRIDE_DIR/.planning/settings.json" <<'EOJSON'
{"model_routing": {"default_code": "opus"}}
EOJSON
( cd "$OVERRIDE_DIR" && run_hmd "some-unknown-task-resolver-present-with-override" )
rm -rf "$OVERRIDE_DIR"

if claude_reached; then
  ok "launch reaches launch:task with a project override present"
else
  bad "launch failed to reach launch:task with a project override present"
  cat "$TRACE_FILE" >&2
fi

if stub_called "heimdall-model-resolve"; then
  bad "heimdall-model-resolve was invoked for the main agent's own launch despite CLAUDE.md's unconditional 'never pinned' — a project-level default_code must stay advisory-only, never a mechanical override of THIS launch"
  cat "$STUB_OUT" >&2
else
  ok "project override present but main agent still unpinned — resolver not invoked, default_code is advisory-only (commands/save.md)"
fi

rm -f "$FAKE_BIN/heimdall-model-resolve"

# ══════════════════════════════════════════════════════════════════════════════
# 8c. THE WHOLE BUG CLASS, NOT JUST ONE INSTANCE — every launch-path helper must
#     be survivable, both ABSENT and PRESENT-BUT-NOT-EXECUTABLE.
#
#     8b pins ONE helper (heimdall-model-resolve). The defect it pins is a CLASS:
#     under `set -euo pipefail` an unguarded helper call kills the launcher. The
#     shapes that are fatal (measured on bash 3.2.57, not assumed):
#         X="$(helper)"        plain assignment          → FATAL
#         helper | while read  pipeline head (pipefail)  → FATAL
#         helper               bare simple command       → FATAL
#     and the shapes that are NOT:
#         local X="$(helper)"  (local's own status is 0) → survives
#         cmd "$(helper)"      (outer status governs)    → survives
#         helper || fallback / if helper / done < <(helper)
#     NOTE `2>/dev/null` silences the MESSAGE, never the exit status — it makes a
#     fatal call SILENT, not safe.
#
#     A lost +x bit is a distinct failure state from an absent file (chmod 000
#     survives a `[ -f ]` test but not `[ -x ]`), so both are exercised here.
# ══════════════════════════════════════════════════════════════════════════════
LAUNCH_HELPERS="heimdall-model-resolve skill-manager heimdall-face heimdall-reuse-metric heimdall-persona heimdall-frontdoor heimdall-comprehend heimdall-telemetry heimdall-haid"

for helper in $LAUNCH_HELPERS; do
  # ABSENT
  reset
  rm -f "$FAKE_BIN/$helper"
  run_hmd "unknown-task-absent-$helper"
  if claude_reached; then
    ok "launch survives ABSENT $helper"
  else
    bad "ABSENT $helper aborted the launcher before launch:task"
    cat "$TRACE_FILE" >&2
  fi

  # PRESENT BUT NOT EXECUTABLE (lost +x bit — a partial/interrupted install)
  reset
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/$helper"
  chmod 000 "$FAKE_BIN/$helper"
  run_hmd "unknown-task-noexec-$helper"
  if claude_reached; then
    ok "launch survives NON-EXECUTABLE $helper (lost +x bit)"
  else
    bad "NON-EXECUTABLE $helper aborted the launcher before launch:task"
    cat "$TRACE_FILE" >&2
  fi
  rm -f "$FAKE_BIN/$helper"
done

# ══════════════════════════════════════════════════════════════════════════════
# 8d. `hmd --skills` MUST NOT die on a missing bin/skill-manager.
#
#     Sibling of the 8b defect, found by sweeping the class. Line ~2217 called the
#     helper as a PIPELINE HEAD:
#         "$PLUGIN_DIR/bin/skill-manager" status "$WORK_DIR" 2>/dev/null | while …
#     Under `pipefail` the pipeline inherits the helper's 127, `set -e` fires, and
#     `--skills` dies part-way — the entire "Commands:" help block below it never
#     prints. Worse than 8b: the `2>/dev/null` swallows the diagnostic, so the
#     user sees truncated output and NO error at all.
#
#     Pinned from both sides, same as 8b:
#       A. skill-manager ABSENT/non-exec → --skills still completes (rc 0) and
#          still prints the trailing Commands block.
#       B. skill-manager PRESENT         → it is still actually invoked with
#          `status`, so a guard can never silently shadow the real helper.
# ══════════════════════════════════════════════════════════════════════════════
# run_skills — like run_hmd but keeps stdout so we can assert the tail printed.
SKILLS_OUT="$(mktemp /tmp/test-hmd-skills-XXXXXX)"
run_skills() {
  PATH="$FAKE_BIN:$PATH" \
  HEIMDALL_HOME="$FAKE_HOME" \
  HEIMDALL_NO_INTRO=1 \
  HEIMDALL_NO_UPDATE_CHECK=1 \
  HMD_STUB_OUT="$STUB_OUT" \
  bash "$FAKE_BIN/heimdall" --skills >"$SKILLS_OUT" 2>/dev/null
}

# A1. absent
reset
rm -f "$FAKE_BIN/skill-manager"
if run_skills; then
  ok "--skills exits 0 with skill-manager ABSENT"
else
  bad "--skills died (rc $?) with skill-manager ABSENT"
fi
if grep -q "Install from registry" "$SKILLS_OUT"; then
  ok "--skills prints the trailing Commands block with skill-manager ABSENT"
else
  bad "--skills output truncated at the skill-manager pipeline (ABSENT)"
  tail -4 "$SKILLS_OUT" >&2
fi

# A2. present but not executable
reset
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/skill-manager"
chmod 000 "$FAKE_BIN/skill-manager"
if run_skills; then
  ok "--skills exits 0 with skill-manager NON-EXECUTABLE"
else
  bad "--skills died with a non-executable skill-manager"
fi
rm -f "$FAKE_BIN/skill-manager"

# B. present → still genuinely invoked (falsifier: a guard must not shadow it)
reset
make_stub skill-manager
if run_skills; then
  ok "--skills exits 0 with skill-manager PRESENT"
else
  bad "--skills failed with skill-manager present"
fi
if stub_called "skill-manager" && args_contain "skill-manager ARGS: status"; then
  ok "present skill-manager IS invoked with 'status' (guard does not shadow it)"
else
  bad "skill-manager present but never invoked with 'status'"
  cat "$STUB_OUT" >&2
fi
rm -f "$FAKE_BIN/skill-manager"
rm -f "$SKILLS_OUT"

# ══════════════════════════════════════════════════════════════════════════════
# 8e. MAIN-AGENT PIN GUARD — --resume and --team must never force --model either.
#
#     8b/8c pin select_model()'s own launch path (the bottom-of-file default
#     route). But bin/heimdall has THREE places that exec/spawn a `claude`
#     process for the main agent, and the pin bug this suite exists to catch
#     (CLAUDE.md "Model routing": "Main Claude Code agent: never pinned...
#     hmd does not hardcode opus — or anything else — for the main agent")
#     previously lived in ALL THREE:
#       - select_model()            (covered above, section 8b)
#       - --resume/--continue relaunch (`claude --continue ...`)
#       - --team tmux pane spawn       (`tmux send-keys ... claude --agent ...`)
#     A fix that only touched select_model() would leave --resume and --team
#     silently re-forcing opus on every relaunch/team pane — this section
#     closes that gap so the guard covers every operational spawn site, not
#     just one instance of the class.
# ══════════════════════════════════════════════════════════════════════════════

# --resume: claude --continue must carry no --model flag.
reset
make_stub claude
run_hmd --resume

if stub_called "claude" && args_contain "claude ARGS: --continue"; then
  ok "--resume reaches claude --continue"
else
  bad "--resume never invoked claude --continue"
  cat "$STUB_OUT" >&2
fi

if grep -q -- '--model' "$STUB_OUT" 2>/dev/null; then
  bad "--resume passed --model to claude — main agent must stay unpinned"
  cat "$STUB_OUT" >&2
else
  ok "--resume passes NO --model flag — main agent inherits the operator's default, unpinned"
fi

# --team: every spawned pane's claude invocation must carry no --model flag.
reset
make_stub tmux
run_hmd --team 2

if stub_called "tmux" && args_contain "tmux ARGS: new-session"; then
  ok "--team reaches tmux new-session"
else
  bad "--team never invoked tmux new-session"
  cat "$STUB_OUT" >&2
fi

if grep -q "claude --agent heimdall" "$STUB_OUT" 2>/dev/null; then
  ok "--team's send-keys carries the claude --agent heimdall launch line"
else
  bad "--team never sent a claude --agent heimdall launch line to any pane"
  cat "$STUB_OUT" >&2
fi

if grep -q -- '--model' "$STUB_OUT" 2>/dev/null; then
  bad "--team passed --model to a spawned pane — main agent must stay unpinned"
  cat "$STUB_OUT" >&2
else
  ok "--team panes get NO --model flag — main agent inherits the operator's default, unpinned"
fi
rm -f "$FAKE_BIN/tmux" "$FAKE_BIN/claude"

# ══════════════════════════════════════════════════════════════════════════════
# 9. Syntax check
# ══════════════════════════════════════════════════════════════════════════════
if bash -n "$REAL_BIN" 2>/dev/null; then
  ok "bin/heimdall passes bash -n syntax check"
else
  bad "bin/heimdall has syntax errors"
  bash -n "$REAL_BIN" >&2
fi

# ── summary ──────────────────────────────────────────────────────────────────
printf "\n  Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
