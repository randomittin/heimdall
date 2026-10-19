#!/usr/bin/env bash
# test/companion-attach.test.sh -- the phone attaches a picture to a message: hmd answers `attach-v1`.
#
# The phone half is hmdapp's src/attach (docs/HANDOFF-TO-HEIMDALL-cursor-parity.md CP6; asked for again in docs/HANDOFF-TO-HEIMDALL-chat-replies.md
# section A). The wire under test, through the REAL bin/heimdall-relay-client against test/lib/fake-relay.py (a hermetic stand-in for the
# relay; test/lib/view_phone.py plays the paired phone and seals with the real bin/lib/hmd_relay_e2e.py -- nothing about the client is mocked,
# and no case imports the client or bin/lib/companion_attach.py; the few that must see inside one call -- a decode that never ran, a write that
# never started, a link on the way down -- run the dispatcher by path in a fresh interpreter: test/lib/attach_inproc.py):
#     cap      attach-v1 in every state frame's caps -- and NOT required in the phone's own resync (the shipped app never lists it)
#     command  {"action":"attach-begin","params":{"rid","name","mime","bytes","w","h","n","sha256"}}   ack {id: att-<8 hex>, result: {chunk_max}}
#              {"action":"attach-chunk","params":{"rid","id","idx","b64"}}                              ack {}
#              {"action":"attach-commit","params":{"rid","id","message"?,"pin"?}}                      ack {id: <inbox record id>, result: {queued}}
#     answer   <repo>/.heimdall/app/attachments/<id>.jpg|png (0600, dir 0700) and ONE inbox record naming that path, which
#              bin/heimdall-inbox-deliver hands to the Claude session behind its provenance marker
#
# What it proves (the cases live in test/lib/attach_scenarios.py, one group per concern):
#   wire     the cap, the three ack shapes, a phone that never listed attach-v1 can attach, begin de-duplicated on its rid -- and a rid ANOTHER
#            action used is not a replay
#   happy    two chunks (256 KiB + the rest) -> the file, its modes, its sha256, the inbox record, the delivered text with the marker; the path in no
#            frame, event, log or audit line; Exif/GPS/XMP/IPTC/comment/thumbnail stripped from a JPEG and eXIf/text/time from a PNG; the size in the
#            line from the file (and equal to the phone's); a hostile `name` ("../../x") never part of any path; a masked secret; stripped escapes;
#            the pin; the note and the pin's note QUOTED as JSON strings on lines of their own, so a note cannot forge a second hmd-looking
#            '[image attached: ...]' line
#   max      exactly 2 MiB in 8 chunks (~3.7 MB of sealed frames on ONE stream connection) through the real client, on the NDJSON leg
#            (max) and on the WebSocket leg the hosted relay speaks (maxws): the client's per-connection byte cap must not drop the stream
#            on the phone's own authenticated frames
#   refuse   bad mime, oversize, 9 chunks, every malformed param, an id that is not att-<8 hex>, a wrong-size, over-long or malformed chunk, a
#            replayed chunk, out-of-order chunks, a missing chunk (incomplete: the upload stays open), a commit replayed, a magic mismatch, a sha
#            mismatch, a corrupted chunk, a cut JPEG, a bad PNG checksum, a frame header that says 9000x9000, a declared size that is not the
#            file's (also swapped sides), a 42-megapixel PNG bomb at begin and at commit, the 40-megapixel boundary, a note one character over
#            what the record holds (refused BEFORE the file is written) and one at the limit -- and after every refusal nothing stored and
#            nothing queued
#   gate     the kill switch (controls-off), an attachments directory, `.heimdall/app` or `.heimdall` that is a symlink (refused, nothing
#            written outside, the sweep does not follow it either), a directory another account owns (refused before any chmod), the direct
#            route (not-implemented), controls.actions
#   keep     the 20 newest and 24 h, a symlink removed as a link, a stranger's file untouched, the sweep when the client starts, and a picture
#            whose inbox record is still waiting kept past both limits until the record is delivered
#   off      HMD_ATTACH=0: the cap is not listed and every command is not-implemented (a phone that was not offered cannot attach)
#   rate     3 open uploads at most (too-many), then rate-limited with retry_after_s; a burst of chunks past its bucket is refused without
#            one base64 decode
# and, falsifiably, that each rule is the thing holding: a copy with one rule removed must turn its group red.
#
# Hermetic: HOME/HEIMDALL_HOME/TMPDIR are temp dirs, every process this suite starts is reaped on exit, every wait is bounded.
# It signals no process it did not start (a running relay client of the operator's is never touched).
#
# Side by side: a scenario process (a slice of the main stack, or the groups of one mutant) has its own temp tree, fake relay and relay client on
# ports the OS hands out, so none needs another; they all run in one pool of 8 (see "the pool"), longest first, and the report comes after the last.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="$REPO/bin/heimdall-relay-client"
SCEN="$REPO/test/lib/attach_scenarios.py"
MODULE="$REPO/bin/lib/companion_attach.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "companion-attach (the phone's picture: attach-v1 through the real relay client)"

for f in "$CLIENT" "$SCEN" "$MODULE" "$REPO/test/lib/attach_inproc.py" "$REPO/test/lib/view_phone.py" "$REPO/test/lib/fake-relay.py" "$REPO/bin/heimdall-inbox-deliver"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
for tool in python3 git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FATAL: required tool missing: %s\n' "$tool" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# -- the pool -------------------------------------------------------------------------------------------------------------------------
# Run one after another the cases were ~240 s for the main stack alone (the 2 MiB picture is ~100 s of pure-python seal/open on a loaded
# machine), and every mutant came after that. The slices of the main stack and the mutants need nothing from one another, so they share ONE
# pool, JOBS at a time. bash 3.2 has no `wait -n`, and waiting for "the job JOBS back" leaves every slot idle behind the first (longest) jobs,
# so a slot is a token on a FIFO: `launch` takes one (blocking while JOBS jobs run) and the job puts it back when it ends. A background job
# cannot add to PASS/FAIL itself, so it leaves its result in a file under $TMPROOT; the report, after the last job, reads those in the order the
# jobs were declared, and a job that left none is a red line, never a skipped one.
JOBS=8
mkfifo "$TMPROOT/slots" && exec 8<>"$TMPROOT/slots" || {
  printf 'FATAL: cannot make the slot pool in %s\n' "$TMPROOT" >&2
  printf '\n0 passed, 1 failed\n'
  exit 1
}
slot=0
while [ "$slot" -lt "$JOBS" ]; do
  echo >&8
  slot=$((slot + 1))
done

# launch CMD ARGS... -- CMD in the background as soon as a slot is free; the slot goes back when CMD ends, however it ends.
launch() {
  local token
  IFS= read -r -u 8 token || return 1      # no slot to be had: the job does not run, and has no result for the report to find
  ( "$@"; echo >&8 ) &
}

# slice LABEL GROUPS -- the real client's cases for GROUPS as one scenario process: its lines go to $TMPROOT/slice.LABEL.out, its exit code to
# slice.LABEL.rc. The main stack's groups (wire happy max refuse gate keep) share one paired stack when they run in one process; off, rate and
# maxws each build their own.
SLICES=()
run_slice() {
  python3 "$SCEN" --client "$CLIENT" --groups "$2" >"$TMPROOT/slice.$1.out" 2>&1
  echo "$?" >"$TMPROOT/slice.$1.rc"
}
slice() {
  SLICES+=("$1")
  launch run_slice "$1" "$2"
}

# report_slice LABEL -- print its lines as the scenario process printed them, fold its tally into ours.
report_slice() {
  local label="$1" out="$TMPROOT/slice.$1.out" rc tally p f
  rc="$(cat "$TMPROOT/slice.$1.rc" 2>/dev/null)"
  cat "$out" 2>/dev/null
  tally="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$out" 2>/dev/null | tail -1)"
  if [ -z "$tally" ]; then
    bad "$label: the scenario run produced no tally (exit ${rc:-?})"
    tail -20 "$out" 2>/dev/null
    return
  fi
  p="${tally%% passed*}"
  f="${tally##*, }"
  f="${f%% failed}"
  PASS=$((PASS + p))
  FAIL=$((FAIL + f))
}

