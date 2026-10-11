#!/usr/bin/env bash
# test/run-all-incremental.test.sh -- INCREMENTAL SWEEPS ARE CHAINED TO THE LAST FULL GREEN RUN, AND ONLY ONE SWEEP RUNS AT A TIME.
#
# WHY THIS EXISTS. The ~500-suite sweep (~70 min at --jobs 2) ran about nine times in one day, mostly because each small
# merge staled the last green receipt (bin/heimdall-state check-quality-gates trusts a receipt only for the HEAD it graded).
# `run-all.sh --since-green` re-runs only the suites a diff can affect and writes a receipt that says so (kind=incremental),
# and the push gate accepts it only while it CHAINS to a green FULL receipt and the selection rules held. A release still
# needs the FULL receipt. A second sweep in the same checkout is refused instead of competing for the same machine.
#
# Proven here, against throwaway git repos holding the REAL run-all.sh / bin/heimdall-state / release/ship.sh and fake suites:
#   A  selection: an unaffected suite is skipped; a suite naming a changed path, a changed test file, or a script a changed
#      module feeds is selected; a red suite from the previous run is carried forward
#   B  escalation to a full sweep: test/gate infrastructure touched, base too old, too many files, too large a selection,
#      no green full base at all; a dirty tree is refused (an incremental receipt must describe HEAD)
#   C  the gate: accepts a chained incremental (hook-owned-path exemption intact), rejects an unchained one, and asks for
#      `--since-green` when a base exists and for a full run when it does not
#   D  release/ship.sh needs a green FULL receipt at HEAD -- an incremental one, or none, refuses before anything is bumped
#   E  one sweep at a time: a concurrent run is refused naming the running pid, a finished or SIGKILLed holder wedges nothing
#   F  retry hygiene: red under load + green solo = FLAKY-UNDER-LOAD in the receipt (counts green, never hidden); a red that
#      stays red alone stays red
#
# HERMETIC: every case runs in a throwaway repo under $TMPDIR with its own HOME/TMPDIR; nothing touches the real receipts.
# EXIT: 0 = every proof holds; 1 = any FAIL.
# shellcheck disable=SC2016  # the fixture suites are written LITERALLY: their $VARs must reach the file unexpanded
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RUN_ALL="$ROOT/test/run-all.sh"
STATE_BIN="$ROOT/bin/heimdall-state"
SHIP="$ROOT/release/ship.sh"
LIB_HOOK="$ROOT/bin/lib/hook-owned-path.sh"
LIB_CHAIN="$ROOT/bin/lib/sweep-chain.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing [$3] in: $(printf '%s' "$2" | tail -c 700)" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $(printf '%s' "$2" | tail -c 700)" ;; *) ok "$1" ;; esac; }

