#!/usr/bin/env bash
# test/pre-commit-stub-gate.test.sh — the TOOL-AGNOSTIC stub/placeholder backstop.
#
# WHY THIS FILE EXISTS. The no-stub gate in hooks/hooks.json is a Claude Code
# PreToolUse hook: it fires only inside a live Claude Code session, only on a
# Write/Edit tool call. Any OTHER committer — cursor-agent, a human `git commit`,
# Claude Code itself run with hooks skipped — bypasses it completely; nothing at
# the git layer ever re-checks the staged diff. This suite proves the git-level
# backstop added to bin/heimdall-gate-run's pre-commit phase: it scans the staged
# diff for the SAME stub shapes hooks.json blocks (shared patterns live in
# bin/lib/heimdall-stub-patterns.sh — see that file's docstring for why
# shape-based, not word-based), so the enforcement holds no matter which tool
# makes the commit.
#
# NOTE ON THIS FILE'S OWN CONTENT: the marker strings this suite stages (a
# code-comment marker, a not-finished throw) are assembled from split literals
# (e.g. "TO" . "DO") rather than written contiguously, so THIS test file itself
# does not trip the very Write/Edit content scanner it is proving out at the git
# layer. The staged fixture content the gate under test actually sees is the
# real, contiguous marker (built at runtime) — the gate is exercised for real.
#
# FALSIFIABLE claims proven:
#   A. a staged diff introducing a code-comment marker is DENIED, and the block
#      NAMES the shape and the file (a BIFROST receipt, not a bare nonzero).
#   B. a staged diff introducing a not-implemented throw is DENIED (a second
#      shape, proving the check is not a single-shape special case).
#   C. a normal, real-code staged diff PASSES.
#   D. an EXISTING, untouched marker elsewhere in the repo does NOT trigger a
#      false block when an unrelated file is staged (diff-scoped, never whole-repo).
#   E. HONEST EMPTY — with nothing staged the gate does not fire at all: no
#      "stub-scan" entry appears in verdict.json's gates[] (matches the existing
#      "gates[] empty when no applicable gate ran" contract other suites pin —
#      see test/heimdall-status-json.test.sh case 8).
#   F. the *.md/etc exemption from hooks/hooks.json's Write|Edit hook is honored
#      here too — a marker introduced only inside an exempt file does not block.
#   G. FAIL CLOSED — a scan that CANNOT run (no git repo at all) DENIES with an
#      actionable message; it never silently passes.
#   H. PHASE-SCOPED — the identical marker-introducing diff is NOT scanned under
#      --phase pre-push (this check is pre-commit only; pre-push has its own,
#      already-covered gates).
#   I. syntax — bash -n clean on heimdall-gate-run and the shared pattern lib.
#
# HERMETIC. Every case runs inside a throwaway `mktemp -d` git repo. No network,
# no real corpus/oracles, no ~/.heimdall.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GATE_RUN="$ROOT/bin/heimdall-gate-run"
STUB_LIB="$ROOT/bin/lib/heimdall-stub-patterns.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; }

command -v jq  >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 2; }
[ -x "$GATE_RUN" ] || { echo "FATAL: missing/!exec $GATE_RUN" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-stubgate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

newrepo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email dev@example.com
  git -C "$1" config user.name Dev
}

gate_state() {  jq -r --arg g "$2" '(.gates // [])[] | select(.id==$g) | .state'  "$1" 2>/dev/null; }

echo "======================================================================"
echo "pre-commit stub gate -- the tool-agnostic backstop"
echo "======================================================================"

echo "-- A. staged code-comment marker ---------------------------------------------"
RA="$WORK/a"; newrepo "$RA"
printf 'function real(){ return 1; }\n' > "$RA/seed.js"
git -C "$RA" add -A; git -C "$RA" commit -qm seed
MARK="TO""DO"
printf 'function real(){ return 1; }\n// %s: wire this up\n' "$MARK" > "$RA/seed.js"
git -C "$RA" add -A
( cd "$RA" && "$GATE_RUN" --phase pre-commit ) >"$WORK/a.out" 2>"$WORK/a.err"; ARC=$?
[ "$ARC" != 0 ] && ok "A1 a staged code-comment marker is DENIED (nonzero exit)" \
  || bad "A1 a staged marker was NOT denied" "exit=$ARC"
