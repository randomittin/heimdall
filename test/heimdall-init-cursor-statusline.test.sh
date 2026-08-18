#!/usr/bin/env bash
# test/heimdall-init-cursor-statusline.test.sh — `hmd init` auto-registers the
# Cursor CLI statusline HUD (bin/heimdall-statusline-register-cursor) when Cursor
# CLI is detected present, so a Cursor user gets the watchman HUD without ever
# knowing bin/heimdall-statusline-register-cursor exists.
#
# THIS SUITE LOCKS:
#   1. Cursor PRESENT  -> `hmd init` registers the statusline (state=registered,
#      valid statusLine block written to a hermetic cli-config.json), announces it
#      in exactly one line naming the undo command.
#   2. Cursor ABSENT   -> no-op: exit 0, no ~/.cursor/ directory ever created, no
#      announce text.
#   3. RE-RUN          -> idempotent: second `hmd init` does not duplicate/churn
#      the entry (byte-identical file), and is silent (no re-announce).
#   4. FOREIGN statusLine already present -> preserved untouched (no-clobber), no
#      false announce.
#   5. Unrelated sibling keys in cli-config.json -> preserved byte-for-byte across
#      a real (write) registration.
#   6. OPT-OUT (--no-cursor-statusline flag, HEIMDALL_NO_CURSOR_STATUSLINE_REGISTER
#      env, ~/.heimdall/no-cursor-statusline-register marker) -> all honored, no
#      file created.
#   7. UNREGISTER (`heimdall-statusline-register-cursor unregister`, reachable via
#      `hmd cursor-statusline unregister`) -> removes OUR entry cleanly, leaves a
#      foreign entry or an absent file untouched, and a later `hmd init` can
#      re-register (full undo/redo round-trip).
#   8. BACKUP -> a pre-existing cli-config.json gets a `.bak` sibling holding the
#      exact pre-write content before its first write; a fresh (no prior file)
#      target gets no spurious backup.
#   9. DISPATCH -> `hmd cursor-statusline` routes through bin/heimdall to
#      heimdall-statusline-register-cursor, args forwarded, no Claude fall-through.
#  10. NEVER TOUCHES THE REAL FILE -> the whole suite runs hermetically.
#
# HERMETIC. HOME is redirected to a mktemp dir; HEIMDALL_CURSOR_CLI_CONFIG pins the
# config path per scenario so the real ~/.cursor/cli-config.json is NEVER touched
# (asserted directly, sha256 before/after — mirrors
# test/heimdall-statusline-register-cursor.test.sh's own sentinel). PATH is curated
# from an explicit tool allowlist (mirrors test/heimdall-init.test.sh) and
# DELIBERATELY may or may not carry a `cursor-agent` stub depending on the
# scenario — this dev box has a REAL cursor-agent on PATH, so "Cursor absent"
# scenarios must PROVABLY scrub it, not just fail to add one (see precondition 0).
#
# FALSIFIABILITY: verified by hand during development (documented in the coder's
# final report, not re-run here to keep this suite's runtime bounded) — forcing the
# Cursor-presence gate to always read "false" flips scenario 1 (and only scenario
# 1) to RED, proving the gate is load-bearing and scenario 2's absence-proof was
# not accidentally always-true.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin"
INIT_BIN="$BIN/heimdall-init"
REAL_HEIMDALL="$BIN/heimdall"
CURSOR_REG="$BIN/heimdall-statusline-register-cursor"
AISEL_BIN="$BIN/heimdall-ai-select"
STATUSLINE_BIN="$BIN/heimdall-statusline"
# DEFAULT-ON egress guard: mirrors test/heimdall-init.test.sh — `hmd init` fires a
# fire-and-forget team-auto + presence-beat plumbing that must never reach a real
# control plane from under this test's hermetic HOME.
. "$REPO/test/lib/net-default-guard.sh"

for b in "$INIT_BIN" "$REAL_HEIMDALL" "$CURSOR_REG" "$AISEL_BIN" "$STATUSLINE_BIN"; do
  [ -x "$b" ] || { echo "FATAL: missing/!exec $b" >&2; exit 2; }
done
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found" >&2; exit 2; }
command -v jq  >/dev/null 2>&1 || { echo "FATAL: jq not found (heimdall-ai-select requires it)" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; }

sha256_of() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null; }

