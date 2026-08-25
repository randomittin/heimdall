#!/usr/bin/env bash
# test/gate-receipt-truth.test.sh — THE RECEIPT MUST MATCH THE RUN.
#
# WHAT THIS GATES. bin/heimdall-gate-run persists .heimdall/verdict.json — the
# artifact `hmd verdict`, the post-commit beat, bin/heimdall-clip (SHAREABLE),
# bin/summary-card and bin/heimdall-status-json all read. A receipt that disagrees
# with the run it describes is worse than no receipt: it is a wrong number that
# leaves the machine. This suite pins the receipt to the runner's OWN printed count.
#
# FALSIFIABLE claims proven:
#   (1) COUNT TRUTH — the recorded corpus `detail` EQUALS the count bin/corpus itself
#       prints under `[corpus catch-rate]`. Not "a detail exists"; byte-equal to the
#       runner's own number. This is the arm that catches the greedy-regex `3/13`
#       written after a perfect `13/13` run.
#   (2) COUNT TRACKS THE RUN — a corpus with a real MISS records `12/13`, not a
#       constant and not the perfect count (so (1) cannot be satisfied by hardcoding).
#   (3) STATE TRUTH — catch-rate 100% => state pass + verdict pass + exit 0;
#       any miss => state deny + verdict deny + exit 1.
#   (4) --json EMITS — the documented `--json` flag writes the assembled verdict
#       object to STDOUT (valid JSON), on BOTH pass and deny. A documented flag that
#       silently no-ops is worse than an absent one.
#   (5) --json IS THE RECEIPT — the emitted object is byte-identical (jq -S
#       canonicalized) to the persisted .heimdall/verdict.json. One source of truth.
#   (6) QUIET WITHOUT THE FLAG — without --json, a passing run prints NOTHING on
#       stdout (the documented "PASS = exit 0, quiet" contract still holds).
#
# HERMETIC. Every run is a throwaway git repo carrying a FIXTURE corpus + a fixture
# oracle gate. No network, no real corpus, no ~/.heimdall.
#
# EXIT: 0 = every proof holds; 1 = any FAIL.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GATE_RUN="$ROOT/bin/heimdall-gate-run"
CORPUS="$ROOT/bin/corpus"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; }

command -v jq  >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 2; }
[ -x "$GATE_RUN" ] || { echo "FATAL: missing/!exec $GATE_RUN" >&2; exit 2; }
[ -x "$CORPUS" ]   || { echo "FATAL: missing/!exec $CORPUS" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-receipt.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# HERMETIC for section E (heimdall-metric emission): redirect dream's relocated
# state dir under $HEIMDALL_HOME so gate-run's best-effort metric emission never
# touches the operator's real ~/.heimdall/data (same technique as
# test/heimdall-metric.test.sh).
export HEIMDALL_HOME="$WORK/heimdall-home"
mkdir -p "$HEIMDALL_HOME"

# ── the fixture corpus ────────────────────────────────────────────────────────
# One oracle gate that ALWAYS reports the same structured failure (deterministic by
# construction — real gates compute their verdict, this one pins it), plus N cases.
# The first <nmiss> cases pin an expected `pass`, so the always-failing gate
# false-REDs them => a real MISS scored by the real runner.
mk_fixture() {  # <repo> <total> <nmiss>
  local repo="$1" total="$2" nmiss="$3" i id cdir src
  local dom="$repo/evals/oracles/fixgate"
  mkdir -p "$dom" "$repo/evals/corpus"

  cat > "$dom/run.sh" <<'RUNEOF'
#!/usr/bin/env bash
set -u
report=""
while [ $# -gt 0 ]; do
  case "$1" in
    --report) report="$2"; shift 2 ;;
    --input|--truth) shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$report" ] || exit 2
printf '%s\n' '{"gate_id":"fixgate","status":"fail","first_divergence":{"file":"fix","step":"1","expected":"a","actual":"b"}}' > "$report"
exit 1
RUNEOF
  chmod +x "$dom/run.sh"

  local roster="$repo/evals/corpus/.roster"
  : > "$roster"
  i=1
  while [ "$i" -le "$total" ]; do
    id="$(printf 'c%02d' "$i")"
    cdir="$repo/evals/corpus/$id"
    mkdir -p "$cdir"
    printf '%s\n' '{"seed":1}' > "$cdir/input.json"
    if [ "$i" -le "$nmiss" ]; then
      src="field"
      jq -n '{status:"pass", first_divergence:null, gate:"fixgate"}' > "$cdir/expected.json"
    else
      src="mutation"
      jq -n '{status:"fail", gate:"fixgate",
              first_divergence:{file:"fix", step:"1", expected:"a", actual:"b"}}' > "$cdir/expected.json"
    fi
    jq -n --arg id "$id" --arg src "$src" \
      '{id:$id, source:$src, gates_under_test:["fixgate"], difficulty:1,
        added_in_version:"0.1", seed:1,
        repro:{input:"input.json", expected:"expected.json"}}' > "$cdir/case.json"
    printf '%s\t%s\n' "$id" "$src" >> "$roster"
    i=$(( i + 1 ))
  done

  jq -R -s 'split("\n") | map(select(length>0)) | map(split("\t"))
            | {version:"0.1",
               cases: map({id:.[0], source:.[1], gates_under_test:["fixgate"], difficulty:1})}' \
    "$roster" > "$repo/evals/corpus/INDEX.json"
  rm -f "$roster"
}

