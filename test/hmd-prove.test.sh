#!/usr/bin/env bash
# test/hmd-prove.test.sh — `hmd prove` (RP2): "do all gates pass, and has each gate been
# shown to fail first?"
#
# WHAT THIS PROVES
#   [H] HELP     `hmd prove --help` exits 0 and documents the contract (flags, exit codes,
#                the schema id); the command is dispatched, never a task prompt.
#   [U] PARSE    the two readers of the runners' output (bin/falsify, bin/corpus) classify
#                every shape they can see, and fail CLOSED on anything they cannot read:
#                a run that says nothing trustworthy is "no verdict" (exit 5), never a pass.
#   [S] SYNTH    real bin/falsify + bin/corpus over tiny synthetic gates the test builds:
#                the document is a valid runhmd.prove/1 (docs/schemas/runhmd.verdict.v1.json,
#                the single source, via bin/lib/runhmd_schema.py) and the verdict is DERIVED:
#                PROVEN only when every gate passes AND is falsified AND no regression case
#                failed. The headline case is a gate that PASSES but was never shown to fail
#                (a mutant survives): it counts toward `passed`, and the verdict is DENIED.
#   [R] REAL     the RP2 acceptance on this repo's own gates, verbatim, plus: prove wrote
#                nothing into the repository.
#   [A] ATTACK   real-gate mutation proof: weaken the `attack` oracle (drop the concurrent
#                retry attacks) and prove flips PROVEN -> DENIED with the gate still passing;
#                restore it and it flips back; corrupt the golden and the gate itself fails.
#   [C] CONSENT  non-TTY without --yes exits 3 before any gate runs; on a TTY the prompt says
#                it will EXECUTE code and a "n" declines.
#   [I] ISOLATE  gates get a private HOME/TMPDIR (removed afterwards), no GIT_* env, no
#                bytecode; a hung gate is killed with its whole process group; Ctrl-C / TERM
#                clean up.
#
# Hermetic: HEIMDALL_HOME and TMPDIR point into a throwaway dir, nothing is written to the
# real home, and no network is touched (every gate is local).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HMD="$REPO/bin/hmd"
PROVE_BIN="$REPO/bin/heimdall-prove"
PYLIB="$REPO/bin/lib"
PROVE_PY="$PYLIB/runhmd_prove.py"
SCHEMA_PY="$PYLIB/runhmd_schema.py"
ORACLES="$REPO/evals/oracles"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check() {  # check <description> <command...> : PASS iff the command exits 0
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

# GIT_* leaking in from a hook would redirect every git call below; start clean.
for _gv in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do
  [ "$_gv" = "GIT_EXEC_PATH" ] || unset "$_gv" 2>/dev/null || true
done
unset _gv

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmd-prove-test-XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"   # canonical (no //, no /var -> /private/var symlink): the path prove prints back
trap 'rm -rf "$TMP"' EXIT
export HEIMDALL_HOME="$TMP/home"; mkdir -p "$HEIMDALL_HOME"
export HEIMDALL_NO_INTRO=1 HEIMDALL_NO_UPDATE_CHECK=1
# Safety rails (same as test/hmd-attack.test.sh): if `hmd prove` is ever unrouted the
# dispatcher falls through to the Claude task-prompt path. With a stub claude, a setup-done
# marker and HEIMDALL_TRACE_ORDER that path only appends "launch:task" to a file and exits,
# so it can never start a model session or touch the network from this suite.
touch "$HEIMDALL_HOME/setup-done"
mkdir -p "$TMP/stubbin"; printf '#!/bin/sh\nexit 0\n' >"$TMP/stubbin/claude"; chmod +x "$TMP/stubbin/claude"
export PATH="$TMP/stubbin:$PATH"
export HEIMDALL_TRACE_ORDER="$TMP/trace.order"; : >"$HEIMDALL_TRACE_ORDER"

command -v jq      >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 2; }
command -v node    >/dev/null 2>&1 || { echo "node required" >&2; exit 2; }

# prove <args...>: run bin/heimdall-prove (stdin /dev/null); sets POUT PERR PRC
prove() {
  POUT="$TMP/prove.out"; PERR="$TMP/prove.err"
  "$PROVE_BIN" "$@" </dev/null >"$POUT" 2>"$PERR"; PRC=$?
}
# valid_prove <description> <file>: PASS iff the schema validator (the only judge of document
# validity) accepts the file as a runhmd.prove/1 document
valid_prove() {
  local out rc
  out="$(python3 "$SCHEMA_PY" validate "$2" 2>"$TMP/v.err")"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "ok runhmd.prove/1" ]; then ok "$1: validates as runhmd.prove/1"
  else bad "$1: not a valid runhmd.prove/1 (rc=$rc out='$out': $(head -2 "$TMP/v.err" | tr '\n' '|'))"; fi
}

# ── the synthetic gate the [S] cases are built from ───────────────────────────────────────────
# A real oracle gate in the report.json contract (evals/oracles/REPORT-CONTRACT.md): it passes
# iff its input contains the word "good". Golden = text with "good"; a mutant that lacks it is
# KILLED, one that has it SURVIVES. So any outcome (PROVEN, a survivor, a red golden) is one line
# of fixture text away, and bin/falsify + bin/corpus judge it for real.
SYNTH_RUN="$TMP/synth-run.sh"
cat >"$SYNTH_RUN" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
INPUT=""; REPORT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input)  INPUT="$2";  shift 2 ;;
    --report) REPORT="$2"; shift 2 ;;
    --truth)  shift 2 ;;
    *) echo "synth: unknown arg $1" >&2; exit 2 ;;
  esac
done
if [ -n "${PROBE_LOG:-}" ]; then
  printf 'probe GIT_DIR=%s HOME=%s TMPDIR=%s PYTHONDONTWRITEBYTECODE=%s\n' \
    "${GIT_DIR:-unset}" "$HOME" "${TMPDIR:-unset}" "${PYTHONDONTWRITEBYTECODE:-unset}" >>"$PROBE_LOG"
fi
if grep -q good "$INPUT"; then
  printf '{"gate_id":"synth","status":"pass","first_divergence":null,"metrics":{},"fix_hint":"ok","haid":"haid:local","wave":null,"ts":"1970-01-01T00:00:00Z"}\n' >"$REPORT"
  exit 0
fi
printf '{"gate_id":"synth","status":"fail","first_divergence":{"file":"synth","step":"s","expected":"good","actual":"bad"},"metrics":{},"fix_hint":"fix","haid":"haid:local","wave":null,"ts":"1970-01-01T00:00:00Z"}\n' >"$REPORT"
exit 1
SH
chmod +x "$SYNTH_RUN"