# ── real-file untouched sentinel: snapshot BEFORE HOME is redirected ──────────
REAL_CFG="$HOME/.cursor/cli-config.json"
REAL_BEFORE=""
[ -f "$REAL_CFG" ] && REAL_BEFORE="$(sha256_of "$REAL_CFG")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-init-cursor.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
export HOME="$WORK/home"; mkdir -p "$HOME/.heimdall"
export HEIMDALL_NO_TEAM_AUTOSHARE=1

# ── PATH sandboxes ───────────────────────────────────────────────────────────
SANDBOX="$WORK/sandbox-bin"; mkdir -p "$SANDBOX"
ln -sf "$REAL_HEIMDALL" "$SANDBOX/hmd"
BASE_PATH="$SANDBOX"
for t in git jq python3 perl date sed grep head cat mkdir chmod readlink basename dirname mktemp env bash rm ls touch printf sort wc cp find; do
  p="$(command -v "$t" 2>/dev/null || true)"; [ -n "$p" ] || continue
  d="$(dirname "$p")"
  case ":$BASE_PATH:" in *":$d:"*) ;; *) BASE_PATH="$BASE_PATH:$d" ;; esac
done

CURSOR_STUB_DIR="$WORK/cursor-stub-bin"; mkdir -p "$CURSOR_STUB_DIR"
cat > "$CURSOR_STUB_DIR/cursor-agent" <<'STUBEOF'
#!/bin/sh
exit 0
STUBEOF
chmod +x "$CURSOR_STUB_DIR/cursor-agent"
WITH_CURSOR_PATH="$CURSOR_STUB_DIR:$BASE_PATH"
NO_CURSOR_PATH="$BASE_PATH"

echo "════════════════════════════════════════════════════════════════"
echo "hmd init — Cursor CLI statusline auto-registration"
echo "════════════════════════════════════════════════════════════════"

if PATH="$NO_CURSOR_PATH" command -v cursor-agent >/dev/null 2>&1 || PATH="$NO_CURSOR_PATH" command -v agent >/dev/null 2>&1; then
  bad "0 precondition: cursor-agent/agent IS reachable on the 'absent' test PATH — the absence proof cannot run here" \
      "$(PATH="$NO_CURSOR_PATH" command -v cursor-agent 2>/dev/null; PATH="$NO_CURSOR_PATH" command -v agent 2>/dev/null)"
else
  ok "0 precondition: cursor-agent/agent PROVABLY absent from the 'absent' test PATH"
fi

gitcfg() { git -C "$1" config user.email dev@example.com; git -C "$1" config user.name Dev; }
newrepo() { mkdir -p "$1"; git -C "$1" init -q; gitcfg "$1"; }

# run_init REPO PATHVAL CFG [extra args...]
run_init() {
  local repo="$1" pathval="$2" cfg="$3"; shift 3
  ( cd "$repo" && env PATH="$pathval" HOME="$HOME" HEIMDALL_CURSOR_CLI_CONFIG="$cfg" "$INIT_BIN" "$@" )
}

# ══════════════════════════════════════════════════════════════════════════════
# 1. CURSOR PRESENT: hmd init auto-registers the statusline
# ══════════════════════════════════════════════════════════════════════════════
echo "== 1) CURSOR PRESENT: hmd init auto-registers the statusline =="
R1="$WORK/r1"; newrepo "$R1"
CFG1="$WORK/cfg1/.cursor/cli-config.json"
OUT1="$(run_init "$R1" "$WITH_CURSOR_PATH" "$CFG1" 2>&1)"; EX1=$?
[ "$EX1" = 0 ] && ok "1a hmd init exits 0 with Cursor present" || bad "1a hmd init exited $EX1" "$OUT1"
[ -f "$CFG1" ] && ok "1b cli-config.json was created" || bad "1b cli-config.json NOT created" "$OUT1"
SL1_OK="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sl = d.get("statusLine")
assert isinstance(sl, dict), "statusLine missing"
assert sl.get("type") == "command"
assert sl.get("command") == sys.argv[2], "command mismatch: %r" % sl.get("command")
print("OK")
' "$CFG1" "$STATUSLINE_BIN" 2>&1)"
[ "$SL1_OK" = OK ] && ok "1c statusLine points at the real bin/heimdall-statusline (absolute path)" || bad "1c shape check failed" "$SL1_OK"
[ -x "$STATUSLINE_BIN" ] && ok "1d the registered command resolves to a real, executable file" || bad "1d target not executable"
printf '%s' "$OUT1" | grep -qi "cursor HUD" && ok "1e hmd init announces the registration (one line)" || bad "1e no cursor HUD announce line in hmd init output" "$OUT1"
ANNOUNCE_LINES="$(printf '%s\n' "$OUT1" | grep -ci "cursor HUD" || true)"
[ "$ANNOUNCE_LINES" = 1 ] && ok "1f the announce is exactly one line" || bad "1f expected exactly 1 announce line, got $ANNOUNCE_LINES" "$OUT1"
printf '%s' "$OUT1" | grep -qi "unregister" && ok "1g the announce says how to undo it" || bad "1g announce does not mention how to undo" "$OUT1"

