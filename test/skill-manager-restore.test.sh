#!/usr/bin/env bash
# test/skill-manager-restore.test.sh -- the skills a launch pauses are put back when it ends.
#
# THE BUG. bin/heimdall pauses the plugins a project does not need (`skill-manager activate`)
# and puts them back in its EXIT trap (`skill-manager restore FILE`). The two halves agreed on
# the restore file by asking `skill-manager restore-file` -- which built the path from ITS OWN
# `$$`. Every skill-manager call is a new process, so `activate` wrote
# /tmp/heimdall-skill-restore-<pid A>.json while the trap asked for <pid B>: `restore` found no
# file, returned 0, and nothing was ever restored. Measured on the operator's machine
# (2026-10-05): 37 unconsumed restore files in /tmp, 33 of them recording the SAME already-paused
# plugin set as their "previous" state -- every launch started from what the last one left.
#
# THE CONTRACT UNDER TEST
#   - the LAUNCHER (its own pid) picks ONE restore path per launch and hands it to BOTH halves:
#       skill-manager restore-file <owner-pid>        prints it (a pure function of the owner)
#       skill-manager activate [dir] [restore-file]   records the undo there
#       skill-manager restore [restore-file]          applies it and deletes it
#   - the files live in a private per-user dir (<HEIMDALL_HOME>/skill-restore), one per owner,
#     so two concurrent launches cannot overwrite each other;
#   - `restore` undoes exactly what ITS launch changed, whatever order overlapping launches exit
#     in, and never clobbers a change somebody else made meanwhile;
#   - a launcher that DIED (kill -9, power loss) leaves a file whose owner pid is gone: the next
#     `activate` recovers it first, bounded to a fixed number of files per activation.
#
# HARNESS. Hermetic: HOME is a throwaway dir (so ~/.claude/settings.json is a fixture, never the
# operator's), the plugin dir is a COPY of bin/ with its own heimdall-skills.json, `claude` is a
# stub. The launcher sections run the REAL bin/heimdall + the REAL skill-manager against it.
#
# EXIT: 0 = all assertions pass; 1 = any FAIL.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
. "$REPO/test/lib/net-default-guard.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

for f in "$REPO/bin/heimdall" "$REPO/bin/skill-manager"; do
  [ -x "$f" ] || { echo "FATAL: $f missing or not executable"; exit 1; }
done

# ── sandbox ───────────────────────────────────────────────────────────────────
TMP="$(mktemp -d /tmp/test-skill-manager-restore-XXXXXX)"
BG_PIDS=""
cleanup() {
  local p
  : > "$TMP/abort" 2>/dev/null || true          # frees any stub claude still waiting on a GO file
  for p in $BG_PIDS; do kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

FAKE="$TMP/plugin"            # a COPY of the launcher + skill-manager: PLUGIN_DIR resolves here
STUBS="$TMP/stubs"
HOME_DIR="$TMP/home"
SETTINGS="$HOME_DIR/.claude/settings.json"
STATE_DIR="$HOME_DIR/.heimdall/skill-restore"
PLAIN="$TMP/work-plain"       # a project that needs only the permanent plugin
FRONT="$TMP/work-front"       # a project that also needs fe@t (it holds a .tsx file)
mkdir -p "$FAKE/bin/lib" "$FAKE/.claude-plugin" "$STUBS" "$TMP/pybin" \
         "$HOME_DIR/.heimdall" "$HOME_DIR/.claude" "$PLAIN" "$FRONT"
touch "$FRONT/app.tsx" "$HOME_DIR/.heimdall/setup-done"
cp "$REPO/bin/heimdall" "$FAKE/bin/heimdall"
cp "$REPO/bin/skill-manager" "$FAKE/bin/skill-manager"
chmod +x "$FAKE/bin/heimdall" "$FAKE/bin/skill-manager"
[ -f "$REPO/bin/lib/skill_restore.py" ] && cp "$REPO/bin/lib/skill_restore.py" "$FAKE/bin/lib/skill_restore.py"

cat > "$FAKE/heimdall-skills.json" <<'EOF'
{
  "permanent": ["perm@t"],
  "detection": {
    "frontend": {"files": ["*.tsx"], "plugins": ["fe@t"]},
    "python":   {"files": ["*.py"],  "plugins": ["rev@t"]}
  },
  "on_demand": ["demand@t"]
}
EOF

# Pin the REAL interpreter (not a version-manager shim): the sandbox HOME must not change which
# python3 runs, and a shim would also make every call ~100ms slower.
REALPY="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
[ -x "$REALPY" ] || { echo "FATAL: no usable python3"; exit 1; }
ln -s "$REALPY" "$TMP/pybin/python3"
PATH="$TMP/pybin:$PATH"; export PATH

# The stub `claude`. The launcher's own launch is the call that carries `--agent heimdall`; it
# records the settings the session would start with, can announce itself (READY_FILE) and wait
# for a release (GO_FILE) so a test can hold a launch open, then exits STUB_CLAUDE_RC.
cat > "$STUBS/claude" <<'EOF'
#!/bin/sh
case " $* " in
  *" --agent heimdall "*)
    [ -n "${DURING_COPY:-}" ] && cp "$HOME/.claude/settings.json" "$DURING_COPY"
    [ -n "${READY_FILE:-}" ] && : > "$READY_FILE"
    if [ -n "${GO_FILE:-}" ]; then
      i=0
      while [ ! -e "$GO_FILE" ] && [ ! -e "${ABORT_FILE:-/nonexistent}" ] && [ "$i" -lt 900 ]; do
        sleep 0.1; i=$((i + 1))
      done
    fi
    exit "${STUB_CLAUDE_RC:-0}" ;;
