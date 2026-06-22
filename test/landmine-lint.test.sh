#!/usr/bin/env bash
#
# landmine-lint.test.sh — plant-and-catch harness for bin/heimdall-landmine-lint.
#
# Three proofs, all runnable, all non-skippable:
#
#   A. PLANT-AND-CATCH — write a throwaway fixture that plants exactly ONE
#      deliberate instance of EACH of the five landmine classes at a KNOWN line,
#      run the linter over it, and assert each class is flagged at the right line.
#
#   B. CLEAN-TREE — run the linter over the REAL current tree (the scripts this
#      repo actually ships) and assert it exits 0 with no findings. This is the
#      no-false-positives guarantee: the v2.0.x guards (|| true / ${var:-default}
#      / [ -t 0 ]) must NOT be flagged. A noisy linter that flags guarded code is
#      a FAILURE — this assertion is the regression fence against that.
#
#   C. GATE-BLOCKS-A-PUSH (R9) — from a clean local clone, install the native
#      pre-push hook, plant a landmine, and run the hook the way `git push` does
#      (refs on stdin) → it must exit nonzero (push blocked). Remove the landmine
#      → the hook must exit 0 (push allowed). We drive the HOOK directly; we never
#      touch origin. This proves the landmine lint is a real blocking gate, not
#      just a standalone command.
#
# Exit 0 = every proof holds. Nonzero = a proof failed (prints which).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LINT="$REPO/bin/heimdall-landmine-lint"

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$LINT" ] || { echo "FATAL: linter not executable at $LINT"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# A. PLANT-AND-CATCH — one deliberate instance of each class, at a known line.
# ─────────────────────────────────────────────────────────────────────────────
# The fixture is a single in-scope-named script (bin/heimdall-fixture) so the
# linter's default scope would pick it up; here we pass it explicitly. Every
# planted line is annotated with the class it carries; the line NUMBERS below are
# asserted, so do not reflow this heredoc without updating the EXPECT_* values.
FIX_DIR="$WORK/fixture/bin"
mkdir -p "$FIX_DIR"
FIX="$FIX_DIR/heimdall-fixture"

cat > "$FIX" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
# line 3: harmless header

# CLASS 1 — SIGPIPE: terminal `| head -c` in a command sub under set -e/pipefail,
# no trailing `|| true`. The pipe closes early → upstream SIGPIPE → abort.
sk="$(printf 'abcdefgh' | head -c 4)"

# CLASS 2 — UNGUARDED-VAR: same-line local self-reference. The RHS expands before
# the local exists, so $dir resolves to the outer scope / unbound under set -u.
seed() { local dir="$1" sub="$dir/.heimdall"; echo "$sub"; }

# CLASS 3 — BAKED-PATH: a machine-specific absolute home literal.
cfg="/Users/someone/.config/heimdall"

# CLASS 4 — TTY-READ: an interactive read from inherited stdin, no [ -t 0 ] guard.
ask() { read -p "Proceed? [y/N] " answer; echo "$answer"; }

# CLASS 5 — ORDER-DESTROY: self-delete then source a file under the deleted tree.
wipe() {
  _heimdall_remove_plugin
  source "$PLUGIN_DIR/lib.sh"
}

echo "$sk $cfg"
FIXTURE
chmod +x "$FIX"

# The asserted lines, derived from the heredoc layout above.
EXPECT_C1=7     # sk="$(printf 'abcdefgh' | head -c 4)"
EXPECT_C2=11    # seed() { local dir="$1" sub="$dir/.heimdall"; ... }
EXPECT_C3=14    # cfg="/Users/someone/.config/heimdall"
EXPECT_C4=17    # ask() { read -p "Proceed? [y/N] " answer; ... }
EXPECT_C5=22    # source "$PLUGIN_DIR/lib.sh"   (the line AFTER the delete)

LINT_OUT="$("$LINT" "$FIX" 2>/dev/null || true)"

assert_class_at_line() {
  # assert_class_at_line CLASS-TAG EXPECTED-LINE HUMAN-LABEL
  local tag="$1" want="$2" label="$3"
  local got
  got="$(printf '%s\n' "$LINT_OUT" | grep -F "  $tag  " | head -1 || true)"
  if [ -z "$got" ]; then
    bad "$label — class $tag not flagged at all"
    return
  fi
  # The finding format is  FILE:LINE  CLASS  snippet → hint. Pull the LINE.
  local gotline
  gotline="$(printf '%s' "$got" | sed -E 's/^[^:]*:([0-9]+).*/\1/')"
  if [ "$gotline" = "$want" ]; then
    ok "$label — $tag flagged at line $gotline"
  else
    bad "$label — $tag flagged at line $gotline, expected $want"
  fi
}

