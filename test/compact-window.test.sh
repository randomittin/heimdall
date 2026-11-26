#!/usr/bin/env bash
# test/compact-window.test.sh -- `hmd compact-window on|off|status|offer`: the native auto-compact window (the biggest measured token lever on a long
# session, docs/analysis/2026-11-22-token-utilization-next.md lever 1) reaches a user's ~/.claude/settings.json only with their yes, and `off` undoes it exactly.
#
#   bash test/compact-window.test.sh
#
# THE CONTRACT UNDER TEST (bin/heimdall-compact-window, the dispatcher arm, install.sh and hmd --update)
#   A  on/off round trip on three file layouts: the key is added in the file's own layout, every other byte survives (a number spelled 1.50 stays 1.50, a 20-digit
#      integer stays one), and `off` returns the file byte for byte, with the record and the backup gone
#   B  the file was rewritten by something else between on and off: only the key is reverted, the rest is kept
#   C  no settings file: on creates it, off removes it again
#   D  the existing-value guard: a different value of the person's own is never replaced (exit 4, file untouched) unless --force, and off puts it back
#   E  a value that is already the wanted one is left alone, and off never removes a setting hmd did not write
#   F  consent: no terminal and no --yes is exit 3 with nothing written; --yes writes; a person at a terminal (a pty, no seam) says yes or no
#   G  --tokens: 250k, a minimum of 100000, an update of hmd's own value in place that still undoes to the very first state
#   H  a settings file that is not a JSON object, or names the key twice, is never touched
#   I  a symlinked settings.json keeps its link; the file it points to is the one edited
#   J  offer: asked once at a terminal, never off one (no output, no write), never when the key is there, silenced by HEIMDALL_NO_COMPACT_WINDOW_OFFER
#   K  status; -h; no verb is a usage error
#   L  wiring: the install.sh step writes nothing without a terminal; the dispatcher reaches the tool; help, runhmd's subcommand list, `hmd --update` and the README name it
#   M  a second settings file (CLAUDE_CONFIG_DIR changed): `on` there never overwrites the first file's record and backup, each file is undone on its own, `off` and
#      `status` act on the current file and name the others hmd set; the record is keyed by the canonical path (a symlinked config directory is the same file)
#   N  the file changed while hmd was working (another writer saves it after hmd read it, even after hmd's own last look): exit 1, nothing of hmd's written over the
#      change, no record, backup or temp file left behind, and a retry works; the same while the person is at the prompt (the file hmd created is not removed)
#   O  a record that cannot be read or used (permissions, not JSON, a field missing, another file's record): exit 1, said plainly, nothing changed, the record undamaged
#   P  an offer nobody answers gives up after the wait (HEIMDALL_COMPACT_WINDOW_OFFER_WAIT_S shortens it, junk is ignored), writes nothing and is not recorded as answered
#   Q  an install from 2.4.12, which kept ONE record and ONE backup for the whole machine (state.json, settings.json.bak), written here by the real 2.4.12 tool read from git
#      (tag v2.4.12): whichever verb comes first after the update (off, status, on --tokens) finds it and works as it did (off byte for byte, "set by hmd", an update without
#      --force); the pair goes to the names of the settings file the record names (a symlinked spelling of this file's path included) and is never adopted for another one; a
#      record that cannot be read or used is exit 1 with nothing moved; a record already in place for that file is never replaced; the move is idempotent and an interrupted
#      one is finished by the next run
#   R  the Bash output cap, a second lever with the window's guarantees on a record and a backup of its own (`on --bash-cap [CHARS]`, key bashOutputMaxChars, 16000 by default, clamped by the
#      agent to 4000-128000; named from Claude Code 2.1.331 and its documentation, where the key, not the variable BASH_MAX_OUTPUT_LENGTH, limits the output Claude receives inline): a round
#      trip on three layouts, the text-exact append, values and their range, a value of the person's own (exit 4, --force, already the wanted one), consent (exit 3 and the command to run
#      again, a person at a terminal), both levers in one file turned off in either order and after the first was updated (the other's key survives every off), the file hmd created for
#      either lever removed by whichever off comes last, in every order of setting and of undoing, and never a file the person made or touched (the record of the lever set second carries who
#      made the file; a file that was there is restored byte for byte), a BASH_MAX_OUTPUT_LENGTH of
#      the person's own (env block, environment: exit 4; empty is unset; the window is never held back), status rows and the other-settings-file listing kept apart per lever, the write
#      race, a record that cannot be used, --help
#
#   S  the compact-now trigger, a transient third lever (`on --compact-now`: env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE = "1", so Claude Code compacts on its next request and /hmd:save can arm it instead of asking the person to
#      paste /compact; the evidence is docs/analysis/2026-11-26-save-auto-compact.md), armed in the PROJECT's .claude/settings.local.json and never in the user-level settings.json, which every session on the machine reads (S0: the
#      user-level file is untouched by arming and by release): the project is CLAUDE_PROJECT_DIR, else the git toplevel of the cwd (a subdirectory too); refused with exit 5 and nothing written for a file git tracks, a symlinked
#      .claude or settings.local.json, a directory or a hard-linked file in its place, and no project; armed inside an existing env object, a new one, an empty one and a new file (the .claude directory hmd made goes with it),
#      text-exact, and put back byte for byte (key-only after another tool rewrote the file); a value of the person's own (the env block of the project's local file, of its shared settings.json or of the user-level one, or the
#      environment) is never replaced and --force is a usage error; refused with exit 5 and nothing written for a Claude Code older than 2.1.329 or whose version is unknown (the session's own binary, CLAUDE_CODE_EXECPATH, by
#      its name or by asking it) and when automatic compaction is off (the most specific of the local, shared and user-level files that names autoCompactEnabled decides); the person's yes is asked once PER REPOSITORY (exit 3 and
#      the command, a person at a terminal, remembered after a yes for that project only, forgotten by `revoke` run inside it, never recorded for an arm that was refused); `release` (what the hooks run) is quiet, puts it back in
#      every project it was armed in, from any directory, and leaves a value the person changed; the expiry timer puts it back when nothing else did, and status says EXPIRED for an arming whose time is up; re-arming; the window
#      in the user-level file and the trigger in the project's, each undone on its own; the real SessionStart (every source) and PreCompact hook commands from hooks.json release it and honour the operator's switch
#   S11 the expiry check, for the day the timer died and no session starts (`release-expired`, what the compact-now-expiry-prompt hook on UserPromptSubmit and the compact-now-expiry-stop hook on Stop run): an arming whose time is over is put back,
#      from a directory in no project too, and only that one (the time is judged per arming, and arming again gives a new one); one still inside its time is kept; a record with no usable expiry counts as over; a value the person changed meanwhile
#      is left; a record that is not JSON is skipped and one that cannot be used costs ONE line on stderr; nothing is printed on stdout and the exit status is 0 whatever the state; the real hook commands from hooks.json do the same, each honours
#      the operator's switch on its own id, and a hook that cannot find the tool says one line on stderr
#
# HERMETIC. HOME, HEIMDALL_HOME and the settings file are throwaway for every scenario; CLAUDE_CONFIG_DIR is unset; nothing reads or writes the operator's ~/.claude
# or ~/.heimdall. CW_BIN=<file> points the suite at another copy of the tool (a mutant, for the break-it check).
# budget: about 60 s solo: roughly 630 starts of one python script (30 of them in Q, which runs the real 2.4.12 tool read from git; 140 in R, the Bash cap; about 260 in S, the trigger and its expiry check, an arming also asking git twice), about twenty-two on a pty, one on a pty that waits out the 1 s seam, one wait of about 1 s for the expiry timer. No network.
# EXIT: 0 = every assertion passes; 1 = any FAIL.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CW="${CW_BIN:-$REPO/bin/heimdall-compact-window}"
PY="$(command -v python3)"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi; }
chk() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "rc=$RC out=$(head -c 300 "$OUT" 2>/dev/null | tr '\n' '|') err=$(head -c 400 "$ERR" 2>/dev/null | tr '\n' '|')"; fi; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3] (out=$(head -c 200 "$OUT" 2>/dev/null | tr '\n' '|') err=$(head -c 300 "$ERR" 2>/dev/null | tr '\n' '|'))"; fi; }

echo "compact-window"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/compact-window.XXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd -P)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1   # every scenario runs from here, outside any git work tree: a command that names no project has none (the trigger's project is a scratch repository the scenario makes)
OUT="$TMP/out"; ERR="$TMP/err"; : >"$OUT"; : >"$ERR"
[ -x "$CW" ] || { bad "the tool is executable: $CW"; exit 1; }

cat >"$TMP/chk.py" <<'PYEOF'
import json, os, sys
KEYS = os.environ.get("CHK_KEY", "autoCompactWindow").split(",")   # the lever(s) under test, comma separated; the value command reads the first
KEY, VALUE = KEYS[0], os.environ.get("CHK_VALUE", "300000")
def pairs(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh, object_pairs_hook=list)
cmd, args = sys.argv[1], sys.argv[2:]
if cmd == "value":      # the key's value as JSON, or ABSENT
    found = [json.dumps(v) for k, v in pairs(args[0]) if k == KEY]
    print(found[0] if found else "ABSENT")
elif cmd == "others":   # every other member, in order, at every level, is the same in both files
    sys.exit(0 if [p for p in pairs(args[0]) if p[0] not in KEYS] == [p for p in pairs(args[1]) if p[0] not in KEYS] else 1)
elif cmd == "added":    # the pretty fixture plus the key, as text: one member appended before the closing brace, nothing else moved
    old, new = open(args[0], encoding="utf-8").read(), open(args[1], encoding="utf-8").read()
    sys.exit(0 if new == old[:-len("\n}\n")] + ',\n  "' + KEY + '": ' + VALUE + "\n}\n" else 1)
elif cmd == "armed":    # the pretty fixture plus the trigger: one member appended inside its existing env object, nothing else moved
    old, new = open(args[0], encoding="utf-8").read(), open(args[1], encoding="utf-8").read()
    sys.exit(0 if new != old and new == old.replace('back"\n  },', 'back",\n    "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "1"\n  },') else 1)
elif cmd == "reserialize":   # what another tool does to the file: re-serialize it and add a member of its own
    doc = json.load(open(args[0], encoding="utf-8"))
    doc["addedLater"] = {"by": "someone else"}
    open(args[0], "w", encoding="utf-8").write(json.dumps(doc, indent=4) + "\n")
PYEOF

cat >"$TMP/pty_drive.py" <<'PYEOF'
import os, pty, select, signal, sys, time
answer, cmd = sys.argv[1], sys.argv[sys.argv.index("--") + 1:]
pid, fd = pty.fork()
if pid == 0:
    try:
        os.execv(cmd[0], cmd)
    finally:
        os._exit(127)
screen, sent, deadline = bytearray(), answer == "-", time.time() + 30
while time.time() < deadline:
    if select.select([fd], [], [], 0.2)[0]:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            chunk = b""
        if not chunk:
            break
        screen += chunk
        if not sent and b"[y/N]" in screen:
            os.write(fd, answer.encode() + b"\n")
            sent = True
else:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    sys.stdout.buffer.write(bytes(screen))
    sys.exit(124)
status = os.waitpid(pid, 0)[1]
sys.stdout.buffer.write(bytes(screen))
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
PYEOF
cat >"$TMP/drive.py" <<'PYEOF'
import importlib.machinery, importlib.util, os, sys, tempfile
# drive.py wait <tool>                                              the seconds an unanswered offer waits, in this environment
# drive.py race <tool> <settings> <point> <kind> -- <args...>       the tool run in this process; at <point> another writer saves the settings file as <kind>
#   point  write   the new file is being written: after the tool's first look at the settings file, before its rename (what a check made earlier cannot see)
#          prompt  the person is deciding (the end of the consent step)
#   kind   inplace the same file, one more newline at the end    swap  a new file (temp + rename) with that newline    twin  a new file with the very same bytes
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("compact_window_under_test", sys.argv[2])
module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(module)
if sys.argv[1] == "wait":
    print("%g" % module.offer_wait())
    sys.exit(0)
settings, point, kind = sys.argv[3:6]
args = sys.argv[sys.argv.index("--") + 1:]
fired = []

def other_writer():
    if fired:
        return
    fired.append(kind)
    with open(settings, "rb") as handle:
        raw = handle.read()
    data = raw if kind == "twin" else raw + b"\n"
    if kind == "inplace":
        with open(settings, "wb") as handle:
            handle.write(data)
    else:
        with open(settings + ".other", "wb") as handle:
            handle.write(data)
        os.replace(settings + ".other", settings)

if point == "write":
    real_mkstemp = tempfile.mkstemp
    def mkstemp(*a, **k):
        made = real_mkstemp(*a, **k)
        if os.path.realpath(k.get("dir", "")) == os.path.dirname(os.path.realpath(settings)):
            other_writer()
        return made
    tempfile.mkstemp = mkstemp
else:
    real_consent = module.consent
    def consent(*a, **k):
        answer = real_consent(*a, **k)
        other_writer()
        return answer
    module.consent = consent
sys.exit(module.main(["heimdall-compact-window"] + args))
PYEOF
"$PY" -I -c 'import pty; pty.openpty()' >/dev/null 2>&1 || { echo "no pseudo-terminal can be opened here: the terminal cases cannot run"; exit 1; }

