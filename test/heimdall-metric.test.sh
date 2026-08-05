#!/usr/bin/env bash
# test/heimdall-metric.test.sh — acceptance for the TASK-OUTCOME METRIC EMITTER
# (bin/heimdall-metric) — the missing PRODUCER for the self-improve/dream loop.
#
# Before this bin existed, .planning/metrics.jsonl carried ONLY metric:"parallelism"
# rows and ZERO metric:"task" rows, so `heimdall-dream` computed honest_empty=True
# every night forever: a correct falsifier with its fuel line unconnected. These
# cases prove the fuel line, end to end, and prove it cannot be faked.
#
# Hermetic: every case runs against a THROWAWAY repo. Nothing here touches a live
# transcript, the network, a real model, or the real .planning dir.
#
# FALSIFIABLE claims proven:
#   (1)  EMIT — a task record lands as ONE JSON line carrying every field the ask
#        names: task type, model tier, effort, wall-clock, first-try AC outcome,
#        retry count, escalation.
#   (2)  CONSUMED — heimdall-self-improve `collect` aggregates the emitted rows into
#        the comparable scalar (it is not merely well-formed, it is READ).
#   (3)  NEVER-FAILS — an unwritable target is a SILENT no-op at exit 0. A metrics
#        write failing must never surface an error to the user.
#   (4)  NEVER-FAILS (usage) — a malformed/incomplete call is also exit 0 + no row.
#        --strict is the opt-in that lets THIS test see the failure.
#   (5)  NO PROMPT CONTENT — free text offered as a task type is slugged + capped;
#        a prompt/secret cannot survive into the corpus. No body/content/prompt key.
#   (6)  INTEGRITY — an off-ladder model tier or a non pass|fail outcome is DROPPED,
#        so a bogus row can never pollute the routing evidence.
#   (7)  ATOMIC APPEND — N concurrent emitters produce N intact, parseable lines
#        (single O_APPEND write under PIPE_BUF — parallel agents cannot interleave).
#   (8)  FIRST-TRY IS THE SCALAR — `outcome` is first-try AC pass/fail (what routing
#        is graded on); `final` is the eventual verdict. A task that failed first try
#        but eventually passed reads fail/pass — the two are NOT conflated.
#   (9)  ESCALATION — an escalated task records the tier it escalated to, and the
#        two-hop haiku->sonnet->opus case yields clean per-tier observations.
#   (10) DREAM CONSUMES REAL DATA — a corpus emitted ONLY by this bin drives
#        heimdall-dream to a real recommendation (honest_empty=false).
#   (11) HONEST EMPTY SURVIVES — an empty corpus still yields honest_empty=true.
#   (12) SAMPLE-SIZE FLOOR — dream REFUSES to act below the floor: a thin corpus
#        (below the floor) yields NO routing suggestion, and the floor cannot be
#        argued down with --min-samples.
#   (13) FALSIFIABILITY — a corpus where a tier is obviously WORSE yields a
#        recommendation AGAINST that tier (escalate away from it), never toward it.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-metric"
SI="$ROOT/bin/heimdall-self-improve"
DREAM="$ROOT/bin/heimdall-dream"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
PY="$(command -v python3 || command -v python)"
[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }

WORK="$(mktemp -d -t hmd-metric-test)"
trap 'chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT

mk_repo() { local d="$WORK/$1"; mkdir -p "$d/.planning"; printf '%s' "$d"; }
rows()    { [ -f "$1/.planning/metrics.jsonl" ] || return 0
            wc -l < "$1/.planning/metrics.jsonl" | tr -d ' '; }
last()    { tail -n 1 "$1/.planning/metrics.jsonl"; }

echo "heimdall-metric acceptance"
echo "=========================="

# ── (1) EMIT ───────────────────────────────────────────────────────────────────
R="$(mk_repo emit)"
"$CLI" --repo "$R" task --type lint --model haiku --effort default \
       --outcome pass --retries 0 --wall-secs 42 >/dev/null

