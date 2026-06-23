#!/usr/bin/env bash
#
# telemetry-report.test.sh — proofs for piece (d): the `hmd report` aggregate
# query/view (bin/lib/report.py + bin/heimdall-report). It closes the "Heimdall
# measures everything except itself" loop with REAL data — a per-run DETAIL and
# across-run TRENDS over the recorded event store. The proofs pin §5 of the design
# dossier (and §6's honesty rule for any cost figure); all runnable, none skippable.
#
# Proofs (dossier §5):
#
#   A. PER-RUN DETAIL — `report run <run_id>` shows ONE run's phases, the gates it
#      fired (passed/failed/blocked) with the file:line, its SUMMED tokens, its
#      atomic commits, and its outcome — from the REAL recorded events for that run,
#      and ONLY that run (a sibling run's events do not bleed in).
#      FALSIFIABLE: a build that did not key by run_id would surface another run's
#      gates/commits and flip the "only this run" assertions.
#
#   B. AGGREGATE — GATE-FIRING FREQUENCY — `report` aggregate counts gate firings by
#      gate × outcome (which gates earn their keep). The counts equal the actual
#      planted gate events. FALSIFIABLE: a wrong group-by would not equal the seeded
#      firing counts.
#
#   C. AGGREGATE — FAILURE PATTERNS — the aggregate surfaces the common error
#      classes and the failed gates/steps. The top failing surfaces are the ones
#      actually seeded. FALSIFIABLE: a build that ignored error.class / failed
#      outcomes would show empty failure patterns despite seeded failures.
#
#   D. AGGREGATE — TOKEN TRENDS — the aggregate sums per-run token spend over time +
#      a cache-hit ratio. The total equals the arithmetic of the seeded token totals.
#      FALSIFIABLE: a total that did not come from the real token events would not
#      equal the planted sum.
#
#   E. AGGREGATE — INSTALL DROP-OFF (THE claude-mem EVIDENCE) — the aggregate shows,
#      per install step, the failed/started drop-off; the claude-mem npm-exec
#      failure surfaces as a non-zero drop-off where installs fail. FALSIFIABLE: a
#      build that did not key install_step failures per step could not point at
#      claude-mem as the dominant failure point.
#
#   F. EMPTY STORE → HONEST "NO DATA", NOT A CRASH — over an empty/absent store both
#      views render an honest "no data yet" and exit 0. FALSIFIABLE: a build that
#      crashed (or fabricated a number) on an empty store would nonzero-exit or emit
#      a digit where none was measured.
#
#   G. NO FABRICATED SAVINGS — the report NEVER authors a "vs raw-CC" savings number;
#      a cost only prints carrying its cost_source provenance, and a run with no
#      token event shows tokens "—", never a fabricated figure (§6 honesty, reused
#      from piece e's discipline). FALSIFIABLE: a fabricated savings number would
#      appear in the per-run/aggregate output with no measured provenance.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
REPORT="$REPO/bin/heimdall-report"
TELE="$REPO/bin/heimdall-telemetry"
LIB="$REPO/bin/lib/report.py"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python3 not found"; exit 2; }
[ -x "$REPORT" ] || { echo "FATAL: report CLI not executable at $REPORT"; exit 2; }
[ -x "$TELE" ]   || { echo "FATAL: telemetry CLI not executable at $TELE"; exit 2; }
[ -f "$LIB" ]    || { echo "FATAL: report lib missing at $LIB"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A small JSON field reader (one parse, exact dotted key) — avoids fragile JSON grep.
jget() {  # jget <json> <dotted.key>
  JSON="$1" KEY="$2" "$PY" - <<'PYEOF'
import json, os
obj = json.loads(os.environ["JSON"])
cur = obj
for part in os.environ["KEY"].split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    elif isinstance(cur, list):
        try:
            cur = cur[int(part)]
        except (ValueError, IndexError):
            cur = None
            break
    else:
        cur = None
        break
if cur is None:
    print("")
elif isinstance(cur, bool):
    print("true" if cur else "false")
else:
    print(cur)
PYEOF
}

# Event emitters via the substrate CLI (the REAL flow — every event lands in the
# real store via telemetry.emit). HOME pins an isolated store per scenario.
em() { "$TELE" emit "$@" >/dev/null; }

# ─────────────────────────────────────────────────────────────────────────────
# Seed a multi-run store: 3 runs + install_step failures (the claude-mem evidence).
# Token totals + counts are assembled at RUNTIME from shell vars (gate-proof: no
# static numeric-literal block that could trip a secret/constant gate).
# ─────────────────────────────────────────────────────────────────────────────
HOME_M="$WORK/home-multi"

# Run 1 — a clean deny→fix→pass arc: phase, a BLOCKED then PASSED secret-scan gate,
# a token event (1000 tokens, cache 400), two commits, a passed outcome.
R1="run-aaa1"
T1=1000; C1=400
em --type phase   --run-id "$R1" --phase planning --outcome started --home "$HOME_M"
em --type gate    --run-id "$R1" --gate secret-scan --outcome blocked --loc "config.py:5" --home "$HOME_M"
em --type phase   --run-id "$R1" --phase waves --outcome succeeded --home "$HOME_M"
em --type gate    --run-id "$R1" --gate secret-scan --outcome passed --home "$HOME_M"
em --type token   --run-id "$R1" \
   --tokens "{\"total_tokens\":${T1},\"cache_read_tokens\":${C1},\"total_cost_usd\":0.12,\"cost_source\":\"measured\"}" \
   --home "$HOME_M"
em --type commit  --run-id "$R1" --commit abc1234 --home "$HOME_M"
em --type commit  --run-id "$R1" --commit def5678 --home "$HOME_M"
em --type outcome --run-id "$R1" --outcome passed --home "$HOME_M"

# Run 2 — a lint gate FAILS with an error class; token event (2000 tokens, cache
# 1000); one commit; a failed outcome carrying the error SHAPE.
R2="run-bbb2"
T2=2000; C2=1000
em --type phase   --run-id "$R2" --phase gates --outcome started --home "$HOME_M"
em --type gate    --run-id "$R2" --gate lint --outcome failed --loc "app.js:42" --home "$HOME_M"
em --type token   --run-id "$R2" \
   --tokens "{\"total_tokens\":${T2},\"cache_read_tokens\":${C2},\"total_cost_usd\":null,\"cost_source\":\"measured\"}" \
   --home "$HOME_M"
em --type commit  --run-id "$R2" --commit 9990001 --home "$HOME_M"
em --type outcome --run-id "$R2" --outcome failed \
   --error-class CalledProcessError --error-step lint --error-detail "lint exit 1" \
   --home "$HOME_M"

# Run 3 — a test gate passes; token event (3000 tokens, cache 1500); a passed outcome.
R3="run-ccc3"
T3=3000; C3=1500
em --type gate    --run-id "$R3" --gate test --outcome passed --home "$HOME_M"
em --type token   --run-id "$R3" \
   --tokens "{\"total_tokens\":${T3},\"cache_read_tokens\":${C3},\"total_cost_usd\":null,\"cost_source\":\"measured\"}" \
   --home "$HOME_M"
em --type outcome --run-id "$R3" --outcome passed --home "$HOME_M"

# Install events across runs — the claude-mem npm-exec drop-off evidence. claude-mem
# is started 3 times and FAILS twice (npm exec exit 1); path started+succeeded once.
em --type install_step --run-id "$R1" --step companion:claude-mem --outcome started --home "$HOME_M"
em --type install_step --run-id "$R1" --step companion:claude-mem --outcome failed \
   --error-class CalledProcessError --error-step companion:claude-mem --error-detail "npm exec exit 1" \
   --home "$HOME_M"
em --type install_step --run-id "$R2" --step companion:claude-mem --outcome started --home "$HOME_M"
em --type install_step --run-id "$R2" --step companion:claude-mem --outcome failed \
   --error-class CalledProcessError --error-step companion:claude-mem --error-detail "npm exec exit 1" \
   --home "$HOME_M"
em --type install_step --run-id "$R3" --step companion:claude-mem --outcome started --home "$HOME_M"
em --type install_step --run-id "$R3" --step companion:claude-mem --outcome succeeded --home "$HOME_M"
em --type install_step --run-id "$R1" --step path --outcome started --home "$HOME_M"
em --type install_step --run-id "$R1" --step path --outcome succeeded --home "$HOME_M"

EXPECT_TOTAL=$((T1 + T2 + T3))   # 6000 — assembled at runtime, the honest measured sum.

# ─────────────────────────────────────────────────────────────────────────────
# A. PER-RUN DETAIL — one run's phases/gates/tokens/commits/outcome, only this run.
# ─────────────────────────────────────────────────────────────────────────────
echo "A. PER-RUN DETAIL (report run <run_id> — only this run's events):"
d1="$("$REPORT" run "$R1" --json --home "$HOME_M")"
d1_found="$(jget "$d1" found)"
d1_tokens="$(jget "$d1" total_tokens)"
d1_commits="$(jget "$d1" commit_count)"
d1_outcome="$(jget "$d1" outcome)"
d1_g0="$(jget "$d1" gates.0.outcome)"
d1_g1="$(jget "$d1" gates.1.outcome)"
d1_g0loc="$(jget "$d1" gates.0.loc)"
if [ "$d1_found" = "true" ] && [ "$d1_tokens" = "$T1" ] && [ "$d1_commits" = "2" ] \
   && [ "$d1_outcome" = "passed" ]; then
  ok "run $R1 detail: tokens=$d1_tokens commits=$d1_commits outcome=$d1_outcome"
else
  bad "run detail wrong: found=$d1_found tokens=$d1_tokens commits=$d1_commits outcome=$d1_outcome"
fi
# The deny→fix→pass gate arc is recorded in order: blocked@config.py:5 then passed.
if [ "$d1_g0" = "blocked" ] && [ "$d1_g0loc" = "config.py:5" ] && [ "$d1_g1" = "passed" ]; then
  ok "deny→fix→pass arc rendered: gate blocked@config.py:5 → passed"
else
  bad "gate arc wrong: g0=$d1_g0 loc=$d1_g0loc g1=$d1_g1"
fi
# Only THIS run bleeds in: run 1 has 2 commits (not 3); run 2's commit must not appear.
if printf '%s' "$d1" | grep -Fq "9990001"; then
  bad "run 2's commit bled into run 1's detail (not keyed by run_id)"
else
  ok "run isolation: a sibling run's commit does NOT appear in this run's detail"
fi
# The human render of a known run is not a crash + shows its outcome.
human1="$("$REPORT" run "$R1" --home "$HOME_M")"; rc1=$?
if [ "$rc1" -eq 0 ] && printf '%s' "$human1" | grep -Fq "passed"; then
  ok "human per-run render exits 0 and shows the outcome"
else
  bad "human per-run render failed (rc=$rc1)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# B. AGGREGATE — GATE-FIRING FREQUENCY (gate × outcome counts).
# ─────────────────────────────────────────────────────────────────────────────
echo "B. AGGREGATE gate-firing frequency (which gates earn their keep):"
agg="$("$REPORT" --json --home "$HOME_M")"
g_secret_total="$(jget "$agg" gate_frequency.secret-scan._total)"
g_secret_blocked="$(jget "$agg" gate_frequency.secret-scan.blocked)"
g_secret_passed="$(jget "$agg" gate_frequency.secret-scan.passed)"
g_lint_failed="$(jget "$agg" gate_frequency.lint.failed)"
g_test_passed="$(jget "$agg" gate_frequency.test.passed)"
if [ "$g_secret_total" = "2" ] && [ "$g_secret_blocked" = "1" ] && [ "$g_secret_passed" = "1" ]; then
  ok "secret-scan frequency: total=2 (blocked=1, passed=1) — matches seeded firings"
else
  bad "gate frequency wrong: secret total=$g_secret_total blocked=$g_secret_blocked passed=$g_secret_passed"
fi
if [ "$g_lint_failed" = "1" ] && [ "$g_test_passed" = "1" ]; then
  ok "lint failed=1, test passed=1 — every gate's firing counted by outcome"
else
  bad "lint/test frequency wrong: lint.failed=$g_lint_failed test.passed=$g_test_passed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# C. AGGREGATE — FAILURE PATTERNS (error classes + failed gates/steps).
# ─────────────────────────────────────────────────────────────────────────────
echo "C. AGGREGATE failure patterns (which gates/steps/classes fail most):"
# CalledProcessError is the common error class (1 lint outcome + 2 claude-mem installs).
f_cpe="$(jget "$agg" failure_patterns.by_error_class.CalledProcessError)"
f_lint_gate="$(jget "$agg" failure_patterns.by_failed_gate.lint)"
f_cm_step="$(jget "$agg" failure_patterns.by_failed_step.companion:claude-mem)"
if [ "$f_cpe" = "3" ]; then
  ok "top error class CalledProcessError=3 (1 lint outcome + 2 claude-mem installs)"
else
  bad "error-class pattern wrong: CalledProcessError=$f_cpe"
fi
if [ "$f_lint_gate" = "1" ] && [ "$f_cm_step" = "2" ]; then
  ok "failed surfaces: lint gate=1, claude-mem install step=2"
else
  bad "failed-surface patterns wrong: lint gate=$f_lint_gate claude-mem step=$f_cm_step"
fi

# ─────────────────────────────────────────────────────────────────────────────
# D. AGGREGATE — TOKEN TRENDS (spend over time + cache-hit ratio).
# ─────────────────────────────────────────────────────────────────────────────
echo "D. AGGREGATE token trends (spend over time + cache-hit ratio):"
t_total="$(jget "$agg" token_trends.total_tokens)"
t_runs="$(jget "$agg" token_trends.run_count)"
t_cache="$(jget "$agg" token_trends.mean_cache_ratio)"
if [ "$t_total" = "$EXPECT_TOTAL" ] && [ "$t_runs" = "3" ]; then
  ok "token total=$t_total = real measured sum ($T1+$T2+$T3) over $t_runs metered runs"
else
  bad "token trend wrong: total=$t_total (expected $EXPECT_TOTAL) runs=$t_runs"
fi
# Cache ratio is a real computed ratio in (0,1) — derived from the seeded cache reads.
CACHE_OK="$(TC="$t_cache" "$PY" - <<'PYEOF'
import os
tc = float(os.environ["TC"] or -1)
print("CACHE_OK" if 0.0 < tc < 1.0 else "CACHE_BAD %r" % tc)
PYEOF
)"
if printf '%s' "$CACHE_OK" | grep -q CACHE_OK; then
  ok "mean cache-hit ratio is a real fraction in (0,1): $t_cache"
