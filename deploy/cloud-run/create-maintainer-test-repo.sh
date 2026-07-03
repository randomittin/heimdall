#!/usr/bin/env bash
# create-maintainer-test-repo.sh — scaffold a SAFE, THROWAWAY sandbox repo for the FIRST live
# maintainer run. RUN BY THE OPERATOR (RJ) on his own machine with HIS gh creds. The agent never
# runs this.
#
# WHY a sandbox: the maintainer is an unproven autonomous PR-bot. Its first live run must NOT
# target a real/important repo. This creates a TINY but REAL private project whose test suite runs
# locally + in CI, then plants 3 EASY, REAL, TEST-GATED bugs — each with (a) a failing test that
# pins the bug and (b) a matching GitHub issue. The maintainer picks an issue → fixes it → the
# deterministic GATE re-runs the tests → a PR opens ONLY when the fix makes the failing test GREEN
# (attestation reads the recorded real exit — never an agent "done" claim). RJ watches the loop
# end-to-end and merges the heimdall/* PRs by hand. Nothing autonomous touches a real codebase.
#
# Stack: a stdlib-only Python package + unittest suite (the maintainer image already carries
# python3; unittest needs NO pip install, so the gate runs anywhere). run_tests.sh prefers pytest
# when present and falls back to `python3 -m unittest` — the tests are written to pass under both.
#
# Usage:
#   create-maintainer-test-repo.sh [--name <repo>] [--dry-run]
#   --name    the sandbox repo name (default: heimdall-maintainer-test)
#   --dry-run print the FULL plan (every file it would write + every issue it would file) and the
#             exact next command, executing NOTHING and needing NO gh/network.
#
# Idempotent: re-running is safe — the repo is created only if absent (guarded by `gh repo view`),
# the scaffold is pushed only when content actually changed, and each issue is created only if an
# issue with the same title does not already exist (guarded by `gh issue list`).
set -euo pipefail

NAME="heimdall-maintainer-test"; DRY=0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do case "$1" in
  --name) NAME="${2:?}"; shift 2 ;;
  --dry-run) DRY=1; shift ;;
  -h|--help) usage; exit 0 ;;
  *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
esac; done

printf '%s' "$NAME" | grep -qE '^[A-Za-z0-9_.-]+$' || { echo "--name must be a bare repo name (got: $NAME)" >&2; exit 2; }