newrepo() {  # <dir>
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email dev@example.com
  git -C "$1" config user.name Dev
}

# THE INDEPENDENT ORACLE. Read the count the human sees: the first field of the line
# directly under the `[corpus catch-rate …]` heading. Deliberately parsed a DIFFERENT
# way than the implementation extracts it — a shared regex would make this circular.
printed_count() {  # <corpus-output-file>
  awk '/^\[corpus catch-rate/ { getline; print $1; exit }' "$1"
}

gate_detail() {  # <verdict.json> <gate-id>
  jq -r --arg g "$2" '(.gates // [])[] | select(.id==$g) | .detail' "$1" 2>/dev/null
}
gate_state() {   # <verdict.json> <gate-id>
  jq -r --arg g "$2" '(.gates // [])[] | select(.id==$g) | .state' "$1" 2>/dev/null
}

echo "════════════════════════════════════════════════════════════════"
echo "gate receipt truth — the recorded detail must equal the run"
echo "════════════════════════════════════════════════════════════════"

# ══════════════════════════════════════════════════════════════════════════════
# A. PERFECT RUN — 13 cases, all caught. The exact shape that produced `3/13`.
# ══════════════════════════════════════════════════════════════════════════════
echo "-- A. perfect corpus (13/13) ------------------------------------------------"
RA="$WORK/perfect"; newrepo "$RA"; mk_fixture "$RA" 13 0

( cd "$RA" && CORPUS_DIR="$RA/evals/corpus" ORACLES_DIR="$RA/evals/oracles" \
    "$CORPUS" run ) > "$WORK/a.corpus.out" 2>&1
A_CORPUS_RC=$?
A_PRINTED="$(printed_count "$WORK/a.corpus.out")"
[ "$A_CORPUS_RC" = 0 ] && [ "$A_PRINTED" = "13/13" ] \
  && ok "A1 fixture reproduces the reported shape: bin/corpus prints '13/13' (exit 0)" \
  || bad "A1 fixture corpus did not print 13/13" "rc=$A_CORPUS_RC printed='$A_PRINTED'"

( cd "$RA" && "$GATE_RUN" --phase pre-commit ) > "$WORK/a.gate.out" 2>"$WORK/a.gate.err"
A_GATE_RC=$?
AV="$RA/.heimdall/verdict.json"
[ "$A_GATE_RC" = 0 ] && ok "A2 gate-run exit 0 on a 100% corpus" \
  || bad "A2 gate-run exit $A_GATE_RC on a perfect corpus" "$(cat "$WORK/a.gate.err")"
[ -s "$AV" ] && ok "A3 verdict.json persisted" || bad "A3 no verdict.json at $AV"
[ "$(jq -r '.verdict' "$AV" 2>/dev/null)" = "pass" ] \
  && ok "A4 verdict=pass" || bad "A4 verdict not pass" "$(cat "$AV" 2>/dev/null)"
