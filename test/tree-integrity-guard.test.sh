#!/usr/bin/env bash
#
# tree-integrity-guard.test.sh — proves test/run-all.sh's guarantee #8 (REPO INTEGRITY):
# a suite that mutates a tracked file, or leaks an untracked entry into the repo ROOT, must
# fail the run LOUDLY and name the offender — never silently, never advisory.
#
# THE PATTERN this guards against (three real incidents, all found by accident, all
# invisible for hours): a hermetic test leaked a 30-minute orphan daemon past its own
# sandbox teardown; a disposable ad-hoc-signed test.app escaped its scratchpad and tripped
# Gatekeeper; a tracked repo file (bin/hmd) was silently replaced on disk by a dangling
# symlink into a deleted test sandbox, surfacing only as an easy-to-miss ` T ` in
# `git status`, undetected for hours, found only by accident. A fourth, found later: a
# test's own cleanup trap (test/heimdall-presence-keeper.test.sh) leaked an untracked
# directory into the REPO ROOT because a guarded-removal chain
# (`[ -n "$E1_HOME" ] && rm -rf "$E1_HOME"`) referenced a guard variable that was genuinely
# unset, and under this codebase's dominant `set -uo pipefail` convention that reference is
# an immediate, unconditional nounset abort of the function — not a mere false test — so a
# later cleanup line never ran. (Verified empirically while building case 5 below: the same
# shape under plain `set -e` alone does NOT abort and does NOT reproduce the leak — nounset
# is the operative mechanism, not errexit; also verified: as of this writing the CURRENT
# test/heimdall-presence-keeper.test.sh no longer contains an E1_HOME/E2_HOME-shaped chain
# at all, so the concrete defect may already be fixed elsewhere — reported, not assumed.)
# That defect is real and is reported separately — it is deliberately NOT fixed here; this
# file only proves the DETECTOR catches the shape it leaves behind.
#
# This suite proves the detector, not the sandbox: it copies the REAL test/run-all.sh (not
# a mock) into a disposable, throwaway git repo — never this repo — drops in a tiny,
# deliberately misbehaving fixture suite, and checks run-all.sh's own exit code and printed
# report. It does NOT attempt to sandbox suites more aggressively; that is out of scope by
# design (see run-all.sh's own "REPO INTEGRITY" comment block).
#
# Usage:  bash test/tree-integrity-guard.test.sh   (exit 0 = every case behaves as proven)
#
# bash 3.2 (macOS system bash) compatible: no timeout(1)/gtimeout — perl's
# `alarm N; exec @ARGV` stands in, same as run-all.sh's own timeout_run(). No associative
# arrays, no mapfile/readarray. Reads are `while IFS= read -r x; do ... done < file`
# (direct redirection), never `cmd | while read`, to avoid the subshell scoping trap.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
REAL_RUNALL="$REPO/test/run-all.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

[ -f "$REAL_RUNALL" ] || { echo "FATAL: $REAL_RUNALL not found" >&2; exit 2; }

