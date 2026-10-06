#!/usr/bin/env bash
# test/hmd-metrics.test.sh — `hmd metrics --json` and `hmd weekly-review --week N` (RP10 items 5-6).
#
# WHAT THIS PROVES
#   [M] METRICS  bin/heimdall-metrics prints exactly the eight plan-1 keys, in order. A number is null
#                (a count is 0) unless a real on-disk source supports it: the empty tree is exactly the
#                spec's default object; Study B (judge-calibration) rows never become an agent
#                false-green rate; a Study A rate needs a headline-eligible study; a receipt's cost is a
#                basis only when a model was invoked and a non-zero cost recorded (the offline engine
#                writes cost 0.0 by construction), so usd_per_* stays null until that exists; an empty
#                denominator is null, never 0/0; invalid receipt files are skipped, never counted.
#   [W] WEEKLY   bin/heimdall-weekly-review --week N prints the plan-17 template, fills what the metrics
#                and git can support, leaves the two unsourced lines blank, and rejects a bad N with 2.
#   [E] E2E      real receipts issued by `hmd attack --receipt` are read as valid receipts and, being
#                zero-cost with no model, never yield a $ figure. Skipped (loudly) without node or an
#                Ed25519 backend.
#   [X] MUTANTS  the [M] and [W] assertions are re-run against throwaway copies of the scripts, each with
#                one planted defect (fabricating a 0, counting Study B as an agent rate, dividing 0/0,
#                ...). Every mutant must make an assertion FAIL, for the reason the mutation is about;
#                an equivalent (comment-only) copy must NOT be flagged.
#
# Hermetic: HOME, HEIMDALL_HOME and TMPDIR point into a throwaway dir; no network, no model call.
#
#   bash test/hmd-metrics.test.sh                                     all sections
#   HMD_METRICS_TEST_SECTIONS="M W" bash test/hmd-metrics.test.sh     only those
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
METRICS="$REPO/bin/heimdall-metrics"
WEEKLY="$REPO/bin/heimdall-weekly-review"
BENCH_CLI="$REPO/bin/benchmark"
SECTIONS="${HMD_METRICS_TEST_SECTIONS:-M W E X}"