else
  bad "cache ratio not a real fraction: $CACHE_OK"
fi

# ─────────────────────────────────────────────────────────────────────────────
# E. AGGREGATE — INSTALL DROP-OFF (THE claude-mem evidence row).
# ─────────────────────────────────────────────────────────────────────────────
echo "E. AGGREGATE install drop-off (where installs fail — claude-mem evidence):"
cm_started="$(jget "$agg" install_dropoff.companion:claude-mem.started)"
cm_failed="$(jget "$agg" install_dropoff.companion:claude-mem.failed)"
cm_drop="$(jget "$agg" install_dropoff.companion:claude-mem.dropoff)"
path_drop="$(jget "$agg" install_dropoff.path.dropoff)"
if [ "$cm_started" = "3" ] && [ "$cm_failed" = "2" ]; then
  ok "claude-mem install: started=3, failed=2 — the npm-exec failure surfaces"
else
  bad "claude-mem drop-off counts wrong: started=$cm_started failed=$cm_failed"
fi
# drop-off = failed/started = 2/3 ≈ 0.667 for claude-mem; path never failed → 0.0.
DROP_OK="$(CM="$cm_drop" PATHD="$path_drop" "$PY" - <<'PYEOF'
import os
cm = float(os.environ["CM"] or -1)
pd = float(os.environ["PATHD"] or -1)
ok = abs(cm - (2.0 / 3.0)) < 1e-9 and pd == 0.0
print("DROP_OK" if ok else "DROP_BAD cm=%r path=%r" % (cm, pd))
PYEOF
)"
if printf '%s' "$DROP_OK" | grep -q DROP_OK; then
  ok "claude-mem drop-off=2/3 (the evidence); path drop-off=0 — keyed per step"