H=""; S=""; N=0
new_home() { N=$((N + 1)); H="$TMP/h$N"; mkdir -p "$H/.claude" "$H/.heimdall"; S="$H/.claude/settings.json"; }
scrub() { env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u BASH_MAX_OUTPUT_LENGTH -u HEIMDALL_NO_COMPACT_WINDOW_OFFER -u CLAUDE_AUTOCOMPACT_PCT_OVERRIDE -u DISABLE_AUTO_COMPACT -u DISABLE_COMPACT -u CLAUDE_CODE_EXECPATH -u CLAUDE_CODE_SESSION_ID -u HEIMDALL_COMPACT_NOW_CC_VERSION -u HEIMDALL_COMPACT_NOW_TTL_S -u HEIMDALL_COMPACT_NOW_NO_TIMER -u CLAUDE_PROJECT_DIR HOME="$H" HEIMDALL_HOME="$H/.heimdall" "$@"; }
cw()    { scrub "$CW" "$@" </dev/null >"$OUT" 2>"$ERR"; RC=$?; }                                 # no terminal
cwpty() { local a="$1"; shift; scrub "$PY" -I "$TMP/pty_drive.py" "$a" -- "$CW" "$@" >"$OUT" 2>"$ERR"; RC=$?; }   # a person at a terminal who types $a
value() { "$PY" -I "$TMP/chk.py" value "$S"; }
state() { find "$H/.heimdall/compact-window" -type f \( -name '*state.json' -o -name '*settings.json.bak' \) 2>/dev/null | wc -l | tr -d ' '; }   # records and backups kept
rec()   { find "$H/.heimdall/compact-window" -type f -name '*state.json' 2>/dev/null | head -n 1; }                                   # the first record
bak()   { find "$H/.heimdall/compact-window" -type f -name '*settings.json.bak' 2>/dev/null | head -n 1; }                            # the first backup
same()  { cmp -s "$1" "$2"; }

PRETTY='{
  "permissions": {
    "allow": [
      "Bash(git fetch:*)",
      "Bash(npx tsc:*)"
    ],
    "deny": []
  },
  "env": {
    "NOTE": "héllo € \"quoted\" \\ back"
  },
  "ratio": 1.50,
  "big": 12345678901234567890,
  "unicode": "héllo €",
  "remoteControlAtStartup": false
}
'
COMPACT='{"a":1,"b":[1,2,{"c":"é"}],"d":{"e":null}}'
TABS=$'{\n\t"x": 1,\n\t"y": {"z": [true, false]}\n}'

# ---- A. round trip on three layouts --------------------------------------------------------------------------------------------------------------------------
for layout in PRETTY COMPACT TABS; do
  new_home; printf '%s' "${!layout}" >"$S"; cp "$S" "$TMP/orig"
  cw on --yes
  eq "A/$layout: on --yes exits 0" 0 "$RC"
  eq "A/$layout: the key is 300000" 300000 "$(value)"
  chk "A/$layout: every other member is the same, in order, at every level" "$PY" -I "$TMP/chk.py" others "$TMP/orig" "$S"
  eq "A/$layout: the record and the backup are kept" 2 "$(state)"
  same "$(bak)" "$TMP/orig"; chk "A/$layout: the backup is the file as it was, byte for byte" test "$?" = 0
  cw off --yes
  eq "A/$layout: off --yes exits 0" 0 "$RC"
  chk "A/$layout: off returns the file byte for byte" same "$S" "$TMP/orig"
  eq "A/$layout: the record and the backup are gone" 0 "$(state)"
done
new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"; cw on --yes
chk "A: the key was appended as one member in the file's own layout (text-exact), 1.50 and the 20-digit integer untouched" "$PY" -I "$TMP/chk.py" added "$TMP/orig" "$S"
chk "A: the result is still valid JSON" "$PY" -I "$TMP/chk.py" others "$S" "$S"

# ---- B. the file was rewritten by another tool between on and off -----------------------------------------------------------------------------------------------
"$PY" -I "$TMP/chk.py" reserialize "$S"
cw off --yes
eq "B: off after the file was rewritten exits 0" 0 "$RC"
eq "B: the key is gone" ABSENT "$(value)"
chk "B: what the other tool added is kept" grep -q '"addedLater"' "$S"
chk "B: and off says only the key was reverted" grep -q "only the key was reverted" "$OUT"

# ---- B2. an unrelated hand edit between on and off, hmd's key still the last member (the key-only revert is the exact inverse of the append) ---------------------
new_home; printf '%s' "$PRETTY" >"$S"; sed 's/1\.50/2.25/' "$S" >"$TMP/edited"
cw on --yes
sed -i.bak 's/1\.50/2.25/' "$S" && rm -f "$S.bak"
cw off --yes
eq "B2: off after an unrelated edit: exit 0, the key is gone" "0|ABSENT" "$RC|$(value)"
chk "B2: only the key was reverted: byte for byte the edited original" same "$S" "$TMP/edited"

# ---- C. no settings file --------------------------------------------------------------------------------------------------------------------------------------
new_home; rmdir "$H/.claude"
cw on --yes
eq "C: on creates the file" "0|300000" "$RC|$(value)"
cw off --yes
eq "C: off removes the file hmd created" "0|no" "$RC|$([ -e "$S" ] && echo yes || echo no)"

# ---- D. the existing-value guard ------------------------------------------------------------------------------------------------------------------------------
new_home; printf '{\n  "a": 1,\n  "autoCompactWindow": 200000,\n  "z": 2\n}\n' >"$S"; cp "$S" "$TMP/orig"
cw on --yes
eq "D: a value of the person's own is refused: exit 4" 4 "$RC"
chk "D: the file is untouched" same "$S" "$TMP/orig"
eq "D: no record and no backup" 0 "$(state)"
chk "D: stderr names --force" grep -q -- "--force" "$ERR"
cw on --yes --tokens 250k
eq "D: a different --tokens does not get past the guard either" "4" "$RC"
cw on --yes --force
eq "D: --force replaces it" "0|300000" "$RC|$(value)"
cw off --yes
eq "D: off puts the earlier value back" "0|200000" "$RC|$(value)"
chk "D: byte for byte" same "$S" "$TMP/orig"

# ---- E. already the wanted value; a setting hmd did not write ---------------------------------------------------------------------------------------------------
new_home; printf '{\n  "autoCompactWindow": 300000\n}\n' >"$S"; cp "$S" "$TMP/orig"
cw on --yes
eq "E: already set: exit 0, says so" "0|1" "$RC|$(grep -c 'already set' "$OUT")"
chk "E: the file is untouched, with no backup or record" test "$(state)" = 0
cw off --yes
eq "E: off with no record of hmd's own: exit 0, nothing to undo" "0|1" "$RC|$(grep -c 'nothing to undo' "$OUT")"
chk "E: the person's setting is still there, byte for byte" same "$S" "$TMP/orig"

# ---- F. consent -------------------------------------------------------------------------------------------------------------------------------------------------
new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"
cw on
eq "F: no terminal and no --yes: exit 3, consent required" "3|1" "$RC|$(grep -c 'consent required' "$ERR")"
chk "F: stderr says to ask the person and run it again with --yes" grep -q -- "--yes" "$ERR"
chk "F: nothing was written (file, backup, record)" test "$(state)|$(same "$S" "$TMP/orig" && echo same)" = "0|same"
cw on --yes; cw off
eq "F: off without --yes or a terminal: exit 3" 3 "$RC"
eq "F: and the key is still there" 300000 "$(value)"
cw off --yes
new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"
cwpty n on
eq "F: a person at a terminal who says n: exit 3, nothing written" "3|0" "$RC|$(state)"
chk "F: the question was shown with what changes and the undo" grep -q "hmd compact-window off" "$OUT"
cwpty y on
eq "F: ... who says y: written" "0|300000" "$RC|$(value)"
cwpty n off
eq "F: off, n: exit 3, the key stays" "3|300000" "$RC|$(value)"
cwpty y off
eq "F: off, y: restored" "0|ABSENT" "$RC|$(value)"
chk "F: byte for byte" same "$S" "$TMP/orig"

# ---- G. --tokens ------------------------------------------------------------------------------------------------------------------------------------------------
new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"
cw on --yes --tokens 99999;  eq "G: below 100000: usage error, exit 2" "2|ABSENT" "$RC|$(value)"
cw on --yes --tokens lots;   eq "G: not a number: exit 2" 2 "$RC"
cw on --yes --tokens 250k;   eq "G: 250k is 250000" "0|250000" "$RC|$(value)"
cw on --yes --tokens 400000; eq "G: hmd's own value is updated in place without --force" "0|400000" "$RC|$(value)"
cw off --yes;                eq "G: off returns to the very first state" "0|ABSENT" "$RC|$(value)"
chk "G: byte for byte" same "$S" "$TMP/orig"

# ---- H. files that must not be touched --------------------------------------------------------------------------------------------------------------------------
for bad_file in 'not json' '[1, 2]' '{"a": 1, "autoCompactWindow": 1, "autoCompactWindow": 2}' '{"a": 1,}' ''; do
  new_home; printf '%s' "$bad_file" >"$S"; cp "$S" "$TMP/orig"
  cw on --yes
  eq "H: [$bad_file] is refused, exit 1" 1 "$RC"
  chk "H: [$bad_file] is untouched, no record" test "$(same "$S" "$TMP/orig" && echo same)|$(state)" = "same|0"
done

# ---- I. a symlinked settings.json -------------------------------------------------------------------------------------------------------------------------------
new_home; mkdir -p "$H/dotfiles"; printf '%s' "$PRETTY" >"$H/dotfiles/settings.json"; cp "$H/dotfiles/settings.json" "$TMP/orig"; ln -s ../dotfiles/settings.json "$S"
cw on --yes
eq "I: on through a symlink: the link stays, the target is edited" "0|link|300000" "$RC|$([ -L "$S" ] && echo link)|$(value)"
cw off --yes
eq "I: off: the link stays, the target is byte for byte" "0|link" "$RC|$([ -L "$S" ] && echo link)"
chk "I: the target is as it was" same "$H/dotfiles/settings.json" "$TMP/orig"

# ---- J. offer ---------------------------------------------------------------------------------------------------------------------------------------------------
new_home
cw offer
eq "J: no terminal: exit 0, no output, nothing written, no state" "0|0|0|no|no" "$RC|$(wc -c <"$OUT" | tr -d ' ')|$(wc -c <"$ERR" | tr -d ' ')|$([ -e "$S" ] && echo yes || echo no)|$([ -e "$H/.heimdall/compact-window" ] && echo yes || echo no)"
cwpty n offer
eq "J: at a terminal, n: exit 0, the settings file is not created" "0|no" "$RC|$([ -e "$S" ] && echo yes || echo no)"
chk "J: the answer is kept (declined)" grep -q '^declined ' "$H/.heimdall/compact-window/offered"
chk "J: it said how to turn it on later" grep -q "hmd compact-window on" "$OUT"
cwpty y offer
eq "J: asked once: the second offer shows no question and writes nothing" "0|0|no" "$RC|$(grep -c '\[y/N\]' "$OUT")|$([ -e "$S" ] && echo yes || echo no)"
new_home
cwpty y offer
eq "J: at a terminal, y: set, recorded as accepted, backed up for undo" "0|300000|1" "$RC|$(value)|$(grep -c '^accepted ' "$H/.heimdall/compact-window/offered")"
cw off --yes; eq "J: and off undoes what the offer wrote" "0|no" "$RC|$([ -e "$S" ] && echo yes || echo no)"
new_home; printf '{\n  "autoCompactWindow": 123456\n}\n' >"$S"; cp "$S" "$TMP/orig"
cwpty y offer
eq "J: the key is already there: no question, recorded as present" "0|0|1" "$RC|$(grep -c '\[y/N\]' "$OUT")|$(grep -c '^present ' "$H/.heimdall/compact-window/offered")"
chk "J: and the file is untouched" same "$S" "$TMP/orig"
new_home; scrub env HEIMDALL_NO_COMPACT_WINDOW_OFFER=1 "$PY" -I "$TMP/pty_drive.py" y -- "$CW" offer >"$OUT" 2>"$ERR"; RC=$?
eq "J: HEIMDALL_NO_COMPACT_WINDOW_OFFER=1: silent, no stamp, no write" "0|0|no" "$RC|$(wc -c <"$OUT" | tr -d ' ')|$([ -e "$H/.heimdall/compact-window/offered" ] && echo yes || echo no)"

# ---- K. status, help, usage ------------------------------------------------------------------------------------------------------------------------------------
new_home; printf '%s' "$PRETTY" >"$S"
cw status;            eq "K: status of a file without the key" "0|1" "$RC|$(grep -c 'not set' "$OUT")"
cw on --yes; cw status; eq "K: status after on says hmd set it" "0|1" "$RC|$(grep -c 'set by hmd' "$OUT")"
cw off --yes; printf '{"autoCompactWindow": 150000}' >"$S"; cw status
eq "K: status of a value that is the person's own says so" "0|1" "$RC|$(grep -c 'your own setting' "$OUT")"
printf 'nope' >"$S"; cw status;   eq "K: status of an unusable file: exit 1" 1 "$RC"
cw --help;            eq "K: --help: exit 0 and the usage" "0|1" "$RC|$(grep -c 'compact-window on' "$OUT")"
cw;                   eq "K: no verb: usage error, exit 2" 2 "$RC"
cw frobnicate;        eq "K: an unknown verb: exit 2" 2 "$RC"

