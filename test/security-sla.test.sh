#!/usr/bin/env bash
#
# security-sla.test.sh — acceptance for the 24h SLA on ⚠-class observations.
#
# THE DISEASE THIS GATE EXISTS TO KILL. A recorded fail-open observation sat known-and-
# unfixed for three days. Nothing was broken: the observation was filed, stored, and
# queryable the whole time. It simply aged into invisibility, because no surface ever
# asked "is this item still unactioned?" A defect queue where an unactioned item can
# quietly get older is the same failure as a monitor that quietly stops — the absence of
# a signal is indistinguishable from the absence of a problem.
#
# THE RULE ENFORCED HERE: every ⚠-class observation (security_alert / security_note /
# sensitive, PLUS fail-open-class findings however they happened to be typed) must, within
# 24 hours, either be FIXED or carry a durable recorded triage reason a human wrote. An
# item with no verdict is a BREACH. Never a pass. Never "it's old, so it must be fine".
#
# THE REGRESSION THIS SUITE EXISTS TO CATCH IS THE QUIET ONE. A check that goes green by
# losing its ability to SEE is strictly worse than no check — it converts an open defect
# into a documented all-clear. So every green path is paired with a red path, the scan
# fails CLOSED when it cannot prove it actually read the store, and section (M) mutates
# the checker itself to prove the red paths are real checks and not tautologies.
#
#   bash test/security-sla.test.sh    (exit 0 = all cases pass)
#
# FALSIFIABLE claims proven:
#   A. a ⚠ item aged 25h with NO triage  -> RED, and the output NAMES that id
#   B. add a triage-with-reason          -> GREEN (self-clearing, no ack step)
#   C. a ⚠ item aged 23h with no triage  -> NOT yet a breach (the window is real)
#   D. fail-closed: unreadable store / empty store / a ⚠-vocabulary that matches
#      nothing all exit 2 LOUDLY. An empty scan never passes.
#   E. triage must be a REASON, not an acknowledgement: bare "ack", a missing HAID,
#      an unknown verdict token, and a verdict for a DIFFERENT id are all rejected.
#   F. lane B: a fail-open finding typed `discovery` (exactly how obs 16105 was filed)
#      is still caught — the check does not trust the type field alone.
#   G. secrecy: default + --advise + weekly output carry ids and status but NEVER the
#      observation title (titles in this store demonstrably contain live secrets).
#   H. --advise is one line, silent when clean, and ALWAYS exits 0 (a SessionStart
#      monitor may never break the session it warns in).
#   M. MUTATION: (m1) age comparison forced always-false and (m2) "no verdict" forced
#      to count as a pass are BOTH killed by cases A/C.
#
# Every path is a temp fixture. The real ~/.claude-mem store is never opened, and the
# real .planning/ledger/decisions.md is never written.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SLA="$ROOT/bin/heimdall-sla"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; }

[ -f "$SLA" ] || { echo "FATAL: missing $SLA" >&2; exit 2; }
command -v sqlite3 >/dev/null 2>&1 || { echo "FATAL: sqlite3 required" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-sla.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A fixed "now" makes every age in this suite exact and the suite immune to wall-clock drift.
NOW=1786000000
H=3600
mk_epoch_ms() { echo $(( (NOW - $1 * H) * 1000 )); }   # <hours ago> -> epoch MILLISECONDS

# ── fixture store: same shape as ~/.claude-mem/claude-mem.db ─────────────────────
DB="$WORK/mem.db"
sqlite3 "$DB" "CREATE TABLE observations (
  id INTEGER PRIMARY KEY, memory_session_id TEXT, project TEXT NOT NULL, text TEXT,
  type TEXT NOT NULL, title TEXT, subtitle TEXT, facts TEXT, narrative TEXT,
  concepts TEXT, created_at TEXT, created_at_epoch INTEGER NOT NULL);"

add_obs() { # <id> <type> <hours_ago> <project> <title> [subtitle]
  sqlite3 "$DB" "INSERT INTO observations (id,memory_session_id,project,text,type,title,subtitle,facts,narrative,concepts,created_at,created_at_epoch)
    VALUES ($1,'s','$4','','$2','$(printf '%s' "$5" | sed "s/'/''/g")','$(printf '%s' "${6:-}" | sed "s/'/''/g")','','','','x',$(mk_epoch_ms $3));"
}

