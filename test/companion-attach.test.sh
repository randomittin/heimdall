#!/usr/bin/env bash
# test/companion-attach.test.sh -- the phone attaches a picture to a message: hmd answers `attach-v1`.
#
# The phone half is hmdapp's src/attach (docs/HANDOFF-TO-HEIMDALL-cursor-parity.md CP6; asked for again in docs/HANDOFF-TO-HEIMDALL-chat-replies.md
# section A). The wire under test, through the REAL bin/heimdall-relay-client against test/lib/fake-relay.py (a hermetic stand-in for the
# relay; test/lib/view_phone.py plays the paired phone and seals with the real bin/lib/hmd_relay_e2e.py -- nothing about the client is mocked,
# and no case imports the client or bin/lib/companion_attach.py):
#     cap      attach-v1 in every state frame's caps -- and NOT required in the phone's own resync (the shipped app never lists it)
#     command  {"action":"attach-begin","params":{"rid","name","mime","bytes","w","h","n","sha256"}}   ack {id: att-<8 hex>, result: {chunk_max}}
#              {"action":"attach-chunk","params":{"rid","id","idx","b64"}}                              ack {}
#              {"action":"attach-commit","params":{"rid","id","message"?,"pin"?}}                      ack {id: <inbox record id>, result: {queued}}
#     answer   <repo>/.heimdall/app/attachments/<id>.jpg|png (0600, dir 0700) and ONE inbox record naming that path, which
#              bin/heimdall-inbox-deliver hands to the Claude session behind its provenance marker
#
# What it proves (the cases live in test/lib/attach_scenarios.py, one group per concern):
#   wire     the cap, the three ack shapes, a phone that never listed attach-v1 can attach, begin de-duplicated on its rid
#   happy    two chunks (256 KiB + the rest) -> the file, its modes, its sha256, the inbox line, the delivered text with the marker; the path in no
#            frame, event, log or audit line; Exif/GPS/XMP/IPTC/comment/thumbnail stripped from a JPEG and eXIf/text/time from a PNG; the size in the
#            line from the file, not the phone; a hostile `name` ("../../x") never part of any path; a masked secret; stripped escapes; the pin
#   max      exactly 2 MiB in 8 chunks (~3.7 MB of sealed frames on ONE stream connection) through the real client, on the NDJSON leg
#            (max) and on the WebSocket leg the hosted relay speaks (maxws): the client's per-connection byte cap must not drop the stream
#            on the phone's own authenticated frames
#   refuse   bad mime, oversize, 9 chunks, every malformed param, an id that is not att-<8 hex>, a wrong-size, over-long or malformed chunk, a
#            replayed chunk, out-of-order chunks, a missing chunk (incomplete: the upload stays open), a commit replayed, a magic mismatch, a sha
#            mismatch, a corrupted chunk, a cut JPEG, a bad PNG checksum, a frame header that says 9000x9000 -- and after every refusal nothing
#            stored and nothing queued
#   gate     the kill switch (controls-off), an attachments directory that is a symlink, the direct route (not-implemented), controls.actions
#   keep     the 20 newest and 24 h, a symlink removed as a link, a stranger's file untouched, the sweep when the client starts
#   off      HMD_ATTACH=0: the cap is not listed and every command is not-implemented (a phone that was not offered cannot attach)
#   rate     3 open uploads at most (too-many), then rate-limited with retry_after_s
# and, falsifiably, that each rule is the thing holding: a copy with one rule removed must turn its group red.
#
# Hermetic: HOME/HEIMDALL_HOME/TMPDIR are temp dirs, every process this suite starts is reaped on exit, every wait is bounded.
# It signals no process it did not start (a running relay client of the operator's is never touched).

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

for f in "$CLIENT" "$SCEN" "$MODULE" "$REPO/test/lib/view_phone.py" "$REPO/test/lib/fake-relay.py" "$REPO/bin/heimdall-inbox-deliver"; do
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

