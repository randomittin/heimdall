#!/usr/bin/env bash
# Journey 07 -- a push waits for the repo's own checks (CLAUDE.md "Push gate: each repo's own checks, not heimdall's",
# skills/heimdall/references/use-case-tests.md "The gate: .heimdall/repo-checks.json").
#
#   A developer's repo is not hmd's own: it declares its checks in .heimdall/repo-checks.json (lint and use-cases). Their coding agent pushes it to the team's
#   remote through hmd's push gate, the PreToolUse hook on every Bash call (bin/heimdall-precheck-bash): Claude Code runs the command only if that hook lets it through.
#     1. with no record of the checks the push is BLOCKED: the hook exits 2, the deny names this repo's own gate, says there is no receipt and prints the command that
#        records one; the real push never ran, so the remote has no branch
#     2. `bin/heimdall-repo-checks run` records the checks: lint and use-cases pass, and the receipt is green, from a clean tree, bound to the commit
#     3. the same push now passes the gate (GREEN, for that commit) and the real `git push` lands: the remote's main is the commit; the secret scan still ran
#     4. a commit that breaks the product (the oat-milk surcharge is dropped) makes the green receipt STALE: the push is BLOCKED again, the remote stays where it was
#     5. recording the checks again turns the use-case scenario RED (exit 1, the broken promise named): the push stays BLOCKED, naming the failing check
#     6. the developer restores the surcharge and commits, records the checks, and the push goes through: the remote's main is the fix
#     7. no model session and no keychain access anywhere
#
# Engines reused: test/heimdall-push-gate-per-repo.test.sh (A: the runner and the receipt's bindings, C: the hook), test/heimdall-push-gate-target-repo.test.sh.
# The doubles: claude and security (lib.sh, never called) and gitleaks, the external scanner the push-time secret gate demands: it finds nothing here, the secret gates
# have proofs of their own. The remote is a real bare repo on the local disk (the file transport), never the network.
# The hook runs from a private clone of the tree under test, as it runs from an install: the hook's helpers run `python3 -I`, which ignores PYTHONDONTWRITEBYTECODE and
# leaves a .pyc beside the libs it imports, and the tree under test is read-only to a journey (run.sh fails a run that wrote into it).
# Mutants (test/use-cases/mutants.list): the hook never denies on the repo's own gate, a failing check is recorded as passing.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"
uc_begin 07_push_blocked_until_checks_pass
uc_tree
uc_fakebin
uc_sandbox push

HH="$UC_ROOT/push/heimdall-home"
mkdir -p "$HH"
GITLEAKS_LOG="$UC_ROOT/gitleaks.log"
: > "$GITLEAKS_LOG"
cat > "$UC_BIN/gitleaks" <<EOF
#!/usr/bin/env bash
echo "gitleaks \$*" >> "$GITLEAKS_LOG"
exit 0
EOF
chmod +x "$UC_BIN/gitleaks"

mkdir -p "$UC_WORK/corner-cafe"
REPO="$(cd "$UC_WORK/corner-cafe" && pwd -P)"
ORIGIN="$UC_WORK/team-remote.git"
PLUGIN="$UC_ROOT/push/plugin"
RUNNER="$PLUGIN/bin/heimdall-repo-checks"
RECEIPT="$REPO/.heimdall/receipts/repo-checks.json"

g() { uc_run "$UC_HOME" "$REPO" -- git "$@"; }
must() { "$@"; if [ "$UC_RC" -ne 0 ]; then uc_fatal "setup step failed (exit $UC_RC): $* -- $(head -c 300 "$UC_ERR" | LC_ALL=C tr '\n' ' ')"; fi; }
head_sha() { g rev-parse HEAD; tr -d '\n' < "$UC_OUT"; }
remote_main() { uc_run "$UC_HOME" "$UC_WORK" -- git -C "$ORIGIN" rev-parse -q --verify refs/heads/main; if [ "$UC_RC" -eq 0 ]; then tr -d '\n' < "$UC_OUT"; else printf none; fi; }
record() { uc_run "$UC_HOME" "$UC_WORK" -- "$RUNNER" run --repo "$REPO"; }