# ---- L. wiring --------------------------------------------------------------------------------------------------------------------------------------------------
for f in bin/heimdall install.sh bin/heimdall-autoupdate; do bash -n "$REPO/$f" 2>"$ERR"; RC=$?; eq "L: bash -n $f" 0 "$RC"; done
new_home
RUN_INSTALL='. "$1"; ensure_compact_window_offer "$2"'
scrub env HEIMDALL_INSTALL_SOURCE_ONLY=1 bash -c "$RUN_INSTALL" _ "$REPO/install.sh" "$REPO" </dev/null >"$OUT" 2>"$ERR"; RC=$?
eq "L: a non-terminal install writes nothing: exit 0, no output, no settings file, no state" "0|0|0|no|no" "$RC|$(wc -c <"$OUT" | tr -d ' ')|$(wc -c <"$ERR" | tr -d ' ')|$([ -e "$S" ] && echo yes || echo no)|$([ -e "$H/.heimdall/compact-window" ] && echo yes || echo no)"
scrub env HEIMDALL_INSTALL_SOURCE_ONLY=1 "$PY" -I "$TMP/pty_drive.py" n -- "$(command -v bash)" -c "$RUN_INSTALL" _ "$REPO/install.sh" "$REPO" >"$OUT" 2>"$ERR"; RC=$?
eq "L: the install step at a terminal asks, and a no changes nothing" "0|1|no" "$RC|$(grep -c '\[y/N\]' "$OUT")|$([ -e "$S" ] && echo yes || echo no)"
scrub env HEIMDALL_INSTALL_SOURCE_ONLY=1 "$PY" -I "$TMP/pty_drive.py" - -- "$(command -v bash)" -c "$RUN_INSTALL" _ "$REPO/install.sh" "$REPO" >"$OUT" 2>"$ERR"; RC=$?
eq "L: ... and only once" "0|0" "$RC|$(grep -c '\[y/N\]' "$OUT")"
new_home; printf '%s' "$PRETTY" >"$S"
scrub "$REPO/bin/heimdall" compact-window status </dev/null >"$OUT" 2>"$ERR"; RC=$?
eq "L: the dispatcher reaches the tool, the verb consumed" "0|1" "$RC|$(grep -c '^window' "$OUT")"
scrub "$REPO/bin/heimdall" compact-window on </dev/null >"$OUT" 2>"$ERR"; RC=$?
eq "L: and its exit status comes back unchanged (3: consent required)" "3|no" "$RC|$(grep -q autoCompactWindow "$S" && echo yes || echo no)"
chk "L: hmd --help lists compact-window" grep -q 'heimdall compact-window <status|on|off>' <(scrub "$REPO/bin/heimdall" --help </dev/null 2>&1)
chk "L: runhmd's subcommand list names it" grep -qx 'compact-window' "$REPO/packages/runhmd/subcommands.txt"
chk "L: hmd --update asks through the same step" grep -q 'ask_compact_window || true' "$REPO/bin/heimdall-autoupdate"
chk "L: the README names the command" grep -q 'hmd compact-window on' "$REPO/README.md"
chk "L: the npm README copy is the same file" cmp -s "$REPO/README.md" "$REPO/packages/runheimdall/README.md"

# ---- M. a second settings file (CLAUDE_CONFIG_DIR changed): the first record and backup stay, and each file is undone on its own -----------------------------------
valueof() { "$PY" -I "$TMP/chk.py" value "$1"; }
cwat()    { local dir="$1"; shift; scrub env CLAUDE_CONFIG_DIR="$dir" "$CW" "$@" </dev/null >"$OUT" 2>"$ERR"; RC=$?; }   # as cw, with CLAUDE_CONFIG_DIR=$dir
new_home; mkdir -p "$H/second"; S2="$H/second/settings.json"
printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"; printf '%s' "$COMPACT" >"$S2"; cp "$S2" "$TMP/orig2"
cw on --yes
cwat "$H/second" on --yes --tokens 250k
eq "M: on against a second settings file: exit 0, each file carries its own value" "0|300000|250000" "$RC|$(value)|$(valueof "$S2")"
eq "M: each file keeps its own record and backup: the second did not overwrite the first (4 files)" 4 "$(state)"
cwat "$H/second" status
eq "M: status of the second file says hmd set it, and names the first" "1|1" "$(grep -c 'set by hmd' "$OUT")|$(grep -c -F '~/.claude/settings.json' "$OUT")"
cw status
eq "M: status of the first file says hmd set it, and names the second" "1|1" "$(grep -c 'set by hmd' "$OUT")|$(grep -c -F '~/second/settings.json' "$OUT")"
cwat "$H/second" off --yes
eq "M: off in the second environment restores the second file, byte for byte" "0|ABSENT|same" "$RC|$(valueof "$S2")|$(same "$S2" "$TMP/orig2" && echo same)"
eq "M: ... and leaves the first file, its record and its backup alone" "300000|2" "$(value)|$(state)"
cwat "$H/second" off --yes
eq "M: off there again: nothing to undo, and it names the first file that still carries the key" "0|1|1" "$RC|$(grep -c 'nothing to undo' "$OUT")|$(grep -c -F '~/.claude/settings.json' "$OUT")"
cw off --yes
eq "M: off in the first environment restores the first file, byte for byte, the record and the backup gone" "0|ABSENT|same|0" "$RC|$(value)|$(same "$S" "$TMP/orig" && echo same)|$(state)"
new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"; ln -s "$H/.claude" "$H/linkdir"
cwat "$H/linkdir" on --yes
cw status
eq "M: keyed by the canonical path: set through a symlinked config directory, the real one finds the record (status)" "0|1" "$RC|$(grep -c 'set by hmd' "$OUT")"
cw off --yes
eq "M: ... and off" "0|ABSENT|same|0" "$RC|$(value)|$(same "$S" "$TMP/orig" && echo same)|$(state)"

# ---- N. the file changed while hmd was working: nothing is written over the other change -------------------------------------------------------------------------
# drive.py runs the tool in this process and, at the chosen moment, has another writer save the settings file (what the writer does to it: see drive.py).
racing()       { local point="$1" kind="$2"; shift 2; scrub "$PY" -I "$TMP/drive.py" race "$CW" "$S" "$point" "$kind" -- "$@" </dev/null >"$OUT" 2>"$ERR"; RC=$?; }
leftovers()    { ls -a "$(dirname "$S")" | grep -c 'hmd-compact-window'; }                 # temp files hmd left in the settings directory
plus_newline() { { cat "$1"; printf '\n'; } >"$2"; }                                       # $2 := $1 and one more newline: what the other writer leaves
for kind in inplace swap twin; do
  new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"; plus_newline "$TMP/orig" "$TMP/theirs"
  racing write "$kind" on --yes
  eq "N/$kind: on, the file saved by another writer during the write: exit 1, says it changed" "1|1" "$RC|$(grep -c 'changed while hmd was working' "$ERR")"
  eq "N/$kind: no record, no backup, no temp file left behind" "0|0" "$(state)|$(leftovers)"
  if [ "$kind" = twin ]; then expect="$TMP/orig"; else expect="$TMP/theirs"; fi
  chk "N/$kind: the file is as the other writer left it, nothing of hmd's in it" same "$S" "$expect"
done
new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"; cw on --yes; plus_newline "$S" "$TMP/theirs"
racing write inplace off --yes
eq "N: off, the file saved by another writer during the write: exit 1, says it changed, the record is kept" "1|1|2" "$RC|$(grep -c 'changed while hmd was working' "$ERR")|$(state)"
chk "N: ... and the other writer's change is in the file" same "$S" "$TMP/theirs"
cw off --yes
plus_newline "$TMP/orig" "$TMP/theirs"
eq "N: run again, off goes through: the key only, the other change stays, the record is gone" "0|ABSENT|0" "$RC|$(value)|$(state)"
chk "N: ... the file is the original plus the other writer's change" same "$S" "$TMP/theirs"
new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"; cw on --yes
racing write inplace on --yes --tokens 400000
eq "N: an update of hmd's own value that aborts: exit 1, the value is still the first one" "1|300000" "$RC|$(value)"
cw off --yes
plus_newline "$TMP/orig" "$TMP/theirs"
eq "N: ... and the earlier record is still true: off undoes to the very first state, keeping the other change" "0|ABSENT|same" "$RC|$(value)|$(same "$S" "$TMP/theirs" && echo same)"
new_home; rmdir "$H/.claude"; cw on --yes; plus_newline "$S" "$TMP/theirs"
racing prompt inplace off --yes
eq "N: off of the file hmd created, saved by another writer while the person was deciding: exit 1, the file is not removed" "1|1|yes" "$RC|$(grep -c 'changed while hmd was working' "$ERR")|$([ -e "$S" ] && echo yes || echo no)"
chk "N: ... and it holds the other writer's change" same "$S" "$TMP/theirs"

# ---- O. a record that cannot be read or used: said plainly, nothing changed, the record not damaged by the attempt ------------------------------------------------
make_unreadable() { chmod 000 "$1"; if [ -r "$1" ]; then chmod 600 "$1"; rm -f "$1"; mkdir "$1"; fi; }   # chmod 000, or (root reads through it) a directory in its place: the same OSError
new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"; cw on --yes; cp "$S" "$TMP/after-on"
REC="$(rec)"; cp "$REC" "$TMP/record"; make_unreadable "$REC"
for verb in "status" "on --yes" "off --yes"; do
  cw $verb
  eq "O: [$verb] with a record that cannot be read: exit 1" 1 "$RC"
  chk "O: [$verb] says it cannot read the record, and which" grep -q "cannot read .*state.json" "$ERR"
  chk "O: [$verb] left the settings file alone" same "$S" "$TMP/after-on"
done
cwat "$H/second" on --yes
eq "O: the unreadable record is its own file's problem: on for another settings file goes through" 0 "$RC"
cwat "$H/second" status
eq "O: ... and its status works, without naming the file whose record cannot be read" "0|0" "$RC|$(grep -c 'also set it' "$OUT")"
rm -rf "$REC"; cp "$TMP/record" "$REC"
for bad_record in 'not json' '[1]' '{"schema": 2}' '{"schema": 1}' '{"schema": 1, "settings": 7}'; do
  printf '%s' "$bad_record" >"$REC"
  cw off --yes
  eq "O: the record [$bad_record] cannot be used: exit 1, says so and how to clear it" "1|1|1" "$RC|$(grep -c 'cannot be used' "$ERR")|$(grep -c 'remove it by hand' "$ERR")"
  chk "O: [$bad_record] left the settings file alone" same "$S" "$TMP/after-on"
done
sed 's|"settings": ".*"|"settings": "/elsewhere/settings.json"|' "$TMP/record" >"$REC"
cw off --yes
eq "O: a record that names another settings file is not this file's: exit 1, says so" "1|1" "$RC|$(grep -c 'another settings file' "$ERR")"
chk "O: ... and the settings file is left alone" same "$S" "$TMP/after-on"
cp "$TMP/record" "$REC"; cw off --yes
eq "O: the record put back, off undoes it: the attempts above damaged nothing" "0|ABSENT|same" "$RC|$(value)|$(same "$S" "$TMP/orig" && echo same)"
new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"; cw on --yes; cp "$S" "$TMP/after-on"
BAK="$(bak)"; cp "$BAK" "$TMP/backup"; make_unreadable "$BAK"
cw off --yes
eq "O: off with a backup that cannot be read: exit 1, names the backup, no traceback" "1|1|0" "$RC|$(grep -c 'cannot read .*settings.json.bak' "$ERR")|$(grep -c Traceback "$ERR")"
chk "O: ... and the settings file is left alone" same "$S" "$TMP/after-on"
rm -rf "$BAK"; cp "$TMP/backup" "$BAK"; cw off --yes
eq "O: the backup put back, off undoes it" "0|ABSENT|same" "$RC|$(value)|$(same "$S" "$TMP/orig" && echo same)"

# ---- P. an offer nobody answers: it gives up after the wait, writes nothing and is not recorded as answered, so it is asked again ----------------------------------
new_home
scrub env HEIMDALL_COMPACT_WINDOW_OFFER_WAIT_S=1 "$PY" -I "$TMP/pty_drive.py" - -- "$CW" offer >"$OUT" 2>"$ERR"; RC=$?
eq "P: nobody answers: the offer gives up after the 1 s seam, exit 0, the question was shown once" "0|1" "$RC|$(grep -c '\[y/N\]' "$OUT")"
eq "P: nothing was written and the unanswered offer is not recorded" "no|no" "$([ -e "$S" ] && echo yes || echo no)|$([ -e "$H/.heimdall/compact-window/offered" ] && echo yes || echo no)"
cwpty n offer
eq "P: so the next offer asks again, and a no is kept" "0|1|1" "$RC|$(grep -c '\[y/N\]' "$OUT")|$(grep -c '^declined ' "$H/.heimdall/compact-window/offered")"
for seam in 7 0.5; do
  eq "P: the seam [$seam] shortens the wait" "$seam" "$(scrub env HEIMDALL_COMPACT_WINDOW_OFFER_WAIT_S="$seam" "$PY" -I "$TMP/drive.py" wait "$CW" 2>&1)"
done
for seam in abc 0 -3 nan inf 1e9 ''; do
  eq "P: the seam [$seam] is ignored: the wait stays 300 s" 300 "$(scrub env HEIMDALL_COMPACT_WINDOW_OFFER_WAIT_S="$seam" "$PY" -I "$TMP/drive.py" wait "$CW" 2>&1)"
done
eq "P: with no seam the wait is 300 s" 300 "$(scrub "$PY" -I "$TMP/drive.py" wait "$CW" 2>&1)"