# mk_gate <repo> <id> <golden-text> <mutant-text>... : evals/oracles/<id> with the synthetic gate
mk_gate() {
  local repo="$1" id="$2" golden="$3"; shift 3
  local d="$repo/evals/oracles/$id" i=0 m entries=""
  mkdir -p "$d/fixtures/golden" "$d/fixtures/mutants"
  cp "$SYNTH_RUN" "$d/run.sh"; chmod +x "$d/run.sh"
  printf '{"id":"%s","golden_input":"fixtures/golden/input.txt"}\n' "$id" >"$d/gate.json"
  printf '%s\n' "$golden" >"$d/fixtures/golden/input.txt"
  for m in "$@"; do
    i=$((i+1))
    printf '%s\n' "$m" >"$d/fixtures/mutants/m$i.txt"
    entries="$entries${entries:+,}{\"name\":\"m$i\",\"file\":\"m$i.txt\"}"
  done
  printf '{"mutants":[%s]}\n' "$entries" >"$d/fixtures/mutants/manifest.json"
}
# mk_case <repo> <case-id> <gate-id> <input-text> <expected-json> : one evals/corpus regression case
mk_case() {
  local repo="$1" cid="$2" gate="$3" input="$4" expected="$5" c="$1/evals/corpus/$2"
  mkdir -p "$c"
  printf '%s\n' "$input" >"$c/input.txt"
  printf '%s\n' "$expected" >"$c/expected.json"
  printf '{"id":"%s","source":"mutation","gates_under_test":["%s"],"difficulty":"easy","added_in_version":"0.1","seed":1,"repro":{"input":"input.txt","expected":"expected.json"}}\n' "$cid" "$gate" >"$c/case.json"
  if [ ! -f "$repo/evals/corpus/INDEX.json" ]; then printf '{"version":"0.1","cases":[]}\n' >"$repo/evals/corpus/INDEX.json"; fi
  jq --arg id "$cid" --arg g "$gate" '.cases += [{"id":$id,"source":"mutation","gates_under_test":[$g],"difficulty":"easy"}]' "$repo/evals/corpus/INDEX.json" >"$repo/evals/corpus/INDEX.tmp" \
    && mv "$repo/evals/corpus/INDEX.tmp" "$repo/evals/corpus/INDEX.json"
}
SYNTH_FAIL_PIN='{"status":"fail","first_divergence":{"file":"synth","step":"s","expected":"good","actual":"bad"},"gate":"alpha"}'

# ══════════════════════════════════════════════════════════════════════════════
# [H] HELP — the command exists, is documented, and is dispatched
# ══════════════════════════════════════════════════════════════════════════════
echo "[H] hmd prove --help, dispatch"

[ -x "$PROVE_BIN" ] && ok "bin/heimdall-prove exists and is executable" || bad "bin/heimdall-prove is missing or not executable"
[ -f "$PROVE_PY" ] && ok "bin/lib/runhmd_prove.py exists (the logic; the launcher is thin)" || bad "bin/lib/runhmd_prove.py is missing"

( cd "$REPO" && "$HMD" prove --help >"$TMP/help.out" 2>"$TMP/help.err" ); hrc=$?
[ "$hrc" -eq 0 ] && grep -q '^usage:' "$TMP/help.out" && ok "ACCEPT: hmd prove --help exits 0 and prints its usage" || bad "ACCEPT: hmd prove --help exit $hrc (want 0) with a usage text"
missing=""
for w in '--json' '--yes' 'runhmd.prove/1' 'falsif' 'PROVEN' 'DENIED' 'RUNHMD_PROVE_TIMEOUT_S' 'evals/oracles' 'evals/corpus'; do
  grep -qF -- "$w" "$TMP/help.out" || missing="$missing $w"
done
[ -z "$missing" ] && ok "--help documents the flags, the document id, the verdict rule, the gate and corpus locations and the timeout variable" || bad "--help is missing:$missing"
exitdoc=""
for c in 0 1 2 3 5; do grep -Eq "^ +$c +[^ ]" "$TMP/help.out" || exitdoc="$exitdoc $c"; done
[ -z "$exitdoc" ] && ok "--help documents exit codes 0, 1, 2, 3 and 5 (the table hmd attack uses)" || bad "--help does not document exit code(s):$exitdoc"
grep -Eq '^ +3 .*consent' "$TMP/help.out" && ok "exit 3 is documented as consent required" || bad "exit 3 is not documented as consent"
"$PROVE_BIN" -h >"$TMP/help2.out" 2>&1 && cmp -s "$TMP/help.out" "$TMP/help2.out" \
  && ok "bin/heimdall-prove -h prints byte-for-byte what hmd prove --help prints (the dispatcher adds nothing)" || bad "-h / --help differ between the launcher and the dispatcher"
[ ! -s "$HEIMDALL_TRACE_ORDER" ] && ok "hmd prove --help never fell through to the Claude task-prompt path" || bad "hmd prove fell through to the task-prompt path: $(head -c 200 "$HEIMDALL_TRACE_ORDER")"
grep -Eq '^  prove\)' "$REPO/bin/heimdall" && ok "bin/heimdall has a prove) dispatch arm" || bad "bin/heimdall has no prove) arm"
bash -n "$REPO/bin/heimdall" && ok "bin/heimdall still passes bash -n" || bad "bin/heimdall has a syntax error"

# ══════════════════════════════════════════════════════════════════════════════
# [U] PARSE — what prove reads out of bin/falsify and bin/corpus, and what it refuses to read
# ══════════════════════════════════════════════════════════════════════════════
echo "[U] reading the runners: every shape classified, anything unreadable is no verdict"

cat >"$TMP/unit.py" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import runhmd_prove as rp

F = rp.classify_falsify
HEAD = "falsify x — falsifiability sweep\nmanifest: m\ngate:     g\n\n[1] golden (gate MUST pass — false-RED check)\n"
GREEN = "  golden: x\n  golden GREEN: run.sh report.json status=pass (gate not over-strict)\n\n[2] mutants (gate MUST reject each — false-GREEN check)\n"
failures = []
def expect(label, got, want):
    if got != want:
        failures.append("%s: got %r want %r" % (label, got, want))

# a clean run: golden green, every mutant killed, exit 0
ok_out = HEAD + GREEN + "SCORE: 3/3 = 1.0000 (golden passing)\nASSERT PASS: score 1.0000 >= target 1.0 (golden passed, no mutant survived)\n"
expect("pass", F(0, ok_out), ("pass", True, 1.0, []))
expect("pass with guard annotation", F(0, HEAD + GREEN + "SCORE: 6/6 = 1.0000 (golden passing) (incl. 2 guard, gate-invoked)\n"), ("pass", True, 1.0, []))
# the golden is fine but a mutant survived: passes, NOT falsified
surv = HEAD + GREEN + "SCORE: 6/7 = 0.8571 (golden passing)\nSURVIVED: racy-duplicate\nASSERT FAIL: score 0.8571 < target 1.0 (or a mutant survived)\n"
expect("survivor", F(1, surv), ("pass", False, 0.8571, ["racy-duplicate"]))
two = HEAD + GREEN + "SCORE: 1/3 = 0.3333 (golden passing)\nSURVIVED: a b\nASSERT FAIL: x\n"
expect("two survivors", F(1, two), ("pass", False, 0.3333, ["a", "b"]))
expect("survivor with no SURVIVED line still parsed", F(1, HEAD + GREEN + "SCORE: 1/2 = 0.5000 (golden passing)\n"), ("pass", False, 0.5, []))
big = HEAD + GREEN + "SCORE: 99999/100000 = 1.0000 (golden passing)\nSURVIVED: z\n"
expect("a score that rounds to 1.0 is never reported as 1.0 for a gate that is not falsified", F(1, big), ("pass", False, 0.9999, ["z"]))
# the gate rejected its own golden: a genuine red
red = HEAD + "  golden: x\n  golden report.json status='fail' (expected pass) — gate is over-strict (false-RED)\nGOLDEN FAILED: the gate rejects its own known-correct golden fixture.\nSCORE: 0/0 (golden precondition failed)\n"
expect("golden red", F(1, red), ("fail", False, 0.0, []))
# ...but a golden that produced no usable report is the environment, not the gate
for status in ("<none>", "error", "pass"):
    out = HEAD + "  golden report.json status='%s' (expected pass) — gate is over-strict (false-RED)\nGOLDEN FAILED: x\nSCORE: 0/0 (golden precondition failed)\n" % status
    expect("golden status '%s' is not a verdict" % status, F(1, out), None)