# ══════════════════════════════════════════════════════════════════════════════
# 2. CURSOR ABSENT: clean no-op
# ══════════════════════════════════════════════════════════════════════════════
echo "== 2) CURSOR ABSENT: hmd init is a clean no-op for the statusline =="
R2="$WORK/r2"; newrepo "$R2"
CFG2="$WORK/cfg2/.cursor/cli-config.json"
OUT2="$(run_init "$R2" "$NO_CURSOR_PATH" "$CFG2" 2>&1)"; EX2=$?
[ "$EX2" = 0 ] && ok "2a hmd init exits 0 with Cursor absent" || bad "2a hmd init exited $EX2" "$OUT2"
[ ! -f "$CFG2" ] && ok "2b no cli-config.json was created" || bad "2b cli-config.json created despite Cursor being absent"
[ ! -d "$WORK/cfg2/.cursor" ] && ok "2c no ~/.cursor/ directory was created at all" || bad "2c a .cursor dir was created despite Cursor being absent"
printf '%s' "$OUT2" | grep -qi "cursor HUD" && bad "2d hmd init mentioned the cursor HUD despite Cursor being absent" "$OUT2" || ok "2d no cursor-related announce text (silent, never nags)"

# ══════════════════════════════════════════════════════════════════════════════
# 3. RE-RUN: idempotent, silent once current
# ══════════════════════════════════════════════════════════════════════════════
echo "== 3) RE-RUN: a second hmd init does not duplicate or churn the entry =="
SUM3_BEFORE="$(sha256_of "$CFG1")"
OUT3="$(run_init "$R1" "$WITH_CURSOR_PATH" "$CFG1" --force 2>&1)"; EX3=$?
SUM3_AFTER="$(sha256_of "$CFG1")"
[ "$EX3" = 0 ] && ok "3a re-run exits 0" || bad "3a re-run exited $EX3" "$OUT3"
[ "$SUM3_BEFORE" = "$SUM3_AFTER" ] && ok "3b cli-config.json is byte-identical after re-init (no duplication/churn)" || bad "3b cli-config.json CHANGED on a no-op re-init"
printf '%s' "$OUT3" | grep -qi "cursor HUD" && bad "3c re-init re-announced an already-registered HUD (should be silent once current)" "$OUT3" || ok "3c re-init is silent once the HUD is already registered (current, not re-announced)"

# ══════════════════════════════════════════════════════════════════════════════
# 4. FOREIGN statusLine preserved (no-clobber honored by the auto path)
# ══════════════════════════════════════════════════════════════════════════════
echo "== 4) FOREIGN statusLine already present: hmd init preserves it (no-clobber) =="
R4="$WORK/r4"; newrepo "$R4"
CFG4="$WORK/cfg4/.cursor/cli-config.json"; mkdir -p "$WORK/cfg4/.cursor"
python3 -c '
import json
json.dump({"statusLine": {"type": "command", "command": "/usr/local/bin/my-own-statusline", "padding": 1}},
          open("'"$CFG4"'", "w"))
'
SUM4_BEFORE="$(sha256_of "$CFG4")"
OUT4="$(run_init "$R4" "$WITH_CURSOR_PATH" "$CFG4" 2>&1)"; EX4=$?
SUM4_AFTER="$(sha256_of "$CFG4")"
[ "$EX4" = 0 ] && ok "4a hmd init exits 0 with a foreign statusLine present" || bad "4a exited $EX4" "$OUT4"
[ "$SUM4_BEFORE" = "$SUM4_AFTER" ] && ok "4b the foreign statusLine survives byte-for-byte (no-clobber honored by the auto path)" || bad "4b the foreign statusLine was modified"
printf '%s' "$OUT4" | grep -qi "cursor HUD" && bad "4c hmd init announced a registration that did not happen (kept-custom, not registered)" "$OUT4" || ok "4c no false announce when the existing custom line was kept, not registered"