# A copy that differs from the real tree in nothing but what a mutant changes. The client, the controls module and the attach module are real
# copies (the controls module finds its siblings -- the attach module -- beside its own real path, so it must be a copy too); everything
# else in bin/ and sentinels/ is linked to the real one. The links are made in bulk -- one `ln -s` per directory, then the three that are to be
# copies are swapped for copies -- not a `basename` and an `ln` per entry: ~430 entries took ~8 s a mutant on a loaded machine, and every
# mutant's tree was built before any scenario ran. Each step must succeed, or the mutant is not run on a half-built tree (it would "fail" for that).
mutant_tree() {
  local dir="$TMPROOT/mutant-$1"
  mkdir -p "$dir/bin" &&
    ln -s "$REPO"/bin/* "$dir/bin/" &&
    rm "$dir/bin/lib" "$dir/bin/heimdall-relay-client" &&
    mkdir "$dir/bin/lib" &&
    ln -s "$REPO"/bin/lib/* "$dir/bin/lib/" &&
    rm "$dir/bin/lib/companion_attach.py" "$dir/bin/lib/companion_ui_controls.py" &&
    cp "$CLIENT" "$dir/bin/heimdall-relay-client" &&
    cp "$MODULE" "$dir/bin/lib/companion_attach.py" &&
    cp "$REPO/bin/lib/companion_ui_controls.py" "$dir/bin/lib/companion_ui_controls.py" &&
    ln -s "$REPO/sentinels" "$dir/sentinels" &&
    printf '%s' "$dir"
}

# mutate FILE OLD NEW -- exactly one occurrence of OLD, else the mutant would be vacuous and the suite says so.
mutate() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
src = open(path, encoding="utf-8").read()
if src.count(old) != 1:
    sys.exit("mutation site found %d times, not once: %r" % (src.count(old), old))
open(path, "w", encoding="utf-8").write(src.replace(old, new))
PYEOF
}

# mutant NAME FILE-IN-TREE OLD NEW GROUPS -- the suite's own cases for GROUPS must go red on the changed copy. `mutant` starts the job in the pool
# and returns; the job builds the copy, runs a scenario process on it and writes its verdict -- two lines, ok|bad and then the message ok/bad
# prints -- to $TMPROOT/verdict.NAME, which collect_mutants reads in the order the mutants were declared (the pattern of companion-view.test.sh).
MUT_NAMES=()

run_mutant() {
  local name="$1" rel="$2" old="$3" new="$4" groups="$5" dir out="$TMPROOT/mut.$1.out" err="$TMPROOT/mut.$1.err" rc verdict="$TMPROOT/verdict.$1"
  if ! dir="$(mutant_tree "$name" 2>"$err")" || ! mutate "$dir/$rel" "$old" "$new" 2>>"$err"; then
    printf 'bad\nmutant %s could not be built: %s\n' "$name" "$(tr '\n' ' ' <"$err")" >"$verdict"
    return
  fi
  python3 "$SCEN" --client "$dir/bin/heimdall-relay-client" --groups "$groups" >"$out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ] && grep -q '^  FAIL ' "$out"; then
    printf 'ok\nmutant %s turns the suite red (%s checks failed: %s)\n' "$name" "$(grep -c '^  FAIL ' "$out")" "$(grep -m1 '^  FAIL ' "$out" | cut -c8-90)" >"$verdict"
  else
    printf 'bad\nmutant %s NOT caught (exit %s) -- the rule it removes is not what the cases test\n' "$name" "$rc" >"$verdict"
  fi
}

mutant() {
  MUT_NAMES+=("$1")
  launch run_mutant "$@"
}

collect_mutants() {
  local name kind message
  for name in "${MUT_NAMES[@]}"; do
    if [ ! -s "$TMPROOT/verdict.$name" ]; then
      bad "mutant $name left no verdict (its job died before it could write one)"
      continue
    fi
    { IFS= read -r kind; IFS= read -r message; } <"$TMPROOT/verdict.$name"
    if [ "$kind" = ok ]; then ok "$message"; else bad "$message"; fi
  done
}

# Started longest first: the pool takes the jobs in this order, so the 2 MiB picture (the max and maxws slices, and the two mutants that send it
# again) starts at once and the quick jobs fill the slots behind it. The report below prints in the same order.
slice max            max
slice refuse         refuse
slice maxws          maxws
slice happy          happy
slice wire-gate-keep wire,gate,keep
slice off-rate       off,rate
mutant stream-cap-counts-all bin/heimdall-relay-client '                    stream_total_bytes -= size' '                    stream_total_bytes -= 0' max
mutant ws-cap-counts-all  bin/heimdall-relay-client '                            ws.total_bytes = max(0, ws.total_bytes - len(event[1]))' '                            ws.total_bytes = ws.total_bytes' maxws
mutant skip-magic-check   bin/lib/companion_attach.py '    if not data.startswith(magic):' '    if False:' refuse
mutant skip-sha-check     bin/lib/companion_attach.py '    if hashlib.sha256(data).hexdigest() != up.sha:' '    if False:' refuse
mutant skip-size-cap      bin/lib/companion_attach.py '    if nbytes > MAX_BYTES:' '    if False:' refuse
mutant skip-chunk-size    bin/lib/companion_attach.py '        if idx >= up.n or len(data) != up.size_of(idx):' '        if idx >= up.n:' refuse
mutant skip-exif-strip    bin/lib/companion_attach.py '    return marker in _JPEG_STRUCTURAL' '    return True' happy
mutant skip-png-strip     bin/lib/companion_attach.py '        if kind in _PNG_KEEP:' '        if True:' happy
mutant skip-secret-mask   bin/lib/companion_attach.py '        text = rx.sub(MASK, text)' '        text = text' happy
mutant loose-file-mode    bin/lib/companion_attach.py '            os.fchmod(fd, 0o600)' '            os.fchmod(fd, 0o644)' happy
mutant loose-dir-mode     bin/lib/companion_attach.py '                os.fchmod(fd, 0o700)' '                os.fchmod(fd, 0o755)' happy
mutant no-path-in-line    bin/lib/companion_attach.py '"[image attached: %s (%dx%d)]" % (path, width, height)' '"[image attached: %s (%dx%d)]" % ("-", width, height)' happy
mutant follow-dir-symlink bin/lib/companion_attach.py '_DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW' '_DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY' gate
mutant skip-owner-check   bin/lib/companion_attach.py '        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid():' '        if False:' gate
mutant ignore-off-switch  bin/lib/companion_attach.py '        if not enabled() or ctx.caps is None:' '        if False:' off,gate
mutant keep-everything    bin/lib/companion_attach.py '            expendable = rank >= KEEP or now - mtime >= KEEP_TTL_S' '            expendable = False' keep
mutant evict-waiting      bin/lib/companion_attach.py '            if expendable and waiting is not None and name not in waiting:' '            if expendable:' keep
mutant raw-note           bin/lib/companion_attach.py '        lines.append("phone note: " + _quoted(message))' '        lines.append("phone note: " + message)' happy
mutant raw-pin-note       bin/lib/companion_attach.py '        lines.append(where + ": " + _quoted(pin["note"]) if pin["note"] else where)' '        lines.append(where + ": " + pin["note"] if pin["note"] else where)' happy
mutant no-pixel-cap-begin bin/lib/companion_attach.py '    if w * h > MAX_PIXELS:' '    if False:' refuse
mutant no-pixel-cap-commit bin/lib/companion_attach.py ' or width * height > MAX_PIXELS:' ':' refuse
mutant no-size-match      bin/lib/companion_attach.py '    if (width, height) != (up.w, up.h):' '    if False:' refuse
mutant note-after-write   bin/lib/companion_attach.py '    if len(text) > inbox.MAX_TEXT_CHARS:' '    if False:' refuse
mutant charge-after-decode bin/lib/companion_ui_controls.py '    charged = spec["policy"].get("max_bytes", MAX_COMMAND_BYTES) > LARGE_COMMAND_BYTES' '    charged = False' rate
mutant rid-without-action bin/lib/companion_ui_controls.py '        key = (action, rid)' '        key = rid' wire
mutant cap-not-listed     bin/heimdall-relay-client '([ATTACH.CAP_ATTACH] if ATTACH is not None and ATTACH.enabled() else [])' '[]' wire
mutant no-startup-sweep   bin/heimdall-relay-client '        ATTACH.sweep(client.root)  # a picture past its TTL does not outlive a restart' '        client.root  # mutant' keep

wait                                           # every job has left its result (or none) before the report reads them

echo "-- the real client: main stack (groups wire happy max refuse gate keep), HMD_ATTACH=0 (off), the limits (rate), the WebSocket leg (maxws) -- one scenario process per slice"
for label in "${SLICES[@]}"; do report_slice "$label"; done

echo "-- mutants: one rule removed from a copy, the cases that guard it must fail"
collect_mutants

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