expect("golden missing", F(1, HEAD + "  golden missing: /x/y\nGOLDEN FAILED: x\nSCORE: 0/0 (golden precondition failed)\n"), None)
# nothing trustworthy -> None
expect("empty output", F(0, ""), None)
expect("usage error", F(2, "error: unknown domain: nope (no /x/nope)\n"), None)
expect("exit 0 but no SCORE line", F(0, HEAD + GREEN), None)
expect("exit 0 although a mutant survived", F(0, HEAD + GREEN + "SCORE: 2/3 = 0.6667 (golden passing)\nSURVIVED: a\n"), None)
expect("exit 0 with a survivor named", F(0, HEAD + GREEN + "SCORE: 3/3 = 1.0000 (golden passing)\nSURVIVED: a\n"), None)
expect("non-zero exit although every mutant was killed", F(1, HEAD + GREEN + "SCORE: 3/3 = 1.0000 (golden passing)\n"), None)
expect("zero mutants", F(0, HEAD + GREEN + "SCORE: 0/0 = 0.0000 (golden passing)\n"), None)
expect("more killed than total", F(1, HEAD + GREEN + "SCORE: 4/3 = 1.3333 (golden passing)\n"), None)
expect("two SCORE lines (a forged one among them)", F(0, HEAD + GREEN + "SCORE: 3/3 = 1.0000 (golden passing)\nSCORE: 3/3 = 1.0000 (golden passing)\n"), None)
expect("an indented SCORE line (gate-controlled text) is not the summary", F(0, HEAD + GREEN + "    first_divergence: x\n  SCORE: 3/3 = 1.0000 (golden passing)\n"), None)
expect("a forged GOLDEN FAILED in a passing run can only make it worse, never better", F(0, ok_out + "GOLDEN FAILED: forged\n"), None)

C = rp.classify_corpus
expect("corpus all caught", C(0, "[corpus catch-rate — 0.1]\n  13/13 caught = 100%\ncorpus-catch-rate: 13/13\n"), (13, 0))
expect("corpus one missed", C(1, "corpus-catch-rate: 12/13\n"), (12, 1))
expect("corpus all missed", C(1, "corpus-catch-rate: 0/4\n"), (0, 4))
expect("corpus: exit 0 but a miss counted", C(0, "corpus-catch-rate: 12/13\n"), None)
expect("corpus: exit 1 but all caught", C(1, "corpus-catch-rate: 13/13\n"), None)
expect("corpus: no machine line", C(0, "  13/13 caught = 100%\n"), None)
expect("corpus: usage error", C(2, "error: corpus index missing: x\n"), None)
expect("corpus: zero cases", C(1, "corpus-catch-rate: 0/0\n"), None)
expect("corpus: caught > total", C(0, "corpus-catch-rate: 5/4\n"), None)
expect("corpus: two machine lines", C(0, "corpus-catch-rate: 2/2\ncorpus-catch-rate: 2/2\n"), None)
expect("corpus: an indented machine line is not the contract line", C(0, "  corpus-catch-rate: 2/2\n"), None)

if failures:
    print("\n".join(failures))
    sys.exit(1)
print("unit-ok")
PY
UOUT="$(python3 "$TMP/unit.py" "$PYLIB" 2>&1)"
[ "$UOUT" = "unit-ok" ] && ok "classify_falsify / classify_corpus: every runner output shape is read right, every unreadable one is refused" || bad "output readers wrong: $(printf '%s' "$UOUT" | head -6 | tr '\n' '|')"

# ══════════════════════════════════════════════════════════════════════════════
# [S] SYNTH — real bin/falsify + bin/corpus over synthetic gates
# ══════════════════════════════════════════════════════════════════════════════
echo "[S] synthetic gates: the verdict is derived from real falsify + corpus runs"

# -- PROVEN ---------------------------------------------------------------------------------------
SB1="$TMP/sb1"; mk_gate "$SB1" alpha "this is good" "bad one" "bad two"
prove "$SB1" --json --yes; cp "$POUT" "$TMP/s1.json"; S1RC=$PRC
[ "$S1RC" -eq 0 ] && ok "PROVEN exits 0" || bad "PROVEN exit code is $S1RC (stderr: $(head -c 200 "$PERR"))"
valid_prove "PROVEN doc" "$TMP/s1.json"
check "PROVEN doc: RP2 shape — one gate that passes AND is falsified at 1.0, no regression tests" \
  jq -e '.schema=="runhmd.prove/1" and .verdict=="PROVEN" and .passed==1 and .total==1
         and .gates==[{"id":"alpha","gate_type":"unregistered","status":"pass","falsified":true,"falsify_score":1.0}]
         and .regression_tests=={"passed":0,"failed":0}' "$TMP/s1.json"
check "the document has exactly the RP2 keys, in the RP2 order" \
  jq -e 'keys_unsorted==["schema","verdict","gates","passed","total","regression_tests"] and (.gates[0]|keys_unsorted)==["id","gate_type","status","falsified","falsify_score"]' "$TMP/s1.json"
check "stdout is the document and nothing else (one JSON value)" jq -e -s 'length==1' "$TMP/s1.json"
[ ! -s "$PERR" ] && ok "--json leaves stderr empty on a PROVEN run" || bad "--json wrote to stderr: $(head -c 200 "$PERR")"
prove "$SB1" --json --yes
[ -s "$POUT" ] && cmp -s "$POUT" "$TMP/s1.json" && ok "deterministic: the same repository gives a byte-identical document" || bad "two runs on one repository differ (or gave nothing)"
# the human render is derived from the document
prove "$SB1" --yes
[ "$PRC" -eq 0 ] && grep -q 'PROVEN' "$POUT" && grep -q 'alpha' "$POUT" && ok "the default (text) output names the gate and says PROVEN" || bad "text output wrong (rc=$PRC): $(head -c 300 "$POUT")"
[ ! -s "$PERR" ] && ok "text mode leaves stderr empty on a PROVEN run" || bad "text mode wrote to stderr: $(head -c 200 "$PERR")"