# ---- Q. an install from 2.4.12: the one record and backup it kept for the whole machine (state.json, settings.json.bak) belong to the settings file the record names ------
# The fixture is the real old format: the 2.4.12 tool itself, read from git (tag v2.4.12), writes it. Whichever verb the person runs first after the update must find it.
OLD="$TMP/heimdall-compact-window-2.4.12"
git -C "$REPO" show v2.4.12:bin/heimdall-compact-window >"$OLD" 2>"$ERR"; RC=$?
eq "Q: the 2.4.12 tool is read from git (a checkout without the tag needs: git fetch --tags)" 0 "$RC"
if [ "$RC" -eq 0 ]; then
  chmod +x "$OLD"
  old()     { scrub "$OLD" "$@" </dev/null >"$OUT" 2>"$ERR"; RC=$?; }                                                          # the 2.4.12 tool, no terminal
  oldat()   { local dir="$1"; shift; scrub env CLAUDE_CONFIG_DIR="$dir" "$OLD" "$@" </dev/null >"$OUT" 2>"$ERR"; RC=$?; }      # ... with CLAUDE_CONFIG_DIR=$dir
  bare()    { find "$H/.heimdall/compact-window" -maxdepth 1 \( -name state.json -o -name settings.json.bak \) 2>/dev/null | wc -l | tr -d ' '; }   # the 2.4.12 names still in place
  listing() { find "$H/.heimdall/compact-window" -type f -exec cksum {} + 2>/dev/null | sort; }                                     # every file kept, with its checksum
  LEG=""   # set per scenario: the record under its 2.4.12 name

  # off is the first verb after the update
  new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"
  old on --yes
  eq "Q: the 2.4.12 tool kept one pair under the bare names (so the fixture is the old format)" "0|2|2" "$RC|$(bare)|$(state)"
  cw off --yes
  eq "Q: off, the first verb after the update, undoes what 2.4.12 set: the key is gone" "0|ABSENT" "$RC|$(value)"
  chk "Q: ... byte for byte" same "$S" "$TMP/orig"
  eq "Q: ... and the pair is gone, under either name" "0|0" "$(bare)|$(state)"

  # status is the first verb after the update
  new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"; old on --yes
  cw status
  eq "Q: status, the first verb after the update: hmd set it, not 'your own setting'" "0|1|0" "$RC|$(grep -c 'set by hmd' "$OUT")|$(grep -c 'your own setting' "$OUT")"
  eq "Q: ... the pair has the names of its settings file now: no bare name left, both files kept" "0|2" "$(bare)|$(state)"
  before="$(listing)"; cw status; cw status
  eq "Q: the move is idempotent: two more runs change nothing" "$before" "$(listing)"
  cw off --yes
  eq "Q: ... and off after it restores the file byte for byte" "0|ABSENT|same|0" "$RC|$(value)|$(same "$S" "$TMP/orig" && echo same)|$(state)"

  # on --tokens is the first verb after the update
  new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"; old on --yes
  cw on --yes --tokens 250k
  eq "Q: on --tokens, the first verb after the update: hmd's own value is updated, no --force" "0|250000" "$RC|$(value)"
  cw off --yes
  eq "Q: ... and off still undoes to the very first state, byte for byte" "0|ABSENT|same|0" "$RC|$(value)|$(same "$S" "$TMP/orig" && echo same)|$(state)"

  # the record names ANOTHER settings file (2.4.12 run with a different CLAUDE_CONFIG_DIR): it becomes that file's, and is never adopted for this one
  new_home; mkdir -p "$H/second"; S2="$H/second/settings.json"
  printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"; printf '%s' "$COMPACT" >"$S2"; cp "$S2" "$TMP/orig2"
  oldat "$H/second" on --yes
  cw status
  eq "Q: a 2.4.12 record of another settings file: this file is not set, and the other one is named" "0|1|1" "$RC|$(grep -c 'not set' "$OUT")|$(grep -c -F '~/second/settings.json' "$OUT")"
  eq "Q: ... the pair went to the other file's names, not this one's: this file untouched, no bare name left" "same|0|2" "$(same "$S" "$TMP/orig" && echo same)|$(bare)|$(state)"
  cw off --yes
  eq "Q: off here: nothing to undo (the record is not this file's), the other file is named and keeps its key" "0|1|1|300000" "$RC|$(grep -c 'nothing to undo' "$OUT")|$(grep -c -F '~/second/settings.json' "$OUT")|$(valueof "$S2")"
  cwat "$H/second" off --yes
  eq "Q: off with its own CLAUDE_CONFIG_DIR restores that file byte for byte, the pair gone" "0|ABSENT|same|0" "$RC|$(valueof "$S2")|$(same "$S2" "$TMP/orig2" && echo same)|$(state)"
  chk "Q: ... and this file was never touched" same "$S" "$TMP/orig"

  # the record spells this file's path through a symlink: it canonicalizes to this file, so it is this file's, and is rewritten to the real path
  new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"; ln -s "$H/.claude" "$H/linkdir"; old on --yes
  LEG="$H/.heimdall/compact-window/state.json"
  sed "s|\"settings\": \".*\"|\"settings\": \"$H/linkdir/settings.json\"|" "$LEG" >"$TMP/spelled" && cp "$TMP/spelled" "$LEG"
  cw status
  eq "Q: a 2.4.12 record that spells this file through a symlink: hmd set it" "0|1" "$RC|$(grep -c 'set by hmd' "$OUT")"
  chk "Q: ... and the record now names the real path" grep -q "\"settings\": \"$S\"" "$(rec)"
  cw off --yes
  eq "Q: ... off restores it byte for byte" "0|ABSENT|same|0" "$RC|$(value)|$(same "$S" "$TMP/orig" && echo same)|$(state)"

  # a 2.4.12 record that cannot be read or used: exit 1, said plainly, nothing changed or moved, the record undamaged
  new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"; old on --yes; cp "$S" "$TMP/after-on"
  LEG="$H/.heimdall/compact-window/state.json"; cp "$LEG" "$TMP/legacy-record"; make_unreadable "$LEG"
  for verb in "status" "on --yes" "off --yes"; do
    cw $verb
    eq "Q: [$verb] with a 2.4.12 record that cannot be read: exit 1, names it, no traceback" "1|1|0" "$RC|$(grep -c 'cannot read .*state.json' "$ERR")|$(grep -c Traceback "$ERR")"
    chk "Q: [$verb] left the settings file alone and moved nothing" test "$(same "$S" "$TMP/after-on" && echo same)|$(bare)" = "same|2"
  done
  rm -rf "$LEG"; cp "$TMP/legacy-record" "$LEG"
  for bad_record in 'not json' '{"schema": 2}' '{"schema": 1, "settings": "relative.json", "had_file": false, "had_key": false, "written": 300000, "sha256_after": "x"}'; do
    printf '%s' "$bad_record" >"$LEG"
    cw off --yes
    eq "Q: the 2.4.12 record [$bad_record] cannot be used: exit 1, says so and how to clear it" "1|1|1" "$RC|$(grep -c 'cannot be used' "$ERR")|$(grep -c 'remove it by hand' "$ERR")"
    chk "Q: ... the settings file is left alone and nothing was moved" test "$(same "$S" "$TMP/after-on" && echo same)|$(bare)" = "same|2"
  done
  cp "$TMP/legacy-record" "$LEG"; cw off --yes
  eq "Q: the record put back, off undoes it: the attempts above damaged nothing" "0|ABSENT|same|0" "$RC|$(value)|$(same "$S" "$TMP/orig" && echo same)|$(state)"

  # a record of the same file is already in place (made by a run before the move existed): the newer one stays, the old pair is left alone
  new_home; printf '%s' "$PRETTY" >"$S"
  cw on --yes --tokens 250k; NEWREC="$(rec)"; cp "$NEWREC" "$TMP/newer-record"
  old on --yes --force --tokens 400k
  eq "Q: the fixture: a 2.4.12 pair next to a record of the same settings file (4 files)" "0|2|4" "$RC|$(bare)|$(state)"
  cw status
  chk "Q: the record already in place is never replaced by the old one" cmp -s "$NEWREC" "$TMP/newer-record"
  eq "Q: ... and the old pair is left where it is, not deleted" "2|4" "$(bare)|$(state)"

  # a move interrupted after the backup moved (the record still under the old name): the next run finishes it
  new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"; old on --yes
  cw status
  mv "$(rec)" "$H/.heimdall/compact-window/state.json"
  eq "Q: the fixture: the backup under its own name, the record under the old one" "1|2" "$(bare)|$(state)"
  cw off --yes
  eq "Q: the next run finishes the move: off restores the file byte for byte, the pair gone" "0|ABSENT|same|0" "$RC|$(value)|$(same "$S" "$TMP/orig" && echo same)|$(state)"
fi

# ---- R. the Bash output cap: `on --bash-cap` sets bashOutputMaxChars with every guarantee of the window, on a record and a backup of its own --------------------------------
# What the agent reads is the settings key bashOutputMaxChars: the output Claude receives inline, 30000 by default, clamped to 4000-128000, past it a preview and a file path. The variable
# BASH_MAX_OUTPUT_LENGTH only sizes the read-back window and is ignored once the key is set, so a BASH_MAX_OUTPUT_LENGTH of the person's own is a value of theirs.
CAPKEY=bashOutputMaxChars
capval() { CHK_KEY=$CAPKEY "$PY" -I "$TMP/chk.py" value "$S"; }                                                                                              # the cap's value as JSON, or ABSENT
cstate() { find "$H/.heimdall/compact-window" -type f \( -name '*.bash-cap.state.json' -o -name '*.bash-cap.settings.json.bak' \) 2>/dev/null | wc -l | tr -d ' '; }   # the cap's records and backups kept
wstate() { echo $(( $(state) - $(cstate) )); }                                                                                                                # the window's
crec()   { find "$H/.heimdall/compact-window" -type f -name '*.bash-cap.state.json' 2>/dev/null | head -n 1; }                                                 # the cap's record
cbak()   { find "$H/.heimdall/compact-window" -type f -name '*.bash-cap.settings.json.bak' 2>/dev/null | head -n 1; }                                          # the cap's backup

# round trip on three layouts
for layout in PRETTY COMPACT TABS; do
  new_home; printf '%s' "${!layout}" >"$S"; cp "$S" "$TMP/orig"
  cw on --bash-cap --yes
  eq "R/$layout: on --bash-cap --yes exits 0" 0 "$RC"
  eq "R/$layout: the cap is 16000 and the window's key is not there" "16000|ABSENT" "$(capval)|$(value)"
  chk "R/$layout: every other member is the same, in order, at every level" env CHK_KEY=$CAPKEY "$PY" -I "$TMP/chk.py" others "$TMP/orig" "$S"
  eq "R/$layout: the cap keeps a record and a backup of its own, the window none" "2|0" "$(cstate)|$(wstate)"
  chk "R/$layout: the backup is the file as it was, byte for byte" same "$(cbak)" "$TMP/orig"
  cw off --bash-cap --yes
  eq "R/$layout: off --bash-cap --yes exits 0" 0 "$RC"
  chk "R/$layout: off returns the file byte for byte" same "$S" "$TMP/orig"
  eq "R/$layout: the record and the backup are gone" 0 "$(state)"
done
new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"; cw on --bash-cap --yes
chk "R: the key was appended as one member in the file's own layout (text-exact), 1.50 and the 20-digit integer untouched" env CHK_KEY=$CAPKEY CHK_VALUE=16000 "$PY" -I "$TMP/chk.py" added "$TMP/orig" "$S"
cw on --bash-cap 12k --yes;   eq "R: 12k is 12000, and hmd's own value is updated in place without --force" "0|12000" "$RC|$(capval)"
cw on --bash-cap 128k --yes;  eq "R: 128000, the top of the range, is taken" "0|128000" "$RC|$(capval)"
cw on --bash-cap 4000 --yes;  eq "R: 4000, the bottom of the range, is taken" "0|4000" "$RC|$(capval)"
cw on --bash-cap 3999 --yes;  eq "R: below 4000: usage error, exit 2, the value stays" "2|4000" "$RC|$(capval)"
cw on --bash-cap 129k --yes;  eq "R: above 128000: exit 2" "2|4000" "$RC|$(capval)"
cw on --bash-cap lots --yes;  eq "R: not a number: exit 2" 2 "$RC"
cw on --tokens 250k --bash-cap --yes; eq "R: --tokens with --bash-cap is one setting too many: exit 2, nothing written" "2|4000" "$RC|$(capval)"
cw off --bash-cap --yes;      eq "R: off returns to the very first state" "0|ABSENT" "$RC|$(capval)"
chk "R: byte for byte" same "$S" "$TMP/orig"

# a value of the person's own
new_home; printf '{\n  "a": 1,\n  "bashOutputMaxChars": 50000,\n  "z": 2\n}\n' >"$S"; cp "$S" "$TMP/orig"
cw on --bash-cap --yes
eq "R: a value of the person's own is refused: exit 4" 4 "$RC"
chk "R: the file is untouched" same "$S" "$TMP/orig"
eq "R: no record and no backup" 0 "$(state)"
chk "R: stderr names --force and the command that puts the value back" grep -qF -- "--force replaces it (hmd compact-window off --bash-cap then puts 50000 back)" "$ERR"
cw on --bash-cap 12k --yes
eq "R: a different value does not get past the guard either" 4 "$RC"
cw on --bash-cap --yes --force
eq "R: --force replaces it" "0|16000" "$RC|$(capval)"
cw off --bash-cap --yes
eq "R: off puts the earlier value back" "0|50000" "$RC|$(capval)"
chk "R: byte for byte" same "$S" "$TMP/orig"
new_home; printf '{\n  "bashOutputMaxChars": 16000\n}\n' >"$S"; cp "$S" "$TMP/orig"
cw on --bash-cap --yes
eq "R: already the wanted value: exit 0, says so" "0|1" "$RC|$(grep -c 'already set' "$OUT")"
chk "R: the file is untouched, with no backup or record" test "$(state)|$(same "$S" "$TMP/orig" && echo same)" = "0|same"
cw off --bash-cap --yes
eq "R: off with no record of hmd's own: nothing to undo, the person's value stays" "0|1|same" "$RC|$(grep -c 'nothing to undo' "$OUT")|$(same "$S" "$TMP/orig" && echo same)"

# consent
new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"
cw on --bash-cap 12k
eq "R: no terminal and no --yes: exit 3, consent required" "3|1" "$RC|$(grep -c 'consent required' "$ERR")"
chk "R: stderr gives the command to run again, the setting and the value kept" grep -qF -- "hmd compact-window on --bash-cap 12000 --yes" "$ERR"
chk "R: nothing was written (file, backup, record)" test "$(state)|$(same "$S" "$TMP/orig" && echo same)" = "0|same"
cw on --bash-cap --yes; cw off --bash-cap
eq "R: off --bash-cap without --yes or a terminal: exit 3, the command names the setting, the key stays" "3|1|16000" "$RC|$(grep -cF -- 'hmd compact-window off --bash-cap --yes' "$ERR")|$(capval)"
cw off --bash-cap --yes
new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"
cwpty n on --bash-cap
eq "R: a person at a terminal who says n: exit 3, nothing written" "3|0" "$RC|$(state)"
chk "R: the question names the setting and its value" grep -qF -- "set the Bash output cap to 16,000 characters" "$OUT"
chk "R: ... and the command that undoes it" grep -qF -- "undo    hmd compact-window off --bash-cap" "$OUT"
cwpty y on --bash-cap
eq "R: ... who says y: written" "0|16000" "$RC|$(capval)"
cwpty n off --bash-cap
eq "R: off --bash-cap, n: exit 3, the key stays" "3|16000" "$RC|$(capval)"
cwpty y off --bash-cap
eq "R: off --bash-cap, y: restored" "0|ABSENT" "$RC|$(capval)"
chk "R: byte for byte" same "$S" "$TMP/orig"