command -v jq  >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 2; }
for f in "$RUN_ALL" "$STATE_BIN" "$SHIP" "$LIB_HOOK"; do [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 2; }; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-run-all-incr.XXXXXX")"
[ -n "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 2; }
mkdir -p "$WORK/tmp" "$WORK/home"
BG_PIDS=""
cleanup() {
  local p
  for p in $BG_PIDS; do kill -KILL "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT
unset HEIMDALL_HOME 2>/dev/null || true
# `mark-clean` only sets lint_clean against a passing lint_last_run receipt (bin/heimdall-stop-lint writes it), and the gate
# blocks without it. These fixtures prove sweep receipts, not lint evidence, so they waive lint explicitly and visibly (the
# waiver is logged in the fixture's state), as test/conflict-log.test.sh and test/checkpoint-depth.test.sh do.
LINT_WAIVER="fixture: run-all-incremental proves sweep receipts, not lint evidence"

# ── fixture: a repo with the real tools plus 12 fake suites; alpha/beta/gamma each name one thing a diff can touch ───────
SUITES="alpha beta gamma f01 f02 f03 f04 f05 f06 f07 f08 f09"
mkfix() { # dir [commit-date]
  local d="$1" s ref
  mkdir -p "$d/test/lib" "$d/bin/lib" "$d/docs" "$d/hooks"
  git -C "$d" init -q
  git -C "$d" config user.email t@example.com; git -C "$d" config user.name T
  printf '.heimdall/\n' > "$d/.gitignore"
  cp "$RUN_ALL" "$d/test/run-all.sh"
  cp "$LIB_HOOK" "$d/bin/lib/hook-owned-path.sh"
  [ -f "$LIB_CHAIN" ] && cp "$LIB_CHAIN" "$d/bin/lib/sweep-chain.sh"
  cp "$STATE_BIN" "$d/bin/heimdall-state"
  printf '#!/bin/sh\necho tool-a\n' > "$d/bin/tool-a"; printf '#!/bin/sh\necho tool-b\n' > "$d/bin/tool-b"
  echo "guide v1" > "$d/docs/guide.md"; echo "notes v1" > "$d/notes.txt"
  echo "# helper" > "$d/test/lib/helper.sh"; echo '{}' > "$d/hooks/hooks.json"
  for s in $SUITES; do
    case "$s" in alpha) ref="bin/tool-a" ;; beta) ref="bin/tool-b" ;; gamma) ref="docs/guide.md" ;; *) ref="nothing" ;; esac
    printf '%s\n' '#!/usr/bin/env bash' "# fixture suite $s -- exercises: $ref" \
      '[ -n "${MARKLOG:-}" ] && echo '"$s"' >> "$MARKLOG"' \
      '[ "${SLOW_SUITE:-}" = '"$s"' ] && sleep "${SLOW_SECS:-0}"' \
      '[ "${FAIL_SUITE:-}" = '"$s"' ] && { echo "  FAIL assertion in '"$s"'"; echo "0 passed, 1 failed"; exit 1; }' \
      'echo "1 passed, 0 failed"' > "$d/test/$s.test.sh"
  done
  git -C "$d" add -A
  if [ -n "${2:-}" ]; then GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" git -C "$d" commit -qm "fixture"
  else git -C "$d" commit -qm "fixture"; fi
}
cm() { git -C "$1" add -A && git -C "$1" commit -qm "${2:-change}"; }          # commit everything pending in fixture $1
sha() { git -C "$1" rev-parse HEAD; }
runit() { # dir [run-all args] -> OUT, RC   (MARKLOG records which suites ran)
  local d="$1"; shift; : > "$d.marks"
  OUT="$( cd "$d" && HOME="$WORK/home" TMPDIR="$WORK/tmp" MARKLOG="$d.marks" HEIMDALL_STATE_FILE="$d.state.json" \
          bash test/run-all.sh --min 1 --jobs 2 "$@" 2>&1 )"; RC=$?
}
ran() { sort -u "$1.marks" | tr '\n' ' ' | sed 's/ $//'; }
rj() { jq -r "$2" "$1" 2>/dev/null; }
LAST() { printf '%s/.heimdall/receipts/last-sweep.json' "$1"; }
FULLG() { printf '%s/.heimdall/receipts/last-full-green.json' "$1"; }
gate() { # dir -> GOUT, GRC
  GOUT="$( cd "$1" && HOME="$WORK/home" HEIMDALL_STATE_FILE="$1.state.json" "$1/bin/heimdall-state" check-quality-gates 2>&1 )"; GRC=$?
}
newfix() { # name [commit-date] -> FIX; builds the fixture and records a green FULL baseline sweep
  FIX="$WORK/$1"; mkfix "$FIX" "${2:-}"
  ( cd "$FIX" && HEIMDALL_STATE_FILE="$FIX.state.json" "$STATE_BIN" init >/dev/null 2>&1 \
    && HMD_LINT_WAIVER="$LINT_WAIVER" HEIMDALL_STATE_FILE="$FIX.state.json" "$STATE_BIN" mark-clean >/dev/null 2>&1 )
  runit "$FIX"
}
touchfile() { printf '%s\n' "# changed $(date +%s)-$RANDOM" >> "$1/$2"; }   # a trailing comment: valid in every fixture script, a real diff for git

echo "════════════════════════════════════════════════════════════════"
echo "run-all --since-green: incremental sweeps chained to the last full green; one sweep at a time"
echo "════════════════════════════════════════════════════════════════"