SECRET_TITLE="Live Cashfree token AbCdEf123 visible in logcat"
add_obs 100 security_alert 25 heimdall "$SECRET_TITLE"          # the 25h breach
add_obs 101 security_note  23 heimdall "Recent note, still inside the window"
add_obs 102 sensitive      99 heimdall "Old sensitive item"      # a second breach
add_obs 103 discovery      50 heimdall "classify() will self-silence after first run" "state=granted once S_RESULT=ok"
add_obs 104 discovery      50 heimdall "An ordinary discovery with no security character"
add_obs 105 security_alert 30 rally    "A different project's alert"
# volume so the store-liveness probe sees a populated store
i=200; while [ $i -lt 260 ]; do add_obs $i feature 200 heimdall "filler $i"; i=$((i+1)); done

# ── fixture triage ledger ────────────────────────────────────────────────────────
DEC="$WORK/decisions.md"
new_ledger() { printf '# Decisions (ADR-lite, append-only)\n\n<!-- entries below -->\n' > "$DEC"; }
triage() { # <id> <verdict> <reason> [attribution-line]
  { printf '\n## 2026-08-06T12:00:00Z — security-SLA triage: obs %s\n\n' "$1"
    printf 'SLA-OBS: %s\n' "$1"
    printf 'SLA-VERDICT: %s\n' "$2"
    printf 'SLA-REASON: %s\n\n' "$3"
    printf '%s\n' "${4-*— recorded by \`haid:rj.rishabhs-macbook-air-46d5\`*}"
  } >> "$DEC"
}
new_ledger

run() { "$SLA" --db "$DB" --decisions "$DEC" --project heimdall --now "$NOW" "$@" 2>&1; }
rc_of() { "$SLA" --db "$DB" --decisions "$DEC" --project heimdall --now "$NOW" "$@" >"$WORK/o" 2>&1; echo $?; }

echo "security-sla.test.sh"
echo "-- A. an untriaged ⚠ item past the window is a BREACH --------------------------"

OUT="$(run)"; RC="$(rc_of)"
[ "$RC" = 1 ] && ok "A1 untriaged 25h item -> exit 1 (RED)" \
  || bad "A1 expected exit 1, got $RC" "$OUT"
printf '%s' "$OUT" | grep -q '\b100\b' \
  && ok "A2 the RED output NAMES the breaching observation id (100)" \
  || bad "A2 breach output does not name id 100" "$OUT"
printf '%s' "$OUT" | grep -q '\b102\b' \
  && ok "A3 the 99h-old item is also named (age never converts a breach into a pass)" \
  || bad "A3 the older breach (102) was not reported" "$OUT"

echo "-- B. a recorded triage-with-reason clears it ----------------------------------"

new_ledger
triage 100 FIXED "Token redaction landed in 3a4b255; the logcat path is scrubbed before write and covered by a regression suite."
triage 102 ACCEPTED-RISK "Hostname is public in the published docs already, so disclosure adds nothing; revisit if the host moves inside the VPC."
triage 103 FALSE-POSITIVE "classify() reads the status file fresh each run, so the granted state cannot persist across a denied repo."
OUT="$(run)"; RC="$(rc_of)"
[ "$RC" = 0 ] && ok "B1 every overdue item triaged -> exit 0 (GREEN)" \
  || bad "B1 expected exit 0 after triage, got $RC" "$OUT"
printf '%s' "$OUT" | grep -qi 'breach' && printf '%s' "$OUT" | grep -qiv '0 breach' >/dev/null 2>&1
printf '%s' "$OUT" | grep -q 'BREACH: ' \
  && bad "B2 a breach was still reported after full triage" "$OUT" \
  || ok "B2 no BREACH line survives a complete triage (self-clearing, no ack step)"

echo "-- C. the window is real: 23h untriaged is NOT yet a breach ---------------------"

printf '%s' "$OUT" | grep -q 'BREACH.*\b101\b' \
  && bad "C1 the 23h item was reported as a breach — the window is not being honored" "$OUT" \
  || ok "C1 the 23h untriaged item is NOT a breach (inside the 24h window)"
printf '%s' "$(run --json)" | grep -q '"within_window":1' \
  && ok "C2 --json accounts for it as within_window (tracked, not silently dropped)" \
  || bad "C2 the 23h item vanished from the accounting" "$(run --json)"

echo "-- D. fail-closed: an empty or unreadable scan NEVER passes ---------------------"

RC="$("$SLA" --db "$WORK/does-not-exist.db" --decisions "$DEC" --project heimdall --now "$NOW" >"$WORK/o" 2>&1; echo $?)"
[ "$RC" = 2 ] && ok "D1 missing store -> exit 2 (blind, fail-closed)" \
  || bad "D1 missing store returned $RC, expected 2" "$(cat "$WORK/o")"