# -- the gate passes but was never shown to fail: DENIED ------------------------------------------
SB2="$TMP/sb2"; mk_gate "$SB2" alpha "this is good" "bad one" "good enough, so this mutant survives"
prove "$SB2" --json --yes; cp "$POUT" "$TMP/s2.json"
[ "$PRC" -eq 1 ] && ok "DENIED exits 1" || bad "DENIED exit code is $PRC, want 1"
valid_prove "DENIED (survivor) doc" "$TMP/s2.json"
check "MUTANT SURVIVES: the gate still PASSES (status pass, passed==total) but is not falsified (0.5): DENIED" \
  jq -e '.verdict=="DENIED" and .passed==1 and .total==1 and .gates[0].status=="pass" and .gates[0].falsified==false and .gates[0].falsify_score==0.5' "$TMP/s2.json"
check "RP2 acceptance on the DENIED doc: [.gates[]|select(.falsified!=true)]|length>0" jq -e '[.gates[]|select(.falsified!=true)]|length>0' "$TMP/s2.json"
prove "$SB2" --yes
[ "$PRC" -eq 1 ] && grep -q 'DENIED' "$POUT" && grep -q 'm2' "$POUT" && grep -qi 'never shown to fail' "$POUT" \
  && ok "the text report names the survivor (m2) and says the gate passes but was never shown to fail" || bad "DENIED text report wrong (rc=$PRC): $(head -c 400 "$POUT")"

# -- the gate rejects its own golden: the gate itself is red --------------------------------------
SB3="$TMP/sb3"; mk_gate "$SB3" alpha "this one lacks the word" "bad one"
prove "$SB3" --json --yes; cp "$POUT" "$TMP/s3.json"
[ "$PRC" -eq 1 ] && ok "a red golden is DENIED (exit 1)" || bad "red golden exit code $PRC, want 1"
valid_prove "DENIED (red golden) doc" "$TMP/s3.json"
check "RED GOLDEN: status fail, not falsified, score 0, passed 0 of 1" \
  jq -e '.verdict=="DENIED" and .passed==0 and .total==1 and .gates[0].status=="fail" and .gates[0].falsified==false and .gates[0].falsify_score==0' "$TMP/s3.json"

# -- every gate is reported (no fast-deny), sorted, typed from the registry ------------------------
SB4="$TMP/sb4"
mk_gate "$SB4" gamma "no verdict word here" "bad one"
mk_gate "$SB4" alpha "this is good" "bad one"
mk_gate "$SB4" beta  "this is good" "bad one" "good enough"
printf '{"version":"1.0.0","oracles":{"alpha":{"gate_type":"differential"},"beta":{"gate_type":"example"}}}\n' >"$SB4/evals/oracles/registry.json"
mkdir -p "$SB4/evals/oracles/notes" && echo "docs only" >"$SB4/evals/oracles/notes/README.md"
mkdir -p "$SB4/evals/oracles/.hidden/fixtures/mutants"
prove "$SB4" --json --yes; cp "$POUT" "$TMP/s4.json"
[ "$PRC" -eq 1 ] && ok "one green + one survivor + one red golden: DENIED" || bad "mixed repository exit code $PRC, want 1"
valid_prove "mixed doc" "$TMP/s4.json"
check "all three gates are reported although two are red (prove does not stop at the first red gate)" \
  jq -e '(.gates|map(.id))==["alpha","beta","gamma"] and .total==3' "$TMP/s4.json"
check "passed counts gates that PASS (alpha, beta), not gates that are falsified (alpha only)" \
  jq -e '.passed==2 and ([.gates[]|select(.falsified)]|length)==1' "$TMP/s4.json"
check "gate_type comes from evals/oracles/registry.json; a gate it does not list is 'unregistered'" \
  jq -e '(.gates|map(.gate_type))==["differential","example","unregistered"]' "$TMP/s4.json"
check "a directory without fixtures/mutants (notes/) and a hidden one are not gates" \
  jq -e '(.gates|map(.id)|index("notes"))==null and (.gates|map(.id)|index(".hidden"))==null' "$TMP/s4.json"

# -- regression corpus ----------------------------------------------------------------------------
SB5="$TMP/sb5"; mk_gate "$SB5" alpha "this is good" "bad one" "bad two"
mk_case "$SB5" c1 alpha "bad input" "$SYNTH_FAIL_PIN"
prove "$SB5" --json --yes; cp "$POUT" "$TMP/s5.json"
[ "$PRC" -eq 0 ] && jq -e '.verdict=="PROVEN" and .regression_tests=={"passed":1,"failed":0}' "$TMP/s5.json" >/dev/null 2>&1 \
  && ok "a corpus whose case is still caught: PROVEN, regression_tests {passed:1, failed:0}" || bad "caught corpus case wrong (rc=$PRC): $(head -c 300 "$POUT")"
valid_prove "corpus doc" "$TMP/s5.json"
[ ! -e "$SB5/evals/corpus/CORPUS-STATUS.md" ] && ok "the corpus is read-only to prove: CORPUS-STATUS.md was not written (bin/corpus status, never run)" || bad "prove wrote CORPUS-STATUS.md into the repository"
mk_case "$SB5" c2 alpha "bad input" '{"status":"pass","first_divergence":null,"gate":"alpha"}'
prove "$SB5" --json --yes; cp "$POUT" "$TMP/s5b.json"
[ "$PRC" -eq 1 ] && ok "a corpus case the gate no longer handles as pinned: DENIED (exit 1)" || bad "missed corpus case exit code $PRC, want 1"
valid_prove "corpus-miss doc" "$TMP/s5b.json"
check "REGRESSION ALONE DENIES: every gate passes and is falsified, one regression case failed" \
  jq -e '.verdict=="DENIED" and .passed==.total and ([.gates[]|select(.falsified!=true)]|length)==0 and .regression_tests=={"passed":1,"failed":1}' "$TMP/s5b.json"
prove "$SB5" --yes
grep -q '1 regression' "$POUT" && ok "the text report says a regression case failed" || bad "text report does not mention the regression: $(head -c 300 "$POUT")"

# -- no verdict is not a verdict -------------------------------------------------------------------
SB6="$TMP/sb6"; mk_gate "$SB6" alpha "this is good" "bad one"; mk_gate "$SB6" broken "this is good" "bad one"
printf '#!/usr/bin/env bash\nexit 2\n' >"$SB6/evals/oracles/broken/run.sh"
prove "$SB6" --json --yes
[ "$PRC" -eq 5 ] && jq -e '.error=="infra" and (.detail|contains("broken")) and (has("verdict")|not) and (has("gates")|not)' "$POUT" >/dev/null 2>&1 \
  && ok "a gate that cannot be run to a verdict: exit 5, an error document naming it, and NO verdict (the healthy gate is not allowed to vouch for the repo)" || bad "unrunnable gate wrong (rc=$PRC): $(head -c 300 "$POUT")"