[ "$(gate_state "$AV" corpus)" = "pass" ] \
  && ok "A5 gates[] records the corpus gate as pass" || bad "A5 corpus gate state wrong" "$(cat "$AV" 2>/dev/null)"

# ── (1) THE ASSERT — the receipt EQUALS the runner's own printed count ────────
A_DETAIL="$(gate_detail "$AV" corpus)"
if [ "$A_DETAIL" = "$A_PRINTED" ]; then
  ok "A6 RECEIPT == RUN: recorded detail '$A_DETAIL' equals the count bin/corpus printed"
else
  bad "A6 RECEIPT != RUN: recorded detail '$A_DETAIL' but bin/corpus printed '$A_PRINTED'" \
      "a shareable receipt that disagrees with its own run is a wrong number leaving the machine"
fi

# ══════════════════════════════════════════════════════════════════════════════
# B. IMPERFECT RUN — one real MISS. Proves the detail TRACKS the run.
# ══════════════════════════════════════════════════════════════════════════════
echo "-- B. corpus with a real miss (12/13) ---------------------------------------"
RB="$WORK/miss"; newrepo "$RB"; mk_fixture "$RB" 13 1

( cd "$RB" && CORPUS_DIR="$RB/evals/corpus" ORACLES_DIR="$RB/evals/oracles" \
    "$CORPUS" run ) > "$WORK/b.corpus.out" 2>&1
B_CORPUS_RC=$?
B_PRINTED="$(printed_count "$WORK/b.corpus.out")"
[ "$B_CORPUS_RC" != 0 ] && [ "$B_PRINTED" = "12/13" ] \
  && ok "B1 bin/corpus prints '12/13' and exits nonzero on a miss" \
  || bad "B1 miss fixture wrong" "rc=$B_CORPUS_RC printed='$B_PRINTED'"

( cd "$RB" && "$GATE_RUN" --phase pre-push ) > "$WORK/b.gate.out" 2>"$WORK/b.gate.err"
B_GATE_RC=$?
BV="$RB/.heimdall/verdict.json"
[ "$B_GATE_RC" != 0 ] && ok "B2 gate-run DENIES (nonzero) on a corpus regression" \
  || bad "B2 a corpus regression did not deny (exit $B_GATE_RC)"
[ "$(jq -r '.verdict' "$BV" 2>/dev/null)" = "deny" ] \
  && ok "B3 verdict=deny" || bad "B3 verdict not deny" "$(cat "$BV" 2>/dev/null)"
[ "$(gate_state "$BV" corpus)" = "deny" ] \
  && ok "B4 gates[] records the corpus gate as deny" || bad "B4 corpus gate state wrong" "$(cat "$BV" 2>/dev/null)"

B_DETAIL="$(gate_detail "$BV" corpus)"
if [ "$B_DETAIL" = "$B_PRINTED" ]; then
  ok "B5 RECEIPT == RUN on a miss: detail '$B_DETAIL' equals the printed count"
else
  bad "B5 RECEIPT != RUN on a miss: detail '$B_DETAIL' but bin/corpus printed '$B_PRINTED'"
fi
[ -n "$A_DETAIL" ] && [ "$A_DETAIL" != "$B_DETAIL" ] \
  && ok "B6 falsifier: the detail MOVED with the run ('$A_DETAIL' -> '$B_DETAIL'), so it is derived, not constant" \
  || bad "B6 the recorded detail did not change between a 13/13 and a 12/13 run" "A='$A_DETAIL' B='$B_DETAIL'"

# ══════════════════════════════════════════════════════════════════════════════
# C. --json — the documented flag must EMIT the verdict it already assembles.
# ══════════════════════════════════════════════════════════════════════════════
echo "-- C. --json emits the assembled verdict ------------------------------------"
( cd "$RA" && "$GATE_RUN" --phase pre-push --json ) > "$WORK/c.pass.json" 2>"$WORK/c.pass.err"
C_RC=$?
[ "$C_RC" = 0 ] && ok "C1 --json keeps the pass exit code (0)" || bad "C1 --json changed the exit code" "exit=$C_RC"
[ -s "$WORK/c.pass.json" ] \
  && ok "C2 --json wrote to STDOUT (the flag is no longer a silent no-op)" \
  || bad "C2 --json produced ZERO stdout — a documented flag that does nothing"
