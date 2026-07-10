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