# ══ A. SELECTION ══════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- A0. a full sweep records kind=full and the chain anchor ------------------------------------"
newfix a1; F="$FIX"; BASE="$(sha "$F")"
eq "A0a baseline full sweep is green" "$RC" "0"
eq "A0b receipt kind is full" "$(rj "$(LAST "$F")" '.kind')" "full"
eq "A0c last-full-green.json is written by a green full sweep, naming HEAD" "$(rj "$(FULLG "$F")" '.head_sha')" "$BASE"
eq "A0d all 12 suites ran" "$(rj "$(LAST "$F")" '.suites_total')" "12"

echo "-- A1. a suite naming a changed script is selected; every other suite is skipped ------------"
touchfile "$F" bin/tool-a; cm "$F" "edit tool-a"
runit "$F" --since-green
eq "A1a incremental sweep is green" "$RC" "0"
eq "A1b ONLY the suite referencing bin/tool-a ran" "$(ran "$F")" "alpha"
eq "A1c receipt kind=incremental" "$(rj "$(LAST "$F")" '.kind')" "incremental"
eq "A1d receipt chains to the full green base" "$(rj "$(LAST "$F")" '.base_full_sha')" "$BASE"
eq "A1e receipt lists exactly the suites it ran" "$(rj "$(LAST "$F")" '.suites_run | join(",")')" "alpha.test.sh"
case "$(rj "$(LAST "$F")" '.selection.reason')" in ?*) ok "A1f receipt carries the selection reason" ;; *) bad "A1f selection.reason empty" ;; esac
eq "A1g the receipt describes HEAD" "$(rj "$(LAST "$F")" '.head_sha')" "$(sha "$F")"
eq "A1h an incremental run never moves the full-green anchor" "$(rj "$(FULLG "$F")" '.head_sha')" "$BASE"
has "A1i the run says it was incremental" "$OUT" "incremental"

echo "-- A2. nothing references the change: no suite runs, the receipt is still written and green ----"
newfix a2; F="$FIX"
touchfile "$F" notes.txt; cm "$F" "edit notes"
runit "$F" --since-green
eq "A2a exit 0" "$RC" "0"
eq "A2b no suite ran" "$(ran "$F")" ""
eq "A2c receipt kind=incremental with an empty suites_run" "$(rj "$(LAST "$F")" '[.kind, (.suites_run|length)]|join(",")')" "incremental,0"
eq "A2d receipt exit_code 0" "$(rj "$(LAST "$F")" '.exit_code')" "0"
has "A2e verdict line is green" "$OUT" "RUN GREEN"

echo "-- A3. a changed path named by a suite, and a changed test file, each select their suite ------"
newfix a3; F="$FIX"
touchfile "$F" docs/guide.md; touchfile "$F" test/f03.test.sh; cm "$F" "edit guide + f03"
runit "$F" --since-green
eq "A3a gamma (names docs/guide.md) and f03 (the changed test file itself) ran, nothing else" "$(ran "$F")" "f03 gamma"
eq "A3b exit 0" "$RC" "0"

echo "-- A4. a module a script depends on selects the suites that run that script --------------------"
F="$WORK/a4"; mkfix "$F"; printf '%s\n' 'source "$(dirname "$0")/lib/shared.sh"' > "$F/bin/tool-b"; echo 'echo shared v1' > "$F/bin/lib/shared.sh"; cm "$F" "tool-b sources shared.sh"
( cd "$F" && HEIMDALL_STATE_FILE="$F.state.json" "$STATE_BIN" init >/dev/null 2>&1 && HMD_LINT_WAIVER="$LINT_WAIVER" HEIMDALL_STATE_FILE="$F.state.json" "$STATE_BIN" mark-clean >/dev/null 2>&1 )
runit "$F"; touchfile "$F" bin/lib/shared.sh; cm "$F" "edit shared lib"
runit "$F" --since-green
eq "A4a beta (runs tool-b, which sources the changed lib) ran; no suite mentions shared.sh itself" "$(ran "$F")" "beta"

