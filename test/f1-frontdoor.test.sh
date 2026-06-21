#!/usr/bin/env bash
#
# f1-frontdoor.test.sh — deterministic harness for the F1 onboarding front-door
# pieces (standalone units; the launch-path wiring is F1 Wave 2).
#
# Four proofs, all runnable against real temp dirs, no network, no mocks:
#
#   A. PERSONA SET-ONCE — `set coder` then `get` returns coder and `is-set` is
#      true (exit 0); a fresh HEIMDALL_HOME reads back `unset` and `is-set` exits
#      1 with no prompt-loop. Proves the store is real and validates input.
#
#   B. FRONTDOOR 4-CONTEXT — four constructed temp dirs (empty / fresh-project /
#      existing-codebase / mid-task-resume) each classify to the right context and
#      route. Real filesystem + real `git init`/commit — no faked signals.
#
#   C. DESIGN TIERS — tier A is the default (no choice -> A), tier B is selectable
#      (explicit B, or a design source URL -> B with a resolved designmatch argv).
#
#   D. GLOBAL PERSISTENCE ACROSS PROCESSES — write the persona in ONE process,
#      read it back in a SEPARATE, freshly-spawned process (same HEIMDALL_HOME).
#      Proves the persona is remembered globally, not held in memory.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
PERSONA="$REPO/bin/heimdall-persona"
FRONTDOOR="$REPO/bin/heimdall-frontdoor"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$PERSONA" ]   || { echo "FATAL: $PERSONA not executable"; exit 2; }
[ -x "$FRONTDOOR" ] || { echo "FATAL: $FRONTDOOR not executable"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A reusable assert: run a command, compare its trimmed stdout to an expected
# string, and assert the exit code.
assert_out_rc() {
  # assert_out_rc LABEL EXPECTED-OUT EXPECTED-RC -- CMD...
  local label="$1" want_out="$2" want_rc="$3"; shift 3
  [ "$1" = "--" ] && shift
  local got_out got_rc
  got_out="$("$@" 2>/dev/null)"; got_rc=$?
  if [ "$got_out" = "$want_out" ] && [ "$got_rc" = "$want_rc" ]; then
    ok "$label (out='$got_out' rc=$got_rc)"
  else
    bad "$label — got out='$got_out' rc=$got_rc, want out='$want_out' rc=$want_rc"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# A. PERSONA SET-ONCE
# ─────────────────────────────────────────────────────────────────────────────
echo "A. PERSONA SET-ONCE:"
HOME_A="$WORK/persona-a/.heimdall"

# Cold: unset.
assert_out_rc "cold get is 'unset'"   "unset" 0 -- env HEIMDALL_HOME="$HOME_A" "$PERSONA" get
assert_out_rc "cold is-set is false"  "false" 1 -- env HEIMDALL_HOME="$HOME_A" "$PERSONA" is-set

# Set coder, then read back.
assert_out_rc "set coder echoes coder" "coder" 0 -- env HEIMDALL_HOME="$HOME_A" "$PERSONA" set coder
assert_out_rc "get returns coder"       "coder" 0 -- env HEIMDALL_HOME="$HOME_A" "$PERSONA" get
assert_out_rc "is-set true after set"   "true"  0 -- env HEIMDALL_HOME="$HOME_A" "$PERSONA" is-set

# Re-set to non-coder (the value is what the user chose; set is idempotent-write).
assert_out_rc "set non-coder"           "non-coder" 0 -- env HEIMDALL_HOME="$HOME_A" "$PERSONA" set non-coder
assert_out_rc "get returns non-coder"   "non-coder" 0 -- env HEIMDALL_HOME="$HOME_A" "$PERSONA" get

# Invalid persona is rejected (rc=2), and does NOT corrupt the stored value.
env HEIMDALL_HOME="$HOME_A" "$PERSONA" set wizard >/dev/null 2>&1
RC=$?
if [ "$RC" = "2" ]; then ok "invalid persona rejected (rc=2)"; else bad "invalid persona rc=$RC, want 2"; fi
assert_out_rc "value intact after rejected set" "non-coder" 0 -- env HEIMDALL_HOME="$HOME_A" "$PERSONA" get

# A DIFFERENT (fresh) HEIMDALL_HOME is independent and reads unset (no leakage,
# no global mutable state) — proves it is keyed on the env-resolved path.
HOME_FRESH="$WORK/persona-fresh/.heimdall"
assert_out_rc "fresh home is unset"   "unset" 0 -- env HEIMDALL_HOME="$HOME_FRESH" "$PERSONA" get
assert_out_rc "fresh home is-set false" "false" 1 -- env HEIMDALL_HOME="$HOME_FRESH" "$PERSONA" is-set

# ─────────────────────────────────────────────────────────────────────────────
# B. FRONTDOOR 4-CONTEXT
# ─────────────────────────────────────────────────────────────────────────────
echo "B. FRONTDOOR 4-CONTEXT:"
BASE="$WORK/dirs"

# 1) empty-dir — nothing meaningful.
D_EMPTY="$BASE/empty"; mkdir -p "$D_EMPTY"

# 2) fresh-project — manifest + source, but NO git history.
D_FRESH="$BASE/fresh"; mkdir -p "$D_FRESH"
printf '{}\n' > "$D_FRESH/package.json"
printf 'console.log("hi")\n' > "$D_FRESH/index.js"

# 3) existing-codebase — real git history + source.
D_EXIST="$BASE/existing"; mkdir -p "$D_EXIST"
(
  cd "$D_EXIST"
  git init -q
  git config user.email "test@example.com"
  git config user.name  "test"
  printf 'def main():\n    return 0\n' > app.py
  printf '{}\n' > package.json
  git add -A
  git commit -q -m "init"
) >/dev/null 2>&1

# 4) mid-task-resume — a .planning checkpoint present (even atop source).
D_RESUME="$BASE/resume"; mkdir -p "$D_RESUME/.planning"
printf '# checkpoint\n' > "$D_RESUME/.planning/CHECKPOINT.md"
printf 'x = 1\n' > "$D_RESUME/main.py"

assert_out_rc "empty-dir routes onboard-new" \
  "empty-dir -> onboard-new" 0 -- "$FRONTDOOR" "$D_EMPTY"
assert_out_rc "fresh-project routes orient-fresh" \
  "fresh-project -> orient-fresh" 0 -- "$FRONTDOOR" "$D_FRESH"
assert_out_rc "existing-codebase routes orient-existing" \
  "existing-codebase -> orient-existing" 0 -- "$FRONTDOOR" "$D_EXIST"
assert_out_rc "mid-task-resume routes resume" \
  "mid-task-resume -> resume" 0 -- "$FRONTDOOR" "$D_RESUME"

# Resume must WIN over source/history: drop a checkpoint into the existing repo
# and assert it now classifies as resume (priority order proof).
cp -R "$D_EXIST" "$BASE/existing-with-ckpt"
mkdir -p "$BASE/existing-with-ckpt/.planning"
printf '# resume me\n' > "$BASE/existing-with-ckpt/.planning/STATE.md"
assert_out_rc "checkpoint wins over codebase" \
  "mid-task-resume -> resume" 0 -- "$FRONTDOOR" "$BASE/existing-with-ckpt"

# The --json record carries the signals (transparency, not an opaque verdict).
JSON_CTX="$("$FRONTDOOR" --json "$D_FRESH" 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["context"])')"
if [ "$JSON_CTX" = "fresh-project" ]; then
  ok "--json record exposes context (fresh-project)"
else
  bad "--json context was '$JSON_CTX', want fresh-project"
fi

# ─────────────────────────────────────────────────────────────────────────────
# C. DESIGN TIERS
# ─────────────────────────────────────────────────────────────────────────────
echo "C. DESIGN TIERS:"

# Tier A is the default: no choice -> A, flagged as default.
assert_out_rc "design default -> tier A" \
  "tier A -> inline-variant  (default)" 0 -- "$FRONTDOOR" design
assert_out_rc "explicit A -> tier A" \
  "tier A -> inline-variant" 0 -- "$FRONTDOOR" design A
assert_out_rc "inline token -> tier A" \
  "tier A -> inline-variant" 0 -- "$FRONTDOOR" design inline

# Tier B is selectable: explicit B, and a design source URL.
assert_out_rc "explicit B -> tier B (designmatch wire)" \
  "tier B -> designmatch  (designmatch wire)" 0 -- "$FRONTDOOR" design B
assert_out_rc "source URL -> tier B (designmatch init)" \
  "tier B -> designmatch  (designmatch init https://claude.design/x)" 0 \
  -- "$FRONTDOOR" design --source https://claude.design/x

# The JSON entry for B resolves a real designmatch argv (Wave-2 hands this off).
B_ROUTE="$("$FRONTDOOR" design --json B 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["route"])')"
B_DEFAULT_FLAG="$("$FRONTDOOR" design --json 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["default"])')"
if [ "$B_ROUTE" = "designmatch" ]; then ok "tier B route is designmatch"; \
  else bad "tier B route was '$B_ROUTE', want designmatch"; fi
if [ "$B_DEFAULT_FLAG" = "True" ]; then ok "tier A default flag is True (no choice)"; \
  else bad "default flag was '$B_DEFAULT_FLAG', want True"; fi

# ─────────────────────────────────────────────────────────────────────────────
# D. GLOBAL PERSISTENCE ACROSS PROCESSES
# ─────────────────────────────────────────────────────────────────────────────
echo "D. GLOBAL PERSISTENCE ACROSS PROCESSES:"
HOME_D="$WORK/persona-d/.heimdall"

# Process 1: write.
env HEIMDALL_HOME="$HOME_D" "$PERSONA" set coder >/dev/null 2>&1
# The on-disk file must exist at the resolved global path.
PFILE="$(env HEIMDALL_HOME="$HOME_D" "$PERSONA" path 2>/dev/null)"
if [ -f "$PFILE" ]; then ok "persona.json written to global path ($PFILE)"; \
  else bad "persona.json not found at resolved path '$PFILE'"; fi

# Process 2 (separate spawn): read. Must see coder — proof it is persisted, not
# carried in the first process's memory.
assert_out_rc "fresh process reads coder" "coder" 0 \
  -- env HEIMDALL_HOME="$HOME_D" "$PERSONA" get
assert_out_rc "fresh process is-set true" "true" 0 \
  -- env HEIMDALL_HOME="$HOME_D" "$PERSONA" is-set

# And a Python consumer (the propagation path) reads the same value in its own
# process via the library API — the documented branch point.
PY_VAL="$(env HEIMDALL_HOME="$HOME_D" python3 -c '
import sys
sys.path.insert(0, "'"$REPO"'/bin/lib")
import persona_store as ps
print(ps.get_persona(), ps.is_coder())
' 2>/dev/null)"
if [ "$PY_VAL" = "coder True" ]; then
  ok "library consumer reads coder + is_coder()=True in a fresh process"
else
  bad "library consumer read '$PY_VAL', want 'coder True'"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "f1-frontdoor.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