# gate COMMAND -- what Claude Code does with a Bash tool call: the PreToolUse hook reads the call as JSON on stdin; exit 2 denies it (the command never runs), 0 lets it through.
gate() {
  # shellcheck disable=SC2016  # the jq program's $c and $d are jq variables, not shell ones
  jq -nc --arg c "$1" --arg d "$REPO" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}' > "$UC_ROOT/payload.json"
  # shellcheck disable=SC2016  # $1 and $2 belong to the inner bash: the payload becomes the hook's stdin (uc_run's own stdin is /dev/null)
  uc_run "$UC_HOME" "$REPO" CLAUDE_PLUGIN_ROOT="$PLUGIN" HEIMDALL_HOME="$HH" HMD_PUSH_TARGET_TIMEOUT_S=60 \
    -- bash -c 'exec bash "$1" < "$2"' _ "$PLUGIN/bin/heimdall-precheck-bash" "$UC_ROOT/payload.json"
  GATE_RC="$UC_RC"; GATE_OUT="$UC_ROOT/gate.out"; GATE_ERR="$UC_ROOT/gate.err"
  cp "$UC_OUT" "$GATE_OUT"; cp "$UC_ERR" "$GATE_ERR"
}
# push -- `git push origin main` as the agent runs it: the gate first, and the real push only when the gate lets it through.
push() {
  gate "git push origin main"
  PUSH_RC=none
  if [ "$GATE_RC" -eq 0 ]; then g push origin main; PUSH_RC="$UC_RC"; fi
}
gate_is() {  # gate_is LABEL WANT -- the gate's exit status for the last push: 2 denied, 0 let through (142: the watchdog)
  if [ "$GATE_RC" -eq 142 ]; then uc_bad "$1: the gate hung (killed by the watchdog after ${UC_TIMEOUT_S}s)"
  elif [ "$GATE_RC" -eq "$2" ]; then uc_ok "$1 (exit $2)"
  else uc_bad "$1 (exit $GATE_RC, wanted $2)" "$(head -c 500 "$GATE_ERR" | LC_ALL=C tr '\n' ' ')"; fi
}
denied_with() {  # denied_with LABEL FRAGMENT -- the deny's text (the hook's JSON error) holds FRAGMENT
  if jq -e --arg f "$2" '.error | contains($f)' "$GATE_OUT" >/dev/null 2>&1; then uc_ok "$1"
  else uc_bad "$1" "no \"$2\" in: $(head -c 400 "$GATE_OUT" | LC_ALL=C tr '\n' ' ')"; fi
}
remote_is() {  # remote_is LABEL WANT -- the team's remote has main at WANT (none: no main at all)
  local got; got="$(remote_main)"
  if [ "$got" = "$2" ]; then uc_ok "$1"; else uc_bad "$1" "the remote's main is $got, wanted $2"; fi
}
pushed_for_real() {  # pushed_for_real LABEL -- the real git push ran, and succeeded
  if [ "$PUSH_RC" = 0 ]; then uc_ok "$1"; else uc_bad "$1" "the real git push exited $PUSH_RC"; fi
}

# The repo: a corner cafe's order program, its use cases through that one entry point, and the declaration of its own checks.
write_order() {  # write_order OAT_CENTS -- the surcharge for oat milk is the line a careless edit drops
  mkdir -p "$REPO/bin"
  sed "s/@OAT@/$1/" > "$REPO/bin/order" <<'EOF'
#!/bin/sh
# order DRINK [--oat] -- the receipt line for one drink at the corner cafe.
drink="${1:?usage: order DRINK [--oat]}"
case "$drink" in
  coffee) cents=300 ;;
  latte) cents=400 ;;
  *) echo "no such drink: $drink" >&2; exit 2 ;;
esac
milk=""
if [ "${2:-}" = "--oat" ]; then cents=$((cents + @OAT@)); milk=" with oat milk"; fi
printf '%s%s: %d.%02d\n' "$drink" "$milk" $((cents / 100)) $((cents % 100))
EOF
}
mkdir -p "$REPO/.heimdall" "$REPO/tests/use_cases"
printf '.heimdall/receipts/\n' > "$REPO/.gitignore"
cat > "$REPO/.heimdall/repo-checks.json" <<'EOF'
{"schema":1,"checks":[
  {"name":"lint","cmd":"sh -n bin/order && sh -n tests/use_cases/run.sh"},
  {"name":"use-cases","cmd":"sh tests/use_cases/run.sh"}
]}
EOF
cat > "$REPO/tests/use_cases/run.sh" <<'EOF'
#!/bin/sh
# The cafe's use cases, one scenario per thing a customer comes to do, through the public door (bin/order).
cd "$(dirname "$0")/../.." || exit 1
status=0
scenario() {  # scenario NAME WANTED ARGS...
  name="$1"; wanted="$2"; shift 2
  got="$(sh bin/order "$@" 2>&1)"
  if [ "$got" = "$wanted" ]; then echo "ok   $name"; else echo "FAIL $name: wanted '$wanted', got '$got'"; status=1; fi
}
scenario order_a_coffee "coffee: 3.00" coffee
scenario order_a_latte_with_oat_milk "latte with oat milk: 4.50" latte --oat
exit "$status"
EOF
write_order 50
must uc_run "$UC_HOME" "$UC_WORK" -- git -c core.hooksPath=/dev/null clone -q "$UC_TREE" "$PLUGIN"
must g init -q
must g symbolic-ref HEAD refs/heads/main
must g config user.email dev@example.com
must g config user.name Dev
must g config commit.gpgsign false
must g add -A
must g commit -q -m "the cafe takes orders, and declares its own checks"
must uc_run "$UC_HOME" "$UC_WORK" -- git init -q --bare "$ORIGIN"
must uc_run "$UC_HOME" "$UC_WORK" -- git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
must g remote add origin "$ORIGIN"
FIRST="$(head_sha)"