esac
exit 0
EOF
chmod +x "$STUBS/claude"

# ── helpers ───────────────────────────────────────────────────────────────────
# sm ARGS... -- the skill-manager under test, in the sandbox HOME, with no inherited env.
sm() { env -i PATH="$PATH" HOME="$HOME_DIR" "$FAKE/bin/skill-manager" "$@"; }

# reset_settings -- the starting point S0, in the canonical on-disk format (indent 2 + newline) so
# that a full round trip can be compared BYTE for byte. Extra keys prove nothing else is touched.
reset_settings() {
  python3 - "$SETTINGS" <<'PY'
import json, sys
s = {
    "model": "opus",
    "permissions": {"allow": ["Bash(ls:*)"]},
    "enabledPlugins": {"perm@t": True, "fe@t": False, "rev@t": True, "demand@t": True, "extra@t": True},
}
with open(sys.argv[1], "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
PY
  cp "$SETTINGS" "$TMP/s0.json"
}
same_as_s0() { cmp -s "$SETTINGS" "$TMP/s0.json"; }

# plugins_of FILE -- "name=on|off ..." sorted: the enabledPlugins of a settings file.
plugins_of() {
  python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])).get("enabledPlugins", {})
print(" ".join("%s=%s" % (k, "on" if v else "off") for k, v in sorted(d.items())))
PY
}
plugins() { plugins_of "$SETTINGS"; }
S0_PLUGINS="demand@t=on extra@t=on fe@t=off perm@t=on rev@t=on"