PASS=0; FAIL=0; QUIET=0; FAILED=""
ok()  { PASS=$((PASS+1)); [ "$QUIET" = 1 ] || printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED="$FAILED|$1"; [ "$QUIET" = 1 ] || printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
say() { [ "$QUIET" = 1 ] || echo "$@"; }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
jqok()  { local desc="$1" file="$2" expr="$3"; if jq -e "$expr" "$file" >/dev/null 2>&1; then ok "$desc"; else bad "$desc  [jq: $expr]"; fi; }
section() { case " $SECTIONS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

for tool in jq python3 git; do command -v "$tool" >/dev/null 2>&1 || { echo "$tool required" >&2; exit 2; }; done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmd-metrics-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" HEIMDALL_HOME="$TMP/home/.heimdall" TMPDIR="$TMP/tmp" PYTHONDONTWRITEBYTECODE=1
mkdir -p "$HOME" "$HEIMDALL_HOME" "$TMPDIR"
# A version manager (pyenv, asdf) puts a slow shim first on PATH and this suite starts python3 about a hundred
# times: link the interpreter the shim resolves to and put it first, once.
PY_REAL="$(python3 -c 'import sys; print(sys.executable)')"
mkdir -p "$TMP/bin"; ln -sf "$PY_REAL" "$TMP/bin/python3"; export PATH="$TMP/bin:$PATH"
unset RUNHMD_RECEIPT_DIR HMD_METRICS_RECEIPTS_DIR HMD_METRICS_BENCH_RESULTS_DIR FG_SUITE_DIR GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_CEILING_DIRECTORIES="$TMP"   # a fixture dir is never "inside" the checkout this suite runs from

# The binaries under test. [X] swaps these for mutant copies and re-runs the same assertions.
M_BIN="$METRICS"; W_BIN="$WEEKLY"
runm() { MOUT="$TMP/m.out"; MERR="$TMP/m.err"; "$M_BIN" "$@" >"$MOUT" 2>"$MERR" </dev/null; MRC=$?; }
runw() { WOUT="$TMP/w.out"; WERR="$TMP/w.err"; "$W_BIN" "$@" >"$WOUT" 2>"$WERR" </dev/null; WRC=$?; }
# same_as <file>: the last metrics run exited 0, printed something, and printed exactly <file> (two empty outputs are not "equal")
same_as() { [ "$MRC" -eq 0 ] && [ -s "$MOUT" ] && cmp -s "$MOUT" "$1"; }

DEFAULT_JSON='{"false_green_rate":null,"catch_rate":null,"denial_precision":null,"real_bugs_caught":0,"usd_per_proven_pr":null,"usd_per_real_bug":null,"active_developers":0,"partner_teams_active_weekly":0}'
KEYS_JSON='["false_green_rate","catch_rate","denial_precision","real_bugs_caught","usd_per_proven_pr","usd_per_real_bug","active_developers","partner_teams_active_weekly"]'

# ══════════════════════════════════════════════════════════════════════════════
# Fixtures (generated once; nothing here is a secret-shaped literal: the long runs are built at run time)
# ══════════════════════════════════════════════════════════════════════════════
FX="$TMP/fx"; mkdir -p "$FX"
python3 - "$FX" "$REPO" <<'PY' || { echo "fixture generation failed" >&2; exit 2; }
import datetime, json, os, shutil, sys

fx, repo = sys.argv[1:3]
HEX64, SIG = "0" * 64, "A" * 86 + "=="
MODEL = "fixture-model"
now = datetime.datetime.now(datetime.timezone.utc)


def stamp(days_ago):
    return (now - datetime.timedelta(days=days_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


# ── receipts: schema-valid runhmd.receipt/1 documents (unsigned: the reader checks structure, not signatures)
def receipt(rid, verdict, cost, model, days_ago):
    proven = verdict == "PROVEN"
    return {
        "schema": "runhmd.receipt/1", "id": rid, "created_at": stamp(days_ago), "visibility": "private",
        "verdict": verdict, "subject": {"kind": "path", "head_sha": None, "tree_sha256": HEX64},
        "attacks": {"total": 24, "survived": 24, "killed": 0} if proven else {"total": 24, "survived": 21, "killed": 3},
        "findings": [] if proven else [{"id": "f-0001", "title": "fixture finding", "severity": "high",
                                        "category": "concurrency", "digest": "sha256:" + HEX64}],
        "agent": {"name": "claude-code" if model else "none", "model": model},
        "cost_usd": cost, "duration_s": 1.25, "tool": {"name": "hmd", "version": "0.0.0"},
        "verdict_sha256": HEX64, "key_id": "0" * 16, "signature": SIG,
    }


def store(name, docs):
    for doc in docs:
        write(os.path.join(fx, name, doc["id"] + ".json"), json.dumps(doc, sort_keys=True) + "\n")


# the offline engine's receipts: cost 0.0 and no model, by construction
store("r-offline", [receipt("off-proven-1", "PROVEN", 0, None, 1), receipt("off-denied-1", "DENIED", 0, None, 1)])
# a measured cost basis: a model was invoked and a non-zero cost recorded (total 1.0, two PROVEN)
store("r-measured", [receipt("m-proven-1", "PROVEN", 0.25, MODEL, 1), receipt("m-proven-2", "PROVEN", 0.25, MODEL, 1.5),
                     receipt("m-denied-1", "DENIED", 0.5, MODEL, 2)])
store("r-measured-denied-only", [receipt("md-denied-1", "DENIED", 0.5, MODEL, 1)])
# a model with cost 0 is not a measured basis; only e-meas-1 is
store("r-edge", [receipt("e-zero-1", "PROVEN", 0, MODEL, 1), receipt("e-meas-1", "PROVEN", 0.5, MODEL, 1)])
store("r-old", [receipt("old-proven-1", "PROVEN", 0.25, MODEL, 30), receipt("old-proven-2", "PROVEN", 0.25, MODEL, 31),
                receipt("old-denied-1", "DENIED", 0.5, MODEL, 32)])
# one valid receipt among files that are not: five .json files must be skipped, the .txt and .tmp ignored
store("r-mixed", [receipt("x-valid-1", "PROVEN", 0.25, MODEL, 1)])
mixed = os.path.join(fx, "r-mixed")
write(os.path.join(mixed, "garbage.json"), "not json{\n")
write(os.path.join(mixed, "array.json"), "[1, 2]\n")
write(os.path.join(mixed, "verdict.json"), json.dumps({"schema": "runhmd.verdict/1"}) + "\n")
bad = receipt("bad-cost", "PROVEN", 0.25, MODEL, 1)
bad["cost_usd"] = -1
write(os.path.join(mixed, "bad-cost.json"), json.dumps(bad) + "\n")
write(os.path.join(mixed, "renamed.json"), json.dumps(receipt("x-valid-2", "PROVEN", 0.25, MODEL, 1)) + "\n")
write(os.path.join(mixed, "notes.txt"), "not a receipt\n")
write(os.path.join(mixed, ".x-valid-3.abcd.tmp"), "a partial write\n")
os.makedirs(os.path.join(fx, "empty-receipts"))
os.makedirs(os.path.join(fx, "empty-results"))


# ── benchmark rows: fg.run/1 (Study A, one row per run and arm) and the committed Study B rows
def run_rows(agent, specs, tag="t"):
    rows = []
    for i, (claim, truth, verdict, label) in enumerate(specs):
        for arm in ("alone", "runhmd"):
            rows.append({"schema": "fg.run/1", "task_id": "%s-%03d" % (tag, i), "agent": agent, "arm": arm,
                         "run_id": "r%03d" % i, "agent_claim": claim, "ground_truth": truth,
                         "verdict": verdict if arm == "runhmd" else None,
                         "human_label": label if arm == "runhmd" else None,
                         "human_interventions": 0, "infra_error": None, "anchor": False})
    return rows


def jsonl(path, rows):
    write(path, "".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))


TP, FP = "true_positive", "false_positive"
# one agent, 7 runs: 6 false greens, 5 DENIED (4 confirmed real, 1 not): below the headline threshold
small = [("done", "fail", "DENIED", TP)] * 4 + [("done", "fail", "DENIED", FP), ("done", "pass", "PROVEN", None),
                                                 ("done", "fail", "PROVEN", None)]
jsonl(os.path.join(fx, "b-study-a-small", "runhmd.jsonl"), run_rows("a1", small, "s"))
# two agents x 60 tasks: 108 of 120 'done' claims false (0.9); 100 of those 108 DENIED (0.925926);
# 100 DENIED findings rated, 90 true positive (0.9)
per_agent = ([("done", "fail", "DENIED", TP)] * 45 + [("done", "fail", "DENIED", FP)] * 5
             + [("done", "fail", "PROVEN", None)] * 4 + [("done", "pass", "PROVEN", None)] * 6)
jsonl(os.path.join(fx, "b-study-a-full", "runhmd.jsonl"), run_rows("a1", per_agent) + run_rows("a2", per_agent))
# the committed Study B rows (judge calibration on mechanical mutants): real rows, copied, never edited
src = os.path.join(repo, "evals", "benchmark", "false-green", "results")
os.makedirs(os.path.join(fx, "b-study-b"))
for name in ("design-set.jsonl", "judge-calibration.jsonl"):
    shutil.copy(os.path.join(src, name), os.path.join(fx, "b-study-b", name))
write(os.path.join(fx, "b-malformed", "bad.jsonl"), "this is not json\n")
PY
E_RC="$FX/empty-receipts"; E_BR="$FX/empty-results"

# a bench summary computed by the real CLI: the control that a null here is a decision, not an absence
summary_of() { "$BENCH_CLI" summarize --suite false-green --in "$1" --json 2>/dev/null; }

# a git repo with 3 commits in the last 3 days and 2 older than a month (git's --since reads the committer date)
GR="$FX/gitrepo"; mkdir -p "$GR"
git -C "$GR" init -q >/dev/null 2>&1
fixture_commit() {  # fixture_commit <days ago> <message>
  local when
  when="$(python3 -c 'import datetime, sys; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=float(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1")"
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$GR" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m "$2" >/dev/null 2>&1
}
fixture_commit 40 "old one"; fixture_commit 35 "old two"; fixture_commit 3 "recent one"; fixture_commit 2 "recent two"; fixture_commit 0.5 "recent three"

# PATH directories that hold only the tools a script needs, minus one: for the infrastructure exit (5)
mkpath() {  # mkpath <dir> <tool>...
  local dir="$1" tool src; shift; mkdir -p "$dir"
  for tool in "$@"; do
    case "$tool" in
      python3) src="$PY_REAL" ;;      # not the version-manager shim: it needs its manager on this restricted PATH
      *)       src="$(command -v "$tool")" ;;
    esac
    [ -n "$src" ] && ln -sf "$src" "$dir/$tool"
  done
}
BASIC_TOOLS=(bash sh env dirname basename readlink sed awk cat date head tail tr wc sort cut mktemp rm cp mkdir ls cmp diff uname)
PATH_NOJQ="$TMP/path-nojq"; PATH_NOPY="$TMP/path-nopy"
mkpath "$PATH_NOJQ" "${BASIC_TOOLS[@]}" git python3
mkpath "$PATH_NOPY" "${BASIC_TOOLS[@]}" git jq
# the summarizer's own output for the benchmark fixtures, from the real CLI (controls; independent of any mutant)
SUM_B="$(summary_of "$FX/b-study-b")"; SUM_SMALL="$(summary_of "$FX/b-study-a-small")"; SUM_FULL="$(summary_of "$FX/b-study-a-full")"