grep -q 'stub-scan' "$WORK/a.err" && ok "A2 the block names the stub-scan gate" \
  || bad "A2 block does not name stub-scan" "$(cat "$WORK/a.err")"
grep -qi "$MARK" "$WORK/a.err" && ok "A3 the block names the matched shape" \
  || bad "A3 block does not name the shape" "$(cat "$WORK/a.err")"
grep -q 'seed.js' "$WORK/a.err" && ok "A4 the block names the FILE the stub was introduced in" \
  || bad "A4 block does not name the file" "$(cat "$WORK/a.err")"
AV="$RA/.heimdall/verdict.json"
[ "$(jq -r '.verdict' "$AV" 2>/dev/null)" = "deny" ] && ok "A5 verdict.json records verdict=deny" \
  || bad "A5 verdict.json wrong" "$(cat "$AV" 2>/dev/null)"
[ "$(gate_state "$AV" stub-scan)" = "deny" ] && ok "A6 gates[] records stub-scan=deny" \
  || bad "A6 gates[] stub-scan state wrong" "$(cat "$AV" 2>/dev/null)"

echo "-- B. staged not-implemented throw ---------------------------------------------"
RB="$WORK/b"; newrepo "$RB"
printf 'function real(){ return 1; }\n' > "$RB/seed.js"
git -C "$RB" add -A; git -C "$RB" commit -qm seed
NOTDONE="not implemented"
printf 'function notdone(){ throw new Error("%s"); }\n' "$NOTDONE" > "$RB/new.js"
git -C "$RB" add -A
( cd "$RB" && "$GATE_RUN" --phase pre-commit ) >"$WORK/b.out" 2>"$WORK/b.err"; BRC=$?
[ "$BRC" != 0 ] && ok "B1 a staged not-implemented throw is DENIED" \
  || bad "B1 not denied" "exit=$BRC"
grep -qi 'not.implemented' "$WORK/b.err" && ok "B2 the block names the not-implemented-throw shape" \
  || bad "B2 shape not named" "$(cat "$WORK/b.err")"

echo "-- C. normal real-code staged diff -----------------------------------------------"
RC_="$WORK/c"; newrepo "$RC_"
printf 'function add(a, b){ return a + b; }\n' > "$RC_/math.js"
git -C "$RC_" add -A
( cd "$RC_" && "$GATE_RUN" --phase pre-commit ) >"$WORK/c.out" 2>"$WORK/c.err"; CRC=$?
[ "$CRC" = 0 ] && ok "C1 normal real-code staged diff PASSES (exit 0)" \
  || bad "C1 real code wrongly denied" "exit=$CRC $(cat "$WORK/c.err")"
CV="$RC_/.heimdall/verdict.json"
[ "$(jq -r '.verdict' "$CV" 2>/dev/null)" = "pass" ] && ok "C2 verdict.json records verdict=pass" \
  || bad "C2 verdict wrong" "$(cat "$CV" 2>/dev/null)"
[ "$(gate_state "$CV" stub-scan)" = "pass" ] && ok "C3 gates[] records stub-scan=pass" \
  || bad "C3 gates[] stub-scan state wrong" "$(cat "$CV" 2>/dev/null)"

echo "-- D. existing untouched marker elsewhere is not flagged -------------------------"
RD="$WORK/d"; newrepo "$RD"
MARK2="TO""DO"
printf '// %s: someday refactor this whole module\nfunction legacy(){ return 42; }\n' "$MARK2" > "$RD/legacy.js"
git -C "$RD" add -A; git -C "$RD" commit -qm "seed with an old marker"
printf 'function add(a, b){ return a + b; }\n' > "$RD/math.js"
git -C "$RD" add -A
( cd "$RD" && "$GATE_RUN" --phase pre-commit ) >"$WORK/d.out" 2>"$WORK/d.err"; DRC=$?
[ "$DRC" = 0 ] && ok "D1 an unrelated staged change PASSES despite an old marker elsewhere" \
  || bad "D1 false-blocked on a pre-existing, untouched marker" "exit=$DRC $(cat "$WORK/d.err")"