L="$(last "$R")"
printf '%s' "$L" | jq -e '.metric=="task"' >/dev/null \
  && ok "(1) emits metric=\"task\"" || bad "(1) wrong metric key: $L"
printf '%s' "$L" | jq -e '.task_type=="lint" and .model=="haiku" and .effort=="default"' >/dev/null \
  && ok "(1) carries task_type + model tier + effort" || bad "(1) missing routing fields: $L"
printf '%s' "$L" | jq -e '.outcome=="pass" and .retries==0 and .wall_secs==42' >/dev/null \
  && ok "(1) carries first-try outcome + retry count + wall-clock" || bad "(1) missing outcome fields: $L"
printf '%s' "$L" | jq -e 'has("escalated_to") and has("ts") and has("schema")' >/dev/null \
  && ok "(1) carries escalation slot + timestamp + schema version" || bad "(1) missing envelope: $L"
[ "$(rows "$R")" = "1" ] && ok "(1) exactly ONE line appended" || bad "(1) wrong row count: $(rows "$R")"

# ── (2) CONSUMED by the real aggregator ────────────────────────────────────────
for i in 1 2 3; do
  "$CLI" --repo "$R" task --type lint --model haiku --outcome fail --retries 2 >/dev/null
done
C="$("$PY" "$SI" --repo "$R" collect)"
[ "$(printf '%s' "$C" | jq -r '.total_task_records')" = "4" ] \
  && ok "(2) self-improve collect READS the emitted rows (4 records)" \
  || bad "(2) collect saw $(printf '%s' "$C" | jq -r '.total_task_records') records"
[ "$(printf '%s' "$C" | jq -r '.cells[] | select(.task_type=="lint") | .pass_rate')" = "0.25" ] \
  && ok "(2) emitted rows aggregate to the comparable scalar (pass_rate 0.25)" \
  || bad "(2) wrong aggregated pass_rate"

# ── (3) NEVER-FAILS: unwritable target is a silent no-op at exit 0 ─────────────
R2="$(mk_repo unwritable)"
chmod a-w "$R2/.planning"
set +e
OUT="$("$CLI" --repo "$R2" task --type lint --model haiku --outcome pass 2>&1)"; RC=$?
set -e
chmod u+w "$R2/.planning"
[ "$RC" = "0" ] && ok "(3) unwritable metrics dir exits 0 (never fails a task)" \
  || bad "(3) unwritable dir exited $RC (would surface an error to the user)"
[ -z "$OUT" ] && ok "(3) unwritable metrics dir is SILENT (no stderr noise)" \
  || bad "(3) unwritable dir printed: $OUT"
[ ! -f "$R2/.planning/metrics.jsonl" ] && ok "(3) no partial row written" \
  || bad "(3) wrote a row into an unwritable dir"

# ── (4) NEVER-FAILS on a malformed call; --strict opts in to seeing it ────────
R3="$(mk_repo malformed)"
set +e
"$CLI" --repo "$R3" task --type lint --outcome pass >/dev/null 2>&1; RC=$?
set -e
[ "$RC" = "0" ] && ok "(4) missing required field exits 0 (never fails a task)" \
  || bad "(4) malformed call exited $RC"
[ "$(rows "$R3")" = "" ] && ok "(4) malformed call writes NO row" \
  || bad "(4) malformed call wrote $(rows "$R3") rows"
set +e
"$CLI" --repo "$R3" --strict task --type lint --outcome pass >/dev/null 2>&1; RC=$?
set -e
[ "$RC" != "0" ] && ok "(4) --strict surfaces the failure (exit $RC) for callers that want it" \
  || bad "(4) --strict swallowed a malformed call"

# ── (5) NO PROMPT CONTENT — free text is slugged + capped ─────────────────────
R4="$(mk_repo noleak)"
"$CLI" --repo "$R4" task \
  --type 'Fix the AWS key AKIA1234567890ABCDEF in src/config.ts and redeploy prod' \
  --model opus --outcome pass >/dev/null