# both levers in one file: each is undone on its own, in either order
for layout in PRETTY COMPACT; do
  new_home; printf '%s' "${!layout}" >"$S"; cp "$S" "$TMP/orig"
  cw on --yes; cw on --bash-cap --yes
  eq "R/both/$layout: the window and the cap in one file: each its own key, its own record and backup" "300000|16000|2|2" "$(value)|$(capval)|$(wstate)|$(cstate)"
  cw off --bash-cap --yes
  eq "R/both/$layout: off --bash-cap takes only the cap: the window's key, record and backup stay" "300000|ABSENT|2|0" "$(value)|$(capval)|$(wstate)|$(cstate)"
  cw off --yes
  eq "R/both/$layout: ... and off then restores the file byte for byte" "same|0" "$(same "$S" "$TMP/orig" && echo same)|$(state)"
  cw on --yes; cw on --bash-cap --yes; cw off --yes
  eq "R/both/$layout: off takes only the window, set first: the cap's key, record and backup stay" "ABSENT|16000|0|2" "$(value)|$(capval)|$(wstate)|$(cstate)"
  cw off --bash-cap --yes
  eq "R/both/$layout: ... and off --bash-cap then restores the file byte for byte" "same|0" "$(same "$S" "$TMP/orig" && echo same)|$(state)"
done
new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"
cw on --yes; cw on --bash-cap --yes; cw on --yes --tokens 400k; cw off --yes
eq "R/both: the window updated after the cap, then off: the cap's key survives (the window's backup, taken before the cap, is not put back)" "ABSENT|16000|0|2" "$(value)|$(capval)|$(wstate)|$(cstate)"
cw off --bash-cap --yes
eq "R/both: ... and off --bash-cap then restores the file byte for byte" "same|0" "$(same "$S" "$TMP/orig" && echo same)|$(state)"
new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"
cw on --bash-cap --yes; cw off --yes
eq "R: off with only the cap set: nothing to undo for the window, the cap stays" "0|1|16000|2" "$RC|$(grep -c 'nothing to undo' "$OUT")|$(capval)|$(cstate)"
cw off --bash-cap --yes; cw on --yes; cw off --bash-cap --yes
eq "R: off --bash-cap with only the window set: nothing to undo for the cap, the window stays" "0|1|300000|2" "$RC|$(grep -c 'nothing to undo' "$OUT")|$(value)|$(wstate)"
cw off --yes

