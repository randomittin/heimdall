#!/usr/bin/env bash
# test/heimdall-emit.test.sh — falsifiable acceptance for bin/lib/heimdall-emit.sh.
#
# WHY THIS FILE EXISTS
# ---------------------
# Measured (docs/analysis/rtk-incorporation-assessment-2026-08-22.md): bash/tool
# output is 22.36% of all replayed input tokens — the single largest identifiable
# category — and hmd had nothing at that layer. RTK's OWN answer to this (declined
# elsewhere in this repo) is to intercept and re-parse FOREIGN command stdout,
# which corrupts silently (upstream #3267 drops a `while read` loop's last line by
# eating `git status --porcelain`'s trailing newline; #2811 duplicates filenames
# out of `git diff --name-only`). That risk is categorically absent here: this
# library never touches another program's bytes. It only helps an hmd bin compact
# ITS OWN already-produced output, which the bin fully owns and controls.
#
# THE SAFE DESIGN — three properties, each load-bearing:
#   1. CONTENT-BLIND. The only thing ever inspected about the captured content is
#      its byte count (`wc -c`). Never parsed, never re-interpreted, never
#      substring-matched. A gate that cannot "misread" content cannot corrupt it.
#   2. CALLER SUPPLIES THE VERDICT. The compact summary text printed on the
#      compaction path is whatever the CALLING bin hands in — normally something
#      it already had lying around in its own counters (e.g. `heimdall-agents`
#      sweep's `n_reap`/`n_parked`). This library never derives a summary by
#      reading the captured bytes; it only ever echoes what the caller says.
#   3. NOTHING BECOMES UNVERIFIABLE. Elided content is never discarded — it is
#      archived byte-for-byte under a durable path and the exact artifact path is
#      printed. "Full detail is one path-read away" is the whole point.
#
# THE FRESHNESS CONTRACT (docs/superpowers/specs/2026-08-22-gate-execution-alternative.md
# §3.4: "never close enough" — a pointer is only safe if it names the EXACT
# identity of what it points to). Applied here: the printed `evidence:` line
# always names the SPECIFIC artifact file this exact call just wrote (its own
# unique mktemp-suffixed name), never the generic mutable `LATEST` pointer. A
# concurrent call landing a newer LATEST a moment later must never invalidate an
# already-printed evidence line — section (3) below is the falsifiable proof.
#
# DURABILITY: artifacts live under ${HEIMDALL_HOME:-$HOME/.heimdall}/runs/<tool>/,
# never /tmp — a bare /tmp evidence dir was the measured root cause of an
# invalidated sweep the same day this library was written (OS-reaped mid-flight).
#
# Four properties this suite must prove, each falsifiably (break -> RED -> revert
# -> GREEN, per AGENTS.md):
#   1. SMALL OUTPUT IS UNTOUCHED    — byte-identical passthrough below threshold.
#   2. LARGE OUTPUT COMPACTS        — summary + evidence pointer; raw content elided.
#   3. THE ARTIFACT IS THE TRUTH    — reconstructs EXACTLY what was elided, byte for byte.
#   4. EXIT CODE ALWAYS SURVIVES    — both branches, several distinct codes.
#
# Hermetic: HOME is redirected to a throwaway dir under mktemp -d; the real
# ~/.heimdall is never read or written by this suite.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/bin/lib/heimdall-emit.sh"

[ -r "$LIB" ] || { echo "FATAL: $LIB not found" >&2; exit 2; }
# shellcheck source=/dev/null
. "$LIB"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-emit-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Hermetic: real $HOME is never touched by this suite.
HOME="$WORK/home"
export HOME
mkdir -p "$HOME"
unset HEIMDALL_HOME
unset HMD_EMIT_VERBOSE
unset HMD_EMIT_THRESHOLD

mk_small() { printf 'hello world\nsecond line\n' > "$1"; }
mk_big()   { yes "the quick brown fox jumps over the lazy dog 0123456789" | head -c 20000 > "$1"; }