prove "$SB6" --yes
[ "$PRC" -eq 5 ] && grep -q 'broken' "$PERR" && [ ! -s "$POUT" ] && ok "text mode: the infrastructure error goes to stderr, stdout stays empty" || bad "text-mode infra error wrong (rc=$PRC): $(head -c 200 "$PERR")"

SB7="$TMP/sb7"; mk_gate "$SB7" alpha "this is good" "bad one"
mkdir -p "$SB7/evals/corpus"; printf '{"version":"0.1","cases":[]}\n' >"$SB7/evals/corpus/INDEX.json"
prove "$SB7" --json --yes
[ "$PRC" -eq 5 ] && jq -e '.error=="infra" and (.detail|test("corpus"))' "$POUT" >/dev/null 2>&1 \
  && ok "a corpus that declares no cases cannot vouch for regressions: exit 5 naming the corpus, not a silent 0/0" || bad "empty corpus index wrong (rc=$PRC): $(head -c 300 "$POUT")"

# -- nothing to prove / bad input is never a PROVEN ------------------------------------------------
mkdir -p "$TMP/empty"
prove "$TMP/empty" --json --yes
[ "$PRC" -eq 2 ] && jq -e '.error=="no_gates" and (has("verdict")|not)' "$POUT" >/dev/null 2>&1 \
  && ok "a repository with no gate exits 2 (no_gates), never a vacuous PROVEN" || bad "no-gate repository wrong (rc=$PRC): $(head -c 300 "$POUT")"
mkdir -p "$TMP/docsonly/evals/oracles/notes"; echo x >"$TMP/docsonly/evals/oracles/notes/README.md"
prove "$TMP/docsonly" --json --yes
[ "$PRC" -eq 2 ] && jq -e '.error=="no_gates"' "$POUT" >/dev/null 2>&1 && ok "evals/oracles with no fixtures/mutants anywhere is still no_gates (exit 2)" || bad "docs-only oracles dir wrong (rc=$PRC)"
mkdir -p "$TMP/flag/evals/oracles/-x/fixtures/mutants"
prove "$TMP/flag" --json --yes
[ "$PRC" -eq 2 ] && jq -e '.error=="bad_gate_id"' "$POUT" >/dev/null 2>&1 && ok "a gate directory named like a flag is refused (bad_gate_id, exit 2): it could not be handed to falsify as a gate id" || bad "flag-like gate id wrong (rc=$PRC)"
prove "$TMP/does-not-exist" --json --yes
[ "$PRC" -eq 2 ] && jq -e '.error=="repo_not_found"' "$POUT" >/dev/null 2>&1 && ok "a missing directory exits 2 (repo_not_found)" || bad "missing directory wrong (rc=$PRC)"
prove "$SYNTH_RUN" --json --yes
[ "$PRC" -eq 2 ] && jq -e '.error=="repo_not_found"' "$POUT" >/dev/null 2>&1 && ok "a file instead of a directory exits 2" || bad "file argument wrong (rc=$PRC)"
prove --bogus --yes;                  [ "$PRC" -eq 2 ] && ok "an unknown flag exits 2" || bad "unknown flag rc=$PRC"
prove "$SB1" "$SB2" --yes;            [ "$PRC" -eq 2 ] && ok "two directories exit 2 (one repository at a time)" || bad "two directories rc=$PRC"
RUNHMD_PROVE_TIMEOUT_S=abc prove "$SB1" --yes; [ "$PRC" -eq 2 ] && ok "RUNHMD_PROVE_TIMEOUT_S=abc exits 2 (a bad limit is refused, not ignored)" || bad "bad timeout value rc=$PRC"
RUNHMD_PROVE_TIMEOUT_S=0 prove "$SB1" --yes;   [ "$PRC" -eq 2 ] && ok "RUNHMD_PROVE_TIMEOUT_S=0 exits 2" || bad "zero timeout rc=$PRC"

# -- default repository: the git repository around the current directory ---------------------------
GR="$TMP/gitrepo"; mkdir -p "$GR"; git -C "$GR" init -q 2>/dev/null
mk_gate "$GR" alpha "this is good" "bad one"; mkdir -p "$GR/sub/dir"
( cd "$GR/sub/dir" && "$PROVE_BIN" --json --yes </dev/null >"$TMP/default.out" 2>"$TMP/default.err" ); drc=$?
[ "$drc" -eq 0 ] && jq -e '.verdict=="PROVEN" and (.gates|map(.id))==["alpha"]' "$TMP/default.out" >/dev/null 2>&1 \
  && ok "no argument inside a git repository proves the repository's gates (resolved from a subdirectory), not the subdirectory" || bad "default repository resolution wrong (rc=$drc): $(head -c 200 "$TMP/default.err")"
( cd "$SB1" && "$PROVE_BIN" --json --yes </dev/null >"$TMP/default2.out" 2>/dev/null ); drc=$?
[ "$drc" -eq 0 ] && jq -e '.verdict=="PROVEN"' "$TMP/default2.out" >/dev/null 2>&1 && ok "outside any git repository the current directory is the repository" || bad "non-git default wrong (rc=$drc)"

# ══════════════════════════════════════════════════════════════════════════════
# [R] REAL — this repository's own gates (the RP2 acceptance)
# ══════════════════════════════════════════════════════════════════════════════
echo "[R] the RP2 acceptance on this repository's own gates"

git_before="$(git -C "$REPO" status --porcelain)"
touch "$TMP/real.marker"; sleep 1
( cd "$REPO" && "$HMD" prove --json --yes </dev/null >"$TMP/real.json" 2>"$TMP/real.err" ); rrc=$?
[ "$rrc" -eq 0 ] && ok "hmd prove --json --yes on this repository: PROVEN, exit 0" || { bad "hmd prove on this repository exit $rrc: $(head -c 300 "$TMP/real.err")"; head -c 600 "$TMP/real.json"; }
check "ACCEPT: jq -e '[.gates[]|select(.falsified!=true)]|length==0' (RP2, verbatim)" jq -e '[.gates[]|select(.falsified!=true)]|length==0' "$TMP/real.json"
valid_prove "this repository's document" "$TMP/real.json"
want_gates="$(cd "$ORACLES" && for d in */; do [ -d "${d}fixtures/mutants" ] && printf '%s\n' "${d%/}"; done | sort | tr '\n' ' ')"
got_gates="$(jq -r '.gates[].id' "$TMP/real.json" 2>/dev/null | sort | tr '\n' ' ')"
[ -n "$want_gates" ] && [ "$want_gates" = "$got_gates" ] && ok "the gates are exactly the oracle domains that ship fixtures/mutants: $got_gates" || bad "gate set differs: want [$want_gates] got [$got_gates]"
check "every gate passes and is falsified at exactly 1.0, and passed == total == the number of gates" \
  jq -e '(.gates|length) as $n | .passed==$n and .total==$n and ([.gates[]|select(.status=="pass" and .falsified==true and .falsify_score==1.0)]|length)==$n' "$TMP/real.json"
check "gate_type is read from evals/oracles/registry.json (attack is differential, ponytail-underdelivery is example)" \
  jq -e '(.gates[]|select(.id=="attack")|.gate_type)=="differential" and (.gates[]|select(.id=="ponytail-underdelivery")|.gate_type)=="example"' "$TMP/real.json"