say()  { printf '\033[36m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
# run: in --dry-run print the command (no secrets are ever in argv), else execute.
run()  { if [ "$DRY" = 1 ]; then printf '  \033[90m$ %s\033[0m\n' "$*"; else "$@"; fi; }

# ── the sandbox project's files (real library + real, failing-then-passing tests) ─────────────
# Each writer emits ONE file into $1 (the repo dir). The heredocs are quoted ('EOF') so nothing
# expands — the content ships verbatim to the throwaway repo. The planted bugs live ONLY here (in
# these templates that ship OUT to the sandbox), NEVER in the heimdall repo.

write_license() { cat > "$1/LICENSE" <<'EOF'
MIT License

Copyright (c) 2026 Heimdall maintainer sandbox

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
}

write_readme() { cat > "$1/README.md" <<'EOF'
# heimdall-maintainer-test

A tiny, **throwaway** sandbox for Heimdall's autonomous maintainer. It is a real Python
package (`tinymath`) with a real test suite — and three **planted, test-gated bugs**.

Each bug ships with:
- a failing test that pins it (red today), and
- a GitHub issue describing it (labelled `maintainer` + `bug`).

The maintainer picks an issue, fixes the code, and its deterministic gate re-runs the tests.
A pull request opens **only** when the fix turns the failing test green — the gate reads the
recorded real exit code, never a self-reported "done". PRs land on `heimdall/*` branches; a
human reviews and merges. The maintainer never pushes `main` and never self-merges.

## Run the tests

```sh
./run_tests.sh
```

Three tests are red until each planted bug is fixed:

| test                       | function          | bug                                   |
|----------------------------|-------------------|---------------------------------------|
| `tests/test_sum_range.py`  | `sum_range`       | off-by-one drops the final element    |
| `tests/test_average.py`    | `average`         | no empty guard → `ZeroDivisionError`  |
| `tests/test_clamp.py`      | `clamp`           | upper bound never enforced            |
EOF
}

write_runner() { cat > "$1/run_tests.sh" <<'EOF'
#!/usr/bin/env bash
# The gate/test runner for the sandbox. Prefers pytest when installed; otherwise falls back to the
# stdlib unittest runner (always available with python3 — no pip install needed). Exits non-zero if
# any test fails, so an attestation over this command records an HONEST red/green.
set -euo pipefail
cd "$(dirname "$0")"
if python3 -c 'import pytest' >/dev/null 2>&1; then
  exec python3 -m pytest -q
fi
exec python3 -m unittest discover -s tests -p 'test_*.py' -v
EOF
chmod +x "$1/run_tests.sh"
}

write_ci() { mkdir -p "$1/.github/workflows"; cat > "$1/.github/workflows/tests.yml" <<'EOF'
name: tests
on:
  push:
  pull_request:
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.x'
      - name: run the suite
        run: ./run_tests.sh
EOF
}

write_pkg_init() { mkdir -p "$1/tinymath"; cat > "$1/tinymath/__init__.py" <<'EOF'
"""tinymath — a tiny sandbox library with three planted, test-gated bugs."""
from .core import sum_range, average, clamp

__all__ = ["sum_range", "average", "clamp"]
EOF
}

# ── the buggy library. Three small, unambiguous defects; each fix is a few lines. ─────────────
write_pkg_core() { cat > "$1/tinymath/core.py" <<'EOF'
"""Three tiny functions, each carrying ONE planted, test-gated bug.

Fixing each bug is a few-line change that turns its failing test green — which is exactly what
the maintainer's gate attests before a PR is allowed to open.
"""


def sum_range(start, stop):
    """Return the sum of the integers from ``start`` to ``stop`` INCLUSIVE.

    BUG (off-by-one): ``range(start, stop)`` excludes ``stop``, so the final element is dropped.
    ``sum_range(1, 5)`` returns 10 (1+2+3+4) instead of 15 (1+2+3+4+5).
    FIX: iterate ``range(start, stop + 1)``.
    """
    total = 0
    for n in range(start, stop):
        total += n
    return total


def average(nums):
    """Return the arithmetic mean of ``nums``; an empty sequence averages to 0.

    BUG (missing empty guard): ``len(nums)`` is 0 for an empty sequence, so this raises
    ``ZeroDivisionError`` instead of returning 0.
    FIX: return 0 when ``nums`` is empty, else the mean.
    """
    return sum(nums) / len(nums)


def clamp(value, low, high):
    """Clamp ``value`` into the inclusive range [``low``, ``high``].

    BUG (wrong return in the over-high edge case): the upper bound is never enforced, so a value
    above ``high`` is returned unchanged. ``clamp(15, 0, 10)`` returns 15 instead of 10.
    FIX: return ``high`` when ``value > high``.
    """
    if value < low:
        return low
    return value
EOF
}

# ── the three gating tests. Each is RED until its bug is fixed. Written with unittest.TestCase so
# they run under BOTH `python3 -m unittest` and pytest. NO trivial always-green assertions. ────
write_test_sum_range() { mkdir -p "$1/tests"; cat > "$1/tests/test_sum_range.py" <<'EOF'
import unittest

from tinymath import sum_range


class SumRangeTest(unittest.TestCase):
    def test_inclusive_of_the_final_element(self):
        # 1+2+3+4+5 == 15. RED while sum_range excludes `stop` (off-by-one) → returns 10.
        self.assertEqual(sum_range(1, 5), 15)

    def test_single_value_range(self):
        self.assertEqual(sum_range(4, 4), 4)


if __name__ == "__main__":
    unittest.main()
EOF
}

write_test_average() { mkdir -p "$1/tests"; cat > "$1/tests/test_average.py" <<'EOF'
import unittest

from tinymath import average


class AverageTest(unittest.TestCase):
    def test_empty_sequence_is_zero(self):
        # RED while average() has no empty guard → raises ZeroDivisionError instead of 0.
        self.assertEqual(average([]), 0)

    def test_non_empty_mean(self):
        self.assertEqual(average([2, 4, 6]), 4)


if __name__ == "__main__":
    unittest.main()
EOF
}

write_test_clamp() { mkdir -p "$1/tests"; cat > "$1/tests/test_clamp.py" <<'EOF'
import unittest

from tinymath import clamp


class ClampTest(unittest.TestCase):
    def test_clamps_to_the_upper_bound(self):
        # RED while clamp() never enforces `high` → returns 15 instead of 10.
        self.assertEqual(clamp(15, 0, 10), 10)

    def test_clamps_to_the_lower_bound(self):
        self.assertEqual(clamp(-3, 0, 10), 0)

    def test_value_within_range_is_unchanged(self):
        self.assertEqual(clamp(7, 0, 10), 7)


if __name__ == "__main__":
    unittest.main()
EOF
}

write_files() {
  local d="$1"
  write_license "$d"; write_readme "$d"; write_runner "$d"; write_ci "$d"
  write_pkg_init "$d"; write_pkg_core "$d"
  write_test_sum_range "$d"; write_test_average "$d"; write_test_clamp "$d"
}

# ── the three planted issues (title + body). Parallel arrays, one entry per bug. Each body names
# the exact gating test + acceptance command so the maintainer (and a human) can see the proof. ─
ISSUE_TITLES=(
  "sum_range drops the final element (off-by-one)"
  "average([]) raises ZeroDivisionError (missing empty guard)"
  "clamp does not enforce the upper bound"
)
ISSUE_GATES=(
  "tests/test_sum_range.py"
  "tests/test_average.py"
  "tests/test_clamp.py"
)
issue_body() { # $1 = index
  case "$1" in
  0) cat <<'EOF'
`tinymath.sum_range(start, stop)` is documented to sum the integers from `start` to `stop`
**inclusive**, but it iterates `range(start, stop)` and so drops the final element.

- Expected: `sum_range(1, 5) == 15`  (1+2+3+4+5)
- Actual:   `sum_range(1, 5) == 10`  (1+2+3+4)

Gating test (red today): `tests/test_sum_range.py::SumRangeTest::test_inclusive_of_the_final_element`

Acceptance (must go green): `./run_tests.sh`
EOF
  ;;
  1) cat <<'EOF'