echo "-- A5. a suite that was red in the previous run is carried forward even if the diff cannot reach it --"
newfix a5; F="$FIX"
touchfile "$F" bin/tool-a; cm "$F" "edit tool-a"
FAIL_SUITE=f05 runit "$F"
eq "A5a the full run is red (f05 fails alone too)" "$RC" "1"
eq "A5b a red full run does not become the full-green anchor" "$(rj "$(FULLG "$F")" '.head_sha')" "$(git -C "$F" rev-list --max-parents=0 HEAD)"
eq "A5c the red run recorded its non-green suites" "$(rj "$(LAST "$F")" '.non_green_suites | join(",")')" "f05.test.sh"
runit "$F" --since-green
eq "A5d the incremental run re-ran alpha (changed) AND f05 (red last time)" "$(ran "$F")" "alpha f05"
has "A5e the reason says why f05 was included" "$(rj "$(LAST "$F")" '.selection.reason')" "carried"

# ══ B. ESCALATION ═════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- B1. test infrastructure changed: a full sweep, whatever else the diff holds -------------------"
for infra in test/lib/helper.sh hooks/hooks.json test/run-all.sh bin/heimdall-state; do
  newfix "b1-$(printf '%s' "$infra" | tr '/.' '__')"; F="$FIX"
  touchfile "$F" "$infra"; cm "$F" "edit $infra"
  runit "$F" --since-green
  eq "B1 [$infra] escalated to a FULL sweep: every suite ran" "$(ran "$F" | wc -w | tr -d ' ')" "12"
  eq "B1 [$infra] receipt kind=full, escalated_from=since-green" "$(rj "$(LAST "$F")" '[.kind, .escalated_from]|join(",")')" "full,since-green"
  has "B1 [$infra] reason names the infrastructure" "$(rj "$(LAST "$F")" '.escalation_reason')" "infrastructure"
done
has "B1z the run output announces the escalation" "$OUT" "ESCALATED TO FULL"
eq "B1y the escalated full run is green and becomes the new anchor" "$(rj "$(FULLG "$F")" '.head_sha')" "$(sha "$F")"

echo "-- B2. the last full green is older than 7 days: a full sweep ------------------------------------"
newfix b2 "2020-01-01T00:00:00Z"; F="$FIX"
touchfile "$F" bin/tool-a; cm "$F" "edit tool-a"
runit "$F" --since-green
eq "B2a all 12 suites ran" "$(ran "$F" | wc -w | tr -d ' ')" "12"
has "B2b reason says the base is too old" "$(rj "$(LAST "$F")" '.escalation_reason')" "days old"

echo "-- B3. too many files changed: a full sweep ------------------------------------------------------"
newfix b3; F="$FIX"
touchfile "$F" bin/tool-a; touchfile "$F" notes.txt; touchfile "$F" docs/guide.md; cm "$F" "three files"
HMD_SWEEP_MAX_FILES=2 runit "$F" --since-green
eq "B3a all 12 suites ran" "$(ran "$F" | wc -w | tr -d ' ')" "12"
has "B3b reason names the file count" "$(rj "$(LAST "$F")" '.escalation_reason')" "files changed"

echo "-- B4. too large a share of the suites selected: a full sweep -----------------------------------"
newfix b4; F="$FIX"
touchfile "$F" bin/tool-a; cm "$F" "edit tool-a"
HMD_SWEEP_MAX_SELECTED_PCT=5 runit "$F" --since-green
eq "B4a all 12 suites ran" "$(ran "$F" | wc -w | tr -d ' ')" "12"
has "B4b reason names the selected share" "$(rj "$(LAST "$F")" '.escalation_reason')" "would be re-run"

echo "-- B5. no green full sweep to chain to: a full sweep ----------------------------------------------"
F="$WORK/b5"; mkfix "$F"
runit "$F" --since-green
eq "B5a all 12 suites ran" "$(ran "$F" | wc -w | tr -d ' ')" "12"
has "B5b reason says there is no green full base" "$(rj "$(LAST "$F")" '.escalation_reason')" "no green full"
eq "B5c the escalated run is a full sweep and anchors the chain" "$(rj "$(FULLG "$F")" '.head_sha')" "$(sha "$F")"