# ══════════════════════════════════════════════════════════════════════════════
# 5. UNRELATED KEYS survive a real registration
# ══════════════════════════════════════════════════════════════════════════════
echo "== 5) UNRELATED KEYS: sibling keys in cli-config.json survive a real registration =="
R5="$WORK/r5"; newrepo "$R5"
CFG5="$WORK/cfg5/.cursor/cli-config.json"; mkdir -p "$WORK/cfg5/.cursor"
python3 -c '
import json
json.dump({"authInfo": {"email": "me@example.com", "userId": 42}, "permissions": {"foo": "bar"}},
          open("'"$CFG5"'", "w"))
'
OUT5="$(run_init "$R5" "$WITH_CURSOR_PATH" "$CFG5" 2>&1)"; EX5=$?
CHECK5="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("authInfo") == {"email": "me@example.com", "userId": 42}, "authInfo mutated"
assert d.get("permissions") == {"foo": "bar"}, "permissions mutated"
assert isinstance(d.get("statusLine"), dict) and d["statusLine"].get("command") == sys.argv[2]
print("OK")
' "$CFG5" "$STATUSLINE_BIN" 2>&1)"
[ "$EX5" = 0 ] && ok "5a hmd init exits 0" || bad "5a exited $EX5" "$OUT5"
[ "$CHECK5" = OK ] && ok "5b unrelated sibling keys (authInfo, permissions) survive byte-faithfully alongside the new statusLine" || bad "5b $CHECK5"

# ══════════════════════════════════════════════════════════════════════════════
# 6. OPT-OUT: flag + env + marker file
# ══════════════════════════════════════════════════════════════════════════════
echo "== 6) OPT-OUT: --no-cursor-statusline and the env/file markers are all honored =="
R6="$WORK/r6"; newrepo "$R6"
CFG6="$WORK/cfg6/.cursor/cli-config.json"
OUT6="$(run_init "$R6" "$WITH_CURSOR_PATH" "$CFG6" --no-cursor-statusline 2>&1)"; EX6=$?
[ "$EX6" = 0 ] && [ ! -f "$CFG6" ] && ok "6a --no-cursor-statusline: no file created, exit 0" || bad "6a --no-cursor-statusline did not suppress registration" "$OUT6"

R6b="$WORK/r6b"; newrepo "$R6b"
CFG6b="$WORK/cfg6b/.cursor/cli-config.json"
OUT6b="$(cd "$R6b" && env PATH="$WITH_CURSOR_PATH" HOME="$HOME" HEIMDALL_CURSOR_CLI_CONFIG="$CFG6b" HEIMDALL_NO_CURSOR_STATUSLINE_REGISTER=1 "$INIT_BIN" 2>&1)"; EX6b=$?
[ "$EX6b" = 0 ] && [ ! -f "$CFG6b" ] && ok "6b HEIMDALL_NO_CURSOR_STATUSLINE_REGISTER=1 env is honored (registrar's own opt-out)" || bad "6b env opt-out not honored" "$OUT6b"

R6c="$WORK/r6c"; newrepo "$R6c"
CFG6c="$WORK/cfg6c/.cursor/cli-config.json"
mkdir -p "$HOME/.heimdall"; : > "$HOME/.heimdall/no-cursor-statusline-register"
OUT6c="$(run_init "$R6c" "$WITH_CURSOR_PATH" "$CFG6c" 2>&1)"; EX6c=$?
rm -f "$HOME/.heimdall/no-cursor-statusline-register"
[ "$EX6c" = 0 ] && [ ! -f "$CFG6c" ] && ok "6c ~/.heimdall/no-cursor-statusline-register marker file is honored" || bad "6c marker-file opt-out not honored" "$OUT6c"

