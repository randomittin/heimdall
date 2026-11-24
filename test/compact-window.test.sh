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
#
# HERMETIC. HOME, HEIMDALL_HOME and the settings file are throwaway for every scenario; CLAUDE_CONFIG_DIR is unset; nothing reads or writes the operator's ~/.claude
# or ~/.heimdall. CW_BIN=<file> points the suite at another copy of the tool (a mutant, for the break-it check).
# budget: about 10 s solo: roughly 120 starts of one python script, a dozen of them on a pty. No network.
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
"$PY" -I -c 'import pty; pty.openpty()' >/dev/null 2>&1 || { echo "no pseudo-terminal can be opened here: the terminal cases cannot run"; exit 1; }

H=""; S=""; N=0
new_home() { N=$((N + 1)); H="$TMP/h$N"; mkdir -p "$H/.claude" "$H/.heimdall"; S="$H/.claude/settings.json"; }
scrub() { env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u HEIMDALL_NO_COMPACT_WINDOW_OFFER HOME="$H" HEIMDALL_HOME="$H/.heimdall" "$@"; }
cw()    { scrub "$CW" "$@" </dev/null >"$OUT" 2>"$ERR"; RC=$?; }                                 # no terminal
cwpty() { local a="$1"; shift; scrub "$PY" -I "$TMP/pty_drive.py" "$a" -- "$CW" "$@" >"$OUT" 2>"$ERR"; RC=$?; }   # a person at a terminal who types $a
value() { "$PY" -I "$TMP/chk.py" value "$S"; }
state() { ls "$H/.heimdall/compact-window" 2>/dev/null | grep -c -E '^(state.json|settings.json.bak)$'; }
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
  same "$H/.heimdall/compact-window/settings.json.bak" "$TMP/orig"; chk "A/$layout: the backup is the file as it was, byte for byte" test "$?" = 0
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

echo
echo "compact-window: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