grep -qi 'blind\|cannot\|unreadable' "$WORK/o" \
  && ok "D2 the blind exit says WHY it could not scan" || bad "D2 blind exit is silent" "$(cat "$WORK/o")"

EMPTY="$WORK/empty.db"
sqlite3 "$EMPTY" "CREATE TABLE observations (id INTEGER PRIMARY KEY, memory_session_id TEXT, project TEXT NOT NULL, text TEXT, type TEXT NOT NULL, title TEXT, subtitle TEXT, facts TEXT, narrative TEXT, concepts TEXT, created_at TEXT, created_at_epoch INTEGER NOT NULL);"
RC="$("$SLA" --db "$EMPTY" --decisions "$DEC" --project heimdall --now "$NOW" >"$WORK/o" 2>&1; echo $?)"
[ "$RC" = 2 ] && ok "D3 store present but EMPTY -> exit 2 (0 rows is not an all-clear)" \
  || bad "D3 empty store returned $RC, expected 2" "$(cat "$WORK/o")"

# The monitor-silently-stopped detector: a populated store in which the ⚠ vocabulary
# matches nothing means the type names changed underneath us and the check is blind.
NOVOCAB="$WORK/novocab.db"
sqlite3 "$NOVOCAB" "CREATE TABLE observations (id INTEGER PRIMARY KEY, memory_session_id TEXT, project TEXT NOT NULL, text TEXT, type TEXT NOT NULL, title TEXT, subtitle TEXT, facts TEXT, narrative TEXT, concepts TEXT, created_at TEXT, created_at_epoch INTEGER NOT NULL);"
i=1; while [ $i -lt 40 ]; do
  sqlite3 "$NOVOCAB" "INSERT INTO observations VALUES ($i,'s','heimdall','','feature','t$i','','','','','x',$(mk_epoch_ms 5));"
  i=$((i+1)); done
RC="$("$SLA" --db "$NOVOCAB" --decisions "$DEC" --project heimdall --now "$NOW" >"$WORK/o" 2>&1; echo $?)"
[ "$RC" = 2 ] && ok "D4 populated store where the ⚠ vocabulary matches NOTHING -> exit 2 (blind)" \
  || bad "D4 vocabulary-drift returned $RC, expected 2" "$(cat "$WORK/o")"

echo "-- E. triage means a REASON a human wrote, not an acknowledgement ---------------"

new_ledger; triage 100 FIXED "ack"
triage 102 ACCEPTED-RISK "Hostname is already public in the shipped docs; disclosure adds nothing new to an attacker."
triage 103 FALSE-POSITIVE "classify() re-reads the status file each run so a granted state cannot persist."
printf '%s' "$(run)" | grep -q 'BREACH.*\b100\b' \
  && ok "E1 a bare 'ack' is NOT triage — still a breach" || bad "E1 'ack' was accepted as triage" "$(run)"

new_ledger; triage 100 FIXED "Redaction landed in 3a4b255 and the logcat write path is scrubbed before it is flushed." "no attribution here"
triage 102 ACCEPTED-RISK "Hostname is already public in the shipped docs; disclosure adds nothing new to an attacker."
triage 103 FALSE-POSITIVE "classify() re-reads the status file each run so a granted state cannot persist."
printf '%s' "$(run)" | grep -q 'BREACH.*\b100\b' \
  && ok "E2 a verdict with NO HAID attribution is rejected (nobody is accountable for it)" \
  || bad "E2 unattributed verdict was accepted" "$(run)"

new_ledger; triage 100 PROBABLY-FINE "Redaction landed in 3a4b255 and the logcat write path is scrubbed before it is flushed."
triage 102 ACCEPTED-RISK "Hostname is already public in the shipped docs; disclosure adds nothing new to an attacker."
triage 103 FALSE-POSITIVE "classify() re-reads the status file each run so a granted state cannot persist."
printf '%s' "$(run)" | grep -q 'BREACH.*\b100\b' \
  && ok "E3 an unknown verdict token is rejected (the vocabulary is closed)" \
  || bad "E3 bogus verdict token accepted" "$(run)"

new_ledger; triage 999 FIXED "This triage names an observation that is not the one in breach, so it must not clear id 100."
triage 102 ACCEPTED-RISK "Hostname is already public in the shipped docs; disclosure adds nothing new to an attacker."
triage 103 FALSE-POSITIVE "classify() re-reads the status file each run so a granted state cannot persist."
printf '%s' "$(run)" | grep -q 'BREACH.*\b100\b' \
  && ok "E4 a verdict for a DIFFERENT id does not clear this one" || bad "E4 cross-id leak in triage matching" "$(run)"

