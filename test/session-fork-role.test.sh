#!/usr/bin/env bash
# test/session-fork-role.test.sh -- falsifiable coverage for bin/session-fork's
# per-task "role" field (wave/run task JSON) and its HEIMDALL_FORK_ROLE /
# SUPERX_FORK_ROLE invocation-wide fallback, both threading into hmd-exec's own
# --role flag (see bin/hmd-exec's ROLE SELECTION header comment and
# bin/session-fork's own ROLE global + fork_one's task_role comment).
#
# WHAT THIS PROVES, falsifiably:
#   1. no role anywhere (no env, no per-task field) -> hmd-exec invoked with NO
#      --role flag at all (never guessed, matches "unset stays unset").
#   2. invocation-wide HEIMDALL_FORK_ROLE alone -> every fork gets it.
#   3. a task's own "role" field -> that fork gets it, even with no
#      invocation-wide default.
#   4. mixed wave: one task omits "role" and falls back to the invocation
#      default, a SIBLING task in the SAME wave keeps its own distinct role --
#      proves per-task override is real, not just a global stuck on one value.
#   5. a task omits "role" AND there is no invocation default either -> NO
#      --role flag (never invented from nothing).
#   6. cmd_run's multi-wave path threads the same per-task field correctly,
#      not just cmd_wave's single-wave path.
#
# HERMETIC: session-fork resolves bin/hmd-exec via a PLUGIN_DIR computed from
# its OWN script location (readlink -f "$0"), never PATH and never an env
# override -- so proving what argv session-fork hands to hmd-exec requires a
# fixture copy: a temp bin/ directory holding a COPY of the real session-fork
# alongside a FAKE hmd-exec that only records its own argv. No real claude
# spawn, no real routing decision, no network, ever happens in this file.
# Every case uses a role-less, depends-less prompt so the logged argv is a
# single physical line (session-fork's own dependency-context injection
# prepends multi-line text to the prompt -- deliberately out of scope here,
# since it is a different feature from the one this file exists to prove).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s -- %s\n' "$1" "$2"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FIXTURE="$WORK/fixture/bin"
mkdir -p "$FIXTURE"
cp "$REPO_ROOT/bin/session-fork" "$FIXTURE/session-fork"
chmod +x "$FIXTURE/session-fork"

ARGV_LOG="$WORK/argv.log"
cat > "$FIXTURE/hmd-exec" <<'EOF'
#!/usr/bin/env bash
# Fake hmd-exec: records its own argv (one line per invocation -- every case
# in this file uses single-line prompts, so "$*" never contains an embedded
# newline) and prints a fixed, recognizable "answer" so session-fork's own
# success/failure bookkeeping (outputs/*.txt, status/*) has something real to
# write.
printf '%s\n' "$*" >> "${SF_ARGV_LOG:?SF_ARGV_LOG not set}"
echo "FAKE-HMD-EXEC-OK"
exit 0
EOF
chmod +x "$FIXTURE/hmd-exec"

SF="$FIXTURE/session-fork"
RESULTS_DIR="$WORK/results"
export SF_ARGV_LOG="$ARGV_LOG"
export HEIMDALL_FORK_DIR="$RESULTS_DIR"
export HEIMDALL_WORK_DIR="$WORK"
export HEIMDALL_MODEL="test-model"

reset_argv_log() { : > "$ARGV_LOG"; rm -rf "$RESULTS_DIR"; }

# last_role_for <marker> -- prints the --role flag's OWN argument from the
# first logged argv line containing <marker>, or empty if that line has no
# --role at all.
last_role_for() { grep -F "$1" "$ARGV_LOG" | head -1 | sed -n 's/.*--role \([^ ]*\).*/\1/p'; }
had_role_flag() { grep -F "$1" "$ARGV_LOG" | head -1 | grep -q -- '--role '; }

echo "== bin/session-fork: per-task role (wave/run JSON) + invocation ROLE fallback =="

# 1. cmd_single, no HEIMDALL_FORK_ROLE at all -> no --role flag passed.
reset_argv_log
unset HEIMDALL_FORK_ROLE SUPERX_FORK_ROLE 2>/dev/null
"$SF" single "task marker s1" >/dev/null 2>&1
if [ -s "$ARGV_LOG" ] && ! had_role_flag "s1"; then
  ok "1. single, no HEIMDALL_FORK_ROLE -> hmd-exec invoked with NO --role flag"