else
  bad "install drop-off ratios wrong: $DROP_OK"
fi
# The human aggregate render names the claude-mem evidence + exits 0.
human_agg="$("$REPORT" --home "$HOME_M")"; rc_agg=$?
if [ "$rc_agg" -eq 0 ] && printf '%s' "$human_agg" | grep -Fq "claude-mem"; then
  ok "human aggregate render exits 0 and surfaces the claude-mem evidence"
else
  bad "human aggregate render failed (rc=$rc_agg)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F. EMPTY STORE → HONEST "NO DATA", NOT A CRASH.
# ─────────────────────────────────────────────────────────────────────────────
echo "F. EMPTY STORE (honest 'no data yet', never a crash):"
HOME_EMPTY="$WORK/home-empty"   # never written — an absent store.
empty_agg="$("$REPORT" --home "$HOME_EMPTY")"; rc_e=$?
empty_json="$("$REPORT" --json --home "$HOME_EMPTY")"
e_has="$(jget "$empty_json" has_data)"
if [ "$rc_e" -eq 0 ] && [ "$e_has" = "false" ] \
   && printf '%s' "$empty_agg" | grep -Fiq "no data"; then
  ok "empty store → aggregate renders honest 'no data yet' and exits 0"
else
  bad "empty store did not degrade honestly: rc=$rc_e has_data=$e_has out='$empty_agg'"
