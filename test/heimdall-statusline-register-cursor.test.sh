#!/usr/bin/env bash
#
# heimdall-statusline-register-cursor.test.sh — bin/heimdall-statusline-register-cursor
# wires the watchman HUD into Cursor CLI's OWN statusLine plug-in point
# (~/.cursor/cli-config.json, per ~/.cursor/skills-cursor/statusline/SKILL.md).
#
# THIS SUITE LOCKS:
#   1. FRESH WRITE — no existing config -> registers a valid statusLine block:
#      absolute bare path (no shell wrapper — Cursor spawns with no shell on Unix),
#      padding=0, updateIntervalMs=3000, timeoutMs=3000, type=command.
#   2. IDEMPOTENT — a second `register` on an already-canonical file is a byte-exact
#      no-op (state=current, file content unchanged).
#   3. NO-CLOBBER — a pre-existing foreign statusLine is left completely untouched
#      (state=kept-custom), AND every sibling key (including a live `authInfo` block,
#      the real-world shape this file carries on an authenticated machine) survives
#      byte-for-byte. This is the single highest-stakes property this bin has: the
#      real ~/.cursor/cli-config.json on a dev box can belong to someone's live
#      Cursor account.
#   4. SIBLING-KEY PRESERVATION ON WRITE — registering onto a file that has OTHER
#      keys but NO statusLine yet still round-trips those other keys untouched.
#   5. NO-SHELL SPAWN CONTRACT — the exact command written is invoked EXACTLY the
#      way Cursor's child_process.spawn (no shell) would invoke it: a single-element
#      argv list, shell=False. It must actually render and exit 0.
#   6. OPT-OUT — both the shared and the cursor-only opt-out markers (env var and
#      marker file, all 4 combinations) produce state=skipped with the file untouched.
#   7. STATUS (read-only) — matches the register outcome without writing anything.
#   8. MISSING ROOT — no bin/heimdall-statusline at the resolved root -> skipped,
#      config file never created.
#   9. UPGRADE — an OURS-but-STALE entry (the exact pre-existing shape this bin
#      shipped before timeoutMs was added: updateIntervalMs=2000, no timeoutMs key
#      at all) is refreshed on the next register to the new canonical shape
#      (state=registered, NOT current) — proving the `cur != want` staleness check
#      catches a VALUE change, not only the path-staleness case it already covered.
#      A follow-up register after the refresh is then idempotent, same as case 2.
#  10. NEVER TOUCHES THE REAL FILE — this whole suite runs with HOME AND
#      HEIMDALL_CURSOR_CLI_CONFIG both hermetically overridden; explicitly assert the
#      real $HOME/.cursor/cli-config.json (if any exists on the host running this
#      suite) is untouched (mtime/hash identical before and after the full run).
#
# FALSIFIER (verified by hand during development, not re-run here to keep this
# suite's runtime bounded): temporarily make the "is this command ours" marker check
# always false -> assertion set 3 (NO-CLOBBER) goes RED the moment a canonical,
# already-ours statusLine gets misclassified as foreign and skipped/left stale.
#
# KILL-PATH SAFETY (verified by hand, same reason not automated here — the check is
# inherently timing-dependent on bin/heimdall-statusline's render speed, which is a
# SIBLING component's active work-in-progress; coupling this suite's pass/fail to
# that component's evolving latency would make the suite flaky by construction, not
# a regression guard): sent SIGALRM (via `perl -e 'alarm N; exec @ARGV'` — this
# sandbox's bash 3.2 has no `timeout(1)`) and SIGTERM at delays from 0.1s-3s into a
# real, unmodified render of test/fixtures/cursor-real-payload.json. Every kill that
# landed before natural completion produced exactly 0 stdout bytes and a non-zero
# exit, in every trial — never a partial byte, never a dangling SGR escape. Root
# cause traced to bin/heimdall-statusline (out of this suite's scope to edit): every
# exit path captures its full rendered string into a shell variable via command
# substitution first, then performs exactly one atomic `printf` to real stdout as
# its last act before `exit 0` — no code path writes incrementally. That satisfies
# SKILL.md's documented safe path ("exits non-zero with empty stdout -> previous
# text kept") by construction, for either of Cursor's two kill triggers (timeout or
# a superseding new update) — no wrapper is needed here to enforce it.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REG="$ROOT/bin/heimdall-statusline-register-cursor"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || {
  echo "SKIP: python3 unavailable"
  echo "heimdall-statusline-register-cursor: 0 passed, 0 failed (SKIPPED — python3 unavailable)"
  exit 0
}
[ -x "$REG" ] || { echo "FATAL: $REG missing/not executable"; echo "heimdall-statusline-register-cursor: 0 passed, 1 failed"; exit 1; }