n_cases="$(jq '.cases|length' "$REPO/evals/corpus/INDEX.json")"
check "regression_tests is the case corpus: every one of its $n_cases cases is still caught" \
  jq -e --argjson n "$n_cases" '.regression_tests=={"passed":$n,"failed":0}' "$TMP/real.json"
[ "$git_before" = "$(git -C "$REPO" status --porcelain)" ] && ok "git status is unchanged by the run (prove changed no tracked file)" || bad "prove changed the repository's git status"
touched="$(find "$REPO/evals" "$REPO/bin" "$REPO/docs" -path '*/__pycache__' -prune -o -type f -newer "$TMP/real.marker" -print 2>/dev/null | head -5 | tr '\n' ' ')"
[ -z "$touched" ] && ok "no file under evals/, bin/ or docs/ was created or modified by the run (no report, no corpus status; bytecode is probed in [I])" || bad "prove wrote into the repository: $touched"

# ══════════════════════════════════════════════════════════════════════════════
# [A] ATTACK — real-gate mutation proof
# ══════════════════════════════════════════════════════════════════════════════
echo "[A] mutation: the verdict follows the real attack gate in both directions"

SBA="$TMP/sba"; mkdir -p "$SBA/evals/oracles"
cp "$ORACLES/registry.json" "$SBA/evals/oracles/"; cp -R "$ORACLES/attack" "$SBA/evals/oracles/attack"
find "$SBA" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
prove "$SBA" --json --yes; cp "$POUT" "$TMP/a1.json"
[ "$PRC" -eq 0 ] && jq -e '.verdict=="PROVEN" and .gates[0].id=="attack" and .gates[0].falsified==true' "$TMP/a1.json" >/dev/null 2>&1 \
  && ok "a copy of the attack gate: PROVEN (every mutant killed)" || bad "attack gate copy not PROVEN (rc=$PRC): $(head -c 300 "$POUT")"
cp "$SBA/evals/oracles/attack/engine/battery.mjs" "$TMP/battery.orig"
python3 - "$SBA/evals/oracles/attack/engine/battery.mjs" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
needle = "export const CASES = [...duplicateCases(), ...readCases(), ...roundingCases()];"
assert needle in src, "battery CASES line moved: update this test"
src = src.replace(needle, "export const CASES = [...duplicateCases(), ...readCases(), ...roundingCases()].filter((c) => !/^duplicate\\.(retry-at|burst)/.test(c.id));")
open(path, "w").write(src)
PY
prove "$SBA" --json --yes; cp "$POUT" "$TMP/a2.json"
[ "$PRC" -eq 1 ] && ok "MUTATION: drop the concurrent-retry attacks from the battery -> PROVEN flips to DENIED" || bad "weakened attack gate exit code $PRC, want 1"
valid_prove "weakened-gate doc" "$TMP/a2.json"
check "MUTATION: the weakened gate still PASSES its golden but racy-duplicate SURVIVES: score 6/7, not falsified" \
  jq -e '.verdict=="DENIED" and .passed==1 and .total==1 and .gates[0].status=="pass" and .gates[0].falsified==false and .gates[0].falsify_score==0.8571' "$TMP/a2.json"
prove "$SBA" --yes
grep -q 'racy-duplicate' "$POUT" && ok "the text report names the surviving mutant (racy-duplicate): the race a sequential-only battery never sees" || bad "survivor not named: $(head -c 300 "$POUT")"
cp "$TMP/battery.orig" "$SBA/evals/oracles/attack/engine/battery.mjs"
prove "$SBA" --json --yes
[ "$PRC" -eq 0 ] && jq -e '.verdict=="PROVEN"' "$POUT" >/dev/null 2>&1 && ok "MUTATION: restore the battery -> DENIED flips back to PROVEN (the verdict tracks the gate, nothing is cached)" || bad "restored attack gate not PROVEN (rc=$PRC)"
cp "$ORACLES/attack/fixtures/mutants/off-by-one-rounding.mjs" "$SBA/evals/oracles/attack/fixtures/golden/target.mjs"
prove "$SBA" --json --yes; cp "$POUT" "$TMP/a3.json"
[ "$PRC" -eq 1 ] && jq -e '.verdict=="DENIED" and .passed==0 and .gates[0].status=="fail" and .gates[0].falsified==false and .gates[0].falsify_score==0' "$TMP/a3.json" >/dev/null 2>&1 \
  && ok "MUTATION: corrupt the golden target -> the gate rejects its own golden: status fail, DENIED" || bad "corrupted golden not DENIED as a failed gate (rc=$PRC): $(head -c 300 "$POUT")"

# ══════════════════════════════════════════════════════════════════════════════
# [C] CONSENT — prove executes the repository's gate code, so it asks first
# ══════════════════════════════════════════════════════════════════════════════
echo "[C] consent (non-TTY without --yes exits 3, before any gate runs)"

MARK="$TMP/ran.log"; rm -f "$MARK"
PROBE_LOG="$MARK" prove "$SB1"
[ "$PRC" -eq 3 ] && [ ! -s "$POUT" ] && grep -q -- '--yes' "$PERR" && ok "no --yes and no TTY: exit 3, nothing on stdout, stderr says to pass --yes" || bad "non-TTY consent refusal wrong (rc=$PRC)"
[ ! -e "$MARK" ] && ok "...and no gate ran (the probe log was never written)" || bad "a gate ran without consent: $(head -c 200 "$MARK")"
PROBE_LOG="$MARK" prove "$SB1" --json
[ "$PRC" -eq 3 ] && jq -e '.error=="consent_required" and (has("verdict")|not)' "$POUT" >/dev/null 2>&1 && ok "--json without consent: exit 3 and an error document on stdout" || bad "--json consent refusal wrong (rc=$PRC)"
( printf 'y\n' | PROBE_LOG="$MARK" "$PROVE_BIN" "$SB1" >"$TMP/piped.out" 2>/dev/null; test $? -eq 3 && [ ! -s "$TMP/piped.out" ] && [ ! -e "$MARK" ] ) \
  && ok "a 'y' piped into a non-TTY is NOT consent (exit 3, nothing ran)" || bad "piped input was accepted as consent"
PROBE_LOG="$MARK" prove "$TMP/does-not-exist"
[ "$PRC" -eq 3 ] && ok "consent is asked for before the directory is looked at (exit 3, not 2)" || bad "consent should precede directory resolution (rc=$PRC)"
( cd "$REPO" && PROBE_LOG="$MARK" "$HMD" prove "$SB1" </dev/null >/dev/null 2>&1 ); [ $? -eq 3 ] && ok "hmd prove </dev/null exits 3 through the dispatcher too" || bad "hmd prove </dev/null did not exit 3"
[ ! -e "$MARK" ] && ok "...and still no gate ran" || bad "a gate ran through the dispatcher without consent"
PROBE_LOG="$MARK" prove "$SB1" --yes
CTRL_LINES="$(wc -l <"$MARK" 2>/dev/null | tr -d ' ')"
[ "$PRC" -eq 0 ] && [ "${CTRL_LINES:-0}" -gt 0 ] && ok "control: with --yes the same command runs the gates (the probe log gets $CTRL_LINES lines: golden + each mutant)" || bad "control run did not execute the gates (rc=$PRC)"