PERL_BIN="$(command -v perl || true)"
# run_with_alarm SECS CMD...  — CMD must be a real executable (perl's exec replaces the
# process image; it cannot invoke a shell function).
run_with_alarm() {
  local secs="$1"; shift
  if [ -n "$PERL_BIN" ]; then
    "$PERL_BIN" -e "alarm $secs; exec @ARGV" "$@"
  else
    "$@"
  fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tree-integrity-guard.XXXXXX")"
[ -n "$WORK" ] || { echo "FATAL: WORK path empty (mktemp failed)" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

echo "tree-integrity-guard harness  work=$WORK  real-runall=$REAL_RUNALL"
echo "--------------------------------------------------------------------"

# build_sandbox NAME — a throwaway git repo at $WORK/NAME with a copy of the REAL
# run-all.sh (so this test exercises actual production logic, never a mock), two tracked
# files, and two trivial always-green suites. Prints the sandbox path on stdout.
build_sandbox() {
  local name="$1"
  local sbx="$WORK/$name"
  mkdir -p "$sbx/test"
  ( cd "$sbx" && git init -q . ) >/dev/null 2>&1
  cp "$REAL_RUNALL" "$sbx/test/run-all.sh"
  chmod +x "$sbx/test/run-all.sh"
  printf 'tracked-a\n' > "$sbx/tracked-a.txt"
  printf 'tracked-b\n' > "$sbx/tracked-b.txt"
  cat > "$sbx/test/good-1.test.sh" <<'FIXEOF'
#!/usr/bin/env bash
echo "good-1: 1 passed, 0 failed."
exit 0
FIXEOF
  cat > "$sbx/test/good-2.test.sh" <<'FIXEOF'
#!/usr/bin/env bash
echo "good-2: 1 passed, 0 failed."
exit 0
FIXEOF
  chmod +x "$sbx/test/good-1.test.sh" "$sbx/test/good-2.test.sh"
  ( cd "$sbx" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1
  printf '%s' "$sbx"
}

# commit_all SBX MSG — stage and commit everything currently on disk (used after dropping
# a fixture suite in, so the ONLY drift run-all.sh can see is caused by running it).
commit_all() {
  local sbx="$1" msg="$2"
  ( cd "$sbx" && git add -A && git -c user.email=t@t -c user.name=t commit -qm "$msg" ) >/dev/null 2>&1
}

# run_sandbox SBX OUTFILE — invoke the sandboxed run-all.sh: floor=3 (exactly the suite
# count every case below uses — no vacuous pass), jobs=1 and no-retry (these fixtures are
# about tree state, not concurrency; serial keeps this guard itself fast and deterministic).
# HOME/HEIMDALL_HOME are scoped to a throwaway dir OUTSIDE the sandbox repo (a sibling under
# $WORK, never nested under $sbx) — run-all.sh's own GATE_MARKER lives at
# ${HEIMDALL_HOME:-$HOME/.heimdall}/.gate-in-flight (run-all.sh:279); nesting it INSIDE the
# sandbox repo would create a real untracked "home/" directory in the sandbox's own repo
# ROOT on every single run and make the root-litter check false-positive on EVERY case,
# including the control. Returns run-all.sh's own exit code.
run_sandbox() {
  local sbx="$1" out="$2" home
  home="$(mktemp -d "${TMPDIR:-/tmp}/tig-home.XXXXXX")"
  ( cd "$sbx" && HOME="$home" HEIMDALL_HOME="$home/.heimdall" \
      run_with_alarm 60 bash test/run-all.sh --min 3 --jobs 1 --no-retry ) >"$out" 2>&1
  local rc=$?
  rm -rf "$home"
  return $rc
}

# ════════════════════════════════════════════════════════════════════════════════════════
# 1 — CONTROL: a fully clean run passes, and says so
# ════════════════════════════════════════════════════════════════════════════════════════
echo
echo "1 — control: clean tree, clean run"
SBX1="$(build_sandbox case1)"
cat > "$SBX1/test/good-3.test.sh" <<'FIXEOF'
#!/usr/bin/env bash
echo "good-3: 1 passed, 0 failed."
exit 0
FIXEOF
chmod +x "$SBX1/test/good-3.test.sh"
commit_all "$SBX1" "add good-3"
OUT1="$WORK/case1.out"
run_sandbox "$SBX1" "$OUT1"; RC1=$?
[ "$RC1" -eq 0 ] && ok "control run exits 0 (got $RC1)" || bad "control run should exit 0, got $RC1"
grep -q 'tree-integrity: clean' "$OUT1" && ok "control run reports tree-integrity: clean" \
  || bad "control run did not report tree-integrity: clean"
grep -q 'RUN GREEN' "$OUT1" && ok "control run reports RUN GREEN" \
  || bad "control run did not report RUN GREEN"
grep -q 'TREE INTEGRITY VIOLATION' "$OUT1" \
  && bad "control run falsely raised a TREE INTEGRITY VIOLATION" \
  || ok "control run raised no false TREE INTEGRITY VIOLATION"

# ════════════════════════════════════════════════════════════════════════════════════════
# 2 — MODIFY: a suite that reports itself GREEN but appends to a tracked file must still
# fail the run. This is the important case: the damage is invisible to pass/fail counts.
# ════════════════════════════════════════════════════════════════════════════════════════
echo
echo "2 — a suite that modifies a tracked file (while reporting itself green) fails the run"
SBX2="$(build_sandbox case2)"
cat > "$SBX2/test/bad-modify.test.sh" <<'FIXEOF'
#!/usr/bin/env bash
echo "junk" >> tracked-a.txt
echo "bad-modify: 1 passed, 0 failed."
exit 0
FIXEOF
chmod +x "$SBX2/test/bad-modify.test.sh"
commit_all "$SBX2" "add bad-modify"
OUT2="$WORK/case2.out"
run_sandbox "$SBX2" "$OUT2"; RC2=$?
[ "$RC2" -ne 0 ] && ok "modify-fixture run exits non-zero (got $RC2)" || bad "modify-fixture run should fail, got $RC2"
grep -q 'TREE INTEGRITY VIOLATION' "$OUT2" && ok "modify-fixture run raises TREE INTEGRITY VIOLATION" \
  || bad "modify-fixture run did not raise TREE INTEGRITY VIOLATION"
grep -q 'tracked-a.txt' "$OUT2" && ok "modify-fixture run NAMES tracked-a.txt" \
  || bad "modify-fixture run did not name tracked-a.txt"
grep -q 'tree-integrity: VIOLATED' "$OUT2" && ok "modify-fixture run's summary line says VIOLATED" \
  || bad "modify-fixture run's summary line did not say VIOLATED"

# ════════════════════════════════════════════════════════════════════════════════════════
# 3 — TYPECHANGE: a tracked file replaced by a dangling symlink — the exact shape (bin/hmd)
# that hid for hours in the real incident, surfacing only as a easy-to-miss ` T `.
# ════════════════════════════════════════════════════════════════════════════════════════
echo
echo "3 — a suite that replaces a tracked file with a dangling symlink fails the run"
SBX3="$(build_sandbox case3)"
cat > "$SBX3/test/bad-typechange.test.sh" <<'FIXEOF'
#!/usr/bin/env bash
rm -f tracked-b.txt
ln -s /nonexistent/dangling/target tracked-b.txt
echo "bad-typechange: 1 passed, 0 failed."
exit 0
FIXEOF
chmod +x "$SBX3/test/bad-typechange.test.sh"
commit_all "$SBX3" "add bad-typechange"
OUT3="$WORK/case3.out"
run_sandbox "$SBX3" "$OUT3"; RC3=$?
[ "$RC3" -ne 0 ] && ok "typechange-fixture run exits non-zero (got $RC3)" || bad "typechange-fixture run should fail, got $RC3"
grep -q 'TREE INTEGRITY VIOLATION' "$OUT3" && ok "typechange-fixture run raises TREE INTEGRITY VIOLATION" \
  || bad "typechange-fixture run did not raise TREE INTEGRITY VIOLATION"
grep -q 'tracked-b.txt' "$OUT3" && ok "typechange-fixture run NAMES tracked-b.txt" \
  || bad "typechange-fixture run did not name tracked-b.txt"

# ════════════════════════════════════════════════════════════════════════════════════════
# 4 — DELETE: a tracked file removed outright.
# ════════════════════════════════════════════════════════════════════════════════════════
echo
echo "4 — a suite that deletes a tracked file fails the run"
SBX4="$(build_sandbox case4)"
cat > "$SBX4/test/bad-delete.test.sh" <<'FIXEOF'
#!/usr/bin/env bash
rm -f tracked-a.txt
echo "bad-delete: 1 passed, 0 failed."
exit 0
FIXEOF
chmod +x "$SBX4/test/bad-delete.test.sh"
commit_all "$SBX4" "add bad-delete"
OUT4="$WORK/case4.out"
run_sandbox "$SBX4" "$OUT4"; RC4=$?
[ "$RC4" -ne 0 ] && ok "delete-fixture run exits non-zero (got $RC4)" || bad "delete-fixture run should fail, got $RC4"
grep -q 'TREE INTEGRITY VIOLATION' "$OUT4" && ok "delete-fixture run raises TREE INTEGRITY VIOLATION" \
  || bad "delete-fixture run did not raise TREE INTEGRITY VIOLATION"
grep -q 'tracked-a.txt' "$OUT4" && ok "delete-fixture run NAMES tracked-a.txt" \
  || bad "delete-fixture run did not name tracked-a.txt"

# ════════════════════════════════════════════════════════════════════════════════════════
# 5 — ROOT LITTER: the real 2026-08-23 incident shape. A suite with a REALISTIC buggy
# cleanup trap — matching this codebase's own dominant convention, `set -uo pipefail`
# (test/heimdall-presence-keeper.test.sh:35, test/run-all.sh) rather than errexit — where a
# guarded-removal chain (`[ -n "$E1_HOME" ] && rm -rf "$E1_HOME"`) references a guard
# variable that is genuinely never assigned anywhere. Under plain `set -e` alone this is
# just a false test and nothing aborts (verified empirically: it does NOT reproduce the
# leak — see below). Under `set -u`, referencing that truly-unset variable is an immediate,
# unconditional "unbound variable" abort of the function, regardless of AND/OR short-
# circuiting, so the LATER `E2_HOME` cleanup line never runs. The suite fails EARLY (exit 1)
# and leaks an untracked directory into the repo ROOT. This must trip the guard EVEN THOUGH
# (in fact, BECAUSE) the leak correlates with the suite's own failure — the check must never
# be gated on "only look if otherwise green". The leaked directory also needs a real file
# inside it: `git status` never reports a wholly empty untracked directory at all (verified
# empirically), so the fixture writes one, matching a real keeper leaving real state behind.
# ════════════════════════════════════════════════════════════════════════════════════════
echo
echo "5 — a suite whose cleanup trap's nounset guard-variable reference aborts early, leaking a dir into the repo root, fails the run"
SBX5="$(build_sandbox case5)"
cat > "$SBX5/test/bad-root-litter.test.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
cleanup() {
  [ -n "$E1_HOME" ] && rm -rf "$E1_HOME"
  [ -n "$E2_HOME" ] && rm -rf "$E2_HOME"
}
trap cleanup EXIT
REPO_ROOT="$(pwd)"
E2_HOME="$REPO_ROOT/.hmd-test-fixture-keeper-e2.$$"
mkdir -p "$E2_HOME/.heimdall"
echo "state=fake" > "$E2_HOME/.heimdall/config"
echo "bad-root-litter: 0 passed, 1 failed."
exit 1
FIXEOF
chmod +x "$SBX5/test/bad-root-litter.test.sh"
commit_all "$SBX5" "add bad-root-litter"
OUT5="$WORK/case5.out"
run_sandbox "$SBX5" "$OUT5"; RC5=$?
[ "$RC5" -ne 0 ] && ok "root-litter-fixture run exits non-zero (got $RC5)" || bad "root-litter-fixture run should fail, got $RC5"
grep -q 'TREE INTEGRITY VIOLATION' "$OUT5" && ok "root-litter-fixture run raises TREE INTEGRITY VIOLATION" \
  || bad "root-litter-fixture run did not raise TREE INTEGRITY VIOLATION"
grep -q 'hmd-test-fixture-keeper-e2' "$OUT5" && ok "root-litter-fixture run NAMES the leaked directory" \
  || bad "root-litter-fixture run did not name the leaked directory"
grep -q 'repo ROOT' "$OUT5" && ok "root-litter-fixture run labels it a root-litter finding" \
  || bad "root-litter-fixture run did not label it as root litter"
LEFTOVER5="$(find "$SBX5" -maxdepth 1 -type d -name '.hmd-test-fixture-keeper-e2.*' 2>/dev/null | head -1)"
[ -n "$LEFTOVER5" ] \
  && ok "sanity: the fixture really did leak the directory on disk (the bug is real, not assumed)" \
  || bad "sanity: expected the fixture's leaked directory to still be sitting in $SBX5"

# ════════════════════════════════════════════════════════════════════════════════════════
# 6 — ADD THE FIXTURE, WATCH IT FAIL; REMOVE IT, WATCH IT PASS (acceptance criterion,
# proven as one explicit before/after pair in a single sandbox, same suite count both times)
# ════════════════════════════════════════════════════════════════════════════════════════
echo
echo "6 — add the fixture and watch it fail, then remove it and watch it pass"
SBX6="$(build_sandbox case6)"
cat > "$SBX6/test/toggle.test.sh" <<'FIXEOF'
#!/usr/bin/env bash
echo "junk" >> tracked-a.txt
echo "toggle: 1 passed, 0 failed."
exit 0
FIXEOF
chmod +x "$SBX6/test/toggle.test.sh"
commit_all "$SBX6" "add misbehaving toggle fixture"
OUT6A="$WORK/case6-before.out"
run_sandbox "$SBX6" "$OUT6A"; RC6A=$?
if [ "$RC6A" -ne 0 ] && grep -q 'tracked-a.txt' "$OUT6A"; then
  ok "6a: WITH the fixture present, the run FAILS and names tracked-a.txt (rc=$RC6A)"
else
  bad "6a: WITH the fixture present, expected a failing run naming tracked-a.txt (rc=$RC6A)"
fi

cat > "$SBX6/test/toggle.test.sh" <<'FIXEOF'
#!/usr/bin/env bash
echo "toggle: 1 passed, 0 failed."
exit 0
FIXEOF
commit_all "$SBX6" "fix the toggle fixture"
OUT6B="$WORK/case6-after.out"
run_sandbox "$SBX6" "$OUT6B"; RC6B=$?
if [ "$RC6B" -eq 0 ] && grep -q 'RUN GREEN' "$OUT6B"; then
  ok "6b: WITHOUT the misbehavior, the SAME sandbox now PASSES (rc=$RC6B)"
else
  bad "6b: WITHOUT the misbehavior, expected RUN GREEN (rc=$RC6B)"
fi

# ════════════════════════════════════════════════════════════════════════════════════════
# 7 — sanity bound: this whole guard (7 sandboxed sub-runs of a 3-suite runner) should be
# fast. Not a precision perf assertion (that would be flaky) — just a hang/regression net.
# ════════════════════════════════════════════════════════════════════════════════════════
echo
echo "7 — sanity: sandboxed sub-runs stay fast (loose bound, not a precision timing test)"
echo "  (implicit — this whole file already ran under the 60s per-sandbox alarm seven times)"
ok "no sandboxed run hit its 60s alarm (would have shown up as a failure above already)"

echo
echo "--------------------------------------------------------------------"
printf 'tree-integrity-guard: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