# ══════════════════════════════════════════════════════════════════════════════
# [M] METRICS
# ══════════════════════════════════════════════════════════════════════════════
assertions_metrics() {
  say "[M] hmd metrics (bin/heimdall-metrics)"
  if [ -x "$M_BIN" ]; then ok "bin/heimdall-metrics exists and is executable"; else bad "bin/heimdall-metrics exists and is executable"; fi

  say "  -- the empty tree is exactly the spec's default object --"
  runm --json --receipts "$E_RC" --bench-results "$E_BR"
  if [ "$MRC" -eq 0 ] && [ "$(cat "$MOUT")" = "$DEFAULT_JSON" ] && [ "$(wc -l <"$MOUT" | tr -d ' ')" = 1 ] && [ ! -s "$MERR" ]; then
    ok "empty sources: exit 0, one line, exactly the spec default object, stderr silent"
  else
    bad "empty sources: exit 0, one line, exactly the spec default object, stderr silent (rc=$MRC, got: $(head -c 300 "$MOUT"), stderr: $(head -c 200 "$MERR"))"
  fi
  jqok "RP10 acceptance: jq -e 'has(\"false_green_rate\")'" "$MOUT" 'has("false_green_rate")'
  jqok "the eight keys, in order, and nothing else" "$MOUT" "keys_unsorted == $KEYS_JSON"
  runm --json --receipts "$TMP/no-such-receipts" --bench-results "$TMP/no-such-results"
  if [ "$MRC" -eq 0 ] && [ "$(cat "$MOUT")" = "$DEFAULT_JSON" ] && [ ! -s "$MERR" ]; then
    ok "missing source dirs are unmeasured, never an error (exit 0, default object, silent)"
  else
    bad "missing source dirs are unmeasured, never an error (rc=$MRC, stderr: $(head -c 200 "$MERR"))"
  fi

  say "  -- sources are overridable by flag and environment --"
  runm --json --receipts "$FX/r-measured" --bench-results "$FX/b-study-a-small"; cp "$MOUT" "$TMP/flags.out"
  jqok "control: the flag run reads both fixtures (real_bugs_caught 4, usd_per_proven_pr 0.5)" "$TMP/flags.out" '.real_bugs_caught==4 and .usd_per_proven_pr==0.5'
  HMD_METRICS_RECEIPTS_DIR="$FX/r-measured" HMD_METRICS_BENCH_RESULTS_DIR="$FX/b-study-a-small" runm --json
  if same_as "$TMP/flags.out"; then ok "HMD_METRICS_RECEIPTS_DIR and HMD_METRICS_BENCH_RESULTS_DIR select the sources (same output as the flags)"; else bad "environment overrides differ from the flags"; fi
  HMD_METRICS_RECEIPTS_DIR="$TMP/no-such" HMD_METRICS_BENCH_RESULTS_DIR="$TMP/no-such" runm --json --receipts "$FX/r-measured" --bench-results "$FX/b-study-a-small"
  if same_as "$TMP/flags.out"; then ok "a flag beats the environment"; else bad "a flag did not beat the environment"; fi
  RUNHMD_RECEIPT_DIR="$FX/r-measured" runm --json --bench-results "$FX/b-study-a-small"
  if same_as "$TMP/flags.out"; then ok "RUNHMD_RECEIPT_DIR (the store hmd attack --receipt writes) is the default receipts source"; else bad "RUNHMD_RECEIPT_DIR was not honoured"; fi
  HMD_METRICS_RECEIPTS_DIR="$FX/r-measured" RUNHMD_RECEIPT_DIR="$FX/r-offline" runm --json --bench-results "$FX/b-study-a-small"
  if same_as "$TMP/flags.out"; then ok "HMD_METRICS_RECEIPTS_DIR beats RUNHMD_RECEIPT_DIR"; else bad "HMD_METRICS_RECEIPTS_DIR did not beat RUNHMD_RECEIPT_DIR"; fi
  mkdir -p "$TMP/hh/runhmd"; rm -rf "$TMP/hh/runhmd/receipts"; cp -R "$FX/r-measured" "$TMP/hh/runhmd/receipts"
  HEIMDALL_HOME="$TMP/hh" runm --json --bench-results "$FX/b-study-a-small"
  if same_as "$TMP/flags.out"; then ok "with no override the store is \$HEIMDALL_HOME/runhmd/receipts"; else bad "\$HEIMDALL_HOME/runhmd/receipts was not the default store"; fi

  say "  -- human render, --help, usage errors --"
  runm --receipts "$E_RC" --bench-results "$E_BR"
  human_ok=1
  [ "$MRC" -eq 0 ] || human_ok=0
  for k in false_green_rate catch_rate denial_precision usd_per_proven_pr usd_per_real_bug; do
    grep -Eq "^  $k +unmeasured\$" "$MOUT" || human_ok=0
  done
  for k in real_bugs_caught active_developers partner_teams_active_weekly; do
    grep -Eq "^  $k +0\$" "$MOUT" || human_ok=0
  done
  if [ "$human_ok" = 1 ]; then ok "without --json: label + value per metric, 'unmeasured' for null, 0 for an empty count"
  else bad "without --json: label + value per metric, 'unmeasured' for null, 0 for an empty count (rc=$MRC): $(head -c 400 "$MOUT")"; fi
  runm --help
  help_ok=1
  [ "$MRC" -eq 0 ] || help_ok=0
  for phrase in 'bin/benchmark summarize --suite false-green' 'fg_summary.py' 'Study B' 'PREREG.md' \
                'docs/schemas/runhmd.receipt.v1.json' 'bin/lib/runhmd_attack.py' 'RUNHMD_RECEIPT_DIR' \
                'HMD_METRICS_RECEIPTS_DIR' 'HMD_METRICS_BENCH_RESULTS_DIR' 'control plane' \
                'partner_teams_active_weekly' 'no local source'; do
    grep -qF -- "$phrase" "$MOUT" || { help_ok=0; say "    --help does not mention: $phrase"; }
  done
  if [ "$help_ok" = 1 ]; then ok "--help exits 0 and names every source, the local scope and the no-source count"
  else bad "--help exits 0 and names every source, the local scope and the no-source count (rc=$MRC)"; fi
  runm --bogus
  if [ "$MRC" -eq 2 ] && grep -q -- '--bogus' "$MERR" && [ ! -s "$MOUT" ]; then ok "unknown option: exit 2, named on stderr, nothing on stdout"; else bad "unknown option (rc=$MRC)"; fi
  runm --receipts
  if [ "$MRC" -eq 2 ] && [ ! -s "$MOUT" ]; then ok "--receipts without a value: exit 2"; else bad "--receipts without a value (rc=$MRC)"; fi
  runm --bench-results
  if [ "$MRC" -eq 2 ] && [ ! -s "$MOUT" ]; then ok "--bench-results without a value: exit 2"; else bad "--bench-results without a value (rc=$MRC)"; fi
  runm stray-argument
  if [ "$MRC" -eq 2 ] && [ ! -s "$MOUT" ]; then ok "a positional argument: exit 2"; else bad "a positional argument (rc=$MRC)"; fi
  runm --json --evidence --receipts "$FX/r-measured" --bench-results "$FX/b-study-a-small"
  jqok "--evidence appends an \"evidence\" object after the same eight keys" "$MOUT" "(keys_unsorted[0:8] == $KEYS_JSON) and (keys_unsorted | length) == 9 and has(\"evidence\")"

  say "  -- the benchmark: Study A only, and only when the summarizer calls it a headline --"
  if printf '%s' "$SUM_B" | jq -e '.judge_calibration.primary.catch_rate.rate != null and .judge_calibration.primary.naive_false_green_rate.rate != null and .judge_calibration.primary.denial_precision.rate != null and .study_a.status == "no-data"' >/dev/null 2>&1; then
    ok "control: the summarizer reports non-null Study B rates for these rows (so a null below is a decision, not an absence)"
  else
    bad "control: the Study B fixture does not give non-null judge-calibration rates"
  fi
  runm --json --receipts "$E_RC" --bench-results "$FX/b-study-b"
  if [ "$MRC" -eq 0 ] && [ "$(cat "$MOUT")" = "$DEFAULT_JSON" ]; then
    ok "Study B rows only: false_green_rate, catch_rate and denial_precision stay null (a judge-calibration rate is never an agent false-green rate)"
  else
    bad "Study B rows only: a judge-calibration number leaked into the metrics (rc=$MRC, got: $(head -c 300 "$MOUT"))"
  fi
  if printf '%s' "$SUM_SMALL" | jq -e '.catch_rate != null and .false_green_rate_by_agent.a1 != null and .study_a.headline_eligible == false' >/dev/null 2>&1; then
    ok "control: the summarizer has Study A rates for 7 runs by one agent, and calls them not headline-eligible"
  else
    bad "control: the small Study A fixture is not a below-threshold study"
  fi
  runm --json --receipts "$E_RC" --bench-results "$FX/b-study-a-small"
  jqok "Study A below the headline threshold: false_green_rate, catch_rate and denial_precision are null" "$MOUT" '.false_green_rate==null and .catch_rate==null and .denial_precision==null'
  jqok "real_bugs_caught counts only DENIED runhmd rows a human labelled true_positive (4 of 5 rated; the false_positive is not counted)" "$MOUT" '.real_bugs_caught==4'
  SF="$SUM_FULL"
  runm --json --receipts "$E_RC" --bench-results "$FX/b-study-a-full"
  if jq -n -e --argjson s "$SF" --slurpfile m "$MOUT" '$m[0] | (.false_green_rate == $s.study_a.pooled.false_green_rate.rate) and (.catch_rate == $s.catch_rate) and (.denial_precision == $s.denial_precision)' >/dev/null 2>&1; then
    ok "a headline-eligible Study A: the three rates are exactly the summarizer's own numbers (reused, not recomputed)"
  else
    bad "the rates differ from the summarizer's output for the eligible Study A fixture"
  fi
  jqok "headline-eligible Study A values: false_green_rate 0.9, catch_rate 0.925926, denial_precision 0.9 (>=100 rated), real_bugs_caught 90" "$MOUT" \
    '.false_green_rate==0.9 and .catch_rate==0.925926 and .denial_precision==0.9 and .real_bugs_caught==90 and .usd_per_proven_pr==null and .usd_per_real_bug==null'
  runm --json --receipts "$E_RC" --bench-results "$FX/b-malformed"
  if [ "$MRC" -eq 0 ] && [ "$(cat "$MOUT")" = "$DEFAULT_JSON" ] && grep -q 'warning' "$MERR"; then
    ok "unreadable benchmark rows: warned on stderr, every benchmark number unmeasured, exit 0 (never a quiet skip)"
  else
    bad "unreadable benchmark rows (rc=$MRC, stderr: $(head -c 200 "$MERR"), stdout: $(head -c 200 "$MOUT"))"
  fi

  say "  -- receipts: what counts, and when a cost is a measured basis --"
  runm --json --receipts "$FX/r-offline" --bench-results "$FX/b-study-a-small"
  jqok "offline-engine receipts (cost 0.0, no model) are never a cost basis: usd_per_proven_pr and usd_per_real_bug stay null even with 4 confirmed bugs" "$MOUT" \
    '.usd_per_proven_pr==null and .usd_per_real_bug==null and .real_bugs_caught==4 and .active_developers==0'
  runm --json --evidence --receipts "$FX/r-measured" --bench-results "$FX/b-study-a-small"
  jqok "measured receipts (1.0 USD over 2 PROVEN, 4 confirmed bugs): usd_per_proven_pr 0.5, usd_per_real_bug 0.25, 3 receipts this week = 1 active developer" "$MOUT" \
    '.usd_per_proven_pr==0.5 and .usd_per_real_bug==0.25 and .active_developers==1'
  jqok "--evidence shows the counts behind the numbers" "$MOUT" \
    '.evidence.receipts.present==true and .evidence.receipts.valid==3 and .evidence.receipts.skipped==0 and .evidence.receipts.in_window==3 and .evidence.receipts.measured==3 and .evidence.receipts.usd_total_measured==1 and .evidence.receipts.proven_measured==2 and .evidence.benchmark.true_positives==4 and .evidence.benchmark.n_rated==5 and .evidence.benchmark.headline_eligible==false and .evidence.window_days==7'
  runm --json --receipts "$FX/r-measured-denied-only" --bench-results "$FX/b-study-a-small"
  if [ "$MRC" -eq 0 ] && jq -e '.usd_per_proven_pr==null and .usd_per_real_bug==0.125' "$MOUT" >/dev/null 2>&1; then
    ok "no PROVEN receipt: usd_per_proven_pr is null (empty PROVEN denominator, never 0/0) while usd_per_real_bug is 0.5/4"
  else
    bad "no PROVEN receipt: usd_per_proven_pr is null (empty PROVEN denominator, never 0/0) while usd_per_real_bug is 0.5/4 (rc=$MRC, stdout: $(head -c 200 "$MOUT"), stderr: $(head -c 200 "$MERR"))"
  fi
  runm --json --receipts "$FX/r-measured" --bench-results "$E_BR"
  jqok "no confirmed bug: usd_per_real_bug is null (empty denominator) while usd_per_proven_pr is 0.5" "$MOUT" '.usd_per_proven_pr==0.5 and .usd_per_real_bug==null'
  runm --json --receipts "$FX/r-edge" --bench-results "$E_BR"
  jqok "a model with cost 0 is not a measured basis: only the 0.5 receipt is (1 PROVEN, not 2)" "$MOUT" '.usd_per_proven_pr==0.5'
  runm --json --evidence --receipts "$FX/r-old" --bench-results "$E_BR"
  jqok "receipts older than 7 days: not an active developer, but cumulative cost still counts (3 valid, 0 this week, 0.5 per PROVEN)" "$MOUT" \
    '.active_developers==0 and .usd_per_proven_pr==0.5 and .evidence.receipts.valid==3 and .evidence.receipts.in_window==0'
  runm --json --evidence --receipts "$FX/r-mixed" --bench-results "$E_BR"
  if [ "$MRC" -eq 0 ] && jq -e '.evidence.receipts.valid==1 and .evidence.receipts.skipped==5 and .usd_per_proven_pr==0.25' "$MOUT" >/dev/null 2>&1 && grep -q 'skipped 5' "$MERR"; then
    ok "invalid files in the store (not JSON, an array, a verdict, a bad cost, a receipt under another id) are skipped and reported on stderr, never counted"
  else
    bad "invalid files in the store (not JSON, an array, a verdict, a bad cost, a receipt under another id) are skipped and reported on stderr, never counted (rc=$MRC, stdout: $(head -c 300 "$MOUT"), stderr: $(head -c 200 "$MERR"))"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# [W] WEEKLY
# ══════════════════════════════════════════════════════════════════════════════
# the plan-17 template, as it must print: <week> <active> <tasks> <bugs> <denial precision> <$ per proven PR> <commits>
expect_review() {
  cat <<EOF
## Week $1 review

### Numbers
- Active developers: $2
- Tasks verified: $3
- Confirmed real bugs caught: $4
- Denial precision: $5
- \$ per proven PR: $6
- Overnight users:
- Developer conversations held:
- Commits shipped: $7

### What users said (verbatim quotes)
-

### What surprised me
-

### Decisions
-

### Next week's one priority
-
EOF
}
# the review without its one window line (and the blank line after it), whose date is the clock's
strip_window() { awk '/^Window: /{ getline; next } { print }' "$1"; }
# same_review <description> <expected review text>: the last weekly run exited 0 and printed exactly that
same_review() {
  local desc="$1" want="$2" got
  got="$(diff <(strip_window "$WOUT") <(printf '%s\n' "$want") 2>&1)"
  if [ "$WRC" -eq 0 ] && [ -z "$got" ]; then ok "$desc"; else bad "$desc (rc=$WRC, diff: $(printf '%s' "$got" | head -8 | tr '\n' '|'))"; fi
}

assertions_weekly() {
  say "[W] hmd weekly-review (bin/heimdall-weekly-review)"
  if [ -x "$W_BIN" ]; then ok "bin/heimdall-weekly-review exists and is executable"; else bad "bin/heimdall-weekly-review exists and is executable"; fi

  say "  -- the template, filled from the metrics and git --"
  runw --week 7 --repo "$GR" --receipts "$FX/r-measured" --bench-results "$FX/b-study-a-small"
  same_review "filled review: exactly the plan-17 template with the Numbers block filled (4 from hmd metrics, tasks verified and commits from receipts and git)" \
    "$(expect_review 7 1 3 4 unmeasured 0.5 3)"
  if [ ! -s "$WERR" ]; then ok "a clean run is silent on stderr"; else bad "a clean run wrote to stderr: $(head -c 200 "$WERR")"; fi
  missing=""
  for line in '- Active developers: 1' '- Confirmed real bugs caught: 4' '- Denial precision: unmeasured' '- $ per proven PR: 0.5'; do
    grep -qxF -- "$line" "$WOUT" || missing="$missing [$line]"
  done
  if [ -z "$missing" ]; then ok "the four metric lines are filled from hmd metrics --json ('unmeasured' for null)"; else bad "metric lines missing:$missing"; fi
  missing=""
  for line in '- Overnight users:' '- Developer conversations held:'; do grep -qxF -- "$line" "$WOUT" || missing="$missing [$line]"; done
  if [ -z "$missing" ]; then ok "manual lines are left BLANK for the human: Overnight users and Developer conversations held have no source and are never invented"
  else bad "manual lines are left BLANK for the human: Overnight users and Developer conversations held have no source and are never invented (not blank:$missing)"; fi
  if [ "$(grep -c '^Window: trailing 7 days' "$WOUT")" = 1 ]; then ok "exactly one line states the window (trailing 7 days)"; else bad "the window line is missing or repeated"; fi
  if [ "$(awk '/^### Numbers/{f=1;next} /^###/{f=0} f && /^- /' "$WOUT" | wc -l | tr -d ' ')" = 8 ]; then ok "the Numbers block has exactly the eight plan-17 lines"; else bad "the Numbers block is not eight lines"; fi

  runw --week 1 --repo "$E_BR" --receipts "$E_RC" --bench-results "$E_BR"
  same_review "empty sources, not a git repo: unmeasured for every null, tasks verified and commits shipped included, never a made-up 0" \
    "$(expect_review 1 0 unmeasured 0 unmeasured unmeasured unmeasured)"
  if grep -q 'warning' "$WERR"; then ok "an uncountable commit history is warned about on stderr, not hidden"; else bad "no warning for the uncountable commit history"; fi
  runw --week 12 --repo "$GR" --receipts "$FX/r-measured" --bench-results "$FX/b-study-a-full"
  same_review "a headline-eligible Study A: denial precision and the confirmed-bug count come through (0.9, 90)" "$(expect_review 12 1 3 90 0.9 0.5 3)"
  runw --week 2 --repo "$GR" --receipts "$FX/r-old" --bench-results "$E_BR"
  if [ "$WRC" -eq 0 ] && grep -qxF -- '- Tasks verified: 0' "$WOUT"; then ok "tasks verified counts this week's receipts: 0 when the store only holds older ones"; else bad "tasks verified with only old receipts"; fi
  runw --week 2 --repo "$GR" --receipts "$FX/r-mixed" --bench-results "$E_BR"
  if [ "$WRC" -eq 0 ] && grep -qxF -- '- Tasks verified: 1' "$WOUT"; then ok "tasks verified counts only valid receipts (1 of the 6 files in the store)"; else bad "tasks verified over a store with invalid files"; fi
  (cd "$GR" && "$W_BIN" --week 7 --receipts "$FX/r-measured" --bench-results "$E_BR" >"$WOUT" 2>"$WERR" </dev/null); WRC=$?
  if [ "$WRC" -eq 0 ] && grep -qxF -- '- Commits shipped: 3' "$WOUT"; then ok "with no --repo the repo is the current directory"; else bad "default repo (rc=$WRC)"; fi

  say "  -- --json --"
  runw --week 7 --json --repo "$GR" --receipts "$FX/r-measured" --bench-results "$FX/b-study-a-small"
  if [ "$WRC" -eq 0 ] && [ "$(wc -l <"$WOUT" | tr -d ' ')" = 1 ] && jq -e '
      (keys_unsorted == ["week","window_days","numbers"]) and .week==7 and .window_days==7
      and (.numbers | keys_unsorted) == ["active_developers","tasks_verified","confirmed_real_bugs_caught","denial_precision","usd_per_proven_pr","overnight_users","developer_conversations_held","commits_shipped"]
      and .numbers.active_developers==1 and .numbers.tasks_verified==3 and .numbers.confirmed_real_bugs_caught==4
      and .numbers.denial_precision==null and .numbers.usd_per_proven_pr==0.5 and .numbers.commits_shipped==3
      and .numbers.overnight_users==null and .numbers.developer_conversations_held==null' "$WOUT" >/dev/null 2>&1; then
    ok "--json: {week, window_days, numbers} with the eight numbers; the two unsourced ones are null"
  else
    bad "--json shape (rc=$WRC): $(head -c 400 "$WOUT")"
  fi

  say "  -- usage errors: N is a positive integer --"
  for value in 0 x -1 1.5 007 "" 1234567890123; do
    runw --week "$value"
    if [ "$WRC" -eq 2 ] && [ ! -s "$WOUT" ] && [ -s "$WERR" ]; then ok "bad --week '$value': exit 2, a message on stderr, no review on stdout"; else bad "bad --week '$value' (rc=$WRC, stdout: $(head -c 100 "$WOUT"))"; fi
  done
  runw
  if [ "$WRC" -eq 2 ] && [ ! -s "$WOUT" ]; then ok "no --week at all: exit 2"; else bad "no --week (rc=$WRC)"; fi
  runw --week
  if [ "$WRC" -eq 2 ] && [ ! -s "$WOUT" ]; then ok "--week without a value: exit 2"; else bad "--week without a value (rc=$WRC)"; fi
  runw --week 1 --bogus
  if [ "$WRC" -eq 2 ] && grep -q -- '--bogus' "$WERR" && [ ! -s "$WOUT" ]; then ok "unknown option: exit 2, named on stderr"; else bad "unknown option (rc=$WRC)"; fi
  runw --week 1 stray
  if [ "$WRC" -eq 2 ] && [ ! -s "$WOUT" ]; then ok "a positional argument: exit 2"; else bad "a positional argument (rc=$WRC)"; fi
  runw --week 1 --receipts
  if [ "$WRC" -eq 2 ] && [ ! -s "$WOUT" ]; then ok "--receipts without a value: exit 2"; else bad "--receipts without a value (rc=$WRC)"; fi
  runw --help
  help_ok=1
  [ "$WRC" -eq 0 ] || help_ok=0
  for phrase in 'plan section 17' 'trailing 7 days' 'BLANK' 'Overnight users' 'git rev-list --count --since' 'heimdall-metrics --json' '--week N' '--repo'; do
    grep -qF -- "$phrase" "$WOUT" || { help_ok=0; say "    --help does not mention: $phrase"; }
  done
  if [ "$help_ok" = 1 ]; then ok "--help exits 0 and documents the template, the window, the blank lines and the sources"; else bad "--help is incomplete"; fi

  say "  -- the metrics come from the sibling script, never from \$PATH; infrastructure is exit 5 --"
  runw --week 7 --repo "$GR" --receipts "$FX/r-measured" --bench-results "$FX/b-study-a-small"
  strip_window "$WOUT" >"$TMP/review.real"
  mkdir -p "$TMP/decoy"; printf '#!/bin/sh\necho "{\\"decoy\\": true}"\n' >"$TMP/decoy/heimdall-metrics"; chmod +x "$TMP/decoy/heimdall-metrics"
  PATH="$TMP/decoy:$PATH" runw --week 7 --repo "$GR" --receipts "$FX/r-measured" --bench-results "$FX/b-study-a-small"
  strip_window "$WOUT" >"$TMP/review.decoy"
  if [ -s "$TMP/review.real" ] && cmp -s "$TMP/review.real" "$TMP/review.decoy"; then ok "heimdall-metrics is invoked relative to the script's own location, a decoy earlier on \$PATH changes nothing"; else bad "a decoy heimdall-metrics on \$PATH was used"; fi
  PATH="$PATH_NOJQ" runw --week 3 --repo "$GR" --receipts "$E_RC" --bench-results "$E_BR"
  if [ "$WRC" -eq 5 ] && grep -q 'jq' "$WERR" && [ ! -s "$WOUT" ]; then ok "no jq: exit 5 (infrastructure), named on stderr, no review"; else bad "no jq (rc=$WRC, stderr: $(head -c 200 "$WERR"))"; fi
  PATH="$PATH_NOPY" runw --week 3 --repo "$GR" --receipts "$E_RC" --bench-results "$E_BR"
  if [ "$WRC" -eq 5 ] && grep -q 'python3' "$WERR" && [ ! -s "$WOUT" ]; then ok "no python3: exit 5 (infrastructure), named on stderr, no review"; else bad "no python3 (rc=$WRC, stderr: $(head -c 200 "$WERR"))"; fi
  PATH="$PATH_NOPY" runm --json --receipts "$E_RC" --bench-results "$E_BR"
  if [ "$MRC" -eq 5 ] && grep -q 'python3' "$MERR" && [ ! -s "$MOUT" ]; then ok "hmd metrics without python3: exit 5, named on stderr"; else bad "metrics without python3 (rc=$MRC, stderr: $(head -c 200 "$MERR"))"; fi
  PATH="$PATH_NOJQ" runm --json --receipts "$E_RC" --bench-results "$E_BR"
  if [ "$MRC" -eq 0 ] && [ "$(cat "$MOUT")" = "$DEFAULT_JSON" ]; then ok "hmd metrics needs python3 only: without jq it still prints the default object"; else bad "metrics without jq (rc=$MRC)"; fi
}

# ══════════════════════════════════════════════════════════════════════════════
# [E] E2E — receipts as the real producer writes them
# ══════════════════════════════════════════════════════════════════════════════
assertions_e2e() {
  say "[E] real receipts from hmd attack --receipt"
  if ! command -v node >/dev/null 2>&1; then say "  SKIP node is not installed: the attack engine cannot run"; return; fi
  if ! python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import cp_auth; sys.exit(0 if cp_auth.crypto_available() else 1)' "$REPO/bin/lib" >/dev/null 2>&1; then
    say "  SKIP no Ed25519 backend (cryptography or pynacl): a receipt cannot be signed"; return
  fi
  local keys="$TMP/e-keys" store="$TMP/e-store"
  if ! python3 "$REPO/bin/heimdall-receipt" keygen --dir "$keys" >/dev/null 2>&1; then bad "hmd receipt keygen failed"; return; fi
  for target in clean-sample buggy-webhook; do
    RUNHMD_RECEIPT_KEY_FILE="$keys/runhmd-receipt.key" RUNHMD_RECEIPT_PUBKEY_FILE="$keys/runhmd-receipt.pub" RUNHMD_RECEIPT_DIR="$store" \
      "$REPO/bin/heimdall-attack" "$REPO/fixtures/attack/$target" --json --yes --receipt >"$TMP/e-$target.out" 2>"$TMP/e-$target.err" </dev/null
  done
  local n; n="$(find "$store" -maxdepth 1 -type f -name '*.json' ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$n" = 2 ]; then ok "hmd attack --receipt wrote one receipt for a PROVEN and one for a DENIED target"; else bad "expected 2 receipts in the store, found $n"; return; fi
  local f all_zero=1
  for f in "$store"/*.json; do jq -e '.cost_usd==0 and .agent.model==null and .agent.name=="none"' "$f" >/dev/null 2>&1 || all_zero=0; done
  if [ "$all_zero" = 1 ]; then ok "as built, a receipt's cost_usd is 0 and it names no model (the premise of the measured-basis rule)"; else bad "a real receipt carries a cost or a model: the measured-basis rule needs revisiting"; fi
  runm --json --evidence --receipts "$store" --bench-results "$E_BR"
  jqok "real receipts are read as valid, counted, and never produce a \$ figure (2 valid, 2 this week, 0 measured, usd_* null)" "$MOUT" \
    '.evidence.receipts.valid==2 and .evidence.receipts.skipped==0 and .evidence.receipts.in_window==2 and .evidence.receipts.measured==0 and .usd_per_proven_pr==null and .usd_per_real_bug==null and .active_developers==0'
}

# ══════════════════════════════════════════════════════════════════════════════
# [X] MUTANTS — the same assertions, against copies of the scripts with one planted defect
# ══════════════════════════════════════════════════════════════════════════════
MUT_JOBS="${HMD_METRICS_TEST_JOBS:-6}"

# mutate <file> <old> <new>: replace exactly one occurrence of <old>. An anchor that drifted (0 or 2+ matches)
# fails here and is reported as "did not apply": it must never turn into a mutant that merely "survives".
mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:4]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
if text.count(old) != 1:
    sys.stderr.write("anchor found %d times, want exactly 1: %s\n" % (text.count(old), old))
    sys.exit(1)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text.replace(old, new))
PY
}

# run_group <root> <group M|W>: run the group's assertions against the tree at <root> and write
# "<failed assertions>\t<their descriptions>" to <root>.result. TMP, the two binaries and the counters are LOCALS: bash
# scopes dynamically, so the assertion functions read and update these copies and never the suite's globals, and each
# mutant gets a private scratch dir (concurrent mutants never share an output file).
run_group() {
  local root="$1" group="$2"
  local TMP="$root/work" M_BIN="$root/bin/heimdall-metrics" W_BIN="$root/bin/heimdall-weekly-review"
  local QUIET=1 PASS=0 FAIL=0 FAILED=""
  if [ "$group" = M ]; then assertions_metrics; else assertions_weekly; fi
  printf '%s\t%s\n' "$FAIL" "$(printf '%s' "$FAILED" | tr '\n\t' '  ')" >"$root.result"
}

# run_mutant <name> <group M|W> <which script: metrics|weekly> <old> <new>   (an empty <old> is the control: a comment is appended)
# Builds a private tree (bin/ with both scripts and the real lib, docs/) and runs the group's assertions against it
# (run_group), writing "<failed assertions>\t<their descriptions>" to <root>.result.
run_mutant() {
  local name="$1" group="$2" which="$3" old="$4" new="$5" root="$TMP/mut/$1" target
  rm -rf "$root"; mkdir -p "$root/bin" "$root/work"
  cp "$METRICS" "$root/bin/heimdall-metrics"; cp "$WEEKLY" "$root/bin/heimdall-weekly-review"
  ln -s "$REPO/bin/lib" "$root/bin/lib"; ln -s "$REPO/docs" "$root/docs"
  target="$root/bin/heimdall-weekly-review"; [ "$which" = metrics ] && target="$root/bin/heimdall-metrics"
  if [ -z "$old" ]; then
    printf '\n# an equivalent change: a comment\n' >>"$target"
  elif ! mutate "$target" "$old" "$new" 2>"$root/mutate.err"; then
    printf 'unapplied\t%s\n' "$(tr '\n\t' '  ' <"$root/mutate.err")" >"$root.result"; return
  fi
  chmod +x "$root/bin/heimdall-metrics" "$root/bin/heimdall-weekly-review"
  run_group "$root" "$group"
}

assertions_mutants() {
  say "[X] mutants: the same assertions, against copies of the scripts with one planted defect"
  mkdir -p "$TMP/mut"
  MUT_NAMES=(); MUT_EXPECT=()
  launch() {  # launch <name> <group> <script> <the assertion that must fail> <old> <new>
    MUT_NAMES+=("$1"); MUT_EXPECT+=("$4")
    while [ "$(jobs -r | wc -l | tr -d ' ')" -ge "$MUT_JOBS" ]; do sleep 0.2; done
    run_mutant "$1" "$2" "$3" "$5" "$6" &
  }
  launch control M metrics '' '' ''
  # a number fabricated where nothing is measured
  launch fabricated-zero M metrics 'default object' \
    '"false_green_rate": bench["false_green_rate"],' '"false_green_rate": bench["false_green_rate"] or 0,'
  launch partner-teams-invented M metrics 'default object' \
    '"partner_teams_active_weekly": 0,' '"partner_teams_active_weekly": 1,'
  # a Study B (judge calibration) number reported as an agent rate
  launch study-b-as-false-green-rate M metrics 'Study B rows only' \
    'false_green_rate=study["pooled"]["false_green_rate"]["rate"] if eligible else None,' \
    'false_green_rate=(summary["judge_calibration"]["primary"] or {}).get("naive_false_green_rate", {}).get("rate"),'
  launch study-b-as-catch-rate M metrics 'Study B rows only' \
    'catch_rate=summary["catch_rate"] if eligible else None,' \
    'catch_rate=(summary["judge_calibration"]["primary"] or {}).get("catch_rate", {}).get("rate"),'
  launch ungated-small-study M metrics 'below the headline threshold' \
    'eligible = study["headline_eligible"]' 'eligible = True'
  launch false-positives-counted M metrics 'real_bugs_caught counts only' \
    'row.get("human_label") == "true_positive")' 'row.get("human_label") in ("true_positive", "false_positive"))'
  # an estimate divided and called measured, and an empty denominator
  launch estimate-as-measured M metrics 'offline-engine receipts' \
    'measured = [r for r in receipts if r["agent"]["model"] and r["cost_usd"] > 0]' 'measured = list(receipts)'
  launch zero-over-zero M metrics 'empty PROVEN denominator' \
    'return round(numerator / denominator, 4) if denominator else None' 'return round(numerator / denominator, 4)'
  launch empty-denominator-as-zero M metrics 'no confirmed bug' \
    'return round(numerator / denominator, 4) if denominator else None' 'return round(numerator / denominator, 4) if denominator else 0'
  launch unvalidated-receipts M metrics 'invalid files in the store' \
    ' or runhmd_schema.validate(doc):' ':'
  # the weekly review
  launch invented-manual-line W weekly 'manual lines are left BLANK' \
    '"- Overnight users:",' '"- Overnight users: 0",'
  launch uncountable-commits-as-zero W weekly 'empty sources, not a git repo' \
    'COMMITS=null' 'COMMITS=0'
  launch week-zero-accepted W weekly "bad --week '0'" \
    '*[!0-9]*|0*)' '*[!0-9]*)'
  # shellcheck disable=SC2016 # both mutation strings are literal source text of the script under test, not expansions
  launch metrics-found-on-path W weekly 'decoy' \
    'METRICS="$BIN_DIR/heimdall-metrics"' 'METRICS="$(command -v heimdall-metrics || echo "$BIN_DIR/heimdall-metrics")"'
  wait

  local i name want fails failed
  for ((i = 0; i < ${#MUT_NAMES[@]}; i++)); do
    name="${MUT_NAMES[$i]}"; want="${MUT_EXPECT[$i]}"
    IFS=$'\t' read -r fails failed <"$TMP/mut/$name.result" || { bad "mutant $name: no result was written"; continue; }
    if [ "$name" = control ]; then
      if [ "$fails" = 0 ]; then ok "control: a comment-only copy passes every assertion, so a kill below is a real detection"
      else bad "control: a comment-only copy failed $fails assertion(s): $failed"; fi
    elif [ "$fails" = unapplied ]; then
      bad "mutant $name: the planted defect did not apply ($failed)"
    elif [ "$fails" -eq 0 ]; then
      bad "mutant $name SURVIVED: no assertion noticed it"
    elif printf '%s' "$failed" | grep -qF -- "$want"; then
      ok "mutant $name is killed: $fails assertion(s) failed, including the one about '$want'"
    else
      bad "mutant $name was killed, but not by the assertion about '$want' (failed: $failed)"
    fi
  done
}

if section M; then assertions_metrics; fi
if section W; then assertions_weekly; fi
if section E; then assertions_e2e; fi
if section X; then assertions_mutants; fi

echo
echo "hmd-metrics: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