else
  bad "1. single, no HEIMDALL_FORK_ROLE -> hmd-exec invoked with NO --role flag" "argv='$(cat "$ARGV_LOG" 2>/dev/null)'"
fi

# 2. cmd_single, HEIMDALL_FORK_ROLE set -> the fork gets that role.
reset_argv_log
export HEIMDALL_FORK_ROLE="hmd:coder"
"$SF" single "task marker s2" >/dev/null 2>&1
if [ "$(last_role_for s2)" = "hmd:coder" ]; then
  ok "2. single, HEIMDALL_FORK_ROLE=hmd:coder -> hmd-exec invoked with --role hmd:coder"
else
  bad "2. single, HEIMDALL_FORK_ROLE=hmd:coder -> hmd-exec invoked with --role hmd:coder" "argv='$(cat "$ARGV_LOG" 2>/dev/null)'"
fi
unset HEIMDALL_FORK_ROLE

# 3. wave JSON: a task's own "role" field, no invocation-wide default.
reset_argv_log
unset HEIMDALL_FORK_ROLE SUPERX_FORK_ROLE 2>/dev/null
"$SF" wave '[{"id": "w1", "prompt": "task marker w1", "role": "hmd:reviewer"}]' >/dev/null 2>&1
if [ "$(last_role_for w1)" = "hmd:reviewer" ]; then
  ok "3. wave task's own \"role\" field -> hmd-exec invoked with --role hmd:reviewer"
else
  bad "3. wave task's own \"role\" field -> hmd-exec invoked with --role hmd:reviewer" "argv='$(cat "$ARGV_LOG" 2>/dev/null)'"
fi

# 4. wave JSON: a task that OMITS role falls back to the invocation-wide
#    HEIMDALL_FORK_ROLE, in the SAME wave as a sibling task with its own role.
reset_argv_log
export HEIMDALL_FORK_ROLE="hmd:coder"
"$SF" wave '[{"id": "w2a", "prompt": "task marker w2a"}, {"id": "w2b", "prompt": "task marker w2b", "role": "hmd:reviewer"}]' >/dev/null 2>&1
if [ "$(last_role_for w2a)" = "hmd:coder" ] && [ "$(last_role_for w2b)" = "hmd:reviewer" ]; then
  ok "4. mixed-role wave: omitted-role task falls back to invocation ROLE, sibling task keeps its OWN role"
else
  bad "4. mixed-role wave: omitted-role task falls back to invocation ROLE, sibling task keeps its OWN role" \
    "w2a='$(last_role_for w2a)' w2b='$(last_role_for w2b)'"
fi
unset HEIMDALL_FORK_ROLE

# 5. wave JSON: a task omits role, AND there is no invocation default either
#    -> no --role flag at all (never invented from nothing).
reset_argv_log
unset HEIMDALL_FORK_ROLE SUPERX_FORK_ROLE 2>/dev/null
"$SF" wave '[{"id": "w3", "prompt": "task marker w3"}]' >/dev/null 2>&1
if [ -s "$ARGV_LOG" ] && ! had_role_flag "w3"; then
  ok "5. wave task omits role, no invocation default either -> NO --role flag (never guessed)"
else
  bad "5. wave task omits role, no invocation default either -> NO --role flag (never guessed)" "argv='$(cat "$ARGV_LOG" 2>/dev/null)'"
fi

# 6. cmd_run (multi-wave) threads the same per-task field, not just cmd_wave's
#    single-wave path. Deliberately no "depends" here (see file header).
reset_argv_log
unset HEIMDALL_FORK_ROLE SUPERX_FORK_ROLE 2>/dev/null
"$SF" run '[[{"id": "r1", "prompt": "task marker r1", "role": "hmd:architect"}], [{"id": "r2", "prompt": "task marker r2"}]]' >/dev/null 2>&1
if [ "$(last_role_for r1)" = "hmd:architect" ] && ! had_role_flag "r2"; then
  ok "6. run (multi-wave) JSON: per-task role threads through wave 1; wave 2's roleless task gets none"
else
  bad "6. run (multi-wave) JSON: per-task role threads through wave 1; wave 2's roleless task gets none" \
    "r1='$(last_role_for r1)' r2_had_role=$(had_role_flag r2 && echo yes || echo no)"
fi

echo "--------------------------------------------------------------------"
printf 'session-fork-role: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