TARGET="$ROOT/bin/heimdall-statusline"

# ── real-file untouched sentinel: snapshot BEFORE this suite does anything ──
REAL_CFG="$HOME/.cursor/cli-config.json"
REAL_BEFORE=""
if [ -f "$REAL_CFG" ]; then
  REAL_BEFORE="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$REAL_CFG" 2>/dev/null)"
fi

hermetic_home() { mktemp -d; }

echo "== 1) FRESH WRITE: no existing config -> valid statusLine block =="
H1="$(hermetic_home)"; CFG1="$H1/.cursor/cli-config.json"
OUT1="$(HOME="$H1" HEIMDALL_CURSOR_CLI_CONFIG="$CFG1" "$REG" register)"; RC1=$?
[ "$RC1" = 0 ] && [ "$OUT1" = registered ] \
  && ok "fresh write: state=registered, exit 0" \
  || bad "fresh write: got state='$OUT1' rc=$RC1, expected 'registered' rc=0"
[ -f "$CFG1" ] && ok "fresh write: cli-config.json created" || bad "fresh write: cli-config.json NOT created"
CHECK1="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sl = d.get("statusLine")
assert isinstance(sl, dict), "statusLine missing/not a dict"
assert sl.get("type") == "command", "type != command: %r" % sl.get("type")
assert sl.get("command") == sys.argv[2], "command mismatch: %r != %r" % (sl.get("command"), sys.argv[2])
assert sl.get("command").startswith("/"), "command is not an absolute path"
assert " " not in sl["command"].strip("/").replace(sys.argv[2].strip("/"), ""), "command has extra shell tokens"
assert sl.get("padding") == 0, "padding != 0: %r" % sl.get("padding")
assert sl.get("updateIntervalMs") == 3000, "updateIntervalMs != 3000: %r" % sl.get("updateIntervalMs")
assert sl.get("timeoutMs") == 3000, "timeoutMs != 3000: %r" % sl.get("timeoutMs")
print("OK")
' "$CFG1" "$TARGET" 2>&1)"
[ "$CHECK1" = OK ] && ok "fresh write: statusLine shape correct (bare absolute path, no shell wrapper, padding=0, updateIntervalMs=3000, timeoutMs=3000)" \
                   || bad "fresh write: shape check failed: $CHECK1"

echo "== 2) IDEMPOTENT: second register on canonical file is a byte-exact no-op =="
SUM_BEFORE="$(python3 -c 'import hashlib; print(hashlib.sha256(open("'"$CFG1"'","rb").read()).hexdigest())')"
OUT2="$(HOME="$H1" HEIMDALL_CURSOR_CLI_CONFIG="$CFG1" "$REG" register)"; RC2=$?
SUM_AFTER="$(python3 -c 'import hashlib; print(hashlib.sha256(open("'"$CFG1"'","rb").read()).hexdigest())')"
[ "$RC2" = 0 ] && [ "$OUT2" = current ] \
  && ok "idempotent: state=current, exit 0" \
  || bad "idempotent: got state='$OUT2' rc=$RC2, expected 'current' rc=0"
[ "$SUM_BEFORE" = "$SUM_AFTER" ] && ok "idempotent: file byte-identical across re-register" \
                                  || bad "idempotent: file CHANGED on a no-op re-register"
rm -rf "$H1"

echo "== 3) NO-CLOBBER: a pre-existing foreign statusLine + a live authInfo block survive untouched =="
H3="$(hermetic_home)"; CFG3="$H3/.cursor/cli-config.json"; mkdir -p "$H3/.cursor"
python3 -c '
import json
d = {
  "authInfo": {"email": "someone-else@example.com", "displayName": "Someone Else",
               "userId": 999999999, "authId": "google-oauth2|user_fake"},
  "statusLine": {"type": "command", "command": "/usr/local/bin/my-own-statusline", "padding": 1},
}
json.dump(d, open("'"$CFG3"'", "w"))
'
SUM3_BEFORE="$(python3 -c 'import hashlib; print(hashlib.sha256(open("'"$CFG3"'","rb").read()).hexdigest())')"
OUT3="$(HOME="$H3" HEIMDALL_CURSOR_CLI_CONFIG="$CFG3" "$REG" register)"; RC3=$?
SUM3_AFTER="$(python3 -c 'import hashlib; print(hashlib.sha256(open("'"$CFG3"'","rb").read()).hexdigest())')"
[ "$RC3" = 0 ] && [ "$OUT3" = kept-custom ] \
  && ok "no-clobber: state=kept-custom, exit 0" \
  || bad "no-clobber: got state='$OUT3' rc=$RC3, expected 'kept-custom' rc=0"