L="$(last "$R4")"
printf '%s' "$L" | grep -q 'AKIA1234567890ABCDEF' \
  && bad "(5) LEAKED a secret-shaped token into the corpus: $L" \
  || ok "(5) free text cannot carry a secret into the corpus"
TT="$(printf '%s' "$L" | jq -r '.task_type')"
[ "${#TT}" -le 32 ] && ok "(5) task_type capped at 32 chars (got ${#TT})" \
  || bad "(5) task_type not capped: ${#TT} chars"
printf '%s' "$TT" | grep -Eq '^[a-z0-9][a-z0-9_-]*$' \
  && ok "(5) task_type is a strict slug ($TT)" || bad "(5) task_type not slugged: $TT"
printf '%s' "$L" | jq -e 'has("prompt") or has("body") or has("content") or has("files")' >/dev/null \
  && bad "(5) record carries a prompt/body/content/files key" \
  || ok "(5) no prompt/body/content/files key exists in the record"

# ── (6) INTEGRITY — off-ladder tier / bad outcome are DROPPED ─────────────────
R5="$(mk_repo integrity)"
"$CLI" --repo "$R5" task --type lint --model gpt-4 --outcome pass >/dev/null 2>&1 || true
[ "$(rows "$R5")" = "" ] && ok "(6) off-ladder model tier is DROPPED (corpus stays routable)" \
  || bad "(6) accepted an off-ladder model tier"
"$CLI" --repo "$R5" task --type lint --model haiku --outcome maybe >/dev/null 2>&1 || true
[ "$(rows "$R5")" = "" ] && ok "(6) non pass|fail outcome is DROPPED" \
  || bad "(6) accepted a non pass|fail outcome"

# ── (7) ATOMIC APPEND under concurrency ───────────────────────────────────────
R6="$(mk_repo concurrent)"
i=0
while [ "$i" -lt 24 ]; do
  "$CLI" --repo "$R6" task --type test --model sonnet --outcome pass --wall-secs "$i" &
  i=$((i+1))
done
wait
[ "$(rows "$R6")" = "24" ] && ok "(7) 24 concurrent emits -> 24 lines (no lost writes)" \
  || bad "(7) concurrent emits produced $(rows "$R6") lines"
BADLINES="$("$PY" -c '
import json,sys
n=0
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    try: json.loads(line)
    except Exception: n+=1
print(n)' "$R6/.planning/metrics.jsonl")"
[ "$BADLINES" = "0" ] && ok "(7) every concurrent line parses (no interleaving)" \
  || bad "(7) $BADLINES interleaved/corrupt lines"

# ── (8) FIRST-TRY IS THE SCALAR, `final` is separate ──────────────────────────
R7="$(mk_repo firsttry)"
"$CLI" --repo "$R7" task --type code --model sonnet --outcome fail --final pass \
       --retries 2 --wall-secs 300 >/dev/null
L="$(last "$R7")"
printf '%s' "$L" | jq -e '.outcome=="fail" and .final=="pass"' >/dev/null \
  && ok "(8) first-try FAIL + eventual PASS are recorded distinctly" \
  || bad "(8) conflated first-try with final: $L"
C="$("$PY" "$SI" --repo "$R7" collect)"
[ "$(printf '%s' "$C" | jq -r '.cells[0].pass_rate')" = "0.0" ] \
  && ok "(8) the routing scalar grades FIRST TRY (pass_rate 0.0, not 1.0)" \
  || bad "(8) scalar credited an eventual pass to the routing tier"
"$CLI" --repo "$R7" task --type code --model sonnet --outcome pass >/dev/null
L="$(last "$R7")"
printf '%s' "$L" | jq -e '.final=="pass"' >/dev/null \
  && ok "(8) --final defaults to --outcome when unstated" || bad "(8) final default wrong: $L"

