#!/usr/bin/env bash
# test/heimdall-pyenv-shim-fix.test.sh — regression guard for the pyenv/asdf
# fast-python3 resolution fix in bin/heimdall-statusline-register and
# bin/heimdall-maintain-loop.
#
# CONTEXT: bin/heimdall-statusline (commit 733219d) established the underlying
# problem — bare `python3` can resolve through a pyenv/asdf shim (~400-620ms/launch
# measured on this dev machine) instead of a direct interpreter (~30-70ms). Both
# scripts tested here run a python3 subprocess synchronously in Claude Code's
# SessionStart foreground path (heimdall-statusline-register's `register` arm,
# heimdall-maintain-loop's `resume-hint` arm) — so the same tax applies.
#
# THE FIRST VERSION OF THIS FIX WAS WRONG, AND THIS TEST'S CLAIM (3b) IS WHY.
# It copied bin/heimdall-statusline's PATH-prepend pattern (export PATH="<fast
# dir>:$PATH"). That regressed test/heimdall-maintain-loop.test.sh: 14 scenarios
# that arrange PATH="$FAKEBIN:$PATH" to shadow real `gh`/`git` with hermetic fakes
# started hitting the REAL /opt/homebrew/bin/gh and /opt/homebrew/bin/git instead,
# because the fix's PATH-prepend landed AHEAD of the caller's own $FAKEBIN —
# unshadowing them and sending real network calls that failed with
# "HTTP 401: Bad credentials". Proven by isolating the variable: reverting the fix
# alone took that suite from 38 passed/14 failed back to 52 passed/0 failed.
#
# THE FIX: resolve the fast interpreter into a VARIABLE ($PY / $PY3) that the
# script's own invocation sites already use (or are rewritten to use) — PATH
# itself is NEVER touched. This can't shadow any other binary because nothing
# outside the resolved variable's own call sites changes.
#
# Hermetic: every scenario runs against FAKE binaries under a scratch PATH/WORK dir
# — nothing here touches a real pyenv install, ~/.heimdall, or ~/.claude/settings.json.
# The fix block itself is extracted VERBATIM out of the live script under test (not a
# hand-copied duplicate), so this stays honest if the block ever moves or is edited.
#
# FALSIFIABLE claims proven per script (heimdall-maintain-loop resolves into $PY,
# heimdall-statusline-register resolves into $PY3 — the extractor below detects
# whichever name a given script uses):
#   (1) PRESENT + POSITIONED — the resolve block exists and precedes the script's
#       first real use of the resolved variable (a block added AFTER the first use
#       is a bug — it would resolve too late to matter).
#   (2) NO-OP WHEN UNSHIMMED — when the resolved variable's starting value does NOT
#       point under a `shims/` dir, running the block leaves it byte-for-byte
#       unchanged, AND leaves $PATH byte-for-byte unchanged.
#   (3a) BYPASS ENGAGES — when the starting value DOES point under a `shims/` dir
#       and a real direct candidate exists on this machine, the block rewrites the
#       variable to that candidate's absolute path. Degrades to a documented,
#       explicitly-labeled pass when no direct candidate exists on this machine.
#   (3b) PATH NEVER MUTATED (the regression this test exists to prevent) — even
#       while the bypass is actively engaging in (3a), $PATH itself comes out
#       byte-for-byte unchanged. This is the exact property whose absence caused
#       the real regression described above; it must hold in EVERY scenario, not
#       just the no-op one.
#   (4) LIVE SMOKE — the REAL script (not just the extracted block), invoked under
#       a fake-shim PATH, still completes (exit 0) and, where a direct candidate
#       exists, never touches the shim either — proving the block is actually
#       wired into the script's execution path, not just present as dead text.
#
# Falsified manually while authoring this test: stripping the block from either
# script drops claim (1) straight to FAIL ("block not found"). Reintroducing the
# OLD PATH-prepend fix (instead of the variable-only fix) drops claim (3b) straight
# to FAIL ("PATH was mutated"). Restoring the correct fix returns to GREEN. See the
# commit message / PR report for the quoted pass/fail counts.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CMD="$ROOT/bin/heimdall-maintain-loop"
SLREG="$ROOT/bin/heimdall-statusline-register"