echo "-- B6. an uncommitted change: refused, and the previous receipt is left alone -----------------------"
newfix b6; F="$FIX"; BEFORE="$(cat "$(LAST "$F")")"
touchfile "$F" bin/tool-a
runit "$F" --since-green
eq "B6a exit 2" "$RC" "2"
has "B6b names the uncommitted change" "$OUT" "uncommitted"
eq "B6c no suite ran" "$(ran "$F")" ""
eq "B6d the previous receipt is untouched" "$(cat "$(LAST "$F")")" "$BEFORE"
runit "$F" --since-green --filter alpha
eq "B6e --since-green cannot be combined with --filter" "$RC" "2"

echo "-- B7. too many commits since the last full green: a full sweep ------------------------------------"
newfix b7; F="$FIX"
touchfile "$F" bin/tool-a; cm "$F" "one"; touchfile "$F" notes.txt; cm "$F" "two"
HMD_SWEEP_MAX_BASE_COMMITS=1 runit "$F" --since-green
eq "B7a all 12 suites ran" "$(ran "$F" | wc -w | tr -d ' ')" "12"
has "B7b reason names the commit count" "$(rj "$(LAST "$F")" '.escalation_reason')" "commits since"

echo "-- B8. history rewritten, the last full green is no ancestor of HEAD: a full sweep ------------------"
newfix b8; F="$FIX"
git -C "$F" checkout -q --orphan rewritten && git -C "$F" add -A && git -C "$F" commit -qm "rewritten history"
runit "$F" --since-green
eq "B8a all 12 suites ran" "$(ran "$F" | wc -w | tr -d ' ')" "12"
has "B8b reason says the base is no ancestor" "$(rj "$(LAST "$F")" '.escalation_reason')" "not an ancestor"

echo "-- B9. a --filter run is neither full nor incremental: it never reaches the gate or the chain --------"
newfix b9; F="$FIX"; BEFORE="$(cat "$(LAST "$F")")"; ANCHOR_BEFORE="$(cat "$(FULLG "$F")")"
runit "$F" --filter alpha
eq "B9a the filtered run is green and ran only the filtered suite" "$RC:$(ran "$F")" "0:alpha"
eq "B9b it did not replace the receipt the push gate reads" "$(cat "$(LAST "$F")")" "$BEFORE"
eq "B9c it recorded itself, as kind=filtered, in a file of its own" "$(rj "$F/.heimdall/receipts/last-filtered.json" '.kind')" "filtered"
eq "B9d it did not touch the chain anchor" "$(cat "$(FULLG "$F")")" "$ANCHOR_BEFORE"
gate "$F"; eq "B9e the gate still sees the green full sweep of this HEAD" "$GRC" "0"

# ══ C. THE GATE ═══════════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- C. gate: accepts a chained incremental, rejects an unchained one, asks for --since-green -----------"
newfix c1; F="$FIX"
gate "$F"; eq "C0 gate passes on the green full receipt" "$GRC" "0"
touchfile "$F" bin/tool-a; cm "$F" "edit tool-a"
gate "$F"; eq "C1a a stale full receipt blocks" "$GRC" "2"
has "C1b names staleness" "$GOUT" "STALE"
has "C1c the gate ASKS for --since-green when a green full base exists" "$GOUT" "--since-green"
runit "$F" --since-green
gate "$F"
eq "C2a the gate accepts a green incremental receipt chained to the full green" "$GRC" "0"
has "C2b it says the receipt is incremental" "$GOUT" "INCREMENTAL"
has "C2c it still prints the pass line" "$GOUT" "All quality gates pass"
mkdir -p "$F/.planning/journal"; echo entry > "$F/.planning/journal/2026-10-11-haid_x.md"; cm "$F" "journal: hook-owned"
gate "$F"
eq "C3a a hook-owned-only commit after the incremental receipt keeps it fresh" "$GRC" "0"
has "C3b with the hook-owned notice" "$GOUT" "hook-owned"
touchfile "$F" bin/tool-b; cm "$F" "edit tool-b"
gate "$F"
eq "C4a a code commit after the incremental receipt makes it STALE" "$GRC" "2"
has "C4b names staleness" "$GOUT" "STALE"
runit "$F" --since-green
eq "C5a the next incremental is cumulative from the SAME full base: alpha and beta both re-run" "$(ran "$F")" "alpha beta"
gate "$F"; eq "C5b and the gate accepts it" "$GRC" "0"