# ── (9) ESCALATION ────────────────────────────────────────────────────────────
R8="$(mk_repo escalate)"
"$CLI" --repo "$R8" task --type code --model haiku --outcome fail --escalated-to sonnet >/dev/null
"$CLI" --repo "$R8" task --type code --model sonnet --outcome fail --escalated-to opus >/dev/null
"$CLI" --repo "$R8" task --type code --model opus --outcome pass >/dev/null
printf '%s' "$(last "$R8")" | jq -e '.escalated_to==null' >/dev/null \
  && ok "(9) a non-escalated task records escalated_to=null" || bad "(9) escalated_to not null"
E="$("$PY" -c '
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(",".join("%s->%s" % (r["model"], r["escalated_to"]) for r in rows if r.get("escalated_to")))
' "$R8/.planning/metrics.jsonl")"
[ "$E" = "haiku->sonnet,sonnet->opus" ] \
  && ok "(9) two-hop escalation reads haiku->sonnet->opus" || bad "(9) escalation chain wrong: $E"
C="$("$PY" "$SI" --repo "$R8" collect)"
[ "$(printf '%s' "$C" | jq -r '.cells | length')" = "3" ] \
  && ok "(9) escalation yields one clean observation PER TIER (3 cells)" \
  || bad "(9) escalation did not produce per-tier observations"

# ── (10) DREAM CONSUMES A CORPUS THIS BIN EMITTED ─────────────────────────────
# 24 lint-on-haiku tasks, 5 pass -> pass_rate 0.21, far below healthy, above floor.
R9="$(mk_repo dreamreal)"
i=0
while [ "$i" -lt 24 ]; do
  if [ "$i" -lt 5 ]; then O=pass; else O=fail; fi
  "$CLI" --repo "$R9" task --type lint --model haiku --outcome "$O" --retries 1 --wall-secs 30 >/dev/null
  i=$((i+1))
done
D="$("$PY" "$DREAM" --repo "$R9" run --json)"
[ "$(printf '%s' "$D" | jq -r '.honest_empty')" = "false" ] \
  && ok "(10) dream on a REAL emitted corpus is NOT honest_empty" \
  || bad "(10) dream still honest_empty on 24 real records"
[ "$(printf '%s' "$D" | jq -r '.counts.suggested_changes')" -ge 1 ] \
  && ok "(10) dream produces a real suggestion (not \"nothing to suggest\")" \
  || bad "(10) dream suggested nothing on real evidence"
grep -q 'hyp-esc-lint-haiku' "$(printf '%s' "$D" | jq -r '.report_path')" \
  && ok "(10) the morning report names the escalate hypothesis" \
  || bad "(10) report missing the hypothesis"

# ── (11) HONEST EMPTY SURVIVES ────────────────────────────────────────────────
R10="$(mk_repo emptycorpus)"
D="$("$PY" "$DREAM" --repo "$R10" run --json)"
[ "$(printf '%s' "$D" | jq -r '.honest_empty')" = "true" ] \
  && ok "(11) empty corpus -> honest_empty=true (guard intact)" \
  || bad "(11) honest_empty did not fire on an empty corpus"
grep -q 'Nothing to suggest' "$(printf '%s' "$D" | jq -r '.report_path')" \
  && ok "(11) report says \"Nothing to suggest\" rather than fabricating" \
  || bad "(11) empty report fabricated content"
R11="$(mk_repo parallelismonly)"
printf '%s\n' '{"ts":"2026-08-01T00:00:00Z","metric":"parallelism","total_turns":9,"parallel_ratio":0.2}' \
  > "$R11/.planning/metrics.jsonl"
D="$("$PY" "$DREAM" --repo "$R11" run --json)"
[ "$(printf '%s' "$D" | jq -r '.honest_empty')" = "true" ] \
  && ok "(11) a parallelism-only corpus is still honestly empty" \
  || bad "(11) non-task rows were mistaken for evidence"