# ══════════════════════════════════════════════════════════════════════════════
# 7. UNREGISTER
# ══════════════════════════════════════════════════════════════════════════════
echo "== 7) UNREGISTER: hmd cursor-statusline unregister removes our entry cleanly =="
R7="$WORK/r7"; newrepo "$R7"
CFG7="$WORK/cfg7/.cursor/cli-config.json"
run_init "$R7" "$WITH_CURSOR_PATH" "$CFG7" >/dev/null 2>&1
[ -f "$CFG7" ] && ok "7a precondition: the entry exists before unregister" || bad "7a precondition failed: nothing to unregister"
UNREG_OUT="$(env PATH="$WITH_CURSOR_PATH" HOME="$HOME" HEIMDALL_CURSOR_CLI_CONFIG="$CFG7" "$REAL_HEIMDALL" cursor-statusline unregister 2>&1)"; UNREG_EX=$?
[ "$UNREG_EX" = 0 ] && printf '%s' "$UNREG_OUT" | grep -q unregistered && ok "7b hmd cursor-statusline unregister reports state=unregistered, exit 0" || bad "7b unregister failed" "$UNREG_OUT"
POST7="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print("absent" if "statusLine" not in d else "present")
' "$CFG7" 2>&1)"
[ "$POST7" = absent ] && ok "7c the statusLine key is gone after unregister" || bad "7c statusLine key still present after unregister" "$POST7"

R7b="$WORK/r7b"; CFG7b="$WORK/cfg7b/.cursor/cli-config.json"; mkdir -p "$WORK/cfg7b/.cursor"
python3 -c '
import json
json.dump({"statusLine": {"type": "command", "command": "/usr/local/bin/my-own-statusline"}}, open("'"$CFG7b"'", "w"))
'
SUM7b_BEFORE="$(sha256_of "$CFG7b")"
UNREG7b_OUT="$(HOME="$HOME" HEIMDALL_CURSOR_CLI_CONFIG="$CFG7b" "$CURSOR_REG" unregister 2>&1)"; UNREG7b_EX=$?
SUM7b_AFTER="$(sha256_of "$CFG7b")"
[ "$UNREG7b_EX" = 0 ] && printf '%s' "$UNREG7b_OUT" | grep -q kept-custom && ok "7d unregister leaves a FOREIGN statusLine untouched (state=kept-custom)" || bad "7d unregister touched a foreign statusLine" "$UNREG7b_OUT"
[ "$SUM7b_BEFORE" = "$SUM7b_AFTER" ] && ok "7e the foreign file is byte-identical after a no-op unregister" || bad "7e foreign file changed by unregister"

CFG7c="$WORK/cfg7c/.cursor/cli-config.json"
UNREG7c_OUT="$(HOME="$HOME" HEIMDALL_CURSOR_CLI_CONFIG="$CFG7c" "$CURSOR_REG" unregister 2>&1)"; UNREG7c_EX=$?
[ "$UNREG7c_EX" = 0 ] && [ ! -f "$CFG7c" ] && printf '%s' "$UNREG7c_OUT" | grep -q "not-registered" && ok "7f unregister on a never-registered target is a clean no-op (not-registered, exit 0, no file created)" || bad "7f unregister on absent target misbehaved" "$UNREG7c_OUT"

OUT7g="$(run_init "$R7" "$WITH_CURSOR_PATH" "$CFG7" 2>&1)"; EX7g=$?
POST7g="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print("present" if isinstance(d.get("statusLine"), dict) else "absent")
' "$CFG7" 2>&1)"
[ "$EX7g" = 0 ] && [ "$POST7g" = present ] && ok "7g a later hmd init re-registers after an unregister (full undo/redo round-trip)" || bad "7g re-registration after unregister failed" "$OUT7g"

# ══════════════════════════════════════════════════════════════════════════════
# 8. BACKUP before first write
# ══════════════════════════════════════════════════════════════════════════════
echo "== 8) BACKUP: a pre-existing cli-config.json gets backed up before its first write =="
R8="$WORK/r8"; newrepo "$R8"
CFG8DIR="$WORK/cfg8/.cursor"; CFG8="$CFG8DIR/cli-config.json"; mkdir -p "$CFG8DIR"
python3 -c 'import json; json.dump({"permissions": {"x": 1}}, open("'"$CFG8"'", "w"))'
BEFORE8_CONTENT="$(cat "$CFG8")"
run_init "$R8" "$WITH_CURSOR_PATH" "$CFG8" >/dev/null 2>&1
BAK_COUNT="$(find "$CFG8DIR" -maxdepth 1 -name 'cli-config.json.heimdall-init-*.bak' 2>/dev/null | grep -c . || true)"
if [ "$BAK_COUNT" -ge 1 ]; then
  ok "8a a backup file was created before the first write"
  BAK_FILE="$(find "$CFG8DIR" -maxdepth 1 -name 'cli-config.json.heimdall-init-*.bak' 2>/dev/null | head -1)"
  BAK_CONTENT="$(cat "$BAK_FILE" 2>/dev/null || true)"
  [ "$BAK_CONTENT" = "$BEFORE8_CONTENT" ] && ok "8b the backup holds the PRE-write content exactly" || bad "8b backup content does not match pre-write content"