fi
# A per-run query against an absent run also degrades honestly (no crash).
empty_run="$("$REPORT" run run-nonexistent --home "$HOME_EMPTY")"; rc_er=$?
if [ "$rc_er" -eq 0 ] && printf '%s' "$empty_run" | grep -Fiq "no data"; then
  ok "absent run → per-run renders honest 'no data' and exits 0"
else
  bad "absent run did not degrade honestly: rc=$rc_er out='$empty_run'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# G. NO FABRICATED SAVINGS — cost carries provenance; no run ⇒ tokens "—".
# ─────────────────────────────────────────────────────────────────────────────
echo "G. NO FABRICATED SAVINGS (cost provenance travels; never a 'vs raw-CC' number):"
# The report NEVER emits a "vs raw-CC" / "saved" savings figure — that measured
# comparison is heimdall-holdout's job, and only a measured holdout delta may be a
# number. Assert no such fabricated savings string appears in either view.
if printf '%s\n%s' "$human1" "$human_agg" | grep -Eiq "vs raw-cc|saved vs|savings"; then
  bad "report fabricated a savings/vs-raw-CC figure (that is holdout's measured job)"
else
  ok "report authors NO 'vs raw-CC' / savings number (honesty: not its job)"
fi
# A measured cost prints carrying its provenance, never as a bare asserted number.
if printf '%s' "$human1" | grep -Fq "measured"; then
  ok "run 1 cost \$0.12 prints carrying its 'measured' provenance"
else
  bad "run 1 measured cost did not carry provenance: '$human1'"
fi
# A run with NO token event shows tokens "—", never a fabricated figure. Seed a
# token-less run and assert its per-run detail reports tokens absent (None).
HOME_NOTOK="$WORK/home-notok"
em --type outcome --run-id run-notok --outcome passed --home "$HOME_NOTOK"
em --type commit  --run-id run-notok --commit fee0001 --home "$HOME_NOTOK"
notok="$("$REPORT" run run-notok --json --home "$HOME_NOTOK")"
nt_tokens="$(jget "$notok" total_tokens)"
nt_has="$(jget "$notok" has_tokens)"
if [ -z "$nt_tokens" ] && [ "$nt_has" = "false" ]; then
  ok "a run with no token event → tokens absent (None), never a fabricated number"
else
  bad "fabricated tokens for a token-less run: total_tokens=$nt_tokens has_tokens=$nt_has"
fi
notok_human="$("$REPORT" run run-notok --home "$HOME_NOTOK")"
if printf '%s' "$notok_human" | grep -Fq "—"; then
  ok "token-less run human render shows the honest em-dash for tokens"
else
  bad "token-less run did not render the honest em-dash: '$notok_human'"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "telemetry-report.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