# run_scenarios LABEL ARGS... -- run one stack of cases, print its lines, fold its tally into ours.
run_scenarios() {
  local label="$1" out="$TMPROOT/out.$RANDOM" rc tally p f
  shift
  python3 "$SCEN" "$@" >"$out" 2>&1
  rc=$?
  cat "$out"
  tally="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$out" | tail -1)"
  if [ -z "$tally" ]; then
    bad "$label: the scenario run produced no tally (exit $rc)"
    tail -20 "$out"
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
# else in bin/ and sentinels/ is linked to the real one.
mutant_tree() {
  local dir="$TMPROOT/mutant-$1" f name
  mkdir -p "$dir/bin/lib"
  for f in "$REPO"/bin/*; do
    name="$(basename "$f")"
    case "$name" in lib|heimdall-relay-client) ;; *) ln -s "$f" "$dir/bin/$name" ;; esac
  done
  for f in "$REPO"/bin/lib/*; do
    name="$(basename "$f")"
    case "$name" in companion_attach.py|companion_ui_controls.py) ;; *) ln -s "$f" "$dir/bin/lib/$name" ;; esac
  done
  cp "$CLIENT" "$dir/bin/heimdall-relay-client"
  cp "$MODULE" "$dir/bin/lib/companion_attach.py"
  cp "$REPO/bin/lib/companion_ui_controls.py" "$dir/bin/lib/companion_ui_controls.py"
  ln -s "$REPO/sentinels" "$dir/sentinels"
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

# mutant NAME FILE-IN-TREE OLD NEW GROUPS -- the suite's own cases for GROUPS must go red on the changed copy. Each mutant runs as its own
# scenario process (its own temp tree, ports and fake relay), six at a time; collect_mutants reads the verdicts.
MUT_NAMES=()
MUT_OUTS=()
MUT_LAUNCHED=0
mutant() {
  local name="$1" rel="$2" old="$3" new="$4" groups="$5" dir out
  dir="$(mutant_tree "$name")"
  if ! mutate "$dir/$rel" "$old" "$new" 2>"$TMPROOT/mut.err"; then
    bad "mutant $name could not be built: $(cat "$TMPROOT/mut.err")"
    return
  fi
  out="$TMPROOT/mut.out.$name"
  ( python3 "$SCEN" --client "$dir/bin/heimdall-relay-client" --groups "$groups" >"$out" 2>&1; echo "exit=$?" >>"$out" ) &
  MUT_NAMES+=("$name")
  MUT_OUTS+=("$out")
  MUT_LAUNCHED=$((MUT_LAUNCHED + 1))
  if [ $((MUT_LAUNCHED % 6)) -eq 0 ]; then wait; fi
}

collect_mutants() {
  local i=0 name out rc
  wait
  while [ "$i" -lt "${#MUT_NAMES[@]}" ]; do
    name="${MUT_NAMES[$i]}"
    out="${MUT_OUTS[$i]}"
    rc="$(grep '^exit=' "$out" | tail -1 | cut -d= -f2)"
    if [ "${rc:-0}" -ne 0 ] && grep -q '^  FAIL ' "$out"; then
      ok "mutant $name turns the suite red ($(grep -c '^  FAIL ' "$out") checks failed: $(grep -m1 '^  FAIL ' "$out" | cut -c8-90))"
    else
      bad "mutant $name NOT caught (exit ${rc:-?}) -- the rule it removes is not what the cases test"
    fi
    i=$((i + 1))
  done
}

echo "-- the real client: main stack (groups wire happy max refuse gate keep), HMD_ATTACH=0 (off), the limits (rate), the WebSocket leg (maxws)"
run_scenarios main

echo "-- mutants: one rule removed from a copy, the cases that guard it must fail"
mutant skip-magic-check   bin/lib/companion_attach.py '    if not data.startswith(magic):' '    if False:' refuse
mutant skip-sha-check     bin/lib/companion_attach.py '    if hashlib.sha256(data).hexdigest() != up.sha:' '    if False:' refuse
mutant skip-size-cap      bin/lib/companion_attach.py '    if nbytes > MAX_BYTES:' '    if False:' refuse
mutant skip-chunk-size    bin/lib/companion_attach.py '        if idx >= up.n or len(data) != up.size_of(idx):' '        if idx >= up.n:' refuse
mutant skip-exif-strip    bin/lib/companion_attach.py '    return marker in _JPEG_STRUCTURAL' '    return True' happy
mutant skip-png-strip     bin/lib/companion_attach.py '        if kind in _PNG_KEEP:' '        if True:' happy
mutant skip-secret-mask   bin/lib/companion_attach.py '        text = rx.sub(MASK, text)' '        text = text' happy
mutant loose-file-mode    bin/lib/companion_attach.py '        os.fchmod(fd, 0o600)' '        os.fchmod(fd, 0o644)' happy
mutant loose-dir-mode     bin/lib/companion_attach.py $'    os.chmod(path, 0o700)\n    return path' $'    os.chmod(path, 0o755)\n    return path' happy
mutant no-path-in-line    bin/lib/companion_attach.py 'text = "[image attached: %s (%dx%d)" % (path, width, height)' 'text = "[image attached: %s (%dx%d)" % ("-", width, height)' happy
mutant follow-dir-symlink bin/lib/companion_attach.py '    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid():' '    if False:' gate
mutant ignore-off-switch  bin/lib/companion_attach.py '        if not enabled() or ctx.caps is None:' '        if False:' off,gate
mutant keep-everything    bin/lib/companion_attach.py '        if rank >= KEEP or now - mtime >= KEEP_TTL_S:' '        if False:' keep
mutant cap-not-listed     bin/heimdall-relay-client '([ATTACH.CAP_ATTACH] if ATTACH is not None and ATTACH.enabled() else [])' '[]' wire
mutant no-startup-sweep   bin/heimdall-relay-client '        ATTACH.sweep(client.root)  # a picture past its TTL does not outlive a restart' '        client.root  # mutant' keep
mutant stream-cap-counts-all bin/heimdall-relay-client '                    stream_total_bytes -= size' '                    stream_total_bytes -= 0' max
mutant ws-cap-counts-all  bin/heimdall-relay-client '                            ws.total_bytes = max(0, ws.total_bytes - len(event[1]))' '                            ws.total_bytes = ws.total_bytes' maxws
collect_mutants

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