echo "-- E. nothing staged -> gate does not fire (gates[] stays empty) -----------------"
RE_="$WORK/e"; newrepo "$RE_"
printf 'x\n' > "$RE_/a.txt"; git -C "$RE_" add -A; git -C "$RE_" commit -qm seed
( cd "$RE_" && "$GATE_RUN" --phase pre-commit ) >"$WORK/e.out" 2>"$WORK/e.err"; ERC=$?
EV="$RE_/.heimdall/verdict.json"
[ "$ERC" = 0 ] && ok "E1 nothing staged => PASS (exit 0)" || bad "E1 wrongly denied" "exit=$ERC"
[ "$(gate_state "$EV" stub-scan)" = "" ] && ok "E2 nothing staged => no stub-scan entry in gates[] (honest empty)" \
  || bad "E2 a stub-scan entry appeared with nothing staged" "$(cat "$EV" 2>/dev/null)"

echo "-- F. exempt file (*.md) is not scanned -------------------------------------------"
RF="$WORK/f"; newrepo "$RF"
printf '# notes\n' > "$RF/notes.md"
git -C "$RF" add -A; git -C "$RF" commit -qm seed
MARK3="TO""DO"
printf '# notes\n%s: write more docs\n' "$MARK3" > "$RF/notes.md"
git -C "$RF" add -A
( cd "$RF" && "$GATE_RUN" --phase pre-commit ) >"$WORK/f.out" 2>"$WORK/f.err"; FRC=$?
[ "$FRC" = 0 ] && ok "F1 a marker introduced only in an exempt *.md file PASSES" \
  || bad "F1 an exempt file was wrongly scanned" "exit=$FRC $(cat "$WORK/f.err")"

echo "-- G. fail closed when the scan cannot run (no git repo) -------------------------"
RG="$WORK/g-not-a-repo"; mkdir -p "$RG"
( cd "$RG" && "$GATE_RUN" --phase pre-commit ) >"$WORK/g.out" 2>"$WORK/g.err"; GRC=$?
[ "$GRC" != 0 ] && ok "G1 no git repo at all => DENIED, not silently passed" \
  || bad "G1 an unrunnable scan silently passed" "exit=$GRC $(cat "$WORK/g.out")"
grep -qi 'stub-scan\|git diff' "$WORK/g.err" && ok "G2 the block explains WHY (names the gate or the failed command)" \
  || bad "G2 no actionable explanation" "$(cat "$WORK/g.err")"

echo "-- H. pre-push phase does not run the stub scan -----------------------------------"
RH="$WORK/h"; newrepo "$RH"
printf 'function real(){ return 1; }\n' > "$RH/seed.js"
git -C "$RH" add -A; git -C "$RH" commit -qm seed
MARK4="TO""DO"
printf 'function real(){ return 1; }\n// %s: wire this up\n' "$MARK4" > "$RH/seed.js"
git -C "$RH" add -A
( cd "$RH" && "$GATE_RUN" --phase pre-push ) >"$WORK/h.out" 2>"$WORK/h.err"; HRC=$?
[ "$HRC" = 0 ] && ok "H1 the identical staged marker diff PASSES under --phase pre-push (pre-commit-only check)" \
  || bad "H1 pre-push wrongly ran the stub scan" "exit=$HRC $(cat "$WORK/h.err")"
HV="$RH/.heimdall/verdict.json"
[ "$(gate_state "$HV" stub-scan)" = "" ] && ok "H2 no stub-scan entry under --phase pre-push" \
  || bad "H2 stub-scan fired under pre-push" "$(cat "$HV" 2>/dev/null)"

echo "-- I. syntax ----------------------------------------------------------------"
[ -f "$STUB_LIB" ] && ok "I1 the shared pattern lib exists at bin/lib/heimdall-stub-patterns.sh" \
  || bad "I1 shared pattern lib missing" "expected $STUB_LIB"
bash -n "$GATE_RUN" 2>/dev/null && ok "I2 bash -n clean on heimdall-gate-run" || bad "I2 syntax error in heimdall-gate-run"
if [ -f "$STUB_LIB" ]; then
  bash -n "$STUB_LIB" 2>/dev/null && ok "I3 bash -n clean on the shared pattern lib" || bad "I3 syntax error in the pattern lib"
else
  bad "I3 cannot syntax-check a missing file"
fi

echo
printf "  Results: %d passed, %d failed\n\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