cp "$(FULLG "$F")" "$WORK/anchor.keep"; rm -f "$(FULLG "$F")"
gate "$F"
eq "C6a an incremental receipt with no full green behind it is rejected" "$GRC" "2"
has "C6b names the broken chain" "$GOUT" "does not chain"
mkdir -p "$F/.heimdall/receipts"; cp "$WORK/anchor.keep" "$(FULLG "$F")"
TAMPER="$(jq '.base_full_sha = "0000000000000000000000000000000000000000"' "$(LAST "$F")")"; printf '%s\n' "$TAMPER" > "$(LAST "$F")"
gate "$F"
eq "C7a an incremental receipt whose base is not the full-green anchor is rejected" "$GRC" "2"
has "C7b names the broken chain" "$GOUT" "does not chain"
runit "$F" --since-green
RED="$(jq '.selection.suites_selected = 12' "$(LAST "$F")")"; printf '%s\n' "$RED" > "$(LAST "$F")"
gate "$F"
eq "C8a a receipt whose recorded selection breaks the size rule is rejected" "$GRC" "2"
has "C8b names the selection rules" "$GOUT" "selection rules"
newfix c9; F="$FIX"; rm -rf "$F/.heimdall"
gate "$F"
eq "C9a no receipt at all blocks" "$GRC" "2"
has "C9b says so" "$GOUT" "no sweep receipt"
lacks "C9c with no full green to chain to, it asks for a full sweep, not --since-green" "$GOUT" "--since-green"
newfix c10; F="$FIX"
BOGUS="$(jq '.kind = "bogus"' "$(LAST "$F")")"; printf '%s\n' "$BOGUS" > "$(LAST "$F")"
gate "$F"
eq "C10a a receipt of an unknown kind is rejected" "$GRC" "2"
has "C10b names the unknown kind" "$GOUT" "unknown kind"