evid_path_of() { grep '^evidence:' "$1" | sed -E 's/^evidence: *([^ ]+).*/\1/'; }

# ═══ (1) SMALL OUTPUT: byte-identical passthrough, default threshold, no artifact ═══
SRC="$WORK/small.txt"; mk_small "$SRC"
OUT="$WORK/out1.txt"
hmd_emit_result "test-tool-small" "$SRC" 0 "irrelevant summary" > "$OUT"
RC=$?
[ "$RC" -eq 0 ] && ok "small: exit 0 passthrough" || bad "small: exit code changed to $RC"
cmp -s "$SRC" "$OUT" && ok "small: stdout byte-identical to source" || bad "small: stdout differs from source"
[ ! -e "$HOME/.heimdall/runs/test-tool-small" ] && ok "small: no artifact directory created" || bad "small: artifact dir created for small output"

# ═══ (2) LARGE OUTPUT (threshold forced low): compacts, elides raw content, prints
#         a caller-verbatim summary + a real evidence pointer ═══
SRC2="$WORK/mid.txt"; mk_small "$SRC2"
OUT2="$WORK/out2.txt"
HMD_EMIT_THRESHOLD=5 hmd_emit_result "test-tool-mid" "$SRC2" 0 "3 rows, 0 problems" > "$OUT2"
RC2=$?
[ "$RC2" -eq 0 ] && ok "compacted: exit 0 passthrough" || bad "compacted: exit code changed to $RC2"
grep -qF "3 rows, 0 problems" "$OUT2" && ok "compacted: caller summary appears verbatim" || bad "compacted: summary missing"
grep -q "^evidence:" "$OUT2" && ok "compacted: prints an evidence pointer line" || bad "compacted: no evidence line"
grep -qF "second line" "$OUT2" && bad "compacted: raw content leaked inline (not elided)" || ok "compacted: raw content NOT inlined (elided)"
EVID_PATH="$(evid_path_of "$OUT2")"
[ -f "$EVID_PATH" ] && ok "compacted: evidence path names a real, existing file" || bad "compacted: evidence path '$EVID_PATH' does not exist"

# ═══ (3) THE ARTIFACT IS THE TRUTH — byte-for-byte reconstruction of the elided content ═══
cmp -s "$SRC2" "$EVID_PATH" && ok "artifact byte-for-byte identical to elided content" || bad "artifact diverges from original content"