[ -x "$CMD" ]   || { echo "FATAL: $CMD not executable" >&2; exit 2; }
[ -x "$SLREG" ] || { echo "FATAL: $SLREG not executable" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "pyenv-shim-fix-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"   # never touch the real ~/.heimdall or ~/.claude

# Extracts the resolve-fast-python3 case/esac block VERBATIM from a live script —
# `case "$PY..." in ... esac` — so every scenario below exercises the actual
# current code, never a hand-kept copy. Matches either $PY (heimdall-maintain-loop)
# or $PY3 (heimdall-statusline-register) or any future $PY<suffix> variable name.
extract_resolve_block() {
  awk '/^case "\$PY[A-Za-z0-9_]*" in$/{f=1} f{print} /^esac$/{if(f)exit}' "$1"
}

# The variable name the block resolves (PY, PY3, ...), read off its own case line.
resolve_varname() {
  grep -m1 '^case "\$PY[A-Za-z0-9_]*" in$' "$1" | sed -E 's/^case "\$(PY[A-Za-z0-9_]*)" in$/\1/'
}

# The first line, after the block's own esac, where the script really USES the
# resolved variable (a quoted "$VARNAME" reference — i.e. actually invokes it).
first_real_use_line() {
  local file="$1" varname esac_line needle
  varname="$(resolve_varname "$file")"
  [ -n "$varname" ] || { echo ""; return; }
  esac_line="$(awk '/^case "\$PY[A-Za-z0-9_]*" in$/{f=1} f && /^esac$/{print NR; exit}' "$file")"
  [ -n "$esac_line" ] || { echo ""; return; }
  needle="\"\$${varname}\""
  awk -v after="$esac_line" -v needle="$needle" 'NR>after && index($0,needle){print NR; exit}' "$file"
}

# Runs: VARNAME="<initial>"; <block>; then reports the FINAL value of $VARNAME and
# whether $PATH changed, as two tab-separated fields. A real temp file (instead of
# `bash -c "$string"`) sidesteps nested-quoting hazards entirely.
run_block() {
  local varname="$1" initial="$2" block="$3" script
  script="$(mktemp "$WORK/inner.XXXXXX")"
  {
    printf '%s=%q\n' "$varname" "$initial"
    printf 'BEFORE_PATH="$PATH"\n'
    printf '%s\n' "$block"
    printf 'AFTER_VAL="${%s}"\n' "$varname"
    printf '[ "$PATH" = "$BEFORE_PATH" ] && PATH_STATE=unchanged || PATH_STATE=changed\n'
    printf 'printf "%%s\\t%%s" "$AFTER_VAL" "$PATH_STATE"\n'
  } > "$script"
  bash "$script"
  rm -f "$script"
}

# ── identical scenario set, run once per script ────────────────────────────────
run_scenarios() {
  local file="$1" label="$2"
  shift 2
  # remaining args (0+) = how to invoke the LIVE script for the smoke test, e.g.:
  #   run_scenarios "$CMD" "maintain-loop" resume-hint --repo ... --planning-dir ...

  echo "── $label ──────────────────────────────────────────────"

  # (1) present + positioned
  local block varname case_line first_use
  block="$(extract_resolve_block "$file")"
  if [ -z "$block" ]; then
    bad "$label: fast-python3 resolve block not found (removed, renamed, or reworded away from the established shape?)"
    return
  fi
  varname="$(resolve_varname "$file")"
  case_line="$(grep -n '^case "\$PY[A-Za-z0-9_]*" in$' "$file" | head -1 | cut -d: -f1)"
  first_use="$(first_real_use_line "$file")"
  if [ -n "$case_line" ] && [ -n "$first_use" ] && [ "$case_line" -lt "$first_use" ]; then
    ok "$label: resolve block (line $case_line, var \$$varname) precedes first real use (line $first_use)"
  else
    bad "$label: resolve block not positioned before first \$$varname use (case=$case_line first_use=$first_use)"
  fi

  # (2) no-op when unshimmed — value AND PATH both untouched
  local noop_start="$WORK/${label}_noop_bin/python3" result val path_state
  mkdir -p "$(dirname "$noop_start")"
  result="$(run_block "$varname" "$noop_start" "$block")"
  val="${result%%$'\t'*}"; path_state="${result##*$'\t'}"
  [ "$val" = "$noop_start" ] && ok "$label: no-op when \$$varname is not under a shims/ dir (value unchanged)" \
                              || bad "$label: value was mutated even though it wasn't under shims/ (got: $val)"
  [ "$path_state" = unchanged ] && ok "$label: PATH untouched in the unshimmed case" \
                                 || bad "$label: PATH was mutated in the unshimmed case"

  # (3) bypass engages against a real candidate on this machine (else labeled-pass);
  #     PATH must stay untouched even while the bypass actively engages.
  local real_candidate=""
  for c in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [ -x "$c" ] && real_candidate="$c" && break
  done

  if [ -z "$real_candidate" ]; then
    ok "$label: no direct python3 candidate on this machine — documented no-op degrade path, nothing to bypass to (not a failure)"
    return
  fi

  local shimmed_start="$WORK/${label}_shim/shims/python3"
  mkdir -p "$(dirname "$shimmed_start")"
  result="$(run_block "$varname" "$shimmed_start" "$block")"
  val="${result%%$'\t'*}"; path_state="${result##*$'\t'}"
  [ "$val" = "$real_candidate" ] && ok "$label: bypass engaged, \$$varname now $real_candidate" \
                                  || bad "$label: bypass did not engage against a real shim path (got: $val)"
  [ "$path_state" = unchanged ] && ok "$label: PATH untouched even while the bypass engages (the regression this test guards against)" \
                                 || bad "$label: PATH was mutated while the bypass engages — this is the exact FAKEBIN-shadowing regression seen before"

  # (4) live smoke — the REAL script, not just the extracted block
  if [ $# -gt 0 ]; then
    local shim_dir hitlog
    shim_dir="$WORK/${label}_liveshim/shims"
    hitlog="$WORK/${label}_hits.log"
    mkdir -p "$shim_dir"
    : > "$hitlog"
    cat > "$shim_dir/python3" <<EOF
#!/usr/bin/env bash
echo hit >> "$hitlog"
exec "$real_candidate" "\$@"
EOF
    chmod +x "$shim_dir/python3"
    if PATH="$shim_dir:$PATH" "$file" "$@" >/dev/null 2>&1; then
      ok "$label: live invocation under a fake-shim PATH completes (exit 0)"
    else
      bad "$label: live invocation under a fake-shim PATH failed (exit $?)"
    fi
    local live_hits
    live_hits="$(wc -l < "$hitlog" | tr -d ' ')"
    [ "$live_hits" = "0" ] && ok "$label: LIVE script never invoked the shim either (0 hits — the block is actually wired in)" \
                           || bad "$label: LIVE script hit the shim $live_hits time(s) — bypass not wired into the real execution path"
  fi
}

FRESH_REPO="$WORK/freshrepo"
mkdir -p "$FRESH_REPO/.planning"

run_scenarios "$CMD" "maintain-loop" resume-hint --repo "$FRESH_REPO" --planning-dir "$FRESH_REPO/.planning"

FAKEPLUGIN="$WORK/fakeplugin"
mkdir -p "$FAKEPLUGIN/hooks"
cat > "$FAKEPLUGIN/hooks/statusline.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKEPLUGIN/hooks/statusline.sh"
export HEIMDALL_STATUSLINE_SETTINGS="$WORK/settings.json"
echo '{}' > "$HEIMDALL_STATUSLINE_SETTINGS"

run_scenarios "$SLREG" "statusline-register" status --root "$FAKEPLUGIN"

echo
echo "════════════════════════════════════════════════════════════════════════════"
printf "pyenv-shim-fix: \033[32m%d passed\033[0m, " "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf "\033[31m%d failed\033[0m\n" "$FAIL"
  exit 1
fi
printf "%d failed\n" "$FAIL"
echo "ALL GREEN — present+positioned · no-op-when-unshimmed · bypass-engages · path-never-mutated · live-smoke-wired-in"