`tinymath.average(nums)` divides by `len(nums)` with no guard, so an empty sequence raises
`ZeroDivisionError`. An empty sequence should average to 0.

- Expected: `average([]) == 0`
- Actual:   `ZeroDivisionError: division by zero`

Gating test (red today): `tests/test_average.py::AverageTest::test_empty_sequence_is_zero`

Acceptance (must go green): `./run_tests.sh`
EOF
  ;;
  2) cat <<'EOF'
`tinymath.clamp(value, low, high)` enforces the lower bound but never the upper bound, so a value
above `high` is returned unchanged.

- Expected: `clamp(15, 0, 10) == 10`
- Actual:   `clamp(15, 0, 10) == 15`

Gating test (red today): `tests/test_clamp.py::ClampTest::test_clamps_to_the_upper_bound`

Acceptance (must go green): `./run_tests.sh`
EOF
  ;;
  esac
}

# ── banner ────────────────────────────────────────────────────────────────────────────────────
echo
printf '\033[1m╔═ HEIMDALL MAINTAINER SANDBOX ══════════════════════════╗\033[0m\n'
printf '\033[1m║\033[0m repo=%-30s dry=%s\n' "$NAME" "$DRY"
printf '\033[1m║\033[0m A THROWAWAY private repo for the FIRST live maintainer run.\n'
printf '\033[1m║\033[0m 3 planted, test-gated bugs — the bot opens PRs on heimdall/*\n'
printf '\033[1m║\033[0m branches (NEVER main, NEVER self-merge). RJ merges by hand.\n'
printf '\033[1m╚════════════════════════════════════════════════════════╝\033[0m\n'

FILES="LICENSE README.md run_tests.sh .github/workflows/tests.yml tinymath/__init__.py tinymath/core.py tests/test_sum_range.py tests/test_average.py tests/test_clamp.py"