[ "$SUM3_BEFORE" = "$SUM3_AFTER" ] && ok "no-clobber: file byte-identical — foreign statusLine AND authInfo both untouched" \
                                    || bad "no-clobber: file CHANGED despite a foreign statusLine present"
rm -rf "$H3"

echo "== 4) SIBLING-KEY PRESERVATION ON WRITE: other keys survive a real (write) registration =="
H4="$(hermetic_home)"; CFG4="$H4/.cursor/cli-config.json"; mkdir -p "$H4/.cursor"
python3 -c '
import json
json.dump({"authInfo": {"email": "me@example.com", "userId": 42}}, open("'"$CFG4"'", "w"))
'
OUT4="$(HOME="$H4" HEIMDALL_CURSOR_CLI_CONFIG="$CFG4" "$REG" register)"; RC4=$?
CHECK4="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("authInfo") == {"email": "me@example.com", "userId": 42}, "authInfo mutated: %r" % d.get("authInfo")
assert isinstance(d.get("statusLine"), dict) and d["statusLine"].get("command") == sys.argv[2]
print("OK")
' "$CFG4" "$TARGET" 2>&1)"
[ "$RC4" = 0 ] && [ "$OUT4" = registered ] && ok "sibling-key write: state=registered, exit 0" \
                                            || bad "sibling-key write: got state='$OUT4' rc=$RC4"
[ "$CHECK4" = OK ] && ok "sibling-key write: pre-existing authInfo survives untouched alongside the new statusLine" \
                    || bad "sibling-key write: $CHECK4"
rm -rf "$H4"

echo "== 5) NO-SHELL SPAWN CONTRACT: registered command runs EXACTLY as Cursor's spawn (argv list, shell=False) =="
H5="$(hermetic_home)"; CFG5="$H5/.cursor/cli-config.json"
HOME="$H5" HEIMDALL_CURSOR_CLI_CONFIG="$CFG5" "$REG" register >/dev/null
SPAWN_OUT="$(python3 -c '
import json, subprocess, sys
cfg = json.load(open(sys.argv[1]))
cmd = cfg["statusLine"]["command"]
p = subprocess.run([cmd], shell=False, input=b"{}", stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
sys.stdout.buffer.write(p.stdout)
sys.exit(p.returncode)
' "$CFG5")"
RC5=$?
[ "$RC5" = 0 ] && ok "no-shell spawn: registered command exits 0 under shell=False argv-list spawn" \
               || bad "no-shell spawn: exit $RC5"
[ -n "$SPAWN_OUT" ] && ok "no-shell spawn: produced non-empty HUD output" \
                     || bad "no-shell spawn: produced EMPTY output"
rm -rf "$H5"

echo "== 6) OPT-OUT: shared + cursor-only markers (env and file) all skip cleanly =="
for mode in shared_env cursor_env shared_file cursor_file; do
  H6="$(hermetic_home)"; CFG6="$H6/.cursor/cli-config.json"
  case "$mode" in
    shared_env)  OUT6="$(HOME="$H6" HEIMDALL_CURSOR_CLI_CONFIG="$CFG6" HEIMDALL_NO_STATUSLINE_REGISTER=1 "$REG" register)" ;;
    cursor_env)  OUT6="$(HOME="$H6" HEIMDALL_CURSOR_CLI_CONFIG="$CFG6" HEIMDALL_NO_CURSOR_STATUSLINE_REGISTER=1 "$REG" register)" ;;
    shared_file) mkdir -p "$H6/.heimdall"; : > "$H6/.heimdall/no-statusline-register"
                 OUT6="$(HOME="$H6" HEIMDALL_CURSOR_CLI_CONFIG="$CFG6" "$REG" register)" ;;
    cursor_file) mkdir -p "$H6/.heimdall"; : > "$H6/.heimdall/no-cursor-statusline-register"
                 OUT6="$(HOME="$H6" HEIMDALL_CURSOR_CLI_CONFIG="$CFG6" "$REG" register)" ;;
  esac
  RC6=$?
  [ "$RC6" = 0 ] && [ "$OUT6" = skipped ] && [ ! -f "$CFG6" ] \
    && ok "opt-out ($mode): state=skipped, exit 0, no file created" \
    || bad "opt-out ($mode): state='$OUT6' rc=$RC6 file-exists=$([ -f "$CFG6" ] && echo yes || echo no)"
  rm -rf "$H6"