# ══ D. RELEASE NEEDS A FULL RECEIPT ═══════════════════════════════════════════════════════════════════════════════════
echo "-- D. release/ship.sh requires a green FULL receipt at HEAD --------------------------------------"
STUB="$WORK/stubbin"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/gh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/gitleaks"; chmod +x "$STUB/gh" "$STUB/gitleaks"
NOOP="$WORK/noop"; printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP"; chmod +x "$NOOP"
mkplug() { # dir -> fake plugin repo + bare origin; home dir for receipts at $dir.home
  local d="$1"
  mkdir -p "$d/release" "$d/bin/lib" "$d/.claude-plugin" "$d.home/receipts"
  cp "$SHIP" "$d/release/ship.sh"; cp "$ROOT/release/sync-release.sh" "$d/release/sync-release.sh"; cp "$LIB_HOOK" "$d/bin/lib/hook-owned-path.sh"
  printf '{\n  "name": "heimdall",\n  "version": "9.9.9"\n}\n' > "$d/.claude-plugin/plugin.json"
  printf '#!/usr/bin/env bash\necho "- line"\n' > "$d/bin/generate-changelog"; chmod +x "$d/bin/generate-changelog" "$d/release/ship.sh"
  git init -q "$d"; git -C "$d" config user.email "rj@runheimdall.dev"; git -C "$d" config user.name RJ
  git -C "$d" add -A; git -C "$d" commit -qm "initial fake plugin"; git -C "$d" branch -M main
  git init -q --bare "$d.git"; git -C "$d" remote add origin "$d.git"; git -C "$d" push -q -u origin main
}
receipt() { # file kind exit_code head repo
  jq -n --arg k "$2" --argjson rc "$3" --arg h "$4" --arg r "$5" \
    '{finished_at:"2026-10-11T00:00:00Z", repo:$r, head_sha:$h, tree_clean:true, exit_code:$rc, kind:$k, suites_total:1, suites_passed:1}' > "$1"
}
ship() { # dir [args] -> SOUT, SRC
  local d="$1"; shift
  SOUT="$( cd "$d" && HOME="$WORK/home" HEIMDALL_HOME="$d.home" GUARD_GITLEAKS_RC=0 SHIP_LANDMINE_LINT="$NOOP" SHIP_RENDERER="$NOOP" SHIP_SYNC_RELEASE="$NOOP" \
           PATH="$STUB:$PATH" bash "$d/release/ship.sh" "$@" 2>&1 )"; SRC=$?
}
P="$WORK/plug-d1"; mkplug "$P"; PCANON="$(git -C "$P" rev-parse --show-toplevel)"; PBASE="$(sha "$P")"
ship "$P" --no-npm
eq "D1a no receipt at all: ship refuses (non-zero)" "$([ "$SRC" != 0 ] && echo refused || echo shipped)" "refused"
has "D1b names the requirement" "$SOUT" "green FULL sweep receipt"
eq "D1c nothing was bumped" "$(git -C "$P" log --oneline | grep -c 'chore(release)')" "0"
receipt "$P.home/receipts/last-sweep.json" incremental 0 "$PBASE" "$PCANON"
ship "$P" --no-npm
eq "D2a only a green INCREMENTAL receipt at HEAD: ship refuses" "$([ "$SRC" != 0 ] && echo refused || echo shipped)" "refused"
has "D2b names the requirement" "$SOUT" "green FULL sweep receipt"
ship "$P" --release-only
eq "D2c --release-only (a tag + release) refuses too" "$([ "$SRC" != 0 ] && echo refused || echo shipped)" "refused"
has "D2d names the requirement" "$SOUT" "green FULL sweep receipt"
receipt "$P.home/receipts/last-full-green.json" full 0 "$PBASE" "$PCANON"
ship "$P" --no-npm
has "D3a a green FULL receipt at HEAD: ship accepts it" "$SOUT" "green FULL sweep receipt"
lacks "D3b and does not refuse on it" "$SOUT" "requires a green FULL"
has "D3c and carries on to the version bump" "$SOUT" "Version bump"
P2="$WORK/plug-d2"; mkplug "$P2"; P2CANON="$(git -C "$P2" rev-parse --show-toplevel)"; P2BASE="$(sha "$P2")"
receipt "$P2.home/receipts/last-full-green.json" full 0 "$P2BASE" "$P2CANON"
echo more > "$P2/more.txt"; git -C "$P2" add more.txt; git -C "$P2" commit -qm "code after the sweep"
ship "$P2" --no-npm
eq "D4a a green full receipt for an OLDER commit: ship refuses" "$([ "$SRC" != 0 ] && echo refused || echo shipped)" "refused"
has "D4b names staleness" "$SOUT" "STALE"
eq "D4c nothing was bumped" "$(git -C "$P2" log --oneline | grep -c 'chore(release)')" "0"

# ══ E. ONE SWEEP AT A TIME ════════════════════════════════════════════════════════════════════════════════════════════
echo "-- E. a second sweep in the same checkout is refused, naming the running pid ----------------------"
newfix e1; F="$FIX"
( cd "$F" && HOME="$WORK/home" TMPDIR="$WORK/tmp" SLOW_SUITE=f09 SLOW_SECS=6 MARKLOG="$F.marks" HEIMDALL_STATE_FILE="$F.state.json" \
    bash test/run-all.sh --min 1 --jobs 2 ) > "$WORK/e1-first.out" 2>&1 &