else
  bad "8a no backup file was created before the first write"
fi
R8c="$WORK/r8c"; newrepo "$R8c"
CFG8cDIR="$WORK/cfg8c/.cursor"; CFG8c="$CFG8cDIR/cli-config.json"
run_init "$R8c" "$WITH_CURSOR_PATH" "$CFG8c" >/dev/null 2>&1
BAK8C_COUNT="$(find "$CFG8cDIR" -maxdepth 1 -name '*.bak' 2>/dev/null | grep -c . || true)"
[ "$BAK8C_COUNT" = 0 ] && ok "8c no spurious backup on a fresh (no pre-existing file) registration" || bad "8c an unnecessary backup was created for a fresh target"

# ══════════════════════════════════════════════════════════════════════════════
# 9. DISPATCH: hmd cursor-statusline routes through bin/heimdall
# ══════════════════════════════════════════════════════════════════════════════
echo "== 9) DISPATCH: hmd cursor-statusline routes through bin/heimdall, args forwarded =="
FAKE="$WORK/fake"; mkdir -p "$FAKE/bin" "$FAKE/home" "$FAKE/.claude-plugin"
cp "$REAL_HEIMDALL" "$FAKE/bin/heimdall"; chmod +x "$FAKE/bin/heimdall"
touch "$FAKE/home/setup-done"
cat > "$FAKE/bin/claude" <<'E'
#!/usr/bin/env bash
exit 0
E
chmod +x "$FAKE/bin/claude"
STUB_OUT="$WORK/stub.out"; TRACE="$WORK/trace.out"; : > "$STUB_OUT"; : > "$TRACE"
cat > "$FAKE/bin/heimdall-statusline-register-cursor" <<EOB
#!/usr/bin/env bash
printf 'heimdall-statusline-register-cursor ARGS: %s\n' "\$*" >> "\${HMD_STUB_OUT:-/dev/null}"
exit 0
EOB
chmod +x "$FAKE/bin/heimdall-statusline-register-cursor"
run_fake() {
  PATH="$FAKE/bin:$WITH_CURSOR_PATH" HEIMDALL_HOME="$FAKE/home" HEIMDALL_NO_INTRO=1 \
    HEIMDALL_NO_UPDATE_CHECK=1 HMD_STUB_OUT="$STUB_OUT" HEIMDALL_TRACE_ORDER="$TRACE" \
    bash "$FAKE/bin/heimdall" "$@" >/dev/null 2>&1 || true
}
run_fake cursor-statusline unregister
grep -q "heimdall-statusline-register-cursor" "$STUB_OUT" && grep -qF -- "unregister" "$STUB_OUT" \
  && ok "9a hmd cursor-statusline routes to heimdall-statusline-register-cursor with args forwarded" || bad "9a dispatch failed" "$(cat "$STUB_OUT")"
grep -q "launch:task" "$TRACE" && bad "9b hmd cursor-statusline WRONGLY fell through to the Claude launch path" "$(cat "$TRACE" 2>/dev/null)" || ok "9b hmd cursor-statusline does NOT fall through to Claude"

# ══════════════════════════════════════════════════════════════════════════════
# 10. NEVER TOUCHES THE REAL FILE
# ══════════════════════════════════════════════════════════════════════════════
echo "== 10) NEVER TOUCHES THE REAL FILE: whole suite ran hermetically =="
REAL_AFTER=""
[ -f "$REAL_CFG" ] && REAL_AFTER="$(sha256_of "$REAL_CFG")"
[ "$REAL_BEFORE" = "$REAL_AFTER" ] && ok "10 real \$HOME/.cursor/cli-config.json untouched across the whole suite" \
                                     || bad "10 real \$HOME/.cursor/cli-config.json CHANGED — hermeticity breach"

echo
printf "  Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