echo "A. PLANT-AND-CATCH (one of each class):"
assert_class_at_line "1-SIGPIPE"       "$EXPECT_C1" "class 1 SIGPIPE"
assert_class_at_line "2-UNGUARDED-VAR" "$EXPECT_C2" "class 2 UNGUARDED-VAR"
assert_class_at_line "3-BAKED-PATH"    "$EXPECT_C3" "class 3 BAKED-PATH"
assert_class_at_line "4-TTY-READ"      "$EXPECT_C4" "class 4 TTY-READ"
assert_class_at_line "5-ORDER-DESTROY" "$EXPECT_C5" "class 5 ORDER-DESTROY"

# The linter must exit nonzero when ANY landmine is present.
"$LINT" "$FIX" >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then ok "linter exits nonzero on a planted fixture (rc=$RC)"; \
  else bad "linter exited 0 on a fixture full of landmines"; fi

# ─────────────────────────────────────────────────────────────────────────────
# A2. CLASS-4 HARDENING — the non-TTY PROMPT-read class, every read form.
# ─────────────────────────────────────────────────────────────────────────────
# Regression fence for the F1-launcher gap: the old class-4 rule SKIPPED any
# `read -t N` as "guarded", so an interactive `read -rt 60 -p "choose [1/2]…"`
# (a 60s-stall-per-call prompt) sailed through — the exact non-TTY-read class the
# rule exists to catch. The hardened rule: a TIMEOUT IS NOT A GUARD; only a
# `[ -t 0 ]` (or --yes/-y refusal) is. This fixture plants every read shape at a
# known line and asserts each is flagged / NOT flagged. Do NOT reflow the heredoc
# without updating the EXPECT_* / NOFLAG_* line numbers below.
FIX4="$FIX_DIR/heimdall-fixture4"
cat > "$FIX4" <<'FIXTURE4'
#!/usr/bin/env bash
set -euo pipefail
# line 3: header
unguarded_p() { read -p "Proceed? [y/N] " ans; echo "$ans"; }
# line 5: read -rt 60 -p — TIMEOUT-ONLY, combined -rt (the F1 launcher shape).
timeout_combined() { read -rt 60 -p "choose [1/2]: " c || c=1; echo "$c"; }
# line 7: read -t 60 -rp — TIMEOUT-ONLY, separate -t token, -rp prompt cluster.
timeout_separate() { read -t 60 -rp "choose: " v || v=1; echo "$v"; }
guarded_p() {
  if [ -t 0 ]; then
    read -p "ok? " g; echo "$g"
  fi
}
stream_loop() {
  printf 'a\nb\n' | while IFS= read -r ln; do echo "$ln"; done
}
file_read() { read -r host < /etc/hostname; echo "$host"; }
keypress_poll() { read -rsn1 -t 2 junk 2>/dev/null || true; }
herestring() { read -r x y <<< "1 2"; echo "$x$y"; }
FIXTURE4
chmod +x "$FIX4"

# FLAGGED (interactive prompt, no [ -t 0 ]): the -p read, both timeout-only reads.
EXPECT4_PLAIN=4        # read -p  (no timeout, no guard)
EXPECT4_TCOMBINED=6    # read -rt 60 -p  (timeout-only, combined -rt)
EXPECT4_TSEPARATE=8    # read -t 60 -rp  (timeout-only, separate -t)
# NOT flagged: guarded read-p (12), stream loop (16), file read (18),
# keypress poll (19), herestring (20).
NOFLAG4_LINES="12 16 18 19 20"

LINT4_OUT="$("$LINT" "$FIX4" 2>/dev/null || true)"

echo "A2. CLASS-4 HARDENING (non-TTY PROMPT read — timeout is NOT a guard):"

assert_c4_flagged() {
  # assert_c4_flagged EXPECTED-LINE HUMAN-LABEL
  local want="$1" label="$2" got
  got="$(printf '%s\n' "$LINT4_OUT" | grep -F "  4-TTY-READ  " \
         | sed -E 's/^[^:]*:([0-9]+).*/\1/' | grep -Fx "$want" | head -1 || true)"
  if [ "$got" = "$want" ]; then ok "$label — flagged at line $want"; \
    else bad "$label — class 4 NOT flagged at line $want (got lines: $(printf '%s' "$LINT4_OUT" | grep -F '  4-TTY-READ  ' | sed -E 's/^[^:]*:([0-9]+).*/\1/' | tr '\n' ' '))"; fi
}
assert_c4_flagged "$EXPECT4_PLAIN"     "read -p (unguarded)"
assert_c4_flagged "$EXPECT4_TCOMBINED" "read -rt 60 -p (timeout-only, combined)"
assert_c4_flagged "$EXPECT4_TSEPARATE" "read -t 60 -rp (timeout-only, separate)"