BG1=$!; BG_PIDS="$BG_PIDS $BG1"
await_holder() { # -> HOLDER: the pid the running sweep published in the lock (a LIVE pid: an old note may linger until it is replaced)
  local i=0
  HOLDER=""
  while [ "$i" -lt 100 ]; do
    HOLDER="$(sed -n 's/^pid=//p' "$F/.heimdall/receipts/sweep.lock" 2>/dev/null)"
    if [ -n "$HOLDER" ] && kill -0 "$HOLDER" 2>/dev/null; then return 0; fi
    HOLDER=""; sleep 0.1; i=$((i + 1))
  done
}
await_holder
if [ -n "$HOLDER" ] && kill -0 "$HOLDER" 2>/dev/null; then ok "E0 the running sweep published its pid in the lock ($HOLDER)"; else bad "E0 no live pid in $F/.heimdall/receipts/sweep.lock" "$(cat "$F/.heimdall/receipts/sweep.lock" 2>/dev/null)"; fi
runit "$F"
eq "E1a the concurrent run is refused (exit 4)" "$RC" "4"
has "E1b it says another sweep is running" "$OUT" "already running"
has "E1c it names the running pid" "$OUT" "pid $HOLDER"
lacks "E1d it started no suite (no progress line)" "$OUT" "progress ["
wait "$BG1" 2>/dev/null
eq "E2a the first sweep finished green (the refused run did not disturb it)" "$(rj "$(LAST "$F")" '.exit_code')" "0"
runit "$F"
eq "E2b once the first sweep is done a new sweep runs" "$RC" "0"
( cd "$F" && HOME="$WORK/home" TMPDIR="$WORK/tmp" SLOW_SUITE=f09 SLOW_SECS=6 MARKLOG="$F.marks" HEIMDALL_STATE_FILE="$F.state.json" \
    bash test/run-all.sh --min 1 --jobs 2 ) > "$WORK/e1-second.out" 2>&1 &
BG2=$!; BG_PIDS="$BG_PIDS $BG2"
await_holder
kill -KILL "$HOLDER" 2>/dev/null; wait "$BG2" 2>/dev/null
runit "$F"
eq "E3 a sweep killed with SIGKILL leaves no stale lock: the next sweep runs" "$RC" "0"

# ══ F. RETRY HYGIENE ══════════════════════════════════════════════════════════════════════════════════════════════════
echo "-- F. red under load, green alone: FLAKY-UNDER-LOAD in the receipt; a real red stays red -----------"
F="$WORK/f1"; mkfix "$F"
printf '%s\n' '#!/usr/bin/env bash' 'if [ ! -f "$FLAKY_MARK" ]; then : > "$FLAKY_MARK"; echo "  FAIL contention-only failure"; echo "0 passed, 1 failed"; exit 1; fi' 'echo "1 passed, 0 failed"' > "$F/test/flaky.test.sh"
cm "$F" "add a flaky suite"
( cd "$F" && HEIMDALL_STATE_FILE="$F.state.json" "$STATE_BIN" init >/dev/null 2>&1 && HMD_LINT_WAIVER="$LINT_WAIVER" HEIMDALL_STATE_FILE="$F.state.json" "$STATE_BIN" mark-clean >/dev/null 2>&1 )
rm -f "$WORK/flaky.mark"; FLAKY_MARK="$WORK/flaky.mark" runit "$F"
eq "F1a the run is green: a suite green on its solo re-run counts as green" "$RC" "0"
has "F1b the run says FLAKY-UNDER-LOAD" "$OUT" "FLAKY-UNDER-LOAD"
eq "F1c the receipt names the flaky suite" "$(rj "$(LAST "$F")" '.flaky_under_load | map(.suite) | join(",")')" "flaky.test.sh"
eq "F1d the receipt keeps the exit codes of both runs" "$(rj "$(LAST "$F")" '.flaky_under_load[0] | "\(.parallel_exit)/\(.solo_exit)"')" "1/0"
has "F1e the receipt keeps the failing assertion the parallel run printed" "$(rj "$(LAST "$F")" '.flaky_under_load[0].parallel_fail_lines | join(" ")')" "contention-only failure"
eq "F1f exit_code is 0 -- reported, not hidden, not blocking" "$(rj "$(LAST "$F")" '.exit_code')" "0"
gate "$F"
has "F1g the gate names the flaky suite when it passes" "$GOUT" "flaky.test.sh"
FAIL_SUITE=f05 runit "$F"
eq "F2a a suite red alone too is a real red: exit 1" "$RC" "1"
eq "F2b it is not reported as flaky" "$(rj "$(LAST "$F")" '.flaky_under_load | length')" "0"
eq "F2c it is in non_green_suites" "$(rj "$(LAST "$F")" '.non_green_suites | map(select(. == "f05.test.sh")) | length')" "1"

echo
printf '  run-all-incremental: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
