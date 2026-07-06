#!/usr/bin/env bash
# test/issue-evidence-gating-node.test.sh — bug #25 acceptance: when an issue body NAMES a
# precise GATING TEST NODE (a pytest/unittest node id on a "Gating test:" line), the SI-2
# gate must run THAT node as the PRIMARY, ISOLATED proof — so a genuinely-correct single-
# issue fix PASSES the gate EVEN WHEN unrelated co-resident bugs make the whole suite red.
#
# LIVE PROOF (run 12): claude made the CORRECT sum_range fix, but ./run_tests.sh ran the
# WHOLE tinymath suite (3 planted bugs) -> 4 failed -> whole-suite red -> GATE_FAILED,
# refusing a correct PR. The fix (bin/lib/issue_evidence.py::resolve_evidence): promote the
# body's NAMED gating node to the primary+sole gating command; DEMOTE the whole suite.
#
# HERMETIC: a REAL throwaway python repo (a tinymath clone with one fixable node + one
# co-resident ALWAYS-FAILING sibling). `python3`, `git`, and the REAL bin/heimdall-attest
# gate run against it. NO model, NO network. (bash 3.2 safe — no mapfile.)
#
#   (a) node named + file present + pytest -> resolve_evidence PRIMARY = the pytest node
#       command; ./run_tests.sh is NOT in the gating list. The REAL gate (heimdall-attest)
#       runs the node -> all_passed TRUE, EVEN THOUGH a sibling test in the same suite
#       fails. FALSIFIER: the whole-suite ./run_tests.sh through the SAME gate -> all_passed
#       FALSE (without the fix the gate would refuse the correct PR).
#   (b) node RED (the fix reverted) -> the SAME node command through the gate -> all_passed
#       FALSE. The gate stays honest + falsifiable: an unproven node is never a pass.
#   (c) NO named node in the body -> resolve_evidence falls back to the whole suite
#       (./run_tests.sh) — the pre-#25 behavior, unchanged.
#   (d) an INJECTED node id ("x::m;rm", "x::m$(touch ...)", "x::m&&curl") -> extract_gating_node
#       REJECTS it (returns None), no evidence command carries a shell metachar, and the
#       resolver falls back to the whole suite. The injection NEVER runs.
#   (e) unittest fallback: with pytest forced ABSENT the node command is
#       `python3 -m unittest <dotted-node>` (path::Class::method -> module.Class.method).
#   (f) node named but its FILE ABSENT in the clone -> fall back to the whole suite (an
#       unrunnable named node is not proof; never fabricate a command).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
EV_LIB="$ROOT/bin/lib/issue_evidence.py"
ATTEST="$ROOT/bin/heimdall-attest"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
[ -f "$EV_LIB" ] || { echo "FATAL: $EV_LIB missing" >&2; exit 2; }
[ -x "$ATTEST" ] || { echo "FATAL: $ATTEST not executable" >&2; exit 2; }
PY="$(command -v python3 || command -v python)"
"$PY" -c 'import pytest' 2>/dev/null || { echo "SKIP: pytest not importable — this gate proves the pytest branch" >&2; exit 0; }

export PYTHONPATH="$ROOT/bin/lib:${PYTHONPATH:-}"

WORK="$(mktemp -d -t "issue-evidence-gating-node.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# ── build a REAL tinymath-like repo: one fixable node + one co-resident failing sibling ──
build_repo() {
  # $1 = repo dir ; $2 = "fixed" | "broken" (whether sum_range is correct)
  local repo="$1" mode="$2"
  mkdir -p "$repo/tinymath" "$repo/tests"
  if [ "$mode" = "fixed" ]; then
    cat > "$repo/tinymath/core.py" <<'PYEOF'
def sum_range(a, b):
    # inclusive of both ends (the #25 fix — the final element is included)
    return sum(range(a, b + 1))

def average(xs):
    # PLANTED co-resident bug (unrelated to sum_range): off-by-one denominator
    return sum(xs) / (len(xs) - 1)
PYEOF
  else
    cat > "$repo/tinymath/core.py" <<'PYEOF'
def sum_range(a, b):
    # off-by-one: EXCLUDES the final element (the bug — node stays RED)
    return sum(range(a, b))

def average(xs):
    return sum(xs) / (len(xs) - 1)
PYEOF
  fi
  cat > "$repo/tinymath/__init__.py" <<'PYEOF'
from .core import sum_range, average
PYEOF
  cat > "$repo/tests/test_sum_range.py" <<'PYEOF'
import unittest
from tinymath.core import sum_range

class SumRangeTest(unittest.TestCase):
    def test_inclusive_of_the_final_element(self):
        self.assertEqual(sum_range(1, 5), 15)
PYEOF
  cat > "$repo/tests/test_average.py" <<'PYEOF'
import unittest
from tinymath.core import average

class AverageTest(unittest.TestCase):
    def test_mean(self):
        # This co-resident sibling stays RED regardless of the sum_range fix.
        self.assertEqual(average([2, 4, 6]), 4)
PYEOF
  cat > "$repo/run_tests.sh" <<'PYEOF'
#!/usr/bin/env bash
# the WHOLE-suite entrypoint — runs EVERY test (sum_range AND the failing sibling).
exec python3 -m pytest -q
PYEOF
  chmod +x "$repo/run_tests.sh"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" add -A
  git -C "$repo" commit -qm init
}