# ── DRY-RUN: print the FULL plan, execute nothing, need no gh ───────────────────────────────────
if [ "$DRY" = 1 ]; then
  say "PLAN (dry-run — nothing executed, no gh/network touched)"
  echo
  say "1) create private repo <owner>/$NAME (guarded: skipped if it already exists)"
  run "gh repo create <owner>/$NAME --private --description 'Heimdall maintainer sandbox'"
  echo
  say "2) scaffold this REAL stdlib-Python project (pushed only when content changed):"
  for f in $FILES; do printf '     + %s\n' "$f"; done
  echo
  say "3) file 3 planted, test-gated ISSUES (guarded: skipped if the title already exists):"
  i=0
  while [ "$i" -lt "${#ISSUE_TITLES[@]}" ]; do
    printf '   \033[1mISSUE %d\033[0m  %s\n' "$((i+1))" "${ISSUE_TITLES[$i]}"
    printf '     labels: maintainer, bug\n'
    printf '     gated by: %s  (red now → green after the fix)\n' "${ISSUE_GATES[$i]}"
    printf '     body:\n'
    issue_body "$i" | sed 's/^/       | /'
    run "gh issue create --repo <owner>/$NAME --title \"${ISSUE_TITLES[$i]}\" --label maintainer --label bug --body-file <body>"
    echo
    i=$((i+1))
  done
  say "4) NEXT: point the maintainer at the sandbox"
  printf '     \033[92m# first, a local run on RJ'\''s box (Arch A):\033[0m\n'
  printf '     deploy/cloud-run/deploy-maintainer.sh --local --repo <owner>/%s\n' "$NAME"
  printf '     \033[92m# then the cloud path once the local loop looks right:\033[0m\n'
  printf '     deploy/cloud-run/deploy-maintainer.sh --cloud --repo <owner>/%s\n' "$NAME"
  echo
  warn "the bot opens PRs on heimdall/* branches (never main, never self-merge) — RJ merges. Each"
  warn "PR opens ONLY after the fix turns its failing test green (attestation gate)."
  echo
  warn "dry-run: nothing executed. Re-run without --dry-run to apply."
  exit 0
fi

# ── LIVE: needs gh + git ────────────────────────────────────────────────────────────────────────
need() { command -v "$1" >/dev/null 2>&1 || die "missing '$1' — $2"; }
need gh "install GitHub CLI (https://cli.github.com) and run: gh auth login"
need git "install git"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"

OWNER="$(gh api user -q .login)"
[ -n "$OWNER" ] || die "could not resolve your GitHub login via gh api user"
FULL="$OWNER/$NAME"

# 1) create the repo (idempotent: only if absent) ───────────────────────────────────────────────
if gh repo view "$FULL" >/dev/null 2>&1; then
  say "repo $FULL already exists — reusing (idempotent)"
else
  say "creating private repo $FULL"
  gh repo create "$FULL" --private --description "Heimdall maintainer sandbox — planted, test-gated bugs" >/dev/null
fi

# 2) scaffold + push (idempotent: commit/push only when content changed) ─────────────────────────
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPODIR="$WORK/repo"
if gh repo clone "$FULL" "$REPODIR" -- -q >/dev/null 2>&1 && [ -d "$REPODIR/.git" ]; then
  git -C "$REPODIR" checkout -q -B main 2>/dev/null || true
else
  git init -q "$REPODIR"; git -C "$REPODIR" checkout -q -B main
  git -C "$REPODIR" remote add origin "$(gh repo view "$FULL" --json url -q .url).git" 2>/dev/null || true
fi
write_files "$REPODIR"
git -C "$REPODIR" add -A
if git -C "$REPODIR" diff --cached --quiet; then
  say "scaffold already present on $FULL — no content change (idempotent)"
else
  git -C "$REPODIR" -c user.name="heimdall-sandbox" -c user.email="sandbox@heimdall.invalid" \
      commit -q -m "scaffold: tinymath library + 3 planted, test-gated bugs"
  git -C "$REPODIR" push -q -u origin HEAD:main
  say "pushed the scaffold to $FULL"
fi

# 3) labels + issues (idempotent: create each only if its title is absent) ───────────────────────
gh label create maintainer --repo "$FULL" --color 5319e7 --description "Heimdall maintainer queue" >/dev/null 2>&1 || true
gh label create bug --repo "$FULL" --color d73a4a --description "Something is broken" >/dev/null 2>&1 || true

ISSUE_NUMS=()
i=0
while [ "$i" -lt "${#ISSUE_TITLES[@]}" ]; do
  title="${ISSUE_TITLES[$i]}"
  num="$(gh issue list --repo "$FULL" --state all --json number,title \
         -q ".[] | select(.title==\"$title\") | .number" | head -n1)"
  if [ -n "$num" ]; then
    say "issue already filed (#$num): $title"
  else
    bf="$WORK/body-$i.md"; issue_body "$i" > "$bf"
    url="$(gh issue create --repo "$FULL" --title "$title" --label maintainer --label bug --body-file "$bf")"
    num="$(printf '%s' "$url" | grep -oE '[0-9]+$')"
    say "filed issue #$num: $title"
  fi
  ISSUE_NUMS+=("$num")
  i=$((i+1))
done

# 4) summary + the exact next command ────────────────────────────────────────────────────────────
REPO_URL="$(gh repo view "$FULL" --json url -q .url)"
echo
printf '\033[1m── SANDBOX READY ───────────────────────────────────────\033[0m\n'
say "repo:   $REPO_URL"
say "issues: #${ISSUE_NUMS[0]:-?}  #${ISSUE_NUMS[1]:-?}  #${ISSUE_NUMS[2]:-?}  (labelled maintainer, bug)"
echo
say "NEXT — point the maintainer at the sandbox:"
printf '  \033[92m# first, a local run on this box (Arch A):\033[0m\n'
printf '  %s/deploy-maintainer.sh --local --repo %s\n' "$HERE" "$FULL"
printf '  \033[92m# then the cloud path once the local loop looks right:\033[0m\n'
printf '  %s/deploy-maintainer.sh --cloud --repo %s\n' "$HERE" "$FULL"
echo
warn "the bot opens PRs on heimdall/* branches (NEVER main, NEVER self-merge). RJ merges each PR."
warn "a PR opens ONLY after the fix turns its failing test green — the attestation gate proves it."
exit 0