EXPECT_DIR="$HOME/.heimdall/runs/test-tool-mid"
case "$EVID_PATH" in
  "$EXPECT_DIR"/*) ok 'artifact stored under ${HEIMDALL_HOME:-$HOME/.heimdall}/runs/<tool> (never /tmp)' ;;
  *) bad "artifact NOT under expected durable root: $EVID_PATH" ;;
esac
[ -f "$EXPECT_DIR/LATEST" ] && ok "LATEST pointer file created" || bad "LATEST pointer missing"
LATEST_VAL="$(cat "$EXPECT_DIR/LATEST" 2>/dev/null)"
[ "$LATEST_VAL" = "$EVID_PATH" ] && ok "LATEST names the exact artifact just written (freshness contract)" || bad "LATEST ('$LATEST_VAL') does not match evidence path ('$EVID_PATH')"

# A second call must mint a DIFFERENT artifact and leave the first one intact —
# the printed evidence line names ITS OWN file, never "whatever LATEST is now".
SRC2B="$WORK/mid-b.txt"; printf 'a different body\nline two\n' > "$SRC2B"
OUT2B="$WORK/out2b.txt"
HMD_EMIT_THRESHOLD=5 hmd_emit_result "test-tool-mid" "$SRC2B" 0 "second call" > "$OUT2B"
EVID_PATH_B="$(evid_path_of "$OUT2B")"
[ "$EVID_PATH_B" != "$EVID_PATH" ] && ok "second call mints a distinct artifact (no overwrite)" || bad "second call collided with the first artifact"
cmp -s "$SRC2" "$EVID_PATH" && ok "first artifact still intact after a second call" || bad "first artifact was mutated by a later call"
cmp -s "$SRC2B" "$EVID_PATH_B" && ok "second artifact matches its own source" || bad "second artifact does not match its source"

# ═══ (4) HEIMDALL_HOME override is respected (not just bare HOME) ═══
ALT="$WORK/altHome"
SRC3="$WORK/mid3.txt"; mk_small "$SRC3"
OUT3="$WORK/out3.txt"
HEIMDALL_HOME="$ALT" HMD_EMIT_THRESHOLD=5 hmd_emit_result "test-tool-althome" "$SRC3" 0 "s" > "$OUT3"
EVID3="$(evid_path_of "$OUT3")"
case "$EVID3" in
  "$ALT"/runs/test-tool-althome/*) ok "HEIMDALL_HOME override respected for artifact root" ;;
  *) bad "HEIMDALL_HOME override ignored: $EVID3" ;;
esac

# ═══ (5) HMD_EMIT_VERBOSE=1 escape hatch forces verbatim even above threshold ═══
SRC4="$WORK/mid4.txt"; mk_small "$SRC4"
OUT4="$WORK/out4.txt"
HMD_EMIT_THRESHOLD=5 HMD_EMIT_VERBOSE=1 hmd_emit_result "test-tool-verbose" "$SRC4" 0 "should not matter" > "$OUT4"
cmp -s "$SRC4" "$OUT4" && ok "HMD_EMIT_VERBOSE=1 forces verbatim even above threshold" || bad "verbose escape hatch did not force verbatim"
[ ! -e "$HOME/.heimdall/runs/test-tool-verbose" ] && ok "verbose mode writes no artifact" || bad "verbose mode archived output (should skip)"

# ═══ (6) EXIT CODE PASSTHROUGH across several distinct codes, in BOTH branches ═══
for code in 0 1 3 42; do
  SRCX="$WORK/ec-small-$code.txt"; mk_small "$SRCX"
  OUTX="$WORK/ec-small-$code.out"
  hmd_emit_result "test-tool-ec-small" "$SRCX" "$code" "s" > "$OUTX"
  RCX=$?
  [ "$RCX" -eq "$code" ] && ok "small path: exit code $code survives" || bad "small path: exit code $code became $RCX"

  SRCY="$WORK/ec-big-$code.txt"; mk_small "$SRCY"
  OUTY="$WORK/ec-big-$code.out"
  HMD_EMIT_THRESHOLD=5 hmd_emit_result "test-tool-ec-big" "$SRCY" "$code" "s" > "$OUTY"
  RCY=$?
  [ "$RCY" -eq "$code" ] && ok "compacted path: exit code $code survives" || bad "compacted path: exit code $code became $RCY"
done

# ═══ (7) Non-UTF8 / no-trailing-newline byte preservation, in BOTH branches ═══
NOEOL="$WORK/noeol.bin"
printf 'no newline at end, and a raw byte: \xC3\x28 done' > "$NOEOL"
OUT5="$WORK/out5.txt"
hmd_emit_result "test-tool-bin" "$NOEOL" 0 "s" > "$OUT5"
cmp -s "$NOEOL" "$OUT5" && ok "small path: non-UTF8/no-EOL content byte-identical" || bad "small path: binary content mangled"

OUT6="$WORK/out6.txt"
HMD_EMIT_THRESHOLD=5 hmd_emit_result "test-tool-bin2" "$NOEOL" 0 "s" > "$OUT6"
EVID6="$(evid_path_of "$OUT6")"
cmp -s "$NOEOL" "$EVID6" && ok "compacted path: non-UTF8/no-EOL artifact byte-identical" || bad "compacted path: binary artifact mangled"

# ═══ (8) Missing content-file -> explicit, documented error path (never a fabricated summary) ═══
MISSOUT="$WORK/miss.out"; MISSERR="$WORK/miss.err"
hmd_emit_result "test-tool-miss" "$WORK/does-not-exist.txt" 0 "s" > "$MISSOUT" 2>"$MISSERR"
RCM=$?
[ "$RCM" -eq 2 ] && ok "missing content-file returns library-error code 2" || bad "missing content-file returned $RCM, expected 2"
[ -s "$MISSERR" ] && ok "missing content-file writes a real error to stderr" || bad "missing content-file: stderr silent"
[ ! -s "$MISSOUT" ] && ok "missing content-file: no fabricated summary on stdout" || bad "missing content-file: fabricated output on stdout ($(cat "$MISSOUT"))"

# ═══ (9) mkdir/copy failure on the durable root -> fail-open to verbatim (never lose data) ═══
RODIR="$WORK/readonly-home"
mkdir -p "$RODIR"
chmod 555 "$RODIR"
SRC7="$WORK/mid7.txt"; mk_small "$SRC7"
OUT7="$WORK/out7.txt"
HEIMDALL_HOME="$RODIR" HMD_EMIT_THRESHOLD=5 hmd_emit_result "test-tool-ro" "$SRC7" 7 "s" > "$OUT7"
RC7=$?
chmod 755 "$RODIR"
[ "$RC7" -eq 7 ] && ok "fail-open path: exit code still survives" || bad "fail-open path: exit code became $RC7"
cmp -s "$SRC7" "$OUT7" && ok "fail-open: unwritable durable root falls back to verbatim stdout" || bad "fail-open: content lost when durable root unwritable"

# ═══ (10) Garbage HMD_EMIT_THRESHOLD falls back to the sane default, never crashes ═══
SRC8="$WORK/mid8.txt"; mk_small "$SRC8"
OUT8="$WORK/out8.txt"
HMD_EMIT_THRESHOLD="not-a-number" hmd_emit_result "test-tool-badthresh" "$SRC8" 0 "s" > "$OUT8"
cmp -s "$SRC8" "$OUT8" && ok "garbage HMD_EMIT_THRESHOLD falls back to default; small content still verbatim" || bad "garbage threshold broke default behavior"

# ═══ (11) Empty tool-name -> usage error, code 2 (cheap guard, mirrors missing-file) ═══
SRC9="$WORK/mid9.txt"; mk_small "$SRC9"
OUT9="$WORK/out9.txt"; ERR9="$WORK/err9.txt"
hmd_emit_result "" "$SRC9" 0 "s" > "$OUT9" 2>"$ERR9"
RC9=$?
[ "$RC9" -eq 2 ] && ok "empty tool-name returns library-error code 2" || bad "empty tool-name returned $RC9, expected 2"
[ -s "$ERR9" ] && ok "empty tool-name writes a real error to stderr" || bad "empty tool-name: stderr silent"

# ═══ (12) Default-threshold, real-scale end-to-end proof (no override at all) ═══
SRC10="$WORK/real-big.txt"; mk_big "$SRC10"
OUT10="$WORK/out10.txt"
hmd_emit_result "test-tool-real" "$SRC10" 0 "216 calls summarized" > "$OUT10"
grep -q "^evidence:" "$OUT10" && ok "default 4096B threshold triggers compaction on real-scale (20000B) output" || bad "default threshold failed to trigger on large real output"
OUT10_BYTES=$(wc -c < "$OUT10" | tr -d ' ')
SRC10_BYTES=$(wc -c < "$SRC10" | tr -d ' ')
[ "$OUT10_BYTES" -lt "$SRC10_BYTES" ] && ok "compacted stdout ($OUT10_BYTES B) far smaller than original ($SRC10_BYTES B)" || bad "compacted stdout not smaller than original"
EVID10="$(evid_path_of "$OUT10")"
cmp -s "$SRC10" "$EVID10" && ok "real-scale artifact byte-for-byte identical to original" || bad "real-scale artifact diverges from original"

echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