cat >"$TMP/pty-consent.py" <<'PY'
import os, pty, select, sys, time

def run(answer, hmd, repo, shown):
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(hmd, [hmd, "prove", repo])
    out, sent, deadline = b"", False, time.time() + 90
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.5)
        if ready:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            if not sent and b"[y/N]" in out:
                os.write(fd, answer)
                sent = True
    _, status = os.waitpid(pid, 0)
    return os.WEXITSTATUS(status), out.decode("utf-8", "replace"), sent

hmd, repo, shown = sys.argv[1], sys.argv[2], sys.argv[3]
rc_y, out_y, sent_y = run(b"y\n", hmd, repo, shown)
rc_n, out_n, sent_n = run(b"n\n", hmd, repo, shown)
print("YES rc=%d prompted=%s proven=%s executes=%s names_repo=%s" % (rc_y, sent_y, "PROVEN" in out_y, "EXECUTE" in out_y.upper(), shown in out_y))
print("NO rc=%d prompted=%s ran=%s" % (rc_n, sent_n, "PROVEN" in out_n or "DENIED" in out_n))
PY
rm -f "$MARK"
SB1_REAL="$(cd "$SB1" && pwd -P)"
pty_out="$(PROBE_LOG="$MARK" python3 "$TMP/pty-consent.py" "$HMD" "$SB1" "$SB1_REAL" 2>/dev/null)"
printf '%s\n' "$pty_out" | grep -q '^YES rc=0 prompted=True proven=True executes=True names_repo=True' \
  && ok "on a TTY the prompt says it will EXECUTE code and names the repository; answering y runs the proof (PROVEN, exit 0)" || bad "TTY consent 'y' flow wrong: $(printf '%s' "$pty_out" | tr '\n' '|')"
printf '%s\n' "$pty_out" | grep -q '^NO rc=3 prompted=True ran=False' && ok "on a TTY, answering n declines: exit 3 and no verdict" || bad "TTY consent 'n' flow wrong: $(printf '%s' "$pty_out" | tr '\n' '|')"
[ "$(wc -l <"$MARK" 2>/dev/null | tr -d ' ')" = "$CTRL_LINES" ] && ok "...and exactly one proof's worth of gate runs happened across both answers (only the 'y' ran anything)" || bad "gate runs across the two TTY answers: $(wc -l <"$MARK" 2>/dev/null | tr -d ' ') (one proof is $CTRL_LINES)"

# ══════════════════════════════════════════════════════════════════════════════
# [I] ISOLATE — environment, bytecode, process group, signals
# ══════════════════════════════════════════════════════════════════════════════
echo "[I] isolation: private HOME/TMPDIR, no GIT_*, no bytecode, hung gates are killed, signals clean up"

OUTER_HOME="$TMP/outer-home"; OUTER_TMP="$TMP/outer-tmp"; mkdir -p "$OUTER_HOME" "$OUTER_TMP"
PROBE="$TMP/probe.log"; rm -f "$PROBE"
( HOME="$OUTER_HOME" TMPDIR="$OUTER_TMP" PROBE_LOG="$PROBE" GIT_DIR=/nonexistent/gitdir GIT_INDEX_FILE=/nonexistent/index \
  "$PROVE_BIN" "$SB1" --json --yes </dev/null >"$TMP/iso.out" 2>"$TMP/iso.err" ); irc=$?
[ "$irc" -eq 0 ] && ok "a run with hostile GIT_DIR / GIT_INDEX_FILE in the environment still PROVES (they are not handed to the gates)" || bad "GIT_* in the environment broke the run (rc=$irc): $(head -c 200 "$TMP/iso.err")"
grep -q 'GIT_DIR=unset' "$PROBE" && ok "the gate saw no GIT_DIR (a hook's git environment cannot redirect the gate at the caller's repository)" || bad "the gate inherited GIT_DIR: $(head -c 200 "$PROBE")"
grep -q "HOME=$OUTER_TMP/runhmd-prove-[^ ]*/home " "$PROBE" && grep -q "TMPDIR=$OUTER_TMP/runhmd-prove-[^ ]*/tmp " "$PROBE" \
  && ok "the gate ran with HOME and TMPDIR inside prove's own temp directory" || bad "gate HOME/TMPDIR are not private: $(head -c 300 "$PROBE")"
grep -q 'PYTHONDONTWRITEBYTECODE=1' "$PROBE" && ok "the gate was told not to write bytecode" || bad "bytecode writing was not disabled for the gate"
[ -z "$(ls -A "$OUTER_HOME")" ] && [ -z "$(ls -A "$OUTER_TMP")" ] && ok "nothing left in the caller's HOME, and prove's temp directory was removed" || bad "left behind: home=[$(ls -A "$OUTER_HOME")] tmp=[$(ls -A "$OUTER_TMP")]"
snap() { (cd "$1" && find . -type f -exec shasum {} + | sort); }
before="$(snap "$SB5")"; prove "$SB5" --yes >/dev/null 2>&1
[ "$before" = "$(snap "$SB5")" ] && ok "the repository under proof is byte-identical afterwards (gates, fixtures and corpus untouched)" || bad "the run modified the repository under proof"

# a python gate that imports a sibling module would drop __pycache__ next to it: prove forbids it
SBP="$TMP/sbp"; mk_gate "$SBP" alpha "this is good" "bad one"
printf 'VALUE = 1\n' >"$SBP/evals/oracles/alpha/helper.py"
{ head -n 1 "$SYNTH_RUN"; printf 'python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import helper" "$(cd "$(dirname "$0")" && pwd)"\n'; tail -n +2 "$SYNTH_RUN"; } >"$SBP/evals/oracles/alpha/run.sh"
env -u PYTHONDONTWRITEBYTECODE bash "$SBP/evals/oracles/alpha/run.sh" --input "$SBP/evals/oracles/alpha/fixtures/golden/input.txt" --report "$TMP/ctl.report.json" >/dev/null 2>&1
if [ -d "$SBP/evals/oracles/alpha/__pycache__" ]; then ok "control: run directly, the python gate DOES drop __pycache__ into its directory (the probe is live)"; else bad "control: the bytecode probe cannot detect bytecode (probe is broken)"; fi
rm -rf "$SBP/evals/oracles/alpha/__pycache__"
prove "$SBP" --json --yes
[ "$PRC" -eq 0 ] && [ ! -d "$SBP/evals/oracles/alpha/__pycache__" ] && ok "run through prove, the same python gate leaves no __pycache__ in the repository" || bad "prove let a python gate write bytecode into the repository (rc=$PRC)"