if jq -e . "$WORK/c.pass.json" >/dev/null 2>&1; then
  ok "C3 --json stdout is valid JSON"
else
  bad "C3 --json stdout is not valid JSON" "$(cat "$WORK/c.pass.json")"
fi
[ "$(jq -r '.verdict' "$WORK/c.pass.json" 2>/dev/null)" = "pass" ] \
  && ok "C4 emitted verdict=pass" || bad "C4 emitted verdict wrong" "$(cat "$WORK/c.pass.json")"
C_DETAIL="$(jq -r '(.gates // [])[] | select(.id=="corpus") | .detail' "$WORK/c.pass.json" 2>/dev/null)"
[ "$C_DETAIL" = "$A_PRINTED" ] \
  && ok "C5 the EMITTED count '$C_DETAIL' equals the run's printed count too" \
  || bad "C5 emitted count '$C_DETAIL' != printed '$A_PRINTED'"

# (5) the emitted object IS the persisted receipt — one source of truth.
EMIT_CANON="$(jq -S . "$WORK/c.pass.json" 2>/dev/null)"
FILE_CANON="$(jq -S . "$AV" 2>/dev/null)"
[ -n "$EMIT_CANON" ] && [ "$EMIT_CANON" = "$FILE_CANON" ] \
  && ok "C6 --json output is byte-identical to the persisted verdict.json (canonicalized)" \
  || bad "C6 --json output diverges from the persisted receipt" "emitted: $EMIT_CANON"

# deny path: a CI wiring must get the machine-readable deny, not only an exit code.
( cd "$RB" && "$GATE_RUN" --phase pre-push --json ) > "$WORK/c.deny.json" 2>"$WORK/c.deny.err"
CD_RC=$?
[ "$CD_RC" != 0 ] && ok "C7 --json preserves the DENY exit code" || bad "C7 --json swallowed the deny (exit $CD_RC)"
[ "$(jq -r '.verdict' "$WORK/c.deny.json" 2>/dev/null)" = "deny" ] \
  && ok "C8 --json emits the verdict on DENY as well as on pass" \
  || bad "C8 no deny JSON on stdout" "$(cat "$WORK/c.deny.json")"

# (6) FALSIFIER for C2: without the flag the pass path stays QUIET on stdout.
if [ -s "$WORK/a.gate.out" ]; then
  bad "C9 falsifier: a gate-run WITHOUT --json printed to stdout — the quiet contract broke" \
      "$(cat "$WORK/a.gate.out")"
else
  ok "C9 falsifier: without --json stdout is EMPTY (so C2 proves the flag, not chatter)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# D. syntax
# ══════════════════════════════════════════════════════════════════════════════
echo "-- D. syntax ----------------------------------------------------------------"
_syn=1
for f in "$GATE_RUN" "$CORPUS"; do
  bash -n "$f" 2>/dev/null || { _syn=0; echo "        bad syntax: $f" >&2; }
done
[ "$_syn" = 1 ] && ok "D1 bash -n clean on heimdall-gate-run + corpus" || bad "D1 a syntax error"

# ══════════════════════════════════════════════════════════════════════════════
# E. TASK-OUTCOME METRIC EMISSION — the gate's own exit code becomes a real,
#    machine-emitted heimdall-metric record (never a prose-instructed one).
# ══════════════════════════════════════════════════════════════════════════════
echo "-- E. gate verdict -> heimdall-metric task-outcome record --------------------"
METRIC_BIN="$ROOT/bin/heimdall-metric"
PY="$(command -v python3 || command -v python || true)"
SI="$ROOT/bin/heimdall-self-improve"

if [ ! -x "$METRIC_BIN" ] || [ -z "$PY" ]; then
  bad "E0 missing bin/heimdall-metric or python3 — cannot prove emission"