# clean_state -- empty the sandbox's restore dir (the path is asserted to sit under $TMP first).
clean_state() {
  case "$STATE_DIR" in "$TMP"/*) ;; *) echo "FATAL: state dir escaped the sandbox: $STATE_DIR"; exit 1 ;; esac
  rm -f "$STATE_DIR"/* "$STATE_DIR"/.lock 2>/dev/null || true
}
state_count() { ls "$STATE_DIR"/*.json 2>/dev/null | wc -l | tr -d ' '; }
# stale_left -- how many of the seeded fake-owner restore files (pids 20000000NN) are still in the state dir.
stale_left() { find "$STATE_DIR" -maxdepth 1 -name '20000000*' | wc -l | tr -d ' '; }

# new_live_pid -- sets LIVE to a process that stays alive for the test. dead_pid -- sets DEAD to
# a pid that has already exited (a launcher that crashed).
new_live_pid() {
  # shellcheck disable=SC2217  # sleep never reads stdin; </dev/null just keeps the long-lived child off the test's own stdin
  sleep 600 </dev/null >/dev/null 2>&1 &
  LIVE=$!
  disown "$LIVE" 2>/dev/null || true             # no "Terminated" job notice when cleanup kills it
  BG_PIDS="$BG_PIDS $LIVE"
}
dead_pid()     { DEAD="$(sh -c 'echo $$')"; }

wait_for() {  # wait_for FILE SECONDS
  local i=0 max=$(( $2 * 10 ))
  while [ ! -e "$1" ] && [ "$i" -lt "$max" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$1" ]
}

# run_launcher WORKDIR ARGS... -- the REAL launcher in the sandbox against the stub claude.
# Knobs (env): STUB_CLAUDE_RC DURING_COPY READY_FILE GO_FILE RUN_PLUGIN (default: the copy).
run_launcher() {
  local wd="$1"; shift
  ( cd "$wd" && env -i \
      PATH="$STUBS:$PATH" HOME="$HOME_DIR" HEIMDALL_HOME="$HOME_DIR/.heimdall" TERM=dumb \
      ANTHROPIC_API_KEY="sk-ant-skill-restore-probe" \
      HEIMDALL_NO_INTRO=1 HEIMDALL_NO_UPDATE_CHECK=1 HEIMDALL_NO_REUSE_METRIC=1 \
      HEIMDALL_DEFAULT_CP_URL="$HEIMDALL_DEFAULT_CP_URL" \
      STUB_CLAUDE_RC="${STUB_CLAUDE_RC:-0}" DURING_COPY="${DURING_COPY:-}" \
      READY_FILE="${READY_FILE:-}" GO_FILE="${GO_FILE:-}" ABORT_FILE="$TMP/abort" \
      HMD_STUB_LOG="${HMD_STUB_LOG:-/dev/null}" \
      perl -e 'alarm shift; exec @ARGV' "${RUN_ALARM:-90}" "${RUN_PLUGIN:-$FAKE}/bin/heimdall" "$@" \
      </dev/null >/dev/null 2>&1 )
}

# ══════════════════════════════════════════════════════════════════════════════
echo "1. restore-file: ONE path per owner, chosen by the caller -- never by the callee's own pid"
# ══════════════════════════════════════════════════════════════════════════════
A1="$(sm restore-file 4242)"; A2="$(sm restore-file 4242)"; B1="$(sm restore-file 4243)"
if [ -n "$A1" ] && [ "$A1" = "$A2" ]; then
  ok "restore-file 4242 called twice -> the same path"
else
  bad "restore-file 4242 gave [$A1] then [$A2] -- every call built the path from its own pid"
fi
if [ -n "$B1" ] && [ "$A1" != "$B1" ]; then ok "a different owner -> a different path"; else bad "owners 4242 and 4243 share [$A1]"; fi
case "$A1" in
  "$STATE_DIR"/4242.json) ok "the path is <HEIMDALL_HOME>/skill-restore/<owner>.json (private per-user dir, not /tmp)" ;;
  *) bad "restore-file 4242 -> [$A1], want $STATE_DIR/4242.json" ;;
esac

# With no argument the owner is the CALLING process: two plain children of one shell agree, and
# the path names that shell -- not either child. (The last statement is a builtin so neither call
# can be exec'd in place of the shell.)
cat > "$TMP/two-calls.sh" <<'EOF'
#!/bin/sh
"$1" restore-file > "$2"
"$1" restore-file > "$3"
echo $$ > "$4"
EOF
env -i PATH="$PATH" HOME="$HOME_DIR" sh "$TMP/two-calls.sh" "$FAKE/bin/skill-manager" "$TMP/o1" "$TMP/o2" "$TMP/o3"
if [ -s "$TMP/o1" ] && cmp -s "$TMP/o1" "$TMP/o2" && [ "$(cat "$TMP/o1")" = "$STATE_DIR/$(cat "$TMP/o3").json" ]; then
  ok "restore-file with no argument is keyed on the caller's pid: stable across calls"
else
  bad "no-arg restore-file: [$(cat "$TMP/o1" 2>/dev/null)] vs [$(cat "$TMP/o2" 2>/dev/null)], caller pid $(cat "$TMP/o3" 2>/dev/null)"
fi

for BADOWNER in abc 0 -5 "1;x" 12abc; do
  sm restore-file "$BADOWNER" >/dev/null 2>&1
  RC=$?
  if [ "$RC" -eq 2 ]; then
    ok "restore-file rejects the owner [$BADOWNER] (rc 2)"
  else
    bad "restore-file accepted the owner [$BADOWNER] (rc $RC; want 2)"
  fi
done

# ══════════════════════════════════════════════════════════════════════════════
echo "2. activate then restore round-trips the original skill set"
# ══════════════════════════════════════════════════════════════════════════════
reset_settings; clean_state
new_live_pid; K1=$LIVE
RF1="$(sm restore-file "$K1")"
ACT_OUT="$(sm activate "$PLAIN" "$RF1" 2>&1)"
[ "$(plugins)" = "demand@t=off extra@t=off fe@t=off perm@t=on rev@t=off" ] \
  && ok "activate paused the plugins the project does not need" \
  || bad "after activate: $(plugins)"
case "$ACT_OUT" in *"Skills:"*) ok "activate prints the Skills summary" ;; *) bad "no Skills summary: [$ACT_OUT]" ;; esac
[ -f "$RF1" ] \
  && ok "activate wrote the restore file at exactly the path restore-file named" \
  || bad "no restore file at [$RF1] -- activate and restore-file disagree (THE bug)"
sm restore "$RF1"; RC=$?
[ "$RC" -eq 0 ] && same_as_s0 \
  && ok "restore puts settings.json back BYTE for byte (rc 0)" \
  || bad "after restore rc=$RC plugins=[$(plugins)] (want $S0_PLUGINS)"
[ ! -e "$RF1" ] && ok "restore deletes the restore file it consumed" || bad "restore left $RF1 behind"
sm restore "$RF1"; RC=$?
[ "$RC" -eq 0 ] && same_as_s0 && ok "a second restore is a harmless no-op (rc 0)" || bad "second restore rc=$RC, plugins=[$(plugins)]"
sm restore "$STATE_DIR/987654.json"; RC=$?
[ "$RC" -eq 0 ] && same_as_s0 && ok "restore of a file that never existed is a no-op (rc 0)" || bad "restore of a missing file rc=$RC"

# A change made DURING the session survives the restore: only what this launch changed is undone.
reset_settings; clean_state
RF2="$(sm restore-file "$K1")"
sm activate "$PLAIN" "$RF2" >/dev/null 2>&1
python3 - "$SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["enabledPlugins"]["new@t"] = True        # a plugin installed mid-session
s["enabledPlugins"]["extra@t"] = True      # the user turned a paused plugin back on
s["model"] = "sonnet"                      # an unrelated setting changed
with open(p, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
PY
sm restore "$RF2" >/dev/null 2>&1
[ "$(plugins)" = "demand@t=on extra@t=on fe@t=off new@t=on perm@t=on rev@t=on" ] \
  && ok "restore undoes only this launch's changes: a mid-session install and toggle survive" \
  || bad "after a mid-session edit + restore: $(plugins)"
[ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['model'])" "$SETTINGS")" = "sonnet" ] \
  && ok "restore leaves unrelated settings alone" || bad "restore reverted an unrelated setting"

# ══════════════════════════════════════════════════════════════════════════════
echo "3. through the REAL launcher: the pause lasts exactly as long as the session"
# ══════════════════════════════════════════════════════════════════════════════
for SHAPE in "task prompt" interactive "--resume"; do
  reset_settings; clean_state; rm -f "$TMP/during.json"
  case "$SHAPE" in
    "task prompt") DURING_COPY="$TMP/during.json" run_launcher "$PLAIN" "fix the bug in x" ;;
    interactive)   DURING_COPY="$TMP/during.json" run_launcher "$PLAIN" ;;
    "--resume")    DURING_COPY="$TMP/during.json" run_launcher "$PLAIN" --resume ;;
  esac
  RC=$?
  if [ -f "$TMP/during.json" ] && [ "$(plugins_of "$TMP/during.json")" = "demand@t=off extra@t=off fe@t=off perm@t=on rev@t=off" ]; then
    ok "$SHAPE: claude starts with the unneeded plugins paused (the pause is real)"
  else
    bad "$SHAPE: claude saw [$(plugins_of "$TMP/during.json" 2>/dev/null)]"
  fi
  if [ "$RC" -eq 0 ] && same_as_s0; then
    ok "$SHAPE: after the launcher exits settings.json is back to the original, byte for byte"
  else
    bad "$SHAPE: rc=$RC, plugins afterwards [$(plugins)] (want $S0_PLUGINS) -- skills left un-restored"
  fi
  [ "$(state_count)" = "0" ] && ok "$SHAPE: no restore file left behind" || bad "$SHAPE: $(state_count) restore file(s) left in $STATE_DIR"
done

reset_settings; clean_state
STUB_CLAUDE_RC=3 run_launcher "$PLAIN" "fix the bug in x"; RC=$?
[ "$RC" -eq 3 ] && same_as_s0 \
  && ok "claude exits 3: the launcher still exits 3 AND restores the skills" \
  || bad "claude exits 3: launcher rc=$RC, plugins [$(plugins)]"

# The invariant itself, with a recording stub in place of skill-manager: the path the launcher
# got from restore-file is the one it hands to activate AND to restore -- and if there is no path,
# nothing is paused (an undo with nowhere to live would leave the skills paused for good).
FAKE2="$TMP/plugin2"; mkdir -p "$FAKE2/bin" "$FAKE2/.claude-plugin"
cp "$REPO/bin/heimdall" "$FAKE2/bin/heimdall"; chmod +x "$FAKE2/bin/heimdall"
make_sm_stub() {  # $1 = what `restore-file` does
  cat > "$FAKE2/bin/skill-manager" <<EOF
#!/bin/sh
printf 'ARGS: %s\n' "\$*" >> "\${HMD_STUB_LOG:-/dev/null}"
if [ "\$1" = restore-file ]; then $1; fi
exit 0
EOF
  chmod +x "$FAKE2/bin/skill-manager"
}
STUB_LOG="$TMP/stub.log"
make_sm_stub "echo '$TMP/the-one-path.json'"
: > "$STUB_LOG"
HMD_STUB_LOG="$STUB_LOG" RUN_PLUGIN="$FAKE2" run_launcher "$PLAIN" "fix the bug in x"
ACT_PATH="$(sed -n 's/^ARGS: activate .* \(\/[^ ]*\.json\)$/\1/p' "$STUB_LOG" | sed -n '1p')"
RES_PATH="$(sed -n 's/^ARGS: restore \(\/[^ ]*\.json\)$/\1/p' "$STUB_LOG" | sed -n '1p')"
if [ "$ACT_PATH" = "$TMP/the-one-path.json" ] && [ "$RES_PATH" = "$ACT_PATH" ]; then
  ok "the launcher hands the SAME path to activate and to restore"
else
  bad "activate got [$ACT_PATH], restore got [$RES_PATH] -- log: $(tr '\n' '|' < "$STUB_LOG")"
fi
if grep -qE '^ARGS: restore-file [1-9][0-9]*$' "$STUB_LOG"; then
  ok "the launcher keys the path on its own pid (restore-file <pid>)"
else
  bad "restore-file was not asked for a pid-keyed path -- log: $(tr '\n' '|' < "$STUB_LOG")"
fi
make_sm_stub "exit 1"
: > "$STUB_LOG"
HMD_STUB_LOG="$STUB_LOG" RUN_PLUGIN="$FAKE2" run_launcher "$PLAIN" "fix the bug in x"; RC=$?
if [ "$RC" -eq 0 ] && ! grep -q '^ARGS: activate' "$STUB_LOG" && ! grep -q '^ARGS: restore ' "$STUB_LOG"; then
  ok "no restore path -> nothing is paused and nothing is restored; the launch itself is unaffected"
else
  bad "restore-file failing: rc=$RC log: $(tr '\n' '|' < "$STUB_LOG")"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo "4. two concurrent launches never clobber each other's restore files"
# ══════════════════════════════════════════════════════════════════════════════
# Launch B starts while A is still running, so B's "current" settings are A's paused ones. The
# files must stay separate and, whichever launch leaves first, the last one out leaves the
# ORIGINAL set behind -- not the state the other one had paused.
for ORDER in "B A" "A B"; do
  reset_settings; clean_state
  new_live_pid; KA=$LIVE; new_live_pid; KB=$LIVE
  RFA="$(sm restore-file "$KA")"; RFB="$(sm restore-file "$KB")"
  sm activate "$PLAIN" "$RFA" >/dev/null 2>&1
  sm activate "$FRONT" "$RFB" >/dev/null 2>&1
  if [ "$RFA" != "$RFB" ] && [ -f "$RFA" ] && [ -f "$RFB" ] && ! cmp -s "$RFA" "$RFB"; then
    ok "[exit $ORDER] two live launches hold two distinct restore files"
  else
    bad "[exit $ORDER] restore files: A=[$RFA] B=[$RFB] ($(state_count) in $STATE_DIR)"
  fi
  [ "$(plugins)" = "demand@t=off extra@t=off fe@t=on perm@t=on rev@t=off" ] \
    && ok "[exit $ORDER] B's own project got its own plugin (fe@t on) over A's pause" \
    || bad "[exit $ORDER] while both run: $(plugins)"
  for W in $ORDER; do
    case "$W" in A) sm restore "$RFA" ;; B) sm restore "$RFB" ;; esac
  done
  same_as_s0 \
    && ok "[exit $ORDER] once both have left the original set is back, byte for byte" \
    || bad "[exit $ORDER] settings left as [$(plugins)] (want $S0_PLUGINS)"
  [ "$(state_count)" = "0" ] && ok "[exit $ORDER] both restore files consumed" || bad "[exit $ORDER] $(state_count) file(s) left"
done

# The same, through two REAL launchers held open inside claude at the same time. A leaves first:
# the order in which a wholesale "put back my snapshot" restore ends up re-pausing B's plugins.
reset_settings; clean_state; rm -f "$TMP"/ready-* "$TMP"/go-*
READY_FILE="$TMP/ready-a" GO_FILE="$TMP/go-a" run_launcher "$PLAIN" "fix the bug in x" &
PA=$!; BG_PIDS="$BG_PIDS $PA"
if wait_for "$TMP/ready-a" 60; then ok "launcher A is running inside claude"; else bad "launcher A never reached claude"; fi
READY_FILE="$TMP/ready-b" GO_FILE="$TMP/go-b" run_launcher "$FRONT" "fix the bug in y" &
PB=$!; BG_PIDS="$BG_PIDS $PB"
if wait_for "$TMP/ready-b" 60; then ok "launcher B is running inside claude, A still alive"; else bad "launcher B never reached claude"; fi
if [ "$(state_count)" = "2" ]; then
  ok "two live launchers -> two restore files"
else
  bad "expected 2 restore files while both launches run, found $(state_count) in $STATE_DIR"
fi
ALIVE_OWNERS=0
for F in "$STATE_DIR"/*.json; do
  [ -e "$F" ] || continue
  OWNER="$(basename "$F" .json)"
  case "$OWNER" in ''|*[!0-9]*) ;; *) kill -0 "$OWNER" 2>/dev/null && ALIVE_OWNERS=$((ALIVE_OWNERS + 1)) ;; esac
done
[ "$ALIVE_OWNERS" -eq 2 ] && ok "each file is named for a live launcher pid" || bad "$ALIVE_OWNERS of 2 restore files name a live process"
: > "$TMP/go-a"; wait "$PA"; RCA=$?
: > "$TMP/go-b"; wait "$PB"; RCB=$?
[ "$RCA" -eq 0 ] && [ "$RCB" -eq 0 ] && ok "both launchers exit 0" || bad "launcher exits: A=$RCA B=$RCB"
same_as_s0 \
  && ok "the first launch to leave does not leave the other's pause behind: original set restored" \
  || bad "after both launches ended: [$(plugins)] (want $S0_PLUGINS)"
[ "$(state_count)" = "0" ] && ok "no restore file left" || bad "$(state_count) restore file(s) left"

# ══════════════════════════════════════════════════════════════════════════════
echo "5. a launcher that died: its stale file is recovered by the next session"
# ══════════════════════════════════════════════════════════════════════════════
reset_settings; clean_state
dead_pid; KD=$DEAD
RFD="$(sm restore-file "$KD")"
sm activate "$PLAIN" "$RFD" >/dev/null 2>&1                 # ... and the launcher is killed here
if [ -f "$RFD" ] && [ "$(plugins)" = "demand@t=off extra@t=off fe@t=off perm@t=on rev@t=off" ]; then
  ok "precondition: the crashed launch left its skills paused and its restore file behind"
else
  bad "precondition failed: file=$([ -f "$RFD" ] && echo yes || echo no) plugins=[$(plugins)]"
fi
new_live_pid; KL=$LIVE; RFL="$(sm restore-file "$KL")"
sm activate "$FRONT" "$RFL" >/dev/null 2>&1                 # the NEXT session starts
[ ! -e "$RFD" ] && ok "the next activate consumed the dead launcher's restore file" || bad "stale file [$RFD] still there after a later activate"
sm restore "$RFL" >/dev/null 2>&1
same_as_s0 \
  && ok "the next session restores the ORIGINAL set, not the crashed launch's paused one" \
  || bad "after recovery + restore: [$(plugins)] (want $S0_PLUGINS)"

# Unreadable debris from a dead owner is dropped without hurting the activation; the same debris
# from a LIVE owner is left alone (it may be mid-flight, and it is not ours to judge).
reset_settings; clean_state
dead_pid; KD=$DEAD; new_live_pid; KG=$LIVE; new_live_pid; KL=$LIVE
mkdir -p "$STATE_DIR"
printf '{ not json' > "$STATE_DIR/$KD.json"
printf '{ not json' > "$STATE_DIR/$KG.json"
RFL="$(sm restore-file "$KL")"
sm activate "$PLAIN" "$RFL" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ "$(plugins)" = "demand@t=off extra@t=off fe@t=off perm@t=on rev@t=off" ] \
  && ok "an unreadable stale file does not break the activation (rc 0)" || bad "activate over debris: rc=$RC plugins=[$(plugins)]"
[ ! -e "$STATE_DIR/$KD.json" ] && ok "...and the dead owner's debris is removed" || bad "dead owner's unreadable file survived"
[ -e "$STATE_DIR/$KG.json" ] && ok "...while a live owner's file is never swept" || bad "a LIVE owner's restore file was swept"
sm restore "$RFL" >/dev/null 2>&1
same_as_s0 && ok "...and restore still round-trips" || bad "debris case: after restore [$(plugins)]"

# The sweep is bounded: one activation recovers at most 64 stale files; the next takes the rest.
reset_settings; clean_state
mkdir -p "$STATE_DIR"
I=1
while [ "$I" -le 70 ]; do printf '{"t": 1.0, "changes": {}}' > "$STATE_DIR/$((2000000000 + I)).json"; I=$((I + 1)); done
new_live_pid; KL=$LIVE; RFL="$(sm restore-file "$KL")"
sm activate "$PLAIN" "$RFL" >/dev/null 2>&1
LEFT="$(stale_left)"
[ "$LEFT" = "6" ] && ok "one activation sweeps at most 64 stale files (70 -> 6 left)" || bad "$LEFT stale files left after one activation (want 6)"
sm activate "$PLAIN" "$RFL" >/dev/null 2>&1
LEFT="$(stale_left)"
[ "$LEFT" = "0" ] && ok "...and the next activation finishes the job" || bad "$LEFT stale files left after the second activation"
sm restore "$RFL" >/dev/null 2>&1
same_as_s0 && ok "...with the skill set intact throughout" || bad "bounded-sweep case: after restore [$(plugins)]"

# ══════════════════════════════════════════════════════════════════════════════
echo "6. activate with nothing to activate stays quiet and leaves nothing behind"
# ══════════════════════════════════════════════════════════════════════════════
EMPTY_HOME="$TMP/home-empty"; mkdir -p "$EMPTY_HOME"
NOSET_OUT="$(env -i PATH="$PATH" HOME="$EMPTY_HOME" "$FAKE/bin/skill-manager" activate "$PLAIN" "$EMPTY_HOME/rf.json" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$NOSET_OUT" ] && [ ! -e "$EMPTY_HOME/rf.json" ]; then
  ok "no settings.json: activate exits 0, prints nothing, writes nothing"
else
  bad "no settings.json: rc=$RC out=[$NOSET_OUT]"
fi
env -i PATH="$PATH" HOME="$EMPTY_HOME" "$FAKE/bin/skill-manager" restore "$EMPTY_HOME/rf.json"; RC=$?
[ "$RC" -eq 0 ] && ok "no settings.json: restore exits 0" || bad "no settings.json: restore rc=$RC"

# ══════════════════════════════════════════════════════════════════════════════
echo "7. syntax"
# ══════════════════════════════════════════════════════════════════════════════
for f in "$REPO/bin/skill-manager" "$REPO/bin/heimdall"; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f") failed"; fi
done
if python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$REPO/bin/lib/skill_restore.py" 2>/dev/null; then
  ok "bin/lib/skill_restore.py parses"
else
  bad "bin/lib/skill_restore.py is missing or does not parse"
fi

echo ""
echo "skill-manager-restore: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