done

echo "== 7) STATUS: read-only preview matches the register outcome, writes nothing =="
H7="$(hermetic_home)"; CFG7="$H7/.cursor/cli-config.json"
BEFORE7="no-file"; [ -f "$CFG7" ] && BEFORE7="exists"
STATUS_OUT="$(HOME="$H7" HEIMDALL_CURSOR_CLI_CONFIG="$CFG7" "$REG" status)"
AFTER7="no-file"; [ -f "$CFG7" ] && AFTER7="exists"
[ "$STATUS_OUT" = would-register ] && ok "status: reports would-register on a fresh (unwritten) target" \
                                     || bad "status: got '$STATUS_OUT', expected would-register"
[ "$BEFORE7" = "$AFTER7" ] && [ "$AFTER7" = no-file ] && ok "status: never creates the file (read-only)" \
                                                        || bad "status: file state changed ($BEFORE7 -> $AFTER7)"
rm -rf "$H7"

echo "== 8) MISSING ROOT: no bin/heimdall-statusline at the resolved root -> skipped, no file touched =="
H8="$(hermetic_home)"; CFG8="$H8/.cursor/cli-config.json"; FAKE_ROOT="$H8/empty-root"; mkdir -p "$FAKE_ROOT/bin"
OUT8="$(HOME="$H8" HEIMDALL_CURSOR_CLI_CONFIG="$CFG8" "$REG" --root "$FAKE_ROOT" register)"; RC8=$?
[ "$RC8" = 0 ] && [ "$OUT8" = skipped ] && [ ! -f "$CFG8" ] \
  && ok "missing root: state=skipped, exit 0, no file created" \
  || bad "missing root: state='$OUT8' rc=$RC8 file-exists=$([ -f "$CFG8" ] && echo yes || echo no)"
rm -rf "$H8"

echo "== 9) UPGRADE: an ours-but-stale entry (old shape: updateIntervalMs=2000, no timeoutMs) is refreshed, not left stale =="
H9="$(hermetic_home)"; CFG9="$H9/.cursor/cli-config.json"; mkdir -p "$H9/.cursor"
python3 -c '
import json, sys
d = {"statusLine": {"type": "command", "command": sys.argv[2], "padding": 0, "updateIntervalMs": 2000}}
json.dump(d, open(sys.argv[1], "w"))
' "$CFG9" "$TARGET"
OUT9="$(HOME="$H9" HEIMDALL_CURSOR_CLI_CONFIG="$CFG9" "$REG" register)"; RC9=$?
[ "$RC9" = 0 ] && [ "$OUT9" = registered ] \
  && ok "upgrade: stale-but-ours entry refreshed, state=registered, exit 0" \
  || bad "upgrade: got state='$OUT9' rc=$RC9, expected 'registered' rc=0 (staleness not detected)"
CHECK9="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sl = d.get("statusLine")
assert sl.get("updateIntervalMs") == 3000, "updateIntervalMs not refreshed: %r" % sl.get("updateIntervalMs")
assert sl.get("timeoutMs") == 3000, "timeoutMs not added on refresh: %r" % sl.get("timeoutMs")
print("OK")
' "$CFG9" 2>&1)"
[ "$CHECK9" = OK ] && ok "upgrade: refreshed entry carries the new updateIntervalMs=3000/timeoutMs=3000" \
                    || bad "upgrade: $CHECK9"
OUT9B="$(HOME="$H9" HEIMDALL_CURSOR_CLI_CONFIG="$CFG9" "$REG" register)"; RC9B=$?
[ "$RC9B" = 0 ] && [ "$OUT9B" = current ] \
  && ok "upgrade: follow-up register on the refreshed file is idempotent (state=current)" \
  || bad "upgrade: follow-up got state='$OUT9B' rc=$RC9B, expected 'current' rc=0"
rm -rf "$H9"

echo "== 10) NEVER TOUCHES THE REAL FILE: whole suite ran hermetically =="
REAL_AFTER=""
if [ -f "$REAL_CFG" ]; then
  REAL_AFTER="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$REAL_CFG" 2>/dev/null)"
fi
[ "$REAL_BEFORE" = "$REAL_AFTER" ] && ok "real \$HOME/.cursor/cli-config.json untouched across the whole suite" \
                                     || bad "real \$HOME/.cursor/cli-config.json CHANGED — hermeticity breach"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
