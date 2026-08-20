#!/usr/bin/env bash
# test/prepare-commit-msg-trailer.test.sh — mechanical hmd co-author trailer.
#
# WHAT THIS GATES. `hmd init` generates .heimdall/hooks/prepare-commit-msg, which
# appends `Co-Authored-By: hmd <hmd@runheimdall.dev>` to every commit message that
# doesn't already carry it (CLAUDE.md "Commit attribution"). This exists because
# prose alone failed: agents were told to add the trailer in every spawn prompt and
# still didn't (measured baseline: 55/81 commits since 2026-08-18 had it, 26 did
# not) — the same class of gap that only a mechanical PreToolUse hook closed for
# "commit early" (bin/heimdall-wip-commit). This is that fix for attribution.
#
# WHY prepare-commit-msg AND NOT pre-commit/commit-msg. Verified empirically (not
# assumed): `git commit --no-verify` skips pre-commit and commit-msg but does NOT
# skip prepare-commit-msg. Agents in this repo commit with --no-verify (see
# bin/heimdall-wip-commit, CLAUDE.md "Pre-commit vs pre-push"), so any hook that
# --no-verify skips would never fire for the commits this feature most needs to
# reach. Section 5 below is the regression lock on this exact property.
#
# GUARANTEES PROVED (hermetic — own throwaway git repo per section, HOME
# redirected, no network):
#   1. INSTALL             — hmd init generates an executable, syntactically valid hook.
#   2/3. ADDED / NOT DUPLICATED — a plain commit gets the trailer appended; a
#                          commit that already carries it is left with exactly one.
#   4. MODEL TRAILER KEPT  — an existing Co-Authored-By (e.g. Claude's own) survives
#                          alongside the added hmd trailer — never overwritten.
#   5. --no-verify         — the trailer still lands under --no-verify (the whole
#                          reason this hook was chosen over pre-commit/commit-msg).
#   6. MERGE SAFE          — a real --no-ff merge commit keeps "Merge branch ..."
#                          and gains exactly one trailer.
#   7. SQUASH SAFE         — a squash-merge commit is handled the same way.
#   8. AMEND SAFE          — amending a commit that already has the trailer (added
#                          by this same hook) never duplicates it.
#   9. CHAINING            — a repo's own pre-existing prepare-commit-msg still
#                          runs, first; removing the chain pointer stops it (the
#                          falsifier proving the chain is real, not coincidental).
#  10. HMD_SKIP NOT CONSULTED — the trailer is added even under HMD_SKIP=1: an
#                          attribution trailer is not a quality gate.
#  11. FAIL OPEN           — no args, a nonexistent path, and an unwritable file
#                          with real content all exit 0, with the message (where it
#                          exists) byte-for-byte UNCHANGED. Malformed input must
#                          never be the reason a commit — or its content — is lost.
#  12. EMPTY-MESSAGE ABORT PATH PROTECTED — a comment-only message (what git shows
#                          before the user types anything) is left untouched, so a
#                          blank-to-abort commit still aborts.
#  13. NO TRAILING NEWLINE — a message with no final newline still gets exactly
#                          one well-formed trailer line, not a welded-together one.
#
# FALSIFIABILITY (proof quoted in the implementing commit, not re-asserted here):
# the idempotency check (`grep -qiF "$TRAILER"`) was mutated to compare against a
# deliberately wrong string, which turned sections 3/8 red (duplicate trailers) —
# then reverted back to green. See the commit message for the exact PASS/FAIL
# counts both directions.
#
# NOT RETROACTIVE. History predating this hook is untouched by design — rewriting
# ~195 already-made commits would change every SHA (CLAUDE.md "Commit
# attribution"). This suite only proves the hook is correct GOING FORWARD.
#
# EXIT: 0 = every proof holds; 1 = any FAIL.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin"
INIT_BIN="$BIN/heimdall-init"

# post-commit (installed alongside prepare-commit-msg by the same `hmd init` call)
# shells the REAL heimdall-presence beat. Pin the default control-plane URL to a
# dead local port so a fresh/undecided HOME under this test can never reach prod.
. "$REPO/test/lib/net-default-guard.sh"