# DEFERRED is the one verdict that could re-create the disease: "defer" with no expiry is
# just a rename of aging into invisibility. So it must carry a date and lapse by itself.
triage_until() { # <id> <reason> <until|"">
  { printf '\n## 2026-08-06T12:00:00Z — security-SLA triage: obs %s\n\n' "$1"
    printf 'SLA-OBS: %s\nSLA-VERDICT: DEFERRED\nSLA-REASON: %s\n' "$1" "$2"
    [ -n "$3" ] && printf 'SLA-UNTIL: %s\n' "$3"
    printf '\n*— recorded by `haid:rj.rishabhs-macbook-air-46d5`*\n'
  } >> "$DEC"
}
clear_others() {
  triage 102 ACCEPTED-RISK "Hostname is already public in the shipped docs; disclosure adds nothing new to an attacker."
  triage 103 FALSE-POSITIVE "classify() re-reads the status file each run so a granted state cannot persist."
}

new_ledger; triage_until 100 "Deferring this one until the payment driver rewrite lands next sprint." ""; clear_others
printf '%s' "$(run)" | grep -q 'BREACH.*\b100\b' \
  && ok "E5 DEFERRED with NO expiry date is rejected (an open-ended defer is just aging)" \
  || bad "E5 an undated deferral was accepted" "$(run)"

new_ledger; triage_until 100 "Deferring this one until the payment driver rewrite lands next sprint." "2020-01-01"; clear_others
printf '%s' "$(run)" | grep -q 'BREACH.*\b100\b' \
  && ok "E6 an EXPIRED deferral re-opens by itself (the deferral loophole is closed)" \
  || bad "E6 a lapsed deferral still suppressed the item" "$(run)"

new_ledger; triage_until 100 "Deferring this one until the payment driver rewrite lands next sprint." "2099-01-01"; clear_others
RC="$(rc_of)"
[ "$RC" = 0 ] && ok "E7 a dated, unexpired deferral DOES clear the item (deferral is still triage)" \
  || bad "E7 a valid deferral did not clear, exit $RC" "$(run)"

echo "-- F. lane B: a fail-open finding typed 'discovery' is still caught -------------"

new_ledger; triage 100 FIXED "Redaction landed in 3a4b255 and the logcat write path is scrubbed before it is flushed."
triage 102 ACCEPTED-RISK "Hostname is already public in the shipped docs; disclosure adds nothing new to an attacker."
OUT="$(run)"
printf '%s' "$OUT" | grep -q 'BREACH.*\b103\b' \
  && ok "F1 the self-silencing item typed 'discovery' IS a breach (type field is not trusted alone)" \
  || bad "F1 lane B missed the untagged fail-open finding (this is exactly obs 16105)" "$OUT"
printf '%s' "$OUT" | grep -q '\b104\b' \
  && bad "F2 an ordinary discovery was swept in — lane B is over-broad" "$OUT" \
  || ok "F2 an ordinary 'discovery' with no fail-open character is NOT swept in"

echo "-- G. the report names an item; it never publishes the vulnerability ------------"

new_ledger
OUT="$(run)"
printf '%s' "$OUT" | grep -qF "$SECRET_TITLE" \
  && bad "G1 the default report leaked an observation TITLE (titles carry live secrets)" "$OUT" \
  || ok "G1 default report carries ids + status, never the title"
printf '%s' "$(run --advise)" | grep -qF "$SECRET_TITLE" \
  && bad "G2 the SessionStart advisory leaked a title" "$(run --advise)" \
  || ok "G2 the one-line advisory carries no title either"
printf '%s' "$(run --verbose)" | grep -qF "$SECRET_TITLE" \
  && ok "G3 --verbose DOES show titles (the local operator still needs to see what it is)" \
  || bad "G3 --verbose hid the title too — the detail became unreachable" "$(run --verbose)"

echo "-- H. the SessionStart advisory: one line, self-clearing, never fatal -----------"

ADV="$(run --advise)"
AL="$(printf '%s' "$ADV" | grep -c '')"
[ "$AL" -eq 1 ] && ok "H1 --advise emits exactly ONE line (the SessionStart budget)" \
  || bad "H1 --advise emitted $AL lines, expected 1" "$ADV"
AB="$(printf '%s' "$ADV" | wc -c | tr -d ' ')"
[ "$AB" -le 420 ] && ok "H2 the advisory line is ${AB}B (budget 420B)" \
  || bad "H2 advisory is ${AB}B, over the 420B budget" "$ADV"