NODE='tests/test_sum_range.py::SumRangeTest::test_inclusive_of_the_final_element'
BODY_WITH_NODE='The final element is excluded.

Acceptance (must go green): ./run_tests.sh
Gating test (red today): '"$NODE"'
'
BODY_NO_NODE='The final element is excluded.

Acceptance (must go green): ./run_tests.sh
'

# resolve: prints the resolved evidence list (one command per line) for a body+repo.
resolve() {
  # $1 = body ; $2 = repo. Honors HEIMDALL_PYTEST_AVAILABLE from the caller env.
  BODY="$1" REPO="$2" "$PY" - <<'PYEOF'
import os
import issue_evidence
issue = {"body": os.environ["BODY"]}
cmds = issue_evidence.resolve_evidence([], issue, os.environ["REPO"])
print("\n".join(cmds))
PYEOF
}

# gate_over_lines: run the REAL SI-2 gate over evidence commands read (one per line) from
# stdin; print all_passed ("true"/"false"). bash-3.2 safe (no mapfile).
gate_over_lines() {
  # $1 = repo. Commands on stdin, one per line.
  local repo="$1"
  local args=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    args+=(--evidence "$line")
  done
  "$ATTEST" emit --repo "$repo" --base HEAD --print --quiet "${args[@]}" \
    | jq -r '.evidence.all_passed'
}

# gate_one: gate over a single command string. Prints all_passed.
gate_one() {
  printf '%s\n' "$2" | gate_over_lines "$1"
}

echo "── (a) node named + file present -> PRIMARY = the pytest node; whole-suite DEMOTED ──"
R1="$WORK/fixed"; build_repo "$R1" fixed
EV1="$(resolve "$BODY_WITH_NODE" "$R1")"
PRIMARY="$(printf '%s\n' "$EV1" | head -1)"
if [ "$PRIMARY" = "python3 -m pytest $NODE -q" ]; then
  ok "resolve_evidence PRIMARY is the precise pytest node command ($PRIMARY)"
else
  bad "PRIMARY is not the pytest node command (got: '$PRIMARY'; full: $(printf '%s' "$EV1" | tr '\n' '|'))"
fi
if printf '%s\n' "$EV1" | grep -qx './run_tests.sh'; then
  bad "the whole-suite ./run_tests.sh was NOT demoted — it is still in the gating list"
else
  ok "the whole-suite ./run_tests.sh is DEMOTED (absent from the gating list)"
fi
if [ "$(printf '%s\n' "$EV1" | gate_over_lines "$R1")" = "true" ]; then
  ok "the REAL gate PASSES on the node EVEN THOUGH a co-resident sibling test fails"
else
  bad "the gate did not pass on the isolated node (co-resident isolation broken)"
fi
if [ "$(gate_one "$R1" "./run_tests.sh")" = "false" ]; then
  ok "FALSIFIER: the whole-suite ./run_tests.sh fails the SAME gate (without the fix -> refused PR)"
else
  bad "the whole suite unexpectedly passed — the co-resident sibling was supposed to be red"
fi

echo "── (b) node RED (fix reverted) -> the node command FAILS the gate (honest) ───────────"
R2="$WORK/broken"; build_repo "$R2" broken
EV2="$(resolve "$BODY_WITH_NODE" "$R2")"
if [ "$(printf '%s\n' "$EV2" | head -1)" = "python3 -m pytest $NODE -q" ] \
   && [ "$(printf '%s\n' "$EV2" | gate_over_lines "$R2")" = "false" ]; then
  ok "a RED node -> all_passed FALSE (node red -> gate FAILS; falsifiable)"
