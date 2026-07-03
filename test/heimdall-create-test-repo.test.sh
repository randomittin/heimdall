#!/usr/bin/env bash
# create-maintainer-test-repo.sh guard: --dry-run needs NO gh + prints the full scaffold plan
# (repo + 3 issues + the 3 gating tests) and makes ZERO side effects; bad args rejected; and the
# planted bugs ↔ gating tests ↔ issues form a 3↔3↔3 triad in the script's templates.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/deploy/cloud-run/create-maintainer-test-repo.sh"
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS %s\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL %s\n' "$1"; }
[ -x "$S" ] || { echo "FATAL: $S not executable"; exit 2; }
bash -n "$S" || { echo "FATAL syntax"; exit 2; }

# A sandbox PATH whose `gh` is a TRAP: it records any invocation to a sentinel file and fails.
# If --dry-run touches gh at all, the sentinel appears → the "needs no gh / zero side effects"
# assertions fail. Proves the dry-run plan is pure.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SENT="$TMP/gh-was-called"
mkdir -p "$TMP/bin"
{ printf '#!/usr/bin/env bash\n'; printf 'echo "gh %s" >> "%s"\n' '$*' "$SENT"; printf 'exit 42\n'; } > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"

# 1. dry-run, default repo → exit 0, gh NEVER invoked, no side effects
OUT="$(PATH="$TMP/bin:$PATH" bash "$S" --dry-run 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "dry-run exit 0" || bad "dry-run rc=$rc"
[ ! -e "$SENT" ] && ok "dry-run never invokes gh (needs no gh)" || bad "dry-run called gh: $(cat "$SENT" 2>/dev/null)"
printf '%s' "$OUT" | grep -q 'heimdall-maintainer-test' && ok "dry-run prints the repo name" || bad "no repo name in plan"
printf '%s' "$OUT" | grep -qi 'nothing executed\|zero side effect\|dry-run' && ok "dry-run marks itself (nothing executed)" || bad "no dry-run marker"

# 2. dry-run prints the 3 planted ISSUES (title text) + the 3 gating TESTS + the next command
for t in sum_range average clamp; do
  printf '%s' "$OUT" | grep -q "$t" && ok "plan mentions bug/test '$t'" || bad "plan missing '$t'"
done
printf '%s' "$OUT" | grep -q 'tests/test_sum_range.py' && ok "plan lists test_sum_range.py" || bad "no test_sum_range.py in plan"
printf '%s' "$OUT" | grep -q 'tests/test_average.py'   && ok "plan lists test_average.py"   || bad "no test_average.py in plan"
printf '%s' "$OUT" | grep -q 'tests/test_clamp.py'     && ok "plan lists test_clamp.py"     || bad "no test_clamp.py in plan"
c=$(printf '%s\n' "$OUT" | grep -c 'ISSUE ')
[ "$c" -ge 3 ] && ok "plan enumerates >=3 issues ($c)" || bad "plan lists $c issues (<3)"
printf '%s' "$OUT" | grep -q 'deploy-maintainer.sh --local --repo' && ok "plan prints the exact next command" || bad "no next-command in plan"
printf '%s' "$OUT" | grep -qi 'heimdall/.*branch\|human merges\|RJ merges' && ok "plan notes heimdall/* branches + human merges" || bad "no branch/merge note"

# 3. THE TRIAD — grep the SCRIPT: 3 buggy fns ↔ 3 failing tests ↔ 3 issues, each REAL.
for fn in 'def sum_range' 'def average' 'def clamp'; do
  grep -q "$fn" "$S" && ok "buggy fn present in template: $fn" || bad "no buggy fn: $fn"
done
# each gating test carries a REAL failing assertion (not a trivial 'assert True')
grep -q 'sum_range(1, 5), 15' "$S" && ok "test_sum_range pins the off-by-one (==15)" || bad "sum_range assertion missing"
grep -q 'average(\[\]), 0'    "$S" && ok "test_average pins the empty guard (==0)"    || bad "average assertion missing"
grep -q 'clamp(15, 0, 10), 10' "$S" && ok "test_clamp pins the upper bound (==10)"    || bad "clamp assertion missing"
grep -q 'assert True' "$S" && bad "template contains a trivial 'assert True' gate" || ok "no trivial assert-true gate"
# 3 issue-title anchors in the script
grep -q 'sum_range drops' "$S" && ok "issue 1 title present (off-by-one)" || bad "issue 1 title missing"
grep -q 'average(\[\]) raises' "$S" && ok "issue 2 title present (empty guard)" || bad "issue 2 title missing"
grep -q 'clamp does not enforce' "$S" && ok "issue 3 title present (upper bound)" || bad "issue 3 title missing"
# the gate is a REAL runner shipped to the sandbox
grep -q 'run_tests.sh' "$S" && ok "ships a real test runner (run_tests.sh)" || bad "no test runner"
grep -q 'gh issue create' "$S" && ok "files issues via gh issue create" || bad "no gh issue create"
grep -q 'gh repo create' "$S" && ok "creates repo via gh repo create" || bad "no gh repo create"

# 4. idempotency + safety guards present in the source
grep -q 'set -euo pipefail' "$S" && ok "set -euo pipefail" || bad "missing strict mode"
grep -qi 'exists\|repo view' "$S" && ok "repo-create is guarded (idempotent)" || bad "repo-create not guarded"
grep -qi 'issue list' "$S" && ok "issue-create is guarded (idempotent)" || bad "issue-create not guarded"

# 5. bad args rejected
PATH="$TMP/bin:$PATH" bash "$S" --dry-run --frobnicate 2>/dev/null; [ $? -ne 0 ] && ok "unknown flag rejected" || bad "unknown flag accepted"

echo "──────────"; echo "create-maintainer-test-repo: $P passed, $F failed"
[ "$F" = 0 ] || exit 1
