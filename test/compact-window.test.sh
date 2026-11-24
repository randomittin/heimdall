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
#
# HERMETIC. HOME, HEIMDALL_HOME and the settings file are throwaway for every scenario; CLAUDE_CONFIG_DIR is unset; nothing reads or writes the operator's ~/.claude
# or ~/.heimdall. CW_BIN=<file> points the suite at another copy of the tool (a mutant, for the break-it check).
# budget: about 12 s solo: roughly 170 starts of one python script, a dozen of them on a pty, one on a pty that waits out the 1 s seam. No network.
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
OUT="$TMP/out"; ERR="$TMP/err"; : >"$OUT"; : >"$ERR"
[ -x "$CW" ] || { bad "the tool is executable: $CW"; exit 1; }

cat >"$TMP/chk.py" <<'PYEOF'
import json, sys
KEY = "autoCompactWindow"
def pairs(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh, object_pairs_hook=list)
cmd, args = sys.argv[1], sys.argv[2:]
if cmd == "value":      # the key's value as JSON, or ABSENT
    found = [json.dumps(v) for k, v in pairs(args[0]) if k == KEY]
    print(found[0] if found else "ABSENT")
elif cmd == "others":   # every other member, in order, at every level, is the same in both files
    sys.exit(0 if [p for p in pairs(args[0]) if p[0] != KEY] == [p for p in pairs(args[1]) if p[0] != KEY] else 1)
elif cmd == "added":    # the pretty fixture plus the key, as text: one member appended before the closing brace, nothing else moved
    old, new = open(args[0], encoding="utf-8").read(), open(args[1], encoding="utf-8").read()
    sys.exit(0 if new == old[:-len("\n}\n")] + ',\n  "' + KEY + '": 300000' + "\n}\n" else 1)
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
scrub() { env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u HEIMDALL_NO_COMPACT_WINDOW_OFFER HOME="$H" HEIMDALL_HOME="$H/.heimdall" "$@"; }
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

echo
echo "compact-window: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