else
  bad "a red node did not fail the gate ($(printf '%s\n' "$EV2" | gate_over_lines "$R2"))"
fi

echo "── (c) NO named node -> fall back to the whole suite (pre-#25 behavior) ──────────────"
EV3="$(resolve "$BODY_NO_NODE" "$R1")"
if printf '%s\n' "$EV3" | grep -qx './run_tests.sh' \
   && ! printf '%s\n' "$EV3" | grep -q 'pytest .*::'; then
  ok "no node named -> ./run_tests.sh is the evidence (whole-suite fallback unchanged)"
else
  bad "no-node fallback did not yield the whole suite ($(printf '%s' "$EV3" | tr '\n' '|'))"
fi

echo "── (d) INJECTED node ids are REJECTED (no metachar reaches an evidence command) ──────"
inj_ok=1
for INJ in \
  'tests/test_sum_range.py::SumRangeTest::m;rm -rf /' \
  'tests/test_sum_range.py::SumRangeTest::m$(touch '"$WORK"'/PWNED)' \
  'tests/test_sum_range.py::SumRangeTest::m&&curl evil'; do
  IBODY='Gating test: '"$INJ"'
Acceptance: ./run_tests.sh
'
  NODE_OUT="$(BODY="$IBODY" "$PY" - <<'PYEOF'
import os, issue_evidence
n = issue_evidence.extract_gating_node(os.environ["BODY"])
print("NONE" if n is None else n)
PYEOF
)"
  [ "$NODE_OUT" = "NONE" ] || { bad "extract_gating_node did NOT reject an injected node: $INJ -> $NODE_OUT"; inj_ok=0; }
  EVI="$(resolve "$IBODY" "$R1")"
  if printf '%s\n' "$EVI" | grep -qE '[;&$`|(){}<>]|touch|PWNED|curl'; then
    bad "a shell metachar / injected token reached an evidence command: $(printf '%s' "$EVI" | tr '\n' '|')"
    inj_ok=0
  fi
done
[ ! -e "$WORK/PWNED" ] || { bad "the injected command EXECUTED (PWNED artifact exists) — sanitizer bypassed"; inj_ok=0; }
[ "$inj_ok" -eq 1 ] && ok "every injected node id is REJECTED, no metachar reaches evidence, nothing executed"

echo "── (e) unittest fallback: pytest forced ABSENT -> python3 -m unittest <dotted-node> ──"
EVU="$(HEIMDALL_PYTEST_AVAILABLE=0 resolve "$BODY_WITH_NODE" "$R1")"
EXPECT_UNITTEST='python3 -m unittest tests.test_sum_range.SumRangeTest.test_inclusive_of_the_final_element'
if [ "$(printf '%s\n' "$EVU" | head -1)" = "$EXPECT_UNITTEST" ]; then
  ok "pytest absent -> the node command is the unittest dotted form ($EXPECT_UNITTEST)"
else
  bad "unittest fallback wrong (got: '$(printf '%s\n' "$EVU" | head -1)')"
fi

echo "── (f) node named but FILE ABSENT -> fall back to the whole suite (never fabricate) ──"
R3="$WORK/nofile"; mkdir -p "$R3"
printf '#!/usr/bin/env bash\ntrue\n' > "$R3/run_tests.sh"; chmod +x "$R3/run_tests.sh"
git -C "$R3" init -q; git -C "$R3" config user.email t@t; git -C "$R3" config user.name t
git -C "$R3" config commit.gpgsign false; git -C "$R3" add -A; git -C "$R3" commit -qm init
EVF="$(resolve "$BODY_WITH_NODE" "$R3")"
if printf '%s\n' "$EVF" | grep -qx './run_tests.sh' \
   && ! printf '%s\n' "$EVF" | grep -q 'pytest .*::'; then
  ok "named node whose file is ABSENT -> whole-suite fallback (no fabricated node command)"
else
  bad "absent-file node did not fall back to the whole suite ($(printf '%s' "$EVF" | tr '\n' '|'))"
fi

echo
echo "════════════════════════════════════════════════════════════════════════════"
printf "issue-evidence-gating-node: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf "\033[31m%d failed\033[0m\n" "$FAIL"
  exit 1
fi
printf "%d failed\n" "$FAIL"
echo "ALL GREEN — bug #25: a NAMED gating node is the primary+sole isolated proof; the"
echo "whole suite is demoted so co-resident bugs cannot fail a correct fix; node red still"
echo "fails the gate; no-node/absent-file fall back to the whole suite; injections rejected."