# a settings file hmd created for one of the two goes with whichever off comes last, in every order of setting and of undoing: the record of the setting made second would say "the file was
# there" (it was, hmd made it a moment ago), so it carries who made the file (file_created). A file the person made or touched is never removed, and one that was there is restored byte for byte.
there()   { [ -e "$S" ] && echo yes || echo no; }
hmdkeys() { grep -o -E '"(autoCompactWindow|bashOutputMaxChars)"' "$S" 2>/dev/null | tr -d '"\n'; }    # the keys of the two settings in the file, run together; empty when there are none or no file
claims()  { cat "$H"/.heimdall/compact-window/*state.json | grep -c "\"file_created\": $1"; }           # the records that say hmd made the file (true) or did not (false)
for first in window cap; do
  for undo in window cap; do
    new_home; rmdir "$H/.claude"
    if [ "$first" = window ]; then cw on --yes; cw on --bash-cap --yes; else cw on --bash-cap --yes; cw on --yes; fi
    eq "R/made/$first-first/$undo-first: both records say hmd made the file" 2 "$(claims true)"
    if [ "$undo" = window ]; then cw off --yes; left=bashOutputMaxChars; else cw off --bash-cap --yes; left=autoCompactWindow; fi
    eq "R/made/$first-first/$undo-first: the first off takes its key only: the file stays, the other setting's key alone in it" "yes|$left" "$(there)|$(hmdkeys)"
    if [ "$undo" = window ]; then cw off --bash-cap --yes; else cw off --yes; fi
    eq "R/made/$first-first/$undo-first: the last off removes the file hmd created, every record and backup with it" "0|no|0" "$RC|$(there)|$(state)"
  done
done
for undo in window cap; do   # the person adds to the file hmd made after both settings were set: it is theirs now, only hmd's keys go
  new_home; rmdir "$H/.claude"; cw on --yes; cw on --bash-cap --yes
  "$PY" -I "$TMP/chk.py" reserialize "$S"
  if [ "$undo" = window ]; then cw off --yes; cw off --bash-cap --yes; else cw off --bash-cap --yes; cw off --yes; fi
  eq "R/made/$undo-first: a file the person added to is theirs: it stays with what they added, and none of hmd's keys" "yes||1|0" "$(there)|$(hmdkeys)|$(grep -c '"addedLater"' "$S")|$(state)"
done
new_home; rmdir "$H/.claude"; cw on --yes
printf '{\n}\n' >"$S"; cp "$S" "$TMP/orig"   # the person puts a file of their own in place of the one hmd made, before the second setting
cw on --bash-cap --yes
eq "R/own: a file that is not the one hmd made is not carried as hmd's: the second record says hmd did not make it (the first still says it made the one it replaced)" "1|1" "$(claims true)|$(claims false)"
cw off --yes; cw off --bash-cap --yes
eq "R/own: ... so the last off restores the person's file byte for byte, and does not remove it" "yes|same|0" "$(there)|$(same "$S" "$TMP/orig" && echo same)|$(state)"
for undo in window cap; do   # a file that was there, the cap set first: restored byte for byte, whichever comes off first
  new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"
  cw on --bash-cap --yes; cw on --yes
  eq "R/own/cap-first/$undo-first: neither record says hmd made the file" 2 "$(claims false)"
  if [ "$undo" = window ]; then cw off --yes; cw off --bash-cap --yes; else cw off --bash-cap --yes; cw off --yes; fi
  eq "R/own/cap-first/$undo-first: the file that was there is restored byte for byte, not removed, nothing kept" "yes|same|0" "$(there)|$(same "$S" "$TMP/orig" && echo same)|$(state)"
done
new_home; rmdir "$H/.claude"; cw on --yes   # a record written before records said who made the file: it made it when the file was not there
"$PY" -I -c 'import json, sys; p = sys.argv[1]; r = json.load(open(p)); r.pop("file_created", None); open(p, "w").write(json.dumps(r, indent=2) + "\n")' "$(rec)"
cw off --yes
eq "R/made: a record with no file_created still removes the file when it was not there before the key" "0|no|0" "$RC|$(there)|$(state)"

# a BASH_MAX_OUTPUT_LENGTH of the person's own: the agent ignores it once the key is set, so it is a value of theirs
new_home; printf '{\n  "env": {\n    "BASH_MAX_OUTPUT_LENGTH": "60000"\n  }\n}\n' >"$S"; cp "$S" "$TMP/orig"
cw on --bash-cap --yes
eq "R: BASH_MAX_OUTPUT_LENGTH in the env block of the settings file: exit 4, nothing written" "4|ABSENT|0" "$RC|$(capval)|$(state)"
chk "R: ... named, with where it is" grep -qF -- 'BASH_MAX_OUTPUT_LENGTH is "60000" in the env block' "$ERR"
chk "R: ... the file is untouched" same "$S" "$TMP/orig"
cw on --bash-cap --yes --force
eq "R: --force sets the key anyway" "0|16000" "$RC|$(capval)"
cw off --bash-cap --yes
eq "R: off removes it again, so the variable counts again: the file byte for byte" "0|ABSENT|same" "$RC|$(capval)|$(same "$S" "$TMP/orig" && echo same)"
new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"
scrub env BASH_MAX_OUTPUT_LENGTH=60000 "$CW" on --bash-cap --yes </dev/null >"$OUT" 2>"$ERR"; RC=$?
eq "R: BASH_MAX_OUTPUT_LENGTH in this environment: exit 4, the file untouched, no state" "4|same|0" "$RC|$(same "$S" "$TMP/orig" && echo same)|$(state)"
chk "R: ... named, with where it is" grep -qF -- "BASH_MAX_OUTPUT_LENGTH is 60000 in this environment" "$ERR"
scrub env BASH_MAX_OUTPUT_LENGTH=60000 "$CW" on --yes </dev/null >"$OUT" 2>"$ERR"; RC=$?
eq "R: the window is not held back by it: on goes through" "0|300000" "$RC|$(value)"
new_home; printf '%s' "$PRETTY" >"$S"
scrub env BASH_MAX_OUTPUT_LENGTH= "$CW" on --bash-cap --yes </dev/null >"$OUT" 2>"$ERR"; RC=$?
eq "R: an empty BASH_MAX_OUTPUT_LENGTH is unset to the agent too: on goes through" "0|16000" "$RC|$(capval)"

# status
new_home; printf '%s' "$PRETTY" >"$S"
cw status
eq "R: status shows the cap at the agent's default and leaves the window's row alone" "0|1|1" "$RC|$(grep -c '^bash cap .*default' "$OUT")|$(grep -c 'not set' "$OUT")"
cw on --bash-cap --yes; cw status
eq "R: status after on --bash-cap: the cap row says hmd set it, the window row does not" "1|0" "$(grep '^bash cap' "$OUT" | grep -c 'set by hmd')|$(grep '^window' "$OUT" | grep -c 'set by hmd')"
cw off --bash-cap --yes; printf '{"bashOutputMaxChars": 50000}' >"$S"; cw status
eq "R: status of a cap value that is the person's own says so" 1 "$(grep '^bash cap' "$OUT" | grep -c 'your own setting')"
scrub env BASH_MAX_OUTPUT_LENGTH=60000 "$CW" status </dev/null >"$OUT" 2>"$ERR"; RC=$?
eq "R: status names a BASH_MAX_OUTPUT_LENGTH set in this environment" "0|1" "$RC|$(grep '^env ' "$OUT" | grep -c 'BASH_MAX_OUTPUT_LENGTH=60000')"

# a second settings file: the cap set there is listed for the cap and never for the window
new_home; mkdir -p "$H/second"; S2="$H/second/settings.json"
printf '%s' "$PRETTY" >"$S"; printf '%s' "$COMPACT" >"$S2"; cp "$S2" "$TMP/orig2"
cwat "$H/second" on --bash-cap --yes
eq "R: the cap set in a second settings file: exit 0, the first file has none" "0|ABSENT" "$RC|$(capval)"
cw status
eq "R: status here names the second file, for the cap" 1 "$(grep -cF '~/second/settings.json' "$OUT")"
cw off --yes
eq "R: off here (the window): nothing to undo, and the cap set elsewhere is not listed under it" "0|1|0" "$RC|$(grep -c 'nothing to undo' "$OUT")|$(grep -cF '~/second/settings.json' "$OUT")"
cw off --bash-cap --yes
eq "R: off --bash-cap here: nothing to undo, the second file is named with the command that undoes it" "0|1|1" "$RC|$(grep -c 'nothing to undo' "$OUT")|$(grep -cF 'off --bash-cap' "$OUT")"
cwat "$H/second" off --bash-cap --yes
eq "R: off --bash-cap with its own CLAUDE_CONFIG_DIR restores that file byte for byte, the pair gone" "0|same|0" "$RC|$(same "$S2" "$TMP/orig2" && echo same)|$(state)"

# the file changed while hmd was working; a record that cannot be used
new_home; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/orig"; plus_newline "$TMP/orig" "$TMP/theirs"
racing write inplace on --bash-cap --yes
eq "R: on --bash-cap, the file saved by another writer during the write: exit 1, says it changed, no record, backup or temp file left" "1|1|0|0" "$RC|$(grep -c 'changed while hmd was working' "$ERR")|$(state)|$(leftovers)"
chk "R: ... and the file is as the other writer left it" same "$S" "$TMP/theirs"
new_home; printf '%s' "$PRETTY" >"$S"; cw on --bash-cap --yes; cp "$S" "$TMP/after-on"
printf 'not json' >"$(crec)"
cw off --bash-cap --yes
eq "R: a cap record that cannot be used: exit 1, says so and which key" "1|1|1" "$RC|$(grep -c 'cannot be used' "$ERR")|$(grep -c 'bashOutputMaxChars' "$ERR")"
chk "R: ... the settings file is left alone" same "$S" "$TMP/after-on"
cw on --yes
eq "R: a cap record that cannot be used does not hold the window back (it carries nothing, and on never fails for it): on goes through" "0|300000" "$RC|$(value)"

cw --help
chk "R: --help documents --bash-cap" grep -qF -- "--bash-cap" "$OUT"

# ---- S. the compact-now trigger: env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE in the PROJECT's .claude/settings.local.json, armed for a few minutes, put back by itself -------------------
echo "S. the compact-now trigger"
CCV="2.1.330"
newp()   { new_home; PROJ="$H/proj"; PL="$PROJ/.claude/settings.local.json"; mkdir -p "$PROJ"; git -c init.defaultBranch=main -C "$PROJ" init -q; }   # a scratch home and a scratch git work tree to arm; PL is the file the trigger arms
putl()   { mkdir -p "$PROJ/.claude"; printf '%s' "$1" >"$PL"; }                                                                                   # the project's local settings file as the person left it
putf()   { mkdir -p "$PROJ/.claude"; printf "$1" >"$PL"; }                                                                                        # ... from a printf format
inproj() { ( cd "$PROJ" && "$@" ); }                                                                                                              # run as a session that sits in the project does
cwt()    { inproj scrub env HEIMDALL_COMPACT_NOW_CC_VERSION="$CCV" HEIMDALL_COMPACT_NOW_NO_TIMER=1 "$CW" "$@" </dev/null >"$OUT" 2>"$ERR"; RC=$?; }   # a Claude Code that takes the override back, and no expiry timer
cwptyt() { local a="$1"; shift; inproj scrub env HEIMDALL_COMPACT_NOW_CC_VERSION="$CCV" HEIMDALL_COMPACT_NOW_NO_TIMER=1 "$PY" -I "$TMP/pty_drive.py" "$a" -- "$CW" "$@" >"$OUT" 2>"$ERR"; RC=$?; }
cwx()    { inproj scrub env HEIMDALL_COMPACT_NOW_NO_TIMER=1 CLAUDE_CODE_EXECPATH="$1" "$CW" on --compact-now --yes </dev/null >"$OUT" 2>"$ERR"; RC=$?; }   # no seam: the version is read from the running binary
cwp()    { inproj scrub "$CW" "$@" </dev/null >"$OUT" 2>"$ERR"; RC=$?; }                                                                          # no seam, in the project
tval()   { "$PY" -I -c 'import json,sys
try:
    e = json.load(open(sys.argv[1])).get("env")
except OSError:
    e = None
print(json.dumps(e["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"]) if isinstance(e, dict) and "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" in e else "ABSENT")' "$PL"; }
hasenv() { "$PY" -I -c 'import json,sys; print("env" in json.load(open(sys.argv[1])))' "$PL"; }
trec()   { find "$H/.heimdall/compact-window" -type f -name '*.compact-now.state.json' 2>/dev/null | head -n 1; }
tbak()   { find "$H/.heimdall/compact-window" -type f -name '*.compact-now.settings.json.bak' 2>/dev/null | head -n 1; }
tstate() { find "$H/.heimdall/compact-window" -type f \( -name '*.compact-now.state.json' -o -name '*.compact-now.settings.json.bak' \) 2>/dev/null | wc -l | tr -d ' '; }   # the trigger's records and backups
rfield() { "$PY" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$(trec)" "$1"; }
consented() { ls "$H/.heimdall/compact-window"/*.compact-now.consent >/dev/null 2>&1; }                                                          # a yes is kept, for some project
nconsent()  { ls "$H/.heimdall/compact-window"/*.compact-now.consent 2>/dev/null | wc -l | tr -d ' '; }                                           # how many projects have one
yn()     { if "$@"; then echo yes; else echo no; fi; }
nbytes() { wc -c <"$1" | tr -d ' '; }

# S0. the contracts of the review finding: the trigger arms the PROJECT's local file and never the user-level one; a tracked file is refused; release restores the project file byte for byte; the user settings are never touched
newp; putl "$PRETTY"; cp "$PL" "$TMP/orig"; printf '%s' "$COMPACT" >"$S"; cp "$S" "$TMP/user-orig"
cwt on --compact-now --yes
eq "S0: on --compact-now arms the PROJECT's .claude/settings.local.json: exit 0, the value is the JSON string \"1\"" '0|"1"' "$RC|$(tval)"
chk "S0: ...the user-level settings.json is untouched, byte for byte: it is not the file the trigger arms" same "$S" "$TMP/user-orig"
eq "S0: ...the record names the project's file, and the backup is that file as it was" "yes|yes" "$(yn grep -q "\"settings\": \"$PL\"" "$(trec)")|$(yn same "$(tbak)" "$TMP/orig")"
cwt release
eq "S0: release restores the project's file byte for byte, and the record and the backup are gone" "0|yes|0" "$RC|$(yn same "$PL" "$TMP/orig")|$(tstate)"
chk "S0: ...and the user-level settings.json is still untouched" same "$S" "$TMP/user-orig"
newp; putl "$PRETTY"; cp "$PL" "$TMP/orig"
git -C "$PROJ" add -f .claude/settings.local.json
git -C "$PROJ" -c user.email=t@t.t -c user.name=t -c commit.gpgsign=false commit -q --no-verify -m seed
cwt on --compact-now --yes
eq "S0: a file git tracks is the repository's text, not the person's: exit 5, the file byte for byte, no record, no yes remembered" "5|yes|0|no" "$RC|$(yn same "$PL" "$TMP/orig")|$(tstate)|$(yn consented)"
chk "S0: ...stderr says git tracks it" grep -q "git tracks" "$ERR"
newp; putl "$PRETTY"; mv "$PL" "$H/real-local.json"; ln -s "$H/real-local.json" "$PL"; cp "$H/real-local.json" "$TMP/orig"
cwt on --compact-now --yes
eq "S0: a symlinked settings.local.json is never followed: exit 5, the link and its target untouched, no record" "5|link|yes|0" "$RC|$([ -L "$PL" ] && echo link)|$(yn same "$H/real-local.json" "$TMP/orig")|$(tstate)"
chk "S0: ...stderr says it is a symbolic link" grep -q "symbolic link" "$ERR"
newp; mkdir -p "$H/real-claude"; printf '%s' "$PRETTY" >"$H/real-claude/settings.local.json"; ln -s "$H/real-claude" "$PROJ/.claude"; cp "$H/real-claude/settings.local.json" "$TMP/orig"
cwt on --compact-now --yes
eq "S0: a symlinked .claude directory is refused too: exit 5, the file it leads to untouched, no record" "5|yes|0" "$RC|$(yn same "$H/real-claude/settings.local.json" "$TMP/orig")|$(tstate)"
newp; mkdir -p "$PROJ/.claude/settings.local.json"
cwt on --compact-now --yes
eq "S0: a directory where the file belongs is not a plain file: exit 5, nothing written" "5|0" "$RC|$(tstate)"
newp; putl "$PRETTY"; ln "$PL" "$H/second-name"; cp "$PL" "$TMP/orig"
cwt on --compact-now --yes
eq "S0: a file with a second hard link is refused (the atomic replace would detach it): exit 5, untouched, no record" "5|yes|0" "$RC|$(yn same "$PL" "$TMP/orig")|$(tstate)"
new_home; mkdir -p "$H/nogit"
( cd "$H/nogit" && scrub env HEIMDALL_COMPACT_NOW_CC_VERSION="$CCV" HEIMDALL_COMPACT_NOW_NO_TIMER=1 "$CW" on --compact-now --yes ) </dev/null >"$OUT" 2>"$ERR"; RC=$?
eq "S0: no project (the working directory is no git work tree and CLAUDE_PROJECT_DIR is unset): exit 5, nothing written, no yes remembered" "5|0|no" "$RC|$(tstate)|$(yn consented)"
newp; mkdir -p "$PROJ/sub/deeper"; putl "$PRETTY"
( cd "$PROJ/sub/deeper" && scrub env HEIMDALL_COMPACT_NOW_CC_VERSION="$CCV" HEIMDALL_COMPACT_NOW_NO_TIMER=1 "$CW" on --compact-now --yes ) </dev/null >"$OUT" 2>"$ERR"; RC=$?
eq "S0: from a subdirectory the project is the top of the git work tree: its file is armed, and no .claude is made below" '0|"1"|no' "$RC|$(tval)|$(yn test -e "$PROJ/sub/deeper/.claude")"
cwt release
newp; mkdir -p "$H/other"; git -c init.defaultBranch=main -C "$H/other" init -q
( cd "$PROJ" && scrub env CLAUDE_PROJECT_DIR="$H/other" HEIMDALL_COMPACT_NOW_CC_VERSION="$CCV" HEIMDALL_COMPACT_NOW_NO_TIMER=1 "$CW" on --compact-now --yes ) </dev/null >"$OUT" 2>"$ERR"; RC=$?
eq "S0: CLAUDE_PROJECT_DIR names the project, ahead of the working directory: its file is armed, the one the shell sits in is not" "0|yes|no" "$RC|$(yn test -f "$H/other/.claude/settings.local.json")|$(yn test -e "$PL")"
( cd "$H" && scrub "$CW" release ) </dev/null >"$OUT" 2>"$ERR"; RC=$?
eq "S0: release run from another directory finds it by its record: the file hmd made, and the .claude directory it made, are gone" "0|no|no|0" "$RC|$(yn test -e "$H/other/.claude/settings.local.json")|$(yn test -d "$H/other/.claude")|$(tstate)"

# round trip inside an existing env object
newp; putl "$PRETTY"; cp "$PL" "$TMP/orig"
cwt on --compact-now --yes
eq "S1: on --compact-now --yes arms: exit 0, env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is the JSON string \"1\"" '0|"1"' "$RC|$(tval)"
chk "S1: it was appended inside the file's own env object, text-exact (1.50 and the 20-digit integer untouched)" "$PY" -I "$TMP/chk.py" armed "$TMP/orig" "$PL"
eq "S1: a record and a backup of the trigger's own are kept, and the person's yes is remembered" "2|yes" "$(tstate)|$(yn consented)"
cwt off --compact-now --yes
eq "S1: off --compact-now exits 0, the record and the backup are gone" "0|0" "$RC|$(tstate)"
chk "S1: ...and the file is back byte for byte" same "$PL" "$TMP/orig"

# other layouts: no env object, an empty one, no file at all, a .claude directory with no file, a file another tool rewrote
for layout in COMPACT TABS; do
  newp; putl "${!layout}"; cp "$PL" "$TMP/orig"
  cwt on --compact-now --yes
  eq "S2/$layout: no env object yet: it is added, with the trigger in it" '0|"1"' "$RC|$(tval)"
  chk "S2/$layout: every other member is the same, in order" env CHK_KEY=env "$PY" -I "$TMP/chk.py" others "$TMP/orig" "$PL"
  cwt off --compact-now --yes
  chk "S2/$layout: off returns the file byte for byte" same "$PL" "$TMP/orig"
done
newp; putl '{"env": {}, "x": 1}'; cp "$PL" "$TMP/orig"
cwt on --compact-now --yes
eq "S2: an empty env object takes the member" '0|"1"' "$RC|$(tval)"
cwt off --compact-now --yes
chk "S2: ...and off returns it byte for byte" same "$PL" "$TMP/orig"
newp
cwt on --compact-now --yes
eq "S2: no settings file and no .claude directory: on creates both, with only the trigger in the file" '0|"1"' "$RC|$(tval)"
cwt off --compact-now --yes
eq "S2: off removes the file hmd created, and the .claude directory it made with it" "0|no|no" "$RC|$(yn test -e "$PL")|$(yn test -d "$PROJ/.claude")"
newp; mkdir -p "$PROJ/.claude"
cwt on --compact-now --yes
cwt off --compact-now --yes
eq "S2: a .claude directory that was there stays when the file hmd made goes" "0|no|yes" "$RC|$(yn test -e "$PL")|$(yn test -d "$PROJ/.claude")"
newp; putl "$COMPACT"
cwt on --compact-now --yes
"$PY" -I "$TMP/chk.py" reserialize "$PL"
cwt off --compact-now --yes
eq "S2: the file was rewritten by another tool in between: off exits 0, the trigger is gone with the env object hmd made for it" "0|ABSENT|False" "$RC|$(tval)|$(hasenv)"
chk "S2: ...what the other tool added is kept" grep -q '"addedLater"' "$PL"
chk "S2: ...and off says only the key was reverted" grep -q "only the key was reverted" "$OUT"
newp; putl '{"env": 5}'; cp "$PL" "$TMP/orig"
cwt on --compact-now --yes
eq "S2: an env that is not an object is never touched: exit 1, the file as it was, nothing recorded" "1|yes|0" "$RC|$(yn same "$PL" "$TMP/orig")|$(tstate)"

# a value of the person's own is never replaced: in the project's file, in the settings files it outranks, in the environment
newp; putf '{\n  "env": {\n    "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "50"\n  }\n}\n'; cp "$PL" "$TMP/orig"
cwt on --compact-now --yes
eq "S3: a value of the person's own in the env block of the project's file: exit 4, the file untouched, no record, no yes remembered" "4|yes|0|no" "$RC|$(yn same "$PL" "$TMP/orig")|$(tstate)|$(yn consented)"
chk "S3: stderr says it is theirs" grep -q "your own setting" "$ERR"
cwt on --compact-now --yes --force
eq "S3: --force is not accepted with the trigger: usage error, exit 2, the file untouched" "2|yes" "$RC|$(yn same "$PL" "$TMP/orig")"
newp; putl "$COMPACT"; cp "$PL" "$TMP/orig"; printf '{\n  "env": {\n    "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "50"\n  }\n}\n' >"$S"; cp "$S" "$TMP/user-orig"
cwt on --compact-now --yes
eq "S3: a value of the person's own in the USER-level settings.json would be shadowed by the project's file: exit 4, both files untouched, no record" "4|yes|yes|0" "$RC|$(yn same "$PL" "$TMP/orig")|$(yn same "$S" "$TMP/user-orig")|$(tstate)"
chk "S3: ...stderr names the user-level file" grep -q "env block of ~/.claude/settings.json" "$ERR"
newp; putl "$COMPACT"; cp "$PL" "$TMP/orig"; printf '{"env": {"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "70"}}' >"$PROJ/.claude/settings.json"
cwt on --compact-now --yes
eq "S3: ...and in the project's shared .claude/settings.json: exit 4, the file untouched, no record" "4|yes|0" "$RC|$(yn same "$PL" "$TMP/orig")|$(tstate)"
newp; putl "$COMPACT"; cp "$PL" "$TMP/orig"
inproj scrub env CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60 HEIMDALL_COMPACT_NOW_CC_VERSION="$CCV" HEIMDALL_COMPACT_NOW_NO_TIMER=1 "$CW" on --compact-now --yes </dev/null >"$OUT" 2>"$ERR"; RC=$?
eq "S3: a CLAUDE_AUTOCOMPACT_PCT_OVERRIDE of the person's own in the environment is refused too: exit 4, untouched, nothing recorded" "4|yes|0" "$RC|$(yn same "$PL" "$TMP/orig")|$(tstate)"

# the build and automatic compaction must be able to honour it: otherwise exit 5 and nothing is written
newp; putl "$PRETTY"; cp "$PL" "$TMP/orig"
for v in 2.1.328 2.1.9 1.9.999 "" "not-a-version"; do
  CCV="$v" cwt on --compact-now --yes
  eq "S4: Claude Code [$v] cannot take the override back, or cannot be told: exit 5, nothing written, no record, no yes remembered" "5|yes|0|no" "$RC|$(yn same "$PL" "$TMP/orig")|$(tstate)|$(yn consented)"
done
CCV=2.1.328 cwt on --compact-now --yes
chk "S4: the reason names the first build that takes it back (2.1.329)" grep -qF "2.1.329" "$ERR"
for v in 2.1.329 2.1.330 2.2.0 3.0.0; do
  CCV="$v" cwt on --compact-now --yes
  eq "S4: Claude Code $v arms" '0|"1"' "$RC|$(tval)"
  cwt off --compact-now --yes
done
chk "S4: ...and each off left the file as it was" same "$PL" "$TMP/orig"
mkdir -p "$TMP/cc/versions"; : >"$TMP/cc/versions/2.1.330"
printf '#!/bin/sh\necho "2.1.327 (Claude Code)"\n' >"$TMP/cc/old"; printf '#!/bin/sh\necho "v20.11.0"\n' >"$TMP/cc/node"; printf '#!/bin/sh\necho "2.1.331 (Claude Code)"\n' >"$TMP/cc/new"
chmod +x "$TMP/cc/old" "$TMP/cc/node" "$TMP/cc/new"
newp; putl "$COMPACT"; cp "$PL" "$TMP/orig"
cwx "$TMP/cc/versions/2.1.330"
eq "S4: the running binary named by its version (the native layout), no seam: 2.1.330 arms" '0|"1"' "$RC|$(tval)"
cwt off --compact-now --yes
cwx "$TMP/cc/new"
eq "S4: any other layout is asked (--version): a binary that answers 2.1.331 (Claude Code) arms" '0|"1"' "$RC|$(tval)"
cwt off --compact-now --yes
cwx "$TMP/cc/old"
eq "S4: ...one that answers 2.1.327 is refused: exit 5, untouched" "5|yes" "$RC|$(yn same "$PL" "$TMP/orig")"
cwx "$TMP/cc/node"
eq "S4: ...one that is not claude (node answers with its own version) is refused: exit 5" 5 "$RC"
cwx "relative/claude"
eq "S4: a CLAUDE_CODE_EXECPATH that is not absolute is refused: exit 5" 5 "$RC"
inproj scrub env HEIMDALL_COMPACT_NOW_NO_TIMER=1 "$CW" on --compact-now --yes </dev/null >"$OUT" 2>"$ERR"; RC=$?
eq "S4: no CLAUDE_CODE_EXECPATH and no seam (not inside a session; the claude on PATH may be another build, so it is not asked): exit 5, untouched" "5|yes" "$RC|$(yn same "$PL" "$TMP/orig")"
newp; putl "$COMPACT"; cp "$PL" "$TMP/orig"; printf '{\n  "autoCompactEnabled": false\n}\n' >"$S"
cwt on --compact-now --yes
eq "S4: autoCompactEnabled false in the user-level settings (automatic compaction is off for every session): exit 5, the project's file untouched, nothing recorded" "5|yes|0" "$RC|$(yn same "$PL" "$TMP/orig")|$(tstate)"
putl '{"autoCompactEnabled": true}'; cp "$PL" "$TMP/orig"
cwt on --compact-now --yes
eq "S4: ...but the project's own true outranks the user-level false (the most specific file decides): armed" '0|"1"' "$RC|$(tval)"
cwt off --compact-now --yes
chk "S4: ...and off returns the project's file byte for byte" same "$PL" "$TMP/orig"
putl '{"autoCompactEnabled": false}'; cp "$PL" "$TMP/orig"; rm -f "$S"
cwt on --compact-now --yes
eq "S4: autoCompactEnabled false in the project's own file: exit 5, untouched, nothing recorded" "5|yes|0" "$RC|$(yn same "$PL" "$TMP/orig")|$(tstate)"
newp; putl "$COMPACT"; cp "$PL" "$TMP/orig"; printf '{"autoCompactEnabled": false}' >"$PROJ/.claude/settings.json"
cwt on --compact-now --yes
eq "S4: autoCompactEnabled false in the project's shared .claude/settings.json: exit 5, untouched, nothing recorded" "5|yes|0" "$RC|$(yn same "$PL" "$TMP/orig")|$(tstate)"
newp; putl "$COMPACT"; cp "$PL" "$TMP/orig"
for name in DISABLE_AUTO_COMPACT DISABLE_COMPACT; do
  inproj scrub env "$name=1" HEIMDALL_COMPACT_NOW_CC_VERSION="$CCV" HEIMDALL_COMPACT_NOW_NO_TIMER=1 "$CW" on --compact-now --yes </dev/null >"$OUT" 2>"$ERR"; RC=$?
  eq "S4: $name=1 in the environment (automatic compaction is off): exit 5, untouched" "5|yes" "$RC|$(yn same "$PL" "$TMP/orig")"
done

# consent: asked once, per repository
newp; putl "$PRETTY"; cp "$PL" "$TMP/orig"
cwt on --compact-now
eq "S5: no terminal, no --yes and no earlier yes: exit 3, the file untouched, nothing recorded" "3|yes|0|no" "$RC|$(yn same "$PL" "$TMP/orig")|$(tstate)|$(yn consented)"
chk "S5: stderr gives the command to run again with --yes" grep -qF "on --compact-now --yes" "$ERR"
cwt on --compact-now --yes
cwt off --compact-now --yes
cwt on --compact-now
eq "S5: once a yes was given in this project, the next arm needs no --yes: exit 0, armed" '0|"1"' "$RC|$(tval)"
cwt off --compact-now --yes
newp; putl "$PRETTY"; PROJA="$PROJ"; PLA="$PL"
cwt on --compact-now --yes
cwt off --compact-now --yes
PROJ="$H/projb"; PL="$PROJ/.claude/settings.local.json"; mkdir -p "$PROJ"; git -c init.defaultBranch=main -C "$PROJ" init -q; putl "$PRETTY"; cp "$PL" "$TMP/orig"
cwt on --compact-now
eq "S5: a yes given in one repository arms no other: project B asks again (exit 3), its file untouched, nothing recorded" "3|yes|0" "$RC|$(yn same "$PL" "$TMP/orig")|$(tstate)"
cwt on --compact-now --yes
cwt off --compact-now --yes
eq "S5: two projects, two yes stamps" 2 "$(nconsent)"
cwt revoke
eq "S5: revoke, run inside B, forgets B's yes only: exit 0, one stamp is left" "0|1" "$RC|$(nconsent)"
cwt on --compact-now
eq "S5: ...B asks again (exit 3)" 3 "$RC"
PROJ="$PROJA"; PL="$PLA"
cwt on --compact-now
eq "S5: ...and A, whose yes stands, arms without --yes" '0|"1"' "$RC|$(tval)"
cwt off --compact-now --yes
newp; putl "$COMPACT"; cp "$PL" "$TMP/orig"
cwptyt y on --compact-now
eq "S5: a person at a terminal who says yes: armed, and the yes is remembered" '0|"1"|yes' "$RC|$(tval)|$(yn consented)"
cwt off --compact-now --yes
newp; putl "$COMPACT"; cp "$PL" "$TMP/orig"
cwptyt n on --compact-now
eq "S5: a person at a terminal who says no: exit 3, untouched, no yes remembered" "3|yes|no" "$RC|$(yn same "$PL" "$TMP/orig")|$(yn consented)"
newp; putl "$COMPACT"
cwt on --compact-now --yes
cwt revoke
eq "S5: revoke also puts an armed trigger back" "0|ABSENT|0" "$RC|$(tval)|$(tstate)"
new_home; mkdir -p "$H/nogit"
( cd "$H/nogit" && scrub "$CW" revoke ) </dev/null >"$OUT" 2>"$ERR"; RC=$?
eq "S5: revoke outside any project forgets nothing and says so: exit 2" "2|1" "$RC|$(grep -c 'Nothing was forgotten' "$ERR")"

# release: what the hooks run
newp; putl "$PRETTY"; cp "$PL" "$TMP/orig"
cwt on --compact-now --yes
cwt release
eq "S6: release exits 0 and prints nothing on stdout (a SessionStart hook's stdout reaches the model)" "0|0" "$RC|$(nbytes "$OUT")"
chk "S6: ...the file is back byte for byte" same "$PL" "$TMP/orig"
eq "S6: ...the record and the backup are gone" 0 "$(tstate)"
cwt release
eq "S6: a second release is a quiet no-op" "0|0|0" "$RC|$(nbytes "$OUT")|$(nbytes "$ERR")"
cwt on --compact-now
sed -i.bak 's/"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "1"/"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "7"/' "$PL" && rm -f "$PL.bak"
cwt release
eq "S6: a value the person changed meanwhile is theirs: release leaves it and clears the record" '0|"7"|0' "$RC|$(tval)|$(tstate)"
newp; putl "$PRETTY"; cp "$PL" "$TMP/orig"; PROJA="$PROJ"; PLA="$PL"
PROJ="$H/projb"; PL="$PROJ/.claude/settings.local.json"; mkdir -p "$PROJ"; git -c init.defaultBranch=main -C "$PROJ" init -q; putl "$COMPACT"; cp "$PL" "$TMP/origb"
cwt on --compact-now --yes
PROJ="$PROJA"; PL="$PLA"
cwt on --compact-now --yes
eq "S6: the trigger armed in two projects: a record and a backup for each" 4 "$(tstate)"
cwt release
eq "S6: one release puts every armed trigger back, in each project: both files byte for byte, no record left" "0|yes|yes|0" "$RC|$(yn same "$PL" "$TMP/orig")|$(yn same "$H/projb/.claude/settings.local.json" "$TMP/origb")|$(tstate)"

# expiry: nothing compacted and no hook ran
newp; putl "$PRETTY"; cp "$PL" "$TMP/orig"
inproj scrub env HEIMDALL_COMPACT_NOW_CC_VERSION="$CCV" HEIMDALL_COMPACT_NOW_TTL_S=1 "$CW" on --compact-now --yes </dev/null >"$OUT" 2>"$ERR"; RC=$?
eq "S7: armed with a one-second life (the timer left running): exit 0 and says so (the file is not read back: on a loaded machine the timer may already have run)" "0|1" "$RC|$(grep -c '^armed: ' "$OUT")"
for _ in $(seq 1 150); do [ "$(tval)" = ABSENT ] && [ "$(tstate)" = 0 ] && break; sleep 0.2; done
eq "S7: nobody compacted and no hook ran: the expiry timer put the file back by itself, byte for byte" "ABSENT|yes|0" "$(tval)|$(yn same "$PL" "$TMP/orig")|$(tstate)"
newp; putl "$PRETTY"
cwt on --compact-now --yes
cwp status
eq "S7: status names the project's file, says hmd armed it and when it expires" "1|1|1" "$(grep -c '^project .*\.claude/settings\.local\.json' "$OUT")|$(grep '^trigger' "$OUT" | grep -c 'set by hmd')|$(grep '^trigger' "$OUT" | grep -c 'expires at')"
"$PY" -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["expires_at"]=1; json.dump(d, open(p,"w"))' "$(trec)"
cwp status
eq "S7: an arming whose time is up says EXPIRED in status" 1 "$(grep '^trigger' "$OUT" | grep -c 'EXPIRED')"
cwt release
eq "S7: ...and release puts it back all the same" "0|ABSENT|0" "$RC|$(tval)|$(tstate)"
cw status
eq "S7: status outside any project says there is none, and that nothing is armed here" "1|1" "$(grep -c '^project .*none found' "$OUT")|$(grep '^trigger' "$OUT" | grep -c 'not armed here')"
newp; putl "$PRETTY"; cp "$PL" "$TMP/orig"
cwt on --compact-now --yes
FIRST_ARM="$(rfield arm_id)"
cwt on --compact-now
eq "S7: arming twice: exit 0, one record and one backup, a new arming id" "0|2|yes" "$RC|$(tstate)|$([ "$FIRST_ARM" != "$(rfield arm_id)" ] && echo yes || echo no)"
cwt off --compact-now --yes
chk "S7: ...and off returns the very first file byte for byte" same "$PL" "$TMP/orig"

# the window (user-level) and the trigger (project) in their own files, in either order
newp; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/user-orig"; putl "$COMPACT"; cp "$PL" "$TMP/orig"
cw on --yes; cwt on --compact-now --yes
eq "S8: the window is in the user-level file and the trigger in the project's: each set in its own" '300000|"1"' "$(value)|$(tval)"
cwt release
eq "S8: release puts only the trigger back: the window stays" '300000|ABSENT' "$(value)|$(tval)"
cw off --yes
chk "S8: ...and the window's off then returns the user-level file as it was" same "$S" "$TMP/user-orig"
chk "S8: ...the project's file was never the window's: byte for byte too" same "$PL" "$TMP/orig"
newp; printf '%s' "$PRETTY" >"$S"; cp "$S" "$TMP/user-orig"; putl "$COMPACT"; cp "$PL" "$TMP/orig"
cw on --yes; cwt on --compact-now --yes; cw off --yes
eq "S8: the window off first while the trigger is armed: the trigger stays" 'ABSENT|"1"' "$(value)|$(tval)"
cwt release
chk "S8: ...and release then leaves the project's file as it was" same "$PL" "$TMP/orig"
chk "S8: ...and the user-level file as it was" same "$S" "$TMP/user-orig"

# the real hook commands from hooks.json
"$PY" -I - "$REPO/hooks/hooks.json" "$REPO/hooks/hooks.metadata.json" "$TMP" >"$TMP/hookinfo" 2>&1 <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
meta = dict((e["id"], e) for e in json.load(open(sys.argv[2]))["hooks"])
errs = []
for hid, event in (("compact-now-release-start", "SessionStart"), ("compact-now-release-precompact", "PreCompact")):
    entry = meta.get(hid)
    if entry is None:
        errs.append("hooks.metadata.json has no hook %s" % hid)
        continue
    group = hooks[entry["event"]][entry["index"]]
    cmd = group["hooks"][0]["command"]
    open("%s/%s.cmd" % (sys.argv[3], hid), "w").write(cmd)
    if entry["event"] != event:
        errs.append("%s is %s, want %s" % (hid, entry["event"], event))
    if group.get("matcher"):
        errs.append("%s has the matcher %r: it must fire for every %s" % (hid, group.get("matcher"), event))
    if entry.get("locked") is not False:
        errs.append("%s is locked: the operator could not switch it off" % hid)
    if "hmd_hook_enabled %s" % hid not in cmd:
        errs.append("%s is not gated by hmd_hook_enabled" % hid)
    if "bin/heimdall-compact-window" not in cmd or " release" not in cmd:
        errs.append("%s does not run heimdall-compact-window release" % hid)
    if not cmd.rstrip().endswith("exit 0") or "set -e" in cmd:
        errs.append("%s does not end in exit 0 (a hook that can fail the session start or the compaction)" % hid)
    if not isinstance(group["hooks"][0].get("timeout"), int):
        errs.append("%s sets no timeout" % hid)
print("OK" if not errs else "; ".join(errs))
PY
eq "S9: hooks.json carries both release hooks (SessionStart for every source, PreCompact): advisory, gated by hmd_hook_enabled, fail-open, with a timeout" "OK" "$(cat "$TMP/hookinfo")"
runhook() {   # ID PAYLOAD: the command from hooks.json as Claude Code runs it (the payload on stdin, the plugin root in the environment)
  printf '%s' "$2" | scrub env CLAUDE_PLUGIN_ROOT="$REPO" sh -c "$(cat "$TMP/$1.cmd")" >"$OUT" 2>"$ERR"; RC=$?
}
for src in startup resume clear compact; do
  newp; putl "$PRETTY"; cp "$PL" "$TMP/orig"
  cwt on --compact-now --yes
  runhook compact-now-release-start "{\"hook_event_name\":\"SessionStart\",\"source\":\"$src\"}"
  eq "S9: a SessionStart ($src) puts the trigger back: exit 0, nothing on stdout, the project's file byte for byte, the record gone" "0|0|yes|0" "$RC|$(nbytes "$OUT")|$(yn same "$PL" "$TMP/orig")|$(tstate)"
done
newp; putl "$PRETTY"; cp "$PL" "$TMP/orig"
cwt on --compact-now --yes
runhook compact-now-release-precompact '{"hook_event_name":"PreCompact","trigger":"auto"}'
eq "S9: a PreCompact (before the summary is written) puts it back: exit 0, nothing on stdout, the project's file byte for byte" "0|0|yes|0" "$RC|$(nbytes "$OUT")|$(yn same "$PL" "$TMP/orig")|$(tstate)"
runhook compact-now-release-start '{"hook_event_name":"SessionStart","source":"startup"}'
eq "S9: a hook with nothing armed is a quiet no-op" "0|0|0" "$RC|$(nbytes "$OUT")|$(nbytes "$ERR")"
newp; putl "$PRETTY"
cwt on --compact-now --yes
printf 'compact-now-release-start\n' >"$H/.heimdall/hooks-disabled"
runhook compact-now-release-start '{"hook_event_name":"SessionStart","source":"startup"}'
eq "S9: the operator's switch (heimdall-hooks disable) is honoured: the hook does nothing, the trigger stays armed" '0|"1"' "$RC|$(tval)"
cwt off --compact-now --yes

cw --help
chk "S10: --help documents --compact-now, release and revoke" sh -c "grep -qF -- '--compact-now' '$OUT' && grep -qF 'release' '$OUT' && grep -qF 'revoke' '$OUT'"
chk "S10: --help says the trigger lives in the project's .claude/settings.local.json" grep -qF -- ".claude/settings.local.json" "$OUT"
newp; putl "$PRETTY"
cwt on --compact-now --yes; cwp status
eq "S10: status after a yes: the consent row says it was given, the window row says nothing of hmd" "1|0" "$(grep '^consent' "$OUT" | grep -c 'given')|$(grep '^window' "$OUT" | grep -c 'set by hmd')"
cwt off --compact-now --yes

# S11. the expiry check, for the day the timer died and no session starts: `release-expired` (what the compact-now-expiry-prompt hook on UserPromptSubmit and the compact-now-expiry-stop hook on Stop run) puts back every arming whose time is
# over, and only those; it never fails the hook that runs it
recset() {   # FIELD JSON [SETTINGS]: set FIELD of the record that arms SETTINGS (the first record when none is named) to the JSON value, or remove it when the value is -
  "$PY" -I -c 'import glob, json, os, sys
directory, field, value, wanted = sys.argv[1], sys.argv[2], sys.argv[3], (sys.argv[4:] or [""])[0]
for path in sorted(glob.glob(os.path.join(directory, "*.compact-now.state.json"))):
    with open(path, encoding="utf-8") as handle:
        record = json.load(handle)
    if wanted and record["settings"] != os.path.realpath(wanted):
        continue
    if value == "-":
        record.pop(field, None)
    else:
        record[field] = json.loads(value)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(record, handle)
    break' "$H/.heimdall/compact-window" "$@"
}
newp; putl "$PRETTY"; cp "$PL" "$TMP/orig"
cwt on --compact-now --yes
cwt release-expired
eq "S11: an arming still inside its time stays armed: exit 0, nothing on stdout or stderr, the trigger still \"1\", the record and the backup kept" '0|0|0|"1"|2' "$RC|$(nbytes "$OUT")|$(nbytes "$ERR")|$(tval)|$(tstate)"
recset expires_at 1
cw release-expired
eq "S11: the same arming once its time is up is put back, from a directory in no project: exit 0, nothing on stdout, the project's file byte for byte, the record and the backup gone" "0|0|yes|0" "$RC|$(nbytes "$OUT")|$(yn same "$PL" "$TMP/orig")|$(tstate)"
cwt release-expired
eq "S11: ...and the next check has nothing to do: a quiet no-op" "0|0|0" "$RC|$(nbytes "$OUT")|$(nbytes "$ERR")"
newp; putl "$PRETTY"; cp "$PL" "$TMP/orig"
cwt release-expired
eq "S11: nothing was ever armed (no state directory yet): exit 0, no output at all, the project's file untouched" "0|0|0|yes" "$RC|$(nbytes "$OUT")|$(nbytes "$ERR")|$(yn same "$PL" "$TMP/orig")"
newp; putl "$PRETTY"; cp "$PL" "$TMP/orig"; PROJA="$PROJ"; PLA="$PL"
PROJ="$H/projb"; PL="$PROJ/.claude/settings.local.json"; PLB="$PL"; mkdir -p "$PROJ"; git -c init.defaultBranch=main -C "$PROJ" init -q; putl "$COMPACT"
cwt on --compact-now --yes
PROJ="$PROJA"; PL="$PLA"
cwt on --compact-now --yes
recset expires_at 1 "$PLA"
cw release-expired
eq "S11: two projects armed, one past its time: that one is put back byte for byte and the other stays armed (the time is judged per arming)" "0|yes|\"1\"|2" "$RC|$(yn same "$PLA" "$TMP/orig")|$(PL="$PLB" tval)|$(tstate)"
newp; putl "$PRETTY"; cp "$PL" "$TMP/orig"
cwt on --compact-now --yes
recset expires_at '"soon"'
cwt release-expired
eq "S11: a record whose expiry is no number cannot show it is inside its time, so it counts as over: put back, byte for byte" "0|0|yes|0" "$RC|$(nbytes "$OUT")|$(yn same "$PL" "$TMP/orig")|$(tstate)"
cwt on --compact-now --yes
recset expires_at -
cwt release-expired
eq "S11: ...and so does a record with no expiry at all" "0|0|yes|0" "$RC|$(nbytes "$OUT")|$(yn same "$PL" "$TMP/orig")|$(tstate)"
newp; putl "$PRETTY"
cwt on --compact-now --yes
sed -i.bak 's/"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "1"/"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "7"/' "$PL" && rm -f "$PL.bak"
recset expires_at 1
cwt release-expired
eq "S11: a value the person changed meanwhile is theirs: the check leaves it and clears the record, as release does" '0|"7"|0' "$RC|$(tval)|$(tstate)"
newp; putl "$PRETTY"
cwt on --compact-now --yes
recset expires_at 1
cwt on --compact-now
cwt release-expired
eq "S11: arming again gives the arming a new time: the check judges the arming that stands, not the first one" '0|"1"|2' "$RC|$(tval)|$(tstate)"
newp; putl "$PRETTY"
cwt on --compact-now --yes
printf 'not json at all' >"$(trec)"
cwt release-expired
eq "S11: a record that is not JSON is skipped, as release skips it: exit 0, nothing on stdout or stderr, the project's file left armed, the record left as it is" '0|0|0|"1"|not json at all' "$RC|$(nbytes "$OUT")|$(nbytes "$ERR")|$(tval)|$(cat "$(trec)")"
newp; putl "$PRETTY"
cwt on --compact-now --yes
recset had_file -
recset expires_at 1
cwt release-expired
eq "S11: an expired record that cannot be used (a field is missing): exit 0, nothing on stdout, ONE line on stderr, the project's file and the record left as they are" '0|0|1|"1"|yes' "$RC|$(nbytes "$OUT")|$(grep -c '' "$ERR")|$(tval)|$(yn test -f "$(trec)")"

# the real hook commands from hooks.json
"$PY" -I - "$REPO/hooks/hooks.json" "$REPO/hooks/hooks.metadata.json" "$TMP" >"$TMP/hookinfo2" 2>&1 <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
meta = dict((e["id"], e) for e in json.load(open(sys.argv[2]))["hooks"])
errs = []
for hid, event in (("compact-now-expiry-prompt", "UserPromptSubmit"), ("compact-now-expiry-stop", "Stop")):
    entry = meta.get(hid)
    if entry is None:
        errs.append("hooks.metadata.json has no hook %s" % hid)
        continue
    group = hooks[entry["event"]][entry["index"]]
    cmd = group["hooks"][0]["command"]
    open("%s/%s.cmd" % (sys.argv[3], hid), "w").write(cmd)
    if entry["event"] != event:
        errs.append("%s is %s, want %s" % (hid, entry["event"], event))
    if group.get("matcher"):
        errs.append("%s has the matcher %r: it must fire for every %s" % (hid, group.get("matcher"), event))
    if entry.get("locked") is not False:
        errs.append("%s is locked: the operator could not switch it off" % hid)
    if "hmd_hook_enabled %s" % hid not in cmd:
        errs.append("%s is not gated by hmd_hook_enabled" % hid)
    if "bin/heimdall-compact-window" not in cmd or '"$HOOK" release-expired >/dev/null' not in cmd:
        errs.append("%s does not run heimdall-compact-window release-expired with its stdout cut off (a UserPromptSubmit hook's stdout reaches the model)" % hid)
    if not cmd.rstrip().endswith("exit 0") or "set -e" in cmd:
        errs.append("%s does not end in exit 0 (a hook that can fail the prompt or the turn's end)" % hid)
    if not isinstance(group["hooks"][0].get("timeout"), int):
        errs.append("%s sets no timeout" % hid)
print("OK" if not errs else "; ".join(errs))
PY
eq "S11: hooks.json carries the expiry check on UserPromptSubmit and on Stop: advisory, gated by hmd_hook_enabled, stdout cut off, fail-open, with a timeout" "OK" "$(cat "$TMP/hookinfo2")"
UPS='{"hook_event_name":"UserPromptSubmit","prompt":"carry on"}'; STP='{"hook_event_name":"Stop","stop_hook_active":false}'
newp; putl "$PRETTY"; cp "$PL" "$TMP/orig"
cwt on --compact-now --yes
runhook compact-now-expiry-prompt "$UPS"
eq "S11: the UserPromptSubmit hook leaves an arming still inside its time armed: exit 0, nothing on stdout or stderr" '0|0|0|"1"' "$RC|$(nbytes "$OUT")|$(nbytes "$ERR")|$(tval)"
recset expires_at 1
runhook compact-now-expiry-prompt "$UPS"
eq "S11: ...and puts one whose time is up back before the request goes out: exit 0, nothing on stdout (it would reach the model), the project's file byte for byte, the record gone" "0|0|yes|0" "$RC|$(nbytes "$OUT")|$(yn same "$PL" "$TMP/orig")|$(tstate)"
runhook compact-now-expiry-prompt "$UPS"
eq "S11: ...with nothing armed it is a quiet no-op" "0|0|0" "$RC|$(nbytes "$OUT")|$(nbytes "$ERR")"
cwt on --compact-now --yes
recset expires_at 1
printf 'compact-now-expiry-prompt\n' >"$H/.heimdall/hooks-disabled"
runhook compact-now-expiry-prompt "$UPS"
eq "S11: the operator's switch (heimdall-hooks disable) is honoured: the UserPromptSubmit hook puts nothing back" '0|"1"' "$RC|$(tval)"
runhook compact-now-expiry-stop "$STP"
eq "S11: ...and it switches off only that hook: the Stop one still puts the expired arming back, exit 0, nothing on stdout, the file byte for byte, the record gone" "0|0|yes|0" "$RC|$(nbytes "$OUT")|$(yn same "$PL" "$TMP/orig")|$(tstate)"
cwt on --compact-now --yes
recset expires_at 1
printf 'compact-now-expiry-stop\n' >"$H/.heimdall/hooks-disabled"
runhook compact-now-expiry-stop "$STP"
eq "S11: the Stop hook has a switch of its own: with it off nothing is put back" '0|"1"' "$RC|$(tval)"
rm -f "$H/.heimdall/hooks-disabled"
mkdir -p "$TMP/emptyroot"
printf '%s' "$UPS" | scrub env CLAUDE_PLUGIN_ROOT="$TMP/emptyroot" sh -c "$(cat "$TMP/compact-now-expiry-prompt.cmd")" >"$OUT" 2>"$ERR"; RC=$?
eq "S11: a hook that cannot find the tool (a stale plugin root) while something is armed: exit 0, nothing on stdout, ONE line on stderr, nothing changed" '0|0|1|"1"' "$RC|$(nbytes "$OUT")|$(grep -c '' "$ERR")|$(tval)"
printf 'garbage' >"$(trec)"
runhook compact-now-expiry-prompt "$UPS"
eq "S11: a broken record: the hook still exits 0, with nothing on stdout or stderr" "0|0|0" "$RC|$(nbytes "$OUT")|$(nbytes "$ERR")"

echo
echo "compact-window: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