uc_jq "(setup) hooks.json wires hmd's push gate on every Bash call" '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(contains("heimdall-precheck-bash"))] | length >= 1' "$PLUGIN/hooks/hooks.json"
if [ ! -e "$RECEIPT" ]; then uc_ok "(setup) the repo declares its checks and has never recorded them"; else uc_bad "(setup) a receipt exists before any run"; fi
remote_is "(setup) the team's remote is empty" none

# 1. no record of the checks: blocked
push
gate_is "a push with no record of the checks is BLOCKED by the gate" 2
denied_with "the deny is this repo's own gate, not hmd's sweep" "pre-push repo-checks gate failed for $REPO"
denied_with "…and says there is no receipt" "no receipt at $RECEIPT"
denied_with "…and prints the command that records the checks" "$RUNNER run --repo $REPO"
remote_is "…and nothing reached the remote" none

# 2. record the checks
record
uc_rc "bin/heimdall-repo-checks run records the checks" 0
uc_has "…lint passed" "$UC_ERR" 'PASS lint'
uc_has "…use-cases passed" "$UC_ERR" 'PASS use-cases'
uc_has "…and the scenarios ran through the cafe's own entry point" "$UC_OUT" 'ok   order_a_latte_with_oat_milk'
uc_jq "the receipt is green, from a clean tree, and lists the declared checks in order" '.exit_code == 0 and .dirty == false and ([.checks[].name] == ["lint","use-cases"]) and ([.checks[].exit_code] == [0,0])' "$RECEIPT"
uc_jq "…and is bound to the commit it was recorded at" ".head_sha == \"$FIRST\"" "$RECEIPT"

# 3. the same push passes, for real
push
gate_is "the same push passes the gate once the record is green" 0
uc_has "…the gate says GREEN for that commit" "$GATE_ERR" "repo-checks: GREEN - 2 check\\(s\\) passed at ${FIRST:0:12}"
pushed_for_real "…and the real git push went through"
remote_is "…and landed: the remote's main is the recorded commit" "$FIRST"
if [ -s "$GITLEAKS_LOG" ]; then uc_ok "…and the push-time secret scan still ran (a green record does not skip the other gates)"; else uc_bad "the push-time secret scan never ran for the push the gate let through"; fi

# 4. a commit after the record: stale
write_order 0
must g add -A
must g commit -q -m "simplify the order program"
push
gate_is "a push after a new commit is BLOCKED: the green record is for the commit before" 2
denied_with "…as STALE" "STALE"
remote_is "…and the remote stays at the commit that was recorded" "$FIRST"

# 5. the checks fail: red, and the push stays blocked
record
uc_rc "recording the checks on the broken product fails" 1
uc_has "…the scenario is named in the customer's words" "$UC_OUT" 'FAIL order_a_latte_with_oat_milk'
uc_has "…and the check that failed" "$UC_ERR" 'FAIL use-cases'
uc_jq "the receipt is red and says which check failed" '.exit_code != 0 and ([.checks[] | select(.exit_code != 0) | .name] == ["use-cases"])' "$RECEIPT"
push
gate_is "the push stays BLOCKED while a check is red" 2
denied_with "…naming the failing check" "RED - check(s) failed: use-cases"
remote_is "…and the remote is still at the last good commit" "$FIRST"

# 6. fixed, recorded, pushed
write_order 50
must g add -A
must g commit -q -m "restore the oat-milk surcharge"
FIXED="$(head_sha)"
record
uc_rc "after the fix the checks are recorded green again" 0
push
gate_is "the push passes the gate on the new green record" 0
pushed_for_real "…and the real git push went through"
remote_is "…and the remote's main is the fix" "$FIXED"

# 7. no model, no keychain
if [ ! -s "$UC_CLAUDE_LOG" ] && [ ! -s "$UC_SECURITY_LOG" ]; then uc_ok "no model session and no keychain access in the whole journey"; else uc_bad "the journey called claude or the keychain" "$(cat "$UC_CLAUDE_LOG" "$UC_SECURITY_LOG" | head -c 200)"; fi

uc_finish