[ -x "$INIT_BIN" ] || { echo "FATAL: missing/!exec $INIT_BIN" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found" >&2; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "FATAL: awk not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-pcm.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
export HOME="$WORK/home"; mkdir -p "$HOME/.heimdall"
export HEIMDALL_NO_TEAM_AUTOSHARE=1

TRAILER='Co-Authored-By: hmd <hmd@runheimdall.dev>'

gitcfg() { git -C "$1" config user.email dev@example.com; git -C "$1" config user.name Dev; }
newrepo() { mkdir -p "$1"; git -C "$1" init -q; gitcfg "$1"; }
hmdinit() { ( cd "$1" && "$INIT_BIN" --no-cursor-statusline >/dev/null 2>&1 ); }
trailer_count_commit() { git -C "$1" log -1 --format=%B 2>/dev/null | grep -Fc "$TRAILER"; }
trailer_count_file() { grep -Fc "$TRAILER" "$1" 2>/dev/null; }

echo "════════════════════════════════════════════════════════════════"
echo "prepare-commit-msg — mechanical hmd co-author trailer"
echo "════════════════════════════════════════════════════════════════"

# ══════════════════════════════════════════════════════════════════════════════
# 1. INSTALL
# ══════════════════════════════════════════════════════════════════════════════
R1="$WORK/r1"; newrepo "$R1"; hmdinit "$R1"
HOOK1="$R1/.heimdall/hooks/prepare-commit-msg"
[ -x "$HOOK1" ] && ok "1a prepare-commit-msg installed and executable" || bad "1a missing/not executable" "$HOOK1"
bash -n "$HOOK1" 2>"$WORK/synerr.txt" && ok "1b generated hook is syntactically valid bash" || bad "1b bash -n failed" "$(cat "$WORK/synerr.txt" 2>/dev/null)"

# ══════════════════════════════════════════════════════════════════════════════
# 2/3. ADDED WHEN ABSENT, then NOT DUPLICATED WHEN ALREADY PRESENT
# ══════════════════════════════════════════════════════════════════════════════
R2="$WORK/r2"; newrepo "$R2"; hmdinit "$R2"
printf 'one\n' > "$R2/f.txt"; git -C "$R2" add f.txt
git -C "$R2" commit -q -m "first commit" >/dev/null 2>&1
[ "$(trailer_count_commit "$R2")" = "1" ] && ok "2a trailer appended to a plain commit" || bad "2a trailer not exactly once" "count=$(trailer_count_commit "$R2")"
git -C "$R2" log -1 --format=%s | grep -qF "first commit" && ok "2b subject preserved" || bad "2b subject lost"

printf 'two\n' > "$R2/g.txt"; git -C "$R2" add g.txt
git -C "$R2" commit -q -m "second commit" -m "$TRAILER" >/dev/null 2>&1
[ "$(trailer_count_commit "$R2")" = "1" ] && ok "3a trailer NOT duplicated when author already included it" || bad "3a duplicated" "count=$(trailer_count_commit "$R2")"

# ══════════════════════════════════════════════════════════════════════════════
# 4. MODEL TRAILER PRESERVED ALONGSIDE
# ══════════════════════════════════════════════════════════════════════════════
R4="$WORK/r4"; newrepo "$R4"; hmdinit "$R4"
printf 'x\n' > "$R4/f.txt"; git -C "$R4" add f.txt
git -C "$R4" commit -q -m "add feature" -m "Co-Authored-By: Claude Opus <noreply@anthropic.com>" >/dev/null 2>&1
BODY4="$(git -C "$R4" log -1 --format=%B)"
printf '%s' "$BODY4" | grep -qF "Co-Authored-By: Claude Opus" && ok "4a model trailer preserved" || bad "4a model trailer lost" "$BODY4"
printf '%s' "$BODY4" | grep -qF "$TRAILER" && ok "4b hmd trailer added alongside it" || bad "4b hmd trailer missing" "$BODY4"
[ "$(trailer_count_commit "$R4")" = "1" ] && ok "4c hmd trailer exactly once" || bad "4c count wrong" "count=$(trailer_count_commit "$R4")"

# ══════════════════════════════════════════════════════════════════════════════
# 5. --no-verify STILL GETS THE TRAILER (the reason this hook was chosen at all)
# ══════════════════════════════════════════════════════════════════════════════
R5="$WORK/r5"; newrepo "$R5"; hmdinit "$R5"
printf 'x\n' > "$R5/f.txt"; git -C "$R5" add f.txt
git -C "$R5" commit -q --no-verify -m "no-verify commit" >/dev/null 2>&1
[ "$(trailer_count_commit "$R5")" = "1" ] && ok "5 trailer present under --no-verify" || bad "5 trailer missing under --no-verify" "count=$(trailer_count_commit "$R5")"

# ══════════════════════════════════════════════════════════════════════════════
# 6. MERGE COMMIT SAFE
# ══════════════════════════════════════════════════════════════════════════════
R6="$WORK/r6"; newrepo "$R6"
printf 'base\n' > "$R6/base.txt"; git -C "$R6" add base.txt; git -C "$R6" commit -q -m "base" --no-verify >/dev/null 2>&1
BASE6="$(git -C "$R6" symbolic-ref --short HEAD)"
hmdinit "$R6"
git -C "$R6" checkout -q -b feature6
printf 'feat\n' > "$R6/feat.txt"; git -C "$R6" add feat.txt; git -C "$R6" commit -q -m "add feat" >/dev/null 2>&1
git -C "$R6" checkout -q "$BASE6"
printf 'main\n' > "$R6/main.txt"; git -C "$R6" add main.txt; git -C "$R6" commit -q -m "add main" >/dev/null 2>&1
git -C "$R6" merge -q --no-ff --no-edit feature6 >/dev/null 2>&1
BODY6="$(git -C "$R6" log -1 --format=%B)"
printf '%s' "$BODY6" | grep -qi "Merge branch" && ok "6a merge commit message intact" || bad "6a merge text lost" "$BODY6"
[ "$(trailer_count_commit "$R6")" = "1" ] && ok "6b trailer added to merge commit exactly once" || bad "6b count wrong" "count=$(trailer_count_commit "$R6")"

# ══════════════════════════════════════════════════════════════════════════════
# 7. SQUASH MESSAGE SAFE
# ══════════════════════════════════════════════════════════════════════════════
R7="$WORK/r7"; newrepo "$R7"
printf 'base\n' > "$R7/base.txt"; git -C "$R7" add base.txt; git -C "$R7" commit -q -m "base" --no-verify >/dev/null 2>&1
BASE7="$(git -C "$R7" symbolic-ref --short HEAD)"
hmdinit "$R7"
git -C "$R7" checkout -q -b feature7
printf 'feat\n' > "$R7/feat.txt"; git -C "$R7" add feat.txt; git -C "$R7" commit -q -m "add feat" >/dev/null 2>&1
git -C "$R7" checkout -q "$BASE7"
git -C "$R7" merge -q --squash feature7 >/dev/null 2>&1
git -C "$R7" commit -q --no-edit >/dev/null 2>&1
BODY7="$(git -C "$R7" log -1 --format=%B)"
printf '%s' "$BODY7" | grep -qi "add feat" && ok "7a squash message content preserved" || bad "7a squash text lost/unexpected" "$BODY7"
[ "$(trailer_count_commit "$R7")" = "1" ] && ok "7b trailer added to squash commit exactly once" || bad "7b count wrong" "count=$(trailer_count_commit "$R7")"

# ══════════════════════════════════════════════════════════════════════════════
# 8. AMEND SAFE — never duplicates a trailer this same hook already added
# ══════════════════════════════════════════════════════════════════════════════
R8="$WORK/r8"; newrepo "$R8"; hmdinit "$R8"
printf 'x\n' > "$R8/f.txt"; git -C "$R8" add f.txt
git -C "$R8" commit -q -m "amend me" >/dev/null 2>&1
[ "$(trailer_count_commit "$R8")" = "1" ] && ok "8pre trailer present before amend (precondition)" || bad "8pre trailer missing before amend" "count=$(trailer_count_commit "$R8")"
git -C "$R8" commit -q --amend --no-edit --allow-empty >/dev/null 2>&1
[ "$(trailer_count_commit "$R8")" = "1" ] && ok "8 amend does not duplicate an existing trailer" || bad "8 duplicated on amend" "count=$(trailer_count_commit "$R8")"

# ══════════════════════════════════════════════════════════════════════════════
# 9. CHAINING — a pre-existing prepare-commit-msg still runs, first + falsifier
# ══════════════════════════════════════════════════════════════════════════════
R9="$WORK/r9"; newrepo "$R9"
mkdir -p "$R9/.git/hooks"
MARKER9="$R9/.prior-hook-marker"
cat > "$R9/.git/hooks/prepare-commit-msg" <<EOF
#!/usr/bin/env bash
echo fired >> "$MARKER9"
exit 0
EOF
chmod +x "$R9/.git/hooks/prepare-commit-msg"
hmdinit "$R9"
printf 'x\n' > "$R9/f.txt"; git -C "$R9" add f.txt
git -C "$R9" commit -q -m "chained commit" >/dev/null 2>&1
[ -f "$MARKER9" ] && ok "9a pre-existing prepare-commit-msg still runs (chained)" || bad "9a prior hook never fired"
[ "$(trailer_count_commit "$R9")" = "1" ] && ok "9b hmd trailer still added on top of the chain" || bad "9b trailer missing after chaining" "count=$(trailer_count_commit "$R9")"
rm -f "$MARKER9"
git -C "$R9" config --unset heimdall.prevHooksPath
printf 'y\n' > "$R9/f2.txt"; git -C "$R9" add f2.txt
git -C "$R9" commit -q -m "unchained commit" >/dev/null 2>&1
[ ! -f "$MARKER9" ] && ok "9c falsifier: no prevHooksPath -> prior hook does not run" || bad "9c prior hook fired without a chain pointer"
[ "$(trailer_count_commit "$R9")" = "1" ] && ok "9d trailer still added with chaining removed" || bad "9d trailer missing" "count=$(trailer_count_commit "$R9")"

# ══════════════════════════════════════════════════════════════════════════════
# 10. HMD_SKIP IS NOT CONSULTED — attribution is not a gate
# ══════════════════════════════════════════════════════════════════════════════
R10="$WORK/r10"; newrepo "$R10"; hmdinit "$R10"
printf 'x\n' > "$R10/f.txt"; git -C "$R10" add f.txt
HMD_SKIP=1 git -C "$R10" commit -q -m "skip test" >/dev/null 2>&1
[ "$(trailer_count_commit "$R10")" = "1" ] && ok "10 trailer added even under HMD_SKIP=1" || bad "10 trailer missing under HMD_SKIP" "count=$(trailer_count_commit "$R10")"

# ══════════════════════════════════════════════════════════════════════════════
# 11. FAIL OPEN — malformed input never blocks, never loses content
# ══════════════════════════════════════════════════════════════════════════════
R11="$WORK/r11"; newrepo "$R11"; hmdinit "$R11"
HOOK11="$R11/.heimdall/hooks/prepare-commit-msg"

( cd "$R11" && "$HOOK11" ); RC=$?
[ "$RC" = "0" ] && ok "11a no args at all -> exit 0" || bad "11a nonzero exit with no args" "rc=$RC"

( cd "$R11" && "$HOOK11" "$R11/does-not-exist.txt" ); RC=$?
[ "$RC" = "0" ] && ok "11b nonexistent message file -> exit 0" || bad "11b nonzero exit" "rc=$RC"

RO="$R11/readonly-msg.txt"
printf 'Subject line only\n' > "$RO"
BEFORE="$(cat "$RO")"
chmod 444 "$RO"
( cd "$R11" && "$HOOK11" "$RO" ); RC=$?
chmod 644 "$RO"
AFTER="$(cat "$RO")"
[ "$RC" = "0" ] && ok "11c unwritable message file -> exit 0" || bad "11c nonzero exit" "rc=$RC"
[ "$BEFORE" = "$AFTER" ] && ok "11d unwritable message file content byte-for-byte unchanged" || bad "11d content changed" "before=[$BEFORE] after=[$AFTER]"

# ══════════════════════════════════════════════════════════════════════════════
# 12. PROTECT THE EMPTY-MESSAGE ABORT PATH — comment-only message untouched
# ══════════════════════════════════════════════════════════════════════════════
CMTONLY="$R11/comment-only.txt"
cat > "$CMTONLY" <<'MSG'
# Please enter the commit message for your changes. Lines starting
# with '#' will be ignored, and an empty message aborts the commit.
#
# On branch main
# nothing to commit, working tree clean
MSG
BEFORE12="$(cat "$CMTONLY")"
( cd "$R11" && "$HOOK11" "$CMTONLY" ); RC=$?
AFTER12="$(cat "$CMTONLY")"
[ "$RC" = "0" ] && ok "12a comment-only message -> exit 0" || bad "12a nonzero exit" "rc=$RC"
[ "$BEFORE12" = "$AFTER12" ] && ok "12b comment-only message left untouched (abort path protected)" || bad "12b comment-only message was mutated"

# ══════════════════════════════════════════════════════════════════════════════
# 13. NO TRAILING NEWLINE — handled without corrupting the subject line
# ══════════════════════════════════════════════════════════════════════════════
NONL="$R11/no-trailing-newline.txt"
printf 'Subject with no trailing newline' > "$NONL"
( cd "$R11" && "$HOOK11" "$NONL" ); RC=$?
[ "$RC" = "0" ] && ok "13a no-trailing-newline message -> exit 0" || bad "13a nonzero exit" "rc=$RC"
[ "$(trailer_count_file "$NONL")" = "1" ] && ok "13b trailer added exactly once" || bad "13b count wrong" "count=$(trailer_count_file "$NONL")"
head -1 "$NONL" | grep -qF "Subject with no trailing newline" && ok "13c original subject line intact, not welded to the trailer" || bad "13c subject line corrupted" "$(head -1 "$NONL")"

# ─────────────────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════"
printf "TOTAL: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
