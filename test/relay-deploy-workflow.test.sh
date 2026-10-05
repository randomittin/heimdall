#!/usr/bin/env bash
#
# relay-deploy-workflow.test.sh -- acceptance for the relay deploy pipeline:
# .github/workflows/relay-deploy.yml, the relay-ci.yml it gates on, relay/wrangler.toml's
# [env.canary], and relay/scripts/health-check.sh (see the header of relay-deploy.yml for the WHY).
#
# A pipeline that ships to production and holds a Cloudflare token is easy to get subtly wrong in
# ways nothing local will ever exercise: a mutable action tag, a rollback that runs after a deploy
# that never happened, a canary that deploys over production, a token an `npm ci` install script can
# read, a gate that two concurrent runs cancel. This suite checks each of those properties
# structurally (test/lib/relay_deploy_workflow_check.py parses the YAML, it does not grep it) and
# PROVE-REDs every one against a deliberately broken copy (test/lib/relay_deploy_workflow_mutants.py),
# so a check that can no longer fail is itself a failing case. When actionlint is installed it also
# runs, as the syntax/expression/shellcheck pass over both workflows.
#
#   bash test/relay-deploy-workflow.test.sh             (exit 0 = every case passes)
#   ACTIONLINT=/path/to/actionlint bash test/relay-deploy-workflow.test.sh
#
# No repo state is mutated: every mutant is a throwaway copy under a temp dir.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CHECK="$REPO/test/lib/relay_deploy_workflow_check.py"
MUTANTS="$REPO/test/lib/relay_deploy_workflow_mutants.py"
WORKFLOW="$REPO/.github/workflows/relay-deploy.yml"
RELAY_CI="$REPO/.github/workflows/relay-ci.yml"

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  SKIP %s\n' "$1"; }

echo "relay-deploy-workflow.test.sh"

for f in "$CHECK" "$MUTANTS"; do
  [ -f "$f" ] || { echo "FATAL: $f not found"; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: python3 has no PyYAML (release-gate-suites-workflow.test.sh needs it too)"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/relay-deploy-workflow-test.XXXXXX")"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

# ── 1. every structural property holds on the real files ──────────────────────────────────────────
real="$WORK/real.out"
python3 "$CHECK" >"$real" 2>&1
rc=$?
while IFS= read -r line; do
  case "$line" in
    "ok   "*) ok "${line#ok   }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
  esac
done <"$real"
if [ "$rc" -ne 0 ] && ! grep -q '^FAIL ' "$real"; then
  bad "checker exited $rc without naming a failing property: $(head -3 "$real" | tr '\n' ' ')"
fi
if ! grep -q '^ok ' "$real"; then
  bad "checker reported no passing property at all"
fi

# ── 2. actionlint, when installed: syntax, expressions, needs/outputs, shellcheck on every run: ───
# actionlint resolves a local `uses: ./.github/workflows/x.yml` only inside a project root it can
# recognise by a .git entry, and a linked worktree has a .git FILE while a bare copy has none. So it
# is run on a throwaway project (the two workflows plus a .git directory), which makes the
# relay-deploy -> relay-ci workflow_call wiring check run wherever this suite does.
ACTIONLINT="${ACTIONLINT:-actionlint}"
lint_bin="$(command -v "$ACTIONLINT" 2>/dev/null || true)"
lint_project() { # <dir holding relay-deploy.yml + relay-ci.yml>  -- prints actionlint's findings, exit = its exit
  local proj="$WORK/lint-project-$$-$RANDOM"
  mkdir -p "$proj/.git" "$proj/.github/workflows"
  cp "$1/relay-deploy.yml" "$1/relay-ci.yml" "$proj/.github/workflows/"
  ( cd "$proj" && "$lint_bin" .github/workflows/relay-deploy.yml .github/workflows/relay-ci.yml 2>&1 )
}
if [ -n "$lint_bin" ]; then
  mkdir -p "$WORK/real-workflows"
  cp "$WORKFLOW" "$RELAY_CI" "$WORK/real-workflows/"
  if lint_out="$(lint_project "$WORK/real-workflows")"; then
    ok "actionlint is clean on relay-deploy.yml and relay-ci.yml, including the deploy -> relay-ci workflow_call wiring"
  else
    bad "actionlint reports problems in relay-deploy.yml / relay-ci.yml"
    printf '%s\n' "$lint_out" | head -20
  fi
else
  skip "actionlint not installed (set ACTIONLINT=/path/to/actionlint to run it); the structural checks above still ran"
fi

# ── 3. PROVE-RED: each deliberately broken copy must turn exactly its property red ────────────────
echo "  -- PROVE-RED: every property must be able to fail --"

n_mutants="$(python3 "$MUTANTS" list | wc -l | tr -d ' ')"
if [ "$n_mutants" -ge 20 ]; then
  ok "the mutant catalog is intact ($n_mutants mutants)"
else
  bad "the mutant catalog shrank to $n_mutants mutants (expected 20 or more)"
fi

while read -r name prop; do
  [ -n "$name" ] || continue
  dir="$WORK/mutant-$name"
  if ! python3 "$MUTANTS" make "$name" "$dir" 2>"$WORK/make.err"; then
    bad "PROVE-RED $name: could not build the mutant: $(cat "$WORK/make.err")"
    continue
  fi
  out="$(python3 "$CHECK" --workflow "$dir/relay-deploy.yml" --relay-ci "$dir/relay-ci.yml" --wrangler "$dir/wrangler.toml" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "^FAIL $prop:"; then
    ok "PROVE-RED $name -> $prop goes red"
  else
    bad "PROVE-RED $name was NOT caught by property $prop (checker exit $rc)"
  fi
done < <(python3 "$MUTANTS" list)

# and the actionlint step must itself be able to fail: the gate's callee losing workflow_call.
if [ -n "$lint_bin" ]; then
  if lint_out="$(lint_project "$WORK/mutant-relay-ci-not-callable")"; then
    bad "PROVE-RED actionlint stayed clean although relay-ci.yml lost its workflow_call trigger"
  else
    ok "PROVE-RED actionlint flags relay-deploy.yml when relay-ci.yml loses workflow_call"
  fi
fi

# the health-check script is a file, not text, so its mutant is a path that is not there.
out="$(python3 "$CHECK" --health-script "$WORK/no-such-health-check.sh" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q '^FAIL health-script:'; then
  ok "PROVE-RED a missing scripts/health-check.sh -> health-script goes red"
else
  bad "PROVE-RED a missing scripts/health-check.sh was NOT caught (checker exit $rc)"
fi

# a workflow that is not YAML at all must stop the checker before any property can pass vacuously.
printf 'jobs: [unterminated\n' >"$WORK/broken.yml"
out="$(python3 "$CHECK" --workflow "$WORK/broken.yml" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q '^FAIL yaml:'; then
  ok "PROVE-RED a workflow that is not valid YAML -> yaml goes red"
else
  bad "PROVE-RED a workflow that is not valid YAML was NOT caught (checker exit $rc)"
fi

echo
printf 'relay-deploy-workflow: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