# ── (12) SAMPLE-SIZE FLOOR — dream refuses to act below it ────────────────────
R12="$(mk_repo thin)"
i=0
while [ "$i" -lt 6 ]; do
  "$CLI" --repo "$R12" task --type lint --model haiku --outcome fail >/dev/null
  i=$((i+1))
done
D="$("$PY" "$DREAM" --repo "$R12" run --json)"
[ "$(printf '%s' "$D" | jq -r '.counts.suggested_changes')" = "0" ] \
  && ok "(12) 6 samples (below floor) -> ZERO routing suggestions" \
  || bad "(12) dream acted on 6 samples"
[ "$(printf '%s' "$D" | jq -r '.min_samples')" -ge 20 ] \
  && ok "(12) dream reports the enforced floor (>= 20)" \
  || bad "(12) dream did not report an enforced floor"
D="$("$PY" "$DREAM" --repo "$R12" run --min-samples 3 --json)"
[ "$(printf '%s' "$D" | jq -r '.counts.suggested_changes')" = "0" ] \
  && ok "(12) --min-samples 3 CANNOT argue the floor down" \
  || bad "(12) floor was overridden by --min-samples 3"
[ "$(printf '%s' "$D" | jq -r '.min_samples_floor_enforced')" = "true" ] \
  && ok "(12) dream flags that it clamped the caller's request up to the floor" \
  || bad "(12) floor clamp not reported"
grep -q 'sample-size floor' "$(printf '%s' "$D" | jq -r '.report_path')" \
  && ok "(12) the report explains the floor rather than silently doing nothing" \
  || bad "(12) report does not explain the floor"

# ── (13) FALSIFIABILITY — recommend AGAINST an obviously worse tier ───────────
# haiku is obviously worse at `code` (2/22) while opus is flawless (22/22).
R13="$(mk_repo falsify)"
i=0
while [ "$i" -lt 22 ]; do
  if [ "$i" -lt 2 ]; then O=pass; else O=fail; fi
  "$CLI" --repo "$R13" task --type code --model haiku --outcome "$O" --retries 3 >/dev/null
  "$CLI" --repo "$R13" task --type docs --model opus --outcome pass --retries 0 >/dev/null
  i=$((i+1))
done
H="$("$PY" "$SI" --repo "$R13" hypotheses --min-samples 20)"
printf '%s' "$H" | jq -e '.hypotheses[] | select(.id=="hyp-esc-code-haiku" and .proposal.from_model=="haiku" and .proposal.to_model=="sonnet")' >/dev/null \
  && ok "(13) obviously-worse tier -> recommends escalating AWAY from haiku" \
  || bad "(13) did not recommend against the worse tier"
printf '%s' "$H" | jq -e '[.hypotheses[] | select(.proposal.to_model=="haiku")] | length == 0' >/dev/null \
  && ok "(13) never recommends routing INTO the tier that is failing" \
  || bad "(13) recommended routing into the failing tier"
printf '%s' "$H" | jq -e '.hypotheses[] | select(.id=="hyp-cheap-docs-opus")' >/dev/null \
  && ok "(13) flawless expensive tier -> proposes the cheaper tier (cost win)" \
  || bad "(13) missed the cheapen hypothesis"

echo
echo "-----------------------------------"
# ROLL-UP FORMAT IS LOAD-BEARING, not cosmetic. test/run-all.sh:196 parses the board with
# `grep -oE '[0-9]+ passed, [0-9]+ failed'` and, per its rule 5, reports a suite whose counts
# it cannot parse as UNPARSED — "counts UNKNOWN, not assumed pass". This suite used to print
# "PASS: 41  FAIL: 0", which that regex never matches, so 41 green assertions scored as a
# question mark on every board run: indistinguishable from a suite that asserted NOTHING and
# exited 0. Emit the canonical "<suite>: N passed, M failed" the other 268 suites emit.
printf "heimdall-metric: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