printf '%s' "$ADV" | grep -q 'heimdall-sla' \
  && ok "H3 the advisory carries a runnable command to see the detail" || bad "H3 no runnable remedy" "$ADV"
RC="$(rc_of --advise)"
[ "$RC" = 0 ] && ok "H4 --advise ALWAYS exits 0 (a monitor may not break the session)" \
  || bad "H4 --advise exited $RC — it can break a SessionStart hook" "$ADV"

new_ledger
triage 100 FIXED "Redaction landed in 3a4b255 and the logcat write path is scrubbed before it is flushed."
triage 102 ACCEPTED-RISK "Hostname is already public in the shipped docs; disclosure adds nothing new to an attacker."
triage 103 FALSE-POSITIVE "classify() re-reads the status file each run so a granted state cannot persist."
[ -z "$(run --advise)" ] && ok "H5 --advise is SILENT when nothing is in breach" \
  || bad "H5 --advise spoke on a clean queue" "$(run --advise)"
# A blind scan must still SPEAK at session start — silence there would be the original bug.
BADV="$("$SLA" --db "$WORK/nope.db" --decisions "$DEC" --project heimdall --now "$NOW" --advise 2>&1)"
[ -n "$BADV" ] && ok "H6 a BLIND scan still speaks in --advise (silence would be the original bug)" \
  || bad "H6 --advise went silent when the store was unreadable"

echo "-- M. MUTATION: prove the red paths are checks, not tautologies -----------------"

m_run() { "$1" --db "$DB" --decisions "$DEC" --project heimdall --now "$NOW" "${@:2}" 2>&1; }
m_rc()  { "$1" --db "$DB" --decisions "$DEC" --project heimdall --now "$NOW" >"$WORK/mo" 2>&1; echo $?; }

new_ledger   # back to zero triage: the real binary is RED here (case A)

# m1 — force the age comparison always-false: nothing is ever "overdue".
M1="$WORK/sla.m1"
sed 's/^  \[ "\$age_s" -gt "\$window_s" \] && overdue=1 || overdue=0$/  overdue=0/' "$SLA" > "$M1"
chmod +x "$M1"
if cmp -s "$M1" "$SLA"; then
  bad "M0 the age-comparison anchor is missing from bin/heimdall-sla — m1 could not be built"
else
  M1RC="$(m_rc "$M1")"
  if [ "$M1RC" = 1 ] && printf '%s' "$(m_run "$M1")" | grep -q 'BREACH.*\b100\b'; then
    bad "M1 SURVIVED: the mutant that can never mark an item overdue still went RED — case A is a tautology"
  else
    ok "M1 KILLED: forcing the age comparison always-false flips case A to green -> case A is a real check"
  fi
fi

# m2 — force "no verdict" to count as a pass.
M2="$WORK/sla.m2"
sed 's/^    status=breach$/    status=triaged/' "$SLA" > "$M2"
chmod +x "$M2"
if cmp -s "$M2" "$SLA"; then
  bad "M0 the no-verdict-is-breach anchor is missing from bin/heimdall-sla — m2 could not be built"
else
  M2RC="$(m_rc "$M2")"
  if [ "$M2RC" = 1 ] && printf '%s' "$(m_run "$M2")" | grep -q 'BREACH.*\b100\b'; then
    bad "M2 SURVIVED: the mutant that treats a missing verdict as a pass still went RED"
  else
    ok "M2 KILLED: making 'no verdict' a pass flips case A to green -> the breach rule is load-bearing"
  fi
fi

# m3 — force the fail-closed guard open: blind() returns instead of exiting, so a scan
# that could not read its source falls through and reports whatever it managed to see.
M3="$WORK/sla.m3"
sed 's/^  exit 2$/  return 0/' "$SLA" > "$M3"
chmod +x "$M3"
if cmp -s "$M3" "$SLA"; then
  bad "M0 the blind() fail-closed anchor is missing from bin/heimdall-sla — m3 could not be built"
else
  M3RC="$("$M3" --db "$WORK/nope.db" --decisions "$DEC" --project heimdall --now "$NOW" >"$WORK/mo" 2>&1; echo $?)"
  [ "$M3RC" = 2 ] \
    && bad "M3 SURVIVED: removing every blind() call still exited 2 — case D is a tautology" \
    || ok "M3 KILLED: disarming the fail-closed guard changes D's exit -> D is a real check"
fi

echo "-- S. syntax -------------------------------------------------------------------"
bash -n "$SLA" 2>"$WORK/syn" && ok "S1 bin/heimdall-sla parses" || bad "S1 syntax error" "$(cat "$WORK/syn")"

echo
printf "  security-sla: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