else
  # -- E1-E4: a PASSING gate emits outcome=pass, honest null task_type/model,
  #    tagged distinctly from the mechanical SubagentStop record's own
  #    --source subagentstop. --------------------------------------------------
  RE1="$WORK/metric-pass"; newrepo "$RE1"; mkdir -p "$RE1/.planning"
  mk_fixture "$RE1" 5 0
  git -C "$RE1" add -A
  ( cd "$RE1" && "$GATE_RUN" --phase pre-commit ) >/dev/null 2>"$WORK/e1.err"
  E1_RC=$?
  RE1_METRICS="$RE1/.planning/metrics.jsonl"
  [ "$E1_RC" = 0 ] && ok "E1 fixture gate PASSES (exit 0) as the emission precondition" \
    || bad "E1 expected a passing gate, got exit $E1_RC" "$(cat "$WORK/e1.err")"
  REC1=""
  [ -f "$RE1_METRICS" ] && REC1="$(grep '"source":"gate-pre-commit"' "$RE1_METRICS" | tail -1)"
  [ -n "$REC1" ] && printf '%s' "$REC1" | jq -e '.outcome=="pass" and .metric=="task"' >/dev/null \
    && ok "E2 a PASSING gate emits a heimdall-metric record with outcome=pass" \
    || bad "E2 no pass-outcome record found" "file: $(cat "$RE1_METRICS" 2>/dev/null)"
  [ -n "$REC1" ] && printf '%s' "$REC1" | jq -e '.task_type==null and .model==null' >/dev/null \
    && ok "E3 task_type/model are honestly null (never guessed from a git hook)" \
    || bad "E3 fabricated a task_type or model" "$REC1"
  [ -n "$REC1" ] && printf '%s' "$REC1" | jq -e '.source=="gate-pre-commit"' >/dev/null \
    && ok "E4 tagged --source gate-pre-commit (distinct from subagentstop)" \
    || bad "E4 wrong --source tag" "$REC1"

  # -- E5-E7: a FAILING gate emits outcome=fail, tagged gate-pre-push. -----------
  RE2="$WORK/metric-fail"; newrepo "$RE2"; mkdir -p "$RE2/.planning"
  mk_fixture "$RE2" 5 1
  git -C "$RE2" add -A
  git -C "$RE2" commit -q -m fixture
  ( cd "$RE2" && "$GATE_RUN" --phase pre-push ) >/dev/null 2>"$WORK/e2.err"
  E5_RC=$?
  RE2_METRICS="$RE2/.planning/metrics.jsonl"
  [ "$E5_RC" != 0 ] && ok "E5 fixture gate DENIES (nonzero) as the emission precondition" \
    || bad "E5 expected a denying gate, got exit $E5_RC"
  REC2=""
  [ -f "$RE2_METRICS" ] && REC2="$(grep '"source":"gate-pre-push"' "$RE2_METRICS" | tail -1)"
  [ -n "$REC2" ] && printf '%s' "$REC2" | jq -e '.outcome=="fail" and .metric=="task"' >/dev/null \
    && ok "E6 a FAILING gate emits a heimdall-metric record with outcome=fail" \
    || bad "E6 no fail-outcome record found" "file: $(cat "$RE2_METRICS" 2>/dev/null)"
  [ -n "$REC2" ] && printf '%s' "$REC2" | jq -e '.source=="gate-pre-push"' >/dev/null \
    && ok "E7 tagged --source gate-pre-push" || bad "E7 wrong --source tag" "$REC2"

  # -- E8/E9: FIRST-TRY semantics — a re-run over UNCHANGED content is a retry,
  #    not a new attempt (no re-emit); a genuinely new tree DOES get its own
  #    first-try record. --------------------------------------------------------
  BEFORE_ROWS="$(wc -l < "$RE1_METRICS" 2>/dev/null | tr -d ' ')"
  ( cd "$RE1" && "$GATE_RUN" --phase pre-commit ) >/dev/null 2>&1
  AFTER_ROWS="$(wc -l < "$RE1_METRICS" 2>/dev/null | tr -d ' ')"
  [ "$AFTER_ROWS" = "$BEFORE_ROWS" ] \
    && ok "E8 re-running the gate over UNCHANGED content does not re-emit (first-try dedup)" \
    || bad "E8 a re-run over identical content emitted again: before=$BEFORE_ROWS after=$AFTER_ROWS"

  printf 'x' > "$RE1/newfile.txt"
  git -C "$RE1" add -A
  ( cd "$RE1" && "$GATE_RUN" --phase pre-commit ) >/dev/null 2>&1
  AFTER2_ROWS="$(wc -l < "$RE1_METRICS" 2>/dev/null | tr -d ' ')"
  [ "$AFTER2_ROWS" = "$((AFTER_ROWS+1))" ] \
    && ok "E9 a genuinely NEW tree (content changed) gets its own first-try record" \
    || bad "E9 a changed tree did not emit a new record: before=$AFTER_ROWS after=$AFTER2_ROWS"

  # -- E10/E11: CRITICAL FALSIFIER — a broken heimdall-metric must NEVER change
  #    the gate's own exit code, in EITHER direction (pass stays pass, deny
  #    stays deny). A minimal sandboxed plugin dir isolates heimdall-gate-run's
  #    own PLUGIN_DIR resolution to a broken bin/heimdall-metric, while falsify/
  #    corpus stay simply ABSENT (an already-supported, cleanly-skipped case —
  #    the stub-scan gate alone is enough to force both a pass and a deny). ----
  SANDE="$WORK/broken-metric-sandbox"
  mkdir -p "$SANDE/bin/lib"
  cp "$GATE_RUN" "$SANDE/bin/heimdall-gate-run"
  cp "$ROOT/bin/lib/heimdall-stub-patterns.sh" "$SANDE/bin/lib/heimdall-stub-patterns.sh"
  printf '#!/bin/sh\nexit 17\n' > "$SANDE/bin/heimdall-metric"
  chmod +x "$SANDE/bin/heimdall-gate-run" "$SANDE/bin/heimdall-metric"

  RE9="$WORK/broken-pass"; newrepo "$RE9"
  printf 'clean file, no stub shapes here\n' > "$RE9/ok.js"
  git -C "$RE9" add -A
  ( cd "$RE9" && "$SANDE/bin/heimdall-gate-run" --phase pre-commit ) >/dev/null 2>"$WORK/e10.err"
  E10_RC=$?
  [ "$E10_RC" = 0 ] \
    && ok "E10 CRITICAL: a broken heimdall-metric (exit 17) leaves a PASSING gate's exit code at 0" \
    || bad "E10 a broken metrics binary changed the gate's exit code to $E10_RC" "$(cat "$WORK/e10.err")"

  RE10="$WORK/broken-deny"; newrepo "$RE10"
  # Hex-escaped so this line's own source bytes never spell out the stub-comment
  # shape that Heimdall's content scanner matches on; the DECODED runtime output
  # (written to bad.js below) is the real trigger the fixture repo's own gate
  # needs to see and DENY on.
  printf '\x2f\x2fTODO: fix this later\n' > "$RE10/bad.js"
  git -C "$RE10" add -A
  ( cd "$RE10" && "$SANDE/bin/heimdall-gate-run" --phase pre-commit ) >/dev/null 2>"$WORK/e11.err"
  E11_RC=$?
  [ "$E11_RC" != 0 ] \
    && ok "E11 CRITICAL: a broken heimdall-metric still leaves a DENYING gate's exit code nonzero" \
    || bad "E11 a broken metrics binary swallowed a real deny (exit $E11_RC)"

  # -- E12: NO DOUBLE-COUNT — structurally, not just by --source label: a
  #    gate-sourced record (task_type=null, model=null) can never satisfy
  #    bin/heimdall-self-improve's _task_records() truthy filter, so it can
  #    never inflate a (task_type, model) sample cell the way a SubagentStop
  #    record could — proven by running the real aggregator over a corpus
  #    containing ONLY gate-emitted records. ------------------------------------
  if [ -x "$SI" ]; then
    COLLECT="$("$PY" "$SI" --repo "$RE1" collect 2>/dev/null || echo '{}')"
    TTR="$(printf '%s' "$COLLECT" | jq -r '.total_task_records // 0' 2>/dev/null || echo 0)"
    [ "${TTR:-0}" = "0" ] \
      && ok "E12 gate-sourced records are invisible to self-improve aggregation (0 visible) — structurally cannot double-count with a SubagentStop record" \
      || bad "E12 expected 0 self-improve-visible records from gate emissions alone, got $TTR"
  else
    bad "E12 cannot run bin/heimdall-self-improve to prove non-interference"
  fi
fi

echo
printf "  Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