# the launcher itself must not write bytecode into the install either
PLUG="$TMP/plug"; mkdir -p "$PLUG/bin/lib" "$PLUG/docs/schemas"
cp "$PROVE_BIN" "$PLUG/bin/heimdall-prove"; cp "$PYLIB"/runhmd_*.py "$PLUG/bin/lib/"; cp "$REPO/docs/schemas/runhmd.verdict.v1.json" "$PLUG/docs/schemas/"
env -u PYTHONDONTWRITEBYTECODE "$PLUG/bin/heimdall-prove" "$TMP/empty" --json --yes </dev/null >"$TMP/plug.out" 2>&1
[ "$(jq -r '.error' "$TMP/plug.out" 2>/dev/null)" = "no_gates" ] && [ -z "$(find "$PLUG" -name __pycache__ -o -name '*.pyc' | head -1)" ] \
  && ok "running the launcher from an install writes no bytecode into that install's bin/lib" || bad "the launcher wrote bytecode into the install: $(find "$PLUG" -name '*.pyc' | head -2 | tr '\n' ' ')"
PLUG2="$TMP/plug2"; mkdir -p "$PLUG2"; cp "$PYLIB/runhmd_schema.py" "$PLUG2/"
env -u PYTHONDONTWRITEBYTECODE python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import runhmd_schema" "$PLUG2"
[ -d "$PLUG2/__pycache__" ] && ok "control: a plain import of the same module does write __pycache__ (so the check above is live)" || bad "control: plain import wrote no bytecode (probe is broken)"

# a hung gate is bounded by the wall clock and its whole process group dies
SBH="$TMP/sbh"; mk_gate "$SBH" alpha "this is good" "bad one"
printf '#!/usr/bin/env bash\nsleep 300 &\necho $! >"$PROBE_PID_FILE"\nwait\n' >"$SBH/evals/oracles/alpha/run.sh"
PIDF="$TMP/hang.pid"; rm -f "$PIDF"
T0=$SECONDS
RUNHMD_PROVE_TIMEOUT_S=2 PROBE_PID_FILE="$PIDF" prove "$SBH" --json --yes
T1=$((SECONDS - T0))
[ "$PRC" -eq 5 ] && jq -e '.error=="infra" and (.detail|test("wall clock")) and (.detail|contains("alpha"))' "$POUT" >/dev/null 2>&1 \
  && ok "a gate that never returns: exit 5 naming the gate and the wall clock, no verdict" || bad "hung gate wrong (rc=$PRC): $(head -c 300 "$POUT")"
[ "$T1" -le 20 ] && ok "...bounded by RUNHMD_PROVE_TIMEOUT_S (took ${T1}s for a 2s limit)" || bad "...but took ${T1}s for a 2s limit"
if [ -s "$PIDF" ] && ! kill -0 "$(cat "$PIDF")" 2>/dev/null; then ok "the hung gate's own child process was killed with it (the whole process group, not just the runner)"
else bad "the hung gate's child (pid $(cat "$PIDF" 2>/dev/null)) is still alive"; kill "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; fi

cat >"$TMP/sigdriver.py" <<'PY'
import os, signal, subprocess, sys, time

prove, repo, pidfile, tmpdir, sig = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])

def alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True

env = dict(os.environ, PROBE_PID_FILE=pidfile, TMPDIR=tmpdir)
proc = subprocess.Popen([prove, repo, "--yes"], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        start_new_session=True, preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
deadline = time.time() + 30
while time.time() < deadline and not (os.path.exists(pidfile) and os.path.getsize(pidfile) > 0):
    time.sleep(0.05)
child = int(open(pidfile).read().strip()) if os.path.exists(pidfile) and os.path.getsize(pidfile) else 0
os.kill(proc.pid, sig)
try:
    rc = proc.wait(timeout=30)
except subprocess.TimeoutExpired:
    proc.kill()
    rc = "hung"
settle = time.time() + 5
while child and alive(child) and time.time() < settle:
    time.sleep(0.1)
leaked = bool(child) and alive(child)
print("rc=%s gate_child_alive=%s tmp_left=%d" % (rc, leaked, len(os.listdir(tmpdir))))
if leaked:
    os.kill(child, signal.SIGKILL)
PY
for pair in "INT:130:2" "TERM:143:15"; do
  sname="${pair%%:*}"; rest="${pair#*:}"; want_rc="${rest%%:*}"; signum="${rest#*:}"
  rm -f "$PIDF"; sigtmp="$TMP/sigtmp.$sname"; mkdir -p "$sigtmp"
  sig_out="$(python3 "$TMP/sigdriver.py" "$PROVE_BIN" "$SBH" "$PIDF" "$sigtmp" "$signum" 2>&1)"
  [ "$sig_out" = "rc=$want_rc gate_child_alive=False tmp_left=0" ] \
    && ok "SIG$sname mid-run: exit $want_rc, the running gate's process group is killed and the temp directory is removed" || bad "SIG$sname handling wrong: $sig_out"
done

# ══════════════════════════════════════════════════════════════════════════════
# [D] DESIGN — what the module may and may not do
# ══════════════════════════════════════════════════════════════════════════════
echo "[D] design constraints"

! grep -En '^[[:space:]]*(import|from)[[:space:]]+(socket|urllib|http|ssl|ftplib|smtplib|requests)' "$PROVE_PY" "$PROVE_BIN" >/dev/null 2>&1 \
  && ok "prove imports no network module (every gate it runs is local)" || bad "prove imports a network module"
! grep -En 'shell[[:space:]]*=[[:space:]]*True|os\.system' "$PROVE_PY" "$PROVE_BIN" >/dev/null 2>&1 \
  && ok "prove never shells out through a shell string" || bad "prove uses shell=True / os.system"
grep -q 'runhmd_schema' "$PROVE_PY" && grep -q 'validate(' "$PROVE_PY" && ok "prove validates its document against the single schema before printing it" || bad "prove does not validate its document"
! grep -Eq '"corpus"[^#]*"run"' "$PROVE_PY" && ok "prove never invokes 'bin/corpus run' (that rewrites CORPUS-STATUS.md in the repository)" || bad "prove invokes bin/corpus run"
python3 - "$PYLIB" "$SB1" >"$TMP/missing-tool.out" 2>&1 <<'PY'
import contextlib, io, json, sys
sys.path.insert(0, sys.argv[1])
import runhmd_prove as rp
rp.PLUGIN_DIR = "/nonexistent-plugin-dir"
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = rp.main([sys.argv[2], "--json", "--yes"])
doc = json.loads(buf.getvalue())
assert rc == 5, rc
assert doc["error"] == "infra" and "falsify" in doc["detail"], doc
print("missing-tool-ok")
PY
grep -q missing-tool-ok "$TMP/missing-tool.out" && ok "bin/falsify missing from the install: exit 5 naming it, never a verdict" || bad "missing falsify handling wrong: $(head -c 300 "$TMP/missing-tool.out")"
[ ! -s "$HEIMDALL_TRACE_ORDER" ] && ok "hmd prove never fell through to the Claude task-prompt path during this suite" || bad "hmd prove fell through to the task-prompt path: $(head -c 200 "$HEIMDALL_TRACE_ORDER")"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