# NO false positives: none of the safe forms may appear as a class-4 finding.
c4_flagged_lines="$(printf '%s\n' "$LINT4_OUT" | grep -F '  4-TTY-READ  ' | sed -E 's/^[^:]*:([0-9]+).*/\1/' | tr '\n' ' ')"
nf_clean=1
for nf in $NOFLAG4_LINES; do
  case " $c4_flagged_lines " in
    *" $nf "*) bad "false positive — safe read at line $nf was flagged class 4"; nf_clean=0 ;;
  esac
done
[ "$nf_clean" -eq 1 ] && ok "no false positives on guarded read-p / stream loop / file read / keypress poll / herestring"

# Exactly three class-4 findings expected (the three unguarded prompts).
c4_count="$(printf '%s\n' "$LINT4_OUT" | grep -cF '  4-TTY-READ  ' || true)"
if [ "$c4_count" = "3" ]; then ok "exactly 3 class-4 findings (the 3 unguarded prompts)"; \
  else bad "expected 3 class-4 findings, got $c4_count"; fi

# ─────────────────────────────────────────────────────────────────────────────
# B. CLEAN-TREE — zero false positives on the real shipped scripts.
# ─────────────────────────────────────────────────────────────────────────────
echo "B. CLEAN-TREE (no false positives on the real current tree):"
TREE_OUT="$("$LINT" --root "$REPO" 2>&1)"
TREE_RC=$?
if [ "$TREE_RC" -eq 0 ]; then
  ok "real tree is clean (exit 0): ${TREE_OUT##*$'\n'}"
else
  bad "real tree flagged a landmine (exit $TREE_RC) — false positive(s):"
  printf '%s\n' "$TREE_OUT" | sed 's/^/      /'
fi

# ─────────────────────────────────────────────────────────────────────────────
# C. GATE-BLOCKS-A-PUSH (R9) — the pre-push hook actually refuses a landmine.
# ─────────────────────────────────────────────────────────────────────────────
# We exercise the gate the way `git push` does: run the native pre-push hook with
# refs on stdin. The hook delegates to bin/heimdall-selfscan, which now runs the
# landmine lint as a blocking step. We DO NOT push to origin — we drive the hook.
echo "C. GATE-BLOCKS-A-PUSH (R9, hook-driven, no origin):"
CLONE="$WORK/clone"
if git clone --quiet --local "$REPO" "$CLONE" 2>/dev/null; then
  # Match this repo's relocatable wiring: hooks live in .heimdall/git-hooks and
  # core.hooksPath points there (relative). The clone carries .heimdall/git-hooks
  # in-tree; wire core.hooksPath so the native hook is live.
  git -C "$CLONE" config core.hooksPath .heimdall/git-hooks
  HOOK="$CLONE/.heimdall/git-hooks/pre-push"
  if [ ! -x "$HOOK" ]; then
    # Fall back to the canonical source location if the dotdir copy is absent.
    HOOK="$CLONE/hooks/git/pre-push"
  fi
  # Clean clone: the hook must pass (gitleaks=0, identities ok, landmines=0).
  if ( cd "$CLONE" && printf '' | "$HOOK" origin "$REPO" >/dev/null 2>&1 ); then
    ok "clean clone: pre-push hook allows the push (exit 0)"
  else
    bad "clean clone: pre-push hook BLOCKED a clean push (should allow)"
  fi
  # Plant a landmine into an in-scope script in the clone and commit it.
  printf '\nbad="$(printf x | head -c 1)"\n' >> "$CLONE/bin/heimdall-selfscan"
  git -C "$CLONE" add bin/heimdall-selfscan >/dev/null 2>&1
  git -C "$CLONE" commit --quiet --no-verify -m "test: plant a class-1 landmine" >/dev/null 2>&1
  if ( cd "$CLONE" && printf '' | "$HOOK" origin "$REPO" >/dev/null 2>&1 ); then
    bad "planted landmine: pre-push hook ALLOWED the push (gate did not block)"
  else
    ok "planted landmine: pre-push hook BLOCKS the push (nonzero)"
  fi
  # Remove the landmine → the hook must allow the push again.
  git -C "$CLONE" revert --no-edit --no-commit HEAD >/dev/null 2>&1 \
    || git -C "$CLONE" checkout -- bin/heimdall-selfscan >/dev/null 2>&1
  git -C "$CLONE" reset --soft HEAD~1 >/dev/null 2>&1 || true
  git -C "$CLONE" checkout -- bin/heimdall-selfscan >/dev/null 2>&1 || true
  if ( cd "$CLONE" && printf '' | "$HOOK" origin "$REPO" >/dev/null 2>&1 ); then
    ok "landmine removed: pre-push hook allows the push again (exit 0)"
  else
    bad "landmine removed: pre-push hook still blocks (should allow)"
  fi
else
  bad "could not create a local clone for the gate proof"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "landmine-lint.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
